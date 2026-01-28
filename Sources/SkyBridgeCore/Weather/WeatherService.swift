//
// WeatherService.swift
// SkyBridgeCore
//
// 智能天气服务 - 多API降级策略
// Created: 2025-10-19
//

import Foundation
import OSLog
import Combine

/// 天气信息
public struct WeatherInfo: Sendable, Codable {
    public let temperature: Double // 摄氏度
    public let condition: WeatherCondition
    public let humidity: Double // 百分比
    public let windSpeed: Double // km/h
    public let visibility: Double? // km
    public let aqi: Int? // 空气质量指数
    public let description: String
    public let location: String
    public let timestamp: Date
    public let source: String
    
    public init(temperature: Double, condition: WeatherCondition, humidity: Double, windSpeed: Double, visibility: Double?, aqi: Int?, description: String, location: String, source: String) {
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
    
 /// 是否需要薄雾效果
    public var needsFogEffect: Bool {
        switch self {
        case .foggy, .haze: return true
        default: return false
        }
    }
    
 /// 薄雾浓度 (0-1)
    public var fogIntensity: Double {
        switch self {
        case .haze: return 0.3
        case .foggy: return 0.5
        default: return 0.0
        }
    }
}

/// SkyBridge天气服务 - 集成多个API并智能降级
@MainActor
public final class SkyBridgeWeatherService: ObservableObject {
 // MARK: - Published Properties
    
    @Published public private(set) var currentWeather: WeatherInfo?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var error: WeatherError?
    
 // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "Service")
    private let cacheKey = "com.skybridge.lastKnownWeather"
    private let cacheValidityDuration: TimeInterval = 1800 // 30分钟缓存
    private let wttrFailureCooldownSeconds: TimeInterval = 1800 // wttr.in 失败后冷却 30 分钟，避免反复超时刷屏
    private let wttrCooldownUntilKey = "com.skybridge.weather.wttrCooldownUntil"
    
 // MARK: - Errors
    
    public enum WeatherError: LocalizedError, Sendable {
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
    
 // MARK: - Public Methods
    
 /// 获取天气（智能降级）
    public func fetchWeather(for location: LocationInfo) async {
        guard !isLoading else { return }
        
        isLoading = true
        error = nil
        logger.info("🌤️ 获取天气数据: \(location.city ?? "未知")")
        
        var weatherInfo: WeatherInfo?
        
 // 策略1: 优先使用 wttr.in (免费且功能强大)
        if shouldAttemptWttr(),
           let weather = await fetchFromWttr(latitude: location.latitude, longitude: location.longitude, city: location.city) {
            weatherInfo = weather
        }
 // 策略2: 降级到 Open-Meteo (免费无API key)
        else if let weather = await fetchFromOpenMeteo(latitude: location.latitude, longitude: location.longitude, city: location.city) {
            weatherInfo = weather
        }
 // 策略3: 最终降级到缓存
        else if let cached = loadCachedWeather() {
            logger.warning("📦 使用缓存天气数据")
            weatherInfo = cached
        }
        
 // 如果获取到天气数据但缺少 AQI，尝试补充 AQI 数据
        if var weather = weatherInfo {
            if weather.aqi == nil {
                logger.info("🔍 天气数据缺少 AQI，尝试获取空气质量数据")
                if let aqi = await fetchAQIData(latitude: location.latitude, longitude: location.longitude) {
                    weather = WeatherInfo(
                        temperature: weather.temperature,
                        condition: weather.condition,
                        humidity: weather.humidity,
                        windSpeed: weather.windSpeed,
                        visibility: weather.visibility,
                        aqi: aqi,
                        description: weather.description,
                        location: weather.location,
                        source: weather.source + " + AQI"
                    )
                    logger.info("✅ 成功补充 AQI 数据: \(aqi)")
                }
            }
            
            currentWeather = weather
            cacheWeather(weather)
        } else {
            error = .networkError
        }
        
        isLoading = false
    }
    
 // MARK: - API Implementations
    
