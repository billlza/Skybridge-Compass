//
// AnomalyDetectionService.swift
// SkyBridgeCore
//
// ML 异常检测服务
// 支持 macOS 14.0+, 渐进增强支持 macOS 26.x Foundation Models
//
// 设计特点:
// - macOS 14/15: 使用基于规则的统计异常检测
// - macOS 26+: 使用 Foundation Models 本地 LLM 推理（未来）
// - 自动学习正常行为基线
// - 实时监控连接和传输模式
//

import Foundation
import OSLog

// MARK: - 异常类型

/// 异常类型
public enum AnomalyType: String, Codable, Sendable, CaseIterable {
    case unusualConnectionTime = "unusual_connection_time"
    case unusualTransferVolume = "unusual_transfer_volume"
    case unknownDevice = "unknown_device"
    case rapidConnectionAttempts = "rapid_connection_attempts"
    case suspiciousFileAccess = "suspicious_file_access"
    case abnormalBandwidthUsage = "abnormal_bandwidth_usage"
    case geolocationAnomaly = "geolocation_anomaly"
    case protocolViolation = "protocol_violation"

    public var displayName: String {
        switch self {
        case .unusualConnectionTime: return "异常连接时间"
        case .unusualTransferVolume: return "异常传输量"
        case .unknownDevice: return "未知设备"
        case .rapidConnectionAttempts: return "频繁连接尝试"
        case .suspiciousFileAccess: return "可疑文件访问"
        case .abnormalBandwidthUsage: return "异常带宽使用"
        case .geolocationAnomaly: return "地理位置异常"
        case .protocolViolation: return "协议违规"
        }
    }

    public var icon: String {
        switch self {
        case .unusualConnectionTime: return "clock.badge.exclamationmark"
        case .unusualTransferVolume: return "chart.bar.xaxis"
        case .unknownDevice: return "questionmark.circle"
        case .rapidConnectionAttempts: return "arrow.triangle.2.circlepath"
        case .suspiciousFileAccess: return "folder.badge.questionmark"
        case .abnormalBandwidthUsage: return "antenna.radiowaves.left.and.right"
        case .geolocationAnomaly: return "location.slash"
        case .protocolViolation: return "exclamationmark.shield"
        }
    }

    public var severity: AnomalySeverity {
        switch self {
        case .protocolViolation, .suspiciousFileAccess:
            return .critical
        case .unknownDevice, .rapidConnectionAttempts, .geolocationAnomaly:
            return .high
        case .unusualConnectionTime, .unusualTransferVolume:
            return .medium
        case .abnormalBandwidthUsage:
            return .low
        }
    }
}

/// 异常严重程度
public enum AnomalySeverity: Int, Codable, Sendable, Comparable {
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4

    public static func < (lhs: AnomalySeverity, rhs: AnomalySeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .critical: return "严重"
        }
    }

    public var color: String {
        switch self {
        case .low: return "gray"
        case .medium: return "yellow"
        case .high: return "orange"
        case .critical: return "red"
        }
    }
}

// MARK: - 检测到的异常

/// 检测到的异常
public struct DetectedAnomaly: Identifiable, Codable, Sendable {
    public let id: UUID
    public let type: AnomalyType
    public let severity: AnomalySeverity
    public let description: String
    public let detectedAt: Date
    public let sourceDeviceID: String?
    public let confidence: Double
    public let context: [String: String]
    public var acknowledged: Bool
    public var resolvedAt: Date?

    public init(
        type: AnomalyType,
        description: String,
        sourceDeviceID: String? = nil,
        confidence: Double,
        context: [String: String] = [:]
    ) {
        self.id = UUID()
        self.type = type
        self.severity = type.severity
        self.description = description
        self.detectedAt = Date()
        self.sourceDeviceID = sourceDeviceID
        self.confidence = min(1.0, max(0.0, confidence))
        self.context = context
        self.acknowledged = false
        self.resolvedAt = nil
    }
}

// MARK: - 检测配置

/// 异常检测配置
public struct AnomalyDetectionConfiguration: Codable, Sendable {
    /// 是否启用异常检测
    public var isEnabled: Bool

    /// 检测灵敏度 (0-1)
    public var sensitivity: Double

    /// 启用的检测类型
    public var enabledTypes: Set<AnomalyType>

