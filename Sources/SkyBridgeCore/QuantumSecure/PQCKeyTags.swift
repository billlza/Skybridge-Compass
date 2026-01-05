import Foundation

struct PQCKeyTags {
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
}
