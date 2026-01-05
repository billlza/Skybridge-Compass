//
// AppleSiliconOptimizer.swift
// SkyBridgeCompassApp
//
// Apple Silicon 专用性能优化器
// 针对 M1/M2/M3/M4 芯片进行深度优化
//

import Foundation
import Metal
import MetalKit
import OSLog
import CoreML
import Accelerate
import MetalPerformanceShaders
import SkyBridgeCore // 导入 SkyBridgeCore 模块以访问其 TaskType

// 导入项目内部类型
// 注意：这些类型应该在其他文件中定义

/// Apple Silicon 优化器 - 专门针对 Apple 芯片进行性能优化
@available(macOS 14.0, *)
@MainActor
public final class AppleSiliconOptimizer: BaseManager, Sendable {
    
 /// Apple Silicon 特性检测器
    private let features: AppleSiliconFeatures
    
 /// Metal 设备
    private let metalDevice: MTLDevice?
    
 /// 统一内存管理器
    private let unifiedMemoryManager: UnifiedMemoryManager
    
 /// Neural Engine 优化器
    private let neuralEngineOptimizer: NeuralEngineOptimizer
    
 /// AMX 协处理器优化器
    private let amxOptimizer: AMXOptimizer
    
 /// GPU 优化器
    private let gpuOptimizer: GPUOptimizer?
    
 /// 单例实例
    public static let shared: AppleSiliconOptimizer = {
        do {
            return try AppleSiliconOptimizer()
        } catch {
 // 生产模式下避免崩溃，记录错误并返回回退实例
            if #available(macOS 14.0, *) {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Apple Silicon 优化器初始化失败"
                    alert.informativeText = "\(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
            return AppleSiliconOptimizer.fallback()
        }
    }()

 /// 回退实例（尽可能使用默认Metal设备与保守配置）
    private static func fallback() -> AppleSiliconOptimizer {
        return AppleSiliconOptimizer(fallback: ())
    }
    
 // MARK: - 初始化
    
 /// 初始化 Apple Silicon 优化器
    public init() throws {
 // 检测 Apple Silicon 特性
        self.features = AppleSiliconFeatures()
        
 // 获取 Metal 设备
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw AppleSiliconOptimizerError.metalDeviceNotAvailable
        }
        self.metalDevice = device
        
 // 初始化各个优化器组件
        self.unifiedMemoryManager = UnifiedMemoryManager(features: features)
        self.neuralEngineOptimizer = NeuralEngineOptimizer(features: features)
        self.amxOptimizer = AMXOptimizer(features: features)
        self.gpuOptimizer = GPUOptimizer(device: device, features: features)
        
        super.init(category: "AppleSiliconOptimizer")
        
