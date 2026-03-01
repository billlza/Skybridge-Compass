import Foundation
import SwiftUI

/// 本地化管理器
@MainActor
public class LocalizationManager: ObservableObject {
    public static let instance = LocalizationManager()
    
    @Published public var currentLanguage: AppLanguage = .system {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "app_language")
        }
    }
    
    public var resolvedLanguage: AppLanguage {
        switch currentLanguage {
        case .system:
            return resolvedSystemLanguage(from: .autoupdatingCurrent)
        case .english, .chinese, .japanese:
            return currentLanguage
        }
    }

    public var locale: Locale {
        switch currentLanguage {
        case .system:
            return .autoupdatingCurrent
        case .english, .chinese, .japanese:
            return currentLanguage.locale
        }
    }

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
        RuntimeLocalization.string(key, table: table)
    }

    public func localized(_ key: String) -> String {
        if let value = Self.inlineTranslations[key]?[resolvedLanguage] {
            return value
        }
        return localizedString(key)
    }

    public func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
        if Self.inlineTranslations[key] != nil {
            let template = localized(key)
            return String(format: template, locale: locale, arguments: args)
        }
        return RuntimeLocalization.format(key, args)
    }

    public func displayName(for language: AppLanguage) -> String {
        switch language {
        case .system:
            return localized("language.system")
        case .english:
            return localized("language.english")
        case .chinese:
            return localized("language.chinese")
        case .japanese:
            return localized("language.japanese")
        }
    }

    private func resolvedSystemLanguage(from locale: Locale) -> AppLanguage {
        let id = locale.identifier.lowercased()
        if id.hasPrefix("zh") {
            return .chinese
        }
        if id.hasPrefix("ja") {
            return .japanese
        }
        return .english
    }

    private static let inlineTranslations: [String: [AppLanguage: String]] = [
        "language.system": [
            .english: "Follow System",
            .chinese: "跟随系统",
            .japanese: "システムに従う"
        ],
        "language.english": [
            .english: "English",
            .chinese: "英语",
            .japanese: "英語"
        ],
        "language.chinese": [
            .english: "Simplified Chinese",
            .chinese: "简体中文",
            .japanese: "簡体字中国語"
        ],
        "language.japanese": [
            .english: "Japanese",
            .chinese: "日语",
            .japanese: "日本語"
        ],
        "common.retry": [
            .english: "Retry",
            .chinese: "重试",
            .japanese: "再試行"
        ],
        "common.cancel": [
            .english: "Cancel",
            .chinese: "取消",
            .japanese: "キャンセル"
        ],
        "common.refresh": [
            .english: "Refresh",
            .chinese: "刷新",
            .japanese: "更新"
        ],
        "tab.discovery": [
            .english: "Discover",
            .chinese: "发现",
            .japanese: "発見"
        ],
        "tab.remote": [
            .english: "Remote",
            .chinese: "远程",
            .japanese: "リモート"
        ],
        "tab.files": [
            .english: "Files",
            .chinese: "文件",
            .japanese: "ファイル"
        ],
        "tab.settings": [
            .english: "Settings",
            .chinese: "设置",
            .japanese: "設定"
        ],
        "weather.loading": [
            .english: "Fetching weather...",
            .chinese: "正在获取天气...",
            .japanese: "天気情報を取得中..."
        ],
        "weather.permission_required": [
            .english: "Please make sure location permission is granted",
            .chinese: "请确保已授权位置权限",
            .japanese: "位置情報の許可を確認してください"
        ],
        "weather.disabled_title": [
            .english: "Real-time weather is off",
            .chinese: "实时天气已关闭",
            .japanese: "リアルタイム天気はオフです"
        ],
        "weather.disabled_hint": [
            .english: "Enable in Settings -> Advanced -> Real-time Weather (API)",
            .chinese: "可在 设置 -> 高级 打开实时天气（API）",
            .japanese: "設定 -> 詳細設定 でリアルタイム天気（API）を有効化できます"
        ],
        "weather.fetch_failed": [
            .english: "Weather fetch failed",
            .chinese: "天气获取失败",
            .japanese: "天気情報の取得に失敗しました"
        ],
        "weather.updated_just_now": [
            .english: "Updated just now",
            .chinese: "刚刚更新",
            .japanese: "たった今更新"
        ],
        "weather.updated_minutes_ago": [
            .english: "Updated %d min ago",
            .chinese: "%d分钟前",
            .japanese: "%d分前に更新"
        ],
        "weather.updated_hours_ago": [
            .english: "Updated %d h ago",
            .chinese: "%d小时前",
            .japanese: "%d時間前に更新"
        ],
        "weather.error.no_location": [
            .english: "Unable to get location",
            .chinese: "无法获取位置信息",
            .japanese: "位置情報を取得できません"
        ],
        "weather.error.api_error": [
            .english: "API error: %@",
            .chinese: "API错误: %@",
            .japanese: "APIエラー: %@"
        ],
        "weather.error.network_error": [
            .english: "Network request failed",
            .chinese: "网络连接失败",
            .japanese: "ネットワーク接続に失敗しました"
        ],
        "weather.error.invalid_response": [
            .english: "Invalid weather data",
            .chinese: "无效的天气数据",
            .japanese: "天気データが無効です"
        ],
        "weather.error.location_permission_denied": [
            .english: "Location permission denied",
            .chinese: "位置权限被拒绝",
            .japanese: "位置情報の権限が拒否されました"
        ],
        "weather.condition.clear": [
            .english: "Clear",
            .chinese: "晴朗",
            .japanese: "晴れ"
        ],
        "weather.condition.cloudy": [
            .english: "Cloudy",
            .chinese: "多云",
            .japanese: "くもり"
        ],
        "weather.condition.rainy": [
            .english: "Rain",
            .chinese: "雨天",
            .japanese: "雨"
        ],
        "weather.condition.snowy": [
            .english: "Snow",
            .chinese: "雪天",
            .japanese: "雪"
        ],
        "weather.condition.foggy": [
            .english: "Fog",
            .chinese: "雾天",
            .japanese: "霧"
        ],
        "weather.condition.haze": [
            .english: "Haze",
            .chinese: "雾霾",
            .japanese: "もや"
        ],
        "weather.condition.stormy": [
            .english: "Storm",
            .chinese: "暴风雨",
            .japanese: "雷雨"
        ],
        "weather.condition.unknown": [
            .english: "Unknown",
            .chinese: "未知",
            .japanese: "不明"
        ],
        "settings.title": [
            .english: "Settings",
            .chinese: "设置",
            .japanese: "設定"
        ],
        "settings.language": [
            .english: "Language",
            .chinese: "语言",
            .japanese: "言語"
        ],
        "settings.section.connection": [
            .english: "Connection",
            .chinese: "连接设置",
            .japanese: "接続設定"
        ],
        "settings.section.security": [
            .english: "Security & Privacy",
            .chinese: "安全与隐私",
            .japanese: "セキュリティとプライバシー"
        ],
        "settings.section.appearance": [
            .english: "Appearance",
            .chinese: "外观",
            .japanese: "外観"
        ],
        "settings.section.advanced": [
            .english: "Advanced",
            .chinese: "高级",
            .japanese: "詳細設定"
        ],
        "settings.section.about": [
            .english: "About",
            .chinese: "关于",
            .japanese: "このアプリについて"
        ],
        "settings.discovery": [
            .english: "Device Discovery",
            .chinese: "设备发现",
            .japanese: "デバイス検出"
        ],
        "settings.auto_reconnect": [
            .english: "Auto Reconnect",
            .chinese: "自动重连",
            .japanese: "自動再接続"
        ],
        "settings.background_connection": [
            .english: "Background Connection",
            .chinese: "后台连接",
            .japanese: "バックグラウンド接続"
        ],
        "settings.pqc": [
            .english: "Post-Quantum Crypto",
            .chinese: "后量子加密",
            .japanese: "耐量子暗号"
        ],
        "settings.trusted_devices": [
            .english: "Trusted Devices",
            .chinese: "受信任的设备",
            .japanese: "信頼済みデバイス"
        ],
        "settings.biometric": [
            .english: "Biometric Authentication",
            .chinese: "生物识别认证",
            .japanese: "生体認証"
        ],
        "settings.e2ee": [
            .english: "End-to-End Encryption",
            .chinese: "端到端加密",
            .japanese: "エンドツーエンド暗号化"
        ],
        "settings.theme": [
            .english: "Theme",
            .chinese: "主题",
            .japanese: "テーマ"
        ],
        "settings.theme.light": [
            .english: "Light",
            .chinese: "浅色",
            .japanese: "ライト"
        ],
        "settings.theme.dark": [
            .english: "Dark",
            .chinese: "深色",
            .japanese: "ダーク"
        ],
        "settings.accent_color": [
            .english: "Accent Color",
            .chinese: "强调色",
            .japanese: "アクセントカラー"
        ],
        "settings.performance": [
            .english: "Performance",
            .chinese: "性能优化",
            .japanese: "パフォーマンス最適化"
        ],
        "settings.clipboard_sync": [
            .english: "Clipboard Sync",
            .chinese: "剪贴板同步",
            .japanese: "クリップボード同期"
        ],
        "settings.icloud_sync": [
            .english: "iCloud Sync",
            .chinese: "iCloud 同步",
            .japanese: "iCloud 同期"
        ],
        "settings.supabase": [
            .english: "Supabase Configuration",
            .chinese: "Supabase 配置",
            .japanese: "Supabase 設定"
        ],
        "settings.logs": [
            .english: "Logs",
            .chinese: "日志查看",
            .japanese: "ログ表示"
        ],
        "settings.experimental": [
            .english: "Experimental Features (Beta)",
            .chinese: "实验功能（Beta）",
            .japanese: "実験機能（ベータ）"
        ],
        "settings.version": [
            .english: "Version",
            .chinese: "版本",
            .japanese: "バージョン"
        ],
        "settings.build": [
            .english: "Build",
            .chinese: "构建号",
            .japanese: "ビルド番号"
        ],
        "settings.opensource": [
            .english: "Open Source Licenses",
            .chinese: "开源许可",
            .japanese: "オープンソースライセンス"
        ],
        "settings.privacy": [
            .english: "Privacy Policy",
            .chinese: "隐私政策",
            .japanese: "プライバシーポリシー"
        ],
        "settings.github": [
            .english: "GitHub Repository",
            .chinese: "GitHub 仓库",
            .japanese: "GitHub リポジトリ"
        ],
        "settings.logout": [
            .english: "Sign Out",
            .chinese: "退出登录",
            .japanese: "ログアウト"
        ],
        "settings.logout.confirm": [
            .english: "Are you sure you want to sign out?",
            .chinese: "确定要退出登录吗？",
            .japanese: "ログアウトしてもよろしいですか？"
        ],
        "settings.user.default_name": [
            .english: "User",
            .chinese: "用户",
            .japanese: "ユーザー"
        ],
        "settings.user.not_logged_in": [
            .english: "Not signed in",
            .chinese: "未登录",
            .japanese: "未ログイン"
        ],
        "settings.user.device_id": [
            .english: "Device ID",
            .chinese: "设备 ID",
            .japanese: "デバイスID"
        ],
        "settings.realtime_weather_api": [
            .english: "Real-time Weather (API)",
            .chinese: "实时天气（API）",
            .japanese: "リアルタイム天気（API）"
        ],
        "notifications.accept": [
            .english: "Accept",
            .chinese: "接受",
            .japanese: "承認"
        ],
        "notifications.reject": [
            .english: "Reject",
            .chinese: "拒绝",
            .japanese: "拒否"
        ]
    ]
}

