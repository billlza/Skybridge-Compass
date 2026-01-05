import Foundation
import CoreML
import Accelerate

// MARK: - 天气预测模型框架
// Swift 6.2.1 最佳实践：为 CoreML 模型提供类型安全的包装

/// 天气预测模型输入
public struct WeatherPredictionInput: Sendable {
 // 当前气象数据
    public let temperature: Double      // 温度 (°C)
    public let humidity: Double         // 湿度 (%)
    public let pressure: Double         // 气压 (hPa)
    public let windSpeed: Double        // 风速 (m/s)
    public let windDirection: Double    // 风向 (°)
    public let cloudCoverage: Double    // 云量 (0-1)
    public let visibility: Double       // 能见度 (km)
    public let uvIndex: Double          // UV 指数
    
 // 时间特征
    public let hourOfDay: Int           // 小时 (0-23)
    public let dayOfYear: Int           // 年中天数 (1-366)
    public let month: Int               // 月份 (1-12)
    
 // 历史趋势（过去 6 小时）
    public let temperatureTrend: Double // 温度变化率
    public let pressureTrend: Double    // 气压变化率
    public let humidityTrend: Double    // 湿度变化率
    
    public init(
        temperature: Double,
        humidity: Double,
        pressure: Double,
        windSpeed: Double,
        windDirection: Double,
        cloudCoverage: Double,
        visibility: Double,
        uvIndex: Double,
        hourOfDay: Int,
        dayOfYear: Int,
        month: Int,
        temperatureTrend: Double,
        pressureTrend: Double,
        humidityTrend: Double
    ) {
        self.temperature = temperature
        self.humidity = humidity
        self.pressure = pressure
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.cloudCoverage = cloudCoverage
        self.visibility = visibility
        self.uvIndex = uvIndex
        self.hourOfDay = hourOfDay
        self.dayOfYear = dayOfYear
        self.month = month
        self.temperatureTrend = temperatureTrend
        self.pressureTrend = pressureTrend
        self.humidityTrend = humidityTrend
    }
    
 /// 从 WeatherData 创建输入
    public static func from(
        _ data: WeatherData,
        temperatureTrend: Double = 0,
        pressureTrend: Double = 0,
        humidityTrend: Double = 0
    ) -> WeatherPredictionInput {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: data.timestamp)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: data.timestamp) ?? 1
        let month = calendar.component(.month, from: data.timestamp)
        
        return WeatherPredictionInput(
            temperature: data.temperature,
            humidity: data.humidity,
            pressure: data.pressure,
            windSpeed: data.windSpeed,
            windDirection: data.windDirection,
            cloudCoverage: data.cloudCoverage,
            visibility: data.visibility,
            uvIndex: data.uvIndex,
            hourOfDay: hour,
            dayOfYear: dayOfYear,
            month: month,
            temperatureTrend: temperatureTrend,
            pressureTrend: pressureTrend,
            humidityTrend: humidityTrend
        )
    }
    
 /// 转换为 MLMultiArray（供 CoreML 使用）
    public func toMLMultiArray() throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [14], dataType: .float32)
        
        array[0] = NSNumber(value: temperature)
        array[1] = NSNumber(value: humidity)
        array[2] = NSNumber(value: pressure)
        array[3] = NSNumber(value: windSpeed)
        array[4] = NSNumber(value: windDirection)
        array[5] = NSNumber(value: cloudCoverage)
        array[6] = NSNumber(value: visibility)
        array[7] = NSNumber(value: uvIndex)
        array[8] = NSNumber(value: hourOfDay)
        array[9] = NSNumber(value: dayOfYear)
        array[10] = NSNumber(value: month)
        array[11] = NSNumber(value: temperatureTrend)
        array[12] = NSNumber(value: pressureTrend)
        array[13] = NSNumber(value: humidityTrend)
        
        return array
    }
    
 /// 归一化输入值
    public func normalized() -> WeatherPredictionInput {
        return WeatherPredictionInput(
            temperature: (temperature + 40) / 80,           // -40 to 40 -> 0 to 1
            humidity: humidity / 100,                        // 0 to 100 -> 0 to 1
            pressure: (pressure - 950) / 100,               // 950 to 1050 -> 0 to 1
            windSpeed: min(windSpeed / 50, 1),              // 0 to 50 -> 0 to 1
            windDirection: windDirection / 360,             // 0 to 360 -> 0 to 1
            cloudCoverage: cloudCoverage,                    // Already 0 to 1
            visibility: min(visibility / 50, 1),            // 0 to 50 -> 0 to 1
            uvIndex: min(uvIndex / 11, 1),                  // 0 to 11 -> 0 to 1
            hourOfDay: hourOfDay,
            dayOfYear: dayOfYear,
            month: month,
            temperatureTrend: (temperatureTrend + 5) / 10,  // -5 to 5 -> 0 to 1
            pressureTrend: (pressureTrend + 10) / 20,       // -10 to 10 -> 0 to 1
            humidityTrend: (humidityTrend + 20) / 40        // -20 to 20 -> 0 to 1
        )
    }
}

