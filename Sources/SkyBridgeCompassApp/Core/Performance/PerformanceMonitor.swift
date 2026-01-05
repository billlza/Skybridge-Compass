//
// PerformanceMonitor.swift
// SkyBridgeCompassApp
//
// 性能监控器 - 实时收集和分析系统性能指标
// 使用 Swift 6.2 并发特性进行高效监控
//

import Foundation
import Metal
import OSLog
import IOKit
import IOKit.ps
@preconcurrency import SkyBridgeCore

/// 性能监控器 - 实时收集系统性能指标
@available(macOS 14.0, *)
@MainActor
@Observable
public final class PerformanceMonitor: Sendable {
    
 // MARK: - 属性
    
 /// 日志记录器
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "PerformanceMonitor")
    
 /// 是否正在监控
    public private(set) var isMonitoring: Bool = false
    
 /// 当前性能指标
    public private(set) var currentMetrics: PerformanceMetrics = PerformanceMetrics()
    
 /// 历史性能数据
    public private(set) var metricsHistory: [PerformanceMetrics] = []
    
 /// 性能警告
    public private(set) var performanceWarnings: [PerformanceWarning] = []
    
 /// 监控任务
    private var monitoringTask: Task<Void, Never>?
    
 /// 监控间隔（秒）
    private let monitoringInterval: TimeInterval = 1.0
    
 /// 历史数据最大保留数量
    private let maxHistoryCount: Int = 300 // 5分钟的数据（每秒一次）
    
 /// Metal 设备
    private let metalDevice: MTLDevice?
    
 /// 系统信息收集器
    private let systemInfoCollector: SystemInfoCollector
    
 /// 单例实例
    public static let shared = PerformanceMonitor()
    
 // MARK: - 初始化
    
 /// 初始化性能监控器
    public init() {
        self.metalDevice = MTLCreateSystemDefaultDevice()
        self.systemInfoCollector = SystemInfoCollector()
        
        logger.info("性能监控器初始化完成")
    }
    
 // MARK: - 公共方法
    
 /// 开始监控
    public func startMonitoring() {
        guard !isMonitoring else {
            logger.warning("性能监控已在运行")
            return
        }
        
        isMonitoring = true
        
        monitoringTask = Task { [weak self] in
            await self?.performMonitoring()
        }
        
        logger.info("开始性能监控")
    }
    
 /// 停止监控
    public func stopMonitoring() {
        guard isMonitoring else {
            logger.warning("性能监控未在运行")
            return
        }
        
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
        
        logger.info("停止性能监控")
    }
    
 /// 获取性能摘要
    public func getPerformanceSummary() -> PerformanceSummary {
        guard !metricsHistory.isEmpty else {
            return PerformanceSummary()
        }
        
        let recentMetrics = Array(metricsHistory.suffix(60)) // 最近1分钟的数据
        
        let avgCPU = recentMetrics.map { $0.cpuUsage }.reduce(0, +) / Double(recentMetrics.count)
        let avgMemory = recentMetrics.map { $0.memoryUsage }.reduce(0, +) / Double(recentMetrics.count)
        let avgGPU = recentMetrics.map { $0.gpuUsage }.reduce(0, +) / Double(recentMetrics.count)
        let avgFPS = recentMetrics.map { $0.fps }.reduce(0, +) / Double(recentMetrics.count)
        
        let maxCPU = recentMetrics.map { $0.cpuUsage }.max() ?? 0
        let maxMemory = recentMetrics.map { $0.memoryUsage }.max() ?? 0
        let maxGPU = recentMetrics.map { $0.gpuUsage }.max() ?? 0
        let maxFPS = recentMetrics.map { $0.fps }.max() ?? 0
        
        return PerformanceSummary(
            averageCPU: avgCPU,
            averageMemory: avgMemory,
            averageGPU: avgGPU,
            averageFPS: avgFPS,
            peakCPU: maxCPU,
            peakMemory: maxMemory,
            peakGPU: maxGPU,
            peakFPS: maxFPS,
            warningCount: performanceWarnings.count
        )
    }
    
 /// 清除历史数据
    public func clearHistory() {
        metricsHistory.removeAll()
        performanceWarnings.removeAll()
        logger.info("性能监控历史数据已清除")
    }
    
 /// 导出性能数据
    public func exportPerformanceData() -> Data? {
        let exportData = PerformanceExportData(
            metrics: metricsHistory,
            warnings: performanceWarnings,
            summary: getPerformanceSummary(),
            exportDate: Date()
        )
        
        do {
            return try JSONEncoder().encode(exportData)
        } catch {
            logger.error("导出性能数据失败: \(error)")
            return nil
        }
    }
    
 // MARK: - 私有方法
    
 /// 执行监控循环
    private func performMonitoring() async {
        while isMonitoring && !Task.isCancelled {
            do {
 // 收集性能指标
                let metrics = await collectPerformanceMetrics()
                
 // 更新当前指标
                await MainActor.run {
                    self.currentMetrics = metrics
                    self.addMetricsToHistory(metrics)
                    self.checkForPerformanceWarnings(metrics)
                }
                
 // 等待下一次监控
                try await Task.sleep(nanoseconds: UInt64(monitoringInterval * 1_000_000_000))
                
            } catch {
                if !Task.isCancelled {
                    logger.error("性能监控错误: \(error)")
                }
                break
            }
        }
    }
    
 /// 收集性能指标
    private func collectPerformanceMetrics() async -> PerformanceMetrics {
 // 使用并发系统监控器获取数据，避免数据竞争
 // 类已经标记为 @available(macOS 14.0, *)，无需额外检查
        let concurrentMonitor = ConcurrentSystemMonitor.shared
        
 // 从缓存获取数据，避免重复系统调用
        async let cpuData = concurrentMonitor.getCachedData(for: .cpu)
        async let memoryData = concurrentMonitor.getCachedData(for: .memory)
        async let gpuData = concurrentMonitor.getCachedData(for: .gpu)
        async let thermalData = concurrentMonitor.getCachedData(for: .thermal)
        async let batteryData = concurrentMonitor.getCachedData(for: .battery)
        async let networkData = concurrentMonitor.getCachedData(for: .network)
        
        let cpu = await cpuData as? CPUData
        let memory = await memoryData as? MemoryData
        let gpu = await gpuData as? GPUData
        let thermal = await thermalData as? ThermalData
        let battery = await batteryData as? BatteryData
        let network = await networkData as? NetworkData
        
        return PerformanceMetrics(
            timestamp: Date(),
            cpuUsage: cpu?.usage ?? 0.0,
            memoryUsage: memory?.usage ?? 0.0,
            gpuUsage: gpu?.usage ?? 0.0,
            thermalState: thermal?.state ?? 0,
            batteryLevel: battery?.level ?? 100.0,
            batteryIsCharging: battery?.isCharging ?? true,
            networkBytesIn: network?.bytesIn ?? 0,
            networkBytesOut: network?.bytesOut ?? 0,
            fps: 0.0 // 需要从渲染引擎获取
        )
    }
    
 /// 添加指标到历史记录
    private func addMetricsToHistory(_ metrics: PerformanceMetrics) {
        metricsHistory.append(metrics)
        
 // 限制历史记录数量
        if metricsHistory.count > maxHistoryCount {
            metricsHistory.removeFirst(metricsHistory.count - maxHistoryCount)
        }
    }
    
 /// 检查性能警告
    private func checkForPerformanceWarnings(_ metrics: PerformanceMetrics) {
        var warnings: [PerformanceWarning] = []
        
 // CPU使用率检查
        if metrics.cpuUsage > 80.0 {
            let warning = PerformanceWarning(
                type: .highCPUUsage,
                message: "CPU使用率过高: \(String(format: "%.1f", metrics.cpuUsage))%",
                severity: metrics.cpuUsage > 90.0 ? .critical : .warning,
                timestamp: metrics.timestamp
            )
            warnings.append(warning)
            
 // 创建性能错误并处理
            let error = PerformanceError(
                type: .cpuOverload,
                message: "CPU使用率过高: \(String(format: "%.1f", metrics.cpuUsage))%",
                severity: metrics.cpuUsage > 90.0 ? .critical : .warning,
                context: ["cpuUsage": String(metrics.cpuUsage)]
            )
            Task {
                await PerformanceErrorHandler.shared.handleError(error)
            }
        }
        
 // 内存使用率检查
        if metrics.memoryUsage > 75.0 {
            let warning = PerformanceWarning(
                type: .highMemoryUsage,
                message: "内存使用率过高: \(String(format: "%.1f", metrics.memoryUsage))%",
                severity: metrics.memoryUsage > 85.0 ? .critical : .warning,
                timestamp: metrics.timestamp
            )
            warnings.append(warning)
            
 // 创建性能错误并处理
            let error = PerformanceError(
                type: .memoryPressure,
                message: "内存使用率过高: \(String(format: "%.1f", metrics.memoryUsage))%",
                severity: metrics.memoryUsage > 85.0 ? .critical : .warning,
                context: ["memoryUsage": String(metrics.memoryUsage)]
            )
            Task {
                await PerformanceErrorHandler.shared.handleError(error)
            }
        }
        
 // GPU使用率检查
        if metrics.gpuUsage > 85.0 {
            let warning = PerformanceWarning(
                type: .highGPUUsage,
                message: "GPU使用率过高: \(String(format: "%.1f", metrics.gpuUsage))%",
                severity: metrics.gpuUsage > 95.0 ? .critical : .warning,
                timestamp: metrics.timestamp
            )
            warnings.append(warning)
            
 // 创建性能错误并处理
            let error = PerformanceError(
                type: .gpuError,
                message: "GPU使用率过高: \(String(format: "%.1f", metrics.gpuUsage))%",
                severity: metrics.gpuUsage > 95.0 ? .critical : .warning,
                context: ["gpuUsage": String(metrics.gpuUsage)]
            )
            Task {
                await PerformanceErrorHandler.shared.handleError(error)
            }
        }
        
 // 热状态检查
        if metrics.thermalState >= 3 {
            let warning = PerformanceWarning(
                type: .thermalThrottling,
                message: "系统过热，可能影响性能",
                severity: .critical,
                timestamp: metrics.timestamp
            )
            warnings.append(warning)
            
 // 创建性能错误并处理
            let error = PerformanceError(
                type: .thermalThrottling,
                message: "系统温度过高，热状态: \(metrics.thermalState)",
                severity: .critical,
                context: ["thermalState": String(metrics.thermalState)]
            )
            Task {
                await PerformanceErrorHandler.shared.handleError(error)
            }
        }
        
 // 电池电量检查
        if metrics.batteryLevel < 20.0 && !metrics.batteryIsCharging {
            let warning = PerformanceWarning(
                type: .lowBattery,
                message: "电池电量低: \(String(format: "%.0f", metrics.batteryLevel))%",
                severity: metrics.batteryLevel < 10.0 ? .critical : .warning,
                timestamp: metrics.timestamp
            )
            warnings.append(warning)
            
 // 创建性能错误并处理
            let error = PerformanceError(
                type: .batteryLow,
                message: "电池电量低: \(String(format: "%.0f", metrics.batteryLevel))%",
                severity: metrics.batteryLevel < 10.0 ? .critical : .warning,
                context: ["batteryLevel": String(metrics.batteryLevel)]
            )
            Task {
                await PerformanceErrorHandler.shared.handleError(error)
            }
        }
        
 // 添加新警告
        for warning in warnings {
            if !performanceWarnings.contains(where: { $0.type == warning.type && 
                abs($0.timestamp.timeIntervalSince(warning.timestamp)) < 60 }) {
                performanceWarnings.append(warning)
                logger.warning("性能警告: \(warning.message)")
            }
        }
        
 // 清理过期警告（超过5分钟）
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        performanceWarnings.removeAll { $0.timestamp < fiveMinutesAgo }
    }
}

