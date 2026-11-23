# Lumen · 进度与任务板

> 所有助手共同维护。开工前读，收工时更新（规则见 [`AGENTS.md`](../AGENTS.md)）。
> 最后更新：2026-11-23 · gpt

## 1. 阶段进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 视频壁纸（MP4/MOV，HEVC 优化）、Metal 着色器壁纸 + Studio 编辑器、多显示器、自动暂停、菜单栏面板 | ✅ 已提交（`fed0b5f`、`57169f6`） |
| 2 | 锁屏视频、画面裁切（framing）、遮挡阈值、简体中文本地化 | ✅ 已提交（`509c56d`、`0af720e`） |
| 3 | Web 壁纸（本地 HTML / 网址，WE web 项目属性 API） | ✅ 已提交（`23d33aa`） |
| 4 | Wallpaper Engine 场景壁纸 + Steam 创意工坊下载 | 🟡 主体已提交（`23d33aa`）；缺口见任务板 |
| 5 | 全局 UI 打磨 + 补翻译 | ⏳ 等功能全部完成后进行 |

## 2. 功能现状

**已可用**

- **视频**：AVPlayerLayer 硬解，同一视频多屏共享解码器，可一键转 HEVC。
- **着色器**：6 个内置 + 用户自写，按像素预算和帧率上限渲染。
- **Web**：
  - WKWebView 加 `lumen-web://` 本地协议，支持 Range 请求；每个壁纸独立数据存储。
  - 支持 WE 属性监听 `wallpaperPropertyListener`，鼠标事件转发到页面。
  - 暂停时显示快照并挂起渲染。
- **WE 场景**：
  - 支持：图片层、大部分特效（WE 原版 GLSL 运行时翻译为 MSL）、粒子、精灵图动画、视频纹理、关键帧动画、文本层（时钟/日期）、SceneScript（JavaScriptCore）、音效、鼠标视差、用户属性面板。
  - 场景需要 WE 的共享 assets 文件夹，会自动从 WallpaperMachine 找到；也可在「设置 › Wallpaper Engine」里指定。
- **创意工坊**：
  - Workshop 页扫描 Steam 下载目录、WallpaperMachine 库和自定义文件夹，一键加入资源库。
  - 支持 Steam 下载：通过 SteamCMD 用用户自己的账号登录，支持 Steam Guard 和手机确认；也可以在内置 Workshop 浏览器里点「Download to Lumen」。

**回归基线**（2026-11-23，`Tools/test.sh`，语料为 WallpaperMachine 库，75 个场景）

| 项目 | 基线 |
|---|---|
| 场景加载/渲染 | 75/75 OK，0 FAIL |
| 加载耗时（着色器缓存命中） | 中位 0.35s，最大 1.43s |
| GPU 帧时间（约 2MP） | 中位 4.4ms，p90 8.3ms（单测 3808922316 为 14.3ms） |
| 着色器翻译 + 编译 | 300/316 通过（失败集中在 3D 光照、体积光和少数工坊自带着色器） |
| 明显洋红色块 | 0 个（3808922316 洋红块、2983846453/3615984066/3397287008 白/灰块均已修复） |
| SteamCMD 提示解析（假 steamcmd） | 通过 |

## 3. 任务板

状态：待认领 / 进行中 / 待验证 / 完成。认领时把「负责」改成你的身份。

