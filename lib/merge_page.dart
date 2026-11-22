import 'dart:async';
import 'package:flutter/material.dart';
import 'app_settings.dart';
import 'console_log_panel.dart';
import 'settings_dialog.dart';
import 'video_service.dart';

// ============================================================================
// Video Concatenation / Merge Page
// ============================================================================

class MergePage extends StatefulWidget {
  final List<VideoItem> initialItems;
  final AppSettings settings;

  const MergePage({
    super.key,
    required this.initialItems,
    required this.settings,
  });

  @override
  State<MergePage> createState() => _MergePageState();
}

class _MergePageState extends State<MergePage> {
  late List<VideoItem> videoItems;
  bool isMerging = false;
  bool hasMerged = false;

  Timer? _timer;
  int _mergeSeconds = 0;
  int _currentGlobalFrame = 0;

  String _currentCommand = "";
  final List<String> _consoleLogs = [];
  final ScrollController _consoleScrollController = ScrollController();

  // Custom output directory; defaults to the first video's parent folder when null.
  String? _customTargetFolder;

  @override
  void initState() {
    super.initState();
    videoItems = List<VideoItem>.from(widget.initialItems);

    // Ensure thumbnails and metadata are loaded for any passed items.
    for (final item in videoItems) {
      _loadItemDetails(item);
    }
  }

  /// Loads missing metadata and 10%-frame thumbnail for a single VideoItem.
  void _loadItemDetails(VideoItem item) {
    if (item.metadata == null) {
      VideoService.getVideoMetadata(item.path).then((meta) {
        if (!mounted) return;
        setState(() => item.metadata = meta);
        if (item.thumbPath == null) {
          VideoService.generateThumbnail(
            item.path,
            fpsValue: meta.fpsValue,
            totalFrames: meta.totalFrames,
            durationSeconds: meta.durationSeconds,
          ).then((thumb) {
            if (mounted && thumb != null) {
              setState(() => item.thumbPath = thumb);
            }
          });
        }
      });
    } else if (item.thumbPath == null) {
      VideoService.generateThumbnail(
        item.path,
        fpsValue: item.metadata?.fpsValue,
        totalFrames: item.metadata?.totalFrames,
        durationSeconds: item.metadata?.durationSeconds,
      ).then((thumb) {
        if (mounted && thumb != null) {
          setState(() => item.thumbPath = thumb);
        }
      });
    }
  }

  void _openSettings() {
    showDialog(
      context: context,
      builder: (context) => SettingsDialog(settings: widget.settings),
    );
  }

  /// Opens the file picker to append additional video files.
  Future<void> _addFiles() async {
    final selectedPaths = await VideoService.pickVideoFiles(
      dialogTitle: "Add Video Files",
      allowedExtensions: widget.settings.allVideoExtensions,
    );

    if (selectedPaths.isEmpty) return;

    if (hasMerged) {
      setState(() {
        hasMerged = false;
        _currentGlobalFrame = 0;
        _consoleLogs.clear();
        _currentCommand = "";
      });
    }

    for (final path in selectedPaths) {
      if (videoItems.any((item) => item.path == path)) continue;

      final newItem = VideoItem(path);
      setState(() => videoItems.add(newItem));
      _loadItemDetails(newItem);
    }
  }

  /// Opens the directory picker for the merged output destination.
  Future<void> _selectTargetFolder() async {
    final selectedFolder = await VideoService.pickDirectory(
      dialogTitle: "Select Output Directory",
    );

    if (selectedFolder != null) {
      setState(() {
        _customTargetFolder = selectedFolder;
      });
    }
  }

  /// Force-stops the active FFmpeg concatenation process.
  void _stopMerge() {
    if (!isMerging) return;

    VideoService.cancelCurrentOperation();
    _stopTimer();

    setState(() {
      isMerging = false;
      _consoleLogs.add(
        "[USER ACTION] Concat pipeline manually terminated by user.",
      );
    });
    _scrollToBottom();
    _showSnackBar("Process force-stopped.");
  }

