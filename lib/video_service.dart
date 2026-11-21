// Platform-conditional barrel for VideoService and local image rendering.
// Native desktop builds use dart:io + ffmpeg_kit_flutter_new;
// Web builds use mock preview data for local UI development.
export 'video_models.dart';
export 'video_service_native.dart'
    if (dart.library.js_interop) 'video_service_web.dart';
