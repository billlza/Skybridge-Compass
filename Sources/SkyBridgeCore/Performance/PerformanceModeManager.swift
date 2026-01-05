// PerformanceModeManager.swift
// SkyBridge Compass Pro
//
// 性能模式管理器 - 支持极致、平衡、节能和自适应四种模式
// 集成 Apple Silicon 优化和自适应性能监控
//

import Foundation
import Metal
import MetalKit
import OSLog
import CoreML
import Accelerate // Apple Silicon 向量化计算优化
import MetalPerformanceShaders // GPU 加速计算
import IOKit.ps // 添加电源管理API导入

// MARK: - 性能模式类型
public enum PerformanceModeType: String, CaseIterable, Sendable {
    case extreme = "extreme"    // 极致模式
    case balanced = "balanced"  // 平衡模式
    case energySaving = "energySaving" // 节能模式
    case adaptive = "adaptive"  // 自适应模式 - 新增
    
 /// 显示名称
    public var displayName: String {
        switch self {
        case .extreme:
            return "极致"
        case .balanced:
            return "平衡"
        case .energySaving:
            return "节能"
        case .adaptive:
            return "自适应"
        }
    }
    
 /// 图标名称
    public var iconName: String {
        switch self {
        case .extreme:
            return "bolt.fill"
        case .balanced:
            return "scale.3d"
        case .energySaving:
            return "leaf.fill"
        case .adaptive:
            return "brain.head.profile"
        }
    }
    
 /// 模式描述
    public var description: String {
        switch self {
        case .extreme:
            return "最高性能\n最大功耗"
        case .balanced:
            return "性能平衡\n适中功耗"
        case .energySaving:
            return "节约电量\n延长续航"
        case .adaptive:
            return "智能调节\n动态优化"
        }
    }
}

// MARK: - 性能配置结构
public struct PerformanceConfiguration: Codable, Sendable {
 /// 渲染缩放比例 (0.5-1.0)
    public let renderScale: Float
 /// 最大粒子数量
    public let maxParticles: Int
 /// 目标帧率
    public let targetFrameRate: Int
 /// MetalFX 质量 (0.0-1.0)
    public let metalFXQuality: Float
 /// 阴影质量等级 (0-2)
    public let shadowQuality: Int
 /// 后处理级别 (0-2)
    public let postProcessingLevel: Int
 /// GPU 频率提示 (0.0-1.0)
    public let gpuFrequencyHint: Float
 /// 内存预算 (MB)
    public let memoryBudget: Int
 /// 使用统一内存优化
    public let useUnifiedMemory: Bool
 /// 使用 Neural Engine
    public let useNeuralEngine: Bool
 /// 使用 AMX 协处理器
    public let useAMX: Bool
 /// 使用 Accelerate 框架
    public let useAccelerate: Bool
    
    public init(
        renderScale: Float,
        maxParticles: Int,
        targetFrameRate: Int,
        metalFXQuality: Float,
        shadowQuality: Int,
        postProcessingLevel: Int,
        gpuFrequencyHint: Float,
        memoryBudget: Int,
        useUnifiedMemory: Bool = true,
        useNeuralEngine: Bool = false,
        useAMX: Bool = false,
        useAccelerate: Bool = true
    ) {
        self.renderScale = renderScale
        self.maxParticles = maxParticles
        self.targetFrameRate = targetFrameRate
        self.metalFXQuality = metalFXQuality
        self.shadowQuality = shadowQuality
        self.postProcessingLevel = postProcessingLevel
        self.gpuFrequencyHint = gpuFrequencyHint
        self.memoryBudget = memoryBudget
        self.useUnifiedMemory = useUnifiedMemory
        self.useNeuralEngine = useNeuralEngine
        self.useAMX = useAMX
        self.useAccelerate = useAccelerate
    }
}

// MARK: - 性能模式管理器
@available(macOS 14.0, *)
@MainActor
public final class PerformanceModeManager: BaseManager, Sendable {
    
 /// 自适应性能监控器
    private var adaptiveMonitor: AdaptivePerformanceMonitor?
    
 /// 自适应模式是否启用
    public private(set) var isAdaptiveModeEnabled: Bool = false
    
 /// 自适应调整历史
    public private(set) var adaptiveHistory: [AdaptiveAdjustment] = []
    
 // MARK: - 公开属性
 /// 当前性能模式
    @Published public var currentMode: PerformanceModeType = .balanced
    
 /// 当前性能配置
    public private(set) var currentConfiguration: PerformanceConfiguration
    
 /// ✅ 系统性能监控器（供其他组件访问）
 /// 在初始化时创建，确保所有模式下都可用
    public private(set) var systemPerformanceMonitor: SystemPerformanceMonitor?
    
 /// Metal 设备
    private let metalDevice: MTLDevice?
    
 /// 设备性能等级
    private let devicePerformanceLevel: DevicePerformanceLevel
    
 /// Apple Silicon 特性检测器
    private let appleSiliconFeatures: AppleSiliconFeatureDetector
    
 /// 性能指标
    public private(set) var performanceMetrics: PerformanceMetrics = PerformanceMetrics()
    
 // MARK: - 单例
    public static let shared: PerformanceModeManager = {
        do {
            return try PerformanceModeManager()
        } catch {
            #if os(macOS)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "性能模式管理器初始化失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
            #endif
            return PerformanceModeManager.fallback()
        }
    }()
    
