# Lumen · 代码结构

## 总体数据流

```
AppModel (@MainActor, 全局状态)
 ├─ LibraryStore ─── library.json + Items/<id>/   资源库、导入
 ├─ PlaylistStore ── playlists.json
 ├─ WorkshopLibrary / SteamWorkshop               创意工坊发现与下载
 ├─ AppSettings ──── UserDefaults                 所有设置
 └─ WallpaperEngine
     ├─ AssignmentStore                           哪块屏幕放哪个壁纸
     ├─ DesktopHost × 每块屏幕 → DesktopWindow    桌面层级窗口（壁纸之上、图标之下）
     │    └─ WallpaperRenderer                    Video / Shader / Web / Scene
     ├─ Policy: OcclusionMonitor, SystemMonitor, DesktopPointerMonitor → PauseReason
     ├─ StillFrameSync                            当前帧同步为系统壁纸
     └─ LockScreenManager                         锁屏视频（AerialSystem）
```

每种壁纸都通过 `WallpaperRenderer` 协议接入（`Engine/Renderers/WallpaperRenderer.swift`）：

- `view`
- `setActive`：暂停时保留最后一帧
- `whenReady`：首帧上屏后再切换，避免黑闪
- `setFraming`
- `tearDown`

新增壁纸类型：

1. 实现这个协议。
2. 在 `WallpaperEngine.makeRenderer` 里分发。
3. 在 `Models.swift` 的 `WallpaperKind` 里加一个 case。

## 目录

| 目录 | 内容 |
|---|---|
| `Lumen/App` | 入口、`AppModel`、`AppSettings`、路由、调试启动参数 |
| `Lumen/Engine` | 桌面窗口、引擎调度、画面裁切、系统壁纸同步 |
| `Lumen/Engine/Renderers` | 视频（AVPlayerLayer + AVPlayerLooper，多屏共享）、着色器（`BudgetedMetalView` 按像素预算渲染） |
| `Lumen/Engine/Shaders` | 内置和用户 Metal 着色器，运行时编译 |
| `Lumen/Engine/Policy` | 自动暂停（遮挡、锁屏、屏保、低电量、电池、高温）、桌面鼠标监听 |
| `Lumen/Engine/LockScreen` | 锁屏视频生成与安装 |
| `Lumen/Engine/Audio` | 系统音频采集（Core Audio process tap）与频谱分析，供音频响应壁纸使用 |
| `Lumen/Engine/Web` | Web 渲染器、`lumen-web://` 本地协议、注入的桥接脚本 |
| `Lumen/Engine/Scene` | Wallpaper Engine 场景渲染器（见下节） |
| `Lumen/Library` | 资源库、导入（视频、WE 项目、网页）、缩略图、HEVC 转码、播放列表 |
| `Lumen/Library/Steam` | SteamCMD 安装与驱动（伪终端）、创意工坊下载队列 |
| `Lumen/UI` | 各页面：Home、Library、Playlists、Studio、Workshop、Detail、Settings、MenuBar |
| `Lumen/Resources` | `Localizable.xcstrings`（zh-Hans）、资源目录 |
| `Tools` | 命令行回归工具（不进 app target），见 `docs/TESTING.md` |

## 数据位置

`~/Library/Application Support/Lumen/`：

- `library.json`、`playlists.json`
- `Items/<uuid>/`：导入的文件；WE 项目在 `content/` 下，同盘时用 APFS clone，不额外占空间
- `Thumbnails/`、`Stills/`
- `SteamCMD/`：SteamCMD 本体、登录缓存、临时下载

其他：

- 场景里的视频纹理缓存：`~/Library/Caches/app.lumen.Lumen/SceneVideos/`
- Web 壁纸的网站数据：每个壁纸一个 `WKWebsiteDataStore(forIdentifier:)`，删除壁纸时一并删除

## WE 项目格式（Lumen 已实现的部分）

- **`project.json`**：
  - `type`：scene / web / video / application
  - `file`、`preview`、`general.properties`（用户属性）
  - 解析在 `Library/WallpaperEngineProject.swift`，属性条件表达式由 `ConditionEvaluator` 处理
