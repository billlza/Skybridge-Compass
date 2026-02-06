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
public enum HandshakeFailureReason: Error, Sendable {
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
public enum HandshakeError: Error, Sendable {
    case alreadyInProgress
    case noSigningCapability
    case failed(HandshakeFailureReason)
    case emptyOfferedSuites
    case homogeneityViolation(message: String)
    case providerAlgorithmMismatch(provider: String, algorithm: String)
    case signatureAlgorithmMismatch(algorithm: String, keyHandleType: String)
    case contextZeroized
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
            $0.load(as: UInt32.self).littleEndian
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
