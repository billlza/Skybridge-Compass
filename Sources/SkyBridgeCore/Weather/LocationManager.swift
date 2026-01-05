//
// LocationManager.swift
// SkyBridgeCore
//
// 智能定位管理器 - 支持多级降级策略
// Created: 2025-10-19
//

import Foundation
import CoreLocation
import OSLog
import Combine

/// 位置信息
public struct LocationInfo: Sendable, Codable {
    public let latitude: Double
    public let longitude: Double
    public let city: String?
    public let country: String?
    public let source: LocationSource
    public let accuracy: CLLocationAccuracy?
    public let timestamp: Date
    
    public enum LocationSource: String, Codable, Sendable {
        case coreLocation = "CoreLocation"
        case ipGeolocation = "IP定位"
        case manualSelection = "手动选择"
        case cache = "缓存"
    }
    
    public init(latitude: Double, longitude: Double, city: String? = nil, country: String? = nil, source: LocationSource, accuracy: CLLocationAccuracy? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.country = country
        self.source = source
        self.accuracy = accuracy
        self.timestamp = Date()
    }
}

/// 定位管理器 - macOS 14+ 优化，支持智能降级
@MainActor
public final class LocationManager: NSObject, ObservableObject, Sendable {
 // MARK: - Published Properties
    
    @Published public private(set) var currentLocation: LocationInfo?
    @Published public private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public private(set) var isLocating: Bool = false
    @Published public private(set) var error: LocationError?
    