 // MARK: - 初始化
    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PerformanceModeError.metalDeviceNotAvailable
        }
        
        self.metalDevice = device
        self.devicePerformanceLevel = Self.detectDevicePerformanceLevel(device: device)
        self.appleSiliconFeatures = AppleSiliconFeatureDetector.shared
        
 // 获取默认配置
        self.currentConfiguration = Self.getConfiguration(
            for: .balanced,
            deviceLevel: self.devicePerformanceLevel,
            features: self.appleSiliconFeatures
        )
        
        super.init(category: "PerformanceModeManager")
        
 // ✅ 在初始化时创建SystemPerformanceMonitor，确保所有模式下都可用
 // 不依赖于自适应模式，让所有组件都能访问真实性能数据
        let newMonitor = SystemPerformanceMonitor()
        systemPerformanceMonitor = newMonitor
        logger.info("✅ SystemPerformanceMonitor已创建（独立于性能模式）")
        
        logger.info("性能模式管理器已初始化")
        logger.info("设备: \(device.name)")
        logger.info("性能级别: \(self.devicePerformanceLevel.rawValue)")
        
 // 加载保存的模式
        loadSavedMode()
        
 // ✅ 自动启动SystemPerformanceMonitor（延迟启动，等待CPU负载平稳）
        newMonitor.startMonitoring(afterDelay: 10.0)
        logger.info("✅ SystemPerformanceMonitor将在10秒后自动启动（等待CPU负载平稳）")
    }
    
    private init(fallbackLevel: DevicePerformanceLevel) {
        self.metalDevice = MTLCreateSystemDefaultDevice()
        self.devicePerformanceLevel = fallbackLevel
        self.appleSiliconFeatures = AppleSiliconFeatureDetector.shared
        self.currentConfiguration = Self.getConfiguration(
            for: .balanced,
            deviceLevel: self.devicePerformanceLevel,
            features: self.appleSiliconFeatures
        )
        super.init(category: "PerformanceModeManager")
        let newMonitor = SystemPerformanceMonitor()
        systemPerformanceMonitor = newMonitor
        newMonitor.startMonitoring(afterDelay: 10.0)
    }
    
    public static func fallback() -> PerformanceModeManager {
        return PerformanceModeManager(fallbackLevel: .medium)
    }
    
 // MARK: - 公开方法
 /// 切换到指定性能模式
    public func switchToMode(_ mode: PerformanceModeType) {
        logger.info("切换性能模式: \(self.currentMode.displayName) -> \(mode.displayName)")
        
        currentMode = mode
        currentConfiguration = Self.getConfiguration(
            for: mode,
            deviceLevel: devicePerformanceLevel,
            features: appleSiliconFeatures
        )
        
 // 处理自适应模式
        if mode == .adaptive {
            enableAdaptiveMode()
        } else {
            disableAdaptiveMode()
        }
        
 // 异步应用配置
        Task {
            await applyPerformanceConfiguration()
        }
        
 // 保存当前模式
        saveCurrentMode()
    }
    
 /// 启用自适应模式
    private func enableAdaptiveMode() {
        isAdaptiveModeEnabled = true
 // ✅ 自适应模式使用已存在的SystemPerformanceMonitor（在init时已创建）
 // AdaptivePerformanceMonitor的init会自动从manager获取
        adaptiveMonitor = AdaptivePerformanceMonitor(manager: self)
        adaptiveMonitor?.startMonitoring()
        logger.info("自适应模式已启用（使用真实性能监控数据）")
    }
    
 /// 禁用自适应模式
    private func disableAdaptiveMode() {
        isAdaptiveModeEnabled = false
        adaptiveMonitor?.stopMonitoring()
        adaptiveMonitor = nil
        logger.info("自适应模式已禁用")
    }
    
 /// 添加自适应调整记录
    internal func addAdaptiveAdjustment(_ adjustment: AdaptiveAdjustment) {
        adaptiveHistory.append(adjustment)
 // 保持历史记录在合理范围内
        if adaptiveHistory.count > 100 {
            adaptiveHistory.removeFirst(adaptiveHistory.count - 100)
        }
    }
    
 // MARK: - 性能配置应用
 /// 应用性能配置
    private func applyPerformanceConfiguration() async {
        logger.info("应用性能配置: \(self.currentMode.displayName)")
        
 // 应用 GPU 频率提示
        await setGPUFrequencyHint(currentConfiguration.gpuFrequencyHint)
        
 // 应用 CPU 性能优化
        await applyCPUPerformanceOptimization(currentConfiguration)
        
 // 应用系统级优化
        await configureSystemLevelOptimizations(for: currentMode, config: currentConfiguration)
    }
    
 /// 设置 GPU 频率提示
    private func setGPUFrequencyHint(_ hint: Float) async {
        logger.debug("设置 GPU 频率提示: \(hint)")
        
 // Apple Silicon GPU 优化
        if appleSiliconFeatures.isAppleSilicon {
            await optimizeAppleSiliconGPU(hint: hint)
        }
    }
    
 /// 优化 Apple Silicon GPU
    private func optimizeAppleSiliconGPU(hint: Float) async {
        logger.debug("优化 Apple Silicon GPU, 频率提示: \(hint)")
        
 // 根据频率提示调整 GPU 性能
 // 这里可以添加具体的 GPU 优化逻辑
    }
    
 /// 应用 CPU 性能优化
    private func applyCPUPerformanceOptimization(_ config: PerformanceConfiguration) async {
        logger.debug("应用 CPU 性能优化")
        
 // 设置 CPU 调度优先级
        await setCPUSchedulingPriority(for: currentMode)
        
 // 配置 CPU 核心使用
        await configureCPUCoreUsage(for: currentMode)
        
 // 配置 CPU 功耗管理
        await configureCPUPowerManagement(for: currentMode, config: config)
        
 // Apple Silicon CPU 优化
        if appleSiliconFeatures.isAppleSilicon {
            await applyAppleSiliconCPUOptimizations(for: currentMode, config: config)
        }
    }
    
 /// 设置 CPU 调度优先级
    private func setCPUSchedulingPriority(for mode: PerformanceModeType) async {
        let priority: Int32
        
        switch mode {
        case .extreme:
            priority = 47 // 高优先级
        case .balanced:
            priority = 31 // 默认优先级
        case .energySaving:
            priority = 15 // 低优先级
        case .adaptive:
            priority = 31 // 默认优先级，由自适应监控器动态调整
        }
        
 // 设置当前线程优先级
        var policy = sched_param()
        policy.sched_priority = priority
        
        let result = pthread_setschedparam(pthread_self(), SCHED_RR, &policy)
        if result == 0 {
            logger.debug("CPU 调度优先级设置成功: \(priority)")
        } else {
            logger.warning("CPU 调度优先级设置失败: \(result)")
        }
    }
    
 /// 配置 CPU 核心使用
    private func configureCPUCoreUsage(for mode: PerformanceModeType) async {
        logger.debug("配置 CPU 核心使用策略: \(mode.displayName)")
        
 // Apple Silicon 设备的性能核心和效率核心配置
        if appleSiliconFeatures.isAppleSilicon {
            await configurePerformanceAndEfficiencyCores(for: mode)
        }
    }
    
 /// 配置 CPU 功耗管理
    private func configureCPUPowerManagement(for mode: PerformanceModeType, config: PerformanceConfiguration) async {
        logger.debug("配置 CPU 功耗管理: \(mode.displayName)")
        
 // 根据模式调整功耗策略
 // 这里可以添加具体的功耗管理逻辑
    }
    
 /// 应用 Apple Silicon CPU 优化
    private func applyAppleSiliconCPUOptimizations(for mode: PerformanceModeType, config: PerformanceConfiguration) async {
 // Neural Engine 优化
        if config.useNeuralEngine && appleSiliconFeatures.supportsNeuralEngine {
            await enableNeuralEngineOptimization()
        }
        
 // AMX 协处理器优化
        if config.useAMX && appleSiliconFeatures.supportsAMX {
            await enableAMXOptimization()
        }
    }
    
 /// 配置性能核心和效率核心
    private func configurePerformanceAndEfficiencyCores(for mode: PerformanceModeType) async {
        logger.debug("配置性能核心和效率核心: \(mode.displayName)")
        
 // 根据模式调整核心使用策略
        switch mode {
        case .extreme:
 // 优先使用性能核心
            break
        case .energySaving:
 // 优先使用效率核心
            break
        default:
 // 平衡使用
            break
        }
    }
    
 /// 配置系统级优化
    private func configureSystemLevelOptimizations(for mode: PerformanceModeType, config: PerformanceConfiguration) async {
 // 热管理优化
        await configureThermalOptimizations(for: mode)
        
 // 统一内存优化
        if config.useUnifiedMemory && appleSiliconFeatures.supportsUnifiedMemory {
            await configureUnifiedMemoryOptimization(config.memoryBudget)
        }
        
 // Accelerate 框架优化
        if config.useAccelerate {
            await enableAccelerateOptimization()
        }
    }
    
 /// 配置热管理优化
    private func configureThermalOptimizations(for mode: PerformanceModeType) async {
        logger.debug("配置热管理优化: \(mode.displayName)")
        
 // 根据模式调整热管理策略
        switch mode {
        case .extreme:
 // 允许更高的热量阈值
            break
        case .energySaving:
 // 更保守的热管理
            break
        default:
 // 平衡的热管理
            break
        }
    }

 /// 配置统一内存优化
    private func configureUnifiedMemoryOptimization(_ budgetMB: Int) async {
        logger.debug("配置统一内存优化, 预算: \(budgetMB)MB")
        
 // 设置内存预算和优化策略
 // 这里可以添加具体的统一内存优化逻辑
    }
    
 /// 启用 Neural Engine 优化
    private func enableNeuralEngineOptimization() async {
        logger.debug("启用 Neural Engine 优化")
        
 // 配置 Neural Engine
        await configureNeuralEngineForCoreML()
        
 // 预热 Neural Engine
        await warmupNeuralEngine()
    }
    
 /// 启用 AMX 优化
    private func enableAMXOptimization() async {
        logger.debug("启用 AMX 协处理器优化")
        
 // 配置 AMX 矩阵运算
        await configureAMXMatrixOperations()
        
 // 预热 AMX 处理器
        await warmupAMXProcessor()
    }
    
 /// 配置 Neural Engine for CoreML
    private func configureNeuralEngineForCoreML() async {
 // 配置 CoreML 使用 Neural Engine
 // 这里可以添加具体的 Neural Engine 配置逻辑
    }
    
 /// 预热 Neural Engine
    private func warmupNeuralEngine() async {
        do {
 // 这里可以添加具体的预热逻辑
            logger.debug("Neural Engine 预热完成")
        }
    }
    
 /// 配置 AMX 矩阵运算
    private func configureAMXMatrixOperations() async {
 // 配置 AMX 协处理器进行矩阵运算优化
        logger.debug("配置 AMX 矩阵运算")
        
 // 使用 Accelerate 框架的 BLAS 函数来利用 AMX
 // 这里可以添加具体的 AMX 配置逻辑
        
 // 示例：配置矩阵乘法优化
        let matrixSize = 64
        let a = Array(repeating: Float(1.0), count: matrixSize * matrixSize)
        let b = Array(repeating: Float(1.0), count: matrixSize * matrixSize)
        var c = Array(repeating: Float(0.0), count: matrixSize * matrixSize)
        
 // ✅ macOS 14+：使用vDSP替代已弃用的cblas_sgemm
 // 对于简单的矩阵乘法，使用vDSP_mmul（支持AMX自动优化）
        vDSP_mmul(
            a, 1,          // A矩阵，步长1
            b, 1,          // B矩阵，步长1
            &c, 1,         // C矩阵（结果），步长1
            vDSP_Length(matrixSize),  // M
            vDSP_Length(matrixSize),  // N
            vDSP_Length(matrixSize)   // P
        )
    }
    
 /// 预热 AMX 处理器
    private func warmupAMXProcessor() async {
        logger.debug("预热 AMX 处理器")
        
 // 执行一些矩阵运算来预热 AMX 协处理器
        let warmupSize = 32
        let iterations = 10
        
        for _ in 0..<iterations {
            let a = Array(repeating: Float.random(in: 0...1), count: warmupSize * warmupSize)
            let b = Array(repeating: Float.random(in: 0...1), count: warmupSize * warmupSize)
            var c = Array(repeating: Float(0.0), count: warmupSize * warmupSize)
            
 // ✅ macOS 14+：使用vDSP替代已弃用的cblas_sgemm
            vDSP_mmul(
                a, 1,
                b, 1,
                &c, 1,
                vDSP_Length(warmupSize),
                vDSP_Length(warmupSize),
                vDSP_Length(warmupSize)
            )
        }
        
        logger.debug("AMX 处理器预热完成")
    }

 /// 启用 Accelerate 优化
    private func enableAccelerateOptimization() async {
        logger.debug("启用 Accelerate 框架优化")
        
 // 配置 Accelerate 框架的向量化计算优化
 // 这里可以添加具体的 Accelerate 优化逻辑
    }
    
 // MARK: - 配置获取
 /// 获取指定模式的配置
    private static func getConfiguration(
        for mode: PerformanceModeType,
        deviceLevel: DevicePerformanceLevel,
        features: AppleSiliconFeatureDetector
    ) -> PerformanceConfiguration {
        let baseConfig = getDefaultConfiguration(for: mode, deviceLevel: deviceLevel)
        
 // 应用 Apple Silicon 优化
        return applyAppleSiliconOptimizations(to: baseConfig, mode: mode, features: features)
    }
    
 /// 应用 Apple Silicon 优化到配置
    private static func applyAppleSiliconOptimizations(
        to config: PerformanceConfiguration, 
        mode: PerformanceModeType,
        features: AppleSiliconFeatureDetector
    ) -> PerformanceConfiguration {
 // 如果不是 Apple Silicon，返回原配置
        guard features.isAppleSilicon else { return config }
        
 // 根据 Apple Silicon 特性调整配置
        return PerformanceConfiguration(
            renderScale: config.renderScale,
            maxParticles: config.maxParticles,
            targetFrameRate: config.targetFrameRate,
            metalFXQuality: config.metalFXQuality,
            shadowQuality: config.shadowQuality,
            postProcessingLevel: config.postProcessingLevel,
            gpuFrequencyHint: config.gpuFrequencyHint,
            memoryBudget: config.memoryBudget,
            useUnifiedMemory: features.supportsUnifiedMemory,
            useNeuralEngine: features.supportsNeuralEngine && (mode == .extreme || mode == .adaptive),
            useAMX: features.supportsAMX && (mode == .extreme || mode == .balanced || mode == .adaptive),
            useAccelerate: true // 总是启用 Accelerate
        )
    }
    
 /// 获取默认配置
    private static func getDefaultConfiguration(for mode: PerformanceModeType, deviceLevel: DevicePerformanceLevel) -> PerformanceConfiguration {
        switch mode {
        case .extreme:
            switch deviceLevel {
            case .high:
                return PerformanceConfiguration(
                    renderScale: 1.0,
                    maxParticles: 15000,  // 增加粒子数量
                    targetFrameRate: 120, // 调整为120fps，匹配自适应刷新率
                    metalFXQuality: 1.0,
                    shadowQuality: 2,
                    postProcessingLevel: 2,
                    gpuFrequencyHint: 1.0,
                    memoryBudget: 3072    // 增加内存预算
                )
            case .medium:
                return PerformanceConfiguration(
                    renderScale: 1.0,     // 提升渲染缩放
                    maxParticles: 12000,  // 增加粒子数量
                    targetFrameRate: 120, // 提升到120fps
                    metalFXQuality: 1.0,  // 提升MetalFX质量
                    shadowQuality: 2,
                    postProcessingLevel: 2, // 提升后处理级别
                    gpuFrequencyHint: 1.0,  // 最大GPU频率
                    memoryBudget: 2048    // 增加内存预算
                )
 // 移除了对低性能设备(Intel Mac)的支持
            }
        case .balanced:
            switch deviceLevel {
            case .high:
                return PerformanceConfiguration(
                    renderScale: 0.8,
                    maxParticles: 5000,
                    targetFrameRate: 60,
                    metalFXQuality: 0.7,
                    shadowQuality: 1,
                    postProcessingLevel: 1,
                    gpuFrequencyHint: 0.7,
                    memoryBudget: 1024
                )
            case .medium:
                return PerformanceConfiguration(
                    renderScale: 0.7,
                    maxParticles: 3000,
                    targetFrameRate: 60,
                    metalFXQuality: 0.6,
                    shadowQuality: 1,
                    postProcessingLevel: 1,
                    gpuFrequencyHint: 0.6,
                    memoryBudget: 768
                )
 // 移除了对低性能设备(Intel Mac)的支持
            }
        case .energySaving:
            switch deviceLevel {
            case .high:
                return PerformanceConfiguration(
                    renderScale: 0.6,
                    maxParticles: 2000,
                    targetFrameRate: 30,
                    metalFXQuality: 0.4,
                    shadowQuality: 0,
                    postProcessingLevel: 0,
                    gpuFrequencyHint: 0.4,
                    memoryBudget: 512
                )
            case .medium:
                return PerformanceConfiguration(
                    renderScale: 0.5,
                    maxParticles: 1000,
                    targetFrameRate: 30,
                    metalFXQuality: 0.3,
                    shadowQuality: 0,
                    postProcessingLevel: 0,
                    gpuFrequencyHint: 0.3,
                    memoryBudget: 384
                )
 // 移除了对低性能设备(Intel Mac)的支持
            }
        case .adaptive:
 // 自适应模式使用平衡模式的基础配置
            return getDefaultConfiguration(for: .balanced, deviceLevel: deviceLevel)
        }
    }
    
 /// 检测设备性能等级
    private static func detectDevicePerformanceLevel(device: MTLDevice) -> DevicePerformanceLevel {
 // 专为 Apple Silicon 设备优化
        let deviceName = device.name.lowercased()
        
 // 检测 Apple Silicon 芯片类型
        if deviceName.contains("m4") || deviceName.contains("m5") {
            return .high  // M4/M5 最高性能
        } else if deviceName.contains("m3") {
            return .high  // M3 高性能
        } else if deviceName.contains("m2") {
            return .high  // M2 高性能
        } else if deviceName.contains("m1") {
            return .medium  // M1 中等性能
        } else {
            return .medium
        }
    }
    
 // MARK: - 持久化
    private func saveCurrentMode() {
        UserDefaults.standard.set(self.currentMode.rawValue, forKey: "PerformanceMode")
        logger.debug("性能模式已保存: \(self.currentMode.displayName)")
    }
    
    public func loadSavedMode() {
        let savedModeString = UserDefaults.standard.string(forKey: "PerformanceMode") ?? PerformanceModeType.balanced.rawValue
        
        if let savedMode = PerformanceModeType(rawValue: savedModeString) {
            switchToMode(savedMode)
            logger.info("已加载保存的性能模式: \(savedMode.displayName)")
        } else {
            logger.warning("无效的保存模式，使用默认平衡模式")
            switchToMode(.balanced)
        }
    }
    
 // MARK: - 性能指标更新
    public func updatePerformanceMetrics(_ metrics: PerformanceMetrics) {
        self.performanceMetrics = metrics
    }
    
 /// 应用自适应配置（内部方法）
    internal func applyAdaptiveConfiguration(_ config: PerformanceConfiguration) async {
        logger.debug("应用自适应配置")
        
 // 更新当前配置
        currentConfiguration = config
        
 // 应用配置
        await applyPerformanceConfiguration()
    }
}

