//
// HandshakeTypes.swift
// SkyBridgeCompassiOS
//
// 握手协议类型定义 - 与 macOS SkyBridgeCore 完全兼容
// 注意：基础类型（CryptoSuite, SessionKeys 等）定义在 CoreTypes.swift 中
//

import Foundation
import CryptoKit

// MARK: - HandshakeConstants

/// 握手协议常量
public enum HandshakeConstants {
    public static let protocolVersion: UInt8 = 1
    public static let defaultTimeout: Duration = .seconds(30)
    public static let timeoutTolerance: Duration = .milliseconds(100)
    public static let maxSupportedSuites: UInt16 = 8
    public static let maxKeyShareCount: UInt16 = 2
    public static let nonceSize = 32
}

// MARK: - HandshakeState

/// 握手状态
public enum HandshakeState: Sendable {
    case idle
    case sendingMessageA
    case waitingMessageB(deadline: ContinuousClock.Instant)
    case processingMessageA
    case sendingMessageB
    case processingMessageB(epoch: UInt64)
    case waitingFinished(deadline: ContinuousClock.Instant, sessionKeys: SessionKeys, expectingFrom: HandshakeRole)
    case established(sessionKeys: SessionKeys)
    case failed(reason: HandshakeFailureReason)
}

// MARK: - HandshakeFailureReason

/// 握手失败原因
public enum HandshakeFailureReason: Error, LocalizedError, Sendable, Equatable {
    case timeout
    case cancelled
    case peerRejected(String)
    case cryptoError(String)
    case transportError(String)
    case versionMismatch(local: UInt8, remote: UInt8)
    case signatureVerificationFailed
    case invalidMessageFormat(String)
    case identityMismatch(expected: String, actual: String)
    case replayDetected
    case secureEnclavePoPRequired
    case secureEnclaveSignatureInvalid
    case keyConfirmationFailed
    case suiteSignatureMismatch(selectedSuite: String, sigAAlgorithm: String)
    case pqcProviderUnavailable
    /// iOS initiator needs the peer's long-term KEM public key (provisioned during pairing / trust sync)
    /// to build a PQC key share (ML-KEM / X-Wing). If absent, PQC handshake cannot start.
    case missingPeerKEMPublicKey(suite: String)
    case suiteNotSupported
    case suiteNegotiationFailed
    case unknownSuite(wireId: UInt16)
    case supersededByConcurrentAttempt(winnerPeerId: String, winnerAttemptId: String)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "握手超时：对端未及时响应。"
        case .cancelled:
            return "握手已取消。"
        case .peerRejected(let reason):
            return reason.isEmpty ? "对端拒绝连接请求。" : "对端拒绝连接：\(reason)"
        case .cryptoError(let message):
            return "密码学处理失败：\(message)"
        case .transportError(let message):
            return "传输层错误：\(message)"
        case .versionMismatch(let local, let remote):
            return "协议版本不兼容（本地 v\(local)，对端 v\(remote)）。"
        case .signatureVerificationFailed:
            return "签名验证失败：无法确认对端身份。"
        case .invalidMessageFormat(let reason):
            return "握手消息格式无效：\(reason)"
        case .identityMismatch:
            return "设备身份不匹配，握手已中止。"
        case .replayDetected:
            return "检测到重放攻击，握手已中止。"
        case .secureEnclavePoPRequired:
            return "连接策略要求 Secure Enclave 证明，但当前设备未满足。"
        case .secureEnclaveSignatureInvalid:
            return "Secure Enclave 签名校验失败。"
        case .keyConfirmationFailed:
            return "密钥确认失败，安全信道建立未完成。"
        case .suiteSignatureMismatch(let selectedSuite, let sigAAlgorithm):
            return "加密套件与签名算法不匹配（suite=\(selectedSuite), sigA=\(sigAAlgorithm)）。"
        case .pqcProviderUnavailable:
            return "后量子密码 provider 不可用。"
        case .missingPeerKEMPublicKey(let suite):
            return "缺少对端 KEM 公钥（\(suite)），无法执行 PQC 握手。"
        case .suiteNotSupported:
            return "对端请求的加密套件不受支持。"
        case .suiteNegotiationFailed:
            return "无法协商共同加密套件。"
        case .unknownSuite(let wireId):
            return String(format: "收到未知加密套件（wireId=0x%04X），握手已拒绝。", wireId)
        case .supersededByConcurrentAttempt:
            return "本次握手已被并发连接仲裁淘汰。"
        }
    }

    public var diagnosticReasonCode: String {
        switch self {
        case .timeout:
            return "timeout"
        case .cancelled:
            return "cancelled"
        case .peerRejected:
            return "peer_rejected"
        case .cryptoError:
            return "crypto_error"
        case .transportError:
            return "transport_error"
        case .versionMismatch(let local, let remote):
            return "version_mismatch local=\(local) remote=\(remote)"
        case .signatureVerificationFailed:
            return "signature_verification_failed"
        case .invalidMessageFormat:
            return "invalid_message_format"
        case .identityMismatch:
            return "identity_mismatch"
        case .replayDetected:
            return "replay_detected"
        case .secureEnclavePoPRequired:
            return "secure_enclave_pop_required"
        case .secureEnclaveSignatureInvalid:
            return "secure_enclave_signature_invalid"
        case .keyConfirmationFailed:
            return "key_confirmation_failed"
        case .suiteSignatureMismatch(let selectedSuite, let sigAAlgorithm):
            return "suite_signature_mismatch suite=\(selectedSuite) sigA=\(sigAAlgorithm)"
        case .pqcProviderUnavailable:
            return "pqc_provider_unavailable"
        case .missingPeerKEMPublicKey:
            return "missing_peer_kem_public_key"
        case .suiteNotSupported:
            return "suite_not_supported"
        case .suiteNegotiationFailed:
            return "suite_negotiation_failed"
        case .unknownSuite(let wireId):
            return String(format: "unknown_suite wire_id=0x%04X", wireId)
        case .supersededByConcurrentAttempt:
            return "superseded_by_concurrent_attempt"
        }
    }
}

