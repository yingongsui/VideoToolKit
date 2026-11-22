import 'dart:async';
import 'package:flutter/material.dart';
import 'app_settings.dart';
import 'video_models.dart';

// ============================================================================
// Web UI Preview Implementation (Mock Data for Local Browser Layout Testing)
// ============================================================================

/// Renders a stylized mock preview thumbnail on Web (since dart:io is unavailable).
Widget buildLocalImage(
  String path, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
}) {
  final seed = path.hashCode.abs();
  const palettes = [
    [Color(0xFF1E3C72), Color(0xFF2A5298)],
    [Color(0xFF134E5E), Color(0xFF71B280)],
    [Color(0xFF3A1C71), Color(0xFFD76D77)],
    [Color(0xFF0F2027), Color(0xFF2C5364)],
    [Color(0xFF42275A), Color(0xFF734B6D)],
  ];
  final colors = palettes[seed % palettes.length];

  final frameMatch = RegExp(r'#f(\d+)').firstMatch(path);
  final frameBadge = frameMatch != null ? "Frame #${frameMatch.group(1)}" : null;

  return Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: colors,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.play_circle_outline, color: Colors.white70, size: 30),
          if (frameBadge != null && (width == null || width >= 90)) ...[
            const SizedBox(height: 4),
            Text(
              frameBadge,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class VideoService {
  /// Indicates whether the service is running in Web mock preview mode.
  static const bool isWebPreview = true;

  /// Diagnostic error field (always null in Web mock preview mode).
  static String? lastThumbnailError;

  static const Map<String, List<String>> _mockLibrary = {
    '/Users/demo/Movies/Travel_4K': [
      '/Users/demo/Movies/Travel_4K/tokyo_night_01.mp4',
      '/Users/demo/Movies/Travel_4K/shibuya_crossing_02.mp4',
      '/Users/demo/Movies/Travel_4K/kyoto_temple_03.mov',
      '/Users/demo/Movies/Travel_4K/mount_fuji_timelapse.mkv',
      '/Users/demo/Movies/Travel_4K/legacy_archive_04.rmvb',
    ],
    '/Users/demo/Movies/Screen_Recordings': [
      '/Users/demo/Movies/Screen_Recordings/app_demo_part1.mp4',
      '/Users/demo/Movies/Screen_Recordings/app_demo_part2.mp4',
      '/Users/demo/Movies/Screen_Recordings/bug_repro_clip.mov',
      '/Users/demo/Movies/Screen_Recordings/camcorder_raw.m2ts',
    ],
    '/Users/demo/Movies/Drone_Clips': [
      '/Users/demo/Movies/Drone_Clips/coastline_sunrise.mp4',
      '/Users/demo/Movies/Drone_Clips/mountain_ridge.mp4',
    ],
  };

  static int _mockFolderCursor = 0;
  static bool _cancelRequested = false;

  static List<String> get defaultPreviewFolders => const [
        '/Users/demo/Movies/Travel_4K',
      ];

  static Future<bool> directoryExists(String folderPath) async => true;

  static Future<String?> pickDirectory({String? dialogTitle}) async {
    final keys = _mockLibrary.keys.toList();
    final selected = keys[_mockFolderCursor % keys.length];
    _mockFolderCursor++;
    return selected;
  }

  static Future<List<String>> pickVideoFiles({
    String? dialogTitle,
    List<String>? allowedExtensions,
  }) async {
    return const [
      '/Users/demo/Movies/Drone_Clips/coastline_sunrise.mp4',
      '/Users/demo/Movies/Drone_Clips/mountain_ridge.mp4',
    ];
  }

  static Future<List<String>> scanVideosInFolder(
    String folderPath, {
    List<String>? allowedExtensions,
  }) async {
    await Future.delayed(const Duration(milliseconds: 120));
    final exts = (allowedExtensions ?? AppSettings.builtInExtensions)
        .map((e) => e.toLowerCase())
        .toSet();
    final files = _mockLibrary[folderPath] ?? const [];
    return files.where((path) {
      final dot = path.lastIndexOf('.');
      if (dot == -1) return false;
      return exts.contains(path.substring(dot + 1).toLowerCase());
    }).toList();
  }

  static Future<String?> generateThumbnail(
    String videoPath, {
    double? fpsValue,
    int? totalFrames,
    double? durationSeconds,
  }) async {
    await Future.delayed(const Duration(milliseconds: 100));
    final sampledFrame = (totalFrames != null && totalFrames > 0)
        ? (totalFrames * 0.10).round()
        : 0;
    return "mock_thumb:$videoPath#f$sampledFrame";
  }

  static Future<VideoMetadata> getVideoMetadata(String videoPath) async {
    await Future.delayed(const Duration(milliseconds: 150));
    final h = videoPath.hashCode.abs();
    const durationSecsList = [45.0, 92.0, 138.0, 185.0, 312.0];
    const resolutions = ["3840x2160", "1920x1080"];
    const fpsValues = [59.94, 60.0, 30.0];
    const timebases = ["1/90000", "1/15360"];
    const pixFmts = ["yuv420p", "yuv420p10le"];
    const profiles = ["High", "Main", "Main 10"];
    const sampleRates = ["48000 Hz", "44100 Hz"];
    const layouts = ["stereo", "5.1"];
    const sizes = ["84.2 MB", "142.5 MB", "268.0 MB", "512.4 MB"];

    final durationSec = durationSecsList[h % durationSecsList.length];
    final fpsVal = fpsValues[h % fpsValues.length];

    return VideoMetadata(
      videoCodec: h % 3 == 0 ? "HEVC" : "H264",
      resolution: resolutions[h % resolutions.length],
      timebase: timebases[h % timebases.length],
      fps: formatFps(fpsVal),
      fpsValue: fpsVal,
      pixelFormat: pixFmts[h % pixFmts.length],
      videoProfile: profiles[h % profiles.length],
      audioCodec: "AAC",
      audioSampleRate: sampleRates[h % sampleRates.length],
      audioChannelLayout: layouts[h % layouts.length],
      bitrate: "${12000 + (h % 8) * 1500} kbps",
      totalFrames: (durationSec * fpsVal).round(),
      duration: formatDuration(durationSec),
      durationSeconds: durationSec,
      size: sizes[h % sizes.length],
    );
  }

  static Future<List<double>> getKeyframes(
    String videoPath, {
    double durationSeconds = 120.0,
  }) async {
    await Future.delayed(const Duration(milliseconds: 120));
    final dur = durationSeconds > 0 ? durationSeconds : 120.0;
    return [for (double t = 0.0; t < dur; t += 4.0) t];
  }

  static Future<String?> extractFrameAtTime(
    String videoPath,
    double timestampSeconds, {
    int? frameNumber,
  }) async {
    await Future.delayed(const Duration(milliseconds: 60));
    final suffix = frameNumber != null
        ? "#f$frameNumber"
        : "@${timestampSeconds.toStringAsFixed(3)}";
    return "mock_frame:$videoPath$suffix";
  }

  static Future<String?> mergeVideosDirectly({
    required List<String> filePaths,
    required int totalFrames,
    required String outputPath,
    required Function(int) onProgressFrames,
    required Function(String) onLogReceived,
  }) async {
    if (filePaths.isEmpty) return null;
    onLogReceived("[WEB PREVIEW] Simulating FFmpeg concat demuxer (-c copy)...");
    for (final p in filePaths) {
      onLogReceived("[WEB PREVIEW] Input stream: ${p.split('/').last}");
    }
    final completed = await _simulateProgress(
      totalFrames: totalFrames > 0 ? totalFrames : 3000,
      steps: 20,
      stepDelayMs: 140,
      speedLabel: "16.0x",
      onProgressFrames: onProgressFrames,
      onLogReceived: onLogReceived,
    );
    if (!completed) return null;
    onLogReceived("[WEB PREVIEW] Mock merge complete -> $outputPath");
    return outputPath;
  }

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
    onLogReceived(
      "[WEB PREVIEW] Trim mode: ${frameAccurate ? 'Fine (Re-encode)' : 'Coarse (-c copy)'}",
    );
    onLogReceived(
      "[WEB PREVIEW] Range: ${formatTimecode(startSeconds)} -> ${formatTimecode(endSeconds)}",
    );
    final completed = await _simulateProgress(
      totalFrames: totalClipFrames > 0 ? totalClipFrames : 600,
      steps: 16,
      stepDelayMs: frameAccurate ? 140 : 80,
      speedLabel: frameAccurate ? "4.0x" : "21.0x",
      onProgressFrames: onProgressFrames,
      onLogReceived: onLogReceived,
    );
    if (!completed) return null;
    onLogReceived("[WEB PREVIEW] Mock trim complete -> $outputPath");
    return outputPath;
  }

  static Future<bool> _simulateProgress({
    required int totalFrames,
    required int steps,
    required int stepDelayMs,
    required String speedLabel,
    required Function(int) onProgressFrames,
    required Function(String) onLogReceived,
  }) async {
    _cancelRequested = false;
    for (int step = 1; step <= steps; step++) {
      await Future.delayed(Duration(milliseconds: stepDelayMs));
      if (_cancelRequested) {
        onLogReceived("[WEB PREVIEW] Operation cancelled.");
        return false;
      }
      final currentFrame = ((totalFrames * step) / steps).round();
      onProgressFrames(currentFrame);
      if (step % 4 == 0) {
        onLogReceived("frame=$currentFrame speed=$speedLabel");
      }
    }
    return true;
  }

  static void cancelCurrentOperation() {
    _cancelRequested = true;
  }
}
