import Foundation
import Combine
import os.log

/// 天气效果设置管理器 - 与SettingsManager同步天气开关状态
/// 修复实时天气API无法控制天气效果的bug
@MainActor
public final class WeatherEffectsSettings: ObservableObject {
    
 // MARK: - Singleton
    public static let shared = WeatherEffectsSettings()
    
 // MARK: - Published Properties
    @Published public var isEnabled: Bool = false
    
 // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "Settings")
    private var cancellables = Set<AnyCancellable>()
    
 // MARK: - Initialization
    private init() {
        logger.info("🌟 WeatherEffectsSettings 初始化开始")
        
 // 🔥 修复bug：直接从SettingsManager同步状态
        setupSettingsManagerBinding()
        
        logger.info("✅ WeatherEffectsSettings 初始化完成")
    }
    
 /// 设置与SettingsManager的绑定关系
    private func setupSettingsManagerBinding() {
 // 初始同步状态
        self.isEnabled = SettingsManager.shared.enableRealTimeWeather
        
        logger.info("🔗 初始状态同步: enableRealTimeWeather=\(SettingsManager.shared.enableRealTimeWeather)")
        
 // 监听SettingsManager的enableRealTimeWeather变化
        SettingsManager.shared.$enableRealTimeWeather
            .sink { [weak self] newValue in
                guard let self = self else { return }
                
                self.logger.info("🎚️ SettingsManager.enableRealTimeWeather 变更: \(newValue)")
                
 // 同步到本地状态
                if self.isEnabled != newValue {
                    self.isEnabled = newValue
                    self.logger.info("✅ WeatherEffectsSettings.isEnabled 已同步: \(newValue)")
                }
            }
            .store(in: &self.cancellables)
    }
}

