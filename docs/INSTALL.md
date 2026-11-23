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

## 更新源

托管一个 HTTPS JSON 文件后，将其地址传给构建命令。

```sh
LUMEN_UPDATE_FEED_URL='https://example.org/lumen/update.json' Tools/release.sh
```

```json
{
  "version": "0.2.0",
  "downloadURL": "https://example.org/lumen/Lumen-0.2.0.dmg",
  "notes": "Improved scene playback on external displays."
}
```

`version` 使用三段整数，下载链接使用 HTTPS。配置地址后，在 General 的 Application 分区点「Check for Updates」会获取版本信息。用户点「Download」后，Lumen 在浏览器打开下载链接，由用户手动安装。