enum HandshakeDiagnosticRedaction {
    static func stableIdentifierLabel(_ rawIdentifier: String?) -> String {
        guard rawIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return "<redacted>"
        }
        return "<redacted>"
    }
}

// MARK: - Paper-aligned Security Events (iOS target-local)

/// Lightweight structured security events for the iOS app target.
///
/// Note: These are placed in an already-in-target file (`HandshakeTypes.swift`) to avoid
/// Xcode target-membership drift during launch hardening.
@available(iOS 17.0, *)
public enum SecurityEventType: String, Codable, Sendable {
    case cryptoDowngrade
    case handshakeFailed
    case legacyBootstrap
}

@available(iOS 17.0, *)
public enum SecurityEventSeverity: String, Codable, Sendable {
    case info
    case warning
    case high
}

@available(iOS 17.0, *)
public struct SecurityEvent: Codable, Sendable, Equatable {
    public let type: SecurityEventType
    public let severity: SecurityEventSeverity
    public let message: String
    public let context: [String: String]
    public let timestamp: Date

    public init(
        type: SecurityEventType,
        severity: SecurityEventSeverity,
        message: String,
        context: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.type = type
        self.severity = severity
        self.message = message
        self.context = context
        self.timestamp = timestamp
    }
}

/// Minimal bounded emitter: keeps a small in-memory ring and prints a single-line representation.
@available(iOS 17.0, *)
public actor SecurityEventEmitter {
    public static let shared = SecurityEventEmitter()

    private let maxEvents: Int = 256
    private var ring: [SecurityEvent] = []

    private init() {}

    public func emit(_ event: SecurityEvent) {
        ring.append(event)
        if ring.count > maxEvents {
            ring.removeFirst(ring.count - maxEvents)
        }
        print(Self.format(event))
    }

    public nonisolated static func emitDetached(_ event: SecurityEvent) {
        Task { await SecurityEventEmitter.shared.emit(event) }
    }

    public func snapshot() -> [SecurityEvent] { ring }

    private nonisolated static func format(_ e: SecurityEvent) -> String {
        let keys = e.context.keys.sorted()
        let ctx = keys.map { "\($0)=\(e.context[$0] ?? "")" }.joined(separator: ",")
        let msg = e.message.replacingOccurrences(of: "\n", with: "\\n")
        return "[SecurityEvent] type=\(e.type.rawValue) severity=\(e.severity.rawValue) message=\"\(msg)\" ctx={\(ctx)}"
    }
}

// MARK: - HandshakeError

/// 握手错误
public enum HandshakeError: Error, LocalizedError, Sendable {
    case alreadyInProgress
    case noSigningCapability
    case failed(HandshakeFailureReason)
    case emptyOfferedSuites
    case homogeneityViolation(message: String)
    case providerAlgorithmMismatch(provider: String, algorithm: String)
    case signatureAlgorithmMismatch(algorithm: String, keyHandleType: String)
    case contextZeroized

