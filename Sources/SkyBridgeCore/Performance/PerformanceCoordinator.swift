import Foundation
import Metal
import os.log

// 导入性能管理组件
// 注意：这些类型在同一个模块中，不需要额外导入
// ThermalState 在 ThermalManager.swift 中定义，同一模块内可直接访问

/// 性能协调器 - 统一管理所有性能优化组件
@available(macOS 14.0, *)
@MainActor
public class PerformanceCoordinator: ObservableObject {
    
 // MARK: - 发布属性
    
    @Published public private(set) var overallPerformanceState: OverallPerformanceState = .optimal
    @Published public private(set) var currentOptimizations: [OptimizationType] = []
    @Published public private(set) var performanceMetrics: PerformanceMetrics = PerformanceMetrics()
    @Published public private(set) var isOptimizationActive: Bool = false
    
 // MARK: - 性能管理组件
    
    private let thermalManager: ThermalManager
    private let powerManager: PowerManager
    private let appleSiliconOptimizer: AppleSiliconOptimizer
    private let metalPerformanceOptimizer: MetalPerformanceOptimizer
    private let metalFXProcessor: MetalFXProcessor?
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "PerformanceCoordinator")
    private var coordinationTimer: Timer?
    private var lastOptimizationTime: Date = Date()
    
 /// 性能协调间隔和冷却期配置
    private let performanceUpdateInterval: TimeInterval = 10.0  // 增加到10秒
    private let optimizationCooldownPeriod: TimeInterval = 30.0 // 增加到30秒
    
 // 回调函数
    private var performanceStateChangeCallback: ((OverallPerformanceState) -> Void)?
    private var optimizationAppliedCallback: (([OptimizationType]) -> Void)?
    
 // MARK: - 初始化
    
    public init(device: MTLDevice) {
 // 初始化性能管理组件
        self.thermalManager = ThermalManager()
        self.powerManager = PowerManager()
        
 // 根据系统版本初始化 AppleSiliconOptimizer
        self.appleSiliconOptimizer = AppleSiliconOptimizer.shared
        
        self.metalPerformanceOptimizer = MetalPerformanceOptimizer(device: device)
        
 // 尝试初始化MetalFX处理器
        do {
            self.metalFXProcessor = try MetalFXProcessor(device: device)
        } catch {
            self.metalFXProcessor = nil
            logger.warning("⚠️ MetalFX处理器初始化失败: \(error.localizedDescription)")
        }
        
        setupPerformanceCoordination()
        logger.info("🎯 性能协调器初始化完成")
    }
    
 // MARK: - 公共方法
    
 /// 开始性能协调
    public func startPerformanceCoordination() {
 // 启动各个组件的监控
        thermalManager.startThermalMonitoring()
        powerManager.startPowerMonitoring()
        
 // 启动协调定时器
        coordinationTimer = Timer.scheduledTimer(withTimeInterval: performanceUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.coordinatePerformance()
            }
        }
        
        isOptimizationActive = true
        logger.info("🚀 性能协调已启动")
    }
    
 /// 停止性能协调
    public func stopPerformanceCoordination() {
 // 停止各个组件的监控
        thermalManager.stopThermalMonitoring()
        powerManager.stopPowerMonitoring()
        
 // 停止协调定时器
        coordinationTimer?.invalidate()
        coordinationTimer = nil
        
        isOptimizationActive = false
        logger.info("🛑 性能协调已停止")
    }
    
 /// 设置性能状态变化回调
    public func setPerformanceStateChangeCallback(_ callback: @escaping (OverallPerformanceState) -> Void) {
        performanceStateChangeCallback = callback
    }
    
 /// 设置优化应用回调
    public func setOptimizationAppliedCallback(_ callback: @escaping ([OptimizationType]) -> Void) {
        optimizationAppliedCallback = callback
    }
    
 /// 手动触发性能优化
    public func triggerPerformanceOptimization() async {
        await coordinatePerformance()
    }
    
 /// 获取当前性能建议
    public func getCurrentPerformanceRecommendations() -> [PerformanceRecommendation] {
        var recommendations: [PerformanceRecommendation] = []
        
 // 热量相关建议
        let thermalAdjustment = thermalManager.getRecommendedPerformanceAdjustment()
        if thermalAdjustment.renderScale < 1.0 {
            recommendations.append(.reduceThermalLoad)
        }
        
 // 电源相关建议
        let powerOptimization = powerManager.getRecommendedPowerOptimization()
        if powerOptimization.cpuThrottling > 0 {
            recommendations.append(.enablePowerSaving)
        }
        
 // 电池相关建议
        let batteryRecommendations = powerManager.getPowerEfficiencyRecommendations()
        if batteryRecommendations.contains(PowerEfficiencyRecommendation.enableLowPowerMode) {
            recommendations.append(.enableLowPowerMode)
        }
        
 // Metal性能建议
        let metalStats = metalPerformanceOptimizer.getPerformanceStats()
        if metalStats.averageFrameTime > 16.67 { // 低于60fps
            recommendations.append(.optimizeRendering)
        }
        
        return recommendations
    }
    
 /// 获取详细性能报告
    public func getDetailedPerformanceReport() -> DetailedPerformanceReport {
        let thermalAdjustment = thermalManager.getRecommendedPerformanceAdjustment()
        let _ = powerManager.getRecommendedPowerOptimization() // 使用下划线忽略未使用的变量
        let metalStats = metalPerformanceOptimizer.getPerformanceStats()
        
        return DetailedPerformanceReport(
            thermalState: thermalManager.currentThermalState,
            powerState: powerManager.powerState,
            batteryLevel: powerManager.batteryLevel,
            cpuTemperature: thermalManager.currentCPUTemperature,
            gpuTemperature: thermalManager.currentGPUTemperature,
            frameRate: 1000.0 / metalStats.averageFrameTime,
            renderScale: thermalAdjustment.renderScale,
            activeOptimizations: currentOptimizations,
            overallState: overallPerformanceState,
            recommendations: getCurrentPerformanceRecommendations()
        )
    }
    
 // 当前MetalFX质量模式，用于防止重复设置
    private var currentMetalFXQuality: MetalFXQuality = .balanced
    
 /// 应用特定的性能配置
    public func applyPerformanceProfile(_ profile: PerformanceProfile) async {
        logger.info("🎯 应用性能配置: \(profile.name)")
        
 // 将PerformanceModeType转换为PerformanceMode
        let metalPerformanceMode: PerformanceMode
        switch profile.metalPerformanceMode {
        case .extreme:
            metalPerformanceMode = .highPerformance
        case .balanced:
            metalPerformanceMode = .balanced
        case .energySaving:
            metalPerformanceMode = .powerEfficient
        case .adaptive:
            metalPerformanceMode = .balanced // 自适应模式默认使用平衡模式
        }
        
 // 应用Metal性能设置
        metalPerformanceOptimizer.setPerformanceMode(metalPerformanceMode)
        metalPerformanceOptimizer.setTargetFrameRate(profile.targetFrameRate)
        
 // 应用MetalFX设置（防止重复调用）
        if let metalFX = metalFXProcessor, currentMetalFXQuality != profile.metalFXQuality {
            currentMetalFXQuality = profile.metalFXQuality
            metalFX.setQualityMode(profile.metalFXQuality) // 移除不必要的try await
        }
        
 // 更新当前优化类型
        currentOptimizations = profile.optimizations
        optimizationAppliedCallback?(currentOptimizations)
        
        logger.info("✅ 性能配置应用完成")
    }
    
 // MARK: - 私有方法
    
 /// 设置性能协调
    private func setupPerformanceCoordination() {
 // 设置热量管理器回调
        thermalManager.setThermalStateChangeCallback { [weak self] thermalState in
            Task { @MainActor in
                await self?.handleThermalStateChange(thermalState)
            }
        }
        
 // 设置电源管理器回调
        powerManager.setPowerStateChangeCallback { [weak self] powerState in
            Task { @MainActor in
                await self?.handlePowerStateChange(powerState)
            }
        }
        
        powerManager.setBatteryLevelChangeCallback { [weak self] batteryLevel in
            Task { @MainActor in
                await self?.handleBatteryLevelChange(batteryLevel)
            }
        }
    }
    
 /// 协调性能
    private func coordinatePerformance() async {
 // 检查是否在冷却期内
        let timeSinceLastOptimization = Date().timeIntervalSince(lastOptimizationTime)
        guard timeSinceLastOptimization >= optimizationCooldownPeriod else {
            logger.debug("性能协调在冷却期内，跳过此次检查。距离上次优化: \(timeSinceLastOptimization)秒")
            return
        }
        
 // 收集当前状态
        let thermalState = thermalManager.currentThermalState
        let powerState = powerManager.powerState
        let batteryLevel = powerManager.batteryLevel
        let metalStats = metalPerformanceOptimizer.getPerformanceStats()
        
 // 更新性能指标
        updatePerformanceMetrics(
            thermalState: thermalState,
            powerState: powerState,
            batteryLevel: batteryLevel,
            metalStats: metalStats
        )
        
 // 计算整体性能状态
        let newOverallState = calculateOverallPerformanceState(
            thermalState: thermalState,
            powerState: powerState,
            batteryLevel: batteryLevel,
            frameRate: 1000.0 / metalStats.averageFrameTime
        )
        
 // 检查状态是否发生变化或者是否需要强制更新
        let stateChanged = newOverallState != overallPerformanceState
        let significantChange = isSignificantStateChange(from: overallPerformanceState, to: newOverallState)
        
        if stateChanged && significantChange {
            logger.info("性能状态发生显著变化: \(self.overallPerformanceState.rawValue) -> \(newOverallState.rawValue)")
            overallPerformanceState = newOverallState
            performanceStateChangeCallback?(overallPerformanceState)
            
 // 应用相应的性能配置
            await applyOptimizationsForState(newOverallState)
            lastOptimizationTime = Date()
        } else if stateChanged {
            logger.debug("性能状态变化不显著，跳过优化: \(self.overallPerformanceState.rawValue) -> \(newOverallState.rawValue)")
        }
    }
    
 /// 判断性能状态变化是否显著，避免频繁切换
    private func isSignificantStateChange(from oldState: OverallPerformanceState, to newState: OverallPerformanceState) -> Bool {
 // 定义状态优先级
        let statePriority: [OverallPerformanceState: Int] = [
            .optimal: 0,
            .good: 1,
            .degraded: 2,
            .critical: 3
        ]
        
        let oldPriority = statePriority[oldState] ?? 0
        let newPriority = statePriority[newState] ?? 0
        
 // 只有当状态变化超过1个级别时才认为是显著变化
        return abs(newPriority - oldPriority) >= 1
    }
    
 /// 处理热量状态变化
    private func handleThermalStateChange(_ thermalState: ThermalState) async {
        logger.info("🌡️ 热量状态变化处理: \(thermalState.rawValue)")
        await coordinatePerformance()
    }
    
 /// 处理电源状态变化
    private func handlePowerStateChange(_ powerState: PowerState) async {
        logger.info("🔋 电源状态变化处理: \(powerState.rawValue)")
        await coordinatePerformance()
    }
    
 /// 处理电池电量变化
    private func handleBatteryLevelChange(_ batteryLevel: Double) async {
 // 只在电量显著变化时触发协调
        if batteryLevel <= 0.2 || batteryLevel <= 0.1 {
            await coordinatePerformance()
        }
    }
    
 /// 更新性能指标
    private func updatePerformanceMetrics(
        thermalState: ThermalState,
        powerState: PowerState,
        batteryLevel: Double,
        metalStats: PerformanceStats
    ) {
        performanceMetrics = PerformanceMetrics(
            frameRate: 1000.0 / metalStats.averageFrameTime,
            frameTime: metalStats.averageFrameTime,
            cpuUsage: metalStats.cpuUsage,
            gpuUsage: metalStats.gpuUsage,
            memoryUsage: metalStats.memoryUsage,
            thermalState: thermalState,
            powerState: powerState,
            batteryLevel: batteryLevel,
            timestamp: Date()
        )
    }
    
 /// 计算整体性能状态
    private func calculateOverallPerformanceState(
        thermalState: ThermalState,
        powerState: PowerState,
        batteryLevel: Double,
        frameRate: Double
    ) -> OverallPerformanceState {
 // 根据各种因素计算整体状态
        var score = 100
        
 // 热量因素
        switch thermalState {
        case .nominal:
            score -= 0
        case .fair:
            score -= 10
        case .serious:
            score -= 30
        case .critical:
            score -= 50
        }
        
 // 电源因素
        switch powerState {
        case .normal:
            score -= 0
        case .lowPower:
            score -= 15
        case .powerSaving:
            score -= 25
        case .critical:
            score -= 40
        case .thermalThrottling:
            score -= 35
        case .batteryOptimized:
            score -= 5
        }
        
 // 电池因素
        if batteryLevel < 0.1 {
            score -= 30
        } else if batteryLevel < 0.2 {
            score -= 15
        }
        
 // 帧率因素
        if frameRate < 30 {
            score -= 25
        } else if frameRate < 45 {
            score -= 15
        } else if frameRate < 55 {
            score -= 5
        }
        
 // 根据分数确定状态
        if score >= 80 {
            return .optimal
        } else if score >= 60 {
            return .good
        } else if score >= 40 {
            return .degraded
        } else {
            return .critical
        }
    }
    
 /// 为特定状态应用优化
    private func applyOptimizationsForState(_ state: OverallPerformanceState) async {
        var optimizations: [OptimizationType] = []
        
        switch state {
        case .optimal:
 // 最佳状态，启用所有增强功能
            metalPerformanceOptimizer.setPerformanceMode(.highPerformance)
            if let metalFX = metalFXProcessor, currentMetalFXQuality != .quality {
                currentMetalFXQuality = .quality
                metalFX.setQualityMode(.quality) // 移除不必要的try await
            }
            optimizations = [.metalFXUpscaling, .highQualityRendering]
            
        case .good:
 // 良好状态，平衡性能和质量
            metalPerformanceOptimizer.setPerformanceMode(.balanced)
            if let metalFX = metalFXProcessor, currentMetalFXQuality != .balanced {
                currentMetalFXQuality = .balanced
                metalFX.setQualityMode(.balanced)
            }
            optimizations = [.metalFXUpscaling, .adaptiveQuality]
            
        case .degraded:
 // 性能下降，优先保证流畅度
            metalPerformanceOptimizer.setPerformanceMode(.powerEfficient)
            if let metalFX = metalFXProcessor, currentMetalFXQuality != .performance {
                currentMetalFXQuality = .performance
                metalFX.setQualityMode(.performance)
            }
            optimizations = [.thermalThrottling, .powerSaving, .reducedQuality]
            
        case .critical:
 // 危险状态，最大程度优化
            metalPerformanceOptimizer.setPerformanceMode(.powerEfficient)
            metalPerformanceOptimizer.setTargetFrameRate(30)
            optimizations = [.aggressiveThermalThrottling, .emergencyPowerSaving, .minimumQuality]
        }
        
        currentOptimizations = optimizations
        optimizationAppliedCallback?(optimizations)
        
        logger.info("🎯 已应用优化: \(optimizations.map { $0.rawValue }.joined(separator: ", "))")
    }
}

