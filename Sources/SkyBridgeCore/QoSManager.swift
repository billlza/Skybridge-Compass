import Foundation
import Dispatch
import os.log

/// 任务优先级枚举
public enum TaskPriority: Sendable {
    case critical   // 关键任务，必须立即执行
    case important  // 重要任务，需要快速响应
    case normal     // 普通任务，正常优先级
    case background // 后台任务，可以延迟执行
}

/// 性能状态枚举
public enum PerformanceState: CustomStringConvertible, Sendable {
    case highPerformance  // 高性能模式，优先使用P核
    case balanced        // 平衡模式，P核和E核混合使用
    case lowPower        // 低功耗模式，优先使用E核
    
    public var description: String {
        switch self {
        case .highPerformance: return "高性能"
        case .balanced: return "平衡"
        case .lowPower: return "低功耗"
        }
    }
}

/// QoS管理器
/// 负责管理和优化系统的服务质量
@available(macOS 14.0, *)
public final class QoSManager: BaseManager {
    
 // MARK: - 单例模式
    public static let shared = QoSManager()
    
 // MARK: - 私有属性
    
    @available(macOS 14.0, *)
    private var optimizer: AppleSiliconOptimizer? {
        return AppleSiliconOptimizer.shared
    }
    
 // 使用actor确保线程安全
    private actor PerformanceStateManager {
        private var _currentState: PerformanceState = .balanced
        
        func getCurrentState() -> PerformanceState {
            return _currentState
        }
        
        func updateState(_ newState: PerformanceState) {
            _currentState = newState
        }
    }
    
    private let stateManager = PerformanceStateManager()
    
 // 热状态监控
    private var thermalState: ProcessInfo.ThermalState {
        return ProcessInfo.processInfo.thermalState
    }
    
