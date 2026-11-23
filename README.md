# Lumen

macOS 原生动态壁纸播放器。SwiftUI + AppKit + AVFoundation + Metal，最低 macOS 26。

支持视频、Metal 着色器、网页和 Wallpaper Engine 场景壁纸，可从 Steam 创意工坊下载。

主要功能：
- 自动暂停：遮挡、锁屏、低电量、电池、高温。
- 锁屏：把当前壁纸录成循环视频，作为锁屏和屏保播放。
- 音频响应、鼠标交互。
- Steam 扫码登录下载创意工坊。
- 中英双语界面。

## 安装

在 GitHub Releases 下载 `Lumen-<版本>.dmg`，拖进「应用程序」。这个版本没有经过 Apple 公证，第一次打开的方法见 [docs/INSTALL.md](docs/INSTALL.md)。

协作开发（Claude / Gemini / GPT）请先读 [AGENTS.md](AGENTS.md)；进度和任务板在 [docs/STATUS.md](docs/STATUS.md)，代码结构在 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，测试方法在 [docs/TESTING.md](docs/TESTING.md)。

## 构建

```bash
xcodegen generate
open Lumen.xcodeproj
```

或命令行：

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Lumen.app
```

`Lumen.xcodeproj` 和 `Lumen/Info.plist` 由 `project.yml` 生成，改工程配置请改 `project.yml`。

## 打包发布

```bash
Tools/make-signing-identity.sh   # 可选，只需一次：生成本地签名证书，重新构建后系统权限不会丢
Tools/release.sh                 # 生成 build/release/Lumen-<版本>.dmg 和 SHA-256
```

版本号在 `project.yml` 的 `MARKETING_VERSION`。

## 结构

| 目录 | 内容 |
|---|---|
| `Lumen/Engine` | 桌面窗口、视频/着色器渲染器、暂停策略、系统壁纸同步 |
| `Lumen/Engine/Shaders` | 运行时编译的 Metal 着色器（6 个内置 + 用户自写） |
| `Lumen/Engine/Web` | 网页壁纸（WKWebView） |
| `Lumen/Engine/Scene` | Wallpaper Engine 场景渲染器（着色器翻译、粒子、脚本） |
| `Lumen/Library/Steam` | 原生 Steam 客户端（扫码登录、CM/CDN 下载）与 SteamCMD 兜底 |
| `Lumen/Engine/LockScreen` | 锁屏/屏保：录制循环视频并写入系统壁纸存储 |
| `Lumen/Engine/Audio` | 系统音频频谱（Core Audio process tap） |
| `Tools` | 命令行回归工具 |
| `Lumen/Library` | 资源库、导入、元数据、缩略图、HEVC 优化、播放列表 |
| `Lumen/UI` | 主窗口各页面、菜单栏面板、设置 |

## 性能设计

- 每块屏幕一个桌面层级的无边框窗口（壁纸之上、桌面图标之下，跨所有 Space）。
- 视频走 `AVPlayerLayer` + `AVPlayerLooper`，由媒体引擎硬解；同一视频在多块屏幕上共享一个解码器。
- 自动暂停：桌面被窗口完全遮挡、显示器睡眠、锁屏、屏保、快速切换用户、低电量模式、电池供电（可选）、高温。
- 程序化壁纸按像素预算渲染（默认约 2MP）再放大，帧率可调（默认 30fps）。
- 导入时可一键转成适配显示器分辨率的 HEVC。
- 可选把当前帧同步为系统壁纸，让 Mission Control、切换 Space 时的画面一致；停用时恢复原壁纸。

## 调试

Debug 构建支持启动参数直接打开某个页面：

```bash
open build/DerivedData/Build/Products/Debug/Lumen.app --args -LumenDebugRoute studio:4C554D45-0000-4000-8000-000000000001
```

数据位于 `~/Library/Application Support/Lumen/`。

## 许可

尚未选定开源许可证。参考过的 WallpaperMachine、MirageWallpaper 是 GPL-3.0，本项目只参考了它们的文件格式和思路，没有复制代码。