// MARK: - 支持类型定义

/// 整体性能状态
public enum OverallPerformanceState: String, CaseIterable {
    case optimal = "最佳"
    case good = "良好"
    case degraded = "下降"
    case critical = "危险"
    
 /// 获取状态颜色
    public var color: String {
        switch self {
        case .optimal:
            return "绿色"
        case .good:
            return "蓝色"
        case .degraded:
            return "橙色"
        case .critical:
            return "红色"
        }
    }
}

/// 优化类型
public enum OptimizationType: String, CaseIterable, Sendable {
    case metalFXUpscaling = "MetalFX超采样"
    case highQualityRendering = "高质量渲染"
    case adaptiveQuality = "自适应质量"
    case thermalThrottling = "热量节流"
    case powerSaving = "省电模式"
    case reducedQuality = "降低质量"
    case aggressiveThermalThrottling = "激进热量节流"
    case emergencyPowerSaving = "紧急省电"
    case minimumQuality = "最低质量"
}

/// 性能建议
public enum PerformanceRecommendation: String, CaseIterable {
    case reduceThermalLoad = "降低热量负载"
    case enablePowerSaving = "启用省电模式"
    case enableLowPowerMode = "启用低功耗模式"
    case optimizeRendering = "优化渲染性能"
    case reduceQuality = "降低渲染质量"
    case limitFrameRate = "限制帧率"
    case closeBackgroundApps = "关闭后台应用"
    case connectCharger = "连接充电器"
}

