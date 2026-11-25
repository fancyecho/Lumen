# Lumen · 安装与本地发布

Lumen 支持 macOS 26 或更新版本。DMG 包含 Apple 芯片和 Intel 两种架构。

## 安装和首次打开

1. 从你信任的发布来源取得 `Lumen-<版本>.dmg` 及同一版本的 `.dmg.sha256`。将两个文件放在同一目录，在该目录运行 `shasum -a 256 -c Lumen-<版本>.dmg.sha256`。
2. 挂载 DMG，将 Lumen 拖到「应用程序」，然后弹出 DMG。
3. 从「应用程序」打开 Lumen。当前构建使用本地签名，尚未由 Apple 公证。若 macOS 提示无法验证开发者，在确认来源和校验值后，前往「系统设置 → 隐私与安全性」，选择「仍要打开」并确认。只有这个 App 获得这次例外。 [Apple 的首次打开说明](https://support.apple.com/en-us/102445)
4. 如需在终端处理由你自己构建且已核实的副本，可仅移除这一份 App 的隔离标记。

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Lumen.app"
   ```

## 系统权限

- **仅录制系统音频**用于跟随 Mac 正在播放的声音。打开音频响应壁纸时按需请求权限。Lumen 在内存中计算频谱，采样随即释放。可在「隐私与安全性 → 屏幕与系统音频录制」管理授权。
- **登录时打开**由「设置 → General → Application」中的开关控制。若系统要求批准，从同一区域打开「登录项与扩展」，再允许 Lumen。
- **锁屏动态壁纸**使用系统当前用户的壁纸存储。完成设置页的锁屏配置流程后，Lumen 才管理对应条目。
- MetricKit 的崩溃与卡顿报告存于 `~/Library/Logs/Lumen/`，最多保留 30 份。报告由 macOS 生成并保存在本机。

## 构建和打包

需要 Xcode 和 XcodeGen。首次在本机固定签名身份时，由登录钥匙串所有者从项目根目录运行以下命令，并按系统提示批准钥匙串访问。

```sh
Tools/make-signing-identity.sh
xcodegen generate
```

XcodeGen 为 Debug 和 Release 选用 `Lumen Local Signing`。机器没有对应身份时使用临时签名。多个同名身份共存时，通过 `LUMEN_CODE_SIGN_IDENTITY` 指定证书的 40 位指纹，再重新生成工程。将其设为 `-` 可显式使用临时签名。保留同一私钥和证书才能在后续构建中维持签名身份。可用 `codesign -dr - /Applications/Lumen.app` 查看安装版的指定要求。 [Apple 的代码签名说明](https://developer.apple.com/library/archive/technotes/tn2206/)

```sh
Tools/release.sh
```

脚本读取 `project.yml` 的版本号，在 `build/release/` 生成 DMG 和 SHA-256 校验文件。

## 更新

Lumen 从本仓库的 GitHub Releases 获取更新（`project.yml` 的 `LumenUpdateRepository`，默认 `fancyecho/Lumen`）。

- 「设置 › General › Application」可以手动检查；「Check for updates automatically」打开时，启动后最多每天检查一次，有新版本时弹出提示。请求只发往 `api.github.com` 和 GitHub 的下载地址，不带任何个人信息。
- 点「Install and Relaunch」后，Lumen 下载 `Lumen-<版本>.zip`，依次核对：与同一发布里的 `Lumen-<版本>.zip.sha256` 一致；解压出的 App 代码签名有效、Bundle ID 和版本号正确；若当前副本用证书签名，新副本还要满足当前副本的指定要求（designated requirement）。然后 Lumen 退出，由一个小脚本把新副本换到原位置并重新打开，替换失败时放回旧副本。
- Lumen 所在文件夹不可写时（例如没有管理员权限），会提示从发布页手动下载。
- 构建是临时签名，验证依赖 HTTPS、SHA-256 和签名完整性，不如 Developer ID 签名可靠；签名每版都会变，更新后 macOS 可能再次询问系统音频权限。

### 发布新版本

1. 改 `project.yml` 的 `MARKETING_VERSION`（三段整数）和 `CURRENT_PROJECT_VERSION`。
2. 运行 `Tools/release.sh`，在 `build/release/` 得到 `Lumen-<版本>.dmg`、`Lumen-<版本>.zip` 和各自的 `.sha256`。
3. 用标签 `v<版本>` 创建 GitHub Release，四个文件都上传。更新器只认带 zip 和 zip 校验文件、且不是草稿或预发布的最新 Release。
