import 'package:flutter/material.dart';
import 'app_settings.dart';

// ============================================================================
// Desktop Settings Dialog (Theme, Color Scheme, Custom Video Extensions)
// ============================================================================

class SettingsDialog extends StatefulWidget {
  final AppSettings settings;
  final VoidCallback? onExtensionsChanged;

  const SettingsDialog({
    super.key,
    required this.settings,
    this.onExtensionsChanged,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final TextEditingController _extController = TextEditingController();
  String? _extError;

  @override
  void dispose() {
    _extController.dispose();
    super.dispose();
  }

  Future<void> _handleAddExtension() async {
    final error = await widget.settings.addCustomExtension(_extController.text);
    if (!mounted) return;
    if (error != null) {
      setState(() => _extError = error);
    } else {
      setState(() {
        _extError = null;
        _extController.clear();
      });
      widget.onExtensionsChanged?.call();
    }
  }

  Future<void> _handleRemoveExtension(String ext) async {
    await widget.settings.removeCustomExtension(ext);
    widget.onExtensionsChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
        final colorScheme = Theme.of(context).colorScheme;

        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Dialog Header
                    Row(
                      children: [
                        Icon(Icons.settings_outlined, color: colorScheme.primary),
                        const SizedBox(width: 10),
                        const Text(
                          "Settings",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const Divider(height: 24),

                    // Section 1: Color Theme
                    const Text(
                      "Color Theme",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: AppSettings.colorThemes.map((theme) {
                        final isSelected =
                            widget.settings.colorThemeId == theme.id;
                        return InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => widget.settings.setColorTheme(theme.id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: isSelected
                                  ? theme.seedColor.withValues(alpha: 0.16)
                                  : Colors.transparent,
                              border: Border.all(
                                color: isSelected
                                    ? theme.seedColor
                                    : Colors.grey.withValues(alpha: 0.35),
                                width: isSelected ? 1.8 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: theme.seedColor,
                                    shape: BoxShape.circle,
                                  ),
                                  child: isSelected
                                      ? const Icon(
                                          Icons.check,
                                          size: 11,
                                          color: Colors.white,
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  theme.name,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: isSelected
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),

                    // Section 2: Appearance Mode (Defaults to System)
                    const Text(
                      "Appearance Mode",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text("System"),
                            icon: Icon(Icons.brightness_auto_outlined, size: 16),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text("Light"),
                            icon: Icon(Icons.light_mode_outlined, size: 16),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text("Dark"),
                            icon: Icon(Icons.dark_mode_outlined, size: 16),
                          ),
                        ],
                        selected: {widget.settings.themeMode},
                        onSelectionChanged: (selection) {
                          if (selection.isNotEmpty) {
                            widget.settings.setThemeMode(selection.first);
                          }
                        },
                      ),
                    ),
                    const Divider(height: 32),

                    // Section 3: Custom Video Extensions
                    const Text(
                      "Video File Extensions",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Files with built-in or custom extensions are treated as video files when scanning folders.",
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                    const SizedBox(height: 12),

                    // Input row to add a custom extension
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _extController,
                            onSubmitted: (_) => _handleAddExtension(),
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              hintText: "Add extension (e.g. rmvb, vob, m2ts)",
                              errorText: _extError,
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.icon(
                          onPressed: _handleAddExtension,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text("Add"),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Custom extensions (removable)
                    if (widget.settings.customExtensions.isNotEmpty) ...[
                      const Text(
                        "Custom Extensions",
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: widget.settings.customExtensions.map((ext) {
                          return InputChip(
                            label: Text(
                              ".$ext",
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                            onDeleted: () => _handleRemoveExtension(ext),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Built-in extensions (read-only)
                    const Text(
                      "Built-in Extensions",
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: AppSettings.builtInExtensions.map((ext) {
                        return Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            ".$ext",
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),

                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text("Done"),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
