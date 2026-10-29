# SkyBridge Core Layering

`SkyBridgeCore` 现在被拆成三层：

1. `SkyBridgeProtocolCore`
   只放协议契约、握手协商模型、跨网络 wire message，以及不依赖 AppKit / CloudKit / Network.framework 的协议辅助逻辑。
   现在也承载跨平台控制面里的轻量 HTTPS bootstrap 客户端与 ICE 配置模型。
   iOS 的 Xcode 与 SwiftPM 入口都必须通过这个 product 消费其公开类型，不能再把该 target 内的源文件直接编译进 App target。
2. `SkyBridgeAppleTransport`
   只放 Apple 平台传输实现，承载 `NativeWebSocketClient`、`WebSocketSignalingClient` 与原生 CoC 帧收发 `BluetoothControlFrameTransport`。每条 CoC 的原生流由独立运行循环线程持有，调用方用 `closeAndAwait()` 核对清理及实际线程退出。`BluetoothAudioChannel` 将共享协议层的四步确认和有序加密记录接到该原生流；它消费现有认证会话导出的单次凭证，不产生账户或播放授权。`BluetoothAudioListener` 及其内部原生 driver 在主队列管理加密 PSM、服务广告和有限候选；通过内部桥交出候选后，delegate 不再访问该通道或流，媒体 I/O 继续归独立 worker。发布 owner 必须保留到撤销回调和子通道清理确认，超时不得丢弃。账户和播放授权归 Core 接收会话；当前默认启动没有新增播放能力广告。
3. `SkyBridgeCore`
   保留现有运行时、Apple 平台服务、PQC 运行时适配、Remote Desktop、发现与 UI 所需集成逻辑，同时通过 typealias 兼容既有导入面。
   Mac 音频兼容输出 `CoreAudioOpusOutput` 与已有严格输出并列，复用原生 AVAudioEngine，只有显式 Opus 模式可使用。`AudioOpusPlayback` actor 连接已有解码/额度流程与该输出，不创建账户或播放许可，也不注册或广告蓝牙能力。共有的 `AudioOutputCleanupOutcome` 独立承载资源释放状态；原严格接收会话继续使用相同契约。
   `AudioPlaybackReceiveSession` 通过 `NativeAudioBluetoothPlaybackLink` 接入原生发布/认证子通道，先取得有限账户授权和精确音源许可，再准备输出。播放 actor 与会话分别持有原生执行和取消状态，控制批次按顺序提交；就绪消息实际发出后才读取媒体。服务复用既有单输出和清理恢复机制，并将实际消费者与两项蓝牙能力同时安装。默认入口仍关闭该安装，待 Android 发送端及直连无线验收后再启用；此接线尚未改变 MAIN 丢失即结束子通道的边界。

文件音频的独立组件 `SkyBridgeAudioFile` 依赖 `SkyBridgeProtocolCore` 和窄 C 桥
`CSkyBridgeFLAC`，承载同一份 Mac/iOS FLAC 解码、完整验证及有界 PCM 读取。
它不依赖 `SkyBridgeCore`、HAL、账户或传输；Mac 原有类型名通过别名指向该模块。
iOS 接入时消费根包 product，不复制解码源码或建立 LocalPackage。组件通过测试
不意味着 iOS 发送会话已经接入，也不意味着输出设备满足严格播放条件。

这样拆层的目的：

- 让协议模型不再被 `AppKit`、`IOKit`、`CloudKit` 这类平台能力污染。
- 给 Android / Ubuntu 后续接入预留一个稳定的“协议与 wire contract”边界。
- 把 Apple-only transport 明确成独立实现，避免后续跨平台移植时误把 `Network.framework` 当成协议核心。

当前第一刀已迁出的内容：

- `SkyBridgeServerConfig`
- `DeviceCapabilities` / `SkyBridgeMessages`
- `WebRTCSignalingEnvelope`
- `CrossNetworkFileTransferWire`
- `CrossNetworkCrypto`
- `CrossNetworkMerkle`
- `CrossNetworkMerkleAuth`
- `SkyBridgeICEConfiguration`
- `SignalServerClient`
- `NativeWebSocketClient`
- `WebSocketSignalingClient`

