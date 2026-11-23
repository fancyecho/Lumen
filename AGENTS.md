# Lumen · 协作开发约定（Claude / Gemini / GPT 共用）

Lumen 是 macOS 原生动态壁纸播放器（SwiftUI + AppKit + AVFoundation + Metal，最低 macOS 26）。
本文件是所有 AI 编码助手的唯一共同约定；`CLAUDE.md`、`GEMINI.md` 只是指向这里的入口。

**每次开工前按顺序读：**

1. 本文件（规则）
2. [`docs/STATUS.md`](docs/STATUS.md)：当前进度、任务板、交接日志
3. 需要时再读 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)（代码结构）和 [`docs/TESTING.md`](docs/TESTING.md)（怎么验证）

## 1. 协作流程

1. **认领**：在 `docs/STATUS.md` 的任务板里选一行，把「负责」填成你的身份（`claude` / `gemini` / `gpt`），状态改为「进行中」。被别人认领的任务不要动；想接手先问用户。
2. **分支**：每个助手在自己的分支上工作，命名 `<身份>/<任务ID>-<简述>`，例如 `gemini/T07-clipping-masks`。
   - 同一台机器上同时开工时用 `git worktree`，不要在同一个工作目录里互相覆盖。
   - 不要直接在 `main` 上改代码。
3. **范围**：只改任务需要的文件。
   - 发现别的问题时，记到任务板「待认领」，不要顺手修。
   - 跨模块的接口改动（如 `WallpaperRenderer` 协议、`Wallpaper` 模型、`AppSettings` 键）先在交接日志里写明，再动手。
4. **验证**：至少保证 `Tools/test.sh build` 通过；改到场景引擎还要跑 `Tools/test.sh scenes` 和 `shaders`，结果不能比 STATUS.md 记录的基线差。
5. **交接**：结束时更新 `docs/STATUS.md`：
   - 改任务状态。
   - 在「交接日志」**顶部**加一条：日期、身份、分支/提交、做了什么、没做完什么、下一步建议。
   - 基线数字变了也一并更新。
6. **提交**（用户规则，必须遵守）：
   - **只有用户要求时才 commit / push / 合并。**
   - 只 `git add` 自己改的文件，禁止 `git add -A` / `git add .`（工作区里可能有别的助手未提交的改动）。
   - 提交信息用英文祈使句，一行概括，如 `Add clipping masks to scene renderer`。

## 2. 工程规则

- **工程文件**：`Lumen.xcodeproj` 由 `project.yml` 通过 `xcodegen generate` 生成。
  - 新增或删除源文件后重新生成。
  - 不要手改 `project.pbxproj`。
  - 合并冲突时直接重新生成，不要手工合并。
- **语言与并发**：Swift 5 模式，`SWIFT_STRICT_CONCURRENCY: minimal`。模型和 UI 状态用 `@MainActor @Observable`；重活放后台队列或 `Task.detached`。
- **场景着色器**：Metal 语言版本固定 `.version3_2`，见 `SceneMaterials.swift`。不要改成默认版本，否则 app 内与命令行编译结果会不一致。
- **性能优先**：这是常驻桌面的应用，新功能要说明 CPU/GPU/能耗代价。
  - 必须遵守现有自动暂停策略：遮挡、锁屏、低电量等，见 `Engine/Policy`。
  - 渲染要按像素预算和帧率上限，不要无条件满帧。
- **本地化**（见 STATUS.md「UI 规则」）：
  - 展示性英文标题保留英文，用 `Text(verbatim:)`；操作性文字走 `Localizable.xcstrings` 的 zh-Hans。
  - 以 `String` 传递的文案要用 `String(localized:)`。
  - 新增字符串目前只写英文，翻译统一在 UI 打磨阶段补。
- **UI 风格**：参考 Wallper 的观感，但不照抄；保留 Lumen 自己的识别度（宽体展示字体、紫色强调色、Liquid Glass 按钮）。颜色和尺寸用 `Theme`。
- **注释**：解释「为什么」，不复述代码。
- **第三方代码**：参考项目 WallpaperMachine、MirageWallpaper 是 GPL-3.0，**只能参考文件格式和思路，不能复制代码**。

## 3. 安全与测试红线

- **不要动用户的其他应用和数据**：
  - Wallper、WallpaperMachine 只读。
  - `~/Library/Application Support/WallpaperMachine/` 是测试语料，只读，绝不写入。
- **测试后必须复原**：
  - 测试导入的壁纸、改过的桌面/锁屏设置都要还原。
  - 用户可能在你测试期间自己导入内容，清理时按 `addedAt` 只删自己的。
  - 不要整体覆盖 `defaults` 域，只改、只还原具体键。
- **账号**：
  - 不要替用户输入 Steam 或任何密码；登录由用户在 app 里自己完成。
  - 不要把用户的邮箱、账号名写进代码、提交或外部请求。
- **构建产物**：`build/` 已被 gitignore，测试输出都放那里。
