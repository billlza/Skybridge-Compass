import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system      // 跟随系统
    case zhHans      // 简体中文
    case en          // 英文
    case ja          // 日文

    public var id: String { rawValue }

 /// 用于 UserDefaults 持久化显示名称
    public var storageKey: String { rawValue }

 /// 对应 Locale identifier；system 返回 nil，表示使用系统 Locale
    public var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .en: return "en"
        case .ja: return "ja"
        }
    }

 /// UI 显示名称
    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }
}
