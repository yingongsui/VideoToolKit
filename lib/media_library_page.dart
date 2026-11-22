import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_settings.dart';
import 'merge_page.dart';
import 'settings_dialog.dart';
import 'trim_page.dart';
import 'video_service.dart';

// ============================================================================
// Desktop Media Library Page (Main Screen)
// ============================================================================

class MediaLibraryPage extends StatefulWidget {
  final AppSettings settings;

  const MediaLibraryPage({
    super.key,
    required this.settings,
  });

  @override
  State<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends State<MediaLibraryPage> {
  static const String _prefsFoldersKey = 'media_library_folders';

  // Persisted folder paths added by the user.
  final List<String> _folders = [];

  // Currently selected folder in the sidebar; null means "All Folders".
  String? _activeFolder;

  // Map from folder path to discovered video file paths.
  final Map<String, List<String>> _folderVideos = {};

  // Shared cache of VideoItem instances (thumbnails & metadata) keyed by path.
  final Map<String, VideoItem> _itemCache = {};

  // Tracks which paths have already started loading thumbnail/metadata.
  final Set<String> _loadingPaths = {};

  // Ordered list of selected video paths (order is preserved for merging).
  final List<String> _selectedPaths = [];

  String _searchQuery = "";
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _loadSavedFolders();
  }

  /// Restores previously added folders from SharedPreferences and scans them.
  Future<void> _loadSavedFolders() async {
    setState(() => _isScanning = true);
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsFoldersKey) ?? [];

    final existingFolders = <String>[];
    for (final path in saved) {
      if (await VideoService.directoryExists(path)) {
        existingFolders.add(path);
      }
    }

    // In Web UI preview mode, seed a default mock folder if none are saved yet.
    if (existingFolders.isEmpty &&
        VideoService.defaultPreviewFolders.isNotEmpty) {
      existingFolders.addAll(VideoService.defaultPreviewFolders);
    }

    _folders
      ..clear()
      ..addAll(existingFolders);

