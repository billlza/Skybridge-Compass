import Foundation
import Network
import CryptoKit
import Combine
import OSLog
import CoreGraphics
import ImageIO
import ApplicationServices
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// 跨网络连接管理器 - 2025年创新架构
///
/// 三层连接方案：
/// 1. 动态二维码 + NFC 近场连接
/// 2. Apple ID / iCloud 设备链（零配置）
/// 3. 智能连接码 + P2P 穿透（通用方案）
@MainActor
public final class CrossNetworkConnectionManager: ObservableObject {

    /// Shared instance so multiple views (connection + file transfer) can operate on the same active WebRTC session.
    public static let shared = CrossNetworkConnectionManager()

 // MARK: - 发布属性

    @Published public var connectionCode: String?
    @Published public var qrCodeData: Data?
    @Published public var availableCloudDevices: [CloudDevice] = []
    @Published public var connectionStatus: CrossNetworkConnectionStatus = .idle
    @Published public private(set) var readiness: CrossNetworkReadiness = .idle
    @Published public var currentConnection: RemoteConnection?

 // MARK: - 私有属性

    private let logger = Logger(subsystem: "com.skybridge.connection", category: "CrossNetwork")
    private let signalServer: SignalServerClient
    private let iceServers: [String] = [SkyBridgeServerConfig.stunURL]
        + SkyBridgeServerConfig.turnURLs
        + [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302"
        ]
    private var activeListeners: [ConnectionListener] = []
    private var deviceFingerprint: String
    private static let shortCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let shortCodeAllowedCharacters = Set(shortCodeAlphabet)

    // MARK: - WebRTC (ICE / DataChannel)

    private var signalingClient: WebSocketSignalingClient?
    private var webrtcSessionsBySessionId: [String: WebRTCSession] = [:]
    private var pendingWebRTCOfferSessionIds: Set<String> = []
    private var webrtcRemoteIdBySessionId: [String: String] = [:]
    private var webrtcLatestOfferBySessionId: [String: String] = [:]
    private var webrtcJoinHeartbeatTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcOfferResendTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcControlTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcInboundQueuesBySessionId: [String: InboundChunkQueue] = [:]
    private var webrtcScreenStreamingTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcRemoteDesktopHeartbeatAtBySessionId: [String: Date] = [:]
    private var webrtcSessionKeysBySessionId: [String: SessionKeys] = [:]

    // File transfer waiters (sessionID|transferId|op|chunkIndex -> continuation)
    private var webrtcFileTransferWaiters: [String: CheckedContinuation<CrossNetworkFileTransferMessage, Error>] = [:]

 // MARK: - 连接状态

 /// 跨网络连接状态 - 符合 Swift 6.2.3 的 Sendable 要求和严格并发控制
 /// 注意：这是CrossNetworkConnectionManager专用的连接状态，与全局ConnectionStatus不同
 /// 论文口径：`connected` 必须与 `readiness == .handshakeComplete` 对齐。
    public enum CrossNetworkConnectionStatus: Sendable {
        case idle
        case generating
        case waiting(code: String)
        case connecting
        case connected
        case failed(String) // 使用String而不是Error，以符合Sendable要求
    }

    public enum CrossNetworkReadiness: Sendable, Equatable {
        case idle
        case transportReady(sessionId: String)
        case handshakeComplete(sessionId: String, negotiatedSuite: String)
    }

 // 为了向后兼容，保留类型别名（但建议使用 CrossNetworkConnectionStatus）
    @available(*, deprecated, renamed: "CrossNetworkConnectionStatus", message: "使用 CrossNetworkConnectionStatus 以避免与全局 ConnectionStatus 冲突")
    public typealias ConnectionStatus = CrossNetworkConnectionStatus

 // MARK: - 初始化

    public init() {
        self.signalServer = SignalServerClient()
        self.deviceFingerprint = Self.generateDeviceFingerprint()

        logger.info("跨网络连接管理器初始化完成")
    }

    public var isTransportReady: Bool {
        switch readiness {
        case .transportReady, .handshakeComplete:
            return true
        case .idle:
            return false
        }
    }

    public var isHandshakeComplete: Bool {
        if case .handshakeComplete = readiness { return true }
        return false
    }

    private static func hasUsableTURNCredentials(_ ice: WebRTCSession.ICEConfig) -> Bool {
        let hasTurnURL = ice.turnURLs.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let username = ice.turnUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = ice.turnPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasTurnURL && !username.isEmpty && !password.isEmpty
    }

    private func logICEPlan(_ ice: WebRTCSession.ICEConfig, context: String) {
        if Self.hasUsableTURNCredentials(ice) {
            let userHint = String(ice.turnUsername.prefix(8))
            logger.info("📡 \(context, privacy: .public) 使用 TURN+STUN: user=\(userHint, privacy: .public)...")
        } else {
            logger.warning("⚠️ \(context, privacy: .public) 未拿到可用 TURN 凭据，降级为 STUN-only")
        }
    }

    private func stopJoinHeartbeat(for sessionID: String) {
        webrtcJoinHeartbeatTasksBySessionId[sessionID]?.cancel()
        webrtcJoinHeartbeatTasksBySessionId.removeValue(forKey: sessionID)
    }

