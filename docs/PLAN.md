# Lumen · 第 6 阶段计划：通用问题与可用性

> 2026-11-23 · claude 起草。用户实测后定的方向：**优先修通用、共性的问题，不再为个别壁纸做专门适配**；界面打磨放到最后。
> 解决思路可以参考 WallpaperMachine 和 MirageWallpaper 两个开源项目，但它们是 GPL-3.0，**只看文档和思路，不复制代码**（见 `AGENTS.md`）。
> 任务由 claude 分配；接手的助手在 `docs/STATUS.md` 任务板上把状态改成「进行中」即可，不用再「认领」。

## 分工原则

- **GPT（6.2，solmax）**：长链路、协议、系统状态这类必须严谨的工作，以及测试和回归工具。
- **Gemini（neon，high）**：渲染、输入、引擎行为这类大块功能实现。
- **Claude**：排查根因、写任务说明、审查和合并、维护文档。

## 用户反馈的问题与根因

| 问题 | 根因（已查实） | 参考项目的做法 |
|---|---|---|
| 锁屏要去系统设置里手动选一次 Lumen 的视频才生效 | Lumen 只写了壁纸存储里的 **Idle**（屏保）选择。macOS 14+ 的锁屏播放的是 **Desktop** 选择里的 Aerial，所以要等用户在系统设置里选一次才生效。另外 `StillFrameSync` 会把每个桌面空间的 Desktop 改成静态图，这同样会盖掉 Aerial。 | WallpaperMachine 的文档：「锁屏动画替换 Desktop，屏保替换 Idle」；每个显示器的覆盖项必须**同时**带 Desktop 和 Idle 字段，否则 macOS 会拒绝整个存储。它在 macOS 26+ 还用 ExtensionKit 壁纸扩展实时渲染锁屏，但依赖私有 XPC 协议，太脆弱，暂不跟进。 |
| 鼠标跟随（眼睛跟着鼠标转、光标特效）没有反应 | `DesktopPointerMonitor` 依赖全局 `mouseMoved` 事件监听。指针停在桌面上时，底下的窗口（Finder 桌面或 Lumen 不接收鼠标的壁纸窗口）不要移动事件，系统很可能就不生成，监听自然收不到；点击照常能收到。另外 `g_EffectTextureProjectionMatrix` 及其逆矩阵目前一律给单位矩阵，跟光标相关的特效坐标不对。 | WallpaperMachine：全局/本地 `NSEvent` 监听只用来唤醒，真正的位置每 16ms 轮询一次（`CGEventCreate` / `NSEvent.mouseLocation`）；点击先用 `windowNumberAtPoint` 加窗口层级判断是不是落在桌面上；只有确实用到指针的场景才轮询。 |
| Steam 登录不上 | `SteamCMD/logs/console_log.txt` 里第一次是 Invalid Password（可能输错，也可能是 PTY 传密码的问题），之后每次都是 Retrying… → Timeout / No Connection。用户的系统代理是 127.0.0.1:7890。按 WallpaperMachine 的说法，steamclient 会跟随系统的 HTTP/HTTPS 代理，但不读环境变量、也不支持纯 SOCKS，所以连不上可能是代理或网络本身的问题。另外让用户把密码交给 SteamCMD，本身体验也差。 | 两个项目都另做了**原生 Steam 客户端**：扫码登录（`IAuthenticationService/BeginAuthSessionViaQR` + `PollAuthSessionStatus`），refresh token 存钥匙串，通过 WebSocket 登录连接管理器（CM），再从 CDN 拉清单和分块，自己解密、解压、校验。SteamCMD 只作兜底（WallpaperMachine 默认仍用 SteamCMD，Mirage 完全不用）。 |

## 任务

### T21 · 锁屏改为写 Desktop 选择（Gemini，高）

- **目标**：在 Lumen 里开启锁屏后，**不需要去系统设置**，锁屏就播放 Lumen 生成的视频（包括场景、网页录出来的那段循环）。
- **做法**：
  - `AerialSystem.select` 同时写 Desktop 选择（锁屏用）和 Idle 选择（屏保用，可以做成单独开关，默认跟随）。覆盖范围：`SystemDefault`、`AllSpacesAndDisplays`、`Displays/<id>`，以及 `Spaces/<id>/Default` 和 `Spaces/<id>/Displays/<id>`。每个显示器的覆盖项必须同时有 Desktop 和 Idle。
  - 第一次替换前，把原内容完整备份进 `InstalledState.backup`，关闭锁屏时原样恢复。原有的备份/恢复逻辑是给 Idle 写的，要扩展到 Desktop。
  - 和 `StillFrameSync` 协调：锁屏开启时，主显示器（以及锁屏跟随的那块屏）**不再**写静态图到 Desktop，Aerial 本身就是当前壁纸录出来的，调度中心里看到的也是它。其他显示器照旧。
  - 确认：在本机上开启锁屏后读 `Index.plist`，所有该改的 Desktop/Idle 都指向 Lumen 的资产 ID；锁屏一次确认在播；关闭后恢复成原来的内容。
- **注意**：这是在改用户的系统设置，测试前先把 `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` 备份到 `build/`，测完复原。只改 Lumen 自己的条目。
- **涉及文件**：`Lumen/Engine/LockScreen/AerialSystem.swift`、`LockScreenManager.swift`、`Lumen/Engine/StillFrameSync.swift`。

### T22 · 鼠标输入管线（Gemini，高；T21 之后）

