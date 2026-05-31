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

    public var locationManager: LocationManager {
        ensureRuntime().locationManager
    }

    public var weatherService: SkyBridgeWeatherService {
        ensureRuntime().weatherService
    }

    public var themeManager: WeatherThemeManager {
        ensureRuntime().themeManager
    }

    public var weatherSettings: WeatherEffectsSettings {
        ensureRuntime().weatherSettings
    }
    
 // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "Integration")
    private var runtime: WeatherRuntime?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var lifecycleState: LifecycleState = .stopped
    private var lifecycleGeneration: UInt64 = 0
    
 // MARK: - Configuration
    
    private let autoRefreshInterval: TimeInterval = 1800 // 30分钟自动刷新
    
 // MARK: - Initialization
    
    private init() {
 // 🌈 初始化为默认晴天主题（将根据实时天气动态更新）
        self.currentTheme = WeatherThemeManager.theme(for: .clear)
        
        logger.info("🌈 天气集成管理器轻量初始化完成，定位/网络服务等待显式启动")
    }
    
 // MARK: - Public Methods
    
    /// 启动天气系统
    public func start() async {
        switch lifecycleState {
        case .running, .starting:
            return
        case .stopped:
            break
        }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        lifecycleState = .starting
        let runtime = ensureRuntime()
        
        logger.info("🚀 启动天气系统")
        isLoading = true
        error = nil
        defer {
            if lifecycleGeneration == generation {
                isLoading = false
            }
        }
        
 // Step 1: 获取位置
        await runtime.locationManager.startLocating()
        guard isCurrentStart(generation) else { return }
        
 // Step 2: 获取天气
        if let location = runtime.locationManager.currentLocation {
            await runtime.weatherService.fetchWeather(for: location)
            guard isCurrentStart(generation) else { return }
        } else {
            error = "无法获取位置信息"
            lifecycleState = .stopped
            isInitialized = false
            logger.error("❌ 位置获取失败")
            return
        }
        
 // Step 3: 更新主题
        if let weather = runtime.weatherService.currentWeather {
            await MainActor.run {
                runtime.themeManager.updateTheme(for: weather)
                currentWeather = weather
            }
        } else {
            error = runtime.weatherService.error?.localizedDescription ?? "无法获取天气数据"
            lifecycleState = .stopped
            isInitialized = false
            logger.error("❌ 天气获取失败")
            return
        }
        
        guard isCurrentStart(generation) else { return }
        lifecycleState = .running
        isInitialized = true

 // Step 4: 启动自动刷新
        startAutoRefresh()

        logger.info("✅ 天气系统启动完成")
    }
    
    /// 手动刷新
    public func refresh() async {
        guard lifecycleState != .starting else { return }
        if lifecycleState == .stopped {
            await start()
            return
        }

        let generation = lifecycleGeneration
        let runtime = ensureRuntime()
        logger.info("🔄 手动刷新天气")
        isLoading = true
        error = nil
        defer {
            if isCurrentRuntime(generation) {
                isLoading = false
            }
        }
        
        await runtime.locationManager.startLocating()
        guard isCurrentRuntime(generation) else { return }
        
        if let location = runtime.locationManager.currentLocation {
            await runtime.weatherService.fetchWeather(for: location)
            guard isCurrentRuntime(generation) else { return }
            
            if let weather = runtime.weatherService.currentWeather {
                runtime.themeManager.updateTheme(for: weather)
                currentWeather = weather
            } else {
                error = runtime.weatherService.error?.localizedDescription ?? "无法获取天气数据"
            }
        } else {
            error = runtime.locationManager.error?.localizedDescription ?? "无法获取位置信息"
        }
    }
    
    /// 停止天气系统
    public func stop() {
        lifecycleGeneration &+= 1
        lifecycleState = .stopped
        stopAutoRefresh()
        runtime?.locationManager.stop()
        isLoading = false
        isInitialized = false
        logger.info("⏹️ 天气系统已停止")
    }
    
 // MARK: - Private Methods

    private func ensureRuntime() -> WeatherRuntime {
        if let runtime {
            return runtime
        }

        let runtime = WeatherRuntime()
        self.runtime = runtime
        setupBindings(runtime)
        logger.info("🌈 天气运行时已按需初始化")
        logger.info("   📊 天气效果状态: \(runtime.weatherSettings.isEnabled ? "✅ 开启" : "❌ 关闭")")
        return runtime
    }
    
    private func setupBindings(_ runtime: WeatherRuntime) {
        cancellables.removeAll()
 // 监听天气服务更新
        runtime.weatherService.$currentWeather
            .compactMap { $0 }
            .sink { [weak self] weather in
                self?.currentWeather = weather
                self?.runtime?.themeManager.updateTheme(for: weather)
            }
            .store(in: &cancellables)
        
 // 监听主题更新
        runtime.themeManager.$currentTheme
            .sink { [weak self] theme in
                self?.currentTheme = theme
            }
            .store(in: &cancellables)
        
 // 监听错误
        runtime.locationManager.$error
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.error = error.localizedDescription
            }
            .store(in: &cancellables)
        
        runtime.weatherService.$error
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

    private func isCurrentStart(_ generation: UInt64) -> Bool {
        guard lifecycleGeneration == generation else { return false }
        if case .starting = lifecycleState {
            return true
        }
        return false
    }

    private func isCurrentRuntime(_ generation: UInt64) -> Bool {
        lifecycleGeneration == generation && lifecycleState != .stopped
    }

    private enum LifecycleState: Equatable {
        case stopped
        case starting
        case running
    }
}

@MainActor
private final class WeatherRuntime {
    let locationManager = LocationManager()
    let weatherService = SkyBridgeWeatherService()
    let themeManager = WeatherThemeManager()
    let weatherSettings = WeatherEffectsSettings.shared
}
