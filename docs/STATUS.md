# Lumen · 进度与任务板

> 所有助手共同维护。开工前读，收工时更新（规则见 [`AGENTS.md`](../AGENTS.md)）。
> 最后更新：2026-11-24 · claude（T30 界面重设计与 app 内创意工坊，已合并到 main）

## 1. 阶段进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 视频壁纸（MP4/MOV，HEVC 优化）、Metal 着色器壁纸 + Studio 编辑器、多显示器、自动暂停、菜单栏面板 | ✅ 已提交（`fed0b5f`、`57169f6`） |
| 2 | 锁屏视频、画面裁切（framing）、遮挡阈值、简体中文本地化 | ✅ 已提交（`509c56d`、`0af720e`） |
| 3 | Web 壁纸（本地 HTML / 网址，WE web 项目属性 API） | ✅ 已提交（`23d33aa`） |
| 4 | Wallpaper Engine 场景壁纸 + Steam 创意工坊下载 | ✅ 完成（木偶、裁剪蒙版、组合层、音频、鼠标事件、3D 光照等已合并；Steam 扫码登录和下载用户实测通过） |
| 6 | **通用问题与可用性**：锁屏免手动、鼠标输入、原生 Steam 扫码登录、通用还原度 | ✅ 完成（含 T28/T29） |
| 7 | 发布准备与能耗：T26、T27（暂不公证，用自签名证书 + DMG） | ✅ 完成，0.1.0 已打包发布到 GitHub 私有仓库 |
| 5 | 全局 UI 打磨 + 补翻译：T12、T11 | ✅ 完成 |

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

**回归基线**（2026-11-23 收尾阶段全部合并后，`Tools/test.sh`，默认 Balanced 预算 6MP、2560×1600 屏，语料为 WallpaperMachine 库，75 个场景）

| 项目 | 基线 |
|---|---|
| 场景加载/渲染 | 75/75 OK，0 FAIL |
| 加载耗时（着色器缓存命中） | 中位约 0.45s，最大约 1.4s（与构建并行跑时会升到 0.7s / 2.8s） |
| GPU 帧时间（原生约 4.7MP） | 中位 4.7ms，p90 11.3ms，最大 17.7ms（Elisa 3808922316）；桌面上由 T26 按实测自动降档 |
| 着色器翻译 + 编译 | 316/316 通过 |
| 明显洋红色块 | 0 个（3808922316 洋红块、2983846453/3615984066/3397287008 白/灰块均已修复） |
| SteamCMD 提示解析（假 steamcmd） | 通过 |
| 单元测试（`Tools/test.sh unit`） | 42/42 通过 |

## 3. 任务板

状态：待认领 / 进行中 / 待验证 / 完成。认领时把「负责」改成你的身份。