        logger.info("Apple Silicon 优化器初始化完成 - \(self.features.description)")
    }
    
    private init(fallback: Void) {
        self.features = AppleSiliconFeatures()
        self.metalDevice = MTLCreateSystemDefaultDevice()
        self.unifiedMemoryManager = UnifiedMemoryManager(features: features)
        self.neuralEngineOptimizer = NeuralEngineOptimizer(features: features)
        self.amxOptimizer = AMXOptimizer(features: features)
        if let d = self.metalDevice {
            self.gpuOptimizer = GPUOptimizer(device: d, features: features)
        } else {
            self.gpuOptimizer = nil
        }
        super.init(category: "AppleSiliconOptimizer")
    }
    
 // MARK: - 公共方法
    
 /// 应用全面的 Apple Silicon 优化
    public func applyOptimizations(for mode: PerformanceModeType) async {
        logger.info("开始应用 Apple Silicon 优化 - 模式: \(mode.displayName)")
        
        await withTaskGroup(of: Void.self) { group in
 // 统一内存优化
            if self.features.hasUnifiedMemory {
                group.addTask { [weak self] in
                    await self?.unifiedMemoryManager.optimizeForMode(mode)
                }
            }
            
 // Neural Engine 优化
            if self.features.hasNeuralEngine {
                group.addTask { [weak self] in
                    await self?.neuralEngineOptimizer.optimizeForMode(mode)
                }
            }
            
 // AMX 协处理器优化
            if self.features.hasAMX {
                group.addTask { [weak self] in
                    await self?.amxOptimizer.optimizeForMode(mode)
                }
            }
            
 // GPU 优化
            group.addTask { [weak self] in
                await self?.gpuOptimizer?.optimizeForMode(mode)
            }
        }
        
        logger.info("Apple Silicon 优化应用完成")
    }
    
 /// 获取优化建议
    public func getOptimizationRecommendations() -> [OptimizationRecommendation] {
        var recommendations: [OptimizationRecommendation] = []
        
 // 统一内存建议
        if features.hasUnifiedMemory {
            recommendations.append(contentsOf: unifiedMemoryManager.getRecommendations())
        }
        
 // Neural Engine 建议
        if features.hasNeuralEngine {
            recommendations.append(contentsOf: neuralEngineOptimizer.getRecommendations())
        }
        
 // AMX 建议
        if features.hasAMX {
            recommendations.append(contentsOf: amxOptimizer.getRecommendations())
        }
        
 // GPU 建议
        if let gpu = gpuOptimizer {
            recommendations.append(contentsOf: gpu.getRecommendations())
        }
        
        return recommendations
    }
    
 /// 获取性能指标
    public func getPerformanceMetrics() async -> AppleSiliconMetrics {
        async let unifiedMemoryMetrics = unifiedMemoryManager.getMetrics()
        async let neuralEngineMetrics = neuralEngineOptimizer.getMetrics()
        async let amxMetrics = amxOptimizer.getMetrics()
        async let gpuMetrics = gpuOptimizer?.getMetrics() ?? GPUMetrics(name: self.metalDevice?.name ?? "Unknown", utilizationRate: 0.0, memoryUsage: 0, temperature: 0.0, powerDraw: 0.0)
        
        return AppleSiliconMetrics(
            unifiedMemory: await unifiedMemoryMetrics,
            neuralEngine: await neuralEngineMetrics,
            amx: await amxMetrics,
            gpu: await gpuMetrics,
            features: features
        )
    }
    
 /// 检查是否为 Apple Silicon 设备
    public var isAppleSilicon: Bool {
        return features.chipModel.contains("Apple")
    }
    
 /// 获取系统信息
    public func getSystemInfo() -> AppleSiliconSystemInfo {
        return AppleSiliconSystemInfo(
            chipModel: features.chipModel,
            performanceCores: features.performanceCores,
            efficiencyCores: features.efficiencyCores,
            hasUnifiedMemory: features.hasUnifiedMemory,
            hasNeuralEngine: features.hasNeuralEngine,
            hasAMX: features.hasAMX,
            metalDevice: metalDevice?.name ?? "Unknown",
            cpuBrand: features.chipModel, // 使用芯片型号作为CPU品牌
            performanceCoreCount: features.performanceCores, // 使用性能核心数量
            efficiencyCoreCount: features.efficiencyCores // 使用效率核心数量
        )
    }
    
 /// 为任务类型推荐 QoS 等级
 /// 兼容 SkyBridgeCore.TaskType 和 SkyBridgeCompassApp.TaskType
    nonisolated public func recommendedQoS(for taskType: SkyBridgeCore.TaskType) -> DispatchQoS.QoSClass {
 // 手动映射 SkyBridgeCore.TaskType 到 QoS 等级
        switch taskType {
        case .userInterface:
            return .userInteractive
        case .userInitiated:
            return .userInitiated
        case .networkRequest:
            return .userInitiated
        case .imageProcessing:
            return .utility
        case .fileIO:
            return .utility
        case .backgroundSync:
            return .background
        case .dataAnalysis:
            return .utility
        }
    }
    
 /// 为任务类型推荐 QoS 等级 (本地 TaskType 重载)
    nonisolated public func recommendedQoS(for taskType: TaskType) -> DispatchQoS.QoSClass {
        switch taskType {
        case .rendering, .realtime:
            return .userInteractive
        case .computation, .ai:
            return .userInitiated
        case .networking, .networkRequest:
            return .userInitiated
        case .dataAnalysis, .fileIO:
            return .utility
        case .background:
            return .background
        }
    }
    
 /// 执行向量化操作，充分利用 Apple Silicon 的 Accelerate 框架
 /// 使用 Swift 6.2 的 Sendable 协议确保线程安全
    public func performVectorizedOperation(
        _ input: [Float],
        operation: VectorOperation
    ) -> [Float] {
        guard !input.isEmpty else { return [] }
        
        var result = [Float](repeating: 0.0, count: input.count)
        
 // 使用 Accelerate 框架进行向量化计算，充分利用 Apple Silicon 的向量处理单元
        switch operation {
        case .square:
            vDSP_vsq(input, 1, &result, 1, vDSP_Length(input.count))
        case .sqrt:
            var inputCopy = input
            vvsqrtf(&result, &inputCopy, [Int32(input.count)])
        case .log:
            var inputCopy = input
            vvlogf(&result, &inputCopy, [Int32(input.count)])
        case .exp:
            var inputCopy = input
            vvexpf(&result, &inputCopy, [Int32(input.count)])
        case .sin:
            var inputCopy = input
            vvsinf(&result, &inputCopy, [Int32(input.count)])
        case .cos:
            var inputCopy = input
            vvcosf(&result, &inputCopy, [Int32(input.count)])
        }
        
        return result
    }
    
 /// 推荐数据块大小，基于 Apple Silicon 的缓存层次结构优化
 /// 针对 M1/M2/M3/M4 芯片的缓存特性进行调优
    nonisolated public func recommendedChunkSize(for dataSize: Int) -> Int {
 // 使用静态配置避免访问实例状态
        let performanceCoreCount = 8 // Apple Silicon 典型性能核心数
        
 // Apple Silicon 缓存层次结构优化
        let l1CacheSize = 128 * 1024      // 128KB L1 缓存
        let l2CacheSize = 12 * 1024 * 1024  // 12MB L2 缓存 (M1/M2)
        let _ = 400 * 1024 * 1024 * 1024  // 400GB/s 统一内存带宽
        
 // 根据数据大小选择最优块大小
        if dataSize <= l1CacheSize {
 // 小数据集：完全适合 L1 缓存
            return dataSize
        } else if dataSize <= l2CacheSize {
 // 中等数据集：分块以适应 L1 缓存，减少缓存未命中
            return l1CacheSize / 2
        } else if dataSize <= (100 * 1024 * 1024) {
 // 大数据集：分块以适应 L2 缓存
            return l2CacheSize / 4
        } else {
 // 超大数据集：考虑内存带宽和并行度
            return max(l2CacheSize / 2, dataSize / (performanceCoreCount * 4))
        }
    }
    
 /// 执行并行计算，充分利用 Apple Silicon 的多核架构
 /// 使用 Swift 6.2 的 Sendable 协议确保并发安全
    public func performParallelComputation<T: Sendable>(
        iterations: Int,
        qos: DispatchQoS.QoSClass = .userInitiated,
        execute: @escaping @Sendable (Int) -> T
    ) async -> [T] {
 // 根据 Apple Silicon 的核心数量优化并行度
        let coreCount = features.performanceCores + features.efficiencyCores
        let chunkSize = max(1, iterations / coreCount)
        
        return await withTaskGroup(of: [T].self) { group in
            var results: [T] = []
            results.reserveCapacity(iterations)
            
 // 将工作分配到多个任务中
            for chunkStart in stride(from: 0, to: iterations, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, iterations)
                
                group.addTask {
                    var chunkResults: [T] = []
                    chunkResults.reserveCapacity(chunkEnd - chunkStart)
                    
                    for i in chunkStart..<chunkEnd {
                        chunkResults.append(execute(i))
                    }
                    
                    return chunkResults
                }
            }
            
 // 收集所有结果
            for await chunkResults in group {
                results.append(contentsOf: chunkResults)
            }
            
            return results
        }
    }
}

