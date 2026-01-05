//
// RealTimeWeatherService.swift
// SkyBridgeCompassApp
//
// 实时天气服务 - 基于当前定位获取实时天气数据
// 使用 Swift 6.2 新特性和现代异步编程模式
//

import Foundation
import CoreLocation
import OSLog
import SkyBridgeCore
import Combine

/// 实时天气服务 - Swift 6.2 严格并发控制
@MainActor
public final class RealTimeWeatherService: NSObject, ObservableObject, Sendable {
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "RealTimeWeatherService")
    
 /// 位置管理器
    private let locationManager = CLLocationManager()
    
 /// 网络会话 - 使用 Swift 6.2 的 Sendable 安全配置
    private let urlSession: URLSession
    private var cancellables = Set<AnyCancellable>()
    
 /// API 密钥 - 从Keychain安全获取
    private var apiKey: String {
        do {
            return try KeychainManager.shared.retrieveWeatherAPIKey()
        } catch {
            logger.warning("无法从Keychain获取天气API密钥，使用环境变量: \(error.localizedDescription)")
            return ProcessInfo.processInfo.environment["WEATHER_API_KEY"] ?? ""
        }
    }
    
 // 引入去抖节流以避免频繁拉取
    private var lastFetchTimestamp: Date?
    private let fetchDebounceInterval: TimeInterval = 2.5
    
 /// 当前天气数据
    @Published public private(set) var currentWeather: WeatherData?
    
 /// 当前位置
    @Published public private(set) var currentLocation: CLLocation?
    
 /// 服务状态
    @Published public private(set) var serviceStatus: WeatherServiceStatus = .idle
    
 /// 错误信息
    @Published public private(set) var lastError: WeatherServiceError?
    
 /// 是否启用服务
    @Published public var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startWeatherService()
            } else {
                stopWeatherService()
            }
        }
    }
    
 /// 单例实例
    public static let shared = RealTimeWeatherService()
    
 /// 初始化实时天气服务
    public override init() {
 // 配置 URL 会话 - Swift 6.2 并发安全配置
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10.0
        configuration.timeoutIntervalForResource = 30.0
        configuration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: configuration)
        
        super.init()
        
 // 配置位置管理器
        setupLocationManager()
        
 // 同步初始启用状态并监听设置变化
        self.isEnabled = SettingsManager.shared.enableRealTimeWeather
        SettingsManager.shared.$enableRealTimeWeather
            .sink { [weak self] enabled in
                self?.isEnabled = enabled
            }
            .store(in: &cancellables)
        
        logger.info("实时天气服务初始化完成")
    }
    
 /// 配置位置管理器
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1000 // 1公里更新一次
    }
    
 /// 开始天气服务 - 使用 Swift 6.2 异步优化
    public func startWeatherService() {
        guard isEnabled else { return }
        
        serviceStatus = .requestingLocation
        
 // 使用 进行异步权限检查
        Task { @MainActor in
            await checkLocationPermissionAndStart()
        }
    }
    
 /// 检查位置权限并开始服务
    private func checkLocationPermissionAndStart() async {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            await handleLocationError(.locationPermissionDenied)
        #if os(macOS)
        case .authorized, .authorizedAlways:
            await startLocationUpdates()
        #else
        case .authorizedWhenInUse, .authorizedAlways:
            await startLocationUpdates()
        #endif
        @unknown default:
            await handleLocationError(.locationPermissionDenied)
        }
    }
    
 /// 停止天气服务
    public func stopWeatherService() {
        locationManager.stopUpdatingLocation()
        serviceStatus = .idle
        logger.info("天气服务已停止")
    }
    
 /// 开始位置更新 - Swift 6.2 异步优化
    private func startLocationUpdates() async {
        guard CLLocationManager.locationServicesEnabled() else {
            await handleLocationError(.locationServicesDisabled)
            return
        }
        
        locationManager.startUpdatingLocation()
        logger.info("开始位置更新")
    }
    
 /// 获取天气数据 - 使用 Swift 6.2 TaskGroup 并发优化
    private func fetchWeatherData(for location: CLLocation) async {
        serviceStatus = .fetchingWeather
        
        do {
 // 使用 TaskGroup 进行并发天气数据获取
            let weatherData = try await withThrowingTaskGroup(of: WeatherData.self) { group in
                group.addTask { [weak self] in
                    guard let self = self else { 
                        throw WeatherServiceError.invalidResponse 
                    }
                    return try await self.performWeatherRequest(location: location)
                }
                
 // 等待第一个成功的结果
                for try await result in group {
                    group.cancelAll()
                    return result
                }
                
                throw WeatherServiceError.invalidResponse
            }
            
            await MainActor.run {
                self.currentWeather = weatherData
                self.serviceStatus = .completed
                self.lastError = nil
                self.logger.info("天气数据获取成功: \(weatherData.description)")
            }
            
        } catch {
            await handleWeatherError(error)
        }
    }

 // 添加一个辅助方法用于判断是否可以执行拉取（去抖）
    private func canPerformFetch() -> Bool {
        if let last = lastFetchTimestamp {
            return Date().timeIntervalSince(last) >= fetchDebounceInterval
        }
        return true
    }
    
 /// 执行天气请求 - Swift 6.2 严格错误处理
    private func performWeatherRequest(location: CLLocation) async throws -> WeatherData {
        let urlString = "https://api.openweathermap.org/data/2.5/weather?lat=\(location.coordinate.latitude)&lon=\(location.coordinate.longitude)&appid=\(apiKey)&units=metric&lang=zh_cn"
        
        guard let url = URL(string: urlString) else {
            throw WeatherServiceError.invalidURL
        }
        
 // 使用 Swift 6.2 的 async/await 网络请求
        let (data, response) = try await urlSession.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WeatherServiceError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            throw WeatherServiceError.httpError(httpResponse.statusCode)
        }
        
        do {
            let weatherResponse = try JSONDecoder().decode(OpenWeatherMapResponse.self, from: data)
            return convertToWeatherData(from: weatherResponse, location: location)
        } catch {
            throw WeatherServiceError.decodingError(error)
        }
    }
    
 /// 转换天气数据
    private func convertToWeatherData(from response: OpenWeatherMapResponse, location: CLLocation) -> WeatherData {
        let weatherLocation = WeatherLocation(
            latitude: response.coord.lat,
            longitude: response.coord.lon,
            city: response.name,
            country: response.sys.country
        )
        
        return WeatherData(
            temperature: response.main.temp,
            humidity: Double(response.main.humidity) / 100.0,
            windSpeed: response.wind?.speed ?? 0.0,
            windDirection: response.wind?.deg ?? 0.0,
            pressure: response.main.pressure,
            visibility: Double(response.visibility ?? 10000) / 1000.0,
            condition: mapWeatherCondition(from: response.weather.first?.main ?? "Clear"),
            location: weatherLocation,
            timestamp: Date(),
            description: response.weather.first?.description ?? "未知天气"
        )
    }
    
 /// 映射天气条件
    private func mapWeatherCondition(from apiCondition: String) -> WeatherDataService.WeatherType {
        switch apiCondition.lowercased() {
        case "clear":
            return .clear
        case "clouds":
            return .cloudy
        case "rain", "drizzle":
            return .rain
        case "snow":
            return .snow
        case "thunderstorm":
            return .thunderstorm
        case "mist", "fog", "haze":
            return .fog
        default:
            return .clear
        }
    }
    
 /// 处理位置错误 - Swift 6.2 异步错误处理
    private func handleLocationError(_ error: WeatherServiceError) async {
        await MainActor.run {
            self.lastError = error
            self.serviceStatus = .error
            self.logger.error("位置错误: \(error.localizedDescription)")
        }
    }
    
 /// 处理天气错误 - Swift 6.2 异步错误处理
    private func handleWeatherError(_ error: Error) async {
        let weatherError: WeatherServiceError
        if let serviceError = error as? WeatherServiceError {
            weatherError = serviceError
        } else {
            weatherError = .networkError(error)
        }
        
        await MainActor.run {
            self.lastError = weatherError
            self.serviceStatus = .error
            self.logger.error("天气数据获取失败: \(weatherError.localizedDescription)")
        }
    }
    
 /// 刷新天气数据 - Swift 6.2 异步优化
    public func refreshWeatherData() {
        guard let location = currentLocation else {
            Task { @MainActor in
                await handleLocationError(.locationNotAvailable)
            }
            return
        }
        
 // 去抖：避免频繁刷新导致重复拉取
        guard canPerformFetch() else {
            logger.debug("忽略刷新：去抖中 \(self.fetchDebounceInterval) 秒")
            return
        }
        lastFetchTimestamp = Date()
        
        Task { @MainActor in
            await fetchWeatherData(for: location)
        }
    }
}

