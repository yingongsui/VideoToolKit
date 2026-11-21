import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
// Color Theme Presets & Application Settings Controller
// ============================================================================

class AppColorTheme {
  final String id;
  final String name;
  final Color seedColor;

  const AppColorTheme({
    required this.id,
    required this.name,
    required this.seedColor,
  });
}

/// Manages persistent app settings: theme mode, color theme, and custom video extensions.
class AppSettings extends ChangeNotifier {
  static const String _keyThemeMode = 'settings_theme_mode';
  static const String _keyColorTheme = 'settings_color_theme';
  static const String _keyCustomExtensions = 'settings_custom_extensions';

  /// Built-in video extensions always recognized by the media library.
  static const List<String> builtInExtensions = [
    'mp4',
    'mkv',
    'mov',
    'avi',
    'webm',
    'm4v',
    'flv',
    'ts',
  ];

  /// Available accent color themes.
  static const List<AppColorTheme> colorThemes = [
    AppColorTheme(id: 'ocean_blue', name: 'Ocean Blue', seedColor: Color(0xFF2196F3)),
    AppColorTheme(id: 'emerald', name: 'Emerald', seedColor: Color(0xFF10B981)),
    AppColorTheme(id: 'violet', name: 'Violet', seedColor: Color(0xFF8B5CF6)),
    AppColorTheme(id: 'amber', name: 'Sunset Orange', seedColor: Color(0xFFF59E0B)),
    AppColorTheme(id: 'crimson', name: 'Crimson Rose', seedColor: Color(0xFFF43F5E)),
    AppColorTheme(id: 'teal', name: 'Teal Cyan', seedColor: Color(0xFF06B6D4)),
  ];

  ThemeMode _themeMode = ThemeMode.system;
  String _colorThemeId = 'ocean_blue';
  final List<String> _customExtensions = [];

  ThemeMode get themeMode => _themeMode;
  String get colorThemeId => _colorThemeId;
  List<String> get customExtensions => List.unmodifiable(_customExtensions);

  /// Combined list of built-in and user-defined video extensions.
  List<String> get allVideoExtensions => [
        ...builtInExtensions,
        ..._customExtensions,
      ];

  AppColorTheme get activeColorTheme {
    return colorThemes.firstWhere(
      (t) => t.id == _colorThemeId,
      orElse: () => colorThemes.first,
    );
  }

  /// Loads persisted settings from SharedPreferences.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final savedMode = prefs.getString(_keyThemeMode);
    if (savedMode == 'light') {
      _themeMode = ThemeMode.light;
    } else if (savedMode == 'dark') {
      _themeMode = ThemeMode.dark;
    } else {
      _themeMode = ThemeMode.system;
    }

    final savedColor = prefs.getString(_keyColorTheme);
    if (savedColor != null && colorThemes.any((t) => t.id == savedColor)) {
      _colorThemeId = savedColor;
    }

    final savedExts = prefs.getStringList(_keyCustomExtensions) ?? [];
    _customExtensions
      ..clear()
      ..addAll(savedExts);

    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    final modeStr = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await prefs.setString(_keyThemeMode, modeStr);
  }

  Future<void> setColorTheme(String themeId) async {
    if (_colorThemeId == themeId) return;
    if (!colorThemes.any((t) => t.id == themeId)) return;
    _colorThemeId = themeId;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyColorTheme, themeId);
  }

  /// Normalizes and adds a custom video extension. Returns null on success or an error message.
  Future<String?> addCustomExtension(String rawInput) async {
    final cleaned = rawInput.trim().toLowerCase().replaceAll(RegExp(r'^\.+'), '');
    if (cleaned.isEmpty) {
      return "Extension cannot be empty.";
    }
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(cleaned)) {
      return "Use letters and digits only (e.g. rmvb, vob, m2ts).";
    }
    if (builtInExtensions.contains(cleaned)) {
      return "'.$cleaned' is already a built-in video extension.";
    }
    if (_customExtensions.contains(cleaned)) {
      return "'.$cleaned' is already added.";
    }

    _customExtensions.add(cleaned);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyCustomExtensions, _customExtensions);
    return null;
  }

  Future<void> removeCustomExtension(String ext) async {
    if (!_customExtensions.remove(ext)) return;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyCustomExtensions, _customExtensions);
  }
}
