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
    private var weatherHistory: [WeatherData] = []
    private let maxHistorySize: Int = 100
    
    // 预测参数
    private let predictionInterval: TimeInterval = 300 // 5分钟预测一次
    private var predictionTimer: Timer?
    
    // MARK: - 初始化
    
    public init() throws {
        try loadMLModel()
        startPredictionTimer()
        print("✅ 天气ML预测器初始化完成")
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
        // 基于当前天气条件和历史数据，预测可能的天气变化
        var possibleTypes: [WeatherType] = []
        
        // 基于温度和湿度的简单规则
        if currentWeather.humidity > 80 && currentWeather.temperature > 15 {
            possibleTypes.append(.rain)
        }
        
        if currentWeather.temperature < 0 && currentWeather.humidity > 70 {
            possibleTypes.append(.snow)
        }
        
        if currentWeather.cloudCoverage > 0.8 && currentWeather.pressure < 1010 {
            possibleTypes.append(.thunderstorm)
        }
        
        if currentWeather.cloudCoverage < 0.3 && currentWeather.pressure > 1020 {
            possibleTypes.append(.clear)  // 使用 .clear 而不是 .sunny
        }
        
        // 如果没有明确的预测，返回当前天气类型
        if possibleTypes.isEmpty {
            possibleTypes.append(currentWeather.weatherType)
        }
        
        return possibleTypes
    }
    
    /// 获取天气变化趋势
    public func getWeatherTrend() -> WeatherTrend {
        guard weatherHistory.count >= 3 else {
            return .stable
        }
        
        let recent = Array(weatherHistory.suffix(3))
        
        // 分析温度趋势
        let temperatureTrend = analyzeTrend(values: recent.map { $0.temperature })
        
        // 分析气压趋势
        let pressureTrend = analyzeTrend(values: recent.map { $0.pressure })
        
        // 分析湿度趋势 - 修复未使用变量警告
        let _ = analyzeTrend(values: recent.map { $0.humidity })
        
        // 综合判断
        if temperatureTrend == .rising && pressureTrend == .rising {
            return .improving
        } else if temperatureTrend == .falling && pressureTrend == .falling {
            return .deteriorating
        } else {
            return .stable
        }
    }
    
    /// 预测未来N小时的天气
    public func predictWeatherForNextHours(_ hours: Int) async -> [HourlyWeatherPrediction] {
        guard let model = mlModel,
              weatherHistory.count >= 10 else {
            return []
        }
        
        var predictions: [HourlyWeatherPrediction] = []
        
        for hour in 1...hours {
            do {
                let prediction = try await predictWeatherForHour(hour, using: model)
                predictions.append(prediction)
            } catch {
                print("❌ 预测第\(hour)小时天气失败: \(error)")
                break
            }
        }
        
        return predictions
    }
    
    // MARK: - 私有方法
    
    /// 加载机器学习模型
    private func loadMLModel() throws {
        // 由于这是一个演示，我们创建一个模拟的ML模型
        // 在实际应用中，这里应该加载训练好的Core ML模型
        print("📦 加载天气预测ML模型...")
        
        // 模拟模型加载
        // let modelURL = Bundle.main.url(forResource: "WeatherPredictionModel", withExtension: "mlmodelc")
        // self.mlModel = try MLModel(contentsOf: modelURL!)
        
        // 为了演示，我们使用一个模拟模型
        self.mlModel = try createMockMLModel()
        
        print("✅ ML模型加载完成")
    }
    
    /// 创建模拟ML模型（仅用于演示）
    private func createMockMLModel() throws -> MLModel {
        // 在实际应用中，这里应该是真实的Core ML模型
        // 这里我们返回一个空的模型作为占位符
        let configuration = MLModelConfiguration()
        
        // 由于无法创建真实的ML模型，我们使用nil并在预测时使用规则引擎
        return try MLModel(contentsOf: Bundle.main.bundleURL, configuration: configuration)
    }
    
    /// 添加到历史记录
    private func addToHistory(_ weatherData: WeatherData) {
        weatherHistory.append(weatherData)
        
        // 限制历史记录大小
        if weatherHistory.count > maxHistorySize {
            weatherHistory.removeFirst()
        }
        
        print("📊 添加天气数据到历史记录，当前记录数: \(weatherHistory.count)")
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
            let prediction = try await generateWeatherPrediction()
            
            self.weatherPrediction = prediction
            self.predictionConfidence = prediction.confidence
            self.predictionStatus = .completed
            
            print("🔮 天气预测完成: \(prediction.predictedWeatherType), 置信度: \(prediction.confidence)")
            
        } catch {
            print("❌ 天气预测失败: \(error)")
            predictionStatus = .failed
        }
    }
    
    /// 生成天气预测
    private func generateWeatherPrediction() async throws -> WeatherPrediction {
        guard let model = mlModel else {
            throw WeatherPredictionError.modelNotLoaded
        }
        
        guard let latestWeather = weatherHistory.last else {
            throw WeatherPredictionError.insufficientData
        }
        
        // 模拟预测逻辑（实际应用中会使用真实的ML模型）
        let confidence = Double.random(in: 0.7...0.95)
        
        // 基于当前条件预测下一个可能的天气类型
        var predictedType: WeatherType = .clear  // 使用 .clear 而不是 .sunny
        
        if latestWeather.pressure < 1010 && latestWeather.humidity > 70 {
            predictedType = .rain
        } else if latestWeather.temperature < 0 && latestWeather.humidity > 80 {
            predictedType = .snow
        } else if latestWeather.cloudCoverage > 0.8 {
            predictedType = .cloudy
        } else if latestWeather.cloudCoverage < 0.3 && latestWeather.pressure > 1020 {
            predictedType = .clear  // 使用 .clear 而不是 .sunny
        }
        
        let factors = createPredictionFactors(
            temperatureTrend: analyzeTrend(values: weatherHistory.suffix(5).map { $0.temperature }),
            pressureTrend: analyzeTrend(values: weatherHistory.suffix(5).map { $0.pressure }),
            humidityTrend: analyzeTrend(values: weatherHistory.suffix(5).map { $0.humidity })
        )
        
        return WeatherPrediction(
            predictedWeatherType: predictedType,
            confidence: confidence,
            predictionTime: Date(),
            factors: factors
        )
    }
    
    /// 预测指定小时的天气
    private func predictWeatherForHour(_ hour: Int, using model: MLModel) async throws -> HourlyWeatherPrediction {
        guard let latestWeather = weatherHistory.last else {
            throw WeatherPredictionError.insufficientData
        }
        
        // 模拟预测逻辑
        let temperatureChange = Double.random(in: -3...3)
        let humidityChange = Double.random(in: -10...10)
        let pressureChange = Double.random(in: -5...5)
        
        let predictedTemperature = latestWeather.temperature + temperatureChange
        let predictedHumidity = max(0, min(100, latestWeather.humidity + humidityChange))
        let predictedPressure = latestWeather.pressure + pressureChange
        
        // 基于预测的条件确定天气类型
        var predictedWeatherType: WeatherType = .clear  // 使用 .clear 而不是 .sunny
        
        if predictedPressure < 1010 && predictedHumidity > 70 {
            predictedWeatherType = .rain
        } else if predictedTemperature < 0 && predictedHumidity > 80 {
            predictedWeatherType = .snow
        } else if predictedHumidity > 80 {
            predictedWeatherType = .cloudy
        } else if predictedPressure > 1020 && predictedHumidity < 50 {
            predictedWeatherType = .clear  // 使用 .clear 而不是 .sunny
        }
        
        let confidence = Double.random(in: 0.6...0.9)
        
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