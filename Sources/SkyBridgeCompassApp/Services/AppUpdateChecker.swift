import AppKit
import Foundation
import SkyBridgeCore

@available(macOS 14.0, *)
enum SkyBridgeAppVersionInfo {
    static func bundleIdentifier(bundle: Bundle = .main) -> String {
        bundle.bundleIdentifier ?? "com.skybridge.compass.pro"
    }

    static func version(bundle: Bundle = .main) -> String {
        stringValue(for: "CFBundleShortVersionString", in: bundle) ?? "0.0.0"
    }

    static func build(bundle: Bundle = .main) -> String {
        stringValue(for: "CFBundleVersion", in: bundle) ?? "0"
    }

    static func displayVersion(bundle: Bundle = .main) -> String {
        "\(version(bundle: bundle)) (Build \(build(bundle: bundle)))"
    }

    static func currentSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func stringValue(for key: String, in bundle: Bundle) -> String? {
        bundle.object(forInfoDictionaryKey: key) as? String
    }
}

@available(macOS 14.0, *)
protocol SkyBridgeAppUpdateManifestFetching: Sendable {
    func loadManifestData(from url: URL) async throws -> Data
}

@available(macOS 14.0, *)
protocol SkyBridgeAppUpdateSequenceStoring: Sendable {
    func highestAcceptedSequence() -> Int64
    func recordAcceptedSequence(_ sequence: Int64)
}

@available(macOS 14.0, *)
struct UserDefaultsSkyBridgeAppUpdateSequenceStore: SkyBridgeAppUpdateSequenceStoring, @unchecked Sendable {
    private static let key = "SkyBridgeAppUpdateHighestAcceptedManifestSequence"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func highestAcceptedSequence() -> Int64 {
        let value = defaults.object(forKey: Self.key)
        if let number = value as? NSNumber {
            return max(0, number.int64Value)
        }
        if let intValue = value as? Int {
            return max(0, Int64(intValue))
        }
        return 0
    }

    func recordAcceptedSequence(_ sequence: Int64) {
        guard sequence > highestAcceptedSequence() else { return }
        defaults.set(sequence, forKey: Self.key)
    }
}

@available(macOS 14.0, *)
struct URLSessionSkyBridgeAppUpdateManifestFetcher: SkyBridgeAppUpdateManifestFetching {
    func loadManifestData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

@available(macOS 14.0, *)
enum SkyBridgeAppUpdateCheckOutcome: Sendable {
    case success(SkyBridgeAppUpdateDecision)
    case failure(String)
}

@available(macOS 14.0, *)
struct SkyBridgeAppUpdateChecker: Sendable {
    private let manifestURL: URL
    private let fetcher: any SkyBridgeAppUpdateManifestFetching
    private let trustedSigningKeys: [SkyBridgeAppUpdateTrustedSigningKey]
    private let sequenceStore: any SkyBridgeAppUpdateSequenceStoring

    init(
        manifestURL: URL = Self.defaultManifestURL(),
        fetcher: any SkyBridgeAppUpdateManifestFetching = URLSessionSkyBridgeAppUpdateManifestFetcher(),
        sequenceStore: any SkyBridgeAppUpdateSequenceStoring = UserDefaultsSkyBridgeAppUpdateSequenceStore()
    ) {
        self.manifestURL = manifestURL
        self.fetcher = fetcher
        self.trustedSigningKeys = Self.defaultTrustedSigningKeys()
        self.sequenceStore = sequenceStore
    }

    #if DEBUG || SKYBRIDGE_TESTING
    init(
        manifestURL: URL,
        fetcher: any SkyBridgeAppUpdateManifestFetching,
        trustedSigningKeys: [SkyBridgeAppUpdateTrustedSigningKey],
        sequenceStore: any SkyBridgeAppUpdateSequenceStoring
    ) {
        self.manifestURL = manifestURL
        self.fetcher = fetcher
        self.trustedSigningKeys = trustedSigningKeys
        self.sequenceStore = sequenceStore
    }
    #endif

    func check() async -> SkyBridgeAppUpdateCheckOutcome {
        await Task.detached(priority: .utility) {
            await self.performCheck()
        }.value
    }

