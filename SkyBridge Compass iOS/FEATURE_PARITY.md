# SkyBridge Compass — macOS vs iOS 功能对照（发行版打磨）

> 范围：macOS (`/Users/bill/Desktop/SkyBridge Compass Pro release`) vs iOS (`/Users/bill/Desktop/SkyBridge Compass iOS`)
>
> 目的：明确 iOS 发行版“承诺给用户的功能”，以及与 macOS 端的差异/限制。

## 核心能力对照

| 功能 | macOS Pro | iOS | 说明/差异 |
|---|---:|---:|---|
| 账号/登录（Supabase） | ✅ | ✅ | iOS 读取优先级：Keychain → Info.plist → SupabaseConfig.plist(SwiftPM) |
| 设备发现（Bonjour/NWBrowser） | ✅ | ✅ | iOS 模拟器对本地网络发现限制更强，建议真机测试 |
| PQC 握手 | ✅ | ✅ | iOS 使用 `CryptoProviderFactory`（Apple PQC 条件编译/Classic fallback） |
| P2P 安全通道 | ✅ | ✅ | iOS 侧实现以 Network.framework 为主，细节与 macOS 可能有差异 |
| 文件传输 | ✅ | ✅ | iOS 已实现分块发送/接收/校验；需确认与 macOS 端协议完全一致 |
| 远程桌面 | ✅ | ⚠️ | macOS 端包含 VNC/或更完整的远控；iOS 端是 viewer/自定义流协议，互通需进一步验证 |
| 剪贴板同步 | ✅ | ⚠️ | iOS 有 `ClipboardManager`/相关模块，但跨端互通策略需联调确认 |
| CloudKit 同步 | ✅ | ⚠️ | iOS 默认关闭（避免未开 iCloud 能力时崩溃/卡死） |
| Widgets | ✅（WidgetKit） | ✅ | iOS 端具备 Widgets 目录；需检查资源/配置是否齐全 |
| Dashboard/性能监控/天气 | ✅ | ❌ | macOS 专属（窗口/硬件/后台能力更强） |
| USB/SSH/系统级能力 | ✅ | ❌ | iOS 平台限制，属于 macOS 专属能力 |

## iOS 发行版建议的“功能开关”策略

- **默认开启**：登录/游客、设备发现、PQC 握手、基础 P2P、文件传输（若已验证与 macOS 协议一致）
- **默认 Beta（可在设置页标注）**：远程桌面、剪贴板同步、跨网络(STUN/Relay)、CloudKit

## 发行前必做清单（iOS）

- **AppIcon/资产**：`Assets.xcassets/AppIcon` 已补齐并接入 Xcode Resources build phase
- **隐私权限文案**：`Info.plist` 已补齐本地网络/Bonjour/相机/照片等描述
- **版本号**：`CFBundleShortVersionString=1.0.0`、`CFBundleVersion=1`（可按发布节奏递增）
- **构建设置**：工程 `SWIFT_VERSION` 提升到 6.0（贴近 Swift 6.2 代码与推荐设置）
- **功能一致性**：对照 macOS 端做一次“互通冒烟测试”
  - 发现 → 连接 → PQC 验证 → 文件传输（双向）
  - 远程桌面（如承诺给用户）/否则 UI 标注 Beta