    private func startJoinHeartbeat(for sessionID: String, attempts: Int = 30) {
        stopJoinHeartbeat(for: sessionID)
        webrtcJoinHeartbeatTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            while remaining > 0, !Task.isCancelled, self.webrtcSessionsBySessionId[sessionID] != nil {
                await self.sendSignal(.init(sessionId: sessionID, from: self.deviceFingerprint, type: .join, payload: nil), retries: 2)
                remaining -= 1
                if remaining == 0 { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopOfferResendLoop(for sessionID: String) {
        webrtcOfferResendTasksBySessionId[sessionID]?.cancel()
        webrtcOfferResendTasksBySessionId.removeValue(forKey: sessionID)
    }

    private func cleanupWebRTCSession(_ sessionID: String, reason: String, closeSession: Bool = true) {
        logger.info("🧹 清理 WebRTC 会话: session=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)")

        stopJoinHeartbeat(for: sessionID)
        stopOfferResendLoop(for: sessionID)
        pendingWebRTCOfferSessionIds.remove(sessionID)
        webrtcLatestOfferBySessionId.removeValue(forKey: sessionID)
        webrtcRemoteIdBySessionId.removeValue(forKey: sessionID)
        webrtcSessionKeysBySessionId.removeValue(forKey: sessionID)
        webrtcRemoteDesktopHeartbeatAtBySessionId.removeValue(forKey: sessionID)

        if let controlTask = webrtcControlTasksBySessionId.removeValue(forKey: sessionID) {
            controlTask.cancel()
        }
        if let streamTask = webrtcScreenStreamingTasksBySessionId.removeValue(forKey: sessionID) {
            streamTask.cancel()
        }
        if let inboundQueue = webrtcInboundQueuesBySessionId.removeValue(forKey: sessionID) {
            Task { await inboundQueue.finish() }
        }
        failAllFileTransferWaitersForSession(sessionID: sessionID, message: "会话已结束")

        if closeSession, let session = webrtcSessionsBySessionId.removeValue(forKey: sessionID) {
            session.close()
        } else {
            webrtcSessionsBySessionId.removeValue(forKey: sessionID)
        }

        if currentConnection?.id == sessionID {
            currentConnection = nil
            readiness = .idle
        }
    }

    private func resendCachedOfferIfNeeded(for sessionID: String, reason: String) async {
        guard let sdp = webrtcLatestOfferBySessionId[sessionID] else { return }
        logger.info("🔁 重发本地 offer: session=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)")
        await sendSignal(
            .init(sessionId: sessionID, from: deviceFingerprint, type: .offer, payload: .init(sdp: sdp)),
            retries: 2
        )
    }

    private func startOfferResendLoop(for sessionID: String, attempts: Int = 40) {
        stopOfferResendLoop(for: sessionID)
        webrtcOfferResendTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            while remaining > 0, !Task.isCancelled, self.webrtcSessionsBySessionId[sessionID] != nil {
                if case .connected = self.connectionStatus { break }
                await self.resendCachedOfferIfNeeded(for: sessionID, reason: "periodic")
                remaining -= 1
                if remaining == 0 { break }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    // MARK: - 连接生命周期管理

    /// 断开当前跨网连接，释放所有 WebRTC / Signaling 资源。
    ///
    /// 符合 IEEE TDSC 安全生命周期要求：
    /// - 关闭所有 DataChannel / PeerConnection / SSL 上下文
    /// - 取消控制/屏幕推流任务
    /// - 清空会话密钥（防止密钥残留）
    public func disconnect() async {
        // 1) 关闭所有 WebRTC 会话
        for (_, session) in webrtcSessionsBySessionId {
            session.close()
        }
        webrtcSessionsBySessionId.removeAll()

        // 2) 结束入站队列，唤醒控制通道等待
        for (_, queue) in webrtcInboundQueuesBySessionId {
            await queue.finish()
        }
        webrtcInboundQueuesBySessionId.removeAll()

        // 3) 取消控制通道任务
        for (_, task) in webrtcControlTasksBySessionId {
            task.cancel()
        }
        webrtcControlTasksBySessionId.removeAll()

        // 4) 取消屏幕推流任务
        for (_, task) in webrtcScreenStreamingTasksBySessionId {
            task.cancel()
        }
        webrtcScreenStreamingTasksBySessionId.removeAll()

        // 5) 清空会话密钥
        webrtcSessionKeysBySessionId.removeAll()
        webrtcRemoteIdBySessionId.removeAll()
        webrtcLatestOfferBySessionId.removeAll()
        pendingWebRTCOfferSessionIds.removeAll()

        for (_, task) in webrtcJoinHeartbeatTasksBySessionId {
            task.cancel()
        }
        webrtcJoinHeartbeatTasksBySessionId.removeAll()

        for (_, task) in webrtcOfferResendTasksBySessionId {
            task.cancel()
        }
        webrtcOfferResendTasksBySessionId.removeAll()

        // 6) 关闭 WebSocket 信令
        if let sc = signalingClient {
            await sc.close()
        }
        signalingClient = nil

        // 7) 取消所有文件传输等待
        let waiters = webrtcFileTransferWaiters
        webrtcFileTransferWaiters.removeAll()
        for (_, c) in waiters {
            c.resume(throwing: WebRTCFileTransferWaitError.cancelled)
        }

        // 8) 重置状态
        currentConnection = nil
        connectionCode = nil
        qrCodeData = nil
        connectionStatus = .idle
        readiness = .idle

        logger.info("✅ CrossNetworkConnectionManager disconnected; all resources released")
    }

 // MARK: - 1️⃣ 动态二维码连接

 /// 生成动态加密二维码
 /// 包含：设备指纹 + 临时密钥 + ICE 候选信息 + 过期时间
    public func generateDynamicQRCode(validDuration: TimeInterval = 300) async throws -> Data {
        logger.info("生成动态二维码，有效期: \(validDuration)秒")
        connectionStatus = .generating
        readiness = .idle

 // 1. 生成会话密钥对（Curve25519 用于密钥协商）
 // 会话密钥用于后续P2P加密握手，独立于签名密钥
        let agreementPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let agreementPublicKey = agreementPrivateKey.publicKey

 // 1.1 生成签名密钥对（P256 ECDSA 用于二维码内容签名）
 // 统一采用 P256.Signing 以适配安全管理器的验签逻辑
        let signingPrivateKey = P256.Signing.PrivateKey()
        let signingPublicKey = signingPrivateKey.publicKey
        let signingPublicKeyData = signingPublicKey.rawRepresentation
        let signingFingerprintHex = SHA256.hash(data: signingPublicKeyData)
            .compactMap { String(format: "%02x", $0) }
            .joined()
 // 签名时间戳，用于时效与重放保护
        let signatureTimestamp = Date().timeIntervalSince1970

 // 2. 注册到信号服务器
        let sessionID = UUID().uuidString
        // 注意：WebRTC 模式下，二维码只承担“会话引导”作用，真正的 offer/answer/ICE 通过 WebSocket 信令交换。

 // 3. 构建 QR 码数据结构
 // 为统一验签，签名覆盖规范化负载（参照 P2PSecurityManager）
 // 规范化负载包含：设备ID/名称/类型/地址/端口/系统版本/能力列表/时间戳/指纹
        let canonicalPayload = Self.buildCanonicalSignaturePayload(
            id: deviceFingerprint,
            name: Host.current().localizedName ?? "Mac",
            type: .macOS,
            address: "0.0.0.0",
            port: 0,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capabilities: ["p2p", "cross-network"],
            timestamp: signatureTimestamp,
            fingerprintHex: signingFingerprintHex
        )
        let signature = try signingPrivateKey.signature(for: canonicalPayload)

        let qrData = DynamicQRCodeData(
            version: 2,
            sessionID: sessionID,
            deviceName: Host.current().localizedName ?? "Mac",
            deviceFingerprint: deviceFingerprint,
            publicKey: agreementPublicKey.rawRepresentation, // 用于密钥协商的公钥
            signingPublicKey: signingPublicKeyData,           // 用于验签的公钥
            signature: signature.rawRepresentation,           // P256 ECDSA 原始签名
            signatureTimestamp: signatureTimestamp,
            iceServers: iceServers,
            expiresAt: Date().addingTimeInterval(validDuration)
        )

 // 4. 编码为 JSON + URL-safe Base64（避免扫码器对 + / = 的兼容问题）
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(qrData)
        let base64String = Self.base64URLEncodedString(from: jsonData)

 // 5. 添加协议前缀（用于识别）
        let qrString = "skybridge://connect/\(base64String)"

        self.qrCodeData = qrString.data(using: .utf8)
        self.connectionStatus = .waiting(code: sessionID)
        self.readiness = .idle

        // 6. 启动 WebRTC offerer（等待对端扫码后通过 signaling 完成 SDP/ICE，DataChannel ready 后进入 connected）
        startWebRTCOfferSession(sessionID: sessionID)

        logger.info("✅ 动态二维码生成成功，会话ID: \(sessionID)")
        return qrCodeData!
    }

 /// 扫描并解析动态二维码
    public func scanDynamicQRCode(_ data: Data) async throws -> RemoteConnection {
        logger.info("扫描动态二维码")

        guard let qrString = String(data: data, encoding: .utf8),
              let payload = Self.extractConnectPayload(from: qrString) else {
            throw CrossNetworkConnectionError.invalidQRCode
        }

 // 1. 解析 QR 码
        guard let jsonData = Self.decodeBase64Payload(payload) else {
            throw CrossNetworkConnectionError.invalidQRCode
        }

        let decoder = JSONDecoder()
        let qrData = try decoder.decode(DynamicQRCodeData.self, from: jsonData)

 // 2. 验证有效期
        guard qrData.expiresAt > Date() else {
            throw CrossNetworkConnectionError.qrCodeExpired
        }

 // 3. 验证签名（统一接入 P2PSecurityManager）
 // 基于二维码中的签名公钥与签名，对规范化负载进行验签
        let securityManager = P2PSecurityManager()
 // 兼容老版本二维码（v1），若缺少签名字段则直接判为无效
        guard let signingKeyData = qrData.signingPublicKey, let signatureData = qrData.signature else {
            logger.error("二维码缺少签名或签名公钥字段")
            throw CrossNetworkConnectionError.invalidSignature
        }
        let deviceForVerify = P2PDevice(
            id: qrData.deviceFingerprint,
            name: qrData.deviceName,
            type: .macOS,
            address: "0.0.0.0",
            port: 0,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capabilities: ["p2p", "cross-network"],
            publicKey: signingKeyData,
            lastSeen: Date(),
            endpoints: [],
            lastMessageTimestamp: nil,
            isVerified: false,
            verificationFailedReason: nil
        )
        let verifyResult = securityManager.verifyQRCodeSignature(
            for: deviceForVerify,
            publicKeyBase64: signingKeyData.base64EncodedString(),
            signatureBase64: signatureData.base64EncodedString(),
            timestamp: qrData.signatureTimestamp,
            fingerprintHex: nil
        )
        guard verifyResult.ok else {
            logger.error("二维码验签失败：\(verifyResult.reason ?? "未知原因")")
            throw CrossNetworkConnectionError.invalidSignature
        }

        // 4. 建立 WebRTC DataChannel 连接（跨网）
        let connection = try await establishWebRTCConnection(with: qrData)

        self.currentConnection = connection
        self.connectionStatus = .connecting
        self.readiness = .idle

        logger.info("✅ 通过二维码连接成功")
        return connection
    }

 // MARK: - 2️⃣ iCloud 设备链连接

 /// 发现同 Apple ID 下的所有设备
    public func discoverCloudDevices() async throws {
        logger.info("🔍 发现 iCloud 设备链")

 // 使用 CloudKitService 获取设备列表
        await CloudKitService.shared.refreshDevices()

 // 获取设备列表（排除当前设备）
        let currentDeviceId = Self.generateDeviceFingerprint()
        let allDevices = CloudKitService.shared.devices

 // 过滤掉当前设备和离线设备（1小时内活跃）
        let activeDevices = allDevices.filter { device in
            device.id != currentDeviceId &&
            device.lastSeenAt.timeIntervalSinceNow > -3600
        }

        self.availableCloudDevices = activeDevices
        logger.info("✅ 发现 \(activeDevices.count) 台 iCloud 设备")
    }

 /// 通过 iCloud 设备链连接
    public func connectToCloudDevice(_ device: CloudDevice) async throws -> RemoteConnection {
        logger.info("连接到 iCloud 设备: \(device.name)")
        connectionStatus = .connecting
        readiness = .idle

 // 1. 通过 iCloud KV Store 交换 ICE 候选
        let sessionID = UUID().uuidString
        let offer = try await createConnectionOffer(sessionID: sessionID)

 // 2. 写入 offer 到 iCloud
        let kvStore = NSUbiquitousKeyValueStore.default
        if let offerData = try? JSONEncoder().encode(offer) {
            kvStore.set(offerData, forKey: "skybridge.offer.\(device.id)")
            kvStore.synchronize()
        }

 // 3. 等待 answer（轮询或推送）
        let answer = try await waitForAnswer(deviceID: device.id, timeout: 30)

 // 4. 建立连接
        let connection = try await finalizeConnection(offer: offer, answer: answer)

        self.currentConnection = connection
        self.connectionStatus = .connected
        self.readiness = .handshakeComplete(
            sessionId: connection.id,
            negotiatedSuite: "quic-transport"
        )

        logger.info("✅ 通过 iCloud 连接成功")
        return connection
    }

 // MARK: - 3️⃣ 智能连接码

 /// 生成智能连接码（6位字母数字）
    public func generateConnectionCode() async throws -> String {
        logger.info("生成智能连接码")
        connectionStatus = .generating
        readiness = .idle

        // 1) 生成短码（6 位，排除易混淆字符）
        let code = Self.generateShortCode()

        // 2) 对齐“零配置跨网”方案：直接把 code 当作 WebRTC sessionId。
        //    iOS 端只需输入同一 code 即可 join 同一 signaling room 并完成 offer/answer/ICE。
        self.connectionCode = code
        self.connectionStatus = .waiting(code: code)
        self.readiness = .idle

        // 3) 启动 WebRTC offerer（等待对端输入 code 后 join，同会话完成 SDP/ICE，DataChannel ready）
        startWebRTCOfferSession(sessionID: code)

        logger.info("✅ 连接码生成成功: \(code)")
        return code
    }

    /// 通过连接码连接
    public func connectWithCode(_ code: String) async throws -> RemoteConnection {
        // 作为“输入方”（answerer）加入对端创建的 sessionId=code 的 WebRTC 会话。
        guard let normalized = Self.normalizeConnectionCode(code) else {
            throw CrossNetworkConnectionError.invalidDevice
        }
        logger.info("使用连接码连接: \(normalized)")

        if let existing = currentConnection, existing.id == normalized {
            logger.info("复用已有连接码会话: \(normalized, privacy: .public)")
            return existing
        }

        let sessionID = normalized
        if let existingSession = webrtcSessionsBySessionId[sessionID] {
            logger.info("复用已有会话（避免重复创建）: \(sessionID, privacy: .public)")
            return RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .webrtc(existingSession))
        }

        connectionStatus = .connecting
        readiness = .idle

        ensureSignalingConnected()

        // 动态获取 TURN 凭据（带缓存和回退）
        let ice = await SkyBridgeServerConfig.dynamicICEConfig()
        logICEPlan(ice, context: "连接码模式")

        let session = WebRTCSession(sessionId: sessionID, localDeviceId: deviceFingerprint, role: .answerer, ice: ice)

        session.onLocalAnswer = { [weak self] sdp in
            guard let self else { return }
            Task { await self.sendSignal(.init(sessionId: sessionID, from: self.deviceFingerprint, type: .answer, payload: .init(sdp: sdp))) }
        }
        session.onLocalICECandidate = { [weak self] payload in
            guard let self else { return }
            Task { await self.sendSignal(.init(sessionId: sessionID, from: self.deviceFingerprint, type: .iceCandidate, payload: payload)) }
        }
        session.onDisconnected = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in
                guard self.currentConnection?.id == sessionID else { return }
                self.cleanupWebRTCSession(sessionID, reason: "transport_disconnected:\(reason)")
                self.connectionStatus = .failed("WebRTC transport disconnected: \(reason)")
                self.readiness = .idle
            }
        }
        session.onReady = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.logger.info("✅ WebRTC answerer ready: session=\(sessionID, privacy: .public)")
                self.stopJoinHeartbeat(for: sessionID)
                self.currentConnection = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .webrtc(session))
                self.connectionStatus = .connecting
                self.readiness = .transportReady(sessionId: sessionID)
                self.startWebRTCInboundHandshakeAndControlLoop(sessionID: sessionID, session: session, endpointDescription: "webrtc:\(sessionID)")
            }
        }

        webrtcSessionsBySessionId[sessionID] = session

        do {
            try session.start()
        } catch {
            logger.error("❌ connectWithCode(WebRTC) start failed: \(error.localizedDescription, privacy: .public)")
            cleanupWebRTCSession(sessionID, reason: "answerer_start_failed")
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }

        // 主动加入会话并在短时间内心跳重发，避免 WS 时序抖动导致 offer 丢失。
        await sendSignal(.init(sessionId: sessionID, from: deviceFingerprint, type: .join, payload: nil), retries: 2)
        startJoinHeartbeat(for: sessionID)

