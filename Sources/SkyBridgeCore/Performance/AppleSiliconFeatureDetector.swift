import Foundation
import os.log

/// Apple Silicon特有功能检测器
/// 检测和利用Apple Silicon芯片的特有功能和优化
@available(macOS 14.0, *)
public final class AppleSiliconFeatureDetector: @unchecked Sendable {
    public static let shared = AppleSiliconFeatureDetector()
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "AppleSiliconFeatureDetector")
    
 // 系统信息缓存
    private var _systemInfo: SystemInfo?
    private let systemInfoLock = NSLock()
    
    private init() {
        logger.info("Apple Silicon功能检测器已初始化")
        detectSystemCapabilities()
    }
    
 // MARK: - 公共接口
    
 /// 获取系统信息
    public var systemInfo: SystemInfo {
        systemInfoLock.lock()
        defer { systemInfoLock.unlock() }
        
        if let info = _systemInfo {
            return info
        }
        
        let info = detectSystemInfo()
        _systemInfo = info
        return info
    }
    
 /// 检查是否运行在Apple Silicon上
    public var isAppleSilicon: Bool {
        return systemInfo.isAppleSilicon
    }
    
 /// 检查是否支持统一内存架构
    public var supportsUnifiedMemory: Bool {
        return systemInfo.supportsUnifiedMemory
    }
    
 /// 检查是否支持Neural Engine
    public var supportsNeuralEngine: Bool {
        return systemInfo.supportsNeuralEngine
    }
    
 /// 检查是否支持AMX（Apple Matrix Extensions）
    public var supportsAMX: Bool {
        return systemInfo.supportsAMX
    }
    
 /// 获取推荐的性能配置
    public func getRecommendedPerformanceConfig() -> PerformanceConfig {
        let info = systemInfo
        
        return PerformanceConfig(
            maxConcurrentTasks: info.performanceCoreCount + (info.efficiencyCoreCount / 2),
            preferredQueueCount: min(8, info.performanceCoreCount),
            memoryOptimizationLevel: info.supportsUnifiedMemory ? .aggressive : .conservative,
            useNeuralEngine: info.supportsNeuralEngine,
            useAMX: info.supportsAMX,
            thermalThrottlingThreshold: info.thermalDesignPower > 20 ? 0.8 : 0.6
        )
    }
    
 /// 获取针对特定任务类型的优化建议
    public func getOptimizationRecommendations(for taskType: TaskType) -> OptimizationRecommendations {
        let info = systemInfo
        let config = getRecommendedPerformanceConfig()
        
        switch taskType {
        case .userInterface:
            return OptimizationRecommendations(
                qosClass: .userInteractive,
                concurrency: 1,
                useGPU: false,
                useNeuralEngine: false,
                memoryStrategy: .lowLatency,
                schedulingHint: .interactive
            )
            
        case .userInitiated:
            return OptimizationRecommendations(
                qosClass: .userInitiated,
                concurrency: min(2, info.performanceCoreCount),
                useGPU: false,
                useNeuralEngine: false,
                memoryStrategy: .balanced,
                schedulingHint: .responsive
            )
            
        case .networkRequest:
            return OptimizationRecommendations(
                qosClass: .utility,
                concurrency: 4,
                useGPU: false,
                useNeuralEngine: false,
                memoryStrategy: .conservative,
                schedulingHint: .throughput
            )
            
        case .imageProcessing:
            return OptimizationRecommendations(
                qosClass: .userInitiated,
                concurrency: info.performanceCoreCount,
                useGPU: true,
                useNeuralEngine: config.useNeuralEngine,
                memoryStrategy: .aggressive,
                schedulingHint: .compute
            )
            
        case .fileIO:
            return OptimizationRecommendations(
                qosClass: .utility,
                concurrency: 2,
                useGPU: false,
                useNeuralEngine: false,
                memoryStrategy: .conservative,
                schedulingHint: .io
            )
            
        case .backgroundSync:
            return OptimizationRecommendations(
                qosClass: .background,
                concurrency: info.efficiencyCoreCount,
                useGPU: false,
                useNeuralEngine: false,
                memoryStrategy: .conservative,
                schedulingHint: .background
            )
            
        case .dataAnalysis:
            return OptimizationRecommendations(
                qosClass: .utility,
                concurrency: config.maxConcurrentTasks,
                useGPU: false,
                useNeuralEngine: config.useNeuralEngine,
                memoryStrategy: .aggressive,
                schedulingHint: .compute
            )
        }
    }
    
 /// 检测当前系统的热状态
    public func getCurrentThermalState() -> SystemThermalState {
        let thermalState = ProcessInfo.processInfo.thermalState
        
        switch thermalState {
        case .nominal:
            return .optimal
        case .fair:
            return .good
        case .serious:
            return .throttled
        case .critical:
            return .critical
        @unknown default:
            return .unknown
        }
    }
    
 /// 获取当前电源状态
    public func getCurrentPowerState() -> AppleSiliconPowerState {
        let powerSource = ProcessInfo.processInfo.isLowPowerModeEnabled
        
        if powerSource {
            return .lowPower
        } else {
            return .normal
        }
    }
    
 // MARK: - 私有方法
    
    private func detectSystemCapabilities() {
        let info = systemInfo
        
        logger.info("系统检测完成:")
        logger.info("- Apple Silicon: \(info.isAppleSilicon)")
        logger.info("- 芯片型号: \(info.chipModel)")
        logger.info("- 性能核心数: \(info.performanceCoreCount)")
        logger.info("- 效率核心数: \(info.efficiencyCoreCount)")
        logger.info("- 统一内存: \(info.supportsUnifiedMemory)")
        logger.info("- Neural Engine: \(info.supportsNeuralEngine)")
        logger.info("- AMX支持: \(info.supportsAMX)")
        logger.info("- 热设计功耗: \(info.thermalDesignPower)W")
    }
    
    private func detectSystemInfo() -> SystemInfo {
        var size = size_t()
        var result: Int32
        
 // 检测CPU架构
        var cpuType: cpu_type_t = 0
        size = MemoryLayout<cpu_type_t>.size
        result = sysctlbyname("hw.cputype", &cpuType, &size, nil, 0)
        let isAppleSilicon = (result == 0) && (cpuType == CPU_TYPE_ARM64)
        
 // 确保仅在Apple Silicon设备上运行
        if !isAppleSilicon {
            logger.warning("检测到非 Apple Silicon 架构，降级处理")
        }
        
 // 获取芯片型号
        var chipModel = "Unknown"
        var buffer = [CChar](repeating: 0, count: 256)
        size = buffer.count
        result = sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        if result == 0 {
 // 获取芯片型号信息，使用推荐的方法
            buffer.withUnsafeBufferPointer { bufferPointer in
                let bufferArray = Array(bufferPointer)
                let truncatedArray = bufferArray.prefix { $0 != 0 }
 // 将 CChar (Int8) 转换为 UInt8 以匹配 UTF8.CodeUnit
                let utf8Array = truncatedArray.map { UInt8(bitPattern: $0) }
                chipModel = String(decoding: utf8Array, as: UTF8.self)
            }
        }
        
 // 获取CPU核心数信息
        var performanceCoreCount: Int = 0
        var efficiencyCoreCount: Int = 0
        
 // 尝试获取性能核心数
        var pCores: UInt64 = 0
        size = MemoryLayout<UInt64>.size
        result = sysctlbyname("hw.perflevel0.logicalcpu", &pCores, &size, nil, 0)
        if result == 0 {
            performanceCoreCount = Int(pCores)
        }
        
 // 尝试获取效率核心数
        var eCores: UInt64 = 0
        size = MemoryLayout<UInt64>.size
        result = sysctlbyname("hw.perflevel1.logicalcpu", &eCores, &size, nil, 0)
        if result == 0 {
            efficiencyCoreCount = Int(eCores)
        }
        
 // 如果无法获取详细信息，使用总核心数估算
        if performanceCoreCount == 0 && efficiencyCoreCount == 0 {
            var totalCores: UInt64 = 0
            size = MemoryLayout<UInt64>.size
            result = sysctlbyname("hw.logicalcpu", &totalCores, &size, nil, 0)
            if result == 0 {
 // 根据芯片型号估算P核和E核分布
                let total = Int(totalCores)
                if chipModel.contains("M1") {
                    performanceCoreCount = min(4, total / 2)
                    efficiencyCoreCount = total - performanceCoreCount
                } else if chipModel.contains("M2") || chipModel.contains("M3") {
                    performanceCoreCount = min(8, total / 2)
                    efficiencyCoreCount = total - performanceCoreCount
                } else {
                    performanceCoreCount = total / 2
                    efficiencyCoreCount = total / 2
                }
            }
        }
        
 // Apple Silicon特殊功能支持
        let supportsUnifiedMemory = true
        let supportsNeuralEngine = chipModel.contains("M1") || chipModel.contains("M2") || chipModel.contains("M3") || chipModel.contains("M4")
        let supportsAMX = true
        
 // 估算热设计功耗
        var thermalDesignPower: Double = 15.0 // 默认值
        if chipModel.contains("Pro") || chipModel.contains("Max") {
            thermalDesignPower = 30.0
        } else if chipModel.contains("Ultra") {
            thermalDesignPower = 60.0
        }
        
        return SystemInfo(
            isAppleSilicon: true,
            chipModel: chipModel,
            performanceCoreCount: performanceCoreCount,
            efficiencyCoreCount: efficiencyCoreCount,
            supportsUnifiedMemory: supportsUnifiedMemory,
            supportsNeuralEngine: supportsNeuralEngine,
            supportsAMX: supportsAMX,
            thermalDesignPower: thermalDesignPower
        )
    }
}

