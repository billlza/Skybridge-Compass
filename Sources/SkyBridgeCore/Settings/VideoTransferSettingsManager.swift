import Foundation
import SwiftUI
import Combine

// 导入视频传输相关的模型
// import SkyBridgeCore // 移除自导入

/// 视频传输设置管理器 - 管理视频分辨率、帧率等配置
/// 提供持久化存储和实时状态更新功能
@MainActor
public class VideoTransferSettingsManager: ObservableObject, Sendable {
    
 // MARK: - 单例实例
    public static let shared = VideoTransferSettingsManager()
    
 // MARK: - 发布的属性
    
 /// 当前选择的视频分辨率
    @Published public var selectedResolution: VideoResolution = .hd1080p {
        didSet {
            saveSettings()
            updateEstimatedDataRate()
        }
    }
    
 /// 当前选择的视频帧率
    @Published public var selectedFrameRate: VideoFrameRate = .fps30 {
        didSet {
            saveSettings()
            updateEstimatedDataRate()
        }
    }
    
 /// 是否启用硬件加速
    @Published public var enableHardwareAcceleration: Bool = true {
        didSet {
            saveSettings()
        }
    }
    
 /// 是否启用Apple Silicon优化
    @Published public var enableAppleSiliconOptimization: Bool = true {
        didSet {
            saveSettings()
        }
    }
    
 /// 视频压缩质量
    @Published public var compressionQuality: VideoCompressionQuality = .balanced {
        didSet {
            saveSettings()
            updateEstimatedDataRate()
        }
    }
    
 /// 是否启用自适应比特率
    @Published public var enableAdaptiveBitrate: Bool = true {
        didSet {
            saveSettings()
        }
    }
    
 /// 预估数据传输率（MB/s）
    @Published public var estimatedDataRate: Double = 0.0
    
 /// 当前配置状态描述
    @Published public var configurationStatus: String = ""
    
 /// 是否显示高级选项
    @Published public var showAdvancedOptions: Bool = false
    
 /// 当前配置是否为最优状态
    @Published public var isConfigurationOptimal: Bool = true
    
 // MARK: - 私有属性
    
    private let userDefaults = UserDefaults.standard
    private let settingsKey = "VideoTransferSettings"
    private var videoTransferCancellables = Set<AnyCancellable>()
    
 // MARK: - 初始化
    
