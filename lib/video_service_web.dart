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
  final palettes = [
    [const Color(0xFF1E3C72), const Color(0xFF2A5298)],
    [const Color(0xFF134E5E), const Color(0xFF71B280)],
    [const Color(0xFF3A1C71), const Color(0xFFD76D77)],
    [const Color(0xFF0F2027), const Color(0xFF2C5364)],
    [const Color(0xFF42275A), const Color(0xFF734B6D)],
  ];
  final colors = palettes[seed % palettes.length];

  String? frameBadge;
  final frameMatch = RegExp(r'#f(\d+)').firstMatch(path);
  if (frameMatch != null) {
    frameBadge = "Frame #${frameMatch.group(1)}";
  }

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
          const Icon(
            Icons.play_circle_outline,
            color: Colors.white70,
            size: 30,
          ),
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

  // Mock library folders and files (includes extra extensions like .rmvb/.m2ts
  // so custom extension filtering can be tested directly in Web preview).
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

  /// Seeds one mock folder automatically so Web UI preview is immediately populated.
  static List<String> get defaultPreviewFolders => const [
        '/Users/demo/Movies/Travel_4K',
      ];

  static Future<bool> directoryExists(String folderPath) async => true;

  /// Simulates adding a folder in Web preview mode by cycling through mock folders.
  static Future<String?> pickDirectory({String? dialogTitle}) async {
    final keys = _mockLibrary.keys.toList();
    final selected = keys[_mockFolderCursor % keys.length];
    _mockFolderCursor++;
    return selected;
  }

  /// Simulates picking extra video files in Web preview mode.
  static Future<List<String>> pickVideoFiles({
    String? dialogTitle,
    List<String>? allowedExtensions,
  }) async {
    return const [
      '/Users/demo/Movies/Drone_Clips/coastline_sunrise.mp4',
      '/Users/demo/Movies/Drone_Clips/mountain_ridge.mp4',
    ];
  }

  /// Returns mock video file paths filtered by the active extension list.
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

  /// Returns a virtual thumbnail identifier sampled at 10% of total frames.
  static Future<String?> generateThumbnail(
    String videoPath, {
    double? fpsValue,
    int? totalFrames,
    double? durationSeconds,
  }) async {
    await Future.delayed(const Duration(milliseconds: 100));
    final sampledFrame =
        (totalFrames != null && totalFrames > 0) ? (totalFrames * 0.10).round() : 0;
    return "mock_thumb:$videoPath#f$sampledFrame";
  }

  /// Returns deterministic mock extended metadata for UI preview cards.
  static Future<VideoMetadata> getVideoMetadata(String videoPath) async {
    await Future.delayed(const Duration(milliseconds: 150));
    final h = videoPath.hashCode.abs();
    final durationSecsList = [45.0, 92.0, 138.0, 185.0, 312.0];
    final durations = ["00:45", "01:32", "02:18", "03:05", "05:12"];
    final resolutions = ["3840x2160", "1920x1080"];
    final fpsValues = [59.94, 60.0, 30.0];
    final timebases = ["1/90000", "1/15360"];
    final pixFmts = ["yuv420p", "yuv420p10le"];
    final profiles = ["High", "Main", "Main 10"];
    final sampleRates = ["48000 Hz", "44100 Hz"];
    final layouts = ["stereo", "5.1"];
    final sizes = ["84.2 MB", "142.5 MB", "268.0 MB", "512.4 MB"];

    final durationSec = durationSecsList[h % durationSecsList.length];
    final fpsVal = fpsValues[h % fpsValues.length];
    final fpsStr = (fpsVal - fpsVal.roundToDouble()).abs() < 0.05
        ? "${fpsVal.round()} FPS"
        : "${fpsVal.toStringAsFixed(2)} FPS";

    return VideoMetadata(
      videoCodec: h % 3 == 0 ? "HEVC" : "H264",
      resolution: resolutions[h % resolutions.length],
      timebase: timebases[h % timebases.length],
      fps: fpsStr,
      fpsValue: fpsVal,
      pixelFormat: pixFmts[h % pixFmts.length],
      videoProfile: profiles[h % profiles.length],
      audioCodec: "AAC",
      audioSampleRate: sampleRates[h % sampleRates.length],
      audioChannelLayout: layouts[h % layouts.length],
      bitrate: "${12000 + (h % 8) * 1500} kbps",
      totalFrames: (durationSec * fpsVal).round(),
      duration: durations[h % durations.length],
      durationSeconds: durationSec,
      size: sizes[h % sizes.length],
    );
  }

  /// Simulates FFmpeg concat progress and console logs in Web preview mode.
  static Future<String?> mergeVideosDirectly({
    required List<String> filePaths,
    required int totalFrames,
    required String outputPath,
    required Function(int) onProgressFrames,
    required Function(String) onLogReceived,
  }) async {
    if (filePaths.isEmpty) return null;
    _cancelRequested = false;

    final effectiveFrames = totalFrames > 0 ? totalFrames : 3000;
    onLogReceived("[WEB PREVIEW] Simulating FFmpeg concat demuxer (-c copy)...");
    for (final p in filePaths) {
      onLogReceived("[WEB PREVIEW] Input stream: ${p.split('/').last}");
    }

    const steps = 20;
    for (int step = 1; step <= steps; step++) {
      await Future.delayed(const Duration(milliseconds: 150));
      if (_cancelRequested) {
        onLogReceived("[WEB PREVIEW] Simulation cancelled.");
        return null;
      }
      final currentFrame = ((effectiveFrames * step) / steps).round();
      onProgressFrames(currentFrame);
      if (step % 4 == 0) {
        onLogReceived(
          "frame=$currentFrame fps=480.0 q=-1.0 size=${step * 14}MB bitrate=N/A speed=16.0x",
        );
      }
    }

    onLogReceived("[WEB PREVIEW] Mock merge complete -> $outputPath");
    return outputPath;
  }

  /// Returns a virtual frame preview token for Web UI testing.
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

  /// Simulates video trimming progress and FFmpeg logs in Web preview mode.
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
    _cancelRequested = false;

    final modeLabel =
        frameAccurate ? "Fine (Frame-Accurate Re-encode)" : "Coarse (Fast -c copy)";
    final effectiveFrames = totalClipFrames > 0 ? totalClipFrames : 600;

    onLogReceived("[WEB PREVIEW] Trim mode: $modeLabel");
    onLogReceived(
      "[WEB PREVIEW] Range: ${formatTimecode(startSeconds)} -> ${formatTimecode(endSeconds)}",
    );

    const steps = 16;
    for (int step = 1; step <= steps; step++) {
      await Future.delayed(Duration(milliseconds: frameAccurate ? 140 : 80));
      if (_cancelRequested) {
        onLogReceived("[WEB PREVIEW] Trim simulation cancelled.");
        return null;
      }
      final currentFrame = ((effectiveFrames * step) / steps).round();
      onProgressFrames(currentFrame);
      if (step % 4 == 0) {
        onLogReceived(
          "frame=$currentFrame fps=${frameAccurate ? '120.0' : '640.0'} time=${formatTimecode((endSeconds - startSeconds) * step / steps)} speed=${frameAccurate ? '4.0x' : '21.0x'}",
        );
      }
    }

    onLogReceived("[WEB PREVIEW] Mock trim complete -> $outputPath");
    return outputPath;
  }

  /// Cancels the simulated merge or trim loop in Web preview mode.
  static void cancelCurrentOperation() {
    _cancelRequested = true;
  }
}
