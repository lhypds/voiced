# Voiced for iOS

原生 SwiftUI iPhone / iPad 版本，与 macOS 版本放在同一个仓库。需要 iOS 17+，建议使用内存充足的较新 iPhone。使用仓库现有的 WhisperKit 1.1.1 和模型配置，完全在设备上进行识别。

## 用免费 Apple ID 连接真机运行

不需要购买 Apple Developer Program。工程使用自动签名，不含 iCloud、推送、App Groups 等需要额外配置的能力。

0. 如果 Xcode 提示 “iOS … is not installed”，先在 Xcode → Settings → Components 下载对应的 iOS 平台组件。
1. 用 Xcode 打开仓库根目录的 `Voiced.xcworkspace`（也可直接打开本目录的 `Voiced.xcodeproj`），等待 Swift Package 依赖解析完成。不要把根目录 `Package.swift` 的 macOS 可执行 scheme 用于 iPhone。
2. Xcode → Settings → Apple Accounts，登录自己的 Apple ID。
3. 选择项目 → TARGETS → VoicedIOS → Signing & Capabilities，保持 **Automatically manage signing**，Team 选择自己的 **Personal Team**。
4. 把 Bundle Identifier `com.voiced.personal.ios` 改成自己的唯一标识，例如 `com.yourname.voiced.ios`。保持同一标识可在后续安装时保留应用数据。
5. USB 连接 iPhone，解锁并信任 Mac。在 iPhone 的“设置 → 隐私与安全性 → 开发者模式”中打开开发者模式，按系统提示重启确认。
6. 在 Xcode 顶部选择连接的 iPhone 和 **`Voiced iOS`** scheme，按 ⌘R。如果手机提示开发者不受信任，在“设置 → 通用 → VPN 与设备管理”中信任对应的开发者。
7. 允许麦克风权限，点击“开始录音”。首次运行会从 Hugging Face 下载模型，然后进行 Core ML 加载；建议 Wi-Fi，并保持应用前台运行。

免费 Personal Team 的设备签名描述文件 **7 天到期**，届时连接 Xcode 再次运行即可。请不要为更新签名删除应用，否则会删除沙盒里的历史记录和模型。免费签名也有设备、App ID 数量限制，以 Xcode 的账户提示为准。

Apple 官方说明：[账户类型与免费真机调试限制](https://developer.apple.com/help/account/basics/about-your-developer-account)、[通过 Xcode 在设备运行](https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device)。

## 功能

- 与 Mac 相同的实时识别、模型和语言选择、自动检测语言范围、分句去重和标点规则。
- 输入设备选择、原始/降噪后电平、噪声校准、频谱降噪、人声过滤、能量阈值、识别预览和提示词编辑。
- 文字与 WAV 自动保存，本地历史可查看、删除、继续追加录音；支持句子定位播放和播放高亮。
- 翻译规则、原文/译文主次、朗读译文、声音选择和试听。翻译需要 iOS 18+，语言包由系统下载。
- **AI 设置**：OpenAI API 密钥、提示和摘要独立开关/模型、自定义模型名、提示语言与联网搜索。
- **AI 提示**：本地过滤日常句子，按需请求解释；轻点可固定提示，× 可关闭。
- **历史摘要**：在记录详情或长按菜单中生成、查看和分享摘要。摘要保存到同一记录目录下的 `summary.txt`。
- 文字、JSON、音频和摘要可通过系统分享菜单导出；支持六种界面语言与偏好重置。

两端共用 `VoicedCore`，包含 AI 请求生命周期、识别、音频、翻译、设置、存储和配色。设置采用 iOS 的分组列表与二级导航，沿用 Mac 的暖白与橙色。

AI 提示需要先输入 API 密钥并主动开启；摘要只在点击生成时发送整段文字。普通识别与翻译在设备上进行。API 费用由你的 OpenAI 账户承担，免费 Apple ID / Personal Team 不包含 API 额度。

完整对照和验证边界见 [功能核对表](../docs/iOS-feature-parity.md)。

## 当前差异

- iOS 17 可识别和使用 AI，但翻译需要 iOS 18+。
- 当前实时识别要求应用在前台；来电、进入后台或切换音频路由时结束录音并保存音频。后台长期识别尚未实现。
- 音频输入限于 iOS 系统提供的麦克风/外接输入，没有 Mac 的任意应用虚拟音频、窗口置顶和命令行安装。
- 两端数据不会自动同步，iOS 不在后台批量预编译所有模型。

## 本地数据与迁移

应用沙盒 `Library/Application Support/Voiced/` 包含 `settings.json`、`prompt.txt`、`noise-profile.json` 和 `history/<record-id>/`。每条记录目录中保存同格式的 `transcript.json`、WAV 和已生成的 `summary.txt`。模型缓存在 `Documents/huggingface/models`。

旧版 iOS 的 `history.json` 自动导入，成功后保留为 `history.json.migrated` 备份；旧版 `ios.*` 设置也会导入，已存在的新设置不被覆盖。卸载应用会删除这些数据，重要内容请先导出。

## 命令行构建（无需签名）

在仓库根目录运行：

```sh
xcodebuild -project iOS/Voiced.xcodeproj -scheme 'Voiced iOS' \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
```

模拟器适合检查界面。Core ML 加载速度、内存占用和麦克风效果应在自己的 iPhone 上确认。真机签名由你在 Xcode 中选择 Personal Team 后完成，不要把证书或账户资料提交到仓库。

## 界面测试

```sh
xcodebuild -project iOS/Voiced.xcodeproj -scheme 'Voiced iOS' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO test
```

将设备名称替换为已安装的模拟器。测试使用临时数据与模拟服务，不会发送真实 AI 请求。原生 iOS target 名为 `VoicedIOS`，scheme 名为 `Voiced iOS`，应用显示名称仍为 `Voiced`，以免与本地 Swift Package 的 Mac 可执行 scheme 混淆。

如果出现 `No such module AppKit`，请检查顶部 scheme：`Voiced (voiced)` 属于 Mac 的 Swift Package 可执行程序；iPhone 必须选择原生工程中的 `Voiced iOS`。无需修改或删除 AppKit 导入。

共享包位于 `Shared/VoicedCore/`。iOS 工程仅依赖此包；根目录的 `Package.swift` 仅用于 macOS，不能作为 iPhone App 构建入口。
