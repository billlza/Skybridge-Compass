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
    
    // 系统监控设置
    public let enableCPUMonitoring: Bool
    public let enableMemoryMonitoring: Bool
    public let enableNetworkMonitoring: Bool
    public let enableDiskMonitoring: Bool
    public let monitoringInterval: TimeInterval
    
    // 元数据
    public let exportDate: Date
    public let appVersion: String
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
public class SettingsManager: ObservableObject {
    
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
    
    // MARK: - 私有属性
    private let userDefaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - 初始化
    private init() {
        loadSettings()
        setupObservers()
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
        
        // 系统监控设置
        systemMonitorRefreshInterval = 1.0
        enableSystemNotifications = true
        cpuThreshold = 80.0
        memoryThreshold = 80.0
        diskThreshold = 90.0
        enableAutoRefresh = true
        showTrendIndicators = true
        enableSoundAlerts = false
        maxHistoryPoints = 300.0
        
        print("🔄 所有设置已重置为默认值")
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
        
        print("📤 设置已导出到: \(fileURL.path)")
        
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
        
        let jsonData = try Data(contentsOf: url)
        
        // 尝试解析为新的结构化数据格式
        if let settingsData = try? JSONDecoder().decode(SettingsExportData.self, from: jsonData) {
            // 验证设置数据的有效性
            try validateImportedSettings(settingsData)
            
            // 应用导入的设置
            await applyImportedSettings(settingsData)
            
            print("📥 设置已从文件导入: \(url.lastPathComponent)")
            
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
        
        print("📥 设置已从文件导入: \(url.lastPathComponent)")
        
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
        if let value = settings["enableConnectionEncryption"] as? Bool { enableConnectionEncryption = value }
        if let value = settings["verifyCertificates"] as? Bool { verifyCertificates = value }
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
        // 注意：enableDebugMode和enablePerformanceMonitoring需要添加到SettingsManager
        
        // 系统监控设置
        systemMonitorRefreshInterval = settingsData.monitoringInterval
        // 注意：其他监控设置需要添加到SettingsManager
        
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
        
        // 重置连接设置
        connectionTimeout = 10
        retryCount = 3
        enableConnectionEncryption = true
        verifyCertificates = true
        
        // 清空自定义服务类型
        customServiceTypes = []
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
        DispatchQueue.main.async {
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
            
            DispatchQueue.main.async {
                self.showSystemNotifications = granted
            }
            
            return granted
        } catch {
            print("通知权限请求失败: \(error)")
            return false
        }
    }
    
    /// 发送系统通知
    public func sendSystemNotification(title: String, body: String, identifier: String = UUID().uuidString) {
        guard showSystemNotifications else { return }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = enableSoundAlerts ? .default : nil
        
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("发送通知失败: \(error)")
            }
        }
    }
    
    // MARK: - 私有辅助方法
    
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
        
        // 计算UserDefaults占用空间（估算）
        totalSize += Int64(userDefaults.dictionaryRepresentation().description.count)
        
        return totalSize
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
            print("清理目录失败: \(error)")
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
    }
    
    /// 设置观察者
    private func setupObservers() {
        // 通用设置观察者
        $autoScanOnStartup.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AutoScanOnStartup")
        }.store(in: &cancellables)
        
        $showSystemNotifications.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowSystemNotifications")
        }.store(in: &cancellables)
        
        $useDarkMode.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.UseDarkMode")
            self?.applyThemeMode() // 立即应用主题变化
        }.store(in: &cancellables)
        
        $scanInterval.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ScanInterval")
        }.store(in: &cancellables)
        
        $showDeviceDetails.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowDeviceDetails")
        }.store(in: &cancellables)
        
        $showConnectionStats.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowConnectionStats")
        }.store(in: &cancellables)
        
        $compactMode.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.CompactMode")
        }.store(in: &cancellables)
        
        // 网络设置观察者
        $autoConnectKnownNetworks.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AutoConnectKnownNetworks")
        }.store(in: &cancellables)
        
        $showHiddenNetworks.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowHiddenNetworks")
        }.store(in: &cancellables)
        
        $prefer5GHz.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.Prefer5GHz")
        }.store(in: &cancellables)
        
        $wifiScanTimeout.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.WiFiScanTimeout")
        }.store(in: &cancellables)
        
        $enableBonjourDiscovery.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableBonjourDiscovery")
        }.store(in: &cancellables)
        
        $enableMDNSResolution.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableMDNSResolution")
        }.store(in: &cancellables)
        
        $scanCustomPorts.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ScanCustomPorts")
        }.store(in: &cancellables)
        
        $discoveryTimeout.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.DiscoveryTimeout")
        }.store(in: &cancellables)
        
        $connectionTimeout.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ConnectionTimeout")
        }.store(in: &cancellables)
        
        $retryCount.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.RetryCount")
        }.store(in: &cancellables)
        
        $enableConnectionEncryption.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableConnectionEncryption")
        }.store(in: &cancellables)
        
        $verifyCertificates.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.VerifyCertificates")
        }.store(in: &cancellables)
        
        $customServiceTypes.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.CustomServiceTypes")
        }.store(in: &cancellables)
        
        // 设备设置观察者
        $autoConnectPairedDevices.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AutoConnectPairedDevices")
        }.store(in: &cancellables)
        
        $showDeviceRSSI.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowDeviceRSSI")
        }.store(in: &cancellables)
        
        $showConnectableDevicesOnly.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowOnlyConnectableDevices")
        }.store(in: &cancellables)
        
        $autoDiscoverAppleTV.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.AutoDiscoverAppleTV")
        }.store(in: &cancellables)
        
        $showHomePodDevices.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowHomePodDevices")
        }.store(in: &cancellables)
        
        $showThirdPartyAirPlayDevices.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowThirdPartyAirPlay")
        }.store(in: &cancellables)
        
        $hideOfflineDevices.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.HideOfflineDevices")
        }.store(in: &cancellables)
        
        $sortBySignalStrength.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.SortBySignalStrength")
        }.store(in: &cancellables)
        
        $showDeviceIcons.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowDeviceIcons")
        }.store(in: &cancellables)
        
        $minimumSignalStrength.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.MinimumSignalStrength")
        }.store(in: &cancellables)
        
        // 高级设置观察者
        $enableVerboseLogging.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableVerboseLogging")
        }.store(in: &cancellables)
        
        $showDebugInfo.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowDebugInfo")
        }.store(in: &cancellables)
        
        $saveNetworkLogs.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.SaveNetworkLogs")
        }.store(in: &cancellables)
        
        $logLevel.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.LogLevel")
        }.store(in: &cancellables)
        
        $enableHardwareAcceleration.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableHardwareAcceleration")
        }.store(in: &cancellables)
        
        $optimizeMemoryUsage.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.OptimizeMemoryUsage")
        }.store(in: &cancellables)
        
        $enableBackgroundScanning.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.BackgroundScanning")
        }.store(in: &cancellables)
        
        $maxConcurrentConnections.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.MaxConcurrentConnections")
        }.store(in: &cancellables)
        
        $enableIPv6Support.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableIPv6Support")
        }.store(in: &cancellables)
        
        $useNewDiscoveryAlgorithm.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.UseNewDiscoveryAlgorithm")
        }.store(in: &cancellables)
        
        $enableP2PDirectConnection.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableP2PDirectConnect")
        }.store(in: &cancellables)
        
        // 系统监控设置观察者
        $systemMonitorRefreshInterval.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.SystemMonitorRefreshInterval")
        }.store(in: &cancellables)
        
        $enableSystemNotifications.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableSystemNotifications")
        }.store(in: &cancellables)
        
        $cpuThreshold.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.CPUThreshold")
        }.store(in: &cancellables)
        
        $memoryThreshold.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.MemoryThreshold")
        }.store(in: &cancellables)
        
        $diskThreshold.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.DiskThreshold")
        }.store(in: &cancellables)
        
        $enableAutoRefresh.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableAutoRefresh")
        }.store(in: &cancellables)
        
        $showTrendIndicators.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.ShowTrendIndicators")
        }.store(in: &cancellables)
        
        $enableSoundAlerts.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.EnableSoundAlerts")
        }.store(in: &cancellables)
        
        $maxHistoryPoints.sink { [weak self] value in
            self?.userDefaults.set(value, forKey: "Settings.MaxHistoryPoints")
        }.store(in: &cancellables)
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