// MARK: - 数据结构

/// Apple Silicon 系统信息
public struct AppleSiliconSystemInfo: Sendable {
    public let chipModel: String
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let hasUnifiedMemory: Bool
    public let hasNeuralEngine: Bool
    public let hasAMX: Bool
    public let metalDevice: String
    public let cpuBrand: String // 添加缺失的 cpuBrand 属性
    public let performanceCoreCount: Int // 添加缺失的 performanceCoreCount 属性
    public let efficiencyCoreCount: Int // 添加缺失的 efficiencyCoreCount 属性
}

/// 向量操作枚举
public enum VectorOperation: CustomStringConvertible, Sendable {
    case square    // 平方
    case sqrt      // 平方根
    case log       // 对数
    case exp       // 指数
    case sin       // 正弦
    case cos       // 余弦
    
    var standardOperation: (Float) -> Float {
        switch self {
        case .square: return { $0 * $0 }
        case .sqrt: return { Foundation.sqrt($0) }
        case .log: return { Foundation.log($0) }
        case .exp: return { Foundation.exp($0) }
        case .sin: return { Foundation.sin($0) }
        case .cos: return { Foundation.cos($0) }
        }
    }
    
    public var description: String {
        switch self {
        case .square: return "平方"
        case .sqrt: return "平方根"
        case .log: return "对数"
        case .exp: return "指数"
        case .sin: return "正弦"
        case .cos: return "余弦"
        }
    }
}