// MARK: - 数据结构

/// 系统信息
public struct SystemInfo: Sendable {
    let isAppleSilicon: Bool
    let chipModel: String
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int
    let supportsUnifiedMemory: Bool
    let supportsNeuralEngine: Bool
    let supportsAMX: Bool
    let thermalDesignPower: Double
}

/// 性能配置
public struct PerformanceConfig: Sendable {
    let maxConcurrentTasks: Int
    let preferredQueueCount: Int
    let memoryOptimizationLevel: MemoryOptimizationLevel
    let useNeuralEngine: Bool
    let useAMX: Bool
    let thermalThrottlingThreshold: Double
}

/// 优化建议
public struct OptimizationRecommendations: Sendable {
    let qosClass: QualityOfService
    let concurrency: Int
    let useGPU: Bool
    let useNeuralEngine: Bool
    let memoryStrategy: MemoryStrategy
    let schedulingHint: SchedulingHint
}

/// 内存策略
public enum MemoryStrategy: Sendable {
    case lowLatency    // 低延迟
    case balanced      // 平衡
    case conservative  // 保守
    case aggressive    // 激进
}

/// 调度提示
public enum SchedulingHint: Sendable {
    case interactive   // 交互式
    case responsive    // 响应式
    case throughput    // 吞吐量
    case compute       // 计算密集
    case io           // IO密集
    case background   // 后台
}

/// 系统热状态
public enum SystemThermalState: Sendable {
    case optimal      // 最佳状态
    case good         // 良好状态
    case throttled    // 降频状态
    case critical     // 临界状态
    case unknown      // 未知状态
}

/// Apple Silicon 电源状态
public enum AppleSiliconPowerState: Sendable {
    case normal       // 正常电源
    case lowPower     // 低功耗模式
}
