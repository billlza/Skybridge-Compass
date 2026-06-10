# SkyBridge Core Layering

`SkyBridgeCore` 现在被拆成三层：

1. `SkyBridgeProtocolCore`
   只放协议契约、握手协商模型、跨网络 wire message，以及不依赖 AppKit / CloudKit / Network.framework 的协议辅助逻辑。
   现在也承载跨平台控制面里的轻量 HTTPS bootstrap 客户端与 ICE 配置模型。
2. `SkyBridgeAppleTransport`
   只放 Apple 平台传输实现，目前承载 `NativeWebSocketClient` 与 `WebSocketSignalingClient`。
3. `SkyBridgeCore`
   保留现有运行时、Apple 平台服务、PQC 运行时适配、Remote Desktop、发现与 UI 所需集成逻辑，同时通过 typealias 兼容既有导入面。

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

已知偏差（2026-06-10 架构审查记录）：

- **iOS 端尚未消费 `SkyBridgeProtocolCore`**：`SkyBridge Compass iOS/` 的协议面（握手、wire、信令、QR、文件传输，约 60 个同名文件）是从 macOS 端手工复制后独立演化的，部分文件已实质分叉（如 `TwoAttemptHandshakeManager`）。两端兼容性目前依赖人工纪律 + parity 测试，而非类型系统。这是"给 Android / Ubuntu 预留稳定协议边界"目标下最大的回归风险来源。
- **`SkyBridgeCore` 中残留完整 SwiftUI 视图**（`Views/SettingsView.swift`、`Views/DeviceManagementView.swift`、`Diagnostics/DiscoveryDiagnosticsView.swift` 等），与 `SkyBridgeUI` 作为 UI 层的边界冲突，待迁出。
- **`OQSRAIILocal` / `SkyBridgeMediaLocal`**（iOS LocalPackages）当前与 macOS 源字节级一致，但没有同步校验脚本或 CI 检查，存在静默漂移风险。

下一步建议：

1. **（优先）建立两端协议文件防漂移机制**：短期为两端同名协议文件增加 CI 同步校验（哈希比对 + 显式豁免清单）；长期让 iOS 工程直接消费 `SkyBridgeProtocolCore`（或将其拆为 LocalPackage 引用），消除手工复制。
2. 评估 `HandshakeIdentityProvider` 是否还需要再分成“协议签名身份”和“可选 SE PoP 身份”两个更细的 provider，以便 Android / Ubuntu 独立实现不同硬件能力。
3. 评估 `DeviceIdentityKeyManager` 周边是否还能再抽出一个更薄的本地身份接口，而不把 Apple Keychain / Secure Enclave 细节泄漏到协议层。
4. 把 `SignalServerClient`、`TURNCredentialService` 里的平台相关标识解析继续从控制面剥离。
5. 将 `SkyBridgeCore/Views` 中的完整 SwiftUI 视图迁往 `SkyBridgeUI`（小步迁移：先确认现有视觉基线测试覆盖，再移动，最后删除旧路径）。

性能约束：

- 本轮拆层只动协议面和控制面，不改 DataChannel、编解码、远控帧处理等媒体热路径。
- 本轮新增的握手拆层也只覆盖 suite/capability/transcript/policy 这些元模型，不改变握手中的实际加解密实现或媒体数据路径。
- 这意味着 Apple-to-Apple 的连通性和吞吐关键路径保持原位，拆层本身不应带来可感知性能回退。