    /// 学习期天数
    public var learningPeriodDays: Int

    /// 最低置信度阈值
    public var minimumConfidence: Double

    /// 是否自动阻止高危异常
    public var autoBlockCritical: Bool

    /// 历史保留天数
    public var historyRetentionDays: Int

    /// 默认配置
    public static let `default` = AnomalyDetectionConfiguration(
        isEnabled: true,
        sensitivity: 0.7,
        enabledTypes: Set(AnomalyType.allCases),
        learningPeriodDays: 7,
        minimumConfidence: 0.6,
        autoBlockCritical: false,
        historyRetentionDays: 30
    )

    public init(
        isEnabled: Bool = true,
        sensitivity: Double = 0.7,
        enabledTypes: Set<AnomalyType> = Set(AnomalyType.allCases),
        learningPeriodDays: Int = 7,
        minimumConfidence: Double = 0.6,
        autoBlockCritical: Bool = false,
        historyRetentionDays: Int = 30
    ) {
        self.isEnabled = isEnabled
        self.sensitivity = sensitivity
        self.enabledTypes = enabledTypes
        self.learningPeriodDays = learningPeriodDays
        self.minimumConfidence = minimumConfidence
        self.autoBlockCritical = autoBlockCritical
        self.historyRetentionDays = historyRetentionDays
    }
}

// MARK: - 行为基线

/// 行为基线统计
public struct BehaviorBaseline: Codable, Sendable {
    public var typicalConnectionHours: Set<Int>
    public var averageDailyTransferBytes: Double
    public var knownDeviceIDs: Set<String>
    public var averageConnectionsPerHour: Double
    public var typicalFileTypes: Set<String>
    public var lastUpdated: Date

    public static let empty = BehaviorBaseline(
        typicalConnectionHours: Set(9...18),
        averageDailyTransferBytes: 0,
        knownDeviceIDs: [],
        averageConnectionsPerHour: 0,
        typicalFileTypes: [],
        lastUpdated: Date()
    )
}

// MARK: - 异常检测服务

/// ML 异常检测服务
@MainActor
public final class AnomalyDetectionService: ObservableObject {

    // MARK: - Singleton

    public static let shared = AnomalyDetectionService()

    private static let configurationStore = CodablePersistenceStore<AnomalyDetectionConfiguration>(
        location: .protectedApplicationSupport(
            path: "AnomalyDetection/configuration.json",
            legacyUserDefaultsKey: "com.skybridge.anomaly.config"
        )
    )
    private static let baselineStore = CodablePersistenceStore<BehaviorBaseline>(
        location: .protectedApplicationSupport(
            path: "AnomalyDetection/baseline.json",
            legacyUserDefaultsKey: "com.skybridge.anomaly.baseline"
        )
    )
    private static let historyStore = CodablePersistenceStore<[DetectedAnomaly]>(
        location: .protectedApplicationSupport(
            path: "AnomalyDetection/history.json",
            legacyUserDefaultsKey: "com.skybridge.anomaly.history"
        )
    )

    // MARK: - Published Properties

    /// 检测配置
    @Published public var configuration: AnomalyDetectionConfiguration {
        didSet { saveConfiguration() }
    }

    /// 检测到的异常历史
    @Published public private(set) var anomalyHistory: [DetectedAnomaly] = []

    /// 未确认的异常数量
    @Published public private(set) var unacknowledgedCount: Int = 0

    /// 行为基线
    @Published public private(set) var baseline: BehaviorBaseline = .empty