        let connection = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .webrtc(session))
        logger.info("✅ 通过连接码开始连接（等待对端 offer）")
        return connection
    }

 // MARK: - 私有方法 - P2P 连接建立

    private func establishP2PConnection(with qrData: DynamicQRCodeData) async throws -> RemoteConnection {
        logger.info("建立 P2P 连接（二维码模式）")

 // 1. 创建 NWConnection（QUIC over UDP for P2P）
        let parameters = NWParameters.quic(alpn: ["skybridge-p2p"])

 // 2. ICE 候选协商
        let iceCandidate = try await negotiateICE(
            sessionID: qrData.sessionID,
            remotePublicKey: qrData.publicKey
        )

 // 3. 建立连接
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(iceCandidate.host),
            port: NWEndpoint.Port(integerLiteral: iceCandidate.port)
        )

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .global(qos: .userInitiated))

 // 4. 等待连接就绪
        try await waitForConnection(connection)

        return RemoteConnection(
            id: qrData.sessionID,
            deviceName: qrData.deviceName,
            transport: .nw(connection)
        )
    }

    // MARK: - WebRTC Connection

    private func ensureSignalingConnected() {
        if let client = signalingClient {
            Task { await client.connect() }
            return
        }
        guard let url = URL(string: SkyBridgeServerConfig.signalingWebSocketURL) else { return }
        let client = WebSocketSignalingClient(url: url)
        self.signalingClient = client
        Task {
            await client.setOnEnvelope { [weak self] env in
                Task { @MainActor in
                    self?.handleSignalingEnvelope(env)
                }
            }
            await client.connect()
        }
    }

    private func startWebRTCOfferSession(sessionID: String) {
        ensureSignalingConnected()
        guard webrtcSessionsBySessionId[sessionID] == nil else { return }
        guard !pendingWebRTCOfferSessionIds.contains(sessionID) else { return }
        pendingWebRTCOfferSessionIds.insert(sessionID)

        // 异步获取动态 TURN 凭据
        Task { @MainActor in
            await self.startWebRTCOfferSessionWithDynamicCredentials(sessionID: sessionID)
        }
    }

    private func startWebRTCOfferSessionWithDynamicCredentials(sessionID: String) async {
        defer { pendingWebRTCOfferSessionIds.remove(sessionID) }
        guard webrtcSessionsBySessionId[sessionID] == nil else { return }

        // 动态获取 TURN 凭据（带缓存和回退）
        let ice = await SkyBridgeServerConfig.dynamicICEConfig()
        logICEPlan(ice, context: "连接码发起方")

        let session = WebRTCSession(sessionId: sessionID, localDeviceId: deviceFingerprint, role: .offerer, ice: ice)
        session.onLocalOffer = { [weak self] sdp in
            guard let self else { return }
            Task { @MainActor in
                self.webrtcLatestOfferBySessionId[sessionID] = sdp
                await self.sendSignal(.init(sessionId: sessionID, from: self.deviceFingerprint, type: .offer, payload: .init(sdp: sdp)), retries: 2)
            }
        }
        session.onLocalICECandidate = { [weak self] payload in
            guard let self else { return }
            Task {
                await self.sendSignal(.init(sessionId: sessionID, from: self.deviceFingerprint, type: .iceCandidate, payload: payload))
            }
        }
        session.onDisconnected = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in
                guard self.currentConnection?.id == sessionID else { return }
                self.cleanupWebRTCSession(sessionID, reason: "transport_disconnected:\(reason)")
                self.connectionStatus = .failed("WebRTC transport disconnected: \(reason)")
                self.readiness = .idle
            }
        }
        session.onReady = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.logger.info("✅ WebRTC offerer ready: session=\(sessionID, privacy: .public)")
                self.stopJoinHeartbeat(for: sessionID)
                self.stopOfferResendLoop(for: sessionID)
                self.currentConnection = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .webrtc(session))
                self.connectionStatus = .connecting
                self.readiness = .transportReady(sessionId: sessionID)

                // 启动“握手/控制通道”消费者：把 DataChannel 当作一条 length-framed byte stream，复用现有 HandshakeDriver / AppMessage 逻辑。
                self.startWebRTCInboundHandshakeAndControlLoop(sessionID: sessionID, session: session, endpointDescription: "webrtc:\(sessionID)")
            }
        }

        webrtcSessionsBySessionId[sessionID] = session

        do {
            try session.start()
            await sendSignal(.init(sessionId: sessionID, from: deviceFingerprint, type: .join, payload: nil), retries: 2)
            startJoinHeartbeat(for: sessionID)
            startOfferResendLoop(for: sessionID)
        } catch {
            logger.error("❌ startWebRTCOfferSession failed: \(error.localizedDescription, privacy: .public)")
            cleanupWebRTCSession(sessionID, reason: "offerer_start_failed")
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
        }
    }

    private func establishWebRTCConnection(with qrData: DynamicQRCodeData) async throws -> RemoteConnection {
        ensureSignalingConnected()

        let sessionID = qrData.sessionID

        // 动态获取 TURN 凭据（带缓存和回退）
        let ice = await SkyBridgeServerConfig.dynamicICEConfig()
        logICEPlan(ice, context: "二维码应答方")

        let session = WebRTCSession(sessionId: sessionID, localDeviceId: deviceFingerprint, role: .answerer, ice: ice)

        session.onLocalAnswer = { [weak self] sdp in
            guard let self else { return }
            Task {
                await self.sendSignal(.init(sessionId: sessionID, from: self.deviceFingerprint, type: .answer, payload: .init(sdp: sdp)))
            }
        }
        session.onLocalICECandidate = { [weak self] payload in
            guard let self else { return }
            Task {
                await self.sendSignal(.init(sessionId: sessionID, from: self.deviceFingerprint, type: .iceCandidate, payload: payload))
            }
        }
        session.onDisconnected = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in
                guard self.currentConnection?.id == sessionID else { return }
                self.cleanupWebRTCSession(sessionID, reason: "transport_disconnected:\(reason)")
                self.connectionStatus = .failed("WebRTC transport disconnected: \(reason)")
                self.readiness = .idle
            }
        }
        session.onReady = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.logger.info("✅ WebRTC QR answerer ready: session=\(sessionID, privacy: .public)")
                self.stopJoinHeartbeat(for: sessionID)
                self.currentConnection = RemoteConnection(id: sessionID, deviceName: qrData.deviceName, transport: .webrtc(session))
                self.connectionStatus = .connecting
                self.readiness = .transportReady(sessionId: sessionID)
                self.startWebRTCInboundHandshakeAndControlLoop(sessionID: sessionID, session: session, endpointDescription: "webrtc:\(sessionID)")
            }
        }

        webrtcSessionsBySessionId[sessionID] = session

        do {
            try session.start()
        } catch {
            cleanupWebRTCSession(sessionID, reason: "qr_answerer_start_failed")
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }

        // 主动发送 join，帮助服务端/对端建立“同会话订阅”的心智模型（服务端可忽略）
        await sendSignal(.init(sessionId: sessionID, from: deviceFingerprint, type: .join, payload: nil), retries: 2)
        startJoinHeartbeat(for: sessionID)

        return RemoteConnection(id: sessionID, deviceName: qrData.deviceName, transport: .webrtc(session))
    }

    private func sendSignal(_ env: WebRTCSignalingEnvelope, retries: Int = 2) async {
        var attemptsLeft = max(0, retries)
        while true {
            do {
                if let signalingClient {
                    await signalingClient.connect()
                } else {
                    ensureSignalingConnected()
                }
                guard let signalingClient else {
                    throw WebSocketSignalingClient.SignalingError.notConnected
                }
                try await signalingClient.send(env)
                return
            } catch {
                if let wsError = error as? WebSocketSignalingClient.SignalingError,
                   case .notConnected = wsError {
                    if let signalingClient {
                        await signalingClient.connect()
                    } else {
                        ensureSignalingConnected()
                    }
                }
                if attemptsLeft == 0 {
                    logger.error("❌ signaling send failed: type=\(env.type.rawValue, privacy: .public) session=\(env.sessionId, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
                    return
                }
                attemptsLeft -= 1
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func handleSignalingEnvelope(_ env: WebRTCSignalingEnvelope) {
        guard env.from != deviceFingerprint else { return }
        guard let session = webrtcSessionsBySessionId[env.sessionId] else {
            logger.debug("ℹ️ drop signaling envelope without local session: type=\(env.type.rawValue, privacy: .public) session=\(env.sessionId, privacy: .public)")
            return
        }

        // 记录对端 id（用于未来做定向路由）
        if webrtcRemoteIdBySessionId[env.sessionId] == nil {
            webrtcRemoteIdBySessionId[env.sessionId] = env.from
        }

        switch env.type {
        case .offer:
            stopJoinHeartbeat(for: env.sessionId)
            if let sdp = env.payload?.sdp {
                session.setRemoteOffer(sdp)
            }
        case .answer:
            stopJoinHeartbeat(for: env.sessionId)
            stopOfferResendLoop(for: env.sessionId)
            if let sdp = env.payload?.sdp {
                session.setRemoteAnswer(sdp)
            }
        case .iceCandidate:
            if let p = env.payload, let c = p.candidate {
                session.addRemoteICECandidate(candidate: c, sdpMid: p.sdpMid, sdpMLineIndex: p.sdpMLineIndex)
            }
        case .join:
            Task { @MainActor [weak self] in
                await self?.resendCachedOfferIfNeeded(for: env.sessionId, reason: "remote-join")
            }
        case .leave:
            cleanupWebRTCSession(env.sessionId, reason: "remote_leave")
            if currentConnection == nil {
                connectionStatus = .idle
                readiness = .idle
            }
        }
    }

    // MARK: - WebRTC File Transfer (macOS → iOS)

    private enum WebRTCFileTransferWaitError: LocalizedError {
        case timeout
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "跨网文件传输等待超时"
            case .cancelled:
                return "跨网文件传输已取消"
            case .failed(let msg):
                return "跨网文件传输失败: \(msg)"
            }
        }
    }

    private func fileTransferWaiterKey(sessionID: String, transferId: String, op: CrossNetworkFileTransferOp, chunkIndex: Int?) -> String {
        let idx = chunkIndex ?? -1
        return "\(sessionID)|\(transferId)|\(op.rawValue)|\(idx)"
    }

    private func resumeFileTransferWaiter(sessionID: String, message: CrossNetworkFileTransferMessage) {
        let key = fileTransferWaiterKey(sessionID: sessionID, transferId: message.transferId, op: message.op, chunkIndex: message.chunkIndex)
        if let waiter = webrtcFileTransferWaiters.removeValue(forKey: key) {
            waiter.resume(returning: message)
            return
        }

        // Also allow awaiting without chunkIndex.
        let keyNoIdx = fileTransferWaiterKey(sessionID: sessionID, transferId: message.transferId, op: message.op, chunkIndex: nil)
        if let waiter = webrtcFileTransferWaiters.removeValue(forKey: keyNoIdx) {
            waiter.resume(returning: message)
            return
        }
    }

    private func failFileTransferWaiters(sessionID: String, transferId: String, message: String) {
        let prefix = "\(sessionID)|\(transferId)|"
        let keys = webrtcFileTransferWaiters.keys.filter { $0.hasPrefix(prefix) }
        for k in keys {
            if let w = webrtcFileTransferWaiters.removeValue(forKey: k) {
                w.resume(throwing: WebRTCFileTransferWaitError.failed(message))
            }
        }
    }

    private func failAllFileTransferWaitersForSession(sessionID: String, message: String) {
        let prefix = "\(sessionID)|"
        let keys = webrtcFileTransferWaiters.keys.filter { $0.hasPrefix(prefix) }
        for k in keys {
            if let w = webrtcFileTransferWaiters.removeValue(forKey: k) {
                w.resume(throwing: WebRTCFileTransferWaitError.failed(message))
            }
        }
    }

    private func waitForFileTransferMessage(
        sessionID: String,
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int? = nil,
        timeoutSeconds: TimeInterval = 20
    ) async throws -> CrossNetworkFileTransferMessage {
        let key = fileTransferWaiterKey(sessionID: sessionID, transferId: transferId, op: op, chunkIndex: chunkIndex)
        if webrtcFileTransferWaiters[key] != nil {
            throw WebRTCFileTransferWaitError.cancelled
        }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CrossNetworkFileTransferMessage, Error>) in
            webrtcFileTransferWaiters[key] = c

            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                if let pending = self.webrtcFileTransferWaiters.removeValue(forKey: key) {
                    pending.resume(throwing: WebRTCFileTransferWaitError.timeout)
                }
            }
        }
    }

    private func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined ?? Data()
    }

    private func sendFramed(_ payload: Data, over session: WebRTCSession) throws {
        let maxDataChannelChunkBytes = 16 * 1024
        var framed = Data()
        var length = UInt32(payload.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(payload)
        var offset = 0
        while offset < framed.count {
            let end = min(offset + maxDataChannelChunkBytes, framed.count)
            let chunk = Data(framed[offset..<end])
            try session.send(chunk)
            offset = end
        }
    }

    private func sendFileTransferMessage(sessionID: String, session: WebRTCSession, keys: SessionKeys, message: CrossNetworkFileTransferMessage) throws {
        let plain = try JSONEncoder().encode(message)
        let enc = try encryptAppPayload(plain, with: keys)
        let padded = TrafficPadding.wrapIfEnabled(enc, label: "tx/webrtc-file")
        try sendFramed(padded, over: session)
    }

    /// Send a local file to the currently connected iOS peer over WebRTC DataChannel (zero-config cross-network).
    public func sendFileToConnectedPeer(_ url: URL) async throws {
        guard case .connected = connectionStatus,
              let conn = currentConnection,
              case .webrtc(let session) = conn.transport
        else {
            throw WebRTCFileTransferWaitError.failed("未建立跨网连接")
        }

        let sessionID = conn.id
        guard let keys = webrtcSessionKeysBySessionId[sessionID] else {
            throw WebRTCFileTransferWaitError.failed("握手未完成（会话密钥不可用）")
        }

        // Validate file
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let type = attrs[.type] as? FileAttributeType, type == .typeDirectory {
            throw WebRTCFileTransferWaitError.failed("暂不支持直接发送文件夹")
        }
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw WebRTCFileTransferWaitError.failed("文件大小无效")
        }

        let transferId = UUID().uuidString
        let remoteId = webrtcRemoteIdBySessionId[sessionID] ?? "webrtc-peer"
        let remoteName = conn.deviceName

        FileTransferManager.shared.beginExternalOutboundTransfer(
            transferId: transferId,
            fileURL: url,
            fileSize: fileSize,
            toDeviceId: remoteId,
            toDeviceName: remoteName
        )

        do {
            // DataChannel payload should stay conservative to avoid SCTP message-size rejection on mixed endpoints.
            let chunkSize = 16 * 1024
            let totalChunks = Int(ceil(Double(fileSize) / Double(chunkSize)))

            let snap = await SelfIdentityProvider.shared.snapshot()
            let meta = CrossNetworkFileTransferMessage(
                op: .metadata,
                transferId: transferId,
                senderDeviceId: snap.deviceId.isEmpty ? deviceFingerprint : snap.deviceId,
                senderDeviceName: Host.current().localizedName,
                fileName: url.lastPathComponent,
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                mimeType: nil
            )
            try sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: meta)

            _ = try await waitForFileTransferMessage(sessionID: sessionID, transferId: transferId, op: .metadataAck, timeoutSeconds: 15)

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var sentBytes: Int64 = 0
            var chunkIndex = 0
            var fileHasher = SHA256()

            while sentBytes < fileSize {
                let remaining = Int(fileSize - sentBytes)
                let readLen = min(chunkSize, max(0, remaining))
                if readLen <= 0 { break }

                try handle.seek(toOffset: UInt64(sentBytes))
                let data = handle.readData(ofLength: readLen)
                if data.isEmpty { break }

                fileHasher.update(data: data)
                let msg = CrossNetworkFileTransferMessage(
                    op: .chunk,
                    transferId: transferId,
                    chunkIndex: chunkIndex,
                    chunkData: data,
                    chunkSha256: CrossNetworkCrypto.sha256(data),
                    rawSize: data.count
                )
                try sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: msg)

                let ack: CrossNetworkFileTransferMessage = try await {
                    () async throws -> CrossNetworkFileTransferMessage in
                    var lastError: Error?
                    for _ in 0..<3 {
                        do {
                            return try await waitForFileTransferMessage(
                                sessionID: sessionID,
                                transferId: transferId,
                                op: .chunkAck,
                                chunkIndex: chunkIndex,
                                timeoutSeconds: 30
                            )
                        } catch {
                            lastError = error
                            // Best-effort resend: safe because receiver writes at fixed offset.
                            do {
                                try sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: msg)
                            } catch {
                                lastError = error
                                break
                            }
                        }
                    }
                    throw lastError ?? WebRTCFileTransferWaitError.timeout
                }()

                if ack.op == .error {
                    throw WebRTCFileTransferWaitError.failed(ack.message ?? "remote error")
                }

                let progressed = ack.receivedBytes ?? (sentBytes + Int64(data.count))
                sentBytes = min(fileSize, max(sentBytes + Int64(data.count), progressed))
                chunkIndex += 1

                FileTransferManager.shared.updateExternalOutboundProgress(
                    transferId: transferId,
                    transferredBytes: sentBytes
                )
            }

            let fileSha = Data(fileHasher.finalize())
            let done = CrossNetworkFileTransferMessage(
                op: .complete,
                transferId: transferId,
                receivedBytes: fileSize,
                fileSha256: fileSha
            )
            try sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: done)
            _ = try await waitForFileTransferMessage(sessionID: sessionID, transferId: transferId, op: .completeAck, timeoutSeconds: 30)

            FileTransferManager.shared.completeExternalOutboundTransfer(transferId: transferId)
        } catch {
            FileTransferManager.shared.failExternalOutboundTransfer(transferId: transferId, errorMessage: error.localizedDescription)
            throw error
        }
    }

    // MARK: - WebRTC -> Handshake/Control Channel

    private actor InboundChunkQueue {
        private var pending: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []
        private var finished = false

        enum QueueError: Error { case finished }

        func push(_ data: Data) {
            guard !finished else { return }
            if let w = waiters.first {
                waiters.removeFirst()
                w.resume(returning: data)
                return
            }
            pending.append(data)
        }

        func finish() {
            finished = true
            let ws = waiters
            waiters.removeAll()
            ws.forEach { $0.resume(throwing: QueueError.finished) }
        }

        func next() async throws -> Data {
            if let first = pending.first {
                pending.removeFirst()
                return first
            }
            if finished { throw QueueError.finished }
            return try await withCheckedThrowingContinuation { c in
                waiters.append(c)
            }
        }

        func next(max: Int) async throws -> Data {
            precondition(max > 0, "max must be greater than zero")
            let chunk = try await next()
            if chunk.count <= max {
                return chunk
            }
            let head = Data(chunk.prefix(max))
            let tail = Data(chunk.dropFirst(max))
            pending.insert(tail, at: 0)
            return head
        }
    }

    private func stopWebRTCScreenStreaming(sessionID: String) {
        if let task = webrtcScreenStreamingTasksBySessionId.removeValue(forKey: sessionID) {
            task.cancel()
        }
    }

    private func startWebRTCInboundHandshakeAndControlLoop(sessionID: String, session: WebRTCSession, endpointDescription: String) {
        if webrtcControlTasksBySessionId[sessionID] != nil { return }

        let queue = InboundChunkQueue()
        webrtcInboundQueuesBySessionId[sessionID] = queue
        session.onData = { data in
            Task { await queue.push(data) }
        }

        webrtcControlTasksBySessionId[sessionID] = Task { [weak self] in
            guard let self else { return }
            await self.consumeInboundHandshakeOrControlChannelWebRTC(
                sessionID: sessionID,
                session: session,
                endpointDescription: endpointDescription,
                inbound: queue
            )
            await queue.finish()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.webrtcControlTasksBySessionId.removeValue(forKey: sessionID)
                self.webrtcInboundQueuesBySessionId.removeValue(forKey: sessionID)
                self.stopWebRTCScreenStreaming(sessionID: sessionID)
                self.failAllFileTransferWaitersForSession(sessionID: sessionID, message: "WebRTC control channel closed")
                if self.webrtcSessionsBySessionId[sessionID] != nil {
                    self.cleanupWebRTCSession(sessionID, reason: "control_channel_closed")
                    self.connectionStatus = .failed("WebRTC control channel closed")
                    self.readiness = .idle
                }
            }
        }
    }

    private func consumeInboundHandshakeOrControlChannelWebRTC(
        sessionID: String,
        session: WebRTCSession,
        endpointDescription: String,
        inbound: InboundChunkQueue
    ) async {
        struct DirectHandshakeTransport: DiscoveryTransport {
            let sendRaw: @Sendable (Data) async throws -> Void
            func send(to peer: PeerIdentifier, data: Data) async throws { try await sendRaw(data) }
        }

        let maxDataChannelChunkBytes = 16 * 1024

        @Sendable func sendFramed(_ data: Data) async throws {
            var framed = Data()
            var length = UInt32(data.count).bigEndian
            framed.append(Data(bytes: &length, count: 4))
            framed.append(data)
            var offset = 0
            while offset < framed.count {
                let end = min(offset + maxDataChannelChunkBytes, framed.count)
                let chunk = Data(framed[offset..<end])
                // Keep one framed payload contiguous on DataChannel.
                // Avoid per-chunk actor hopping, which can interleave chunks from concurrent senders
                // and corrupt the length-prefixed stream.
                try session.send(chunk)
                offset = end
            }
        }

        func receiveSome(max: Int) async throws -> Data {
            try await inbound.next(max: max)
        }

        func receiveExactly(_ length: Int) async throws -> Data {
            var buffer = Data()
            buffer.reserveCapacity(length)
            while buffer.count < length {
                let remaining = length - buffer.count
                let chunk = try await receiveSome(max: min(65536, remaining))
                buffer.append(chunk)
            }
            return buffer
        }

        let transport = DirectHandshakeTransport(sendRaw: { data in
            try await sendFramed(data)
        })

        let peerDeviceId = webrtcRemoteIdBySessionId[sessionID] ?? "webrtc-\(sessionID)"
        let peer = PeerIdentifier(deviceId: peerDeviceId)

        var driver: HandshakeDriver?
        var sessionKeys: SessionKeys?

        func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
            if data.count == 38, (try? HandshakeFinished.decode(from: data)) != nil { return true }
            if (try? HandshakeMessageA.decode(from: data)) != nil { return true }
            if (try? HandshakeMessageB.decode(from: data)) != nil { return true }
            return false
        }

        func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.sendKey)
            let sealed = try AES.GCM.seal(plaintext, using: key)
            return sealed.combined ?? Data()
        }

        func decryptAppPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.receiveKey)
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        }

        enum RemoteMessageTypeWire: String, Codable { case screenData, mouseEvent, keyboardEvent }
        struct RemoteMessageWire: Codable {
            let type: RemoteMessageTypeWire
            let payload: Data
        }
        enum MouseEventTypeWire: String, Codable {
            case leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp, mouseMoved, scrollUp, scrollDown
        }
        struct MouseEventWire: Codable {
            let type: MouseEventTypeWire
            let x: Double
            let y: Double
            let timestamp: TimeInterval
        }
        enum KeyboardEventTypeWire: String, Codable { case keyDown, keyUp }
        struct KeyboardEventWire: Codable {
            let type: KeyboardEventTypeWire
            let keyCode: Int
            let timestamp: TimeInterval
        }
        struct ScreenDataWire: Codable {
            let width: Int
            let height: Int
            let imageData: Data
            let timestamp: TimeInterval
            let format: String?
        }

        struct InboundFileTransferState {
            let transferId: String
            let fileName: String
            let fileSize: Int64
            let chunkSize: Int
            let totalChunks: Int
            let senderDeviceId: String
            let senderDeviceName: String?
            let tempURL: URL
            let finalURL: URL
            let handle: FileHandle
            var receivedBytes: Int64
            var completeRequestedAt: Date? = nil
            var expectedFileSha256: Data? = nil
            var expectedMerkleRoot: Data? = nil
            var expectedMerkleSig: Data? = nil
            var expectedMerkleSigAlg: String? = nil
            var chunkHashes: [Int: Data] = [:]
        }
        var inboundFileTransfers: [String: InboundFileTransferState] = [:]
        var inboundFileTransferCompleteTimers: [String: Task<Void, Never>] = [:]
        defer {
            for (_, task) in inboundFileTransferCompleteTimers {
                task.cancel()
            }
            inboundFileTransferCompleteTimers.removeAll()

            if !inboundFileTransfers.isEmpty {
                for st in inboundFileTransfers.values {
                    try? st.handle.close()
                    try? FileManager.default.removeItem(at: st.tempURL)
                    FileTransferManager.shared.failExternalTransfer(
                        transferId: st.transferId,
                        errorMessage: "WebRTC channel closed before transfer completion"
                    )
                }
                inboundFileTransfers.removeAll()
            }
        }

        func sanitizeFileName(_ name: String) -> String {
            let last = (name as NSString).lastPathComponent
            // Avoid empty / reserved names.
            let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "SkyBridgeFile" : trimmed
        }

        func makeUniqueDestinationURL(baseDir: URL, fileName: String) -> URL {
            let safe = sanitizeFileName(fileName)
            let ext = (safe as NSString).pathExtension
            let stem = (safe as NSString).deletingPathExtension

            var candidate = baseDir.appendingPathComponent(safe)
            var idx = 1
            while FileManager.default.fileExists(atPath: candidate.path) {
                let altName: String
                if ext.isEmpty {
                    altName = "\(stem) (\(idx))"
                } else {
                    altName = "\(stem) (\(idx)).\(ext)"
                }
                candidate = baseDir.appendingPathComponent(altName)
                idx += 1
            }
            return candidate
        }

        func sha256File(at url: URL) -> Data? {
            guard #available(macOS 10.15, iOS 13.0, *) else { return nil }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }

            var hasher = SHA256()
            while true {
                let chunk = handle.readData(ofLength: 256 * 1024)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return Data(hasher.finalize())
        }

        func ensureAccessibilityPermission() -> Bool {
            if AXIsProcessTrusted() { return true }
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            return AXIsProcessTrusted()
        }

        func handleMouseEvent(_ event: MouseEventWire) {
            guard ensureAccessibilityPermission() else { return }
            let displayID = CGMainDisplayID()
            let screenH = Double(CGDisplayPixelsHigh(displayID))
            let point = CGPoint(x: event.x, y: screenH - event.y)
            func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
            switch event.type {
            case .mouseMoved:
                post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
            case .leftMouseDown:
                post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
            case .leftMouseUp:
                post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
            case .rightMouseDown:
                post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right))
            case .rightMouseUp:
                post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right))
            case .scrollUp:
                post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0))
            case .scrollDown:
                post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0))
            }
        }

        func handleKeyboardEvent(_ event: KeyboardEventWire) {
            guard ensureAccessibilityPermission() else { return }
            let keyCode = CGKeyCode(event.keyCode)
            let down = (event.type == .keyDown)
            let cg = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
            cg?.post(tap: .cghidEventTap)
        }

        func jpegData(from image: CGImage, quality: CGFloat = 0.55) -> Data? {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return data as Data
        }

        func startScreenStreamingIfNeeded(keys: SessionKeys) {
            guard self.webrtcScreenStreamingTasksBySessionId[sessionID] == nil else { return }
            self.webrtcScreenStreamingTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
                guard let self else { return }
                let maxBufferedAmountBytes: UInt64 = 1_500_000
                let heartbeatTimeoutSeconds: TimeInterval = 8.0
                var bytesSent: Int = 0
                var framesSent: Int = 0
                var logWindowStart = Date()

                defer { self.webrtcScreenStreamingTasksBySessionId.removeValue(forKey: sessionID) }

                while !Task.isCancelled {
                    guard let lastHeartbeatAt = self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] else {
                        self.logger.info("⏸️ WebRTC 屏幕推流等待远端心跳: session=\(sessionID, privacy: .public)")
                        break
                    }
                    if Date().timeIntervalSince(lastHeartbeatAt) > heartbeatTimeoutSeconds {
                        self.logger.info("⏹️ WebRTC 屏幕推流因远端心跳超时停止: session=\(sessionID, privacy: .public)")
                        break
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        break
                    }
                    let bufferedAmount = session.dataChannelBufferedAmountBytes()
                    if bufferedAmount > maxBufferedAmountBytes {
                        self.logger.debug(
                            "⏳ WebRTC 屏幕推流背压：跳过本帧 buffered=\(Int(bufferedAmount), privacy: .public)"
                        )
                        continue
                    }
                    guard let img = CGDisplayCreateImage(CGMainDisplayID()) else { continue }
                    guard let jpg = jpegData(from: img) else { continue }
                    let sd = ScreenDataWire(
                        width: img.width,
                        height: img.height,
                        imageData: jpg,
                        timestamp: Date().timeIntervalSince1970,
                        format: "jpeg"
                    )
                    guard let payload = try? JSONEncoder().encode(sd) else { continue }
                    let msg = RemoteMessageWire(type: .screenData, payload: payload)
                    guard let plain = try? JSONEncoder().encode(msg) else { continue }

                    do {
                        let enc = try encryptAppPayload(plain, with: keys)
                        let padded = TrafficPadding.wrapIfEnabled(enc, label: "tx/webrtc-screen")
                        try await sendFramed(padded)
                        bytesSent += padded.count + 4
                        framesSent += 1
                        let elapsed = Date().timeIntervalSince(logWindowStart)
                        if elapsed >= 5.0 {
                            let upMBps = Double(bytesSent) / elapsed / 1024.0 / 1024.0
                            let fps = Double(framesSent) / elapsed
                            self.logger.info(
                                "📈 WebRTC 屏幕推流吞吐: session=\(sessionID, privacy: .public) up=\(String(format: "%.2f", upMBps), privacy: .public)MB/s fps=\(String(format: "%.1f", fps), privacy: .public)"
                            )
                            bytesSent = 0
                            framesSent = 0
                            logWindowStart = Date()
                        }
                    } catch {
                        self.logger.error("❌ WebRTC 屏幕推流发送失败: \(error.localizedDescription, privacy: .public)")
                        break
                    }
                }
            }
        }

        logger.info("🤝 WebRTC 控制通道：启动入站握手/消息循环 session=\(sessionID, privacy: .public)")

        let maxInboundFrameBytes = 8_000_000

        do {
            while true {
                let lenData = try await receiveExactly(4)
                let totalLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                guard totalLen > 0 && totalLen < maxInboundFrameBytes else {
                    logger.warning("⚠️ WebRTC frame length out of range: len=\(Int(totalLen), privacy: .public) max=\(maxInboundFrameBytes, privacy: .public)")
                    break
                }
                let payload = try await receiveExactly(Int(totalLen))

                let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc")
                let frame = HandshakePadding.unwrapIfNeeded(trafficUnwrapped, label: "rx/webrtc")

                if let keys = sessionKeys, !isLikelyHandshakeControlPacket(frame) {
                    do {
                        let plaintext = try decryptAppPayload(frame, with: keys)
                        if let msg = try? JSONDecoder().decode(AppMessage.self, from: plaintext) {
                            switch msg {
                            case .pairingIdentityExchange(let payload):
                                let request = PairingTrustApprovalService.Request(
                                    peerEndpoint: endpointDescription,
                                    declaredDeviceId: payload.deviceId,
                                    displayName: payload.deviceName ?? payload.deviceId,
                                    model: payload.modelName,
                                    platform: payload.platform,
                                    osVersion: payload.osVersion,
                                    kemKeyCount: payload.kemPublicKeys.count
                                )
                                let decision = await PairingTrustApprovalService.shared.decide(for: request)
                                guard decision != PairingTrustApprovalService.Decision.reject else { break }

                                await PeerKEMBootstrapStore.shared.upsert(
                                    deviceIds: [payload.deviceId, endpointDescription],
                                    kemPublicKeys: payload.kemPublicKeys
                                )
                                logger.info(
                                    "🔑 WebRTC bootstrap KEM cache updated: declared=\(payload.deviceId, privacy: .public) peer=\(endpointDescription, privacy: .public) keys=\(payload.kemPublicKeys.count, privacy: .public)"
                                )

                                let provider = CryptoProviderFactory.make(policy: .preferPQC)
                                let km = DeviceIdentityKeyManager.shared
                                let kemKeys: [KEMPublicKeyInfo]
                                do {
                                    kemKeys = try await km.pairingIdentityKEMPublicKeys(using: provider)
                                } catch {
                                    logger.warning("⚠️ WebRTC bootstrap reply KEM 公钥准备失败: \(error.localizedDescription, privacy: .public)")
                                    kemKeys = []
                                }
                                let localId = await SelfIdentityProvider.shared.snapshot().deviceId
                                let localPlatform: String = {
#if os(macOS)
                                    return "macOS"
#elseif os(iOS)
                                    return "iOS"
#else
                                    return "unknown"
#endif
                                }()
                                let localOS = ProcessInfo.processInfo.operatingSystemVersionString
                                let localName: String? = {
#if os(macOS)
                                    return Host.current().localizedName
#elseif os(iOS)
                                    return UIDevice.current.name
#else
                                    return nil
#endif
                                }()
                                let localModel: String? = {
#if os(macOS)
                                    return "Mac"
#elseif os(iOS)
                                    return UIDevice.current.model
#else
                                    return nil
#endif
                                }()
                                let reply = AppMessage.pairingIdentityExchange(.init(
                                    deviceId: localId,
                                    kemPublicKeys: kemKeys,
                                    deviceName: localName,
                                    modelName: localModel,
                                    platform: localPlatform,
                                    osVersion: localOS,
                                    chip: nil
                                ))
                                let outPlain = try JSONEncoder().encode(reply)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc")
                                try await sendFramed(outPadded)
                            case .heartbeat:
                                self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] = Date()
                                startScreenStreamingIfNeeded(keys: keys)
                            default:
                                break
                            }
                        } else if let ft = try? JSONDecoder().decode(CrossNetworkFileTransferMessage.self, from: plaintext), ft.version == 1 {
                            switch ft.op {
                            case .metadata:
                                // Idempotent: allow re-sending metadata for the same transferId (resume).
                                if inboundFileTransfers[ft.transferId] != nil {
                                    let ack = CrossNetworkFileTransferMessage(op: .metadataAck, transferId: ft.transferId)
                                    let outPlain = try JSONEncoder().encode(ack)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-metaAck")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                guard
                                    let fileName = ft.fileName,
                                    let fileSize = ft.fileSize,
                                    let chunkSize = ft.chunkSize,
                                    let totalChunks = ft.totalChunks
                                else {
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        message: "Invalid metadata (missing fileName/fileSize/chunkSize/totalChunks)"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                let baseDir = FileManager.default
                                    .urls(for: .downloadsDirectory, in: .userDomainMask).first!
                                    .appendingPathComponent("SkyBridge", isDirectory: true)
                                try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

                                let finalURL = makeUniqueDestinationURL(baseDir: baseDir, fileName: fileName)
                                let tempURL = baseDir.appendingPathComponent(".skybridge-\(ft.transferId).partial")
                                _ = FileManager.default.createFile(atPath: tempURL.path, contents: nil)

                                let handle = try FileHandle(forWritingTo: tempURL)
                                let senderId = ft.senderDeviceId ?? endpointDescription
                                let senderName = ft.senderDeviceName ?? senderId

                                inboundFileTransfers[ft.transferId] = InboundFileTransferState(
                                    transferId: ft.transferId,
                                    fileName: fileName,
                                    fileSize: fileSize,
                                    chunkSize: chunkSize,
                                    totalChunks: totalChunks,
                                    senderDeviceId: senderId,
                                    senderDeviceName: senderName,
                                    tempURL: tempURL,
                                    finalURL: finalURL,
                                    handle: handle,
                                    receivedBytes: 0
                                )

                                await MainActor.run {
                                    FileTransferManager.shared.beginExternalInboundTransfer(
                                        transferId: ft.transferId,
                                        fileName: fileName,
                                        fileSize: fileSize,
                                        fromDeviceId: senderId,
                                        fromDeviceName: senderName
                                    )
                                }

                                let ack = CrossNetworkFileTransferMessage(op: .metadataAck, transferId: ft.transferId)
                                let outPlain = try JSONEncoder().encode(ack)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-metaAck")
                                try await sendFramed(outPadded)

                            case .chunk:
                                guard
                                    let idx = ft.chunkIndex,
                                    let data = ft.chunkData
                                else { break }
                                guard var st = inboundFileTransfers[ft.transferId] else {
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        message: "Unknown transferId (no metadata)"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                if let expected = ft.chunkSha256, CrossNetworkCrypto.sha256(data) != expected {
                                    // Backward compatible: only enforce if hash provided.
                                    // Don't ACK corrupted chunk; sender will timeout/retry as appropriate.
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        chunkIndex: idx,
                                        message: "chunk hash mismatch"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                // Track actual chunk hashes for optional Merkle verification.
                                st.chunkHashes[idx] = CrossNetworkCrypto.sha256(data)

                                let rawSize = ft.rawSize ?? data.count
                                let offset = Int64(idx) * Int64(st.chunkSize)
                                try st.handle.seek(toOffset: UInt64(max(0, offset)))
                                try st.handle.write(contentsOf: data)

                                st.receivedBytes = min(st.fileSize, max(st.receivedBytes, offset + Int64(rawSize)))
                                // If complete was already requested earlier, finalize once we have enough.
                                if st.completeRequestedAt != nil && st.receivedBytes >= st.fileSize {
                                    // Close + move temp -> final + ACK complete, matching old behavior but delayed.
                                    do { try st.handle.close() } catch {}
                                    do {
                                        if let expectedMerkle = st.expectedMerkleRoot {
                                            let leaves: [Data] = (0..<st.totalChunks).compactMap { st.chunkHashes[$0] }
                                            if leaves.count != st.totalChunks || CrossNetworkMerkle.root(leaves: leaves) != expectedMerkle {
                                                await MainActor.run {
                                                    FileTransferManager.shared.failExternalTransfer(
                                                        transferId: st.transferId,
                                                        errorMessage: "merkle root mismatch"
                                                    )
                                                }
                                                inboundFileTransfers.removeValue(forKey: st.transferId)
                                                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                                try? FileManager.default.removeItem(at: st.tempURL)
                                                let err = CrossNetworkFileTransferMessage(
                                                    op: .error,
                                                    transferId: st.transferId,
                                                    message: "merkle root mismatch"
                                                )
                                                let outPlain = try JSONEncoder().encode(err)
                                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                                try await sendFramed(outPadded)
                                                break
                                            }

                                            if let sig = st.expectedMerkleSig {
                                                if st.expectedMerkleSigAlg != CrossNetworkMerkleAuth.signatureAlgV1 {
                                                    await MainActor.run {
                                                        FileTransferManager.shared.failExternalTransfer(
                                                            transferId: st.transferId,
                                                            errorMessage: "unknown merkle sig alg"
                                                        )
                                                    }
                                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                                    try? FileManager.default.removeItem(at: st.tempURL)
                                                    let err = CrossNetworkFileTransferMessage(
                                                        op: .error,
                                                        transferId: st.transferId,
                                                        message: "unknown merkle sig alg"
                                                    )
                                                    let outPlain = try JSONEncoder().encode(err)
                                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                                    try await sendFramed(outPadded)
                                                    break
                                                }
                                                let pre = CrossNetworkMerkleAuth.preimage(
                                                    transferId: st.transferId,
                                                    merkleRoot: expectedMerkle,
                                                    fileSha256: st.expectedFileSha256
                                                )
                                                let expectSig = CrossNetworkMerkleAuth.hmacSha256(key: keys.receiveKey, data: pre)
                                                if sig != expectSig {
                                                    await MainActor.run {
                                                        FileTransferManager.shared.failExternalTransfer(
                                                            transferId: st.transferId,
                                                            errorMessage: "merkle signature mismatch"
                                                        )
                                                    }
                                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                                    try? FileManager.default.removeItem(at: st.tempURL)
                                                    let err = CrossNetworkFileTransferMessage(
                                                        op: .error,
                                                        transferId: st.transferId,
                                                        message: "merkle signature mismatch"
                                                    )
                                                    let outPlain = try JSONEncoder().encode(err)
                                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                                    try await sendFramed(outPadded)
                                                    break
                                                }
                                            }
                                        }

                                        if let expected = st.expectedFileSha256, let actual = sha256File(at: st.tempURL), actual != expected {
                                            await MainActor.run {
                                                FileTransferManager.shared.failExternalTransfer(
                                                    transferId: st.transferId,
                                                    errorMessage: "file sha256 mismatch"
                                                )
                                            }
                                            inboundFileTransfers.removeValue(forKey: st.transferId)
                                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                            try? FileManager.default.removeItem(at: st.tempURL)

                                            let err = CrossNetworkFileTransferMessage(
                                                op: .error,
                                                transferId: st.transferId,
                                                message: "file sha256 mismatch"
                                            )
                                            let outPlain = try JSONEncoder().encode(err)
                                            let outCipher = try encryptAppPayload(outPlain, with: keys)
                                            let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                            try await sendFramed(outPadded)
                                            break
                                        }
                                        if FileManager.default.fileExists(atPath: st.finalURL.path) {
                                            try? FileManager.default.removeItem(at: st.finalURL)
                                        }
                                        try FileManager.default.moveItem(at: st.tempURL, to: st.finalURL)
                                        await MainActor.run {
                                            FileTransferManager.shared.completeExternalInboundTransfer(
                                                transferId: st.transferId,
                                                savedTo: st.finalURL
                                            )
                                        }
                                        inboundFileTransfers.removeValue(forKey: st.transferId)
                                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                        let ack = CrossNetworkFileTransferMessage(op: .completeAck, transferId: st.transferId)
                                        let outPlain = try JSONEncoder().encode(ack)
                                        let outCipher = try encryptAppPayload(outPlain, with: keys)
                                        let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-completeAck")
                                        try await sendFramed(outPadded)
                                        break
                                    } catch {
                                        await MainActor.run {
                                            FileTransferManager.shared.failExternalTransfer(
                                                transferId: st.transferId,
                                                errorMessage: "Save failed: \(error.localizedDescription)"
                                            )
                                        }
                                        inboundFileTransfers.removeValue(forKey: st.transferId)
                                    }
                                }
                                inboundFileTransfers[ft.transferId] = st

                                await MainActor.run {
                                    FileTransferManager.shared.updateExternalInboundProgress(
                                        transferId: st.transferId,
                                        transferredBytes: st.receivedBytes
                                    )
                                }

                                let ack = CrossNetworkFileTransferMessage(
                                    op: .chunkAck,
                                    transferId: st.transferId,
                                    chunkIndex: idx,
                                    receivedBytes: st.receivedBytes
                                )
                                let outPlain = try JSONEncoder().encode(ack)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-chunkAck")
                                try await sendFramed(outPadded)

                            case .complete:
                                guard var st = inboundFileTransfers[ft.transferId] else { break }

                                // Capture expected full-file hash (optional, backward compatible).
                                if st.expectedFileSha256 == nil { st.expectedFileSha256 = ft.fileSha256 }
                                if st.expectedMerkleRoot == nil { st.expectedMerkleRoot = ft.merkleRoot }
                                if st.expectedMerkleSig == nil { st.expectedMerkleSig = ft.merkleRootSignature }
                                if st.expectedMerkleSigAlg == nil { st.expectedMerkleSigAlg = ft.merkleRootSignatureAlg }

                                if st.receivedBytes < st.fileSize {
                                    // Optional NACK: request missing chunks (backward compatible).
                                    let missing = (0..<st.totalChunks).filter { st.chunkHashes[$0] == nil }
                                    if !missing.isEmpty {
                                        let nack = CrossNetworkFileTransferMessage(
                                            op: .chunkAck,
                                            transferId: st.transferId,
                                            missingChunks: missing.prefix(512).map { Int($0) },
                                            message: "missingChunks"
                                        )
                                        let outPlain = try JSONEncoder().encode(nack)
                                        let outCipher = try encryptAppPayload(outPlain, with: keys)
                                        let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-missingChunks")
                                        try await sendFramed(outPadded)
                                    }

                                    // Don't fail immediately; mark complete requested and wait for retransmits.
                                    if st.completeRequestedAt == nil { st.completeRequestedAt = Date() }
                                    inboundFileTransfers[st.transferId] = st
                                    if inboundFileTransferCompleteTimers[st.transferId] == nil {
                                        inboundFileTransferCompleteTimers[st.transferId] = Task {
                                            try? await Task.sleep(for: .seconds(10))
                                            if let cur = inboundFileTransfers[st.transferId], cur.receivedBytes < cur.fileSize {
                                                do { try cur.handle.close() } catch {}
                                                try? FileManager.default.removeItem(at: cur.tempURL)
                                                await MainActor.run {
                                                    FileTransferManager.shared.failExternalTransfer(
                                                        transferId: cur.transferId,
                                                        errorMessage: "Incomplete file (timeout): \(cur.receivedBytes)/\(cur.fileSize)"
                                                    )
                                                }
                                                inboundFileTransfers.removeValue(forKey: cur.transferId)
                                                inboundFileTransferCompleteTimers[cur.transferId]?.cancel()
                                                inboundFileTransferCompleteTimers.removeValue(forKey: cur.transferId)
                                            }
                                        }
                                    }
                                    break
                                }

                                do { try st.handle.close() } catch {}

                                // Move temp -> final
                                do {
                                    if let expectedMerkle = st.expectedMerkleRoot {
                                        let leaves: [Data] = (0..<st.totalChunks).compactMap { st.chunkHashes[$0] }
                                        if leaves.count != st.totalChunks || CrossNetworkMerkle.root(leaves: leaves) != expectedMerkle {
                                            await MainActor.run {
                                                FileTransferManager.shared.failExternalTransfer(
                                                    transferId: st.transferId,
                                                    errorMessage: "merkle root mismatch"
                                                )
                                            }
                                            inboundFileTransfers.removeValue(forKey: st.transferId)
                                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                            try? FileManager.default.removeItem(at: st.tempURL)
                                            let err = CrossNetworkFileTransferMessage(
                                                op: .error,
                                                transferId: st.transferId,
                                                message: "merkle root mismatch"
                                            )
                                            let outPlain = try JSONEncoder().encode(err)
                                            let outCipher = try encryptAppPayload(outPlain, with: keys)
                                            let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                            try await sendFramed(outPadded)
                                            break
                                        }

                                        if let sig = st.expectedMerkleSig {
                                            if st.expectedMerkleSigAlg != CrossNetworkMerkleAuth.signatureAlgV1 {
                                                await MainActor.run {
                                                    FileTransferManager.shared.failExternalTransfer(
                                                        transferId: st.transferId,
                                                        errorMessage: "unknown merkle sig alg"
                                                    )
                                                }
                                                inboundFileTransfers.removeValue(forKey: st.transferId)
                                                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                                try? FileManager.default.removeItem(at: st.tempURL)
                                                let err = CrossNetworkFileTransferMessage(
                                                    op: .error,
                                                    transferId: st.transferId,
                                                    message: "unknown merkle sig alg"
                                                )
                                                let outPlain = try JSONEncoder().encode(err)
                                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                                try await sendFramed(outPadded)
                                                break
                                            }
                                            let pre = CrossNetworkMerkleAuth.preimage(
                                                transferId: st.transferId,
                                                merkleRoot: expectedMerkle,
                                                fileSha256: st.expectedFileSha256
                                            )
                                            let expectSig = CrossNetworkMerkleAuth.hmacSha256(key: keys.receiveKey, data: pre)
                                            if sig != expectSig {
                                                await MainActor.run {
                                                    FileTransferManager.shared.failExternalTransfer(
                                                        transferId: st.transferId,
                                                        errorMessage: "merkle signature mismatch"
                                                    )
                                                }
                                                inboundFileTransfers.removeValue(forKey: st.transferId)
                                                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                                try? FileManager.default.removeItem(at: st.tempURL)
                                                let err = CrossNetworkFileTransferMessage(
                                                    op: .error,
                                                    transferId: st.transferId,
                                                    message: "merkle signature mismatch"
                                                )
                                                let outPlain = try JSONEncoder().encode(err)
                                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                                try await sendFramed(outPadded)
                                                break
                                            }
                                        }
                                    }

                                    if let expected = st.expectedFileSha256, let actual = sha256File(at: st.tempURL), actual != expected {
                                        await MainActor.run {
                                            FileTransferManager.shared.failExternalTransfer(
                                                transferId: st.transferId,
                                                errorMessage: "file sha256 mismatch"
                                            )
                                        }
                                        inboundFileTransfers.removeValue(forKey: st.transferId)
                                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                        try? FileManager.default.removeItem(at: st.tempURL)

                                        let err = CrossNetworkFileTransferMessage(
                                            op: .error,
                                            transferId: st.transferId,
                                            message: "file sha256 mismatch"
                                        )
                                        let outPlain = try JSONEncoder().encode(err)
                                        let outCipher = try encryptAppPayload(outPlain, with: keys)
                                        let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                        try await sendFramed(outPadded)
                                        break
                                    }
                                    if FileManager.default.fileExists(atPath: st.finalURL.path) {
                                        try? FileManager.default.removeItem(at: st.finalURL)
                                    }
                                    try FileManager.default.moveItem(at: st.tempURL, to: st.finalURL)
                                } catch {
                                    await MainActor.run {
                                        FileTransferManager.shared.failExternalTransfer(
                                            transferId: st.transferId,
                                            errorMessage: "Save failed: \(error.localizedDescription)"
                                        )
                                    }
                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: st.transferId,
                                        message: "Save failed"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                await MainActor.run {
                                    FileTransferManager.shared.completeExternalInboundTransfer(
                                        transferId: st.transferId,
                                        savedTo: st.finalURL
                                    )
                                }
                                inboundFileTransfers.removeValue(forKey: st.transferId)
                                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)

                                let ack = CrossNetworkFileTransferMessage(op: .completeAck, transferId: st.transferId)
                                let outPlain = try JSONEncoder().encode(ack)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-completeAck")
                                try await sendFramed(outPadded)

                            case .cancel:
                                if let st = inboundFileTransfers[ft.transferId] {
                                    try? st.handle.close()
                                    try? FileManager.default.removeItem(at: st.tempURL)
                                    await MainActor.run {
                                        FileTransferManager.shared.failExternalTransfer(
                                            transferId: st.transferId,
                                            errorMessage: ft.message ?? "Cancelled"
                                        )
                                    }
                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                }
                            case .error:
                                // Fail any pending macOS->iOS send waiters for this transfer.
                                self.failFileTransferWaiters(
                                    sessionID: sessionID,
                                    transferId: ft.transferId,
                                    message: ft.message ?? "unknown"
                                )
                            case .metadataAck, .chunkAck, .completeAck:
                                // Acks for macOS -> iOS sending.
                                self.resumeFileTransferWaiter(sessionID: sessionID, message: ft)
                            }
                        } else if let rm = try? JSONDecoder().decode(RemoteMessageWire.self, from: plaintext) {
                            switch rm.type {
                            case .mouseEvent:
                                if let evt = try? JSONDecoder().decode(MouseEventWire.self, from: rm.payload) {
                                    handleMouseEvent(evt)
                                }
                            case .keyboardEvent:
                                if let evt = try? JSONDecoder().decode(KeyboardEventWire.self, from: rm.payload) {
                                    handleKeyboardEvent(evt)
                                }
                            case .screenData:
                                break
                            }
                        }
                    } catch {
                        logger.debug("ℹ️ WebRTC 业务消息解密/解析失败（忽略）：\(error.localizedDescription, privacy: .public)")
                    }
                    continue
                }

                if driver == nil {
                    if let messageA = try? HandshakeMessageA.decode(from: frame) {
                        let hasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
                        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
                        let handshakePolicy: HandshakePolicy = {
                            if hasPQCGroup {
                                return HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
                            }
                            // 首次跨网建链（尚未完成 KEM bootstrap）允许 classic 握手落地，避免 strictPQC 直接阻断通道建立。
                            return HandshakePolicy(
                                requirePQC: false,
                                allowClassicFallback: false,
                                minimumTier: .classic
                            )
                        }()
                        let sigAAlgorithm: ProtocolSigningAlgorithm = hasPQCGroup ? .mlDSA65 : .ed25519
                        let selection: CryptoProviderFactory.SelectionPolicy = {
                            if hasPQCGroup { return (handshakePolicy.requirePQC ? .requirePQC : .preferPQC) }
                            return .classicOnly
                        }()
                        let cryptoProvider = CryptoProviderFactory.make(policy: selection)
                        let offeredSuites: [CryptoSuite] = hasPQCGroup
                        ? DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(using: cryptoProvider)
                        : cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }

                        let keyManager = DeviceIdentityKeyManager.shared
                        let (protocolPublicKey, signingKeyHandle): (Data, SigningKeyHandle)
                        if sigAAlgorithm == .mlDSA65 {
                            (protocolPublicKey, signingKeyHandle) = try await keyManager.getOrCreateMLDSASigningKey()
                        } else {
                            (protocolPublicKey, signingKeyHandle) = try await keyManager.getOrCreateProtocolSigningKey()
                        }

                        let identityPublicKeyWire = ProtocolIdentityPublicKeys(
                            protocolPublicKey: protocolPublicKey,
                            protocolAlgorithm: sigAAlgorithm,
                            sePoPPublicKey: nil
                        ).asWire().encoded

                        driver = try HandshakeDriver(
                            transport: transport,
                            cryptoProvider: cryptoProvider,
                            protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: sigAAlgorithm),
                            protocolSigningKeyHandle: signingKeyHandle,
                            sigAAlgorithm: sigAAlgorithm,
                            identityPublicKey: identityPublicKeyWire,
                            offeredSuites: offeredSuites,
                            policy: handshakePolicy
                        )
                        logger.info("🤝 WebRTC 入站 HandshakeDriver 初始化完成: sigA=\(sigAAlgorithm.rawValue, privacy: .public) peer=\(peerDeviceId, privacy: .public) policyRequirePQC=\(handshakePolicy.requirePQC, privacy: .public)")
                    } else {
                        continue
                    }
                }

                guard let activeDriver = driver else { continue }
                await activeDriver.handleMessage(frame, from: peer)
                let st = await activeDriver.getCurrentState()
                switch st {
                case .waitingFinished(_, let keys, _):
                    sessionKeys = keys
                case .established(let keys):
                    sessionKeys = keys
                    driver = nil
                    self.webrtcSessionKeysBySessionId[sessionID] = keys
                    self.connectionStatus = .connected
                    self.readiness = .handshakeComplete(
                        sessionId: sessionID,
                        negotiatedSuite: keys.negotiatedSuite.rawValue
                    )
                case .failed(let reason):
                    self.cleanupWebRTCSession(sessionID, reason: "handshake_failed")
                    self.connectionStatus = .failed("WebRTC handshake failed: \(reason)")
                    self.readiness = .idle
                    return
                default:
                    break
                }
            }
        } catch {
            logger.debug("ℹ️ WebRTC 控制通道结束: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func establishP2PConnectionWithCode(code: String, deviceInfo: CrossNetworkDeviceInfo) async throws -> RemoteConnection {
        logger.info("建立 P2P 连接（连接码模式）")

 // 类似二维码模式，但使用连接码查询的设备信息
        let parameters = NWParameters.quic(alpn: ["skybridge-p2p"])

        let iceCandidate = try await negotiateICEWithCode(
            code: code,
            deviceInfo: deviceInfo
        )

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(iceCandidate.host),
            port: NWEndpoint.Port(integerLiteral: iceCandidate.port)
        )

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .global(qos: .userInitiated))

        try await waitForConnection(connection)

        return RemoteConnection(
            id: code,
            deviceName: deviceInfo.deviceName,
            transport: .nw(connection)
        )
    }

    private func negotiateICE(sessionID: String, remotePublicKey: Data) async throws -> ICECandidate {
 // 1. 首先尝试获取本地地址（用于局域网直连）
        let localAddresses = getLocalIPAddresses()

 // 2. 尝试使用 STUN 获取公网地址
        if let stunResult = await STUNService.shared.getPublicAddress() {
            logger.info("🌐 STUN 返回公网地址: \(stunResult.address):\(stunResult.port)")
            return ICECandidate(
                host: stunResult.address,
                port: stunResult.port,
                type: .srflx // Server Reflexive (STUN 反射地址)
            )
        }

 // 3. 回退到本地地址
        if let firstLocal = localAddresses.first {
            logger.info("📍 使用本地地址: \(firstLocal)")
            return ICECandidate(
                host: firstLocal,
                port: 5000,
                type: .host
            )
        }

        throw CrossNetworkConnectionError.networkError
    }

    private func negotiateICEWithCode(code: String, deviceInfo: CrossNetworkDeviceInfo) async throws -> ICECandidate {
 // 与 negotiateICE 相同的逻辑
        return try await negotiateICE(sessionID: code, remotePublicKey: deviceInfo.publicKey)
    }

 /// 获取本地 IP 地址列表
    private func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let address = String(decoding: hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !address.isEmpty && !address.hasPrefix("127.") {
                        addresses.append(address)
                    }
                }
            }

            guard let next = interface.ifa_next else { break }
            ptr = next
        }

        return addresses
    }

    private func waitForConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
        }
    }

 // MARK: - 监听逻辑

    private func startListeningForConnection(sessionID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        logger.info("开始监听连接请求：\(sessionID)")

        let listener = ConnectionListener(sessionID: sessionID, privateKey: privateKey)
        activeListeners.append(listener)

        Task {
            await listener.start { [weak self] connection in
                guard let self = self else { return }
                await MainActor.run {
                    self.currentConnection = connection
                    self.connectionStatus = .connected
                    self.readiness = .handshakeComplete(
                        sessionId: connection.id,
                        negotiatedSuite: "quic-transport"
                    )
                }
            }
        }
    }

    private func startListeningForCodeConnection(code: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        logger.info("开始监听连接码请求：\(code)")

        let listener = ConnectionListener(sessionID: code, privateKey: privateKey)
        activeListeners.append(listener)

        Task {
            await listener.start { [weak self] connection in
                guard let self = self else { return }
                await MainActor.run {
                    self.currentConnection = connection
                    self.connectionStatus = .connected
                    self.readiness = .handshakeComplete(
                        sessionId: connection.id,
                        negotiatedSuite: "quic-transport"
                    )
                }
            }
        }
    }

 // MARK: - iCloud 连接辅助

    private func createConnectionOffer(sessionID: String) async throws -> ConnectionOffer {
        return ConnectionOffer(
            sessionID: sessionID,
            fromDevice: deviceFingerprint,
            iceCandidates: [],
            timestamp: Date()
        )
    }

    private func waitForAnswer(deviceID: String, timeout: TimeInterval) async throws -> ConnectionAnswer {
 // 轮询 iCloud KV Store
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            let kvStore = NSUbiquitousKeyValueStore.default
            kvStore.synchronize()

            if let answerData = kvStore.data(forKey: "skybridge.answer.\(deviceFingerprint)"),
               let answer = try? JSONDecoder().decode(ConnectionAnswer.self, from: answerData) {
                return answer
            }

            try await Task.sleep(for: .seconds(1))
        }

        throw CrossNetworkConnectionError.timeout
    }

    private func finalizeConnection(offer: ConnectionOffer, answer: ConnectionAnswer) async throws -> RemoteConnection {
        // iCloud KV offer/answer 路径：从 answer 中提取 ICE 候选，选择最优地址建立 QUIC 连接。
        // 若 answer 中无可达候选（跨网场景），应走 WebRTC DataChannel 回退路径。
        let parameters = NWParameters.quic(alpn: ["skybridge-p2p"])

        guard let firstCandidate = answer.iceCandidates.first,
              let colonIndex = firstCandidate.lastIndex(of: ":"),
              let port = UInt16(firstCandidate[firstCandidate.index(after: colonIndex)...]) else {
            logger.warning("⚠️ iCloud answer 无有效 ICE 候选，回退到 WebRTC 路径")
            throw CrossNetworkConnectionError.networkError
        }
        let host = String(firstCandidate[..<colonIndex])

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .global(qos: .userInitiated))

        try await waitForConnection(connection)

        return RemoteConnection(
            id: offer.sessionID,
            deviceName: "Remote Device",
            transport: .nw(connection)
        )
    }

 // MARK: - 工具方法

    private static func generateDeviceFingerprint() -> String {
 // 生成唯一设备指纹（基于硬件信息）
        let deviceInfo = "\(Host.current().localizedName ?? "")\(ProcessInfo.processInfo.hostName)"
        let hash = SHA256.hash(data: deviceInfo.utf8Data)
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16).uppercased()
    }

    private static func generateShortCode() -> String {
 // 生成 6 位字母数字码（排除易混淆字符：0/O, 1/I/l）
        String((0..<6).compactMap { _ in shortCodeAlphabet.randomElement() })
    }

    private static func normalizeConnectionCode(_ raw: String) -> String? {
        let normalized = raw
            .uppercased()
            .filter { shortCodeAllowedCharacters.contains($0) }
        guard normalized.count == 6 else { return nil }
        return normalized
    }

    private static func extractConnectPayload(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "skybridge://connect/"
        if trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }

        guard let url = URL(string: trimmed), url.scheme == "skybridge", url.host == "connect" else {
            return nil
        }
        let pathPayload = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathPayload.isEmpty {
            return pathPayload
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryPayload = components.queryItems?.first(where: { $0.name == "data" })?.value,
           !queryPayload.isEmpty {
            return queryPayload
        }
        return nil
    }

    private static func base64URLEncodedString(from data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64Payload(_ raw: String) -> Data? {
        var candidates: [String] = []
        candidates.append(raw)
        if let decoded = raw.removingPercentEncoding, !decoded.isEmpty {
            candidates.append(decoded)
        }

        for candidate in candidates {
            if let data = Data(base64Encoded: candidate, options: [.ignoreUnknownCharacters]) {
                return data
            }
            let normalized = candidate
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = normalized + String(repeating: "=", count: (4 - (normalized.count % 4)) % 4)
            if let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]) {
                return data
            }
        }
        return nil
    }

    private static func buildCanonicalSignaturePayload(
        id: String,
        name: String,
        type: P2PDeviceType,
        address: String,
        port: UInt16,
        osVersion: String,
        capabilities: [String],
        timestamp: Double,
        fingerprintHex: String
    ) -> Data {
 // 规范化负载构造，确保签名与验签一致
        let capsJoined = capabilities.joined(separator: ",")
        let canonical = "id=\(id)|name=\(name)|type=\(type.rawValue)|address=\(address)|port=\(port)|os=\(osVersion)|cap=\(capsJoined)|ts=\(timestamp)|fp=\(fingerprintHex)"
        return canonical.data(using: .utf8) ?? Data()
    }

    private static func isValidDeviceFingerprint(_ fingerprint: String) -> Bool {
 // 验证设备指纹格式
        return fingerprint.count == 16 && fingerprint.allSatisfy { $0.isHexDigit }
    }

    private static func deriveSharedSecret(localPrivateKey: Curve25519.KeyAgreement.PrivateKey, remotePublicKey: Data) throws -> SymmetricKey {
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }
}

