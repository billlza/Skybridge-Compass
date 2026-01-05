import Foundation
import SwiftUI

// MARK: - 远程桌面设置数据模型

/// 远程桌面设置配置
/// 符合 Swift 6.2 和 Apple Silicon 最佳实践
@MainActor
public final class RemoteDesktopSettings: ObservableObject, @unchecked Sendable {
    
 // MARK: - 显示设置
    @Published public var displaySettings = DisplaySettings()
    
 // MARK: - 交互设置
    @Published public var interactionSettings = InteractionSettings()
    
 // MARK: - 网络优化设置
    @Published public var networkSettings = NetworkSettings()
    
 // MARK: - 初始化
    public init() {}
}

// MARK: - 显示设置

/// 显示相关设置配置
public struct DisplaySettings: Codable, Sendable {
 /// 分辨率设置
    public var resolution: ResolutionSetting = .auto
    
 /// 色彩深度
    public var colorDepth: ColorDepth = .depth24
    
 /// 刷新率 (Hz)
    public var refreshRate: RefreshRate = .hz60
    
 /// 视频质量
    public var videoQuality: VideoQuality = .high
    
 /// 压缩级别 (0-100)
    public var compressionLevel: Double = 50.0
    
 /// 启用硬件加速
    public var enableHardwareAcceleration: Bool = true
    
 /// Apple Silicon 优化
    public var enableAppleSiliconOptimization: Bool = true
    
 /// 全屏模式
    public var fullScreenMode: Bool = false
    
 /// 多显示器支持
    public var multiMonitorSupport: Bool = false

 /// 视频编码器（HEVC / H.264）
    public var preferredCodec: PreferredVideoCodec = .hevc

 /// 关键帧间隔（GOP），单位：帧
    public var keyFrameInterval: Int = 60

 /// 目标帧率（FPS）
    public var targetFrameRate: Int = 60
 /// 编码档位（ProfileLevel）
    public var encodingProfile: EncodingProfile = .auto
 /// 低延迟模式（减少GOP、关闭B帧等）
    public var lowLatencyMode: Bool = false
    
    public init() {}
}

/// 视频编码器选项（设置层使用，避免与硬件编码器枚举重名）
public enum PreferredVideoCodec: String, CaseIterable, Codable, Sendable {
    case h264 = "h264"
    case hevc = "hevc"

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

/// 分辨率设置选项
public enum ResolutionSetting: String, CaseIterable, Codable, Sendable {
    case auto = "auto"
    case resolution1024x768 = "1024x768"
    case resolution1280x720 = "1280x720"
    case resolution1366x768 = "1366x768"
    case resolution1920x1080 = "1920x1080"
    case resolution2560x1440 = "2560x1440"
    case resolution3840x2160 = "3840x2160"
    case custom = "custom"
    
    public var displayName: String {
        switch self {
        case .auto: return "自动适应"
        case .resolution1024x768: return "1024 × 768"
        case .resolution1280x720: return "1280 × 720 (HD)"
        case .resolution1366x768: return "1366 × 768"
        case .resolution1920x1080: return "1920 × 1080 (Full HD)"
        case .resolution2560x1440: return "2560 × 1440 (2K)"
        case .resolution3840x2160: return "3840 × 2160 (4K)"
        case .custom: return "自定义"
        }
    }
    
    public var dimensions: (width: Int, height: Int)? {
        switch self {
        case .auto, .custom: return nil
        case .resolution1024x768: return (1024, 768)
        case .resolution1280x720: return (1280, 720)
        case .resolution1366x768: return (1366, 768)
        case .resolution1920x1080: return (1920, 1080)
        case .resolution2560x1440: return (2560, 1440)
        case .resolution3840x2160: return (3840, 2160)
        }
    }
}

/// 色彩深度选项
public enum ColorDepth: Int, CaseIterable, Codable, Sendable {
    case depth16 = 16
    case depth24 = 24
    case depth32 = 32
    
    public var displayName: String {
        switch self {
        case .depth16: return "16 位 (65K 色)"
        case .depth24: return "24 位 (1600万色)"
        case .depth32: return "32 位 (真彩色)"
        }
    }
}

/// 刷新率选项
public enum RefreshRate: Int, CaseIterable, Codable, Sendable {
    case hz30 = 30
    case hz60 = 60
    case hz75 = 75
    case hz120 = 120
    case hz144 = 144
    
    public var displayName: String {
        return "\(rawValue) Hz"
    }
}

/// 视频质量选项
public enum VideoQuality: String, CaseIterable, Codable, Sendable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case ultra = "ultra"
    
