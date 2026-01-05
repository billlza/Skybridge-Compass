//
// WeatherThemeManager.swift
// SkyBridgeCore
//
// 动态天气主题管理器
// Created: 2025-10-19
//

import Foundation
import SwiftUI
import OSLog
import Combine

/// 天气主题配置
public struct WeatherTheme: Sendable {
    public let condition: WeatherCondition
    public let primaryColor: Color
    public let secondaryColor: Color
    public let backgroundColor: Color
    public let foregroundColor: Color
    public let accentColor: Color
    public let effectIntensity: Double
    public let particleEffect: ParticleEffectType?
    
    public enum ParticleEffectType: Sendable {
        case rain
        case snow
        case fog(intensity: Double)
        case haze(intensity: Double)
    }
    
    public init(condition: WeatherCondition, primaryColor: Color, secondaryColor: Color, backgroundColor: Color, foregroundColor: Color, accentColor: Color, effectIntensity: Double, particleEffect: ParticleEffectType?) {
        self.condition = condition
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.accentColor = accentColor
        self.effectIntensity = effectIntensity
        self.particleEffect = particleEffect
    }
}

/// 天气主题管理器
@MainActor
public final class WeatherThemeManager: ObservableObject, Sendable {
 // MARK: - Published Properties
    
    @Published public private(set) var currentTheme: WeatherTheme
    @Published public private(set) var isTransitioning: Bool = false
    
 // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "Theme")
    private var weatherThemeCancellables = Set<AnyCancellable>()
    
 // MARK: - Initialization
    
    public init() {
 // 默认主题（晴朗）
        self.currentTheme = Self.theme(for: .clear)
        logger.info("🎨 天气主题管理器初始化")
    }
    
 // MARK: - 生命周期管理
    
 /// 启动天气主题管理器
    public func start() async {
        logger.info("启动天气主题管理器")
 // 天气主题管理器主要是响应式的，不需要主动启动任务
    }
    
 /// 停止天气主题管理器
    public func stop() {
        logger.info("停止天气主题管理器")
        cleanup()
    }
    
 /// 清理资源
    public func cleanup() {
        weatherThemeCancellables.removeAll()
        
 // 重置为默认主题
        currentTheme = Self.theme(for: .clear)
        isTransitioning = false
        
        logger.info("天气主题管理器资源已清理")
    }
    
 // MARK: - Public Methods
    
 /// 更新主题（基于天气）
    public func updateTheme(for weather: WeatherInfo) {
        let newTheme = Self.theme(for: weather.condition, aqi: weather.aqi)
        
        guard newTheme.condition != currentTheme.condition else { return }
        
        logger.info("🎨 切换天气主题: \(weather.condition.rawValue)")
        
 // 平滑过渡
        isTransitioning = true
        withAnimation(.easeInOut(duration: 1.5)) {
            currentTheme = newTheme
        }
        
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            isTransitioning = false
        }
    }
    
 // MARK: - Theme Definitions
    
 /// 根据天气状态生成主题
    public static func theme(for condition: WeatherCondition, aqi: Int? = nil) -> WeatherTheme {
        switch condition {
        case .clear:
            return WeatherTheme(
                condition: .clear,
                primaryColor: Color(red: 1.0, green: 0.8, blue: 0.0),
                secondaryColor: Color(red: 0.2, green: 0.6, blue: 1.0),
                backgroundColor: Color(red: 0.95, green: 0.97, blue: 1.0),
                foregroundColor: .primary,
                accentColor: Color.blue,
                effectIntensity: 0.0,
                particleEffect: nil
            )
            
        case .cloudy:
            return WeatherTheme(
                condition: .cloudy,
                primaryColor: Color(red: 0.7, green: 0.7, blue: 0.75),
                secondaryColor: Color(red: 0.5, green: 0.5, blue: 0.6),
                backgroundColor: Color(red: 0.9, green: 0.92, blue: 0.95),
                foregroundColor: .primary,
                accentColor: Color.gray,
                effectIntensity: 0.1,
                particleEffect: nil
            )
            
        case .rainy:
            return WeatherTheme(
                condition: .rainy,
                primaryColor: Color(red: 0.3, green: 0.4, blue: 0.6),
                secondaryColor: Color(red: 0.2, green: 0.3, blue: 0.5),
                backgroundColor: Color(red: 0.85, green: 0.88, blue: 0.92),
                foregroundColor: .primary,
                accentColor: Color(red: 0.4, green: 0.5, blue: 0.7),
                effectIntensity: 0.5,
                particleEffect: .rain
            )
            
        case .snowy:
            return WeatherTheme(
                condition: .snowy,
                primaryColor: Color(red: 0.9, green: 0.95, blue: 1.0),
                secondaryColor: Color(red: 0.7, green: 0.8, blue: 0.95),
                backgroundColor: Color(red: 0.95, green: 0.97, blue: 1.0),
                foregroundColor: .primary,
                accentColor: Color(red: 0.6, green: 0.7, blue: 0.9),
                effectIntensity: 0.4,
                particleEffect: .snow
            )
            
        case .foggy:
            return WeatherTheme(
                condition: .foggy,
                primaryColor: Color(red: 0.75, green: 0.8, blue: 0.85),
                secondaryColor: Color(red: 0.6, green: 0.65, blue: 0.7),
                backgroundColor: Color(red: 0.88, green: 0.90, blue: 0.93),
                foregroundColor: Color.secondary,
                accentColor: Color.gray,
                effectIntensity: 0.5,
                particleEffect: .fog(intensity: 0.5)
            )
            
        case .haze:
 // 根据AQI调整雾霾浓度
            let hazeIntensity = calculateHazeIntensity(aqi: aqi)
            return WeatherTheme(
                condition: .haze,
                primaryColor: Color(red: 0.8, green: 0.75, blue: 0.7),
                secondaryColor: Color(red: 0.65, green: 0.6, blue: 0.55),
                backgroundColor: Color(red: 0.9, green: 0.88, blue: 0.85),
                foregroundColor: Color.secondary,
                accentColor: Color(red: 0.7, green: 0.65, blue: 0.6),
                effectIntensity: hazeIntensity,
                particleEffect: .haze(intensity: hazeIntensity)
            )
            
        case .stormy:
            return WeatherTheme(
                condition: .stormy,
                primaryColor: Color(red: 0.2, green: 0.2, blue: 0.3),
                secondaryColor: Color(red: 0.3, green: 0.3, blue: 0.4),
                backgroundColor: Color(red: 0.75, green: 0.78, blue: 0.82),
                foregroundColor: .primary,
                accentColor: Color(red: 1.0, green: 0.8, blue: 0.0),
                effectIntensity: 0.7,
                particleEffect: .rain
            )
            
        case .unknown:
            return theme(for: .clear)
        }
    }
    
 /// 计算雾霾浓度（基于AQI）
    private static func calculateHazeIntensity(aqi: Int?) -> Double {
        guard let aqi = aqi else { return 0.6 } // 提高默认强度到0.6
        
        switch aqi {
        case 0..<50: return 0.2  // 即使AQI很低也显示一些雾霾效果
        case 50..<100: return 0.35
        case 100..<150: return 0.5
        case 150..<200: return 0.65
        case 200..<300: return 0.8
        default: return 1.0
        }
    }
}

