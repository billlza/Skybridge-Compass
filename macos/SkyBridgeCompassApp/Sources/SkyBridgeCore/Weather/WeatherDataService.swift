import Foundation
import WeatherKit
import CoreLocation
import Combine
import os.log

/// 天气数据服务 - 使用WeatherKit获取实时天气数据
@MainActor
public final class WeatherDataService: ObservableObject {
    
    // MARK: - 发布的属性
    @Published public private(set) var currentWeather: Weather?
    @Published public private(set) var hourlyForecast: [HourWeather] = []
    @Published public private(set) var dailyForecast: [DayWeather] = []
    @Published public private(set) var weatherAlerts: [WeatherAlert] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastUpdateTime: Date?
    @Published public private(set) var weatherError: WeatherError?
    
    // MARK: - 私有属性
    private let weatherService = WeatherService.shared
    private let log = Logger(subsystem: "com.skybridge.compass", category: "WeatherData")
    @MainActor private var weatherUpdateTimer: Timer?
    private let weatherUpdateInterval: TimeInterval = 600 // 10分钟更新一次天气
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - 位置服务
    public var locationService: WeatherLocationService?
    
    // MARK: - 天气错误类型
    public enum WeatherError: LocalizedError {
        case locationRequired
        case networkError
        case apiError(String)
        case dataUnavailable
        case rateLimitExceeded
        case unauthorized
        
        public var errorDescription: String? {
            switch self {
            case .locationRequired:
                return "需要位置信息获取天气数据"
            case .networkError:
                return "网络连接错误"
            case .apiError(let message):
                return "天气API错误: \(message)"
            case .dataUnavailable:
                return "天气数据不可用"
            case .rateLimitExceeded:
                return "API调用频率超限"
            case .unauthorized:
                return "天气服务未授权"
            }
        }
    }
    
    // MARK: - 天气类型枚举
    public enum WeatherType: String, CaseIterable, Codable, Sendable {
        case clear = "clear"
        case partlyCloudy = "partlyCloudy"
        case cloudy = "cloudy"
        case rain = "rain"
        case heavyRain = "heavyRain"
        case snow = "snow"
        case heavySnow = "heavySnow"
        case thunderstorm = "thunderstorm"
        case fog = "fog"
        case haze = "haze"  // 新增雾霾天气类型
        case wind = "wind"
        case hail = "hail"
        case unknown = "unknown"
        
        public var displayName: String {
            switch self {
            case .clear: return "晴天"
            case .partlyCloudy: return "多云"
            case .cloudy: return "阴天"
            case .rain: return "雨天"
            case .heavyRain: return "大雨"
            case .snow: return "雪天"
            case .heavySnow: return "大雪"
            case .thunderstorm: return "雷暴"
            case .fog: return "雾天"
            case .haze: return "雾霾"  // 雾霾显示名称
            case .wind: return "大风"
            case .hail: return "冰雹"
            case .unknown: return "未知"
            }
        }

        /// 根据WeatherKit的天气条件映射到自定义类型
        public static func from(condition: WeatherCondition) -> WeatherType {
            switch condition {
            case .clear:
                return .clear
            case .partlyCloudy:
                return .partlyCloudy
            case .cloudy, .mostlyCloudy:
                return .cloudy
            case .rain, .drizzle:
                return .rain
            case .heavyRain:
                return .heavyRain
            case .snow, .flurries:
                return .snow
            case .heavySnow, .blizzard:
                return .heavySnow
            case .thunderstorms:
                return .thunderstorm
            case .foggy:
                return .fog
            case .haze, .smoky:  // 将haze和smoky映射到雾霾类型
                return .haze
            case .breezy, .windy:
                return .wind
            case .hail:
                return .hail
            default:
                return .unknown
            }
        }
    }
    
    // MARK: - 天气强度枚举
    public enum WeatherIntensity: Double, CaseIterable {
        case light = 0.3
        case moderate = 0.6
        case heavy = 1.0
        
        public var displayName: String {
            switch self {
            case .light: return "轻微"
            case .moderate: return "中等"
            case .heavy: return "强烈"
            }
        }
    }
    
    // MARK: - 初始化
    public init() {
        log.info("天气数据服务已初始化")
    }
    
    deinit {
        // 简化 deinit，避免访问非 Sendable 的 Timer
        // Timer 会在对象销毁时自动清理
    }
    
    // MARK: - 公共方法
    
