import Foundation
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

    /// Settings initialization calls this once per launch. It drives the
    /// production provisioning chain (signed-policy verification, durable
    /// Keychain CAS, native probe, immutable registry install) and stays
    /// fail-closed: on any failure the suite remains dark and the failure is
    /// logged, because a policy that cannot be verified must never surface as
    /// a supported capability.
    public static func prepareLocalRuntimeSupport() async -> Bool {
        #if os(macOS)
        do {
            switch try await QPeriaptProductionRuntime.prepareProductionSession() {
            case .unprovisioned:
                SkyBridgeLogger.p2p.info(
                    "Q-Periapt ABI2 未配置生产信任根；套件 0x0012 保持停用且不广告"
                )
            case .alreadyActive:
                break
            case .activated:
                SkyBridgeLogger.p2p.info("Q-Periapt ABI2 生产策略会话已激活")
            }
        } catch is CancellationError {
            SkyBridgeLogger.p2p.info("Q-Periapt ABI2 启动准备已取消；套件保持停用")
        } catch {
            SkyBridgeLogger.p2p.error(
                "Q-Periapt ABI2 生产策略会话激活失败；套件保持停用: \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
        return isLocalRuntimeSupported
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
        guard let platform = platform?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              let osVersion = osVersion?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !platform.isEmpty,
              !osVersion.isEmpty else {
            return false
        }

        let expectedFamily: PeerPlatformFamily
        switch platform {
        case "ios": expectedFamily = .iOS
        case "macos", "mac os": expectedFamily = .macOS
        case "android": expectedFamily = .android
        default: return false
        }

        let fullVersion: String
        if Self.matches(osVersion, pattern: #"^\d{1,3}(?:\.\d{1,3}){0,2}$"#) {
            guard expectedFamily != .android else { return false }
            fullVersion = "\(expectedFamily.capabilityName) \(osVersion)"
        } else {
            fullVersion = osVersion
        }

        guard let parsed = parseFullPlatformVersion(fullVersion),
              parsed.family == expectedFamily else {
            return false
        }
        return parsed.isEligible
    }

    private static func isPeerPlatformVersionStringEligible(_ platformVersion: String?) -> Bool {
        guard let trimmedPlatformVersion = platformVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedPlatformVersion.isEmpty else {
            return false
        }
        return parseFullPlatformVersion(trimmedPlatformVersion)?.isEligible == true
    }

    public static func requirePeerAppPlatformEligible(platform: String?, osVersion: String?) throws {
        guard isPeerAppPlatformEligible(platform: platform, osVersion: osVersion) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "Q-Periapt peer key requires macOS 26+, iOS 26+, or Android 16 / API 36+"
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

    private static func parseFullPlatformVersion(
        _ value: String
    ) -> ParsedPeerPlatformVersion? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let match = firstMatch(
            in: trimmed,
            pattern: #"(?i)^(ios|macos|mac\s+os)\s+(\d{1,3})(?:\.\d{1,3}){0,2}$"#
        ), let familyName = capturedString(in: trimmed, match: match, capture: 1)?
            .lowercased(),
           let major = capturedInteger(in: trimmed, match: match, capture: 2) {
            let family: PeerPlatformFamily = familyName == "ios" ? .iOS : .macOS
            return ParsedPeerPlatformVersion(family: family, major: major, api: nil)
        }

        if let match = firstMatch(
            in: trimmed,
            pattern: #"(?i)^android\s+(\d{1,3})(?:\.\d{1,3}){0,2}\s*(?:\(\s*api\s*(\d{1,3})\s*\)|api\s*(\d{1,3}))$"#
        ), let releaseMajor = capturedInteger(in: trimmed, match: match, capture: 1),
           let api = capturedInteger(in: trimmed, match: match, capture: 2)
            ?? capturedInteger(in: trimmed, match: match, capture: 3) {
            return ParsedPeerPlatformVersion(
                family: .android,
                major: releaseMajor,
                api: api
            )
        }

        return nil
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        firstMatch(in: value, pattern: pattern) != nil
    }

    private static func firstMatch(
        in value: String,
        pattern: String
    ) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range)
    }

    private static func capturedInteger(
        in value: String,
        match: NSTextCheckingResult,
        capture: Int
    ) -> Int? {
        capturedString(in: value, match: match, capture: capture).flatMap(Int.init)
    }

    private static func capturedString(
        in value: String,
        match: NSTextCheckingResult,
        capture: Int
    ) -> String? {
        guard capture < match.numberOfRanges else { return nil }
        let captureRange = match.range(at: capture)
        guard captureRange.location != NSNotFound,
              let valueRange = Range(captureRange, in: value)
        else {
            return nil
        }
        return String(value[valueRange])
    }

    private enum PeerPlatformFamily: Equatable {
        case iOS
        case macOS
        case android

        var capabilityName: String {
            switch self {
            case .iOS: return "iOS"
            case .macOS: return "macOS"
            case .android: return "Android"
            }
        }
    }

    private struct ParsedPeerPlatformVersion {
        let family: PeerPlatformFamily
        let major: Int
        let api: Int?

        var isEligible: Bool {
            switch family {
            case .iOS, .macOS:
                return major >= minimumAppleMajorVersion
            case .android:
                return major >= 16 && api.map { $0 >= 36 } == true
            }
        }
    }
}