- **`scene.pkg`**：
  - 头部 `PKGV00xx`，后跟文件表（名字、偏移、大小）
  - 读取：`SceneFileSystem` 的 `PackageArchive`
  - 查找顺序：pkg 内 → 项目文件夹 → 共享 assets
- **`.tex`**（`TexDecoder.swift`）：
  - 结构：`TEXV0005` / `TEXI0001` 头，`TEXB0001-0004` 图像容器，每个 mip 可能经过 LZ4 压缩
  - 格式：RGBA8888、DXT1/3/5、RG88、R8，或内嵌图片（交给 ImageIO）
  - flags：4 = 精灵图（`TEXS` 帧表）、32 = 内嵌 MP4 视频

## 场景渲染管线（`Engine/Scene`）

1. **加载**：`SceneLoader.load(Request)`，在后台执行。
   - `SceneDocument`：解析 `scene.json`，把用户属性绑定解到 `SceneValues`。
   - 对象并发构建（`concurrentPerform`），每个对象是图片层、粒子层或文本层之一。
   - 材质 → `MaterialPass` → `SceneShaderLibrary` 编译：
     - `WEShaderPreprocessor`：处理 include 和 `#if`，combo 写成 `#define`。
     - `WEShaderTranslator`：GLSL/HLSL 风格源码 → MSL。整段着色器包进 C++ struct，uniform 打包成 float4 槽，HLSL 的隐式截断用 `we_vecN()` 辅助函数处理。
     - 编译结果按「源码 + combos」缓存；并发请求同一个着色器时去重。
   - 纹理：`SceneTextureCache`（去重，GPU blit 上传，生成 mipmap）。视频纹理用 AVPlayer + CVMetalTextureCache。
2. **每帧**：`SceneInstance.encode(into:frame:)`。
   - 计算对象状态：关键帧动画 → 脚本覆盖 → 父级传递（可见性、透明度）→ 世界矩阵。
   - 每个图片层：基础材质画进 FBO → 特效 ping-pong（具名 FBO、bind/copy 命令）→ 按材质混合模式合成到场景纹理。
   - 粒子：CPU 模拟（`SceneParticles.swift`），用 WE 的 genericparticle 着色器绘制。
   - 文本：Core Text 按 300 dpi 光栅化（`SceneText.swift`），内容变化时才重画。
   - 脚本：`SceneScript.swift` 在 JavaScriptCore 里跑 WE 的 SceneScript，每帧返回被改动的图层。
   - `_rt_FullFrameBuffer`：需要时从场景纹理 blit 一份。
3. **呈现**：`SceneRenderer`（MTKView）。
   - 场景先按画布比例画到 rgba8 离屏纹理：覆盖屏幕的原生像素，上限为画布尺寸，再受像素预算限制（`SceneLoader.renderSize`）。纹理按同样的比例选 mip，不会被砍到比显示还小。
   - 再按 framing 缩放到屏幕；显示得比渲染大时用 Catmull-Rom 采样（`presentSharp`），否则双线性。
   - 窗口被遮挡时不绘制。
   - 支持鼠标视差，并把指针坐标换算到画布坐标。

## 调试启动参数（仅 Debug 构建）

| 参数 | 作用 |
|---|---|
| `-LumenDebugRoute wallpaper:<uuid>` / `studio:<uuid>` / `playlists` | 启动后直接打开某页 |
| `-LumenDebugImport <folder,folder>` | 启动时导入 WE 项目文件夹 |
| `-LumenDebugApply <title>` | 把指定标题的壁纸设为桌面（**测试后记得还原**） |
| `-LumenDebugSteam YES` | 启动时打开 Steam 面板 |
| `-LumenDebugMenuPreview YES` | 在普通窗口里显示菜单栏面板 |
| `SceneLoader.debugLayerFilter` | 只加载指定对象 id（`Tools/test.sh scenes <id> <time> <object ids>`） |