    /// 获取指定位置的天气数据
    public func fetchWeather(for location: CLLocation) async {
        isLoading = true
        weatherError = nil
        
        do {
            log.info("开始获取天气数据，位置: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            
            let weather = try await weatherService.weather(for: location)
            
            await MainActor.run {
                self.currentWeather = weather
                self.hourlyForecast = Array(weather.hourlyForecast.prefix(24)) // 24小时预报
                self.dailyForecast = Array(weather.dailyForecast.prefix(7)) // 7天预报
                self.weatherAlerts = weather.weatherAlerts ?? []
                self.lastUpdateTime = Date()
                self.isLoading = false
                
                self.log.info("天气数据获取成功")
            }
            
        } catch {
            await MainActor.run {
                self.handleWeatherError(error)
                self.isLoading = false
            }
        }
    }
    
    /// 开始自动天气更新
    public func startWeatherUpdates(for location: CLLocation) {
        // 立即获取一次天气数据
        Task {
            await fetchWeather(for: location)
        }
        
        // 设置定时更新
        weatherUpdateTimer = Timer.scheduledTimer(withTimeInterval: weatherUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.fetchWeather(for: location)
            }
        }
        
        log.info("开始自动天气更新")
    }
    
    /// 停止自动天气更新
    public func stopWeatherUpdates() {
        weatherUpdateTimer?.invalidate()
        weatherUpdateTimer = nil
        log.info("停止自动天气更新")
    }
    
    /// 获取当前天气类型
    public func getCurrentWeatherType() -> WeatherType {
        guard let weather = currentWeather else { return .unknown }
        return WeatherType.from(condition: weather.currentWeather.condition)
    }
    
    /// 获取天气强度（基于降水量、风速等）
    public func getWeatherIntensity() -> WeatherIntensity {
        guard let weather = currentWeather else { return .light }
        
        let current = weather.currentWeather
        let weatherType = getCurrentWeatherType()
        
        switch weatherType {
        case .rain, .heavyRain:
            // 基于降水概率和云层覆盖判断强度
            let cloudCover = current.cloudCover
            if cloudCover > 0.8 { return .heavy }
            if cloudCover > 0.5 { return .moderate }
            return weatherType == .heavyRain ? .heavy : .light
            
        case .snow, .heavySnow:
            // 基于云层覆盖度判断强度
            let cloudCover = current.cloudCover
            if cloudCover > 0.9 { return .heavy }
            if cloudCover > 0.7 { return .moderate }
            return weatherType == .heavySnow ? .heavy : .light
            
        case .wind:
            // 基于风速判断强度
            let windSpeed = current.wind.speed.value
            if windSpeed > 15.0 { return .heavy }
            if windSpeed > 8.0 { return .moderate }
            return .light
            
        case .thunderstorm:
            return .heavy
            
        case .fog:
            // 基于能见度判断强度
            let visibility = current.visibility.value
            if visibility < 1.0 { return .heavy }
            if visibility < 5.0 { return .moderate }
            return .light
            
        case .haze:  // 新增雾霾强度判断
            // 基于能见度和湿度判断雾霾强度
            let visibility = current.visibility.value
            let humidity = current.humidity
            
            // 雾霾强度综合考虑能见度和湿度
            if visibility < 2.0 || humidity > 0.8 { return .heavy }
            if visibility < 5.0 || humidity > 0.6 { return .moderate }
            return .light
            
        default:
            return .light
        }
    }
    
    /// 获取天气参数用于渲染
    public func getWeatherRenderingParameters() -> WeatherRenderingParameters {
        let weatherType = getCurrentWeatherType()
        let intensity = getWeatherIntensity()
        
        guard let weather = currentWeather else {
            return WeatherRenderingParameters(
                weatherType: weatherType,
                intensity: intensity.rawValue,
                temperature: 20.0,
                humidity: 0.5,
                windSpeed: 0.0,
                windDirection: 0.0,
                cloudCoverage: 0.0,
                precipitationAmount: 0.0,
                visibility: 10.0,
                pressure: 1013.25,
                uvIndex: 0.0,
                timeOfDay: getTimeOfDay()
            )
        }
        
        let current = weather.currentWeather
        
        return WeatherRenderingParameters(
            weatherType: weatherType,
            intensity: intensity.rawValue,
            temperature: current.temperature.value,
            humidity: current.humidity,
            windSpeed: current.wind.speed.value,
            windDirection: current.wind.direction.value,
            cloudCoverage: current.cloudCover,
            precipitationAmount: 0.0, // WeatherKit不直接提供降水量
            visibility: current.visibility.value,
            pressure: current.pressure.value,
            uvIndex: Double(current.uvIndex.value),
            timeOfDay: getTimeOfDay()
        )
    }
    