    /// 是否处于学习模式
    @Published public private(set) var isLearning: Bool = true

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "AnomalyDetection")

    // 统计数据
    private var connectionTimestamps: [Date] = []
    private var transferVolumes: [Int64] = []

    // 回调
    public var onAnomalyDetected: ((DetectedAnomaly) -> Void)?
    public var onCriticalAnomaly: ((DetectedAnomaly) async -> Bool)?

    // MARK: - Initialization

    private init() {
        self.configuration = Self.loadConfiguration() ?? .default
        self.baseline = Self.loadBaseline() ?? .empty
        self.anomalyHistory = Self.loadHistory()

        updateUnacknowledgedCount()

        // 检查学习期
        let learningEndDate = baseline.lastUpdated.addingTimeInterval(Double(configuration.learningPeriodDays) * 86400)
        isLearning = Date() < learningEndDate

        logger.info("🔍 异常检测服务已初始化, 学习模式: \(self.isLearning)")
    }

    // MARK: - Public Methods

    /// 报告连接事件（用于学习和检测）
    public func reportConnection(
        deviceID: String,
        deviceName: String,
        isNewDevice: Bool
    ) async {
        guard configuration.isEnabled else { return }

        let now = Date()
        connectionTimestamps.append(now)

        // 学习模式下更新基线
        if isLearning {
            updateBaseline(deviceID: deviceID, connectionTime: now)
            return
        }

        // 检测未知设备
        if isNewDevice && !baseline.knownDeviceIDs.contains(deviceID) {
            if configuration.enabledTypes.contains(.unknownDevice) {
                let anomaly = DetectedAnomaly(
                    type: .unknownDevice,
                    description: "检测到新设备连接: \(deviceName)",
                    sourceDeviceID: deviceID,
                    confidence: 0.9,
                    context: ["deviceName": deviceName]
                )
                await handleAnomaly(anomaly)
            }
        }

        // 检测异常连接时间
        let hour = Calendar.current.component(.hour, from: now)
        if !baseline.typicalConnectionHours.contains(hour) {
            if configuration.enabledTypes.contains(.unusualConnectionTime) {
                let confidence = calculateTimeAnomalyConfidence(hour: hour)
                if confidence >= configuration.minimumConfidence {
                    let anomaly = DetectedAnomaly(
                        type: .unusualConnectionTime,
                        description: "在非常规时间 \(hour):00 检测到连接",
                        sourceDeviceID: deviceID,
                        confidence: confidence,
                        context: ["hour": String(hour)]
                    )
                    await handleAnomaly(anomaly)
                }
            }
        }

        // 检测频繁连接尝试
        await checkRapidConnections(deviceID: deviceID)
    }

    /// 报告传输事件
    public func reportTransfer(
        deviceID: String,
        bytesTransferred: Int64,
        fileType: String?
    ) async {
        guard configuration.isEnabled else { return }

        transferVolumes.append(bytesTransferred)

        if isLearning {
            if let fileType = fileType {
                baseline.typicalFileTypes.insert(fileType)
            }
            return
        }

        // 检测异常传输量
        let dailyTransfer = transferVolumes.suffix(1000).reduce(0, +)
        let expectedDaily = baseline.averageDailyTransferBytes

        if expectedDaily > 0 {
            let ratio = Double(dailyTransfer) / expectedDaily
            if ratio > 3.0 * configuration.sensitivity {
                if configuration.enabledTypes.contains(.unusualTransferVolume) {
                    let confidence = min(1.0, (ratio - 1.0) / 5.0)
                    let anomaly = DetectedAnomaly(
                        type: .unusualTransferVolume,
                        description: "传输量是平均值的 \(String(format: "%.1f", ratio)) 倍",
                        sourceDeviceID: deviceID,
                        confidence: confidence,
                        context: ["ratio": String(format: "%.2f", ratio)]
                    )
                    await handleAnomaly(anomaly)
                }
            }
        }

        // 检测可疑文件类型
        if let fileType = fileType, !baseline.typicalFileTypes.contains(fileType) {
            if configuration.enabledTypes.contains(.suspiciousFileAccess) {
                let anomaly = DetectedAnomaly(
                    type: .suspiciousFileAccess,
                    description: "检测到非常规文件类型访问: \(fileType)",
                    sourceDeviceID: deviceID,
                    confidence: 0.7,
                    context: ["fileType": fileType]
                )
                await handleAnomaly(anomaly)
            }
        }
    }

    /// 确认异常
    public func acknowledgeAnomaly(_ anomalyID: UUID) {
        if let index = anomalyHistory.firstIndex(where: { $0.id == anomalyID }) {
            anomalyHistory[index].acknowledged = true
            updateUnacknowledgedCount()
            saveHistory()
        }
    }

    /// 解决异常
    public func resolveAnomaly(_ anomalyID: UUID) {
        if let index = anomalyHistory.firstIndex(where: { $0.id == anomalyID }) {
            anomalyHistory[index].resolvedAt = Date()
            anomalyHistory[index].acknowledged = true
            updateUnacknowledgedCount()
            saveHistory()
        }
    }

    /// 将设备添加到已知列表
    public func trustDevice(_ deviceID: String) {
        baseline.knownDeviceIDs.insert(deviceID)
        saveBaseline()
    }

    /// 重置学习
    public func resetLearning() {
        baseline = .empty
        isLearning = true
        saveBaseline()
        logger.info("🔍 已重置学习基线")
    }

    /// 清除历史
    public func clearHistory() {
        anomalyHistory.removeAll()
        updateUnacknowledgedCount()
        saveHistory()
    }

    // MARK: - Private Methods

    private func handleAnomaly(_ anomaly: DetectedAnomaly) async {
        // 检查置信度
        guard anomaly.confidence >= configuration.minimumConfidence else { return }

        anomalyHistory.insert(anomaly, at: 0)
        updateUnacknowledgedCount()

        // 通知回调
        onAnomalyDetected?(anomaly)

        // 严重异常处理
        if anomaly.severity == .critical && configuration.autoBlockCritical {
            if let handler = onCriticalAnomaly {
                let shouldBlock = await handler(anomaly)
                if shouldBlock {
                    logger.warning("🔍 自动阻止严重异常来源: \(anomaly.sourceDeviceID ?? "unknown")")
                }
            }
        }

        // 清理旧历史
        cleanupHistory()
        saveHistory()

        logger.info("🔍 检测到异常: \(anomaly.type.displayName), 置信度: \(anomaly.confidence)")
    }

    private func checkRapidConnections(deviceID: String) async {
        // 检查最近1分钟内的连接数
        let oneMinuteAgo = Date().addingTimeInterval(-60)
        let recentConnections = connectionTimestamps.filter { $0 > oneMinuteAgo }.count

        let threshold = max(5, Int(baseline.averageConnectionsPerHour / 6 * configuration.sensitivity * 3))

        if recentConnections > threshold {
            if configuration.enabledTypes.contains(.rapidConnectionAttempts) {
                let anomaly = DetectedAnomaly(
                    type: .rapidConnectionAttempts,
                    description: "1分钟内检测到 \(recentConnections) 次连接尝试",
                    sourceDeviceID: deviceID,
                    confidence: min(1.0, Double(recentConnections) / Double(threshold * 2)),
                    context: ["count": String(recentConnections)]
                )
                await handleAnomaly(anomaly)
            }
        }
    }

    private func updateBaseline(deviceID: String, connectionTime: Date) {
        baseline.knownDeviceIDs.insert(deviceID)

        let hour = Calendar.current.component(.hour, from: connectionTime)
        baseline.typicalConnectionHours.insert(hour)

        // 更新平均连接数
        let recentCount = Double(connectionTimestamps.suffix(100).count)
        baseline.averageConnectionsPerHour = recentCount / 24

        // 更新平均传输量
        let totalTransfer = transferVolumes.suffix(1000).reduce(0, +)
        baseline.averageDailyTransferBytes = Double(totalTransfer)

        baseline.lastUpdated = Date()
        saveBaseline()
    }

    private func calculateTimeAnomalyConfidence(hour: Int) -> Double {
        // 深夜时间更可疑
        if hour >= 0 && hour < 6 {
            return 0.9 * configuration.sensitivity
        } else if hour >= 22 || hour < 8 {
            return 0.7 * configuration.sensitivity
        } else {
            return 0.5 * configuration.sensitivity
        }
    }

    private func updateUnacknowledgedCount() {
        unacknowledgedCount = anomalyHistory.filter { !$0.acknowledged }.count
    }

    private func cleanupHistory() {
        let cutoff = Date().addingTimeInterval(-Double(configuration.historyRetentionDays) * 86400)
        anomalyHistory.removeAll { $0.detectedAt < cutoff }
    }

    // MARK: - Persistence

    private func saveConfiguration() {
        try? Self.configurationStore.save(configuration)
    }

    private static func loadConfiguration() -> AnomalyDetectionConfiguration? {
        Self.configurationStore.load()
    }

    private func saveBaseline() {
        try? Self.baselineStore.save(baseline)
    }

    private static func loadBaseline() -> BehaviorBaseline? {
        Self.baselineStore.load()
    }

    private func saveHistory() {
        try? Self.historyStore.save(anomalyHistory)
    }

    private static func loadHistory() -> [DetectedAnomaly] {
        Self.historyStore.load() ?? []
    }
}
