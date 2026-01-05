//
// iOSP2PSessionManager.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Session Manager
// Requirements: 2.1, 2.2, 4.1
//
// 统一管理 iOS P2P 会话生命周期：
// 1. 配对（QR 码 / 6 位码 PAKE）
// 2. 会话认证
// 3. 逻辑通道复用
//

import Foundation
import CryptoKit
import Network

// MARK: - Session State

/// 会话状态
public enum P2PSessionState: String, Sendable {
    case idle = "idle"
    case pairing = "pairing"
    case authenticating = "authenticating"
    case connected = "connected"
    case reconnecting = "reconnecting"
    case disconnecting = "disconnecting"
    case failed = "failed"
}

// MARK: - Session Error

/// 会话错误
public enum P2PSessionError: Error, LocalizedError, Sendable {
    case invalidState(String)
    case pairingFailed(String)
    case authenticationFailed(String)
    case connectionFailed(String)
    case handshakeFailed(String)
    case certificateRejected(String)
    case identityMismatch
    case replayDetected
    case timeout
    case deviceNotFound
    case alreadyConnected
    case notConnected
    
    public var errorDescription: String? {
        switch self {
        case .invalidState(let reason):
            return "Invalid session state: \(reason)"
        case .pairingFailed(let reason):
            return "Pairing failed: \(reason)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .handshakeFailed(let reason):
            return "Handshake failed: \(reason)"
        case .certificateRejected(let reason):
            return "Certificate rejected: \(reason)"
        case .identityMismatch:
            return "Identity mismatch"
        case .replayDetected:
            return "Replay attack detected"
        case .timeout:
            return "Operation timed out"
        case .deviceNotFound:
            return "Device not found"
        case .alreadyConnected:
            return "Already connected to a device"
        case .notConnected:
            return "Not connected to any device"
        }
    }
}

// MARK: - QR Code Data

/// QR 码数据
public struct P2PQRCodeData: Codable, Sendable, TranscriptEncodable {
 /// 设备 ID
    public let deviceId: String
    
 /// 公钥指纹 (SHA-256 hex, 64 chars)
    public let pubKeyFP: String
    
 /// 挑战值
    public let challenge: Data
    
 /// Nonce
    public let nonce: Data
    
 /// 过期时间
    public let expiresAt: Date
    
 /// 协议版本
    public let version: Int
    
 /// 加密能力
    public let cryptoCapabilities: P2PCryptoCapabilities
    
    public init(
        deviceId: String,
        pubKeyFP: String,
        challenge: Data,
        nonce: Data,
        expiresAt: Date,
        version: Int = P2PProtocolVersion.current.rawValue,
        cryptoCapabilities: P2PCryptoCapabilities
    ) {
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.challenge = challenge
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.version = version
        self.cryptoCapabilities = cryptoCapabilities
    }
    
 /// 是否已过期
    public var isExpired: Bool {
        Date() > expiresAt
    }
    
 /// 确定性编码
    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(deviceId)
        encoder.encode(pubKeyFP)
        encoder.encode(challenge)
        encoder.encode(nonce)
        encoder.encode(expiresAt)
        encoder.encode(Int64(version))
        let capData = try cryptoCapabilities.deterministicEncode()
        encoder.encode(capData)
        return encoder.finalize()
    }
}

// MARK: - Crypto Capabilities

/// 加密能力声明
public struct P2PCryptoCapabilities: Codable, Sendable, TranscriptEncodable {
 /// 支持的 KEM 算法
    public let supportedKEM: [String]
    
 /// 支持的签名算法（身份签名；长期 P-256，独立于 KEM/套件）
    public let supportedSignature: [String]
    
 /// 支持的认证配置（Classic/PQC/Hybrid）
    public let supportedAuthProfiles: [String]
    
 /// 支持的 AEAD 算法
    public let supportedAEAD: [String]
    
 /// PQC 是否可用
    public let pqcAvailable: Bool
    
 /// 平台版本
    public let platformVersion: String
    
    public init(
        supportedKEM: [String] = ["X25519"],
        supportedSignature: [String] = ["P-256"],
        supportedAuthProfiles: [String] = [AuthProfile.classic.displayName],
        supportedAEAD: [String] = ["AES-256-GCM", "ChaCha20-Poly1305"],
        pqcAvailable: Bool = false,
        platformVersion: String = ""
    ) {
        self.supportedKEM = supportedKEM
        self.supportedSignature = supportedSignature
        self.supportedAuthProfiles = supportedAuthProfiles
        self.supportedAEAD = supportedAEAD
        self.pqcAvailable = pqcAvailable
        self.platformVersion = platformVersion
    }
    
 /// 获取当前设备的加密能力
    public static func current() -> P2PCryptoCapabilities {
        var kem = ["X25519"]
        var sig = ["P-256"]
        var authProfiles = [AuthProfile.classic.displayName]
        var pqc = false
        
        if #available(iOS 26.0, macOS 26.0, *) {
            kem = ["X-Wing", "ML-KEM-768", "X25519"]
            sig = ["P-256"]
            authProfiles = [
                AuthProfile.hybrid.displayName,
                AuthProfile.pqc.displayName,
                AuthProfile.classic.displayName
            ]
            pqc = true
        }
        
        #if os(iOS)
        let platform = "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #elseif os(macOS)
        let platform = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        let platform = "Unknown"
        #endif
        
        return P2PCryptoCapabilities(
            supportedKEM: kem,
            supportedSignature: sig,
            supportedAuthProfiles: authProfiles,
            supportedAEAD: ["AES-256-GCM", "ChaCha20-Poly1305"],
            pqcAvailable: pqc,
            platformVersion: platform
        )
    }
    
 /// 确定性编码
    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(supportedKEM)
        encoder.encode(supportedSignature)
        encoder.encode(supportedAuthProfiles)
        encoder.encode(supportedAEAD)
        encoder.encode(pqcAvailable)
        encoder.encode(platformVersion)
        return encoder.finalize()
    }
}

// MARK: - Negotiated Crypto Profile

/// 协商后的加密配置
public struct P2PNegotiatedCryptoProfile: Codable, Sendable, TranscriptEncodable {
 /// KEM 算法
    public let kemAlgorithm: String
    
 /// 认证配置（Classic/PQC/Hybrid）
    public let authProfile: String
    
 /// 签名算法（兼容字段）
    public let signatureAlgorithm: String
    
 /// 握手阶段使用的 AEAD/密封模式描述
    public let handshakeAeadAlgorithm: String?
    
 /// AEAD 算法
    public let aeadAlgorithm: String
    
 /// QUIC Datagram 是否启用
    public let quicDatagramEnabled: Bool
    
 /// PQC 是否启用
    public let pqcEnabled: Bool
    
