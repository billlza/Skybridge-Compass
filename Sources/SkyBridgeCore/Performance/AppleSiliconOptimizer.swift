import Foundation
import os.log
import Accelerate

/// Apple Silicon性能优化器
/// 专门针对M1-M4芯片的性能和效率核心优化
///
/// ⚡ Swift 6.2.1 改进：使用 actor 模型确保线程安全访问
@available(macOS 14.0, *)
public actor AppleSiliconOptimizer {
    
 // MARK: - 单例模式
    public static let shared = AppleSiliconOptimizer()
    
 // MARK: - 私有属性
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "AppleSiliconOptimizer")
    private let systemInfo: SystemInfo
    private var performanceCoreCount: Int = 0
    private var efficiencyCoreCount: Int = 0
    
 // MARK: - 系统信息结构
    public struct SystemInfo: Sendable {
        public let isAppleSilicon: Bool
        public let cpuBrand: String
        public let totalCoreCount: Int
        public let performanceCoreCount: Int
        public let efficiencyCoreCount: Int
        public let cacheLineSize: Int
        public let pageSize: Int
        
        public init(isAppleSilicon: Bool, cpuBrand: String, totalCoreCount: Int, performanceCoreCount: Int, efficiencyCoreCount: Int, cacheLineSize: Int, pageSize: Int) {
            self.isAppleSilicon = isAppleSilicon
            self.cpuBrand = cpuBrand
            self.totalCoreCount = totalCoreCount
            self.performanceCoreCount = performanceCoreCount
            self.efficiencyCoreCount = efficiencyCoreCount
            self.cacheLineSize = cacheLineSize
            self.pageSize = pageSize
        }
    }
    
 // MARK: - 初始化
    private init() {
        self.systemInfo = Self.detectSystemInfo()
        self.performanceCoreCount = self.systemInfo.performanceCoreCount
        self.efficiencyCoreCount = self.systemInfo.efficiencyCoreCount
        
 // 存储到局部变量以避免在 autoclosure 中访问 actor 隔离属性
        let cpuBrand = self.systemInfo.cpuBrand
        let perfCores = self.performanceCoreCount
        let effCores = self.efficiencyCoreCount
        
        logger.info("Apple Silicon优化器已初始化")
        logger.info("系统信息: \(cpuBrand)")
        logger.info("性能核心: \(perfCores), 效率核心: \(effCores)")
    }
    
 // MARK: - 系统检测
    private static func detectSystemInfo() -> SystemInfo {
        var isAppleSilicon = false
        var cpuBrand = "Unknown"
        
 // 获取 CPU 品牌信息
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brandString = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brandString, &size, nil, 0)
        
 // 使用推荐的方式处理 C 字符串
        let nullTerminatedData = Data(bytes: brandString, count: size)
        if let nullIndex = nullTerminatedData.firstIndex(of: 0) {
            let truncatedData = nullTerminatedData.prefix(upTo: nullIndex)
            cpuBrand = String(decoding: truncatedData, as: UTF8.self)
        } else {
            cpuBrand = String(decoding: nullTerminatedData, as: UTF8.self)
        }
        
 // 检测是否为Apple Silicon
        isAppleSilicon = cpuBrand.contains("Apple")
        
 // 获取核心数量信息
        var totalCores: Int32 = 0
        var performanceCores: Int32 = 0
        var efficiencyCores: Int32 = 0
        var cacheLineSize: Int32 = 0
        var pageSize: Int32 = 0
        
        size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &totalCores, &size, nil, 0)
        sysctlbyname("hw.perflevel0.logicalcpu", &performanceCores, &size, nil, 0)
        sysctlbyname("hw.perflevel1.logicalcpu", &efficiencyCores, &size, nil, 0)
        sysctlbyname("hw.cachelinesize", &cacheLineSize, &size, nil, 0)
        sysctlbyname("hw.pagesize", &pageSize, &size, nil, 0)
        
        return SystemInfo(
            isAppleSilicon: isAppleSilicon,
            cpuBrand: cpuBrand,
            totalCoreCount: Int(totalCores),
            performanceCoreCount: Int(performanceCores),
            efficiencyCoreCount: Int(efficiencyCores),
            cacheLineSize: Int(cacheLineSize),
            pageSize: Int(pageSize)
        )
    }
    
 // MARK: - 公共接口
    
 /// 检查是否运行在Apple Silicon上
    public var isAppleSilicon: Bool {
        return systemInfo.isAppleSilicon
    }
    
 /// 获取系统信息
    public func getSystemInfo() -> SystemInfo {
        return systemInfo
    }
    
 /// 为任务分配最优的QoS类别
 /// - Parameter taskType: 任务类型
 /// - Returns: 推荐的QoS类别
    public func recommendedQoS(for taskType: TaskType) -> DispatchQoS.QoSClass {
        guard isAppleSilicon else {
 // 非Apple Silicon设备使用默认策略
            return taskType.defaultQoS
        }
        
        switch taskType {
        case .userInterface:
            return .userInteractive // 在P核上运行，最高优先级
        case .userInitiated:
            return .userInitiated   // 在P核上运行，高优先级
        case .networkRequest:
            return .userInitiated   // 网络请求需要快速响应
        case .imageProcessing:
            return .utility         // 平衡性能和效率
        case .fileIO:
            return .utility         // 文件操作可以在E核上运行
        case .backgroundSync:
            return .background      // 在E核上运行，节省电量
        case .dataAnalysis:
            return .utility         // 数据分析可以利用多核
        }
    }
    
 /// 创建优化的并发队列
 /// - Parameters:
 /// - label: 队列标签
 /// - qos: QoS类别
 /// - attributes: 队列属性
 /// - Returns: 优化的调度队列
    public func createOptimizedQueue(
        label: String,
        qos: DispatchQoS.QoSClass,
        attributes: DispatchQueue.Attributes = .concurrent
    ) -> DispatchQueue {
        let queue = DispatchQueue(
            label: label,
            qos: DispatchQoS(qosClass: qos, relativePriority: 0),
            attributes: attributes,
            autoreleaseFrequency: .workItem
        )
        
        logger.debug("创建优化队列: \(label), QoS: \(String(describing: qos))")
        return queue
    }
    
 /// 执行并行计算任务，充分利用Apple Silicon的多核架构
 /// - Parameters:
 /// - iterations: 迭代次数
 /// - qos: QoS类别
 /// - execute: 执行块
    public func performParallelComputation<T: Sendable>(
        iterations: Int,
        qos: DispatchQoS.QoSClass = .userInitiated,
        execute: @escaping @Sendable (Int) -> T
    ) async -> [T] {
        guard isAppleSilicon && iterations > 1 else {
 // 非Apple Silicon或单次迭代，使用串行执行
            return (0..<iterations).map(execute)
        }
        
        return await withTaskGroup(of: [(Int, T)].self) { group in
 // 根据核心数量和QoS类别决定并发度
            let concurrency = qos == .userInteractive ? performanceCoreCount : 
                             qos == .background ? efficiencyCoreCount :
                             systemInfo.totalCoreCount
            
            let chunkSize = max(1, iterations / concurrency)
            
            for chunkStart in stride(from: 0, to: iterations, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, iterations)
                
                group.addTask {
                    let chunkResults = (chunkStart..<chunkEnd).map { index in
                        (index, execute(index))
                    }
                    return chunkResults
                }
            }
            
            var results: [(Int, T)] = []
            for await chunkResults in group {
                results.append(contentsOf: chunkResults)
            }
            
 // 按索引排序并返回结果
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
    
 /// 优化内存访问模式，利用Apple Silicon的缓存架构
 /// - Parameter dataSize: 数据大小（字节）
 /// - Returns: 推荐的块大小
    public func recommendedChunkSize(for dataSize: Int) -> Int {
        guard isAppleSilicon else {
            return 4096 // 默认页面大小
        }
        
        let cacheLineSize = systemInfo.cacheLineSize
        let pageSize = systemInfo.pageSize
        
 // 根据数据大小选择最优块大小
        if dataSize < cacheLineSize * 8 {
            return cacheLineSize
        } else if dataSize < pageSize * 16 {
            return pageSize
        } else {
 // 大数据集使用多个页面
            return pageSize * 4
        }
    }
    
 /// 使用Accelerate框架进行向量化计算
 /// - Parameters:
 /// - input: 输入数组
 /// - operation: 向量操作类型
 /// - Returns: 计算结果
    public func performVectorizedOperation(
        _ input: [Float],
        operation: VectorOperation
    ) -> [Float] {
        guard isAppleSilicon && input.count > 100 else {
 // 小数据集或非Apple Silicon使用标准计算
            return input.map(operation.standardOperation)
        }
        
        var result = [Float](repeating: 0, count: input.count)
        let count = vDSP_Length(input.count)
        
        switch operation {
        case .square:
            vDSP_vsq(input, 1, &result, 1, count)
        case .sqrt:
            vvsqrtf(&result, input, [Int32(count)])
        case .log:
            vvlogf(&result, input, [Int32(count)])
        case .exp:
            vvexpf(&result, input, [Int32(count)])
        case .sin:
            vvsinf(&result, input, [Int32(count)])
        case .cos:
            vvcosf(&result, input, [Int32(count)])
        }
        
        logger.debug("向量化操作完成: \(operation), 数据量: \(input.count)")
        return result
    }
    
 /// 使用统一内存架构进行优化的数据处理
 /// - Parameters:
 /// - data: 输入数据
 /// - operation: 处理操作
 /// - Returns: 处理结果
    public func performUnifiedMemoryOptimizedOperation<T: Sendable>(
        _ data: [T],
        operation: @escaping @Sendable (T) -> T
    ) async -> [T] {
        guard isAppleSilicon else {
 // 非Apple Silicon设备使用标准处理
            return data.map(operation)
        }
        
 // 利用统一内存架构的零拷贝特性
        return await withTaskGroup(of: [(Int, T)].self) { group in
            let chunkSize = recommendedChunkSize(for: data.count * MemoryLayout<T>.size)
            let elementsPerChunk = max(1, chunkSize / MemoryLayout<T>.size)
            
            for chunkStart in stride(from: 0, to: data.count, by: elementsPerChunk) {
                let chunkEnd = min(chunkStart + elementsPerChunk, data.count)
                
                group.addTask {
                    let chunkData = Array(data[chunkStart..<chunkEnd])
                    let processedChunk = chunkData.enumerated().map { (index, element) in
                        (chunkStart + index, operation(element))
                    }
                    return processedChunk
                }
            }
            
            var results: [(Int, T)] = []
            for await chunkResults in group {
                results.append(contentsOf: chunkResults)
            }
            
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
    
 /// 获取Apple Silicon GPU优化建议
 /// - Parameter workloadType: 工作负载类型
 /// - Returns: GPU优化配置
    public func getGPUOptimizationConfig(for workloadType: GPUWorkloadType) -> GPUOptimizationConfig {
        guard isAppleSilicon else {
            return GPUOptimizationConfig.default
        }
        
        switch workloadType {
        case .rendering:
            return GPUOptimizationConfig(
                preferredThreadgroupSize: MTLSize(width: 32, height: 32, depth: 1),
                memoryOptimization: .aggressive,
                useUnifiedMemory: true,
                enableTileMemory: true
            )
        case .compute:
            return GPUOptimizationConfig(
                preferredThreadgroupSize: MTLSize(width: 64, height: 1, depth: 1),
                memoryOptimization: .balanced,
                useUnifiedMemory: true,
                enableTileMemory: false
            )
        case .imageProcessing:
            return GPUOptimizationConfig(
                preferredThreadgroupSize: MTLSize(width: 16, height: 16, depth: 1),
                memoryOptimization: .aggressive,
                useUnifiedMemory: true,
                enableTileMemory: true
            )
        case .machineLearning:
            return GPUOptimizationConfig(
                preferredThreadgroupSize: MTLSize(width: 32, height: 8, depth: 1),
                memoryOptimization: .conservative,
                useUnifiedMemory: true,
                enableTileMemory: false
            )
        }
    }
    
 /// 优化内存分配策略，利用Apple Silicon的内存子系统
 /// - Parameter size: 分配大小
 /// - Returns: 优化的内存分配建议
    public func getOptimizedMemoryAllocation(size: Int) -> MemoryAllocationStrategy {
        guard isAppleSilicon else {
            return .standard
        }
        
        let pageSize = systemInfo.pageSize
        let cacheLineSize = systemInfo.cacheLineSize
        
        if size <= cacheLineSize {
            return .cacheAligned
        } else if size <= pageSize {
            return .pageAligned
        } else if size <= pageSize * 16 {
            return .multiPage
        } else {
            return .largeAllocation
        }
    }
}

// MARK: - 支持类型定义

/// 任务类型枚举
public enum TaskType: Sendable {
    case userInterface      // 用户界面更新
    case userInitiated      // 用户发起的操作
    case networkRequest     // 网络请求
    case imageProcessing    // 图像处理
    case fileIO            // 文件输入输出
    case backgroundSync    // 后台同步
    case dataAnalysis      // 数据分析
    
    var defaultQoS: DispatchQoS.QoSClass {
        switch self {
        case .userInterface: return .userInteractive
        case .userInitiated: return .userInitiated
        case .networkRequest: return .userInitiated
        case .imageProcessing: return .utility
        case .fileIO: return .utility
        case .backgroundSync: return .background
        case .dataAnalysis: return .utility
        }
    }
}

/// 向量操作类型
public enum VectorOperation: CustomStringConvertible {
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

// MARK: - 扩展方法

@available(macOS 14.0, *)
extension DispatchQueue {
 /// 创建Apple Silicon优化的队列
 /// - Parameters:
 /// - label: 队列标签
 /// - taskType: 任务类型
 /// - Returns: 优化的队列
    public static func appleSiliconOptimized(
        label: String,
        for taskType: TaskType
    ) async -> DispatchQueue {
        let qos = await AppleSiliconOptimizer.shared.recommendedQoS(for: taskType)
        return await AppleSiliconOptimizer.shared.createOptimizedQueue(
            label: label,
            qos: qos
        )
    }
}

/// GPU工作负载类型
public enum GPUWorkloadType {
    case rendering          // 渲染工作负载
    case compute           // 通用计算
    case imageProcessing   // 图像处理
    case machineLearning   // 机器学习
}

/// GPU优化配置
public struct GPUOptimizationConfig: Sendable {
    public let preferredThreadgroupSize: MTLSize
    public let memoryOptimization: MemoryOptimizationLevel
    public let useUnifiedMemory: Bool
    public let enableTileMemory: Bool
    
    public static let `default` = GPUOptimizationConfig(
        preferredThreadgroupSize: MTLSize(width: 32, height: 32, depth: 1),
        memoryOptimization: MemoryOptimizationLevel.balanced,
        useUnifiedMemory: false,
        enableTileMemory: false
    )
}

/// 内存优化级别
public enum MemoryOptimizationLevel: Sendable {
    case conservative   // 保守优化
    case balanced      // 平衡优化
    case aggressive    // 激进优化
}

/// 内存分配策略
public enum MemoryAllocationStrategy {
    case standard       // 标准分配
    case cacheAligned   // 缓存行对齐
    case pageAligned    // 页面对齐
    case multiPage      // 多页面分配
    case largeAllocation // 大内存分配
}