# VideoToolKit

[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

A lightweight desktop video media library and processing utility built with Flutter for **macOS** and **Ubuntu Linux**. Manage local video folders, inspect detailed stream diagnostics, perform lossless video concatenation (`-c copy`), and trim videos with both coarse keyframe snapping and fine frame-accurate controls.

---

## Features

### 1. Desktop Media Library
- **Persistent Folder Management**: Add multiple local video directories (persisted locally), browse by individual folder or `All Folders`, search by filename, and refresh anytime.
- **Automatic Thumbnails**: Extracts and caches thumbnails sampled at **10%** of each video's total frames for both short and long clips.
- **Custom Video Extensions**: Built-in support for `mp4 / mkv / mov / avi / webm / m4v / flv / ts`, plus customizable extra extensions (e.g. `rmvb / m2ts / vob`) in Settings.
- **Dynamic Single Action Button**: Automatically adapts in the top-right corner based on selection:
  - `0` selected → `Waiting` (disabled)
  - `1` selected → `Trim`
  - `2+` selected → `Merge (N)` (preserves selection order)
- **Themes & Notifications**:
  - Follows system appearance by default (`System / Light / Dark`) with **6 Material 3 color themes**.
  - Centered floating capsule toast notifications styled by status (`success / warning / error / info`).

### 2. Stream Diagnostics & Lossless Merge
- **9 Stream Parameters Probed**:
  - **Video**: Codec, Resolution, Timebase, Frame Rate (`FPS`), Pixel Format / Bit Depth (`pix_fmt`), Codec Profile (normalized e.g. `High / Main / Baseline`)
  - **Audio**: Audio Codec, Sample Rate, Channel Layout
- **Stream Compatibility Check**: Automatically compares all queued clips against the first clip across all 9 fields (**±0.5 FPS tolerance**) and highlights mismatches before running `-c copy`.
- **Fast Lossless Concatenation**: Uses the FFmpeg `concat` demuxer (`-c copy`) with drag-to-reorder, per-clip progress gradients, custom output directory, live console logs, and instant cancellation.

### 3. Dual-Mode Video Trim
- **Coarse Mode (Time-Based)**:
  - Full-duration range slider, `HH:MM:SS.mmm` timecode inputs, and `±1s / ±10s` step controls.
  - **Snap to Nearest Keyframe** enabled by default with `< KF / KF >` jumping, powered by on-demand FFprobe **`-read_intervals` local scanning** (scans only a local window around the cursor—instant startup even on multi-hour videos).
- **Fine Mode (Frame-Accurate)**:
  - Synchronized with the coarse range, offering a **±5s zoomed frame scrubber**, direct frame number entry, and `±1f / ±10f` stepping.
  - Defaults to frame-accurate re-encoding (`libx264 CRF 18 + AAC`) with an option to toggle back to `-c copy`.
- **Live Start / End Frame Previews**: Side-by-side **START (IN)** and **END (OUT)** frame previews with live timecode and frame number overlays.

---

## Supported Platforms

| Platform | FFmpeg Backend | Release Format |
| --- | --- | --- |
| **macOS** (Apple Silicon) | Bundled `ffmpeg_kit_flutter_new` (no system FFmpeg required) | `.dmg` |
| **Ubuntu Linux** (amd64) | System `ffmpeg` / `ffprobe` (installed automatically via `.deb` `Depends`) | `.deb` |
| **Web (Local UI Preview)** | Mock preview layer (`video_service_web.dart`; `web/` is gitignored) | `flutter run -d chrome` |

---

## Installation

Download the direct installer for your platform from the repository's **Releases** page (no `.zip` extraction needed):

### macOS
1. Download `VideoToolKit-<version>-macos.dmg` and drag `VideoToolKit.app` into `Applications`.
2. If macOS blocks the unsigned app on first launch, run:
   ```bash
   xattr -cr /Applications/VideoToolKit.app
   ```

### Ubuntu Linux (amd64)
Install with `apt` to automatically resolve `ffmpeg`, `libgtk-3`, and `zenity` dependencies and register the launcher icon and CLI command:
```bash
sudo apt install ./VideoToolKit-<version>-amd64.deb

# Launch from terminal (or via the Applications menu)
videotoolkit

# Uninstall
sudo apt remove videotoolkit
```

---

## Development & Cloud Builds

### Local Development
- Requirements: Flutter `3.50.1` (Dart SDK `^3.11.5`)
- Preview UI locally in a browser without installing Xcode:
  ```bash
  flutter create . --platforms=web
  flutter run -d chrome
  ```
- Static analysis:
  ```bash
  flutter pub get
  flutter analyze
  ```

### GitHub Actions Cloud Packaging
Both workflows run on demand via **Actions → Run workflow** or automatically when pushing a `v*` tag:
- [build_macos.yml](.github/workflows/build_macos.yml): Builds and publishes `VideoToolKit-<version>-macos.dmg` on `macos-15` (with CocoaPods caching).
- [build_linux.yml](.github/workflows/build_linux.yml): Builds and publishes `VideoToolKit-<version>-amd64.deb` on `ubuntu-24.04`.

> The app version is controlled by `version` in [pubspec.yaml](pubspec.yaml). Re-running a workflow on the same version overwrites that platform's asset in the matching GitHub Release.

---

## Project Structure

```text
lib/
├── main.dart                  # Entry point & global Material 3 theme
├── app_settings.dart          # Theme mode, color presets & custom extensions store
├── settings_dialog.dart       # Settings modal UI
├── media_library_page.dart    # Main screen: folder sidebar & video grid
├── merge_page.dart            # Lossless concatenation & stream compatibility check
├── trim_page.dart             # Coarse (time + keyframe snap) & Fine (frame) trimmer
├── console_log_panel.dart     # Shared FFmpeg console log & progress panel
├── floating_toast.dart        # Centered floating capsule toast overlay
├── video_models.dart          # VideoMetadata / VideoItem & pure Dart formatters
├── video_service.dart         # Platform-conditional export entry
├── video_service_native.dart  # macOS (FFmpegKit) & Linux (ffmpeg/ffprobe CLI) backend
└── video_service_web.dart     # Local Web UI preview mock backend
```