    public init(
        kemAlgorithm: String,
        authProfile: String,
        signatureAlgorithm: String,
        handshakeAeadAlgorithm: String? = nil,
        aeadAlgorithm: String,
        quicDatagramEnabled: Bool = true,
        pqcEnabled: Bool = false
    ) {
        self.kemAlgorithm = kemAlgorithm
        self.authProfile = authProfile
        self.signatureAlgorithm = signatureAlgorithm
        self.handshakeAeadAlgorithm = handshakeAeadAlgorithm
        self.aeadAlgorithm = aeadAlgorithm
        self.quicDatagramEnabled = quicDatagramEnabled
        self.pqcEnabled = pqcEnabled
    }
    
 /// 确定性编码
    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(kemAlgorithm)
        encoder.encode(authProfile)
        encoder.encode(signatureAlgorithm)
        encoder.encode(handshakeAeadAlgorithm ?? "")
        encoder.encode(aeadAlgorithm)
        encoder.encode(quicDatagramEnabled)
        encoder.encode(pqcEnabled)
        return encoder.finalize()
    }
    
 /// 从两端能力协商
    public static func negotiate(
        local: P2PCryptoCapabilities,
        remote: P2PCryptoCapabilities
    ) -> P2PNegotiatedCryptoProfile {
 // KEM: 优先选择双方都支持的最强算法
        let kemPriority = ["X-Wing", "ML-KEM-768", "X25519"]
        let kem = kemPriority.first { algo in
            local.supportedKEM.contains(algo) && remote.supportedKEM.contains(algo)
        } ?? "X25519"
        
 // Signature: 身份签名（独立于 KEM/套件）
        let sigPriority = ["P-256"]
        let sig = sigPriority.first { algo in
            local.supportedSignature.contains(algo) && remote.supportedSignature.contains(algo)
        } ?? "P-256"
        
 // AuthProfile: 优先 Hybrid
        let authPriority = [
            AuthProfile.hybrid.displayName,
            AuthProfile.pqc.displayName,
            AuthProfile.classic.displayName
        ]
        let authProfile = authPriority.first { profile in
            local.supportedAuthProfiles.contains(profile) && remote.supportedAuthProfiles.contains(profile)
        } ?? AuthProfile.classic.displayName
        
 // AEAD: 优先 AES-256-GCM
        let aeadPriority = ["AES-256-GCM", "ChaCha20-Poly1305"]
        let aead = aeadPriority.first { algo in
            local.supportedAEAD.contains(algo) && remote.supportedAEAD.contains(algo)
        } ?? "AES-256-GCM"
        
        let handshakeAead: String
        if kem == "X25519" {
            handshakeAead = "HPKE-ChaCha20-Poly1305"
        } else {
            handshakeAead = "AES-256-GCM"
        }
        
        let pqcEnabled = local.pqcAvailable && remote.pqcAvailable &&
            (kem == "X-Wing" || kem == "ML-KEM-768")
        
        return P2PNegotiatedCryptoProfile(
            kemAlgorithm: kem,
            authProfile: authProfile,
            signatureAlgorithm: sig,
            handshakeAeadAlgorithm: handshakeAead,
            aeadAlgorithm: aead,
            quicDatagramEnabled: true,
            pqcEnabled: pqcEnabled
        )
    }
}

// MARK: - Connection Metrics

/// 连接指标
public struct P2PConnectionMetrics: Sendable {
 /// 延迟（毫秒）
    public let latencyMs: Double
    
 /// 带宽（Mbps）
    public let bandwidthMbps: Double
    
 /// 丢包率（百分比）
    public let packetLossPercent: Double
    
 /// 加密模式
    public let encryptionMode: String
    
 /// 协议版本
    public let protocolVersion: String
    
 /// 对端能力
    public let peerCapabilities: [String]
    
 /// PQC 是否启用
    public let pqcEnabled: Bool
    
 /// 时间戳
    public let timestamp: Date
    
    public init(
        latencyMs: Double = 0,
        bandwidthMbps: Double = 0,
        packetLossPercent: Double = 0,
        encryptionMode: String = "",
        protocolVersion: String = "v1",
        peerCapabilities: [String] = [],
        pqcEnabled: Bool = false,
        timestamp: Date = Date()
    ) {
        self.latencyMs = latencyMs
        self.bandwidthMbps = bandwidthMbps
        self.packetLossPercent = packetLossPercent
        self.encryptionMode = encryptionMode
        self.protocolVersion = protocolVersion
        self.peerCapabilities = peerCapabilities
        self.pqcEnabled = pqcEnabled
        self.timestamp = timestamp
    }
}

// MARK: - iOS P2P Session Manager

// 注意：P2PDiscoveredDevice 定义在 P2PDeviceDiscovery.swift 中

