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

```bash
Tools/test.sh shaders
```

把 assets 和语料里的全部 WE 着色器翻译成 MSL 再编译，输出通过数和错误分类。

- `Tools/test.sh shaders v`：打印每个失败项。
- `Tools/test.sh shaders dump:<名字片段>`：把翻译结果写到 `build/tools/dump.metal`，便于排查。

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