// MARK: - 设备性能等级
@available(macOS 14.0, *)
private enum DevicePerformanceLevel: String {
    case high = "high"      // 高性能设备 (M2, M3, M4)
    case medium = "medium"  // 中等性能设备 (M1)
    
 /// 获取当前设备的性能等级
    static var current: DevicePerformanceLevel {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .medium
        }
        return detectDevicePerformanceLevel(device: device)
    }
    
 /// 检测设备性能等级
    private static func detectDevicePerformanceLevel(device: MTLDevice) -> DevicePerformanceLevel {
 // 专为 Apple Silicon 设备优化
        let deviceName = device.name.lowercased()
        
 // 检测 Apple Silicon 芯片类型
        if deviceName.contains("m4") || deviceName.contains("m5") {
            return .high  // M4/M5 最高性能
        } else if deviceName.contains("m3") {
            return .high  // M3 高性能
        } else if deviceName.contains("m2") {
            return .high  // M2 高性能
        } else if deviceName.contains("m1") {
            return .medium  // M1 中等性能
        } else {
            return .medium
        }
    }
}

// MARK: - 错误类型
public enum PerformanceModeError: Error, LocalizedError {
    case metalDeviceNotAvailable
    
    public var errorDescription: String? {
        switch self {
        case .metalDeviceNotAvailable:
            return "Metal 设备不可用"
        }
    }
}