/// 天气预测模型输出
public struct WeatherPredictionOutput: Sendable {
 /// 预测的天气类型概率分布
    public let weatherTypeProbabilities: [WeatherDataService.WeatherType: Double]
    
 /// 最可能的天气类型
    public let predictedWeatherType: WeatherDataService.WeatherType
    
 /// 预测置信度
    public let confidence: Double
    
 /// 预测的温度变化
    public let temperatureChange: Double
    
 /// 预测的降水概率
    public let precipitationProbability: Double
    
    public init(
        weatherTypeProbabilities: [WeatherDataService.WeatherType: Double],
        temperatureChange: Double,
        precipitationProbability: Double
    ) {
        self.weatherTypeProbabilities = weatherTypeProbabilities
        
 // 找出最可能的天气类型
        let sorted = weatherTypeProbabilities.sorted { $0.value > $1.value }
        self.predictedWeatherType = sorted.first?.key ?? .clear
        self.confidence = sorted.first?.value ?? 0.5
        
        self.temperatureChange = temperatureChange
        self.precipitationProbability = precipitationProbability
    }
}

// MARK: - 增强型规则引擎后端

/// 增强型规则引擎后端
///
/// 使用气象学规则和统计模型进行预测
/// 当 CoreML 模型不可用时作为高质量降级方案
public struct EnhancedRuleEngineBackend: WeatherPredictorBackend, Sendable {
    
 // MARK: - 气象学常数
    
 /// 饱和水蒸气压计算（Magnus 公式）
    private func saturatedVaporPressure(temperature: Double) -> Double {
 // Magnus 公式: e_s = 6.112 * exp((17.67 * T) / (T + 243.5))
        return 6.112 * exp((17.67 * temperature) / (temperature + 243.5))
    }
    
 /// 计算露点温度
    private func dewPoint(temperature: Double, humidity: Double) -> Double {
        let es = saturatedVaporPressure(temperature: temperature)
        let e = es * humidity / 100
 // 反向 Magnus 公式
        let ln_e = log(e / 6.112)
        return (243.5 * ln_e) / (17.67 - ln_e)
    }
    
 /// 计算温度露点差（判断降水可能性）
    private func temperatureDewPointSpread(temperature: Double, humidity: Double) -> Double {
        return temperature - dewPoint(temperature: temperature, humidity: humidity)
    }
    
 // MARK: - WeatherPredictorBackend 实现
    