/// iOS P2P 会话管理器
///
/// 统一管理 iOS P2P 会话生命周期，包括：
/// - 设备配对（QR 码 / 6 位码 PAKE）
/// - 会话认证
/// - 逻辑通道复用
///
/// Tech Debt Cleanup - 15: 集成 HandshakeDriver
/// Requirements: 4.1, 5.1
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class iOSP2PSessionManager: ObservableObject {
    
 // MARK: - Published Properties
    
 /// 当前会话状态
    @Published public private(set) var state: P2PSessionState = .idle
    
 /// 已连接的设备
    @Published public private(set) var connectedDevice: P2PDiscoveredDevice?
    
 /// 连接指标
    @Published public private(set) var metrics: P2PConnectionMetrics?
    
 /// 协商后的加密配置
    @Published public private(set) var negotiatedCrypto: P2PNegotiatedCryptoProfile?
    
 /// 最后一次错误
    @Published public private(set) var lastError: P2PSessionError?
    
 /// 握手指标（来自 HandshakeDriver）
    @Published public private(set) var handshakeMetrics: HandshakeMetrics?
    
 /// 当前握手策略（由上层决定）
    public var handshakePolicy: HandshakePolicy
    
 // MARK: - Private Properties
    
 /// 传输服务
    private var transport: QUICTransportService?
    
 /// PAKE 服务
    private let pakeService = PAKEService()
    
 /// 证书签发器
    private let certificateIssuer = P2PIdentityCertificateIssuer.shared
    
 /// 密钥管理器
    private let keyManager = DeviceIdentityKeyManager.shared
    
 /// 信任同步服务
    private let trustService = TrustSyncService.shared
    
 /// Transcript 构建器
    private var transcriptBuilder: TranscriptBuilder?
    
 /// 当前 QR 码数据
    private var currentQRData: P2PQRCodeData?
    
 /// 会话密钥（派生后）
    private var sessionKeys: P2PSessionKeys?
    
 /// 重连尝试次数
    private var reconnectAttempts: Int = 0
    
 /// 握手驱动器 ( 15.1)
 /// Requirement 4.1: 使用 HandshakeDriver 替代内联握手逻辑
    private var handshakeDriver: HandshakeDriver?
    
 /// 发现传输层 ( 15.1)
 /// Requirement 5.1: 使用 DiscoveryTransport 发送消息
    private var discoveryTransport: (any DiscoveryTransport)?
    
 /// PAKE 响应 continuation ( 1.2)
 /// Requirements: 1.2 - 用于等待 PAKE messageB 响应
    private var pakeResponseContinuation: CheckedContinuation<Data, Error>?
    
 /// PAKE 超时时间（秒）
    private static let pakeTimeoutSeconds: TimeInterval = 30
    
 // MARK: - Initialization
    
    public init(handshakePolicy: HandshakePolicy = .default) {
        self.handshakePolicy = handshakePolicy
    }
    
 // MARK: - Pairing Methods
    
 /// 生成配对 QR 码
 /// - Returns: QR 码数据
    public func generatePairingQRCode() async throws -> P2PQRCodeData {
        guard state == .idle || state == .failed else {
            throw P2PSessionError.invalidState("Cannot generate QR code in state: \(state)")
        }
        
        state = .pairing
        lastError = nil
        
        do {
 // 获取本机身份
            let keyInfo = try await keyManager.getOrCreateIdentityKey()
            
 // 生成挑战和 nonce
 // 19.1: Type C force unwrap handling (Requirements 9.1, 9.2)
            let challenge = Self.generateSecureRandomData(count: P2PConstants.challengeSize, context: "challenge")
            let nonce = Self.generateSecureRandomData(count: P2PConstants.nonceSize, context: "nonce")
            
 // 计算过期时间
            let expiresAt = Date().addingTimeInterval(P2PConstants.qrCodeExpirationSeconds)
            
 // 获取加密能力
            let capabilities = P2PCryptoCapabilities.current()
            
            let qrData = P2PQRCodeData(
                deviceId: keyInfo.deviceId,
                pubKeyFP: keyInfo.pubKeyFP,
                challenge: challenge,
                nonce: nonce,
                expiresAt: expiresAt,
                cryptoCapabilities: capabilities
            )
            
            currentQRData = qrData
            
            SkyBridgeLogger.p2p.info("Generated pairing QR code, expires: \(expiresAt)")
            return qrData
            
        } catch {
            state = .failed
            let sessionError = P2PSessionError.pairingFailed(error.localizedDescription)
            lastError = sessionError
            throw sessionError
        }
    }
    
 /// 使用 6 位码配对（PAKE）
 /// - Parameters:
 /// - code: 6 位配对码
 /// - device: 目标设备
    public func pairWithCode(_ code: String, device: P2PDiscoveredDevice) async throws {
        guard state == .idle || state == .failed else {
            throw P2PSessionError.invalidState("Cannot pair in state: \(state)")
        }
        
        guard code.count == P2PConstants.pairingCodeLength else {
            throw P2PSessionError.pairingFailed("Invalid pairing code length")
        }
        
        state = .pairing
        lastError = nil
        
        do {
 // 初始化 transcript
            transcriptBuilder = TranscriptBuilder(role: .initiator)
            
 // 发起 PAKE 交换
            let messageA = try await pakeService.initiateExchange(
                password: code,
                peerId: device.deviceId
            )
            
 // 添加到 transcript
            try transcriptBuilder?.append(message: messageA, type: .pairingPAKEMessageA)
            
 // 1.1: 通过发现服务发送 messageA 并等待 messageB
 // Requirements: 1.1, 1.2
            let messageAData = try JSONEncoder().encode(messageA)
            try await completePAKEExchange(messageAData: messageAData, device: device)
            
            SkyBridgeLogger.p2p.info("PAKE exchange completed with device: \(device.deviceId)")
            
 // 继续连接流程
            try await connect(to: device)
            
        } catch {
            state = .failed
            let sessionError = P2PSessionError.pairingFailed(error.localizedDescription)
            lastError = sessionError
            throw sessionError
        }
    }
    
 /// 扫描 QR 码配对
 /// - Parameters:
 /// - qrData: QR 码数据
 /// - device: 目标设备
    public func pairWithQRCode(_ qrData: P2PQRCodeData, device: P2PDiscoveredDevice) async throws {
        guard state == .idle || state == .failed else {
            throw P2PSessionError.invalidState("Cannot pair in state: \(state)")
        }
        
 // 验证 QR 码未过期
        guard !qrData.isExpired else {
            throw P2PSessionError.pairingFailed("QR code has expired")
        }
        
 // 验证设备 ID 匹配
        guard qrData.deviceId == device.deviceId else {
            throw P2PSessionError.pairingFailed("Device ID mismatch")
        }
        
        state = .pairing
        lastError = nil
        
        do {
 // 初始化 transcript
            transcriptBuilder = TranscriptBuilder(role: .responder)
            
 // 添加 QR 数据到 transcript
            try transcriptBuilder?.append(message: qrData, type: .pairingQRData)
            
 // 获取本机证书（确保证书已创建，用于后续握手）
            _ = try await certificateIssuer.getOrCreateLocalCertificate()
            
 // 协商加密配置
            let localCapabilities = P2PCryptoCapabilities.current()
            let profile = P2PNegotiatedCryptoProfile.negotiate(
                local: localCapabilities,
                remote: qrData.cryptoCapabilities
            )
            
            negotiatedCrypto = profile
            
 // 添加协商结果到 transcript
            try transcriptBuilder?.append(message: profile, type: .negotiatedProfile)
            
            SkyBridgeLogger.p2p.info("QR code pairing initiated, crypto: \(profile.kemAlgorithm)")
            
 // 继续连接流程
            try await connect(to: device)
            
        } catch {
            state = .failed
            let sessionError = P2PSessionError.pairingFailed(error.localizedDescription)
            lastError = sessionError
            throw sessionError
        }
    }
    
 // MARK: - PAKE Exchange Methods ( 1)
    
 /// 完成 PAKE 交换 - 发送 messageA 并等待 messageB
 /// 1.1: Requirements 1.1, 1.2
 /// - Parameters:
 /// - messageAData: 编码后的 PAKE messageA
 /// - device: 目标设备
    private func completePAKEExchange(
        messageAData: Data,
        device: P2PDiscoveredDevice
    ) async throws {
 // 获取或创建 DiscoveryTransport
        let transport = await getOrCreateDiscoveryTransport()
        
 // 创建对端标识
        let peer = PeerIdentifier(
            deviceId: device.deviceId,
            address: device.endpoint.debugDescription
        )
        
 // 发送 messageA
        try await transport.send(to: peer, data: messageAData)
        SkyBridgeLogger.p2p.debug("Sent PAKE messageA to \(device.deviceId)")
        
 // 等待 messageB（带超时）
 // 1.4: Requirements 1.4 - 超时处理
        let messageB: Data
        do {
            messageB = try await withThrowingTaskGroup(of: Data.self) { group in
 // 等待响应任务
                group.addTask {
                    try await self.awaitPAKEResponse(from: peer)
                }
                
 // 超时任务
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.pakeTimeoutSeconds * 1_000_000_000))
                    throw P2PSessionError.timeout
                }
                
 // 返回第一个完成的结果
                guard let result = try await group.next() else {
                    throw P2PSessionError.timeout
                }
                
 // 取消其他任务
                group.cancelAll()
                return result
            }
        } catch {
 // 1.4: 超时时发射 SecurityEvent
            if case P2PSessionError.timeout = error {
                SecurityEventEmitter.emitDetached(SecurityEvent(
                    type: .handshakeFailed,
                    severity: .warning,
                    message: "PAKE exchange timeout",
                    context: [
                        "deviceId": device.deviceId,
                        "timeout": String(Self.pakeTimeoutSeconds)
                    ]
                ))
                state = .failed
                lastError = .timeout
            }
            throw error
        }
        
 // 解码 messageB
        let pakeMessageB = try JSONDecoder().decode(PAKEMessageB.self, from: messageB)
        
 // 添加到 transcript
        try transcriptBuilder?.append(message: pakeMessageB, type: .pairingPAKEMessageB)
        
 // 完成 PAKE 交换并获取共享密钥
        let sharedSecret = try await pakeService.completeExchange(
            messageB: pakeMessageB,
            peerId: device.deviceId
        )
        
 // 派生会话密钥
        try await deriveSessionKeysFromPAKE(sharedSecret: sharedSecret)
        
        SkyBridgeLogger.p2p.info("PAKE exchange completed, session keys derived")
    }
    
 /// 等待 PAKE 响应
 /// 1.2: Requirements 1.2 - 使用 CheckedContinuation 等待响应
 /// - Parameter peer: 对端标识
 /// - Returns: PAKE messageB 数据
    private func awaitPAKEResponse(from peer: PeerIdentifier) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
 // 设置 continuation，handleControlMessage 会在收到 messageB 时 resume
            self.pakeResponseContinuation = continuation
        }
    }
    
 /// 从 PAKE 共享密钥派生会话密钥
 /// - Parameter sharedSecret: PAKE 派生的共享密钥
    private func deriveSessionKeysFromPAKE(sharedSecret: Data) async throws {
        guard let transcriptBuilder = transcriptBuilder else {
            throw P2PSessionError.handshakeFailed("No transcript builder")
        }
        
 // 计算 transcript hash
        let transcriptHash = transcriptBuilder.computeHash()
        
 // 派生各通道密钥（应用层，方向分离）
        let localRole = transcriptBuilder.role.rawValue
        let peerRole = transcriptBuilder.role.peer.rawValue
        
        let controlSendKey = deriveDirectionalKey(
            baseKey: sharedSecret,
            transcriptHash: transcriptHash,
            channel: .control,
            direction: "tx",
            roleLabel: localRole
        )
        let controlReceiveKey = deriveDirectionalKey(
            baseKey: sharedSecret,
            transcriptHash: transcriptHash,
            channel: .control,
            direction: "rx",
            roleLabel: peerRole
        )
        
        let videoSendKey = deriveDirectionalKey(
            baseKey: sharedSecret,
            transcriptHash: transcriptHash,
            channel: .video,
            direction: "tx",
            roleLabel: localRole
        )
        let videoReceiveKey = deriveDirectionalKey(
            baseKey: sharedSecret,
            transcriptHash: transcriptHash,
            channel: .video,
            direction: "rx",
            roleLabel: peerRole
        )
        
        let fileSendKey = deriveDirectionalKey(
            baseKey: sharedSecret,
            transcriptHash: transcriptHash,
            channel: .file,
            direction: "tx",
            roleLabel: localRole
        )
        let fileReceiveKey = deriveDirectionalKey(
            baseKey: sharedSecret,
            transcriptHash: transcriptHash,
            channel: .file,
            direction: "rx",
            roleLabel: peerRole
        )
        
        let finishedSendKey = deriveDirectionalKey(
            baseKey: sharedSecret,
            transcriptHash: transcriptHash,
            channel: .finishedMAC,
            direction: "tx",
            roleLabel: localRole
        )
        let finishedReceiveKey = deriveDirectionalKey(
            baseKey: sharedSecret,
            transcriptHash: transcriptHash,
            channel: .finishedMAC,
            direction: "rx",
            roleLabel: peerRole
        )
        
        sessionKeys = P2PSessionKeys(
            controlSendKey: controlSendKey,
            controlReceiveKey: controlReceiveKey,
            videoSendKey: videoSendKey,
            videoReceiveKey: videoReceiveKey,
            fileSendKey: fileSendKey,
            fileReceiveKey: fileReceiveKey,
            finishedSendKey: finishedSendKey,
            finishedReceiveKey: finishedReceiveKey,
            transcriptHash: transcriptHash
        )
        
        SkyBridgeLogger.p2p.debug("Session keys derived from PAKE shared secret")
    }
    
 // MARK: - Connection Methods
    
 /// 连接到已配对设备
 /// - Parameter device: 目标设备
    public func connect(to device: P2PDiscoveredDevice) async throws {
        guard state == .idle || state == .pairing || state == .failed else {
            throw P2PSessionError.invalidState("Cannot connect in state: \(state)")
        }
        
        if connectedDevice != nil {
            throw P2PSessionError.alreadyConnected
        }
        
        state = .authenticating
        lastError = nil
        reconnectAttempts = 0
        
        do {
 // 验证设备是否受信任
            let trustRecords = await trustService.getActiveTrustRecords()
            let isTrusted = trustRecords.contains { $0.deviceId == device.deviceId }
            
            if !isTrusted {
                SkyBridgeLogger.p2p.warning("Connecting to untrusted device: \(device.deviceId)")
            }
            
 // 创建传输服务
            let transportService = QUICTransportService()
            transport = transportService
            
 // 设置回调
            await transportService.setCallbacks(
                onControl: { [weak self] data in
                    Task { @MainActor in
                        await self?.handleControlMessage(data)
                    }
                },
                onStateChanged: { [weak self] newState in
                    Task { @MainActor in
                        self?.handleTransportStateChange(newState)
                    }
                }
            )
            
 // 建立 QUIC 连接
            try await transportService.connect(to: device.endpoint)
            
 // 执行握手
            try await performHandshake(with: device)
            
 // 连接成功
            state = .connected
            connectedDevice = device
            
 // 开始指标更新
            startMetricsUpdate()
            
            SkyBridgeLogger.p2p.info("Connected to device: \(device.deviceId)")
            
        } catch {
            state = .failed
            transport = nil
            let sessionError = P2PSessionError.connectionFailed(error.localizedDescription)
            lastError = sessionError
            throw sessionError
        }
    }
    
 /// 断开连接
    public func disconnect() async {
        guard state == .connected || state == .reconnecting else {
            return
        }
        
        state = .disconnecting
        
 // 1.2: 取消 PAKE 响应等待（如果存在）
        if let continuation = pakeResponseContinuation {
            continuation.resume(throwing: P2PSessionError.connectionFailed("Disconnected"))
            pakeResponseContinuation = nil
        }
        
 // 15.1: 取消握手驱动器（如果存在）
        if let driver = handshakeDriver {
            await driver.cancel()
            handshakeDriver = nil
        }
        
 // 停止发现传输层
        if let transport = discoveryTransport as? BonjourDiscoveryTransport {
            await transport.stop()
        }
        discoveryTransport = nil
        
        await transport?.disconnect()
        transport = nil
        connectedDevice = nil
        metrics = nil
        sessionKeys = nil
        transcriptBuilder = nil
        handshakeMetrics = nil
        
        state = .idle
        
        SkyBridgeLogger.p2p.info("Disconnected from P2P session")
    }
    
 // MARK: - Handshake
    
 // MARK: - SE PoP Pairing Helper (iOS Handshake Entry Alignment)
    
 /// 加载 SE PoP 成对数据（handle 和 publicKey 必须同时存在或同时为 nil）
 ///
 /// **Requirements: 3.1, 3.2, 3.3, 3.4, 3.5**
 /// - 如果 handle 存在但 publicKey 不存在，视为禁用并发射事件
 /// - 如果 publicKey 存在但 handle 不存在，视为禁用并发射事件
    private func loadSEPoPPair() async -> (handle: SigningKeyHandle?, publicKey: Data?) {
        do {
 // 获取 handle 和 publicKey（独立获取以检测不一致状态）
            let handle = try await keyManager.getSecureEnclaveKeyHandle()
            let publicKey = try await keyManager.getSecureEnclavePublicKey()
            
 // 成对约束检查
            switch (handle, publicKey) {
            case (.some(let h), .some(let pk)):
 // 正常情况：两者都存在
                return (h, pk)
                
            case (.some, .none):
 // Requirement 3.2: handle 存在但 publicKey 不存在
                SkyBridgeLogger.p2p.warning("SE PoP handle exists but public key missing; disabling SE PoP")
                SecurityEventEmitter.emitDetached(SecurityEvent(
                    type: .sePoPInconsistentStateDetected,
                    severity: .warning,
                    message: "SE PoP inconsistent state: handle exists but public key missing",
                    context: ["state": "handle_only"]
                ))
                return (nil, nil)
                
            case (.none, .some):
 // Requirement 3.3: publicKey 存在但 handle 不存在
                SkyBridgeLogger.p2p.warning("SE PoP public key exists but handle missing; disabling SE PoP")
                SecurityEventEmitter.emitDetached(SecurityEvent(
                    type: .sePoPInconsistentStateDetected,
                    severity: .warning,
                    message: "SE PoP inconsistent state: public key exists but handle missing",
                    context: ["state": "pubkey_only"]
                ))
                return (nil, nil)
                
            case (.none, .none):
 // Requirement 3.4: 两者都不存在，SE PoP 禁用
                return (nil, nil)
            }
        } catch {
 // SE PoP 获取失败：降级为禁用（不影响主握手）
            SkyBridgeLogger.p2p.warning("Failed to load SE PoP; disabling SE PoP: \(error.localizedDescription)")
            return (nil, nil)
        }
    }
    
 /// 执行握手协议 (iOS Handshake Entry Alignment)
 ///
 /// **DoD 对齐**:
 /// 1. sigA/sigB 的 keyHandle 来自 `getProtocolSigningKeyHandle(for:)`
 /// 2. identityPublicKey 传入 `ProtocolIdentityPublicKeys.asWire().encoded`
 /// 3. SE PoP 使用成对约束
 /// 4. 使用 `TwoAttemptHandshakeManager.performHandshakeWithPreparation()`
 ///
 /// **Requirements: 1.1-1.5, 2.1-2.5, 3.1-3.5, 4.1-4.7, 5.1-5.5**
    private func performHandshake(with device: P2PDiscoveredDevice) async throws {
 // 可选：确保设备身份初始化（不参与协议签名）
        _ = try await keyManager.getOrCreateIdentityKey()
        
        let policy = handshakePolicy
        let providerPolicy: CryptoProviderFactory.SelectionPolicy = policy.requirePQC ? .requirePQC : .preferPQC
        let cryptoProvider = CryptoProviderFactory.make(policy: providerPolicy)
        
        let preferPQC = policy.minimumTier != .classic
        let sessionKeys = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
            deviceId: device.deviceId,
            preferPQC: preferPQC,
            policy: policy,
            cryptoProvider: cryptoProvider
        ) { [weak self] preparation in
            guard let self else {
                throw HandshakeError.failed(.transportError("iOSP2PSessionManager deallocated"))
            }
            
 // 1) 协议签名密钥（sigA/sigB）：严格按 attempt 的 sigAAlgorithm 取
            let protocolSigningKeyHandle = try await self.keyManager.getProtocolSigningKeyHandle(
                for: preparation.sigAAlgorithm
            )
            let protocolSigningPublicKey = try await self.keyManager.getProtocolSigningPublicKey(
                for: preparation.sigAAlgorithm
            )
            
 // 2) SE PoP（可选）：成对约束
            let sePoP = await self.loadSEPoPPair()
            
 // 3) identityPublicKey：必须是 Wire 编码（不是裸公钥）
            let protocolIdentityKeys = ProtocolIdentityPublicKeys(
                protocolPublicKey: protocolSigningPublicKey,
                protocolAlgorithm: preparation.sigAAlgorithm,
                sePoPPublicKey: sePoP.publicKey
            )
            let identityEncoded: Data = protocolIdentityKeys.asWire().encoded
            
 // 4) transport
            let transport = await self.getOrCreateDiscoveryTransport()
            
 // 5) 发射 SecurityEvent 记录选择的签名算法
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .signatureProviderSelected,
                severity: .info,
                message: "Signature provider selected for MessageA",
                context: [
                    "algorithm": preparation.sigAAlgorithm.rawValue,
                    "offeredSuiteCount": String(preparation.offeredSuites.count),
                    "hasPQCSuite": String(preparation.offeredSuites.contains { $0.isPQCGroup }),
                    "strategy": preparation.strategy.rawValue
                ]
            ))
            
 // 6) driver（每次 attempt 新建）
            let driver = try HandshakeDriver(
                transport: transport,
                cryptoProvider: cryptoProvider,
                protocolSignatureProvider: preparation.signatureProvider,
                protocolSigningKeyHandle: protocolSigningKeyHandle,
                sigAAlgorithm: preparation.sigAAlgorithm,
                identityPublicKey: identityEncoded,
                sePoPSigningKeyHandle: sePoP.handle,
                offeredSuites: preparation.offeredSuites,
                policy: policy,
                timeout: .seconds(Double(P2PConstants.handshakeTimeoutSeconds))
            )
            
            await MainActor.run {
                self.handshakeDriver = driver
            }
            defer {
 // attempt 结束必须清理 driver 引用
                Task { @MainActor in
                    if self.handshakeDriver === driver {
                        self.handshakeDriver = nil
                    }
                }
            }
            
 // 7) message routing（保持现有逻辑：handler → routeHandshakeMessage → driver.handleMessage）
            if let bonjourTransport = transport as? BonjourDiscoveryTransport {
                await bonjourTransport.setMessageHandler { [weak self] (peer: PeerIdentifier, data: Data) in
                    guard let self else { return }
                    await self.routeHandshakeMessage(data, from: peer)
                }
            }
            
 // 8) 发起握手
            let peer = PeerIdentifier(
                deviceId: device.deviceId,
                address: device.endpoint.debugDescription
            )
            return try await driver.initiateHandshake(with: peer)
        }
        
 // 握手成功，处理会话密钥
        try await handleHandshakeSuccess(sessionKeys: sessionKeys, device: device)
    }
    
 /// 处理握手成功后的会话密钥派生和状态更新
 ///
 /// **Requirements: 1.1** - signatureAlgorithm 与实际 attempt 对齐
    private func handleHandshakeSuccess(sessionKeys: SessionKeys, device: P2PDiscoveredDevice) async throws {
 // 握手成功，保存会话密钥（应用层，方向分离）
        let localRole = sessionKeys.role.rawValue
        let peerRole = sessionKeys.role == .initiator ? HandshakeRole.responder.rawValue : HandshakeRole.initiator.rawValue
        
        let controlSendKey = deriveDirectionalKey(
            baseKey: sessionKeys.sendKey,
            transcriptHash: sessionKeys.transcriptHash,
            channel: .control,
            direction: "tx",
            roleLabel: localRole
        )
        let controlReceiveKey = deriveDirectionalKey(
            baseKey: sessionKeys.receiveKey,
            transcriptHash: sessionKeys.transcriptHash,
            channel: .control,
            direction: "rx",
            roleLabel: peerRole
        )
        
        let videoSendKey = deriveDirectionalKey(
            baseKey: sessionKeys.sendKey,
            transcriptHash: sessionKeys.transcriptHash,
            channel: .video,
            direction: "tx",
            roleLabel: localRole
        )
        let videoReceiveKey = deriveDirectionalKey(
            baseKey: sessionKeys.receiveKey,
            transcriptHash: sessionKeys.transcriptHash,
            channel: .video,
            direction: "rx",
            roleLabel: peerRole
        )
        
        let fileSendKey = deriveDirectionalKey(
            baseKey: sessionKeys.sendKey,
            transcriptHash: sessionKeys.transcriptHash,
            channel: .file,
            direction: "tx",
            roleLabel: localRole
        )
        let fileReceiveKey = deriveDirectionalKey(
            baseKey: sessionKeys.receiveKey,
            transcriptHash: sessionKeys.transcriptHash,
            channel: .file,
            direction: "rx",
            roleLabel: peerRole
        )
        
        let finishedSendKey = deriveDirectionalKey(
            baseKey: sessionKeys.sendKey,
            transcriptHash: sessionKeys.transcriptHash,
            channel: .finishedMAC,
            direction: "tx",
            roleLabel: localRole
        )
        let finishedReceiveKey = deriveDirectionalKey(
            baseKey: sessionKeys.receiveKey,
            transcriptHash: sessionKeys.transcriptHash,
            channel: .finishedMAC,
            direction: "rx",
            roleLabel: peerRole
        )
        
        self.sessionKeys = P2PSessionKeys(
            controlSendKey: controlSendKey,
            controlReceiveKey: controlReceiveKey,
            videoSendKey: videoSendKey,
            videoReceiveKey: videoReceiveKey,
            fileSendKey: fileSendKey,
            fileReceiveKey: fileReceiveKey,
            finishedSendKey: finishedSendKey,
            finishedReceiveKey: finishedReceiveKey,
            transcriptHash: sessionKeys.transcriptHash
        )
        
 // 更新协商的加密配置
 // Requirements 1.1: signatureAlgorithm 与实际 attempt 对齐（不再写死 "P-256"）
        let suite = sessionKeys.negotiatedSuite
        let signatureAlgorithm: String
        if suite.isPQCGroup {
            signatureAlgorithm = "ML-DSA-65"
        } else {
            signatureAlgorithm = "Ed25519"
        }
        
        negotiatedCrypto = P2PNegotiatedCryptoProfile(
            kemAlgorithm: suite.rawValue.contains("X-Wing") ? "X-Wing" :
                          suite.rawValue.contains("ML-KEM") ? "ML-KEM-768" : "X25519",
            authProfile: suite.rawValue.contains("X-Wing") ? "Hybrid" : (suite.isPQC ? "PQC" : "Classic"),
            signatureAlgorithm: signatureAlgorithm,
            aeadAlgorithm: "AES-256-GCM",
            quicDatagramEnabled: true,
            pqcEnabled: suite.isPQC
        )
        
 // 获取并保存握手指标
        if let driver = handshakeDriver {
            handshakeMetrics = await driver.getLastMetrics()
        }
        
        SkyBridgeLogger.p2p.info("Handshake completed with \(device.deviceId), suite: \(suite.rawValue)")
    }
    
 /// 获取或创建 DiscoveryTransport ( 15.1)
 /// Requirement 5.1: 使用 DiscoveryTransport 发送消息
    @available(macOS 14.0, *)
    private func getOrCreateDiscoveryTransport() async -> any DiscoveryTransport {
        if let existing = discoveryTransport {
            return existing
        }
        
        let transport = BonjourDiscoveryTransport()
        discoveryTransport = transport
        
 // 启动传输层
        do {
            try await transport.start()
        } catch {
            SkyBridgeLogger.p2p.error("Failed to start discovery transport: \(error.localizedDescription)")
        }
        
        return transport
    }
    
 /// 路由握手消息到 HandshakeDriver ( 15.3)
 /// Requirement 4.1: 将握手消息路由到 HandshakeDriver
    private func routeHandshakeMessage(_ data: Data, from peer: PeerIdentifier) async {
        guard let driver = handshakeDriver else {
            SkyBridgeLogger.p2p.warning("Received handshake message but no driver available")
            return
        }
        
        await driver.handleMessage(data, from: peer)
    }
    
 // MARK: - Message Handling
    
 /// 处理控制消息 ( 15.3, 1.3)
 /// Requirement 4.1: 将握手消息路由到 HandshakeDriver
 /// 1.3: Requirements 1.3 - 路由 PAKE messageB 到 continuation
    private func handleControlMessage(_ data: Data) async {
 // 1.3: 检查是否是 PAKE messageB，如果有等待的 continuation 则 resume
        if state == .pairing, let continuation = pakeResponseContinuation {
 // 尝试解码为 PAKEMessageB
            if let _ = try? JSONDecoder().decode(PAKEMessageB.self, from: data) {
 // 这是 PAKE messageB，resume continuation
                pakeResponseContinuation = nil
                continuation.resume(returning: data)
                SkyBridgeLogger.p2p.debug("Received PAKE messageB, resuming continuation")
                return
            }
        }
        
 // 15.3: 优先路由到 HandshakeDriver（如果存在且处于握手状态）
        if let driver = handshakeDriver, state == .authenticating {
            let peer = PeerIdentifier(
                deviceId: connectedDevice?.deviceId ?? "unknown",
                address: nil
            )
            await driver.handleMessage(data, from: peer)
            return
        }
        
 // 其他控制消息
        SkyBridgeLogger.p2p.debug("Received control message: \(data.count) bytes")
    }
    
 /// HKDF 密钥派生
    private func deriveKey(secret: Data, salt: Data, info: Data) -> Data {
        let key = SymmetricKey(data: secret)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    private func appInfo(channel: P2PHKDFInfo, direction: String, roleLabel: String) -> Data {
        let info = "\(P2PDomainSeparator.keyDerivation.rawValue)|app|\(channel.rawValue)|\(direction)|\(roleLabel)"
        return Data(info.utf8)
    }

    private func deriveDirectionalKey(
        baseKey: Data,
        transcriptHash: Data,
        channel: P2PHKDFInfo,
        direction: String,
        roleLabel: String
    ) -> Data {
        deriveKey(
            secret: baseKey,
            salt: transcriptHash,
            info: appInfo(channel: channel, direction: direction, roleLabel: roleLabel)
        )
    }
    
 /// 计算 Finished MAC
    private func computeFinishedMAC(transcriptHash: Data, key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: transcriptHash, using: symmetricKey)
        return Data(mac)
    }
    
 // MARK: - Certificate Trust Validation
    
 /// 证书信任验证结果
    struct CertificateTrustResult {
        let isTrusted: Bool
        let reason: String
        let trustRecord: TrustRecord?
    }
    
 /// 验证证书是否在信任列表中
 /// - Parameter certificate: 待验证的证书
 /// - Returns: 信任验证结果
    private func validateCertificateTrust(_ certificate: P2PIdentityCertificate) async -> CertificateTrustResult {
 // 获取所有有效的信任记录
        let trustRecords = await trustService.getActiveTrustRecords()
        
 // 查找匹配的信任记录
 // 1. 首先按 deviceId 匹配
        if let record = trustRecords.first(where: { $0.deviceId == certificate.deviceId }) {
 // 验证公钥指纹是否匹配
            if record.pubKeyFP == certificate.pubKeyFP {
                return CertificateTrustResult(
                    isTrusted: true,
                    reason: "Device ID and pubKeyFP match",
                    trustRecord: record
                )
            } else {
 // deviceId 匹配但 pubKeyFP 不匹配 - 可能是密钥替换攻击
                return CertificateTrustResult(
                    isTrusted: false,
                    reason: "Device ID matches but pubKeyFP mismatch - possible key substitution attack",
                    trustRecord: nil
                )
            }
        }
        
 // 2. 按 pubKeyFP 匹配（设备可能更换了 deviceId）
        if let record = trustRecords.first(where: { $0.pubKeyFP == certificate.pubKeyFP }) {
            return CertificateTrustResult(
                isTrusted: true,
                reason: "pubKeyFP matches (deviceId may have changed)",
                trustRecord: record
            )
        }
        
 // 3. 未找到匹配的信任记录
        return CertificateTrustResult(
            isTrusted: false,
            reason: "No matching trust record found",
            trustRecord: nil
        )
    }
    
 // MARK: - Transport State
    
 /// 处理传输状态变化
    private func handleTransportStateChange(_ newState: QUICConnectionState) {
        switch newState {
        case .disconnected:
            if state == .connected {
                handleConnectionLost()
            }
        case .failed:
            state = .failed
            lastError = P2PSessionError.connectionFailed("Transport failed")
        default:
            break
        }
    }
    
 /// 处理连接丢失
    private func handleConnectionLost() {
        guard reconnectAttempts < P2PConstants.maxReconnectAttempts else {
            state = .failed
            lastError = P2PSessionError.connectionFailed("Max reconnect attempts reached")
            return
        }
        
        state = .reconnecting
        reconnectAttempts += 1
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(P2PConstants.autoReconnectDelaySeconds * 1_000_000_000))
            
            if let device = connectedDevice {
                do {
                    try await connect(to: device)
                } catch {
                    SkyBridgeLogger.p2p.error("Reconnect failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
 // MARK: - Metrics
    
 /// 开始指标更新
    private func startMetricsUpdate() {
        Task {
            while state == .connected {
                await updateMetrics()
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }
        }
    }
    
 /// 更新指标（从传输层获取实际数据）
 /// Requirements: 4.1, 4.2, 4.3, 4.4
    private func updateMetrics() async {
 // 从 QUICTransportService 获取连接
        guard let transportService = transport,
              let connection = await transportService.getConnection() else {
 // 使用默认值
            metrics = createDefaultMetrics()
            return
        }
        
 // 获取当前路径信息
        guard let path = connection.currentPath else {
            metrics = createDefaultMetrics()
            return
        }
        
 // 提取网络指标
        let latencyMs = extractLatency(from: path)
        let bandwidthMbps = extractBandwidth(from: path)
        let packetLossPercent = extractPacketLoss(from: path)
        
        metrics = P2PConnectionMetrics(
            latencyMs: latencyMs,
            bandwidthMbps: bandwidthMbps,
            packetLossPercent: packetLossPercent,
            encryptionMode: {
                guard let negotiatedCrypto else { return "Unknown" }
                let transport = negotiatedCrypto.aeadAlgorithm
                if let handshake = negotiatedCrypto.handshakeAeadAlgorithm, !handshake.isEmpty, handshake != transport {
                    return "\(transport) (handshake: \(handshake))"
                }
                return transport
            }(),
            protocolVersion: "v\(P2PProtocolVersion.current.rawValue)",
            peerCapabilities: connectedDevice?.capabilities ?? [],
            pqcEnabled: negotiatedCrypto?.pqcEnabled ?? false
        )
    }
    
 /// 从 NWPath 提取延迟
 /// Requirements: 4.2
 ///
 /// Note: Network.framework 不直接在 NWPath 上提供 estimatedRTT。
 /// 可以通过 NWConnection.requestEstablishmentReport() 获取连接建立时的 RTT，
 /// 但这需要异步调用且只反映建立时的状态。
 /// 当前实现使用基于接口类型的保守估计，这在大多数场景下是合理的。
    private func extractLatency(from path: NWPath) -> Double {
        switch path.status {
        case .satisfied:
 // 根据接口类型估计延迟
            if path.usesInterfaceType(.wifi) {
                return 5.0  // WiFi 典型延迟 (ms)
            } else if path.usesInterfaceType(.wiredEthernet) {
                return 1.0  // 有线典型延迟 (ms)
            } else if path.usesInterfaceType(.cellular) {
                return 50.0  // 蜂窝典型延迟 (ms)
            } else if path.usesInterfaceType(.loopback) {
                return 0.1  // 本地回环 (ms)
            }
            return 10.0  // 默认
        default:
            return 0.0
        }
    }
    
 /// 从 NWPath 提取带宽
 /// Requirements: 4.2
 ///
 /// Note: Network.framework 不直接在 NWPath 上提供 estimatedBandwidth。
 /// 实际带宽需要通过 NWConnection.DataTransferReport 或应用层测量获取。
 /// 当前实现使用基于接口类型的保守估计。
    private func extractBandwidth(from path: NWPath) -> Double {
        switch path.status {
        case .satisfied:
            if path.usesInterfaceType(.wifi) {
                return 100.0  // WiFi 保守估计 (Mbps)
            } else if path.usesInterfaceType(.wiredEthernet) {
                return 1000.0  // 千兆以太网 (Mbps)
            } else if path.usesInterfaceType(.cellular) {
                return 10.0  // 蜂窝保守估计 (Mbps)
            } else if path.usesInterfaceType(.loopback) {
                return 10000.0  // 本地回环 (Mbps)
            }
            return 50.0  // 默认
        default:
            return 0.0
        }
    }
    
 /// 从 NWPath 提取丢包率
 /// Requirements: 4.2
    private func extractPacketLoss(from path: NWPath) -> Double {
 // macOS 26+ 可能提供丢包统计
 // 目前使用保守估计
        switch path.status {
        case .satisfied:
            return 0.0  // 假设无丢包
        case .unsatisfied:
            return 100.0  // 连接断开
        case .requiresConnection:
            return 50.0  // 需要重连
        @unknown default:
            return 0.0
        }
    }
    
 /// 创建默认指标
 /// Requirements: 4.3
    private func createDefaultMetrics() -> P2PConnectionMetrics {
        P2PConnectionMetrics(
            latencyMs: 0,
            bandwidthMbps: 0,
            packetLossPercent: 0,
            encryptionMode: {
                guard let negotiatedCrypto else { return "Unknown" }
                let transport = negotiatedCrypto.aeadAlgorithm
                if let handshake = negotiatedCrypto.handshakeAeadAlgorithm, !handshake.isEmpty, handshake != transport {
                    return "\(transport) (handshake: \(handshake))"
                }
                return transport
            }(),
            protocolVersion: "v\(P2PProtocolVersion.current.rawValue)",
            peerCapabilities: connectedDevice?.capabilities ?? [],
            pqcEnabled: negotiatedCrypto?.pqcEnabled ?? false
        )
    }
    
 // MARK: - Secure Random Generation
    
 /// Generate cryptographically secure random data
 /// 19.1: Type C force unwrap handling (Requirements 9.1, 9.2)
 /// - DEBUG: assertionFailure() to alert developer
 /// - RELEASE: emit SecurityEvent and return fallback data
 /// - Parameters:
 /// - count: Number of bytes to generate
 /// - context: Context string for logging (e.g., "challenge", "nonce")
 /// - Returns: Random data (cryptographically secure if possible, fallback otherwise)
    private static func generateSecureRandomData(count: Int, context: String) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        
        if status != errSecSuccess {
 // Type C: Development assertion - should never fail in normal operation
            #if DEBUG
            assertionFailure("SecRandomCopyBytes failed with status \(status) for \(context) - this indicates a serious system issue")
            #endif
            
 // RELEASE: Emit security event and return timestamp-based fallback
 // This is a degraded mode - the data won't be cryptographically random
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .cryptoProviderSelected,  // Reuse existing type for crypto-related events
                severity: .critical,
                message: "SecRandomCopyBytes failed in iOSP2PSessionManager",
                context: [
                    "status": String(status),
                    "component": "iOSP2PSessionManager",
                    "context": context,
                    "fallback": "timestamp-based"
                ]
            ))
            
 // Fallback: Use timestamp + process info + context hash (NOT cryptographically secure!)
 // This allows the system to continue but with degraded security
            var fallbackData = Data(count: count)
            var timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            var processId = UInt32(ProcessInfo.processInfo.processIdentifier)
            var contextHash = context.hashValue
            
            withUnsafeMutableBytes(of: &timestamp) { timestampBytes in
                let copyCount = min(8, count)
                fallbackData.replaceSubrange(0..<copyCount, with: timestampBytes.prefix(copyCount))
            }
            
            if count > 8 {
                withUnsafeMutableBytes(of: &processId) { pidBytes in
                    let copyCount = min(4, count - 8)
                    fallbackData.replaceSubrange(8..<(8 + copyCount), with: pidBytes.prefix(copyCount))
                }
            }
            
            if count > 12 {
                withUnsafeMutableBytes(of: &contextHash) { hashBytes in
                    let copyCount = min(8, count - 12)
                    fallbackData.replaceSubrange(12..<(12 + copyCount), with: hashBytes.prefix(copyCount))
                }
            }
            
            return fallbackData
        }
        
        return data
    }
}

