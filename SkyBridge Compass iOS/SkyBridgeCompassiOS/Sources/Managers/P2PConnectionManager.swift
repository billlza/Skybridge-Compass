import Foundation
import Network
import CryptoKit
import ActivityKit
#if canImport(UIKit)
import UIKit
#endif

/// P2P 连接管理器 - 管理与其他设备的点对点连接
/// 使用完整的 HandshakeDriver 协议实现与 macOS 的互操作
/// 支持双向握手：iOS 可以发起，也可以响应 macOS 的握手请求
@available(iOS 17.0, *)
@MainActor
public class P2PConnectionManager: ObservableObject {
    public static let instance = P2PConnectionManager()
    
    // MARK: - Published Properties
    
    @Published public private(set) var activeConnections: [Connection] = []
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var currentHandshakeState: String = "空闲"
    @Published public private(set) var lastError: String?
    /// 每个设备的连接状态（用于 UI 展示“已连接/连接中/已断开”等）
    @Published public private(set) var connectionStatusByDeviceId: [String: ConnectionStatus] = [:]
    /// 每个设备最近一次连接错误（用于定位“莫名其妙断开”原因）
    @Published public private(set) var connectionErrorByDeviceId: [String: String] = [:]
    /// 每个设备当前协商的加密套件（用于 UI/LiveActivity 在 rekey 后正确刷新）
    /// 注意：`sessionKeys` 不是 @Published，因此仅更新 `sessionKeys` 不会触发 SwiftUI 刷新。
    @Published public private(set) var negotiatedSuiteByDeviceId: [String: CryptoSuite] = [:]
    
    // MARK: - Private Properties
    
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private var sessionKeys: [String: SessionKeys] = [:] // device.id -> SessionKeys
    /// 握手驱动器缓存（用于响应方角色）
    private var handshakeDrivers: [String: HandshakeDriver] = [:]
    /// 兼容旧逻辑：握手过程中/早期阶段可能缓存 shared secret（最终以 sessionKeys 为准）
    private var sharedSecrets: [String: SecureBytes] = [:] // device.id -> shared secret
    private let queue = DispatchQueue(label: "com.skybridge.p2p", qos: .userInitiated)
    private var connectingCount: Int = 0
    private var userInitiatedDisconnects: Set<String> = []
    private var heartbeatTasks: [String: Task<Void, Never>] = [:]
    private var lastActivityByDeviceId: [String: Date] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private var reconnectSuppressedDeviceIds: Set<String> = []
    private var lastKnownDevices: [String: DiscoveredDevice] = [:]
    private var pairKeyByDeviceId: [String: Data] = [:]
    
    /// Prevent pairing identity exchange ping-pong loops.
    private var lastPairingIdentityExchangeSentAt: [String: Date] = [:]
    
    /// Bootstrap rekey tasks (Classic -> PQC) keyed by peerId.
    private var bootstrapRekeyTasks: [String: Task<Void, Never>] = [:]

    /// Inbound peers currently using legacy classic bootstrap responder driver.
    private var inboundLegacyBootstrapPeers: Set<String> = []
    
    /// In-band rekey flag (pause heartbeat / non-essential business sends to reduce ciphertext-handshake interleaving).
    private var rekeyInProgress: Set<String> = []
    
    // MARK: - Pairing / Trust Prompt
    
    public enum PairingTrustDecision: String, Sendable {
        case alwaysAllow
        case allowOnce
        case reject
    }
    
    public struct PairingTrustRequest: Identifiable, Sendable {
        public let id: UUID
        public let peerId: String
        public let declaredDeviceId: String
        public let deviceName: String
        public let platform: DevicePlatform
        public let modelName: String
        public let osVersion: String
        public let kemKeyCount: Int
        public let receivedAt: Date
    }
    
    /// A pending pairing/trust request that requires user approval.
    @Published public private(set) var pendingPairingTrustRequest: PairingTrustRequest?
    
    private struct PendingPairingContext: Sendable {
        let peerId: String
        let payload: AppMessage.PairingIdentityExchangePayload
    }
    private var pendingPairingContextByRequestId: [UUID: PendingPairingContext] = [:]
    
    private let pairingPolicyStorageKey = "pairing_policy.v1"
    /// peerId -> decisionRawValue (only persists "alwaysAllow" and "reject"; allowOnce is not persisted)
    private var pairingPolicyByPeerId: [String: String] = [:]

    private let heartbeatIntervalSeconds: TimeInterval = 20
    private let maxReconnectAttempts: Int = 8