    public func generatePrediction(history: [WeatherData]) async throws -> WeatherPrediction {
        guard history.count >= 3 else { throw WeatherPredictionError.insufficientData }
        
        let recent = Array(history.suffix(6))
        let latest = recent.last!
        
 // 计算趋势
        let tempTrend = calculateLinearTrend(values: recent.map { $0.temperature })
        let pressureTrend = calculateLinearTrend(values: recent.map { $0.pressure })
        let humidityTrend = calculateLinearTrend(values: recent.map { $0.humidity })
        
 // 计算气象指标
        let tdSpread = temperatureDewPointSpread(temperature: latest.temperature, humidity: latest.humidity)
        
 // 计算各天气类型的概率
        var probabilities: [WeatherDataService.WeatherType: Double] = [:]
        
 // 晴天概率
        let clearProb = calculateClearProbability(
            pressure: latest.pressure,
            pressureTrend: pressureTrend,
            cloudCoverage: latest.cloudCoverage,
            humidity: latest.humidity
        )
        probabilities[.clear] = clearProb
        
 // 多云概率
        let cloudyProb = calculateCloudyProbability(
            cloudCoverage: latest.cloudCoverage,
            humidity: latest.humidity
        )
        probabilities[.cloudy] = cloudyProb
        
 // 雨天概率
        let rainProb = calculateRainProbability(
            pressure: latest.pressure,
            pressureTrend: pressureTrend,
            humidity: latest.humidity,
            humidityTrend: humidityTrend,
            tdSpread: tdSpread,
            cloudCoverage: latest.cloudCoverage
        )
        probabilities[.rain] = rainProb
        
 // 雪天概率
        let snowProb = calculateSnowProbability(
            temperature: latest.temperature,
            humidity: latest.humidity,
            precipProbability: rainProb
        )
        probabilities[.snow] = snowProb
        
 // 雷暴概率
        let thunderProb = calculateThunderstormProbability(
            temperature: latest.temperature,
            humidity: latest.humidity,
            pressure: latest.pressure,
            pressureTrend: pressureTrend
        )
        probabilities[.thunderstorm] = thunderProb
        
 // 雾霾概率
        let hazeProb = calculateHazeProbability(
            visibility: latest.visibility,
            humidity: latest.humidity,
            windSpeed: latest.windSpeed
        )
        probabilities[.haze] = hazeProb
        
 // 归一化概率
        let total = probabilities.values.reduce(0, +)
        if total > 0 {
            for (key, value) in probabilities {
                probabilities[key] = value / total
            }
        }
        
 // 找出最可能的天气类型
        let sorted = probabilities.sorted { $0.value > $1.value }
        let predicted = sorted.first?.key ?? .clear
        let confidence = sorted.first?.value ?? 0.5
        
 // 构建预测因子
        let factors: [String: String] = [
            "temperatureTrend": formatTrend(tempTrend),
            "pressureTrend": formatTrend(pressureTrend),
            "humidityTrend": formatTrend(humidityTrend),
            "dewPointSpread": String(format: "%.1f°C", tdSpread),
            "historicalDataPoints": "\(history.count)",
            "backend": "EnhancedRuleEngine"
        ]
        
        return WeatherPrediction(
            predictedWeatherType: predicted,
            confidence: confidence,
            predictionTime: Date(),
            factors: factors
        )
    }
    
    public func predictNextHours(history: [WeatherData], hours: Int) async -> [HourlyWeatherPrediction] {
        guard history.count >= 3, let latest = history.last else { return [] }
        
        let recent = Array(history.suffix(6))
        
 // 计算趋势
        let tempTrend = calculateLinearTrend(values: recent.map { $0.temperature })
        let pressureTrend = calculateLinearTrend(values: recent.map { $0.pressure })
        let humidityTrend = calculateLinearTrend(values: recent.map { $0.humidity })
        
        var predictions: [HourlyWeatherPrediction] = []
        
        for hour in 1...hours {
            let hoursAhead = Double(hour)
            
 // 使用趋势预测未来值，添加衰减因子
            let decay = exp(-0.1 * hoursAhead) // 随时间衰减
            let predictedTemp = latest.temperature + (tempTrend * hoursAhead * decay)
            let predictedHumidity = max(0, min(100, latest.humidity + (humidityTrend * hoursAhead * decay)))
            let predictedPressure = latest.pressure + (pressureTrend * hoursAhead * decay)
            
 // 确定天气类型
            let weatherType = determineWeatherType(
                temperature: predictedTemp,
                humidity: predictedHumidity,
                pressure: predictedPressure,
                pressureTrend: pressureTrend
            )
            
 // 置信度随预测时间增加而降低
            let baseConfidence = 0.85
            let confidence = baseConfidence * exp(-0.05 * hoursAhead)
            
            predictions.append(HourlyWeatherPrediction(
                hour: hour,
                weatherType: weatherType,
                temperature: predictedTemp,
                humidity: predictedHumidity,
                pressure: predictedPressure,
                confidence: confidence,
                predictionTime: Date()
            ))
        }
        
        return predictions
    }
    