// MARK: - CLLocationManagerDelegate - Swift 6.2 并发安全
extension RealTimeWeatherService: CLLocationManagerDelegate {
    
    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
 // 使用 在 MainActor 上下文中安全更新属性
        Task { @MainActor in
            self.currentLocation = location
            self.logger.info("位置更新: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            
 // 去抖：避免位置快速变化导致的频繁拉取
            guard self.canPerformFetch() else {
                self.logger.debug("忽略位置驱动刷新：去抖中 \(self.fetchDebounceInterval) 秒")
                return
            }
            self.lastFetchTimestamp = Date()
            
 // 异步获取天气数据
            await self.fetchWeatherData(for: location)
            
 // 停止位置更新以节省电量
            self.locationManager.stopUpdatingLocation()
        }
    }
    
    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let locationError: WeatherServiceError
        if let clError = error as? CLError {
            switch clError.code {
            case .denied:
                locationError = .locationPermissionDenied
            case .locationUnknown:
                locationError = .locationNotAvailable
            default:
                locationError = .locationError(error)
            }
        } else {
            locationError = .locationError(error)
        }
        
        Task { @MainActor in
            await self.handleLocationError(locationError)
        }
    }
    
    nonisolated public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                await self.startLocationUpdates()
            case .denied, .restricted:
                await self.handleLocationError(.locationPermissionDenied)
            case .notDetermined:
                break // 等待用户响应
            @unknown default:
                await self.handleLocationError(.locationPermissionDenied)
            }
        }
    }
}