/// 性能指标
/// 包含系统性能的各项关键指标，针对macOS 14.0+进行优化
@available(macOS 14.0, *)
public struct PerformanceMetrics {
    public let frameRate: Double
    public let frameTime: Double
    public let cpuUsage: Float
    public let gpuUsage: Float
    public let memoryUsage: Float
    public let thermalState: ThermalState
    public let powerState: PowerState
    public let batteryLevel: Double
    public let timestamp: Date
    
    public init(
        frameRate: Double = 60.0,
        frameTime: Double = 16.67,
        cpuUsage: Float = 0.0,
        gpuUsage: Float = 0.0,
        memoryUsage: Float = 0.0,
        thermalState: ThermalState = .nominal,
        powerState: PowerState = .normal,
        batteryLevel: Double = 1.0,
        timestamp: Date = Date()
    ) {
        self.frameRate = frameRate
        self.frameTime = frameTime
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.memoryUsage = memoryUsage
        self.thermalState = thermalState
        self.powerState = powerState
        self.batteryLevel = batteryLevel
        self.timestamp = timestamp
    }
}

/// 详细性能报告
/// 提供完整的系统性能分析报告，针对macOS 14.0+进行优化
@available(macOS 14.0, *)
public struct DetailedPerformanceReport {
    public let thermalState: ThermalState
    public let powerState: PowerState
    public let batteryLevel: Double
    public let cpuTemperature: Double
    public let gpuTemperature: Double
    public let frameRate: Double
    public let renderScale: Float
    public let activeOptimizations: [OptimizationType]
    public let overallState: OverallPerformanceState
    public let recommendations: [PerformanceRecommendation]
}

