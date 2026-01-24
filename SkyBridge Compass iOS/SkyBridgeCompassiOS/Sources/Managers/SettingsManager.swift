import Foundation

/// 设置管理器
@MainActor
public class SettingsManager: ObservableObject {
    public static let instance = SettingsManager()
    
    // 连接设置
    @Published public var autoReconnect: Bool = true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "auto_reconnect") }
    }
    
    @Published public var allowBackgroundConnection: Bool = false {
        didSet { UserDefaults.standard.set(allowBackgroundConnection, forKey: "background_connection") }
    }

    // 发现设置（持久化，作为“省电策略/扫描周期/自定义服务类型”的配置源）
    @Published public var discoveryEnabled: Bool = true {
        didSet { UserDefaults.standard.set(discoveryEnabled, forKey: "discovery_enabled") }
    }

    /// 0=skybridgeOnly 1=extended 2=full 3=custom
    @Published public var discoveryModePreset: Int = 0 {
        didSet { UserDefaults.standard.set(discoveryModePreset, forKey: "discovery_mode_preset") }
    }

    /// custom 模式的服务类型 rawValue 列表（DiscoveryServiceType.rawValue）
    @Published public var discoveryCustomServiceTypes: [String] = [] {
        didSet { UserDefaults.standard.set(discoveryCustomServiceTypes, forKey: "discovery_custom_services") }
    }

    /// 扫描周期（秒）。0 表示持续发现（不周期 refresh）。
    @Published public var discoveryRefreshIntervalSeconds: Double = 0 {
        didSet { UserDefaults.standard.set(discoveryRefreshIntervalSeconds, forKey: "discovery_refresh_interval_seconds") }
    }

    // 并发/限速（最小实现：限制连接并发；速率限制优先落在剪贴板最大大小/最小发送间隔）
    @Published public var maxConcurrentConnections: Int = 2 {
        didSet { UserDefaults.standard.set(maxConcurrentConnections, forKey: "max_concurrent_connections") }
    }
    
    // 安全设置
    @Published public var requireBiometricAuth: Bool = false {
        didSet { UserDefaults.standard.set(requireBiometricAuth, forKey: "biometric_auth") }
    }
    
    @Published public var endToEndEncryption: Bool = true {
        didSet { UserDefaults.standard.set(endToEndEncryption, forKey: "e2e_encryption") }
    }
    
    // CloudKit 设置（默认关闭；未配置 iCloud 能力时避免运行时中断）
    @Published public var enableCloudKitSync: Bool = false {
        didSet { UserDefaults.standard.set(enableCloudKitSync, forKey: "enable_cloudkit_sync") }
    }

    // 实验功能（发行版建议默认关闭/标注 Beta）
    @Published public var enableExperimentalFeatures: Bool = false {
        didSet { UserDefaults.standard.set(enableExperimentalFeatures, forKey: "enable_experimental_features") }
    }

    // 实时天气（API）
    @Published public var enableRealTimeWeather: Bool = true {
        didSet { UserDefaults.standard.set(enableRealTimeWeather, forKey: "enable_real_time_weather") }
    }

    // 剪贴板同步（对齐 macOS：图片/URL/最大大小/历史）
    @Published public var clipboardSyncEnabled: Bool = false {
        didSet { UserDefaults.standard.set(clipboardSyncEnabled, forKey: "clipboard_sync_enabled") }
    }

    @Published public var clipboardSyncImages: Bool = false {
        didSet { UserDefaults.standard.set(clipboardSyncImages, forKey: "clipboard_sync_images") }
    }

    @Published public var clipboardSyncFileURLs: Bool = true {
        didSet { UserDefaults.standard.set(clipboardSyncFileURLs, forKey: "clipboard_sync_file_urls") }
    }

    /// 最大内容大小（字节）
    @Published public var clipboardMaxContentSize: Int = 1 * 1024 * 1024 {
        didSet { UserDefaults.standard.set(clipboardMaxContentSize, forKey: "clipboard_max_content_size") }
    }

    /// 历史记录保留条数
    @Published public var clipboardHistoryLimit: Int = 25 {
        didSet { UserDefaults.standard.set(clipboardHistoryLimit, forKey: "clipboard_history_limit") }
    }

    /// 剪贴板轮询间隔（秒）
    @Published public var clipboardPollIntervalSeconds: Double = 1.0 {
        didSet { UserDefaults.standard.set(clipboardPollIntervalSeconds, forKey: "clipboard_poll_interval_seconds") }
    }

    /// 最小发送间隔（秒），用于“限速/降噪”
    @Published public var clipboardMinSendIntervalSeconds: Double = 0.8 {
        didSet { UserDefaults.standard.set(clipboardMinSendIntervalSeconds, forKey: "clipboard_min_send_interval_seconds") }
    }

    // 文件传输：并发与限速（KB/s，0 表示不限制）
    @Published public var fileTransferMaxConcurrentTransfers: Int = 2 {
        didSet { UserDefaults.standard.set(fileTransferMaxConcurrentTransfers, forKey: "file_transfer_max_concurrent") }
    }

    @Published public var fileTransferUploadLimitKBps: Int = 0 {
        didSet { UserDefaults.standard.set(fileTransferUploadLimitKBps, forKey: "file_transfer_upload_kbps") }
    }

    @Published public var fileTransferDownloadLimitKBps: Int = 0 {
        didSet { UserDefaults.standard.set(fileTransferDownloadLimitKBps, forKey: "file_transfer_download_kbps") }
    }
    
    private init() {
        loadSettings()
    }
    
    private func loadSettings() {
        autoReconnect = UserDefaults.standard.bool(forKey: "auto_reconnect")
        allowBackgroundConnection = UserDefaults.standard.bool(forKey: "background_connection")

        discoveryEnabled = UserDefaults.standard.object(forKey: "discovery_enabled") as? Bool ?? true
        discoveryModePreset = UserDefaults.standard.object(forKey: "discovery_mode_preset") as? Int ?? 0
        discoveryCustomServiceTypes = UserDefaults.standard.stringArray(forKey: "discovery_custom_services") ?? []
        discoveryRefreshIntervalSeconds = UserDefaults.standard.object(forKey: "discovery_refresh_interval_seconds") as? Double ?? 0
        maxConcurrentConnections = UserDefaults.standard.object(forKey: "max_concurrent_connections") as? Int ?? 2

        requireBiometricAuth = UserDefaults.standard.bool(forKey: "biometric_auth")
        endToEndEncryption = UserDefaults.standard.bool(forKey: "e2e_encryption")
        enableCloudKitSync = UserDefaults.standard.bool(forKey: "enable_cloudkit_sync")
        enableExperimentalFeatures = UserDefaults.standard.bool(forKey: "enable_experimental_features")
        enableRealTimeWeather = UserDefaults.standard.object(forKey: "enable_real_time_weather") as? Bool ?? true

        clipboardSyncEnabled = UserDefaults.standard.bool(forKey: "clipboard_sync_enabled")
        clipboardSyncImages = UserDefaults.standard.bool(forKey: "clipboard_sync_images")
        clipboardSyncFileURLs = UserDefaults.standard.object(forKey: "clipboard_sync_file_urls") as? Bool ?? true
        clipboardMaxContentSize = UserDefaults.standard.object(forKey: "clipboard_max_content_size") as? Int ?? (1 * 1024 * 1024)
        clipboardHistoryLimit = UserDefaults.standard.object(forKey: "clipboard_history_limit") as? Int ?? 25
        clipboardPollIntervalSeconds = UserDefaults.standard.object(forKey: "clipboard_poll_interval_seconds") as? Double ?? 1.0
        clipboardMinSendIntervalSeconds = UserDefaults.standard.object(forKey: "clipboard_min_send_interval_seconds") as? Double ?? 0.8

        fileTransferMaxConcurrentTransfers = UserDefaults.standard.object(forKey: "file_transfer_max_concurrent") as? Int ?? 2
        fileTransferUploadLimitKBps = UserDefaults.standard.object(forKey: "file_transfer_upload_kbps") as? Int ?? 0
        fileTransferDownloadLimitKBps = UserDefaults.standard.object(forKey: "file_transfer_download_kbps") as? Int ?? 0
    }
}