    public var displayName: String {
        switch self {
        case .low: return "低质量"
        case .medium: return "中等质量"
        case .high: return "高质量"
        case .ultra: return "超高质量"
        }
    }
}

// MARK: - 交互设置

/// 交互相关设置配置
public struct InteractionSettings: Codable, Sendable {
 /// 鼠标灵敏度 (0.1-5.0)
    public var mouseSensitivity: Double = 1.0
    
 /// 启用鼠标加速
    public var enableMouseAcceleration: Bool = true
    
 /// 键盘映射模式
    public var keyboardMapping: KeyboardMapping = .standard
    
 /// 启用剪贴板同步
    public var enableClipboardSync: Bool = true
    
 /// 启用音频重定向
    public var enableAudioRedirection: Bool = true
    
 /// 启用打印机重定向
    public var enablePrinterRedirection: Bool = false
    
 /// 启用文件传输
    public var enableFileTransfer: Bool = true
    
 /// 触控板手势支持
    public var enableTrackpadGestures: Bool = true
    
 /// 滚轮灵敏度 (0.1-5.0)
    public var scrollSensitivity: Double = 1.0
    
 /// 双击间隔 (毫秒)
    public var doubleClickInterval: Int = 500
    
 /// 启用右键菜单
    public var enableContextMenu: Bool = true
    
    public init() {}
}

/// 键盘映射模式
public enum KeyboardMapping: String, CaseIterable, Codable, Sendable {
    case standard = "standard"
    case mac = "mac"
    case windows = "windows"
    case custom = "custom"
    
    public var displayName: String {
        switch self {
        case .standard: return "标准映射"
        case .mac: return "Mac 键盘"
        case .windows: return "Windows 键盘"
        case .custom: return "自定义映射"
        }
    }
}

// MARK: - 网络优化设置

/// 网络优化相关设置配置
public struct NetworkSettings: Codable, Sendable {
 /// 连接类型
    public var connectionType: ConnectionType = .auto
    
 /// 带宽限制 (Mbps, 0 表示无限制)
    public var bandwidthLimit: Double = 0
    
 /// 网络压缩级别 (0-9)
    public var compressionLevel: Int = 6
    
 /// 启用网络加密
    public var enableEncryption: Bool = true
    
 /// 启用 UDP 传输
    public var enableUDPTransport: Bool = true
    
 /// 连接超时 (秒)
    public var connectionTimeout: Int = 30
    
 /// 心跳间隔 (秒)
    public var keepAliveInterval: Int = 60
    
 /// 启用自适应质量
    public var enableAdaptiveQuality: Bool = true
    
 /// 缓冲区大小 (KB)
    public var bufferSize: Int = 1024
    
 /// 启用网络统计
    public var enableNetworkStats: Bool = true
    
 /// 最大重连次数
    public var maxReconnectAttempts: Int = 3
 /// 重连退避起始毫秒
    public var reconnectBackoffInitialMs: Int = 500
 /// 重连退避最大毫秒
    public var reconnectBackoffMaxMs: Int = 10_000
 /// 重连退避乘数
    public var reconnectBackoffMultiplier: Double = 2.0

 /// 加密算法配置
    public var encryptionAlgorithm: EncryptionAlgorithm = .tls13
    
    public init() {}
}

/// 加密算法选项
public enum EncryptionAlgorithm: String, CaseIterable, Codable, Sendable {
    case none = "none"
    case tls12 = "tls12"
    case tls13 = "tls13"

    public var displayName: String {
        switch self {
        case .none: return "不加密"
        case .tls12: return "TLS 1.2"
        case .tls13: return "TLS 1.3"
        }
    }
}

/// 连接类型选项
public enum ConnectionType: String, CaseIterable, Codable, Sendable {
    case auto = "auto"
    case lan = "lan"
    case wan = "wan"
    case mobile = "mobile"
    case satellite = "satellite"
    
    public var displayName: String {
        switch self {
        case .auto: return "自动检测"
        case .lan: return "局域网 (LAN)"
        case .wan: return "广域网 (WAN)"
        case .mobile: return "移动网络"
        case .satellite: return "卫星网络"
        }
    }
}

// MARK: - 设置持久化管理器

/// 远程桌面设置持久化管理器
/// 使用 UserDefaults 进行本地存储，符合 Apple 最佳实践
@MainActor
public final class RemoteDesktopSettingsManager: ObservableObject, Sendable {
    public static let shared = RemoteDesktopSettingsManager()
    