// MARK: - 天气服务状态 - Swift 6.2 Sendable 枚举
public enum WeatherServiceStatus: String, CaseIterable, Sendable {
    case idle = "idle"                          // 空闲
    case requestingLocation = "requesting_location"  // 请求位置
    case fetchingWeather = "fetching_weather"   // 获取天气
    case completed = "completed"                // 完成
    case error = "error"                        // 错误
    
    public var displayName: String {
        switch self {
        case .idle:
            return "空闲"
        case .requestingLocation:
            return "获取位置中..."
        case .fetchingWeather:
            return "获取天气中..."
        case .completed:
            return "完成"
        case .error:
            return "错误"
        }
    }
}

// MARK: - 服务状态 - Swift 6.2 Sendable 枚举
public enum ServiceStatus: Sendable {
    case inactive      // 未激活
    case initializing  // 初始化中
    case active        // 活跃状态
    case error(String) // 错误状态
    
 /// 状态描述
    public var description: String {
        switch self {
        case .inactive:
            return "未激活"
        case .initializing:
            return "初始化中..."
        case .active:
            return "运行中"
        case .error(let message):
            return "错误: \(message)"
        }
    }
}

// MARK: - 天气服务错误 - Swift 6.2 严格错误处理
public enum WeatherServiceError: Error, LocalizedError, Sendable {
    case locationPermissionDenied
    case locationServicesDisabled
    case locationNotAvailable
    case locationError(Error)
    case networkError(Error)
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .locationPermissionDenied:
            return "位置权限被拒绝"
        case .locationServicesDisabled:
            return "位置服务未启用"
        case .locationNotAvailable:
            return "位置信息不可用"
        case .locationError(let error):
            return "位置错误: \(error.localizedDescription)"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .invalidURL:
            return "无效的 URL"
        case .invalidResponse:
            return "无效的响应"
        case .httpError(let code):
            return "HTTP 错误: \(code)"
        case .decodingError(let error):
            return "数据解析错误: \(error.localizedDescription)"
        }
    }
}

// MARK: - 天气位置 - Swift 6.2 Sendable 结构体
public struct WeatherLocation: Codable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let city: String
    public let country: String
    
    public init(latitude: Double, longitude: Double, city: String, country: String) {
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.country = country
    }
}

// MARK: - 天气数据 - Swift 6.2 Sendable 结构体
public struct WeatherData: Codable, Sendable {
    public let temperature: Double      // 温度 (摄氏度)
    public let humidity: Double         // 湿度 (0-1)
    public let windSpeed: Double        // 风速 (m/s)
    public let windDirection: Double    // 风向 (度)
    public let pressure: Double         // 气压 (hPa)
    public let visibility: Double       // 能见度 (km)
    public let condition: WeatherDataService.WeatherType
    public let location: WeatherLocation
    public let timestamp: Date
    public let description: String      // 天气描述
    
    public init(
        temperature: Double,
        humidity: Double,
        windSpeed: Double,
        windDirection: Double,
        pressure: Double,
        visibility: Double,
        condition: WeatherDataService.WeatherType,
        location: WeatherLocation,
        timestamp: Date,
        description: String
    ) {
        self.temperature = temperature
        self.humidity = humidity
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.pressure = pressure
        self.visibility = visibility
        self.condition = condition
        self.location = location
        self.timestamp = timestamp
        self.description = description
    }
}

// MARK: - OpenWeatherMap API 响应结构 - Swift 6.2 Sendable
private struct OpenWeatherMapResponse: Codable, Sendable {
    let coord: Coordinate
    let weather: [Weather]
    let main: Main
    let visibility: Int?
    let wind: Wind?
    let sys: Sys
    let name: String
    
    struct Coordinate: Codable, Sendable {
        let lon: Double
        let lat: Double
    }
    
    struct Weather: Codable, Sendable {
        let main: String
        let description: String
    }
    
    struct Main: Codable, Sendable {
        let temp: Double
        let humidity: Int
        let pressure: Double
    }
    
    struct Wind: Codable, Sendable {
        let speed: Double
        let deg: Double?
    }
    
    struct Sys: Codable, Sendable {
        let country: String
    }
}