当前第二刀已迁出的握手元模型：

- `CryptoSuite` / `CryptoTier`
- `SignatureAlgorithm` / `ProtocolSigningAlgorithm`
- `CryptoProviderType`
- `CryptoCapabilities`
- `NegotiatedCryptoProfile`
- `P2PProtocolConstants`
- `TranscriptBuilder`
- `TranscriptVersion`
- `HandshakePolicy`
- `HandshakeState`
- `HandshakeFailureReason`
- `HandshakeRole`
- `SessionKeys`
- `HandshakeError`
- `AuthProfile`
- `PeerIdentifier`
- `HandshakeConstants`
- `DiscoveryTransport`
- `HandshakeTrustProvider`

当前第三刀已收窄的运行时接缝：

- `HandshakeKEMIdentityStore`
- `DefaultHandshakeKEMIdentityStore`（仍委托 `DeviceIdentityKeyManager`，不改变 Apple 当前密钥路径）
- `HandshakeIdentityProvider`
- `DeviceIdentityHandshakeProvider`（统一组装 `identityPublicKey` wire payload 与 `SigningKeyHandle`）

已知偏差（2026-07-28 架构审查更新）：

- **iOS 已开始消费、但尚未完全收敛到 `SkyBridgeProtocolCore`**：`ClassicTransferSafety`、`STUNMessageCodec`、`InboundFileTransferIOActor`、`CrossNetworkFileTransferWire` 与其入站 admission policy 已由 iOS 通过根包 product 导入，Xcode 工程不再重复直编这些源文件；其余握手、信令、QR、文件传输运行时文件仍有平行副本，部分已实质分叉（如 `TwoAttemptHandshakeManager`、`CrossNetworkWebRTCLocalAppMessageFactory`）。未迁移部分仍依赖 parity 闸门，而不是类型系统。
- **`SkyBridgeProtocolCore` 还不是完全平台无关的协议 target**：经典文件传输安全文件中仍包含 `Darwin` 文件描述符 I/O，`InboundFileTransferIOActor` 也是 Apple 平台实现。它们目前为 macOS/iOS 提供单一真相源，但在 Android/Linux 复用前必须把纯契约与 Apple I/O adapter 拆开。
- **WebRTC 进程级 runtime 已收敛为 `SkyBridgeWebRTCRuntime` product**：macOS `SkyBridgeCore`、iOS Xcode App target 与 iOS SwiftPM library 都通过同一模块消费工厂生命周期和出站帧 gate；iOS 工程不再 direct-source 编译 `WebRTCSessionRuntimeSupport.swift`，避免新增入口时再次形成 shared-source 接缝。
- **Apple P2P 路由决策已收敛到共享 policy（2026-08-03）**：`SkyBridgeProtocolCore.ApplePeerConnectivityPolicy` 统一服务角色、DNS-SD route identity、协议身份 claim、route provenance 与连接失败码；macOS/iOS 只保留 `NWBrowser`/`NWListener`/scene 生命周期 adapter。Apple 对端只能拨当前 browser generation 的 authority-bound endpoint，不能再从持久化名称、TXT host/port 或 `interface:nil` 重建路由。
- **同名 `P2PModels.swift` 不是一对可比较的协议副本**：iOS 文件承载 DTO，macOS 同名文件是连接引擎；真正共享的发现模型由 parity 脚本跨文件对照 `P2PDeviceModels.swift`。两端遗留 `P2PMessage.fileTransferRequest` payload schema 已分叉（iOS `P2PFileTransferRequest` 与 macOS `FileTransferRequest`），因此不能用相同 case 名声称 wire parity。该 JSON API 在 macOS 已弃用且当前无生产调用；新业务流必须继续使用已认证加密的 `AppMessage` 或共享 `CrossNetworkFileTransferWire`。若未来恢复该遗留通道，必须先定义共享 DTO 并按破坏性 wire 迁移处理。
- **设备消息存储、队列与服务是平台运行时分叉，不是独立 wire contract**：macOS 使用 actor repository 与 `P2PNetworkManager`，iOS 使用主线程持久化 facade 与 `P2PConnectionManager`，因此 parity 闸门将 `DeviceMessageStore`、`OfflineMessageQueue`、`DeviceMessagingService` 明确标记为 known fork。两端共享 `DeviceMessagingPolicy` 的输入上限、失败码和投递 disposition；线上消息格式仍必须来自 `AppMessage.textMessage`，并在原始 JSON 字节通过重复字段/单判别字段检查后解码。不能因为同名类型推断持久化、调度或错误呈现语义一致，相关行为必须由各平台测试分别证明。
- **`SkyBridgeCore` 中残留完整 SwiftUI 视图**（`Views/SettingsView.swift`、`Views/DeviceManagementView.swift`、`Diagnostics/DiscoveryDiagnosticsView.swift` 等），与 `SkyBridgeUI` 作为 UI 层的边界冲突，待迁出。
- **`SkyBridgeMediaLocal`**（iOS LocalPackages）仍与 macOS 源保持平行副本，但没有同步校验脚本或 CI 检查，存在静默漂移风险。`OQSRAIILocal` 已删除，iOS 直接消费根包的 `OQSRAII` product。

