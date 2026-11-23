# Lumen · 进度与任务板

> 所有助手共同维护。开工前读，收工时更新（规则见 [`AGENTS.md`](../AGENTS.md)）。
> 最后更新：2026-11-23 · claude（合并）

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
  - 支持：图片层、大部分特效（WE 原版 GLSL 运行时翻译为 MSL）、木偶变形（`.mdl` 网格/骨骼蒙皮/`animationlayers`/骨骼附着/内嵌裁剪蒙版）、跨层裁剪蒙版、粒子、精灵图动画、视频纹理、关键帧动画、文本层（时钟/日期）、SceneScript（JavaScriptCore）、音效、鼠标视差、用户属性面板。
  - 场景需要 WE 的共享 assets 文件夹，会自动从 WallpaperMachine 找到；也可在「设置 › Wallpaper Engine」里指定。
- **创意工坊**：
  - Workshop 页扫描 Steam 下载目录、WallpaperMachine 库和自定义文件夹，一键加入资源库。
  - 支持 Steam 下载：通过 SteamCMD 用用户自己的账号登录，支持 Steam Guard 和手机确认；也可以在内置 Workshop 浏览器里点「Download to Lumen」。

**回归基线**（2026-11-23 合并后，`Tools/test.sh`，语料为 WallpaperMachine 库，75 个场景）

| 项目 | 基线 |
|---|---|
| 场景加载/渲染 | 75/75 OK，0 FAIL |
| 加载耗时（着色器缓存命中） | 中位 0.39s，最大 1.5s |
| GPU 帧时间（约 2MP） | 中位 3.6ms，p90 6.9ms，最大 15.5ms（含木偶、音频） |
| 着色器翻译 + 编译 | 300/316 通过（失败集中在 3D 光照、体积光和少数工坊自带着色器） |
| 明显洋红色块 | 0 个（3808922316 洋红块、2983846453/3615984066/3397287008 白/灰块均已修复） |
| SteamCMD 提示解析（假 steamcmd） | 通过 |
| 单元测试（`Tools/test.sh unit`） | 18/18 通过 |

## 3. 任务板

状态：待认领 / 进行中 / 待验证 / 完成。认领时把「负责」改成你的身份。

| ID | 任务 | 模块 | 优先级 | 状态 | 负责 | 备注 |
|---|---|---|---|---|---|---|
| T01 | 提交阶段 3/4 的改动 | 全局 | 高 | 完成 | claude | `23d33aa` |
| T02 | 木偶变形（puppet warp）：MDL 解析、骨骼蒙皮（genericimage4 `SKINNING` / `g_Bones`）、animationlayers、MDL 内嵌裁剪蒙版（`clippingmaskimage4`） | 场景 | 高 | 完成 | gemini | 已合并 `main`（`ca5ee70`）：MDL 网格、骨骼蒙皮、animationlayers、MDL 内嵌裁剪蒙版；Chisa 眼睛错位已修复。未做：`MORPHING` |
| T03 | 图层裁剪蒙版（clipping masks） | 场景 | 高 | 完成 | gemini | 已合并 `main`：跨层合成目标 `_rt_imageLayerComposite_*`、链式 `colorBlendMode` 最终合成、目标清空同步、`startpaused` 及相关着色器翻译修复；3808922316/3615984066/3397287008/2983846453 均已修复 |
| T04 | 音频响应：系统音频频谱（`g_AudioSpectrum*`、脚本 audio buffer） | 场景/Web | 中 | 待验证 | claude | 已合并 `main`（`cc2990e`）。需用户授权「录制系统音频」后用真实音乐验收手感 |
| T05 | 场景/Web 壁纸的锁屏：录一段循环视频交给 `LockScreenVideoBuilder` | 锁屏 | 中 | 待认领 | | 现在保留上一个视频锁屏（`.keepingPrevious`） |
| T06 | SceneScript 鼠标事件（cursorClick/Down/Up/Move 等） | 场景 | 中 | 完成 | gpt | 已合并 `main`（`144ffe7`）：2D 图层六种鼠标事件 |
| T07 | 片头/时间线类场景（如 3436945972），以及 3463692991 的布局问题 | 场景 | 中 | 待认领 | | 另需核对 3436945972 的视差下拉框。项目把「关」保存为非零值 `2`，直接绑定缺少选项匹配条件 |
| T08 | 3D 模型与光照（`PerformLighting_V1`）、体积光 | 场景 | 低 | 待认领 | | 对应 18 个编译失败的着色器中的大部分 |
| T09 | 为解析器补 XCTest：pkg、tex、project.json、着色器预处理、SteamCMD 输出 | 测试 | 中 | 完成 | gpt | 已合并 `main`（`3f51c54`）：14 项 XCTest，`Tools/test.sh unit` |
| T10 | 真实 Steam 登录和下载的端到端验证 | Steam | 中 | 待认领 | 需用户 | 必须用户本人登录，助手不得代输密码 |
| T11 | 新界面文案翻译（Workshop、Steam 面板、WE 设置、属性面板、添加网页） | UI | 低 | 待认领 | | 放到阶段 5 |
| T12 | 全局 UI 打磨 | UI | 低 | 待认领 | | 等功能完成后再做（用户要求） |
| T13 | 处理 `DesktopHost` 转场回调的 Swift 并发警告 | 引擎 | 低 | 完成 | gpt | 已合并 `main`（`08045c9`） |
| T14 | 组合层（composelayer）分组：子图层先画进父组合层的缓冲（`copybackground` 缺省为 true，先拷贝背景），再跑父层特效、按父层混合合成；子图层不再直接画到场景 | 场景 | 高 | 完成 | gemini | 分支 `gemini/T14-composelayer-grouping`（独立工作树 `build/worktrees/gemini-T14`，待提交）：组合层子图层分组渲染、`copybackground: false` 清零背景、`effects/opacity` 的 `g_UserAlpha` 常量修复；《清风·兰亭》18%/36% 模糊字列与 3479521040/3491865410/3610728777 均已验证 |
| T15 | 场景用户属性绑定的类型转换 | 场景 | 高 | 完成 | gpt | `gpt/T15-scene-property-bindings`。直接绑定到布尔字段时按非空、非零转换，显式条件按选项比较。《清风·兰亭》的浅色底图已恢复，75/75 场景与 18 项 XCTest 通过。待提交 |
| T16 | 场景清晰度：渲染分辨率按屏幕实际像素覆盖、上限为画布尺寸；低于屏幕时用 MetalFX 空间放大（`MTLFXSpatialScaler`）代替双线性；详情页预览预算提高；纹理上限跟随屏幕 | 场景 | 高 | 待验证 | 分支 `claude/T16-scene-sharpness`：按屏幕原生像素渲染（上限画布尺寸）、纹理不再被砍半、放大时用 Catmull-Rom。MetalFX 实测每帧 2–5ms，未采用。待用户在 app 里看效果 |
| T17 | 场景视觉回归：回归工具把渲染结果和作者预览图（preview.gif/jpg 首帧）做感知相似度打分，输出最差的 N 个场景和对比拼图 | 测试 | 中 | 待认领 | | 只改 `Tools/`，可完全并行；用来自动发现「清风」这类整体偏差 |
| T18 | SceneScript 动画控制：`layer.getAnimation()` 的 `play/pause/stop/isPlaying`，配合 `startpaused` 关键帧动画 | 场景 | 低 | 待认领 | | T03 让 `startpaused` 动画停在第 0 帧，但脚本还不能让它播放 |