// MARK: - 通知扩展
extension Notification.Name {
    static let performanceConfigurationDidChange = Notification.Name("PerformanceConfigurationDidChange")
}

// MARK: - 自适应调整记录
/// 自适应性能调整记录
public struct AdaptiveAdjustment: Sendable {
    public let timestamp: Date
    public let fromMode: PerformanceModeType
    public let toMode: PerformanceModeType
    public let reason: String
    public let systemMetrics: SystemMetrics
    
    public init(
        timestamp: Date = Date(),
        fromMode: PerformanceModeType,
        toMode: PerformanceModeType,
        reason: String,
        systemMetrics: SystemMetrics
    ) {
        self.timestamp = timestamp
        self.fromMode = fromMode
        self.toMode = toMode
        self.reason = reason
        self.systemMetrics = systemMetrics
    }
}

// MARK: - 系统指标
public struct SystemMetrics: Sendable {
    public let cpuUsage: Double
    public let memoryPressure: Double
    public let thermalState: Int
    public let batteryLevel: Double
    public let powerSource: String
    
    public init(
        cpuUsage: Double = 0.0,
        memoryPressure: Double = 0.0,
        thermalState: Int = 0,
        batteryLevel: Double = 100.0,
        powerSource: String = "AC"
    ) {
        self.cpuUsage = cpuUsage
        self.memoryPressure = memoryPressure
        self.thermalState = thermalState
        self.batteryLevel = batteryLevel
        self.powerSource = powerSource
    }
}