| ID | 任务 | 模块 | 优先级 | 状态 | 负责 | 备注 |
|---|---|---|---|---|---|---|
| T01 | 提交阶段 3/4 的改动 | 全局 | 高 | 完成 | claude | `23d33aa` |
| T02 | 木偶变形（puppet warp）：MDL 解析、骨骼蒙皮（genericimage4 `SKINNING` / `g_Bones`）、animationlayers、MDL 内嵌裁剪蒙版（`clippingmaskimage4`） | 场景 | 高 | 完成 | gemini | 已合并 `main`（`ca5ee70`）：MDL 网格、骨骼蒙皮、animationlayers、MDL 内嵌裁剪蒙版；Chisa 眼睛错位已修复。未做：`MORPHING` |
| T03 | 图层裁剪蒙版（clipping masks） | 场景 | 高 | 完成 | gemini | 已合并 `main`：跨层合成目标 `_rt_imageLayerComposite_*`、链式 `colorBlendMode` 最终合成、目标清空同步、`startpaused` 及相关着色器翻译修复；3808922316/3615984066/3397287008/2983846453 均已修复 |
| T04 | 音频响应：系统音频频谱（`g_AudioSpectrum*`、脚本 audio buffer） | 场景/Web | 中 | 完成 | claude | 已合并 `main`（`cc2990e`）。用户用真实音乐实测正常 |
| T05 | 场景/Web 壁纸的锁屏：录一段循环视频交给 `LockScreenVideoBuilder` | 锁屏 | 中 | 完成 | claude | 已合并 `main`（`e079a73`）；配合 T21 用户实测正常 |
| T06 | SceneScript 鼠标事件（cursorClick/Down/Up/Move 等） | 场景 | 中 | 完成 | gpt | 已合并 `main`（`144ffe7`）：2D 图层六种鼠标事件 |
| T07 | 片头/时间线类场景（如 3436945972），以及 3463692991 的布局问题 | 场景 | 中 | 完成 | gemini | 已合并 `main`（`328e04c`）。分支 `gemini/T07-timeline-and-layout`：实现 `thisScene.destroyLayer` 与帧时钟 `setTimeout`/`clearTimeout`；支持二选一开/关下拉框直绑布尔与嵌套用户属性回退；实现文本层 `limitwidth`/`limitrows`/省略号自动换行、对齐锚点偏移及 4096 纹理缩放一致性修复。3436945972 片头淡出与视差开关、3463692991/2867182492 文本布局均已修复 |
| T08 | 3D 模型与光照（`PerformLighting_V1`）、体积光 | 场景 | 低 | 完成 | gpt | 已合并 `main`（`c0a0e7f`）。`gpt/T08-scene-lighting`。静态单网格、点光照与正交点光体积通过应用预览和真实桌面验证，已提交 |
| T09 | 为解析器补 XCTest：pkg、tex、project.json、着色器预处理、SteamCMD 输出 | 测试 | 中 | 完成 | gpt | 已合并 `main`（`3f51c54`）：14 项 XCTest，`Tools/test.sh unit` |
| T10 | 真实 Steam 登录和下载的端到端验证 | Steam | 中 | 完成 | 用户 | 用户本人扫码登录并下载成功（T23 原生客户端） |
| T11 | 补全简体中文翻译（T12 改动后的全部界面，及 Workshop、Steam 面板、WE 设置、属性面板、添加网页） | UI | 中 | 完成 | claude | gemini 额度用尽、gpt 未做，由 claude 接手：补齐 158 条 zh-Hans（Steam、创意工坊、场景、更新、锁屏等），另加 `InfoPlist.xcstrings` 翻译系统音频授权提示。已合并 `main` |
| T12 | 全局 UI 打磨：参考 Wallper 的质感，颜色和布局更高级；先出 `docs/DESIGN.md`，分两批交付并附前后截图 | UI | 高 | 完成 | gemini / claude | 第一批 gemini（`docs/DESIGN.md`、Theme、主窗口各页）；第二批 claude（播放列表、创作及编辑器、菜单栏面板、添加网页、锁屏预览改用 Theme，抽出 `EmptyStatePanel`，卡片补辅助功能动作）。已合并 `main` |
| T13 | 处理 `DesktopHost` 转场回调的 Swift 并发警告 | 引擎 | 低 | 完成 | gpt | 已合并 `main`（`08045c9`） |
| T14 | 组合层（composelayer）分组：子图层先画进父组合层的缓冲（`copybackground` 缺省为 true，先拷贝背景），再跑父层特效、按父层混合合成；子图层不再直接画到场景 | 场景 | 高 | 完成 | gemini | 已合并 `main`（`d8663af`）：组合层子图层画进父层缓冲，支持 `copybackground`；「清风」背景字列已正常 |
| T15 | 场景用户属性绑定的类型转换 | 场景 | 高 | 完成 | gpt | 已合并 `main`（`89373a8`）：直接绑定到布尔字段时数字按非零、字符串按非空；「清风」白色底图已恢复 |
| T16 | 场景清晰度：渲染分辨率按屏幕实际像素覆盖、上限为画布尺寸；低于屏幕时用 MetalFX 空间放大（`MTLFXSpatialScaler`）代替双线性；详情页预览预算提高；纹理上限跟随屏幕 | 场景 | 高 | 完成 | claude | 已合并 `main`（`7303cc0`）：原生分辨率渲染、纹理不再砍半、放大用 Catmull-Rom。用户实测清晰 |
| T17 | 场景视觉回归：回归工具把渲染结果和作者预览图（preview.gif/jpg 首帧）做感知相似度打分，输出最差的 N 个场景和对比拼图 | 测试 | 中 | 完成 | gpt | 已合并 `main`（`1ea4e5b`）。`Tools/test.sh visual [N]`：0–100 相似度排序，输出 JSON 与最差 N 张对比拼图 |
| T18 | SceneScript 动画控制：`layer.getAnimation()` 的 `play/pause/stop/isPlaying`，配合 `startpaused` 关键帧动画 | 场景 | 低 | 完成 | gpt | 已合并 `main`（`640bb08`）。`gpt/T18-scene-animation-control`。具名及绑定属性时间线支持播放控制，共用轨道同步。23 项 XCTest 和 75/75 场景通过 |
| T19 | 修复仍编译失败的 10 个工坊特效着色器（翻译层）：数组初始化、`clamp` 歧义、向量隐式截断、`sample`/`currentColor` 等未声明标识符、宏展开语法 | 场景 | 中 | 完成 | claude | 已合并 `main`（`a5b0c5e`）：10 个工坊特效能编译 |
| T20 | 3347416586（海边摩托）画面上有大片白色「裂纹」图层，作者预览里没有：查明是哪层、为什么可见（可能是条件可见、遮罩或混合模式） | 场景 | 中 | 完成 | gemini | 随 T25 合并：离屏 Pass 0 投影没缩放 Z，木偶骨骼 Z 偏移被深度裁剪出空洞。属共性缺陷，已统一修复 |
| T21 | 锁屏改为写 Desktop 选择（免去系统设置里手动选），协调 StillFrameSync，扩展备份/恢复 | 锁屏 | 高 | 完成 | gemini | 已合并 `main`（`1654110`）：同时写 Desktop/Idle 全部容器，新增「也用作屏保」开关，关闭时按备份原样恢复；锁屏开启时主屏不再写静态图。用户实测正常 |
| T22 | 鼠标输入管线：位置改为轮询、按需开启；补 `g_EffectTextureProjectionMatrix`；核对坐标系 | 场景/Web | 高 | 完成 | gemini | 已合并 `main`（`0eba484`）：只在有交互壁纸播放时按帧率轮询（≤60Hz，静止时跳过）；补特效投影矩阵及逆矩阵，`g_ParallaxPosition` 改为 [0,1] 居中。用户实测正常；粒子控制点跟随鼠标另见 T28 |
| T23 | 原生 Steam 客户端：扫码登录（钥匙串存 token）+ CM/CDN 下载创意工坊；先改好 SteamCMD 的错误分类和重试 | Steam | 高 | 完成 | gpt | 已合并 `main`（`72b575b`）：二维码登录、CM/CDN 下载与校验、SteamCMD 错误分类和重试。用户实测登录和下载成功 |
| T25 | 通用场景还原度：用 T17 报告和「不支持特性统计」找影响面最大的共性问题，逐类修 | 场景 | 中 | 完成 | gemini | 已合并 `main`（`6135397`）：离屏/组合层 Z 深度映射、`rope`/`ropetrail` 粒子、场景全局 bloom、最后一个着色器。着色器 316/316 |
| T26 | 能耗与稳定：按 GPU 实测自适应分辨率、加载失败与内存压力降级、长时间播放稳定性检查 | 引擎 | 中 | 完成 | gpt | 已合并 `main`（`e92c19a`）：按实测 GPU 时间自动降档、内存压力与加载失败降级、`Tools/test.sh stability` |
| T27 | 发布准备（暂不公证）：自签名证书固定签名身份、DMG 打包脚本、安装说明、开机启动、检查更新、本地崩溃记录 | 发布 | 中 | 完成 | gpt | 已合并 `main`（`1915d89`）：`Tools/make-signing-identity.sh`（用户本人运行）、`Tools/release.sh`、`docs/INSTALL.md`、开机启动、检查更新、MetricKit 本地记录。0.1.0 DMG 为临时签名 |
| T28 | 粒子控制点跟随鼠标：发射器、`mapsequencearoundcontrolpoint`/`betweencontrolpoints`、`vortex` 等以控制点为中心；测试工具支持模拟指针 | 场景 | 高 | 完成 | gemini | 已合并 `main`（`22b3a36`）：控制点统一解析（跟随鼠标/世界空间/父级链接）、发射器跟随控制点、`mapsequence*`、`vortex` 控制点；`LUMEN_POINTER` 模拟指针 |
| T29 | 父层 alpha 不再乘到子图层（只传可见性和变换），用 T17 打分验证 | 场景 | 高 | 完成 | gpt | 已合并 `main`（`c5afad0`）：普通父层只传可见性和变换；「清风」印章恢复；`Tools/test.sh visual diff` 前后对比 |
| T30 | 界面重设计（第二轮）：氛围背景按壁纸取色并控亮度、首页「舞台」、卡片/列表双视图、详情页信息栏、统一面板组件、播放条与菜单栏面板；同步改写 `docs/DESIGN.md` | UI | 高 | 完成 | claude | 分支 `claude/T30-ui-redesign`。第二轮：降紫色饱和度、自绘按钮、对齐。第三轮：菜单栏面板改成整幅作品铺满；创意工坊改为 app 内的 Steam 创意工坊。第四轮：页码分页、工具栏下载进度、完整排序与筛选、可显隐的预览侧边栏。用户确认后已合并到 `main` |
| T32 | 场景/网页高清封面帧：很多创意工坊场景只带 160–256px 的预览 GIF，卡片和首页舞台发虚。从实时渲染（详情页预览或桌面渲染器）抓一帧 ≥1920px 存为封面，`ThumbnailCache` 优先用它 | 场景/UI | 中 | 待认领 | — | 需要渲染器提供读回帧的接口，属跨模块改动，先在交接日志写明 |

