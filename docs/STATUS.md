# Lumen · 进度与任务板

> 所有助手共同维护。开工前读，收工时更新（规则见 [`AGENTS.md`](../AGENTS.md)）。
> 最后更新：2026-11-23 · claude

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
| 加载耗时（着色器缓存命中） | 中位 0.37s，最大 1.5s |
| GPU 帧时间（约 2MP） | 中位 3.7ms，p90 8.4ms，最大 13.5ms |
| 着色器翻译 + 编译 | 298/316 通过（失败集中在 3D 光照、体积光和少数工坊自带着色器） |
| 明显洋红色块（裁剪蒙版缺失） | 1 个（3808922316）；白块不会被自动检测 |
| SteamCMD 提示解析（假 steamcmd） | 通过 |

## 3. 任务板

状态：待认领 / 进行中 / 待验证 / 完成。认领时把「负责」改成你的身份。

| ID | 任务 | 模块 | 优先级 | 状态 | 负责 | 备注 |
|---|---|---|---|---|---|---|
| T01 | 提交阶段 3/4 的改动 | 全局 | 高 | 完成 | claude | `23d33aa` |
| T02 | 木偶变形（puppet warp）：MDL 解析、骨骼蒙皮（genericimage4 `SKINNING` / `g_Bones`）、animationlayers | 场景 | 高 | 待认领 | | 语料中 139 处使用；目前角色静止不动 |
| T03 | 图层裁剪蒙版（clipping masks） | 场景 | 高 | 待认领 | | 导致洋红/白块，例：3808922316、3615984066、3397287008 |
| T04 | 音频响应：系统音频频谱（`g_AudioSpectrum*`、脚本 audio buffer） | 场景/Web | 中 | 待认领 | | 需要系统音频采集（Core Audio tap 或 ScreenCaptureKit），注意权限和能耗 |
| T05 | 场景/Web 壁纸的锁屏：录一段循环视频交给 `LockScreenVideoBuilder` | 锁屏 | 中 | 待认领 | | 现在保留上一个视频锁屏（`.keepingPrevious`） |
| T06 | SceneScript 鼠标事件（cursorClick/Down/Up/Move 等） | 场景 | 中 | 待认领 | | |
| T07 | 片头/时间线类场景（如 3436945972），以及 3463692991 的布局问题 | 场景 | 中 | 待认领 | | |
| T08 | 3D 模型与光照（`PerformLighting_V1`）、体积光 | 场景 | 低 | 待认领 | | 对应 18 个编译失败的着色器中的大部分 |
| T09 | 为解析器补 XCTest：pkg、tex、project.json、着色器预处理、SteamCMD 输出 | 测试 | 中 | 待认领 | | 目前只有 `Tools/` 下的命令行回归工具，没有 XCTest target |
| T10 | 真实 Steam 登录和下载的端到端验证 | Steam | 中 | 待认领 | 需用户 | 必须用户本人登录，助手不得代输密码 |
| T11 | 新界面文案翻译（Workshop、Steam 面板、WE 设置、属性面板、添加网页） | UI | 低 | 待认领 | | 放到阶段 5 |
| T12 | 全局 UI 打磨 | UI | 低 | 待认领 | | 等功能完成后再做（用户要求） |

不做：WE 的 application 类型（只能在 Windows 上运行）。

## 4. UI 规则（用户定的）

- 观感以 Wallper 为基准，但要有自己的识别度，不照抄。
- 「高级感」的展示标题和眉标保留英文，例如 "Your desktop, in motion."、"Smart pause"、"LIBRARY"。
- 设置、按钮、菜单、状态、提示、错误和说明性副标题都翻译成 zh-Hans。
- 用户的 macOS 是英文系统；要看中文，在 app 内切换语言，或用 `-AppleLanguages "(zh-Hans)"` 启动。

## 5. 交接日志（新的写在最上面）

### 2026-11-23 · claude · `main`：`23d33aa`（代码）+ 文档提交

- **做了什么**：
  - 完成阶段 3（Web 壁纸）和阶段 4 主体（WE 场景渲染器、Workshop 页、SteamCMD 下载、属性面板、WE 设置页）。
  - 把回归工具迁入 `Tools/`。
  - 建立本协作文档：`AGENTS.md`、`docs/`。
- **没做完**：任务板 T02–T11。
- **注意**：
  - 测试时导入的壁纸已清理。资源库里现有的 WE 项目是用户自己导入的，不要删。
- **建议下一步**：用户打算让 Gemini 接手剩余工作。建议先做 T03（裁剪蒙版）：范围最小，回归工具能直接看到洋红块是否消失。之后再做 T02（木偶）。两者都改 `SceneLoader` 和 `SceneInstance`，不要并行做。
