# Lumen · 进度与任务板

> 所有助手共同维护。开工前读，收工时更新（规则见 [`AGENTS.md`](../AGENTS.md)）。
> 最后更新：2026-11-23 · claude（合并 T17 / T21 / T22 / T23 / T25）

## 1. 阶段进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 视频壁纸（MP4/MOV，HEVC 优化）、Metal 着色器壁纸 + Studio 编辑器、多显示器、自动暂停、菜单栏面板 | ✅ 已提交（`fed0b5f`、`57169f6`） |
| 2 | 锁屏视频、画面裁切（framing）、遮挡阈值、简体中文本地化 | ✅ 已提交（`509c56d`、`0af720e`） |
| 3 | Web 壁纸（本地 HTML / 网址，WE web 项目属性 API） | ✅ 已提交（`23d33aa`） |
| 4 | Wallpaper Engine 场景壁纸 + Steam 创意工坊下载 | ✅ 主体完成（木偶、裁剪蒙版、组合层、音频、鼠标事件、3D 光照等已合并）；Steam 实际登录未通 |
| 6 | **通用问题与可用性**：锁屏免手动、鼠标输入、原生 Steam 扫码登录、通用还原度、能耗 | 🔵 进行中，计划见 [`PLAN.md`](PLAN.md) |
| 7 | 发布准备：签名、公证、自动更新 | ⏳ |
| 5 | 全局 UI 打磨 + 补翻译 | ⏳ 放到最后（用户要求） |

## 2. 功能现状

**已可用**

- **视频**：AVPlayerLayer 硬解，同一视频多屏共享解码器，可一键转 HEVC。
- **着色器**：6 个内置 + 用户自写，按像素预算和帧率上限渲染。
- **Web**：
  - WKWebView 加 `lumen-web://` 本地协议，支持 Range 请求；每个壁纸独立数据存储。
  - 支持 WE 属性监听 `wallpaperPropertyListener`，鼠标事件转发到页面。
  - 暂停时显示快照并挂起渲染。
- **WE 场景**：
  - 支持：图片层、大部分特效（WE 原版 GLSL 运行时翻译为 MSL）、木偶变形（`.mdl` 网格/骨骼蒙皮/`animationlayers`/骨骼附着/内嵌裁剪蒙版）、跨层裁剪蒙版、粒子、精灵图动画、视频纹理、关键帧动画、文本层（时钟/日期）、SceneScript（JavaScriptCore）、音效、鼠标视差、用户属性面板。
  - 场景需要 WE 的共享 assets 文件夹，会自动从 WallpaperMachine 找到；也可在「设置 › Wallpaper Engine」里指定。
- **创意工坊**：
  - Workshop 页扫描 Steam 下载目录、WallpaperMachine 库和自定义文件夹，一键加入资源库。
  - 支持 Steam 下载：通过 SteamCMD 用用户自己的账号登录，支持 Steam Guard 和手机确认；也可以在内置 Workshop 浏览器里点「Download to Lumen」。

**回归基线**（2026-11-23 合并 T17/T21/T22/T23/T25 后，`Tools/test.sh`，默认 Balanced 预算 6MP、2560×1600 屏，语料为 WallpaperMachine 库，75 个场景）

| 项目 | 基线 |
|---|---|
| 场景加载/渲染 | 75/75 OK，0 FAIL |
| 加载耗时（着色器缓存命中） | 中位 0.46s，最大 1.4s |
| GPU 帧时间（原生约 4.7MP） | 中位 4.3ms，p90 9.5ms，最大约 16ms（3808922316 全量跑时偶发 25.8ms，单独重跑 15–16ms，属测量噪声） |
| 着色器翻译 + 编译 | 316/316 通过 |
| 明显洋红色块 | 0 个（3808922316 洋红块、2983846453/3615984066/3397287008 白/灰块均已修复） |
| SteamCMD 提示解析（假 steamcmd） | 通过 |
| 单元测试（`Tools/test.sh unit`） | 40/40 通过 |

## 3. 任务板

状态：待认领 / 进行中 / 待验证 / 完成。认领时把「负责」改成你的身份。

