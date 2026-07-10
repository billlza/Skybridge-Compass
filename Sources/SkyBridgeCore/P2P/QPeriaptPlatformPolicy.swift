import Foundation
#if canImport(CQPeriapt)
import CQPeriapt
#endif

/// Runtime admission policy for the experimental Q-Periapt suite.
///
/// Q-Periapt is beta-only. Advertisement, provider routing, and bootstrap
/// export must all pass the same gate so a UI setting or environment flag cannot
/// make older Apple platforms look Q-capable.
@available(macOS 14.0, iOS 17.0, *)
public enum QPeriaptPlatformPolicy {
    public static let authProfile = "q-periapt-beta"
    #if canImport(CQPeriapt)
    public static let publicKeyLength = Int(Q_PERIAPT_MLKEM768_PK_LEN) + Int(Q_PERIAPT_X25519_LEN)
    public static let privateKeyLength = Int(Q_PERIAPT_MLKEM768_SK_LEN)
        + Int(Q_PERIAPT_X25519_LEN)
        + Int(Q_PERIAPT_MLKEM768_PK_LEN)
        + Int(Q_PERIAPT_X25519_LEN)
    #else
    public static let publicKeyLength = 1_216
    public static let privateKeyLength = 3_648
    #endif

    private static let minimumAppleMajorVersion = 26

    private static let localRuntimeProbeSucceeded: Bool = {
        #if canImport(CQPeriapt)
        if #available(macOS 26.0, iOS 26.0, *) {
            return QPeriaptCryptoProvider.quickRuntimeProbe()
        }
        #endif
        return false
    }()

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
        localRuntimeProbeSucceeded
    }

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
        guard let trimmedPlatform = platform?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedPlatform.isEmpty else {
            return false
        }
        return isEligible(parsePeerPlatformVersion(platform: trimmedPlatform, osVersion: osVersion))
    }

    private static func isPeerPlatformVersionStringEligible(_ platformVersion: String?) -> Bool {
        guard let trimmedPlatformVersion = platformVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedPlatformVersion.isEmpty else {
            return false
        }
        return isEligible(parsePeerPlatformVersion(platform: trimmedPlatformVersion, osVersion: nil))
    }

    private static func isEligible(_ parsed: PeerPlatformVersion) -> Bool {
        switch parsed {
        case .apple(_, let major):
            return major.map { $0 >= minimumAppleMajorVersion } ?? false
        case .android(let releaseMajor, let api):
            return releaseMajor.map { $0 >= 16 } == true && api.map { $0 >= 36 } == true
        case .unsupported:
            return false
        }
    }

    public static func requirePeerAppPlatformEligible(platform: String?, osVersion: String?) throws {
        guard isPeerAppPlatformEligible(platform: platform, osVersion: osVersion) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "Q-Periapt peer key requires macOS 26+, iOS 26+, or Android 16 / API 36+"
            )
        }
    }

    public static func isHandshakePeerEligible(_ capabilities: CryptoCapabilities) -> Bool {
        capabilities.pqcAvailable &&
            capabilities.supportedKEM.contains { canonicalCapabilityToken($0) == canonicalCapabilityToken(P2PCryptoAlgorithm.qperiaptContextBound.rawValue) } &&
            capabilities.supportedSignature.contains { canonicalCapabilityToken($0) == canonicalCapabilityToken(P2PCryptoAlgorithm.mlDSA65.rawValue) } &&
            capabilities.supportedAuthProfiles.contains { canonicalCapabilityToken($0) == canonicalCapabilityToken(authProfile) } &&
            capabilities.providerType == .qPeriapt &&
            isPeerPlatformVersionStringEligible(capabilities.platformVersion)
    }

    public static func requireHandshakePeerEligible(_ capabilities: CryptoCapabilities) throws {
        guard isHandshakePeerEligible(capabilities) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "Q-Periapt peer capability requires Q provider, ML-DSA-65, q-periapt-beta, and supported platform"
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

    private static func canonicalCapabilityToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { character in
                character.isLetter || character.isNumber
            }
    }

    private static func parsePeerPlatformVersion(platform: String?, osVersion: String?) -> PeerPlatformVersion {
        let platformValue = platform?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let versionValue = osVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let combined = [platformValue, versionValue?.lowercased()]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " ")

        guard !combined.isEmpty else { return .unsupported }

        if combined.contains("android") || combined.contains("api ") {
            return .android(
                releaseMajor: androidReleaseMajor(from: combined),
                api: androidAPI(from: combined)
            )
        }

        if combined.contains("macos") || combined.contains("mac os") {
            return .apple(name: "macOS", major: firstMajor(from: versionValue ?? combined))
        }

        if combined.range(of: #"\bios\b"#, options: .regularExpression) != nil {
            return .apple(name: "iOS", major: firstMajor(from: versionValue ?? combined))
        }

        return .unsupported
    }

    private static func firstMajor(from value: String) -> Int? {
        firstMatch(in: value, pattern: #"\d{1,3}"#)
    }

    private static func androidReleaseMajor(from value: String) -> Int? {
        firstMatch(in: value, pattern: #"\bandroid\s+(\d{1,3})\b"#)
    }

    private static func androidAPI(from value: String) -> Int? {
        firstMatch(in: value, pattern: #"\bapi\s*(\d{1,3})\b"#)
    }

    private static func firstMatch(in value: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
        guard captureRange.location != NSNotFound,
              let valueRange = Range(captureRange, in: value)
        else { return nil }
        return Int(value[valueRange])
    }

    private enum PeerPlatformVersion {
        case apple(name: String, major: Int?)
        case android(releaseMajor: Int?, api: Int?)
        case unsupported
    }
}
