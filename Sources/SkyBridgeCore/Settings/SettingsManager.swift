import Foundation
import SwiftUI
import Combine
import UserNotifications
import AppKit
import os.log

/// 设置导出数据结构
public struct SettingsExportData: Codable {
 // 通用设置
    public let useDarkMode: Bool
    public let themeColor: String
    public let enableSystemNotifications: Bool

 // 网络设置
    public let scanInterval: TimeInterval
    public let connectionTimeout: TimeInterval
    public let maxRetryAttempts: Int

 // 设备管理设置
    public let autoDiscoverAppleTV: Bool
    public let showHomePodDevices: Bool
    public let showThirdPartyAirPlayDevices: Bool
    public let enableBluetoothScanning: Bool
    public let autoScanWiFi: Bool
    public let wifiScanInterval: TimeInterval

 // 高级设置
    public let enableDebugMode: Bool
    public let enableVerboseLogging: Bool
    public let enablePerformanceMonitoring: Bool
 /// 性能模式（可选，兼容旧版本导入）
    public let performanceMode: String?
 /// 隐私诊断开关：是否启用TLS握手诊断（可选，兼容旧版本导入）
    public let enableHandshakeDiagnostics: Bool?

 // 系统监控设置
    public let enableCPUMonitoring: Bool
    public let enableMemoryMonitoring: Bool
    public let enableNetworkMonitoring: Bool
    public let enableDiskMonitoring: Bool
    public let monitoringInterval: TimeInterval
    public let showTrendIndicators: Bool?
    public let maxHistoryPoints: Double?
    public let systemMonitorRetentionDays: Int?
    public let enablePerformanceAlerts: Bool?
    public let temperatureThreshold: Double?
    public let enableTemperatureMonitoring: Bool?
    public let enableFanSpeedMonitoring: Bool?
    public let fanSpeedThreshold: Double?
    public let enableThermalThrottlingAlert: Bool?
    public let showMonitorCPU: Bool?
    public let showMonitorMemory: Bool?
    public let showMonitorTemperature: Bool?
    public let showMonitorFanSpeed: Bool?
    public let showMonitorDisk: Bool?
    public let showMonitorNetwork: Bool?
    public let systemMonitorChartType: String?
    public let systemMonitorSamplingPrecision: String?
    public let enableRemoteMonitoring: Bool?

 // 元数据
    public let exportDate: Date
    public let appVersion: String
}

public enum SettingsStorageKeys {
    public static let preferXWingHybrid = "Settings.PreferXWingHybrid"
}

/// 设置错误类型
public enum SettingsError: Error, LocalizedError {
    case fileAccessDenied
    case invalidData
    case validationFailed(String)
    case exportFailed(String)
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileAccessDenied:
            return "文件访问被拒绝"
        case .invalidData:
            return "无效的数据格式"
        case .validationFailed(let message):
            return "验证失败: \(message)"
        case .exportFailed(let message):
            return "导出失败: \(message)"
        case .importFailed(let message):
            return "导入失败: \(message)"
        }
    }
}

/// 扩展DateFormatter以支持文件名格式
extension DateFormatter {
    static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}

/// 应用设置管理器 - 统一管理所有设置数据和持久化
@MainActor
public class SettingsManager: ObservableObject, Sendable {

 // MARK: - 单例
    public static let shared = SettingsManager()

 // MARK: - 日志记录器
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SettingsManager")

 // MARK: - 通用设置
    @Published public var autoScanOnStartup: Bool = true
    @Published public var showSystemNotifications: Bool = true
    @Published public var useDarkMode: Bool = false
    @Published public var scanInterval: Int = 30
    @Published public var showDeviceDetails: Bool = true
    @Published public var showConnectionStats: Bool = true
    @Published public var compactMode: Bool = false
    @Published public var themeColor: Color = .blue

 // MARK: - 网络设置
    @Published public var autoConnectKnownNetworks: Bool = true
    @Published public var showHiddenNetworks: Bool = false
    @Published public var prefer5GHz: Bool = true
    @Published public var wifiScanTimeout: Int = 10
    @Published public var enableBonjourDiscovery: Bool = true
    @Published public var enableMDNSResolution: Bool = true
    @Published public var scanCustomPorts: Bool = false
    @Published public var discoveryTimeout: Int = 30
    @Published public var connectionTimeout: Int = 10
    @Published public var retryCount: Int = 3
 /// 发现探测策略：true 为纯被动模式（不做主动端口/NWConnection探测）
    @Published public var discoveryPassiveMode: Bool = true
 /// 建立任何网络连接前是否需要用户授权
    @Published public var requireAuthorizationForConnection: Bool = true
 /// 是否启用 Wi‑Fi Aware 被动发现（macOS 26+ 可用，低版本自动忽略）
    @Published public var enableWiFiAwareDiscovery: Bool = true
    @Published public var enableConnectionEncryption: Bool = true
    @Published public var verifyCertificates: Bool = true
    @Published public var customServiceTypes: [String] = []

 // MARK: - 设备设置
    @Published public var autoConnectPairedDevices: Bool = true
    @Published public var showDeviceRSSI: Bool = true
    @Published public var showConnectableDevicesOnly: Bool = false
    @Published public var autoDiscoverAppleTV: Bool = true
    @Published public var showHomePodDevices: Bool = true
    @Published public var showThirdPartyAirPlayDevices: Bool = true
    @Published public var hideOfflineDevices: Bool = false
    @Published public var sortBySignalStrength: Bool = true
    @Published public var showDeviceIcons: Bool = true
    @Published public var minimumSignalStrength: Double = -80.0
 /// 信号强度平滑参数（EMA），范围 0.1~0.95，越小越平滑
    @Published public var signalStrengthAlpha: Double = 0.6
 /// 设备列表排序权重：验签通过的分值
    @Published public var sortWeightVerified: Int = 2000
 /// 设备列表排序权重：已连接设备的分值
    @Published public var sortWeightConnected: Int = 1000
 /// 设备列表排序权重：信号强度系数（0~100）
    @Published public var sortWeightSignalMultiplier: Int = 100

 // MARK: - 高级设置
    @Published public var enableVerboseLogging: Bool = false
    @Published public var showDebugInfo: Bool = false
    @Published public var saveNetworkLogs: Bool = false
    @Published public var logLevel: String = "Info"
    @Published public var enableHardwareAcceleration: Bool = true
    @Published public var optimizeMemoryUsage: Bool = true
    @Published public var enableBackgroundScanning: Bool = false
    @Published public var maxConcurrentConnections: Int = 10
    @Published public var enableIPv6Support: Bool = false
    @Published public var useNewDiscoveryAlgorithm: Bool = false
    @Published public var enableP2PDirectConnection: Bool = false
    @Published public var enableRealTimeWeather: Bool = false

 // 性能模式设置
    public enum PerformanceMode: String, CaseIterable, Codable {
        case extreme = "极致"
        case balanced = "平衡"
        case energySaving = "节能"

        public var targetFPS: Double {
            switch self {
            case .extreme: return 60.0
            case .balanced: return 30.0
            case .energySaving: return 15.0
            }
        }
    }
    @Published public var performanceMode: PerformanceMode = .balanced

 /// 是否在仪表盘顶部显示实时FPS（默认关闭）
    @Published public var showRealtimeFPS: Bool = false
 /// 兼容/更多设备发现开关（默认关闭，正常用户场景仅SkyBridge）
    @Published public var enableCompatibilityMode: Bool = false
 /// 是否启用 companion‑link 服务类型（默认关闭）
    @Published public var enableCompanionLink: Bool = false
 /// 健康提醒：敏感人群更严格模式
    @Published public var strictModeForSensitiveGroups: Bool = false
 /// AQI阈值（城市）
    @Published public var aqiThresholdCautionUrban: Int = 100
    @Published public var aqiThresholdSensitiveUrban: Int = 150
    @Published public var aqiThresholdUnhealthyUrban: Int = 200
    @Published public var aqiThresholdVeryUnhealthyUrban: Int = 300
 /// AQI阈值（郊区）
    @Published public var aqiThresholdCautionSuburban: Int = 120
    @Published public var aqiThresholdSensitiveSuburban: Int = 170
    @Published public var aqiThresholdUnhealthySuburban: Int = 220
    @Published public var aqiThresholdVeryUnhealthySuburban: Int = 300
 /// UV阈值
    @Published public var uvThresholdModerate: Double = 6.0
    @Published public var uvThresholdStrong: Double = 8.0
 /// 可连接设备提醒：仅提醒已验签设备
    @Published public var onlyNotifyVerifiedDevices: Bool = false
 /// 隐私诊断开关：是否采集TLS握手诊断数据（ALPN/SNI等），默认关闭以保护隐私
    @Published public var enableHandshakeDiagnostics: Bool = false
 /// Secure Enclave 支持（仅在 macOS 26+ 且 CryptoKit PQC 可用时生效）
    @Published public var useSecureEnclaveMLDSA: Bool = true
 /// Secure Enclave 支持（仅在 macOS 26+ 且 CryptoKit PQC 可用时生效）
    @Published public var useSecureEnclaveMLKEM: Bool = true
 /// 量子安全：启用后量子密码（应用层）
 /// 🔧 优化：默认启用PQC，提供量子安全保护
    @Published public var enablePQC: Bool = true
 /// 量子安全：优先签名算法（当前运行时支持 ML-DSA-65/ML-DSA-87）
    @Published public var pqcSignatureAlgorithm: String = "ML-DSA-65"
 /// 量子安全：是否启用TLS混合协商（视系统支持而定）
    @Published public var enablePQCHybridTLS: Bool = false
 /// 量子安全：是否优先协商 X-Wing 混合套件（仅调整套件优先级）
    @Published public var preferXWingHybrid: Bool = false

 // MARK: - 系统监控设置
    @Published public var systemMonitorRefreshInterval: Double = 1.0
    @Published public var enableSystemNotifications: Bool = true
    @Published public var cpuThreshold: Double = 80.0
    @Published public var memoryThreshold: Double = 80.0
    @Published public var diskThreshold: Double = 90.0
    @Published public var enableAutoRefresh: Bool = true
    @Published public var showTrendIndicators: Bool = true
    @Published public var enableSoundAlerts: Bool = false
    @Published public var maxHistoryPoints: Double = 300.0
    @Published public var systemMonitorRetentionDays: Int = 7

    public enum SystemMonitorChartType: String, CaseIterable, Codable {
        case line
        case bar
        case area
    }

    public enum SystemMonitorSamplingPrecision: String, CaseIterable, Codable {
        case low
        case normal
        case high
    }

    @Published public var systemMonitorChartType: SystemMonitorChartType = .line
    @Published public var systemMonitorSamplingPrecision: SystemMonitorSamplingPrecision = .normal
    @Published public var enableRemoteMonitoring: Bool = false

    // 系统监控：性能警报与显示控制
    @Published public var enablePerformanceAlerts: Bool = true
    @Published public var temperatureThreshold: Double = 80.0
    @Published public var enableTemperatureMonitoring: Bool = true
    @Published public var enableFanSpeedMonitoring: Bool = true
    @Published public var fanSpeedThreshold: Double = 4000.0
    @Published public var enableThermalThrottlingAlert: Bool = true
    @Published public var showMonitorCPU: Bool = true
    @Published public var showMonitorMemory: Bool = true
    @Published public var showMonitorTemperature: Bool = true
    @Published public var showMonitorFanSpeed: Bool = true
    @Published public var showMonitorDisk: Bool = true
    @Published public var showMonitorNetwork: Bool = true

