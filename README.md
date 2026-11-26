# Lumen · macOS 动态壁纸 / Live Wallpaper for macOS

[中文](#中文) · [English](#english)

Lumen 是一个原生的 macOS 动态壁纸播放器：视频、Metal 着色器、网页和 Wallpaper Engine 场景壁纸都能放在桌面和锁屏上，并且可以在 App 内浏览、下载 Steam 创意工坊的作品。

Lumen is a native macOS live wallpaper player. It puts videos, Metal shaders, web pages and Wallpaper Engine scenes on your desktop and Lock Screen, and lets you browse and download Steam Workshop items from inside the app.

```
SwiftUI · AppKit · AVFoundation · Metal · JavaScriptCore · WebKit   |   macOS 26+   |   MIT
```

---

## 中文

### 它是什么

Lumen 想解决一件具体的事：在 Mac 上，用一个省电、原生的 App，把 Wallpaper Engine 生态里的壁纸和自己的视频、着色器、网页壁纸放在一起管理和播放。

- **四种壁纸，一个资源库**：视频（MP4/MOV）、Metal 着色器（6 个内置，可在 Studio 里自己写）、网页（本地 HTML 或网址）、Wallpaper Engine 场景。还有一个「原生壁纸」接口，作者自己的两个 Metal 壁纸（代码海、PRO 光丝）就是这样接进来的（需要导入它们各自的项目文件夹）。
- **Wallpaper Engine 场景在 Mac 上原生渲染**：不用虚拟机、不用 Windows。Lumen 读取 `scene.pkg` 和 `.tex`，把 WE 的 GLSL/HLSL 风格着色器在运行时翻译成 Metal，用 JavaScriptCore 跑 SceneScript。
- **App 内的 Steam 创意工坊**：不登录就能按排序、标签、关键词浏览；扫码登录 Steam 后直接下载到资源库（原生 Steam 客户端，SteamCMD 作为后备）。
- **锁屏也能动**：把当前壁纸录成一段无缝循环视频，交给 macOS 的锁屏和屏保播放。
- **常驻桌面也要省**：窗口完全挡住桌面、显示器睡眠、锁屏、屏保、切换用户、低电量模式、用电池（可选）、过热时自动暂停；程序化壁纸按像素预算和帧率上限渲染；场景按实测 GPU 时间自动降分辨率。
- **其他**：多显示器、播放列表轮换、画面裁切、音频响应（系统音频频谱）、鼠标交互、菜单栏面板、导入时一键转 HEVC、中英双语界面、App 内更新。

### 实事求是地说，它做到了什么程度

数字都来自仓库里的回归工具（`Tools/test.sh`，测试方法见 [docs/TESTING.md](docs/TESTING.md)），测试机是一台 MacBook Air（M4，16 GB）。

| 项目 | 结果 |
|---|---|
| Wallpaper Engine 场景加载 | 92/92（75 个日常收藏 + 17 个 2026 年 11 月创意工坊「本周热门」） |
| 场景里用到的 WE 着色器，翻译成 Metal 并编译 | 316/316 |
| 渲染结果里的洋红色缺失纹理块 | 0 |
| 单元测试（解析器、动画、更新器等） | 46/46 |
| 场景 GPU 帧时间（2560×1600 屏，Balanced 预算） | 中位约 5ms，最重的场景约 20ms |

「能加载」不等于「和 Windows 上一模一样」。每个场景都和作者的预览图逐个对比过，绝大多数看起来正确，但仍有差异，见下面的[尚未解决的问题](#尚未解决的问题)。

### 安装

1. 在 [Releases](https://github.com/fancyecho/Lumen/releases) 下载最新的 `Lumen-<版本>.dmg`，拖进「应用程序」。
2. Lumen 目前**没有 Apple 开发者签名和公证**，第一次打开会被 Gatekeeper 拦下：到「系统设置 › 隐私与安全性」点「仍要打开」。详细步骤和校验方法见 [docs/INSTALL.md](docs/INSTALL.md)。
3. 之后的版本可以在「设置 › 通用」里检查并一键安装（默认每天自动检查一次，可关闭）。

场景壁纸需要 Wallpaper Engine 的共享 `assets` 文件夹（着色器、材质），它属于 Wallpaper Engine 本体，Lumen 不附带。登录拥有 Wallpaper Engine 的 Steam 账号后，在资源库的提示或「设置 › Wallpaper Engine」里点「从 Steam 下载」，Lumen 会只取出 `assets`（约 85 MB），保存在自己的文件夹 `~/Library/Application Support/Lumen/SceneAssets`，不依赖其他应用；也可以从文件夹导入一份。下载创意工坊作品同样需要这个账号。

### 项目结构与实现

```
Lumen/
├─ App/          入口、AppModel（全局状态）、设置、路由、更新器
├─ Engine/       桌面窗口与调度
│  ├─ Renderers/   视频（AVPlayerLayer + AVPlayerLooper）、着色器（按像素预算的 MTKView）
│  ├─ Shaders/     内置与用户 Metal 着色器，运行时编译
│  ├─ Web/         WKWebView、lumen-web:// 本地协议、WE 网页属性桥接
│  ├─ Scene/       Wallpaper Engine 场景渲染器（约 9,400 行）
│  ├─ Native/      原生壁纸（代码海、PRO 光丝）
│  ├─ Audio/       Core Audio process tap，系统音频频谱
│  ├─ LockScreen/  锁屏循环视频的录制与安装
│  └─ Policy/      自动暂停：遮挡、锁屏、电源、温度、鼠标
├─ Library/      资源库、导入、缩略图、HEVC 转码、播放列表
│  └─ Steam/       创意工坊目录、原生 Steam 客户端（CM/CDN）、SteamCMD
└─ UI/           SwiftUI 各页面与菜单栏面板
Tools/           命令行回归工具：场景渲染、着色器语料、视觉对比、稳定性、打包
```

约 3.2 万行 Swift，唯一的第三方依赖是 [zstd](https://github.com/facebook/zstd)（Steam CDN 解压）。完整的代码结构见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

**桌面层**：每块屏幕一个无边框窗口，位于系统壁纸之上、桌面图标之下，跨所有 Space。每种壁纸实现同一个 `WallpaperRenderer` 协议（显示、暂停时保留最后一帧、首帧就绪再切换以免黑闪、裁切、销毁）。

**视频**：`AVPlayerLayer` 由媒体引擎硬件解码，同一视频在多块屏幕上共享一个解码器。

**Wallpaper Engine 场景**（`Engine/Scene`）：

1. **解析**：自己实现的 `scene.pkg`（PKGV）、`.tex`（DXT1/3/5、RG88、R8、LZ4、精灵图、内嵌 MP4）、`project.json` 和用户属性绑定解析器。
2. **着色器**：预处理 `#include`/`#if` 和 combo，再把 WE 的着色器源码翻译成 Metal Shading Language（uniform 打包成 float4 槽，处理 HLSL 的隐式截断等差异），按「源码 + combo」缓存编译结果。
3. **每帧**：关键帧动画 → 脚本 → 父子层级 → 每个图层画进自己的离屏缓冲，跑完特效链（具名 FBO、ping-pong）后按混合模式合成。支持木偶变形（骨骼蒙皮的 MDL 网格）、裁剪蒙版、组合层、粒子（CPU 模拟，含绳索、控制点跟随鼠标）、文本层（Core Text）、视频纹理、3D 点光照、全局泛光和光束。
4. **SceneScript**：在 JavaScriptCore 里模拟 WE 的脚本 API（图层属性、定时器、音频缓冲、鼠标事件、动画控制、脚本创建图层、特效和着色器常量上的脚本）。
5. **呈现**：按覆盖屏幕所需的原生像素渲染（上限为画布尺寸，再受像素预算约束），显示得比渲染大时用 Catmull-Rom 放大。

**锁屏**：场景和网页离屏录成循环视频，写进 macOS 当前用户的壁纸存储，由系统锁屏和屏保播放；关闭时按备份恢复原设置。

**Steam**：原生客户端用 Steam 的 CM 协议扫码登录（令牌存在钥匙串），从 CDN 下载并校验创意工坊内容；浏览创意工坊不需要登录。

**更新**：从本仓库的 GitHub Releases 下载 zip，核对同时发布的 SHA-256、代码签名的有效性、Bundle ID 和版本号，在 Lumen 退出后替换自身并重新打开，失败时还原旧版本。

**开发方式**：Lumen 由作者主导，Claude、GPT、Gemini 等 AI 编码助手按 [AGENTS.md](AGENTS.md) 的规则分工协作完成，任务、交接记录和测试基线都公开在 [docs/STATUS.md](docs/STATUS.md)。

### 尚未解决的问题

这些是已知的、真实存在的问题，会持续改进：

- **签名**：没有 Apple Developer ID，构建是临时签名（ad-hoc），第一次打开要手动放行。因为签名每个版本都会变，更新后 macOS 可能会再次询问系统音频权限。更新只靠 HTTPS、发布页上的 SHA-256 和签名完整性来验证，不如开发者签名可靠。
- **系统要求**：只支持 macOS 26 及以上。Intel 架构能编译、也打进了 DMG，但没有在 Intel Mac 上实际测试过；多显示器只在少数配置上验证过。
- **场景还原度**：
  - 脚本控制视频播放（`getVideoTexture` 的播放、停止、结束回调）还是占位，多段视频切换的壁纸会停在第一段。
  - 脚本凭空创建的文本层（常见于文字阴影）不会显示。
  - 媒体集成（「正在播放」的封面、标题、播放状态）没有接入，相关小组件始终按「没有播放」显示。
  - 3D 模型上的特效、木偶的 `MORPHING`、透视相机下的体积光还没做；Wallpaper Engine 的 application 类型（Windows 程序）无法支持。
  - 对比只基于单帧和作者预览图，动画节奏、粒子密度这类随时间变化的差异，主要靠人工观察发现。
- **锁屏**：用到的是 macOS 未公开的壁纸存储格式，系统大版本更新后可能失效。
- **性能**：重场景在高分辨率下 GPU 占用不低（最重约 20ms/帧），虽然有自动降分辨率和暂停策略，但还没有系统地测过电池续航；每个网页壁纸都是一个独立的 WebKit 进程，内存开销比视频大。
- **截图和文档**：README 还没有截图，用户文档也比较少。

可以继续优化的方向：动画类差异的自动化对比、更多设备上的性能测试、媒体集成、脚本视频控制、正式的签名与公证。

### 从源码构建

需要 Xcode 26 或更新（日常在 Xcode 27.1 上构建）和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
xcodegen generate
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Lumen.app
```

`Lumen.xcodeproj` 由 `project.yml` 生成，改工程配置请改 `project.yml`。打包发布用 `Tools/release.sh`（生成 DMG、zip 和 SHA-256，见 [docs/INSTALL.md](docs/INSTALL.md)）。回归测试用 `Tools/test.sh unit | scenes | shaders | visual`。

### 许可与致谢

Lumen 以 [MIT 许可证](LICENSE) 开源。

开发中参考了 [WallpaperMachine](https://github.com/MMFoundation/WallpaperMachine) 和 [MirageWallpaper](https://github.com/laobamac/MirageWallpaper)（均为 GPL-3.0）的文件格式与思路，没有复制它们的代码；Lumen 的解析器、渲染器和 Steam 客户端都是独立实现。Wallpaper Engine 的 assets 和创意工坊作品属于各自的作者，不包含在本仓库中。Wallpaper Engine 和 Steam 是其各自所有者的商标，Lumen 与它们没有关联。

---

## English

### What it is

Lumen aims at one concrete thing: a native, power-aware Mac app that manages and plays Wallpaper Engine content alongside your own videos, shaders and web wallpapers.

- **Four kinds of wallpaper, one library**: videos (MP4/MOV), Metal shaders (6 built in, plus your own written in Studio), web pages (local HTML or a URL) and Wallpaper Engine scenes. A "native wallpaper" interface brings in the author's two Metal wallpapers, Code Sea and PRO Strands (imported from their own project folders).
- **Wallpaper Engine scenes rendered natively on the Mac**: no VM, no Windows. Lumen reads `scene.pkg` and `.tex` files, translates WE's GLSL/HLSL-style shaders to Metal at runtime and runs SceneScript in JavaScriptCore.
- **Steam Workshop inside the app**: browse by sort order, tag and keyword without signing in; sign in to Steam with a QR code and download straight into the library (native Steam client, with SteamCMD as a fallback).
- **A moving Lock Screen**: Lumen records the current wallpaper as a seamless loop and hands it to the macOS Lock Screen and screen saver.
- **Built to sit on the desktop all day**: it pauses when windows cover the desktop, the display sleeps, the Mac locks, the screen saver runs, another user is active, Low Power Mode is on, on battery (optional) or when the Mac runs hot. Procedural wallpapers render to a pixel budget and frame-rate cap, and scenes lower their resolution based on measured GPU time.
- **Also**: multiple displays, playlists, framing, audio reactivity (system audio spectrum), mouse interaction, a menu bar panel, one-click HEVC conversion on import, English and Simplified Chinese UI, in-app updates.

### How far it actually gets

These numbers come from the regression tools in this repository (`Tools/test.sh`, see [docs/TESTING.md](docs/TESTING.md)), measured on a MacBook Air (M4, 16 GB).

| Check | Result |
|---|---|
| Wallpaper Engine scenes that load | 92/92 (75 from a personal collection + 17 from the Workshop's "most popular this week", November 2026) |
| WE shaders used by those scenes, translated to Metal and compiled | 316/316 |
| Magenta missing-texture blocks in the renders | 0 |
| Unit tests (parsers, animation, updater and more) | 46/46 |
| Scene GPU frame time (2560×1600 display, Balanced budget) | median ~5 ms, heaviest scene ~20 ms |

"Loads" is not the same as "looks exactly like Windows". Every scene was compared against its author's preview by eye; most look right, and the differences that remain are listed under [Known issues](#known-issues).

### Install

1. Download the latest `Lumen-<version>.dmg` from [Releases](https://github.com/fancyecho/Lumen/releases) and drag Lumen into Applications.
2. Lumen is **not signed with an Apple Developer ID or notarized** yet, so Gatekeeper blocks the first launch: open System Settings › Privacy & Security and click Open Anyway. [docs/INSTALL.md](docs/INSTALL.md) has the details and how to verify the download.
3. Later versions can be checked for and installed from Settings › General (Lumen checks once a day; you can turn that off).

Scene wallpapers need Wallpaper Engine's shared `assets` folder (shaders and materials). It belongs to Wallpaper Engine itself and isn't bundled with Lumen. Once you sign in with a Steam account that owns Wallpaper Engine, click Download from Steam in the Library notice or in Settings › Wallpaper Engine: Lumen fetches only `assets` (about 85 MB) and keeps it in its own folder, `~/Library/Application Support/Lumen/SceneAssets`, so it doesn't depend on any other app. You can also import a copy from a folder. Downloading Workshop items needs the same account.

### Project structure and implementation

```
Lumen/
├─ App/          entry point, AppModel (global state), settings, routing, updater
├─ Engine/       desktop windows and scheduling
│  ├─ Renderers/   video (AVPlayerLayer + AVPlayerLooper), shaders (pixel-budgeted MTKView)
│  ├─ Shaders/     built-in and user Metal shaders, compiled at runtime
│  ├─ Web/         WKWebView, the lumen-web:// scheme, WE web property bridge
│  ├─ Scene/       Wallpaper Engine scene renderer (~9,400 lines)
│  ├─ Native/      native wallpapers (Code Sea, PRO Strands)
│  ├─ Audio/       Core Audio process tap, system audio spectrum
│  ├─ LockScreen/  recording and installing Lock Screen loops
│  └─ Policy/      automatic pause: occlusion, lock, power, thermals, pointer
├─ Library/      library, import, thumbnails, HEVC conversion, playlists
│  └─ Steam/       Workshop catalog, native Steam client (CM/CDN), SteamCMD
└─ UI/           SwiftUI screens and the menu bar panel
Tools/           command-line regression tools: scene renders, shader corpus, visual diff, stability, packaging
```

About 32,000 lines of Swift. The only third-party dependency is [zstd](https://github.com/facebook/zstd), for Steam CDN chunks. The full code map is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (Chinese).

**Desktop layer**: one borderless window per display, above the system wallpaper and below the desktop icons, on every Space. Each wallpaper kind implements the same `WallpaperRenderer` protocol (show, keep the last frame while paused, switch only once the first frame is ready to avoid a black flash, framing, teardown).

**Video**: `AVPlayerLayer` decoded by the media engine in hardware, with one decoder shared across displays showing the same video.

**Wallpaper Engine scenes** (`Engine/Scene`):

1. **Parsing**: Lumen's own readers for `scene.pkg` (PKGV), `.tex` (DXT1/3/5, RG88, R8, LZ4, sprite sheets, embedded MP4), `project.json` and user-property bindings.
2. **Shaders**: `#include`/`#if` and combos are preprocessed, then WE shader source is translated to Metal Shading Language (uniforms packed into float4 slots, HLSL's implicit truncation and other differences handled). Compiled programs are cached per source and combo set.
3. **Every frame**: keyframes → scripts → parent hierarchy → each layer draws into its own offscreen buffer, runs its effect chain (named FBOs, ping-pong) and is composited with its blend mode. Puppet warp (skinned MDL meshes), clipping masks, composition layers, particles (simulated on the CPU, including ropes and pointer-following control points), text layers (Core Text), video textures, 3D point lights, scene bloom and light shafts are supported.
4. **SceneScript**: WE's scripting API emulated in JavaScriptCore (layer properties, timers, audio buffers, cursor events, animation control, layers created by scripts, scripts on effects and shader constants).
5. **Presentation**: rendered at the native pixels needed to cover the display (capped at the canvas size, then by the pixel budget), upscaled with Catmull-Rom when shown larger than rendered.

**Lock Screen**: scenes and web pages are recorded offscreen into a loop and written into the current user's macOS wallpaper store, which the Lock Screen and screen saver play; turning it off restores the previous settings from a backup.

**Steam**: the native client signs in over Steam's CM protocol with a QR code (the token stays in the Keychain), then downloads and verifies Workshop content from the CDN. Browsing the Workshop needs no sign-in.

**Updates**: the zip from this repository's GitHub Releases is checked against the SHA-256 published with it, its code signature, bundle ID and version; Lumen then replaces itself after quitting and reopens, restoring the old copy if the swap fails.

**How it's developed**: the author leads the project, and AI coding assistants (Claude, GPT, Gemini) split the work under the rules in [AGENTS.md](AGENTS.md). Tasks, hand-off notes and test baselines are public in [docs/STATUS.md](docs/STATUS.md) (Chinese).

### Known issues

These are real, known problems, and they're being worked on:

- **Signing**: there's no Apple Developer ID, so builds are ad-hoc signed and the first launch must be allowed by hand. Because the signature changes with every version, macOS may ask for the system audio permission again after an update. Updates are verified only by HTTPS, the SHA-256 on the release page and signature integrity, which is weaker than a developer signature.
- **Requirements**: macOS 26 or later only. The Intel slice builds and ships in the DMG but hasn't been tested on an Intel Mac; multiple displays have been checked on only a few setups.
- **Scene fidelity**:
  - Script-controlled video playback (`getVideoTexture` play, stop and ended callbacks) is still a stand-in, so wallpapers that switch between several clips stay on the first one.
  - Text layers that scripts create from nothing (usually text shadows) don't appear.
  - Media integration ("now playing" cover, title and playback state) isn't wired up, so those widgets always show the "nothing playing" state.
  - Effects on 3D models, puppet `MORPHING` and volumetric lights under a perspective camera aren't done; Wallpaper Engine's application type (Windows programs) can't be supported.
  - Comparisons are single frames against author previews, so differences that only show over time, such as animation pacing or particle density, are mostly found by watching.
- **Lock Screen**: it relies on macOS's undocumented wallpaper store format and may break with a major macOS update.
- **Performance**: heavy scenes at high resolution use a fair amount of GPU (up to ~20 ms per frame). Lumen lowers resolution and pauses automatically, but battery life hasn't been measured systematically. Each web wallpaper is its own WebKit process and uses more memory than a video.
- **Screenshots and docs**: the README has no screenshots yet, and user documentation is thin.

Directions for further work: automated comparison of animated differences, performance tests on more Macs, media integration, script video control, and proper signing and notarization.

### Build from source

Requires Xcode 26 or later (developed with Xcode 27.1) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Lumen.app
```

`Lumen.xcodeproj` is generated from `project.yml`; change project settings there. `Tools/release.sh` packages a release (DMG, zip and SHA-256 files, see [docs/INSTALL.md](docs/INSTALL.md)). Regression tests: `Tools/test.sh unit | scenes | shaders | visual`.

### License and credits

Lumen is open source under the [MIT License](LICENSE).

The file formats and ideas in [WallpaperMachine](https://github.com/MMFoundation/WallpaperMachine) and [MirageWallpaper](https://github.com/laobamac/MirageWallpaper) (both GPL-3.0) were used as references; no code was copied from them, and Lumen's parsers, renderer and Steam client are independent implementations. Wallpaper Engine assets and Workshop items belong to their authors and aren't included in this repository. Wallpaper Engine and Steam are trademarks of their respective owners; Lumen isn't affiliated with them.