    private func performCheck() async -> SkyBridgeAppUpdateCheckOutcome {
        do {
            let data = try await fetcher.loadManifestData(from: manifestURL)
            let manifest = try SkyBridgeAppUpdateEvaluator.decodeManifest(from: data)
            let minimumSequence = sequenceStore.highestAcceptedSequence()
            let context = SkyBridgeAppUpdateContext(
                bundleIdentifier: SkyBridgeAppVersionInfo.bundleIdentifier(),
                currentVersion: SkyBridgeAppVersionInfo.version(),
                currentBuild: SkyBridgeAppVersionInfo.build(),
                channel: "stable",
                currentSystemVersion: SkyBridgeAppVersionInfo.currentSystemVersion(),
                minimumAcceptedManifestSequence: minimumSequence
            )
            let decision = try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context,
                trustedSigningKeys: trustedSigningKeys
            )
            sequenceStore.recordAcceptedSequence(decision.manifest.sequence)
            return .success(decision)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func defaultManifestURL(bundle: Bundle = .main) -> URL {
        #if DEBUG || SKYBRIDGE_TESTING
        if let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_UPDATE_MANIFEST_URL"],
           let url = URL(string: raw),
           url.scheme?.lowercased() == "https" {
            return url
        }
        #endif
        if let raw = bundle.object(forInfoDictionaryKey: "SKYBRIDGE_UPDATE_MANIFEST_URL") as? String,
           let url = URL(string: raw),
           url.scheme?.lowercased() == "https" {
            return url
        }
        return URL(string: "https://github.com/billlza/Skybridge-Compass/releases/latest/download/macos-stable.json")!
    }

    static func defaultTrustedSigningKeys(bundle: Bundle = .main) -> [SkyBridgeAppUpdateTrustedSigningKey] {
        let bundleKeys = parseTrustedSigningKeys(
            raw: bundle.object(forInfoDictionaryKey: "SKYBRIDGE_UPDATE_MANIFEST_ED25519_PUBLIC_KEYS") as? String
        )
        if !bundleKeys.isEmpty {
            return bundleKeys
        }

        #if DEBUG || SKYBRIDGE_TESTING
        let environment = ProcessInfo.processInfo.environment
        guard environment["SKYBRIDGE_ALLOW_UPDATE_TRUST_OVERRIDE"] == "1" else {
            return []
        }
        return parseTrustedSigningKeys(raw: environment["SKYBRIDGE_UPDATE_MANIFEST_ED25519_PUBLIC_KEYS"])
        #else
        return []
        #endif
    }

    private static func parseTrustedSigningKeys(raw: String?) -> [SkyBridgeAppUpdateTrustedSigningKey] {
        guard let raw else { return [] }
        return raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .compactMap { entry in
                let parts = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { return nil }
                let keyId = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let publicKey = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keyId.isEmpty, !publicKey.isEmpty else { return nil }
                return SkyBridgeAppUpdateTrustedSigningKey(
                    keyId: keyId,
                    publicKeyBase64: publicKey
                )
            }
    }
}

@available(macOS 14.0, *)
@MainActor
enum SkyBridgeAppUpdateController {
    private enum PresentationMode {
        case manual
        case automatic
    }

    private static var isChecking = false

    static func checkAndPresent() async {
        await checkAndPresent(mode: .manual)
    }

    static func scheduleAutomaticCheckAfterLaunch() {
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            await checkAndPresentAvailableUpdateIfDue()
        }
    }

    private static func checkAndPresentAvailableUpdateIfDue() async {
        let shouldCheck = await Task.detached(priority: .utility) {
            SkyBridgeAppUpdateAutomaticCheckPolicy().claimDueCheck()
        }.value
        guard shouldCheck else { return }
        await checkAndPresent(mode: .automatic)
    }

    private static func checkAndPresent(mode: PresentationMode) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let outcome = await SkyBridgeAppUpdateChecker().check()
        switch mode {
        case .manual:
            SkyBridgeAppUpdatePresenter.present(outcome)
        case .automatic:
            SkyBridgeAppUpdatePresenter.presentAutomaticUpdateIfNeeded(outcome)
        }
    }
}

