# SkyBridge Compass (云桥司南)

SkyBridge Compass 是一款针对企业设备编排场景打造的 **iOS 原生应用**，使用 Swift 6.2 与 SwiftUI 6 构建，提供液态玻璃风格的控制中心式体验。应用整合了远程桌面、文件传输、远程终端、动态岛实时活动以及 Siri 快捷唤醒等功能，帮助运维团队随时掌握设备状态并执行操作。

## 技术栈

- **语言**: Swift 6.2
- **UI 框架**: SwiftUI 6（支持液态玻璃组件）
- **最低系统版本**: iOS 16.0
- **兼容系统**: iOS 17、iOS 18，以及规划中的 iOS 26
- **构建工具**: Xcode 16（或更新版本，包含 Swift 6.2 toolchain）
- **Widget & Live Activity**: ActivityKit、WidgetKit
- **网络层**: URLSession + Combine，用于与真实 API 对接

> ℹ️ 苹果尚未发布 iOS 19–25，因此项目不会声明或依赖这些版本。

## 核心特性

- 🧭 **总览仪表盘**：液态玻璃风格的导航面板，汇总环境指标与远程任务状态。
- 🖥️ **远程桌面控制**：通过最新渲染管线拉取预览帧，支持画质调节、会话监控与多端切换。
- 📁 **文件传输**：浏览远端目录、上传 / 下载文件，并实时追踪作业进度。
- 💻 **远程终端**：基于 WebSocket 的命令行会话，支持多标签记录与历史回放。
- ⚙️ **系统设置联动**：将常用调节项绑定到真实 API，并通过 Siri 快捷指令快速唤醒。
- 📱 **动态岛与锁屏小组件**：ActivityKit + WidgetKit 显示关键指标，让状态更新随时呈现。

## 快速开始

### 环境准备

1. macOS Sonoma 14.4 或以上版本。
2. 安装 Xcode 16（或更高版本），确保包含 Swift 6.2 toolchain 与 iOS 18 SDK。
3. 安装 Apple 开发者账号证书（若需要在真机或 TestFlight 上调试）。

### 获取项目

```bash
# 克隆仓库
git clone https://github.com/billlza/Skybridge-Compass.git
cd Skybridge-Compass
```

### 打开与运行

#### 使用 Xcode

1. 打开 `ios/SkybridgeCompass/SkybridgeCompass.xcodeproj`。
2. 选择目标设备（模拟器或真机，需运行 iOS 16+）。
3. 点击 **Run** 以编译并安装应用。
   - 首次构建前，工程会在 "Generate App Icon" 脚本阶段自动执行 `Scripts/GenerateAppIcon.swift` 生成 `AppIcon.png`，避免将二进制图标纳入版本库。如需手动生成，可运行 `swift ios/SkybridgeCompass/SkybridgeCompass/Scripts/GenerateAppIcon.swift ios/SkybridgeCompass/SkybridgeCompass/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`。

#### 使用命令行

```bash
# 清理并构建 Debug 版本
defaults write com.apple.dt.Xcode IDEPackageSupportUseBuiltinSCM YES
xcodebuild \
  -project ios/SkybridgeCompass/SkybridgeCompass.xcodeproj \
  -scheme SkybridgeCompass \
  -destination 'generic/platform=iOS' \
  clean build

# 运行单元 / UI 测试（如已配置）
xcodebuild \
  -project ios/SkybridgeCompass/SkybridgeCompass.xcodeproj \
  -scheme SkybridgeCompass \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=18.0' \
  test
```

> 如果在 CI 中构建，可结合 `xcodebuild` 与 `xcpretty` 输出更易读的日志。

## 项目结构（iOS 部分）

```
ios/
└── SkybridgeCompass/
    ├── SkybridgeCompass.xcodeproj       # Xcode 工程
    ├── SkybridgeCompass/
    │   ├── Features/                    # SwiftUI 功能模块
    │   ├── Models/                      # 数据模型与 DTO
    │   ├── Services/                    # API 服务封装
    │   ├── ViewModels/                  # 业务状态与数据绑定
    │   ├── Widgets/                     # Widget & Live Activity 入口
    │   └── Supporting/                  # Info.plist、资源等
    └── SkybridgeCompassTests/           # 单元 / UI 测试（预留）
```

## API 对接

- 应用通过 `CompassAPIClient` 管理 REST 与 WebSocket 会话。
- 所有面板均在 `ViewModel` 中发起真实网络请求，并使用 `@MainActor` 安全更新 UI。
- 若要自定义后端地址，可在 `DeviceStatusService`、`OperationsServices` 中修改基地址或注入配置。

## 贡献指南

欢迎通过 Pull Request 或 Issue 反馈需求与问题。提交代码前请确保：

- 通过 `xcodebuild test` 或等效的 CI 流程。
- 遵循 Swift 官方编码规范，避免强制解包，优先使用 `Observable` / `Observation` 模型。
- 遵守项目的模块划分，公用逻辑放置在 `Services` 与 `Utilities` 中。

## 许可证

MIT License。

---

如需进一步集成后端、扩展面板或编写自动化脚本，欢迎联系项目维护者一起完善这套 iOS 远程运维解决方案。