    private init() {
        super.init(category: "QoSManager")
        logger.info("QoS管理器已初始化")
        
 // 监听热状态变化
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.updatePerformanceStateBasedOnThermal()
            }
        }
        
 // 初始化性能状态
        Task {
            await updatePerformanceStateBasedOnThermal()
        }
    }
    
    public override func performInitialization() async {
 // QoS管理器的初始化逻辑
        logger.info("QoS管理器初始化完成")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
 /// 获取当前性能状态
    public var currentPerformanceState: PerformanceState {
        get async {
            return await stateManager.getCurrentState()
        }
    }
    
 /// 根据热状态更新性能状态
    private func updatePerformanceStateBasedOnThermal() async {
        let newState: PerformanceState
        let currentThermalState = thermalState
        
        switch currentThermalState {
        case .nominal:
            newState = .highPerformance
        case .fair:
            newState = .balanced
        case .serious, .critical:
            newState = .lowPower
        @unknown default:
            newState = .balanced
        }
        
        await stateManager.updateState(newState)
        logger.info("性能状态已更新: \(newState) (热状态: \(currentThermalState.rawValue))")
    }
    
 /// 根据任务类型和当前性能状态推荐QoS
    public func recommendedQoS(for taskType: TaskType, priority: TaskPriority = .normal) async -> DispatchQoS.QoSClass {
 // 检查是否为Apple Silicon并获取优化器
        guard let optimizer = optimizer, await optimizer.isAppleSilicon else {
            return standardQoSMapping(for: taskType)
        }
        
        let currentState = await currentPerformanceState
        
 // Apple Silicon优化的QoS选择
        switch (priority, currentState) {
        case (.critical, _):
            return .userInteractive  // 关键任务始终使用最高优先级（P核）
            
        case (.important, .highPerformance), (.important, .balanced):
            return .userInitiated    // 重要任务在高性能/平衡模式下使用P核
            
        case (.important, .lowPower):
            return .default          // 重要任务在低功耗模式下降级到E核
            
        case (.normal, .highPerformance):
            return taskType == .userInterface ? .userInitiated : .default
            
        case (.normal, .balanced):
            return .default          // 普通任务在平衡模式下使用E核
            
        case (.normal, .lowPower):
            return .utility          // 普通任务在低功耗模式下进一步降级
            
        case (.background, _):
            return .background       // 后台任务始终使用最低优先级（E核）
        }
    }
    
 /// 标准QoS映射（非Apple Silicon设备）
    private func standardQoSMapping(for taskType: TaskType) -> DispatchQoS.QoSClass {
        return taskType.defaultQoS
    }
    
 /// 创建针对Apple Silicon优化的队列
    public func createOptimizedQueue(
        label: String,
        taskType: TaskType,
        priority: TaskPriority = .normal,
        concurrent: Bool = false
    ) async -> DispatchQueue {
        let qos = await recommendedQoS(for: taskType, priority: priority)
        let attributes: DispatchQueue.Attributes = concurrent ? .concurrent : []
        
        let queue = DispatchQueue(
            label: "com.skybridge.compass.\(label)",
            qos: DispatchQoS(qosClass: qos, relativePriority: 0),
            attributes: attributes
        )
        
        logger.debug("创建优化队列: \(label) - QoS: \(qos.description) - 并发: \(concurrent)")
        
        return queue
    }
    
 /// 执行优化任务
    public func executeOptimizedTask<T: Sendable>(
        taskType: TaskType,
        priority: TaskPriority = .normal,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let qos = await recommendedQoS(for: taskType, priority: priority)
        
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: TaskPriority.toSwiftTaskPriority(qos)) {
                return try await operation()
            }
            
            guard let result = try await group.next() else {
                throw NSError(domain: "QoSManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "任务执行失败"])
            }
            
            return result
        }
    }
    
 /// 批量执行任务
    public func executeBatchTasks<T: Sendable>(
        tasks: [(TaskType, TaskPriority, @Sendable () async throws -> T)],
        maxConcurrency: Int? = nil
    ) async throws -> [T] {
        let concurrency: Int
        if let maxConcurrency = maxConcurrency {
            concurrency = maxConcurrency
        } else {
            concurrency = await recommendedConcurrency(for: .dataAnalysis)
        }
        
        return try await withThrowingTaskGroup(of: (Int, T).self, returning: [T].self) { group in
            var results: [(Int, T)] = []
            
            for (index, (taskType, priority, operation)) in tasks.enumerated() {
 // 控制并发数量
                if index >= concurrency {
                    if let (completedIndex, result) = try await group.next() {
                        results.append((completedIndex, result))
                    }
                }
                
                group.addTask { [taskType, priority] in
                    let qos = await QoSManager.shared.recommendedQoS(for: taskType, priority: priority)
                    
                    return try await withThrowingTaskGroup(of: T.self) { innerGroup in
                        innerGroup.addTask(priority: TaskPriority.toSwiftTaskPriority(qos)) {
                            return try await operation()
                        }
                        
                        guard let result = try await innerGroup.next() else {
                            throw NSError(domain: "QoSManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "批量任务执行失败"])
                        }
                        
                        return (index, result)
                    }
                }
            }
            
 // 收集剩余结果
            while let (completedIndex, result) = try await group.next() {
                results.append((completedIndex, result))
            }
            
 // 按原始顺序排序并返回结果
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
    
 /// 推荐并发数
    public func recommendedConcurrency(for taskType: TaskType) async -> Int {
 // 如果不是Apple Silicon，使用处理器核心数
        guard let optimizer = optimizer, await optimizer.isAppleSilicon else {
            return ProcessInfo.processInfo.processorCount
        }
        
        let currentState = await currentPerformanceState
        let systemInfo = await optimizer.getSystemInfo()
        
        switch (taskType, currentState) {
        case (.userInterface, .highPerformance):
            return min(2, systemInfo.performanceCoreCount) // UI任务限制并发
            
        case (.dataAnalysis, .highPerformance):
            return systemInfo.performanceCoreCount // 数据处理在高性能模式下使用所有P核
            
        case (.dataAnalysis, .balanced):
            return systemInfo.performanceCoreCount + systemInfo.efficiencyCoreCount / 2
            
        case (.dataAnalysis, .lowPower):
            return systemInfo.efficiencyCoreCount // 低功耗模式仅使用E核
            
        case (.networkRequest, _):
            return min(4, systemInfo.performanceCoreCount + systemInfo.efficiencyCoreCount) // 网络请求适度并发
            
        case (.fileIO, _):
            return min(2, systemInfo.efficiencyCoreCount) // 文件IO使用E核
            
        default:
 // 默认情况：使用所有核心
            return systemInfo.performanceCoreCount + systemInfo.efficiencyCoreCount
        }
    }
    
 /// 监控队列性能
    public func monitorQueuePerformance(queue: DispatchQueue, taskType: TaskType) {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        queue.async { [weak self] in
            let endTime = CFAbsoluteTimeGetCurrent()
            let executionTime = endTime - startTime
            
            self?.logger.debug("队列性能监控 - 任务类型: \(String(describing: taskType)), 执行时间: \(executionTime)ms")
            
 // 如果执行时间过长，记录警告
            if executionTime > 0.1 { // 100ms阈值
                self?.logger.warning("队列执行时间过长: \(executionTime)ms - 任务类型: \(String(describing: taskType))")
            }
        }
    }
}

// MARK: - 扩展方法

extension TaskPriority {
 /// 转换为Swift TaskPriority
    static func toSwiftTaskPriority(_ qos: DispatchQoS.QoSClass) -> _Concurrency.TaskPriority {
        switch qos {
        case .userInteractive:
            return .high
        case .userInitiated:
            return .medium
        case .default, .utility:
            return .medium
        case .background:
            return .low
        case .unspecified:
            return .medium
        @unknown default:
            return .medium
        }
    }
}

extension DispatchQoS.QoSClass {
 /// 获取QoS描述
    var description: String {
        switch self {
        case .userInteractive: return "userInteractive"
        case .userInitiated: return "userInitiated"
        case .default: return "default"
        case .utility: return "utility"
        case .background: return "background"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }
}