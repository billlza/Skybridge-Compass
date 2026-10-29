import SwiftUI
import Combine

private struct LocalizationBundleCacheKey: Hashable {
    let bundlePath: String
    let languageCode: String
}

private struct LocalizationPreferenceSnapshot: Sendable {
    let languageCode: String
    let isSystemPreference: Bool
}

private struct LocalizationStringCacheKey: Hashable {
    let key: String
    let bundlePath: String
    let languageCode: String
    let isSystemPreference: Bool
}

private final class LocalizationBundleLookupCache: @unchecked Sendable {
    private enum CachedBundle {
        case found(Bundle)
        case missing
    }

    private let lock = NSLock()
    private var localizedBundles: [LocalizationBundleCacheKey: CachedBundle] = [:]
    private var resourceBundlesByKey: [String: [Bundle]] = [:]
    private var resourceSearchRootsByBundlePath: [String: [URL]] = [:]
    private var defaultResourceRootsByExecutablePath: [String: [URL]] = [:]
    private var localizedStrings: [LocalizationStringCacheKey: String] = [:]
    private var preferenceSnapshot: LocalizationPreferenceSnapshot?

    func localizedBundle(
        in bundle: Bundle,
        languageCode: String,
        lookup: () -> Bundle?
    ) -> Bundle? {
        localizedBundle(
            cachePath: bundle.bundleURL.standardizedFileURL.path,
            languageCode: languageCode,
            lookup: lookup
        )
    }

    func localizedBundle(
        cachePath: String,
        languageCode: String,
        lookup: () -> Bundle?
    ) -> Bundle? {
        let key = LocalizationBundleCacheKey(bundlePath: cachePath, languageCode: languageCode)

        lock.lock()
        if let cached = localizedBundles[key] {
            lock.unlock()
            switch cached {
            case .found(let bundle):
                return bundle
            case .missing:
                return nil
            }
        }
        lock.unlock()

        let resolved = lookup()

        lock.lock()
        localizedBundles[key] = resolved.map(CachedBundle.found) ?? .missing
        lock.unlock()

        return resolved
    }