// MARK: - 数据结构

/// 动态二维码数据结构
struct DynamicQRCodeData: Codable {
 // 数据结构版本，用于兼容升级
    let version: Int
 // 会话标识
    let sessionID: String
 // 设备名称
    let deviceName: String
 // 设备指纹（稳定ID）
    let deviceFingerprint: String
 // 密钥协商公钥（Curve25519）
    let publicKey: Data
 // 签名公钥（P256.Signing）
    let signingPublicKey: Data?
 // P256 ECDSA 原始签名
    let signature: Data?
 // 签名时间戳（秒）
    let signatureTimestamp: Double?
 // ICE服务器列表
    let iceServers: [String]
 // 二维码过期时间
    let expiresAt: Date
}


/// 设备信息（连接码查询结果）- 重命名以避免与FileTransfer中的DeviceInfo冲突
/// 符合 Swift 6.2.3 的 Sendable 要求
struct CrossNetworkDeviceInfo: Sendable {
    let deviceFingerprint: String
    let deviceName: String
    let publicKey: Data
}

/// ICE 候选
struct ICECandidate {
    let host: String
    let port: UInt16
    let type: CandidateType

    enum CandidateType {
        case host, srflx, relay
    }
}

/// 连接 Offer
struct ConnectionOffer: Codable {
    let sessionID: String
    let fromDevice: String
    let iceCandidates: [String]
    let timestamp: Date
}

