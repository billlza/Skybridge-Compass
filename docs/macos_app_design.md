# SkyBridge Compass macOS 客户端技术方案

## 1. 架构原则

- **语言与框架**：全面切换至 Swift 6（Swift 6.2 语法约定）与 SwiftUI 4.0，必要时通过 Objective-C 桥接 FreeRDP 等底层库。SwiftUI 组件默认运行在 macOS 14/15/26（向后兼容 10.14/10.15）以及未来版本，确保可以复用部分逻辑至 iOS/iPadOS。
- **架构模式**：采用 MVVM，对 SwiftUI 视图、业务逻辑、数据模型进行解耦。远程桌面、设备发现、文件传输等模块通过 Combine 将状态回推给界面层，实现实时刷新。
- **性能策略**：VideoToolbox + Metal 负责帧渲染；GCD 管理后台任务；BackgroundTasks 维持长时间文件传输。

## 2. 功能模块

### 2.1 远程桌面

- **协议支持**：通过 SwiftVNC / FreeRDP 桥接实现 RFB、RDP 协议。模块暴露统一的 `RemoteDesktopManager` 接口，在 SwiftUI 中以 `RemoteSessionSummary` 形式呈现。
- **硬件加速**：视频帧经由 VideoToolbox 解码，Metal 渲染输出，输入事件使用 `CGEvent` 发送，确保实时操作。
- **H.265 策略**：优先使用 VideoToolbox 提供的 HEVC（H.265）硬件编解码管线，在支持机型上直接解码远程帧；如遇到不支持 HEVC 的终端或会话服务器，自动协商回退至 H.264，并在必要时以 CPU 解码对接第三方编码器，保证兼容性与性能。
- **监控指标**：`RemoteDesktopManager` 周期性采集 CPU 负载与帧延迟，写入 `RemoteMetricsSnapshot`，在仪表盘中绘制折线图。

### 2.2 设备发现

- **真实扫描**：`DeviceDiscoveryService` 借助 `NWBrowser` 扫描 `_rdp._tcp`、`_rfb._tcp`、`_skybridge._tcp` 等 Bonjour 服务，拒绝模拟数据。扫描到的设备会附带真实 IP、端口映射与服务列表。
- **跨网段拓展**：后续可通过 mDNS Relay、WSD、主动 Ping 扩展发现策略。

### 2.3 文件传输

- **大文件**：URLSession 背景任务，支持断点续传与 QoS 调度。
- **实时同步**：WebSocket 通道用于小文件/指令流，数据使用 Compression(LZFSE) + CryptoKit(AES-GCM) 保护。
- **进度反馈**：`FileTransferManager` 将任务转换为 `FileTransferTask`，界面无需 mock 数据即可展示真实进度、吞吐、剩余时间。

## 3. UI 布局

- **导航结构**：`NavigationSplitView` + `LazyVGrid` 构建双栏布局，左侧为在线会话、操作列表，右侧为仪表盘卡片。
- **视觉风格**：深色渐变背景 + 玻璃卡片，与参考截图保持一致；Metric 卡片、折线图、传输列表均使用真实数据驱动。
- **响应式设计**：最小窗口 1280×720，可根据窗口变化调整列宽；状态组件使用 SwiftUI 自适应布局。

## 4. 安全性

- 所有传输通道启用 TLS，加密密钥由 CryptoKit 生成。
- 输入事件、会话凭证存储在系统钥匙串，通过 Secure Enclave 管理。
- 文件传输支持可选的国密算法扩展。

## 5. 原生扩展能力

- **官方小组件**：通过 `SkyBridgeCompassWidget` 支持 medium/large 小组件，WidgetKit 直接调用真实的 `DeviceDiscoveryService` 获取设备数量、状态并刷新时间线。
- **Siri / App Intents**：定义 `StartSkyBridgeSessionIntent`，用户可通过 Siri 快速唤醒应用并连接指定终端，事件通过 `NotificationCenter` 下发给主进程的 `DashboardViewModel`。
- **系统兼容**：Package.swift 统一声明 macOS 14 及以上目标，辅以运行时检查以兼容最新（macOS 15/16/26）系统能力。

## 6. 跟进落地

- ✅ **FreeRDP 动态库桥接**：通过 `CBFreeRDPClient` Objective-C 封装动态加载 `libfreerdp2.dylib`，Swift `RemoteDesktopManager` 统一调度连接生命周期。
- ✅ **Metal + VideoToolbox 渲染链路**：`RemoteFrameRenderer` 利用 VideoToolbox 解码 H.264/H.265 帧、Metal 纹理缓存完成 GPU 呈现，并回传实时带宽/延迟指标。
- ✅ **后台/通知/多租户管理**：`BackgroundTaskCoordinator` 调度 BGProcessing & NSBackgroundActivity，`FileTransferManager` 支持后台续传与通知，`TenantAccessController` 负责多租户权限与钥匙串凭据。