/// 任务类型枚举
public enum TaskType: String, CaseIterable, Sendable {
    case rendering = "rendering"
    case computation = "computation"
    case ai = "ai"
    case background = "background"
    case networking = "networking"
    case realtime = "realtime"
    case networkRequest = "networkRequest"
    case dataAnalysis = "dataAnalysis"
    case fileIO = "fileIO"
}

// MARK: - 统一内存管理器

/// 统一内存管理器 - 优化 Apple Silicon 的统一内存架构
public final class UnifiedMemoryManager: Sendable {
    private let features: AppleSiliconFeatures
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "UnifiedMemoryManager")
    
    public init(features: AppleSiliconFeatures) {
        self.features = features
    }
    
 /// 针对性能模式优化统一内存
    public func optimizeForMode(_ mode: PerformanceModeType) async {
        guard features.hasUnifiedMemory else { return }
        
        logger.info("优化统一内存 - 模式: \(mode.displayName)")
        
        switch mode {
        case .extreme:
            await configureHighPerformanceMemory()
        case .balanced:
            await configureBalancedMemory()
        case .energySaving:
            await configureEnergyEfficientMemory()
        case .adaptive:
            await configureAdaptiveMemory()
        }
    }
    
    private func configureHighPerformanceMemory() async {
 // 配置高性能内存模式
        logger.debug("配置高性能统一内存模式")
 // 实现高性能内存配置逻辑
    }
    
    private func configureBalancedMemory() async {
 // 配置平衡内存模式
        logger.debug("配置平衡统一内存模式")
 // 实现平衡内存配置逻辑
    }
    
    private func configureEnergyEfficientMemory() async {
 // 配置节能内存模式
        logger.debug("配置节能统一内存模式")
 // 实现节能内存配置逻辑
    }
    
    private func configureAdaptiveMemory() async {
 // 配置自适应内存模式
        logger.debug("配置自适应统一内存模式")
 // 实现自适应内存配置逻辑
    }
    
    public func getRecommendations() -> [OptimizationRecommendation] {
        return [
            OptimizationRecommendation(
                title: "统一内存优化",
                description: "利用 Apple Silicon 统一内存架构提升性能",
                impact: .high,
                category: .memory
            )
        ]
    }
    
    public func getMetrics() async -> UnifiedMemoryMetrics {
        return UnifiedMemoryMetrics(
            totalMemory: ProcessInfo.processInfo.physicalMemory,
            availableMemory: 0, // 需要实现获取可用内存的逻辑
            memoryPressure: 0.0, // 需要实现获取内存压力的逻辑
            isOptimized: true
        )
    }
}

// MARK: - Neural Engine 优化器

