//
// HandshakeTypes.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - 10.1: 握手基础设施
// Requirements: 4.1, 4.2, 4.8
//
// 握手状态机类型定义：
// - HandshakeState: 握手状态枚举
// - HandshakeFailureReason: 失败原因枚举
// - HandshakeRole: 角色枚举
// - SessionKeys: 会话密钥结构
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

// MARK: - HandshakeState

/// 握手状态
public enum HandshakeState: Sendable {
 /// 空闲状态
    case idle
    
 /// 正在发送 MessageA（发起方）
    case sendingMessageA
    
 /// 等待 MessageB（发起方）
    case waitingMessageB(deadline: ContinuousClock.Instant)

 /// 正在处理 MessageB（发起方，防重入）
    case processingMessageB(epoch: UInt64)
    
 /// 正在处理 MessageA（响应方）
    case processingMessageA
    
 /// 正在发送 MessageB（响应方）
    case sendingMessageB
    
 /// 等待 FINISHED（密钥确认）
    case waitingFinished(deadline: ContinuousClock.Instant, sessionKeys: SessionKeys, expectingFrom: HandshakeRole)
    
 /// 握手完成
    case established(sessionKeys: SessionKeys)
    
 /// 握手失败
    case failed(reason: HandshakeFailureReason)
}

// MARK: - HandshakeFailureReason

/// 握手失败原因
public enum HandshakeFailureReason: Sendable, Equatable {
 /// 超时
    case timeout
    
 /// 对端拒绝
    case peerRejected(message: String)
    
 /// 加密错误
    case cryptoError(String)
    
 /// 传输错误
    case transportError(String)
    
 /// 被取消
    case cancelled
    
 /// 协议版本不匹配
    case versionMismatch(local: UInt8, remote: UInt8)
    
 /// 套件协商失败
    case suiteNegotiationFailed
    
 /// 签名验证失败
    case signatureVerificationFailed
    
 /// 无效消息格式
    case invalidMessageFormat(String)
    
 /// 身份不匹配（pinning 失败）
    case identityMismatch(expected: String, actual: String)
    
 /// 重放检测
    case replayDetected
    
 /// Secure Enclave PoP 缺失但策略要求
    case secureEnclavePoPRequired
    
 /// Secure Enclave PoP 验证失败
    case secureEnclaveSignatureInvalid
    
 /// 密钥确认失败（FINISHED 校验不通过）
    case keyConfirmationFailed
    
 /// Suite-Signature 不匹配（ 9.1）
 /// selectedSuite 与 sigA 算法不兼容
    case suiteSignatureMismatch(selectedSuite: String, sigAAlgorithm: String)
    
 /// PQC Provider 不可用
    case pqcProviderUnavailable
    
 /// Suite 不支持
    case suiteNotSupported
}

// MARK: - HandshakeRole

/// 握手角色
public enum HandshakeRole: String, Sendable {
 /// 发起方（发送 MessageA）
    case initiator
    
 /// 响应方（接收 MessageA，发送 MessageB）
    case responder
}

/// 中文注释：本地加密策略（不入线、不进 transcript），用于控制 Hybrid 能力的默认行为
public struct CryptoPolicy: Sendable, Equatable {
    public enum MinimumSecurityTier: String, Sendable {
        case classicOnly
        case pqcPreferred
        case hybridPreferred
        case pqcOnly
    }
    
    public let minimumSecurityTier: MinimumSecurityTier
    public let allowExperimentalHybrid: Bool
    public let advertiseHybrid: Bool
    public let requireHybridIfAvailable: Bool
    
    public init(
        minimumSecurityTier: MinimumSecurityTier = .pqcPreferred,
        allowExperimentalHybrid: Bool = false,
        advertiseHybrid: Bool = false,
        requireHybridIfAvailable: Bool = false
    ) {
        self.minimumSecurityTier = minimumSecurityTier
        self.allowExperimentalHybrid = allowExperimentalHybrid
        self.advertiseHybrid = advertiseHybrid
        self.requireHybridIfAvailable = requireHybridIfAvailable
    }
    
