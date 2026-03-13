import Foundation

/// Wire-visible signature algorithm enumeration.
///
/// Includes `p256ECDSA` for backward-compatible decoding, but protocol signing
/// should use `ProtocolSigningAlgorithm` to exclude legacy P-256 at the type level.
public enum SignatureAlgorithm: String, Codable, Sendable, Equatable {
    case ed25519 = "Ed25519"
    case mlDSA65 = "ML-DSA-65"
    case p256ECDSA = "P-256-ECDSA"

    public static func forSuite(_ suite: CryptoSuite) -> SignatureAlgorithm {
        if suite.isPQC || suite.isHybrid {
            return .mlDSA65
        } else {
            return .ed25519
        }
    }

    public var wireCode: UInt16 {
        switch self {
        case .ed25519: return 0x0001
        case .mlDSA65: return 0x0002
        case .p256ECDSA: return 0x0003
        }
    }
}

/// Main-protocol signing algorithm set.
///
/// This intentionally excludes P-256 so cross-platform handshake logic cannot
/// accidentally route `sigA` / `sigB` through legacy signing.
public enum ProtocolSigningAlgorithm: String, Codable, Sendable, Hashable {
    case ed25519 = "Ed25519"
    case mlDSA65 = "ML-DSA-65"

    public var wire: SignatureAlgorithm {
        switch self {
        case .ed25519: return .ed25519
        case .mlDSA65: return .mlDSA65
        }
    }

    public init?(from wire: SignatureAlgorithm) {
        switch wire {
        case .ed25519: self = .ed25519
        case .mlDSA65: self = .mlDSA65
        case .p256ECDSA: return nil
        }
    }

    public var wireCode: UInt16 {
        switch self {
        case .ed25519: return 0x0001
        case .mlDSA65: return 0x0002
        }
    }

    public static func forSuite(_ suite: CryptoSuite) -> ProtocolSigningAlgorithm {
        if suite.isPQC || suite.isHybrid {
            return .mlDSA65
        } else {
            return .ed25519
        }
    }
}
