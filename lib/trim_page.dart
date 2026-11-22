import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'console_log_panel.dart';
import 'video_service.dart';

// ============================================================================
// Video Trim Page (Coarse Time Selection + Fine Frame Selection)
// ============================================================================

enum TrimSelectionMode {
  coarseTime,
  fineFrame,
}

class TrimPage extends StatefulWidget {
  final VideoItem videoItem;

  const TrimPage({
    super.key,
    required this.videoItem,
  });

  @override
  State<TrimPage> createState() => _TrimPageState();
}

class _TrimPageState extends State<TrimPage> {
  TrimSelectionMode _mode = TrimSelectionMode.coarseTime;

  // Export mode: false = fast keyframe copy (-c copy), true = frame-accurate re-encode.
  bool _frameAccurateExport = false;

  // Keyframe snapping state (on-demand local -read_intervals scan; no full-file scan).
  bool _snapToKeyframe = true;
  bool _isProbingKeyframes = false;

  // Which boundary is currently focused in Fine Frame zoom slider (true = IN, false = OUT).
  bool _fineEditingStart = true;

  VideoMetadata? _metadata;
  double _durationSeconds = 60.0;
  double _fps = 30.0;
  int _totalFrames = 1800;

  // Trim range in seconds (always synchronized with frame indices).
  double _startSeconds = 0.0;
  double _endSeconds = 60.0;

  // Frame preview image paths (or Web preview tokens).
  String? _startFrameThumb;
  String? _endFrameThumb;
  Timer? _startPreviewDebounce;
  Timer? _endPreviewDebounce;

  // Text controllers for manual timecode / frame input.
  late final TextEditingController _startTimeController;
  late final TextEditingController _endTimeController;
  late final TextEditingController _startFrameController;
  late final TextEditingController _endFrameController;
  late final TextEditingController _outputNameController;

  // Output directory & execution state.
  String? _customTargetFolder;
  bool _isTrimming = false;
  bool _hasTrimmed = false;
  int _trimSeconds = 0;
  int _currentTrimFrame = 0;
  Timer? _trimTimer;
  final List<String> _consoleLogs = [];
  final ScrollController _consoleScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _startTimeController = TextEditingController();
    _endTimeController = TextEditingController();
    _startFrameController = TextEditingController();
    _endFrameController = TextEditingController();

    final baseName = stripFileExtension(widget.videoItem.name);
    _outputNameController = TextEditingController(text: "${baseName}_trim.mp4");

    _startFrameThumb = widget.videoItem.thumbPath;
    _endFrameThumb = widget.videoItem.thumbPath;