| ID | 任务 | 模块 | 优先级 | 状态 | 负责 | 备注 |
|---|---|---|---|---|---|---|
| T01 | 提交阶段 3/4 的改动 | 全局 | 高 | 完成 | claude | `23d33aa` |
| T02 | 木偶变形（puppet warp）：MDL 解析、骨骼蒙皮（genericimage4 `SKINNING` / `g_Bones`）、animationlayers、MDL 内嵌裁剪蒙版（`clippingmaskimage4`） | 场景 | 高 | 完成 | gemini | 已合并 `main`（`ca5ee70`）：MDL 网格、骨骼蒙皮、animationlayers、MDL 内嵌裁剪蒙版；Chisa 眼睛错位已修复。未做：`MORPHING` |
| T03 | 图层裁剪蒙版（clipping masks） | 场景 | 高 | 完成 | gemini | 已合并 `main`：跨层合成目标 `_rt_imageLayerComposite_*`、链式 `colorBlendMode` 最终合成、目标清空同步、`startpaused` 及相关着色器翻译修复；3808922316/3615984066/3397287008/2983846453 均已修复 |
| T04 | 音频响应：系统音频频谱（`g_AudioSpectrum*`、脚本 audio buffer） | 场景/Web | 中 | 待验证 | claude | 已合并 `main`（`cc2990e`）。需用户授权「录制系统音频」后用真实音乐验收手感 |
| T05 | 场景/Web 壁纸的锁屏：录一段循环视频交给 `LockScreenVideoBuilder` | 锁屏 | 中 | 待验证 | claude | 已合并 `main`（`e079a73`）：场景离屏录 30 秒、网页快照录 12 秒做锁屏循环。待用户开启锁屏实测 |
| T06 | SceneScript 鼠标事件（cursorClick/Down/Up/Move 等） | 场景 | 中 | 完成 | gpt | 已合并 `main`（`144ffe7`）：2D 图层六种鼠标事件 |
| T07 | 片头/时间线类场景（如 3436945972），以及 3463692991 的布局问题 | 场景 | 中 | 完成 | gemini | 已合并 `main`（`328e04c`）。分支 `gemini/T07-timeline-and-layout`：实现 `thisScene.destroyLayer` 与帧时钟 `setTimeout`/`clearTimeout`；支持二选一开/关下拉框直绑布尔与嵌套用户属性回退；实现文本层 `limitwidth`/`limitrows`/省略号自动换行、对齐锚点偏移及 4096 纹理缩放一致性修复。3436945972 片头淡出与视差开关、3463692991/2867182492 文本布局均已修复 |
| T08 | 3D 模型与光照（`PerformLighting_V1`）、体积光 | 场景 | 低 | 完成 | gpt | 已合并 `main`（`c0a0e7f`）。`gpt/T08-scene-lighting`。静态单网格、点光照与正交点光体积通过应用预览和真实桌面验证，已提交 |
| T09 | 为解析器补 XCTest：pkg、tex、project.json、着色器预处理、SteamCMD 输出 | 测试 | 中 | 完成 | gpt | 已合并 `main`（`3f51c54`）：14 项 XCTest，`Tools/test.sh unit` |
| T10 | 真实 Steam 登录和下载的端到端验证 | Steam | 中 | 待认领 | 需用户 | 必须用户本人登录，助手不得代输密码 |
| T11 | 新界面文案翻译（Workshop、Steam 面板、WE 设置、属性面板、添加网页） | UI | 低 | 待认领 | | 放到阶段 5 |
| T12 | 全局 UI 打磨 | UI | 低 | 待认领 | | 等功能完成后再做（用户要求） |
| T13 | 处理 `DesktopHost` 转场回调的 Swift 并发警告 | 引擎 | 低 | 完成 | gpt | 已合并 `main`（`08045c9`） |
| T14 | 组合层（composelayer）分组：子图层先画进父组合层的缓冲（`copybackground` 缺省为 true，先拷贝背景），再跑父层特效、按父层混合合成；子图层不再直接画到场景 | 场景 | 高 | 完成 | gemini | 已合并 `main`（`d8663af`）：组合层子图层画进父层缓冲，支持 `copybackground`；「清风」背景字列已正常 |
| T15 | 场景用户属性绑定的类型转换 | 场景 | 高 | 完成 | gpt | 已合并 `main`（`89373a8`）：直接绑定到布尔字段时数字按非零、字符串按非空；「清风」白色底图已恢复 |
| T16 | 场景清晰度：渲染分辨率按屏幕实际像素覆盖、上限为画布尺寸；低于屏幕时用 MetalFX 空间放大（`MTLFXSpatialScaler`）代替双线性；详情页预览预算提高；纹理上限跟随屏幕 | 场景 | 高 | 待验证 | claude | 已合并 `main`（`7303cc0`）：原生分辨率渲染、纹理不再砍半、放大用 Catmull-Rom。待用户在桌面上看效果 |
| T17 | 场景视觉回归：回归工具把渲染结果和作者预览图（preview.gif/jpg 首帧）做感知相似度打分，输出最差的 N 个场景和对比拼图 | 测试 | 中 | 完成 | gpt | 已合并 `main`（`1ea4e5b`）。`Tools/test.sh visual [N]`：0–100 相似度排序，输出 JSON 与最差 N 张对比拼图 |
| T18 | SceneScript 动画控制：`layer.getAnimation()` 的 `play/pause/stop/isPlaying`，配合 `startpaused` 关键帧动画 | 场景 | 低 | 完成 | gpt | 已合并 `main`（`640bb08`）。`gpt/T18-scene-animation-control`。具名及绑定属性时间线支持播放控制，共用轨道同步。23 项 XCTest 和 75/75 场景通过 |
| T19 | 修复仍编译失败的 10 个工坊特效着色器（翻译层）：数组初始化、`clamp` 歧义、向量隐式截断、`sample`/`currentColor` 等未声明标识符、宏展开语法 | 场景 | 中 | 完成 | claude | 已合并 `main`（`a5b0c5e`）：10 个工坊特效能编译 |
| T20 | 3347416586（海边摩托）画面上有大片白色「裂纹」图层，作者预览里没有：查明是哪层、为什么可见（可能是条件可见、遮罩或混合模式） | 场景 | 中 | 完成 | gemini | 随 T25 合并：离屏 Pass 0 投影没缩放 Z，木偶骨骼 Z 偏移被深度裁剪出空洞。属共性缺陷，已统一修复 |
| T21 | 锁屏改为写 Desktop 选择（免去系统设置里手动选），协调 StillFrameSync，扩展备份/恢复 | 锁屏 | 高 | 待验证 | gemini | 已合并 `main`（`1654110`）：同时写 Desktop/Idle 全部容器，新增「也用作屏保」开关，关闭时按备份原样恢复；锁屏开启时主屏不再写静态图。待用户开锁屏后按 `⌃⌘Q` 目测 |
| T22 | 鼠标输入管线：位置改为轮询、按需开启；补 `g_EffectTextureProjectionMatrix`；核对坐标系 | 场景/Web | 高 | 待验证 | gemini | 已合并 `main`（`0eba484`）：只在有交互壁纸播放时按帧率轮询（≤60Hz，静止时跳过）；补特效投影矩阵及逆矩阵，`g_ParallaxPosition` 改为 [0,1] 居中。待用户在桌面实测鼠标跟随 |
| T23 | 原生 Steam 客户端：扫码登录（钥匙串存 token）+ CM/CDN 下载创意工坊；先改好 SteamCMD 的错误分类和重试 | Steam | 高 | 待验证 | gpt | 已合并 `main`（`72b575b`）：Steam 面板二维码登录、CM/CDN 下载与校验；SteamCMD 分类报错并对网络失败重试。新增 SPM 依赖 zstd 1.5.7。待用户网络可达时扫码实测 |
| T25 | 通用场景还原度：用 T17 报告和「不支持特性统计」找影响面最大的共性问题，逐类修 | 场景 | 中 | 完成 | gemini | 已合并 `main`（`6135397`）：离屏/组合层 Z 深度映射、`rope`/`ropetrail` 粒子、场景全局 bloom、最后一个着色器。着色器 316/316 |
| T26 | 能耗与稳定：按 GPU 实测自适应分辨率、指针/音频按需、加载失败与内存压力降级 | 引擎 | 中 | 待认领 |  | 未分配 |
| T27 | 发布准备：Developer ID 签名、公证、Hardened Runtime、自动更新、开机启动 | 发布 | 中 | 待认领 |  | 未分配；在 UI 打磨之前 |

**2026-11-23 claude 补充（给 T02）**：「[Chisa]Autumn and temple」（库里 EDF506EA…）的 `02眼组` 是木偶模型，贴图是眼白/瞳孔/闭眼的拼图，必须按 `02眼组_puppet.mdl` 里的网格顶点和 UV 去画；**哪怕先只画静止网格、不做骨骼动画，眼睛错位也会消失**，建议 T02 先交付这一步。

不做：WE 的 application 类型（只能在 Windows 上运行）。

## 4. UI 规则（用户定的）

- 观感以 Wallper 为基准，但要有自己的识别度，不照抄。
- 「高级感」的展示标题和眉标保留英文，例如 "Your desktop, in motion."、"Smart pause"、"LIBRARY"。
- 设置、按钮、菜单、状态、提示、错误和说明性副标题都翻译成 zh-Hans。
- 用户的 macOS 是英文系统；要看中文，在 app 内切换语言，或用 `-AppleLanguages "(zh-Hans)"` 启动。

## 5. 交接日志（新的写在最上面）

### 2026-11-23 · claude · 合并第 6 阶段到 `main`

- 先在各自分支上提交未提交的改动：T21 `1654110`、T22 `0eba484`、T25 `6135397`、T23 `72b575b`；T17 已由 gpt 提交（`1ea4e5b`）。
- 依次合并 T17、T21、T22、T25、T23 到 `main`。只有 `project.pbxproj` 冲突（T21 和 T23 都改了 `project.yml`），按约定重新 `xcodegen generate`。T22 与 T25 都改了 `SceneInstance`/`SceneParticles`，自动合并无冲突。
- 验证：build 通过（首次需要拉取 SPM 依赖 zstd）；`unit` 40/40（新增 5 项锁屏、10 项 Steam）；`shaders` 316/316；`scenes` 75/75、0 洋红；`steam` 通过。3808922316 在全量跑时 GPU 25.8ms，单独重跑 15–16ms，与 T25 分支一致，属噪声。
- 待用户实测：T21 锁屏（开启后不再需要去系统设置里手动选）、T22 鼠标跟随、T23 扫码登录（需 Steam 网络可达）。T05 需要随 T21 重新验收。
- 下一步：按用户实测反馈分派；T26（能耗）、T27（发布）仍未分配。