/// 性能配置文件
public struct PerformanceProfile: Sendable {
    public let name: String
    public let metalPerformanceMode: PerformanceModeType
    public let metalFXQuality: MetalFXQuality
    public let targetFrameRate: Int
    public let optimizations: [OptimizationType]
    
 /// 预定义的性能配置
 /// 性能配置数组，标记为 nonisolated 以避免并发安全问题
    nonisolated public static let profiles: [PerformanceProfile] = [
        PerformanceProfile(
            name: "最高质量",
            metalPerformanceMode: PerformanceModeType.extreme,
            metalFXQuality: MetalFXQuality.quality,
            targetFrameRate: 60,
            optimizations: [OptimizationType.metalFXUpscaling, OptimizationType.highQualityRendering]
        ),
        PerformanceProfile(
            name: "平衡模式",
            metalPerformanceMode: PerformanceModeType.balanced,
            metalFXQuality: MetalFXQuality.balanced,
            targetFrameRate: 60,
            optimizations: [OptimizationType.metalFXUpscaling, OptimizationType.adaptiveQuality]
        ),
        PerformanceProfile(
            name: "省电模式",
            metalPerformanceMode: PerformanceModeType.energySaving,
            metalFXQuality: MetalFXQuality.performance,
            targetFrameRate: 30,
            optimizations: [OptimizationType.powerSaving, OptimizationType.reducedQuality]
        )
    ]
}