**2026-11-23 claude 补充（给 T02）**：「[Chisa]Autumn and temple」（库里 EDF506EA…）的 `02眼组` 是木偶模型，贴图是眼白/瞳孔/闭眼的拼图，必须按 `02眼组_puppet.mdl` 里的网格顶点和 UV 去画；**哪怕先只画静止网格、不做骨骼动画，眼睛错位也会消失**，建议 T02 先交付这一步。

不做：WE 的 application 类型（只能在 Windows 上运行）。

## 4. UI 规则（用户定的）

- 观感以 Wallper 为基准，但要有自己的识别度，不照抄。
- 「高级感」的展示标题和眉标保留英文，例如 "Your desktop, in motion."、"Smart pause"、"LIBRARY"。
- 设置、按钮、菜单、状态、提示、错误和说明性副标题都翻译成 zh-Hans。
- 用户的 macOS 是英文系统；要看中文，在 app 内切换语言，或用 `-AppleLanguages "(zh-Hans)"` 启动。

## 5. 交接日志（新的写在最上面）

### 2026-11-24 · claude · `claude/T30-ui-redesign` 第四轮，合并到 `main`

- **用户反馈**：
  1. 无限滚动会越加载越多，也不方便跳转，要分页。
  2. 在创意工坊页时，下载进度要在顶栏显示。
  3. 排序和分类要完整，比如「评分最高」。
  4. 要一个可以显示和隐藏的侧边栏来预览。
