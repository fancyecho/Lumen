# Lumen · 测试与验证

用 XCTest 验证解析器，用命令行工具跑场景和着色器语料，并在 app 里验证实际效果。
工具编译产物和输出都在 `build/tools/`，已被 gitignore。

## 命令

```bash
Tools/test.sh build
```

用 xcodegen 重新生成工程，然后构建 Debug 版。产物在 `build/DerivedData/Build/Products/Debug/Lumen.app`。

```bash
Tools/test.sh unit
```

用 `LumenTests` scheme 运行解析器 XCTest，覆盖 `scene.pkg`、`.tex`、`project.json`、着色器预处理和 SteamCMD 输出。测试复用生产源码，不启动 Lumen，也不需要 WallpaperMachine 语料、网络或 Steam 账号。在 Xcode 中也可以选中 `LumenTests` scheme 后按 ⌘U。

```bash
Tools/test.sh scenes
```

渲染语料里的全部场景，第 2 秒各存一张 PNG。

- 每个场景一行：`OK` / `FAIL`、加载耗时、GPU 帧时间、粒子数、层数。
- 同目录还有 `<id>-ref.png`（作者的预览图），可对比效果。
- `magenta%` 表示洋红像素占比，大于 0 通常意味着缺纹理或缺裁剪蒙版。
- 只跑部分场景：`Tools/test.sh scenes 3808922316,3615984066 2.5`。第 2 个参数是 id 列表，第 3 个是渲染时刻（秒），第 4 个可选，是只加载的对象 id 列表。
- 设环境变量 `DUMPLAYERS=1` 会打印每层的纹理、uniform、特效步骤。
- 设 `LUMEN_FAKE_AUDIO=1` 会注入一段假频谱（低音强、高音弱），用来检查音频响应的着色器、粒子和脚本。
- 设 `LUMEN_POINTER=0.3,0.6`（单个归一化屏幕坐标，左上 `0,0`、右下 `1,1`）或 `LUMEN_POINTER=0.2,0.7;0.8,0.3`（分号分隔的多段路径）会注入模拟鼠标，用来验证跟随鼠标的粒子、着色器和交互效果；启用时默认以 30fps 连续模拟 30 帧（可用 `LUMEN_FRAMES=60` 调整）。
- 默认按 app 的 Balanced 场景预算（6MP）和 2560×1600 屏渲染；`LUMEN_DISPLAY=2560x1664`、`LUMEN_BUDGET=2000000` 可改。
- `LUMEN_BENCH=1`：每个场景连续渲染 60 帧取 GPU 时间中位数（GPU 频率升上来后的数字，比默认的单帧数字稳定）。
- `LUMEN_MEMORY=1`：打印每个场景加载后的 GPU 内存。


```bash
Tools/test.sh stability 3808922316 5
```

连续按 30 fps 节奏播放一个场景，默认 5 分钟。跳过前 5 秒热身，定期记录 GPU 帧时间中位数及 p90、进程内存和 Metal 分配量。比较最早和最后一个采样窗口，容许进程内存增长 32 MiB 或 10%、Metal 增长 16 MiB 或 10%、GPU 中位数增长 2 ms 或 25%，各取较大值。超出任一阈值或渲染失败时退出码为 1。日志为 `build/tools/stability.log`。桌面自适应阈值仍需用真实桌面帧校准，工具不经过窗口合成。

```bash
Tools/test.sh visual 10
```

在 `Tools/test.sh scenes` 后运行。按本轮生成的清单匹配渲染 PNG 与作者预览首帧，输出相似度最低的 N 个场景和对比拼图。省略 N 时取 10。每张拼图最多 10 组，左列为参与评分的渲染裁切区域，右列为作者预览。终端会给出 `build/tools/visual/` 下的产物路径，同目录的 `report.json` 保留全部分数、渲染批次和跳过原因。

评分先把渲染图居中裁切到作者预览的宽高比，再缩小到同样尺寸。分数取 70% 局部亮度 SSIM 与 30% RGB 色彩一致度，100 为最相似。动画时刻、作者构图和裁切都可能影响结果。 GIF 首帧的黑场和渲染中的片头也会拉低分数。排名用于安排人工抽查，无通过阈值。 [SSIM 原论文](https://eceweb.uwaterloo.ca/~z70wang/publications/ssim.html)

```bash
cp -R build/tools/scenes build/tools/scenes-before
# 修改引擎后，沿用同样的参数重新执行 Tools/test.sh scenes
Tools/test.sh visual diff build/tools/scenes-before build/tools/scenes 10
```

按两个批次的清单匹配同一场景。对同尺寸的渲染帧报告发生 RGB 变化的像素数、占比及平均通道差（0–255），按平均通道差排序，输出变化最大的前 N 组前后拼图。报告也记录尺寸不一致、渲染失败和缺失图片等情况。两轮应使用相同的渲染时间、画面预算、音频、图层筛选和 `LUMEN_BENCH` 设置。时钟、视频纹理和动画仍可能让画面产生变化。

```bash
Tools/test.sh shaders
```

把 assets 和语料里的全部 WE 着色器翻译成 MSL 再编译，输出通过数和错误分类。

- `Tools/test.sh shaders v`：打印每个失败项。
- `Tools/test.sh shaders dump:<名字片段>`：把翻译结果写到 `build/tools/dump.metal`，便于排查。

```bash
Tools/test.sh lockloop scene "<项目文件夹>"
Tools/test.sh lockloop web "<项目文件夹>"
```

把场景或网页壁纸录成锁屏用的循环视频（`build/tools/lockloop.mov`），**不安装到系统锁屏**。会编译整个 app 源码，第一次要几分钟。

```bash
Tools/test.sh steam
```

用 `Tools/SteamCMDFake/fake-steamcmd.sh` 模拟 SteamCMD，检查密码、Steam Guard、登录和下载路径的解析。

## 语料

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `LUMEN_SCENE_CORPUS` | `~/Library/Application Support/WallpaperMachine/Library` | 75 个场景，**只读** |
| `LUMEN_SCENE_ASSETS` | `~/Library/Application Support/WallpaperMachine/SceneAssets` | WE 共享 assets，**只读** |

在别的机器上，把这两个变量指向自己的 Steam 创意工坊目录（`steamapps/workshop/content/431960`）和 Wallpaper Engine 的 `assets` 文件夹即可。

## 合并前的最低要求

- `Tools/test.sh build`：无 error。
- 改到 `Engine/Scene`：
  - `scenes` 的 OK 数不少于 STATUS.md 里的基线。
  - 耗时没有明显变差。
  - 抽查相关场景的 PNG。
- 改到 `Engine/Scene/Shaders`：`shaders` 的通过数不少于基线。
- 改到 `Library/Steam`：`steam` 通过。
- 改到 UI：在 app 里打开对应页面看一遍，英文和中文都要看（`-AppleLanguages "(zh-Hans)"`）。
- 基线数字有变化时，更新 STATUS.md。

## 在真实桌面上测试

- 用户的 Mac 经常开着低电量模式，桌面也常被窗口挡住，Lumen 会自动暂停。测试时可以临时用 `defaults` 关掉对应的暂停策略，**测完把那几个键改回原值**。
- 用 `-LumenDebugImport` / `-LumenDebugApply` 导入并应用测试壁纸。测完要：
  - 删除自己导入的项目（按 `addedAt` 判断，不要删用户的）。
  - 还原 `displayAssignments`。
  - 确认系统桌面图片和锁屏没有被留在测试状态。
- Steam 的真实登录只能由用户本人在 app 里完成。