// MARK: - 系统信息收集器

/// 系统信息收集器 - 收集各种系统性能指标
public final class SystemInfoCollector: Sendable {
    
 /// 获取 CPU 使用率
    public func getCPUUsage() async -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
 // 这里需要更复杂的 CPU 使用率计算
 // 简化版本，实际应该使用 host_processor_info
            return Double(info.resident_size) / Double(1024 * 1024) // 临时使用内存作为指标
        }
        
        return 0.0
    }
    
 /// 获取内存使用率
    public func getMemoryUsage() async -> Double {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let usedMemory = Double(info.resident_size)
            return (usedMemory / Double(physicalMemory)) * 100.0
        }
        
        return 0.0
    }
    
 /// 获取 GPU 使用率
    public func getGPUUsage(device: MTLDevice?) async -> Double {
 // 使用新的GPU使用率监控器获取真实数据
        if #available(macOS 14.0, *) {
            let gpuMonitor = GPUUsageMonitor()
            return await gpuMonitor.getCurrentGPUUsage()
        } else {
 // 对于较旧的macOS版本，返回估算值
            return 0.0
        }
    }
    
 /// 获取热状态
    public func getThermalState() async -> Int {
        return ProcessInfo.processInfo.thermalState.rawValue
    }
    
 /// 获取电池信息
    public func getBatteryInfo() async -> BatteryInfo {
 // 使用 IOKit 获取电池信息
        let powerSources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let powerSourcesList = IOPSCopyPowerSourcesList(powerSources)?.takeRetainedValue() as? [CFTypeRef]
        
        guard let sources = powerSourcesList, !sources.isEmpty else {
            return BatteryInfo(level: 100.0, isCharging: true)
        }
        
        for source in sources {
            let sourceInfo = IOPSGetPowerSourceDescription(powerSources, source)?.takeUnretainedValue() as? [String: Any]
            
            if let info = sourceInfo,
               let capacity = info[kIOPSCurrentCapacityKey] as? Int,
               let isCharging = info[kIOPSIsChargingKey] as? Bool {
                return BatteryInfo(level: Double(capacity), isCharging: isCharging)
            }
        }
        
        return BatteryInfo(level: 100.0, isCharging: true)
    }
    
 /// 获取网络统计
    public func getNetworkStats() async -> NetworkStats {
 // 简化版本，实际应该使用系统 API 获取网络统计
        return NetworkStats(bytesIn: 0, bytesOut: 0)
    }
}

