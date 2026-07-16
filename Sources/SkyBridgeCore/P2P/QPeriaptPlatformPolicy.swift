import Foundation
import os
#if canImport(CQPeriapt)
import CQPeriapt
#endif

private final class QPeriaptRuntimeAdmissionState: Sendable {
    private let runtimeSession = OSAllocatedUnfairLock<QPeriaptRuntimeSession?>(initialState: nil)

    func session() -> QPeriaptRuntimeSession? {
        runtimeSession.withLock { $0 }
    }

    func install(_ session: QPeriaptRuntimeSession) throws {
        try runtimeSession.withLock { installedSession in
            if let current = installedSession,
               current.trustRootIdentifier != session.trustRootIdentifier {
                throw CryptoProviderError.operationFailed(
                    "Q-Periapt trust root replacement requires an explicit reset/re-enrollment flow"
                )
            }
            if let current = installedSession {
                guard session.policyVersion >= current.policyVersion else {
                    throw CryptoProviderError.operationFailed(
                        "Q-Periapt runtime session rollback was rejected"
                    )
                }
                guard session.policyVersion != current.policyVersion
                        || session.policyDigest == current.policyDigest else {
                    throw CryptoProviderError.operationFailed(
                        "Q-Periapt runtime session reused a policy version with a different digest"
                    )
                }
            }
            installedSession = session
        }
    }

    #if DEBUG || SKYBRIDGE_TESTING
    func resetForTesting() {
        runtimeSession.withLock { $0 = nil }
    }
    #endif
}

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
        runtimeAdmissionState.session()?.authProfile
            ?? "q-periapt-abi2-policy-unprovisioned"
    }
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

    private static let runtimeAdmissionState = QPeriaptRuntimeAdmissionState()

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
        runtimeAdmissionState.session() != nil
    }

    /// Existing settings initialization calls this method before a product
    /// policy has necessarily been provisioned. It is intentionally fail-closed;
    /// only `activateRuntimeSession` can install an authenticated session.
    public static func prepareLocalRuntimeSupport() async -> Bool {
        isLocalRuntimeSupported
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
        try runtimeAdmissionState.install(session)
    }

    static func currentRuntimeSession() -> QPeriaptRuntimeSession? {
        runtimeAdmissionState.session()
    }

    static func makeCryptoProvider() -> QPeriaptCryptoProvider? {
        currentRuntimeSession().map(QPeriaptCryptoProvider.init(session:))
    }

    #if DEBUG || SKYBRIDGE_TESTING
    /// Restores the process-wide admission boundary between tests. Production
    /// builds intentionally expose no reset because replacing an enrolled trust
    /// root requires the explicit product re-enrollment flow.
    static func resetRuntimeSessionForTesting() {
        runtimeAdmissionState.resetForTesting()
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
        guard let session = currentRuntimeSession() else { return false }
        return isHandshakePeerEligible(capabilities, for: session)
    }

    static func isHandshakePeerEligible(
        _ capabilities: CryptoCapabilities,
        for session: QPeriaptRuntimeSession
    ) -> Bool {
        return capabilities.pqcAvailable &&
            capabilities.supportedKEM.contains { canonicalCapabilityToken($0) == canonicalCapabilityToken(P2PCryptoAlgorithm.qperiaptABI2PolicyBound.rawValue) } &&
            capabilities.supportedSignature.contains { canonicalCapabilityToken($0) == canonicalCapabilityToken(P2PCryptoAlgorithm.mlDSA65.rawValue) } &&
            capabilities.supportedAuthProfiles.contains { $0 == session.authProfile } &&
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