  void _startTimer() {
    _mergeSeconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _mergeSeconds++);
    });
  }

  void _stopTimer() {
    _timer?.cancel();
  }

  void _scrollToBottom() {
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

  /// Builds a compact badge chip for video stream metadata.
  Widget _buildMetaBadge(String? text, Color color) {
    if (text == null || text.isEmpty || text == "null") {
      return const SizedBox.shrink();
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isDark ? color.withValues(alpha: 0.9) : color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  /// Computes a map of item index -> mismatched stream fields relative to item 0.
  Map<int, List<String>> _computeStreamMismatches() {
    final result = <int, List<String>>{};
    if (videoItems.length < 2) return result;
    final refMeta = videoItems.first.metadata;
    if (refMeta == null) return result;

    for (int i = 1; i < videoItems.length; i++) {
      final meta = videoItems[i].metadata;
      if (meta == null) continue;
      final diffs = meta.compareCompatibility(refMeta);
      if (diffs.isNotEmpty) {
        result[i] = diffs;
      }
    }
    return result;
  }

  @override
  void dispose() {
    _stopTimer();
    _consoleScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // Resolve displayed target output directory text.
    String displayFolderText = "Default (Same as 1st Video)";
    if (_customTargetFolder != null) {
      displayFolderText = _customTargetFolder!;
    } else if (videoItems.isNotEmpty) {
      displayFolderText = getParentDirectoryPath(videoItems[0].path);
    }

    final allMetadataLoaded =
        videoItems.length >= 2 && videoItems.every((e) => e.metadata != null);
    final mismatchesByIndex = _computeStreamMismatches();
    final hasMismatch = mismatchesByIndex.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Direct-Stream Merger"),
        actions: [
          IconButton(
            tooltip: "Settings",
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // Target output directory selector card
          Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            color: colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListTile(
              leading: Icon(
                Icons.create_new_folder_outlined,
                color: colorScheme.primary,
              ),
              title: const Text(
                "Target Save Directory",
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                displayFolderText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: _customTargetFolder != null
                      ? colorScheme.primary
                      : Colors.grey,
                ),
              ),
              trailing: isMerging
                  ? null
                  : IconButton(
                      icon: Icon(Icons.edit_note, color: colorScheme.primary),
                      onPressed: _selectTargetFolder,
                    ),
            ),
          ),

          // Stream compatibility summary banner (with 0.5 FPS tolerance)
          if (allMetadataLoaded)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: (hasMismatch ? Colors.amber : Colors.green)
                    .withValues(alpha: isDarkMode ? 0.15 : 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (hasMismatch ? Colors.amber : Colors.green)
                      .withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    hasMismatch
                        ? Icons.warning_amber_rounded
                        : Icons.check_circle_outline,
                    size: 18,
                    color: hasMismatch ? Colors.amber[700] : Colors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      hasMismatch
                          ? "Stream mismatch detected on ${mismatchesByIndex.length} file(s) vs #1 (FPS tolerance: ±0.5). Lossless -c copy may fail or desync."
                          : "All ${videoItems.length} video streams are compatible for lossless -c copy (FPS tolerance: ±0.5).",
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          Expanded(
            child: videoItems.isEmpty
                ? const Center(
                    child: Text(
                      "No videos added yet.\nClick 'Add Videos' to select local files.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 15),
                    ),
                  )
                : ReorderableListView.builder(
                    itemCount: videoItems.length,
                    onReorderItem: (oldIndex, newIndex) {
                      if (isMerging) return;
                      setState(() {
                        hasMerged = false;
                        final item = videoItems.removeAt(oldIndex);
                        videoItems.insert(newIndex, item);
                      });
                    },
                    itemBuilder: (context, i) {
                      final item = videoItems[i];
                      final itemMismatches = mismatchesByIndex[i] ?? const [];

                      double localProgress = 0.0;
                      if (hasMerged) {
                        localProgress = 1.0;
                      } else if (isMerging) {
                        if (_currentGlobalFrame < item.startFrame) {
                          localProgress = 0.0;
                        } else if (_currentGlobalFrame > item.endFrame) {
                          localProgress = 1.0;
                        } else {
                          int totalItemFrames = item.endFrame - item.startFrame;
                          if (totalItemFrames > 0) {
                            localProgress =
                                (_currentGlobalFrame - item.startFrame) /
                                    totalItemFrames;
                          }
                        }
                      }

                      final bool isActiveSlot = isMerging &&
                          localProgress > 0.0 &&
                          localProgress < 1.0;

                      return Card(
                        key: ValueKey(item.path),
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        clipBehavior: Clip.antiAlias,
                        elevation: isActiveSlot ? 6 : 2,
                        shape: isActiveSlot
                            ? RoundedRectangleBorder(
                                side: BorderSide(
                                  color: colorScheme.primary,
                                  width: 2.0,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              )
                            : itemMismatches.isNotEmpty
                                ? RoundedRectangleBorder(
                                    side: BorderSide(
                                      color: Colors.amber.withValues(alpha: 0.6),
                                      width: 1.2,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  )
                                : RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                        child: Container(
                          decoration: BoxDecoration(
                            gradient:
                                (isMerging || hasMerged) && localProgress > 0.0
                                    ? LinearGradient(
                                        colors: [
                                          colorScheme.primary.withValues(
                                            alpha: isDarkMode ? 0.25 : 0.20,
                                          ),
                                          colorScheme.secondary.withValues(
                                            alpha: isDarkMode ? 0.15 : 0.10,
                                          ),
                                          Colors.transparent,
                                        ],
                                        stops: [
                                          localProgress - 0.03 < 0
                                              ? 0
                                              : localProgress - 0.03,
                                          localProgress,
                                          localProgress,
                                        ],
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                      )
                                    : null,
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            leading: item.thumbPath != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: buildLocalImage(
                                      item.thumbPath!,
                                      width: 52,
                                      height: 52,
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : Container(
                                    width: 52,
                                    height: 52,
                                    decoration: BoxDecoration(
                                      color: isDarkMode
                                          ? Colors.grey[800]
                                          : Colors.grey[200],
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Icon(
                                      Icons.video_file,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                            title: Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                "#${i + 1}  ${item.name}",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            subtitle: item.metadata == null
                                ? Row(
                                    children: [
                                      SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.5,
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      const Text(
                                        "Parsing media stream details...",
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ],
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // Primary badges
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          _buildMetaBadge(
                                            item.metadata!.videoCodec,
                                            colorScheme.primary,
                                          ),
                                          _buildMetaBadge(
                                            item.metadata!.resolution,
                                            Colors.teal,
                                          ),
                                          _buildMetaBadge(
                                            item.metadata!.fps,
                                            Colors.cyan,
                                          ),
                                          _buildMetaBadge(
                                            item.metadata!.duration,
                                            Colors.indigo,
                                          ),
                                          _buildMetaBadge(
                                            item.metadata!.size,
                                            Colors.blueGrey,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 5),
                                      // Extended video stream diagnostics
                                      Text(
                                        "Video: Profile ${item.metadata!.videoProfile}  |  pix_fmt: ${item.metadata!.pixelFormat}  |  Timebase: ${item.metadata!.timebase}  |  Bitrate: ${item.metadata!.bitrate}",
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontFamily: 'monospace',
                                          color: isDarkMode
                                              ? Colors.grey[400]
                                              : Colors.blueGrey[700],
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      // Extended audio stream diagnostics
                                      Text(
                                        "Audio: ${item.metadata!.audioCodec}  |  Sample Rate: ${item.metadata!.audioSampleRate}  |  Layout: ${item.metadata!.audioChannelLayout}  |  Frames: ${item.metadata!.totalFrames}",
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontFamily: 'monospace',
                                          color: isDarkMode
                                              ? Colors.grey[400]
                                              : Colors.blueGrey[700],
                                        ),
                                      ),
                                      if (itemMismatches.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          "Mismatch vs #1: ${itemMismatches.join(', ')}",
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.amber[700],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                            trailing: (isMerging || hasMerged)
                                ? Text(
                                    "${(localProgress * 100).toStringAsFixed(0)}%",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                      color: isActiveSlot
                                          ? Colors.orange
                                          : colorScheme.primary,
                                    ),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.drag_handle,
                                        color: Colors.grey,
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          color: Colors.redAccent,
                                        ),
                                        onPressed: () => setState(
                                          () => videoItems.removeAt(i),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
          ),

          // Runtime console log panel
          if (videoItems.isNotEmpty)
            ConsoleLogPanel(
              title: "CONSOLE RUNTIME LOGS",
              commandPreview: _currentCommand,
              idleMessage: "System Idle. Ready for terminal tracking...",
              logs: _consoleLogs,
              scrollController: _consoleScrollController,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),

          if (isMerging)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Processing Stream Index Frame: $_currentGlobalFrame",
                    style: TextStyle(
                      color: colorScheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    "Mode: Pass-Through Copy (-c copy)",
                    style: TextStyle(color: colorScheme.primary, fontSize: 12),
                  ),
                ],
              ),
            ),

          // Bottom action bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                // Switches between "Add Videos" and "Stop Merging" while active.
                Expanded(
                  child: isMerging
                      ? FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red[800],
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: _stopMerge,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text("Stop Merging"),
                        )
                      : OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: _addFiles,
                          icon: const Icon(Icons.video_library_outlined),
                          label: const Text("Add Videos"),
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: isMerging ? null : _startMerge,
                    icon: isMerging
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.merge_type),
                    label: Text(
                      isMerging ? "Merging ($_mergeSeconds s)" : "Merge",
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Future<void> _startMerge() async {
    if (videoItems.isEmpty) {
      _showSnackBar("Add at least one video file first.");
      return;
    }

    setState(() {
      _consoleLogs.clear();
      hasMerged = false;
    });

    // Resolve output directory path.
    final String finalOutputDirPath =
        _customTargetFolder ?? getParentDirectoryPath(videoItems[0].path);

    final String firstFileName = stripFileExtension(videoItems[0].name);

    final String computedOutPath =
        "$finalOutputDirPath/${firstFileName}_merged.mp4";

    int currentOffsetFrames = 0;
    for (var item in videoItems) {
      item.startFrame = currentOffsetFrames;
      int itemFrames = item.metadata?.totalFrames ?? 0;
      item.endFrame = currentOffsetFrames + itemFrames;
      currentOffsetFrames = item.endFrame;
    }

    int totalFrames = currentOffsetFrames;
    const String listFileName = "merge_list_timestamp.txt";

    setState(() {
      isMerging = true;
      _currentGlobalFrame = 0;
      _currentCommand =
          "ffmpeg -f concat -safe 0 -i \$CACHE/$listFileName -c copy \"$computedOutPath\"";
    });
    _startTimer();

    List<String> paths = videoItems.map((item) => item.path).toList();

    String? outputPath = await VideoService.mergeVideosDirectly(
      filePaths: paths,
      totalFrames: totalFrames,
      outputPath: computedOutPath,
      onProgressFrames: (currentFrame) {
        if (mounted) {
          setState(() {
            _currentGlobalFrame = currentFrame;
          });
        }
      },
      onLogReceived: (logLine) {
        if (mounted) {
          setState(() {
            _consoleLogs.add(logLine);
          });
          _scrollToBottom();
        }
      },
    );

    _stopTimer();
    setState(() {
      isMerging = false;
      if (outputPath != null) {
        hasMerged = true;
      }
    });

    if (outputPath != null) {
      _showSnackBar(
        "Merged successfully in $_mergeSeconds seconds.\nSaved to: $outputPath",
      );
    } else {
      if (_consoleLogs.isNotEmpty &&
          _consoleLogs.last.contains("[USER ACTION]")) {
        return;
      }
      _showSnackBar(
        "Concatenation failed. Check console logs for stream alignment issues.",
      );
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }
}
