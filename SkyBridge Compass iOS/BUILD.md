# SkyBridge Compass iOS - 构建指南

## 📋 前提条件

### 系统要求
- macOS 14.0+ (Sonoma 或更新版本)
- Xcode 15.0+ 
- iOS 17.0+ 模拟器或真机
- Swift 6.2+
- Apple 开发者账号（用于真机测试）

### 依赖项
- WebRTC Swift Package（Xcode 会自动解析）
- liboqs（可选：若你要在 iOS 17-25 上实现 PQC-only，需要提供 iOS 架构的 liboqs XCFramework）

## 🚀 快速开始

### 1. 克隆项目

```bash
cd "/path/to/SkyBridge Compass iOS"
```

### 3. 使用 Xcode 打开

```bash
open SkyBridgeCompass-iOS.xcodeproj
```

### 4. 配置签名

1. 在 Xcode 中，选择项目文件
2. 选择 "SkyBridgeCompassiOS" target
3. 在 "Signing & Capabilities" 标签页：
   - Team: 选择你的 Apple 开发团队
   - Bundle Identifier: 修改为唯一值（如 `com.yourcompany.skybridge.ios`）

### 5. 配置 Capabilities

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

### 6. 运行项目

#### 模拟器

1. 选择目标设备（iPhone 15 Pro 或 iPad Pro）
2. 点击运行按钮 (⌘R)

#### 真机

1. 连接 iOS 设备
2. 在设备上信任开发证书
3. 选择设备作为运行目标
4. 点击运行

## 🔧 故障排除

### 问题 1: 找不到 SkyBridgeCore 模块

**说明**：Standalone 版本不再依赖 `SkyBridgeCore` 模块（也不需要任何符号链接）。

### 问题 2: 编译错误 - Swift 版本不匹配

**解决方案：**
- 确保使用 Xcode 15+ 和 Swift 6.2+
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

### 单元测试

```bash
swift test
```

### UI 测试

在 Xcode 中：
1. Product → Test (⌘U)
2. 或选择特定的测试文件运行

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

### 使用 liboqs (可选)

如果要使用真实的 PQC 实现而不是模拟：

```bash
# 下载 liboqs
git clone https://github.com/open-quantum-safe/liboqs.git
cd liboqs

# 构建 iOS 版本
mkdir build-ios && cd build-ios
cmake .. -DCMAKE_TOOLCHAIN_FILE=../cmake/ios.toolchain.cmake
make

# 将编译的库复制到项目
cp lib/liboqs.a ../SkyBridge\ Compass\ iOS/Shared/Libraries/
```

然后在 Package.swift 中链接：

```swift
.target(
    name: "SkyBridgeCore",
    dependencies: [],
    linkerSettings: [
        .linkedLibrary("oqs")
    ]
)
```

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