// MARK: - 数据结构

/// 性能指标
public struct PerformanceMetrics: Codable, Sendable {
    public let timestamp: Date
    public let cpuUsage: Double
    public let memoryUsage: Double
    public let gpuUsage: Double
    public let thermalState: Int
    public let batteryLevel: Double
    public let batteryIsCharging: Bool
    public let networkBytesIn: UInt64
    public let networkBytesOut: UInt64
    public let fps: Double
    
    public init(
        timestamp: Date = Date(),
        cpuUsage: Double = 0.0,
        memoryUsage: Double = 0.0,
        gpuUsage: Double = 0.0,
        thermalState: Int = 0,
        batteryLevel: Double = 100.0,
        batteryIsCharging: Bool = true,
        networkBytesIn: UInt64 = 0,
        networkBytesOut: UInt64 = 0,
        fps: Double = 0.0
    ) {
        self.timestamp = timestamp
        self.cpuUsage = cpuUsage
        self.memoryUsage = memoryUsage
        self.gpuUsage = gpuUsage
        self.thermalState = thermalState
        self.batteryLevel = batteryLevel
        self.batteryIsCharging = batteryIsCharging
        self.networkBytesIn = networkBytesIn
        self.networkBytesOut = networkBytesOut
        self.fps = fps
    }
}

