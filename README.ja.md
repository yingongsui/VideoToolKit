# VideoToolKit

[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

Flutter で開発された **macOS**・**Ubuntu Linux** 対応の軽量デスクトップ動画メディアライブラリ＆処理ツールです。ローカルフォルダの一括管理、詳細なストリーム診断、無劣化結合（`-c copy`）、および粗調整・精密トリミング機能を備えています。

---

## 主な機能

### 1. デスクトップ・メディアライブラリ
- **フォルダの永続管理**：複数のローカル動画フォルダを登録（設定を自動保存）し、フォルダ別または `All Folders` で一覧表示。ファイル名検索や手動更新にも対応。
- **自動サムネイル生成**：各動画の総フレーム数の **10%** 地点からサムネイルを自動抽出・キャッシュし、短尺・長尺どちらの動画でも適切に表示。
- **カスタム拡張子対応**：標準対応形式（`mp4 / mkv / mov / avi / webm / m4v / flv / ts`）に加え、設定画面から任意の拡張子（`rmvb / m2ts / vob` など）を追加・削除可能。
- **単一ダイナミック操作ボタン**：選択数に応じて右上のボタンが自動切替：
  - 未選択 → `Waiting`（無効表示）
  - 1 件選択 → `Trim`（トリミング画面へ）
  - 2 件以上選択 → `Merge (N)`（選択順を保持して結合画面へ）
- **テーマ＆通知**：
  - デフォルトでシステムの外観に追従（`System / Light / Dark` 切替可）＋ **6 種類の Material 3 カラーテーマ**。
  - ステータス別に色分けされた中央フローティング・カプセル型トースト通知を採用。

### 2. ストリーム診断＆無劣化結合（Merge）
- **9 項目の詳細ストリーム検出**：
  - **映像**：コーデック（`Codec`）、解像度（`Resolution`）、タイムベース（`Timebase`）、フレームレート（`FPS`）、ピクセル形式・ビット深度（`pix_fmt`）、プロファイル（`High / Main / Baseline` などに正規化）
  - **音声**：音声コーデック（`Audio Codec`）、サンプルレート（`Sample Rate`）、チャンネルレイアウト（`Channel Layout`）
- **結合互換性の自動チェック**：結合前に 1 本目の動画を基準として上記 9 項目を比較（**FPS 許容誤差 ±0.5**）。不一致がある場合はバナーおよび該当カードで警告表示。
- **高速無劣化結合**：FFmpeg の `concat` デマクサ（`-c copy`）による高速結合。ドラッグによる並び替え、ファイル別プログレス表示、出力先フォルダ指定、リアルタイムログ表示、途中強制停止に対応。

### 3. 2 モード動画トリミング（Trim）
- **粗選択モード（Coarse - Time）**：
  - 全体レンジスライダー、`HH:MM:SS.mmm` タイムコード入力、`±1s / ±10s` 微調整ボタンを搭載。
  - **最寄りキーフレーム吸着（Snap to Nearest Keyframe）** をデフォルト有効化（`< KF / KF >` 移動対応）。FFprobe の **`-read_intervals` によるオンデマンド局所スキャン**を採用し、長尺動画でも即座に開けてフリーズしません。
- **精密選択モード（Fine - Frame）**：
  - 粗選択の範囲とリアルタイム同期し、**±5 秒ズームフレームスライダー**、フレーム番号直接入力、`±1f / ±10f` ステップ移動に対応。
  - デフォルトでフレーム単位の再エンコード（`libx264 CRF 18 + AAC`）を使用（`-c copy` への切替も可）。
- **開始・終了フレームのライブプレビュー**：画面上部に **START (IN)** と **END (OUT)** のフレーム画像・タイムコード・フレーム番号を並べて表示。

---

## 対応プラットフォーム

| プラットフォーム | FFmpeg バックエンド | 配布形式 |
| --- | --- | --- |
| **macOS** (Apple Silicon) | 同梱 `ffmpeg_kit_flutter_new`（システム FFmpeg 不要） | `.dmg` |
| **Ubuntu Linux** (amd64) | システム `ffmpeg` / `ffprobe`（`.deb` の `Depends` で自動導入） | `.deb` |
| **Web（ローカル UI 確認用）** | モック実装（`video_service_web.dart`、`web/` は Git 管理外） | `flutter run -d chrome` |

---

## インストール方法

リポジトリの **Releases** ページから各 OS 用のインストーラーを直接ダウンロードできます（`.zip` の解凍は不要）：

### macOS
1. `VideoToolKit-<version>-macos.dmg` をダウンロードし、`VideoToolKit.app` を `Applications` へドラッグします。
2. 初回起動時に未署名警告が表示された場合は、ターミナルで次を実行してください：
   ```bash
   xattr -cr /Applications/VideoToolKit.app
   ```

### Ubuntu Linux (amd64)
`apt` でインストールすると、`ffmpeg`・`libgtk-3`・`zenity` などの依存関係とアプリケーションメニュー・CLI コマンドが自動でセットアップされます：
```bash
sudo apt install ./VideoToolKit-<version>-amd64.deb

# ターミナルから起動（またはアプリ一覧から VideoToolKit を起動）
videotoolkit

# アンインストール
sudo apt remove videotoolkit
```

---

## 開発＆クラウドビルド

### ローカル開発
- 必要環境：Flutter `3.50.1`（Dart SDK `^3.11.5`）
- Xcode なしの macOS でローカル UI プレビューを行う場合：
  ```bash
  flutter create . --platforms=web
  flutter run -d chrome
  ```
- 静的解析：
  ```bash
  flutter pub get
  flutter analyze
  ```

### GitHub Actions クラウドビルド
**Actions → Run workflow** からの手動実行、または `v*` タグのプッシュで自動ビルド＆リリースされます：
- [build_macos.yml](.github/workflows/build_macos.yml)：`macos-15` 上で `VideoToolKit-<version>-macos.dmg` をビルド＆公開（CocoaPods キャッシュ対応）。
- [build_linux.yml](.github/workflows/build_linux.yml)：`ubuntu-24.04` 上で `VideoToolKit-<version>-amd64.deb` をビルド＆公開。

> バージョン番号は [pubspec.yaml](pubspec.yaml) の `version` で一元管理されます。同一バージョンで再実行すると、該当プラットフォームのリリースファイルが上書き更新されます。

---

## ディレクトリ構成

```text
lib/
├── main.dart                  # エントリーポイント＆Material 3 テーマ管理
├── app_settings.dart          # 外観・カラーテーマ・カスタム拡張子の永続化
├── settings_dialog.dart       # 設定ダイアログ UI
├── media_library_page.dart    # メイン画面：フォルダ一覧＆動画グリッド
├── merge_page.dart            # 無劣化結合＆ストリーム互換性チェック画面
├── trim_page.dart             # 粗選択（時間＋キーフレーム吸着）/ 精密選択（フレーム）画面
├── console_log_panel.dart     # 共通 FFmpeg コンソールログ＆進捗パネル
├── floating_toast.dart        # 中央フローティング・カプセル型トースト通知
├── video_models.dart          # VideoMetadata / VideoItem ＆フォーマッター
├── video_service.dart         # プラットフォーム別条件エクスポート
├── video_service_native.dart  # macOS (FFmpegKit) / Linux (ffmpeg CLI) 実装
└── video_service_web.dart     # ローカル Web UI プレビュー用モック実装
```
