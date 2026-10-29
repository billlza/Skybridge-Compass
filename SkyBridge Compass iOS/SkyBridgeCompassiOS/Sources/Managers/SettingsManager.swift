import Foundation
import SkyBridgeProtocolCore

/// 设置管理器
@MainActor
public class SettingsManager: ObservableObject {
    public static let instance = SettingsManager()

    // 连接设置
    @Published public var autoReconnect: Bool = true {
        didSet { persist(autoReconnect, forKey: "auto_reconnect") }
    }

    @Published public var allowBackgroundConnection: Bool = false {
        didSet { persist(allowBackgroundConnection, forKey: "background_connection") }
    }

    // 发现设置（持久化，作为“省电策略/扫描周期/自定义服务类型”的配置源）
    @Published public var discoveryEnabled: Bool = true {
        didSet { persist(discoveryEnabled, forKey: "discovery_enabled") }
    }

    /// 0=skybridgeOnly 1=extended 2=full 3=custom
    @Published public var discoveryModePreset: Int = 0 {
        didSet { persist(discoveryModePreset, forKey: "discovery_mode_preset") }
    }

    /// custom 模式的服务类型 rawValue 列表（DiscoveryServiceType.rawValue）
    @Published public var discoveryCustomServiceTypes: [String] = [] {
        didSet { persist(discoveryCustomServiceTypes, forKey: "discovery_custom_services") }
    }

    /// 扫描周期（秒）。0 表示持续发现（不周期 refresh）。
    @Published public var discoveryRefreshIntervalSeconds: Double = 0 {
        didSet { persist(discoveryRefreshIntervalSeconds, forKey: "discovery_refresh_interval_seconds") }
    }

    // 并发/限速（最小实现：限制连接并发；速率限制优先落在剪贴板最大大小/最小发送间隔）
    @Published public var maxConcurrentConnections: Int = 2 {
        didSet { persist(maxConcurrentConnections, forKey: "max_concurrent_connections") }
    }

    // 安全设置
    @Published public var requireBiometricAuth: Bool = false {
        didSet { persist(requireBiometricAuth, forKey: "biometric_auth") }
    }

    @Published public var endToEndEncryption: Bool = true {
        didSet { persist(endToEndEncryption, forKey: "e2e_encryption") }
    }
    
    // CloudKit 设置（默认关闭；未配置 iCloud 能力时避免运行时中断）
    @Published public var enableCloudKitSync: Bool = false {
        didSet { persist(enableCloudKitSync, forKey: "enable_cloudkit_sync") }
    }

    // 兼容保留字段：旧版本曾用它控制 Beta Banner。
    // 正式版阶段不再用它门控文件传输/远程桌面核心功能。
    @Published public var enableExperimentalFeatures: Bool = false {
        didSet { persist(enableExperimentalFeatures, forKey: "enable_experimental_features") }
    }

    // 实时天气（API）
    @Published public var enableRealTimeWeather: Bool = true {
        didSet { persist(enableRealTimeWeather, forKey: "enable_real_time_weather") }
    }

    // 剪贴板同步（对齐 macOS：图片/URL/最大大小/历史）
    @Published public var clipboardSyncEnabled: Bool = false {
        didSet { persist(clipboardSyncEnabled, forKey: "clipboard_sync_enabled") }
    }

    @Published public var clipboardSyncImages: Bool = false {
        didSet { persist(clipboardSyncImages, forKey: "clipboard_sync_images") }
    }

    @Published public var clipboardSyncFileURLs: Bool = true {
        didSet { persist(clipboardSyncFileURLs, forKey: "clipboard_sync_file_urls") }
    }

    /// 最大内容大小（字节）
    @Published public var clipboardMaxContentSize: Int = P2PControlFramePolicy.maximumInlineClipboardByteCount {
        didSet {
            let normalized = Self.normalizedClipboardMaxContentSize(clipboardMaxContentSize)
            guard normalized == clipboardMaxContentSize else {
                clipboardContentSizeWasMigrated = true
                clipboardMaxContentSize = normalized
                return
            }
            persist(clipboardMaxContentSize, forKey: "clipboard_max_content_size")
        }
    }

    @Published public private(set) var clipboardContentSizeWasMigrated = false

    /// 历史记录保留条数
    @Published public var clipboardHistoryLimit: Int = 25 {
        didSet { persist(clipboardHistoryLimit, forKey: "clipboard_history_limit") }
    }

    /// 剪贴板轮询间隔（秒）
    @Published public var clipboardPollIntervalSeconds: Double = 1.0 {
        didSet { persist(clipboardPollIntervalSeconds, forKey: "clipboard_poll_interval_seconds") }
    }

    /// 最小发送间隔（秒），用于“限速/降噪”
    @Published public var clipboardMinSendIntervalSeconds: Double = 0.8 {
        didSet { persist(clipboardMinSendIntervalSeconds, forKey: "clipboard_min_send_interval_seconds") }
    }