- **数据层**（`WorkshopCatalog.swift`）：
  - 改为解析浏览页里嵌入的结果 JSON（`current_page / total_pages / total_count / results`）。一次请求就拿到这一页的标题、预览、大小、标签、订阅数、收藏数、星级、投票数，以及总页数；Steam 对普通浏览封顶 1000 页，搜索时 `total_count` 才准确。原来的「条目链接 + `GetPublishedFileDetails`」留作后备。
  - 实测可用的排序：`trend`（加 days：1/7/30/90/180/365/-1）、`toprated`、`totaluniquesubscribers`、`mostrecent`、`lastupdated`；`favorited` 之类会被当成默认排序。
  - 标签取自页面里 WE 官方的标签表：25 个题材、按标准 / 超宽 / 双屏 / 三屏 / 竖屏 / 其他分组的分辨率、9 个特性。
  - `WorkshopBrowser` 改为按页码加载（每页 30 条），缓存最近 24 页，并保存侧边栏的选中项。
- **界面**：
  - 分页器分两处：网格上方是紧凑的「‹ 3 / 1000 ›」，下方是完整页码（首页、末页、当前页前后各两页，外加跳页输入框），翻页后回到顶部。
  - 新增「筛选」菜单（分辨率、特性、内容分级），带已选数量的角标。
  - 排序补上「评分最高」，热门可以选近 3 个月、近 6 个月。
  - 预览侧边栏：340pt 宽的玻璃面板，浮在右侧，不跟随网格滚动，默认显示（`@AppStorage("workshopInspector")`）。显示时点卡片是选中（描边高亮），隐藏时点卡片弹出详情弹窗；侧边栏和弹窗共用 `WorkshopDetails`。
  - 工具栏下载按钮（`DownloadsToolbarButton`）：创意工坊页上只要有下载记录就显示，其他页只在有下载进行中时显示，用进度环加数量表示，全部完成后变成绿色对勾；点开是下载列表弹层，包括缩略图、进度、「显示」、「清除已完成」，以及账号与下载入口。账号按钮旁原来的下载提示已去掉。
- **调试**：新增 `-LumenDebugDelete <uuid>`（只在 Debug 构建生效），用正常删除流程清理测试时加入的壁纸。
- **验证**：build 通过，unit 42/42。实机检查了侧边栏选中与隐藏、翻到第 2 页、跳到第 25 页、搜索结果数和页数，以及真实下载一个 1.6MB 的条目（工具栏进度环、卡片角标、侧边栏进度、完成后绿色对勾和列表）。测试条目已用 `-LumenDebugDelete` 删除，资源库恢复到 35 条。「筛选」菜单打不开（后台控制无法打开菜单），没有目视检查。补了 41 条 zh-Hans。

### 2026-11-24 · claude · `claude/T30-ui-redesign` 第三轮（按用户反馈，未提交）

- **菜单栏面板**：按用户要求去掉播放设置磁贴，这些设置留在 app 里。作品铺满整个面板（300×540），下半部分渐隐成作品自己的氛围色。上方是字标和两个玻璃图标按钮；下方是题材、标题、规格行和播放控制，最底下一行左边是显示器标签（多屏时可点开切换），右边是「打开 Lumen ↗」。
- **app 内的 Steam 创意工坊**（用户要求）：
  - **数据**：新增 `Library/Steam/WorkshopCatalog.swift`，不需要账号或 API key。`steamcommunity.com/workshop/browse` 公开页给出有序的条目 ID（排序、搜索、类型/题材标签、分页都由 URL 参数控制，并固定排除 Application 和 Mature）；`ISteamRemoteStorage/GetPublishedFileDetails` 一次批量返回 30 条的标题、预览、大小、标签、订阅数和收藏数。请求不带 cookie，也不发送任何用户信息。只有下载才用用户的登录，复用 `SteamWorkshop.download`。
  - **接口改动**：`AppModel` 新增 `workshopBrowser: WorkshopBrowser`，让浏览状态在切换标签页时保留。新增 `UserDefaults` 键 `workshopSource`（`steam` / `local`）。工具栏「添加壁纸」菜单改为「浏览 Steam 创意工坊」和「本机上的 Wallpaper Engine 项目」两项。
  - **界面**：新增 `UI/Workshop/SteamWorkshopView.swift`，包括搜索框（和工具栏搜索同步）、类型标签、排序（热门可选时间段 / 订阅最多 / 最新发布 / 最近更新，搜索时为「最相关」）、分级（全年龄 / 全年龄及轻度敏感）、刷新、题材标签，以及无限滚动网格。卡片悬停时播放 GIF 并显示下载按钮，角标显示排队 / 进度 / 正在加入 / 已在资源库。详情弹窗：小 GIF 完整显示在模糊铺底之上，配说明、标签、下载或打开、在 Steam 上查看。未登录时点下载会打开登录面板并给出提示。原来的本机项目页保留为「本机」模式。新通用组件 `GlassSegmentedControl`，资源库的网格/列表切换也改用它。
  - **能耗与流量**：只在浏览时联网；`LazyVGrid` 只加载可见卡片，离开屏幕即取消。预览图走磁盘缓存，网格里只解码首帧，悬停才播动画。最近 8 个查询的结果缓存在内存里，返回上一个查询不重新请求。
