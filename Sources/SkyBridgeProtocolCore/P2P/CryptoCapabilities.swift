import Foundation

public enum CryptoProviderType: String, Codable, Sendable, CaseIterable {
    case qPeriapt = "Q-Periapt-ContextBound"
    case cryptoKitPQC = "CryptoKit-PQC"
    case liboqs = "liboqs"
    case swiftCrypto = "SwiftCrypto"
    case classic = "CryptoKit-Classic"

    public var supportsPQC: Bool {
        switch self {
        case .qPeriapt, .cryptoKitPQC, .liboqs:
            return true
        case .swiftCrypto, .classic:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .qPeriapt: return "Q-Periapt ContextBound (Beta)"
        case .cryptoKitPQC: return "CryptoKit PQC (iOS 26+)"
        case .liboqs: return "liboqs (Fallback)"
        case .swiftCrypto: return "Swift Crypto"
        case .classic: return "CryptoKit Classic"
        }
    }

    public var securityLevel: String {
        switch self {
        case .qPeriapt: return "量子安全 (Q-Periapt beta)"
        case .cryptoKitPQC: return "量子安全 (原生)"
        case .liboqs: return "量子安全 (第三方)"
        case .swiftCrypto, .classic: return "经典安全"
        }
    }
}

public struct CryptoCapabilities: Codable, Sendable, Equatable, TranscriptEncodable {
    public let supportedKEM: [String]
    public let supportedSignature: [String]
    public let supportedAuthProfiles: [String]
    public let supportedAEAD: [String]
    public let pqcAvailable: Bool
    public let platformVersion: String
    public let providerType: CryptoProviderType

    public init(
        supportedKEM: [String],
        supportedSignature: [String],
        supportedAuthProfiles: [String],
        supportedAEAD: [String],
        pqcAvailable: Bool,
        platformVersion: String,
        providerType: CryptoProviderType
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
        encoder.encode(supportedKEM)
        encoder.encode(supportedSignature)
        encoder.encode(supportedAuthProfiles)
        encoder.encode(supportedAEAD)
        encoder.encode(pqcAvailable)
        encoder.encode(platformVersion)
        encoder.encode(providerType.rawValue)
        return encoder.finalize()
    }
}

public struct NegotiatedCryptoProfile: Codable, Sendable, Equatable, TranscriptEncodable {
    public let kemAlgorithm: String
    public let authProfile: String
    public let signatureAlgorithm: String
    public let handshakeAeadAlgorithm: String?
    public let aeadAlgorithm: String
    public let quicDatagramEnabled: Bool
    public let pqcEnabled: Bool
    public let negotiatedAt: Date

    public init(
        kemAlgorithm: String,
        authProfile: String,
        signatureAlgorithm: String,
        aeadAlgorithm: String,
        quicDatagramEnabled: Bool,
        pqcEnabled: Bool,
        handshakeAeadAlgorithm: String? = nil,
        negotiatedAt: Date = Date()
    ) {
        self.kemAlgorithm = kemAlgorithm
        self.authProfile = authProfile
        self.signatureAlgorithm = signatureAlgorithm
        self.handshakeAeadAlgorithm = handshakeAeadAlgorithm
        self.aeadAlgorithm = aeadAlgorithm
        self.quicDatagramEnabled = quicDatagramEnabled
        self.pqcEnabled = pqcEnabled
        self.negotiatedAt = negotiatedAt
    }

    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(kemAlgorithm)
        encoder.encode(authProfile)
        encoder.encode(signatureAlgorithm)
        encoder.encode(handshakeAeadAlgorithm ?? "")
        encoder.encode(aeadAlgorithm)
        encoder.encode(quicDatagramEnabled)
        encoder.encode(pqcEnabled)
        encoder.encode(negotiatedAt)
        return encoder.finalize()
    }
}
