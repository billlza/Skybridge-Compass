public enum SkyBridgeApplePQCSDKBuildProvenance {
    public static let stableReleaseSymbolSet = "cryptokit-pqc-v1"
    public static let os27BetaSymbolSet = "cryptokit-pqc-os27-v1"
    public static let networkTLSPQCSymbolSet = "network-tls-pqc-v1"
    public static let requiredSymbolSet = stableReleaseSymbolSet

    public static var compiledWithHASApplePQCSDK: Bool {
        #if HAS_APPLE_PQC_SDK
        true
        #else
        false
        #endif
    }

    public static var compileMarker: String {
        #if HAS_APPLE_PQC_SDK
        "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk"
        #else
        "skybridge.apple-pqc-sdk.compile-fact.v1.missing-has-apple-pqc-sdk"
        #endif
    }
}
