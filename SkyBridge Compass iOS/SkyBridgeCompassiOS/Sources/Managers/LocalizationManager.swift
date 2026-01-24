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
    
    private init() {
        if let languageString = UserDefaults.standard.string(forKey: "app_language"),
           let language = AppLanguage(rawValue: languageString) {
            currentLanguage = language
        }
    }
    
    public func localizedString(_ key: String) -> String {
        // TODO: 实际本地化实现
        return NSLocalizedString(key, comment: "")
    }
}
