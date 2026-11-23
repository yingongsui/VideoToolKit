# VideoToolKit

[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

一款基于 Flutter 开发的轻量级桌面端视频媒体库与处理工具，支持 **macOS** 与 **Ubuntu Linux**，提供本地文件夹管理、流参数诊断、无损拼接合并（`-c copy`）以及粗选/精选视频截取功能。

---

## 核心功能

### 1. 桌面端媒体库
- **多文件夹持久化管理**：添加任意本地视频目录（自动保存至本地配置），支持按单目录或 `All Folders` 浏览、按文件名实时检索与刷新。
- **自动抽帧缩略图**：按视频总帧数的 **10%** 自动采样生成并缓存缩略图，兼顾短视频与长视频。
- **自定义视频扩展名**：除内置格式（`mp4 / mkv / mov / avi / webm / m4v / flv / ts`）外，可在设置中自由增删自定义扩展名（如 `rmvb / m2ts / vob`），立即生效。
- **单按钮智能联动**：右上角操作按钮随选中数量自动切换：
  - 未选择 → `Waiting`（禁用态）
  - 选中 1 个 → `Trim`（进入视频截取）
  - 选中 2 个及以上 → `Merge (N)`（按勾选顺序进入无损合并）
- **个性化外观与提示**：
  - 默认跟随系统深浅色（支持 `System / Light / Dark` 切换），内置 **6 套 Material 3 颜色主题**；
  - 全局采用居中悬浮胶囊 Toast 通知（成功/警告/错误/提示区分色）。

### 2. 流参数诊断与无损合并（Merge）
- **9 项核心流检测**：
  - **视频流**：编码（`Codec`）、分辨率（`Resolution`）、时间基（`Timebase`）、帧率（`FPS`）、像素格式/位深（`pix_fmt`）、编码 Profile（自动映射如 `High / Main / Baseline`）
  - **音频流**：音频编码（`Audio Codec`）、采样率（`Sample Rate`）、声道布局（`Channel Layout`）
- **自动流一致性校验**：合并多段视频前自动以第 1 个视频为基准比对上述 9 项参数（**FPS 允许 ±0.5 容差**），存在差异时在顶部横幅与对应卡片高亮提示。
- **无损直通拼接**：使用 FFmpeg `concat` demuxer（`-c copy`）极速合并，支持拖拽重排顺序、单视频实时进度渐变、自定义输出目录、终端日志实时滚动与随时强制终止。

### 3. 双模式视频截取（Trim）
- **粗选（Coarse - Time）**：
  - 全时长双滑块 + `HH:MM:SS.mmm` 时间码输入 + `±1s / ±10s` 快捷微调；
  - 默认开启 **最近关键帧吸附（Snap to Nearest Keyframe）** 与 `< KF / KF >` 关键帧跳转，采用 FFprobe **`-read_intervals` 按需局部扫描**（仅扫描光标附近区间，长视频秒开不卡顿），解决 `-c copy` 切不到关键帧的问题。
- **精选（Fine - Frame）**：
  - 与粗选区间实时同步，提供 **±5 秒局部缩放逐帧滑块**、精确帧号输入与 `±1f / ±10f` 步进；
  - 默认启用帧精准重编码（`libx264 CRF 18 + AAC`），也可自由切换回 `-c copy`。
- **起止帧实时预览**：顶部并排实时展示当前选中的 **START (IN)** 与 **END (OUT)** 关键帧画面及时间码/帧号。

---

## 支持平台与架构

| 平台 | FFmpeg 后端 | 发布格式 |
| --- | --- | --- |
| **macOS** (Apple Silicon) | 内置 `ffmpeg_kit_flutter_new`（免安装系统 FFmpeg） | `.dmg` |
| **Ubuntu Linux** (amd64) | 系统 `ffmpeg` / `ffprobe`（`.deb` 安装时由 `apt` 自动拉取） | `.deb` |
| **Web（仅本地 UI 调试）** | Mock 预览层（`video_service_web.dart`，`web/` 已忽略不入库） | 仅本地 `flutter run -d chrome` |

---

## 安装与使用

从仓库右侧 **Releases** 页面直接下载对应平台的安装包（无需解压 `.zip`）：

### macOS
1. 下载 `VideoToolKit-<version>-macos.dmg`，将 `VideoToolKit.app` 拖入 `Applications`。
2. 首次打开若触发系统未签名提示，在终端执行一次：
   ```bash
   xattr -cr /Applications/VideoToolKit.app
   ```

### Ubuntu Linux (amd64)
使用 `apt` 安装（自动补齐 `ffmpeg`、`libgtk-3`、`zenity` 等依赖并创建桌面菜单图标与命令行入口）：
```bash
sudo apt install ./VideoToolKit-<version>-amd64.deb

# 终端启动（或直接从应用菜单打开 VideoToolKit）
videotoolkit

# 卸载
sudo apt remove videotoolkit
```

---

## 开发与云端构建

### 本地开发与 UI 预览
- 环境要求：Flutter `3.50.1`（Dart SDK `^3.11.5`）
- 如需在未安装 Xcode 的 macOS 上仅预览调试 UI：
  ```bash
  flutter create . --platforms=web
  flutter run -d chrome
  ```
- 静态检查：
  ```bash
  flutter pub get
  flutter analyze
  ```

### GitHub Actions 云端打包
项目内置两条按需触发的云端构建流水线（支持在 **Actions** 页面点击 **Run workflow** 手动触发，或推送 `v*` 标签自动发布）：
- [build_macos.yml](.github/workflows/build_macos.yml)：在 `macos-15` 上构建并发布 `VideoToolKit-<version>-macos.dmg` 至对应版本 Release（带 CocoaPods 缓存）。
- [build_linux.yml](.github/workflows/build_linux.yml)：在 `ubuntu-24.04` 上构建并发布 `VideoToolKit-<version>-amd64.deb` 至对应版本 Release。

> 版本号统一由 [pubspec.yaml](pubspec.yaml) 的 `version` 字段管理；同版本号重跑工作流会自动覆盖对应平台的安装包。

---

## 目录结构

```text
lib/
├── main.dart                  # 应用入口与全局 Material 3 主题管理
├── app_settings.dart          # 主题模式、颜色主题、自定义扩展名持久化
├── settings_dialog.dart       # 设置弹窗 UI
├── media_library_page.dart    # 主界面：文件夹侧边栏与视频网格媒体库
├── merge_page.dart            # 无损拼接与流一致性校验页面
├── trim_page.dart             # 粗选（时间+关键帧吸附）/ 精选（逐帧）截取页面
├── console_log_panel.dart     # 复用的 FFmpeg 控制台日志与进度面板
├── floating_toast.dart        # 居中悬浮胶囊 Toast 提示组件
├── video_models.dart          # VideoMetadata / VideoItem 与纯 Dart 格式化工具
├── video_service.dart         # 平台条件导出入口
├── video_service_native.dart  # macOS (FFmpegKit) 与 Linux (ffmpeg/ffprobe CLI) 实现
└── video_service_web.dart     # 本地 Web UI 调试用 Mock 实现
```