 // MARK: - 文件传输设置
    @Published public var defaultTransferPath: String = "~/Downloads"
    @Published public var transferBufferSize: Int = 131072  // 128KB
    @Published public var autoRetryFailedTransfers: Bool = true
    @Published public var keepTransferHistory: Bool = true
    @Published public var keepSystemAwakeDuringTransfer: Bool = false
    @Published public var scanTransferFilesForVirus: Bool = false
 /// 文件传输速率限制（MB/s），0 表示不限速
    @Published public var transferSpeedLimitMBps: Double = 0
    @Published public var encryptionAlgorithm: FileTransferEncryptionAlgorithm = .aes256GCM
 /// 文件扫描级别：Quick/Standard/Deep
    @Published public var scanLevel: FileScanService.ScanLevel = .standard
 /// MetalFX 降级缩放：是否优先选择最近邻（更快但质量低），默认关闭（使用双线性）
    @Published public var preferNearestNeighborScaling: Bool = false
    @Published public var enableZeroCopyBGRA: Bool = false

 // MARK: - 私有属性
    private let userDefaults = UserDefaults.standard
    private var settingsCancellables = Set<AnyCancellable>()

 // MARK: - 初始化
    private init() {
        loadSettings()
        setupObservers()
        applyRuntimeSettingsSnapshot()
    }

 // MARK: - 生命周期管理方法

 /// 启动设置管理器
    public func start() async throws {
        logger.info("⚙️ 设置管理器已启动")
    }

 /// 停止设置管理器
    public func stop() async {
        logger.info("⚙️ 设置管理器已停止")
    }

 /// 清理资源
    public func cleanup() {
        settingsCancellables.removeAll()
        logger.info("⚙️ 设置管理器资源已清理")
    }

 // MARK: - 公共方法

 /// 重置所有设置到默认值
    @MainActor
    public func resetToDefaults() async {
 // 通用设置
        autoScanOnStartup = true
        showSystemNotifications = true
        useDarkMode = false
        scanInterval = 30
        showDeviceDetails = true
        showConnectionStats = true
        compactMode = false
        themeColor = .blue

 // 网络设置
        autoConnectKnownNetworks = true
        showHiddenNetworks = false
        prefer5GHz = true
        wifiScanTimeout = 10
        enableBonjourDiscovery = true
        enableMDNSResolution = true
        scanCustomPorts = false
        discoveryTimeout = 30
        connectionTimeout = 10
        retryCount = 3
        enableConnectionEncryption = true
        verifyCertificates = true
        discoveryPassiveMode = true
        requireAuthorizationForConnection = true
        enableWiFiAwareDiscovery = true
        customServiceTypes = []

 // 设备设置
        autoConnectPairedDevices = true
        showDeviceRSSI = true
        showConnectableDevicesOnly = false
        autoDiscoverAppleTV = true
        showHomePodDevices = true
        showThirdPartyAirPlayDevices = true
        hideOfflineDevices = false
        sortBySignalStrength = true
        showDeviceIcons = true
        minimumSignalStrength = -80.0
        signalStrengthAlpha = 0.6
        sortWeightVerified = 2000
        sortWeightConnected = 1000
        sortWeightSignalMultiplier = 100

 // 高级设置
        enableVerboseLogging = false
        showDebugInfo = false
        saveNetworkLogs = false
        logLevel = "Info"
        enableHardwareAcceleration = true
        optimizeMemoryUsage = true
        enableBackgroundScanning = false
        maxConcurrentConnections = 10
        enableIPv6Support = false
        useNewDiscoveryAlgorithm = false
        enableP2PDirectConnection = false
        enableRealTimeWeather = false
        performanceMode = .balanced
        showRealtimeFPS = false
        enableCompatibilityMode = false
        enableCompanionLink = false
        enableHandshakeDiagnostics = false
        useSecureEnclaveMLDSA = true
        useSecureEnclaveMLKEM = true
        // 默认启用应用层 PQC（与属性默认值/注释保持一致）
        enablePQC = true
        pqcSignatureAlgorithm = "ML-DSA-65"
        enablePQCHybridTLS = false
        preferXWingHybrid = false
        strictModeForSensitiveGroups = false
        aqiThresholdCautionUrban = 100
        aqiThresholdSensitiveUrban = 150
        aqiThresholdUnhealthyUrban = 200
        aqiThresholdVeryUnhealthyUrban = 300
        aqiThresholdCautionSuburban = 120
        aqiThresholdSensitiveSuburban = 170
        aqiThresholdUnhealthySuburban = 220
        aqiThresholdVeryUnhealthySuburban = 300
        uvThresholdModerate = 6.0
        uvThresholdStrong = 8.0
        onlyNotifyVerifiedDevices = false

 // 系统监控设置
        resetSystemMonitorSettingsToDefaults()

 // 文件传输设置
        defaultTransferPath = "~/Downloads"
        transferBufferSize = 131072
        autoRetryFailedTransfers = true
        keepTransferHistory = true
        keepSystemAwakeDuringTransfer = false
        scanTransferFilesForVirus = false
        transferSpeedLimitMBps = 0
        encryptionAlgorithm = .aes256GCM
        scanLevel = .standard

        applyRuntimeSettingsSnapshot()
        SkyBridgeLogger.ui.debugOnly("🔄 所有设置已重置为默认值")
    }

    public func resetSystemMonitorSettingsToDefaults() {
        systemMonitorRefreshInterval = 1.0
        enableSystemNotifications = true
        cpuThreshold = 80.0
        memoryThreshold = 80.0
        diskThreshold = 90.0
        enableAutoRefresh = true
        showTrendIndicators = true
        enableSoundAlerts = false
        maxHistoryPoints = 300.0
        systemMonitorRetentionDays = 7
        systemMonitorChartType = .line
        systemMonitorSamplingPrecision = .normal
        enableRemoteMonitoring = false
        enablePerformanceAlerts = true
        temperatureThreshold = 80.0
        enableTemperatureMonitoring = true
        enableFanSpeedMonitoring = true
        fanSpeedThreshold = 4000.0
        enableThermalThrottlingAlert = true
        showMonitorCPU = true
        showMonitorMemory = true
        showMonitorTemperature = true
        showMonitorFanSpeed = true
        showMonitorDisk = true
        showMonitorNetwork = true
    }

    public func applyRuntimeSettingsSnapshot() {
        enforceStrictCertificateValidationIfNeeded(context: "runtime snapshot")

        NotificationCenter.default.post(
            name: NSNotification.Name("LayoutModeChanged"),
            object: nil,
            userInfo: ["isCompact": compactMode]
        )
        NotificationCenter.default.post(name: NSNotification.Name("DeviceDisplayModeChanged"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("ConnectionStatsDisplayChanged"), object: nil)
        NotificationCenter.default.post(
            name: NSNotification.Name("ThemeDidChange"),
            object: nil,
            userInfo: ["isDarkMode": useDarkMode, "themeColor": themeColor]
        )
        NotificationCenter.default.post(
            name: NSNotification.Name("ThemeColorChanged"),
            object: nil,
            userInfo: ["color": themeColor]
        )

        NetworkActivityLogStore.shared.setEnabled(saveNetworkLogs)
        applyLoggingRuntimeSettings()

        Task { @MainActor in
            FileTransferSettingsBridge.shared.apply()
            NetworkPreferenceService.shared.applyRuntimeSettings(
                prefer5GHz: self.prefer5GHz,
                autoConnectKnownNetworks: self.autoConnectKnownNetworks,
                scanIntervalSeconds: self.wifiScanTimeout
            )
            let sharedScanInterval = Double(self.scanInterval)
            DeviceManagementSettingsManager.shared.wifiScanInterval = sharedScanInterval
            DeviceManagementSettingsManager.shared.bluetoothScanInterval = sharedScanInterval
            DeviceManagementSettingsManager.shared.airplayScanInterval = sharedScanInterval
            self.postWiFiSettingsChanged(["scanInterval": sharedScanInterval])
            self.postBluetoothSettingsChanged(["scanInterval": sharedScanInterval])
            self.postAirPlaySettingsChanged([
                "scanInterval": sharedScanInterval,
                "autoDiscoverAppleTV": self.autoDiscoverAppleTV,
                "showHomePodDevices": self.showHomePodDevices,
                "showThirdPartyAirPlayDevices": self.showThirdPartyAirPlayDevices
            ])
            DeviceDiscoveryService.shared.applyRuntimeDiscoverySettings(restartIfNeeded: false)
            if #available(macOS 14.0, *) {
                UnifiedOnlineDeviceManager.shared.applyRuntimeDiscoverySettings(restartIfNeeded: false)
            }
            self.applyWeatherRuntimeSetting(self.enableRealTimeWeather)
            self.applyRemotePerformanceSettings(self.enableHardwareAcceleration)
        }
    }

    private func scheduleFileTransferSettingsApply() {
        Task { @MainActor in
            FileTransferSettingsBridge.shared.apply()
        }
    }

