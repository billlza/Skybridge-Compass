import Foundation
import SkyBridgeProtocolCore
import SkyBridgeQPeriaptRuntime

/// Runtime admission policy for the experimental Q-Periapt suite.
///
/// Q-Periapt is beta-only. Advertisement, provider routing, and bootstrap
/// export must all pass the same gate so a UI setting or environment flag cannot
/// make older Apple platforms look Q-capable.
@available(macOS 14.0, iOS 17.0, *)
public enum QPeriaptPlatformPolicy {
    /// The exact policy identity is part of capability negotiation. This
    /// placeholder is never advertised because runtime admission stays false
    /// until a verified session is activated.
    public static var authProfile: String {
        runtimeSessionRegistry.snapshot()?.authProfile
            ?? "q-periapt-abi2-policy-unprovisioned"
    }
    public static let publicKeyLength = QPeriaptNativeAdapter.publicKeyLength
    public static let privateKeyLength = QPeriaptNativeAdapter.privateKeyLength

    private static let minimumAppleMajorVersion = 26

    private static let runtimeSessionRegistry = QPeriaptRuntimeSessionRegistry()

    public static func isRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        if isTruthy(environment["SB_ENABLE_QPERIAPT"]) {
            return true
        }

        if let preferredSuite = environment["SKYBRIDGE_PQC_PREFERRED_SUITE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           preferredSuite == "q-periapt" || preferredSuite == "qperiapt" {
            return true
        }

        return userDefaults.bool(forKey: SettingsStorageKeys.preferQPeriaptBeta)
    }

    public static var isLocalRuntimeSupported: Bool {
        runtimeSessionRegistry.snapshot() != nil
    }

    /// Prepare the existing production provisioning chain. Typed policy,
    /// persistence, and native errors reach the settings boundary unchanged;
    /// only `activateRuntimeSession` can install an authenticated session.
    public static func prepareLocalRuntimeSupport() async throws
        -> QPeriaptProductionPreparationResult {
        #if os(macOS)
        let result = try await QPeriaptProductionRuntime.prepareProductionSession()
        if result == .activated {
            SkyBridgeLogger.p2p.info("Q-Periapt ABI2 生产策略会话已激活")
        }
        return result
        #else
        throw CryptoProviderError.providerNotAvailable(.qPeriapt)
        #endif
    }

    /// A requested Q-only connection cannot become an ordinary handshake
    /// merely because policy, persistence, or native preparation failed.
    /// Returns the captured request so later identity/offer validation uses
    /// the same intent even if a preference changes while creation awaits.
    static func requireRequestedRuntimeAdmission(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) throws -> Bool {
        guard isRequested(environment: environment, userDefaults: userDefaults) else { return false }
        guard currentRuntimeSession() != nil else {
            throw CryptoProviderError.providerNotAvailable(.qPeriapt)
        }
        return true
    }

    /// Activates one session only after signed-policy verification, durable
    /// trusted-state persistence, ABI validation, and a native round trip.
    public static func activateRuntimeSession(_ session: QPeriaptRuntimeSession) async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw CryptoProviderError.providerNotAvailable(.qPeriapt)
        }
        guard try await QPeriaptCryptoProvider.quickRuntimeProbe(session: session) else {
            throw CryptoProviderError.operationFailed("Q-Periapt ABI2 runtime round-trip probe failed")
        }
        do {
            try runtimeSessionRegistry.install(session)
        } catch let error as QPeriaptRuntimeSessionRegistryError {
            throw CryptoProviderError.operationFailed(error.localizedDescription)
        }
    }

    static func currentRuntimeSession() -> QPeriaptRuntimeSession? {
        runtimeSessionRegistry.snapshot()
    }

    static func makeCryptoProvider() -> QPeriaptCryptoProvider? {
        currentRuntimeSession().map(QPeriaptCryptoProvider.init(session:))
    }

    #if DEBUG || SKYBRIDGE_TESTING
    /// Restores the process-wide admission boundary between tests. Production
    /// builds intentionally expose no reset because replacing an enrolled trust
    /// root requires the explicit product re-enrollment flow.
    static func resetRuntimeSessionForTesting() {
        runtimeSessionRegistry.resetForTesting()
    }
    #endif

    public static func isEnabledForLocalRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        isRequested(environment: environment, userDefaults: userDefaults) && isLocalRuntimeSupported
    }

    public static func localPlatformName() -> String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "Apple"
        #endif
    }

    public static func localOSVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(localPlatformName()) \(version.majorVersion).\(version.minorVersion)"
    }

    public static func isSupportedAppleOSVersion(_ osVersion: OperatingSystemVersion) -> Bool {
        osVersion.majorVersion >= minimumAppleMajorVersion
    }

    public static func isPeerAppPlatformEligible(platform: String?, osVersion: String?) -> Bool {
        QPeriaptPeerPlatformPolicy.isPeerAppPlatformEligible(
            platform: platform,
            osVersion: osVersion
        )
    }

    private static func isPeerPlatformVersionStringEligible(_ platformVersion: String?) -> Bool {
        QPeriaptPeerPlatformPolicy.isPeerHandshakePlatformVersionEligible(platformVersion)
    }

    public static func requirePeerAppPlatformEligible(platform: String?, osVersion: String?) throws {
        guard isPeerAppPlatformEligible(platform: platform, osVersion: osVersion) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "Q-Periapt peer key requires macOS/iOS 26+, Android 16 / API 36+, Ubuntu 24.04+, or Windows 10.0.19041+"
            )
        }
    }

    public static func isHandshakePeerEligible(_ capabilities: CryptoCapabilities) -> Bool {
        guard let session = currentRuntimeSession() else { return false }
        return isHandshakePeerEligible(capabilities, for: session)
    }

    static func isHandshakePeerEligible(
        _ capabilities: CryptoCapabilities,
        for session: QPeriaptRuntimeSession
    ) -> Bool {
        isHandshakePeerEligible(
            capabilities,
            for: QPeriaptProviderIdentity(
                authProfile: session.authProfile,
                trustRootFingerprint: session.trustRootFingerprint
            )
        )
    }

    static func isHandshakePeerEligible(
        _ capabilities: CryptoCapabilities,
        for identity: QPeriaptProviderIdentity
    ) -> Bool {
        return capabilities.pqcAvailable &&
            identity.trustRootFingerprint.count == 32 &&
            capabilities.supportedKEM.contains(P2PCryptoAlgorithm.qperiaptABI2PolicyBound.rawValue) &&
            capabilities.supportedSignature.contains(P2PCryptoAlgorithm.mlDSA65.rawValue) &&
            capabilities.supportedAuthProfiles.contains(identity.authProfile) &&
            capabilities.supportedAEAD.contains(P2PCryptoAlgorithm.aes256GCM.rawValue) &&
            capabilities.providerType == .qPeriapt &&
            isPeerPlatformVersionStringEligible(capabilities.platformVersion)
    }

    public static func requireHandshakePeerEligible(_ capabilities: CryptoCapabilities) throws {
        guard isHandshakePeerEligible(capabilities) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "Q-Periapt peer capability requires ABI2 PolicyBound, ML-DSA-65, an exact signed-policy identity, and a supported platform"
            )
        }
    }

    private static func isTruthy(_ raw: String?) -> Bool {
        guard let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }
        return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on"
    }

}