- **验证**：build 通过，unit 42/42。实机检查了热门列表、搜索「cherry blossom」、滚动自动加载第 2、3 页、详情弹窗、「本机」模式、菜单栏面板，补了 53 条 zh-Hans。**没有实际点下载**：那会用用户的 Steam 账号把条目写进资源库，下载链路本身是已有并经用户实测的，留给用户验证。
- **局限 / 后续**：依赖创意工坊公开页的 HTML 里有 `filedetails/?id=` 链接，Steam 改版后可能需要调整（如需更稳，可改走已登录 CM 会话的 `PublishedFile.QueryFiles`）；英文复数「1 favorites」未处理。

### 2026-11-24 · claude · `claude/T30-ui-redesign` 第二轮（按用户反馈，未提交）

- **用户反馈**：按钮紫色太艳，透明按钮里更明显；菜单栏不好看，大紫按钮丑，文字看不清；对齐不到位。
- **根因**：系统 `.glass` 按钮会继承环境里的 `.tint`。根视图设了 `.tint(Theme.accent)`，所以所有次要按钮都成了高饱和紫色。
- **改法**：
  - **调色**：强调色改为灰调薰衣草 `#8E85D6`，`AccentColor` 资源同步修改，只用在开关、滑块和焦点上。状态色整体降饱和。
  - **按钮自绘**（`LumenButtonStyle`）：主按钮是米白胶囊配深色字，每个区域只放一个；次要按钮是中性 Liquid Glass；图标按钮是玻璃圆。菜单标签用同一套外观（`ChromeLabel`）。高度按 controlSize 分三档：24、28、34。工具栏里的按钮仍用系统玻璃。
  - **筛选标签**：选中改为米白底配深色字，不再用紫色填充。`IconWell` 默认改为中性白，只在需要表达状态时着色（例如绿色表示已省电）。
- **菜单栏面板重做**：
  - 强制深色（`.environment(\.colorScheme, .dark)`）。原来面板跟随系统浅色模式，导致「LUMEN」字标和开关看不清。
  - 改为居中的海报式布局：作品渐隐进它自己的氛围色，下方依次是标题（最多两行）、规格行、状态胶囊。
  - 播放控制：中间是 60pt 的米白暂停圆钮，两侧是不带底的普通图标。
  - 快捷设置改为 2×2 的控制中心式磁贴，开启时图标圆变白；播放速度磁贴是一个菜单。
- **对齐**：
  - Smart pause 固定四列，磁贴等高（112pt）、文字单行，原来自适应网格会在宽窗口多出一个空列。
  - 卡片标题去掉 2pt 缩进，和作品边缘齐平。
  - 资源库那一行控件统一为 28pt，网格/列表切换改成同款玻璃胶囊。
  - 详情页预览改为铺满内容列，左右边缘和标题、面板对齐。高度跟随窗口，宽窗口下是宽银幕比例，最高不超过 16:9。
  - 播放列表的间隔选择改为同款玻璃菜单。
- **整体复查后追加的改动**：
  - 工具栏下方滚动时加柔和边缘效果，内容不再生硬地穿到工具栏按钮后面。
  - 创意工坊卡片：类型写进说明文字，已在资源库的显示小角标，「加入资源库 / 打开」只在悬停时出现。
  - 首页舞台的操作按钮不再被挤压截断。
  - 中文「Playing on %@」改为「播放中 · %@」。
  - 菜单标签合并成一个辅助功能元素，不再被读成三段。
- **验证**：build 通过，unit 42/42。窗口处于激活状态时实机截图检查了首页、资源库网格和列表、视频详情、场景详情、创意工坊、创作编辑器、播放列表和菜单栏面板，没有饱和紫色，同一行控件高度一致。新增 1 条 zh-Hans（加入资源库），「View」标为 stale。

### 2026-11-24 · claude · `claude/T30-ui-redesign`（待验证，未提交）

