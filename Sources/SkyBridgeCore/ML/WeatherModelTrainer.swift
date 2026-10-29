import Foundation
import CoreML
import os.log

// MARK: - 天气模型管理
// Swift 6.2.1 最佳实践：CoreML 模型管理和版本控制

/// 天气训练记录
///
/// 用于记录和导出天气历史数据，供外部训练工具使用
public struct WeatherTrainingRecord: Sendable, Codable {
 // 输入特征
    public let temperature: Double
    public let humidity: Double
    public let pressure: Double
    public let windSpeed: Double
    public let windDirection: Double
    public let cloudCoverage: Double
    public let visibility: Double
    public let uvIndex: Double
    public let hourOfDay: Int
    public let month: Int
    public let temperatureTrend: Double
    public let pressureTrend: Double
    public let humidityTrend: Double

 // 目标标签
    public let targetWeatherType: String
    public let targetTemperature: Double
    public let targetHumidity: Double

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
        month: Int,
        temperatureTrend: Double,
        pressureTrend: Double,
        humidityTrend: Double,
        targetWeatherType: String,
        targetTemperature: Double,
        targetHumidity: Double
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
        self.month = month
        self.temperatureTrend = temperatureTrend
        self.pressureTrend = pressureTrend
        self.humidityTrend = humidityTrend
        self.targetWeatherType = targetWeatherType
        self.targetTemperature = targetTemperature
        self.targetHumidity = targetHumidity
    }
}

// MARK: - 训练数据导出器