**2026-11-23 claude 补充（给 T02）**：「[Chisa]Autumn and temple」（库里 EDF506EA…）的 `02眼组` 是木偶模型，贴图是眼白/瞳孔/闭眼的拼图，必须按 `02眼组_puppet.mdl` 里的网格顶点和 UV 去画；**哪怕先只画静止网格、不做骨骼动画，眼睛错位也会消失**，建议 T02 先交付这一步。

不做：WE 的 application 类型（只能在 Windows 上运行）。

## 4. UI 规则（用户定的）

- 观感以 Wallper 为基准，但要有自己的识别度，不照抄。
- 「高级感」的展示标题和眉标保留英文，例如 "Your desktop, in motion."、"Smart pause"、"LIBRARY"。
- 设置、按钮、菜单、状态、提示、错误和说明性副标题都翻译成 zh-Hans。
- 用户的 macOS 是英文系统；要看中文，在 app 内切换语言，或用 `-AppleLanguages "(zh-Hans)"` 启动。

## 5. 交接日志（新的写在最上面）

### 2026-11-23 · gpt · `gpt/T15-scene-property-bindings`（独立工作树）

- 完成 T15。场景直接绑定到布尔字段时，数字和数值字符串按非零处理，其他字符串按非空处理。保留了显式选项条件、缺失属性回退以及布尔值转数值的 1/0。新增 4 项场景解析测试。
- 原任务板把「清风」的现象写反了。3420988161 的 269 号浅色底图此前被误判为隐藏。修复后，同一角落采样 RGB 由 178/178/178 变为 232/232/232，更接近作者预览。背景字列的分组和模糊由 T14 负责。
- `build` 通过，`unit` 18/18，`scenes` 75/75、0 洋红，`shaders` 300/316。三个跨类型绑定场景均做了离屏对照。
- 转换只在解析和重建场景时执行。《清风·兰亭》会多绘制恢复的全屏底图。同机两轮离屏 GPU 读数原版为 6.69/5.51 ms，新版为 11.02/5.91 ms，单帧耗时波动较大。
- 3436945972 的「关」选项编码为 `2`，没有显式条件，按非零规则仍为真。已记入 T07 的待认领备注。改动待提交。

### 2026-11-23 · gemini · `gemini/T14-composelayer-grouping`（工作树 `build/worktrees/gemini-T14`，待提交）

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