@available(macOS 14.0, *)
@MainActor
enum SkyBridgeAppUpdatePresenter {
    static func present(_ outcome: SkyBridgeAppUpdateCheckOutcome) {
        switch outcome {
        case .success(let decision):
            present(decision)
        case .failure(let detail):
            let alert = baseAlert(
                titleKey: "update.failed.title",
                message: format("update.failed.message", detail)
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: localized("action.ok"))
            alert.runModal()
        }
    }

    static func presentAutomaticUpdateIfNeeded(_ outcome: SkyBridgeAppUpdateCheckOutcome) {
        guard case .success(let decision) = outcome else { return }
        switch decision.state {
        case .updateAvailable, .unsupportedSystemVersion:
            break
        case .upToDate:
            return
        }
        let didClaimPresentation = SkyBridgeAppUpdateAutomaticCheckPolicy()
            .claimPresentation(for: decision.manifest.sequence)
        guard didClaimPresentation else { return }
        present(decision)
    }

    private static func present(_ decision: SkyBridgeAppUpdateDecision) {
        switch decision.state {
        case .upToDate:
            let alert = baseAlert(
                titleKey: "update.latest.title",
                message: format("update.latest.message", SkyBridgeAppVersionInfo.displayVersion())
            )
            alert.addButton(withTitle: localized("action.ok"))
            alert.runModal()
        case .unsupportedSystemVersion:
            let alert = baseAlert(
                titleKey: "update.unsupported.title",
                message: format(
                    "update.unsupported.message",
                    decision.manifest.version,
                    decision.manifest.minimumSystemVersion,
                    SkyBridgeAppVersionInfo.currentSystemVersion()
                )
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: localized("action.ok"))
            alert.runModal()
        case .updateAvailable:
            let alert = baseAlert(
                titleKey: "update.available.title",
                message: format(
                    "update.available.message",
                    decision.manifest.version,
                    decision.manifest.build,
                    decision.manifest.minimumSystemVersion
                )
            )
            alert.addButton(withTitle: localized("update.download"))
            alert.addButton(withTitle: localized("update.later"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(decision.manifest.downloadURL)
            }
        }
    }

    private static func baseAlert(titleKey: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = localized(titleKey)
        alert.informativeText = message
        alert.alertStyle = .informational
        return alert
    }

    private static func localized(_ key: String) -> String {
        LocalizationManager.shared.localizedString(key)
    }

    private static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: LocalizationManager.shared.locale, arguments: arguments)
    }
}

@available(macOS 14.0, *)
private struct SkyBridgeAppUpdateAutomaticCheckPolicy: @unchecked Sendable {
    private static let lastCheckAtKey = "SkyBridgeAppUpdateLastAutomaticCheckAt"
    private static let lastPresentedSequenceKey = "SkyBridgeAppUpdateLastAutomaticPresentedSequence"
    private static let minimumAutomaticCheckInterval: TimeInterval = 6 * 60 * 60

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.now = now
    }

    func claimDueCheck() -> Bool {
        let current = now()
        if let lastCheckAt = defaults.object(forKey: Self.lastCheckAtKey) as? Date,
           current.timeIntervalSince(lastCheckAt) < Self.minimumAutomaticCheckInterval {
            return false
        }
        if let lastCheckInterval = defaults.object(forKey: Self.lastCheckAtKey) as? TimeInterval,
           current.timeIntervalSince(Date(timeIntervalSince1970: lastCheckInterval)) < Self.minimumAutomaticCheckInterval {
            return false
        }
        defaults.set(current, forKey: Self.lastCheckAtKey)
        return true
    }

    func claimPresentation(for sequence: Int64) -> Bool {
        guard sequence > 0 else { return false }
        let lastPresented: Int64
        if let number = defaults.object(forKey: Self.lastPresentedSequenceKey) as? NSNumber {
            lastPresented = number.int64Value
        } else if let intValue = defaults.object(forKey: Self.lastPresentedSequenceKey) as? Int {
            lastPresented = Int64(intValue)
        } else {
            lastPresented = 0
        }
        guard sequence > lastPresented else { return false }
        defaults.set(sequence, forKey: Self.lastPresentedSequenceKey)
        return true
    }
}