/// 训练数据导出器
///
/// 将历史天气数据导出为可用于训练的格式
@available(macOS 14.0, *)
public final class WeatherTrainingDataExporter: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "TrainingDataExporter")

    public init() {}

 /// 从历史天气数据生成训练记录
    public func generateTrainingRecords(from history: [WeatherData]) -> [WeatherTrainingRecord] {
        guard history.count >= 12 else {
            logger.warning("历史数据不足，至少需要 12 条记录")
            return []
        }

        var records: [WeatherTrainingRecord] = []

 // 使用滑动窗口生成训练样本
        for i in 6..<history.count {
            let window = Array(history[max(0, i-6)..<i])
            let target = history[i]

 // 计算趋势
            let tempTrend = calculateTrend(values: window.map { $0.temperature })
            let pressureTrend = calculateTrend(values: window.map { $0.pressure })
            let humidityTrend = calculateTrend(values: window.map { $0.humidity })

 // 当前条件
            let current = window.last!

            let record = WeatherTrainingRecord(
                temperature: current.temperature,
                humidity: current.humidity,
                pressure: current.pressure,
                windSpeed: current.windSpeed,
                windDirection: current.windDirection,
                cloudCoverage: current.cloudCoverage,
                visibility: current.visibility,
                uvIndex: current.uvIndex,
                hourOfDay: Calendar.current.component(.hour, from: current.timestamp),
                month: Calendar.current.component(.month, from: current.timestamp),
                temperatureTrend: tempTrend,
                pressureTrend: pressureTrend,
                humidityTrend: humidityTrend,
                targetWeatherType: target.weatherType.rawValue,
                targetTemperature: target.temperature,
                targetHumidity: target.humidity
            )

            records.append(record)
        }

        logger.info("生成 \(records.count) 条训练记录")
        return records
    }

 /// 导出为 JSON 格式（供 Python/Create ML 使用）
    public func exportToJSON(_ records: [WeatherTrainingRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(records)
        try data.write(to: url)

        logger.info("导出 \(records.count) 条记录到 \(url.path)")
    }

 /// 导出为 CSV 格式
    public func exportToCSV(_ records: [WeatherTrainingRecord], to url: URL) throws {
        var csv = "temperature,humidity,pressure,windSpeed,windDirection,cloudCoverage,visibility,uvIndex,hourOfDay,month,temperatureTrend,pressureTrend,humidityTrend,targetWeatherType,targetTemperature,targetHumidity\n"

        for record in records {
            csv += "\(record.temperature),\(record.humidity),\(record.pressure),\(record.windSpeed),\(record.windDirection),\(record.cloudCoverage),\(record.visibility),\(record.uvIndex),\(record.hourOfDay),\(record.month),\(record.temperatureTrend),\(record.pressureTrend),\(record.humidityTrend),\(record.targetWeatherType),\(record.targetTemperature),\(record.targetHumidity)\n"
        }

        try csv.write(to: url, atomically: true, encoding: .utf8)

        logger.info("导出 \(records.count) 条记录到 CSV: \(url.path)")
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

// MARK: - 模型状态

/// 模型状态
public enum ModelStatus: Sendable {
    case notLoaded
    case loading
    case loaded
    case usingFallback
    case error(String)
}

// MARK: - 训练错误

/// 训练错误类型
public enum TrainingError: Error, Sendable {
    case insufficientData(String)
    case invalidDataFormat(String)
    case trainingFailed(String)
    case exportFailed(String)
}

// MARK: - 模型管理器

/// 天气模型管理器
///
/// 管理 CoreML 模型的加载、更新和版本控制
@available(macOS 14.0, *)
@MainActor
public final class WeatherModelManager: ObservableObject {

 // MARK: - Singleton

    public static let shared = WeatherModelManager()

 // MARK: - Published Properties

    @Published public private(set) var currentModel: MLModel?
    @Published public private(set) var modelVersion: String = "N/A"
    @Published public private(set) var modelStatus: ModelStatus = .notLoaded
    @Published public private(set) var lastUpdateDate: Date?

 // MARK: - Properties

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "WeatherModelManager")
    private let modelFileName = "WeatherPredictionModel.mlmodelc"

 // MARK: - Initialization

    private init() {
        Task {
            await loadDefaultModel()
        }
    }

 // MARK: - Public Methods

 /// 加载默认模型
    public func loadDefaultModel() async {
        modelStatus = .loading

 // 尝试从 Bundle 加载
        if let bundleURL = Bundle.main.url(forResource: "WeatherPredictionModel", withExtension: "mlmodelc") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine

                currentModel = try MLModel(contentsOf: bundleURL, configuration: config)
                modelVersion = "Bundle 1.0"
                modelStatus = .loaded
                logger.info("✅ 从 Bundle 加载天气模型成功")
                return
            } catch {
                logger.warning("从 Bundle 加载失败: \(error.localizedDescription)")
            }
        }

 // 尝试从 App Support 加载用户训练的模型
        if let appSupportURL = getAppSupportURL() {
            let modelURL = appSupportURL.appendingPathComponent(modelFileName)
            if FileManager.default.fileExists(atPath: modelURL.path) {
                do {
                    let config = MLModelConfiguration()
                    config.computeUnits = .cpuAndNeuralEngine

                    currentModel = try MLModel(contentsOf: modelURL, configuration: config)
                    modelVersion = "Custom 1.0"
                    modelStatus = .loaded
                    lastUpdateDate = try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.modificationDate] as? Date
                    logger.info("✅ 从 App Support 加载自定义模型成功")
                    return
                } catch {
                    logger.warning("从 App Support 加载失败: \(error.localizedDescription)")
                }
            }
        }

 // 无模型可用，使用规则引擎
        modelStatus = .usingFallback
        logger.info("ℹ️ 未找到 CoreML 模型，使用增强规则引擎作为降级方案")
    }

 /// 安装新模型
    public func installModel(from url: URL) async throws {
        modelStatus = .loading

 // 编译模型
        let compiledURL = try await MLModel.compileModel(at: url)

 // 复制到 App Support
        guard let appSupportURL = getAppSupportURL() else {
            throw TrainingError.exportFailed("无法访问 App Support 目录")
        }

        let destURL = appSupportURL.appendingPathComponent(modelFileName)

 // 删除旧模型
        try? FileManager.default.removeItem(at: destURL)

 // 复制新模型
        try FileManager.default.copyItem(at: compiledURL, to: destURL)

 // 重新加载
        await loadDefaultModel()

        logger.info("✅ 新模型安装成功")
    }

 /// 卸载当前模型（回退到规则引擎）
    public func uninstallModel() async {
        currentModel = nil
        modelVersion = "N/A"
        modelStatus = .usingFallback

 // 删除本地模型文件
        if let appSupportURL = getAppSupportURL() {
            let modelURL = appSupportURL.appendingPathComponent(modelFileName)
            try? FileManager.default.removeItem(at: modelURL)
        }

        logger.info("已卸载 CoreML 模型，使用规则引擎")
    }

 /// 检查模型更新
    public func checkForUpdates() async -> Bool {
 // 这里可以添加从远程服务器检查更新的逻辑
 // 当前返回 false 表示无更新
        return false
    }

 /// 获取模型元数据
    public func getModelMetadata() -> [String: String] {
        guard let model = currentModel else {
            return ["status": "未加载", "backend": "EnhancedRuleEngine"]
        }

        var metadata: [String: String] = [
            "status": "已加载",
            "version": modelVersion,
            "backend": "CoreML"
        ]

        if let lastUpdate = lastUpdateDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            metadata["lastUpdate"] = formatter.string(from: lastUpdate)
        }

 // 获取模型描述
        let description = model.modelDescription
        metadata["author"] = description.metadata[MLModelMetadataKey.author] as? String ?? "未知"
        metadata["description"] = description.metadata[MLModelMetadataKey.description] as? String ?? ""

        return metadata
    }

 // MARK: - Private Helpers

    private func getAppSupportURL() -> URL? {
        let fileManager = FileManager.default
        guard let appSupport = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }

        let appDir = appSupport.appendingPathComponent("SkyBridgeCompass")

 // 确保目录存在
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)

        return appDir
    }
}