    public static let `default` = CryptoPolicy()
}

// MARK: - SessionKeys

/// 会话密钥（握手成功后的结果）
public struct SessionKeys: Sendable {
 /// 发送密钥（用于加密发出的消息）
    public let sendKey: Data
    
 /// 接收密钥（用于解密收到的消息）
    public let receiveKey: Data
    
 /// 协商的加密套件
    public let negotiatedSuite: CryptoSuite

 /// 握手角色
    public let role: HandshakeRole

 /// Transcript hash（用于后续密钥派生）
    public let transcriptHash: Data
    
 /// 会话 ID（用于日志和调试）
    public let sessionId: String
    
 /// 创建时间
    public let createdAt: Date
    
    public init(
        sendKey: Data,
        receiveKey: Data,
        negotiatedSuite: CryptoSuite,
        role: HandshakeRole,
        transcriptHash: Data,
        sessionId: String = UUID().uuidString,
        createdAt: Date = Date()
    ) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        self.negotiatedSuite = negotiatedSuite
        self.role = role
        self.transcriptHash = transcriptHash
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

// MARK: - SessionKeys + Pairing Verification Code (SAS)

@available(macOS 14.0, iOS 17.0, *)
extension SessionKeys {
    /// 6-digit Short Authentication String (SAS) used for the paper's out-of-band pairing ceremony.
    ///
    /// Deterministically derived from the handshake transcript hash so the user verification is bound to:
    /// - the negotiated suite,
    /// - policy-in-transcript,
    /// - key shares, nonces, and Finished MACs.
    public func pairingVerificationCode() -> String {
        var material = Data("SkyBridge-Pairing-SAS|".utf8)
        material.append(transcriptHash)

        let digest = SHA256.hash(data: material)
        let raw = digest.withUnsafeBytes { ptr -> UInt32 in
            ptr.loadUnaligned(as: UInt32.self).bigEndian
        }
        let code = Int(raw % 1_000_000)
        return String(format: "%06d", code)
    }
}

// MARK: - HandshakeError

/// 握手错误
public enum HandshakeError: Error, LocalizedError, Sendable {
 /// 握手已在进行中
    case alreadyInProgress
    
 /// 握手失败
    case failed(HandshakeFailureReason)
    
 /// 无效状态
    case invalidState(String)
    
 /// 上下文已被清理
    case contextZeroized
    
 /// 无签名能力（无回调且无原始密钥）
    case noSigningCapability
    
 // MARK: - 2 新增错误类型 ( 5.1)
    
 /// offeredSuites 为空
    case emptyOfferedSuites
    
 /// offeredSuites 同质性违反（混装 PQC 和 Classic）
    case homogeneityViolation(message: String)
    
 /// Provider 与算法不匹配
    case providerAlgorithmMismatch(provider: String, algorithm: String)
    
 /// 签名算法与密钥句柄不匹配
    case signatureAlgorithmMismatch(algorithm: String, keyHandleType: String)
    
 /// 无效的 Provider 类型（CryptoProvider 被当成签名 provider）
    case invalidProviderType(message: String)
    
    public var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return "Handshake already in progress"
        case .failed(let reason):
            return "Handshake failed: \(reason)"
        case .invalidState(let state):
            return "Invalid handshake state: \(state)"
        case .contextZeroized:
            return "Handshake context has been zeroized"
        case .noSigningCapability:
            return "No signing capability: neither signing callback nor raw key provided"
        case .emptyOfferedSuites:
            return "offeredSuites cannot be empty"
        case .homogeneityViolation(let message):
            return "offeredSuites homogeneity violation: \(message)"
        case .providerAlgorithmMismatch(let provider, let algorithm):
            return "Provider '\(provider)' does not match algorithm '\(algorithm)'"
        case .signatureAlgorithmMismatch(let algorithm, let keyHandleType):
            return "Signature algorithm '\(algorithm)' does not match key handle type '\(keyHandleType)'"
        case .invalidProviderType(let message):
            return "Invalid provider type: \(message)"
        }
    }
}

// MARK: - SigningCallback Protocol