- **方向**：「夜间画廊」。窗口按当前壁纸取色，界面元素退到玻璃和细线后面。保留宽体展示字体和紫色强调色；壁纸名改用标准宽度，因为大多含中日文，宽体只对拉丁字母生效。详见重写后的 `docs/DESIGN.md`。
- **氛围背景**：`ThumbnailCache.atmosphere(for:)` 模糊后按平均亮度做曝光增益（目标线性 0.022），并把单通道上限钳在 0.10。亮图压暗、暗图略提，白字对比度保持在 7:1 以上。每张壁纸只算一次并缓存，没有每帧开销。
- **页面**：
  - 首页改为「舞台」：左边是装框的当前壁纸（悬停 350ms 后播放预览），右边是说明栏，含问候、标题、状态、操作（自定义 / 随便来一张 / 暂停 / 更多）、多屏切换和三项统计。下面依次是最近添加、喜欢、实时渲染三排卡片，以及 Smart pause。
  - 资源库新增网格/列表切换，新 `UserDefaults` 键 `libraryLayout`。列表的标题、时长、大小三列可点表头排序。分类改为安静样式的筛选标签。
  - 详情页：预览按窗口高度给出明确的 16:9 尺寸（修复了实时渲染器在滚动视图里被拉满整宽的问题）。左栏是位置与缩放、自定义，右栏是新的「简介」面板（类型、分辨率、编码、大小、来源、创意工坊 ID、标签等）和优化卡。
  - 创作编辑器预览下方加了「More to try」，可直接切换其他着色器。
  - 播放条：缩略图改成胶囊形，加了「随便来一张」。
  - 创意工坊、播放列表、菜单栏面板、两个弹窗统一用新组件。
- **新组件**：`Eyebrow`、`SectionLink`、`LumenPanel`、`IconWell`、`InfoRow`、`HairlineDivider`、`artworkFrame()`，`FilterChip(style: .quiet)`，`WallpaperDescriptor`（统一描述一张壁纸的文字）。`AppModel.surpriseMe(on:)` 合并了菜单栏原来的随机逻辑。
- **顺手修的**：场景/网页卡片悬停时，方形预览 GIF 不再在 16:9 卡片里留黑边（`AspectFillImageView`）。菜单栏把场景也写成「实时渲染」的问题已改。列表行和简介面板不再把 `author` 字段当作者显示，它其实是来源标签（"You"、"Steam Workshop"），改为显示真实来源。
- **调试**：新增 `-LumenDebugWindowSize 1280x840`（只在 Debug 构建生效），已记入 ARCHITECTURE。注意 `-LumenDebugCaptureDir` 用离屏方式截图，画不出 Liquid Glass 和深色外观，检查 UI 请用真实窗口截图。
- **本地化**：`xcodebuild -exportLocalizations` 同步后补齐 25 条 zh-Hans，字符串目录保持原有格式和顺序。
- **验证**：`Tools/test.sh build` 通过，`unit` 42/42。没碰场景引擎，未跑 scenes/shaders。在 1020×732 和 1280×840 下逐页实机截图（首页、资源库网格/列表、详情、创意工坊、创作及编辑器、播放列表、菜单栏面板），中文界面无截断。
- **没做 / 下一步**：设置窗口仍用系统原生表单（有意保留）。场景卡片发虚要靠 T32 的高清封面帧。用户确认观感后再提交并合并。

### 2026-11-23 · claude · 收尾：合并全部任务、接手 T12 第二批与 T11、发布 0.1.0

- **合并**：
  - 先在各自分支提交未提交的改动：T29 `c5afad0`、T28 `22b3a36`、T26 `e92c19a`、T27 `1915d89`、T12 第一批 `0ce75b2`。
  - 依次合并到 `main`。`project.pbxproj` 冲突按约定重新 `xcodegen generate`。`WallpaperDetailView.swift` 冲突两边都保留：T26 的降级提示加上 gemini 的新按钮组。
- **T12 第二批**（gemini 额度用尽，claude 接手，分支 `claude/T12-ui-polish-batch2`）：
  - 播放列表、创作页和着色器编辑器、菜单栏面板、添加网页弹窗、锁屏预览全部改用 `Theme` 令牌，并删除旧别名。
  - 新增 `EmptyStatePanel`，资源库和播放列表的空状态共用。新增 `Surface.recessed` 和 `TypeScale.panelTitle` 两个令牌。
  - 修了一个辅助功能问题：壁纸卡片、播放列表卡片、首页显示器卡片原来只响应鼠标点击，VoiceOver 无法打开，现在补了辅助功能动作。
- **T11**：`xcodebuild -exportLocalizations` 同步字符串目录后，补齐 158 条 zh-Hans，原有译文无一丢失。新增 `InfoPlist.xcstrings` 翻译系统音频授权提示。术语：Steam Guard → Steam 令牌，Workshop → 创意工坊，引号用「」。
- **验证**：build 通过；`unit` 42/42；`shaders` 316/316；`scenes` 75/75、0 洋红；`steam` 通过；中文界面逐页截图，无截断。
- **发布**：`Tools/release.sh` 生成 0.1.0 通用版 DMG（arm64 + x86_64，临时签名），已推送并发布到 GitHub 私有仓库。用户运行 `Tools/make-signing-identity.sh` 之后，再打的包会改用固定的本地证书签名。
- **后续可做**：用户运行证书脚本后验证权限跨构建保留；真实 MetricKit 回调；有开发者账号后改为 Developer ID + 公证 + Sparkle。

### 2026-11-23 · gpt · `gpt/T26-scene-adaptive`（待验证）