// MARK: - QUICTransportService Extension

@available(macOS 14.0, iOS 17.0, *)
extension QUICTransportService {
 /// 设置回调
    func setCallbacks(
        onControl: @escaping @Sendable (Data) -> Void,
        onStateChanged: @escaping @Sendable (QUICConnectionState) -> Void
    ) async {
        self.onControlReceived = onControl
        self.onStateChanged = onStateChanged
    }
}


// MARK: - Handshake Message

/// 握手消息类型
// MARK: - Session Keys

/// 会话密钥
public struct P2PSessionKeys: Sendable {
 /// 控制通道发送密钥
    public let controlSendKey: Data
    
 /// 控制通道接收密钥
    public let controlReceiveKey: Data
    
 /// 视频通道发送密钥
    public let videoSendKey: Data
    
 /// 视频通道接收密钥
    public let videoReceiveKey: Data
    
 /// 文件通道发送密钥
    public let fileSendKey: Data
    
 /// 文件通道接收密钥
    public let fileReceiveKey: Data
    
 /// Finished MAC 发送密钥
    public let finishedSendKey: Data
    
 /// Finished MAC 接收密钥
    public let finishedReceiveKey: Data
    
 /// 控制通道密钥（兼容字段，等同于 controlSendKey）
    public let controlKey: Data
    