下一步建议：

1. **（优先）建立两端协议文件防漂移机制**：
   - **已落地（2026-06-16）**：`Scripts/check_protocol_parity.py` + `.github/workflows/protocol-parity.yml` 提供 CI 防漂移闸门。它自动发现 iOS `Sources/Core` 与 macOS `Sources/` 的同名协议文件（实时数量由闸门报告，另有显式豁免清单），对每侧做**归一化哈希**（剥离注释/import/空白）并与提交进仓的基线 `Scripts/protocol_parity_baseline.json` 比对——任一侧在未重新确认基线的情况下变更即失败，强制人工复核 wire 格式兼容性后再 `--update-baseline`；同时对**必须跨端一致的 wire 锚点**（如 DataChannel label `skybridge`/`skybridge-screen`）做等值断言。注意：由于两端文件已实质分叉，该闸门是**“变更确认 + 锚点等值”**而非“字节相等”。
   - **已完成的收敛切片（2026-07-30）**：iOS Xcode/SwiftPM 统一依赖根包 `SkyBridgeProtocolCore`，并移除 target 内对 `ClassicTransferSafety`、`STUNMessageCodec`、`InboundFileTransferIOActor`、`CrossNetworkFileTransferWire` 的重复直编；文件传输入队 shape/byte admission 也改为两端共享。
   - **长期**：逐组迁移剩余平行协议文件；每组先保留 parity 保护，再切换调用方 import，最后删除旧副本。不要用第二套 LocalPackage 或新增 direct-source 路径绕过模块边界。
2. 评估 `HandshakeIdentityProvider` 是否还需要再分成“协议签名身份”和“可选 SE PoP 身份”两个更细的 provider，以便 Android / Ubuntu 独立实现不同硬件能力。
3. 评估 `DeviceIdentityKeyManager` 周边是否还能再抽出一个更薄的本地身份接口，而不把 Apple Keychain / Secure Enclave 细节泄漏到协议层。
4. 把 `SignalServerClient`、`TURNCredentialService` 里的平台相关标识解析继续从控制面剥离。
5. 将 `SkyBridgeCore/Views` 中的完整 SwiftUI 视图迁往 `SkyBridgeUI`（小步迁移：先确认现有视觉基线测试覆盖，再移动，最后删除旧路径）。

性能约束：

- 本轮拆层只动协议面和控制面，不改 DataChannel、编解码、远控帧处理等媒体热路径。
- 本轮新增的握手拆层也只覆盖 suite/capability/transcript/policy 这些元模型，不改变握手中的实际加解密实现或媒体数据路径。
- 这意味着 Apple-to-Apple 的连通性和吞吐关键路径保持原位，拆层本身不应带来可感知性能回退。
