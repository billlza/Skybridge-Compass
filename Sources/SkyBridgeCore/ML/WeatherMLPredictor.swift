import Foundation
import CoreML
import Combine

// MARK: - 类型别名和导入
public typealias WeatherType = WeatherDataService.WeatherType

/// 天气数据结构
public struct WeatherData: Sendable {
    public let weatherType: WeatherType
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
    public let timestamp: Date
    
    public init(
        weatherType: WeatherType,
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
        timeOfDay: TimeOfDay,
        timestamp: Date = Date()
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
        self.timestamp = timestamp
    }
    
 /// 默认天气数据 - Swift 6.2 并发安全
    public static let `default`: WeatherData = {
        WeatherData(
            weatherType: .clear,
            intensity: 0.5,
            temperature: 20.0,
            humidity: 50.0,
            windSpeed: 5.0,
            windDirection: 0.0,
            cloudCoverage: 0.3,
            precipitationAmount: 0.0,
            visibility: 10.0,
            pressure: 1013.25,
            uvIndex: 5.0,
            timeOfDay: .afternoon
        )
    }()
}

/// 时间段枚举
public enum TimeOfDay: String, CaseIterable, Sendable {
    case morning = "上午"
    case afternoon = "下午"
    case evening = "傍晚"
    case night = "夜晚"
}

/// 天气机器学习预测器 - 使用Core ML进行天气预测和趋势分析
@MainActor
public class WeatherMLPredictor: ObservableObject {
    
 // MARK: - 发布属性
    
 /// 当前天气预测结果
    @Published public var weatherPrediction: WeatherPrediction?
    
 /// 预测置信度
    @Published public var predictionConfidence: Double = 0.0
    
 /// 预测状态
    @Published public var predictionStatus: PredictionStatus = .idle
    
 // MARK: - 私有属性
    
    private var mlModel: MLModel?
    private var backend: WeatherPredictorBackend = EnhancedRuleEngineBackend()
    private var weatherHistory: [WeatherData] = []
    private let maxHistorySize: Int = 100
    
 // 预测参数
    private let predictionInterval: TimeInterval = 300 // 5分钟预测一次
    private var predictionTimer: Timer?
    
 // MARK: - 初始化
    
    public init() throws {
        try loadMLModel()
        startPredictionTimer()
        SkyBridgeLogger.performance.debugOnly("✅ 天气ML预测器初始化完成")
    }
    
    deinit {
 // 简化 deinit，避免访问非 Sendable 的 Timer
 // Timer 会在对象销毁时自动清理
    }
    
 // MARK: - 公共方法
    
 /// 更新天气数据并触发预测
    public func updateWeatherData(_ weatherData: WeatherData) async {
 // 添加到历史记录
        addToHistory(weatherData)
        
 // 如果有足够的历史数据，进行预测
        if weatherHistory.count >= 5 {
            await performPrediction()
        }
    }
    
 /// 获取可能的下一个天气类型
    public func getPossibleNextWeatherTypes(from currentWeather: WeatherData) -> [WeatherType] {
        return backend.possibleNextTypes(currentWeather: currentWeather, history: weatherHistory)
    }
    
 /// 获取天气变化趋势
    public func getWeatherTrend() -> WeatherTrend {
        return backend.weatherTrend(history: weatherHistory)
    }
    
 /// 预测未来N小时的天气
    public func predictWeatherForNextHours(_ hours: Int) async -> [HourlyWeatherPrediction] {
        return await backend.predictNextHours(history: weatherHistory, hours: hours)
    }
    
 // MARK: - 私有方法
    
