import Foundation

struct PQCKeyTags {
    static let xWingAlgorithm = "XWing"
    static let xWingVariant = "768"
    static let xWingPrivateLegacyKind = "Mem"
    static let xWingPublicLegacyKind = "Pub"
    static let xWingRemotePublicKind = "RemotePub"
    static let xWingV2Variant = "xwing-mlkem768-x25519"

    static func service(_ algorithm: String, _ variant: String, _ kind: String) -> String {
        return "SkyBridge.PQC.v1.\(algorithm).\(variant).\(kind)"
    }
    static func serviceV1(_ algorithm: String, _ variant: String, _ kind: String) -> String {
        return "SkyBridge.PQC.v1.\(algorithm).\(variant).\(kind)"
    }
    static func v2Kem(_ variant: String) -> String {
        return "com.skybridge.pqc.v2.kem.\(variant)"
    }
    static func v2Sig(_ variant: String) -> String {
        return "com.skybridge.pqc.v2.sig.\(variant)"
    }

    static var xWingLegacyPrivate: String {
        serviceV1(xWingAlgorithm, xWingVariant, xWingPrivateLegacyKind)
    }

    static var xWingLegacyPublic: String {
        serviceV1(xWingAlgorithm, xWingVariant, xWingPublicLegacyKind)
    }

    static var xWingRemotePublic: String {
        serviceV1(xWingAlgorithm, xWingVariant, xWingRemotePublicKind)
    }

    static var xWingV2: String {
        v2Kem(xWingV2Variant)
    }
}