    if (widget.videoItem.metadata != null) {
      _applyMetadata(widget.videoItem.metadata!);
    } else {
      _syncControllers();
      VideoService.getVideoMetadata(widget.videoItem.path).then((meta) {
        if (mounted) {
          widget.videoItem.metadata = meta;
          _applyMetadata(meta);
        }
      });
    }
  }

  void _applyMetadata(VideoMetadata meta) {
    final parsedDuration = meta.durationSeconds > 0
        ? meta.durationSeconds
        : (meta.totalFrames > 0 && (meta.fpsValue ?? 0) > 0
            ? meta.totalFrames / meta.fpsValue!
            : 60.0);
    final parsedFps = (meta.fpsValue != null && meta.fpsValue! > 0)
        ? meta.fpsValue!
        : 30.0;
    final parsedFrames = meta.totalFrames > 0
        ? meta.totalFrames
        : (parsedDuration * parsedFps).round();

    setState(() {
      _metadata = meta;
      _durationSeconds = parsedDuration;
      _fps = parsedFps;
      _totalFrames = math.max(1, parsedFrames);
      _startSeconds = 0.0;
      _endSeconds = parsedDuration;
      _syncControllers();
    });

    _scheduleFramePreview(isStart: true);
    _scheduleFramePreview(isStart: false);
  }

  /// Queries keyframes only in a local window around [targetSeconds] via -read_intervals.
  Future<List<double>> _probeKeyframesNear(
    double targetSeconds, {
    double windowSeconds = 15.0,
  }) async {
    setState(() => _isProbingKeyframes = true);
    try {
      return await VideoService.getKeyframesNear(
        widget.videoItem.path,
        centerSeconds: targetSeconds,
        windowSeconds: windowSeconds,
        durationSeconds: _durationSeconds,
      );
    } finally {
      if (mounted) setState(() => _isProbingKeyframes = false);
    }
  }

  /// Snaps the IN or OUT boundary to the nearest keyframe in a local +/-15s window.
  Future<void> _snapBoundaryToNearestKeyframe({
    required bool isStart,
    required double targetSeconds,
  }) async {
    final kfs = await _probeKeyframesNear(targetSeconds);
    if (!mounted || kfs.isEmpty) return;

    double best = kfs.first;
    double bestDiff = (targetSeconds - best).abs();
    for (final kf in kfs) {
      final diff = (targetSeconds - kf).abs();
      if (diff < bestDiff) {
        best = kf;
        bestDiff = diff;
      }
    }

    if (isStart) {
      _setStartSeconds(best);
    } else {
      _setEndSeconds(best);
    }
  }

  /// Steps to the previous or next keyframe relative to the current IN/OUT timestamp
  /// using an on-demand local -read_intervals scan.
  Future<void> _stepKeyframe({required bool isStart, required bool next}) async {
    final current = isStart ? _startSeconds : _endSeconds;
    // Scan a +/-20s window around the current point; widen to +/-45s for very long GOPs.
    var kfs = await _probeKeyframesNear(current, windowSeconds: 20.0);
    double? target = _findAdjacentKeyframe(kfs, current, next: next);

    if (target == null && mounted) {
      kfs = await _probeKeyframesNear(current, windowSeconds: 45.0);
      target = _findAdjacentKeyframe(kfs, current, next: next);
    }

    if (!mounted) return;
    target ??= next ? _durationSeconds : 0.0;

    if (isStart) {
      _setStartSeconds(target);
    } else {
      _setEndSeconds(target);
    }
  }

  double? _findAdjacentKeyframe(
    List<double> keyframes,
    double current, {
    required bool next,
  }) {
    if (next) {
      for (final kf in keyframes) {
        if (kf > current + 0.02) return kf;
      }
    } else {
      for (int i = keyframes.length - 1; i >= 0; i--) {
        if (keyframes[i] < current - 0.02) return keyframes[i];
      }
    }
    return null;
  }

  int get _startFrame => (_startSeconds * _fps).round().clamp(0, _totalFrames);
  int get _endFrame => (_endSeconds * _fps).round().clamp(0, _totalFrames);
  double get _clipDuration => math.max(0.0, _endSeconds - _startSeconds);
  int get _clipFrames => math.max(0, _endFrame - _startFrame);

  double get _minGapSeconds => 1.0 / _fps;

  void _syncControllers() {
    _startTimeController.text = formatTimecode(_startSeconds);
    _endTimeController.text = formatTimecode(_endSeconds);
    _startFrameController.text = "$_startFrame";
    _endFrameController.text = "$_endFrame";
  }

  /// Updates start time while keeping it strictly before end time.
  void _setStartSeconds(double value, {bool refreshPreview = true}) {
    final maxStart = math.max(0.0, _endSeconds - _minGapSeconds);
    final clamped = value.clamp(0.0, maxStart);
    setState(() {
      _startSeconds = clamped;
      _hasTrimmed = false;
      _syncControllers();
    });
    if (refreshPreview) {
      _scheduleFramePreview(isStart: true);
    }
  }

  /// Updates end time while keeping it strictly after start time.
  void _setEndSeconds(double value, {bool refreshPreview = true}) {
    final minEnd = math.min(_durationSeconds, _startSeconds + _minGapSeconds);
    final clamped = value.clamp(minEnd, _durationSeconds);
    setState(() {
      _endSeconds = clamped;
      _hasTrimmed = false;
      _syncControllers();
    });
    if (refreshPreview) {
      _scheduleFramePreview(isStart: false);
    }
  }

  /// Steps the start or end point by a signed frame delta.
  void _stepFrames({required bool isStart, required int deltaFrames}) {
    final targetFrame = (isStart ? _startFrame : _endFrame) + deltaFrames;
    final clampedFrame = targetFrame.clamp(0, _totalFrames);
    final seconds = clampedFrame / _fps;
    if (isStart) {
      _setStartSeconds(seconds);
    } else {
      _setEndSeconds(seconds);
    }
  }

  /// Debounces FFmpeg frame extraction while dragging sliders or stepping frames.
  void _scheduleFramePreview({required bool isStart}) {
    if (isStart) {
      _startPreviewDebounce?.cancel();
      _startPreviewDebounce = Timer(const Duration(milliseconds: 180), () async {
        final ts = _startSeconds;
        final frame = _startFrame;
        final path = await VideoService.extractFrameAtTime(
          widget.videoItem.path,
          ts,
          frameNumber: frame,
        );
        if (mounted && path != null) {
          setState(() => _startFrameThumb = path);
        }
      });
    } else {
      _endPreviewDebounce?.cancel();
      _endPreviewDebounce = Timer(const Duration(milliseconds: 180), () async {
        // Sample slightly before the exact end to avoid empty EOF frames.
        final ts = math.max(0.0, _endSeconds - (0.5 / _fps));
        final frame = _endFrame;
        final path = await VideoService.extractFrameAtTime(
          widget.videoItem.path,
          ts,
          frameNumber: frame,
        );
        if (mounted && path != null) {
          setState(() => _endFrameThumb = path);
        }
      });
    }
  }

  void _applyTimeInput({required bool isStart, required String text}) {
    final parsed = parseTimecode(text);
    if (parsed == null) {
      _syncControllers();
      _showSnackBar("Invalid timecode. Use HH:MM:SS.mmm or seconds.");
      return;
    }
    if (isStart) {
      _setStartSeconds(parsed);
    } else {
      _setEndSeconds(parsed);
    }
  }

  void _applyFrameInput({required bool isStart, required String text}) {
    final parsed = int.tryParse(text.trim());
    if (parsed == null || parsed < 0) {
      _syncControllers();
      _showSnackBar("Invalid frame number.");
      return;
    }
    final clampedFrame = parsed.clamp(0, _totalFrames);
    if (isStart) {
      _setStartSeconds(clampedFrame / _fps);
    } else {
      _setEndSeconds(clampedFrame / _fps);
    }
  }

  Future<void> _selectTargetFolder() async {
    final folder = await VideoService.pickDirectory(
      dialogTitle: "Select Trim Output Directory",
    );
    if (folder != null) {
      setState(() => _customTargetFolder = folder);
    }
  }

  String _resolvedOutputPath() {
    final dir =
        _customTargetFolder ?? getParentDirectoryPath(widget.videoItem.path);
    var fileName = _outputNameController.text.trim();
    if (fileName.isEmpty) {
      fileName = "${stripFileExtension(widget.videoItem.name)}_trim.mp4";
    }
    if (!fileName.contains('.')) {
      fileName = "$fileName.mp4";
    }
    return "$dir/$fileName";
  }

  String _buildPreviewCommand() {
    final startStr = formatTimecode(_startSeconds);
    final durStr = formatTimecode(_clipDuration);
    final outPath = _resolvedOutputPath();
    if (_frameAccurateExport) {
      return "ffmpeg -ss $startStr -i \"${widget.videoItem.name}\" -t $durStr -c:v libx264 -crf 18 -c:a aac \"$outPath\"";
    }
    return "ffmpeg -ss $startStr -i \"${widget.videoItem.name}\" -t $durStr -c copy \"$outPath\"";
  }

  Future<void> _startTrim() async {
    if (_clipDuration <= 0) {
      _showSnackBar("End point must be after start point.");
      return;
    }

    final outputPath = _resolvedOutputPath();
    setState(() {
      _isTrimming = true;
      _hasTrimmed = false;
      _currentTrimFrame = 0;
      _trimSeconds = 0;
      _consoleLogs.clear();
    });

    _trimTimer?.cancel();
    _trimTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _trimSeconds++);
    });

    final result = await VideoService.trimVideo(
      inputPath: widget.videoItem.path,
      outputPath: outputPath,
      startSeconds: _startSeconds,
      endSeconds: _endSeconds,
      frameAccurate: _frameAccurateExport,
      totalClipFrames: _clipFrames,
      onProgressFrames: (frame) {
        if (mounted) {
          setState(() => _currentTrimFrame = frame);
        }
      },
      onLogReceived: (line) {
        if (mounted) {
          setState(() => _consoleLogs.add(line));
          _scrollLogsToBottom();
        }
      },
    );

    _trimTimer?.cancel();
    if (!mounted) return;

    setState(() {
      _isTrimming = false;
      if (result != null) {
        _hasTrimmed = true;
      }
    });

    if (result != null) {
      _showSnackBar("Trimmed in $_trimSeconds s.\nSaved to: $result");
    } else if (!_consoleLogs.any((l) => l.contains("[USER ACTION]"))) {
      _showSnackBar("Trim failed. Check console logs for details.");
    }
  }

  void _stopTrim() {
    if (!_isTrimming) return;
    VideoService.cancelCurrentOperation();
    _trimTimer?.cancel();
    setState(() {
      _isTrimming = false;
      _consoleLogs.add("[USER ACTION] Trim operation stopped by user.");
    });
    _scrollLogsToBottom();
    _showSnackBar("Trim stopped.");
  }

  void _scrollLogsToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_consoleScrollController.hasClients) {
        _consoleScrollController.animateTo(
          _consoleScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  @override
  void dispose() {
    _startPreviewDebounce?.cancel();
    _endPreviewDebounce?.cancel();
    _trimTimer?.cancel();
    _startTimeController.dispose();
    _endTimeController.dispose();
    _startFrameController.dispose();
    _endFrameController.dispose();
    _outputNameController.dispose();
    _consoleScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final progress = _clipFrames > 0
        ? (_currentTrimFrame / _clipFrames).clamp(0.0, 1.0)
        : (_hasTrimmed ? 1.0 : 0.0);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          "Trim Video - ${widget.videoItem.name}",
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          // Mode switcher: Coarse (Time) vs Fine (Frame)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: SegmentedButton<TrimSelectionMode>(
              segments: const [
                ButtonSegment(
                  value: TrimSelectionMode.coarseTime,
                  label: Text("Coarse (Time)"),
                  icon: Icon(Icons.schedule, size: 16),
                ),
                ButtonSegment(
                  value: TrimSelectionMode.fineFrame,
                  label: Text("Fine (Frame)"),
                  icon: Icon(Icons.filter_frames, size: 16),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: _isTrimming
                  ? null
                  : (selection) {
                      if (selection.isEmpty) return;
                      final next = selection.first;
                      setState(() {
                        _mode = next;
                        // Default to frame-accurate export in Fine mode, fast copy + keyframe snap in Coarse mode.
                        _frameAccurateExport =
                            next == TrimSelectionMode.fineFrame;
                        _snapToKeyframe =
                            next == TrimSelectionMode.coarseTime;
                      });
                    },
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Side-by-side Start (IN) and End (OUT) frame previews
                _buildPreviewRow(colorScheme, isDark),
                const SizedBox(height: 14),

                // Selection workspace (switches between Coarse Time and Fine Frame)
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _mode == TrimSelectionMode.coarseTime
                        ? _buildCoarseTimePanel(colorScheme)
                        : _buildFineFramePanel(colorScheme),
                  ),
                ),
                const SizedBox(height: 14),

                // Output configuration & export mode card
                _buildOutputCard(colorScheme),
                const SizedBox(height: 14),

                // Compact stream diagnostics summary
                if (_metadata != null) _buildMetadataSummary(isDark),
                const SizedBox(height: 14),

                // Console logs & progress bar
                ConsoleLogPanel(
                  title: "TRIM CONSOLE LOGS",
                  commandPreview: _buildPreviewCommand(),
                  idleMessage:
                      "Ready to trim. Adjust time or frame boundaries above.",
                  logs: _consoleLogs,
                  scrollController: _consoleScrollController,
                  progress: (_isTrimming || _hasTrimmed) ? progress : null,
                  statusText: (_isTrimming || _hasTrimmed)
                      ? "${(progress * 100).toStringAsFixed(0)}% (Frame $_currentTrimFrame / $_clipFrames)"
                      : null,
                ),
                const SizedBox(height: 16),

                // Bottom action buttons
                Row(
                  children: [
                    if (_isTrimming)
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red[800],
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _stopTrim,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text("Stop Trim"),
                        ),
                      )
                    else
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: () {
                            _setStartSeconds(0.0);
                            _setEndSeconds(_durationSeconds);
                          },
                          icon: const Icon(Icons.restart_alt),
                          label: const Text("Reset Range"),
                        ),
                      ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _isTrimming ? null : _startTrim,
                        icon: _isTrimming
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.content_cut),
                        label: Text(
                          _isTrimming
                              ? "Trimming ($_trimSeconds s)..."
                              : "Export Trimmed Clip (${formatTimecode(_clipDuration)})",
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewRow(ColorScheme colorScheme, bool isDark) {
    return Row(
      children: [
        Expanded(
          child: _buildFramePreviewCard(
            title: "START (IN)",
            timecode: formatTimecode(_startSeconds),
            frameNumber: _startFrame,
            thumbPath: _startFrameThumb,
            isHighlighted:
                _mode == TrimSelectionMode.fineFrame && _fineEditingStart,
            colorScheme: colorScheme,
            isDark: isDark,
            onTap: () => setState(() => _fineEditingStart = true),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildFramePreviewCard(
            title: "END (OUT)",
            timecode: formatTimecode(_endSeconds),
            frameNumber: _endFrame,
            thumbPath: _endFrameThumb,
            isHighlighted:
                _mode == TrimSelectionMode.fineFrame && !_fineEditingStart,
            colorScheme: colorScheme,
            isDark: isDark,
            onTap: () => setState(() => _fineEditingStart = false),
          ),
        ),
      ],
    );
  }

  Widget _buildFramePreviewCard({
    required String title,
    required String timecode,
    required int frameNumber,
    required String? thumbPath,
    required bool isHighlighted,
    required ColorScheme colorScheme,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isHighlighted
                ? colorScheme.primary
                : Colors.grey.withValues(alpha: 0.25),
            width: isHighlighted ? 2.2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (thumbPath != null)
                    buildLocalImage(thumbPath, fit: BoxFit.cover)
                  else
                    Container(
                      color: isDark ? Colors.grey[900] : Colors.grey[200],
                      child: Center(
                        child: Icon(
                          Icons.movie_creation_outlined,
                          size: 42,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        "$timecode  |  Frame #$frameNumber",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Panel 1: Coarse Selection by Time (RangeSlider + Keyframe Snapping + Timecode inputs).
  Widget _buildCoarseTimePanel(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.schedule, size: 18, color: colorScheme.primary),
            const SizedBox(width: 8),
            const Text(
              "Coarse Selection (Time-Based)",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 12),
            FilterChip(
              avatar: _isProbingKeyframes
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  : const Icon(Icons.key, size: 15),
              label: Text(
                _isProbingKeyframes
                    ? "Snapping..."
                    : "Snap to Nearest Keyframe",
                style: const TextStyle(fontSize: 11.5),
              ),
              selected: _snapToKeyframe,
              onSelected: _isTrimming
                  ? null
                  : (selected) async {
                      setState(() => _snapToKeyframe = selected);
                      if (selected) {
                        await _snapBoundaryToNearestKeyframe(
                          isStart: true,
                          targetSeconds: _startSeconds,
                        );
                        if (_endSeconds < _durationSeconds - 0.1) {
                          await _snapBoundaryToNearestKeyframe(
                            isStart: false,
                            targetSeconds: _endSeconds,
                          );
                        }
                      }
                    },
            ),
            const Spacer(),
            Text(
              "Clip: ${formatTimecode(_clipDuration)} / ${formatTimecode(_durationSeconds)}",
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        RangeSlider(
          values: RangeValues(_startSeconds, _endSeconds),
          min: 0.0,
          max: _durationSeconds > 0 ? _durationSeconds : 1.0,
          labels: RangeLabels(
            formatTimecode(_startSeconds),
            formatTimecode(_endSeconds),
          ),
          onChanged: _isTrimming
              ? null
              : (values) {
                  final startChanged =
                      (values.start - _startSeconds).abs() > 0.001;
                  final endChanged = (values.end - _endSeconds).abs() > 0.001;
                  final newEnd = math.max(
                    values.end,
                    math.min(_durationSeconds, values.start + _minGapSeconds),
                  );

                  setState(() {
                    _startSeconds = values.start;
                    _endSeconds = newEnd;
                    _hasTrimmed = false;
                    _syncControllers();
                  });
                  if (startChanged) _scheduleFramePreview(isStart: true);
                  if (endChanged) _scheduleFramePreview(isStart: false);
                },
          onChangeEnd: _isTrimming || !_snapToKeyframe
              ? null
              : (values) async {
                  // Snap on release via on-demand local -read_intervals probe.
                  await _snapBoundaryToNearestKeyframe(
                    isStart: true,
                    targetSeconds: values.start,
                  );
                  if (values.end < _durationSeconds - 0.05) {
                    await _snapBoundaryToNearestKeyframe(
                      isStart: false,
                      targetSeconds: values.end,
                    );
                  }
                },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            // Start time input + quick second/keyframe jumps
            Expanded(
              child: _buildTimeControlGroup(
                label: "Start Time (IN)",
                controller: _startTimeController,
                onSubmit: (v) => _applyTimeInput(isStart: true, text: v),
                onAdjustSeconds: (delta) =>
                    _setStartSeconds(_startSeconds + delta),
                onPrevKeyframe: () => _stepKeyframe(isStart: true, next: false),
                onNextKeyframe: () => _stepKeyframe(isStart: true, next: true),
              ),
            ),
            const SizedBox(width: 20),
            // End time input + quick second/keyframe jumps
            Expanded(
              child: _buildTimeControlGroup(
                label: "End Time (OUT)",
                controller: _endTimeController,
                onSubmit: (v) => _applyTimeInput(isStart: false, text: v),
                onAdjustSeconds: (delta) => _setEndSeconds(_endSeconds + delta),
                onPrevKeyframe: () =>
                    _stepKeyframe(isStart: false, next: false),
                onNextKeyframe: () => _stepKeyframe(isStart: false, next: true),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTimeControlGroup({
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onSubmit,
    required ValueChanged<double> onAdjustSeconds,
    required VoidCallback onPrevKeyframe,
    required VoidCallback onNextKeyframe,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            _buildMiniStepBtn("< KF", onPrevKeyframe),
            _buildMiniStepBtn("KF >", onNextKeyframe),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !_isTrimming,
                onSubmitted: onSubmit,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _buildMiniStepBtn("-10s", () => onAdjustSeconds(-10)),
            _buildMiniStepBtn("-1s", () => onAdjustSeconds(-1)),
            _buildMiniStepBtn("+1s", () => onAdjustSeconds(1)),
            _buildMiniStepBtn("+10s", () => onAdjustSeconds(10)),
          ],
        ),
      ],
    );
  }

  /// Panel 2: Fine Selection by Frame (Frame steppers + zoomed frame scrubber).
  Widget _buildFineFramePanel(ColorScheme colorScheme) {
    final activeFrame = _fineEditingStart ? _startFrame : _endFrame;
    // Zoom window: +/- 5 seconds around the active frame.
    final windowRadius = (_fps * 5).round();
    final windowMin = math.max(0, activeFrame - windowRadius);
    final windowMax = math.min(_totalFrames, activeFrame + windowRadius);
    final safeMax = windowMax > windowMin ? windowMax : windowMin + 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.filter_frames, size: 18, color: colorScheme.primary),
            const SizedBox(width: 8),
            const Text(
              "Fine Selection (Frame-Accurate)",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            Text(
              "FPS: ${_fps.toStringAsFixed(2)}  |  Selected: $_clipFrames / $_totalFrames frames",
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Target selector + zoomed local frame scrubber
        Row(
          children: [
            ChoiceChip(
              label: Text("Zoom IN (Frame #$_startFrame)"),
              selected: _fineEditingStart,
              onSelected: (_) => setState(() => _fineEditingStart = true),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text("Zoom OUT (Frame #$_endFrame)"),
              selected: !_fineEditingStart,
              onSelected: (_) => setState(() => _fineEditingStart = false),
            ),
            const Spacer(),
            Text(
              "Window: #$windowMin .. #$windowMax (±5s)",
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Colors.grey,
              ),
            ),
          ],
        ),
        Slider(
          value: activeFrame.clamp(windowMin, safeMax).toDouble(),
          min: windowMin.toDouble(),
          max: safeMax.toDouble(),
          divisions: math.max(1, safeMax - windowMin),
          label: "Frame #$activeFrame",
          onChanged: _isTrimming
              ? null
              : (val) {
                  final frame = val.round();
                  if (_fineEditingStart) {
                    _setStartSeconds(frame / _fps);
                  } else {
                    _setEndSeconds(frame / _fps);
                  }
                },
        ),
        const SizedBox(height: 6),

        Row(
          children: [
            Expanded(
              child: _buildFrameControlGroup(
                label: "Start Frame (IN)",
                controller: _startFrameController,
                onSubmit: (v) => _applyFrameInput(isStart: true, text: v),
                onStep: (delta) =>
                    _stepFrames(isStart: true, deltaFrames: delta),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: _buildFrameControlGroup(
                label: "End Frame (OUT)",
                controller: _endFrameController,
                onSubmit: (v) => _applyFrameInput(isStart: false, text: v),
                onStep: (delta) =>
                    _stepFrames(isStart: false, deltaFrames: delta),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFrameControlGroup({
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onSubmit,
    required ValueChanged<int> onStep,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !_isTrimming,
                onSubmitted: onSubmit,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  prefixText: "#",
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _buildMiniStepBtn("-10f", () => onStep(-10)),
            _buildMiniStepBtn("-1f", () => onStep(-1)),
            _buildMiniStepBtn("+1f", () => onStep(1)),
            _buildMiniStepBtn("+10f", () => onStep(10)),
          ],
        ),
      ],
    );
  }

  Widget _buildMiniStepBtn(String label, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          minimumSize: const Size(0, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: _isTrimming ? null : onPressed,
        child: Text(
          label,
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
        ),
      ),
    );
  }

  Widget _buildOutputCard(ColorScheme colorScheme) {
    final targetDir =
        _customTargetFolder ?? getParentDirectoryPath(widget.videoItem.path);

    return Card(
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.folder_outlined,
                      color: colorScheme.primary,
                    ),
                    title: const Text(
                      "Target Save Directory",
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      targetDir,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: _isTrimming
                        ? null
                        : IconButton(
                            icon: Icon(
                              Icons.edit_note,
                              color: colorScheme.primary,
                            ),
                            onPressed: _selectTargetFolder,
                          ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: TextField(
                    controller: _outputNameController,
                    enabled: !_isTrimming,
                    style: const TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      labelText: "Output File Name",
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            Row(
              children: [
                Switch(
                  value: _frameAccurateExport,
                  onChanged: _isTrimming
                      ? null
                      : (v) => setState(() => _frameAccurateExport = v),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _frameAccurateExport
                        ? "Frame-Accurate Re-encode (Exact frame cut using libx264 CRF 18)"
                        : "Fast Stream Copy (-c copy, instantaneous keyframe-aligned cut)",
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataSummary(bool isDark) {
    final meta = _metadata!;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Video: ${meta.videoCodec} (${meta.videoProfile})  |  ${meta.resolution}  |  ${meta.fps}  |  Timebase: ${meta.timebase}  |  pix_fmt: ${meta.pixelFormat}",
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: isDark ? Colors.grey[400] : Colors.blueGrey[700],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              "Audio: ${meta.audioCodec}  |  Sample Rate: ${meta.audioSampleRate}  |  Layout: ${meta.audioChannelLayout}  |  Bitrate: ${meta.bitrate}  |  Size: ${meta.size}",
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: isDark ? Colors.grey[400] : Colors.blueGrey[700],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