    public func possibleNextTypes(currentWeather: WeatherData, history: [WeatherData]) -> [WeatherType] {
        var types: Set<WeatherType> = []
        
 // 基于当前条件确定可能的转变
        let tdSpread = temperatureDewPointSpread(temperature: currentWeather.temperature, humidity: currentWeather.humidity)
        
 // 降水条件
        if tdSpread < 3 && currentWeather.humidity > 70 {
            if currentWeather.temperature > 0 {
                types.insert(.rain)
            } else {
                types.insert(.snow)
            }
        }
        
 // 雷暴条件
        if currentWeather.temperature > 20 && currentWeather.humidity > 80 && currentWeather.cloudCoverage > 0.7 {
            types.insert(.thunderstorm)
        }
        
 // 晴天条件
        if currentWeather.pressure > 1015 && currentWeather.humidity < 60 {
            types.insert(.clear)
        }
        
 // 多云条件
        if currentWeather.cloudCoverage > 0.3 && currentWeather.cloudCoverage < 0.8 {
            types.insert(.cloudy)
        }
        
 // 雾霾条件
        if currentWeather.visibility < 5 && currentWeather.windSpeed < 3 {
            types.insert(.haze)
        }
        
 // 至少返回当前天气类型
        if types.isEmpty {
            types.insert(currentWeather.weatherType)
        }
        
        return Array(types)
    }
    
    public func weatherTrend(history: [WeatherData]) -> WeatherTrend {
        guard history.count >= 3 else { return .stable }
        
        let recent = Array(history.suffix(6))
        
        let tempTrend = calculateLinearTrend(values: recent.map { $0.temperature })
        let pressureTrend = calculateLinearTrend(values: recent.map { $0.pressure })
        let humidityTrend = calculateLinearTrend(values: recent.map { $0.humidity })
        
 // 综合评估
        var score = 0.0
        
 // 气压上升 -> 好转
        score += pressureTrend * 0.5
        
 // 湿度下降 -> 好转
        score -= humidityTrend * 0.3
        
 // 温度适度上升（白天）-> 好转
        score += min(tempTrend * 0.2, 0.2)
        
        if score > 0.1 {
            return .improving
        } else if score < -0.1 {
            return .deteriorating
        }
        return .stable
    }
    
 // MARK: - 私有方法 - 概率计算
    
    private func calculateClearProbability(
        pressure: Double,
        pressureTrend: Double,
        cloudCoverage: Double,
        humidity: Double
    ) -> Double {
        var prob = 0.0
        
 // 高气压 -> 晴天
        if pressure > 1020 { prob += 0.3 }
        else if pressure > 1015 { prob += 0.2 }
        else if pressure > 1010 { prob += 0.1 }
        
 // 气压上升 -> 晴天
        if pressureTrend > 1 { prob += 0.15 }
        else if pressureTrend > 0 { prob += 0.1 }
        
 // 低云量 -> 晴天
        prob += (1 - cloudCoverage) * 0.3
        
 // 低湿度 -> 晴天
        if humidity < 50 { prob += 0.15 }
        else if humidity < 70 { prob += 0.1 }
        
        return min(prob, 1.0)
    }
    
    private func calculateCloudyProbability(
        cloudCoverage: Double,
        humidity: Double
    ) -> Double {
        var prob = 0.0
        
 // 中等云量
        if cloudCoverage > 0.3 && cloudCoverage < 0.8 {
            prob += 0.4
        } else if cloudCoverage >= 0.8 {
            prob += 0.3
        }
        
 // 中等湿度
        if humidity > 50 && humidity < 80 {
            prob += 0.2
        }
        
        return min(prob, 1.0)
    }
    