// MARK: - 自适应性能监控器
@available(macOS 14.0, *)
@MainActor
public class AdaptivePerformanceMonitor: ObservableObject {
    private weak var manager: PerformanceModeManager?
    private var monitoringTimer: Timer?
    private let evaluationInterval: TimeInterval = 5.0 // 每5秒评估一次
    
 /// ✅ 真实的系统性能监控器
    private var systemPerformanceMonitor: SystemPerformanceMonitor?
    
 /// ✅ 公开访问器（供PerformanceModeManager使用）
    var systemPerformanceMonitorInstance: SystemPerformanceMonitor? {
        return systemPerformanceMonitor
    }
    
 // 稳定性控制
    private var lastModeChangeTime: Date = Date.distantPast
    private let minimumSwitchInterval: TimeInterval = 30.0 // 最小切换间隔30秒
    private var consecutiveRecommendations: [PerformanceModeType] = []
    private let stabilityRequiredCount: Int = 3 // 需要连续3次推荐同一模式才切换
    
 // 阈值配置
    private let highCPUThreshold: Double = 80.0
    private let highMemoryThreshold: Double = 75.0
    private let lowBatteryThreshold: Double = 20.0
    private let thermalThrottlingThreshold: Int = 3
    
    public init(manager: PerformanceModeManager) {
        self.manager = manager
 // ✅ 使用PerformanceModeManager已创建的SystemPerformanceMonitor实例
 // 确保所有组件共享同一个监控器实例
        self.systemPerformanceMonitor = manager.systemPerformanceMonitor
    }
    