### 2026-11-23 · gemini · `gemini/T25-scene-fidelity`（已合并 `main`）

- **做了什么**：
  - 先对全库 75 个场景做特性普查（发现：0 个场景用 `MDLM` morphing；25 个用木偶骨骼；16 个场景共 24 个可见层用 `rope`/`ropetrail` 粒子；7 个用全局 `general.bloom`；仅剩 1 个着色器编译失败 `puppettexturechannels`），并结合 T17 视觉回归报告（75/75 评分）定位了 **4 类影响面最大的共性问题**，全部改动在 `build/worktrees/gemini-T25`（分支 `gemini/T25-scene-fidelity`，基于 `main` `e79429e`）：
    1. **离屏 Pass 0 与 `composelayer` 组投影 Z 深度裁剪修复（`SceneInstance.swift`）**：
       - 原 `encodeChain` Pass 0 与 `groupVP` 使用 `SceneMath.scale(SIMD2(...))`（`zScale = 1`），导致任何具有非零局部 Z（`|z| > 1`）的木偶骨骼顶点或 3D 倾斜子层被 Metal 深度平面裁剪出空洞。
       - 新增 `SceneMath.localOrthographic(center:size:)`（`zScale = -0.0001`，与 `orthographic` 一致，经翻译层 `(z + w) * 0.5` 映射 `[-10000, 10000]` 至 Metal `[0, 1]`）。
       - **一并查实并解决 T20（`3347416586` 海边摩托）**：所谓「白色裂纹层」实为 `SunFragment4_1_puppet.mdl` 骨骼 24 位移至 `z = -529.57` 被裁剪出大片空洞、露出 `0.7` 灰色 `clearcolor`；修复后整片夕阳海面、波浪、镜头光晕完整恢复。
    2. **`rope` 与 `ropetrail` 粒子渲染器（`SceneParticles.swift`、`SceneLoader.swift`、`SceneInstance.swift`）**：
       - 覆盖 16 个场景共 24 个此前完全不可见的流星/拖尾/闪电/轨迹粒子层。
       - `ropetrail` 区分于 `spritetrail`：按 `duration` 秒数与粒子速度/年龄计算实际世界尾长（不被 `particle.size` 重复放大，修复 `3652110998`/`3613963197` 过长光线），从粒子头部向后延伸并尾部平滑淡出；`rope` 连接相邻存活粒子形成连续丝带，并规避零速度 `NaN`。
    3. **场景全局 `general.bloom` 后处理（`SceneDocument.swift`、`SceneInstance.swift`）**：
       - 解析 `bloom`、`bloomstrength`、`bloomthreshold`、`bloomtint`（支持用户属性绑定）。
       - 仅在 `bloomEnabled && bloomStrength > 0.001` 的 7 个场景上分配两张 1/4 分辨率 `.rgba16Float` 纹理，执行软阈值亮部提取 → 水平/垂直 9-tap 可分离高斯模糊 → 加法合成；其余 68 个场景零内存、零 GPU 开销。
    4. **最后 1 个着色器编译失败修复（`WEShaderTranslator.swift`）**：
       - `WEUniform` 新增 `isArray` 标记，保留符号长度数组（如 `g_BlendMap[BLENDROWCOUNT]` 缺省为 `1` 时仍声明为数组）；`wrapAssignments` 扩展支持 `*=` 和 `/=`（修复 `puppettexturechannels.frag` 的 `albedo.rgb *= g_Color4 * ...`）。
       - 着色器编译通过率从 315/316 提升至 **316/316（100%）**。
  - **性能/能耗评估**：
    - `localOrthographic` 零额外开销；
    - `rope`/`ropetrail` 复用现有粒子顶点缓冲和 `genericparticle` 管线，无新增 pass；
    - `bloom` 仅在开启 bloom 的 7 个场景运行 1/4 分辨率 4 pass（约 +0.3ms），68 个非 bloom 场景完全跳过；全库 75 场景 GPU 中位 4.81ms、p90 10.75ms、最大 17.11ms（持平基线）。
  - **验证**（均在 `build/worktrees/gemini-T25` 中执行）：
    - `Tools/test.sh build`：**BUILD SUCCEEDED**
    - `Tools/test.sh unit`：**25/25** 通过（持平基线）
    - `Tools/test.sh shaders`：**316/316（0 失败，100%）**
    - `Tools/test.sh scenes`：**75/75 OK，0 FAIL，0 洋红**（加载中位 0.42s / 最大 1.39s；GPU 中位 4.81ms / p90 10.75ms / 最大 17.11ms）
    - **视觉抽检**：`3347416586`（海边摩托）海面完全恢复无灰白空洞；`3652110998`、`3613963197`、`3356432625` 流星拖尾长度与尾端淡出自然；`3690417937`、`3000562427` 全局泛光柔和无过曝。
- **没做完**：
  - 改动在独立工作树 `build/worktrees/gemini-T25`（分支 `gemini/T25-scene-fidelity`），按约定未 commit/merge。
  - 合并提示：T22 与 T25 均改了 `SceneInstance.swift`（T22 在 `usesPointer` 和 `effectTextureProjection`，T25 在 `bloomTargets`、`localOrthographic` 和 `encodeParticles`），以及 `SceneParticles.swift`（T22 加了 `usesPointer`，T25 加了 `.rope`/`.ropeTrail`），位置基本不重叠，合并时两边保留即可。

### 2026-11-23 · gemini · `gemini/T22-pointer-input`（已合并 `main`）