- **目标**：所有交互式壁纸（场景的视差、跟随光标的特效、`cursor*` 脚本事件，网页的 mousemove/click）在指针停在桌面上时都能响应。
- **做法**：
  - 位置改成**轮询**：只要有「需要指针」的壁纸在播放，就以渲染帧率（最多 60Hz）读 `NSEvent.mouseLocation`；位置没变就不做命中判断。事件监听只负责唤醒和转发点击。
  - 只在需要时才轮询：场景用到了 `g_PointerPosition`/`g_PointerPositionLast`、视差，或者脚本用到了 cursor 事件；网页注册了鼠标监听。其他情况不轮询，省电。
  - 补上 `g_EffectTextureProjectionMatrix` 及其逆矩阵（特效贴图空间 ↔ 屏幕）的真实含义，跟光标相关的特效才会以图层为中心。
  - 核对 `g_PointerPosition` 的坐标系（原点和 y 轴方向）。
  - 确认：3287715210、3463692991 的眼睛跟着鼠标转；有视差的场景跟随鼠标；一个网页壁纸能收到 mousemove。命中判断仍然是「指针在桌面上才转发」。
- **涉及文件**：`Lumen/Engine/Policy/DesktopPointerMonitor.swift`、`WallpaperEngine.swift`、`Scene/SceneRenderer.swift`、`Scene/SceneMaterials.swift`、`Scene/SceneInstance.swift`、`Web/WebRenderer.swift`。

### T23 · 原生 Steam 客户端：扫码登录 + 创意工坊下载（GPT，高）

- **目标**：用户在 Lumen 里**扫码**登录 Steam（不输入密码），能下载自己账号可用的 Wallpaper Engine 创意工坊内容；走 `URLSession`，所以自动跟随系统代理。
- **分两步**：
  1. **SteamCMD 兜底先改好**（小）：把 console_log 里的真实错误分类给用户看（密码错误、连不上 Steam 服务器且提示检查代理/网络、Steam Guard、限流）；手机确认时提示在 Steam App 里选「Steam Client」；被拒的密码不自动重试；断线只在登录成功后才重试（最多 3 次，间隔约 2/8/30 秒）。
  2. **原生客户端**（大）：
     - 认证：`IAuthenticationService/BeginAuthSessionViaQR`，轮询 `PollAuthSessionStatus`，界面显示二维码；refresh token 存钥匙串（generic password，service 用 `app.lumen.steam-client`）；不记日志、不写别处。
     - 连接：通过 WebSocket（`URLSessionWebSocketTask`）连 CM，protobuf 消息，用 refresh token 登录。
     - 下载：先用 `PublishedFileService.GetDetails` 拿到 `hcontent_file`（清单 ID），再取 depot 解密 key 和 CDN 服务器列表，下载清单和分块，做 AES 解密、解压（zip/LZMA/zstd）和 SHA-1 校验，落盘后交给现有的 `importFiles`。
     - 保留 SteamCMD 作为「高级：用账号密码登录」的兜底入口。
- **注意**：只参考公开的协议资料和这两个项目的**文档**，不复制 SteamKit2 或 DepotDownloader 的代码（许可证不兼容）。不得替用户输入密码；真实账号测试由用户本人操作。
- **涉及文件**：新增 `Lumen/Library/Steam/Native/…`；改 `SteamWorkshop.swift`、`UI/Workshop/SteamPanel.swift`（界面先能用，打磨放到最后）。
- **验收**：协议各层（protobuf 编解码、清单解析、分块解密）都要有单元测试，可以用录好的样本数据；用户扫码登录后，能下载任意一个创意工坊壁纸并导入成功。

### T17 · 场景视觉回归工具（GPT，收尾）

- GPT 已经做完但还没提交，提交后合并。之后 T25 就靠它挑问题。

### T25 · 通用场景还原度（Gemini，中；T22 之后）

- 不再一个个修壁纸。先用 T17 的报告，再加上「不支持特性统计」（汇总所有场景的 `instance.unsupported`、编译失败的着色器、缺失的纹理），找出**影响场景最多的那几类问题**，按影响面从大到小修。
- 已知候选：木偶 `MORPHING`、特效投影矩阵（T22 会顺带补上）、文本排版细节、最后 1 个 3D 着色器。T20（海边摩托的白色裂纹）先看它属不属于某个共性类别，不是就暂缓。

### T26 · 能耗与稳定（未分配，中）

- 按实测 GPU 时间自适应渲染分辨率（先在 app 里校准阈值：桌面 30fps 下 GPU 不满载、频率偏低，测出来的时间会比连续渲染偏高）。
- 指针和音频都按需开关（T22 和已有的 T04 机制）。
- 场景加载失败或内存压力大时自动降级（降分辨率，或改用预览图）。

### T27 · 发布准备（未分配，中；UI 打磨之前）

- 开发者证书签名 + 公证 + Hardened Runtime。现在是临时签名，每次重新构建，系统音频、录屏之类的权限都要重新授权。
- 自动更新、开机启动、崩溃收集（本地）。

### 最后：T11 翻译、T12 全局 UI 打磨

## 待用户验证

- T04 跟着音乐动的手感；T16 清晰度；T05 锁屏（T21 修好之后再测一次）。
- 用户想自己试 Steam 的话：先确认代理软件开着、系统代理设成 HTTP/HTTPS（不要只开 SOCKS），再用 SteamCMD 登录一次；T23 完成后改用扫码。
