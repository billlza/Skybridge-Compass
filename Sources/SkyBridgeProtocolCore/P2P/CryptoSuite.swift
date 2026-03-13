import Foundation

/// Handshake / P2P cryptographic suite descriptor.
///
/// This type is protocol metadata, not a provider implementation detail.
/// Keeping it in `SkyBridgeProtocolCore` lets every platform share the exact same
/// suite IDs, compatibility mapping, and downgrade semantics.
public struct CryptoSuite: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public let wireId: UInt16

    public init(rawValue: String, wireId: UInt16) {
        self.rawValue = rawValue
        self.wireId = wireId
    }

    public init?(rawValue: String) {
        switch rawValue {
        case Self.xwingMLDSA.rawValue, "X-Wing+ML-DSA-65": self = .xwingMLDSA
        case Self.mlkem768MLDSA65.rawValue, "ML-KEM-768+ML-DSA-65": self = .mlkem768MLDSA65
        case Self.mlkem768MLDSA65FS.rawValue, "ML-KEM-768-FS+ML-DSA-65": self = .mlkem768MLDSA65FS
        case Self.x25519Ed25519.rawValue, "X25519+Ed25519": self = .x25519Ed25519
        case Self.p256ECDSA.rawValue, "P-256+ECDSA": self = .p256ECDSA
        default: return nil
        }
    }

    public static let xwingMLDSA = CryptoSuite(rawValue: "X-Wing", wireId: 0x0001)
    public static let mlkem768MLDSA65 = CryptoSuite(rawValue: "ML-KEM-768", wireId: 0x0101)
    public static let mlkem768MLDSA65FS = CryptoSuite(rawValue: "ML-KEM-768-FS", wireId: 0x0102)
    public static let x25519Ed25519 = CryptoSuite(rawValue: "X25519", wireId: 0x1001)
    public static let p256ECDSA = CryptoSuite(rawValue: "P-256", wireId: 0x1002)

    public static func unknown(_ wireId: UInt16) -> CryptoSuite {
        CryptoSuite(rawValue: "unknown-\(wireId)", wireId: wireId)
    }

    public init(wireId: UInt16) {
        switch wireId {
        case 0x0001: self = .xwingMLDSA
        case 0x0101: self = .mlkem768MLDSA65
        case 0x0102: self = .mlkem768MLDSA65FS
        case 0x1001: self = .x25519Ed25519
        case 0x1002: self = .p256ECDSA
        default: self = .unknown(wireId)
        }
    }

    public var tierFromWireId: String {
        switch wireId >> 8 {
        case 0x00: return "hybridPQC"
        case 0x01: return "purePQC"
        case 0x10: return "classic"
        case 0xF0: return "experimental"
        default: return "unknown"
        }
    }

    public var isKnown: Bool {
        !rawValue.hasPrefix("unknown-")
    }

    public var isPQC: Bool {
        let tier = wireId >> 8
        return tier == 0x00 || tier == 0x01
    }

    public var isHybrid: Bool {
        (wireId >> 8) == 0x00
    }

    public var isPQCGroup: Bool {
        let tier = wireId >> 8
        return tier == 0x00 || tier == 0x01
    }

    public var providerCompatibilitySuite: CryptoSuite {
        switch wireId {
        case 0x0102:
            return .mlkem768MLDSA65
        default:
            return self
        }
    }

    public var canonicalKEMSuite: CryptoSuite {
        providerCompatibilitySuite
    }

    public var forwardSecureUpgradeSuite: CryptoSuite? {
        switch wireId {
        case 0x0101:
            return .mlkem768MLDSA65FS
        default:
            return nil
        }
    }

    public var requiresV2EphemeralContribution: Bool {
        wireId == 0x0102
    }

    public var kdfCompositionLabel: String {
        requiresV2EphemeralContribution ? "v2-static+ephemeral" : "v1-single"
    }
}

public enum CryptoTier: String, Sendable, Codable {
    case nativePQC = "nativePQC"
    case liboqsPQC = "liboqsPQC"
    case classic = "classic"
}