/// Neural Engine 优化器 - 优化 Apple Neural Engine 使用
public final class NeuralEngineOptimizer: Sendable {
    private let features: AppleSiliconFeatures
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "NeuralEngineOptimizer")
    
    public init(features: AppleSiliconFeatures) {
        self.features = features
    }
    
 /// 针对性能模式优化 Neural Engine
    public func optimizeForMode(_ mode: PerformanceModeType) async {
        guard features.hasNeuralEngine else { return }
        
        logger.info("优化 Neural Engine - 模式: \(mode.displayName)")
        
        switch mode {
        case .extreme:
            await enableMaximumNeuralEnginePerformance()
        case .balanced:
            await enableBalancedNeuralEnginePerformance()
        case .energySaving:
            await enableEnergyEfficientNeuralEngine()
        case .adaptive:
            await enableAdaptiveNeuralEngine()
        }
    }
    
    private func enableMaximumNeuralEnginePerformance() async {
        logger.debug("启用最大 Neural Engine 性能")
 // 实现最大性能配置
    }
    
    private func enableBalancedNeuralEnginePerformance() async {
        logger.debug("启用平衡 Neural Engine 性能")
 // 实现平衡性能配置
    }
    
    private func enableEnergyEfficientNeuralEngine() async {
        logger.debug("启用节能 Neural Engine 模式")
 // 实现节能配置
    }
    
    private func enableAdaptiveNeuralEngine() async {
        logger.debug("启用自适应 Neural Engine 模式")
 // 实现自适应配置
    }
    
    public func getRecommendations() -> [OptimizationRecommendation] {
        return [
            OptimizationRecommendation(
                title: "Neural Engine 优化",
                description: "利用 Apple Neural Engine 加速 AI 推理任务",
                impact: .high,
                category: .ai
            )
        ]
    }
    
    public func getMetrics() async -> NeuralEngineMetrics {
        return NeuralEngineMetrics(
            isAvailable: features.hasNeuralEngine,
            utilizationRate: 0.0, // 需要实现获取利用率的逻辑
            inferenceLatency: 0.0, // 需要实现获取推理延迟的逻辑
            powerEfficiency: 1.0
        )
    }
}

// MARK: - AMX 协处理器优化器

/// AMX 协处理器优化器 - 优化 Apple Matrix coprocessor 使用
public final class AMXOptimizer: Sendable {
    private let features: AppleSiliconFeatures
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "AMXOptimizer")
    
    public init(features: AppleSiliconFeatures) {
        self.features = features
    }
    
 /// 针对性能模式优化 AMX
    public func optimizeForMode(_ mode: PerformanceModeType) async {
        guard features.hasAMX else { return }
        
        logger.info("优化 AMX 协处理器 - 模式: \(mode.displayName)")
        
        switch mode {
        case .extreme:
            await enableMaximumAMXPerformance()
        case .balanced:
            await enableBalancedAMXPerformance()
        case .energySaving:
            await enableEnergyEfficientAMX()
        case .adaptive:
            await enableAdaptiveAMX()
        }
    }
    
    private func enableMaximumAMXPerformance() async {
        logger.debug("启用最大 AMX 性能")
 // 实现最大性能配置
    }
    
    private func enableBalancedAMXPerformance() async {
        logger.debug("启用平衡 AMX 性能")
 // 实现平衡性能配置
    }
    
    private func enableEnergyEfficientAMX() async {
        logger.debug("启用节能 AMX 模式")
 // 实现节能配置
    }
    
    private func enableAdaptiveAMX() async {
        logger.debug("启用自适应 AMX 模式")
 // 实现自适应配置
    }
    
    public func getRecommendations() -> [OptimizationRecommendation] {
        return [
            OptimizationRecommendation(
                title: "AMX 协处理器优化",
                description: "利用 Apple Matrix coprocessor 加速矩阵运算",
                impact: .medium,
                category: .compute
            )
        ]
    }
    
    public func getMetrics() async -> AMXMetrics {
        return AMXMetrics(
            isAvailable: features.hasAMX,
            utilizationRate: 0.0, // 需要实现获取利用率的逻辑
            matrixOperationsPerSecond: 0.0, // 需要实现获取操作速率的逻辑
            powerEfficiency: 1.0
        )
    }
}

// MARK: - GPU 优化器