| ID | 任务 | 模块 | 优先级 | 状态 | 负责 | 备注 |
|---|---|---|---|---|---|---|
| T01 | 提交阶段 3/4 的改动 | 全局 | 高 | 完成 | claude | `23d33aa` |
| T02 | 木偶变形（puppet warp）：MDL 解析、骨骼蒙皮（genericimage4 `SKINNING` / `g_Bones`）、animationlayers、MDL 内嵌裁剪蒙版（`clippingmaskimage4`） | 场景 | 高 | 待认领 | | 语料中 139 处使用（含 6 个场景的 `*_puppet.mdl` 眼部/部件裁剪蒙版）；目前角色静止不动 |
| T03 | 图层裁剪蒙版（clipping masks） | 场景 | 高 | 完成 | gemini | 已合并 `main`：跨层合成目标 `_rt_imageLayerComposite_*`、链式 `colorBlendMode` 最终合成、目标清空同步、`startpaused` 及相关着色器翻译修复；3808922316/3615984066/3397287008/2983846453 均已修复 |
| T04 | 音频响应：系统音频频谱（`g_AudioSpectrum*`、脚本 audio buffer） | 场景/Web | 中 | 待认领 | | 需要系统音频采集（Core Audio tap 或 ScreenCaptureKit），注意权限和能耗 |
| T05 | 场景/Web 壁纸的锁屏：录一段循环视频交给 `LockScreenVideoBuilder` | 锁屏 | 中 | 待认领 | | 现在保留上一个视频锁屏（`.keepingPrevious`） |
| T06 | SceneScript 鼠标事件（cursorClick/Down/Up/Move 等） | 场景 | 中 | 待认领 | | |
| T07 | 片头/时间线类场景（如 3436945972），以及 3463692991 的布局问题 | 场景 | 中 | 待认领 | | |
| T08 | 3D 模型与光照（`PerformLighting_V1`）、体积光 | 场景 | 低 | 待认领 | | 对应 18 个编译失败的着色器中的大部分 |
| T09 | 为解析器补 XCTest：pkg、tex、project.json、着色器预处理、SteamCMD 输出 | 测试 | 中 | 完成 | gpt | `gpt/T09-parser-tests` 上 14 项 XCTest 全部通过，运行 `Tools/test.sh unit` |
| T10 | 真实 Steam 登录和下载的端到端验证 | Steam | 中 | 待认领 | 需用户 | 必须用户本人登录，助手不得代输密码 |
| T11 | 新界面文案翻译（Workshop、Steam 面板、WE 设置、属性面板、添加网页） | UI | 低 | 待认领 | | 放到阶段 5 |
| T12 | 全局 UI 打磨 | UI | 低 | 待认领 | | 等功能完成后再做（用户要求） |
| T13 | 处理 `DesktopHost` 转场回调的 Swift 并发警告 | 引擎 | 低 | 待认领 | | 构建时提示 `@Sendable` 闭包捕获了非 Sendable 的 `previous` |

不做：WE 的 application 类型（只能在 Windows 上运行）。

## 4. UI 规则（用户定的）

- 观感以 Wallper 为基准，但要有自己的识别度，不照抄。
- 「高级感」的展示标题和眉标保留英文，例如 "Your desktop, in motion."、"Smart pause"、"LIBRARY"。
- 设置、按钮、菜单、状态、提示、错误和说明性副标题都翻译成 zh-Hans。
- 用户的 macOS 是英文系统；要看中文，在 app 内切换语言，或用 `-AppleLanguages "(zh-Hans)"` 启动。

## 5. 交接日志（新的写在最上面）

### 2026-11-23 · gpt · `gpt/T09-parser-tests`（改动在独立工作树）

- 完成 T09。新增独立的 `LumenTests` target 和 scheme，复用生产解析器源码。测试覆盖 pkg 文件表和查找顺序、tex mip/LZ4/精灵图、project.json 元数据和属性、着色器条件与 include、SteamCMD 提示和结果解析。
- `Tools/test.sh unit` 14 项全部通过，`Tools/test.sh build` 通过。构建脚本现在传递 Xcode 的失败退出状态。测试使用临时夹具和本地模拟 SteamCMD，应用运行时代码未改，无新增渲染和能耗开销。
- T09 已验证。改动尚未提交，待用户决定是否提交和合并。构建中发现的既有并发警告记为 T13。

### 2026-11-23 · gemini · `gemini/T03-clipping-masks`（已合并 `main`）

