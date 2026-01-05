import Foundation
import SwiftUI

// MARK: - 设备管理扩展协议

/// 设备管理扩展协议
/// 为设备管理功能提供可扩展的接口，支持插件化架构和未来功能升级
@MainActor
public protocol DeviceManagementExtensible: Sendable {
 /// 扩展标识符
    var extensionId: String { get }
    
 /// 扩展名称
    var extensionName: String { get }
    
 /// 扩展版本
    var extensionVersion: String { get }
    
 /// 扩展描述
    var extensionDescription: String { get }
    
 /// 是否启用
    var isEnabled: Bool { get set }
    
 /// 初始化扩展
    func initialize() async throws
    
 /// 清理扩展资源
    func cleanup() async
}

// MARK: - 设备扫描扩展协议

/// 设备扫描扩展协议
/// 允许添加新的设备扫描类型和方法
@MainActor
public protocol DeviceScannerExtension: DeviceManagementExtensible, Sendable {
 /// 支持的设备类型
    var supportedDeviceTypes: [String] { get }
    
 /// 扫描设备
 /// - Parameter completion: 扫描完成回调，返回发现的设备列表
    func scanDevices() async throws -> [any DeviceRepresentable]
    
 /// 停止扫描
    func stopScanning() async
    
 /// 是否正在扫描
    var isScanning: Bool { get }
    
 /// 扫描配置
    var scanConfiguration: DeviceScanConfiguration { get set }
}

// MARK: - 设备连接扩展协议

/// 设备连接扩展协议
/// 允许添加新的设备连接方式和协议
@MainActor
public protocol DeviceConnectionExtension: DeviceManagementExtensible, Sendable {
 /// 支持的连接协议
    var supportedProtocols: [String] { get }
    
 /// 连接设备
 /// - Parameters:
 /// - device: 要连接的设备
 /// - options: 连接选项
 /// - Returns: 连接是否成功
    func connectDevice(_ device: any DeviceRepresentable, options: [String: Any]?) async throws -> Bool
    
 /// 断开设备连接
 /// - Parameter device: 要断开的设备
    func disconnectDevice(_ device: any DeviceRepresentable) async throws
    
 /// 获取连接状态
 /// - Parameter device: 设备
 /// - Returns: 连接状态
    func getConnectionStatus(for device: any DeviceRepresentable) -> DeviceConnectionStatus
}

// MARK: - 设备管理UI扩展协议

/// 设备管理UI扩展协议
/// 允许添加自定义的设备管理界面组件
@MainActor
public protocol DeviceManagementUIExtension: DeviceManagementExtensible, Sendable {
 /// 设置页面标签
    var settingsTabTitle: String { get }
    
 /// 设置页面图标
    var settingsTabIcon: String { get }
    
 /// 创建设置视图
 /// - Returns: 设置视图
    @ViewBuilder func createSettingsView() -> AnyView
    
 /// 创建设备详情视图
 /// - Parameter device: 设备对象
 /// - Returns: 设备详情视图
    @ViewBuilder func createDeviceDetailView(for device: any DeviceRepresentable) -> AnyView?
    
 /// 创建设备操作按钮
 /// - Parameter device: 设备对象
 /// - Returns: 操作按钮视图
    @ViewBuilder func createDeviceActionButtons(for device: any DeviceRepresentable) -> AnyView?
}

// MARK: - 设备数据处理扩展协议

/// 设备数据处理扩展协议
/// 负责处理设备数据的转换、过滤和分析
@MainActor
public protocol DeviceDataProcessorExtension: DeviceManagementExtensible, Sendable {
 /// 支持的数据类型
    var supportedDataTypes: [String] { get }
    
 /// 处理设备数据
 /// - Parameters:
 /// - data: 原始数据
 /// - device: 数据来源设备
 /// - Returns: 处理后的数据
    func processDeviceData(_ data: Data, from device: any DeviceRepresentable) async throws -> ProcessedDeviceData
    
 /// 分析设备性能
 /// - Parameter device: 设备对象
 /// - Returns: 性能分析结果
    func analyzeDevicePerformance(for device: any DeviceRepresentable) async throws -> DevicePerformanceAnalysis
    
 /// 生成设备报告
 /// - Parameters:
 /// - devices: 设备列表
 /// - timeRange: 时间范围
 /// - Returns: 设备报告
    func generateDeviceReport(for devices: [any DeviceRepresentable], timeRange: DateInterval) async throws -> DeviceReport
}

// MARK: - 设备安全扩展协议