    @Published public var settings = RemoteDesktopSettings()
    
    private let userDefaults = UserDefaults.standard
    private let settingsKey = "com.skybridge.compass.remote_desktop_settings"
    
 // MARK: - 生命周期管理属性
    private var isStarted = false
    
    private init() {
        loadSettings()
    }
    
 // MARK: - 生命周期管理方法
    
 /// 启动远程桌面设置管理器
 /// 初始化设置监听和自动保存功能
    public func start() {
        guard !isStarted else {
            SkyBridgeLogger.ui.debugOnly("⚠️ RemoteDesktopSettingsManager 已经启动")
            return
        }
        
        SkyBridgeLogger.ui.debugOnly("🚀 启动 RemoteDesktopSettingsManager")
        
 // 加载最新设置
        loadSettings()
        
 // 标记为已启动
        isStarted = true
        
        SkyBridgeLogger.ui.debugOnly("✅ RemoteDesktopSettingsManager 启动完成")
    }
    
 /// 停止远程桌面设置管理器
 /// 保存当前设置并停止监听
    public func stop() {
        guard isStarted else {
            SkyBridgeLogger.ui.debugOnly("⚠️ RemoteDesktopSettingsManager 尚未启动")
            return
        }
        
        SkyBridgeLogger.ui.debugOnly("🛑 停止 RemoteDesktopSettingsManager")
        
 // 保存当前设置
        saveSettings()
        
 // 标记为已停止
        isStarted = false
        
        SkyBridgeLogger.ui.debugOnly("✅ RemoteDesktopSettingsManager 停止完成")
    }
    
 /// 清理远程桌面设置管理器
 /// 重置所有设置并清理资源
    public func cleanup() {
        SkyBridgeLogger.ui.debugOnly("🧹 清理 RemoteDesktopSettingsManager")
        
 // 停止管理器
        if isStarted {
            stop()
        }
        
 // 重置设置为默认值
        settings = RemoteDesktopSettings()
        
        SkyBridgeLogger.ui.debugOnly("✅ RemoteDesktopSettingsManager 清理完成")
    }
    
 /// 加载设置
    public func loadSettings() {
 // 使用 UserDefaults 分别加载各个设置项
        loadDisplaySettings()
        loadInteractionSettings()
        loadNetworkSettings()
        SkyBridgeLogger.ui.debugOnly("设置已从 UserDefaults 加载")
    }
    
 /// 保存设置
    public func saveSettings() {
 // 使用 UserDefaults 分别保存各个设置项
        saveDisplaySettings()
        saveInteractionSettings()
        saveNetworkSettings()
        SkyBridgeLogger.ui.debugOnly("设置已保存到 UserDefaults")
    }
    
 /// 重置为默认设置
    public func resetToDefaults() {
        settings = RemoteDesktopSettings()
        saveSettings()
        SkyBridgeLogger.ui.debugOnly("设置已重置为默认值")
    }
    