 /// 加载机器学习模型
 ///
 /// Swift 6.2.1 最佳实践：
 /// - 优先加载 CoreML 模型
 /// - 降级到增强规则引擎（基于气象学算法）
    private func loadMLModel() throws {
        SkyBridgeLogger.performance.debugOnly("📦 加载天气预测ML模型...")
        
 // 尝试加载 CoreML 模型
        if let modelURL = Bundle.main.url(forResource: "WeatherPredictionModel", withExtension: "mlmodelc") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine // Apple Silicon 优化
                
                self.mlModel = try MLModel(contentsOf: modelURL, configuration: config)
                
                if #available(macOS 14.0, *) {
                    backend = CoreMLWeatherBackend(model: self.mlModel)
                } else {
                    backend = EnhancedRuleEngineBackend()
                }
                
                SkyBridgeLogger.performance.debugOnly("✅ CoreML 模型加载成功")
            } catch {
                SkyBridgeLogger.performance.warning("⚠️ CoreML 模型加载失败，使用增强规则引擎: \(error.localizedDescription)")
                backend = EnhancedRuleEngineBackend()
            }
        } else {
 // 使用增强规则引擎作为高质量降级方案
            SkyBridgeLogger.performance.debugOnly("ℹ️ 未找到 CoreML 模型，使用增强规则引擎")
            backend = EnhancedRuleEngineBackend()
        }
        
        SkyBridgeLogger.performance.debugOnly("✅ 天气预测后端初始化完成")
    }
    
 /// 获取当前使用的后端类型
    public var currentBackendType: String {
        if mlModel != nil {
            return "CoreML"
        }
        return "EnhancedRuleEngine"
    }
    
 /// 添加到历史记录
    private func addToHistory(_ weatherData: WeatherData) {
        weatherHistory.append(weatherData)
        
 // 限制历史记录大小
        if weatherHistory.count > maxHistorySize {
            weatherHistory.removeFirst()
        }
        
        SkyBridgeLogger.performance.debugOnly("📊 添加天气数据到历史记录，当前记录数: \(weatherHistory.count)")
    }
    
 /// 启动预测定时器
    private func startPredictionTimer() {
        predictionTimer = Timer.scheduledTimer(withTimeInterval: predictionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performPrediction()
            }
        }
    }
    
 /// 执行天气预测
    private func performPrediction() async {
        guard weatherHistory.count >= 5 else {
            return
        }
        
        predictionStatus = .predicting
        
        do {
            let prediction = try await backend.generatePrediction(history: weatherHistory)
            
            self.weatherPrediction = prediction
            self.predictionConfidence = prediction.confidence
            self.predictionStatus = .completed
            
            SkyBridgeLogger.performance.debugOnly("🔮 天气预测完成: \(prediction.predictedWeatherType) 置信度: \(prediction.confidence)")
            
        } catch {
            SkyBridgeLogger.performance.error("❌ 天气预测失败: \(error.localizedDescription, privacy: .private)")
            predictionStatus = .failed
        }
    }
    
 /// 生成天气预测
    private func generateWeatherPrediction() async throws -> WeatherPrediction {
        return try await backend.generatePrediction(history: weatherHistory)
    }
    
 /// 预测指定小时的天气
 /// 基于历史数据趋势分析进行预测，而非随机值
    private func predictWeatherForHour(_ hour: Int, using model: MLModel) async throws -> HourlyWeatherPrediction {
        guard weatherHistory.count >= 3 else {
            throw WeatherPredictionError.insufficientData
        }
        
 // 使用最近的历史数据计算趋势
        let recentHistory = Array(weatherHistory.suffix(6))
        
 // 计算温度趋势（线性回归简化版）
        let temperatureTrend = calculateTrend(values: recentHistory.map { $0.temperature })
        let humidityTrend = calculateTrend(values: recentHistory.map { $0.humidity })
        let pressureTrend = calculateTrend(values: recentHistory.map { $0.pressure })
        
 // 基于趋势预测未来值
        let hoursAhead = Double(hour)
        let latestWeather = weatherHistory.last!
        
        let predictedTemperature = latestWeather.temperature + (temperatureTrend * hoursAhead)
        let predictedHumidity = max(0, min(100, latestWeather.humidity + (humidityTrend * hoursAhead)))
        let predictedPressure = latestWeather.pressure + (pressureTrend * hoursAhead)
        
 // 基于预测的条件确定天气类型
        var predictedWeatherType: WeatherType = .clear
        
        if predictedPressure < 1010 && predictedHumidity > 70 {
            predictedWeatherType = .rain
        } else if predictedTemperature < 0 && predictedHumidity > 80 {
            predictedWeatherType = .snow
        } else if predictedHumidity > 80 {
            predictedWeatherType = .cloudy
        } else if predictedPressure > 1020 && predictedHumidity < 50 {
            predictedWeatherType = .clear
        }
        
 // 置信度基于历史数据量和趋势稳定性
        let trendStability = 1.0 - min(1.0, abs(temperatureTrend) / 5.0)
        let dataConfidence = min(1.0, Double(weatherHistory.count) / 10.0)
        let confidence = 0.5 + (trendStability * 0.25) + (dataConfidence * 0.25)
        
        return HourlyWeatherPrediction(
            hour: hour,
            weatherType: predictedWeatherType,
            temperature: predictedTemperature,
            humidity: predictedHumidity,
            pressure: predictedPressure,
            confidence: confidence,
            predictionTime: Date()
        )
    }
    
 /// 计算数值序列的趋势（每单位时间的变化率）
 /// 使用简单线性回归计算斜率
    private func calculateTrend(values: [Double]) -> Double {
        guard values.count >= 2 else { return 0.0 }
        
        let n = Double(values.count)
        var sumX = 0.0
        var sumY = 0.0
        var sumXY = 0.0
        var sumX2 = 0.0
        
        for (i, value) in values.enumerated() {
            let x = Double(i)
            sumX += x
            sumY += value
            sumXY += x * value
            sumX2 += x * x
        }
        
 // 线性回归斜率: (n*sumXY - sumX*sumY) / (n*sumX2 - sumX*sumX)
        let denominator = n * sumX2 - sumX * sumX
        guard denominator != 0 else { return 0.0 }
        
        return (n * sumXY - sumX * sumY) / denominator
    }
    
 /// 分析数值趋势
    private func analyzeTrend(values: [Double]) -> Trend {
        guard values.count >= 2 else { return .stable }
        
        let first = values.first!
        let last = values.last!
        let change = last - first
        
        let threshold = abs(first) * 0.05 // 5%的变化阈值
        
        if change > threshold {
            return .rising
        } else if change < -threshold {
            return .falling
        } else {
            return .stable
        }
    }
    
 /// 创建预测因子
    private func createPredictionFactors(
        temperatureTrend: Trend,
        pressureTrend: Trend,
        humidityTrend: Trend
    ) -> [String: String] {
        return [
            "temperatureTrend": temperatureTrend.rawValue,
            "pressureTrend": pressureTrend.rawValue,
            "humidityTrend": humidityTrend.rawValue,
            "historicalDataPoints": "\(weatherHistory.count)"
        ]
    }
}

