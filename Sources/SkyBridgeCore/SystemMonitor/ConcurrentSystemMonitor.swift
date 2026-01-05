//
// ConcurrentSystemMonitor.swift
// SkyBridge Compass Pro
//
// 并发系统监控器 - 解决数据竞争问题
//

import Foundation
import OSLog
import QuartzCore

/// 并发系统监控器 - 使用Actor模式确保线程安全
@available(macOS 14.0, *)
public actor ConcurrentSystemMonitor {
    
 /// 单例实例
    public static let shared = ConcurrentSystemMonitor()
    
 /// 日志记录器
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "ConcurrentSystemMonitor")
    
 /// 监控状态
    private var isMonitoring: Bool = false
    
 /// 数据缓存
    private var cachedData: [SystemMonitoringType: (data: Any, timestamp: CFTimeInterval)] = [:]
    
 /// 监控回调
    private var monitoringCallbacks: [SystemMonitoringType: @Sendable (Any) -> Void] = [:]
    
 /// 监控任务
    private var monitoringTasks: [SystemMonitoringType: Task<Void, Never>] = [:]
    
 // MARK: - 初始化
    
    private init() {
        logger.info("并发系统监控器初始化完成")
    }
    
 // MARK: - 公共方法
    
 /// 开始监控
    public func startMonitoring() async {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        
        logger.info("🚀 并发系统监控已启动 - 远程桌面优化模式")
    }
    
 /// 停止监控
    public func stopMonitoring() async {
        guard isMonitoring else { return }
        
        isMonitoring = false
        
 // 取消所有监控任务
        for (_, task) in monitoringTasks {
            task.cancel()
        }
        monitoringTasks.removeAll()
        
 // 清空缓存
        cachedData.removeAll()
        
        logger.info("🛑 并发系统监控已停止")
    }
    
 /// 注册监控回调
    public func registerCallback(for type: SystemMonitoringType, callback: @escaping @Sendable (Any) -> Void) {
        monitoringCallbacks[type] = callback
        
 // 如果已经在监控，立即启动该类型的监控
        if isMonitoring {
            Task {
                await startMonitoringForType(type)
            }
        }
    }
    
 /// 获取缓存数据
    public func getCachedData(for type: SystemMonitoringType) -> Any? {
        guard let cached = cachedData[type] else { return nil }
        
        let currentTime = CACurrentMediaTime()
        let cacheTimeout: TimeInterval = 1.0  // 默认1秒缓存超时
        
 // 检查缓存是否过期
        if currentTime - cached.timestamp > cacheTimeout {
            cachedData.removeValue(forKey: type)
            return nil
        }
        
        return cached.data
    }
    
 // MARK: - 私有方法
    
 /// 启动特定类型的监控
    private func startMonitoringForType(_ type: SystemMonitoringType) async {
 // 如果已经有监控任务在运行，先取消
        if let existingTask = monitoringTasks[type] {
            existingTask.cancel()
        }
        
 // 根据类型设置监控间隔
        let interval: TimeInterval
        switch type {
        case .cpu:
            interval = 1.5  // CPU监控间隔
        case .gpu:
            interval = 1.0  // GPU监控间隔（远程桌面优化）
        case .memory:
            interval = 4.0  // 内存监控间隔
        case .network:
            interval = 1.0  // 网络监控间隔（远程桌面优化）
        case .battery:
            interval = 15.0  // 电池监控间隔
        case .thermal:
            interval = 8.0  // 热状态监控间隔
        }
        
 // 创建监控任务
        let task = Task {
            while !Task.isCancelled {
                await self.performMonitoring(for: type)
                
 // 等待指定间隔
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        
        monitoringTasks[type] = task
        logger.info("启动\(type.rawValue)监控，间隔: \(interval)秒")
    }
    
 /// 执行特定类型的监控
    private func performMonitoring(for type: SystemMonitoringType) async {
        let startTime = CACurrentMediaTime()
        
 // 模拟数据收集（实际实现中会调用相应的系统API）
        let data = await collectDataForType(type)
        
 // 更新缓存
        cachedData[type] = (data: data, timestamp: startTime)
        
 // 调用回调
        if let callback = monitoringCallbacks[type] {
            callback(data)
        }
        
        let endTime = CACurrentMediaTime()
        let duration = endTime - startTime
        
        if duration > 0.1 {  // 如果数据收集耗时超过100ms，记录警告
            logger.warning("\(type.rawValue)数据收集耗时: \(String(format: "%.3f", duration))秒")
        }
    }
    
 /// 收集特定类型的数据
    private func collectDataForType(_ type: SystemMonitoringType) async -> Any {
        switch type {
        case .cpu:
            return CPUData(usage: Double.random(in: 0...100), cores: 8)
        case .gpu:
            return GPUData(usage: Double.random(in: 0...100), temperature: Double.random(in: 30...80))
        case .memory:
            return MemoryData(used: UInt64.random(in: 1000000000...8000000000), total: 16000000000)
        case .network:
            return NetworkData(bytesIn: UInt64.random(in: 0...1000000), bytesOut: UInt64.random(in: 0...1000000))
        case .battery:
            return BatteryData(level: Double.random(in: 0...100), isCharging: Bool.random())
        case .thermal:
            return ThermalData(state: Int.random(in: 0...3))
        }
    }
}

// MARK: - 数据结构

/// CPU数据
public struct CPUData: Sendable {
    public let usage: Double
    public let cores: Int
    
    public init(usage: Double, cores: Int) {
        self.usage = usage
        self.cores = cores
    }
}

/// GPU数据
public struct GPUData: Sendable {
    public let usage: Double
    public let temperature: Double
    
    public init(usage: Double, temperature: Double) {
        self.usage = usage
        self.temperature = temperature
    }
}

/// 内存数据
public struct MemoryData: Sendable {
    public let used: UInt64
    public let total: UInt64
    
    public var percentage: Double {
        guard total > 0 else { return 0.0 }
        return Double(used) / Double(total) * 100.0
    }
    
    public init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }
}

/// 网络数据
public struct NetworkData: Sendable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    
    public init(bytesIn: UInt64, bytesOut: UInt64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// 电池数据
public struct BatteryData: Sendable {
    public let level: Double
    public let isCharging: Bool
    
    public init(level: Double, isCharging: Bool) {
        self.level = level
        self.isCharging = isCharging
    }
}

/// 热状态数据
public struct ThermalData: Sendable {
    public let state: Int
    
    public init(state: Int) {
        self.state = state
    }
}

/// 监控类型枚举
public enum SystemMonitoringType: String, CaseIterable {
    case cpu = "cpu"
    case gpu = "gpu"
    case memory = "memory"
    case network = "network"
    case battery = "battery"
    case thermal = "thermal"
}