 /// 导出设置
    public func exportSettings() -> Data? {
        let settingsDict: [String: Any] = [
            "displaySettings": displaySettingsToDict(),
            "interactionSettings": interactionSettingsToDict(),
            "networkSettings": networkSettingsToDict()
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: settingsDict, options: .prettyPrinted)
            SkyBridgeLogger.ui.debugOnly("设置已导出")
            return data
        } catch {
            SkyBridgeLogger.ui.error("导出设置失败: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
    
 /// 导入设置
    public func importSettings(from data: Data) -> Bool {
        do {
            guard let settingsDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                SkyBridgeLogger.ui.error("导入设置失败: 数据格式错误")
                return false
            }
            
            if let displayDict = settingsDict["displaySettings"] as? [String: Any] {
                loadDisplaySettingsFromDict(displayDict)
            }
            
            if let interactionDict = settingsDict["interactionSettings"] as? [String: Any] {
                loadInteractionSettingsFromDict(interactionDict)
            }
            
            if let networkDict = settingsDict["networkSettings"] as? [String: Any] {
                loadNetworkSettingsFromDict(networkDict)
            }
            
            saveSettings()
            SkyBridgeLogger.ui.debugOnly("设置已导入")
            return true
        } catch {
            SkyBridgeLogger.ui.error("导入设置失败: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
    
 // MARK: - 私有方法 - 显示设置
    
    private func saveDisplaySettings() {
        let prefix = "\(settingsKey).display."
        userDefaults.set(settings.displaySettings.resolution.rawValue, forKey: "\(prefix)resolution")
        userDefaults.set(settings.displaySettings.colorDepth.rawValue, forKey: "\(prefix)colorDepth")
        userDefaults.set(settings.displaySettings.refreshRate.rawValue, forKey: "\(prefix)refreshRate")
        userDefaults.set(settings.displaySettings.videoQuality.rawValue, forKey: "\(prefix)videoQuality")
        userDefaults.set(settings.displaySettings.compressionLevel, forKey: "\(prefix)compressionLevel")
        userDefaults.set(settings.displaySettings.enableHardwareAcceleration, forKey: "\(prefix)enableHardwareAcceleration")
        userDefaults.set(settings.displaySettings.enableAppleSiliconOptimization, forKey: "\(prefix)enableAppleSiliconOptimization")
        userDefaults.set(settings.displaySettings.fullScreenMode, forKey: "\(prefix)fullScreenMode")
        userDefaults.set(settings.displaySettings.multiMonitorSupport, forKey: "\(prefix)multiMonitorSupport")
        userDefaults.set(settings.displaySettings.preferredCodec.rawValue, forKey: "\(prefix)preferredCodec")
        userDefaults.set(settings.displaySettings.keyFrameInterval, forKey: "\(prefix)keyFrameInterval")
        userDefaults.set(settings.displaySettings.targetFrameRate, forKey: "\(prefix)targetFrameRate")
        userDefaults.set(settings.displaySettings.encodingProfile.rawValue, forKey: "\(prefix)encodingProfile")
        userDefaults.set(settings.displaySettings.lowLatencyMode, forKey: "\(prefix)lowLatencyMode")
    }
    
    private func loadDisplaySettings() {
        let prefix = "\(settingsKey).display."
        
        if let resolutionString = userDefaults.object(forKey: "\(prefix)resolution") as? String,
           let resolution = ResolutionSetting(rawValue: resolutionString) {
            settings.displaySettings.resolution = resolution
        }
        
        let colorDepthValue = userDefaults.integer(forKey: "\(prefix)colorDepth")
        if colorDepthValue != 0, let colorDepth = ColorDepth(rawValue: colorDepthValue) {
            settings.displaySettings.colorDepth = colorDepth
        }
        
        let refreshRateValue = userDefaults.integer(forKey: "\(prefix)refreshRate")
        if refreshRateValue != 0, let refreshRate = RefreshRate(rawValue: refreshRateValue) {
            settings.displaySettings.refreshRate = refreshRate
        }
        
        if let videoQualityString = userDefaults.object(forKey: "\(prefix)videoQuality") as? String,
           let videoQuality = VideoQuality(rawValue: videoQualityString) {
            settings.displaySettings.videoQuality = videoQuality
        }
        
        if userDefaults.object(forKey: "\(prefix)compressionLevel") != nil {
            settings.displaySettings.compressionLevel = userDefaults.double(forKey: "\(prefix)compressionLevel")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableHardwareAcceleration") != nil {
            settings.displaySettings.enableHardwareAcceleration = userDefaults.bool(forKey: "\(prefix)enableHardwareAcceleration")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableAppleSiliconOptimization") != nil {
            settings.displaySettings.enableAppleSiliconOptimization = userDefaults.bool(forKey: "\(prefix)enableAppleSiliconOptimization")
        }
        
        if userDefaults.object(forKey: "\(prefix)fullScreenMode") != nil {
            settings.displaySettings.fullScreenMode = userDefaults.bool(forKey: "\(prefix)fullScreenMode")
        }
        
        if userDefaults.object(forKey: "\(prefix)multiMonitorSupport") != nil {
            settings.displaySettings.multiMonitorSupport = userDefaults.bool(forKey: "\(prefix)multiMonitorSupport")
        }

        if let codecString = userDefaults.object(forKey: "\(prefix)preferredCodec") as? String,
           let codec = PreferredVideoCodec(rawValue: codecString) {
            settings.displaySettings.preferredCodec = codec
        }

        if userDefaults.object(forKey: "\(prefix)keyFrameInterval") != nil {
            settings.displaySettings.keyFrameInterval = userDefaults.integer(forKey: "\(prefix)keyFrameInterval")
        }

        if userDefaults.object(forKey: "\(prefix)targetFrameRate") != nil {
            settings.displaySettings.targetFrameRate = userDefaults.integer(forKey: "\(prefix)targetFrameRate")
        }
        
        if let profileString = userDefaults.object(forKey: "\(prefix)encodingProfile") as? String,
           let profile = EncodingProfile(rawValue: profileString) {
            settings.displaySettings.encodingProfile = profile
        }
        if userDefaults.object(forKey: "\(prefix)lowLatencyMode") != nil {
            settings.displaySettings.lowLatencyMode = userDefaults.bool(forKey: "\(prefix)lowLatencyMode")
        }
    }
    
    private func displaySettingsToDict() -> [String: Any] {
        return [
            "resolution": settings.displaySettings.resolution.rawValue,
            "colorDepth": settings.displaySettings.colorDepth.rawValue,
            "refreshRate": settings.displaySettings.refreshRate.rawValue,
            "videoQuality": settings.displaySettings.videoQuality.rawValue,
            "compressionLevel": settings.displaySettings.compressionLevel,
            "enableHardwareAcceleration": settings.displaySettings.enableHardwareAcceleration,
            "enableAppleSiliconOptimization": settings.displaySettings.enableAppleSiliconOptimization,
            "fullScreenMode": settings.displaySettings.fullScreenMode,
            "multiMonitorSupport": settings.displaySettings.multiMonitorSupport
        ]
    }
    
    private func loadDisplaySettingsFromDict(_ dict: [String: Any]) {
        if let resolutionString = dict["resolution"] as? String,
           let resolution = ResolutionSetting(rawValue: resolutionString) {
            settings.displaySettings.resolution = resolution
        }
        
        if let colorDepthValue = dict["colorDepth"] as? Int,
           let colorDepth = ColorDepth(rawValue: colorDepthValue) {
            settings.displaySettings.colorDepth = colorDepth
        }
        
        if let refreshRateValue = dict["refreshRate"] as? Int,
           let refreshRate = RefreshRate(rawValue: refreshRateValue) {
            settings.displaySettings.refreshRate = refreshRate
        }
        
        if let videoQualityString = dict["videoQuality"] as? String,
           let videoQuality = VideoQuality(rawValue: videoQualityString) {
            settings.displaySettings.videoQuality = videoQuality
        }
        
        if let compressionLevel = dict["compressionLevel"] as? Double {
            settings.displaySettings.compressionLevel = compressionLevel
        }
        
        if let enableHardwareAcceleration = dict["enableHardwareAcceleration"] as? Bool {
            settings.displaySettings.enableHardwareAcceleration = enableHardwareAcceleration
        }
        
        if let enableAppleSiliconOptimization = dict["enableAppleSiliconOptimization"] as? Bool {
            settings.displaySettings.enableAppleSiliconOptimization = enableAppleSiliconOptimization
        }
        
        if let fullScreenMode = dict["fullScreenMode"] as? Bool {
            settings.displaySettings.fullScreenMode = fullScreenMode
        }
        
        if let multiMonitorSupport = dict["multiMonitorSupport"] as? Bool {
            settings.displaySettings.multiMonitorSupport = multiMonitorSupport
        }
    }
    
 // MARK: - 私有方法 - 交互设置
    
    private func saveInteractionSettings() {
        let prefix = "\(settingsKey).interaction."
        userDefaults.set(settings.interactionSettings.mouseSensitivity, forKey: "\(prefix)mouseSensitivity")
        userDefaults.set(settings.interactionSettings.enableMouseAcceleration, forKey: "\(prefix)enableMouseAcceleration")
        userDefaults.set(settings.interactionSettings.keyboardMapping.rawValue, forKey: "\(prefix)keyboardMapping")
        userDefaults.set(settings.interactionSettings.enableClipboardSync, forKey: "\(prefix)enableClipboardSync")
        userDefaults.set(settings.interactionSettings.enableAudioRedirection, forKey: "\(prefix)enableAudioRedirection")
        userDefaults.set(settings.interactionSettings.enablePrinterRedirection, forKey: "\(prefix)enablePrinterRedirection")
        userDefaults.set(settings.interactionSettings.enableFileTransfer, forKey: "\(prefix)enableFileTransfer")
        userDefaults.set(settings.interactionSettings.enableTrackpadGestures, forKey: "\(prefix)enableTrackpadGestures")
        userDefaults.set(settings.interactionSettings.scrollSensitivity, forKey: "\(prefix)scrollSensitivity")
        userDefaults.set(settings.interactionSettings.doubleClickInterval, forKey: "\(prefix)doubleClickInterval")
        userDefaults.set(settings.interactionSettings.enableContextMenu, forKey: "\(prefix)enableContextMenu")
    }
    
    private func loadInteractionSettings() {
        let prefix = "\(settingsKey).interaction."
        
        if userDefaults.object(forKey: "\(prefix)mouseSensitivity") != nil {
            settings.interactionSettings.mouseSensitivity = userDefaults.double(forKey: "\(prefix)mouseSensitivity")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableMouseAcceleration") != nil {
            settings.interactionSettings.enableMouseAcceleration = userDefaults.bool(forKey: "\(prefix)enableMouseAcceleration")
        }
        
        if let keyboardMappingString = userDefaults.object(forKey: "\(prefix)keyboardMapping") as? String,
           let keyboardMapping = KeyboardMapping(rawValue: keyboardMappingString) {
            settings.interactionSettings.keyboardMapping = keyboardMapping
        }
        
        if userDefaults.object(forKey: "\(prefix)enableClipboardSync") != nil {
            settings.interactionSettings.enableClipboardSync = userDefaults.bool(forKey: "\(prefix)enableClipboardSync")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableAudioRedirection") != nil {
            settings.interactionSettings.enableAudioRedirection = userDefaults.bool(forKey: "\(prefix)enableAudioRedirection")
        }
        
        if userDefaults.object(forKey: "\(prefix)enablePrinterRedirection") != nil {
            settings.interactionSettings.enablePrinterRedirection = userDefaults.bool(forKey: "\(prefix)enablePrinterRedirection")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableFileTransfer") != nil {
            settings.interactionSettings.enableFileTransfer = userDefaults.bool(forKey: "\(prefix)enableFileTransfer")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableTrackpadGestures") != nil {
            settings.interactionSettings.enableTrackpadGestures = userDefaults.bool(forKey: "\(prefix)enableTrackpadGestures")
        }
        
        if userDefaults.object(forKey: "\(prefix)scrollSensitivity") != nil {
            settings.interactionSettings.scrollSensitivity = userDefaults.double(forKey: "\(prefix)scrollSensitivity")
        }
        
        if userDefaults.object(forKey: "\(prefix)doubleClickInterval") != nil {
            settings.interactionSettings.doubleClickInterval = userDefaults.integer(forKey: "\(prefix)doubleClickInterval")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableContextMenu") != nil {
            settings.interactionSettings.enableContextMenu = userDefaults.bool(forKey: "\(prefix)enableContextMenu")
        }
    }
    
    private func interactionSettingsToDict() -> [String: Any] {
        return [
            "mouseSensitivity": settings.interactionSettings.mouseSensitivity,
            "enableMouseAcceleration": settings.interactionSettings.enableMouseAcceleration,
            "keyboardMapping": settings.interactionSettings.keyboardMapping.rawValue,
            "enableClipboardSync": settings.interactionSettings.enableClipboardSync,
            "enableAudioRedirection": settings.interactionSettings.enableAudioRedirection,
            "enablePrinterRedirection": settings.interactionSettings.enablePrinterRedirection,
            "enableFileTransfer": settings.interactionSettings.enableFileTransfer,
            "enableTrackpadGestures": settings.interactionSettings.enableTrackpadGestures,
            "scrollSensitivity": settings.interactionSettings.scrollSensitivity,
            "doubleClickInterval": settings.interactionSettings.doubleClickInterval,
            "enableContextMenu": settings.interactionSettings.enableContextMenu
        ]
    }
    
    private func loadInteractionSettingsFromDict(_ dict: [String: Any]) {
        if let mouseSensitivity = dict["mouseSensitivity"] as? Double {
            settings.interactionSettings.mouseSensitivity = mouseSensitivity
        }
        
        if let enableMouseAcceleration = dict["enableMouseAcceleration"] as? Bool {
            settings.interactionSettings.enableMouseAcceleration = enableMouseAcceleration
        }
        
        if let keyboardMappingString = dict["keyboardMapping"] as? String,
           let keyboardMapping = KeyboardMapping(rawValue: keyboardMappingString) {
            settings.interactionSettings.keyboardMapping = keyboardMapping
        }
        
        if let enableClipboardSync = dict["enableClipboardSync"] as? Bool {
            settings.interactionSettings.enableClipboardSync = enableClipboardSync
        }
        
        if let enableAudioRedirection = dict["enableAudioRedirection"] as? Bool {
            settings.interactionSettings.enableAudioRedirection = enableAudioRedirection
        }
        
        if let enablePrinterRedirection = dict["enablePrinterRedirection"] as? Bool {
            settings.interactionSettings.enablePrinterRedirection = enablePrinterRedirection
        }
        
        if let enableFileTransfer = dict["enableFileTransfer"] as? Bool {
            settings.interactionSettings.enableFileTransfer = enableFileTransfer
        }
        
        if let enableTrackpadGestures = dict["enableTrackpadGestures"] as? Bool {
            settings.interactionSettings.enableTrackpadGestures = enableTrackpadGestures
        }
        
        if let scrollSensitivity = dict["scrollSensitivity"] as? Double {
            settings.interactionSettings.scrollSensitivity = scrollSensitivity
        }
        
        if let doubleClickInterval = dict["doubleClickInterval"] as? Int {
            settings.interactionSettings.doubleClickInterval = doubleClickInterval
        }
        
        if let enableContextMenu = dict["enableContextMenu"] as? Bool {
            settings.interactionSettings.enableContextMenu = enableContextMenu
        }
    }
    
 // MARK: - 私有方法 - 网络设置
    
    private func saveNetworkSettings() {
        let prefix = "\(settingsKey).network."
        userDefaults.set(settings.networkSettings.connectionType.rawValue, forKey: "\(prefix)connectionType")
        userDefaults.set(settings.networkSettings.bandwidthLimit, forKey: "\(prefix)bandwidthLimit")
        userDefaults.set(settings.networkSettings.compressionLevel, forKey: "\(prefix)compressionLevel")
        userDefaults.set(settings.networkSettings.enableEncryption, forKey: "\(prefix)enableEncryption")
        userDefaults.set(settings.networkSettings.enableUDPTransport, forKey: "\(prefix)enableUDPTransport")
        userDefaults.set(settings.networkSettings.connectionTimeout, forKey: "\(prefix)connectionTimeout")
        userDefaults.set(settings.networkSettings.keepAliveInterval, forKey: "\(prefix)keepAliveInterval")
        userDefaults.set(settings.networkSettings.enableAdaptiveQuality, forKey: "\(prefix)enableAdaptiveQuality")
        userDefaults.set(settings.networkSettings.bufferSize, forKey: "\(prefix)bufferSize")
        userDefaults.set(settings.networkSettings.enableNetworkStats, forKey: "\(prefix)enableNetworkStats")
        userDefaults.set(settings.networkSettings.maxReconnectAttempts, forKey: "\(prefix)maxReconnectAttempts")
        userDefaults.set(settings.networkSettings.reconnectBackoffInitialMs, forKey: "\(prefix)reconnectBackoffInitialMs")
        userDefaults.set(settings.networkSettings.reconnectBackoffMaxMs, forKey: "\(prefix)reconnectBackoffMaxMs")
        userDefaults.set(settings.networkSettings.reconnectBackoffMultiplier, forKey: "\(prefix)reconnectBackoffMultiplier")
    }
    
    private func loadNetworkSettings() {
        let prefix = "\(settingsKey).network."
        
        if let connectionTypeString = userDefaults.object(forKey: "\(prefix)connectionType") as? String,
           let connectionType = ConnectionType(rawValue: connectionTypeString) {
            settings.networkSettings.connectionType = connectionType
        }
        
        if userDefaults.object(forKey: "\(prefix)bandwidthLimit") != nil {
            settings.networkSettings.bandwidthLimit = userDefaults.double(forKey: "\(prefix)bandwidthLimit")
        }
        
        if userDefaults.object(forKey: "\(prefix)compressionLevel") != nil {
            settings.networkSettings.compressionLevel = userDefaults.integer(forKey: "\(prefix)compressionLevel")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableEncryption") != nil {
            settings.networkSettings.enableEncryption = userDefaults.bool(forKey: "\(prefix)enableEncryption")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableUDPTransport") != nil {
            settings.networkSettings.enableUDPTransport = userDefaults.bool(forKey: "\(prefix)enableUDPTransport")
        }
        
        if userDefaults.object(forKey: "\(prefix)connectionTimeout") != nil {
            settings.networkSettings.connectionTimeout = userDefaults.integer(forKey: "\(prefix)connectionTimeout")
        }
        
        if userDefaults.object(forKey: "\(prefix)keepAliveInterval") != nil {
            settings.networkSettings.keepAliveInterval = userDefaults.integer(forKey: "\(prefix)keepAliveInterval")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableAdaptiveQuality") != nil {
            settings.networkSettings.enableAdaptiveQuality = userDefaults.bool(forKey: "\(prefix)enableAdaptiveQuality")
        }
        
        if userDefaults.object(forKey: "\(prefix)bufferSize") != nil {
            settings.networkSettings.bufferSize = userDefaults.integer(forKey: "\(prefix)bufferSize")
        }
        
        if userDefaults.object(forKey: "\(prefix)enableNetworkStats") != nil {
            settings.networkSettings.enableNetworkStats = userDefaults.bool(forKey: "\(prefix)enableNetworkStats")
        }
        
        if userDefaults.object(forKey: "\(prefix)maxReconnectAttempts") != nil {
            settings.networkSettings.maxReconnectAttempts = userDefaults.integer(forKey: "\(prefix)maxReconnectAttempts")
        }
        if userDefaults.object(forKey: "\(prefix)reconnectBackoffInitialMs") != nil {
            settings.networkSettings.reconnectBackoffInitialMs = userDefaults.integer(forKey: "\(prefix)reconnectBackoffInitialMs")
        }
        if userDefaults.object(forKey: "\(prefix)reconnectBackoffMaxMs") != nil {
            settings.networkSettings.reconnectBackoffMaxMs = userDefaults.integer(forKey: "\(prefix)reconnectBackoffMaxMs")
        }
        if userDefaults.object(forKey: "\(prefix)reconnectBackoffMultiplier") != nil {
            settings.networkSettings.reconnectBackoffMultiplier = userDefaults.double(forKey: "\(prefix)reconnectBackoffMultiplier")
        }
    }
    
    private func networkSettingsToDict() -> [String: Any] {
        return [
            "connectionType": settings.networkSettings.connectionType.rawValue,
            "bandwidthLimit": settings.networkSettings.bandwidthLimit,
            "compressionLevel": settings.networkSettings.compressionLevel,
            "enableEncryption": settings.networkSettings.enableEncryption,
            "enableUDPTransport": settings.networkSettings.enableUDPTransport,
            "connectionTimeout": settings.networkSettings.connectionTimeout,
            "keepAliveInterval": settings.networkSettings.keepAliveInterval,
            "enableAdaptiveQuality": settings.networkSettings.enableAdaptiveQuality,
            "bufferSize": settings.networkSettings.bufferSize,
            "enableNetworkStats": settings.networkSettings.enableNetworkStats,
            "maxReconnectAttempts": settings.networkSettings.maxReconnectAttempts
        ]
    }
    
    private func loadNetworkSettingsFromDict(_ dict: [String: Any]) {
        if let connectionTypeString = dict["connectionType"] as? String,
           let connectionType = ConnectionType(rawValue: connectionTypeString) {
            settings.networkSettings.connectionType = connectionType
        }
        
        if let bandwidthLimit = dict["bandwidthLimit"] as? Double {
            settings.networkSettings.bandwidthLimit = bandwidthLimit
        }
        
        if let compressionLevel = dict["compressionLevel"] as? Int {
            settings.networkSettings.compressionLevel = compressionLevel
        }
        
        if let enableEncryption = dict["enableEncryption"] as? Bool {
            settings.networkSettings.enableEncryption = enableEncryption
        }
        
        if let enableUDPTransport = dict["enableUDPTransport"] as? Bool {
            settings.networkSettings.enableUDPTransport = enableUDPTransport
        }
        
        if let connectionTimeout = dict["connectionTimeout"] as? Int {
            settings.networkSettings.connectionTimeout = connectionTimeout
        }
        
        if let keepAliveInterval = dict["keepAliveInterval"] as? Int {
            settings.networkSettings.keepAliveInterval = keepAliveInterval
        }
        
        if let enableAdaptiveQuality = dict["enableAdaptiveQuality"] as? Bool {
            settings.networkSettings.enableAdaptiveQuality = enableAdaptiveQuality
        }
        
        if let bufferSize = dict["bufferSize"] as? Int {
            settings.networkSettings.bufferSize = bufferSize
        }
        
        if let enableNetworkStats = dict["enableNetworkStats"] as? Bool {
            settings.networkSettings.enableNetworkStats = enableNetworkStats
        }
        
        if let maxReconnectAttempts = dict["maxReconnectAttempts"] as? Int {
            settings.networkSettings.maxReconnectAttempts = maxReconnectAttempts
        }
    }
}
/// 编码档位（ProfileLevel）
public enum EncodingProfile: String, CaseIterable, Codable, Sendable {
    case auto
    case h264Baseline
    case h264Main
    case h264High
    case hevcMain
    
    public var displayName: String {
        switch self {
        case .auto: return "自动"
        case .h264Baseline: return "H.264 Baseline"
        case .h264Main: return "H.264 Main"
        case .h264High: return "H.264 High"
        case .hevcMain: return "HEVC Main"
        }
    }
}
