# SkyBridge Compass iOS - 构建指南

## 📋 前提条件

### 系统要求
- macOS 14.0+ (Sonoma 或更新版本)
- Xcode 26.5+（正式发布/CI 基线）；Xcode 27 beta 仅用于手动 OS 27 兼容验证
- iOS 17.0+ 模拟器或真机
- Swift 6.3+
- Apple 开发者账号（用于真机测试）

### 依赖项
- WebRTC Swift Package（Xcode 会自动解析）
- liboqs（可选：若你要在 iOS 17-25 上实现 PQC-only，需要提供 iOS 架构的 liboqs XCFramework）

## 🚀 快速开始

### 1. 进入项目目录

```bash
cd "/path/to/SkyBridge Compass iOS"
```

### 2. 使用 Xcode 打开

```bash
open SkyBridgeCompass-iOS.xcodeproj
```

### 3. 配置签名

1. 在 Xcode 中，选择项目文件
2. 选择 "SkyBridgeCompassiOS" target
3. 在 "Signing & Capabilities" 标签页：
   - Team: 选择你的 Apple 开发团队
   - Bundle Identifier: 修改为唯一值（如 `com.yourcompany.skybridge.ios`）

### 4. 配置 Capabilities

确保启用以下功能：

- [x] **Network** - 本地网络访问
- [x] **Background Modes** 
  - Background fetch
  - Remote notifications
  - Background processing
- [x] **Push Notifications**
- [x] **iCloud** 
  - CloudKit
  - iCloud Documents
- [x] **Keychain Sharing**
- [x] **App Groups** (用于 Widget)

### 5. 运行项目

#### 模拟器

1. 选择目标设备（iPhone 15 Pro 或 iPad Pro）
2. 点击运行按钮 (⌘R)

#### 真机

1. 连接 iOS 设备
2. 在设备上信任开发证书
3. 选择设备作为运行目标
4. 点击运行

## 🔐 Apple CryptoKit PQC（iOS 26+，论文 strictPQC 路径）

### 需要在哪里声明？

- **在当前仓库提交的 `SkyBridgeCompass-iOS.xcodeproj` 里，app/test target 只保留空的** `SKYBRIDGE_APPLE_PQC_SDK_CONDITION` **接入口**，不会按 SDK 大版本自动打开 `HAS_APPLE_PQC_SDK`
- **只有通过 Apple PQC symbol probe 的构建 lane** 才能显式传入 `SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK`
- **如果你复制 target、重建工程，或使用不同构建入口**，必须先运行 Apple PQC SDK probe，再显式传入这个 build setting；不要用 `iphoneos26*` / `iphoneos27*` SDK selector 推断可用性
- **不需要、也不应该在 Info.plist 里声明**：Info.plist 只负责权限/能力（如相机、本地网络、定位、Live Activities），不影响编译期是否包含 `MLKEM768/MLDSA65` 类型

### 何时需要打开？

- 你使用的 Xcode 必须包含对应 SDK 并通过 Apple PQC 符号探测（否则编译会报找不到 `MLKEM768/MLDSA65` 等 CryptoKit PQC 类型）
- 运行时必须满足 `#available(iOS 26.0, *)`
- 并且需要完成一次配对/信任同步，让双方保存对端 **KEM 身份公钥（Trust Store）**；若缺失，则 `strictPQC` 会直接 fail-closed，不会再自动 classic bootstrap 或降级

## 🔧 故障排除

### 问题 1: 找不到 SkyBridgeCore 模块

**说明**：Standalone 版本不再依赖 `SkyBridgeCore` 模块（也不需要任何符号链接）。

### 问题 2: 编译错误 - Swift 版本不匹配

**解决方案：**
- 确保正式发布使用 Xcode 26.5+ / Swift 6.3+；Xcode 27 beta 用根目录 `Scripts/run_os27_beta_compatibility.sh` 单独验证
- 更新到最新的 Xcode 版本

### 问题 3: 本地网络权限不起作用

**解决方案：**
- 检查 Info.plist 中的 `NSLocalNetworkUsageDescription`
- 确保 `NSBonjourServices` 包含 `_skybridge._tcp`
- 在真机上测试（模拟器可能不支持某些网络功能）

### 问题 4: Widget 不显示

**解决方案：**
- 确保配置了 App Groups
- Widget 和主 App 使用相同的 App Group ID
- 在主屏幕长按，添加 Widget

## 📱 支持的设备

### iPhone
- iPhone 15 系列
- iPhone 14 系列
- iPhone 13 系列
- iPhone 12 系列
- iPhone SE (第 3 代)