    public var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return "握手已在进行中。"
        case .noSigningCapability:
            return "缺少可用签名能力（未配置协议签名密钥）。"
        case .failed(let reason):
            return reason.errorDescription ?? "握手失败。"
        case .emptyOfferedSuites:
            return "offeredSuites 不能为空。"
        case .homogeneityViolation(let message):
            return "offeredSuites 同质性校验失败：\(message)"
        case .providerAlgorithmMismatch(let provider, let algorithm):
            return "provider 与算法不匹配（provider=\(provider), algorithm=\(algorithm)）。"
        case .signatureAlgorithmMismatch(let algorithm, let keyHandleType):
            return "签名算法与密钥类型不匹配（algorithm=\(algorithm), keyHandle=\(keyHandleType)）。"
        case .contextZeroized:
            return "握手上下文已清理，无法继续。"
        }
    }
}

// MARK: - HandshakePolicy

/// 握手策略
public struct HandshakePolicy: Sendable, Codable {
    public let requirePQC: Bool
    public let allowClassicFallback: Bool
    public let minimumTier: CryptoTier
    public let requireSecureEnclavePoP: Bool
    
    public init(
        requirePQC: Bool = false,
        allowClassicFallback: Bool = true,
        minimumTier: CryptoTier = .classic,
        requireSecureEnclavePoP: Bool = false
    ) {
        self.requirePQC = requirePQC
        // Defense-in-depth: strict PQC implies no classic fallback (paper semantics).
        // Even if a caller passes allowClassicFallback=true, enforcePQC must disable it.
        self.allowClassicFallback = requirePQC ? false : allowClassicFallback
        self.minimumTier = minimumTier
        self.requireSecureEnclavePoP = requireSecureEnclavePoP
    }
    
    public static let `default` = HandshakePolicy()
    
    public static let strictPQC = HandshakePolicy(
        requirePQC: true,
        allowClassicFallback: false,
        minimumTier: .nativePQC
    )
    
    public func deterministicEncode() -> Data {
        // 与 macOS SkyBridgeCore 对齐（DeterministicDecoder 解码顺序：Bool, Bool, String, Bool?）
        var encoder = DeterministicEncoder()
        encoder.encodeBool(requirePQC)
        encoder.encodeBool(allowClassicFallback)
        encoder.encodeString(minimumTier.rawValue)
        encoder.encodeBool(requireSecureEnclavePoP)
        return encoder.data
    }
}

// MARK: - CryptoPolicy

/// Local handshake crypto policy for suite admission.
///
/// This mirrors the mac/shared-core contract closely enough that the iOS-local
/// handshake stack can make the same X-Wing / hybrid admission decisions,
/// instead of silently diverging from macOS during suite negotiation.
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

// MARK: - HandshakeCryptoPolicyResolver

/// Resolves the per-attempt local crypto policy from the suites we are about to
/// advertise or accept. This prevents the iOS-local handshake stack from
/// selecting an X-Wing-capable provider while still rejecting hybrid suites in
/// the local admission layer.
public enum HandshakeCryptoPolicyResolver {
    public static func policy(for offeredSuites: [CryptoSuite]) -> CryptoPolicy {
        let pqcSuites = offeredSuites.filter(\.isPQCGroup)
        let hasHybridSuites = pqcSuites.contains(where: \.isHybrid)

        guard hasHybridSuites else {
            return .default
        }

        let onlyOffersHybrid = !pqcSuites.isEmpty && pqcSuites.allSatisfy(\.isHybrid)
        return CryptoPolicy(
            minimumSecurityTier: onlyOffersHybrid ? .hybridPreferred : .pqcPreferred,
            allowExperimentalHybrid: true,
            advertiseHybrid: true,
            requireHybridIfAvailable: onlyOffersHybrid
        )
    }
}

// MARK: - CryptoCapabilities

/// 加密能力声明
public struct CryptoCapabilities: Sendable, Codable {
    public let supportedKEM: [String]
    public let supportedSignature: [String]
    public let supportedAuthProfiles: [String]
    public let supportedAEAD: [String]
    public let pqcAvailable: Bool
    public let platformVersion: String
    public let providerType: CryptoProviderType
    