/// 设备安全扩展协议
/// 负责设备安全检查和验证
@MainActor
public protocol DeviceSecurityExtension: DeviceManagementExtensible, Sendable {
 /// 安全检查设备
 /// - Parameter device: 要检查的设备
 /// - Returns: 安全检查结果
    func performSecurityCheck(on device: any DeviceRepresentable) async throws -> DeviceSecurityResult
    
 /// 验证设备身份
 /// - Parameter device: 要验证的设备
 /// - Returns: 身份验证结果
    func verifyDeviceIdentity(_ device: any DeviceRepresentable) async throws -> Bool
    
 /// 加密设备通信
 /// - Parameters:
 /// - data: 要加密的数据
 /// - device: 目标设备
 /// - Returns: 加密后的数据
    func encryptCommunication(_ data: Data, for device: any DeviceRepresentable) async throws -> Data
    
 /// 解密设备通信
 /// - Parameters:
 /// - encryptedData: 加密的数据
 /// - device: 源设备
 /// - Returns: 解密后的数据
    func decryptCommunication(_ encryptedData: Data, from device: any DeviceRepresentable) async throws -> Data
}

// MARK: - 支持数据结构

/// 设备扫描配置
public struct DeviceScanConfiguration {
 /// 扫描间隔（秒）
    public var scanInterval: TimeInterval
    
 /// 扫描超时（秒）
    public var scanTimeout: TimeInterval
    
 /// 是否包含隐藏设备
    public var includeHiddenDevices: Bool
    
 /// 信号强度阈值
    public var signalStrengthThreshold: Double
    
 /// 自定义参数
    public var customParameters: [String: Any]
    
    public init(
        scanInterval: TimeInterval = 5.0,
        scanTimeout: TimeInterval = 30.0,
        includeHiddenDevices: Bool = false,
        signalStrengthThreshold: Double = -80.0,
        customParameters: [String: Any] = [:]
    ) {
        self.scanInterval = scanInterval
        self.scanTimeout = scanTimeout
        self.includeHiddenDevices = includeHiddenDevices
        self.signalStrengthThreshold = signalStrengthThreshold
        self.customParameters = customParameters
    }
}

/// 设备连接状态
public enum DeviceConnectionStatus {
    case disconnected
    case connecting
    case connected
    case failed(Error)
    case unknown
    
    public var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

/// 处理后的设备数据
public struct ProcessedDeviceData {
 /// 数据类型
    public let dataType: String
    
 /// 处理时间
    public let processedAt: Date
    
 /// 原始数据大小
    public let originalSize: Int
    
 /// 处理后数据
    public let processedData: Data
    
 /// 元数据
    public let metadata: [String: Any]
    
    public init(
        dataType: String,
        processedAt: Date = Date(),
        originalSize: Int,
        processedData: Data,
        metadata: [String: Any] = [:]
    ) {
        self.dataType = dataType
        self.processedAt = processedAt
        self.originalSize = originalSize
        self.processedData = processedData
        self.metadata = metadata
    }
}

/// 设备性能分析结果
public struct DevicePerformanceAnalysis {
 /// 分析时间
    public let analyzedAt: Date
    
 /// CPU使用率
    public let cpuUsage: Double?
    
 /// 内存使用率
    public let memoryUsage: Double?
    
 /// 网络延迟
    public let networkLatency: TimeInterval?
    
 /// 信号质量评分
    public let signalQualityScore: Double?
    
 /// 性能建议
    public let recommendations: [String]
    
 /// 详细指标
    public let detailedMetrics: [String: Any]
    
    public init(
        analyzedAt: Date = Date(),
        cpuUsage: Double? = nil,
        memoryUsage: Double? = nil,
        networkLatency: TimeInterval? = nil,
        signalQualityScore: Double? = nil,
        recommendations: [String] = [],
        detailedMetrics: [String: Any] = [:]
    ) {
        self.analyzedAt = analyzedAt
        self.cpuUsage = cpuUsage
        self.memoryUsage = memoryUsage
        self.networkLatency = networkLatency
        self.signalQualityScore = signalQualityScore
        self.recommendations = recommendations
        self.detailedMetrics = detailedMetrics
    }
}

/// 设备报告
public struct DeviceReport {
 /// 报告生成时间
    public let generatedAt: Date
    
 /// 报告时间范围
    public let timeRange: DateInterval
    
 /// 设备数量统计
    public let deviceCounts: [String: Int]
    
 /// 连接统计
    public let connectionStats: DeviceConnectionStats
    
 /// 性能摘要
    public let performanceSummary: DevicePerformanceSummary
    