    func resourceBundles(cacheKey: String, lookup: () -> [Bundle]) -> [Bundle] {
        lock.lock()
        if let cached = resourceBundlesByKey[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = lookup()

        lock.lock()
        resourceBundlesByKey[cacheKey] = resolved
        lock.unlock()

        return resolved
    }

    func resourceSearchBaseURLs(cacheKey: String, lookup: () -> [URL]) -> [URL] {
        lock.lock()
        if let cached = resourceSearchRootsByBundlePath[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = lookup()

        lock.lock()
        resourceSearchRootsByBundlePath[cacheKey] = resolved
        lock.unlock()

        return resolved
    }

    func defaultResourceSearchBaseURLs(executablePath: String, lookup: () -> [URL]) -> [URL] {
        lock.lock()
        if let cached = defaultResourceRootsByExecutablePath[executablePath] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = lookup()

        lock.lock()
        defaultResourceRootsByExecutablePath[executablePath] = resolved
        lock.unlock()

        return resolved
    }

    func preferenceSnapshot(lookup: () -> LocalizationPreferenceSnapshot) -> LocalizationPreferenceSnapshot {
        lock.lock()
        if let cached = preferenceSnapshot {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = lookup()

        lock.lock()
        preferenceSnapshot = resolved
        lock.unlock()

        return resolved
    }

    func updatePreferenceSnapshot(_ snapshot: LocalizationPreferenceSnapshot) {
        lock.lock()
        preferenceSnapshot = snapshot
        localizedStrings.removeAll()
        lock.unlock()
    }

    func invalidateRuntimePreferences() {
        lock.lock()
        preferenceSnapshot = nil
        localizedStrings.removeAll()
        lock.unlock()
    }

    func localizedString(key: LocalizationStringCacheKey, lookup: () -> String) -> String {
        lock.lock()
        if let cached = localizedStrings[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = lookup()

        lock.lock()
        localizedStrings[key] = resolved
        lock.unlock()

        return resolved
    }
}

/// 本地化管理器 - 负责应用内语言动态切换
@MainActor
public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()
    private nonisolated static let lookupCache = LocalizationBundleLookupCache()
    nonisolated static let runtimePreferenceInvalidationNotificationNames: [Notification.Name] = [
        UserDefaults.didChangeNotification,
        NSLocale.currentLocaleDidChangeNotification,
    ]
    
    private let kAppLanguageKey = "AppLanguagePreference"
    
    @Published public private(set) var currentLanguage: AppLanguage = .system
    @Published public private(set) var locale: Locale = .current
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
 // 从 UserDefaults 加载设置
        if let storedValue = UserDefaults.standard.string(forKey: kAppLanguageKey),
           let language = AppLanguage(rawValue: storedValue) {
            self.currentLanguage = language
        } else {
            self.currentLanguage = .system
        }
        
        updateLocale()
        Self.lookupCache.updatePreferenceSnapshot(Self.makePreferenceSnapshot(storedValue: currentLanguage.rawValue))

        for notificationName in Self.runtimePreferenceInvalidationNotificationNames {
            Self.makeRuntimePreferenceInvalidationSubscription(for: notificationName)
                .store(in: &cancellables)
        }
    }
    
    public func setLanguage(_ language: AppLanguage) {
        self.currentLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: kAppLanguageKey)
        updateLocale()
        Self.lookupCache.updatePreferenceSnapshot(Self.makePreferenceSnapshot(storedValue: language.rawValue))
    }
    
    private func updateLocale() {
        if let identifier = currentLanguage.localeIdentifier {
            self.locale = Locale(identifier: identifier)
        } else {
            self.locale = .current
        }
    }
    
 /// 获取当前生效的语言代码（用于加载资源）
    private nonisolated static func runtimePreferenceSnapshot() -> LocalizationPreferenceSnapshot {
        lookupCache.preferenceSnapshot {
            makePreferenceSnapshot(storedValue: UserDefaults.standard.string(forKey: "AppLanguagePreference"))
        }
    }

    private nonisolated static func makePreferenceSnapshot(storedValue: String?) -> LocalizationPreferenceSnapshot {
        if let storedValue,
           let language = AppLanguage(rawValue: storedValue),
           let code = language.localeIdentifier {
            return LocalizationPreferenceSnapshot(languageCode: code, isSystemPreference: false)
        }

        return LocalizationPreferenceSnapshot(
            languageCode: systemPreferredLanguageCode(),
            isSystemPreference: true
        )
    }

    private nonisolated static func makeRuntimePreferenceInvalidationSubscription(
        for notificationName: Notification.Name
    ) -> AnyCancellable {
        NotificationCenter.default
            .publisher(for: notificationName)
            .sink(receiveValue: invalidateRuntimePreferenceCache)
    }

    private nonisolated static func invalidateRuntimePreferenceCache(_: Notification) {
        lookupCache.invalidateRuntimePreferences()
    }

    private nonisolated static func systemPreferredLanguageCode() -> String {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        if preferred.hasPrefix("ja") { return "ja" }
        if preferred.hasPrefix("ko") { return "ko" }
        if preferred.hasPrefix("es") { return "es" }
        return "en"
    }
    
 /// 获取本地化字符串（用于非 SwiftUI 环境）
 /// - Parameters:
 /// - key: Localizable.strings 中的 key
 /// - bundle: 资源包，默认为 Bundle.module (当前模块资源)
 /// - Returns: 翻译后的字符串
    public nonisolated func localizedString(_ key: String, bundle: Bundle? = nil) -> String {
        let preference = LocalizationManager.runtimePreferenceSnapshot()
        let bundlePath = bundle?.bundlePath ?? "<default>"
        let cacheKey = LocalizationStringCacheKey(
            key: key,
            bundlePath: bundlePath,
            languageCode: preference.languageCode,
            isSystemPreference: preference.isSystemPreference
        )

        return Self.lookupCache.localizedString(key: cacheKey) {
            localizedStringUncached(key, bundle: bundle, preference: preference)
        }
    }

    private nonisolated func localizedStringUncached(
        _ key: String,
        bundle: Bundle?,
        preference: LocalizationPreferenceSnapshot
    ) -> String {
        let languageCode = preference.languageCode
        if bundle == nil,
           let value = localizedStringFromDefaultResourceRoots(key, languageCode: languageCode) {
            return value
        }

        let primaryBundle = bundle ?? Bundle.main
        let secondaryBundle = SkyBridgeResourceBundleLocator.core

 // 系统默认语言直接查找（避免返回原始key）
        let systemValue = primaryBundle.localizedString(forKey: key, value: nil, table: nil)
        if systemValue != key, preference.isSystemPreference {
            return systemValue
        }

        if let localizedBundle = findLocalizedBundle(in: primaryBundle, languageCode: languageCode) {
            let v = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
            if v != key { return v }
        }
        if let localizedBundle = findLocalizedBundle(in: secondaryBundle, languageCode: languageCode) {
            let v = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
            if v != key { return v }
        }
        
 // 搜索 Bundle.main 的 Resources 目录下的 SPM 资源 bundle
 // SPM 生成的资源 bundle 可能不在 Bundle.allBundles 中
        for spmBundle in discoverSPMResourceBundles() {
            if let localizedBundle = findLocalizedBundle(in: spmBundle, languageCode: languageCode) {
                let v = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
                if v != key { return v }
            }
        }
        
 // 遍历所有已加载的Bundle（包括其他目标/插件）
        for bundle in (Bundle.allBundles + Bundle.allFrameworks) {
            if let localizedBundle = findLocalizedBundle(in: bundle, languageCode: languageCode) {
                let v = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
                if v != key { return v }
            }
        }
        if let fallbackBundle = findLocalizedBundle(in: primaryBundle, languageCode: "en") ??
            findLocalizedBundle(in: secondaryBundle, languageCode: "en") {
            let v = fallbackBundle.localizedString(forKey: key, value: nil, table: nil)
            if v != key { return v }
        }
        for bundle in (Bundle.allBundles + Bundle.allFrameworks) {
            if let localizedBundle = findLocalizedBundle(in: bundle, languageCode: "en") {
                let v = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
                if v != key { return v }
            }
        }
 // SPM bundle 英文回退
        for spmBundle in discoverSPMResourceBundles() {
            if let localizedBundle = findLocalizedBundle(in: spmBundle, languageCode: "en") {
                let v = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
                if v != key { return v }
            }
        }
        return systemValue
    }

    private nonisolated func localizedStringFromDefaultResourceRoots(
        _ key: String,
        languageCode: String
    ) -> String? {
        let resourceRoots = defaultResourceSearchBaseURLs()
        guard !resourceRoots.isEmpty else { return nil }

        for code in localizedLanguageSearchOrder(for: languageCode) {
            for root in resourceRoots {
                guard let localizedBundle = findLocalizedBundle(inResourceRoot: root, languageCode: code) else {
                    continue
                }
                let value = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
                if value != key {
                    return value
                }
            }
        }

        // A miss in the executable-relative resource roots is not authoritative.
        // SwiftPM targets can still resolve the key from Bundle.module, so allow
        // localizedStringUncached to continue through its existing bundle chain.
        return nil
    }
    
 /// 发现 Bundle.main 的 Resources 目录下的 SPM 资源 bundle
 /// SPM 打包的应用会将各模块的资源放在 .app/Contents/Resources/*.bundle 中
    private nonisolated func discoverSPMResourceBundles() -> [Bundle] {
        let resourceRoots = resourceSearchBaseURLs(for: Bundle.main)
        let cacheKey = resourceRoots
            .map { $0.standardizedFileURL.path }
            .joined(separator: "|")

        return Self.lookupCache.resourceBundles(cacheKey: cacheKey) {
            var bundles: [Bundle] = []
            let fileManager = FileManager.default

            for resourceURL in resourceRoots {
                guard let contents = try? fileManager.contentsOfDirectory(
                    at: resourceURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for url in contents where url.pathExtension == "bundle" {
                    if let bundle = Bundle(url: url) {
                        bundles.append(bundle)
                    }
                }
            }
            return bundles
        }
    }

    private nonisolated func findLocalizedBundle(in bundle: Bundle, languageCode: String) -> Bundle? {
        Self.lookupCache.localizedBundle(in: bundle, languageCode: languageCode) {
            findLocalizedBundleUncached(in: bundle, languageCode: languageCode)
        }
    }

    private nonisolated func findLocalizedBundle(inResourceRoot root: URL, languageCode: String) -> Bundle? {
        Self.lookupCache.localizedBundle(
            cachePath: root.standardizedFileURL.path,
            languageCode: languageCode
        ) {
            findLocalizedBundleUncached(inResourceRoot: root, languageCode: languageCode)
        }
    }

    private nonisolated func findLocalizedBundleUncached(in bundle: Bundle, languageCode: String) -> Bundle? {
        let fileManager = FileManager.default
        let languageCandidates = localizedLanguageSearchOrder(for: languageCode, includeEnglishFallback: false)
        let resourceRoots = resourceSearchBaseURLs(for: bundle)
        return findLocalizedBundleUncached(
            inResourceRoots: resourceRoots,
            languageCandidates: languageCandidates,
            fileManager: fileManager
        )
    }

    private nonisolated func findLocalizedBundleUncached(inResourceRoot root: URL, languageCode: String) -> Bundle? {
        let fileManager = FileManager.default
        let languageCandidates = localizedLanguageSearchOrder(for: languageCode, includeEnglishFallback: false)
        return findLocalizedBundleUncached(
            inResourceRoots: [root],
            languageCandidates: languageCandidates,
            fileManager: fileManager
        )
    }

    private nonisolated func findLocalizedBundleUncached(
        inResourceRoots resourceRoots: [URL],
        languageCandidates: [String],
        fileManager: FileManager
    ) -> Bundle? {
        for root in resourceRoots {
            for code in languageCandidates {
                let url = root.appendingPathComponent("\(code).lproj", isDirectory: true)
                if isDirectory(url, fileManager: fileManager),
                   let localizedBundle = Bundle(url: url) {
                    return localizedBundle
                }
            }
        }

        for root in resourceRoots {
            let localizationRoot = root.appendingPathComponent("Localization", isDirectory: true)
            for code in languageCandidates {
                let url = localizationRoot.appendingPathComponent("\(code).lproj", isDirectory: true)
                if isDirectory(url, fileManager: fileManager),
                   let localizedBundle = Bundle(url: url) {
                    return localizedBundle
                }
            }
        }

        for root in resourceRoots {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let targetNames = Set(languageCandidates.map { "\($0).lproj".lowercased() })
            if let match = urls.first(where: { targetNames.contains($0.lastPathComponent.lowercased()) }),
               let localizedBundle = Bundle(url: match) {
                return localizedBundle
            }
        }
        return nil
    }

    private nonisolated func localizedLanguageSearchOrder(
        for languageCode: String,
        includeEnglishFallback: Bool = true
    ) -> [String] {
        var candidates: [String] = []
        for code in [languageCode, languageCode.lowercased()] {
            guard !candidates.contains(code) else { continue }
            candidates.append(code)
        }
        if includeEnglishFallback {
            for code in ["en", "en".lowercased()] where !candidates.contains(code) {
                candidates.append(code)
            }
        }
        return candidates
    }

    private nonisolated func defaultResourceSearchBaseURLs() -> [URL] {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            return []
        }

        return Self.lookupCache.defaultResourceSearchBaseURLs(executablePath: executablePath) {
            defaultResourceSearchBaseURLsUncached(executablePath: executablePath)
        }
    }

    private nonisolated func defaultResourceSearchBaseURLsUncached(executablePath: String) -> [URL] {
        let fileManager = FileManager.default

        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        let executableDirectory = executableURL.deletingLastPathComponent()
        var candidates: [URL] = []

        if executableDirectory.lastPathComponent == "MacOS" {
            let contentsURL = executableDirectory.deletingLastPathComponent()
            if contentsURL.lastPathComponent == "Contents" {
                candidates.append(contentsURL.appendingPathComponent("Resources", isDirectory: true))
            }
        } else if executableDirectory.pathExtension == "app" {
            candidates.append(executableDirectory)
        }

        var roots: [URL] = []
        for candidate in candidates where isDirectory(candidate, fileManager: fileManager) {
            roots.append(candidate)
            guard let contents = try? fileManager.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for bundleURL in contents where bundleURL.pathExtension == "bundle" {
                let bundleResources = bundleURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                if isDirectory(bundleResources, fileManager: fileManager) {
                    roots.append(bundleResources)
                }
            }
        }

        var seen = Set<String>()
        return roots.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private nonisolated func resourceSearchBaseURLs(for bundle: Bundle) -> [URL] {
        let cacheKey = bundle.bundlePath
        return Self.lookupCache.resourceSearchBaseURLs(cacheKey: cacheKey) {
            resourceSearchBaseURLsUncached(for: bundle)
        }
    }

    private nonisolated func resourceSearchBaseURLsUncached(for bundle: Bundle) -> [URL] {
        let fileManager = FileManager.default
        let bundleURL = bundle.bundleURL.standardizedFileURL
        var candidates: [URL] = []

        let contentsResources = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        if isDirectory(contentsResources, fileManager: fileManager) {
            candidates.append(contentsResources)
        }

        if candidates.isEmpty,
           let resourceURL = bundle.resourceURL?.standardizedFileURL,
           isDirectory(resourceURL, fileManager: fileManager) {
            candidates.append(resourceURL)
        }

        if isDirectory(bundleURL, fileManager: fileManager) {
            candidates.append(bundleURL)
        }

        var seen = Set<String>()
        return candidates.filter { url in
            seen.insert(url.path).inserted
        }
    }

    private nonisolated func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