    private func calculateRainProbability(
        pressure: Double,
        pressureTrend: Double,
        humidity: Double,
        humidityTrend: Double,
        tdSpread: Double,
        cloudCoverage: Double
    ) -> Double {
        var prob = 0.0
        
 // 低气压 -> 降水
        if pressure < 1005 { prob += 0.3 }
        else if pressure < 1010 { prob += 0.2 }
        else if pressure < 1015 { prob += 0.1 }
        
 // 气压下降 -> 降水
        if pressureTrend < -2 { prob += 0.2 }
        else if pressureTrend < 0 { prob += 0.1 }
        
 // 高湿度 -> 降水
        if humidity > 90 { prob += 0.25 }
        else if humidity > 80 { prob += 0.15 }
        else if humidity > 70 { prob += 0.1 }
        
 // 湿度上升 -> 降水
        if humidityTrend > 5 { prob += 0.1 }
        
 // 温度露点差小 -> 降水（空气接近饱和）
        if tdSpread < 2 { prob += 0.2 }
        else if tdSpread < 4 { prob += 0.1 }
        
 // 高云量 -> 降水
        if cloudCoverage > 0.8 { prob += 0.1 }
        
        return min(prob, 1.0)
    }
    
    private func calculateSnowProbability(
        temperature: Double,
        humidity: Double,
        precipProbability: Double
    ) -> Double {
 // 需要温度低于冰点且有降水可能
        guard temperature < 2 else { return 0 }
        
        var prob = precipProbability
        
 // 温度越低越可能是雪
        if temperature < -5 { prob *= 1.0 }
        else if temperature < 0 { prob *= 0.8 }
        else { prob *= 0.5 }
        
        return min(prob, 1.0)
    }
    
    private func calculateThunderstormProbability(
        temperature: Double,
        humidity: Double,
        pressure: Double,
        pressureTrend: Double
    ) -> Double {
 // 需要高温高湿
        guard temperature > 20 && humidity > 70 else { return 0 }
        
        var prob = 0.0
        
 // 高温
        if temperature > 30 { prob += 0.2 }
        else if temperature > 25 { prob += 0.15 }
        else { prob += 0.1 }
        
 // 高湿度
        if humidity > 85 { prob += 0.2 }
        else if humidity > 75 { prob += 0.1 }
        
 // 气压快速下降
        if pressureTrend < -3 { prob += 0.2 }
        else if pressureTrend < -1 { prob += 0.1 }
        
        return min(prob, 1.0)
    }
    
    private func calculateHazeProbability(
        visibility: Double,
        humidity: Double,
        windSpeed: Double
    ) -> Double {
        var prob = 0.0
        
 // 低能见度
        if visibility < 2 { prob += 0.4 }
        else if visibility < 5 { prob += 0.25 }
        else if visibility < 10 { prob += 0.1 }
        
 // 中等湿度（太高会变成雾）
        if humidity > 60 && humidity < 90 { prob += 0.15 }
        
 // 低风速（污染物不易扩散）
        if windSpeed < 2 { prob += 0.2 }
        else if windSpeed < 4 { prob += 0.1 }
        
        return min(prob, 1.0)
    }
    
 // MARK: - 私有方法 - 辅助函数
    
    private func calculateLinearTrend(values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        
        let n = Double(values.count)
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumX2 = 0.0
        
        for (i, value) in values.enumerated() {
            let x = Double(i)
            sumX += x
            sumY += value
            sumXY += x * value
            sumX2 += x * x
        }
        
        let denominator = n * sumX2 - sumX * sumX
        guard denominator != 0 else { return 0 }
        
        return (n * sumXY - sumX * sumY) / denominator
    }
    
    private func determineWeatherType(
        temperature: Double,
        humidity: Double,
        pressure: Double,
        pressureTrend: Double
    ) -> WeatherType {
        let tdSpread = temperatureDewPointSpread(temperature: temperature, humidity: humidity)
        
 // 优先判断恶劣天气
        if tdSpread < 3 && humidity > 80 {
            if temperature < 0 {
                return .snow
            }
            if temperature > 25 && pressureTrend < -2 {
                return .thunderstorm
            }
            return .rain
        }
        
        if humidity > 70 && pressure < 1010 {
            return .cloudy
        }
        
        if pressure > 1015 && humidity < 60 {
            return .clear
        }
        
        return .cloudy
    }
    