- **做了什么**：
  - 完成 **T22（鼠标输入管线）**，改动位于独立工作树 `build/worktrees/gemini-T22`（分支 `gemini/T22-pointer-input`，基于 `main` `e79429e`）：
    1. **轮询 + 按需开启（`DesktopPointerMonitor.swift`、`WallpaperEngine.swift`、`WebRenderer.swift`、`SceneRenderer.swift`、`SceneInstance.swift`、`SceneMaterials.swift`、`SceneParticles.swift`、`SceneScript.swift`）**：
       - `DesktopPointerMonitor` 位置改为按渲染帧率（`pollRate` 限制在 `15...60 Hz`）定时轮询 `NSEvent.mouseLocation`，解决鼠标停在桌面或 `ignoresMouseEvents` 窗口上方时 macOS 不再派发全局 `mouseMoved` 的问题；位置未变时直接短路跳过命中判断与 `CGWindowListCopyWindowInfo`，全局/本地监听负责唤醒与点击转发；支持按 `activeDisplayIDs` 跳过无需指针的显示器。
       - 扩展 `PointerAwareRenderer` 协议增加 `needsPointer` 与 `onPointerNeedChange`，`WallpaperEngine.reconcile()` 仅在有正在播放且 `needsPointer == true` 的壁纸时才开启轮询。
       - 场景按需判定（`SceneInstance.usesPointer`）覆盖：视差开关、`g_PointerPosition`/`g_PointerPositionLast`/`g_ParallaxPosition` uniform、cursor 脚本回调或 `input.cursor*` 读取、以及锁定鼠标的粒子控制点。
       - 网页按需判定（`WebBridgeScript`）拦截 `EventTarget.prototype.addEventListener` 鼠标/指针事件类型并扫描 `onmouse*`/`onpointer*`/`onclick` 句柄，注册后才开启轮询。
    2. **补全 `g_EffectTextureProjectionMatrix` 及其逆矩阵，并核对坐标系（`SceneInstance.swift`、`SceneMaterials.swift`、`SceneRenderer.swift`、`RenderedLoopRecorder.swift`、`Tools/SceneHarness/main.swift`）**：
       - 计算每层的真实特效贴图投影矩阵 `screenViewProjection * model * translation(chainCenter) * scale(chainSize / 2)` 及其安全逆矩阵（即使位于 `composelayer` 子分组内也投影至屏幕 NDC），写入 `DrawState` 并填充至 `g_EffectTextureProjectionMatrix` / `g_EffectTextureProjectionMatrixInverse`。
       - 核对 WE 原版 `cursorripple`、`fluidsimulation`、`xray`、`iris_follow_cursor`、`iris_movement__`、`dot_matrix` 与 `depthparallax` 着色器：确认 `g_PointerPosition` 为左上角原点 `[0, 1]^2`（完全一致），同时修复 `g_ParallaxPosition` 此前以 `(0, 0)` 为中心偏移过小的错误，改为 `[0, 1]^2` 左下角原点、以 `(0.5, 0.5)` 为中心的平滑指针位置（与 `depthparallax.vert` 一致），并同步更新离屏录屏与回归工具默认帧值。
  - **跨模块接口改动**：`PointerAwareRenderer` 新增 `var needsPointer: Bool { get }` 和 `var onPointerNeedChange: (() -> Void)? { get set }`（仅 `SceneRenderer`、`WebRenderer` 实现）。
  - **性能/能耗评估**：非交互壁纸或暂停状态下轮询定时器与事件监听完全关闭（零 CPU/零唤醒）；交互壁纸播放且指针静止时每帧仅做一次 `NSEvent.mouseLocation == lastLocation` 比较（微秒级），不做窗口查询；`effectTextureProjection` 仅对当前可见图层每帧算一次 4×4 矩阵乘与求逆，实测 75 场景 GPU 中位 4.67ms、p90 8.98ms（与基线持平）。
  - **验证**（均在 `build/worktrees/gemini-T22` 中执行）：
    - `Tools/test.sh build`：**BUILD SUCCEEDED**
    - `Tools/test.sh unit`：**25/25** 通过（持平基线）
    - `Tools/test.sh shaders`：**315/316** 通过（持平基线）
    - `Tools/test.sh scenes`：**75/75 OK，0 FAIL，0 洋红**（加载中位 0.42s、最大 1.36s；GPU 中位 4.67ms、p90 8.98ms、最大 16.35ms）
    - **专项验证**：`3287715210`（`iris_follow_cursor`，`usesPointer=true`，左右/上下指针变化 ~2.25 万像素）、`3463692991`（`iris_movement__`，`usesPointer=true`，眼球跟随移动）、`3373818743`（`depthparallax` + `cursorripple` + 视差，上下/左右均响应）、`3436945972`（跳过片头后视差显著响应）、`3821868213`（无交互，`usesPointer=false` 不轮询）；`WebRenderer` 监听 `mousemove` 页面 `needsPointer=true` 并准确收到 `[[123, 45]]`，静态页面保持 `needsPointer=false`。
- **没做完**：
  - 改动在独立工作树 `build/worktrees/gemini-T22`（分支 `gemini/T22-pointer-input`），按约定未 commit/merge；合并提示：与 `gemini/T21` 仅在 `WallpaperEngine.swift` 不同方法有邻近修改，无逻辑冲突。
  - 接下来直接开工 **T25（通用场景还原度）**。

### 2026-11-23 · gpt · `gpt/T23-native-steam`（已合并 `main`，待 Steam 真机验收）

