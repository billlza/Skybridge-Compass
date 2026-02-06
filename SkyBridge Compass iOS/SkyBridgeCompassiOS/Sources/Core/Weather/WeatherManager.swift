//
// WeatherManager.swift
// SkyBridgeCompassiOS
//
// 天气集成管理器 - iOS 优化版本
// 协调位置获取和天气更新，控制刷新频率以节省电量
//

import Foundation
import CoreLocation
import Combine

// MARK: - Weather Manager

/// iOS 天气集成管理器
@available(iOS 17.0, *)
@MainActor
public final class WeatherManager: NSObject, ObservableObject {
    
    // MARK: - Singleton
    
    public static let shared = WeatherManager()
    
    // MARK: - Published Properties
    
    @Published public private(set) var isInitialized: Bool = false
    @Published public private(set) var currentWeather: WeatherInfo?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var error: String?
    @Published public private(set) var currentLocation: LocationInfo?
    @Published public private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    
    // MARK: - Services
    
    private let weatherService = WeatherService.shared
    private let locationManager = CLLocationManager()
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var lastRefreshTime: Date?
    
    // MARK: - Configuration (iOS 优化)
    
    /// 自动刷新间隔：60分钟（比 macOS 的 30 分钟更长，节省电量）
    private let autoRefreshInterval: TimeInterval = 3600
    
    /// 最小刷新间隔：10分钟（防止频繁刷新）
    private let minimumRefreshInterval: TimeInterval = 600
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer // 精度降低，省电
        
        setupBindings()
    }
    
    // MARK: - Public Methods
    
    /// 启动天气系统
    public func start() async {
        guard !isInitialized else { return }
        
        SkyBridgeLogger.shared.info("🌤️ 启动天气系统")
        isLoading = true
        error = nil
        
        // 请求位置权限
        requestLocationPermission()
        
        // 如果已有位置，直接获取天气
        if let location = currentLocation {
            await weatherService.fetchWeather(for: location)
            currentWeather = weatherService.currentWeather
        }
        
        isInitialized = true
        isLoading = false
        
        // 启动自动刷新
        startAutoRefresh()
    }
    
    /// 手动刷新
    public func refresh() async {
        // 检查最小刷新间隔
        if let lastRefresh = lastRefreshTime,
           Date().timeIntervalSince(lastRefresh) < minimumRefreshInterval {
            SkyBridgeLogger.shared.info("⏳ 刷新间隔过短，跳过")
            return
        }
        
        SkyBridgeLogger.shared.info("🔄 刷新天气")
        isLoading = true
        error = nil
        
        // 更新位置
        locationManager.requestLocation()
        
        // 等待位置更新
        try? await Task.sleep(for: .seconds(2))
        
        // 获取天气
        if let location = currentLocation {
            await weatherService.fetchWeather(for: location)
            currentWeather = weatherService.currentWeather
        }
        
        lastRefreshTime = Date()
        isLoading = false
    }
    
    /// 停止天气系统
    public func stop() {
        stopAutoRefresh()
        SkyBridgeLogger.shared.info("⏹️ 天气系统已停止")
    }

    /// 按设置启用/停用天气系统（停用时同时清理当前状态，避免 UI 继续显示“旧天气”）
    public func setEnabled(_ enabled: Bool) async {
        if enabled {
            await start()
        } else {
            stop()
            currentWeather = nil
            error = nil
            isLoading = false
        }
    }
    
    /// 请求位置权限
    public func requestLocationPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        default:
            break
        }
    }
    
    // MARK: - Private Methods
    
    private func setupBindings() {
        // 监听天气服务更新
        weatherService.$currentWeather
            .receive(on: DispatchQueue.main)
            .sink { [weak self] weather in
                self?.currentWeather = weather
            }
            .store(in: &cancellables)
        
        weatherService.$error
            .receive(on: DispatchQueue.main)
            .compactMap { $0?.localizedDescription }
            .sink { [weak self] errorMsg in
                self?.error = errorMsg
            }
            .store(in: &cancellables)
        
        weatherService.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                self?.isLoading = loading
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
        
        SkyBridgeLogger.shared.info("⏰ 天气自动刷新已启动: \(Int(autoRefreshInterval/60))分钟")
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - CLLocationManagerDelegate

@available(iOS 17.0, *)
extension WeatherManager: CLLocationManagerDelegate {
    
    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        Task { @MainActor in
            // 使用反向地理编码获取城市名
            let geocoder = CLGeocoder()
            
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                let cityName = placemarks.first?.locality ?? placemarks.first?.administrativeArea
                
                self.currentLocation = LocationInfo(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    city: cityName
                )
                
                SkyBridgeLogger.shared.info("📍 位置更新: \(cityName ?? "未知")")
                
                // 如果天气数据为空，立即获取
                if self.currentWeather == nil, let loc = self.currentLocation {
                    await self.weatherService.fetchWeather(for: loc)
                    self.currentWeather = self.weatherService.currentWeather
                }
                
            } catch {
                // 即使地理编码失败，也保存坐标
                self.currentLocation = LocationInfo(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    city: nil
                )

                // 地理编码失败也要继续拉天气（否则 UI 会一直停在“正在获取”）
                if self.currentWeather == nil, let loc = self.currentLocation {
                    await self.weatherService.fetchWeather(for: loc)
                    self.currentWeather = self.weatherService.currentWeather
                }
            }
        }
    }
    
    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            SkyBridgeLogger.shared.error("❌ 位置获取失败: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }
    
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationAuthorizationStatus = status
            
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.locationManager.requestLocation()
            case .denied, .restricted:
                self.error = "位置权限被拒绝"
            default:
                break
            }
        }
    }
}