- 以实机 `DesktopHost` 临时可见区域、原生 2940×1912 drawable 和 30fps 播放上限校准阈值。轻场景 GPU p50 约 2.4ms、实测 30fps，重场景约 22–27ms 开始掉帧。以帧间隔的 65% 为阈值，8 个稀疏样本有 6 个超限才减小像素预算，最多三次。按约每秒四次读取已有 Metal 时间戳，未加 GPU pass；重建时尽量延续当前画面，仅内存压力时先释放旧资源。
- Elisa 的实际渲染尺寸 3266×1837→2771×1559，轻场景 1700×956 保持原档、继续 30fps。重场景的短测未证实能维持 30fps。模拟内存压力复现暂停期间延迟重载、恢复后低分辨率加载、预算耗尽显示预览图。结束后撤销临时窗口，系统壁纸未变。
- Debug 构建、42/42 XCTest、75/75 场景、0 洋红、316/316 着色器通过。`Tools/test.sh stability 3808922316 5` 连续绘制 6,992 帧，内存 −0.3 MiB、Metal 分配不变、末段 GPU p50 +5.23ms（在 25% 容差内）。中途重叠的桌面探针带来一次 GPU 争用尖峰，内存始终稳定。日志在 `build/tools/stability.log`。
- T11 依赖 T12 每批实际合并。已检查 main，第一批仍在 Gemini 工作树。

### 2026-11-23 · gpt · `gpt/T27-local-release`（待验证）

- XcodeGen 为 Debug/Release 自动解析 `Lumen Local Signing`，支持指定指纹和临时签名。独立钥匙串验证两个 Xcode 构建的证书指定要求一致，并验证同一证书签署的两个 Lumen 版本要求一致。测试钥匙串已移除，搜索列表复原。
- `Tools/release.sh` 从项目版本生成双架构 DMG、Applications 链接和 SHA-256。Debug 构建通过，Release DMG 已只读挂载验证签名、版本、内置空更新源和 arm64/x86_64。
- General 的 Application 分区沿用 `SMAppService` 登录启动，补上系统批准入口；可选 HTTPS 版本源只在用户点击时请求。MetricKit 崩溃和卡顿报告保存在本地。版本解析和日志去重、保留上限已复测。
- 用户本人运行证书脚本后验收系统音频权限跨构建保留；系统生成的真实 MetricKit 崩溃/卡顿回调待验证。后续公证需切换 Developer ID Application、Hardened Runtime 和安全时间戳，再通过 notarytool 提交并 stapler 装订。

### 2026-11-23 · gpt · `gpt/T29-parent-opacity`（复核）

- 在实机 `DesktopHost` 的原生 Metal 呈现帧确认《清风·兰亭》红印章。桌面窗口完全被遮挡时，临时提高测试窗口层级并保留 2940×1912 drawable，结束后撤销窗口，系统壁纸未变。前后差异仍仅在印章区域；作者预览 67.48→67.25，保留数值验收差异。

### 2026-11-23 · gpt · `gpt/T27-local-release`（进行中）

- T26 实现及 Debug/XCTest 验证完成，剩场景回归和桌面校准。认领 T27：现有登录启动控件移入 General 的应用分区，同区加入可选更新检查，其他设置 UI 交由 T12。加入项目级签名配置、DMG 和本地 MetricKit 日志。

### 2026-11-23 · gemini · `gemini/T28-particle-control-points`（待验证，未提交，工作树 `build/worktrees/gemini-T28`）

- **做了什么**：
  - 统一粒子控制点解析（`ParticleSystem.controlPointPosition(_:)`）：支持 `flags & 1`（锁定鼠标，移出桌面保留 `lastPointer`、从未收到指针时退回 `offset`）、`flags & 2`（世界/画布空间坐标经 `worldToLocal` 转换，涵盖 `Bird.json`/`thunderbolt.json`）、`flags & 4`（链接父系统控制点 `parentcontrolpoint`），并解析 `instanceoverride.controlpoint0..7` 覆盖根系统控制点偏移。
  - 发射器 `Emitter.controlPoint`（默认 0）在 `spawn` 时以 `controlPointPosition(cp) + emitter.origin` 生成新粒子，已生成粒子保持原位形成拖尾；同步修复 `.rope` 渲染器淘汰过期粒子时用保序 `remove(at:)` 替代 `swapAt`，避免拖尾超过生命周期后头尾折返乱连。
  - 实现 `mapsequencearoundcontrolpoint`（含 `count`/`axis`/`speedmin`/`speedmax`/`bounds`/`limitbehavior` 顺序排布与绕轴速度旋转）与 `mapsequencebetweencontrolpoints`（含 `arcamount` 弧度）；`vortex` 支持 `controlpoint` 中心与 `flags & 1` 环形距离；补 `reducemovementnearcontrolpoint`。
  - `SceneInstance` 传入带视差补偿的 `pointerCanvas` 给粒子层；`SceneLoader` 预热时传入 `localModel.inverse`。
  - `Tools/SceneHarness` 新增 `LUMEN_POINTER`（单点 `0.3,0.6` 或分号分隔轨迹 `0.2,0.7;0.8,0.3`）与 `LUMEN_FRAMES` 环境变量，并更新 `docs/TESTING.md`。