- 按分工先提交 T17（`1ea4e5b`）。同步到阶段 6 的 `main` 后，构建通过，75/75 场景渲染与评分，T25 可直接读取 JSON 和拼图。
- SteamCMD 解析终端和本轮追加的日志，区分密码、Steam Guard、限流、拒绝访问及网络失败。只在下载已登录后重试网络失败，最多三次，间隔 2、8、30 秒。手机确认提示选择 Steam Client。
- 原生入口在 Steam 面板显示二维码，用户确认后将 refresh token 写入钥匙串。使用系统网络配置的 URLSession 连接 CM 和 CDN，验证清单范围及分块、文件的 SHA-1，再导入资源库。ZIP 用 zlib，LZMA 用 macOS 的 libarchive，Zstandard 锁定 1.5.7。空闲时无轮询；下载逐块解密、解压和校验。[Steam 消息结构](https://github.com/SteamTracking/Protobufs/tree/master/steam) · [Zstandard 1.5.7](https://github.com/facebook/zstd/releases/tag/v1.5.7)
- 正式构建、35/35 XCTest 与 SteamCMD 假进程通过。英文及简体中文环境的隔离测试版均可显示并解出测试二维码。夹具覆盖认证请求和轮询、CM 帧、路径校验、三种解压格式和文件落盘。
- 本机公开 CM 目录请求超时（`NSURLErrorDomain -1001`），二维码接口连接失败。真实扫码、账号访问权限、CDN 下载和最终导入待验收。网络可达后，由用户本人在 Steam Mobile 扫码，再下载有权限的工坊壁纸。T23 改动留在本地分支，等待验收。

### 2026-11-23 · gemini · `gemini/T21-lockscreen-desktop`（已合并 `main`）

- **做了什么**：
  - 完成 **T21（锁屏改为写 Desktop 选择，免去系统设置手动选）**，改动位于独立工作树 `build/worktrees/gemini-T21`（分支 `gemini/T21-lockscreen-desktop`，基于 `main` `e79429e`）：
    1. **`AerialSystem.swift`（Desktop + Idle 全覆盖与完整备份/恢复）**：
       - `select(assetID:includeIdle:excludedDesktopDisplayIDs:backup:)` 同时写入 `Desktop`（锁屏）与可选 `Idle`（屏保），覆盖 `SystemDefault`、`AllSpacesAndDisplays`、`Displays/<id>`、`Spaces/<id>/Default` 和 `Spaces/<id>/Displays/<id>`。保证每个含 `Desktop` 的容器都同时携带 `Idle` 与合法 `Type`（如 `AllSpacesAndDisplays` 从 `"idle"` 升为 `"individual"`），避免 macOS 拒绝存储。
       - 扩展 `backup` 记录所有 Desktop/Idle 原内容、原先不存在的槽位（`__lumenAbsent` 标记）及容器 `Type`；关闭锁屏或关闭屏保开关时按原样恢复，新增 Space 自动借用同类型原备份（Desktop 借 Desktop、Idle 借 Idle，不串槽）。
       - 用 `isSelectionActive` 替代原 `selectedIdleAssetIDs`（修复某 Space 被静态图覆盖时因 `assetIDs` 返回空数组而漏检的问题），并将纯字典变换提取为可单测方法。
    2. **`LockScreenManager.swift`、`AppSettings.swift`、`LockScreenSettings.swift`**：
       - 新增 `AppSettings.lockScreenScreenSaver`（键 `"lockScreenScreenSaver"`，默认 `true`，设置页新增 `"Also use as screen saver"` 开关），关闭时仅还原 `Idle`、保留 `Desktop` 锁屏播放。
       - `disable()` 还原 `Index.plist` 并重启 `WallpaperAgent` 完成后，回调 `WallpaperEngine.syncStillFramesAfterLockScreenDisabled()`，确保恢复静态图或原壁纸无竞态。
    3. **`StillFrameSync.swift`、`WallpaperEngine.swift`（与静态图同步协调）**：
       - 锁屏开启时，主显示器（`lockScreenManagedDisplayIDs`）不再写入 `StillFrameSync` 静态图，且立即取消在途静态图任务（`StillFrameSync.cancel(for:)`）；其他副屏照旧走 `StillFrameSync`，并通过 `stillFrameManagedDisplayIDs()` 传给 `AerialSystem` 避免互相覆盖。
    4. **单元测试（`LumenTests/AerialSystemTests.swift`、`project.yml`）**：
       - 新增 5 项 XCTest，覆盖全容器 Desktop/Idle 写入与无损还原、副屏排除、仅 Desktop 模式下恢复屏保、单 Space 静态图覆盖检测、以及启用后新建 Space 的恢复借用；已用 `xcodegen generate` 重生成工程。
  - **接口/配置改动**：新增 `AppSettings` 键 `"lockScreenScreenSaver"`（Bool，默认 `true`）；`StillFrameSync` 新增 `cancel(for:)`；`WallpaperEngine` 新增 `lockScreenManagedDisplayIDs()`、`stillFrameManagedDisplayIDs()`、`syncStillFramesAfterLockScreenDisabled()`。
  - **性能/能耗评估**：纯事件驱动（开启/切换/关闭/15 分钟自检时才读写 `Index.plist`），关闭主屏 `StillFrameSync` 后反而省去主屏静态图生成与磁盘写入，无额外常驻开销。
  - **验证**：
    - `Tools/test.sh build`：**BUILD SUCCEEDED**
    - `Tools/test.sh unit`：**30/30** 通过（较基线 25/25 新增 5 项 `AerialSystemTests`）
    - **本机 `Index.plist` + `WallpaperAgent` 实测**：测试前备份原 `Index.plist`；执行 `select` + `restartWallpaperAgent()` 后等待 3 秒复读，`isSelectionActive == true`，全部 11 个容器（`AllSpacesAndDisplays`、`SystemDefault`、`Displays/<id>`、4 个 `Spaces/*/Default` 及 `Displays/<id>`）均保持 Lumen 资产 ID 未被系统回退；执行 `restoreSelection` 后 `AllSpacesAndDisplays` 恢复为 `Type=idle` 且无 `Desktop`，全部 Space 恢复原静态图；最后已用原备份完整复原。
- **没做完**：
  - 按约定未 commit/merge；需用户在开启锁屏后按 `⌃⌘Q` 目测锁屏实际播放效果。
  - 接下来直接开工 **T22（鼠标输入管线）**。

### 2026-11-23 · gpt · `gpt/T23-native-steam`（进行中）

- 先完成 T17，已提交 `1ea4e5b`。T23 将扩展 `SteamWorkshop` 与 `SteamPanel` 的认证和下载状态。先验证 SteamCMD 的失败分类与重试，再接入原生认证、钥匙串和内容下载。

### 2026-11-23 · gpt · `gpt/T17-visual-regression`（已提交）

- `Tools/test.sh scenes` 记录本轮渲染，`Tools/test.sh visual [N]` 按预览比例居中裁切，结合局部亮度 SSIM 和 RGB 色差排序，输出全量 JSON 和最差 N 个场景的分页拼图。
- 同步到 `main` 的 `e79429e` 后重新验证。Debug 构建通过，75/75 场景渲染、0 洋红，75/75 成功评分。产物在 T17 工作树的 `build/tools/visual`。
- GIF 首帧和片头会影响分数。T25 可用拼图挑选共性缺陷，再对照渲染进度和作者预览；评分工具只在 CLI 中运行。

### 2026-11-23 · claude · 第 6 阶段规划（未改代码）

- 根据用户实测反馈查了三个主要问题的根因，并对照了两个参考项目的做法，写成 [`PLAN.md`](PLAN.md)：
  - **锁屏**：只写了 Idle，而锁屏播放的是 Desktop 选择；`StillFrameSync` 写的静态图也会盖掉它。→ T21（gemini）
  - **鼠标跟随**：桌面上可能根本收不到全局 `mouseMoved` 事件，要改成轮询；特效投影矩阵目前是单位矩阵。→ T22（gemini）
  - **Steam**：SteamCMD 连 Steam 服务器一直超时（用户走 127.0.0.1:7890 代理），第一次还报了 Invalid Password。→ T23（gpt）：先改好 SteamCMD 的错误提示，再做原生扫码登录 + CDN 下载。
- 新原则：**优先修共性问题，个别壁纸暂不适配**（T20 暂缓）；界面打磨仍放最后。
- 新增 T21–T27 并分配：gemini 依次做 T21 → T22 → T25；gpt 先提交 T17，再做 T23。T26、T27 暂未分配。

### 2026-11-23 · claude · 合并 T07 到 `main`

- 合并 `gemini/T07-timeline-and-layout`（`328e04c`），无冲突。验证：build 通过；`unit` 25/25；`shaders` 315/316；`scenes` 75/75、0 洋红；`steam` 通过。
- 还没合并：`gpt/T17-visual-regression`（未提交）。

### 2026-11-23 · claude · 第三次合并到 `main`

- 合并了 `claude/T19-shader-translation`、`claude/T05-lockscreen-rendered`、`gpt/T08-scene-lighting`、`gpt/T18-scene-animation-control`；代码无冲突。未提交的 `gemini/T07`、`gpt/T17` 没有合并。
- 合并后验证：build 通过；`unit` 23/23；`shaders` 315/316；`scenes` 75/75、0 洋红；`steam` 通过。
- **之后开工请从最新 `main` 拉新分支**（T07、T17 需要先合并/变基到最新 `main`）。

### 2026-11-23 · gpt · `gpt/T18-scene-animation-control`（独立工作树）

- 完成 T18。`thisLayer.getAnimation(name)` 获取具名时间线，`thisObject.getAnimation()` 获取当前绑定属性的时间线。支持播放、暂停、继续、停止复位、单次重播、读写帧和非负速率。同一图层的关联属性共用播放位置。[Wallpaper Engine IAnimation](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IAnimation.html)
- `SceneLoader` 提供图层时间线声明，`SceneScriptRuntime.Change` 把受控帧交给 `SceneDocument.Object.state`。复用已有场景时钟和暂停策略，CPU 维护脚本控制的播放位置，GPU 沿用原有绘制流程。三个场景的同机 60 帧交替复测，GPU 中位数原版 6.50 ms、T18 6.67 ms。
- Debug 构建通过，XCTest 23/23，场景 75/75、0 洋红，着色器 300/316。JavaScriptCore 用例验证具名和无参查找、状态、速率及实例隔离。9 帧离屏 Metal 测试验证桌面点击事件经过脚本确实改变了图层位置和透明度。
- 本次覆盖图层属性时间线。媒体事件回调、特效和木偶动画控制仍待接入，真实桌面交互尚未手测。T07 当前涉及的四份共用源码通过了补丁应用检查，正式合并时应由 xcodegen 重生成工程。

### 2026-11-23 · claude · 分支 `claude/T19-shader-translation`（已合并 `main`）

- **做了什么**：修好仍编译失败的 10 个工坊特效着色器（影响 8 个场景，之前这些特效被静默跳过），全部是 `WEShaderTranslator`/`WEShaderPreprocessor` 的问题：
  - **Swift 正则的 `\b` 默认按 Unicode 规则**，`fragment.x` 被当成一个词，保留字 `fragment` 没改名（test_shader）。保留字替换改用 `.wordBoundaryKind(.simple)`。其他用 `\b` 的正则检查过，不受影响。
  - 数组整体赋值 `float a[N] = g_AudioSpectrum32Left;` 改成声明加逐元素拷贝循环（simple_gradient_audio_bar）。
  - 一行多个变量 `vec3 color = CAST3(0.0), currentColor;` 只包裹第一个初值（bokeh、downsample）。
  - HLSL 隐式截断：给向量赋值时，顶层的更宽向量操作数加 `.xy`/`.xyz`（pixelate、iris_movement、iris_follow_cursor）；函数参数里的不动，避免改变 `dot`/`length` 的含义。
  - 名字含 texcoord 的 vec3 varying 也按原规则窄化（cutout_vignette）。
  - `clamp(0, 0.15, x)` 这类调用里有浮点字面量时，整数字面量改成浮点（gaussian）；注意不误伤科学计数法。
  - 预处理器去掉 `#define mask 1.0;` 这类简单宏末尾的分号（crt_screen）。
- **验证**：`shaders` 300→310/316；`scenes` 75/75、0 洋红；全库用 main 和本分支各渲染一遍逐图对比，只有修好的场景有变化（另有两个场景本身每次渲染都不一样，属正常）；`unit` 18/18；build 通过。
- **发现**：3347416586 修好模糊后，画面上仍有大片白色「裂纹」图层，作者预览里没有，已记为 T20。
- **建议下一步**：剩下 6 个 3D 着色器缺 `PerformLighting_V1` 等光照函数，留给 T08。

### 2026-11-23 · claude · 分支 `claude/T05-lockscreen-rendered`（已合并 `main`）

- **做了什么**：场景和网页壁纸现在也能当锁屏（以前保留上一个视频）。
  - 场景（`SceneLoopRecorder`）：离屏加载场景，先预热 3 秒（片头、粒子、脚本稳定下来），再按 30fps 录 30 秒；最后 1.5 秒溶回第一帧，所以一小时的重复没有跳变。画面按壁纸的 framing/缩放放置，和桌面一致。场景里有视频纹理时按真实时间录（视频跟墙钟走），否则全速录。声音不播放。
  - 网页（`WebLoopRecorder`）：在屏幕外窗口里打开页面，用 WebKit 私有开关 `_setWindowOcclusionDetectionEnabled:` 让它在不可见时继续动画；每秒最多 30 张快照、按实际时间戳编码，录 12 秒，最后 1 秒溶回首帧。
  - `LoopVideoWriter`：从 Metal 纹理或 CGImage 写 HEVC，场景、网页共用。
  - `LockScreenManager`：场景缺包文件或缺 WE assets、网页缺文件时才保留旧锁屏（`.keepingPrevious`），设置页文案相应改了（英文，待翻译）。缓存键加入用户属性值，改了属性会重录。
  - `WebRenderer` 新增 `keepRenderingWhenOccluded()` 和 `snapshot()`，只给录制用。
- **验证**：build 通过。`Tools/test.sh lockloop`（新命令，不安装）实测：Chisa 30 秒录制用时 18 秒、41MB，首尾帧 0% 差异；清风 18 秒、38MB；网页「樱花」12 秒、20fps、11.5MB，花瓣在动，首尾帧 0% 差异。
- **没验证**：真正安装到系统锁屏（会改用户的锁屏设置），需要用户在「设置 › 锁屏」开启后看一眼。
- **代价**：录制只在锁屏的跟随壁纸变化时跑一次，场景约 20 秒 GPU 负载、网页约 15 秒；产物每个 10–40MB，沿用原来「只保留最新 4 个」的缓存清理。

### 2026-11-23 · gpt · `gpt/T08-scene-lighting` · `c0a0e7f`（桌面验证通过）

- 用隔离 Debug 构建在 2940×1912 的登录桌面验证原版球体、工坊 `3287715210` 体积光开关和 `3652110998` Galaxy。详情页、桌面和暂停恢复共 9 帧通过 Metal 呈现确认，各帧均采用 30 fps 设置。读回与日志保存在工作树的 `build/tools/t08-native`。
- 球体中心与背景在两条呈现路径的采样一致。体积光开启后灯心附近 RGB 中位数各增加 23，范围外四处采样一致。目视确认两条路径都显示球体高光、角色周围的体积光和 Galaxy 星空。
- 已撤下测试覆盖层、删除四个测试导入及隔离版的偏好键。真实 Lumen 资源库、偏好与系统桌面和锁屏记录的测试前后校验值一致。
- 当前支持范围通过验收。多网格、蒙皮及带阴影的体积光仍待扩展，后续可用对应的真实模型样本继续验证。

### 2026-11-23 · gpt · `gpt/T08-scene-lighting`（待验证，未提交）

- 新增静态单网格 `.mdl` 模型绘制，支持正交与透视相机、材质深度测试和写入。四个内置材质可通过 `PerformLighting_V1` 接收场景点光，光源跟随场景变换和可见性。正交点光体积按光源范围做加法混合。
- Build 通过，XCTest 18/18，场景 75/75、0 洋红，着色器 305/316（主分支 300/316）。Metal 像素验证覆盖原版球体、透视远裁剪、遮挡与跨 2D 绘制深度、点光半径内衰减、半径外不变和脚本可见性。工坊 `3287715210` 开关体积光时，灯心附近 RGB 中位各增加 23，范围外采样一致。工坊 `3652110998` 恢复原先因光照着色器编译失败而跳过的 Galaxy 层。
- 深度附件仅分配给需要深度的模型目标，每盏体积光最多四次积分采样，无额外全屏缓冲。工坊 `3287715210` 的 2844×1600、60 帧比较中位约增加 0.49ms。全库串行复测 GPU 中位 5.20ms、p90 9.38ms、最大 16.02ms，加载中位 0.50s。同环境重跑 `main` 的 GPU 中位 4.34ms、p90 8.96ms、最大 16.27ms，加载中位 0.41s。按场景配对的单帧差值中位 +0.02ms。波动最大的三个样本补跑 60 帧，差值为 −0.99、+0.09、−0.03ms。恢复 Galaxy 的场景为 +2.39ms，体积光场景为 +0.55ms。
- 待桌面画面对照。当前范围为静态单网格、点光与无阴影的正交体积光。蒙皮、多网格、模型特效、其他光源和透视体积光仍待扩展。剩余 11 个编译失败项为 10 个工坊特效（T19）和内置 `puppettexturechannels`。

### 2026-11-23 · claude · 第二次合并到 `main`

- 合并了 `gemini/T14-composelayer-grouping`、`gpt/T15-scene-property-bindings`、`claude/T16-scene-sharpness`；代码没有冲突，只合并了任务板。
- 合并后验证：build 通过；`unit` 18/18；`shaders` 300/316；`scenes` 75/75、0 洋红；`steam` 通过。「清风·兰亭」已接近作者预览（白底、淡字列、墨色「清」）。
- 小提醒（T15）：字符串值恰好是 `"false"` 的属性现在会被当成真；WE 的下拉选项一般是数字，暂不处理。
- **之后开工请从最新 `main` 拉新分支。**

### 2026-11-23 · claude · 分支 `claude/T16-scene-sharpness`（已合并 `main`）

- **原因**：
  1. 纹理被砍半：旧逻辑在纹理边长超过「渲染宽度 × 1.6」时直接丢掉最高一级 mip。app 默认渲染约 2286 宽，阈值约 3660，所以 4K/4096 纹理只剩 1920/2048，再被放大显示。这是发糊的主因。
  2. 渲染分辨率偏低：Balanced 只渲染约 2.9MP，2560×1664 屏铺满需要约 4.9MP。
- **改动**：
  - `TexDecoder`/`SceneTextureCache`：按「细节比例」（渲染缩放 × 1.3）选 mip，只有下一级 mip 仍够用时才跳过；8192 硬上限保留。`decode(_:maxDimension:)` 旧签名仍可用。
  - `SceneLoader.renderSize`：覆盖屏幕的原生像素，上限为画布尺寸（除非这样要放大超过 2 倍），再受预算限制。
  - `ShaderQuality.scenePixelBudget`：Efficient 2MP / Balanced 6MP / Full 16.6MP（原来是着色器预算 × 1.4）；详情页预览 0.9MP → 1.6MP。
  - 呈现：场景显示得比渲染大时（Efficient、或屏幕比画布大）用 Catmull-Rom 9 次采样（`presentSharp`），否则照旧双线性。
  - MetalFX 空间放大实测 M4 上每帧 2.3ms（2286→2958）到 4.5ms（5K），比直接原生渲染贵得多，**没有采用**。
  - 回归工具：`LUMEN_DISPLAY`、`LUMEN_BUDGET`（默认 6MP）、`LUMEN_BENCH`（连续 60 帧取中位）、`LUMEN_MEMORY`。
- **代价**（2560×1664，75 场景）：GPU 中位 4.0→4.9ms、均值 4.4→5.6ms；最重的几个特效场景多 4–6ms。GPU 内存中位 241→400MB、最大 957→1373MB（8 个代表场景）。加载中位基本不变，冷缓存会慢一些。
- **效果**：Laplacian 方差（越大越清晰）全图 114→185，Chisa 脸部 497→960。
- **验证**：build、unit 14/14、scenes 75/75、0 洋红。**没有**在 app 桌面上实测，需要用户看一眼。
- **建议下一步**：如果最重的几个场景耗电明显，可以加「按实测 GPU 时间自动降分辨率」（要先在 app 里校准阈值：桌面 30fps 下 GPU 不满载，频率低，测出的时间会比连续渲染偏高）。

### 2026-11-23 · gpt · `gpt/T15-scene-property-bindings`（已合并 `main`）

- 完成 T15。场景直接绑定到布尔字段时，数字和数值字符串按非零处理，其他字符串按非空处理。保留了显式选项条件、缺失属性回退以及布尔值转数值的 1/0。新增 4 项场景解析测试。
- 原任务板把「清风」的现象写反了。3420988161 的 269 号浅色底图此前被误判为隐藏。修复后，同一角落采样 RGB 由 178/178/178 变为 232/232/232，更接近作者预览。背景字列的分组和模糊由 T14 负责。
- `build` 通过，`unit` 18/18，`scenes` 75/75、0 洋红，`shaders` 300/316。三个跨类型绑定场景均做了离屏对照。
- 转换只在解析和重建场景时执行。《清风·兰亭》会多绘制恢复的全屏底图。同机两轮离屏 GPU 读数原版为 6.69/5.51 ms，新版为 11.02/5.91 ms，单帧耗时波动较大。
- 3436945972 的「关」选项编码为 `2`，没有显式条件，按非零规则仍为真。已记入 T07 的待认领备注。改动待提交。

### 2026-11-23 · gemini · `gemini/T14-composelayer-grouping`（已合并 `main`）

- **做了什么**：
  - 完成 **T14（组合层 `composelayer` 分组）**：
    - **子图层分组渲染（`SceneLoader.swift`、`SceneInstance.swift`）**：预扫描所有 `passthrough: true` 组合层，将所有可绘制后代（图片、文本、粒子、嵌套组合层）归入其最近组合层祖先的 `children` 列表，不再直接绘制到主场景；`SceneInstance.encodeChain` 在 Pass 0 之后、父特效链之前，以 `groupVP = scale(2/chainSize) * translation(-chainCenter) * model.inverse` 把子图层按原场景顺序画入父组合层的 `buffers[0]`，再统一执行父层特效并按父层混合模式/透明度合成回上层目标。保留 `drawables` 全量扁平列表，确保 `usesAudio`、木偶表、点击命中、目标分配与清理逻辑覆盖所有分组子层。
    - **`copybackground` 支持（默认 `true`）**：当组合层显式设置 `copybackground: false`（如 `3491865410`、`3516294127`、`3610728777` 的 `Audio bar`）时，Pass 0 仅清零为透明黑，不再拷贝 `_rt_FullFrameBuffer`，避免后续 `scroll`/频谱特效涂抹背景；`copybackground: true`（默认）保持先拷贝背景再叠加子层与特效，保证 `3479521040` 中叠加混合（additive）粒子子层与 `3420988161` 模糊字列混合正确。
    - **修复 `effects/opacity` 的 `g_UserAlpha` 覆盖问题（`SceneMaterials.swift`、`SceneLoader.swift`）**：为 `UniformBlock.init` 增加 `isEffect` 参数，特效 pass 中带有 `materialKey` 的 `g_UserAlpha`（`effects/opacity` 绑定到 `constantshadervalues["alpha"]`）不再被对象自身的 `object.alpha` 覆盖，使 `3420988161`（18%/36% 透明度）、`3479521040`（关键帧淡出）及 `3347416586`（35% 混合层）的透明度特效真正生效。
    - **组合层透明度与防重复乘算**：`lumen_scene_composite_fragment` 支持传入组合层 `alpha`，`state(of:)` 对归入组合层分组的子图层不再把父组合层 `alpha` 重复乘入子层。
  - **性能/能耗评估**：不增加任何额外离屏纹理（复用组合层现有 `buffers[0]`）；`copybackground: false` 跳过一次全帧 blit 和 Pass 0 绘制；分组绘制仅在组合层可见或被采样时运行，完全遵守现有自动暂停与像素预算策略。
  - **验证**（全部在 `build/worktrees/gemini-T14` 中执行）：
    - `Tools/test.sh build`：**BUILD SUCCEEDED**
    - `Tools/test.sh unit`：**14/14** 通过
    - `Tools/test.sh shaders`：**300/316** 通过（持平基线）
    - `Tools/test.sh scenes`：**75/75 OK，0 FAIL，0 洋红块**（加载中位 0.62s、最大 2.02s；GPU 中位 3.70ms、p90 7.74ms）
    - 视觉抽检：`3420988161`（清风·兰亭）背景 18 列兰亭集序字列已恢复为 18%/36% 透明水波模糊效果；`3479521040` 粒子遮罩与淡出正常；`LUMEN_FAKE_AUDIO=1` 下 `3491865410`/`3610728777` 的 `copybackground: false` 音频条清晰透明、无背景涂抹。
- **没做完**：
  - 改动在独立工作树 `build/worktrees/gemini-T14`（分支 `gemini/T14-composelayer-grouping`）尚未提交或合并（按规则等用户/协调者确认后提交合并；合并时与 T16 仅在 `SceneLoader.swift` 不同函数，预计无冲突）。
- **建议下一步**：
  - 合并 T14 与 GPT 的 T15 后，《清风·兰亭》（`3420988161`）的浅色宣纸底图 + 模糊透明字列将完整还原。下一批未认领中优先级任务为 **T05（场景/Web 锁屏循环视频）**、**T07（片头/时间线场景 `3436945972` 与 `3463692991` 布局）**、**T17（场景视觉回归感知打分）**。

### 2026-11-23 · claude · 合并到 `main`

- 合并了 `gemini/T02-puppet-warp`、`gpt/T13-desktop-transition`、`claude/T04-audio-reactive`、`gpt/T06-scene-cursor-events`、`gpt/T09-parser-tests`。
- 冲突处理：`SceneMaterials` 同时保留 `bones/bonesAlpha` 和 `audio(resolution:right:)`；`SceneScript.update` 和 `__frame` 同时接收鼠标事件与音频；`project.pbxproj` 用 xcodegen 重新生成。
- 合并后验证：build 通过；`unit` 14/14；`shaders` 300/316；`scenes` 75/75、0 洋红；`steam` 通过；抽查 Chisa 眼睛已正常。
- **之后开工请从最新 `main` 拉新分支。**

### 2026-11-23 · claude · 分支 `claude/T04-audio-reactive`（已合并 `main`）

- **做了什么**：
  - 新增 `Lumen/Engine/Audio/`：`SystemAudioCapture`（Core Audio process tap + 私有聚合设备，切换输出设备时自动重建）、`AudioSpectrumAnalyzer`（2048 点 FFT，64 段对数频带 45 Hz–16 kHz，快起慢落平滑）、`AudioSpectrumService`（引用计数，只在有音频响应壁纸正在播放时采集）。
  - 场景：`g_AudioSpectrum{16,32,64}{Left,Right}` 填入真实数据；粒子发射器支持 `audioprocessingmode/bounds/exponent/frequencystart/end`；SceneScript 的 `engine.registerAudioBuffers()` 每帧刷新 `left/right/average`。
  - Web：`wallpaperRegisterAudioListener` 收到 128 个值（64 左 + 64 右），约 30 次/秒。
  - 设置：`audioReactiveWallpapers`（默认开，「设置 › Wallpaper Engine」里可关）；`project.yml` 加了 `NSAudioCaptureUsageDescription`。预览渲染器不会触发采集。
  - 场景回归工具支持 `LUMEN_FAKE_AUDIO=1` 注入假频谱。
- **验证**：build 通过；场景 75/75 OK、0 洋红；假频谱下音频条/脉冲效果有变化；合成正弦波测试频带位置正确。**没有**在真机上采集过真实音频（会弹系统权限框，需要用户本人授权）。
- **接口改动**：`EngineUniform.audio` 变成 `.audio(resolution:right:)`；`SceneInstance.Frame`、`DrawState` 新增 `audio`；`ParticleSystem.update`、`SceneScriptRuntime.update` 新增带默认值的 `audio` 参数；`SceneRenderSettings`、`WebRenderSettings` 新增 `audioReactive`。
- **合并提示**：Gemini 的 T02 在 `SceneMaterials.swift` 同一位置加了 `bones/bonesAlpha`，后合并的一方会有小冲突：两个 case 都保留即可。
- **建议下一步**：用户授权后播放音乐，看频谱条高度和粒子节奏，必要时调整 `AudioSpectrumAnalyzer` 里的电平映射（`decibels + 60) / 48`）和倾斜（3 dB/oct，以 400 Hz 为轴）。


### 2026-11-23 · gemini · `gemini/T02-puppet-warp`（待提交）

- **做了什么**：
  - 完成 **T02（木偶变形 puppet warp）**：
    - **`.mdl` 二进制解析（新增 `Lumen/Engine/Scene/ScenePuppet.swift`）**：完整支持 `MDLV0016/19/21/23`（顶点格式 `0x00000009`/`0x0000000f`/`0x01800009`/`0x0180000f`、UInt16 索引、子网格表与内嵌裁剪蒙版表）、`MDLS0002/03/04`（骨骼树与 bind pose 逆矩阵）、`MDAT0001`（骨骼附着点）、`MDLA0003/05/06`（骨骼 TRS 动画与可选 `alphaTracks`）。实测全语料 93/93 个 `.mdl` 零失败解析；UV 自动按主贴图 `imageExtent` 缩放以适配块对齐 `.tex`。
    - **骨骼动画与附着点（`PuppetAnimator` + `SceneInstance.parentWorld(of:)`）**：每帧按 `animationlayers` 的 `rate`/`blend`/`additive`/`visible` 与 `loop`/`mirror`/`single` 模式求值骨骼矩阵（最短欧拉角差值插值），通过 `g_Bones`（`mat4x3`）和 `g_BonesAlpha`（`SKINNING_ALPHA`）传入着色器；子图层及嵌套子级通过 `attachment` 自动跟随父木偶骨骼运动（如 `3808922316` 角色眼睛/头发/光环/耳坠、`3367836416` 初音草帽）。
    - **MDL 内嵌裁剪蒙版（`clippingmaskimage4` + `CLIPPINGUVS`/`CLIPPINGTARGET`）**：`SceneBlend` 新增 `.max` 混合模式，对带内嵌裁剪蒙版的子网格按需先将遮罩子网格渲染至图层 `clippingMaskTarget`，再绑定到 `g_Texture8` 绘制被裁剪子网格（同一帧连续共享遮罩的子网格复用结果），修复 6 个场景的眼部/部件裁剪。
    - **偏心 PSD 木偶特效链适配**：`SceneLoader` 按木偶网格包围盒计算 `chainCenter`/`chainSize`（居中木偶保持原心以对齐特效遮罩，偏心 PSD 木偶居中到网格并留 15% 摆动余量），防止带特效的拆分部件在 Pass 0 被裁切。
  - **性能/能耗评估**：
    - `BONECOUNT` 按 `[16, 32, 64, 96, 128]` 分桶，避免为不同骨骼数编译数十份重复着色器变体；超过 Metal 4 KB 内联上限的骨骼 Uniform（如 95 骨模型 `3495507502`）改为每 pass 复用 6 槽共享 `MTLBuffer` 环形缓冲，消除逐帧分配。
    - 静止（无活跃 `animationlayers`）的木偶只求值一次；自动遵守现有遮挡/锁屏/低电量暂停与像素预算策略。
    - 全库 75 场景实测：加载中位 0.42s（最大 1.44s），GPU 帧时间中位 3.02ms、p90 6.81ms（158 层 Elisa `3808922316` 仅 13.23ms，95 骨 `3495507502` 仅 4.41ms）。
  - **验证**：
    - `Tools/test.sh build`（含 `xcodegen generate`）通过；`Tools/test.sh shaders` 300/316（持平基线）；`Tools/test.sh scenes` 75/75 OK、0 FAIL、0 洋红块。
    - 肉眼抽检 9 个代表性木偶场景（`3808922316`、`2862513197`、`3367836416`、`3463692991`、`3479521040`、`3491865410`、`3610728777`、`3675289919`、`3495507502`），骨骼装配与眼部裁剪均正确；跨时间帧对比（`t=0.5` vs `t=2.5`）确认顶点实时变形（`3808922316` 60.0% 像素变化、`3367836416` 36.9%、`3495507502` 1.7%）。
- **没做完**：
  - 改动尚在 `gemini/T02-puppet-warp` 工作区未提交（等用户确认后 commit/合并）。
  - 尚未实现木偶 `MORPHING`（形态变形目标，语料中无依赖此项的坏图，如需后续可单列）。
- **建议下一步**：
  - 用户确认提交并合并 `gemini/T02-puppet-warp` 到 `main` 后，可继续认领尚未被占用的高/中优先级任务：**T05（场景/Web 壁纸锁屏循环视频）** 或 **T07（片头/时间线类场景 3436945972 与 3463692991 布局）**。

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
