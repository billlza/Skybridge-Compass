import SwiftUI
import Combine

/// 本地化管理器 - 负责应用内语言动态切换
@MainActor
public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()
    
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
    }
    
    public func setLanguage(_ language: AppLanguage) {
        self.currentLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: kAppLanguageKey)
        updateLocale()
    }
    
    private func updateLocale() {
        if let identifier = currentLanguage.localeIdentifier {
            self.locale = Locale(identifier: identifier)
        } else {
            self.locale = .current
        }
    }
    
 /// 获取当前生效的语言代码（用于加载资源）
    private nonisolated static func getEffectiveLanguageCodeStatic() -> String {
        if let storedValue = UserDefaults.standard.string(forKey: "AppLanguagePreference"),
           let language = AppLanguage(rawValue: storedValue),
           let code = language.localeIdentifier {
            return code
        }
 // 使用系统首选语言，映射到资源目录
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
        let languageCode = LocalizationManager.getEffectiveLanguageCodeStatic()
        let primaryBundle = bundle ?? Bundle.main
        let secondaryBundle = Bundle.module

 // 系统默认语言直接查找（避免返回原始key）
        let systemValue = primaryBundle.localizedString(forKey: key, value: nil, table: nil)
        let storedPref = UserDefaults.standard.string(forKey: "AppLanguagePreference")
        let isSystemPref: Bool
        if let storedPref, let pref = AppLanguage(rawValue: storedPref) {
            isSystemPref = pref == .system
        } else {
            isSystemPref = true
        }
        if systemValue != key, isSystemPref {
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
    
 /// 发现 Bundle.main 的 Resources 目录下的 SPM 资源 bundle
 /// SPM 打包的应用会将各模块的资源放在 .app/Contents/Resources/*.bundle 中
    private nonisolated func discoverSPMResourceBundles() -> [Bundle] {
        var bundles: [Bundle] = []
        guard let resourceURL = Bundle.main.resourceURL else { return bundles }
        
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return bundles }
        
        for url in contents where url.pathExtension == "bundle" {
            if let bundle = Bundle(url: url) {
                bundles.append(bundle)
            }
        }
        return bundles
    }

    private nonisolated func findLocalizedBundle(in bundle: Bundle, languageCode: String) -> Bundle? {
 // 顶层 lproj
        if let path = bundle.path(forResource: languageCode, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            return localizedBundle
        }
 // 尝试小写版本（SPM 生成的 bundle 可能使用小写目录名，如 zh-hans.lproj）
        let lowercaseCode = languageCode.lowercased()
        if let path = bundle.path(forResource: lowercaseCode, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            return localizedBundle
        }
 // Localization 子目录（SPM 子目录本地化）
        if let path = bundle.path(forResource: languageCode, ofType: "lproj", inDirectory: "Localization"),
           let localizedBundle = Bundle(path: path) {
            return localizedBundle
        }
 // 枚举所有 lproj 目录并匹配文件名（大小写不敏感）
        if let urls = bundle.urls(forResourcesWithExtension: "lproj", subdirectory: nil) {
            let targetName = "\(languageCode).lproj".lowercased()
            if let match = urls.first(where: { $0.lastPathComponent.lowercased() == targetName }),
               let localizedBundle = Bundle(url: match) {
                return localizedBundle
            }
        }
        return nil
    }
}
