//
// WeatherService.swift
// SkyBridgeCompassiOS
//
// 轻量级天气服务 - iOS 优化版本
// 复用 macOS 相同的 API，但优化了性能开销
//

import Foundation
import CoreLocation

// MARK: - Weather Info

/// 天气信息
public struct WeatherInfo: Sendable, Codable {
    public let temperature: Double
    public let condition: WeatherCondition
    public let humidity: Double
    public let windSpeed: Double
    public let visibility: Double?
    public let aqi: Int?
    public let description: String
    public let location: String
    public let timestamp: Date
    public let source: String
    
    public init(
        temperature: Double,
        condition: WeatherCondition,
        humidity: Double,
        windSpeed: Double,
        visibility: Double? = nil,
        aqi: Int? = nil,
        description: String,
        location: String,
        source: String
    ) {
        self.temperature = temperature
        self.condition = condition
        self.humidity = humidity
        self.windSpeed = windSpeed
        self.visibility = visibility
        self.aqi = aqi
        self.description = description
        self.location = location
        self.timestamp = Date()
        self.source = source
    }
}

// MARK: - Weather Condition

/// 天气状态
public enum WeatherCondition: String, Codable, Sendable {
    case clear = "晴朗"
    case cloudy = "多云"
    case rainy = "雨天"
    case snowy = "雪天"
    case foggy = "雾天"
    case haze = "雾霾"
    case stormy = "暴风雨"
    case unknown = "未知"
    
    public var iconName: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .cloudy: return "cloud.fill"
        case .rainy: return "cloud.rain.fill"
        case .snowy: return "cloud.snow.fill"
        case .foggy: return "cloud.fog.fill"
        case .haze: return "aqi.medium"
        case .stormy: return "cloud.bolt.rain.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    public var localizationKey: String {
        switch self {
        case .clear: return "weather.condition.clear"
        case .cloudy: return "weather.condition.cloudy"
        case .rainy: return "weather.condition.rainy"
        case .snowy: return "weather.condition.snowy"
        case .foggy: return "weather.condition.foggy"
        case .haze: return "weather.condition.haze"
        case .stormy: return "weather.condition.stormy"
        case .unknown: return "weather.condition.unknown"
        }
    }
    
    /// 渐变色（用于背景）
    public var gradientColors: [String] {
        switch self {
        case .clear: return ["#FF9500", "#FFCC00"]      // 橙黄
        case .cloudy: return ["#8E8E93", "#C7C7CC"]     // 灰色
        case .rainy: return ["#007AFF", "#5AC8FA"]      // 蓝色
        case .snowy: return ["#5AC8FA", "#FFFFFF"]      // 浅蓝白
        case .foggy: return ["#8E8E93", "#AEAEB2"]      // 浅灰
        case .haze: return ["#FF9500", "#8E8E93"]       // 橙灰
        case .stormy: return ["#5856D6", "#007AFF"]     // 紫蓝
        case .unknown: return ["#8E8E93", "#636366"]    // 深灰
        }
    }
}

// MARK: - Weather Error

/// 天气服务错误
public enum WeatherError: Error, LocalizedError, Sendable {
    case noLocation
    case apiError(String)
    case networkError
    case invalidResponse
    
    public var errorDescription: String? {
        switch self {
        case .noLocation: return "无法获取位置信息"
        case .apiError(let msg): return "API错误: \(msg)"
        case .networkError: return "网络连接失败"
        case .invalidResponse: return "无效的天气数据"
        }
    }
}

private enum WeatherProvider: String, Sendable {
    case wttr = "wttr.in"
    case openMeteo = "open-meteo"
    case metNo = "met.no"
}

// MARK: - Location Info

/// 位置信息
public struct LocationInfo: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let city: String?
    
    public init(latitude: Double, longitude: Double, city: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
    }
}

// MARK: - Weather Service

/// iOS 轻量级天气服务
@available(iOS 17.0, *)
@MainActor
public final class WeatherService: ObservableObject {
    private static let weatherCacheStore = CodablePersistenceStore<WeatherInfo>(
        location: .protectedApplicationSupport(
            path: "Weather/ios-last-known-weather.json",
            legacyUserDefaultsKey: "com.skybridge.ios.weather"
        )
    )
    
    // MARK: - Singleton
    
    public static let shared = WeatherService()
    
    // MARK: - Published Properties
    
    @Published public private(set) var currentWeather: WeatherInfo?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var error: WeatherError?
    