 // MARK: - Private Properties
    
    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "Location")
    private let geocoder = CLGeocoder()
    
 // 缓存配置
    private let cacheKey = "com.skybridge.lastKnownLocation"
    private let cacheValidityDuration: TimeInterval = 3600 // 1小时缓存有效期
    
    private var isCoreLocationAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorized
    }
    private let maxRetryCount = 1
    private var retriesRemaining = 0
    private var activeRequestID = UUID()
    private var periodicRefreshTask: Task<Void, Never>?
    
 // MARK: - Errors
    
    public enum LocationError: LocalizedError, Sendable {
        case unauthorized
        case unavailable
        case timeout
        case geocodingFailed
        case networkError(String)
        
        public var errorDescription: String? {
            switch self {
            case .unauthorized: return "位置访问未授权"
            case .unavailable: return "位置服务不可用"
            case .timeout: return "定位超时"
            case .geocodingFailed: return "地址解析失败"
            case .networkError(let msg): return "网络错误: \(msg)"
            }
        }
    }
    
 // MARK: - Initialization
    
    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer // 省电模式
        authorizationStatus = locationManager.authorizationStatus
        
        logger.info("🌍 定位管理器初始化完成")
        
 // 尝试加载缓存位置
        loadCachedLocation()
    }
    
 // MARK: - Lifecycle Management
    
 /// 启动定位管理器
    public func start() {
        logger.info("🚀 启动定位管理器")
 // 定位管理器在初始化时已经设置好，这里可以添加额外的启动逻辑
        startPeriodicCoreLocationRefresh()
    }
    
 /// 停止定位管理器
    public func stop() {
        logger.info("⏹️ 停止定位管理器")
        locationManager.stopUpdatingLocation()
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        isLocating = false
    }
    
 /// 清理定位管理器资源
    public func cleanup() {
        logger.info("🧹 清理定位管理器资源")
        stop()
        error = nil
 // 保留缓存的位置信息，不清除currentLocation
    }
    
 // MARK: - Public Methods
    
 /// 开始定位（智能降级）
    public func startLocating() async {
        guard !isLocating else { return }
        
        isLocating = true
        error = nil
        retriesRemaining = maxRetryCount
        logger.info("🔍 开始定位...")
        
 // 策略1: 尝试CoreLocation
        if await requestLocationAuthorization() {
            await requestLocationUpdate()
        } else {
 // 策略2: 降级到IP定位
            logger.warning("⚠️ CoreLocation不可用，降级到IP定位")
            await fallbackToIPGeolocation()
            isLocating = false
        }
    }
    
 /// 请求位置权限
    @discardableResult
    public func requestLocationAuthorization() async -> Bool {
        let status = locationManager.authorizationStatus
        
        switch status {
        case .notDetermined:
            logger.info("📝 请求位置权限")
            locationManager.requestWhenInUseAuthorization()
 // 等待权限响应
            try? await Task.sleep(for: .seconds(1))
            return locationManager.authorizationStatus == .authorizedAlways || locationManager.authorizationStatus == .authorized
            
        case .authorizedAlways, .authorized:
            return true
            
        case .denied, .restricted:
            error = .unauthorized
            return false
            
        @unknown default:
            return false
        }
    }
    
 /// 手动设置位置（用户选择城市）
    public func setManualLocation(latitude: Double, longitude: Double, city: String?, country: String?) {
        let location = LocationInfo(
            latitude: latitude,
            longitude: longitude,
            city: city,
            country: country,
            source: .manualSelection
        )
        currentLocation = location
        cacheLocation(location)
        logger.info("📍 手动设置位置: \(city ?? "未知")")
    }
    
 // MARK: - Private Methods
    
 /// 请求位置更新（单次）
    private func requestLocationUpdate() async {
        let requestID = UUID()
        activeRequestID = requestID
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            locationManager.requestLocation()
            
 // 超时保护
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard activeRequestID == requestID else { return }
                await handleLocationFailure(reason: .timeout)
                continuation.resume()
            }
        }
    }
    
 /// 降级方案：IP地理定位
    private func fallbackToIPGeolocation() async {
        logger.info("🌐 使用IP地理定位")
        
 // 使用免费的IP定位API (ipapi.co)
        guard let url = URL(string: "https://ipapi.co/json/") else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(IPLocationResponse.self, from: data)
            
            let location = LocationInfo(
                latitude: response.latitude,
                longitude: response.longitude,
                city: response.city,
                country: response.country_name,
                source: .ipGeolocation
            )
            
            currentLocation = location
            cacheLocation(location)
            logger.info("✅ IP定位成功: \(response.city), \(response.country_name)")
            
        } catch {
            logger.error("❌ IP定位失败: \(error.localizedDescription)")
            self.error = .networkError(error.localizedDescription)
            
 // 最终降级：使用缓存
            if let cached = loadCachedLocation() {
                logger.info("📦 使用缓存位置")
                currentLocation = cached
            }
        }
    }
    
 /// 反地理编码
    private func reverseGeocode(location: CLLocation) async -> (city: String?, country: String?) {
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return (nil, nil) }
 // 🔧 修复：中国地区 locality 可能为空，按优先级回退
            let city = placemark.locality 
                ?? placemark.subAdministrativeArea  // 区/县级市
                ?? placemark.administrativeArea     // 省/直辖市
                ?? placemark.subLocality            // 街道/镇
            return (city, placemark.country)
        } catch {
            logger.error("❌ 反地理编码失败: \(error.localizedDescription)")
            return (nil, nil)
        }
    }
    
 // MARK: - Cache Management
    
    private func cacheLocation(_ location: LocationInfo) {
        if let encoded = try? JSONEncoder().encode(location) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
        }
    }
    
    @discardableResult
    private func loadCachedLocation() -> LocationInfo? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let location = try? JSONDecoder().decode(LocationInfo.self, from: data) else {
            return nil
        }
        
 // 检查缓存是否过期
        if Date().timeIntervalSince(location.timestamp) < cacheValidityDuration {
            var cachedLocation = location
 // 标记为缓存来源
            if location.source != .cache {
                cachedLocation = LocationInfo(
                    latitude: location.latitude,
                    longitude: location.longitude,
                    city: location.city,
                    country: location.country,
                    source: .cache,
                    accuracy: location.accuracy
                )
            }
            currentLocation = cachedLocation
            logger.info("📦 加载缓存位置: \(location.city ?? "未知")")
            return cachedLocation
        }
        
        return nil
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        Task { @MainActor in
            logger.info("📍 位置更新: (\(location.coordinate.latitude), \(location.coordinate.longitude))")
            activeRequestID = UUID()
            
 // 反地理编码获取城市名
            let (city, country) = await reverseGeocode(location: location)
            
            let locationInfo = LocationInfo(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                city: city,
                country: country,
                source: .coreLocation,
                accuracy: location.horizontalAccuracy
            )
            
            currentLocation = locationInfo
            cacheLocation(locationInfo)
            error = nil
            retriesRemaining = maxRetryCount
            isLocating = false
        }
    }
    
    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            logger.error("❌ 定位失败: \(error.localizedDescription)")
            activeRequestID = UUID()
            
 // 根据错误类型设置
            if let clError = error as? CLError {
                switch clError.code {
                case .denied:
                    self.error = .unauthorized
                default:
                    self.error = .unavailable
                }
            }
            
            await handleLocationFailure(reason: self.error ?? .unavailable)
        }
    }
    
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            self.logger.info("🔐 定位权限状态: \(status.rawValue)")
        }
    }

// MARK: - Failure Handling & Periodic Refresh
    
    private func handleLocationFailure(reason: LocationError) async {
        error = reason
        
        if isCoreLocationAuthorized {
            if self.retriesRemaining > 0 {
                self.retriesRemaining -= 1
                logger.info("🔁 CoreLocation重试：剩余 \(self.retriesRemaining) 次")
                await requestLocationUpdate()
                return
            }
            await fallbackToIPGeolocation()
        } else {
            await fallbackToIPGeolocation()
        }
        
        isLocating = false
    }
    
    private func startPeriodicCoreLocationRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                await self?.refreshCoreLocationIfAuthorized()
            }
        }
    }
    
    private func refreshCoreLocationIfAuthorized() async {
        guard isCoreLocationAuthorized else { return }
        guard !isLocating else { return }
        isLocating = true
        retriesRemaining = maxRetryCount
        await requestLocationUpdate()
    }
}

// MARK: - IP Location Response Model

private struct IPLocationResponse: Codable {
    let latitude: Double
    let longitude: Double
    let city: String
    let country_name: String
}