    private init() {
        loadSettings()
        updateEstimatedDataRate()
        updateConfigurationStatus()
        
 // 监听配置变化，实时更新状态
        Publishers.CombineLatest4(
            $selectedResolution,
            $selectedFrameRate,
            $compressionQuality,
            $enableAppleSiliconOptimization
        )
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            self?.updateConfigurationStatus()
            self?.updateEstimatedDataRate()
        }
        .store(in: &videoTransferCancellables)
    }
    
 // MARK: - 生命周期管理方法
    
 /// 启动视频传输设置管理器
    public func start() async throws {
 // 视频传输设置管理器启动时的初始化逻辑
        updateEstimatedDataRate()
        updateConfigurationStatus()
    }
    
 /// 停止视频传输设置管理器
    public func stop() async {
 // 停止时保存当前设置
        saveSettings()
    }
    
 /// 清理资源
    public func cleanup() {
        videoTransferCancellables.removeAll()
    }
    
 // MARK: - 公共方法
    
 /// 获取当前视频传输配置
    public func getCurrentConfiguration() -> VideoTransferConfiguration {
        return VideoTransferConfiguration(
            resolution: selectedResolution,
            frameRate: selectedFrameRate,
            enableHardwareAcceleration: enableHardwareAcceleration,
            enableAppleSiliconOptimization: enableAppleSiliconOptimization,
            compressionQuality: compressionQuality,
            adaptiveBitrate: enableAdaptiveBitrate
        )
    }
    
 /// 应用预设配置
    public func applyPresetConfiguration(_ preset: VideoTransferPreset) {
        switch preset {
        case .balanced:
            selectedResolution = .hd1080p
            selectedFrameRate = .fps30
            compressionQuality = .balanced
            enableAdaptiveBitrate = true
            
        case .highPerformance:
            selectedResolution = .apple5k
            selectedFrameRate = .fps120
            compressionQuality = .fast
            enableAdaptiveBitrate = true
            
        case .highQuality:
            selectedResolution = .uhd4k
            selectedFrameRate = .fps60
            compressionQuality = .maximum
            enableAdaptiveBitrate = false
            
        case .lowLatency:
            selectedResolution = .hd1080p
            selectedFrameRate = .fps60
            compressionQuality = .fast
            enableAdaptiveBitrate = true
        }
        
        enableHardwareAcceleration = true
        enableAppleSiliconOptimization = true
    }
    
 /// 重置为默认设置
    public func resetToDefaults() {
        selectedResolution = .hd1080p
        selectedFrameRate = .fps30
        enableHardwareAcceleration = true
        enableAppleSiliconOptimization = true
        compressionQuality = .balanced
        enableAdaptiveBitrate = true
        showAdvancedOptions = false
    }
    
 /// 验证当前配置是否有效
    public func validateConfiguration() -> (isValid: Bool, warnings: [String]) {
        var warnings: [String] = []
        
 // 检查高分辨率和高帧率的组合
        if selectedResolution == .apple5k && selectedFrameRate == .fps120 {
            warnings.append("5K@120fps需要极高的系统性能，建议降低帧率或分辨率")
        }
        
        if selectedResolution == .uhd4k && selectedFrameRate == .fps120 {
            warnings.append("4K@120fps可能导致传输延迟，建议使用60fps")
        }
        
 // 检查硬件加速状态
        if !enableHardwareAcceleration && (selectedResolution == .uhd4k || selectedResolution == .apple5k) {
            warnings.append("高分辨率传输建议启用硬件加速以获得最佳性能")
        }
        
 // 检查Apple Silicon优化
        if !enableAppleSiliconOptimization {
            warnings.append("建议启用Apple Silicon优化以提升传输性能")
        }
        
        return (isValid: warnings.isEmpty, warnings: warnings)
    }
    
 // MARK: - 私有方法
    
 /// 保存设置到UserDefaults
    private func saveSettings() {
        let settings: [String: Any] = [
            "selectedResolution": selectedResolution.rawValue,
            "selectedFrameRate": selectedFrameRate.rawValue,
            "enableHardwareAcceleration": enableHardwareAcceleration,
            "enableAppleSiliconOptimization": enableAppleSiliconOptimization,
            "compressionQuality": compressionQuality.rawValue,
            "enableAdaptiveBitrate": enableAdaptiveBitrate,
            "showAdvancedOptions": showAdvancedOptions
        ]
        
        userDefaults.set(settings, forKey: settingsKey)
        SkyBridgeLogger.ui.debugOnly("✅ 视频传输设置已保存")
    }
    
 /// 从UserDefaults加载设置
    private func loadSettings() {
        guard let settings = userDefaults.dictionary(forKey: settingsKey) else {
            SkyBridgeLogger.ui.debugOnly("📱 使用默认视频传输设置")
            return
        }
        
        if let resolutionString = settings["selectedResolution"] as? String,
           let resolution = VideoResolution(rawValue: resolutionString) {
            selectedResolution = resolution
        }
        
        if let frameRateValue = settings["selectedFrameRate"] as? Int,
           let frameRate = VideoFrameRate(rawValue: frameRateValue) {
            selectedFrameRate = frameRate
        }
        
        if let hardwareAcceleration = settings["enableHardwareAcceleration"] as? Bool {
            enableHardwareAcceleration = hardwareAcceleration
        }
        
        if let appleSiliconOptimization = settings["enableAppleSiliconOptimization"] as? Bool {
            enableAppleSiliconOptimization = appleSiliconOptimization
        }
        
        if let qualityString = settings["compressionQuality"] as? String,
           let quality = VideoCompressionQuality(rawValue: qualityString) {
            compressionQuality = quality
        }
        
        if let adaptiveBitrate = settings["enableAdaptiveBitrate"] as? Bool {
            enableAdaptiveBitrate = adaptiveBitrate
        }
        
        if let advancedOptions = settings["showAdvancedOptions"] as? Bool {
            showAdvancedOptions = advancedOptions
        }
        
        SkyBridgeLogger.ui.debugOnly("✅ 视频传输设置已加载")
    }
    
 /// 更新预估数据传输率
    private func updateEstimatedDataRate() {
        let config = getCurrentConfiguration()
        let rateInBytesPerSecond = config.estimatedDataRate
        estimatedDataRate = Double(rateInBytesPerSecond) / (1024 * 1024) // 转换为MB/s
    }
    
 /// 更新配置状态描述
    private func updateConfigurationStatus() {
        let resolution = selectedResolution.displayName
        let frameRate = selectedFrameRate.displayName
        let quality = compressionQuality.displayName
        
        configurationStatus = "\(resolution) • \(frameRate) • \(quality)"
        
 // 添加优化状态指示
        var optimizations: [String] = []
        if enableHardwareAcceleration {
            optimizations.append("硬件加速")
        }
        if enableAppleSiliconOptimization {
            optimizations.append("Apple Silicon优化")
        }
        if enableAdaptiveBitrate {
            optimizations.append("自适应比特率")
        }
        
        if !optimizations.isEmpty {
            configurationStatus += " • " + optimizations.joined(separator: " • ")
        }
        
 // 更新配置优化状态
        updateOptimalStatus()
    }
    
 /// 更新配置是否为最优状态
    private func updateOptimalStatus() {
 // 检查配置是否为最优状态的逻辑
        var isOptimal = true
        
 // 检查传输率是否过高
        if estimatedDataRate > 10.0 {
            isOptimal = false
        }
        
 // 检查是否启用了推荐的优化选项
        if !enableHardwareAcceleration || !enableAppleSiliconOptimization {
            isOptimal = false
        }
        
 // 检查分辨率和帧率的组合是否合理
        if selectedResolution == .uhd4k && selectedFrameRate == .fps60 && compressionQuality == .none {
            isOptimal = false
        }
        
 // 检查是否启用了自适应比特率（推荐选项）
        if !enableAdaptiveBitrate {
            isOptimal = false
        }
        
        isConfigurationOptimal = isOptimal
    }
}