    private func formatTrend(_ value: Double) -> String {
        if value > 0.5 { return "快速上升" }
        if value > 0.1 { return "上升" }
        if value < -0.5 { return "快速下降" }
        if value < -0.1 { return "下降" }
        return "稳定"
    }
}

// MARK: - CoreML 模型包装

/// CoreML 天气预测模型包装
///
/// 当真实模型文件存在时，使用 CoreML 进行推理
/// 否则降级到增强规则引擎
@available(macOS 14.0, *)
public struct CoreMLWeatherBackend: WeatherPredictorBackend, @unchecked Sendable {
    private let model: MLModel?
    private let fallback = EnhancedRuleEngineBackend()
    
    public init(model: MLModel?) {
        self.model = model
    }
    
    public func generatePrediction(history: [WeatherData]) async throws -> WeatherPrediction {
        guard let model = model, history.count >= 3 else {
            return try await fallback.generatePrediction(history: history)
        }
        
 // 准备输入
        let recent = Array(history.suffix(6))
        let latest = recent.last!
        
        let tempTrend = calculateTrend(values: recent.map { $0.temperature })
        let pressureTrend = calculateTrend(values: recent.map { $0.pressure })
        let humidityTrend = calculateTrend(values: recent.map { $0.humidity })
        
        let input = WeatherPredictionInput.from(
            latest,
            temperatureTrend: tempTrend,
            pressureTrend: pressureTrend,
            humidityTrend: humidityTrend
        )
        
        do {
 // 创建 CoreML 输入
            let mlInput = try input.toMLMultiArray()
            
 // 创建特征提供者
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input": mlInput])
            
 // 执行预测
            let output = try await model.prediction(from: provider)
            
 // 解析输出
            if let probabilities = output.featureValue(for: "weatherTypeProbabilities")?.multiArrayValue {
                var probs: [WeatherDataService.WeatherType: Double] = [:]
                let types: [WeatherDataService.WeatherType] = [.clear, .cloudy, .rain, .snow, .thunderstorm, .haze]
                
                for (i, type) in types.enumerated() {
                    if i < probabilities.count {
                        probs[type] = probabilities[i].doubleValue
                    }
                }
                
                let sorted = probs.sorted { $0.value > $1.value }
                let predicted = sorted.first?.key ?? .clear
                let confidence = sorted.first?.value ?? 0.5
                
                return WeatherPrediction(
                    predictedWeatherType: predicted,
                    confidence: confidence,
                    predictionTime: Date(),
                    factors: [
                        "backend": "CoreML",
                        "modelVersion": "1.0",
                        "inputFeatures": "14"
                    ]
                )
            }
        } catch {
            SkyBridgeLogger.performance.error("CoreML 预测失败，降级到规则引擎: \(error.localizedDescription)")
        }
        
 // 降级到规则引擎
        return try await fallback.generatePrediction(history: history)
    }
    
    public func predictNextHours(history: [WeatherData], hours: Int) async -> [HourlyWeatherPrediction] {
 // 使用规则引擎进行多小时预测
        return await fallback.predictNextHours(history: history, hours: hours)
    }
    
    public func possibleNextTypes(currentWeather: WeatherData, history: [WeatherData]) -> [WeatherType] {
        return fallback.possibleNextTypes(currentWeather: currentWeather, history: history)
    }
    
    public func weatherTrend(history: [WeatherData]) -> WeatherTrend {
        return fallback.weatherTrend(history: history)
    }
    
    private func calculateTrend(values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        
        let n = Double(values.count)
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumX2 = 0.0
        
        for (i, value) in values.enumerated() {
            let x = Double(i)
            sumX += x
            sumY += value
            sumXY += x * value
            sumX2 += x * x
        }
        
        let denominator = n * sumX2 - sumX * sumX
        guard denominator != 0 else { return 0 }
        
        return (n * sumXY - sumX * sumY) / denominator
    }
}