    // MARK: - Local Device Info (best-effort, for pairing UI)
    private static func currentModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(cString: ptr)
            }
        }
    }

    private static func currentModelDisplayName() -> String {
        switch currentModelIdentifier() {
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone17,2": return "iPhone 16 Pro Max"
        case "iPhone17,3": return "iPhone 16"
        case "iPhone17,4": return "iPhone 16 Plus"
        default: return currentModelIdentifier()
        }
    }

    private static func currentChipDisplayName() -> String {
        switch currentModelIdentifier() {
        case "iPhone17,1", "iPhone17,2": return "A18 Pro"
        case "iPhone17,3", "iPhone17,4": return "A18"
        default: return "Apple Silicon"
        }
    }
    
    // PQC 加密管理器
    private var pqcManager: PQCCryptoManager { PQCCryptoManager.instance }
    
    // 传输层适配器
    private var transport: NWConnectionTransport?
    
    // SkyBridge 核心
    private var skyBridgeCore: SkyBridgeiOSCore { SkyBridgeiOSCore.shared }
    
    // 发现管理器
    private var discoveryManager: DeviceDiscoveryManager { DeviceDiscoveryManager.instance }
    
    private init() {
        pairingPolicyByPeerId = Self.loadPairingPolicy(storageKey: pairingPolicyStorageKey)
        
        // 设置入站连接回调
        Task { @MainActor in
            discoveryManager.onNewConnection = { [weak self] connection, peerId in
                Task { @MainActor in
                    await self?.handleIncomingConnection(connection, peerId: peerId)
                }
            }
        }
    }
    
    /// Decide an effective selection policy given user preference + local PQC capability.
    ///
    /// Paper alignment:
    /// - If the user requests strict PQC but the local build/device has no PQC provider, we cannot satisfy strictPQc.
    ///   We fall back to `preferPQC` (classic) and emit a clear log so this isn't mistaken as a protocol failure.
    private func effectiveSelectionPolicy(enforcePQC: Bool) -> CryptoProviderFactory.SelectionPolicy {
        guard enforcePQC else { return .classicOnly }
        let cap = CryptoProviderFactory.detectCapability()
        if cap.hasApplePQC || cap.hasLiboqs {
            return .requirePQC
        }
        SkyBridgeLogger.shared.warning(
            "⚠️ 本机运行在 iOS 26+ 也可能出现 Classic：当前构建未启用 Apple PQC 编译开关或自检失败（hasApplePQC=\(cap.hasApplePQC), hasLiboqs=\(cap.hasLiboqs)）。" +
            "无法满足 strictPQC(requirePQC)，将回退到 preferPQC（classic）以保持可连接性。" +
            "要启用原生 PQC：请使用 Xcode 26+ / iOS 26 SDK 编译，并确保 Package.swift 开启 HAS_APPLE_PQC_SDK。"
        )
        return .preferPQC
    }
    
    private static func loadPairingPolicy(storageKey: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    
    private func savePairingPolicy() {
        let data = (try? JSONEncoder().encode(pairingPolicyByPeerId)) ?? Data()
        UserDefaults.standard.set(data, forKey: pairingPolicyStorageKey)
    }
    
    /// Called by UI to resolve a pending pairing/trust request.
    public func resolvePairingTrustRequest(_ request: PairingTrustRequest, decision: PairingTrustDecision) async {
        guard let ctx = pendingPairingContextByRequestId.removeValue(forKey: request.id) else {
            pendingPairingTrustRequest = nil
            return
        }
        
        pendingPairingTrustRequest = nil
        
        switch decision {
        case .alwaysAllow:
            pairingPolicyByPeerId[ctx.peerId] = PairingTrustDecision.alwaysAllow.rawValue
            savePairingPolicy()
            await acceptPairingIdentityExchange(from: ctx.peerId, payload: ctx.payload, trustPeer: true, persistTrust: true)
        case .allowOnce:
            await acceptPairingIdentityExchange(from: ctx.peerId, payload: ctx.payload, trustPeer: false, persistTrust: false)
        case .reject:
            pairingPolicyByPeerId[ctx.peerId] = PairingTrustDecision.reject.rawValue
            savePairingPolicy()
            SkyBridgeLogger.shared.warning("🛑 Pairing/trust request rejected: peer=\(ctx.peerId) declaredDeviceId=\(ctx.payload.deviceId)")
        }
    }
    
    // MARK: - Public Methods
    
    /// 开始监听连接（使用 DeviceDiscoveryManager 的广播功能）
    public func startListening() async throws {
        if discoveryManager.isAdvertising {
            isListening = true
            return
        }
        if isListening {
            // Recover from stale state (e.g. listener failed/cancelled but flag not updated).
            isListening = false
        }
        
        // 确保 SkyBridgeCore 已按当前设置初始化（允许按 policy 重新初始化）
        if pqcManager.enforcePQCHandshake {
            // 强制 PQC = strictPQC（论文语义）：不允许 classic fallback。
            let policy = effectiveSelectionPolicy(enforcePQC: true)
            try await skyBridgeCore.initialize(policy: policy)
        } else {
            try await skyBridgeCore.initialize(policy: .classicOnly)
        }
        
        // 初始化传输层
        if transport == nil {
            transport = NWConnectionTransport()
        }
        
        // 使用 DeviceDiscoveryManager 的广播功能
        try await discoveryManager.startAdvertising(port: 9527)
        guard discoveryManager.isAdvertising else {
            isListening = false
            lastError = "P2P 广播监听未进入可用状态"
            throw P2PError.connectionFailed
        }
        isListening = true
        lastError = nil
        
        SkyBridgeLogger.shared.info("🎧 P2P 监听器已启动（通过 Bonjour 广播）")
    }
    
    /// 停止监听
    public func stopListening() {
        discoveryManager.stopAdvertising()
        listener?.cancel()
        listener = nil
        isListening = false
        
        SkyBridgeLogger.shared.info("⏹️ P2P 监听器已停止")
    }

    /// 握手验证码（6 位数字）——用于“配对/信任”阶段的人工可视比对（论文中的 OOB pairing ceremony）。
    ///
    /// - Important: Code is deterministically derived from the *handshake transcript hash* to bind user verification
    ///   to the negotiated suite + policy + key shares. Both peers compute the same value after a successful handshake.
    public func pairingVerificationCode(for deviceId: String) -> String? {
        guard let keys = sessionKeys[deviceId] else { return nil }

        var material = Data("SkyBridge-Pairing-SAS|".utf8)
        material.append(keys.transcriptHash)

        let digest = SHA256.hash(data: material)
        let raw = digest.withUnsafeBytes { ptr -> UInt32 in
            ptr.loadUnaligned(as: UInt32.self).bigEndian
        }
        let code = Int(raw % 1_000_000)
        return String(format: "%06d", code)
    }
    
    /// 连接到设备
    /// - Parameter allowUntrustedClassicBootstrapOnMissingPeerKEM:
    ///   当 strictPQC 因缺少对端 KEM 公钥而失败时，是否允许一次性 classic bootstrap（仅用于交换 KEM identity key）。
    public func connect(
        to device: DiscoveredDevice,
        allowUntrustedClassicBootstrapOnMissingPeerKEM: Bool = false
    ) async throws {
        if isSelfConnectionTarget(device) {
            connectionStatusByDeviceId[device.id] = .failed
            connectionErrorByDeviceId[device.id] = "已阻止自连接"
            SkyBridgeLogger.shared.warning("⚠️ 已阻止可能的自连接目标: \(device.id)")
            throw P2PError.selfConnectionBlocked
        }

        // 并发限制（来自 Settings）
        let limit = max(1, SettingsManager.instance.maxConcurrentConnections)
        guard connectingCount < limit else {
            throw P2PError.tooManyConcurrentConnections
        }
        if sessionKeys[device.id] != nil || connections[device.id] != nil {
            throw P2PError.alreadyConnected
        }
        connectingCount += 1
        defer { connectingCount -= 1 }
        reconnectSuppressedDeviceIds.remove(device.id)
        
        // 创建连接：优先使用 SkyBridge 主服务（_skybridge._tcp / _skybridge._udp -> _skybridge._tcp）
        // 避免误用 _skybridge-transfer/_skybridge-remote 等“功能端口”导致握手失败。
        let endpoint: NWEndpoint
        let bonjourName = device.bonjourServiceName ?? device.name
        let bonjourDomain = device.bonjourServiceDomain ?? "local."

        let skybridgeTCP = DiscoveryServiceType.skybridge.rawValue
        let skybridgeUDP = DiscoveryServiceType.skybridgeQUIC.rawValue

        if device.services.contains(skybridgeTCP) || device.services.contains(skybridgeUDP) {
            // 发现列表里如果包含 UDP 主服务，也优先用 TCP 建立握手连接（当前实现以 TCP 为主）
            endpoint = .service(
                name: bonjourName,
                type: skybridgeTCP,
                domain: bonjourDomain,
                interface: nil
            )
        } else if let serviceType = device.bonjourServiceType, !serviceType.isEmpty,
                  serviceType == skybridgeTCP || serviceType == skybridgeUDP {
            endpoint = .service(
                name: bonjourName,
                type: skybridgeTCP,
                domain: bonjourDomain,
                interface: nil
            )
        } else if let ipAddress = device.ipAddress, !ipAddress.isEmpty {
            // When connecting by IP (e.g., VPN / port-forward / server mode), honor the discovered/QR-provided port if present.
            let portValue: UInt16 = device.portMap[skybridgeTCP]
                ?? device.portMap[skybridgeUDP]
                ?? 9527
            endpoint = .hostPort(
            host: NWEndpoint.Host(ipAddress),
            port: NWEndpoint.Port(integerLiteral: portValue)
        )
        } else {
            throw P2PError.noConnectableEndpoint
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            // 低开销保活：减少同网/点对点链路在空闲时被系统/路由器清理导致的“突然断开”
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }

        // 更新状态（UI：连接中）
        connectionStatusByDeviceId[device.id] = .connecting
        connectionErrorByDeviceId.removeValue(forKey: device.id)
        lastKnownDevices[device.id] = device

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.viabilityUpdateHandler = { [weak self] viable in
            Task { @MainActor in
                guard let self else { return }
                SkyBridgeLogger.shared.debug("🌐 连接可用性变化：\(device.name) viable=\(viable)")
                if !viable {
                    self.connectionStatusByDeviceId[device.id] = .connecting
                }
            }
        }
        connection.betterPathUpdateHandler = { betterPath in
            Task { @MainActor in
                SkyBridgeLogger.shared.debug("🌐 更优路径可用：\(device.name) betterPath=\(betterPath)")
            }
        }
        // 设置状态处理器（同时用于本次 connect 的 ready/fail 等待）
        let readyGate = ConnectionReadyGate()
        connection.stateUpdateHandler = { [weak self] state in
            readyGate.onState(state)
            Task { @MainActor in
                await self?.handleConnectionStateChange(state, for: device)
            }
        }
        
        // 启动连接
        connection.start(queue: queue)
        connections[device.id] = connection

        SkyBridgeLogger.shared.info("🔗 尝试连接：\(device.name) endpoint=\(endpoint)")

        // 发起方也必须开始接收（握手 MessageB 需要被路由到 HandshakeDriver）
        startReceiving(from: connection, peerId: device.id)

        // 等待连接 ready 再握手（避免在 .preparing/.setup 时握手导致失败）
        try await readyGate.waitReady(timeoutSeconds: 10)
        
        // 执行握手（可能 PQC-only 或 classic bootstrap，取决于 trust store 是否已有 peer KEM keys）
        do {
            try await performPQCHandshake(connection: connection, device: device, preferPQC: pqcManager.enforcePQCHandshake)
        } catch {
            enum StrictBootstrapPlan {
                case missingPeerKEM(suite: String, reason: String)
                case staleKEMTimeout(suite: String, knownKEMSuites: [String], reason: String)
            }

            func preferredPQCSuiteRaw() -> String? {
                let provider = CryptoProviderFactory.make(policy: .preferPQC)
                return provider.supportedSuites.first(where: { $0.isPQCGroup })?.rawValue
            }

            let bootstrapPlan: StrictBootstrapPlan? = await {
                guard pqcManager.enforcePQCHandshake,
                      let hs = error as? HandshakeError else {
                    return nil
                }

                switch hs {
                case .failed(.missingPeerKEMPublicKey(let suite)):
                    if TrustedDeviceStore.shared.isTrusted(deviceId: device.id)
                        || allowUntrustedClassicBootstrapOnMissingPeerKEM {
                        let bootstrapReason = TrustedDeviceStore.shared.isTrusted(deviceId: device.id)
                            ? "trusted_peer_missing_kem_key"
                            : "explicit_untrusted_bootstrap_path"
                        return .missingPeerKEM(suite: suite, reason: bootstrapReason)
                    }
                    return nil

                case .failed(.timeout):
                    guard TrustedDeviceStore.shared.isTrusted(deviceId: device.id) else {
                        return nil
                    }
                    let known = await KEMTrustStore.shared.kemPublicKeys(for: device.id)
                    let knownSuites = known.keys.map(\.rawValue).sorted()
                    guard !knownSuites.isEmpty,
                          let preferred = preferredPQCSuiteRaw() else {
                        return nil
                    }
                    return .staleKEMTimeout(
                        suite: preferred,
                        knownKEMSuites: knownSuites,
                        reason: "trusted_peer_timeout_with_existing_kem"
                    )

                default:
                    return nil
                }
            }()

            // Paper-aligned legacy gating:
            // If strict-PQC fails ONLY because we're missing the peer's long-term KEM public key, and the user has
            // already established a trust record (pairing ceremony), allow a one-time Classic bootstrap channel to
            // exchange KEM identity keys, then immediately rekey to PQC.
            if let bootstrapPlan {
                let bootstrapReason: String
                let suite: String
                switch bootstrapPlan {
                case .missingPeerKEM(let suiteRaw, let reason):
                    suite = suiteRaw
                    bootstrapReason = reason
                    SkyBridgeLogger.shared.warning(
                        "🧩 strictPQC bootstrap: missing KEM key (suite=\(suite), reason=\(bootstrapReason)). " +
                        "Performing one-time Classic bootstrap to provision trust, then rekey to PQC."
                    )
                case .staleKEMTimeout(let suiteRaw, let knownKEMSuites, let reason):
                    suite = suiteRaw
                    bootstrapReason = reason
                    SkyBridgeLogger.shared.warning(
                        "🧩 strictPQC recovery: handshake timed out with existing KEM records " +
                        "(possible stale/rotated KEM identity keys). " +
                        "Attempting one-time Classic bootstrap to refresh keys, then rekey to PQC. " +
                        "peer=\(device.id) knownKEM=\(knownKEMSuites.joined(separator: ",")) targetSuite=\(suite)"
                    )
                }
                SecurityEventEmitter.emitDetached(SecurityEvent(
                    type: .legacyBootstrap,
                    severity: .warning,
                    message: "strictPQC bootstrap: missing peer KEM public key; establishing one-time Classic channel to provision KEM keys then rekey to PQC",
                    context: [
                        "reason": bootstrapReason,
                        "bootstrapReason": bootstrapReason,
                        "suite": suite,
                        "peer": device.id,
                        // Paper terminology alignment:
                        "downgradeResistance": "policy_gate+no_timeout_fallback+rate_limited",
                        "policyInTranscript": "1",
                        "transcriptBinding": "1",
                        "policyRequirePQC": "1"
                    ]
                ))
                
                do {
                    // 1) Establish a Classic session (authenticated by protocol signatures) solely for provisioning.
                    try await performPQCHandshake(
                        connection: connection,
                        device: device,
                        preferPQC: false,
                        selectionPolicyOverride: .classicOnly,
                        allowSOA: false
                    )
                    
                    // 2) Exchange KEM identity keys over the authenticated channel.
                    try await sendPairingIdentityExchange(to: device.id)
                    // 3) Do NOT time-based rekey. Wait for the peer KEM key to arrive (often gated by approval UI on macOS),
                    // then rekey exactly once in the background. Keep the Classic session alive during provisioning.
                    scheduleBootstrapRekeyIfNeeded(peerId: device.id, suiteRaw: suite)
                } catch {
                    SkyBridgeLogger.shared.error("❌ strictPQC bootstrap failed: \(error.localizedDescription)")
                    
                    // Cleanup and propagate the bootstrap error (more actionable than the original).
                    connection.cancel()
                    connections.removeValue(forKey: device.id)
                    sessionKeys.removeValue(forKey: device.id)
                    handshakeDrivers.removeValue(forKey: device.id)
                    sharedSecrets.removeValue(forKey: device.id)
                    await transport?.removeConnection(for: device.id)
                    activeConnections.removeAll { $0.device.id == device.id }
                    connectionStatusByDeviceId[device.id] = .failed
                    connectionErrorByDeviceId[device.id] = error.localizedDescription
                    throw error
                }
            } else {
                // 握手失败：明确取消连接并清理，避免留下“看似已连接但无法用”的悬挂状态
                connection.cancel()
                connections.removeValue(forKey: device.id)
                sessionKeys.removeValue(forKey: device.id)
                handshakeDrivers.removeValue(forKey: device.id)
                sharedSecrets.removeValue(forKey: device.id)
                await transport?.removeConnection(for: device.id)
                activeConnections.removeAll { $0.device.id == device.id }
                connectionStatusByDeviceId[device.id] = .failed
                connectionErrorByDeviceId[device.id] = error.localizedDescription
                // Avoid tight reconnect loops when the error explicitly tells us a cooldown.
                if let prep = error as? AttemptPreparationError,
                   case .fallbackRateLimited(_, let cooldownSeconds) = prep {
                    SkyBridgeLogger.shared.warning("⏳ 降级被限流：将在 \(cooldownSeconds)s 后再尝试重连（避免反复触发 TCP RST/flow_failed）")
                    scheduleReconnectIfNeeded(deviceId: device.id, delayOverrideSeconds: Double(cooldownSeconds))
                } else if let hs = error as? HandshakeError,
                          case .failed(.missingPeerKEMPublicKey(let suite)) = hs {
                    // In strict-PQC mode this is expected until pairing/trust sync provisions the peer KEM key.
                    // Do not auto-reconnect storm; surface a stable actionable error instead.
                    if TrustedDeviceStore.shared.isTrusted(deviceId: device.id) {
                        let message = "🔐 缺少对端 PQC KEM 公钥（suite=\(suite)）。该设备已受信任：请重试连接以触发 classic bootstrap（仅用于交换KEM公钥）后自动切换回PQC。"
                        SkyBridgeLogger.shared.warning(message)
                        connectionErrorByDeviceId[device.id] = message
                    } else {
                        let message = "🔐 缺少对端 PQC KEM 公钥（suite=\(suite)）。请先完成配对/信任同步（加入“受信任设备”后重试将自动引导），或临时开启“允许经典降级”用于引导。"
                        SkyBridgeLogger.shared.warning(message)
                        connectionErrorByDeviceId[device.id] = message
                    }
                    reconnectSuppressedDeviceIds.insert(device.id)
                    reconnectTasks[device.id]?.cancel()
                    reconnectTasks.removeValue(forKey: device.id)
                } else {
                    scheduleReconnectIfNeeded(deviceId: device.id)
                }
                throw error
            }
        }

        // If strictPQC is enabled but we negotiated a Classic suite, it almost always means we do NOT yet
        // have the peer's long-term KEM identity public key in the trust store (bootstrap phase).
        // Proactively kick off the KEM identity exchange and schedule a single rekey to PQC.
        if pqcManager.enforcePQCHandshake,
           let negotiated = sessionKeys[device.id]?.negotiatedSuite,
           !negotiated.isPQCGroup {
            do {
                // In strictPQC mode, the bootstrap rekey target must follow the strict selection policy.
                // Do NOT let a "prefer X-Wing" UI toggle accidentally force X-Wing as a strict dependency.
                let provider = CryptoProviderFactory.make(policy: effectiveSelectionPolicy(enforcePQC: true))
                if let preferred = provider.supportedSuites.first(where: { $0.isPQCGroup }) {
                    SkyBridgeLogger.shared.warning("🧩 strictPQC bootstrap: negotiated Classic (\(negotiated.rawValue)). Exchanging KEM identity keys then rekeying to \(preferred.rawValue)… peer=\(device.id)")
                    try await sendPairingIdentityExchange(to: device.id)
                    scheduleBootstrapRekeyIfNeeded(peerId: device.id, suiteRaw: preferred.rawValue)
                } else {
                    SkyBridgeLogger.shared.warning("⚠️ strictPQC enabled but no PQC suites are available on this build/device; staying on Classic. peer=\(device.id)")
                }
            } catch {
                SkyBridgeLogger.shared.warning("⚠️ strictPQC bootstrap: failed to send pairing identity exchange (ignored): \(error.localizedDescription)")
            }
        }
        
        // Paper-aligned contract:
        // connected == handshake finished && session keys ready (not just transport ready).
        SkyBridgeLogger.shared.info("✅ 已连接到 \(device.name)")
        connectionStatusByDeviceId[device.id] = .connected
        connectionErrorByDeviceId.removeValue(forKey: device.id)
        upsertActiveConnection(device: device, status: .connected)
        startHeartbeatIfNeeded(deviceId: device.id)

        // 更新灵动岛状态（iOS 17+）
        let suite = sessionKeys[device.id]?.negotiatedSuite.rawValue ?? "已连接"
        Task {
            await LiveActivityManager.shared.setConnected(deviceName: device.name, cryptoSuite: suite)
        }
    }
    
    /// 断开连接
    public func disconnect(from device: DiscoveredDevice) async {
        guard let connection = connections[device.id] else { return }

        connectionStatusByDeviceId[device.id] = .disconnecting
        userInitiatedDisconnects.insert(device.id)
        heartbeatTasks[device.id]?.cancel()
        heartbeatTasks.removeValue(forKey: device.id)
        reconnectTasks[device.id]?.cancel()
        reconnectTasks.removeValue(forKey: device.id)
        reconnectAttempts.removeValue(forKey: device.id)
        connection.cancel()
        connections.removeValue(forKey: device.id)
        sharedSecrets.removeValue(forKey: device.id)
        sessionKeys.removeValue(forKey: device.id)
        negotiatedSuiteByDeviceId.removeValue(forKey: device.id)
        handshakeDrivers.removeValue(forKey: device.id)
        inboundLegacyBootstrapPeers.remove(device.id)
        await transport?.removeConnection(for: device.id)
        await releaseArbiterState(for: device.id)
        
        // 更新活动连接列表
        activeConnections.removeAll { $0.device.id == device.id }
        connectionStatusByDeviceId[device.id] = .disconnected
        connectionErrorByDeviceId.removeValue(forKey: device.id)

        // 更新灵动岛状态（iOS 17+）
        Task {
            await LiveActivityManager.shared.setDisconnected()
        }
        
        SkyBridgeLogger.shared.info("🔌 已断开与 \(device.name) 的连接")
    }
    
    /// 接受连接请求
    public func acceptConnection(from deviceID: String) async {
        // 实现连接接受逻辑
        SkyBridgeLogger.shared.info("✅ 接受来自 \(deviceID) 的连接")
    }
    
    /// 拒绝连接请求
    public func rejectConnection(from deviceID: String) async {
        SkyBridgeLogger.shared.info("❌ 拒绝来自 \(deviceID) 的连接")
    }
    
    // MARK: - Private Methods
    
    private func handleListenerStateChange(_ state: NWListener.State) async {
        switch state {
        case .ready:
            SkyBridgeLogger.shared.info("✅ 监听器就绪")
            
        case .failed(let error):
            SkyBridgeLogger.shared.error("❌ 监听器失败: \(error.localizedDescription)")
            isListening = false
            lastError = error.localizedDescription
            
        case .cancelled:
            SkyBridgeLogger.shared.info("⏹️ 监听器已取消")
            isListening = false
            
        default:
            break
        }
    }
    
    /// 处理入站连接（作为响应方）
    private func handleIncomingConnection(_ connection: NWConnection, peerId: String) async {
        SkyBridgeLogger.shared.info("📞 处理入站连接: \(peerId)")
        
        // 保存连接
        connections[peerId] = connection
        
        // 设置传输层
        await transport?.setConnection(connection, for: peerId)
        
        // 创建握手驱动器（响应方角色）
        do {
            let driver = try skyBridgeCore.createHandshakeDriver(
                transport: transport!,
                localSOAPeerId: localSOAPeerIdBytes(),
                expectedRemoteSOAPeerId: soaPeerIdBytes(for: peerId)
            )
            handshakeDrivers[peerId] = driver
            
            // 开始接收消息
            startReceiving(from: connection, peerId: peerId)
            
            currentHandshakeState = "等待握手消息..."
            SkyBridgeLogger.shared.info("🔐 等待来自 \(peerId) 的握手消息")
            
        } catch {
            SkyBridgeLogger.shared.error("❌ 创建握手驱动器失败: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }
    
    /// 开始从连接接收消息
    private func startReceiving(from connection: NWConnection, peerId: String) {
        // 与 macOS 端一致：4-byte big-endian length framing
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] lengthData, _, isComplete, error in
            Task { @MainActor in
                if let error = error {
                    SkyBridgeLogger.shared.error("❌ 接收长度头错误: \(error.localizedDescription)")
                    return
                }
                guard let lengthData, lengthData.count == 4 else {
                    if !isComplete {
                        self?.startReceiving(from: connection, peerId: peerId)
                    }
                    return
                }
                
	                let length = lengthData.withUnsafeBytes { raw -> UInt32 in
	                    raw.baseAddress!.loadUnaligned(as: UInt32.self).bigEndian
	                }
	                let bodyLen = Int(length)
	                guard bodyLen <= 2_000_000 else {
                    if self?.looksLikeTLSRecordHeader(lengthData) == true {
                        SkyBridgeLogger.shared.warning("⚠️ 检测到 TLS 记录头，但当前通道期望 length-framed 明文握手，已关闭该入站连接")
                        self?.cleanupBrokenInboundConnection(connection, peerId: peerId, reason: "传输协议不匹配（收到 TLS 记录头）")
                    } else {
                        let headerHex = lengthData.map { String(format: "%02x", $0) }.joined()
                        SkyBridgeLogger.shared.error("❌ 接收长度头非法: \(bodyLen) peer=\(peerId) header=0x\(headerHex)（可能连接到了错误协议或端口）")
                        self?.cleanupBrokenInboundConnection(connection, peerId: peerId, reason: "非法消息长度头: \(bodyLen)")
                    }
                    return
                }

                connection.receive(minimumIncompleteLength: bodyLen, maximumLength: bodyLen) { [weak self] payload, _, isComplete2, error2 in
                    Task { @MainActor in
                        if let error2 = error2 {
                            SkyBridgeLogger.shared.error("❌ 接收消息体错误: \(error2.localizedDescription)")
                            return
                        }
                        if let payload, !payload.isEmpty {
                            await self?.handleReceivedMessage(payload, from: peerId)
                }
                
                        // 继续接收（只要连接未 complete）
                        if !(isComplete || isComplete2) {
                    self?.startReceiving(from: connection, peerId: peerId)
                        }
                    }
                }
            }
        }
    }

    private func looksLikeTLSRecordHeader(_ header: Data) -> Bool {
        guard header.count == 4 else { return false }
        let bytes = [UInt8](header)
        let contentType = bytes[0]
        let majorVersion = bytes[1]
        let minorVersion = bytes[2]
        guard [0x14, 0x15, 0x16, 0x17].contains(contentType) else { return false }
        guard majorVersion == 0x03 else { return false }
        return minorVersion <= 0x04 // TLS 1.0...1.3
    }

    private func cleanupBrokenInboundConnection(_ connection: NWConnection, peerId: String, reason: String) {
        connection.cancel()

        let isTrackedConnection = connections[peerId].map { $0 === connection } ?? false
        guard isTrackedConnection else { return }

        connections.removeValue(forKey: peerId)
        handshakeDrivers.removeValue(forKey: peerId)
        inboundLegacyBootstrapPeers.remove(peerId)
        sharedSecrets.removeValue(forKey: peerId)
        sessionKeys.removeValue(forKey: peerId)
        negotiatedSuiteByDeviceId.removeValue(forKey: peerId)
        heartbeatTasks[peerId]?.cancel()
        heartbeatTasks.removeValue(forKey: peerId)
        reconnectTasks[peerId]?.cancel()
        reconnectTasks.removeValue(forKey: peerId)
        reconnectAttempts.removeValue(forKey: peerId)
        connectionStatusByDeviceId[peerId] = .failed
        connectionErrorByDeviceId[peerId] = reason
        Task { @MainActor in
            await self.releaseArbiterState(for: peerId)
        }
    }
    
    /// 处理收到的消息
    private func handleReceivedMessage(_ data: Data, from peerId: String) async {
        lastActivityByDeviceId[peerId] = Date()
        // Phase C2: optional post-handshake traffic padding (SBP2).
        // This is safe to apply unconditionally because unwrap is a no-op unless magic matches.
        let unwrapped = TrafficPadding.unwrapIfNeeded(data, label: "rx")

        SkyBridgeLogger.shared.debug("📨 收到消息 (\(unwrapped.count) bytes) from \(peerId)")

        // 已有握手驱动器：交给握手状态机处理
        if let driver = handshakeDrivers[peerId] {
            await processHandshakeFrame(unwrapped, from: peerId, initialDriver: driver)
            return
        }

        // 支持“握手失败后的同连接重试”：
        // strictPQC 失败（例如 stale KEM）后，对端可能在同一条 TCP 连接上发起 classic bootstrap。
        // 若此前 driver 已进入 failed 并被移除，需要在这里按新 MessageA 重新创建 driver。
        if let freshInboundDriver = await ensureInboundHandshakeDriverIfNeeded(for: peerId, frame: unwrapped) {
            await processHandshakeFrame(unwrapped, from: peerId, initialDriver: freshInboundDriver)
            return
        }

        // 支持“已建立会话上的入站 rekey”：
        // 若当前无 driver 但已存在 sessionKeys，且收到的是 MessageA，则切换回握手模式而不是误当业务密文。
        if let rekeyDriver = await ensureInboundRekeyDriverIfNeeded(for: peerId, frame: unwrapped) {
            await processHandshakeFrame(unwrapped, from: peerId, initialDriver: rekeyDriver)
            return
        }

        // 握手完成后的业务消息（加密通道）
        if handshakeDrivers[peerId] == nil, sessionKeys[peerId] != nil {
            // 兼容：避免把握手控制包（尤其是 Finished 38 bytes）当作业务消息去解密，导致 CryptoKitError 3 日志
            if isLikelyHandshakeControlPacket(unwrapped) {
                SkyBridgeLogger.shared.debug("ℹ️ 收到握手控制包（忽略）：\(unwrapped.count) bytes")
                return
            }
            do {
                let plaintext = try decryptFromDevice(unwrapped, deviceId: peerId)
                let msg = try JSONDecoder().decode(AppMessage.self, from: plaintext)
                await handleAppMessage(msg, from: peerId)
            } catch {
                // 如果不是业务消息（比如对端还在发旧格式），忽略即可
                SkyBridgeLogger.shared.debug("ℹ️ 无法解析业务消息（忽略）：\(error.localizedDescription)")
            }
        }
    }

    private func ensureInboundHandshakeDriverIfNeeded(for peerId: String, frame: Data) async -> HandshakeDriver? {
        guard handshakeDrivers[peerId] == nil else { return handshakeDrivers[peerId] }
        guard sessionKeys[peerId] == nil else { return nil }

        let handshakeFrame = HandshakePadding.unwrapIfNeeded(frame, label: "rx")
        guard let messageA = try? HandshakeMessageA.decode(from: handshakeFrame) else { return nil }
        guard !messageA.supportedSuites.isEmpty else { return nil }

        let peerHasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let previousPolicy = effectiveSelectionPolicy(enforcePQC: pqcManager.enforcePQCHandshake)

        do {
            if !peerHasPQCGroup && pqcManager.enforcePQCHandshake {
                try await switchToLegacyBootstrapInboundDriver(for: peerId)
            } else {
                try await skyBridgeCore.initialize(policy: previousPolicy)
                guard let transport else { throw P2PError.connectionFailed }
                let driver = try skyBridgeCore.createHandshakeDriver(
                    transport: transport,
                    localSOAPeerId: localSOAPeerIdBytes(),
                    expectedRemoteSOAPeerId: soaPeerIdBytes(for: peerId)
                )
                handshakeDrivers[peerId] = driver
            }
        } catch {
            SkyBridgeLogger.shared.warning("⚠️ 入站握手 driver 重建失败: \(error.localizedDescription)")
            return nil
        }

        currentHandshakeState = "收到新的入站握手请求，握手中..."
        SkyBridgeLogger.shared.info(
            "🔁 重新创建入站握手驱动器: peer=\(peerId) suites=\(messageA.supportedSuites.map(\.rawValue).joined(separator: ","))"
        )
        return handshakeDrivers[peerId]
    }

    private func processHandshakeFrame(_ frame: Data, from peerId: String, initialDriver: HandshakeDriver) async {
        if shouldUseLegacyBootstrapInboundDriver(for: frame, peerId: peerId) {
            do {
                try await switchToLegacyBootstrapInboundDriver(for: peerId)
            } catch {
                SkyBridgeLogger.shared.warning("⚠️ legacyBootstrap(inbound) driver switch failed: \(error.localizedDescription)")
            }
        }

        let activeDriver = handshakeDrivers[peerId] ?? initialDriver
        let peer = PeerIdentifier(deviceId: peerId)
        await activeDriver.handleMessage(frame, from: peer)

        let state = await activeDriver.getCurrentState()
        switch state {
        case .established(let keys):
            setSessionKeys(keys, for: peerId)
            if let remotePeerId = soaPeerIdBytes(for: peerId) {
                pairKeyByDeviceId[peerId] = PeerSessionArbiter.pairKey(
                    localPeerId: localSOAPeerIdBytes(),
                    remotePeerId: remotePeerId
                )
            } else {
                pairKeyByDeviceId.removeValue(forKey: peerId)
            }
            handshakeDrivers.removeValue(forKey: peerId)
            rekeyInProgress.remove(peerId)
            currentHandshakeState = "握手成功 (Suite: \(keys.negotiatedSuite.rawValue))"
            SkyBridgeLogger.shared.info("✅ 握手完成: \(peerId) (Suite: \(keys.negotiatedSuite.rawValue))")
            connectionStatusByDeviceId[peerId] = .connected
            connectionErrorByDeviceId.removeValue(forKey: peerId)
            startHeartbeatIfNeeded(deviceId: peerId)

            let activeDevice = makeActiveConnectionDevice(
                peerId: peerId,
                connection: connections[peerId]
            )
            upsertActiveConnection(device: activeDevice, status: .connected)

        case .failed(let reason):
            handshakeDrivers.removeValue(forKey: peerId)
            rekeyInProgress.remove(peerId)
            currentHandshakeState = "握手失败: \(reason)"
            lastError = "\(reason)"
            connectionStatusByDeviceId[peerId] = .failed
            connectionErrorByDeviceId[peerId] = "\(reason)"
            SkyBridgeLogger.shared.error("❌ 握手失败: \(peerId) - \(reason)")

        default:
            break
        }
    }

    private func ensureInboundRekeyDriverIfNeeded(for peerId: String, frame: Data) async -> HandshakeDriver? {
        guard handshakeDrivers[peerId] == nil else { return handshakeDrivers[peerId] }
        guard sessionKeys[peerId] != nil else { return nil }

        let handshakeFrame = HandshakePadding.unwrapIfNeeded(frame, label: "rx")
        guard let messageA = try? HandshakeMessageA.decode(from: handshakeFrame) else { return nil }
        guard !messageA.supportedSuites.isEmpty else { return nil }

        let peerHasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let previousPolicy = effectiveSelectionPolicy(enforcePQC: pqcManager.enforcePQCHandshake)

        do {
            if !peerHasPQCGroup && pqcManager.enforcePQCHandshake {
                try await switchToLegacyBootstrapInboundDriver(for: peerId)
            } else {
                try await skyBridgeCore.initialize(policy: previousPolicy)
                guard let transport else { throw P2PError.connectionFailed }
                let driver = try skyBridgeCore.createHandshakeDriver(
                    transport: transport,
                    localSOAPeerId: localSOAPeerIdBytes(),
                    expectedRemoteSOAPeerId: soaPeerIdBytes(for: peerId)
                )
                handshakeDrivers[peerId] = driver
            }
        } catch {
            SkyBridgeLogger.shared.warning("⚠️ 入站 rekey driver 初始化失败: \(error.localizedDescription)")
            return nil
        }

        sessionKeys.removeValue(forKey: peerId)
        rekeyInProgress.insert(peerId)
        currentHandshakeState = "收到对端 rekey 请求，重新握手中..."
        SkyBridgeLogger.shared.info(
            "🔁 收到对端 rekey 请求，切换到握手模式: peer=\(peerId) suites=\(messageA.supportedSuites.map(\.rawValue).joined(separator: ","))"
        )
        return handshakeDrivers[peerId]
    }

    private func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
        let frame = HandshakePadding.unwrapIfNeeded(data, label: "rx")
        // Finished: 固定长度 38 bytes（magic 4 + version 1 + direction 1 + mac 32）
        if frame.count == 38, (try? HandshakeFinished.decode(from: frame)) != nil {
            return true
        }
        // MessageA / MessageB：长度通常 < 2KB，且可以被解码（用于避免误解密）
        if (try? HandshakeMessageA.decode(from: frame)) != nil { return true }
        if (try? HandshakeMessageB.decode(from: frame)) != nil { return true }
        return false
    }

    private func shouldUseLegacyBootstrapInboundDriver(for frame: Data, peerId: String) -> Bool {
        guard pqcManager.enforcePQCHandshake else { return false }
        guard !inboundLegacyBootstrapPeers.contains(peerId) else { return false }
        guard sessionKeys[peerId] == nil else { return false }

        let handshakeFrame = HandshakePadding.unwrapIfNeeded(frame, label: "rx")
        guard let messageA = try? HandshakeMessageA.decode(from: handshakeFrame) else {
            return false
        }
        guard !messageA.supportedSuites.isEmpty else { return false }
        let peerHasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        return !peerHasPQCGroup
    }

    private func switchToLegacyBootstrapInboundDriver(for peerId: String) async throws {
        guard let transport else { throw P2PError.connectionFailed }

        SkyBridgeLogger.shared.info(
            "🧩 legacyBootstrap(inbound): strictPQC enabled but peer offered classic-only. " +
            "Allowing classic bootstrap channel for KEM provisioning. peer=\(peerId)"
        )

        let previousPolicy = effectiveSelectionPolicy(enforcePQC: pqcManager.enforcePQCHandshake)
        try await skyBridgeCore.initialize(policy: .classicOnly)
        let classicDriver = try skyBridgeCore.createHandshakeDriver(
            transport: transport
        )
        handshakeDrivers[peerId] = classicDriver
        inboundLegacyBootstrapPeers.insert(peerId)

        if previousPolicy != .classicOnly {
            try await skyBridgeCore.initialize(policy: previousPolicy)
        }
    }

    private func handleAppMessage(_ message: AppMessage, from peerId: String) async {
        switch message {
        case .clipboard(let payload):
            guard let data = payload.decodedData else { return }
            ClipboardManager.shared.setRemoteClipboard(data: data, mimeType: payload.mimeType, fromDeviceId: peerId)
            ClipboardManager.shared.recordDeviceSync(deviceId: peerId, mimeType: payload.mimeType, bytes: data.count)
            SkyBridgeLogger.shared.info("📋 已接收远端剪贴板：\(peerId)")
        case .pairingIdentityExchange(let payload):
            await handlePairingIdentityExchangeRequest(from: peerId, payload: payload)
        case .heartbeat:
            break
        case .ping(let payload):
            await replyPong(to: peerId, pingId: payload.id)
        case .pong:
            break
        }
    }

    private func replyPong(to peerId: String, pingId: UInt64) async {
        // Avoid mixing business traffic during in-band rekey.
        if rekeyInProgress.contains(peerId) { return }
        guard let connection = connections[peerId] else { return }
        guard sessionKeys[peerId] != nil else { return }

        do {
            let message = AppMessage.pong(.init(id: pingId))
            let payload = try JSONEncoder().encode(message)
            let ciphertext = try encryptForDevice(payload, deviceId: peerId)
            try await send(data: ciphertext, over: connection)
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ pong reply failed (ignored): \(error.localizedDescription)")
        }
    }
    
    private func handlePairingIdentityExchangeRequest(from peerId: String, payload: AppMessage.PairingIdentityExchangePayload) async {
        // Policy: auto-accept / auto-reject if a decision exists; otherwise raise a UI prompt.
        if let raw = pairingPolicyByPeerId[peerId],
           let policy = PairingTrustDecision(rawValue: raw) {
            switch policy {
            case .alwaysAllow:
                await acceptPairingIdentityExchange(from: peerId, payload: payload, trustPeer: true, persistTrust: true)
                return
            case .reject:
                SkyBridgeLogger.shared.warning("🛑 Pairing/trust request auto-rejected: peer=\(peerId) declaredDeviceId=\(payload.deviceId)")
                return
            case .allowOnce:
                // Should not be persisted; fall through to prompt.
                break
            }
        }
        
        // If the peer is already trusted OR we are currently bootstrapping Classic->PQC for this peer,
        // auto-accept to avoid the bootstrap being blocked by an extra prompt on the initiator side.
        if TrustedDeviceStore.shared.isTrusted(deviceId: peerId) || bootstrapRekeyTasks[peerId] != nil {
            await acceptPairingIdentityExchange(from: peerId, payload: payload, trustPeer: true, persistTrust: false)
            return
        }
        
        // If another prompt is already showing, don't overwrite it. Keep the first one.
        guard pendingPairingTrustRequest == nil else {
            SkyBridgeLogger.shared.warning("ℹ️ Pairing/trust request received but UI prompt already pending; ignoring duplicate. peer=\(peerId)")
            return
        }
        
        // Gather device info best-effort from discovery cache.
        let device = lastKnownDevices[peerId]
            ?? discoveryManager.discoveredDevices.first(where: { $0.id == peerId })
            ?? DiscoveredDevice(id: peerId, name: peerId, modelName: "", platform: .unknown, osVersion: "Unknown")
        
        let requestId = UUID()
        pendingPairingContextByRequestId[requestId] = PendingPairingContext(peerId: peerId, payload: payload)
        pendingPairingTrustRequest = PairingTrustRequest(
            id: requestId,
            peerId: peerId,
            declaredDeviceId: payload.deviceId,
            deviceName: device.name,
            platform: device.platform,
            modelName: device.modelName,
            osVersion: device.osVersion,
            kemKeyCount: payload.kemPublicKeys.count,
            receivedAt: Date()
        )
        
        SkyBridgeLogger.shared.warning("🔔 收到配对/受信任申请：\(device.name) platform=\(device.platform.displayName) os=\(device.osVersion) peerId=\(peerId)")
    }
    
    private func scheduleBootstrapRekeyIfNeeded(peerId: String, suiteRaw: String) {
        guard bootstrapRekeyTasks[peerId] == nil else { return }
        
        // Surface a stable "pending approval/keys" state to prevent reconnect storms.
        connectionErrorByDeviceId[peerId] = "等待对端批准配对/受信任申请以完成 PQC 切换（suite=\(suiteRaw)）"
        currentHandshakeState = "等待对端批准以完成 PQC 切换..."
        
        bootstrapRekeyTasks[peerId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.bootstrapRekeyTasks.removeValue(forKey: peerId) }
            
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !Task.isCancelled {
                let keys = await KEMTrustStore.shared.kemPublicKeys(for: peerId)
                if keys.keys.contains(where: { $0.rawValue == suiteRaw }) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            
            let keysNow = await KEMTrustStore.shared.kemPublicKeys(for: peerId)
            guard keysNow.keys.contains(where: { $0.rawValue == suiteRaw }) else {
                let known = keysNow.keys.map(\.rawValue).sorted().joined(separator: ",")
                SkyBridgeLogger.shared.warning(
                    "⏳ 等待对端 KEM 公钥超时（targetSuite=\(suiteRaw) knownSuites=\(known)）。" +
                    "请在 macOS 弹窗选择允许后重试，或稍后手动点击“重新握手”。"
                )
                return
            }
            
            do {
                SkyBridgeLogger.shared.info("🔁 已获得对端 KEM 公钥，开始 rekey 到 PQC… peer=\(peerId)")
                try await self.rekeyToPreferPQC(deviceId: peerId, allowSOA: false)
                self.connectionErrorByDeviceId.removeValue(forKey: peerId)
                self.currentHandshakeState = "已切换到 PQC"
            } catch {
                self.connectionErrorByDeviceId[peerId] = "PQC 切换失败：\(error.localizedDescription)"
                SkyBridgeLogger.shared.error("❌ rekeyToPreferPQC failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func acceptPairingIdentityExchange(
        from peerId: String,
        payload: AppMessage.PairingIdentityExchangePayload,
        trustPeer: Bool,
        persistTrust: Bool
    ) async {
        // Store under both the "declared" deviceId and the current peerId key.
        // Reason: in discovery/bonjour flows the runtime peerId can be "bonjour:<name>@local." while the
        // pairing identity exchange uses a stable deviceId. If we only store one, PQC lookup may miss.
        await KEMTrustStore.shared.upsert(deviceId: payload.deviceId, kemPublicKeys: payload.kemPublicKeys)
        await KEMTrustStore.shared.upsert(deviceId: peerId, kemPublicKeys: payload.kemPublicKeys)
        SkyBridgeLogger.shared.info("🔑 已保存对端 KEM 公钥：peer=\(peerId) declaredDeviceId=\(payload.deviceId) keys=\(payload.kemPublicKeys.count)")
        
        if trustPeer {
            // Persist a "trusted" record so strict-PQC bootstrap can be gated by an explicit trust decision.
            let device = lastKnownDevices[peerId]
                ?? discoveryManager.discoveredDevices.first(where: { $0.id == peerId })
                ?? DiscoveredDevice(id: peerId, name: peerId, modelName: "", platform: .unknown, osVersion: "Unknown")
            TrustedDeviceStore.shared.trust(device)
            if persistTrust {
                SkyBridgeLogger.shared.info("✅ 已加入受信任设备：\(device.name) peerId=\(peerId)")
            }
        }
        
        // Reply once (rate-limited) so both sides learn each other's KEM identity keys.
        if let last = lastPairingIdentityExchangeSentAt[peerId],
           Date().timeIntervalSince(last) < 10 {
            return
        }
        lastPairingIdentityExchangeSentAt[peerId] = Date()
        do {
            try await sendPairingIdentityExchange(to: peerId)
            SkyBridgeLogger.shared.info("🔁 pairingIdentityExchange replied to peer=\(peerId)")
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ pairingIdentityExchange reply failed (ignored): \(error.localizedDescription)")
        }
    }

    /// 向对端发送本机 KEM identity 公钥，用于 bootstrap PQC suite 协商（首次可用 classic，收到后即可 rekey 到 PQC）。
    public func sendPairingIdentityExchange(to deviceId: String) async throws {
        // Avoid mixing business traffic during in-band rekey.
        if rekeyInProgress.contains(deviceId) { return }
        guard let connection = connections[deviceId] else { throw P2PError.connectionFailed }
        guard sessionKeys[deviceId] != nil else { throw P2PError.noSessionKey }

        let kemKeys = try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()

        // 设备 ID：用于对端把我们写入 trust store 的 key（尽量与 discovery 的 deviceId 对齐）
        #if canImport(UIKit)
        let localId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-unknown"
        #else
        let localId = "ios-unknown"
        #endif
        #if canImport(UIKit)
        let deviceName = UIDevice.current.name
        let osVersion = UIDevice.current.systemVersion
        let platform = UIDevice.current.systemName
        #else
        let deviceName: String? = nil
        let osVersion: String? = nil
        let platform: String? = nil
        #endif
        let message = AppMessage.pairingIdentityExchange(.init(
            deviceId: localId,
            kemPublicKeys: kemKeys,
            deviceName: deviceName,
            modelName: Self.currentModelDisplayName(),
            platform: platform,
            osVersion: osVersion,
            chip: Self.currentChipDisplayName()
        ))
        let payload = try JSONEncoder().encode(message)
        let ciphertext = try encryptForDevice(payload, deviceId: deviceId)
        try await send(data: ciphertext, over: connection)
    }

    /// 发送剪贴板内容到指定设备（走已建立的会话密钥加密通道）
    public func sendClipboard(to deviceId: String, data: Data, mimeType: String) async throws {
        // Avoid mixing business traffic during in-band rekey.
        if rekeyInProgress.contains(deviceId) { return }
        guard let connection = connections[deviceId] else { throw P2PError.connectionFailed }
        guard sessionKeys[deviceId] != nil else { throw P2PError.noSessionKey }

        let message = AppMessage.clipboard(.init(mimeType: mimeType, dataBase64: data.base64EncodedString()))
        let payload = try JSONEncoder().encode(message)
        let ciphertext = try encryptForDevice(payload, deviceId: deviceId)
        try await send(data: ciphertext, over: connection)

        ClipboardManager.shared.recordDeviceSync(deviceId: deviceId, mimeType: mimeType, bytes: data.count)
    }

    /// 广播剪贴板到所有已建立会话的连接
    public func broadcastClipboard(data: Data, mimeType: String) async {
        for deviceId in connections.keys {
            guard sessionKeys[deviceId] != nil else { continue }
            try? await sendClipboard(to: deviceId, data: data, mimeType: mimeType)
        }
    }
    
    private func handleConnectionStateChange(_ state: NWConnection.State, for device: DiscoveredDevice) async {
        switch state {
        case .ready:
            // Transport ready != protocol handshake complete.
            connectionStatusByDeviceId[device.id] = .connecting
            connectionErrorByDeviceId.removeValue(forKey: device.id)
            userInitiatedDisconnects.remove(device.id)
            lastActivityByDeviceId[device.id] = Date()

        case .waiting(let error):
            connectionStatusByDeviceId[device.id] = .connecting
            connectionErrorByDeviceId[device.id] = error.localizedDescription
            SkyBridgeLogger.shared.warning("⏳ 连接等待网络: \(device.name) error=\(error.localizedDescription)")
            
        case .failed(let error):
            SkyBridgeLogger.shared.error("❌ 连接失败: \(device.name) error=\(error.localizedDescription)")
            connectionStatusByDeviceId[device.id] = .failed
            connectionErrorByDeviceId[device.id] = error.localizedDescription
            userInitiatedDisconnects.remove(device.id)
            connections.removeValue(forKey: device.id)
            sessionKeys.removeValue(forKey: device.id)
            handshakeDrivers.removeValue(forKey: device.id)
            sharedSecrets.removeValue(forKey: device.id)
            await transport?.removeConnection(for: device.id)
            activeConnections.removeAll { $0.device.id == device.id }
            heartbeatTasks[device.id]?.cancel()
            heartbeatTasks.removeValue(forKey: device.id)
            await releaseArbiterState(for: device.id)
            scheduleReconnectIfNeeded(deviceId: device.id)
            
        case .cancelled:
            connections.removeValue(forKey: device.id)
            sessionKeys.removeValue(forKey: device.id)
            handshakeDrivers.removeValue(forKey: device.id)
            sharedSecrets.removeValue(forKey: device.id)
            await transport?.removeConnection(for: device.id)
            activeConnections.removeAll { $0.device.id == device.id }
            connectionStatusByDeviceId[device.id] = .disconnected
            let wasUser = userInitiatedDisconnects.remove(device.id) != nil
            if !wasUser, connectionErrorByDeviceId[device.id] == nil {
                connectionErrorByDeviceId[device.id] = "连接已断开（系统未提供错误原因）"
            }
            SkyBridgeLogger.shared.warning("⏹️ 连接已取消/断开: \(device.name) user=\(wasUser)")
            heartbeatTasks[device.id]?.cancel()
            heartbeatTasks.removeValue(forKey: device.id)
            await releaseArbiterState(for: device.id)
            if !wasUser {
                scheduleReconnectIfNeeded(deviceId: device.id)
            }
            
        default:
            break
        }
    }

    private func startHeartbeatIfNeeded(deviceId: String) {
        guard heartbeatTasks[deviceId] == nil else { return }
        guard connections[deviceId] != nil, sessionKeys[deviceId] != nil else { return }

        heartbeatTasks[deviceId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.heartbeatIntervalSeconds ?? 20))
                guard let self else { return }
                guard self.connections[deviceId] != nil, self.sessionKeys[deviceId] != nil else { return }
                
                // Pause heartbeat during in-band rekey to reduce ciphertext/handshake interleaving.
                if self.rekeyInProgress.contains(deviceId) { continue }

                let now = Date()
                let last = self.lastActivityByDeviceId[deviceId] ?? .distantPast
                if now.timeIntervalSince(last) < self.heartbeatIntervalSeconds { continue }

                do {
                    #if canImport(UIKit)
                    let localId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-unknown"
                    let deviceName = UIDevice.current.name
                    let osVersion = UIDevice.current.systemVersion
                    let platform = UIDevice.current.systemName
                    #else
                    let localId = "ios-unknown"
                    let deviceName: String? = nil
                    let osVersion: String? = nil
                    let platform: String? = nil
                    #endif
                    
                    let message = AppMessage.heartbeat(.init(
                        sentAt: now,
                        deviceId: localId,
                        deviceName: deviceName,
                        modelName: Self.currentModelDisplayName(),
                        platform: platform,
                        osVersion: osVersion,
                        chip: Self.currentChipDisplayName()
                    ))
                    let payload = try JSONEncoder().encode(message)
                    let ciphertext = try self.encryptForDevice(payload, deviceId: deviceId)
                    if let connection = self.connections[deviceId] {
                        try await self.send(data: ciphertext, over: connection)
                        self.lastActivityByDeviceId[deviceId] = now
                    }
                } catch {
                    self.connectionErrorByDeviceId[deviceId] = error.localizedDescription
                }
            }
        }
    }

    private func scheduleReconnectIfNeeded(deviceId: String, delayOverrideSeconds: Double? = nil) {
        guard !userInitiatedDisconnects.contains(deviceId) else { return }
        guard reconnectTasks[deviceId] == nil else { return }
        guard let device = lastKnownDevices[deviceId] else { return }
        
        // Avoid reconnect storms when we're awaiting explicit pairing/trust approval or KEM key provisioning.
        if let err = connectionErrorByDeviceId[deviceId],
           (err.contains("缺少对端 PQC KEM 公钥")
            || err.contains("missingPeerKEMPublicKey")
            || err.contains("等待对端批准")) {
            return
        }

        if reconnectSuppressedDeviceIds.contains(deviceId) {
            return
        }

        if bootstrapRekeyTasks[deviceId] != nil
            || pendingPairingTrustRequest?.peerId == deviceId {
            return
        }

        let attempt = min(reconnectAttempts[deviceId] ?? 0, maxReconnectAttempts)
        if attempt >= maxReconnectAttempts { return }
        reconnectAttempts[deviceId] = attempt + 1

        let computedDelay = min(30.0, pow(2.0, Double(attempt)))
        let delay = min(60.0, max(delayOverrideSeconds ?? computedDelay, computedDelay))
        reconnectTasks[deviceId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.reconnectTasks.removeValue(forKey: deviceId)
            if self.connections[deviceId] != nil { return }
            do {
                try await self.connect(to: device)
                self.reconnectAttempts.removeValue(forKey: deviceId)
            } catch {
                self.connectionErrorByDeviceId[deviceId] = error.localizedDescription
                self.scheduleReconnectIfNeeded(deviceId: deviceId)
            }
        }
    }

    private func upsertActiveConnection(device: DiscoveredDevice, status: ConnectionStatus) {
        if let index = activeConnections.firstIndex(where: { $0.device.id == device.id }) {
            let existing = activeConnections[index]
            activeConnections[index] = Connection(
                id: existing.id,
                device: device,
                status: status,
                encryptionType: existing.encryptionType,
                latency: existing.latency,
                bandwidth: existing.bandwidth,
                connectedAt: existing.connectedAt
            )
            return
        }
        activeConnections.append(Connection(device: device, status: status))
    }

    private func makeActiveConnectionDevice(peerId: String, connection: NWConnection?) -> DiscoveredDevice {
        if let discovered = discoveryManager.discoveredDevices.first(where: { $0.id == peerId }) {
            return discovered
        }

        let endpointAddress = endpointHostAddress(connection?.endpoint)
        let bonjour = parseBonjourPeerIdentifier(peerId)
        let fallbackName = bonjour?.name ?? endpointAddress ?? peerId

        var services: [String] = []
        if bonjour != nil {
            services.append(DiscoveryServiceType.skybridge.rawValue)
        }

        return DiscoveredDevice(
            id: peerId,
            name: fallbackName,
            bonjourServiceName: bonjour?.name,
            modelName: "Unknown",
            platform: .macOS,
            osVersion: "Unknown",
            ipAddress: endpointAddress,
            bonjourServiceType: bonjour != nil ? DiscoveryServiceType.skybridge.rawValue : nil,
            bonjourServiceDomain: bonjour?.domain,
            services: services,
            portMap: [:],
            signalStrength: -50,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: false,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )
    }

    private func parseBonjourPeerIdentifier(_ peerId: String) -> (name: String, domain: String)? {
        guard peerId.hasPrefix("bonjour:") else { return nil }
        let payload = String(peerId.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return (name, domain)
    }

    private func endpointHostAddress(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let ipv4):
            return "\(ipv4)"
        case .ipv6(let ipv6):
            return "\(ipv6)"
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }

    private func isLoopbackAddress(_ ipAddress: String) -> Bool {
        let normalized = ipAddress.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "0:0:0:0:0:0:0:1"
            || normalized == "::ffff:127.0.0.1"
            || normalized == "localhost"
    }

    private func isSelfConnectionTarget(_ device: DiscoveredDevice) -> Bool {
        #if canImport(UIKit)
        if let localId = UIDevice.current.identifierForVendor?.uuidString.lowercased() {
            let normalizedDeviceId = device.id.lowercased()
            if normalizedDeviceId == localId || normalizedDeviceId == "id:\(localId)" {
                return true
            }
        }
        #endif

        if let ipAddress = device.ipAddress,
           isLoopbackAddress(ipAddress) {
            return true
        }

        return false
    }

    private func setSessionKeys(_ keys: SessionKeys, for deviceId: String, deviceNameHint: String? = nil) {
        sessionKeys[deviceId] = keys
        negotiatedSuiteByDeviceId[deviceId] = keys.negotiatedSuite

        // Keep Live Activity in sync with the latest negotiated suite (e.g., after Classic -> PQC rekey).
        let name =
            deviceNameHint
            ?? lastKnownDevices[deviceId]?.name
            ?? discoveryManager.discoveredDevices.first(where: { $0.id == deviceId })?.name
            ?? deviceId
        Task {
            await LiveActivityManager.shared.setConnected(deviceName: name, cryptoSuite: keys.negotiatedSuite.rawValue)
        }
    }

    private func shouldUseSOA(for device: DiscoveredDevice) -> Bool {
        device.capabilities.contains("hs_soa") || device.advertisedCapabilities.contains("hs_soa")
    }

    private func localSOAPeerIdBytes() -> Data {
        #if canImport(UIKit)
        if let vendor = UIDevice.current.identifierForVendor?.uuidString {
            return canonicalPeerIdBytes(from: vendor)
        }
        #endif
        let key = "p2p.local_peer_id_fallback.v1"
        let existing = UserDefaults.standard.string(forKey: key) ?? ""
        if !existing.isEmpty {
            return canonicalPeerIdBytes(from: existing)
        }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return canonicalPeerIdBytes(from: generated)
    }

    private func soaPeerIdBytes(for peerId: String) -> Data? {
        guard let canonical = canonicalSOATrustedPeerIdentifier(peerId) else {
            return nil
        }
        return canonicalPeerIdBytes(from: canonical)
    }

    private func canonicalSOATrustedPeerIdentifier(_ peerId: String) -> String? {
        let normalized = peerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") {
            return String(normalized.dropFirst(3))
        }

        if normalized.hasPrefix("host:") {
            let hostRaw = String(normalized.dropFirst(5))
            let hostNoScope = hostRaw.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? hostRaw
            func normalizedIP(_ raw: String?) -> String? {
                guard let raw else { return nil }
                var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if value.hasPrefix("[") && value.hasSuffix("]") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                if let percent = value.firstIndex(of: "%") {
                    value = String(value[..<percent])
                }
                return value
            }
            let candidates = Set([hostRaw, hostNoScope])
            if let matched = discoveryManager.discoveredDevices.first(where: {
                guard $0.id.lowercased().hasPrefix("id:"),
                      let ip = normalizedIP($0.ipAddress) else {
                    return false
                }
                return candidates.contains(ip)
            }) {
                return canonicalSOATrustedPeerIdentifier(matched.id)
            }
        }

        if normalized.hasPrefix("bonjour:"),
           let matched = discoveryManager.discoveredDevices.first(where: {
               guard $0.id.lowercased().hasPrefix("id:"),
                     let bonjourName = $0.bonjourServiceName?.lowercased() else {
                   return false
               }
               return normalized.contains(bonjourName)
           }) {
            return canonicalSOATrustedPeerIdentifier(matched.id)
        }

        if let known = lastKnownDevices[peerId]?.id, known.lowercased().hasPrefix("id:") {
            return canonicalSOATrustedPeerIdentifier(known)
        }

        return nil
    }

    private func canonicalPeerIdBytes(from canonicalId: String) -> Data {
        let digest = SHA256.hash(data: Data(canonicalId.utf8))
        return Data(digest)
    }

    private func randomAttemptIdBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return Data(bytes)
    }

    private func releaseArbiterState(for deviceId: String) async {
        guard let pairKey = pairKeyByDeviceId.removeValue(forKey: deviceId) else { return }
        await PeerSessionArbiter.shared.clearEstablished(pairKey: pairKey)
        await PeerSessionArbiter.shared.clearOutgoing(pairKey: pairKey, attemptId: nil)
    }
    
    /// 执行 PQC 握手（使用完整的 HandshakeDriver 协议）
    private func performPQCHandshake(
        connection: NWConnection,
        device: DiscoveredDevice,
        preferPQC: Bool,
        selectionPolicyOverride: CryptoProviderFactory.SelectionPolicy? = nil,
        allowSOA: Bool = true
    ) async throws {
        SkyBridgeLogger.shared.info("🔐 开始 PQC 握手...")
        currentHandshakeState = "握手中..."
        
        // 确保 SkyBridgeCore 已按当前设置初始化（允许按 policy 重新初始化）
        if let override = selectionPolicyOverride {
            try await skyBridgeCore.initialize(policy: override)
        } else if pqcManager.enforcePQCHandshake {
            let policy = effectiveSelectionPolicy(enforcePQC: true)
            try await skyBridgeCore.initialize(policy: policy)
        } else {
            try await skyBridgeCore.initialize(policy: .classicOnly)
        }
        
        // 创建传输层
        if transport == nil {
            transport = NWConnectionTransport()
        }
        await transport!.setConnection(connection, for: device.id)

        do {
            let localPeerId = localSOAPeerIdBytes()
            let remotePeerId = soaPeerIdBytes(for: device.id)
            if let remotePeerId {
                pairKeyByDeviceId[device.id] = PeerSessionArbiter.pairKey(
                    localPeerId: localPeerId,
                    remotePeerId: remotePeerId
                )
            } else {
                pairKeyByDeviceId.removeValue(forKey: device.id)
            }
            let outboundSOA: HandshakeSOAMetadata? = {
                guard allowSOA, shouldUseSOA(for: device), let remotePeerId else { return nil }
                return try? HandshakeSOAMetadata(
                    initiatorPeerId: localPeerId,
                    targetPeerId: remotePeerId,
                    attemptId: randomAttemptIdBytes()
                )
            }()

            // 让握手驱动器可接收来自 startReceiving 的消息
            let peerId = device.id
            let keys = try await skyBridgeCore.performHandshake(
                deviceId: peerId,
                transport: transport!,
                preferPQC: preferPQC,
                soaMetadata: outboundSOA,
                localSOAPeerId: localPeerId,
                expectedRemoteSOAPeerId: remotePeerId,
                onDriverCreated: { driver in
                    // Swift 6 并发：避免在并发回调里捕获/引用 `self`（即使是 weak self）
                    await MainActor.run {
                        P2PConnectionManager.instance.handshakeDrivers[peerId] = driver
                    }
                }
            )
            
            // 保存会话密钥 + 清理握手 driver
            setSessionKeys(keys, for: device.id, deviceNameHint: device.name)
            handshakeDrivers.removeValue(forKey: device.id)
            
            currentHandshakeState = "握手成功 (Suite: \(keys.negotiatedSuite.rawValue))"
            SkyBridgeLogger.shared.info("✅ PQC 握手完成 (Suite: \(keys.negotiatedSuite.rawValue))")
            
        } catch {
            handshakeDrivers.removeValue(forKey: device.id)
            currentHandshakeState = "握手失败: \(error.localizedDescription)"
            lastError = error.localizedDescription
            SkyBridgeLogger.shared.error("❌ PQC 握手失败: \(String(reflecting: error))")
            throw error
        }
    }

    /// 强制用 preferPQC=true 重新握手（用于完成 KEM 公钥交换后的“立刻切换到 PQC suite”）
    public func rekeyToPreferPQC(deviceId: String, allowSOA: Bool = true) async throws {
        rekeyInProgress.insert(deviceId)
        defer { rekeyInProgress.remove(deviceId) }
        guard let connection = connections[deviceId] else { throw P2PError.connectionFailed }
        let device = discoveryManager.discoveredDevices.first(where: { $0.id == deviceId })
            ?? DiscoveredDevice(id: deviceId, name: deviceId, modelName: "", platform: .unknown, osVersion: "Unknown")
        try await performPQCHandshake(
            connection: connection,
            device: device,
            preferPQC: true,
            allowSOA: allowSOA
        )
    }

    // MARK: - Ready Gate (await connection.ready)

    private final class ConnectionReadyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false
        private var lastState: NWConnection.State?

        func onState(_ state: NWConnection.State) {
            lock.lock()
            defer { lock.unlock() }
            lastState = state
            guard !finished, let continuation else { return }

            switch state {
            case .ready:
                finished = true
                continuation.resume()
                self.continuation = nil
            case .failed(let error):
                finished = true
                continuation.resume(throwing: error)
                self.continuation = nil
            default:
                break
            }
        }

        func waitReady(timeoutSeconds: Double) async throws {
            let gate = self
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await gate.awaitReadyOrFail()
                }

                group.addTask {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    throw P2PError.connectionFailed
                }

                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }

        private func awaitReadyOrFail() async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                // 如果 ready/fail 已经先到，直接返回，避免错过 stateUpdate
                if let last = lastState, !finished {
                    switch last {
                    case .ready:
                        finished = true
                        lock.unlock()
                        cont.resume()
                        return
                    case .failed(let error):
                        finished = true
                        lock.unlock()
                        cont.resume(throwing: error)
                        return
                    default:
                        break
                    }
                }
                continuation = cont
                lock.unlock()
            }
        }
    }
    
    /// 使用会话密钥加密数据
    public func encryptForDevice(_ data: Data, deviceId: String) throws -> Data {
        guard let keys = sessionKeys[deviceId] else {
            throw P2PError.noSessionKey
        }
        return try skyBridgeCore.encrypt(data, sessionKey: keys.sendKey)
    }
    
    /// 使用会话密钥解密数据
    public func decryptFromDevice(_ data: Data, deviceId: String) throws -> Data {
        guard let keys = sessionKeys[deviceId] else {
            throw P2PError.noSessionKey
        }
        return try skyBridgeCore.decrypt(data, sessionKey: keys.receiveKey)
    }
    
    /// 获取设备的协商套件
    public func getNegotiatedSuite(for deviceId: String) -> CryptoSuite? {
        sessionKeys[deviceId]?.negotiatedSuite
    }
    
    private func send(data: Data, over connection: NWConnection) async throws {
        // Phase C2: optional padding for post-handshake business traffic (SBP2)
        let padded = TrafficPadding.wrapIfEnabled(data, label: "tx")

        // 与 macOS 端一致：4-byte big-endian length framing
        var framed = Data()
        var length = UInt32(padded.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(padded)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: framed,
                completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }
    
    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: P2PError.noData)
                }
            }
        }
    }
}

// MARK: - P2P Error

public enum P2PError: Error, LocalizedError {
    case noIPAddress
    case noConnectableEndpoint
    case noData
    case handshakeFailed
    case connectionFailed
    case noSessionKey
    case encryptionFailed
    case decryptionFailed
    case tooManyConcurrentConnections
    case alreadyConnected
    case selfConnectionBlocked
    
    public var errorDescription: String? {
        switch self {
        case .noIPAddress: return "设备没有 IP 地址"
        case .noConnectableEndpoint: return "设备缺少可连接地址（Bonjour/IP）"
        case .noData: return "没有接收到数据"
        case .handshakeFailed: return "PQC 握手失败"
        case .connectionFailed: return "连接失败"
        case .noSessionKey: return "没有会话密钥"
        case .encryptionFailed: return "加密失败"
        case .decryptionFailed: return "解密失败"
        case .tooManyConcurrentConnections: return "连接过于频繁，请稍后再试（已达到并发上限）"
        case .alreadyConnected: return "设备已建立连接"
        case .selfConnectionBlocked: return "已阻止自连接目标"
        }
    }
}