    public func startMonitoring() {
        stopMonitoring() // 确保没有重复的定时器
        
 // ✅ 启动真实的系统性能监控（带延迟，等待CPU负载平稳）
        systemPerformanceMonitor?.startMonitoring(afterDelay: 10.0)
        
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: evaluationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.evaluateAndAdjustPerformance()
            }
        }
        
        SkyBridgeLogger.performance.debugOnly("自适应性能监控已启动（使用真实性能数据）")
    }
    
    public func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
 // ✅ 不停止SystemPerformanceMonitor，因为它可能被其他组件使用
 // 只在禁用自适应模式时停止评估
        SkyBridgeLogger.performance.debugOnly("自适应性能监控已停止")
    }
    
    private func evaluateAndAdjustPerformance() async {
        guard let manager = manager, manager.currentMode == .adaptive else { return }
        
        let metrics = await getCurrentSystemMetrics()
        
 // 在自适应模式下，不切换模式，而是动态调整性能参数
        await adjustAdaptivePerformance(metrics: metrics)
    }
    
    private func shouldSwitchToMode(_ recommendedMode: PerformanceModeType, currentMode: PerformanceModeType) -> Bool {
 // 检查最小切换间隔
        let timeSinceLastChange = Date().timeIntervalSince(lastModeChangeTime)
        if timeSinceLastChange < minimumSwitchInterval {
            return false
        }
        
 // 检查稳定性要求
        consecutiveRecommendations.append(recommendedMode)
        if consecutiveRecommendations.count > stabilityRequiredCount {
            consecutiveRecommendations.removeFirst()
        }
        
 // 需要连续推荐同一模式
        let allSame = consecutiveRecommendations.count == stabilityRequiredCount &&
                     consecutiveRecommendations.allSatisfy { $0 == recommendedMode }
        
        if allSame && recommendedMode != currentMode {
            lastModeChangeTime = Date()
            consecutiveRecommendations.removeAll()
            return true
        }
        
        return false
    }
    
    private func getCurrentSystemMetrics() async -> SystemMetrics {
 // ✅ 优先使用SystemPerformanceMonitor的真实数据
        let cpuUsage: Double
        let memoryPressure: Double
        
 // 通过PerformanceModeManager的systemPerformanceMonitor属性访问
        if let monitor = systemPerformanceMonitor, monitor.isMonitoring {
            cpuUsage = monitor.cpuUsage
            memoryPressure = monitor.memoryUsage
        } else {
 // 回退方案
            cpuUsage = await getCPUUsage()
            memoryPressure = await getMemoryPressure()
        }
        
        let thermalState = ProcessInfo.processInfo.thermalState.rawValue
        let batteryInfo = await getBatteryInfo()
        
        return SystemMetrics(
            cpuUsage: cpuUsage,
            memoryPressure: memoryPressure,
            thermalState: thermalState,
            batteryLevel: batteryInfo.level,
            powerSource: batteryInfo.isCharging ? "AC" : "Battery"
        )
    }
    
    private func getCPUUsage() async -> Double {
 // ✅ 使用真实的SystemPerformanceMonitor获取CPU使用率
 // 如果SystemPerformanceMonitor可用，使用真实数据
        if let monitor = systemPerformanceMonitor, monitor.isMonitoring {
            return monitor.cpuUsage
        }
        
 // 回退方案：使用系统API计算真实CPU使用率
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCpus: natural_t = 0
        
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCpus, &cpuInfo, &numCpuInfo)
        
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return 0.0
        }
        
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(numCpuInfo))
        }
        
        var totalUsage: Double = 0.0
        
        for i in 0..<Int(numCpus) {
            let cpuLoadInfo = cpuInfo.withMemoryRebound(to: processor_cpu_load_info_t.self, capacity: Int(numCpus)) { $0 }
            let load = cpuLoadInfo[i].pointee
            
            let user = Double(load.cpu_ticks.0)
            let system = Double(load.cpu_ticks.1)
            let nice = Double(load.cpu_ticks.2)
            let idle = Double(load.cpu_ticks.3)
            
            let total = user + system + nice + idle
            let usage = total > 0 ? ((user + system + nice) / total) * 100.0 : 0.0
            
            totalUsage += usage
        }
        
        return totalUsage / Double(numCpus)
    }
    
    private func getMemoryPressure() async -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
 // 计算内存压力百分比
            let totalMemory = ProcessInfo.processInfo.physicalMemory
            let usedMemory = UInt64(info.resident_size)
            return Double(usedMemory) / Double(totalMemory) * 100.0
        }
        
        return 0.0
    }
    
    private func getBatteryInfo() async -> (level: Double, isCharging: Bool) {
 // 使用 IOKit 获取电池信息
        let powerSourceInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let powerSources = IOPSCopyPowerSourcesList(powerSourceInfo)?.takeRetainedValue() as? [CFTypeRef]
        
        guard let sources = powerSources else {
            return (level: 100.0, isCharging: true) // 默认值（可能是台式机）
        }
        
        for source in sources {
            let sourceInfo = IOPSGetPowerSourceDescription(powerSourceInfo, source)?.takeUnretainedValue() as? [String: Any]
            
            if let info = sourceInfo,
               let capacity = info[kIOPSCurrentCapacityKey] as? Int,
               let isCharging = info[kIOPSIsChargingKey] as? Bool {
                return (level: Double(capacity), isCharging: isCharging)
            }
        }
        
        return (level: 100.0, isCharging: true)
    }
    
    private func evaluateOptimalMode(metrics: SystemMetrics) -> PerformanceModeType {
 // 在自适应模式下，始终返回自适应模式
 // 不再进行模式切换，而是通过动态调整参数来适应系统状态
        return .adaptive
    }
    
    private func generateAdjustmentReason(metrics: SystemMetrics, targetMode: PerformanceModeType) -> String {
        var reasons: [String] = []
        
        if metrics.thermalState >= thermalThrottlingThreshold {
            reasons.append("热量节流保护")
        }
        
        if metrics.powerSource == "Battery" && metrics.batteryLevel <= lowBatteryThreshold {
            reasons.append("低电量保护")
        }
        
        if metrics.cpuUsage >= highCPUThreshold {
            reasons.append("CPU高负载")
        }
        
        if metrics.memoryPressure >= highMemoryThreshold {
            reasons.append("内存压力高")
        }
        
        if reasons.isEmpty {
            return "系统状态正常，优化性能设置"
        } else {
            return reasons.joined(separator: "、")
        }
    }
    
 /// 自适应模式动态调整性能参数
 /// 根据系统状态动态调整性能配置，而不是切换模式
    private func adjustAdaptivePerformance(metrics: SystemMetrics) async {
        guard let manager = manager, manager.currentMode == .adaptive else { return }
        
 // 获取当前配置作为基准
        let baseConfig = manager.currentConfiguration
        var adjustedConfig = baseConfig
        
 // 根据系统状态动态调整参数
        let performanceMultiplier = calculatePerformanceMultiplier(metrics: metrics)
        
 // 动态调整渲染缩放 (50%-100%)
        let baseRenderScale: Float = 0.75 // 基准75%
        adjustedConfig = PerformanceConfiguration(
            renderScale: max(0.5, min(1.0, baseRenderScale * performanceMultiplier)),
            maxParticles: Int(Float(baseConfig.maxParticles) * performanceMultiplier),
            targetFrameRate: calculateAdaptiveFrameRate(metrics: metrics),
            metalFXQuality: max(0.3, min(1.0, baseConfig.metalFXQuality * performanceMultiplier)),
            shadowQuality: calculateAdaptiveShadowQuality(metrics: metrics),
            postProcessingLevel: calculateAdaptivePostProcessing(metrics: metrics),
            gpuFrequencyHint: max(0.3, min(1.0, baseConfig.gpuFrequencyHint * performanceMultiplier)),
            memoryBudget: Int(Float(baseConfig.memoryBudget) * performanceMultiplier),
            useUnifiedMemory: baseConfig.useUnifiedMemory,
            useNeuralEngine: baseConfig.useNeuralEngine,
            useAMX: baseConfig.useAMX,
            useAccelerate: baseConfig.useAccelerate
        )
        
 // 应用调整后的配置
        await manager.applyAdaptiveConfiguration(adjustedConfig)
        
 // 记录调整信息
        let reason = generateAdaptiveAdjustmentReason(metrics: metrics, multiplier: performanceMultiplier)
        let adjustment = AdaptiveAdjustment(
            fromMode: .adaptive,
            toMode: .adaptive,
            reason: reason,
            systemMetrics: metrics
        )
        manager.addAdaptiveAdjustment(adjustment)
    }
    
 /// 计算性能倍数 (0.5 - 1.5)
    private func calculatePerformanceMultiplier(metrics: SystemMetrics) -> Float {
        var multiplier: Float = 1.0
        
 // 热量状态影响 (-0.4 到 0)
        if metrics.thermalState >= thermalThrottlingThreshold {
            multiplier -= 0.4
        } else if metrics.thermalState >= 2 {
            multiplier -= 0.2
        }
        
 // 电池状态影响 (-0.3 到 +0.2)
        if metrics.powerSource == "Battery" {
            if metrics.batteryLevel <= lowBatteryThreshold {
                multiplier -= 0.3
            } else if metrics.batteryLevel <= 50 {
                multiplier -= 0.1
            }
        } else {
            multiplier += 0.2 // AC电源加成
        }
        
 // CPU负载影响 (-0.2 到 +0.3)
        if metrics.cpuUsage >= highCPUThreshold {
            multiplier -= 0.2
        } else if metrics.cpuUsage <= 30 {
            multiplier += 0.3
        }
        
 // 内存压力影响 (-0.2 到 0)
        if metrics.memoryPressure >= highMemoryThreshold {
            multiplier -= 0.2
        } else if metrics.memoryPressure >= 50 {
            multiplier -= 0.1
        }
        
        return max(0.5, min(1.5, multiplier))
    }
    
 /// 计算自适应帧率 - 限制最大帧率不超过极致模式
    private func calculateAdaptiveFrameRate(metrics: SystemMetrics) -> Int {
 // 基准帧率60fps
        var targetFPS = 60
        
        if metrics.thermalState >= thermalThrottlingThreshold || 
           (metrics.powerSource == "Battery" && metrics.batteryLevel <= lowBatteryThreshold) {
            targetFPS = 30 // 节能情况
        } else if metrics.powerSource == "AC" && metrics.thermalState <= 1 && 
                  metrics.cpuUsage <= 50 && metrics.memoryPressure <= 50 {
 // 自适应模式最高不超过100fps，确保极致模式仍是最高性能
            targetFPS = 100 
        } else if metrics.cpuUsage >= highCPUThreshold || metrics.memoryPressure >= highMemoryThreshold {
            targetFPS = 75 // 高负载情况，降低到75fps
        }
        
        return targetFPS
    }
    
 /// 计算自适应阴影质量
    private func calculateAdaptiveShadowQuality(metrics: SystemMetrics) -> Int {
        if metrics.thermalState >= thermalThrottlingThreshold || 
           (metrics.powerSource == "Battery" && metrics.batteryLevel <= lowBatteryThreshold) {
            return 0 // 低质量
        } else if metrics.cpuUsage >= highCPUThreshold || metrics.memoryPressure >= highMemoryThreshold {
            return 1 // 中等质量
        } else {
            return 2 // 高质量
        }
    }
    
 /// 计算自适应后处理级别
    private func calculateAdaptivePostProcessing(metrics: SystemMetrics) -> Int {
        if metrics.thermalState >= thermalThrottlingThreshold || 
           (metrics.powerSource == "Battery" && metrics.batteryLevel <= lowBatteryThreshold) {
            return 0 // 禁用
        } else if metrics.cpuUsage >= highCPUThreshold || metrics.memoryPressure >= highMemoryThreshold {
            return 1 // 基础后处理
        } else {
            return 2 // 完整后处理
        }
    }
    
 /// 生成自适应调整原因
    private func generateAdaptiveAdjustmentReason(metrics: SystemMetrics, multiplier: Float) -> String {
        var reasons: [String] = []
        
        if multiplier < 0.8 {
            if metrics.thermalState >= thermalThrottlingThreshold {
                reasons.append("热量节流降频")
            }
            if metrics.powerSource == "Battery" && metrics.batteryLevel <= lowBatteryThreshold {
                reasons.append("低电量节能")
            }
            if metrics.cpuUsage >= highCPUThreshold {
                reasons.append("CPU高负载优化")
            }
            if metrics.memoryPressure >= highMemoryThreshold {
                reasons.append("内存压力缓解")
            }
        } else if multiplier > 1.2 {
            reasons.append("系统状态良好，提升性能")
        } else {
            reasons.append("性能平衡调节")
        }
        
        return reasons.isEmpty ? "智能性能调节" : reasons.joined(separator: "、")
    }
}
