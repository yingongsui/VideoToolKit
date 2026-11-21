// ============================================================================
// Shared Video Data Models & Pure Dart Helpers
// ============================================================================

/// Holds parsed video/audio stream and file diagnostics for a video asset.
class VideoMetadata {
  // Core video stream fields
  final String videoCodec;         // e.g. "H264", "HEVC"
  final String resolution;         // e.g. "1920x1080"
  final String timebase;           // e.g. "1/90000"
  final String fps;                // e.g. "59.94 FPS"
  final double? fpsValue;          // Numeric FPS used for 0.5 tolerance check
  final String pixelFormat;        // e.g. "yuv420p", "yuv420p10le"
  final String videoProfile;       // e.g. "High", "Main"

  // Core audio stream fields
  final String audioCodec;         // e.g. "AAC"
  final String audioSampleRate;    // e.g. "48000 Hz"
  final String audioChannelLayout; // e.g. "stereo", "5.1"

  // General container/file fields
  final String bitrate;            // e.g. "12500 kbps"
  final int totalFrames;
  final String duration;           // e.g. "02:15"
  final double durationSeconds;    // Exact duration in seconds for trim sliders
  final String size;               // e.g. "142.5 MB"

  /// Tolerance in frames per second when comparing two videos for direct copy.
  static const double fpsTolerance = 0.5;

  VideoMetadata({
    this.videoCodec = "Unknown",
    this.resolution = "Unknown",
    this.timebase = "Unknown",
    this.fps = "Unknown",
    this.fpsValue,
    this.pixelFormat = "Unknown",
    this.videoProfile = "Unknown",
    this.audioCodec = "No Audio",
    this.audioSampleRate = "N/A",
    this.audioChannelLayout = "N/A",
    this.bitrate = "Unknown",
    this.totalFrames = 0,
    this.duration = "Unknown",
    this.durationSeconds = 0.0,
    this.size = "Unknown",
  });

  /// Compares this video's stream parameters against a reference video for
  /// lossless (-c copy) concatenation compatibility. Returns mismatched field names.
  List<String> compareCompatibility(VideoMetadata reference) {
    final mismatches = <String>[];

    if (videoCodec != reference.videoCodec) {
      mismatches.add("Video Codec");
    }
    if (resolution != reference.resolution) {
      mismatches.add("Resolution");
    }
    if (timebase != reference.timebase) {
      mismatches.add("Timebase");
    }
    if (fpsValue != null && reference.fpsValue != null) {
      if ((fpsValue! - reference.fpsValue!).abs() > fpsTolerance) {
        mismatches.add("FPS (>0.5 diff)");
      }
    } else if (fps != reference.fps) {
      mismatches.add("FPS");
    }
    if (pixelFormat != reference.pixelFormat) {
      mismatches.add("Pixel Format");
    }
    if (videoProfile != reference.videoProfile) {
      mismatches.add("Profile");
    }
    if (audioCodec != reference.audioCodec) {
      mismatches.add("Audio Codec");
    }
    if (audioSampleRate != reference.audioSampleRate) {
      mismatches.add("Sample Rate");
    }
    if (audioChannelLayout != reference.audioChannelLayout) {
      mismatches.add("Channel Layout");
    }

    return mismatches;
  }
}

/// Represents a video file tracked by the media library, merge, or trim views.
class VideoItem {
  final String path;
  final String name;
  String? thumbPath;
  VideoMetadata? metadata;

  // Frame range offsets used during stream concatenation progress tracking.
  int startFrame = 0;
  int endFrame = 0;

  VideoItem(this.path) : name = path.split('/').last;

  /// Creates a shallow copy with reset merge frame offsets.
  VideoItem copyForMerge() {
    final copy = VideoItem(path);
    copy.thumbPath = thumbPath;
    copy.metadata = metadata;
    return copy;
  }
}

/// Pure string helper to extract the parent directory from a POSIX/Windows path.
String getParentDirectoryPath(String filePath) {
  final normalized = filePath.replaceAll('\\', '/');
  final lastSlash = normalized.lastIndexOf('/');
  if (lastSlash <= 0) return "/";
  return normalized.substring(0, lastSlash);
}

/// Formats seconds into HH:MM:SS.mmm timecode string.
String formatTimecode(double totalSeconds) {
  final clamped = totalSeconds < 0 ? 0.0 : totalSeconds;
  final totalMillis = (clamped * 1000).round();
  final hours = totalMillis ~/ 3600000;
  final minutes = (totalMillis % 3600000) ~/ 60000;
  final seconds = (totalMillis % 60000) ~/ 1000;
  final millis = totalMillis % 1000;

  final hh = hours.toString().padLeft(2, '0');
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  final ms = millis.toString().padLeft(3, '0');
  return "$hh:$mm:$ss.$ms";
}

/// Parses HH:MM:SS.mmm, MM:SS.mmm, or raw seconds into a double. Returns null if invalid.
double? parseTimecode(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  final parts = trimmed.split(':');
  if (parts.length == 1) {
    return double.tryParse(parts[0]);
  } else if (parts.length == 2) {
    final m = int.tryParse(parts[0]);
    final s = double.tryParse(parts[1]);
    if (m == null || s == null || m < 0 || s < 0) return null;
    return m * 60 + s;
  } else if (parts.length == 3) {
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final s = double.tryParse(parts[2]);
    if (h == null || m == null || s == null || h < 0 || m < 0 || s < 0) {
      return null;
    }
    return h * 3600 + m * 60 + s;
  }
  return null;
}
