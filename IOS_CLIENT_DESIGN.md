# SkyBridge Compass Pro iOS 客户端规划

## 1. 目标与视觉语言
- **平台**：Swift 6.2.1 + SwiftUI 4，支持 iOS 17/18/26（假设对应 Xcode 26）。
- **目标**：提供与 macOS 版一致的体验，并对 iPhone 进行单手、底部导向优化。
- **视觉**：星空 / 渐变背景 + Liquid Glass 漂浮面板，颜色、模糊、卡片布局与 macOS 版呼应。
- **动效**：全局使用 SwiftUI Spring 动画，并在 iOS 18+ 启用浮动 TabBar、Zoom、交互式 widget 动效。

## 2. 技术栈与模块化
- **语言 & UI**：Swift 6.2.1、SwiftUI 4、Observation 模型（`@Observable`、`@State`、`@Environment`）。
- **并发**：`async/await` 与 `AsyncSequence`。
- **共享组件**：所有核心逻辑抽象为 Swift Packages，macOS/iOS 共用。
- **建议模块**：
  - `SkyBridgeCore`：会话、传输、P2P/中继逻辑。
  - `DeviceDiscoveryKit`：扫描、服务列表、IPv4/IPv6、新发现算法。
  - `RemoteDesktopKit`：编解码、帧率、Metal 渲染。
  - `QuantumSecurityKit`：ML-DSA/ML-KEM、Secure Enclave。
  - `SettingsKit`：配置模型、UserDefaults + 加密存储。
  - `SkyBridgeDesignSystem`：颜色、字体、Liquid Glass 封装、卡片组件。
  - `SkyBridgeWidgets`：WidgetKit 扩展（Home/Lock/Control/Dynamic Island Live Activity）。

### PQC 策略
- **iOS 26**：优先调用 Apple 官方 PQC、Liquid Glass、CryptoKit 扩展。
- **iOS 17–18**：继续使用 `QuantumSecurityKit`（liboqs 封装），UI 中标明“实验性/软件实现”。

## 3. 信息架构与底部 Liquid Glass
### 顶层导航
- 底部浮动 TabBar + 顶部标题行，映射 macOS 分栏：Dashboard、设备发现、文件传输、远程桌面、系统监控/设置。
- iOS 18+ 使用浮动 TabBar，采用 Liquid Glass 材质并保留安全区。

### 底部 Liquid Glass 原则
- 结构：顶部大标题/定位 → 中间信息卡片 → 底部 Liquid Glass 面板。
- 面板包含：设备操作、高级设置、上拉 Sheet 入口。
- Safe Area：`RootView` 忽略底部安全区，`LiquidBottomBar` 根据版本应用 Liquid Glass / `.ultraThinMaterial`。

示例伪代码：
```swift
struct RootView: View {
    var body: some View {
        ZStack {
            SkyBridgeBackground()
            VStack(spacing: 0) {
                TopStatusBar()
                MainContent()
                    .frame(maxHeight: .infinity, alignment: .top)
                LiquidBottomBar()
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}
```

Liquid Glass fallback：
```swift
@ViewBuilder
func liquidGlassMaterial() -> some ShapeStyle {
    if #available(iOS 26, *) {
        LiquidGlass.thin()
    } else {
        .ultraThinMaterial
    }
}
```

## 4. 分阶段实施
1. **阶段 0：初始化**
   - 创建 iOS App + Widget Extension + Live Activities target。
   - 拆出共享 Swift Packages；构建 `SkyBridgeDesignSystem`（颜色、渐变、Glass 组件）。
2. **阶段 1：导航骨架**
   - `RootView` + 背景 + TabView/自定义浮动 TabBar。
   - 每个 Tab：顶部标题、卡片占位、底部 `LiquidBottomBar`。
3. **阶段 2：主控台 & 天气**
   - 调用现有天气服务（wttr.in + AQI）。
   - 卡片：城市、天气图标、温度、湿度、能见度、风速、AQI。
   - 底部玻璃按钮：刷新天气、切换城市、性能面板。
4. **阶段 3：设备发现**
   - 复用 mac 卡片：名称、网络状态、服务数。
   - 点击卡片 → 底部 Sheet 展示连接模式、加密状态；`DeviceDiscoveryKit` 提供数据。
5. **阶段 4：文件传输 / 远程桌面入口**
   - 文件传输：任务列表、速度、剩余时间；底部操作（上传、剪贴板发送）。
   - 远程桌面：最近会话卡片（分辨率/FPS/延迟）；底部快速连接、性能预设。
6. **阶段 5：高级设置**
   - GlassBottomSheet 中的设置组：
     - 性能模式（省电/平衡/极致）、渲染倍率、最大分辨率、目标 FPS。
     - 网络 & 实验：IPv6、发现算法、P2P 直连（警示）、最大并发连接。
     - 量子安全：PQC 开关、TLS 混合、签名算法、Secure Enclave 选项、系统 PQC 检测。
     - 设备强度平滑（EMA 滑条）、重置按钮。

## 5. Dynamic Island & Live Activities
- 使用 ActivityKit 构建场景：
  - **远程会话**：设备名、编码分辨率、实时 FPS、延迟；点击展开网络详情，长按提供断开/性能模式。
  - **文件传输**：文件名、进度条、速度；点击跳转传输列表。
  - **量子安全状态**：锁图标 + “PQC ON/OFF”、“Secure Enclave”。
- 紧凑/展开布局遵守 HIG；利用 Live Activity 数据模型实时更新。

## 6. WidgetKit & 控制小组件
- **iOS 17+**：Home/Lock Screen Widget（快速连接、系统状态）。
- **交互式 Widget**：性能模式切换、PQC 开关（AppIntent）。
- **iOS 18+ Control Widgets**：控制中心/锁屏底部操作（上一台设备、一键 PQC）。
- **颜色适配**：支持 iOS 18+ 色彩/tint 自定义，保证可读性。

## 7. 版本兼容策略
- Liquid Glass：iOS 26 使用官方材质，其余回退 `.ultraThinMaterial`。
- Widget 能力按版本启用（控制小组件仅 iOS 18+）。
- PQC：iOS 26 走系统 API，其余使用 `QuantumSecurityKit`。

## 8. 性能 & 体验
- 极致模式限制目标 FPS 于硬件可承受范围；远程桌面首选 Metal + 高效纹理。
- Liquid Glass：iOS 26 可多用；iOS 17/18 减少叠加避免掉帧。
- 网络：自动 P2P/中继切换在 `SkyBridgeCore`；UI 仅显示“当前链路”。

## 9. 交付标准
- 阶段性验收：每个阶段可独立运行并展示核心交互。
- UI 细节遵守 Apple HIG、Dynamic Island 规范、WidgetKit 限制。
- 文档同步：保持 macOS/iOS 共享包说明与 API 设计一致。
