import Foundation
import SwiftUI

/// 本地化管理器
@MainActor
public class LocalizationManager: ObservableObject {
    public static let instance = LocalizationManager()
    
    @Published public var currentLanguage: AppLanguage = .english {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "app_language")
        }
    }
    
    public var locale: Locale {
        currentLanguage.locale
    }

    private var bundleCache: [AppLanguage: Bundle] = [:]
    
    private init() {
        if let languageString = UserDefaults.standard.string(forKey: "app_language"),
           let language = AppLanguage(rawValue: languageString) {
            currentLanguage = language
        }
    }
    
    public func localizedString(_ key: String) -> String {
        localizedString(key, table: nil)
    }

    public func localizedString(_ key: String, table: String?) -> String {
        let bundle = bundleForCurrentLanguage()
        let value = bundle.localizedString(forKey: key, value: nil, table: table)
        // 如果当前语言 bundle 缺失/未包含该 key，则回退到主 bundle（系统语言）
        if value == key {
            return Bundle.main.localizedString(forKey: key, value: nil, table: table)
        }
        return value
    }

    private func bundleForCurrentLanguage() -> Bundle {
        if let cached = bundleCache[currentLanguage] {
            return cached
        }
        // English 默认走主 bundle（通常没有 en.lproj 或不需要强制）
        if currentLanguage == .english {
            bundleCache[currentLanguage] = .main
            return .main
        }
        if let path = Bundle.main.path(forResource: currentLanguage.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            bundleCache[currentLanguage] = bundle
            return bundle
        }
        bundleCache[currentLanguage] = .main
        return .main
    }
}