 /// 视频通道密钥（兼容字段，等同于 videoSendKey）
    public let videoKey: Data
    
 /// 文件通道密钥（兼容字段，等同于 fileSendKey）
    public let fileKey: Data
    
 /// Finished MAC 密钥（兼容字段，等同于 finishedSendKey）
    public let finishedKey: Data
    
 /// Transcript 哈希（用于通道绑定）
    public let transcriptHash: Data
    
    public init(
        controlSendKey: Data,
        controlReceiveKey: Data,
        videoSendKey: Data,
        videoReceiveKey: Data,
        fileSendKey: Data,
        fileReceiveKey: Data,
        finishedSendKey: Data,
        finishedReceiveKey: Data,
        transcriptHash: Data
    ) {
        self.controlSendKey = controlSendKey
        self.controlReceiveKey = controlReceiveKey
        self.videoSendKey = videoSendKey
        self.videoReceiveKey = videoReceiveKey
        self.fileSendKey = fileSendKey
        self.fileReceiveKey = fileReceiveKey
        self.finishedSendKey = finishedSendKey
        self.finishedReceiveKey = finishedReceiveKey
        self.controlKey = controlSendKey
        self.videoKey = videoSendKey
        self.fileKey = fileSendKey
        self.finishedKey = finishedSendKey
        self.transcriptHash = transcriptHash
    }
}