// MARK: - 便捷扩展

@available(macOS 14.0, *)
public extension WeatherModelManager {
 /// 获取当前使用的预测后端
    var currentBackend: any WeatherPredictorBackend {
        if let model = currentModel {
            return CoreMLWeatherBackend(model: model)
        }
        return EnhancedRuleEngineBackend()
    }

 /// 模型是否可用
    var isModelAvailable: Bool {
        currentModel != nil
    }

 /// 后端描述
    var backendDescription: String {
        switch modelStatus {
        case .loaded:
            return "CoreML (\(modelVersion))"
        case .usingFallback:
            return "增强规则引擎（气象学算法）"
        case .loading:
            return "加载中..."
        case .notLoaded:
            return "未加载"
        case .error(let msg):
            return "错误: \(msg)"
        }
    }
}

// MARK: - Create ML 训练脚本说明

/*
 ## 使用 Create ML 训练天气预测模型

 ### 步骤 1: 导出训练数据

 ```swift
 let exporter = WeatherTrainingDataExporter()
 let records = exporter.generateTrainingRecords(from: historyData)
 try exporter.exportToJSON(records, to: URL(fileURLWithPath: "weather_training_data.json"))
 ```

 ### 步骤 2: 使用 Create ML App 或 Python 脚本训练

 **Create ML App:**
 1. 打开 Xcode -> Create ML
 2. 创建新的 Tabular Classifier
 3. 导入 JSON/CSV 数据
 4. 设置 "targetWeatherType" 为目标列
 5. 选择特征列
 6. 训练并导出为 .mlmodel

 **Python + coremltools:**
 ```python
 import coremltools as ct
 from sklearn.ensemble import RandomForestClassifier
 import pandas as pd

 # 加载数据
 df = pd.read_json('weather_training_data.json')

 # 准备特征和标签
 features = ['temperature', 'humidity', 'pressure', 'windSpeed',
             'cloudCoverage', 'temperatureTrend', 'pressureTrend']
 X = df[features]
 y = df['targetWeatherType']

 # 训练模型
 clf = RandomForestClassifier(n_estimators=100)
 clf.fit(X, y)

 # 转换为 CoreML
 model = ct.converters.sklearn.convert(clf, features, 'weatherType')
 model.save('WeatherPredictionModel.mlmodel')
 ```

 ### 步骤 3: 安装模型到应用

 ```swift
 let modelURL = URL(fileURLWithPath: "path/to/WeatherPredictionModel.mlmodel")
 try await WeatherModelManager.shared.installModel(from: modelURL)
 ```

 ### 推荐的数据来源

 1. **OpenWeatherMap API** - https://openweathermap.org/api
    - 提供历史天气数据 API
    - 免费套餐每天 1000 次调用

 2. **NOAA 公开数据集** - https://www.noaa.gov/weather
    - 美国国家海洋和大气管理局
    - 提供高质量的历史气象数据

 3. **Apple WeatherKit** - https://developer.apple.com/weatherkit/
    - 与 iOS/macOS 原生集成
    - 需要 Apple Developer 会员

 */