/// 性能警告
public struct PerformanceWarning: Codable, Sendable {
    public let type: WarningType
    public let message: String
    public let severity: Severity
    public let timestamp: Date
    
    public enum WarningType: String, Codable, Sendable {
        case highCPUUsage = "highCPUUsage"
        case highMemoryUsage = "highMemoryUsage"
        case highGPUUsage = "highGPUUsage"
        case thermalThrottling = "thermalThrottling"
        case lowBattery = "lowBattery"
        case networkIssue = "networkIssue"
    }
    
    public enum Severity: String, Codable, Sendable {
        case info = "info"
        case warning = "warning"
        case critical = "critical"
    }
}

/// 性能摘要
public struct PerformanceSummary: Codable, Sendable {
    public let averageCPU: Double
    public let averageMemory: Double
    public let averageGPU: Double
    public let averageFPS: Double
    public let peakCPU: Double
    public let peakMemory: Double
    public let peakGPU: Double
    public let peakFPS: Double
    public let warningCount: Int
    
    public init(
        averageCPU: Double = 0.0,
        averageMemory: Double = 0.0,
        averageGPU: Double = 0.0,
        averageFPS: Double = 0.0,
        peakCPU: Double = 0.0,
        peakMemory: Double = 0.0,
        peakGPU: Double = 0.0,
        peakFPS: Double = 0.0,
        warningCount: Int = 0
    ) {
        self.averageCPU = averageCPU
        self.averageMemory = averageMemory
        self.averageGPU = averageGPU
        self.averageFPS = averageFPS
        self.peakCPU = peakCPU
        self.peakMemory = peakMemory
        self.peakGPU = peakGPU
        self.peakFPS = peakFPS
        self.warningCount = warningCount
    }
}

/// 电池信息
public struct BatteryInfo: Sendable {
    public let level: Double
    public let isCharging: Bool
}

/// 网络统计
public struct NetworkStats: Sendable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64
}

/// 性能数据导出结构
public struct PerformanceExportData: Codable, Sendable {
    public let metrics: [PerformanceMetrics]
    public let warnings: [PerformanceWarning]
    public let summary: PerformanceSummary
    public let exportDate: Date
}