/// 签名回调协议
///
/// 用于支持 Secure Enclave 或其他硬件安全模块中的密钥签名。
/// 实现此协议可以让 HandshakeDriver 使用硬件保护的密钥进行签名，
/// 而无需将私钥暴露到内存中。
///
/// **Requirements: 2.1, 2.2**
///
/// **使用场景**:
/// - Secure Enclave 签名（macOS 26+/iOS 26+）
/// - 硬件安全模块 (HSM) 签名
/// - 远程签名服务
///
/// **线程安全**: 实现必须是 Sendable 的
public protocol SigningCallback: Sendable {
 /// 使用安全存储中的密钥对数据进行签名
 ///
 /// - Parameter data: 要签名的数据
 /// - Returns: 签名结果
 /// - Throws: 签名失败时抛出错误
    func sign(data: Data) async throws -> Data
}

// MARK: - SigningKeyHandle

/// Signing key handle for secure storage (Keychain/Secure Enclave) or raw key data.
public enum SigningKeyHandle: @unchecked Sendable {
    case softwareKey(Data)
    #if canImport(Security)
    case secureEnclaveRef(SecKey)
    #endif
    case callback(any SigningCallback)
}

// MARK: - AuthProfile

/// 握手认证配置（与 KEM/AEAD/KDF 解耦）
public enum AuthProfile: UInt8, Codable, CaseIterable, Sendable {
 /// Classic：经典密钥建立（X25519）+ 经典 HPKE
    case classic = 0x01
 /// PQC：纯 PQC 密钥建立（ML-KEM）
    case pqc = 0x02
 /// Hybrid：混合密钥建立（例如 X-Wing）
    case hybrid = 0x03
    
    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .pqc: return "PQC"
        case .hybrid: return "Hybrid"
        }
    }
}

/// 握手身份密钥（协议签名 + 可选 Secure Enclave PoP）
public struct HandshakeIdentityKeys: Sendable {
    public let classicPublicKey: Data?
    public let classicKeyHandle: SigningKeyHandle?
    public let pqcPublicKey: Data?
    public let pqcKeyHandle: SigningKeyHandle?
    public let secureEnclavePublicKey: Data?
    
    public init(
        classicPublicKey: Data? = nil,
        classicKeyHandle: SigningKeyHandle? = nil,
        pqcPublicKey: Data? = nil,
        pqcKeyHandle: SigningKeyHandle? = nil,
        secureEnclavePublicKey: Data? = nil
    ) {
        self.classicPublicKey = classicPublicKey
        self.classicKeyHandle = classicKeyHandle
        self.pqcPublicKey = pqcPublicKey
        self.pqcKeyHandle = pqcKeyHandle
        self.secureEnclavePublicKey = secureEnclavePublicKey
    }
}

// MARK: - PeerIdentifier

/// 对端标识符
public struct PeerIdentifier: Hashable, Sendable {
 /// 设备 ID
    public let deviceId: String
    
 /// 显示名称（可选）
    public let displayName: String?
    
 /// 网络地址（可选）
    public let address: String?
    
    public init(deviceId: String, displayName: String? = nil, address: String? = nil) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.address = address
    }
}

// MARK: - HandshakeConstants

/// 握手常量
public enum HandshakeConstants {
 /// 默认超时时间（秒）
    public static let defaultTimeout: Duration = .seconds(30)
    
 /// 最大超时时间（秒）
    public static let maxTimeout: Duration = .seconds(120)
    
 /// 超时容差（毫秒）
    public static let timeoutTolerance: Duration = .milliseconds(100)
    
 /// 协议版本
    public static let protocolVersion: UInt8 = 1
    
 /// MessageA 最大长度
    public static let maxMessageALength = 8192
    
 /// MessageB 最大长度
    public static let maxMessageBLength = 16384
    
 /// supportedSuites 最大数量
    public static let maxSupportedSuites: UInt16 = 8
    
 /// supportedAuthProfiles 最大数量
    public static let maxSupportedAuthProfiles: UInt8 = 3
    
 /// keyShares 最大数量
    public static let maxKeyShareCount: UInt16 = 2
}
