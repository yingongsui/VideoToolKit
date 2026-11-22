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
        final result = await task();
        completer.complete(result);
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

    final List<String> results = [];
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
    return _enqueue(() async {
      try {
        final cacheDir = await _getWritableCacheDir();

        // Sample at 10% of total frames so both short and long videos get a representative frame.
        final int sampledFrame = (totalFrames != null && totalFrames > 0)
            ? (totalFrames * 0.10).round()
            : 0;

        final jpgPath =
            "${cacheDir.path}/thumb_v2_${videoPath.hashCode}_10pct_f$sampledFrame.jpg";
        final jpgFile = File(jpgPath);
        if (await jpgFile.exists() && await jpgFile.length() > 0) {
          return jpgPath;
        }

        double seekSeconds = 0.0;
        if (sampledFrame > 0 && fpsValue != null && fpsValue > 0) {
          seekSeconds = sampledFrame / fpsValue;
        } else if (durationSeconds != null && durationSeconds > 0) {
          seekSeconds = durationSeconds * 0.10;
        }

        // Use executeWithArguments to safely handle spaces/Unicode, and convert to
        // full-range yuvj420p with -strict unofficial so MJPEG accepts 8-bit/10-bit inputs.
        final args = <String>[
          '-y',
          if (seekSeconds > 0) ...['-ss', seekSeconds.toStringAsFixed(3)],
          '-i',
          videoPath,
          '-frames:v',
          '1',
          '-vf',
          'scale=480:-2,format=yuvj420p',
          '-strict',
          'unofficial',
          '-q:v',
          '3',
          jpgPath,
        ];

        final session = await FFmpegKit.executeWithArguments(args);
        if (ReturnCode.isSuccess(await session.getReturnCode()) &&
            await jpgFile.exists() &&
            await jpgFile.length() > 0) {
          return jpgPath;
        }

        final jpgErr = await session.getOutput() ?? "Unknown FFmpeg error";
        debugPrint(
          "[VideoService] JPEG thumbnail failed for '$videoPath': $jpgErr",
        );

        // Fallback to PNG from the first frame (avoids MJPEG pixel-format restrictions).
        final pngPath =
            "${cacheDir.path}/thumb_v2_${videoPath.hashCode}_fallback.png";
        final pngFile = File(pngPath);
        if (await pngFile.exists() && await pngFile.length() > 0) {
          return pngPath;
        }

        final fallbackArgs = <String>[
          '-y',
          '-i',
          videoPath,
          '-frames:v',
          '1',
          '-vf',
          'scale=480:-2',
          pngPath,
        ];
        final fallbackSession =
            await FFmpegKit.executeWithArguments(fallbackArgs);
        if (ReturnCode.isSuccess(await fallbackSession.getReturnCode()) &&
            await pngFile.exists() &&
            await pngFile.length() > 0) {
          return pngPath;
        }

        final pngErr = await fallbackSession.getOutput() ?? "Unknown FFmpeg error";
        lastThumbnailError = pngErr.trim().split('\n').last;
        debugPrint(
          "[VideoService] PNG fallback thumbnail failed for '$videoPath': $pngErr",
        );
      } catch (e) {
        lastThumbnailError = e.toString();
        debugPrint("[VideoService] Thumbnail generation error: $e");
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
          final bytes = file.lengthSync();
          if (bytes > 1024 * 1024 * 1024) {
            sizeStr =
                "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
          } else {
            sizeStr = "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
          }
        }
      } catch (_) {}

      final session = await FFprobeKit.getMediaInformation(videoPath);
      final info = session.getMediaInformation();
      if (info != null) {
        String bitrate = "Unknown";
        if (info.getBitrate() != null) {
          final parsedBitrate = double.tryParse(info.getBitrate()!);
          if (parsedBitrate != null) {
            bitrate = "${(parsedBitrate / 1000).toStringAsFixed(0)} kbps";
          }
        }

        // Format duration as HH:MM:SS or MM:SS and keep exact numeric seconds.
        String durationStr = "Unknown";
        double durationSeconds = 0.0;
        final rawDuration = info.getDuration();
        if (rawDuration != null) {
          final durationSec = double.tryParse(rawDuration);
          if (durationSec != null && durationSec > 0) {
            durationSeconds = durationSec;
            int totalSecs = durationSec.round();
            int hours = totalSecs ~/ 3600;
            int minutes = (totalSecs % 3600) ~/ 60;
            int secs = totalSecs % 60;
            String minPart = minutes.toString().padLeft(2, '0');
            String secPart = secs.toString().padLeft(2, '0');
            durationStr = hours > 0
                ? "${hours.toString().padLeft(2, '0')}:$minPart:$secPart"
                : "$minPart:$secPart";
          }
        }

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

        final streams = info.getStreams();
        for (var stream in streams) {
          final props = stream.getAllProperties();

          if (stream.getType() == "video" && !hasVideo) {
            hasVideo = true;
            resolution = "${stream.getWidth()}x${stream.getHeight()}";

            if (stream.getCodec() != null) {
              vCodec = stream.getCodec()!.toUpperCase();
            }

            // Extract timebase (e.g. "1/90000").
            final tb = stream.getTimeBase() ?? props?['time_base']?.toString();
            if (tb != null && tb.isNotEmpty) {
              timebase = tb;
            }

            // Extract pixel format / bit depth (pix_fmt, e.g. "yuv420p10le").
            final pixFmt =
                stream.getFormat() ?? props?['pix_fmt']?.toString();
            if (pixFmt != null && pixFmt.isNotEmpty) {
              pixelFormat = pixFmt;
            }

            // Extract codec profile (normalize numeric H.264/HEVC IDs like 77 -> Main).
            final profile = props?['profile']?.toString();
            if (profile != null && profile.isNotEmpty) {
              videoProfile = _normalizeProfileName(vCodec, profile);
            }

            // Parse numeric FPS from r_frame_rate or avg_frame_rate.
            final rawFps =
                stream.getRealFrameRate() ?? stream.getAverageFrameRate();
            if (rawFps != null && rawFps.contains('/')) {
              final parts = rawFps.split('/');
              final num = double.tryParse(parts[0]);
              final den = double.tryParse(parts[1]);
              if (num != null && den != null && den != 0) {
                fpsValue = num / den;
                fpsStr = _formatFps(fpsValue);
              }
            }
          } else if (stream.getType() == "audio" && !hasAudio) {
            hasAudio = true;
            if (stream.getCodec() != null) {
              aCodec = stream.getCodec()!.toUpperCase();
            }

            // Extract audio sample rate (e.g. "48000 Hz").
            final sr =
                stream.getSampleRate() ?? props?['sample_rate']?.toString();
            if (sr != null && sr.isNotEmpty) {
              aSampleRate = "$sr Hz";
            }

            // Extract audio channel layout (e.g. "stereo", "5.1").
            final layout = stream.getChannelLayout() ??
                props?['channel_layout']?.toString();
            if (layout != null && layout.isNotEmpty) {
              aChannelLayout = layout;
            } else if (props?['channels'] != null) {
              aChannelLayout = "${props!['channels']}ch";
            }
          }
        }

        int totalFrames = 0;
        if (rawDuration != null && fpsValue != null && fpsValue > 0) {
          final duration = double.tryParse(rawDuration);
          if (duration != null) {
            totalFrames = (duration * fpsValue).round();
          }
        }

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
          durationSeconds: durationSeconds,
          size: sizeStr,
        );
      }
    } catch (e) {
      debugPrint("[VideoService] Metadata probe error: $e");
    }
    return VideoMetadata();
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
    for (var path in filePaths) {
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

    FFmpegKitConfig.enableStatisticsCallback((statistics) {
      try {
        int currentFrame = 0;
        try {
          currentFrame = (statistics as dynamic).videoFrameNumber;
        } catch (_) {
          try {
            currentFrame = (statistics as dynamic).frameNumber;
          } catch (_) {
            try {
              currentFrame = (statistics as dynamic).getVideoFrameNumber();
            } catch (_) {}
          }
        }

        if (currentFrame > 0) {
          onProgressFrames(currentFrame);
        }
      } catch (_) {}
    });

    FFmpegKitConfig.enableLogCallback((log) {
      onLogReceived(log.getMessage());
    });

    debugPrint("[VideoService] Starting FFmpeg concat merge.");
    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();

    FFmpegKitConfig.enableStatisticsCallback(null);
    FFmpegKitConfig.enableLogCallback(null);

    try {
      if (await listFile.exists()) await listFile.delete();
    } catch (_) {}

    if (ReturnCode.isSuccess(returnCode)) {
      onProgressFrames(totalFrames);
      return outputPath;
    } else {
      debugPrint("[VideoService] FFmpeg concat merge failed.");
      return null;
    }
  }

  /// Extracts a single preview frame at the given timestamp/frame for trim previewing.
  static Future<String?> extractFrameAtTime(
    String videoPath,
    double timestampSeconds, {
    int? frameNumber,
  }) async {
    return _enqueue(() async {
      try {
        final cacheDir = await _getWritableCacheDir();
        final key = frameNumber != null
            ? "f$frameNumber"
            : "ms${(timestampSeconds * 1000).round()}";
        final outPath =
            "${cacheDir.path}/trim_v2_${videoPath.hashCode}_$key.jpg";
        final outFile = File(outPath);
        if (await outFile.exists() && await outFile.length() > 0) {
          return outPath;
        }

        final ts = timestampSeconds.toStringAsFixed(3);
        final args = <String>[
          '-y',
          '-ss',
          ts,
          '-i',
          videoPath,
          '-frames:v',
          '1',
          '-vf',
          'scale=960:-2,format=yuvj420p',
          '-strict',
          'unofficial',
          '-q:v',
          '3',
          outPath,
        ];
        final session = await FFmpegKit.executeWithArguments(args);
        if (ReturnCode.isSuccess(await session.getReturnCode()) &&
            await outFile.exists() &&
            await outFile.length() > 0) {
          return outPath;
        }

        // PNG fallback if MJPEG rejects the stream's pixel format.
        final pngPath =
            "${cacheDir.path}/trim_v2_${videoPath.hashCode}_$key.png";
        final pngFile = File(pngPath);
        final fallbackArgs = <String>[
          '-y',
          '-ss',
          ts,
          '-i',
          videoPath,
          '-frames:v',
          '1',
          '-vf',
          'scale=960:-2',
          pngPath,
        ];
        final fallbackSession =
            await FFmpegKit.executeWithArguments(fallbackArgs);
        if (ReturnCode.isSuccess(await fallbackSession.getReturnCode()) &&
            await pngFile.exists() &&
            await pngFile.length() > 0) {
          return pngPath;
        }
      } catch (e) {
        debugPrint("[VideoService] Frame extraction error: $e");
      }
      return null;
    });
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

    // Coarse mode uses input seeking + stream copy; fine mode uses accurate seeking + re-encode.
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

    FFmpegKitConfig.enableStatisticsCallback((statistics) {
      try {
        int currentFrame = 0;
        try {
          currentFrame = (statistics as dynamic).videoFrameNumber;
        } catch (_) {
          try {
            currentFrame = (statistics as dynamic).frameNumber;
          } catch (_) {
            try {
              currentFrame = (statistics as dynamic).getVideoFrameNumber();
            } catch (_) {}
          }
        }
        if (currentFrame > 0) {
          onProgressFrames(currentFrame);
        }
      } catch (_) {}
    });

    FFmpegKitConfig.enableLogCallback((log) {
      onLogReceived(log.getMessage());
    });

    debugPrint("[VideoService] Starting FFmpeg trim (frameAccurate=$frameAccurate).");
    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();

    FFmpegKitConfig.enableStatisticsCallback(null);
    FFmpegKitConfig.enableLogCallback(null);

    if (ReturnCode.isSuccess(returnCode)) {
      onProgressFrames(totalClipFrames);
      return outputPath;
    } else {
      debugPrint("[VideoService] FFmpeg trim failed.");
      return null;
    }
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

  static String _formatFps(double fps) {
    final rounded = fps.roundToDouble();
    if ((fps - rounded).abs() < 0.05) {
      return "${rounded.toInt()} FPS";
    }
    return "${fps.toStringAsFixed(2)} FPS";
  }

  static String _normalizeProfileName(String codec, String rawProfile) {
    if (codec == 'H264' || codec == 'AVC') {
      switch (rawProfile) {
        case '66':
          return 'Baseline';
        case '77':
          return 'Main';
        case '88':
          return 'Extended';
        case '100':
          return 'High';
        case '110':
          return 'High 10';
        case '122':
          return 'High 4:2:2';
        case '244':
          return 'High 4:4:4';
      }
    } else if (codec == 'HEVC' || codec == 'H265') {
      switch (rawProfile) {
        case '1':
          return 'Main';
        case '2':
          return 'Main 10';
        case '3':
          return 'Main Still Picture';
      }
    }
    return rawProfile;
  }

  static String _escapeConcatPath(String input) {
    return input.replaceAll("'", "'\\''");
  }
}
