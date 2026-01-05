# SkyBridge Compass Widget Extension 配置指南

## 问题说明

macOS Widget Extension 必须通过 Xcode 项目构建，SwiftPM 不支持构建 App Extensions。
Widget Extension 需要：
1. 作为 `.appex` bundle 嵌入主应用
2. 配置 App Groups 以共享数据
3. 正确的 Bundle ID 层级关系

## 配置步骤

### 1. 在 Xcode 中打开项目

```bash
open .swiftpm/xcode/package.xcworkspace
```

### 2. 添加 Widget Extension Target

1. 在 Xcode 中，选择 **File → New → Target...**
2. 选择 **macOS → Widget Extension**
3. 配置：
   - Product Name: `SkyBridgeCompassWidgets`
   - Bundle Identifier: `com.skybridge.compass.widgets`
   - Include Configuration App Intent: ✅ (可选)
   - Embed in Application: `SkyBridgeCompassApp`

### 3. 配置 App Groups

#### 主应用 (SkyBridgeCompassApp)
1. 选择主应用 target
2. 进入 **Signing & Capabilities**
3. 点击 **+ Capability**
4. 添加 **App Groups**
5. 添加 group: `group.com.skybridge.compass`

#### Widget Extension
1. 选择 Widget Extension target
2. 进入 **Signing & Capabilities**
3. 点击 **+ Capability**
4. 添加 **App Groups**
5. 添加相同的 group: `group.com.skybridge.compass`

### 4. 替换 Widget 源代码

删除 Xcode 自动生成的 Widget 代码，使用我们已有的：

1. 删除 Xcode 生成的 `.swift` 文件
2. 将以下文件添加到 Widget Extension target：
   - `Sources/SkyBridgeCompassWidgets/CompassWidget.swift`
   - `Sources/SkyBridgeCompassWidgets/WidgetIntents.swift`

### 5. 添加 SkyBridgeWidgetShared 依赖

1. 选择 Widget Extension target
2. 进入 **General → Frameworks and Libraries**
3. 点击 **+**
4. 选择 `SkyBridgeWidgetShared` (来自本地 Package)

### 6. 更新 WidgetDataLimits.swift 中的 App Group ID

确保 `Sources/SkyBridgeWidgetShared/WidgetDataLimits.swift` 中的 App Group ID 正确：

```swift
public static let appGroupIdentifier = "group.com.skybridge.compass"
```

### 7. 构建和运行

1. 选择主应用 scheme
2. 构建 (⌘B)
3. 运行 (⌘R)

Widget Extension 会自动嵌入到主应用的 `.app` bundle 中。

## 验证 Widget 是否正常工作

1. 运行应用后，右键点击桌面
2. 选择 **编辑小组件...**
3. 搜索 "SkyBridge" 或 "云桥司南"
4. 应该能看到三个 Widget：
   - 设备状态 (DeviceStatusWidget)
   - 系统监控 (SystemMonitorWidget)
   - 文件传输 (FileTransferWidget)

## 常见问题

### Widget 不显示在小组件库中
- 确保 Widget Extension 的 Bundle ID 是主应用 Bundle ID 的子级
- 确保 Info.plist 中的 `NSExtensionPointIdentifier` 是 `com.apple.widgetkit-extension`

### Widget 显示 "无法加载"
- 检查 App Groups 配置是否一致
- 检查 Widget Extension 是否正确嵌入主应用

### 数据不同步
- 确保主应用和 Widget 使用相同的 App Group ID
- 检查 `WidgetDataService` 是否正确写入共享容器

## 文件结构

```
SkyBridge Compass.app/
├── Contents/
│   ├── MacOS/
│   │   └── SkyBridge Compass
│   ├── PlugIns/
│   │   └── SkyBridgeCompassWidgetsExtension.appex/  ← Widget Extension
│   │       └── Contents/
│   │           ├── MacOS/
│   │           │   └── SkyBridgeCompassWidgetsExtension
│   │           └── Info.plist
│   └── Info.plist
```

## 已实现的 Widget 功能

- ✅ DeviceStatusWidget - 设备状态小组件
- ✅ SystemMonitorWidget - 系统监控小组件  
- ✅ FileTransferWidget - 文件传输小组件
- ✅ AppIntent 交互支持 (扫描设备、打开应用等)
- ✅ Deep Link 路由
- ✅ Widget Push 更新服务
- ✅ 三种尺寸支持 (small/medium/large)
- ✅ 深色/浅色模式适配
- ✅ 数据过期提示
- ✅ 截断显示 "+N more"