 /// 详细数据
    public let detailedData: [String: Any]
    
    public init(
        generatedAt: Date = Date(),
        timeRange: DateInterval,
        deviceCounts: [String: Int],
        connectionStats: DeviceConnectionStats,
        performanceSummary: DevicePerformanceSummary,
        detailedData: [String: Any] = [:]
    ) {
        self.generatedAt = generatedAt
        self.timeRange = timeRange
        self.deviceCounts = deviceCounts
        self.connectionStats = connectionStats
        self.performanceSummary = performanceSummary
        self.detailedData = detailedData
    }
}

/// 设备连接统计
public struct DeviceConnectionStats {
 /// 总连接次数
    public let totalConnections: Int
    
 /// 成功连接次数
    public let successfulConnections: Int
    
 /// 失败连接次数
    public let failedConnections: Int
    
 /// 平均连接时间
    public let averageConnectionTime: TimeInterval
    
 /// 连接成功率
    public var connectionSuccessRate: Double {
        guard totalConnections > 0 else { return 0.0 }
        return Double(successfulConnections) / Double(totalConnections)
    }
    
    public init(
        totalConnections: Int,
        successfulConnections: Int,
        failedConnections: Int,
        averageConnectionTime: TimeInterval
    ) {
        self.totalConnections = totalConnections
        self.successfulConnections = successfulConnections
        self.failedConnections = failedConnections
        self.averageConnectionTime = averageConnectionTime
    }
}

/// 设备性能摘要
public struct DevicePerformanceSummary {
 /// 平均信号强度
    public let averageSignalStrength: Double
    
 /// 平均响应时间
    public let averageResponseTime: TimeInterval
    
 /// 稳定性评分
    public let stabilityScore: Double
    
 /// 性能趋势
    public let performanceTrend: PerformanceTrend
    
    public init(
        averageSignalStrength: Double,
        averageResponseTime: TimeInterval,
        stabilityScore: Double,
        performanceTrend: PerformanceTrend
    ) {
        self.averageSignalStrength = averageSignalStrength
        self.averageResponseTime = averageResponseTime
        self.stabilityScore = stabilityScore
        self.performanceTrend = performanceTrend
    }
}

/// 性能趋势
public enum PerformanceTrend {
    case improving
    case stable
    case declining
    case unknown
}

/// 设备安全检查结果
public struct DeviceSecurityResult {
 /// 检查时间
    public let checkedAt: Date
    
 /// 安全等级
    public let securityLevel: ProtocolDeviceSecurityLevel
    
 /// 发现的威胁
    public let threats: [SecurityThreat]
    
 /// 安全建议
    public let recommendations: [String]
    
 /// 是否安全
    public var isSecure: Bool {
        return securityLevel == .high && threats.isEmpty
    }
    
    public init(
        checkedAt: Date = Date(),
        securityLevel: ProtocolDeviceSecurityLevel,
        threats: [SecurityThreat] = [],
        recommendations: [String] = []
    ) {
        self.checkedAt = checkedAt
        self.securityLevel = securityLevel
        self.threats = threats
        self.recommendations = recommendations
    }
}

/// 设备安全等级（协议专用）
public enum ProtocolDeviceSecurityLevel {
    case high
    case medium
    case low
    case critical
}

/// 安全威胁
public struct SecurityThreat {
 /// 威胁类型
    public let type: String
    
 /// 威胁描述
    public let description: String
    
 /// 严重程度
    public let severity: ThreatSeverity
    
 /// 发现时间
    public let discoveredAt: Date
    
    public init(
        type: String,
        description: String,
        severity: ThreatSeverity,
        discoveredAt: Date = Date()
    ) {
        self.type = type
        self.description = description
        self.severity = severity
        self.discoveredAt = discoveredAt
    }
}

/// 威胁严重程度
public enum ThreatSeverity {
    case low
    case medium
    case high
    case critical
}

// MARK: - 设备表示协议

/// 设备表示协议
/// 为所有设备类型提供统一的接口
public protocol DeviceRepresentable: Identifiable, Sendable {
 /// 设备唯一标识符
    var id: String { get }
    
 /// 设备名称
    var name: String { get }
    
 /// 设备类型
    var deviceType: String { get }
    
 /// 是否在线
    var isOnline: Bool { get }
    
 /// 是否已连接
    var isConnected: Bool { get }
    
 /// 信号强度（如果适用）
    var signalStrength: Double? { get }
    
 /// 最后发现时间
    var lastSeen: Date { get }
    
 /// 设备元数据
    var metadata: [String: Any] { get }
}