 /// wttr.in API (推荐: 免费、无需API key、支持空气质量)
    private func fetchFromWttr(latitude: Double, longitude: Double, city: String?) async -> WeatherInfo? {
 // wttr.in 支持坐标查询
        let urlString = "https://wttr.in/\(latitude),\(longitude)?format=j1"

        guard let url = URL(string: urlString) else { return nil }

        do {
 // 配置轻量网络超时与不等待网络连接，避免请求阻塞主流程
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5.0
            config.timeoutIntervalForResource = 5.0
            config.waitsForConnectivity = false
            let session = URLSession(configuration: config)
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            let (data, _) = try await session.data(for: request)
            let response = try JSONDecoder().decode(WttrResponse.self, from: data)

            guard let current = response.current_condition.first else { return nil }

 // 解析天气状态
            let condition = parseWeatherCondition(code: Int(current.weatherCode) ?? 0, description: current.weatherDesc.first?.value ?? "")

 // 计算AQI（如果有PM2.5数据）
            let aqi = calculateAQI(pm25: Double(current.pm2_5 ?? "0") ?? 0)

            // 🔧 优先使用传入的city，否则尝试从API响应获取，最后用坐标
            let locationName = city ?? response.nearest_area?.first?.areaName?.first?.value ?? formatCoordinates(latitude, longitude)

            let weather = WeatherInfo(
                temperature: Double(current.temp_C) ?? 0,
                condition: condition,
                humidity: Double(current.humidity) ?? 0,
                windSpeed: Double(current.windspeedKmph) ?? 0,
                visibility: Double(current.visibility) ?? nil,
                aqi: aqi,
                description: current.weatherDesc.first?.value ?? "未知",
                location: locationName,
                source: "wttr.in"
            )

            logger.info("✅ wttr.in 天气获取成功: \(condition.rawValue), \(weather.temperature)°C")
            return weather

        } catch {
            // 请求失败时不阻塞主流程，记录简洁日志并返回nil以触发降级。
            // 同时触发“失败冷却”，避免在代理/网络不通时反复触发系统级 NW/CFNetwork 报错刷屏。
            markWttrFailedIfNeeded(error)
            logger.debug("❌ wttr.in 请求失败(超时或网络不可用): \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - wttr.in failure cooldown (避免反复超时导致系统刷屏)
    
    private func shouldAttemptWttr() -> Bool {
        let until = UserDefaults.standard.double(forKey: wttrCooldownUntilKey)
        if until <= 0 { return true }
        return Date().timeIntervalSince1970 >= until
    }
    
    private func markWttrFailedIfNeeded(_ error: Error) {
        // 只对典型的“网络不可用/超时/连接丢失”触发冷却，避免把 4xx/JSON 解析等逻辑错误也当成网络问题。
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                 NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost, NSURLErrorInternationalRoamingOff:
                let until = Date().addingTimeInterval(wttrFailureCooldownSeconds).timeIntervalSince1970
                UserDefaults.standard.set(until, forKey: wttrCooldownUntilKey)
            default:
                break
            }
        }
    }

 /// Open-Meteo API (备用: 免费、开源、无需API key)
    private func fetchFromOpenMeteo(latitude: Double, longitude: Double, city: String?) async -> WeatherInfo? {
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,visibility&timezone=auto"

        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

            let condition = parseWeatherCondition(code: response.current.weather_code, description: nil)

 // 18.5: 安全处理 visibility optional (Requirements 8.1)
 // 使用 map 替代 force unwrap，更安全地处理 Optional
            let visibilityKm = response.current.visibility.map { $0 / 1000 }

            // 🔧 如果city为nil，尝试通过坐标反向解析或使用格式化坐标
            let locationName = city ?? formatCoordinates(latitude, longitude)

            let weather = WeatherInfo(
                temperature: response.current.temperature_2m,
                condition: condition,
                humidity: response.current.relative_humidity_2m,
                windSpeed: response.current.wind_speed_10m,
                visibility: visibilityKm,
                aqi: nil, // Open-Meteo 不提供AQI
                description: condition.rawValue,
                location: locationName,
                source: "Open-Meteo"
            )

            logger.info("✅ Open-Meteo 天气获取成功: \(condition.rawValue), \(weather.temperature)°C")
            return weather

        } catch {
            logger.error("❌ Open-Meteo 请求失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 格式化坐标为更友好的显示格式
    private func formatCoordinates(_ latitude: Double, _ longitude: Double) -> String {
        let latDir = latitude >= 0 ? "N" : "S"
        let lonDir = longitude >= 0 ? "E" : "W"
        return String(format: "%.2f°%@ %.2f°%@", abs(latitude), latDir, abs(longitude), lonDir)
    }
    
 /// 专门获取 AQI 数据（备用策略）
    private func fetchAQIData(latitude: Double, longitude: Double) async -> Int? {
 // 策略1: 使用 OpenWeatherMap Air Pollution API (免费)
        if let aqi = await fetchAQIFromOpenWeatherMap(latitude: latitude, longitude: longitude) {
            return aqi
        }
        
 // 策略2: 使用 WAQI API (免费但需要注册)
        if let aqi = await fetchAQIFromWAQI(latitude: latitude, longitude: longitude) {
            return aqi
        }
        
 // 策略3: 基于能见度估算 AQI
        if let weather = currentWeather, let visibility = weather.visibility {
            return estimateAQIFromVisibility(visibility: visibility)
        }
        
        return nil
    }
    
 /// 从 OpenWeatherMap Air Pollution API 获取 AQI
    private func fetchAQIFromOpenWeatherMap(latitude: Double, longitude: Double) async -> Int? {
        guard let apiKey = UserDefaults.standard.string(forKey: "OPENWEATHERMAP_API_KEY"), !apiKey.isEmpty else { return nil }
        let urlString = "https://api.openweathermap.org/data/2.5/air_pollution?lat=\(latitude)&lon=\(longitude)&appid=\(apiKey)"
        
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            
            if let list = response?["list"] as? [[String: Any]],
               let first = list.first,
               let main = first["main"] as? [String: Any],
               let aqi = main["aqi"] as? Int {
                logger.info("✅ OpenWeatherMap AQI 获取成功: \(aqi)")
                return aqi
            }
        } catch {
            logger.debug("❌ OpenWeatherMap AQI 请求失败: \(error.localizedDescription)")
        }
        
        return nil
    }
    
 /// 从 WAQI API 获取 AQI
    private func fetchAQIFromWAQI(latitude: Double, longitude: Double) async -> Int? {
        guard let token = UserDefaults.standard.string(forKey: "WAQI_API_TOKEN"), !token.isEmpty else { return nil }
        let urlString = "https://api.waqi.info/feed/geo:\(latitude);\(longitude)/?token=\(token)"
        
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            
            if let data = response?["data"] as? [String: Any],
               let aqi = data["aqi"] as? Int {
                logger.info("✅ WAQI AQI 获取成功: \(aqi)")
                return aqi
            }
        } catch {
            logger.debug("❌ WAQI AQI 请求失败: \(error.localizedDescription)")
        }
        
        return nil
    }
    
 /// 基于能见度估算 AQI（备用方案）
    private func estimateAQIFromVisibility(visibility: Double) -> Int {
 // 根据能见度粗略估算 AQI
 // 这是一个简化的估算，实际 AQI 受多种因素影响
        switch visibility {
        case 10...: return 50    // 优秀 (能见度 >= 10km)
        case 7..<10: return 100  // 良好 (7-10km)
        case 4..<7: return 150   // 轻度污染 (4-7km)
        case 2..<4: return 200   // 中度污染 (2-4km)
        case 1..<2: return 250   // 重度污染 (1-2km)
        default: return 300      // 严重污染 (<1km)
        }
    }
    
 // MARK: - Helper Methods
    
 /// 解析天气状态码（支持 wttr.in 和 WMO 标准）
    private func parseWeatherCondition(code: Int, description: String?) -> WeatherCondition {
 // 首先尝试通过描述文字判断（最准确）
        if let desc = description?.lowercased() {
            logger.debug("🔍 天气描述: \(desc), 代码: \(code)")
            
 // 优先级匹配
            if desc.contains("haze") || desc.contains("smoke") || desc.contains("mist") {
                return .haze
            }
            if desc.contains("fog") {
                return .foggy
            }
            if desc.contains("thunder") || desc.contains("storm") {
                return .stormy
            }
            if desc.contains("rain") || desc.contains("drizzle") || desc.contains("shower") {
                return .rainy
            }
            if desc.contains("snow") || desc.contains("sleet") || desc.contains("blizzard") {
                return .snowy
            }
            if desc.contains("cloud") || desc.contains("overcast") {
                return .cloudy
            }
            if desc.contains("clear") || desc.contains("sunny") || desc.contains("fair") {
                return .clear
            }
        }
        
 // wttr.in 天气代码映射表（参考 https://www.worldweatheronline.com/developer/api/docs/weather-icons.aspx）
        switch code {
 // 晴朗
        case 113: return .clear
 // 多云
        case 116: return .cloudy  // Partly cloudy
        case 119: return .cloudy  // Cloudy
        case 122: return .cloudy  // Overcast
 // 雾霾/雾
        case 143: return .haze    // Mist
        case 248: return .foggy   // Fog
        case 260: return .foggy   // Freezing fog
 // 雨
        case 176: return .rainy   // Patchy rain possible
        case 263: return .rainy   // Patchy light drizzle
        case 266: return .rainy   // Light drizzle
        case 281: return .rainy   // Freezing drizzle
        case 284: return .rainy   // Heavy freezing drizzle
        case 293: return .rainy   // Patchy light rain
        case 296: return .rainy   // Light rain
        case 299: return .rainy   // Moderate rain at times
        case 302: return .rainy   // Moderate rain
        case 305: return .rainy   // Heavy rain at times
        case 308: return .rainy   // Heavy rain
        case 311: return .rainy   // Light freezing rain
        case 314: return .rainy   // Moderate or heavy freezing rain
        case 353: return .rainy   // Light rain shower
        case 356: return .rainy   // Moderate or heavy rain shower
        case 359: return .rainy   // Torrential rain shower
 // 雪
        case 179: return .snowy   // Patchy snow possible
        case 227: return .snowy   // Blowing snow
        case 230: return .snowy   // Blizzard
        case 320: return .snowy   // Light sleet
        case 323: return .snowy   // Patchy light snow
        case 326: return .snowy   // Light snow
        case 329: return .snowy   // Patchy moderate snow
        case 332: return .snowy   // Moderate snow
        case 335: return .snowy   // Patchy heavy snow
        case 338: return .snowy   // Heavy snow
        case 350: return .snowy   // Ice pellets
        case 368: return .snowy   // Light snow showers
        case 371: return .snowy   // Moderate or heavy snow showers
        case 374: return .snowy   // Light showers of ice pellets
        case 377: return .snowy   // Moderate or heavy showers of ice pellets
 // 雷暴
        case 200: return .stormy  // Thundery outbreaks possible
        case 386: return .stormy  // Patchy light rain with thunder
        case 389: return .stormy  // Moderate or heavy rain with thunder
        case 392: return .stormy  // Patchy light snow with thunder
        case 395: return .stormy  // Moderate or heavy snow with thunder
        
 // WMO Weather Code 标准（兼容 Open-Meteo）
        case 0: return .clear
        case 1...3: return .cloudy
        case 45, 48: return .foggy
        case 51...67: return .rainy
        case 71...77, 85, 86: return .snowy
        case 95...99: return .stormy
        
        default:
            logger.warning("⚠️ 未识别的天气代码: \(code), 描述: \(description ?? "无")")
            return .unknown
        }
    }
    
 /// 计算AQI（基于PM2.5）
    private func calculateAQI(pm25: Double) -> Int? {
        guard pm25 > 0 else { return nil }
        
 // 简化的AQI计算（中国标准）
        switch pm25 {
        case 0..<35: return Int(pm25 * 50 / 35)
        case 35..<75: return Int(50 + (pm25 - 35) * 50 / 40)
        case 75..<115: return Int(100 + (pm25 - 75) * 50 / 40)
        case 115..<150: return Int(150 + (pm25 - 115) * 50 / 35)
        case 150..<250: return Int(200 + (pm25 - 150) * 100 / 100)
        default: return Int(300 + (pm25 - 250) * 200 / 250)
        }
    }
    
 // MARK: - Cache Management
    
    private func cacheWeather(_ weather: WeatherInfo) {
        if let encoded = try? JSONEncoder().encode(weather) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
        }
    }
    
    private func loadCachedWeather() -> WeatherInfo? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let weather = try? JSONDecoder().decode(WeatherInfo.self, from: data) else {
            return nil
        }
        
 // 检查缓存是否过期
        if Date().timeIntervalSince(weather.timestamp) < cacheValidityDuration {
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
        let region: [NameValue]?
        let country: [NameValue]?

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