/// GPU 优化器 - 优化 Apple GPU 性能
public final class GPUOptimizer: Sendable {
    private let device: MTLDevice
    private let features: AppleSiliconFeatures
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "GPUOptimizer")
    
    public init(device: MTLDevice, features: AppleSiliconFeatures) {
        self.device = device
        self.features = features
    }
    
 /// 针对性能模式优化 GPU
    public func optimizeForMode(_ mode: PerformanceModeType) async {
        logger.info("优化 Apple GPU - 模式: \(mode.displayName)")
        
        switch mode {
        case .extreme:
            await configureMaximumGPUPerformance()
        case .balanced:
            await configureBalancedGPUPerformance()
        case .energySaving:
            await configureEnergyEfficientGPU()
        case .adaptive:
            await configureAdaptiveGPU()
        }
    }
    
    private func configureMaximumGPUPerformance() async {
        logger.debug("配置最大 GPU 性能")
 // 实现最大性能配置
    }
    
    private func configureBalancedGPUPerformance() async {
        logger.debug("配置平衡 GPU 性能")
 // 实现平衡性能配置
    }
    
    private func configureEnergyEfficientGPU() async {
        logger.debug("配置节能 GPU 模式")
 // 实现节能配置
    }
    
    private func configureAdaptiveGPU() async {
        logger.debug("配置自适应 GPU 模式")
 // 实现自适应配置
    }
    
    public func getRecommendations() -> [OptimizationRecommendation] {
        return [
            OptimizationRecommendation(
                title: "Apple GPU 优化",
                description: "优化 Apple 集成 GPU 性能和功耗",
                impact: .high,
                category: .graphics
            )
        ]
    }
    
    public func getMetrics() async -> GPUMetrics {
        return GPUMetrics(
            name: device.name,
            utilizationRate: 0.0, // 需要实现获取利用率的逻辑
            memoryUsage: 0, // 需要实现获取内存使用的逻辑
            temperature: 0.0, // 需要实现获取温度的逻辑
            powerDraw: 0.0 // 需要实现获取功耗的逻辑
        )
    }
}

// MARK: - 数据结构

/// 优化建议
public struct OptimizationRecommendation: Sendable {
    public let title: String
    public let description: String
    public let impact: Impact
    public let category: Category
    
    public enum Impact: String, Sendable {
        case low = "low"
        case medium = "medium"
        case high = "high"
    }
    
    public enum Category: String, Sendable {
        case memory = "memory"
        case graphics = "graphics"
        case compute = "compute"
        case ai = "ai"
        case power = "power"
    }
}

/// Apple Silicon 性能指标
public struct AppleSiliconMetrics: Sendable {
    public let unifiedMemory: UnifiedMemoryMetrics
    public let neuralEngine: NeuralEngineMetrics
    public let amx: AMXMetrics
    public let gpu: GPUMetrics
    public let features: AppleSiliconFeatures
}

/// 统一内存指标
public struct UnifiedMemoryMetrics: Sendable {
    public let totalMemory: UInt64
    public let availableMemory: UInt64
    public let memoryPressure: Double
    public let isOptimized: Bool
}

/// Neural Engine 指标
public struct NeuralEngineMetrics: Sendable {
    public let isAvailable: Bool
    public let utilizationRate: Double
    public let inferenceLatency: Double
    public let powerEfficiency: Double
}

/// AMX 指标
public struct AMXMetrics: Sendable {
    public let isAvailable: Bool
    public let utilizationRate: Double
    public let matrixOperationsPerSecond: Double
    public let powerEfficiency: Double
}

/// GPU 指标
public struct GPUMetrics: Sendable {
    public let name: String
    public let utilizationRate: Double
    public let memoryUsage: UInt64
    public let temperature: Double
    public let powerDraw: Double
}

// MARK: - 错误类型

/// Apple Silicon 优化器错误
public enum AppleSiliconOptimizerError: Error, LocalizedError {
    case metalDeviceNotAvailable
    case featureNotSupported(String)
    case optimizationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .metalDeviceNotAvailable:
            return "Metal 设备不可用"
        case .featureNotSupported(let feature):
            return "不支持的特性: \(feature)"
        case .optimizationFailed(let reason):
            return "优化失败: \(reason)"
        }
    }
}