// MARK: - 视频传输预设

/// 视频传输预设配置
public enum VideoTransferPreset: String, CaseIterable {
    case balanced = "平衡"
    case highPerformance = "高性能"
    case highQuality = "高质量"
    case lowLatency = "低延迟"
    
 /// 预设描述
    public var description: String {
        switch self {
        case .balanced:
            return "平衡性能和质量，适合大多数场景"
        case .highPerformance:
            return "最大化传输性能，适合Apple Silicon设备"
        case .highQuality:
            return "最高画质，适合专业用途"
        case .lowLatency:
            return "最低延迟，适合实时交互"
        }
    }
    
 /// 预设图标
    public var iconName: String {
        switch self {
        case .balanced:
            return "scale.3d"
        case .highPerformance:
            return "bolt.fill"
        case .highQuality:
            return "sparkles"
        case .lowLatency:
            return "timer"
        }
    }
}

// MARK: - 扩展VideoCompressionQuality

extension VideoCompressionQuality {
 /// 压缩质量描述
    public var qualityDescription: String {
        switch self {
        case .none:
            return "原始质量，最大文件大小"
        case .fast:
            return "快速压缩，较大文件大小"
        case .balanced:
            return "平衡压缩，中等文件大小"
        case .maximum:
            return "最大压缩，最小文件大小"
        }
    }
}