    await _scanAllFolders();
  }

  Future<void> _persistFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsFoldersKey, _folders);
  }

  /// Opens the settings dialog (color theme, appearance mode, custom extensions).
  void _openSettings() {
    showDialog(
      context: context,
      builder: (context) => SettingsDialog(
        settings: widget.settings,
        onExtensionsChanged: _scanAllFolders,
      ),
    );
  }

  /// Opens the directory picker and adds the selected folder to the library.
  Future<void> _addFolder() async {
    final selectedDir = await VideoService.pickDirectory(
      dialogTitle: "Select Video Folder",
    );
    if (selectedDir == null) return;

    if (_folders.contains(selectedDir)) {
      setState(() => _activeFolder = selectedDir);
      _showSnackBar("Folder is already in the media library.");
      return;
    }

    setState(() {
      _folders.add(selectedDir);
      _activeFolder = selectedDir;
      _isScanning = true;
    });

    await _persistFolders();
    await _scanSingleFolder(selectedDir);

    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  /// Removes a folder from the library sidebar and clears orphaned selections.
  Future<void> _removeFolder(String folderPath) async {
    final removedVideos = _folderVideos.remove(folderPath) ?? [];
    setState(() {
      _folders.remove(folderPath);
      if (_activeFolder == folderPath) {
        _activeFolder = null;
      }
      for (final path in removedVideos) {
        if (!_isPathInAnyFolder(path)) {
          _selectedPaths.remove(path);
        }
      }
    });
    await _persistFolders();
  }

  bool _isPathInAnyFolder(String videoPath) {
    for (final list in _folderVideos.values) {
      if (list.contains(videoPath)) return true;
    }
    return false;
  }

  /// Rescans all registered folders using the latest allowed video extensions.
  Future<void> _scanAllFolders() async {
    setState(() => _isScanning = true);
    for (final folder in _folders) {
      await _scanSingleFolder(folder);
    }
    if (mounted) {
      setState(() {
        // Drop any selected paths that are no longer present after rescanning.
        _selectedPaths.removeWhere((p) => !_isPathInAnyFolder(p));
        _isScanning = false;
      });
    }
  }

  /// Scans a single folder and registers discovered video items in the cache.
  Future<void> _scanSingleFolder(String folderPath) async {
    final paths = await VideoService.scanVideosInFolder(
      folderPath,
      allowedExtensions: widget.settings.allVideoExtensions,
    );
    if (!mounted) return;

    setState(() {
      _folderVideos[folderPath] = paths;
      for (final path in paths) {
        _itemCache.putIfAbsent(path, () => VideoItem(path));
      }
    });

    // Trigger asynchronous thumbnail and metadata loading for newly found items.
    for (final path in paths) {
      _ensureItemLoaded(path);
    }
  }

  /// Lazily loads metadata first, then generates a thumbnail at 10% of total frames.
  void _ensureItemLoaded(String path) {
    if (_loadingPaths.contains(path)) return;
    _loadingPaths.add(path);

    final item = _itemCache[path];
    if (item == null) return;

    VideoService.getVideoMetadata(path).then((meta) {
      if (!mounted) return;
      setState(() => item.metadata = meta);

      VideoService.generateThumbnail(
        path,
        fpsValue: meta.fpsValue,
        totalFrames: meta.totalFrames,
        durationSeconds: meta.durationSeconds,
      ).then((thumb) {
        if (mounted && thumb != null) {
          setState(() => item.thumbPath = thumb);
        }
      });
    });
  }

  /// Computes the list of visible video items based on active folder and search.
  List<VideoItem> get _visibleItems {
    final Set<String> seen = {};
    final List<VideoItem> items = [];

    final sourceFolders =
        _activeFolder != null ? [_activeFolder!] : _folders;

    for (final folder in sourceFolders) {
      final paths = _folderVideos[folder] ?? [];
      for (final path in paths) {
        if (seen.add(path)) {
          final item = _itemCache[path];
          if (item != null) {
            if (_searchQuery.isEmpty ||
                item.name.toLowerCase().contains(_searchQuery.toLowerCase())) {
              items.add(item);
            }
          }
        }
      }
    }
    return items;
  }

  int get _totalVideoCount {
    final Set<String> all = {};
    for (final paths in _folderVideos.values) {
      all.addAll(paths);
    }
    return all.length;
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedPaths.clear());
  }

  /// Opens the MergePage with the currently selected videos in selection order.
  void _openMergePage() {
    if (_selectedPaths.length < 2) return;

    final selectedItems = _selectedPaths
        .map((p) => _itemCache[p])
        .whereType<VideoItem>()
        .map((item) => item.copyForMerge())
        .toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MergePage(
          initialItems: selectedItems,
          settings: widget.settings,
        ),
      ),
    );
  }

  /// Opens the TrimPage placeholder with the single selected video.
  void _openTrimPage() {
    if (_selectedPaths.length != 1) return;

    final item = _itemCache[_selectedPaths.first];
    if (item == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TrimPage(videoItem: item),
      ),
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final visibleItems = _visibleItems;
    final selectedCount = _selectedPaths.length;
    final canMerge = selectedCount >= 2;
    final canTrim = selectedCount == 1;

    return Scaffold(
      appBar: AppBar(
        // Top-left settings button
        leading: IconButton(
          tooltip: "Settings",
          icon: const Icon(Icons.settings_outlined),
          onPressed: _openSettings,
        ),
        title: Row(
          children: [
            Icon(Icons.video_collection_outlined, color: colorScheme.primary),
            const SizedBox(width: 10),
            const Text(
              "VideoToolKit",
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
            ),
            if (VideoService.isWebPreview) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.amber.withValues(alpha: 0.6),
                  ),
                ),
                child: const Text(
                  "Web UI Preview",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.amber,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          // Single dynamic action button: Waiting (0), Trim (1), Merge (2+)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: FilledButton.icon(
              onPressed: canTrim
                  ? _openTrimPage
                  : (canMerge ? _openMergePage : null),
              icon: Icon(
                canTrim
                    ? Icons.content_cut
                    : (canMerge ? Icons.merge_type : Icons.hourglass_empty),
                size: 18,
              ),
              label: Text(
                canTrim
                    ? "Trim"
                    : (canMerge ? "Merge ($selectedCount)" : "Waiting"),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: "Refresh folders",
            icon: const Icon(Icons.refresh),
            onPressed: _isScanning ? null : _scanAllFolders,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          // Left sidebar: registered media folders
          _buildSidebar(colorScheme),
          const VerticalDivider(width: 1),
          // Main area: search/selection bar + video grid
          Expanded(
            child: Column(
              children: [
                _buildToolbar(colorScheme, visibleItems.length, selectedCount),
                const Divider(height: 1),
                Expanded(
                  child: _buildMediaContent(colorScheme, visibleItems),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar(ColorScheme colorScheme) {
    return Container(
      width: 260,
      color: colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "FOLDERS",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    color: Colors.grey,
                  ),
                ),
                TextButton.icon(
                  onPressed: _addFolder,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: const Text("Add Folder", style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          // "All Folders" virtual item
          ListTile(
            dense: true,
            selected: _activeFolder == null,
            selectedTileColor: colorScheme.primary.withValues(alpha: 0.14),
            leading: Icon(
              Icons.all_inbox_outlined,
              size: 18,
              color: _activeFolder == null ? colorScheme.primary : Colors.grey,
            ),
            title: const Text(
              "All Folders",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            trailing: _buildCountChip(_totalVideoCount),
            onTap: () => setState(() => _activeFolder = null),
          ),
          const Divider(height: 1),
          Expanded(
            child: _folders.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        "No folders added.\nClick 'Add Folder' to import local videos.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _folders.length,
                    itemBuilder: (context, index) {
                      final folderPath = _folders[index];
                      final folderName = folderPath.split('/').last;
                      final count = _folderVideos[folderPath]?.length ?? 0;
                      final isSelected = _activeFolder == folderPath;

                      return Tooltip(
                        message: folderPath,
                        waitDuration: const Duration(milliseconds: 500),
                        child: ListTile(
                          dense: true,
                          selected: isSelected,
                          selectedTileColor:
                              colorScheme.primary.withValues(alpha: 0.14),
                          leading: Icon(
                            Icons.folder_outlined,
                            size: 18,
                            color:
                                isSelected ? colorScheme.primary : Colors.grey,
                          ),
                          title: Text(
                            folderName.isEmpty ? folderPath : folderName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildCountChip(count),
                              const SizedBox(width: 4),
                              InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _removeFolder(folderPath),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(
                                    Icons.close,
                                    size: 14,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          onTap: () =>
                              setState(() => _activeFolder = folderPath),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountChip(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        "$count",
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildToolbar(
    ColorScheme colorScheme,
    int visibleCount,
    int selectedCount,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 260,
            height: 34,
            child: TextField(
              onChanged: (val) => setState(() => _searchQuery = val),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: "Filter videos by name...",
                prefixIcon: const Icon(Icons.search, size: 18),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 0,
                  horizontal: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            "$visibleCount video${visibleCount == 1 ? '' : 's'}",
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const Spacer(),
          if (selectedCount > 0) ...[
            Text(
              selectedCount == 1
                  ? "1 selected (ready to Trim)"
                  : "$selectedCount selected (ready to Merge)",
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: _clearSelection,
              child: const Text(
                "Clear Selection",
                style: TextStyle(fontSize: 12),
              ),
            ),
          ] else
            const Text(
              "Select 1 video to Trim, or 2+ videos to Merge",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
        ],
      ),
    );
  }

  Widget _buildMediaContent(
    ColorScheme colorScheme,
    List<VideoItem> visibleItems,
  ) {
    if (_isScanning && visibleItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_folders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 56, color: Colors.grey[500]),
            const SizedBox(height: 12),
            const Text(
              "Your media library is empty",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              "Add one or more local folders to browse and process videos.",
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
              ),
              onPressed: _addFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text("Add Video Folder"),
            ),
          ],
        ),
      );
    }

    if (visibleItems.isEmpty) {
      return Center(
        child: Text(
          _searchQuery.isNotEmpty
              ? "No videos match '$_searchQuery'."
              : "No supported video files found in this folder.",
          style: const TextStyle(color: Colors.grey, fontSize: 14),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        childAspectRatio: 1.08,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: visibleItems.length,
      itemBuilder: (context, index) {
        final item = visibleItems[index];
        final selectionIndex = _selectedPaths.indexOf(item.path);
        final isSelected = selectionIndex != -1;

        return _buildVideoCard(
          colorScheme,
          item,
          isSelected,
          selectionIndex + 1,
        );
      },
    );
  }

  Widget _buildVideoCard(
    ColorScheme colorScheme,
    VideoItem item,
    bool isSelected,
    int orderNumber,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final meta = item.metadata;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _toggleSelection(item.path),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        elevation: isSelected ? 4 : 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: isSelected
                ? colorScheme.primary
                : Colors.grey.withValues(alpha: 0.25),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Video thumbnail preview with selection overlay badge
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.thumbPath != null)
                    buildLocalImage(
                      item.thumbPath!,
                      fit: BoxFit.cover,
                    )
                  else
                    Tooltip(
                      message: VideoService.lastThumbnailError ??
                          "Loading thumbnail...",
                      child: Container(
                        color: isDark ? Colors.grey[850] : Colors.grey[200],
                        child: Center(
                          child: Icon(
                            Icons.movie_outlined,
                            size: 36,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  // Duration badge (bottom-right)
                  if (meta != null && meta.duration != "Unknown")
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          meta.duration,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  // Selection order indicator (top-right)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? colorScheme.primary
                            : Colors.black.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: Center(
                        child: isSelected
                            ? Text(
                                "$orderNumber",
                                style: TextStyle(
                                  color: colorScheme.onPrimary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Filename and compact metadata strip
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    meta == null
                        ? "Reading metadata..."
                        : "${meta.resolution} • ${meta.fps} • ${meta.size}",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                    ),
                  ),
                  if (meta != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      "${meta.videoCodec} (${meta.videoProfile}) • ${meta.pixelFormat} • ${meta.audioCodec}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: isDark ? Colors.grey[500] : Colors.grey[600],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
