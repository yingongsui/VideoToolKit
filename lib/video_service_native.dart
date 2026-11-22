import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'app_settings.dart';
import 'video_models.dart';

// ============================================================================
// Native Desktop Implementation (macOS / Windows / Linux)
// ============================================================================

/// Renders a local image file on native platforms.
Widget buildLocalImage(
  String path, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
}) {
  return Image.file(
    File(path),
    width: width,
    height: height,
    fit: fit,
  );
}

class VideoService {
  /// Indicates whether the service is running in Web mock preview mode.
  static const bool isWebPreview = false;

  /// Stores the most recent thumbnail error message for diagnostics/tooltips.
  static String? lastThumbnailError;

  // Serializes FFmpeg/FFprobe background tasks to avoid native concurrency failures.
  static Future<void> _taskQueue = Future.value();

  static Future<T> _enqueue<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _taskQueue = _taskQueue.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Returns an existing, writable cache directory (creates it if missing on macOS).
  static Future<Directory> _getWritableCacheDir() async {
    Directory baseDir;
    try {
      baseDir = await getTemporaryDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }
    final cacheDir = Directory('${baseDir.path}/video_merger_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  /// Default initial folders (empty on native; user picks real directories).
  static List<String> get defaultPreviewFolders => const [];

  /// Checks whether a local directory exists.
  static Future<bool> directoryExists(String folderPath) {
    return Directory(folderPath).exists();
  }

  /// Opens the native OS directory picker.
  static Future<String?> pickDirectory({String? dialogTitle}) {
    return FilePicker.platform.getDirectoryPath(
      dialogTitle: dialogTitle ?? "Select Folder",
    );
  }

  /// Opens the native OS multi-file picker for allowed video extensions.
  static Future<List<String>> pickVideoFiles({
    String? dialogTitle,
    List<String>? allowedExtensions,
  }) async {
    final exts = allowedExtensions ?? AppSettings.builtInExtensions;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: dialogTitle ?? "Select Video Files",
      type: FileType.custom,
      allowedExtensions: exts,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return [];
    return result.files.map((f) => f.path).whereType<String>().toList();
  }

  /// Scans a local directory (non-recursive) and returns sorted video paths.
  static Future<List<String>> scanVideosInFolder(
    String folderPath, {
    List<String>? allowedExtensions,
  }) async {
    final exts = (allowedExtensions ?? AppSettings.builtInExtensions)
        .map((e) => e.toLowerCase())
        .toSet();
    final dir = Directory(folderPath);
    if (!await dir.exists()) return [];

    final results = <String>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final fileName = entity.path.split('/').last;
          if (fileName.startsWith('.')) continue;

          final dotIdx = fileName.lastIndexOf('.');
          if (dotIdx == -1) continue;

          final ext = fileName.substring(dotIdx + 1).toLowerCase();
          if (exts.contains(ext)) {
            results.add(entity.path);
          }
        }
      }
      results.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    } catch (e) {
      debugPrint("[VideoService] Failed to scan folder '$folderPath': $e");
    }
    return results;
  }

  /// Generates and caches a thumbnail sampled at 10% of the video's total frames.
  static Future<String?> generateThumbnail(
    String videoPath, {
    double? fpsValue,
    int? totalFrames,
    double? durationSeconds,
  }) async {
    final sampledFrame = (totalFrames != null && totalFrames > 0)
        ? (totalFrames * 0.10).round()
        : 0;

    double seekSeconds = 0.0;
    if (sampledFrame > 0 && fpsValue != null && fpsValue > 0) {
      seekSeconds = sampledFrame / fpsValue;
    } else if (durationSeconds != null && durationSeconds > 0) {
      seekSeconds = durationSeconds * 0.10;
    }

    return _extractFrameImage(
      videoPath: videoPath,
      cacheKey: "thumb_v2_${videoPath.hashCode}_10pct_f$sampledFrame",
      scaleWidth: 480,
      seekSeconds: seekSeconds,
      allowFirstFrameFallback: true,
    );
  }

  /// Extracts a single preview frame at the given timestamp/frame for trim previewing.
  static Future<String?> extractFrameAtTime(
    String videoPath,
    double timestampSeconds, {
    int? frameNumber,
  }) async {
    final key = frameNumber != null
        ? "f$frameNumber"
        : "ms${(timestampSeconds * 1000).round()}";

    return _extractFrameImage(
      videoPath: videoPath,
      cacheKey: "trim_v2_${videoPath.hashCode}_$key",
      scaleWidth: 960,
      seekSeconds: timestampSeconds,
      allowFirstFrameFallback: false,
    );
  }

  /// Shared JPEG + PNG fallback frame extraction helper.
  static Future<String?> _extractFrameImage({
    required String videoPath,
    required String cacheKey,
    required int scaleWidth,
    required double seekSeconds,
    required bool allowFirstFrameFallback,
  }) async {
    return _enqueue(() async {
      try {
        final cacheDir = await _getWritableCacheDir();
        final jpgPath = "${cacheDir.path}/$cacheKey.jpg";
        final jpgFile = File(jpgPath);
        if (await jpgFile.exists() && await jpgFile.length() > 0) {
          return jpgPath;
        }

        // Convert to full-range yuvj420p with -strict unofficial for MJPEG compatibility.
        final jpgArgs = <String>[
          '-y',
          if (seekSeconds > 0) ...['-ss', seekSeconds.toStringAsFixed(3)],
          '-i',
          videoPath,
          '-frames:v',
          '1',
          '-vf',
          'scale=$scaleWidth:-2,format=yuvj420p',
          '-strict',
          'unofficial',
          '-q:v',
          '3',
          jpgPath,
        ];

        final session = await FFmpegKit.executeWithArguments(jpgArgs);
        if (ReturnCode.isSuccess(await session.getReturnCode()) &&
            await jpgFile.exists() &&
            await jpgFile.length() > 0) {
          return jpgPath;
        }

        debugPrint(
          "[VideoService] JPEG extraction failed for '$videoPath': ${await session.getOutput()}",
        );

        // Fallback to PNG (avoids MJPEG pixel-format restrictions).
        final pngPath = "${cacheDir.path}/${cacheKey}_fallback.png";
        final pngFile = File(pngPath);
        if (await pngFile.exists() && await pngFile.length() > 0) {
          return pngPath;
        }

        final pngArgs = <String>[
          '-y',
          if (!allowFirstFrameFallback && seekSeconds > 0) ...[
            '-ss',
            seekSeconds.toStringAsFixed(3),
          ],
          '-i',
          videoPath,
          '-frames:v',
          '1',
          '-vf',
          'scale=$scaleWidth:-2',
          pngPath,
        ];
        final fallbackSession = await FFmpegKit.executeWithArguments(pngArgs);
        if (ReturnCode.isSuccess(await fallbackSession.getReturnCode()) &&
            await pngFile.exists() &&
            await pngFile.length() > 0) {
          return pngPath;
        }

        final pngErr =
            await fallbackSession.getOutput() ?? "Unknown FFmpeg error";
        lastThumbnailError = pngErr.trim().split('\n').last;
        debugPrint(
          "[VideoService] PNG fallback failed for '$videoPath': $pngErr",
        );
      } catch (e) {
        lastThumbnailError = e.toString();
        debugPrint("[VideoService] Frame extraction error: $e");
      }
      return null;
    });
  }

  /// Probes detailed video and audio metadata using file stats and FFprobeKit.
  static Future<VideoMetadata> getVideoMetadata(String videoPath) async {
    return _enqueue(() async {
      try {
        String sizeStr = "Unknown";
        try {
          final file = File(videoPath);
          if (file.existsSync()) {
            sizeStr = formatByteSize(file.lengthSync());
          }
        } catch (_) {}

        final session = await FFprobeKit.getMediaInformation(videoPath);
        final info = session.getMediaInformation();
        if (info == null) return VideoMetadata(size: sizeStr);

        String bitrate = "Unknown";
        if (info.getBitrate() != null) {
          final parsedBitrate = double.tryParse(info.getBitrate()!);
          if (parsedBitrate != null) {
            bitrate = "${(parsedBitrate / 1000).toStringAsFixed(0)} kbps";
          }
        }

        final durationSec = double.tryParse(info.getDuration() ?? '') ?? 0.0;
        final durationStr = formatDuration(durationSec);

        String resolution = "Unknown";
        String timebase = "Unknown";
        double? fpsValue;
        String fpsStr = "Unknown";
        String pixelFormat = "Unknown";
        String videoProfile = "Unknown";
        String vCodec = "Unknown";

        String aCodec = "No Audio";
        String aSampleRate = "N/A";
        String aChannelLayout = "N/A";

        bool hasVideo = false;
        bool hasAudio = false;

        for (final stream in info.getStreams()) {
          final props = stream.getAllProperties();

          if (stream.getType() == "video" && !hasVideo) {
            hasVideo = true;
            resolution = "${stream.getWidth()}x${stream.getHeight()}";

            if (stream.getCodec() != null) {
              vCodec = stream.getCodec()!.toUpperCase();
            }

            final tb = stream.getTimeBase() ?? props?['time_base']?.toString();
            if (tb != null && tb.isNotEmpty) timebase = tb;

            final pixFmt =
                stream.getFormat() ?? props?['pix_fmt']?.toString();
            if (pixFmt != null && pixFmt.isNotEmpty) pixelFormat = pixFmt;

            final profile = props?['profile']?.toString();
            if (profile != null && profile.isNotEmpty) {
              videoProfile = _normalizeProfileName(vCodec, profile);
            }

            final rawFps =
                stream.getRealFrameRate() ?? stream.getAverageFrameRate();
            if (rawFps != null && rawFps.contains('/')) {
              final parts = rawFps.split('/');
              final num = double.tryParse(parts[0]);
              final den = double.tryParse(parts[1]);
              if (num != null && den != null && den != 0) {
                fpsValue = num / den;
                fpsStr = formatFps(fpsValue);
              }
            }
          } else if (stream.getType() == "audio" && !hasAudio) {
            hasAudio = true;
            if (stream.getCodec() != null) {
              aCodec = stream.getCodec()!.toUpperCase();
            }

            final sr =
                stream.getSampleRate() ?? props?['sample_rate']?.toString();
            if (sr != null && sr.isNotEmpty) aSampleRate = "$sr Hz";

            final layout = stream.getChannelLayout() ??
                props?['channel_layout']?.toString();
            if (layout != null && layout.isNotEmpty) {
              aChannelLayout = layout;
            } else if (props?['channels'] != null) {
              aChannelLayout = "${props!['channels']}ch";
            }
          }
        }

        final totalFrames = (durationSec > 0 && fpsValue != null && fpsValue > 0)
            ? (durationSec * fpsValue).round()
            : 0;

        return VideoMetadata(
          videoCodec: vCodec,
          resolution: resolution,
          timebase: timebase,
          fps: fpsStr,
          fpsValue: fpsValue,
          pixelFormat: pixelFormat,
          videoProfile: videoProfile,
          audioCodec: aCodec,
          audioSampleRate: aSampleRate,
          audioChannelLayout: aChannelLayout,
          bitrate: bitrate,
          totalFrames: totalFrames,
          duration: durationStr,
          durationSeconds: durationSec,
          size: sizeStr,
        );
      } catch (e) {
        debugPrint("[VideoService] Metadata probe error: $e");
        return VideoMetadata();
      }
    });
  }

  /// Extracts keyframe (I-frame) timestamps within a local window around [centerSeconds]
  /// using FFprobe -read_intervals to avoid full-file packet scans and native log overflow.
  static Future<List<double>> getKeyframesNear(
    String videoPath, {
    required double centerSeconds,
    double windowSeconds = 15.0,
    double durationSeconds = 0.0,
  }) async {
    return _enqueue(() async {
      try {
        final start = (centerSeconds - windowSeconds) < 0
            ? 0.0
            : (centerSeconds - windowSeconds);
        final span = (windowSeconds * 2).toStringAsFixed(2);
        final interval = "${start.toStringAsFixed(2)}%+$span";

        final args = <String>[
          '-v',
          'error',
          '-select_streams',
          'v:0',
          '-read_intervals',
          interval,
          '-show_entries',
          'packet=pts_time,flags',
          '-of',
          'csv=p=0',
          videoPath,
        ];

        final session = await FFprobeKit.executeWithArguments(args);
        if (!ReturnCode.isSuccess(await session.getReturnCode())) {
          return const <double>[];
        }

        final output = await session.getOutput();
        if (output == null || output.isEmpty) return const <double>[];

        final keyframes = <double>[];
        for (final rawLine in output.split('\n')) {
          final line = rawLine.trim();
          if (line.isEmpty) continue;
          final parts = line.split(',');
          if (parts.length < 2 || !parts[1].contains('K')) continue;
          final pts = double.tryParse(parts[0]);
          if (pts != null && pts >= 0) keyframes.add(pts);
        }

        keyframes.sort();
        final deduped = <double>[];
        for (final kf in keyframes) {
          if (deduped.isEmpty || (kf - deduped.last).abs() > 0.001) {
            deduped.add(kf);
          }
        }
        return deduped;
      } catch (e) {
        debugPrint("[VideoService] Local keyframe probe error: $e");
        return const <double>[];
      }
    });
  }

  /// Concatenates video files losslessly via FFmpeg concat demuxer (-c copy).
  static Future<String?> mergeVideosDirectly({
    required List<String> filePaths,
    required int totalFrames,
    required String outputPath,
    required Function(int) onProgressFrames,
    required Function(String) onLogReceived,
  }) async {
    if (filePaths.isEmpty) return null;

    final cacheDir = await _getWritableCacheDir();
    final listFile = File(
      '${cacheDir.path}/merge_list_${DateTime.now().millisecondsSinceEpoch}.txt',
    );

    final buffer = StringBuffer();
    for (final path in filePaths) {
      buffer.writeln("file '${_escapeConcatPath(path)}'");
    }
    await listFile.writeAsString(buffer.toString());

    final args = <String>[
      '-y',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      listFile.path,
      '-c',
      'copy',
      outputPath,
    ];

    final success = await _executeWithProgress(
      args: args,
      totalFrames: totalFrames,
      onProgressFrames: onProgressFrames,
      onLogReceived: onLogReceived,
    );

    try {
      if (await listFile.exists()) await listFile.delete();
    } catch (_) {}

    return success ? outputPath : null;
  }

  /// Trims a video segment using either coarse fast copy (-c copy) or
  /// fine frame-accurate re-encoding.
  static Future<String?> trimVideo({
    required String inputPath,
    required String outputPath,
    required double startSeconds,
    required double endSeconds,
    required bool frameAccurate,
    required int totalClipFrames,
    required Function(int) onProgressFrames,
    required Function(String) onLogReceived,
  }) async {
    if (endSeconds <= startSeconds) return null;

    final startStr = formatTimecode(startSeconds);
    final durationStr = formatTimecode(endSeconds - startSeconds);

    final args = frameAccurate
        ? <String>[
            '-y',
            '-ss',
            startStr,
            '-i',
            inputPath,
            '-t',
            durationStr,
            '-c:v',
            'libx264',
            '-preset',
            'veryfast',
            '-crf',
            '18',
            '-c:a',
            'aac',
            outputPath,
          ]
        : <String>[
            '-y',
            '-ss',
            startStr,
            '-i',
            inputPath,
            '-t',
            durationStr,
            '-c',
            'copy',
            outputPath,
          ];

    final success = await _executeWithProgress(
      args: args,
      totalFrames: totalClipFrames,
      onProgressFrames: onProgressFrames,
      onLogReceived: onLogReceived,
    );

    return success ? outputPath : null;
  }

  /// Shared FFmpeg execution helper that wires up statistics & log callbacks cleanly.
  static Future<bool> _executeWithProgress({
    required List<String> args,
    required int totalFrames,
    required Function(int) onProgressFrames,
    required Function(String) onLogReceived,
  }) async {
    FFmpegKitConfig.enableStatisticsCallback((statistics) {
      final frame = _readFrameNumber(statistics);
      if (frame > 0) onProgressFrames(frame);
    });

    FFmpegKitConfig.enableLogCallback((log) {
      onLogReceived(log.getMessage());
    });

    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();

    FFmpegKitConfig.enableStatisticsCallback(null);
    FFmpegKitConfig.enableLogCallback(null);

    if (ReturnCode.isSuccess(returnCode)) {
      onProgressFrames(totalFrames);
      return true;
    }
    return false;
  }

  static int _readFrameNumber(dynamic statistics) {
    try {
      return statistics.videoFrameNumber as int;
    } catch (_) {}
    try {
      return statistics.frameNumber as int;
    } catch (_) {}
    try {
      return statistics.getVideoFrameNumber() as int;
    } catch (_) {}
    return 0;
  }

  /// Cancels any active FFmpegKit execution session.
  static void cancelCurrentOperation() {
    try {
      FFmpegKit.cancel();
      debugPrint("[VideoService] FFmpegKit cancel signal sent.");
    } catch (e) {
      debugPrint("[VideoService] Failed to cancel FFmpeg process: $e");
    }
  }

  static String _normalizeProfileName(String codec, String rawProfile) {
    if (codec == 'H264' || codec == 'AVC') {
      return const {
            '66': 'Baseline',
            '77': 'Main',
            '88': 'Extended',
            '100': 'High',
            '110': 'High 10',
            '122': 'High 4:2:2',
            '244': 'High 4:4:4',
          }[rawProfile] ??
          rawProfile;
    } else if (codec == 'HEVC' || codec == 'H265') {
      return const {
            '1': 'Main',
            '2': 'Main 10',
            '3': 'Main Still Picture',
          }[rawProfile] ??
          rawProfile;
    }
    return rawProfile;
  }

  static String _escapeConcatPath(String input) {
    return input.replaceAll("'", "'\\''");
  }
}
