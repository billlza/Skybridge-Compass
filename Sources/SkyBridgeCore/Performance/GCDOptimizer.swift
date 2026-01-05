import Foundation
import Dispatch
import os.log

/// GCD优化器，专门针对Apple Silicon的多核架构进行优化
@available(macOS 14.0, *)
@MainActor
public final class GCDOptimizer: @unchecked Sendable {
    public static let shared = GCDOptimizer()
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "GCDOptimizer")
    @available(macOS 14.0, *)
    private var optimizer: AppleSiliconOptimizer? {
        return AppleSiliconOptimizer.shared
    }
    private let qosManager: QoSManager
    
 // 预创建的优化队列池
    private let queuePool: QueuePool
    
 // 工作负载监控
    private let workloadMonitor = WorkloadMonitor()
    
    private init() {
 // 现在可以直接访问QoSManager.shared，因为我们在MainActor上
        self.qosManager = QoSManager.shared
        self.queuePool = QueuePool()
        logger.info("GCD优化器已初始化")
        
 // 启动工作负载监控
        Task {
            await workloadMonitor.startMonitoring()
        }
    }
    
    deinit {
 // 不能在deinit中使用async操作
 // workloadMonitor会在其自己的deinit中清理
    }
    
 // MARK: - 公共接口
    
 /// 获取优化的队列
    public func getOptimizedQueue(for taskType: TaskType, priority: TaskPriority = .normal) async -> DispatchQueue {
        return await queuePool.getQueue(for: taskType, priority: priority)
    }
    
 /// 执行并行任务，自动优化核心分配
    public func executeParallelTasks<T: Sendable>(
        tasks: [@Sendable () async throws -> T],
        taskType: TaskType = .dataAnalysis,
        priority: TaskPriority = .normal
    ) async throws -> [T] {
        let optimalConcurrency = await calculateOptimalConcurrency(for: taskType, taskCount: tasks.count)
        
        logger.debug("执行并行任务: \(tasks.count)个任务，最优并发数: \(optimalConcurrency)")
        
        return try await withThrowingTaskGroup(of: (Int, T).self, returning: [T].self) { group in
            var results: [(Int, T)] = []
            
 // 分批执行任务以控制并发
            for (index, task) in tasks.enumerated() {
 // 如果达到并发限制，等待一个任务完成
                if index >= optimalConcurrency {
                    if let (completedIndex, result) = try await group.next() {
                        results.append((completedIndex, result))
                    }
                }
                
 // 添加新任务
                group.addTask(priority: await getTaskPriority(for: taskType, priority: priority)) {
                    let result = try await task()
                    return (index, result)
                }
            }
            
 // 收集剩余结果
            while let (completedIndex, result) = try await group.next() {
                results.append((completedIndex, result))
            }
            
 // 按原始顺序返回结果
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
    
 /// 执行CPU密集型任务，优化P核使用
    public func executeCPUIntensiveTask<T: Sendable>(
        _ task: @escaping @Sendable () async throws -> T,
        priority: TaskPriority = .important
    ) async throws -> T {
        let queue = await getOptimizedQueue(for: .dataAnalysis, priority: priority)
        
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                Task {
                    do {
                        let result = try await task()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
 /// 执行IO密集型任务，优化E核使用
    public func executeIOIntensiveTask<T: Sendable>(
        _ task: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let queue = await getOptimizedQueue(for: .fileIO, priority: .normal)
        
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                Task {
                    do {
                        let result = try await task()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
 /// 批量处理数据，自动分片和负载均衡
    public func processBatchData<Input: Sendable, Output: Sendable>(
        data: [Input],
        chunkSize: Int? = nil,
        processor: @escaping @Sendable ([Input]) async throws -> [Output]
    ) async throws -> [Output] {
        guard !data.isEmpty else { return [] }
        
        let optimalChunkSize: Int
        if let chunkSize = chunkSize {
            optimalChunkSize = chunkSize
        } else {
            optimalChunkSize = await calculateOptimalChunkSize(for: data.count)
        }
        let chunks = data.chunked(into: optimalChunkSize)
        
        logger.debug("批量处理数据: \(data.count)项，分为\(chunks.count)个块，每块\(optimalChunkSize)项")
        
        let chunkTasks: [@Sendable () async throws -> [Output]] = chunks.map { chunk in
            return { try await processor(chunk) }
        }
        
        let results = try await executeParallelTasks(
            tasks: chunkTasks,
            taskType: .dataAnalysis,
            priority: .normal
        )
        
        return results.flatMap { $0 }
    }
    
 // MARK: - 私有方法
    
 /// 计算最优并发数
    private func calculateOptimalConcurrency(for taskType: TaskType, taskCount: Int) async -> Int {
        let systemInfo: AppleSiliconOptimizer.SystemInfo
        if let optimizerInfo = await optimizer?.getSystemInfo() {
            systemInfo = optimizerInfo
        } else {
            systemInfo = AppleSiliconOptimizer.SystemInfo(
                isAppleSilicon: false,
                cpuBrand: "Unknown",
                totalCoreCount: 4,
                performanceCoreCount: 2,
                efficiencyCoreCount: 2,
                cacheLineSize: 64,
                pageSize: 4096
            )
        }
        
        let currentLoad = await workloadMonitor.getCurrentLoad()
        let recommendedConcurrency = await qosManager.recommendedConcurrency(for: taskType)
        
 // 根据当前系统负载调整并发数
        let loadAdjustment: Double
        switch currentLoad {
        case 0.0..<0.3:
            loadAdjustment = 1.0  // 低负载，使用全部推荐并发
        case 0.3..<0.7:
            loadAdjustment = 0.7  // 中等负载，减少30%
        case 0.7..<0.9:
            loadAdjustment = 0.5  // 高负载，减少50%
        default:
            loadAdjustment = 0.3  // 极高负载，大幅减少
        }
        
        let adjustedConcurrency = Int(Double(recommendedConcurrency) * loadAdjustment)
        let totalCores = systemInfo.performanceCoreCount + systemInfo.efficiencyCoreCount
        let finalConcurrency = min(adjustedConcurrency, taskCount, totalCores)
        
        logger.debug("并发数计算: 推荐=\(recommendedConcurrency), 负载=\(currentLoad), 调整后=\(finalConcurrency)")
        
        return max(1, finalConcurrency)
    }
    
 /// 计算最优分片大小
    private func calculateOptimalChunkSize(for itemCount: Int) async -> Int {
 // 获取系统信息，但不使用具体值
        _ = await optimizer?.getSystemInfo()
        
        let recommendedConcurrency = await qosManager.recommendedConcurrency(for: .dataAnalysis)
        
 // 基于核心数和数据量计算分片大小
        let baseChunkSize = max(1, itemCount / (recommendedConcurrency * 2))
        
 // 限制分片大小范围
        let minChunkSize = 10
        let maxChunkSize = 1000
        
        return min(maxChunkSize, max(minChunkSize, baseChunkSize))
    }
    
 /// 获取任务优先级
    private func getTaskPriority(for taskType: TaskType, priority: TaskPriority) async -> _Concurrency.TaskPriority {
        let qos = await qosManager.recommendedQoS(for: taskType, priority: priority)
        return TaskPriority.toSwiftTaskPriority(qos)
    }
}

// MARK: - 队列池

@available(macOS 14.0, *)
@MainActor
private final class QueuePool: @unchecked Sendable {
    private let queueCache = NSCache<NSString, DispatchQueue>()
    private let qosManager: QoSManager
    
    init() {
        queueCache.countLimit = 20  // 限制缓存的队列数量
        self.qosManager = QoSManager.shared  // 现在可以直接访问，因为我们在MainActor上
    }
    
    func getQueue(for taskType: TaskType, priority: TaskPriority) async -> DispatchQueue {
        let cacheKey = "\(taskType)_\(priority)" as NSString
        
        if let cachedQueue = queueCache.object(forKey: cacheKey) {
            return cachedQueue
        }
        
        let queue = await qosManager.createOptimizedQueue(
            label: "gcd_optimizer_\(taskType)_\(priority)",
            taskType: taskType,
            priority: priority,
            concurrent: true
        )
        
        queueCache.setObject(queue, forKey: cacheKey)
        return queue
    }
}

// MARK: - 工作负载监控

@available(macOS 14.0, *)
private actor WorkloadMonitor {
    private var isMonitoring = false
    private var currentLoad: Double = 0.0
    private var monitoringTask: Task<Void, Never>?
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        monitoringTask = Task {
            while !Task.isCancelled && isMonitoring {
                updateSystemLoad()  // 移除不必要的 await
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒更新一次
            }
        }
    }
    
    func stopMonitoring() {
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }
    
    func getCurrentLoad() -> Double {
        return currentLoad
    }
    
    private func updateSystemLoad() {
 // 获取系统负载信息
        var loadAvg = [Double](repeating: 0.0, count: 3)
        let result = getloadavg(&loadAvg, 3)
        
        if result > 0 {
 // 使用1分钟平均负载，并标准化到0-1范围
            let processorCount = Double(ProcessInfo.processInfo.processorCount)
            currentLoad = min(1.0, loadAvg[0] / processorCount)
        }
    }
}

// MARK: - 扩展方法

internal extension Array {
 /// 将数组分割成指定大小的块
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension TaskPriority {
 /// 转换为Swift TaskPriority
    func toSwiftTaskPriority() -> _Concurrency.TaskPriority {
        switch self {
        case .background:
            return .low
        case .normal:
            return .medium
        case .important:
            return .high
        case .critical:
            return .high
        }
    }
}