# SkyBridge Compass iOS

SkyBridge Compass 的 iOS 版本 - 跨平台设备管理与远程控制应用

## 项目概述

这是 SkyBridge Compass Pro 的 iOS 移植版本，与 macOS 版本完全兼容，支持：

- **后量子密码学 (PQC)** 加密握手和通信
- **跨平台 P2P 连接**：iOS ↔ macOS ↔ 其他设备
- **设备发现与管理**
- **远程桌面查看与控制**（触摸优化）
- **安全文件传输**
- **跨设备剪贴板同步**
- **CloudKit 同步**
- **iOS Widget 支持**

## 系统要求

- **iOS 17.0+**（运行目标）  
- **iOS 26 SDK +**（仅当你要启用 Apple CryptoKit PQC：ML‑KEM/ML‑DSA）
- **iPadOS 17.0+**
- **Xcode 26.2+**
- **Swift 6.2+**

## 技术栈

### 核心技术
- Swift 6.2 (Strict Concurrency)
- SwiftUI + UIKit
- Network Framework (P2P 通信)
- CryptoKit + liboqs (后量子加密)
- CloudKit (云端同步)
- WidgetKit (小组件)

### 共享模块
**注意**：iOS 版本已改为 **完全自包含（Standalone）**，不再通过符号链接/父目录 SwiftPM 引用去“复用 macOS 工程的 SkyBridgeCore”。
核心逻辑已内置在 `SkyBridgeCompassiOS/Sources/Core`（并保持与论文协议/线格式兼容）。

### iOS 专属
- **SkyBridgeUI_iOS**: iOS 优化的用户界面
  - 触摸交互
  - iPhone / iPad 自适应布局
  - iOS 原生控件集成
  - 手势识别

## 项目结构

```
SkyBridge Compass iOS/
├── Package.swift                   # Swift Package 配置
├── SkyBridgeCompassiOS/           # iOS 主应用
│   ├── Sources/
│   │   ├── App/                   # 应用入口
│   │   ├── Views/                 # 视图层
│   │   ├── ViewModels/            # 视图模型
│   │   └── Services/              # iOS 专属服务
│   ├── UI/                        # iOS UI 组件库
│   └── Resources/                 # 资源文件
├── Widgets/                       # iOS Widget Extension
└── Tests/                         # 测试
```

## 与 macOS 版本的互通性

### PQC 握手协议
目标是让 iOS 和 macOS 使用相同的后量子密码学协议。但请注意：**当前 iOS 端默认会落到 Classic suite**，除非你满足 Apple PQC 的编译/运行条件并且具备对端 KEM 公钥的信任记录（见下方说明）。

- **密钥交换**: ML-KEM-768 / Kyber768
- **签名验证**: ML-DSA-65 / Dilithium3
- **混合加密**: X-Wing (Kyber768 + X25519)

#### 当前“实际协商”的 suite（你现在跑起来看到的）
- **默认**：`x25519Ed25519`（Classic），因为 iOS 项目默认不定义 `HAS_APPLE_PQC_SDK`，并且 iOS 26 的 CryptoKit PQC 类型在旧 SDK 下不可用。
- **启用 Apple PQC 的前提**：
  - 使用包含 **iOS 26 SDK** 的 Xcode（否则编译期没有 `MLKEM768/MLDSA65` 类型）
  - 在 Xcode Target -> Build Settings 里添加 `SWIFT_ACTIVE_COMPILATION_CONDITIONS`：`HAS_APPLE_PQC_SDK`
  - 运行时满足 `#available(iOS 26.0, *)`

#### 为什么“有 ApplePQCCryptoProvider 还不一定能走 PQC suite”
PQC 握手（按 macOS SkyBridgeCore 的设计）需要 **对端的 KEM 身份公钥**（TrustRecord.kemPublicKeys）用于 initiator 端 `kemEncapsulate()`，以及 responder 端用本地 KEM 身份私钥 `kemDecapsulate()`。

macOS 端已经有 `TrustSyncService/TrustRecord`；iOS 端目前还没有完整的 TrustRecord 同步/持久化链路，所以即使启用了 Apple PQC provider，也可能会因为缺少对端 KEM 公钥而无法进行 PQC-only attempt，最终回落到 Classic。

### P2P 通信
使用 Network Framework 的 P2P 功能：

1. **本地网络发现**: Bonjour + NWBrowser
2. **跨网络连接**: iCloud Relay / STUN
3. **加密通道**: TLS 1.3 + PQC 层

### 数据同步
- CloudKit 同步设备列表和信任关系
- 离线消息队列
- 剪贴板实时同步

## 构建与运行

### 1. 克隆并初始化

```bash
cd "/path/to/SkyBridge Compass iOS"
```

### 2. 使用 Xcode 打开

```bash
open SkyBridgeCompass-iOS.xcodeproj
```

### 3. 选择目标设备
- 选择 iPhone 或 iPad 模拟器
- 或连接真机（需要开发者账号）

### 4. 运行
- ⌘R 运行
- ⌘U 运行测试

## 🔑 Supabase 配置

如果你在登录/注册时看到 **“Supabase 配置缺失（SUPABASE_URL / SUPABASE_ANON_KEY）”**：

- **推荐**：在登录页点击 **“Supabase 配置”**，填写并保存（写入 Keychain，优先级最高）
- **读取优先级**：Keychain → `Info.plist` → `SupabaseConfig.plist`（仅 SwiftPM：打开 `Package.swift` 运行时）

注意：`SUPABASE_SERVICE_ROLE_KEY` 属于服务端密钥，**不建议放在客户端**；如需调试，请仅在本地 Keychain 配置并避免提交到仓库。

## 核心功能实现状态

- [x] 项目结构创建
- [ ] 设备发现（本地 + iCloud）
- [ ] PQC 握手与加密通信
- [ ] 远程桌面查看（触摸控制）
- [ ] 文件传输（Files app 集成）
- [ ] 剪贴板同步
- [ ] iOS Widget
- [ ] CloudKit 同步
- [ ] 多语言支持

## 开发指南

### iOS 与 macOS 差异

1. **UI 框架**
   - iOS: UIKit / SwiftUI for iOS
   - 触摸手势替代鼠标点击
   - 适配不同屏幕尺寸

2. **后台运行**
   - iOS 后台限制更严格
   - 使用 Background Tasks Framework
   - P2P 连接需要特殊权限

3. **系统集成**
   - Files app 替代 Finder
   - UIPasteboard 替代 NSPasteboard
   - 无菜单栏，使用 Tab Bar

### 版本兼容性

```swift
// iOS 17-26 兼容性示例
if #available(iOS 26, *) {
    // 使用 iOS 26 新特性
    useCKSyncEngine()
} else {
    // 回退到 iOS 17 兼容方式
    useLegacyCKDatabase()
}
```

## 安全性

- 端到端 PQC 加密
- 零知识认证
- 设备信任链验证
- 安全飞地 (Secure Enclave) 集成
- 生物识别认证 (Face ID / Touch ID)

## 贡献

详见主项目 README 和 IEEE 论文

## 许可

与 macOS 版本相同

---

**注意**: 本项目与 macOS 版本共享核心代码，确保任何修改都保持跨平台兼容性。