    // MARK: - 调试方法
    
    /// 设置模拟天气数据（仅用于测试）
    public func setSimulatedWeather(
        weatherType: WeatherType,
        intensity: WeatherIntensity = .moderate,
        temperature: Double = 20.0,
        humidity: Double = 60.0,
        visibility: Double = 5.0
    ) {
        // 创建模拟的天气渲染参数
        _ = WeatherRenderingParameters(
            weatherType: weatherType,
            intensity: intensity.rawValue,
            temperature: temperature,
            humidity: humidity,
            windSpeed: 5.0,
            windDirection: 0.0,
            cloudCoverage: 0.7,
            precipitationAmount: 0.0,
            visibility: visibility,
            pressure: 1013.25,
            uvIndex: 3.0,
            timeOfDay: getTimeOfDay()
        )
        
        // 触发天气数据更新通知
        objectWillChange.send()
        
        log.info("🧪 设置模拟天气: \(weatherType.displayName), 强度: \(intensity.displayName), 能见度: \(visibility)km")
    }
    
    /// 获取模拟的雾霾天气参数
    public func getSimulatedHazeWeatherParameters() -> WeatherRenderingParameters {
        return WeatherRenderingParameters(
            weatherType: .haze,
            intensity: WeatherIntensity.heavy.rawValue,
            temperature: 25.0,
            humidity: 80.0,
            windSpeed: 2.0,
            windDirection: 45.0,
            cloudCoverage: 0.8,
            precipitationAmount: 0.0,
            visibility: 2.0, // 低能见度
            pressure: 1008.0,
            uvIndex: 2.0,
            timeOfDay: getTimeOfDay()
        )
    }
    
    // MARK: - 私有方法
    
    /// 处理天气错误
    private func handleWeatherError(_ error: Error) {
        log.error("天气数据获取失败: \(error.localizedDescription)")
        
        if let weatherKitError = error as? WeatherError {
            weatherError = weatherKitError
        } else {
            // 根据错误类型映射到自定义错误
            let errorDescription = error.localizedDescription.lowercased()
            
            if errorDescription.contains("network") || errorDescription.contains("internet") {
                weatherError = .networkError
            } else if errorDescription.contains("unauthorized") || errorDescription.contains("permission") {
                weatherError = .unauthorized
            } else if errorDescription.contains("rate") || errorDescription.contains("limit") {
                weatherError = .rateLimitExceeded
            } else {
                weatherError = .apiError(error.localizedDescription)
            }
        }
    }
    
    /// 获取当前时间段
    private func getTimeOfDay() -> TimeOfDay {
        let hour = Calendar.current.component(.hour, from: Date())
        
        switch hour {
        case 6..<12:
            return .morning
        case 12..<18:
            return .afternoon
        case 18..<22:
            return .evening
        default:
            return .night
        }
    }
}

// MARK: - 天气渲染参数
public struct WeatherRenderingParameters {
    public let weatherType: WeatherDataService.WeatherType
    public let intensity: Double
    public let temperature: Double
    public let humidity: Double
    public let windSpeed: Double
    public let windDirection: Double
    public let cloudCoverage: Double
    public let precipitationAmount: Double
    public let visibility: Double
    public let pressure: Double
    public let uvIndex: Double
    public let timeOfDay: TimeOfDay
    
    public init(
        weatherType: WeatherDataService.WeatherType,
        intensity: Double,
        temperature: Double,
        humidity: Double,
        windSpeed: Double,
        windDirection: Double,
        cloudCoverage: Double,
        precipitationAmount: Double,
        visibility: Double,
        pressure: Double,
        uvIndex: Double,
        timeOfDay: TimeOfDay
    ) {
        self.weatherType = weatherType
        self.intensity = intensity
        self.temperature = temperature
        self.humidity = humidity
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.cloudCoverage = cloudCoverage
        self.precipitationAmount = precipitationAmount
        self.visibility = visibility
        self.pressure = pressure
        self.uvIndex = uvIndex
        self.timeOfDay = timeOfDay
    }
}

// MARK: - 时间段枚举（移除重复定义，使用 WeatherMLPredictor 中的定义）
// public enum TimeOfDay: String, CaseIterable {
//     case morning = "morning"
//     case afternoon = "afternoon"
//     case evening = "evening"
//     case night = "night"
//     
//     public var displayName: String {
//         switch self {
//         case .morning: return "上午"
//         case .afternoon: return "下午"
//         case .evening: return "傍晚"
//         case .night: return "夜晚"
//         }
//     }
// }