enum RuntimeLocalization {
    static let appLanguageDefaultsKey = "app_language"

    static func string(_ key: String, table: String? = nil) -> String {
        let bundle = bundleForCurrentLanguage()
        let value = bundle.localizedString(forKey: key, value: nil, table: table)
        if value == key {
            return Bundle.main.localizedString(forKey: key, value: nil, table: table)
        }
        return value
    }

    static func format(_ key: String, _ args: [CVarArg], table: String? = nil) -> String {
        let template = string(key, table: table)
        return String(format: template, locale: localeForCurrentLanguage(), arguments: args)
    }

    private static func bundleForCurrentLanguage() -> Bundle {
        let language = resolvedLanguage()
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    private static func localeForCurrentLanguage() -> Locale {
        resolvedLanguage().locale
    }

    private static func selectedLanguage() -> AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: appLanguageDefaultsKey),
              let language = AppLanguage(rawValue: raw) else {
            return .system
        }
        return language
    }

    private static func resolvedLanguage() -> AppLanguage {
        switch selectedLanguage() {
        case .english, .chinese, .japanese:
            return selectedLanguage()
        case .system:
            let id = Locale.autoupdatingCurrent.identifier.lowercased()
            if id.hasPrefix("zh") { return .chinese }
            if id.hasPrefix("ja") { return .japanese }
            return .english
        }
    }
}