所有设备需要运行 **iOS 17.0** 或更新版本

### iPad
- iPad Pro (所有型号)
- iPad Air (第 4 代及更新)
- iPad (第 9 代及更新)
- iPad mini (第 6 代及更新)

所有设备需要运行 **iPadOS 17.0** 或更新版本

## 🧪 测试

### 自动化测试（推荐）

```bash
xcodebuild test \
  -project "SkyBridgeCompass-iOS.xcodeproj" \
  -scheme "SkyBridgeCompass-iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'
```

说明：
- 这是当前最接近真实 app 入口的验证方式，会同时覆盖主 app scheme、`SkyBridgeCompassiOSTests` 与最小 `SkyBridgeCompassiOSUITests` smoke
- `swift test` 或直接 `swift build --package-path ...` 只适合检查 SwiftPM 路径，不等价于完整 iOS app 工程验证

### 仅运行最小 UI smoke

```bash
xcodebuild test \
  -project "SkyBridgeCompass-iOS.xcodeproj" \
  -scheme "SkyBridgeCompass-iOS" \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -only-testing:SkyBridgeCompassiOSUITests
```

当前 UI smoke 覆盖：
- app 启动
- 游客入口进入 dashboard
- 主 tab 导航切换
- 配对信任弹窗最短 happy path
- 文件传输入口与预置传输态 smoke
- 远程桌面入口与 viewer 切入 smoke

### Xcode 内测试

在 Xcode 中：
1. Product → Test (⌘U)
2. 或选择特定的测试文件运行

当前状态：
- 已有 `SkyBridgeCompassiOSTests` XCTest suite
- 已有 `SkyBridgeCompassiOSUITests` 最小 XCUITest bundle，用于启动与主导航 smoke

### 与 macOS 版本互通测试

1. 在 Mac 上运行 macOS 版 SkyBridge Compass
2. 在 iPhone/iPad 上运行 iOS 版
3. 两个设备连接到同一个 Wi-Fi 网络
4. 在 iOS 上的"发现"页面应该能看到 Mac
5. 点击连接并完成 PQC 验证

## 📦 发布构建

### 创建 Archive

1. 选择 "Any iOS Device" 作为目标
2. Product → Archive
3. 等待构建完成
4. 在 Organizer 中选择 Archive
5. Distribute App → App Store Connect / Ad Hoc / Enterprise

### TestFlight 分发

1. 创建 Archive
2. 选择 "Distribute App"
3. 选择 "App Store Connect"
4. 上传到 TestFlight
5. 邀请测试用户

## 🔐 PQC 加密配置

### 使用 liboqs

iOS 与 macOS 共用根包中唯一的、带版本锁与 provenance 的 liboqs XCFramework。重新生成时必须使用仓库配方：

```bash
cd ..
bash Scripts/build_liboqs_xcframework.sh
python3 Scripts/native_vendor_provenance.py verify \
  --repository-root "$PWD" \
  --lock Config/native-dependencies.lock.json \
  --provenance Sources/Vendor/liboqs.provenance.json
```

说明：
- 唯一产物位置是 `Sources/Vendor/liboqs.xcframework`
- iOS 通过根包 `SkyBridgeRoot` 的 `OQSRAII` product 消费该产物
- 不允许手工覆盖二进制或在 iOS 子目录恢复平行 vendor / local package
- 不再使用旧文档里 `Shared/Libraries/` 这类目录布局

## 📚 更多资源

- [SwiftUI 文档](https://developer.apple.com/documentation/swiftui/)
- [Network Framework](https://developer.apple.com/documentation/network)
- [WidgetKit](https://developer.apple.com/documentation/widgetkit)
- [CloudKit](https://developer.apple.com/icloud/cloudkit/)
- [liboqs 文档](https://github.com/open-quantum-safe/liboqs)

## 💡 开发提示

### Xcode 预览

在视图文件底部使用 `#Preview` 宏：

```swift
#Preview {
    DeviceDiscoveryView()
        .environmentObject(DeviceDiscoveryManager.shared)
}
```

### 日志查看

使用 Console.app 查看详细日志：
1. 打开 Console.app
2. 连接 iOS 设备
3. 搜索 "com.skybridge.compass"

### 性能分析

使用 Instruments：
1. Product → Profile (⌘I)
2. 选择模板（Time Profiler, Network, etc.）
3. 记录并分析

## 🤝 贡献

参见主项目的 CONTRIBUTING.md

## 📄 许可

与 macOS 版本相同

---

**问题？** 查看 [Issues](https://github.com/billlza/Skybridge-Compass/issues) 或创建新的 issue。