// MARK: - 支持类型定义

/// 天气预测结果
public struct WeatherPrediction: Sendable {
    public let predictedWeatherType: WeatherType
    public let confidence: Double
    public let predictionTime: Date
    public let factors: [String: String] // 修改为Sendable类型
    
    public init(predictedWeatherType: WeatherType, confidence: Double, predictionTime: Date, factors: [String: String]) {
        self.predictedWeatherType = predictedWeatherType
        self.confidence = confidence
        self.predictionTime = predictionTime
        self.factors = factors
    }
}

/// 天气预测错误类型
public enum WeatherPredictionError: Error, Sendable {
    case modelNotLoaded
    case insufficientData
    case predictionFailed
}

/// 小时级天气预测
public struct HourlyWeatherPrediction: Sendable {
    public let hour: Int
    public let weatherType: WeatherType
    public let temperature: Double
    public let humidity: Double
    public let pressure: Double
    public let confidence: Double
    public let predictionTime: Date
    
    public init(hour: Int, weatherType: WeatherType, temperature: Double, humidity: Double, pressure: Double, confidence: Double, predictionTime: Date) {
        self.hour = hour
        self.weatherType = weatherType
        self.temperature = temperature
        self.humidity = humidity
        self.pressure = pressure
        self.confidence = confidence
        self.predictionTime = predictionTime
    }
}