    private func scheduleDiscoveryRuntimeApply(restartIfNeeded: Bool) {
        Task { @MainActor in
            DeviceDiscoveryService.shared.applyRuntimeDiscoverySettings(restartIfNeeded: restartIfNeeded)
            if #available(macOS 14.0, *) {
                UnifiedOnlineDeviceManager.shared.applyRuntimeDiscoverySettings(restartIfNeeded: restartIfNeeded)
            }
        }
    }

    private func scheduleOnlineDevicePresentationRefresh() {
        Task { @MainActor in
            if #available(macOS 14.0, *) {
                UnifiedOnlineDeviceManager.shared.refreshDevices()
            }
        }
    }

    private func postWiFiSettingsChanged(_ userInfo: [String: Any]) {
        NotificationCenter.default.post(
            name: NSNotification.Name("WiFiSettingsChanged"),
            object: self,
            userInfo: userInfo
        )
    }

    private func postBluetoothSettingsChanged(_ userInfo: [String: Any]) {
        NotificationCenter.default.post(
            name: NSNotification.Name("BluetoothSettingsChanged"),
            object: self,
            userInfo: userInfo
        )
    }

    private func postAirPlaySettingsChanged(_ userInfo: [String: Any]) {
        NotificationCenter.default.post(
            name: NSNotification.Name("AirPlaySettingsChanged"),
            object: self,
            userInfo: userInfo
        )
    }

    private func clearCryptoProviderCacheForSettingsChange() {
        Task {
            await CryptoProviderSelector.shared.clearCache()
        }
    }

    private func applyLoggingRuntimeSettings() {
        SkyBridgeLogger.minimumLogLevel = enableVerboseLogging
            ? .debug
            : Self.logLevel(from: logLevel)
    }

    private static func logLevel(from rawValue: String) -> LogLevel {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "trace":
            return .trace
        case "debug":
            return .debug
        case "warning", "warn":
            return .warning
        case "error":
            return .error
        case "critical", "fault":
            return .critical
        default:
            return .info
        }
    }

    public static func normalizedPQCSignatureAlgorithm(_ rawValue: String) -> String {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ML-DSA", "ML-DSA-65", "MLDSA", "MLDSA-65":
            return "ML-DSA-65"
        case "ML-DSA-87", "MLDSA-87":
            return "ML-DSA-87"
        default:
            return "ML-DSA-65"
        }
    }

    private func applyWeatherRuntimeSetting(_ enabled: Bool) {
        Task { @MainActor in
            if enabled {
                await WeatherIntegrationManager.shared.start()
            } else {
                WeatherIntegrationManager.shared.stop()
            }
        }
    }

    private func applyRemotePerformanceSettings(_ hardwareAccelerationEnabled: Bool) {
        Task { @MainActor in
            let remoteSettings = RemoteDesktopSettingsManager.shared
            remoteSettings.settings.displaySettings.enableHardwareAcceleration = hardwareAccelerationEnabled
            remoteSettings.saveSettings()
        }
    }

 /// 导出设置到文件
    @MainActor
    public func exportSettings() async throws -> URL {
        let settings = [
 // 通用设置
            "autoScanOnStartup": autoScanOnStartup,
            "showSystemNotifications": showSystemNotifications,
            "useDarkMode": useDarkMode,
            "scanInterval": scanInterval,
            "showDeviceDetails": showDeviceDetails,
            "showConnectionStats": showConnectionStats,
            "compactMode": compactMode,

 // 网络设置
            "autoConnectKnownNetworks": autoConnectKnownNetworks,
            "showHiddenNetworks": showHiddenNetworks,
            "prefer5GHz": prefer5GHz,
            "wifiScanTimeout": wifiScanTimeout,
            "enableBonjourDiscovery": enableBonjourDiscovery,
            "enableMDNSResolution": enableMDNSResolution,
            "scanCustomPorts": scanCustomPorts,
            "discoveryTimeout": discoveryTimeout,
            "connectionTimeout": connectionTimeout,
            "retryCount": retryCount,
            "discoveryPassiveMode": discoveryPassiveMode,
            "requireAuthorizationForConnection": requireAuthorizationForConnection,
            "enableWiFiAwareDiscovery": enableWiFiAwareDiscovery,
            "enableConnectionEncryption": enableConnectionEncryption,
            "verifyCertificates": verifyCertificates,
            "customServiceTypes": customServiceTypes,

 // 设备设置
            "autoConnectPairedDevices": autoConnectPairedDevices,
            "showDeviceRSSI": showDeviceRSSI,
            "showConnectableDevicesOnly": showConnectableDevicesOnly,
            "autoDiscoverAppleTV": autoDiscoverAppleTV,
            "showHomePodDevices": showHomePodDevices,
            "showThirdPartyAirPlayDevices": showThirdPartyAirPlayDevices,
            "hideOfflineDevices": hideOfflineDevices,
            "sortBySignalStrength": sortBySignalStrength,
            "showDeviceIcons": showDeviceIcons,
            "minimumSignalStrength": minimumSignalStrength,
            "signalStrengthAlpha": signalStrengthAlpha,
            "sortWeightVerified": sortWeightVerified,
            "sortWeightConnected": sortWeightConnected,
            "sortWeightSignalMultiplier": sortWeightSignalMultiplier,

 // 高级设置
            "enableVerboseLogging": enableVerboseLogging,
            "showDebugInfo": showDebugInfo,
            "saveNetworkLogs": saveNetworkLogs,
            "logLevel": logLevel,
            "enableHardwareAcceleration": enableHardwareAcceleration,
            "optimizeMemoryUsage": optimizeMemoryUsage,
            "enableBackgroundScanning": enableBackgroundScanning,
            "maxConcurrentConnections": maxConcurrentConnections,
            "enableIPv6Support": enableIPv6Support,
            "useNewDiscoveryAlgorithm": useNewDiscoveryAlgorithm,
            "enableP2PDirectConnection": enableP2PDirectConnection,
            "enableRealTimeWeather": enableRealTimeWeather,
            "performanceMode": performanceMode.rawValue,
            "enableHandshakeDiagnostics": enableHandshakeDiagnostics,
            "showRealtimeFPS": showRealtimeFPS,
            "enableCompatibilityMode": enableCompatibilityMode,
            "enableCompanionLink": enableCompanionLink,
            "strictModeForSensitiveGroups": strictModeForSensitiveGroups,
            "aqiThresholdCautionUrban": aqiThresholdCautionUrban,
            "aqiThresholdSensitiveUrban": aqiThresholdSensitiveUrban,
            "aqiThresholdUnhealthyUrban": aqiThresholdUnhealthyUrban,
            "aqiThresholdVeryUnhealthyUrban": aqiThresholdVeryUnhealthyUrban,
            "aqiThresholdCautionSuburban": aqiThresholdCautionSuburban,
            "aqiThresholdSensitiveSuburban": aqiThresholdSensitiveSuburban,
            "aqiThresholdUnhealthySuburban": aqiThresholdUnhealthySuburban,
            "aqiThresholdVeryUnhealthySuburban": aqiThresholdVeryUnhealthySuburban,
            "uvThresholdModerate": uvThresholdModerate,
            "uvThresholdStrong": uvThresholdStrong,
            "onlyNotifyVerifiedDevices": onlyNotifyVerifiedDevices,
            "enablePQC": enablePQC,
            "pqcSignatureAlgorithm": pqcSignatureAlgorithm,
            "enablePQCHybridTLS": enablePQCHybridTLS,
            "preferXWingHybrid": preferXWingHybrid,
            "useSecureEnclaveMLDSA": useSecureEnclaveMLDSA,
            "useSecureEnclaveMLKEM": useSecureEnclaveMLKEM,

 // 系统监控设置
            "systemMonitorRefreshInterval": systemMonitorRefreshInterval,
            "enableSystemNotifications": enableSystemNotifications,
            "cpuThreshold": cpuThreshold,
            "memoryThreshold": memoryThreshold,
            "diskThreshold": diskThreshold,
            "enableAutoRefresh": enableAutoRefresh,
            "showTrendIndicators": showTrendIndicators,
            "enableSoundAlerts": enableSoundAlerts,
            "maxHistoryPoints": maxHistoryPoints,
            "systemMonitorRetentionDays": systemMonitorRetentionDays,
            "systemMonitorChartType": systemMonitorChartType.rawValue,
            "systemMonitorSamplingPrecision": systemMonitorSamplingPrecision.rawValue,
            "enableRemoteMonitoring": enableRemoteMonitoring,
            "enablePerformanceAlerts": enablePerformanceAlerts,
            "temperatureThreshold": temperatureThreshold,
            "enableTemperatureMonitoring": enableTemperatureMonitoring,
            "enableFanSpeedMonitoring": enableFanSpeedMonitoring,
            "fanSpeedThreshold": fanSpeedThreshold,
            "enableThermalThrottlingAlert": enableThermalThrottlingAlert,
            "showMonitorCPU": showMonitorCPU,
            "showMonitorMemory": showMonitorMemory,
            "showMonitorTemperature": showMonitorTemperature,
            "showMonitorFanSpeed": showMonitorFanSpeed,
            "showMonitorDisk": showMonitorDisk,
            "showMonitorNetwork": showMonitorNetwork,

 // 文件传输设置
            "defaultTransferPath": defaultTransferPath,
            "transferBufferSize": transferBufferSize,
            "autoRetryFailedTransfers": autoRetryFailedTransfers,
            "keepTransferHistory": keepTransferHistory,
            "keepSystemAwakeDuringTransfer": keepSystemAwakeDuringTransfer,
            "scanTransferFilesForVirus": scanTransferFilesForVirus,
            "transferSpeedLimitMBps": transferSpeedLimitMBps,
            "encryptionAlgorithm": encryptionAlgorithm.rawValue,
            "scanLevel": scanLevel.rawValue,

 // 元数据
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        ] as [String: Any]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted) else {
            throw NSError(domain: "SettingsExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法序列化设置数据"])
        }

 // 创建临时文件
        let tempDirectory = FileManager.default.temporaryDirectory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "SkyBridge_Settings_\(dateFormatter.string(from: Date())).json"
        let fileURL = tempDirectory.appendingPathComponent(fileName)

        try jsonData.write(to: fileURL)

        SkyBridgeLogger.ui.debugOnly("📤 设置已导出到: \(fileURL.path)")

 // 发送通知
        if showSystemNotifications {
            sendSystemNotification(
                title: "设置导出成功",
                body: "设置已成功导出到 \(fileName)"
            )
        }

        return fileURL
    }

 /// 从文件导入设置
    @MainActor
    public func importSettings(from url: URL) async throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw SettingsError.fileAccessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

 // ✅ 异步文件读取，避免主线程阻塞
        let jsonData = try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let data = try Data(contentsOf: url)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

 // 尝试解析为新的结构化数据格式
        if let settingsData = try? JSONDecoder().decode(SettingsExportData.self, from: jsonData) {
 // 验证设置数据的有效性
            try validateImportedSettings(settingsData)

 // 应用导入的设置
            await applyImportedSettings(settingsData)

            SkyBridgeLogger.ui.debugOnly("📥 设置已从文件导入: \(url.lastPathComponent)")

 // 发送通知
            if showSystemNotifications {
                sendSystemNotification(
                    title: "设置导入成功",
                    body: "设置已成功从 \(url.lastPathComponent) 导入"
                )
            }
            return
        }

 // 回退到旧的字典格式
        guard let settings = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw SettingsError.invalidData
        }

 // 验证设置数据的有效性
        try validateLegacyImportedSettings(settings)

 // 应用旧格式设置
        await applyLegacyImportedSettings(settings)

        SkyBridgeLogger.ui.debugOnly("📥 设置已从文件导入: \(url.lastPathComponent)")

 // 发送通知
        if showSystemNotifications {
            sendSystemNotification(
                title: "设置导入成功",
                body: "设置已成功从 \(url.lastPathComponent) 导入"
            )
        }
    }

 /// 验证旧格式导入的设置数据
    private func validateLegacyImportedSettings(_ settings: [String: Any]) throws {
 // 验证扫描间隔范围
        if let scanInterval = settings["scanInterval"] as? Int {
            if scanInterval < 1 || scanInterval > 300 {
                throw SettingsError.validationFailed("扫描间隔必须在1-300秒之间")
            }
        }

 // 验证连接超时范围
        if let connectionTimeout = settings["connectionTimeout"] as? Int {
            if connectionTimeout < 1 || connectionTimeout > 60 {
                throw SettingsError.validationFailed("连接超时必须在1-60秒之间")
            }
        }

 // 验证重试次数范围
        if let retryCount = settings["retryCount"] as? Int {
            if retryCount < 1 || retryCount > 10 {
                throw SettingsError.validationFailed("重试次数必须在1-10次之间")
            }
        }

        if let value = settings["encryptionAlgorithm"] as? String {
            do {
                _ = try FileTransferEncryptionAlgorithm(persistedValue: value)
            } catch {
                throw SettingsError.validationFailed("文件传输仅支持 AES-256-GCM 加密")
            }
        }
    }

 /// 应用旧格式导入的设置
    @MainActor
    private func applyLegacyImportedSettings(_ settings: [String: Any]) async {
 // 通用设置
        if let value = settings["autoScanOnStartup"] as? Bool { autoScanOnStartup = value }
        if let value = settings["showSystemNotifications"] as? Bool { showSystemNotifications = value }
        if let value = settings["useDarkMode"] as? Bool { useDarkMode = value }
        if let value = settings["scanInterval"] as? Int { scanInterval = value }
        if let value = settings["showDeviceDetails"] as? Bool { showDeviceDetails = value }
        if let value = settings["showConnectionStats"] as? Bool { showConnectionStats = value }
        if let value = settings["compactMode"] as? Bool { compactMode = value }

 // 网络设置
        if let value = settings["autoConnectKnownNetworks"] as? Bool { autoConnectKnownNetworks = value }
        if let value = settings["showHiddenNetworks"] as? Bool { showHiddenNetworks = value }
        if let value = settings["prefer5GHz"] as? Bool { prefer5GHz = value }
        if let value = settings["wifiScanTimeout"] as? Int { wifiScanTimeout = value }
        if let value = settings["enableBonjourDiscovery"] as? Bool { enableBonjourDiscovery = value }
        if let value = settings["enableMDNSResolution"] as? Bool { enableMDNSResolution = value }
        if let value = settings["scanCustomPorts"] as? Bool { scanCustomPorts = value }
        if let value = settings["discoveryTimeout"] as? Int { discoveryTimeout = value }
        if let value = settings["connectionTimeout"] as? Int { connectionTimeout = value }
        if let value = settings["retryCount"] as? Int { retryCount = value }
        if let value = settings["discoveryPassiveMode"] as? Bool { discoveryPassiveMode = value }
        if let value = settings["requireAuthorizationForConnection"] as? Bool { requireAuthorizationForConnection = value }
        if let value = settings["enableWiFiAwareDiscovery"] as? Bool { enableWiFiAwareDiscovery = value }
        if let value = settings["enableConnectionEncryption"] as? Bool { enableConnectionEncryption = value }
        if let value = settings["verifyCertificates"] as? Bool {
            verifyCertificates = value
            enforceStrictCertificateValidationIfNeeded(context: "legacy import")
        }
        if let value = settings["customServiceTypes"] as? [String] { customServiceTypes = value }

 // 设备设置
        if let value = settings["autoConnectPairedDevices"] as? Bool { autoConnectPairedDevices = value }
        if let value = settings["showDeviceRSSI"] as? Bool { showDeviceRSSI = value }
        if let value = settings["showConnectableDevicesOnly"] as? Bool { showConnectableDevicesOnly = value }
        if let value = settings["autoDiscoverAppleTV"] as? Bool { autoDiscoverAppleTV = value }
        if let value = settings["showHomePodDevices"] as? Bool { showHomePodDevices = value }
        if let value = settings["showThirdPartyAirPlayDevices"] as? Bool { showThirdPartyAirPlayDevices = value }
        if let value = settings["hideOfflineDevices"] as? Bool { hideOfflineDevices = value }
        if let value = settings["sortBySignalStrength"] as? Bool { sortBySignalStrength = value }
        if let value = settings["showDeviceIcons"] as? Bool { showDeviceIcons = value }
        if let value = settings["minimumSignalStrength"] as? Double { minimumSignalStrength = value }
        if let value = settings["signalStrengthAlpha"] as? Double { signalStrengthAlpha = value }
        if let value = settings["sortWeightVerified"] as? Int { sortWeightVerified = value }
        if let value = settings["sortWeightConnected"] as? Int { sortWeightConnected = value }
        if let value = settings["sortWeightSignalMultiplier"] as? Int { sortWeightSignalMultiplier = value }

 // 高级设置
        if let value = settings["enableVerboseLogging"] as? Bool { enableVerboseLogging = value }
        if let value = settings["showDebugInfo"] as? Bool { showDebugInfo = value }
        if let value = settings["saveNetworkLogs"] as? Bool { saveNetworkLogs = value }
        if let value = settings["logLevel"] as? String { logLevel = value }
        if let value = settings["enableHardwareAcceleration"] as? Bool { enableHardwareAcceleration = value }
        if let value = settings["optimizeMemoryUsage"] as? Bool { optimizeMemoryUsage = value }
        if let value = settings["enableBackgroundScanning"] as? Bool { enableBackgroundScanning = value }
        if let value = settings["maxConcurrentConnections"] as? Int { maxConcurrentConnections = value }
        if let value = settings["enableIPv6Support"] as? Bool { enableIPv6Support = value }
        if let value = settings["useNewDiscoveryAlgorithm"] as? Bool { useNewDiscoveryAlgorithm = value }
        if let value = settings["enableP2PDirectConnection"] as? Bool { enableP2PDirectConnection = value }
        if let value = settings["enableRealTimeWeather"] as? Bool { enableRealTimeWeather = value }
        if let value = settings["enableHandshakeDiagnostics"] as? Bool { enableHandshakeDiagnostics = value }
        if let value = settings["performanceMode"] as? String, let pm = PerformanceMode(rawValue: value) { performanceMode = pm }
        if let value = settings["showRealtimeFPS"] as? Bool { showRealtimeFPS = value }
        if let value = settings["enableCompatibilityMode"] as? Bool { enableCompatibilityMode = value }
        if let value = settings["enableCompanionLink"] as? Bool { enableCompanionLink = value }
        if let value = settings["strictModeForSensitiveGroups"] as? Bool { strictModeForSensitiveGroups = value }
        if let value = settings["aqiThresholdCautionUrban"] as? Int { aqiThresholdCautionUrban = value }
        if let value = settings["aqiThresholdSensitiveUrban"] as? Int { aqiThresholdSensitiveUrban = value }
        if let value = settings["aqiThresholdUnhealthyUrban"] as? Int { aqiThresholdUnhealthyUrban = value }
        if let value = settings["aqiThresholdVeryUnhealthyUrban"] as? Int { aqiThresholdVeryUnhealthyUrban = value }
        if let value = settings["aqiThresholdCautionSuburban"] as? Int { aqiThresholdCautionSuburban = value }
        if let value = settings["aqiThresholdSensitiveSuburban"] as? Int { aqiThresholdSensitiveSuburban = value }
        if let value = settings["aqiThresholdUnhealthySuburban"] as? Int { aqiThresholdUnhealthySuburban = value }
        if let value = settings["aqiThresholdVeryUnhealthySuburban"] as? Int { aqiThresholdVeryUnhealthySuburban = value }
        if let value = settings["uvThresholdModerate"] as? Double { uvThresholdModerate = value }
        if let value = settings["uvThresholdStrong"] as? Double { uvThresholdStrong = value }
        if let value = settings["onlyNotifyVerifiedDevices"] as? Bool { onlyNotifyVerifiedDevices = value }
        if settings["enablePQC"] is Bool { enablePQC = true }
        if let value = settings["pqcSignatureAlgorithm"] as? String { pqcSignatureAlgorithm = value }
        if let value = settings["enablePQCHybridTLS"] as? Bool { enablePQCHybridTLS = value }
        if let value = settings["preferXWingHybrid"] as? Bool { preferXWingHybrid = value }
        if let value = settings["useSecureEnclaveMLDSA"] as? Bool { useSecureEnclaveMLDSA = value }
        if let value = settings["useSecureEnclaveMLKEM"] as? Bool { useSecureEnclaveMLKEM = value }

 // 系统监控设置
        if let value = settings["systemMonitorRefreshInterval"] as? Double { systemMonitorRefreshInterval = value }
        if let value = settings["enableSystemNotifications"] as? Bool { enableSystemNotifications = value }
        if let value = settings["cpuThreshold"] as? Double { cpuThreshold = value }
        if let value = settings["memoryThreshold"] as? Double { memoryThreshold = value }
        if let value = settings["diskThreshold"] as? Double { diskThreshold = value }
        if let value = settings["enableAutoRefresh"] as? Bool { enableAutoRefresh = value }
        if let value = settings["showTrendIndicators"] as? Bool { showTrendIndicators = value }
        if let value = settings["enableSoundAlerts"] as? Bool { enableSoundAlerts = value }
        if let value = settings["maxHistoryPoints"] as? Double { maxHistoryPoints = value }
        if let value = settings["systemMonitorRetentionDays"] as? Int { systemMonitorRetentionDays = max(1, value) }
        if let value = settings["systemMonitorChartType"] as? String,
           let chartType = SystemMonitorChartType(rawValue: value) {
            systemMonitorChartType = chartType
        }
        if let value = settings["systemMonitorSamplingPrecision"] as? String,
           let samplingPrecision = SystemMonitorSamplingPrecision(rawValue: value) {
            systemMonitorSamplingPrecision = samplingPrecision
        }
        if let value = settings["enableRemoteMonitoring"] as? Bool { enableRemoteMonitoring = value }
        if let value = settings["enablePerformanceAlerts"] as? Bool { enablePerformanceAlerts = value }
        if let value = settings["temperatureThreshold"] as? Double { temperatureThreshold = value }
        if let value = settings["enableTemperatureMonitoring"] as? Bool { enableTemperatureMonitoring = value }
        if let value = settings["enableFanSpeedMonitoring"] as? Bool { enableFanSpeedMonitoring = value }
        if let value = settings["fanSpeedThreshold"] as? Double { fanSpeedThreshold = value }
        if let value = settings["enableThermalThrottlingAlert"] as? Bool { enableThermalThrottlingAlert = value }
        if let value = settings["showMonitorCPU"] as? Bool { showMonitorCPU = value }
        if let value = settings["showMonitorMemory"] as? Bool { showMonitorMemory = value }
        if let value = settings["showMonitorTemperature"] as? Bool { showMonitorTemperature = value }
        if let value = settings["showMonitorFanSpeed"] as? Bool { showMonitorFanSpeed = value }
        if let value = settings["showMonitorDisk"] as? Bool { showMonitorDisk = value }
        if let value = settings["showMonitorNetwork"] as? Bool { showMonitorNetwork = value }

 // 文件传输设置
        if let value = settings["defaultTransferPath"] as? String { defaultTransferPath = value }
        if let value = settings["transferBufferSize"] as? Int { transferBufferSize = value }
        if let value = settings["autoRetryFailedTransfers"] as? Bool { autoRetryFailedTransfers = value }
        if let value = settings["keepTransferHistory"] as? Bool { keepTransferHistory = value }
        if let value = settings["keepSystemAwakeDuringTransfer"] as? Bool { keepSystemAwakeDuringTransfer = value }
        if let value = settings["scanTransferFilesForVirus"] as? Bool { scanTransferFilesForVirus = value }
        if let value = settings["transferSpeedLimitMBps"] as? Double { transferSpeedLimitMBps = value }
        if let value = settings["transferSpeedLimitMBps"] as? Int { transferSpeedLimitMBps = Double(value) }
        if let value = settings["encryptionAlgorithm"] as? String,
           let algorithm = try? FileTransferEncryptionAlgorithm(persistedValue: value) {
            encryptionAlgorithm = algorithm
        }
        if let value = settings["scanLevel"] as? String, let level = FileScanService.ScanLevel(rawValue: value) { scanLevel = level }

        enforceStrictCertificateValidationIfNeeded(context: "legacy import payload")
        applyRuntimeSettingsSnapshot()
    }

 /// 验证导入的设置数据
    private func validateImportedSettings(_ settingsData: SettingsExportData) throws {
 // 验证扫描间隔范围
        if settingsData.scanInterval < 1.0 || settingsData.scanInterval > 300.0 {
            throw SettingsError.validationFailed("扫描间隔必须在1-300秒之间")
        }

 // 验证连接超时范围
        if settingsData.connectionTimeout < 1.0 || settingsData.connectionTimeout > 60.0 {
            throw SettingsError.validationFailed("连接超时必须在1-60秒之间")
        }

 // 验证重试次数范围
        if settingsData.maxRetryAttempts < 1 || settingsData.maxRetryAttempts > 10 {
            throw SettingsError.validationFailed("重试次数必须在1-10次之间")
        }

 // 验证WiFi扫描间隔范围
        if settingsData.wifiScanInterval < 5.0 || settingsData.wifiScanInterval > 300.0 {
            throw SettingsError.validationFailed("WiFi扫描间隔必须在5-300秒之间")
        }

 // 验证监控间隔范围
        if settingsData.monitoringInterval < 1.0 || settingsData.monitoringInterval > 60.0 {
            throw SettingsError.validationFailed("监控间隔必须在1-60秒之间")
        }

 // 验证主题色彩
        let validThemeColors = ["blue", "green", "red", "orange", "purple", "pink"]
        if !validThemeColors.contains(settingsData.themeColor) {
            throw SettingsError.validationFailed("无效的主题色彩")
        }
    }

 /// 应用导入的设置
    @MainActor
    private func applyImportedSettings(_ settingsData: SettingsExportData) async {
 // 通用设置
        useDarkMode = settingsData.useDarkMode
 // 将字符串转换为Color
        switch settingsData.themeColor {
        case "blue": themeColor = .blue
        case "green": themeColor = .green
        case "red": themeColor = .red
        case "orange": themeColor = .orange
        case "purple": themeColor = .purple
        case "pink": themeColor = .pink
        default: themeColor = .blue
        }
        showSystemNotifications = settingsData.enableSystemNotifications

 // 网络设置
        scanInterval = Int(settingsData.scanInterval)
        connectionTimeout = Int(settingsData.connectionTimeout)
        retryCount = settingsData.maxRetryAttempts

 // 设备管理设置
        autoDiscoverAppleTV = settingsData.autoDiscoverAppleTV
        showHomePodDevices = settingsData.showHomePodDevices
        showThirdPartyAirPlayDevices = settingsData.showThirdPartyAirPlayDevices
 // 注意：这些属性在当前SettingsManager中不存在，需要添加或映射到现有属性

 // 高级设置
        enableVerboseLogging = settingsData.enableVerboseLogging
 // 性能模式（结构化导入可选）
        if let pmRaw = settingsData.performanceMode, let pm = PerformanceMode(rawValue: pmRaw) {
            performanceMode = pm
        }
 // 隐私诊断开关（结构化导入可选）
        if let diagEnabled = settingsData.enableHandshakeDiagnostics {
            enableHandshakeDiagnostics = diagEnabled
        }
 // 注意：enableDebugMode和enablePerformanceMonitoring需要添加到SettingsManager

 // 系统监控设置
        systemMonitorRefreshInterval = settingsData.monitoringInterval
        if let value = settingsData.showTrendIndicators { showTrendIndicators = value }
        if let value = settingsData.maxHistoryPoints { maxHistoryPoints = value }
        if let value = settingsData.systemMonitorRetentionDays { systemMonitorRetentionDays = max(1, value) }
        if let value = settingsData.systemMonitorChartType, let chartType = SystemMonitorChartType(rawValue: value) {
            systemMonitorChartType = chartType
        }
        if let value = settingsData.systemMonitorSamplingPrecision, let samplingPrecision = SystemMonitorSamplingPrecision(rawValue: value) {
            systemMonitorSamplingPrecision = samplingPrecision
        }
        if let value = settingsData.enableRemoteMonitoring { enableRemoteMonitoring = value }
        if let value = settingsData.enablePerformanceAlerts { enablePerformanceAlerts = value }
        if let value = settingsData.temperatureThreshold { temperatureThreshold = value }
        if let value = settingsData.enableTemperatureMonitoring { enableTemperatureMonitoring = value }
        if let value = settingsData.enableFanSpeedMonitoring { enableFanSpeedMonitoring = value }
        if let value = settingsData.fanSpeedThreshold { fanSpeedThreshold = value }
        if let value = settingsData.enableThermalThrottlingAlert { enableThermalThrottlingAlert = value }
        if let value = settingsData.showMonitorCPU { showMonitorCPU = value }
        if let value = settingsData.showMonitorMemory { showMonitorMemory = value }
        if let value = settingsData.showMonitorTemperature { showMonitorTemperature = value }
        if let value = settingsData.showMonitorFanSpeed { showMonitorFanSpeed = value }
        if let value = settingsData.showMonitorDisk { showMonitorDisk = value }
        if let value = settingsData.showMonitorNetwork { showMonitorNetwork = value }

        enforceStrictCertificateValidationIfNeeded(context: "structured import payload")
        applyRuntimeSettingsSnapshot()
        logger.info("设置导入完成，来源版本: \(settingsData.appVersion)，导出时间: \(settingsData.exportDate)")
    }

 /// 重置网络设置到默认值
    public func resetNetworkSettings() {
 // 重置WiFi设置
        autoConnectKnownNetworks = true
        showHiddenNetworks = false
        prefer5GHz = true
        wifiScanTimeout = 10

 // 重置网络发现设置
        enableBonjourDiscovery = true
        enableMDNSResolution = true
        scanCustomPorts = false
        discoveryTimeout = 30
        discoveryPassiveMode = true
        requireAuthorizationForConnection = true
        enableWiFiAwareDiscovery = true

 // 重置连接设置
        connectionTimeout = 10
        retryCount = 3
        enableConnectionEncryption = true
        verifyCertificates = true

 // 清空自定义服务类型
        customServiceTypes = []
        applyRuntimeSettingsSnapshot()
    }

 /// 获取缓存大小
    public func getCacheSize() -> String {
        let cacheSize = calculateCacheSize()
        return formatBytes(cacheSize)
    }

 /// 清理缓存
    public func clearCache() {
        Task {
            await performCacheClear()
        }
    }

 /// 应用主题模式
    public func applyThemeMode() {
        Task { @MainActor in
            if let window = NSApplication.shared.windows.first {
                window.appearance = self.useDarkMode ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
            }

 // 发送主题变更通知
            NotificationCenter.default.post(
                name: NSNotification.Name("ThemeDidChange"),
                object: nil,
                userInfo: ["isDarkMode": self.useDarkMode, "themeColor": self.themeColor]
            )
        }
    }

 /// 请求通知权限
    public func requestNotificationPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])

            Task { @MainActor in
            self.showSystemNotifications = granted
        }

            return granted
        } catch {
            SkyBridgeLogger.ui.error("通知权限请求失败: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

 /// 发送系统通知
    public func sendSystemNotification(
        title: String,
        body: String,
        identifier: String = UUID().uuidString,
        categoryIdentifier: String? = nil,
        userInfo: [AnyHashable: Any] = [:]
    ) {
        guard showSystemNotifications else { return }

        // Some run environments (unit tests, `swift run`, certain Xcode/DerivedData launch setups)
        // don't have a valid App Bundle. In that case UNUserNotificationCenter.current() may assert:
        // "bundleProxyForCurrentProcess is nil".
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.path.lowercased().hasSuffix(".app"),
              Bundle.main.bundleIdentifier != nil else {
            SkyBridgeLogger.ui.debugOnly("跳过系统通知：当前进程无有效 App Bundle title=\(title)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = enableSoundAlerts ? .default : nil
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        if !userInfo.isEmpty {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                SkyBridgeLogger.ui.error("发送通知失败: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

 // MARK: - 私有辅助方法

    private func enforceStrictCertificateValidationIfNeeded(context: String) {
        guard !verifyCertificates else { return }
        logger.warning("检测到已关闭证书校验（\(context, privacy: .public)），已迁移为严格校验")
        verifyCertificates = true
        userDefaults.set(true, forKey: "Settings.VerifyCertificates")
    }

 /// 计算缓存大小
    private func calculateCacheSize() -> Int64 {
        var totalSize: Int64 = 0

 // 计算应用缓存目录大小
        if let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let appCacheURL = cacheURL.appendingPathComponent(Bundle.main.bundleIdentifier ?? "SkyBridgeCompass")
            totalSize += directorySize(at: appCacheURL)
        }

 // 计算临时文件大小
        let tempURL = FileManager.default.temporaryDirectory
        totalSize += directorySize(at: tempURL.appendingPathComponent("SkyBridgeCompass"))

 // 计算头像缓存大小
        totalSize += calculateAvatarCacheSize()

 // 计算Metal渲染缓存大小（估算）
        totalSize += calculateMetalCacheSize()

 // 计算系统监控数据缓存大小
        totalSize += calculateSystemMonitorCacheSize()

 // 计算网络日志缓存大小
        totalSize += calculateNetworkLogsCacheSize()

 // 计算UserDefaults占用空间（估算）
        totalSize += Int64(userDefaults.dictionaryRepresentation().description.count)

        return totalSize
    }

 /// 计算头像缓存大小
    private func calculateAvatarCacheSize() -> Int64 {
 // 备用方案：计算头像缓存目录大小
        if let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let avatarCacheURL = cacheURL.appendingPathComponent("Avatars")
            return directorySize(at: avatarCacheURL)
        }

        return 0
    }

 /// 计算Metal缓存大小（估算）
    private func calculateMetalCacheSize() -> Int64 {
        var metalCacheSize: Int64 = 0

 // 计算Metal着色器缓存
        if let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let metalCacheURL = cacheURL.appendingPathComponent("com.apple.metal")
            metalCacheSize += directorySize(at: metalCacheURL)
        }

 // 估算运行时Metal缓存（基于可用内存的小部分）
        let processInfo = ProcessInfo.processInfo
        metalCacheSize += Int64(processInfo.physicalMemory / 10000) // 更保守的估算值

        return metalCacheSize
    }

 /// 计算系统监控数据缓存大小
    private func calculateSystemMonitorCacheSize() -> Int64 {
        if let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let monitorCacheURL = cacheURL.appendingPathComponent("SystemMonitor")
            return directorySize(at: monitorCacheURL)
        }
        return 0
    }

 /// 计算网络日志缓存大小
    private func calculateNetworkLogsCacheSize() -> Int64 {
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let logsURL = documentsURL.appendingPathComponent("Logs")
            return directorySize(at: logsURL)
        }
        return 0
    }

 /// 计算目录大小
    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                totalSize += Int64(resourceValues.fileSize ?? 0)
            } catch {
                continue
            }
        }

        return totalSize
    }

 /// 格式化字节数
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

 /// 执行缓存清理
    @MainActor
    private func performCacheClear() async {
        var clearedSize: Int64 = 0

 // 清理应用缓存目录
        if let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let appCacheURL = cacheURL.appendingPathComponent(Bundle.main.bundleIdentifier ?? "SkyBridgeCompass")
            clearedSize += await clearDirectory(at: appCacheURL)
        }

 // 清理临时文件
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("SkyBridgeCompass")
        clearedSize += await clearDirectory(at: tempURL)

 // 清理过期的网络日志
        if !saveNetworkLogs {
            await clearNetworkLogs()
        }

 // 发送缓存清理完成通知
        if enableSystemNotifications {
            sendSystemNotification(
                title: "缓存清理完成",
                body: "已清理 \(formatBytes(clearedSize)) 缓存数据"
            )
        }

 // 发送应用内通知
        NotificationCenter.default.post(
            name: NSNotification.Name("CacheClearCompleted"),
            object: nil,
            userInfo: ["clearedSize": clearedSize]
        )
    }

 /// 清理指定目录
    private func clearDirectory(at url: URL) async -> Int64 {
        var clearedSize: Int64 = 0

        do {
            if FileManager.default.fileExists(atPath: url.path) {
 // 计算清理前的大小
                clearedSize = directorySize(at: url)

 // 删除目录内容
                let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for item in contents {
                    try FileManager.default.removeItem(at: item)
                }
            }
        } catch {
            SkyBridgeLogger.ui.error("清理目录失败: \(error.localizedDescription, privacy: .private)")
        }

        return clearedSize
    }

 /// 清理网络日志
    private func clearNetworkLogs() async {
 // 实现网络日志清理逻辑
 // 这里可以清理应用生成的网络日志文件
    }

 /// 添加自定义服务类型
    public func addCustomServiceType(_ serviceType: String) {
        if !customServiceTypes.contains(serviceType) {
            customServiceTypes.append(serviceType)
        }
    }

 /// 移除自定义服务类型
    public func removeCustomServiceType(_ serviceType: String) {
        customServiceTypes.removeAll { $0 == serviceType }
    }

 // MARK: - 私有方法

 /// 加载设置
    private func loadSettings() {
 // 通用设置
        autoScanOnStartup = userDefaults.bool(forKey: "Settings.AutoScanOnStartup", defaultValue: true)
        showSystemNotifications = userDefaults.bool(forKey: "Settings.ShowSystemNotifications", defaultValue: true)
        useDarkMode = userDefaults.bool(forKey: "Settings.UseDarkMode", defaultValue: false)
        scanInterval = userDefaults.integer(forKey: "Settings.ScanInterval", defaultValue: 30)
        showDeviceDetails = userDefaults.bool(forKey: "Settings.ShowDeviceDetails", defaultValue: true)
        showConnectionStats = userDefaults.bool(forKey: "Settings.ShowConnectionStats", defaultValue: true)
        compactMode = userDefaults.bool(forKey: "Settings.CompactMode", defaultValue: false)
        // themeColor: support both new namespaced key and legacy key ("ThemeColor") used by older UI code.
        if let data = userDefaults.data(forKey: "Settings.ThemeColor") ?? userDefaults.data(forKey: "ThemeColor"),
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            themeColor = Color(nsColor)
        } else if let hex = userDefaults.string(forKey: "Settings.ThemeColorHex") {
            themeColor = Self.color(fromHexRGBA: hex) ?? .blue
        }

 // 网络设置
        autoConnectKnownNetworks = userDefaults.bool(forKey: "Settings.AutoConnectKnownNetworks", defaultValue: true)
        showHiddenNetworks = userDefaults.bool(forKey: "Settings.ShowHiddenNetworks", defaultValue: false)
        prefer5GHz = userDefaults.bool(forKey: "Settings.Prefer5GHz", defaultValue: true)
        wifiScanTimeout = userDefaults.integer(forKey: "Settings.WiFiScanTimeout", defaultValue: 10)
        enableBonjourDiscovery = userDefaults.bool(forKey: "Settings.EnableBonjourDiscovery", defaultValue: true)
        enableMDNSResolution = userDefaults.bool(forKey: "Settings.EnableMDNSResolution", defaultValue: true)
        scanCustomPorts = userDefaults.bool(forKey: "Settings.ScanCustomPorts", defaultValue: false)
        discoveryTimeout = userDefaults.integer(forKey: "Settings.DiscoveryTimeout", defaultValue: 30)
        connectionTimeout = userDefaults.integer(forKey: "Settings.ConnectionTimeout", defaultValue: 10)
        retryCount = userDefaults.integer(forKey: "Settings.RetryCount", defaultValue: 3)
        enableConnectionEncryption = userDefaults.bool(forKey: "Settings.EnableConnectionEncryption", defaultValue: true)
        verifyCertificates = userDefaults.bool(forKey: "Settings.VerifyCertificates", defaultValue: true)
        enforceStrictCertificateValidationIfNeeded(context: "load settings")
        discoveryPassiveMode = userDefaults.bool(forKey: "Settings.DiscoveryPassiveMode", defaultValue: true)
        requireAuthorizationForConnection = userDefaults.bool(forKey: "Settings.RequireAuthorizationForConnection", defaultValue: true)
        enableWiFiAwareDiscovery = userDefaults.bool(forKey: "Settings.EnableWiFiAwareDiscovery", defaultValue: true)
        customServiceTypes = userDefaults.stringArray(forKey: "Settings.CustomServiceTypes") ?? []

 // 设备设置
        autoConnectPairedDevices = userDefaults.bool(forKey: "Settings.AutoConnectPairedDevices", defaultValue: true)
        showDeviceRSSI = userDefaults.bool(forKey: "Settings.ShowDeviceRSSI", defaultValue: true)
        showConnectableDevicesOnly = userDefaults.bool(forKey: "Settings.ShowOnlyConnectableDevices", defaultValue: false)
        autoDiscoverAppleTV = userDefaults.bool(forKey: "Settings.AutoDiscoverAppleTV", defaultValue: true)
        showHomePodDevices = userDefaults.bool(forKey: "Settings.ShowHomePodDevices", defaultValue: true)
        showThirdPartyAirPlayDevices = userDefaults.bool(forKey: "Settings.ShowThirdPartyAirPlay", defaultValue: true)
        hideOfflineDevices = userDefaults.bool(forKey: "Settings.HideOfflineDevices", defaultValue: false)
        sortBySignalStrength = userDefaults.bool(forKey: "Settings.SortBySignalStrength", defaultValue: true)
        showDeviceIcons = userDefaults.bool(forKey: "Settings.ShowDeviceIcons", defaultValue: true)
        minimumSignalStrength = userDefaults.double(forKey: "Settings.MinimumSignalStrength", defaultValue: -80.0)
        signalStrengthAlpha = userDefaults.double(forKey: "Settings.SignalStrengthAlpha", defaultValue: 0.6)
        sortWeightVerified = userDefaults.integer(forKey: "Settings.SortWeightVerified", defaultValue: 2000)
        sortWeightConnected = userDefaults.integer(forKey: "Settings.SortWeightConnected", defaultValue: 1000)
        sortWeightSignalMultiplier = userDefaults.integer(forKey: "Settings.SortWeightSignalMultiplier", defaultValue: 100)

 // 高级设置
        enableVerboseLogging = userDefaults.bool(forKey: "Settings.EnableVerboseLogging", defaultValue: false)
        showDebugInfo = userDefaults.bool(forKey: "Settings.ShowDebugInfo", defaultValue: false)
        saveNetworkLogs = userDefaults.bool(forKey: "Settings.SaveNetworkLogs", defaultValue: false)
        logLevel = userDefaults.string(forKey: "Settings.LogLevel") ?? "Info"
        enableHardwareAcceleration = userDefaults.bool(forKey: "Settings.EnableHardwareAcceleration", defaultValue: true)
        optimizeMemoryUsage = userDefaults.bool(forKey: "Settings.OptimizeMemoryUsage", defaultValue: true)
        enableBackgroundScanning = userDefaults.bool(forKey: "Settings.BackgroundScanning", defaultValue: false)
        maxConcurrentConnections = userDefaults.integer(forKey: "Settings.MaxConcurrentConnections", defaultValue: 10)
        enableIPv6Support = userDefaults.bool(forKey: "Settings.EnableIPv6Support", defaultValue: false)
        useNewDiscoveryAlgorithm = userDefaults.bool(forKey: "Settings.UseNewDiscoveryAlgorithm", defaultValue: false)
        enableP2PDirectConnection = userDefaults.bool(forKey: "Settings.EnableP2PDirectConnect", defaultValue: false)
        enableHandshakeDiagnostics = userDefaults.bool(forKey: "Settings.EnableHandshakeDiagnostics", defaultValue: false)
        enableRealTimeWeather = userDefaults.bool(forKey: "Settings.EnableRealTimeWeather", defaultValue: false)
        performanceMode = PerformanceMode(rawValue: userDefaults.string(forKey: "Settings.PerformanceMode") ?? "") ?? .balanced
        showRealtimeFPS = userDefaults.bool(forKey: "Settings.ShowRealtimeFPS", defaultValue: false)
        enableCompatibilityMode = userDefaults.bool(forKey: "Settings.EnableCompatibilityMode", defaultValue: false)
        enableCompanionLink = userDefaults.bool(forKey: "Settings.EnableCompanionLink", defaultValue: false)
        // PQC settings (previously not persisted)
        enablePQC = true
        userDefaults.set(true, forKey: "Settings.EnablePQC")
        pqcSignatureAlgorithm = Self.normalizedPQCSignatureAlgorithm(
            userDefaults.string(forKey: "Settings.PQCSignatureAlgorithm") ?? "ML-DSA-65"
        )
        enablePQCHybridTLS = userDefaults.bool(forKey: "Settings.EnablePQCHybridTLS", defaultValue: false)
        preferXWingHybrid = userDefaults.bool(forKey: SettingsStorageKeys.preferXWingHybrid, defaultValue: false)
        useSecureEnclaveMLDSA = userDefaults.bool(forKey: "Settings.UseSecureEnclaveMLDSA", defaultValue: true)
        useSecureEnclaveMLKEM = userDefaults.bool(forKey: "Settings.UseSecureEnclaveMLKEM", defaultValue: true)
        strictModeForSensitiveGroups = userDefaults.bool(forKey: "Settings.StrictModeForSensitiveGroups", defaultValue: false)
        aqiThresholdCautionUrban = userDefaults.integer(forKey: "Settings.AQIThresholdCautionUrban", defaultValue: 100)
        aqiThresholdSensitiveUrban = userDefaults.integer(forKey: "Settings.AQIThresholdSensitiveUrban", defaultValue: 150)
        aqiThresholdUnhealthyUrban = userDefaults.integer(forKey: "Settings.AQIThresholdUnhealthyUrban", defaultValue: 200)
        aqiThresholdVeryUnhealthyUrban = userDefaults.integer(forKey: "Settings.AQIThresholdVeryUnhealthyUrban", defaultValue: 300)
        aqiThresholdCautionSuburban = userDefaults.integer(forKey: "Settings.AQIThresholdCautionSuburban", defaultValue: 120)
        aqiThresholdSensitiveSuburban = userDefaults.integer(forKey: "Settings.AQIThresholdSensitiveSuburban", defaultValue: 170)
        aqiThresholdUnhealthySuburban = userDefaults.integer(forKey: "Settings.AQIThresholdUnhealthySuburban", defaultValue: 220)
        aqiThresholdVeryUnhealthySuburban = userDefaults.integer(forKey: "Settings.AQIThresholdVeryUnhealthySuburban", defaultValue: 300)
        uvThresholdModerate = userDefaults.double(forKey: "Settings.UVThresholdModerate", defaultValue: 6.0)
        uvThresholdStrong = userDefaults.double(forKey: "Settings.UVThresholdStrong", defaultValue: 8.0)
        onlyNotifyVerifiedDevices = userDefaults.bool(forKey: "Settings.OnlyNotifyVerifiedDevices", defaultValue: false)

 // 系统监控设置
        systemMonitorRefreshInterval = userDefaults.double(forKey: "Settings.SystemMonitorRefreshInterval", defaultValue: 1.0)
        enableSystemNotifications = userDefaults.bool(forKey: "Settings.EnableSystemNotifications", defaultValue: true)
        cpuThreshold = userDefaults.double(forKey: "Settings.CPUThreshold", defaultValue: 80.0)
        memoryThreshold = userDefaults.double(forKey: "Settings.MemoryThreshold", defaultValue: 80.0)
        diskThreshold = userDefaults.double(forKey: "Settings.DiskThreshold", defaultValue: 90.0)
        enableAutoRefresh = userDefaults.bool(forKey: "Settings.EnableAutoRefresh", defaultValue: true)
        showTrendIndicators = userDefaults.bool(forKey: "Settings.ShowTrendIndicators", defaultValue: true)
        enableSoundAlerts = userDefaults.bool(forKey: "Settings.EnableSoundAlerts", defaultValue: false)
        maxHistoryPoints = userDefaults.double(forKey: "Settings.MaxHistoryPoints", defaultValue: 300.0)
        systemMonitorRetentionDays = userDefaults.integer(forKey: "Settings.SystemMonitorRetentionDays", defaultValue: 7)
        systemMonitorChartType = SystemMonitorChartType(rawValue: userDefaults.string(forKey: "Settings.SystemMonitorChartType") ?? "") ?? .line
        systemMonitorSamplingPrecision = SystemMonitorSamplingPrecision(rawValue: userDefaults.string(forKey: "Settings.SystemMonitorSamplingPrecision") ?? "") ?? .normal
        enableRemoteMonitoring = userDefaults.bool(forKey: "Settings.EnableRemoteMonitoring", defaultValue: false)
        enablePerformanceAlerts = userDefaults.bool(forKey: "Settings.EnablePerformanceAlerts", defaultValue: true)
        temperatureThreshold = userDefaults.double(forKey: "Settings.TemperatureThreshold", defaultValue: 80.0)
        enableTemperatureMonitoring = userDefaults.bool(forKey: "Settings.EnableTemperatureMonitoring", defaultValue: true)
        enableFanSpeedMonitoring = userDefaults.bool(forKey: "Settings.EnableFanSpeedMonitoring", defaultValue: true)
        fanSpeedThreshold = userDefaults.double(forKey: "Settings.FanSpeedThreshold", defaultValue: 4000.0)
        enableThermalThrottlingAlert = userDefaults.bool(forKey: "Settings.EnableThermalThrottlingAlert", defaultValue: true)
        showMonitorCPU = userDefaults.bool(forKey: "Settings.ShowMonitorCPU", defaultValue: true)
        showMonitorMemory = userDefaults.bool(forKey: "Settings.ShowMonitorMemory", defaultValue: true)
        showMonitorTemperature = userDefaults.bool(forKey: "Settings.ShowMonitorTemperature", defaultValue: true)
        showMonitorFanSpeed = userDefaults.bool(forKey: "Settings.ShowMonitorFanSpeed", defaultValue: true)
        showMonitorDisk = userDefaults.bool(forKey: "Settings.ShowMonitorDisk", defaultValue: true)
        showMonitorNetwork = userDefaults.bool(forKey: "Settings.ShowMonitorNetwork", defaultValue: true)

 // 文件传输设置
        defaultTransferPath = userDefaults.string(forKey: "Settings.DefaultTransferPath") ?? "~/Downloads"
        transferBufferSize = userDefaults.integer(forKey: "Settings.TransferBufferSize", defaultValue: 131072)
        autoRetryFailedTransfers = userDefaults.bool(forKey: "Settings.AutoRetryFailedTransfers", defaultValue: true)
        keepTransferHistory = userDefaults.bool(forKey: "Settings.KeepTransferHistory", defaultValue: true)
        keepSystemAwakeDuringTransfer = userDefaults.bool(forKey: "Settings.KeepSystemAwakeDuringTransfer", defaultValue: false)
        scanTransferFilesForVirus = userDefaults.bool(forKey: "Settings.ScanTransferFilesForVirus", defaultValue: false)
        transferSpeedLimitMBps = userDefaults.double(forKey: "Settings.TransferSpeedLimitMBps", defaultValue: 0)
        let persistedFileTransferAlgorithm = userDefaults.string(forKey: "Settings.EncryptionAlgorithm") ?? FileTransferEncryptionAlgorithm.aes256GCM.rawValue
        encryptionAlgorithm = (try? FileTransferEncryptionAlgorithm(persistedValue: persistedFileTransferAlgorithm)) ?? .aes256GCM
        userDefaults.set(encryptionAlgorithm.rawValue, forKey: "Settings.EncryptionAlgorithm")
        scanLevel = FileScanService.ScanLevel(rawValue: userDefaults.string(forKey: "Settings.ScanLevel") ?? "") ?? .standard
        enableZeroCopyBGRA = userDefaults.bool(forKey: "Settings.EnableZeroCopyBGRA", defaultValue: false)
        preferNearestNeighborScaling = userDefaults.bool(forKey: "Settings.PreferNearestNeighborScaling", defaultValue: false)
    }

 /// 设置观察者
    private func setupObservers() {
 // 通用设置观察者
        $autoScanOnStartup.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AutoScanOnStartup")
        }.store(in: &settingsCancellables)

        $showSystemNotifications.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowSystemNotifications")
        }.store(in: &settingsCancellables)

        $useDarkMode.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.UseDarkMode")
            self?.applyThemeMode() // 立即应用主题变化
        }.store(in: &settingsCancellables)

        $scanInterval.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ScanInterval")
            let interval = Double(value)
            DeviceManagementSettingsManager.shared.wifiScanInterval = interval
            DeviceManagementSettingsManager.shared.bluetoothScanInterval = interval
            DeviceManagementSettingsManager.shared.airplayScanInterval = interval
            self?.postWiFiSettingsChanged(["scanInterval": interval])
            self?.postBluetoothSettingsChanged(["scanInterval": interval])
            self?.postAirPlaySettingsChanged(["scanInterval": interval])
        }.store(in: &settingsCancellables)

        $showDeviceDetails.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowDeviceDetails")
            NotificationCenter.default.post(name: NSNotification.Name("DeviceDisplayModeChanged"), object: nil)
        }.store(in: &settingsCancellables)

        $showConnectionStats.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowConnectionStats")
            NotificationCenter.default.post(name: NSNotification.Name("ConnectionStatsDisplayChanged"), object: nil)
        }.store(in: &settingsCancellables)

        $compactMode.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.CompactMode")
            NotificationCenter.default.post(
                name: NSNotification.Name("LayoutModeChanged"),
                object: nil,
                userInfo: ["isCompact": value]
            )
        }.store(in: &settingsCancellables)

        // Theme color persistence (namespaced + legacy compatibility)
        $themeColor.sink { [weak self] value in
            guard let self else { return }
            if let data = Self.archive(color: value) {
                self.userDefaults.set(data, forKey: "Settings.ThemeColor")
                // legacy key used by older UI code
                self.userDefaults.set(data, forKey: "ThemeColor")
            }
            if let hex = Self.hexRGBA(from: value) {
                self.userDefaults.set(hex, forKey: "Settings.ThemeColorHex")
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("ThemeColorChanged"),
                object: nil,
                userInfo: ["color": value]
            )
        }.store(in: &settingsCancellables)

 // 设备列表排序权重观察者
        $sortWeightVerified.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.SortWeightVerified")
        }.store(in: &settingsCancellables)
        $sortWeightConnected.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.SortWeightConnected")
        }.store(in: &settingsCancellables)
        $sortWeightSignalMultiplier.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.SortWeightSignalMultiplier")
        }.store(in: &settingsCancellables)

 // 网络设置观察者
        $autoConnectKnownNetworks.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AutoConnectKnownNetworks")
        }.store(in: &settingsCancellables)

 // 文件传输设置观察者
        $defaultTransferPath.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.DefaultTransferPath")
        }.store(in: &settingsCancellables)

        $transferBufferSize.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.TransferBufferSize")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $autoRetryFailedTransfers.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AutoRetryFailedTransfers")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $keepTransferHistory.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.KeepTransferHistory")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $keepSystemAwakeDuringTransfer.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.KeepSystemAwakeDuringTransfer")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $scanTransferFilesForVirus.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ScanTransferFilesForVirus")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $transferSpeedLimitMBps.sink { [weak self] value in
            self?.userDefaults.set(max(0, value), forKey: "Settings.TransferSpeedLimitMBps")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $scanLevel.sink { [weak self] value in
            self?.userDefaults.set(value.rawValue, forKey: "Settings.ScanLevel")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $encryptionAlgorithm.sink { [weak self] value in
            self?.userDefaults.set(value.rawValue, forKey: "Settings.EncryptionAlgorithm")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $showHiddenNetworks.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowHiddenNetworks")
            self?.postWiFiSettingsChanged(["showHiddenNetworks": value])
        }.store(in: &settingsCancellables)

        $prefer5GHz.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.Prefer5GHz")
        }.store(in: &settingsCancellables)

        $wifiScanTimeout.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.WiFiScanTimeout")
            self?.postWiFiSettingsChanged(["scanInterval": Double(value)])
        }.store(in: &settingsCancellables)

        $enableBonjourDiscovery.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableBonjourDiscovery")
            self?.scheduleDiscoveryRuntimeApply(restartIfNeeded: true)
        }.store(in: &settingsCancellables)

        $enableMDNSResolution.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableMDNSResolution")
            self?.scheduleDiscoveryRuntimeApply(restartIfNeeded: false)
        }.store(in: &settingsCancellables)

        $discoveryPassiveMode.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.DiscoveryPassiveMode")
            self?.scheduleDiscoveryRuntimeApply(restartIfNeeded: true)
        }.store(in: &settingsCancellables)

        $requireAuthorizationForConnection.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.RequireAuthorizationForConnection")
        }.store(in: &settingsCancellables)

        $enableWiFiAwareDiscovery.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableWiFiAwareDiscovery")
            self?.scheduleDiscoveryRuntimeApply(restartIfNeeded: true)
        }.store(in: &settingsCancellables)

        $scanCustomPorts.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ScanCustomPorts")
            self?.scheduleDiscoveryRuntimeApply(restartIfNeeded: true)
        }.store(in: &settingsCancellables)

        $discoveryTimeout.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.DiscoveryTimeout")
            self?.scheduleDiscoveryRuntimeApply(restartIfNeeded: false)
        }.store(in: &settingsCancellables)

        $connectionTimeout.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ConnectionTimeout")
        }.store(in: &settingsCancellables)

        $retryCount.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.RetryCount")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $enableConnectionEncryption.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableConnectionEncryption")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $verifyCertificates.sink { [weak self] value in
            guard let self else { return }
            if !value {
                self.logger.warning("检测到证书校验被关闭请求，已强制保持严格校验")
                self.userDefaults.set(true, forKey: "Settings.VerifyCertificates")
                if self.verifyCertificates != true {
                    self.verifyCertificates = true
                }
                return
            }
            self.userDefaults.set(true, forKey: "Settings.VerifyCertificates")
        }.store(in: &settingsCancellables)

        $customServiceTypes.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.CustomServiceTypes")
            self?.scheduleDiscoveryRuntimeApply(restartIfNeeded: true)
        }.store(in: &settingsCancellables)

 // 设备设置观察者
        $autoConnectPairedDevices.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AutoConnectPairedDevices")
        }.store(in: &settingsCancellables)

        $showDeviceRSSI.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowDeviceRSSI")
        }.store(in: &settingsCancellables)

        $showConnectableDevicesOnly.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowOnlyConnectableDevices")
            self?.scheduleOnlineDevicePresentationRefresh()
        }.store(in: &settingsCancellables)

        $autoDiscoverAppleTV.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AutoDiscoverAppleTV")
            self?.postAirPlaySettingsChanged(["autoDiscoverAppleTV": value])
        }.store(in: &settingsCancellables)

        $showHomePodDevices.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowHomePodDevices")
            self?.postAirPlaySettingsChanged(["showHomePodDevices": value])
        }.store(in: &settingsCancellables)

        $showThirdPartyAirPlayDevices.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowThirdPartyAirPlay")
            self?.postAirPlaySettingsChanged(["showThirdPartyAirPlayDevices": value])
        }.store(in: &settingsCancellables)

        $hideOfflineDevices.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.HideOfflineDevices")
            self?.scheduleOnlineDevicePresentationRefresh()
        }.store(in: &settingsCancellables)

        $sortBySignalStrength.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.SortBySignalStrength")
        }.store(in: &settingsCancellables)

        $showDeviceIcons.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowDeviceIcons")
        }.store(in: &settingsCancellables)

        $minimumSignalStrength.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.MinimumSignalStrength")
            self?.scheduleOnlineDevicePresentationRefresh()
        }.store(in: &settingsCancellables)

        $signalStrengthAlpha.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.SignalStrengthAlpha")
        }.store(in: &settingsCancellables)

 // 高级设置观察者
        $enableVerboseLogging.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableVerboseLogging")
            self?.applyLoggingRuntimeSettings()
        }.store(in: &settingsCancellables)

        $showDebugInfo.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowDebugInfo")
        }.store(in: &settingsCancellables)

        $saveNetworkLogs.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.SaveNetworkLogs")
            NetworkActivityLogStore.shared.setEnabled(value)
        }.store(in: &settingsCancellables)

        $logLevel.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.LogLevel")
            self?.applyLoggingRuntimeSettings()
        }.store(in: &settingsCancellables)

        $enableHardwareAcceleration.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableHardwareAcceleration")
            self?.applyRemotePerformanceSettings(value)
        }.store(in: &settingsCancellables)

        $optimizeMemoryUsage.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.OptimizeMemoryUsage")
        }.store(in: &settingsCancellables)

        $enableBackgroundScanning.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.BackgroundScanning")
        }.store(in: &settingsCancellables)

        $maxConcurrentConnections.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.MaxConcurrentConnections")
            self?.scheduleFileTransferSettingsApply()
        }.store(in: &settingsCancellables)

        $enableIPv6Support.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableIPv6Support")
            self?.scheduleDiscoveryRuntimeApply(restartIfNeeded: false)
        }.store(in: &settingsCancellables)

        $useNewDiscoveryAlgorithm.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.UseNewDiscoveryAlgorithm")
            self?.scheduleDiscoveryRuntimeApply(restartIfNeeded: true)
        }.store(in: &settingsCancellables)

        $enableP2PDirectConnection.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableP2PDirectConnect")
        }.store(in: &settingsCancellables)
 // 隐私诊断开关持久化
        $enableHandshakeDiagnostics.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableHandshakeDiagnostics")
        }.store(in: &settingsCancellables)

        $enableRealTimeWeather.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableRealTimeWeather")
            self?.applyWeatherRuntimeSetting(value)
        }.store(in: &settingsCancellables)

        $performanceMode.sink { [weak self] value in
            self?.userDefaults.set(value.rawValue, forKey: "Settings.PerformanceMode")
            Task { await SystemOrchestrator.shared.reloadProfile(modeName: value.rawValue) }
        }.store(in: &settingsCancellables)
        $enableZeroCopyBGRA.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableZeroCopyBGRA")
        }.store(in: &settingsCancellables)

 // 实时FPS显示持久化
        $showRealtimeFPS.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowRealtimeFPS")
        }.store(in: &settingsCancellables)
	 // 兼容/更多设备模式与 companion‑link 开关持久化，并实时驱动 P2P Bonjour 浏览器集合。
        $enableCompatibilityMode
            .combineLatest($enableCompanionLink)
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1
            }
            .sink { [weak self] runtime in
                let compatibilityMode = runtime.0
                let companionLink = runtime.1
                self?.userDefaults.set(compatibilityMode, forKey: "Settings.EnableCompatibilityMode")
                self?.userDefaults.set(companionLink, forKey: "Settings.EnableCompanionLink")
                Task { @MainActor in
                    P2PDiscoveryService.shared.applyDiscoverySettings(
                        compatibilityMode: compatibilityMode,
                        companionLink: companionLink
                    )
                }
            }
            .store(in: &settingsCancellables)

        $preferNearestNeighborScaling.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.PreferNearestNeighborScaling")
        }.store(in: &settingsCancellables)

        // PQC settings persistence
        $enablePQC.sink { [weak self] value in
            guard let self else { return }
            guard value else {
                self.userDefaults.set(true, forKey: "Settings.EnablePQC")
                self.enablePQC = true
                self.clearCryptoProviderCacheForSettingsChange()
                return
            }
            self.userDefaults.set(true, forKey: "Settings.EnablePQC")
            self.clearCryptoProviderCacheForSettingsChange()
        }.store(in: &settingsCancellables)
        $pqcSignatureAlgorithm.sink { [weak self] value in
            guard let self else { return }
            let normalized = Self.normalizedPQCSignatureAlgorithm(value)
            guard normalized == value else {
                self.pqcSignatureAlgorithm = normalized
                return
            }
            self.userDefaults.set(normalized, forKey: "Settings.PQCSignatureAlgorithm")
            self.clearCryptoProviderCacheForSettingsChange()
        }.store(in: &settingsCancellables)
        $enablePQCHybridTLS.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnablePQCHybridTLS")
            self?.clearCryptoProviderCacheForSettingsChange()
        }.store(in: &settingsCancellables)
        $preferXWingHybrid.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: SettingsStorageKeys.preferXWingHybrid)
            self?.clearCryptoProviderCacheForSettingsChange()
        }.store(in: &settingsCancellables)
        $useSecureEnclaveMLDSA.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.UseSecureEnclaveMLDSA")
            self?.clearCryptoProviderCacheForSettingsChange()
        }.store(in: &settingsCancellables)
        $useSecureEnclaveMLKEM.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.UseSecureEnclaveMLKEM")
            self?.clearCryptoProviderCacheForSettingsChange()
        }.store(in: &settingsCancellables)

 // 系统监控设置观察者
        $systemMonitorRefreshInterval.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.SystemMonitorRefreshInterval")
        }.store(in: &settingsCancellables)

        $enableSystemNotifications.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableSystemNotifications")
        }.store(in: &settingsCancellables)

        $cpuThreshold.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.CPUThreshold")
        }.store(in: &settingsCancellables)

        $memoryThreshold.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.MemoryThreshold")
        }.store(in: &settingsCancellables)

        $diskThreshold.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.DiskThreshold")
        }.store(in: &settingsCancellables)

        $enableAutoRefresh.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableAutoRefresh")
        }.store(in: &settingsCancellables)

        $showTrendIndicators.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowTrendIndicators")
        }.store(in: &settingsCancellables)

        $enableSoundAlerts.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableSoundAlerts")
        }.store(in: &settingsCancellables)

        $maxHistoryPoints.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.MaxHistoryPoints")
        }.store(in: &settingsCancellables)
        $systemMonitorRetentionDays.sink { [weak self] value in
            self?.userDefaults.set(max(1, value), forKey: "Settings.SystemMonitorRetentionDays")
        }.store(in: &settingsCancellables)
        $systemMonitorChartType.sink { [weak self] value in
            self?.userDefaults.set(value.rawValue, forKey: "Settings.SystemMonitorChartType")
        }.store(in: &settingsCancellables)
        $systemMonitorSamplingPrecision.sink { [weak self] value in
            self?.userDefaults.set(value.rawValue, forKey: "Settings.SystemMonitorSamplingPrecision")
        }.store(in: &settingsCancellables)
        $enableRemoteMonitoring.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableRemoteMonitoring")
        }.store(in: &settingsCancellables)

        $enablePerformanceAlerts.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnablePerformanceAlerts")
        }.store(in: &settingsCancellables)
        $temperatureThreshold.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.TemperatureThreshold")
        }.store(in: &settingsCancellables)
        $enableTemperatureMonitoring.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableTemperatureMonitoring")
        }.store(in: &settingsCancellables)
        $enableFanSpeedMonitoring.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableFanSpeedMonitoring")
        }.store(in: &settingsCancellables)
        $fanSpeedThreshold.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.FanSpeedThreshold")
        }.store(in: &settingsCancellables)
        $enableThermalThrottlingAlert.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableThermalThrottlingAlert")
        }.store(in: &settingsCancellables)
        $showMonitorCPU.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowMonitorCPU")
        }.store(in: &settingsCancellables)
        $showMonitorMemory.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowMonitorMemory")
        }.store(in: &settingsCancellables)
        $showMonitorTemperature.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowMonitorTemperature")
        }.store(in: &settingsCancellables)
        $showMonitorFanSpeed.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowMonitorFanSpeed")
        }.store(in: &settingsCancellables)
        $showMonitorDisk.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowMonitorDisk")
        }.store(in: &settingsCancellables)
        $showMonitorNetwork.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowMonitorNetwork")
        }.store(in: &settingsCancellables)

 // 健康提醒阈值观察者
        $strictModeForSensitiveGroups.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.StrictModeForSensitiveGroups")
        }.store(in: &settingsCancellables)
        $aqiThresholdCautionUrban.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AQIThresholdCautionUrban")
        }.store(in: &settingsCancellables)
        $aqiThresholdSensitiveUrban.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AQIThresholdSensitiveUrban")
        }.store(in: &settingsCancellables)
        $aqiThresholdUnhealthyUrban.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AQIThresholdUnhealthyUrban")
        }.store(in: &settingsCancellables)
        $aqiThresholdVeryUnhealthyUrban.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AQIThresholdVeryUnhealthyUrban")
        }.store(in: &settingsCancellables)
        $aqiThresholdCautionSuburban.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AQIThresholdCautionSuburban")
        }.store(in: &settingsCancellables)
        $aqiThresholdSensitiveSuburban.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AQIThresholdSensitiveSuburban")
        }.store(in: &settingsCancellables)
        $aqiThresholdUnhealthySuburban.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AQIThresholdUnhealthySuburban")
        }.store(in: &settingsCancellables)
        $aqiThresholdVeryUnhealthySuburban.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AQIThresholdVeryUnhealthySuburban")
        }.store(in: &settingsCancellables)
        $uvThresholdModerate.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.UVThresholdModerate")
        }.store(in: &settingsCancellables)
        $uvThresholdStrong.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.UVThresholdStrong")
        }.store(in: &settingsCancellables)
        $onlyNotifyVerifiedDevices.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.OnlyNotifyVerifiedDevices")
        }.store(in: &settingsCancellables)
    }
}