    public init(
        supportedKEM: [String] = ["ML-KEM-768", "X25519"],
        supportedSignature: [String] = ["ML-DSA-65", "Ed25519"],
        supportedAuthProfiles: [String] = ["pqc", "classic"],
        supportedAEAD: [String] = ["AES-256-GCM", "ChaCha20-Poly1305"],
        pqcAvailable: Bool = false,
        platformVersion: String = "",
        providerType: CryptoProviderType = .classic
    ) {
        self.supportedKEM = supportedKEM
        self.supportedSignature = supportedSignature
        self.supportedAuthProfiles = supportedAuthProfiles
        self.supportedAEAD = supportedAEAD
        self.pqcAvailable = pqcAvailable
        self.platformVersion = platformVersion
        self.providerType = providerType
    }
    
    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encodeStringArray(supportedKEM)
        encoder.encodeStringArray(supportedSignature)
        encoder.encodeStringArray(supportedAuthProfiles)
        encoder.encodeStringArray(supportedAEAD)
        encoder.encodeBool(pqcAvailable)
        encoder.encodeString(platformVersion)
        encoder.encodeString(providerType.rawValue)
        return encoder.data
    }
    
    @available(iOS 17.0, *)
    public static func fromProvider(_ provider: any CryptoProvider) -> CryptoCapabilities {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let capability = CryptoProviderFactory.detectCapability()
        
        return CryptoCapabilities(
            supportedKEM: provider.activeSuite.isPQC ? ["ML-KEM-768", "X25519"] : ["X25519"],
            supportedSignature: provider.activeSuite.isPQC ? ["ML-DSA-65", "Ed25519"] : ["Ed25519"],
            supportedAuthProfiles: provider.activeSuite.isPQC ? ["pqc", "classic"] : ["classic"],
            supportedAEAD: ["AES-256-GCM", "ChaCha20-Poly1305"],
            pqcAvailable: capability.hasApplePQC || capability.hasLiboqs,
            platformVersion: osVersion,
            providerType: CryptoProviderType(from: provider.tier)
        )
    }
}

// MARK: - CryptoProviderType

/// Provider 类型标识
public enum CryptoProviderType: String, Sendable, Codable {
    // 与 macOS SkyBridgeCore 对齐（Sources/SkyBridgeCore/P2P/CryptoProviderSelector.swift）
    case cryptoKitPQC = "CryptoKit-PQC"
    case liboqs = "liboqs"
    case swiftCrypto = "SwiftCrypto"
    case classic = "CryptoKit-Classic"
    
    public init(from tier: CryptoTier) {
        switch tier {
        case .nativePQC: self = .cryptoKitPQC
        case .liboqsPQC: self = .liboqs
        case .classic: self = .classic
        }
    }
}

// MARK: - Deterministic Encoding Helpers

public struct DeterministicEncoder {
    public var data = Data()
    
    public init() {}
    
    /// 与 macOS SkyBridgeCore 对齐：UInt32 little-endian 作为长度/计数前缀（TranscriptBuilder 规则）
    public mutating func encodeUInt32(_ value: UInt32) {
        var little = value.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &little) { Data($0) })
    }

    public mutating func encodeBool(_ value: Bool) {
        data.append(value ? 0x01 : 0x00)
    }

    public mutating func encodeString(_ string: String) {
        let bytes = Data(string.utf8)
        encodeUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    public mutating func encodeStringArray(_ array: [String]) {
        // 不排序：由上层确保稳定顺序（mac 端同样不排序）
        encodeUInt32(UInt32(array.count))
        for string in array {
            encodeString(string)
        }
    }
}

public struct DeterministicDecoder {
    private var data: Data
    private var offset: Int = 0
    
    public init(data: Data) {
        self.data = data
    }
    
    public var isAtEnd: Bool {
        offset >= data.count
    }

    private mutating func decodeUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw TranscriptError.decodingError("Unexpected end of data")
        }
        let value = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian
        }
        offset += 4
        return value
    }
    
    public mutating func decodeStringArray() throws -> [String] {
        let count = try decodeUInt32()
        
        var result: [String] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            result.append(try decodeString())
        }
        return result
    }
    
    public mutating func decodeString() throws -> String {
        let length = Int(try decodeUInt32())
        
        guard offset + length <= data.count else {
            throw TranscriptError.decodingError("Unexpected end of data")
        }
        let bytes = data[offset..<(offset + length)]
        offset += length
        
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw TranscriptError.decodingError("Invalid UTF-8 string")
        }
        return string
    }
    
    public mutating func decodeBool() throws -> Bool {
        guard offset < data.count else {
            throw TranscriptError.decodingError("Unexpected end of data")
        }
        let value = data[offset]
        offset += 1
        return value != 0
    }
}

public enum TranscriptError: Error {
    case decodingError(String)
    case encodingError(String)
}
