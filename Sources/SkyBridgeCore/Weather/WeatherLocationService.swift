import Foundation
import CoreLocation
import Combine
import os.log

/// 天气地理位置服务 - 获取用户当前位置用于天气数据查询
@MainActor
public final class WeatherLocationService: NSObject, ObservableObject {
    
 // MARK: - 发布的属性
    @Published public private(set) var currentLocation: CLLocation?
    @Published public private(set) var currentCity: String = ""
    @Published public private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public private(set) var isLocationEnabled: Bool = false
    @Published public private(set) var locationError: LocationError?
    
 // MARK: - 计算属性
 /// 位置是否已授权
    public var isLocationAuthorized: Bool {
        #if os(macOS)
        return authorizationStatus == .authorized
        #else
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
        #endif
    }
    
 // MARK: - 私有属性
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let log = Logger(subsystem: "com.skybridge.compass", category: "WeatherLocation")
    @MainActor private var locationUpdateTimer: Timer?
    private let locationUpdateInterval: TimeInterval = 300 // 5分钟更新一次位置
    
 // MARK: - 位置错误类型
    public enum LocationError: LocalizedError {
        case permissionDenied
        case locationUnavailable
        case geocodingFailed
        case networkError
        case timeout
        
        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "位置权限被拒绝"
            case .locationUnavailable:
                return "位置服务不可用"
            case .geocodingFailed:
                return "地理编码失败"
            case .networkError:
                return "网络连接错误"
            case .timeout:
                return "位置获取超时"
            }
        }
    }
    
 // MARK: - 初始化
    public override init() {
        super.init()
        setupLocationManager()
        log.info("天气地理位置服务已初始化")
    }
    
    deinit {
 // 直接在 deinit 中清理，不使用 避免捕获 self
 // 注意：这里可能会有并发警告，但在 deinit 中是安全的
    }
    
 // MARK: - 公共方法
    
 /// 请求位置权限
    public func requestLocationPermission() {
        guard CLLocationManager.locationServicesEnabled() else {
            locationError = .locationUnavailable
            log.error("位置服务未启用")
            return
        }
        
        switch authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            log.info("请求位置权限")
        case .denied, .restricted:
            locationError = .permissionDenied
            log.error("位置权限被拒绝或受限")
        #if os(macOS)
        case .authorized, .authorizedAlways:
            startLocationUpdates()
        #else
        case .authorizedAlways, .authorizedWhenInUse:
            startLocationUpdates()
        #endif
        @unknown default:
            log.warning("未知的位置权限状态")
        }
    }
    
 /// 开始位置更新
    public func startLocationUpdates() {
        #if os(macOS)
        guard authorizationStatus == .authorized || authorizationStatus == .authorizedAlways else {
            requestLocationPermission()
            return
        }
        #else
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            requestLocationPermission()
            return
        }
        #endif
        
        locationManager.startUpdatingLocation()
        isLocationEnabled = true
        
 // 设置定时更新
        locationUpdateTimer = Timer.scheduledTimer(withTimeInterval: locationUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.locationManager.requestLocation()
            }
        }
        
        log.info("开始位置更新")
    }
    
 /// 停止位置更新
    public func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
        locationUpdateTimer?.invalidate()
        locationUpdateTimer = nil
        isLocationEnabled = false
        log.info("停止位置更新")
    }
    
 /// 获取当前位置（一次性）
    public func getCurrentLocation() async throws -> CLLocation {
        return try await withCheckedThrowingContinuation { continuation in
            #if os(macOS)
            guard authorizationStatus == .authorized else {
                continuation.resume(throwing: LocationError.permissionDenied)
                return
            }
            #else
            guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
                continuation.resume(throwing: LocationError.permissionDenied)
                return
            }
            #endif
            
 // 设置超时
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10秒超时
                continuation.resume(throwing: LocationError.timeout)
            }
            
 // 临时存储continuation
            let tempContinuation = continuation
            
 // 请求位置
            locationManager.requestLocation()
            
 // 监听位置更新
            let cancellable = $currentLocation
                .compactMap { $0 }
                .first()
                .sink { location in
                    timeoutTask.cancel()
                    tempContinuation.resume(returning: location)
                }
            
 // 确保cancellable不被释放
            Task {
                _ = cancellable
            }
        }
    }
    
 /// 根据位置获取城市名称
    public func getCityName(for location: CLLocation) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
                if let error = error {
                    self?.log.error("地理编码失败: \(error.localizedDescription)")
                    continuation.resume(throwing: LocationError.geocodingFailed)
                    return
                }
                
                guard let placemark = placemarks?.first,
                      let city = placemark.locality ?? placemark.administrativeArea else {
                    self?.log.error("无法获取城市名称")
                    continuation.resume(throwing: LocationError.geocodingFailed)
                    return
                }
                
                continuation.resume(returning: city)
            }
        }
    }
    
 // MARK: - 私有方法
    
 /// 设置位置管理器
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer // 天气数据不需要高精度
        locationManager.distanceFilter = 1000 // 1公里变化才更新
        authorizationStatus = locationManager.authorizationStatus
    }
    
 /// 更新城市名称
    private func updateCityName(for location: CLLocation) {
        Task {
            do {
                let city = try await getCityName(for: location)
                await MainActor.run {
                    self.currentCity = city
                    self.log.info("城市名称已更新: \(city)")
                }
            } catch {
                await MainActor.run {
                    self.locationError = error as? LocationError ?? .geocodingFailed
                    self.log.error("更新城市名称失败: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate 扩展
extension WeatherLocationService: CLLocationManagerDelegate {
    
    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        Task { @MainActor in
            self.currentLocation = location
            self.locationError = nil
            self.updateCityName(for: location)
            self.log.info("位置已更新: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        }
    }
    
    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError {
            switch clError.code {
            case .denied:
                Task { @MainActor in
                    self.locationError = .permissionDenied
                }
            case .network:
                Task { @MainActor in
                    self.locationError = .networkError
                }
            case .locationUnknown:
                Task { @MainActor in
                    self.locationError = .locationUnavailable
                }
            default:
                Task { @MainActor in
                    self.locationError = .locationUnavailable
                }
            }
        }
        
        Task { @MainActor in
            self.log.error("位置更新失败: \(error.localizedDescription)")
        }
    }
    
    nonisolated public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            self.authorizationStatus = status
            
            switch status {
            #if os(macOS)
            case .authorized, .authorizedAlways:
                self.startLocationUpdates()
            #else
            case .authorizedAlways, .authorizedWhenInUse:
                self.startLocationUpdates()
            #endif
            case .denied, .restricted:
                self.locationError = .permissionDenied
                self.isLocationEnabled = false
            case .notDetermined:
                break
            @unknown default:
                self.log.warning("未知的位置权限状态")
            }
        }
    }
}