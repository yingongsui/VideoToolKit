import 'package:flutter/material.dart';
import 'app_settings.dart';
import 'media_library_page.dart';

void main() => runApp(const VideoToolKitApp());

/// Root application widget managing system/light/dark appearance and color themes.
class VideoToolKitApp extends StatefulWidget {
  const VideoToolKitApp({super.key});

  @override
  State<VideoToolKitApp> createState() => _VideoToolKitAppState();
}

class _VideoToolKitAppState extends State<VideoToolKitApp> {
  final AppSettings _settings = AppSettings();

  @override
  void initState() {
    super.initState();
    _settings.load();
  }

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final seedColor = _settings.activeColorTheme.seedColor;

        return MaterialApp(
          title: "VideoToolKit",
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: seedColor,
              brightness: Brightness.light,
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: seedColor,
              brightness: Brightness.dark,
            ),
          ),
          themeMode: _settings.themeMode,
          home: MediaLibraryPage(settings: _settings),
        );
      },
    );
  }
}