- **做了什么**：
  - 完成 **T03（图层裁剪蒙版与洋红/白块修复）**：
    - **跨层合成目标（`_rt_imageLayerComposite_<id>_a/b`）**：`SceneLoader` 预扫描跨层目标引用，保留作为来源的 `composelayer`（即使无特效或自身 `visible: false`，如 `2983846453` 图层 89、`3808922316` 主题 2 边框捕获层）；`SceneInstance` 新增 `.layerComposite(Int)` 并在每帧捕获后供下游 `clipping_mask` / `blend` 特效采样。
    - **链式图层 `colorBlendMode` 最终合成**：带特效链或纯色图层不再把 `BLENDMODE` 编进 Pass 0（避免把整张场景画进局部 FBO 并导致 `3808922316` 出现整屏重影、`3615984066` 无法 Additive 混合），改为在特效链结束后通过 `genericimage4` 最终合成。同时 `PreparedPass.usesFrameBuffer` 改为只检查已编译活跃 sampler，减少无谓全帧 blit。
    - **私有 Render Target 同步清零**：`SceneInstance.clearTargets` 改为在传入的渲染队列上执行并 `waitUntilCompleted()`，彻底消除 `motionblur` 首帧读到未初始化 GPU 显存产生的随机洋红色块（`3808922316`）。
    - **`SceneAnimation` 支持 `startpaused`**：标记 `startpaused: true` 的动画停留在第 0 帧，消除 `3397287008`、`3354881783`、`3478434536` 等场景中媒体未播放时残留的专辑封面灰/白方块。
    - **`WEShaderTranslator` HLSL 兼容补齐**：支持 1D 标量数组二维索引（`g_AudioSpectrum64Left[i/4][i%4]`）、向量返回值隐式截断、`mix` 混合宽向量重载、以及未读写 `.z/.w` 的 `vec4 v_TexCoord` 窄化，修复 `3615984066`（`video.frag`）和 `2983846453`（`clipping_mask.frag`）。
  - **性能/能耗评估**：仅对被引用为跨层来源的隐藏/透传图层保留离屏缓冲（父级不可见时不绘制）；移除 `genericimage4` 未启用反射/混合时的冗余全帧拷贝后，`3615984066` GPU 耗时由 5.0ms 降至 3.2ms、`3397287008` 由 4.1ms 降至 2.7ms；全库 75/75 OK，加载中位 0.35s。
  - **验证**：`Tools/test.sh build` 通过；`Tools/test.sh shaders` 提升至 300/316；`Tools/test.sh scenes` 75/75 OK、0 FAIL、0 洋红块；肉眼抽检 `3808922316`、`3615984066`、`3397287008`、`2983846453`、`3354881783`、`3478434536` PNG 均正常。
- **没做完**：
  - 6 个场景的木偶 `.mdl` 内嵌部件裁剪蒙版（`clippingmaskimage4` + `materials/masks/clipping_mask_*.tex`）依赖 MDL 二进制解析，已归并备注到 **T02**。
  - 改动尚在 `gemini/T03-clipping-masks` 工作区未提交（等用户确认后 commit/合并）。
- **建议下一步**：确认 T03 改动是否提交并合并到 `main`，然后按计划推进 **T02（木偶变形：MDL 解析、骨骼蒙皮、animationlayers 与 MDL 裁剪蒙版）**。

### 2026-11-23 · claude · `main`：`23d33aa`（代码）+ 文档提交

- **做了什么**：
  - 完成阶段 3（Web 壁纸）和阶段 4 主体（WE 场景渲染器、Workshop 页、SteamCMD 下载、属性面板、WE 设置页）。
  - 把回归工具迁入 `Tools/`。
  - 建立本协作文档：`AGENTS.md`、`docs/`。
- **没做完**：任务板 T02–T11。
- **注意**：
  - 测试时导入的壁纸已清理。资源库里现有的 WE 项目是用户自己导入的，不要删。
- **建议下一步**：用户打算让 Gemini 接手剩余工作。建议先做 T03（裁剪蒙版）：范围最小，回归工具能直接看到洋红块是否消失。之后再做 T02（木偶）。两者都改 `SceneLoader` 和 `SceneInstance`，不要并行做。
