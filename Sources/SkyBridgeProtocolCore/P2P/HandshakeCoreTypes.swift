import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - HandshakeState

public enum HandshakeState: Sendable {
    case idle
    case sendingMessageA
    case waitingMessageB(deadline: ContinuousClock.Instant)
    case processingMessageB(epoch: UInt64)
    case processingMessageA
    case sendingMessageB
    case waitingFinished(deadline: ContinuousClock.Instant, sessionKeys: SessionKeys, expectingFrom: HandshakeRole)
    case established(sessionKeys: SessionKeys)
    case failed(reason: HandshakeFailureReason)
}

// MARK: - HandshakeFailureReason

public enum HandshakeFailureReason: Error, LocalizedError, Sendable, Equatable {
    case timeout
    case peerRejected(message: String)
    case cryptoError(String)
    case transportError(String)
    case cancelled
    case versionMismatch(local: UInt8, remote: UInt8)
    case suiteNegotiationFailed
    case signatureVerificationFailed
    case invalidMessageFormat(String)
    case identityMismatch(expected: String, actual: String)
    case replayDetected
    case secureEnclavePoPRequired
    case secureEnclaveSignatureInvalid
    case keyConfirmationFailed
    case suiteSignatureMismatch(selectedSuite: String, sigAAlgorithm: String)
    case pqcProviderUnavailable
    case suiteNotSupported
    case supersededByConcurrentAttempt(winnerPeerId: String, winnerAttemptId: String)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Handshake timed out"
        case .peerRejected(let message):
            return message.isEmpty ? "Peer rejected handshake" : "Peer rejected handshake: \(message)"
        case .cryptoError(let reason):
            return "Cryptographic error: \(reason)"
        case .transportError(let reason):
            return "Transport error: \(reason)"
        case .cancelled:
            return "Handshake cancelled"
        case .versionMismatch(let local, let remote):
            return "Version mismatch (local: \(local), remote: \(remote))"
        case .suiteNegotiationFailed:
            return "Suite negotiation failed"
        case .signatureVerificationFailed:
            return "Signature verification failed"
        case .invalidMessageFormat(let reason):
            return "Invalid message format: \(reason)"
        case .identityMismatch(let expected, let actual):
            return "Identity mismatch (expected: \(expected), actual: \(actual))"
        case .replayDetected:
            return "Replay detected"
        case .secureEnclavePoPRequired:
            return "Secure Enclave proof-of-possession required"
        case .secureEnclaveSignatureInvalid:
            return "Secure Enclave signature invalid"
        case .keyConfirmationFailed:
            return "Finished MAC verification failed"
        case .suiteSignatureMismatch(let selectedSuite, let sigAAlgorithm):
            return "Suite/signature mismatch (suite: \(selectedSuite), sigA: \(sigAAlgorithm))"
        case .pqcProviderUnavailable:
            return "PQC provider unavailable"
        case .suiteNotSupported:
            return "Suite not supported"
        case .supersededByConcurrentAttempt(let winnerPeerId, let winnerAttemptId):
            return "Superseded by concurrent attempt (winner: \(winnerPeerId), attempt: \(winnerAttemptId))"
        }
    }
}

// MARK: - HandshakeRole

public enum HandshakeRole: String, Sendable {
    case initiator
    case responder
}

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

public struct SessionKeys: Sendable {
    public let sendKey: Data
    public let receiveKey: Data
    public let negotiatedSuite: CryptoSuite
    public let role: HandshakeRole
    public let transcriptHash: Data
    public let sessionId: String
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

@available(macOS 14.0, iOS 17.0, *)
extension SessionKeys {
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

public enum HandshakeError: Error, LocalizedError, Sendable {
    case alreadyInProgress
    case failed(HandshakeFailureReason)
    case invalidState(String)
    case contextZeroized
    case noSigningCapability
    case emptyOfferedSuites
    case homogeneityViolation(message: String)
    case providerAlgorithmMismatch(provider: String, algorithm: String)
    case signatureAlgorithmMismatch(algorithm: String, keyHandleType: String)
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

// MARK: - AuthProfile

public enum AuthProfile: UInt8, Codable, CaseIterable, Sendable {
    case classic = 0x01
    case pqc = 0x02
    case hybrid = 0x03

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .pqc: return "PQC"
        case .hybrid: return "Hybrid"
        }
    }
}

// MARK: - PeerIdentifier

public struct PeerIdentifier: Hashable, Sendable {
    public let deviceId: String
    public let displayName: String?
    public let address: String?

    public init(deviceId: String, displayName: String? = nil, address: String? = nil) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.address = address
    }
}

// MARK: - HandshakeConstants

public enum HandshakeConstants {
    public static let defaultTimeout: Duration = .seconds(30)
    public static let maxTimeout: Duration = .seconds(120)
    public static let timeoutTolerance: Duration = .milliseconds(100)
    public static let protocolVersion: UInt8 = 1
    public static let maxMessageALength = 8192
    public static let maxMessageBLength = 16384
    public static let maxSupportedSuites: UInt16 = 8
    public static let maxSupportedAuthProfiles: UInt8 = 3
    public static let maxKeyShareCount: UInt16 = 2
}
