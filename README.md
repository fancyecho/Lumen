# Lumen

macOS 原生动态壁纸播放器。SwiftUI + AppKit + AVFoundation + Metal，最低 macOS 26。

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

## 结构

| 目录 | 内容 |
|---|---|
| `Lumen/Engine` | 桌面窗口、视频/着色器渲染器、暂停策略、系统壁纸同步 |
| `Lumen/Engine/Shaders` | 运行时编译的 Metal 着色器（6 个内置 + 用户自写） |
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
