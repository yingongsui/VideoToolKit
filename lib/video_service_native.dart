import 'dart:async';
import 'dart:convert';
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
// Native Desktop Implementation
// - macOS: uses bundled ffmpeg_kit_flutter_new (zero system dependencies)
// - Linux: uses system ffmpeg / ffprobe CLI (installed via .deb Depends: ffmpeg)
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

  static Process? _activeCliProcess;

  // Serializes background probe/thumbnail tasks to keep resource usage predictable.
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

  /// Returns an existing, writable cache directory (creates it if missing).
  static Future<Directory> _getWritableCacheDir() async {
    Directory baseDir;
    try {
      baseDir = await getTemporaryDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }
    final cacheDir = Directory('${baseDir.path}/videotoolkit_cache');
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
      fileName: "thumb_${videoPath.hashCode}_f$sampledFrame.jpg",
      scaleWidth: 480,
      seekSeconds: seekSeconds,
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
      fileName: "trim_${videoPath.hashCode}_$key.jpg",
      scaleWidth: 960,
      seekSeconds: timestampSeconds,
    );
  }

  /// Extracts a single scaled JPEG frame via system ffmpeg (Linux) or FFmpegKit (macOS).
  static Future<String?> _extractFrameImage({
    required String videoPath,
    required String fileName,
    required int scaleWidth,
    required double seekSeconds,
  }) async {
    return _enqueue(() async {
      try {
        final cacheDir = await _getWritableCacheDir();
        final outPath = "${cacheDir.path}/$fileName";
        final outFile = File(outPath);
        if (await outFile.exists() && await outFile.length() > 0) {
          return outPath;
        }

        final args = <String>[
          '-y',
          if (seekSeconds > 0) ...['-ss', seekSeconds.toStringAsFixed(3)],
          '-i',
          videoPath,
          '-an',
          '-sn',
          '-dn',
          '-frames:v',
          '1',
          '-vf',
          'scale=$scaleWidth:-2',
          '-pix_fmt',
          'yuv420p',
          '-strict',
          'unofficial',
          '-q:v',
          '3',
          '-f',
          'mjpeg',
          outPath,
        ];

        final errorText = await _runFfmpegOneShot(args);
        if (await outFile.exists() && await outFile.length() > 0) {
          return outPath;
        }

        if (errorText != null && errorText.isNotEmpty) {
          lastThumbnailError = errorText
                  .trim()
                  .split('\n')
                  .where((l) => l.trim().isNotEmpty)
                  .lastOrNull ??
              "Thumbnail extraction failed";
          debugPrint(
            "[VideoService] Frame extraction failed for '$videoPath': $errorText",
          );
        }
      } catch (e) {
        lastThumbnailError = e.toString();
        debugPrint("[VideoService] Frame extraction error: $e");
      }
      return null;
    });
  }

  /// Probes detailed video and audio metadata.
  static Future<VideoMetadata> getVideoMetadata(String videoPath) async {
    return _enqueue(() async {
      String sizeStr = "Unknown";
      try {
        final file = File(videoPath);
        if (file.existsSync()) {
          sizeStr = formatByteSize(file.lengthSync());
        }
      } catch (_) {}

      try {
        if (Platform.isLinux) {
          return await _probeMetadataViaCli(videoPath, sizeStr);
        }
        return await _probeMetadataViaKit(videoPath, sizeStr);
      } catch (e) {
        debugPrint("[VideoService] Metadata probe error: $e");
        return VideoMetadata(size: sizeStr);
      }
    });
  }

  static Future<VideoMetadata> _probeMetadataViaCli(
    String videoPath,
    String sizeStr,
  ) async {
    final res = await Process.run('ffprobe', [
      '-v',
      'quiet',
      '-print_format',
      'json',
      '-show_format',
      '-show_streams',
      videoPath,
    ]);
    if (res.exitCode != 0) return VideoMetadata(size: sizeStr);

    final decoded = jsonDecode(res.stdout.toString());
    if (decoded is! Map<String, dynamic>) return VideoMetadata(size: sizeStr);

    final format = decoded['format'] as Map<String, dynamic>? ?? const {};
    final streams = (decoded['streams'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

    return _buildMetadataFromMaps(
      formatProps: format,
      streamPropsList: streams,
      sizeStr: sizeStr,
    );
  }

  static Future<VideoMetadata> _probeMetadataViaKit(
    String videoPath,
    String sizeStr,
  ) async {
    final session = await FFprobeKit.getMediaInformation(videoPath);
    final info = session.getMediaInformation();
    if (info == null) return VideoMetadata(size: sizeStr);

    final formatProps = <String, dynamic>{
      'duration': info.getDuration(),
      'bit_rate': info.getBitrate(),
    };
    final streamPropsList = <Map<String, dynamic>>[];
    for (final stream in info.getStreams()) {
      final props = Map<String, dynamic>.from(
        stream.getAllProperties() ?? const {},
      );
      props['codec_type'] ??= stream.getType();
      props['codec_name'] ??= stream.getCodec();
      props['width'] ??= stream.getWidth();
      props['height'] ??= stream.getHeight();
      props['time_base'] ??= stream.getTimeBase();
      props['pix_fmt'] ??= stream.getFormat();
      props['r_frame_rate'] ??= stream.getRealFrameRate();
      props['avg_frame_rate'] ??= stream.getAverageFrameRate();
      props['sample_rate'] ??= stream.getSampleRate();
      props['channel_layout'] ??= stream.getChannelLayout();
      streamPropsList.add(props);
    }

    return _buildMetadataFromMaps(
      formatProps: formatProps,
      streamPropsList: streamPropsList,
      sizeStr: sizeStr,
    );
  }

  /// Unified FFprobe JSON/property parser shared by both Linux CLI and macOS FFprobeKit.
  static VideoMetadata _buildMetadataFromMaps({
    required Map<String, dynamic> formatProps,
    required List<Map<String, dynamic>> streamPropsList,
    required String sizeStr,
  }) {
    String bitrate = "Unknown";
    final parsedBitrate =
        double.tryParse(formatProps['bit_rate']?.toString() ?? '');
    if (parsedBitrate != null && parsedBitrate > 0) {
      bitrate = "${(parsedBitrate / 1000).toStringAsFixed(0)} kbps";
    }

    final durationSec =
        double.tryParse(formatProps['duration']?.toString() ?? '') ?? 0.0;
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

    for (final s in streamPropsList) {
      final type = s['codec_type']?.toString();
      if (type == 'video' && !hasVideo) {
        hasVideo = true;
        final w = s['width'];
        final h = s['height'];
        if (w != null && h != null) resolution = "${w}x$h";

        final codec = s['codec_name']?.toString();
        if (codec != null && codec.isNotEmpty) vCodec = codec.toUpperCase();

        final tb = s['time_base']?.toString();
        if (tb != null && tb.isNotEmpty) timebase = tb;

        final pixFmt = s['pix_fmt']?.toString();
        if (pixFmt != null && pixFmt.isNotEmpty) pixelFormat = pixFmt;

        final profile = s['profile']?.toString();
        if (profile != null && profile.isNotEmpty) {
          videoProfile = _normalizeProfileName(vCodec, profile);
        }

        final rawFps = (s['r_frame_rate'] ?? s['avg_frame_rate'])?.toString();
        final parsedFps = _parseFrameRate(rawFps);
        if (parsedFps != null) {
          fpsValue = parsedFps;
          fpsStr = formatFps(parsedFps);
        }
      } else if (type == 'audio' && !hasAudio) {
        hasAudio = true;
        final codec = s['codec_name']?.toString();
        if (codec != null && codec.isNotEmpty) aCodec = codec.toUpperCase();

        final sr = s['sample_rate']?.toString();
        if (sr != null && sr.isNotEmpty) aSampleRate = "$sr Hz";

        final layout = s['channel_layout']?.toString();
        if (layout != null && layout.isNotEmpty) {
          aChannelLayout = layout;
        } else if (s['channels'] != null) {
          aChannelLayout = "${s['channels']}ch";
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
  }

  /// Extracts keyframe (I-frame) timestamps within a local window around [centerSeconds]
  /// using FFprobe -read_intervals to avoid full-file packet scans.
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

        final output = await _runFfprobeOutput(args);
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

  /// Runs a one-shot FFmpeg command and returns error output if it failed.
  static Future<String?> _runFfmpegOneShot(List<String> args) async {
    if (Platform.isLinux) {
      final res = await Process.run('ffmpeg', args);
      return res.exitCode == 0 ? null : res.stderr.toString();
    }
    final session = await FFmpegKit.executeWithArguments(args);
    if (ReturnCode.isSuccess(await session.getReturnCode())) return null;
    return await session.getOutput();
  }

  /// Runs FFprobe and returns stdout on success.
  static Future<String?> _runFfprobeOutput(List<String> args) async {
    if (Platform.isLinux) {
      final res = await Process.run('ffprobe', args);
      return res.exitCode == 0 ? res.stdout.toString() : null;
    }
    final session = await FFprobeKit.executeWithArguments(args);
    if (!ReturnCode.isSuccess(await session.getReturnCode())) return null;
    return await session.getOutput();
  }

  /// Executes FFmpeg with live progress & log streaming (Linux CLI or macOS FFmpegKit).
  static Future<bool> _executeWithProgress({
    required List<String> args,
    required int totalFrames,
    required Function(int) onProgressFrames,
    required Function(String) onLogReceived,
  }) async {
    if (Platform.isLinux) {
      final process = await Process.start('ffmpeg', args);
      _activeCliProcess = process;
      final frameRegex = RegExp(r'frame=\s*(\d+)');

      final sub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        onLogReceived(line);
        final match = frameRegex.firstMatch(line);
        if (match != null) {
          final frame = int.tryParse(match.group(1) ?? '');
          if (frame != null && frame > 0) onProgressFrames(frame);
        }
      });

      final exitCode = await process.exitCode;
      await sub.cancel();
      _activeCliProcess = null;

      if (exitCode == 0) {
        onProgressFrames(totalFrames);
        return true;
      }
      return false;
    }

    FFmpegKitConfig.enableStatisticsCallback((statistics) {
      final frame = statistics.getVideoFrameNumber();
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

  /// Cancels any active FFmpeg process.
  static void cancelCurrentOperation() {
    if (Platform.isLinux) {
      _activeCliProcess?.kill();
      _activeCliProcess = null;
      return;
    }
    try {
      FFmpegKit.cancel();
    } catch (e) {
      debugPrint("[VideoService] Failed to cancel FFmpeg process: $e");
    }
  }

  static double? _parseFrameRate(String? rawFps) {
    if (rawFps == null || !rawFps.contains('/')) return null;
    final parts = rawFps.split('/');
    final num = double.tryParse(parts[0]);
    final den = double.tryParse(parts[1]);
    if (num == null || den == null || den == 0) return null;
    return num / den;
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