    // MARK: - Private Properties
    
    private let cacheValidityDuration: TimeInterval = 3600 // 1小时缓存（比 macOS 更长）
    private let requestTimeout: TimeInterval = 5.0 // 单源快速超时，配合多源并行兜底
    private let requestUserAgent = "SkyBridgeCompass/1.0 (iOS Weather; support@skybridge.local)"
    
    // MARK: - Initialization
    
    private init() {
        // 尝试加载缓存
        if let cached = loadCachedWeather() {
            currentWeather = cached
        }
    }
    
    // MARK: - Public Methods
    
    /// 获取天气数据
    public func fetchWeather(for location: LocationInfo) async {
        guard !isLoading else { return }
        
        isLoading = true
        error = nil
        
        var weatherInfo = await fetchWeatherFromProviders(location: location)

        // 策略2: 使用新鲜缓存
        if weatherInfo == nil, let cached = loadCachedWeather() {
            weatherInfo = cached
            SkyBridgeLogger.shared.info("📦 使用缓存天气数据")
        }

        // 策略3: 使用过期缓存（最终兜底，避免 UI 长期空白）
        if weatherInfo == nil, let stale = loadCachedWeather(allowStale: true) {
            weatherInfo = stale
            SkyBridgeLogger.shared.warning("📦 使用过期缓存天气数据（网络不可用）")
        }
        
        if let weather = weatherInfo {
            currentWeather = weather
            cacheWeather(weather)
        } else {
            error = .networkError
        }
        
        isLoading = false
    }
    
    /// 刷新天气
    public func refresh(location: LocationInfo) async {
        await fetchWeather(for: location)
    }

    private func fetchWeatherFromProviders(location: LocationInfo) async -> WeatherInfo? {
        if let weather = await fetchFromOpenMeteo(location: location) {
            return weather
        }
        if let weather = await fetchFromMetNo(location: location) {
            return weather
        }
        return nil
    }
    
    // MARK: - Private API Methods
    