// MARK: - UserDefaults 扩展
extension UserDefaults {
    func bool(forKey key: String, defaultValue: Bool) -> Bool {
        if object(forKey: key) == nil {
            return defaultValue
        }
        return bool(forKey: key)
    }

    func integer(forKey key: String, defaultValue: Int) -> Int {
        if object(forKey: key) == nil {
            return defaultValue
        }
        return integer(forKey: key)
    }

    func double(forKey key: String, defaultValue: Double) -> Double {
        if object(forKey: key) == nil {
            return defaultValue
        }
        return double(forKey: key)
    }
}

// MARK: - Theme color helpers (UserDefaults)
@available(macOS 14.0, *)
private extension SettingsManager {
    static func archive(color: Color) -> Data? {
        let ns = NSColor(color)
        return try? NSKeyedArchiver.archivedData(withRootObject: ns, requiringSecureCoding: false)
    }

    static func hexRGBA(from color: Color) -> String? {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        let a = Int(round(rgb.alphaComponent * 255))
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    static func color(fromHexRGBA s: String) -> Color? {
        var str = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 8, let v = UInt32(str, radix: 16) else { return nil }
        let r = Double((v >> 24) & 0xFF) / 255.0
        let g = Double((v >> 16) & 0xFF) / 255.0
        let b = Double((v >> 8) & 0xFF) / 255.0
        let a = Double(v & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