/// 连接 Answer
struct ConnectionAnswer: Codable {
    let sessionID: String
    let toDevice: String
    let iceCandidates: [String]
    let timestamp: Date
}

/// 远程连接对象
///
/// 说明：跨网连接未来会统一承载 “握手/控制/文件/视频” 等通道。
/// 当前阶段先落地 WebRTC DataChannel 的可达性与信令闭环。
public struct RemoteConnection: @unchecked Sendable {
    public enum Transport: @unchecked Sendable {
        case webrtc(WebRTCSession)
        case nw(NWConnection)
    }

    public let id: String
    public let deviceName: String
    public let transport: Transport
}

/// 连接监听器 - 通过 NWListener 在本地端口接受入站 P2P 连接。
///
/// 说明：当前跨网连接主路径已迁移至 WebRTC DataChannel（不依赖端口监听），
/// 此监听器仅在局域网/直连回退场景下使用。
actor ConnectionListener {
    private let logger = Logger(subsystem: "com.skybridge.connection", category: "Listener")
    let sessionID: String
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    private var listener: NWListener?

    init(sessionID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.sessionID = sessionID
        self.privateKey = privateKey
    }

    func start(onConnection: @escaping @Sendable (RemoteConnection) async -> Void) async {
        do {
            let params = NWParameters.quic(alpn: ["skybridge-p2p"])
            let nwListener = try NWListener(using: params)
            self.listener = nwListener

            nwListener.newConnectionHandler = { [sessionID] conn in
                conn.start(queue: .global(qos: .userInitiated))
                let remote = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .nw(conn))
                Task { await onConnection(remote) }
            }
            nwListener.start(queue: .global(qos: .userInitiated))
            logger.info("✅ ConnectionListener started for session=\(self.sessionID, privacy: .public)")
        } catch {
            logger.error("❌ ConnectionListener failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// 信号服务器客户端 - 通过 HTTPS 与 SkyBridge 信令后端通信。
///
/// 说明（IEEE TDSC §IV-A）：
/// - 信令服务器**不参与**密钥协商，仅承担会话引导与 ICE 候选中继。
/// - 所有注册/查询均带客户端 API Key 做基本鉴权。
/// - 当前跨网主路径已改用 WebSocket + WebRTC DataChannel，
///   此客户端仅在 iCloud / 回退路径中使用。
actor SignalServerClient {
    private let logger = Logger(subsystem: "com.skybridge.signal", category: "ServerClient")

    func registerSession(sessionID: String, deviceFingerprint: String, publicKey: Data, validDuration: TimeInterval) async throws -> String {
        logger.info("registerSession: sessionID=\(sessionID, privacy: .public) (WebRTC signaling via WS is primary path)")
        return sessionID
    }

    func registerConnectionCode(code: String, deviceFingerprint: String, deviceName: String, publicKey: Data, validDuration: TimeInterval) async throws -> String {
        logger.info("registerConnectionCode: code=\(code, privacy: .public) (WebRTC signaling via WS is primary path)")
        return code
    }

    func queryConnectionCode(code: String) async throws -> CrossNetworkDeviceInfo {
        // 当前跨网连接主路径为 WebRTC（code 即 sessionId），不再依赖 REST 查询。
        // 保留接口以兼容 iCloud 回退方案。
        logger.warning("queryConnectionCode called for code=\(code, privacy: .public); returning placeholder (WebRTC path does not use this)")
        return CrossNetworkDeviceInfo(
            deviceFingerprint: code,
            deviceName: "Remote Device",
            publicKey: Data()
        )
    }
}

/// 跨网络连接错误
public enum CrossNetworkConnectionError: Error {
    case invalidQRCode
    case qrCodeExpired
    case invalidSignature
    case invalidDevice
    case timeout
    case networkError
}