    // 文件传输：并发与限速（KB/s，0 表示不限制）
    @Published public var fileTransferMaxConcurrentTransfers: Int = 2 {
        didSet { persist(fileTransferMaxConcurrentTransfers, forKey: "file_transfer_max_concurrent") }
    }

    @Published public var fileTransferUploadLimitKBps: Int = 0 {
        didSet { persist(fileTransferUploadLimitKBps, forKey: "file_transfer_upload_kbps") }
    }

    @Published public var fileTransferDownloadLimitKBps: Int = 0 {
        didSet { persist(fileTransferDownloadLimitKBps, forKey: "file_transfer_download_kbps") }
    }

    private let defaults: UserDefaults
    private var shouldPersistChanges = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadSettings()
        shouldPersistChanges = true
    }

    private func loadSettings() {
        autoReconnect = bool(forKey: "auto_reconnect", default: true)
        allowBackgroundConnection = bool(forKey: "background_connection", default: false)

        discoveryEnabled = bool(forKey: "discovery_enabled", default: true)
        discoveryModePreset = defaults.object(forKey: "discovery_mode_preset") as? Int ?? 0
        let storedDiscoveryServiceTypes = defaults.stringArray(
            forKey: "discovery_custom_services"
        ) ?? []
        discoveryCustomServiceTypes = Self.migratedDiscoveryServiceTypes(
            storedDiscoveryServiceTypes
        )
        if discoveryCustomServiceTypes != storedDiscoveryServiceTypes {
            defaults.set(
                discoveryCustomServiceTypes,
                forKey: "discovery_custom_services"
            )
        }
        discoveryRefreshIntervalSeconds = defaults.object(forKey: "discovery_refresh_interval_seconds") as? Double ?? 0
        maxConcurrentConnections = defaults.object(forKey: "max_concurrent_connections") as? Int ?? 2

        requireBiometricAuth = bool(forKey: "biometric_auth", default: false)
        endToEndEncryption = bool(forKey: "e2e_encryption", default: true)
        enableCloudKitSync = bool(forKey: "enable_cloudkit_sync", default: false)
        enableExperimentalFeatures = bool(forKey: "enable_experimental_features", default: false)
        enableRealTimeWeather = bool(forKey: "enable_real_time_weather", default: true)

        clipboardSyncEnabled = bool(forKey: "clipboard_sync_enabled", default: false)
        clipboardSyncImages = bool(forKey: "clipboard_sync_images", default: false)
        clipboardSyncFileURLs = bool(forKey: "clipboard_sync_file_urls", default: true)
        let storedClipboardMaximum = defaults.object(forKey: "clipboard_max_content_size") as? Int
            ?? P2PControlFramePolicy.maximumInlineClipboardByteCount
        clipboardMaxContentSize = Self.normalizedClipboardMaxContentSize(storedClipboardMaximum)
        if clipboardMaxContentSize != storedClipboardMaximum {
            defaults.set(clipboardMaxContentSize, forKey: "clipboard_max_content_size")
            clipboardContentSizeWasMigrated = true
        }
        clipboardHistoryLimit = defaults.object(forKey: "clipboard_history_limit") as? Int ?? 25
        clipboardPollIntervalSeconds = defaults.object(forKey: "clipboard_poll_interval_seconds") as? Double ?? 1.0
        clipboardMinSendIntervalSeconds = defaults.object(forKey: "clipboard_min_send_interval_seconds") as? Double ?? 0.8

        fileTransferMaxConcurrentTransfers = defaults.object(forKey: "file_transfer_max_concurrent") as? Int ?? 2
        fileTransferUploadLimitKBps = defaults.object(forKey: "file_transfer_upload_kbps") as? Int ?? 0
        fileTransferDownloadLimitKBps = defaults.object(forKey: "file_transfer_download_kbps") as? Int ?? 0
    }

    private func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    private static func migratedDiscoveryServiceTypes(_ stored: [String]) -> [String] {
        var seen = Set<String>()
        return stored.compactMap { raw in
            let migrated: String
            switch raw {
            case BonjourInteropProtocolContract.legacyFileTransferServiceType:
                migrated = BonjourInteropProtocolContract.fileTransferServiceType
            case BonjourInteropProtocolContract.legacyRemoteControlServiceType:
                migrated = BonjourInteropProtocolContract.remoteControlServiceType
            default:
                migrated = raw
            }
            return seen.insert(migrated).inserted ? migrated : nil
        }
    }

    private func persist(_ value: Any, forKey key: String) {
        guard shouldPersistChanges else { return }
        defaults.set(value, forKey: key)
    }

    private static func normalizedClipboardMaxContentSize(_ value: Int) -> Int {
        guard value > 0 else {
            return P2PControlFramePolicy.maximumInlineClipboardByteCount
        }
        return min(value, P2PControlFramePolicy.maximumInlineClipboardByteCount)
    }
}