- **CPU/GPU/能耗代价**：沿用 T22 既有 `usesPointer` 按需轮询机制（无鼠标粒子时不开启轮询），控制点解析为每帧/每粒子 O(1) 向量运算，无额外 GPU pass、内存分配或能耗增加。
- **验证结果**：
  - `Tools/test.sh build`：Debug 构建通过。
  - `Tools/test.sh unit`：40/40 通过。
  - `Tools/test.sh shaders`：316/316 通过。
  - `Tools/test.sh scenes`：75/75 OK，0 FAIL，0 洋红；`Tools/test.sh visual 10` 75/75 全部计分，无退化。
  - `LUMEN_POINTER` 抽查：赛琳娜 `3516294127` 定点 `0.75,0.25` 在右上光标处生成 5 瓣旋绕樱花、轨迹 `0.2,0.7;0.8,0.3` 留下平滑斜向樱花尾迹；`3373818743` / `1723129994`（`.rope` 鼠标拖尾）45 帧（1.5s > 1s 寿命）轨迹连续无折返；`3593194513`、`3615984066` 画面正常。
- **未做 / 下一步**：等待审核与合并 `gemini/T28-particle-control-points`；按分工下一步进入 **T12 第一批**（全局 UI 打磨：`docs/DESIGN.md` + `Theme.swift` + 主窗口核心页面 + 前后截图）。

### 2026-11-23 · gpt · `gpt/T26-scene-adaptive`（进行中）

- 认领 T26。先在桌面窗口测量 30fps 实际 GPU 用时，再实现预算下调和加载/内存降级。详情页通过 `WallpaperEngine` 查询当前场景的降级说明，沿用现有渲染器接口。

### 2026-11-23 · gpt · `gpt/T29-parent-opacity`（待验证）

- 普通父层只传递可见性，世界变换和骨骼附着继续沿用同一条父链。透明度留在各图层，组合层仍在输出时应用一次。没有新增逐帧计算或 GPU pass。
- `Tools/test.sh visual diff <before> <after> [N]` 输出两轮渲染的全分辨率 RGB 像素差、跳过原因及分页拼图。原作者预览评分入口继续可用。保存的同一批次自比 75/75 零差异，真实前后批次 75/75 配对、0 跳过。
- Debug 构建、40/40 XCTest、316/316 着色器通过。全库 75/75 成功、0 洋红。Metal 夹具验证零和部分父层 alpha、子层自有 alpha、父层位移、隐藏链、`disablepropagation`、组合层及隐藏合成源。
- 《清风·兰亭》确认恢复作者预览中的红印章，实际变化的 12,994 像素全在印章区域。作者预览为 224×224 方形且印章显得更小、更淡，全图相似度 67.48→67.25。复测 Elisa 与 Chisa 的变化集中于拆分阴影和日期，分数降幅 ≤0.03。檐花穗影重复单版本渲染也有动画差异，另可见透明父层下原有控件恢复。原计划的「分数不降」尚未全部满足，保留实际结果供画面验收。
- 串行全库对照的加载中位 0.48→0.43s，GPU 单帧中位 4.57→5.13ms。连续 60 帧对照中，《清风》8.67→8.64ms、Elisa 15.16→15.36ms、檐花穗影 7.23→7.57ms。报告、逐帧对照和复测日志都在工作树的 `build/tools`。

### 2026-11-23 · gpt · `gpt/T29-parent-opacity`（进行中）

- 基于 `main` 的 `5521c25`。核对父层可见性、变换与组的合成透明度，新增 T17 的前后帧像素对比。

### 2026-11-23 · claude · 重新均衡分工（未改代码）

- 用户确认：Steam 扫码登录和下载成功，音频响应正常。T04、T10、T23 标为完成。
- 用户没有 Apple 开发者账号，暂不公证。T27 改为：自签名证书固定签名身份（解决每次构建都要重新授权），DMG 打包，安装说明，开机启动，只做检查更新（不接 Sparkle），本地崩溃记录。
- 按工作量重新均分，两条线预计同时做完：
  - Gemini：T28 → T12（分两批）。T28 的代码是它写的，接着做最快。
  - GPT：T29 → T26 → T27 → T11。T11 跟着 T12 的批次翻译，不用等界面全部改完。
- 详细说明见 [`PLAN.md`](PLAN.md)。

### 2026-11-23 · claude · 收尾阶段分工（未改代码）

- 用户实测第 6 阶段合并版：「绝大部分正常且清晰」。T05、T16、T21、T22 标为完成；T04（音频手感）、T23/T10（Steam 扫码）仍待用户确认。
- 查了用户报的两个问题，都是共性问题：
  - 「清风」印章：父层 alpha 被乘到子图层，归为 T29。
  - 赛琳娜的鼠标樱花：粒子控制点只用在吸引算子里，归为 T28。
- 根因、证据和场景清单写在 [`PLAN.md`](PLAN.md)。
- 分工：
  - GPT：T29 → T28 → T26 → T27；用户反馈 Steam 问题时 T23 插队。
  - Gemini：T12（参考 Wallper 的界面打磨，先出 `docs/DESIGN.md`）→ T11。
- 唯一的文件交集是设置页：T27 只加最朴素的「开机启动」和「检查更新」，样式由 Gemini 统一调。

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