/// 预测状态
public enum PredictionStatus: Sendable {
    case idle
    case predicting
    case completed
    case failed
}

/// 天气趋势
public enum WeatherTrend: Sendable {
    case improving    // 天气转好
    case deteriorating // 天气转坏
    case stable       // 稳定
}

/// 数值趋势
public enum Trend: String, Sendable {
    case rising = "上升"
    case falling = "下降"
    case stable = "稳定"
}

// MARK: - 预测后端抽象

public protocol WeatherPredictorBackend: Sendable {
    func generatePrediction(history: [WeatherData]) async throws -> WeatherPrediction
    func predictNextHours(history: [WeatherData], hours: Int) async -> [HourlyWeatherPrediction]
    func possibleNextTypes(currentWeather: WeatherData, history: [WeatherData]) -> [WeatherType]
    func weatherTrend(history: [WeatherData]) -> WeatherTrend
}

/// 基础规则引擎后端（向后兼容）
/// 中文说明：推荐使用 EnhancedRuleEngineBackend，此类型仅用于向后兼容
@available(*, deprecated, message: "Use EnhancedRuleEngineBackend instead")
struct RuleEngineBackend: WeatherPredictorBackend {
    private let enhanced = EnhancedRuleEngineBackend()
    
    init() {
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "RuleEngineBackend",
                replacement: "EnhancedRuleEngineBackend"
            )
        }
    }
    
    func generatePrediction(history: [WeatherData]) async throws -> WeatherPrediction {
        return try await enhanced.generatePrediction(history: history)
    }
    
    func predictNextHours(history: [WeatherData], hours: Int) async -> [HourlyWeatherPrediction] {
        return await enhanced.predictNextHours(history: history, hours: hours)
    }
    
    func possibleNextTypes(currentWeather: WeatherData, history: [WeatherData]) -> [WeatherType] {
        return enhanced.possibleNextTypes(currentWeather: currentWeather, history: history)
    }
    
    func weatherTrend(history: [WeatherData]) -> WeatherTrend {
        return enhanced.weatherTrend(history: history)
    }
}

/// CoreML 后端（向后兼容别名）
@available(*, deprecated, message: "Use CoreMLWeatherBackend instead")
struct CoreMLBackend: WeatherPredictorBackend, @unchecked Sendable {
    let model: MLModel?
    private let enhanced: WeatherPredictorBackend
    
    init(model: MLModel?) {
        self.model = model
        if #available(macOS 14.0, iOS 17.0, *) {
            DeprecationTracker.shared.recordUsage(
                api: "CoreMLBackend",
                replacement: "CoreMLWeatherBackend"
            )
            self.enhanced = CoreMLWeatherBackend(model: model)
        } else {
            self.enhanced = EnhancedRuleEngineBackend()
        }
    }
    
    func generatePrediction(history: [WeatherData]) async throws -> WeatherPrediction {
        return try await enhanced.generatePrediction(history: history)
    }
    
    func predictNextHours(history: [WeatherData], hours: Int) async -> [HourlyWeatherPrediction] {
        return await enhanced.predictNextHours(history: history, hours: hours)
    }
    
    func possibleNextTypes(currentWeather: WeatherData, history: [WeatherData]) -> [WeatherType] {
        return enhanced.possibleNextTypes(currentWeather: currentWeather, history: history)
    }
    
    func weatherTrend(history: [WeatherData]) -> WeatherTrend {
        return enhanced.weatherTrend(history: history)
    }
}
