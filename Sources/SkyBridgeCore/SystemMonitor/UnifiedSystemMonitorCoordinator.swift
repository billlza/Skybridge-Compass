// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import SwiftUI
import Combine
import os.log

/// 统一系统监控协调器 - 解决多定时器冲突和性能问题
/// 按照Apple 2025年最佳实践设计，避免UI卡顿
@available(macOS 14.0, *)
@MainActor
public final class UnifiedSystemMonitorCoordinator: ObservableObject {
    
 // MARK: - 发布属性
    
    @Published public private(set) var isMonitoring: Bool = false
    @Published public private(set) var lastUpdateTime: Date = Date()
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "UnifiedSystemMonitorCoordinator")
    
 /// 主监控定时器 - 统一调度所有监控任务
    private var masterTimer: Timer?
    
 /// 监控组件引用
    private weak var systemMonitorManager: SystemMonitorManager?
    private weak var thermalManager: ThermalManager?
    private weak var fanSpeedMonitor: FanSpeedMonitor?
    private weak var networkStatsManager: NetworkStatsManager?
    
 /// 更新计数器 - 用于错开不同监控任务的执行时机
    private var updateCounter: Int = 0
    
 /// 配置参数 - 根据用户要求优化更新频率，避免卡顿
    private let baseInterval: TimeInterval = 1.0  // 基础间隔1秒
    private let cpuUpdateFrequency = 5    // CPU使用率每5秒更新（避免卡顿）
    private let memoryUpdateFrequency = 3 // 内存每3秒更新（用户要求）
    private let thermalUpdateFrequency = 3 // 温度每3秒更新
    private let fanUpdateFrequency = 5    // 风扇每5秒更新（用户要求）
    private let networkUpdateFrequency = 2 // 网络每2秒更新
    
 /// 性能监控
    private var performanceMetrics = CoordinatorPerformanceMetrics()
    
 // MARK: - 单例
    
    public static let shared = UnifiedSystemMonitorCoordinator()
    
    private init() {
        logger.info("🎯 统一系统监控协调器已初始化")
    }
    
 // MARK: - 公共方法
    
 /// 注册监控组件
    public func registerComponents(
        systemMonitor: SystemMonitorManager,
        thermalManager: ThermalManager,
        fanSpeedMonitor: FanSpeedMonitor,
        networkStatsManager: NetworkStatsManager
    ) {
        self.systemMonitorManager = systemMonitor
        self.thermalManager = thermalManager
        self.fanSpeedMonitor = fanSpeedMonitor
        self.networkStatsManager = networkStatsManager
        
        logger.info("📋 监控组件已注册")
    }
    
 /// 开始统一监控
    public func startUnifiedMonitoring() {
        guard !isMonitoring else {
            logger.warning("⚠️ 监控已在运行中")
            return
        }
        
        logger.info("🚀 开始统一系统监控")
        isMonitoring = true
        updateCounter = 0
        
 // 停止所有组件的独立定时器
        stopIndividualTimers()
        
 // 启动统一的主定时器
        masterTimer = Timer.scheduledTimer(withTimeInterval: baseInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.coordinatedUpdate()
            }
        }
        
 // 立即执行一次更新
        Task {
            await coordinatedUpdate()
        }
    }
    
 /// 停止统一监控
    public func stopUnifiedMonitoring() {
        guard isMonitoring else { return }
        
        logger.info("🛑 停止统一系统监控")
        isMonitoring = false
        
        masterTimer?.invalidate()
        masterTimer = nil
        
 // 恢复各组件的独立监控（如果需要）
        restoreIndividualTimers()
    }
    
 /// 强制刷新所有数据
    public func forceRefreshAll() async {
        logger.info("🔄 强制刷新所有监控数据")
        
 // 并发执行所有更新，但使用适当的延迟避免冲突
        async let cpuUpdate: Void = updateCPUMetrics()
        async let memoryUpdate: Void = updateMemoryMetrics()
        async let thermalUpdate: Void = updateThermalMetrics()
        async let fanUpdate: Void = updateFanMetrics()
        async let networkUpdate: Void = updateNetworkMetrics()
        
 // 等待所有更新完成
        await cpuUpdate
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms延迟
        await memoryUpdate
        try? await Task.sleep(nanoseconds: 50_000_000)
        await thermalUpdate
        try? await Task.sleep(nanoseconds: 50_000_000)
        await fanUpdate
        try? await Task.sleep(nanoseconds: 50_000_000)
        await networkUpdate
        
        lastUpdateTime = Date()
    }
    
 // MARK: - 私有方法
    
 /// 协调更新 - 核心调度逻辑
    private func coordinatedUpdate() async {
        let startTime = CFAbsoluteTimeGetCurrent()
        updateCounter += 1
        
 // 根据更新频率决定哪些组件需要更新
        var updateTasks: [() async -> Void] = []
        
 // CPU监控 - 每秒更新
        if updateCounter % cpuUpdateFrequency == 0 {
            updateTasks.append(updateCPUMetrics)
        }
        
 // 内存监控 - 每2秒更新
        if updateCounter % memoryUpdateFrequency == 0 {
            updateTasks.append(updateMemoryMetrics)
        }
        
 // 温度监控 - 每3秒更新
        if updateCounter % thermalUpdateFrequency == 0 {
            updateTasks.append(updateThermalMetrics)
        }
        
 // 风扇监控 - 每4秒更新
        if updateCounter % fanUpdateFrequency == 0 {
            updateTasks.append(updateFanMetrics)
        }
        
 // 网络监控 - 每2秒更新，但错开时机
        if (updateCounter + 1) % networkUpdateFrequency == 0 {
            updateTasks.append(updateNetworkMetrics)
        }
        
 // 顺序执行更新任务，避免并发冲突
        for updateTask in updateTasks {
            await updateTask()
 // 在每个任务之间添加小延迟，避免CPU峰值
            try? await Task.sleep(nanoseconds: 25_000_000) // 25ms
        }
        
 // 更新性能指标
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        performanceMetrics.recordUpdateTime(executionTime)
        
        lastUpdateTime = Date()
        
 // 每60秒重置计数器，避免溢出
        if updateCounter >= 60 {
            updateCounter = 0
        }
        
 // 性能监控 - 如果执行时间过长，记录警告
        if executionTime > 0.1 {
            logger.warning("⚠️ 监控更新耗时过长: \(String(format: "%.3f", executionTime))秒")
        }
    }
    
 /// 更新CPU指标
    private func updateCPUMetrics() async {
        await systemMonitorManager?.updateCPUAndNetworkMetricsAsync()
    }
    
 /// 更新内存指标
    private func updateMemoryMetrics() async {
        await systemMonitorManager?.updateMemoryMetricsAsync()
    }
    
 /// 更新温度指标
    private func updateThermalMetrics() async {
        await thermalManager?.forceUpdateThermalStatus()
    }
    
 /// 更新风扇指标
    private func updateFanMetrics() async {
        await fanSpeedMonitor?.forceUpdate()
    }
    
 /// 更新网络指标
    private func updateNetworkMetrics() async {
 // NetworkStatsManager会自动更新，无需手动调用
 // 这里可以添加其他网络相关的更新逻辑
    }
    
 /// 停止各组件的独立定时器
    private func stopIndividualTimers() {
        systemMonitorManager?.stopMonitoring()
        thermalManager?.stopThermalMonitoring()
        fanSpeedMonitor?.stopMonitoring()
        networkStatsManager?.stopNetworkMonitoring()
        networkStatsManager?.stopStatsCollection()
        
        logger.info("⏹️ 已停止所有独立定时器")
    }
    
 /// 恢复各组件的独立定时器
    private func restoreIndividualTimers() {
 // 如果需要，可以在这里恢复各组件的独立监控
 // 但通常不建议这样做，应该始终使用统一协调器
        logger.info("🔄 独立定时器恢复逻辑（当前为空实现）")
    }
}

// MARK: - 性能指标

/// 协调器性能指标记录器
private struct CoordinatorPerformanceMetrics {
    private var updateTimes: [TimeInterval] = []
    private let maxRecords = 100
    
    mutating func recordUpdateTime(_ time: TimeInterval) {
        updateTimes.append(time)
        if updateTimes.count > maxRecords {
            updateTimes.removeFirst()
        }
    }
    
    var averageUpdateTime: TimeInterval {
        guard !updateTimes.isEmpty else { return 0 }
        return updateTimes.reduce(0, +) / Double(updateTimes.count)
    }
    
    var maxUpdateTime: TimeInterval {
        return updateTimes.max() ?? 0
    }
}
#endif