    /// wttr.in API
    private func fetchFromWttr(location: LocationInfo) async -> WeatherInfo? {
        let urlString = "https://wttr.in/\(location.latitude),\(location.longitude)?format=j1"
        
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let data = try await fetchData(url, provider: .wttr)
            
            let response = try JSONDecoder().decode(WttrResponse.self, from: data)
            
            guard let current = response.current_condition.first else { return nil }
            
            let condition = parseWeatherCondition(
                code: Int(current.weatherCode) ?? 0,
                description: current.weatherDesc.first?.value
            )
            
            let aqi = calculateAQI(pm25: Double(current.pm2_5 ?? "0") ?? 0)
            let locationName = location.city ?? response.nearest_area?.first?.areaName?.first?.value ?? formatCoordinates(location.latitude, location.longitude)
            
            return WeatherInfo(
                temperature: Double(current.temp_C) ?? 0,
                condition: condition,
                humidity: Double(current.humidity) ?? 0,
                windSpeed: Double(current.windspeedKmph) ?? 0,
                visibility: Double(current.visibility),
                aqi: aqi,
                description: localizedConditionDescription(for: condition),
                location: locationName,
                source: "wttr.in"
            )
            
        } catch {
            SkyBridgeLogger.shared.warning("🌧️ wttr.in 请求失败: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Open-Meteo API
    private func fetchFromOpenMeteo(location: LocationInfo) async -> WeatherInfo? {
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(location.latitude)&longitude=\(location.longitude)&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,visibility&timezone=auto"
        
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let data = try await fetchData(url, provider: .openMeteo)
            
            let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let condition = parseWeatherCondition(code: response.current.weather_code, description: nil)
            let visibilityKm = response.current.visibility.map { $0 / 1000 }
            let locationName = location.city ?? formatCoordinates(location.latitude, location.longitude)
            
            return WeatherInfo(
                temperature: response.current.temperature_2m,
                condition: condition,
                humidity: response.current.relative_humidity_2m,
                windSpeed: response.current.wind_speed_10m,
                visibility: visibilityKm,
                aqi: nil,
                description: localizedConditionDescription(for: condition),
                location: locationName,
                source: "Open-Meteo"
            )
            
        } catch {
            SkyBridgeLogger.shared.warning("🌧️ Open-Meteo 请求失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// met.no API (海外网络稳定兜底)
    private func fetchFromMetNo(location: LocationInfo) async -> WeatherInfo? {
        let urlString = "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=\(location.latitude)&lon=\(location.longitude)"

        guard let url = URL(string: urlString) else { return nil }

        do {
            let data = try await fetchData(url, provider: .metNo)
            let response = try JSONDecoder().decode(MetNoResponse.self, from: data)

            guard let first = response.properties.timeseries.first else { return nil }
            let details = first.data.instant.details

            let description = first.data.next_1_hours?.summary.symbol_code ?? first.data.next_6_hours?.summary.symbol_code
            let normalizedDescription = description?.replacingOccurrences(of: "_", with: " ")
            let condition = parseWeatherCondition(code: 0, description: normalizedDescription)
            let locationName = location.city ?? formatCoordinates(location.latitude, location.longitude)

            return WeatherInfo(
                temperature: details.air_temperature,
                condition: condition,
                humidity: details.relative_humidity,
                windSpeed: details.wind_speed,
                visibility: details.visibility.map { $0 / 1000 },
                aqi: nil,
                description: localizedConditionDescription(for: condition),
                location: locationName,
                source: "met.no"
            )
        } catch {
            SkyBridgeLogger.shared.warning("🌧️ met.no 请求失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Networking (Proxy/TLS Harden)

    private func fetchData(_ url: URL, provider: WeatherProvider) async throws -> Data {
        do {
            return try await fetchData(url, provider: provider, proxyBypass: false)
        } catch {
            // 有些系统会配置本地代理（例如 127.0.0.1:1082），导致 TLS 握手失败（-1200 / -9816）。
            // 检测到代理/TLS特征时，自动尝试一次“禁用代理”请求。
            guard shouldRetryBypassingProxy(error) else { throw error }
            SkyBridgeLogger.shared.info("🌦️ \(provider.rawValue) 疑似被代理影响，尝试绕过代理重试…")
            return try await fetchData(url, provider: provider, proxyBypass: true)
        }
    }

    private func fetchData(_ url: URL, provider: WeatherProvider, proxyBypass: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(LocalizationManager.instance.currentLanguage.acceptLanguageTag, forHTTPHeaderField: "Accept-Language")
        request.setValue(requestUserAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = requestTimeout
            config.timeoutIntervalForResource = requestTimeout
            config.waitsForConnectivity = true
            config.allowsConstrainedNetworkAccess = true
            config.allowsExpensiveNetworkAccess = true

            if proxyBypass {
                // 显式清空 proxy 配置（绕过系统 HTTP/HTTPS 代理）
                config.connectionProxyDictionary = [
                    "HTTPEnable": false,
                    "HTTPSEnable": false,
                    "SOCKSEnable": false
                ]
            }

            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else { return data }
            guard (200...299).contains(http.statusCode) else {
                let bodyPreview: String
                if let body = String(data: data, encoding: .utf8) {
                    bodyPreview = String(body.replacingOccurrences(of: "\n", with: " ").prefix(180))
                } else {
                    bodyPreview = ""
                }
                SkyBridgeLogger.shared.warning("🌧️ \(provider.rawValue) HTTP \(http.statusCode): \(bodyPreview)")
                throw WeatherError.apiError("\(provider.rawValue) HTTP \(http.statusCode)")
            }
            return data
        } catch {
            SkyBridgeLogger.shared.debug("🌧️ \(provider.rawValue) 请求异常: \(error.localizedDescription)")
            throw error
        }
    }

    private func shouldRetryBypassingProxy(_ error: Error) -> Bool {
        let ns = error as NSError

        // 常见 TLS/证书错误
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorNetworkConnectionLost:
                return true
            default:
                break
            }
        }

        // 深挖 underlying error：截图里有 kCFStreamErrorCodeKey=-9816
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorSecureConnectionFailed {
                return true
            }
            // kCFStreamErrorDomainSSL = 3，-9816 为常见握手/证书链问题
            if underlying.domain == kCFErrorDomainCFNetwork as String {
                // allow fallthrough to string heuristics
            }
            let u = underlying.userInfo
            if let streamDomain = u["_kCFStreamErrorDomainKey"] as? Int, streamDomain == 3,
               let streamCode = u["_kCFStreamErrorCodeKey"] as? Int, streamCode == -9816 {
                return true
            }
        }

        // 兜底：日志中明确出现 TLS / secure connection
        let msg = ns.localizedDescription.lowercased()
        if msg.contains("tls") || msg.contains("secure connection") {
            return true
        }

        return false
    }
    
    // MARK: - Helper Methods
    
    private func parseWeatherCondition(code: Int, description: String?) -> WeatherCondition {
        // 优先通过描述判断
        if let desc = description?.lowercased() {
            if desc.contains("haze") || desc.contains("smoke") || desc.contains("mist") {
                return .haze
            }
            if desc.contains("fog") { return .foggy }
            if desc.contains("thunder") || desc.contains("storm") { return .stormy }
            if desc.contains("rain") || desc.contains("drizzle") || desc.contains("shower") { return .rainy }
            if desc.contains("snow") || desc.contains("sleet") || desc.contains("blizzard") { return .snowy }
            if desc.contains("cloud") || desc.contains("overcast") { return .cloudy }
            if desc.contains("clear") || desc.contains("sunny") || desc.contains("fair") { return .clear }
        }
        
        // wttr.in 和 WMO 代码映射
        switch code {
        case 113, 0: return .clear
        case 116, 119, 122, 1...3: return .cloudy
        case 143, 248, 260, 45, 48: return .foggy
        case 176, 263, 266, 281...314, 353...359, 51...67: return .rainy
        case 179, 227, 230, 320...377, 71...77, 85, 86: return .snowy
        case 200, 386...395, 95...99: return .stormy
        default: return .unknown
        }
    }

    private func localizedConditionDescription(for condition: WeatherCondition) -> String {
        LocalizationManager.instance.localized(condition.localizationKey)
    }
    
    private func calculateAQI(pm25: Double) -> Int? {
        guard pm25 > 0 else { return nil }
        
        switch pm25 {
        case 0..<35: return Int(pm25 * 50 / 35)
        case 35..<75: return Int(50 + (pm25 - 35) * 50 / 40)
        case 75..<115: return Int(100 + (pm25 - 75) * 50 / 40)
        case 115..<150: return Int(150 + (pm25 - 115) * 50 / 35)
        case 150..<250: return Int(200 + (pm25 - 150) * 100 / 100)
        default: return Int(300 + (pm25 - 250) * 200 / 250)
        }
    }
    
    private func formatCoordinates(_ latitude: Double, _ longitude: Double) -> String {
        let latDir = latitude >= 0 ? "N" : "S"
        let lonDir = longitude >= 0 ? "E" : "W"
        return String(format: "%.2f°%@ %.2f°%@", abs(latitude), latDir, abs(longitude), lonDir)
    }
    
    // MARK: - Cache
    
    private func cacheWeather(_ weather: WeatherInfo) {
        try? Self.weatherCacheStore.save(weather)
    }
    
    private func loadCachedWeather(allowStale: Bool = false) -> WeatherInfo? {
        guard let weather = Self.weatherCacheStore.load() else {
            return nil
        }
        
        // 检查缓存是否过期
        if allowStale || Date().timeIntervalSince(weather.timestamp) < cacheValidityDuration {
            return weather
        }
        
        return nil
    }
}

// MARK: - API Response Models

private struct WttrResponse: Codable {
    let current_condition: [CurrentCondition]
    let nearest_area: [NearestArea]?
    
    struct CurrentCondition: Codable {
        let temp_C: String
        let weatherCode: String
        let weatherDesc: [Description]
        let humidity: String
        let windspeedKmph: String
        let visibility: String
        let pm2_5: String?
        
        struct Description: Codable {
            let value: String
        }
    }
    
    struct NearestArea: Codable {
        let areaName: [NameValue]?
        
        struct NameValue: Codable {
            let value: String
        }
    }
}

private struct OpenMeteoResponse: Codable {
    let current: Current
    
    struct Current: Codable {
        let temperature_2m: Double
        let relative_humidity_2m: Double
        let weather_code: Int
        let wind_speed_10m: Double
        let visibility: Double?
    }
}

private struct MetNoResponse: Codable {
    let properties: Properties

    struct Properties: Codable {
        let timeseries: [TimeSeries]
    }

    struct TimeSeries: Codable {
        let data: DataPoint
    }

    struct DataPoint: Codable {
        let instant: Instant
        let next_1_hours: ForecastSummary?
        let next_6_hours: ForecastSummary?
    }

    struct Instant: Codable {
        let details: Details
    }

    struct Details: Codable {
        let air_temperature: Double
        let relative_humidity: Double
        let wind_speed: Double
        let visibility: Double?
    }

    struct ForecastSummary: Codable {
        let summary: Summary
    }

    struct Summary: Codable {
        let symbol_code: String
    }
}
