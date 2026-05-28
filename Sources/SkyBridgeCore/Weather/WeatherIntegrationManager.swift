//
// WeatherIntegrationManager.swift
// SkyBridgeCore
//
// 天气集成管理器 - 协调位置、天气、主题
// Created: 2025-10-19
//

import Foundation
import SwiftUI
import OSLog
import Combine

/// 天气集成管理器 - 单例模式
@MainActor
public final class WeatherIntegrationManager: ObservableObject {
 // MARK: - Singleton
    
    public static let shared = WeatherIntegrationManager()
    
 // MARK: - Published Properties
    
    @Published public private(set) var isInitialized: Bool = false
    @Published public private(set) var currentWeather: WeatherInfo?
    @Published public private(set) var currentTheme: WeatherTheme
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var error: String?
    
 // MARK: - Managers
    
    public let locationManager = LocationManager()
    public let weatherService = SkyBridgeWeatherService()
    public let themeManager = WeatherThemeManager()
    
 // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "Integration")
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    
 // MARK: - Configuration
    
    private let autoRefreshInterval: TimeInterval = 1800 // 30分钟自动刷新
    
 /// 天气效果设置（引用全局单例）
    public let weatherSettings = WeatherEffectsSettings.shared
    
 // MARK: - Initialization
    
    private init() {
 // 🌈 初始化为默认晴天主题（将根据实时天气动态更新）
        self.currentTheme = WeatherThemeManager.theme(for: .clear)
        
        logger.info("🌈 天气集成管理器初始化完成")
        logger.info("   📊 天气效果状态: \(self.weatherSettings.isEnabled ? "✅ 开启" : "❌ 关闭")")
        
 // 延迟设置绑定，避免阻塞启动
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            await MainActor.run {
                self.setupBindings()
            }
        }
    }
    
 // MARK: - Public Methods
    
 /// 启动天气系统
    public func start() async {
        guard !isInitialized else { return }
        
        logger.info("🚀 启动天气系统")
        isLoading = true
        error = nil
        
 // Step 1: 获取位置
        await locationManager.startLocating()
        
 // Step 2: 获取天气
        if let location = locationManager.currentLocation {
            await weatherService.fetchWeather(for: location)
        } else {
            error = "无法获取位置信息"
            logger.error("❌ 位置获取失败")
        }
        
 // Step 3: 更新主题
        if let weather = weatherService.currentWeather {
            await MainActor.run {
                themeManager.updateTheme(for: weather)
                currentWeather = weather
            }
        }
        
        isInitialized = true
        isLoading = false
        
 // Step 4: 启动自动刷新
        startAutoRefresh()
        
        logger.info("✅ 天气系统启动完成")
    }
    
 /// 手动刷新
    public func refresh() async {
        logger.info("🔄 手动刷新天气")
        isLoading = true
        error = nil
        
        await locationManager.startLocating()
        
        if let location = locationManager.currentLocation {
            await weatherService.fetchWeather(for: location)
            
            if let weather = weatherService.currentWeather {
                themeManager.updateTheme(for: weather)
                currentWeather = weather
            }
        }
        
        isLoading = false
    }
    
 /// 停止天气系统
    public func stop() {
        stopAutoRefresh()
        locationManager.stop()
        isLoading = false
        isInitialized = false
        logger.info("⏹️ 天气系统已停止")
    }
    
 // MARK: - Private Methods
    
    private func setupBindings() {
 // 监听天气服务更新
        weatherService.$currentWeather
            .compactMap { $0 }
            .sink { [weak self] weather in
                self?.currentWeather = weather
                self?.themeManager.updateTheme(for: weather)
            }
            .store(in: &cancellables)
        
 // 监听主题更新
        themeManager.$currentTheme
            .sink { [weak self] theme in
                self?.currentTheme = theme
            }
            .store(in: &cancellables)
        
 // 监听错误
        locationManager.$error
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.error = error.localizedDescription
            }
            .store(in: &cancellables)
        
        weatherService.$error
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.error = error.localizedDescription
            }
            .store(in: &cancellables)
    }
    
    private func startAutoRefresh() {
        stopAutoRefresh()
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: autoRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        
        logger.info("⏰ 自动刷新已启动: \(self.autoRefreshInterval)秒")
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
