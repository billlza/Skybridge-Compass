import Foundation
import Combine
import SkyBridgeCore
import os.log
import os.lock
import Network

/// 仪表盘数据加载服务
/// 将原来在View中的外部命令和mach API调用移动到此服务中
@available(macOS 14.0, *)
@MainActor
public final class DashboardDataService: ObservableObject {
    
 // MARK: - Published Properties
    
    @Published public private(set) var cpuUsage: Double = 0.0
    @Published public private(set) var memoryFootprint: Int = 0 // MB
    @Published public private(set) var cpuTime: Int = 0 // ms
    @Published public private(set) var systemLoadAverage: Double = 0.0
    @Published public private(set) var isNetworkConnected: Bool = false
    @Published public private(set) var isLoading: Bool = false
    
 // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.skybridge.SkyBridgeCompassApp", category: "DashboardDataService")
    private var optimizer: AppleSiliconOptimizer? {
        return AppleSiliconOptimizer.shared
    }
    
 // MARK: - Initialization
    
    public init() {}
    
 // MARK: - Public Methods
    
 /// 使用Apple Silicon优化的数据加载策略
    public func loadDashboardDataOptimized() async {
        guard let optimizer = optimizer, optimizer.isAppleSilicon else {
            logger.info("使用标准数据加载模式")
            return
        }
        
        isLoading = true
        
 // 使用Apple Silicon优化的并行加载
        let loadTasks = [
            ("网络状态", SkyBridgeCore.TaskType.networkRequest),
            ("系统监控", SkyBridgeCore.TaskType.dataAnalysis),
            ("设备信息", SkyBridgeCore.TaskType.fileIO),
            ("性能指标", SkyBridgeCore.TaskType.dataAnalysis)
        ]
        
        await withTaskGroup(of: Void.self) { group in
            for (taskName, taskType) in loadTasks {
                group.addTask {
                    let qos = optimizer.recommendedQoS(for: taskType)
                    let _ = await DispatchQueue.appleSiliconOptimized(
                        label: "dashboard.\(taskName.lowercased().replacingOccurrences(of: " ", with: ""))",
                        for: taskType
                    )
                    
                    let actualDataSize = await self.getActualDataSize(for: taskType)
                    let chunkSize = optimizer.recommendedChunkSize(for: actualDataSize)
                    
                    self.logger.debug("加载\(taskName)数据 - QoS: \(String(describing: qos)), 实际数据大小: \(actualDataSize), 块大小: \(chunkSize)")
                    
                    await self.performActualDataLoading(for: taskType, chunkSize: chunkSize)
                }
            }
        }
        
        isLoading = false
        logger.info("仪表板数据加载完成 - 使用Apple Silicon优化")
    }
    
 /// 获取系统负载平均值
    public func getSystemLoadAverage() -> Double {
        var loadAvg: [Double] = [0.0, 0.0, 0.0]
        let result = getloadavg(&loadAvg, 3)
        let avg = result > 0 ? loadAvg[0] : 0.0
        self.systemLoadAverage = avg
        return avg
    }
    
 /// 获取CPU使用率（使用真实系统数据）
    public func fetchCPUUsage() async -> Double {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.launchPath = "/usr/bin/top"
            process.arguments = ["-l", "1", "-n", "0"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            let resumed = OSAllocatedUnfairLock(initialState: false)
            
            process.terminationHandler = { _ in
                let shouldResume = resumed.withLock { isResumed -> Bool in
                    guard !isResumed else { return false }
                    isResumed = true
                    return true
                }
                guard shouldResume else { return }
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8),
                   let cpuLine = output.components(separatedBy: "\n").first(where: { $0.contains("CPU usage") }),
                   let userMatch = cpuLine.range(of: #"(\d+\.\d+)% user"#, options: .regularExpression) {
                    let userStr = String(cpuLine[userMatch]).replacingOccurrences(of: "% user", with: "")
                    let cpuUsage = Double(userStr) ?? 0.0
                    continuation.resume(returning: cpuUsage)
                } else {
                    continuation.resume(returning: 0.0)
                }
            }
            
            do {
                try process.run()
            } catch {
                let shouldResume = resumed.withLock { isResumed -> Bool in
                    guard !isResumed else { return false }
                    isResumed = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(returning: 0.0)
            }
        }
    }
    
 /// 获取应用内存占用（使用mach API）
    public func fetchMemoryFootprint() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let footprint = Int(info.resident_size) / (1024 * 1024) // 转换为MB
            self.memoryFootprint = footprint
            return footprint
        } else {
            return 0
        }
    }
    
 /// 获取CPU时间（使用mach API）
    public func fetchCPUTime() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let time = Int(info.user_time.seconds * 1000 + info.user_time.microseconds / 1000) // 转换为毫秒
            self.cpuTime = time
            return time
        } else {
            return 0
        }
    }
    
 /// 执行网络状态检查（使用 Network.framework）
    public func performNetworkStatusCheck() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue.global(qos: .utility)
            let resumed = OSAllocatedUnfairLock(initialState: false)
            
            monitor.pathUpdateHandler = { path in
                let shouldResume = resumed.withLock { isResumed -> Bool in
                    guard !isResumed else { return false }
                    isResumed = true
                    return true
                }
                guard shouldResume else { return }
                
                Task { @MainActor in
                    self.isNetworkConnected = path.status == .satisfied
                }
                monitor.cancel()
                continuation.resume(returning: ())
            }
            
            monitor.start(queue: queue)
            
 // 超时保护
            queue.asyncAfter(deadline: .now() + 3) {
                let shouldResume = resumed.withLock { isResumed -> Bool in
                    guard !isResumed else { return false }
                    isResumed = true
                    return true
                }
                guard shouldResume else { return }
                self.logger.debug("网络连通性检查超时，默认未连接")
                monitor.cancel()
                continuation.resume(returning: ())
            }
        }
    }
    
 // MARK: - Private Methods
    
 /// 获取实际数据大小，基于任务类型使用Apple官方API
    private func getActualDataSize(for taskType: SkyBridgeCore.TaskType) async -> Int {
        switch taskType {
        case .networkRequest:
 // 使用Network framework获取网络接口信息
            return await withCheckedContinuation { continuation in
                let process = Process()
                process.launchPath = "/usr/sbin/netstat"
                process.arguments = ["-i"]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                
                let resumed = OSAllocatedUnfairLock(initialState: false)
                
                process.terminationHandler = { _ in
                    let shouldResume = resumed.withLock { isResumed -> Bool in
                        guard !isResumed else { return false }
                        isResumed = true
                        return true
                    }
                    guard shouldResume else { return }
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: data.count)
                }
                
                do {
                    try process.run()
                } catch {
                    let shouldResume = resumed.withLock { isResumed -> Bool in
                        guard !isResumed else { return false }
                        isResumed = true
                        return true
                    }
                    guard shouldResume else { return }
                    continuation.resume(returning: 4096)
                }
            }
            
        case .dataAnalysis:
            let processInfo = ProcessInfo.processInfo
            let systemUptime = processInfo.systemUptime
            let physicalMemory = processInfo.physicalMemory
            
            let baseSize = MemoryLayout<Double>.size * 10
            let memoryInfoSize = Int(physicalMemory / (1024 * 1024 * 1024)) * 100
            let uptimeSize = Int(systemUptime) / 60
            
            return baseSize + memoryInfoSize + uptimeSize
            
        case .fileIO:
            let fileManager = FileManager.default
            if let systemAttributes = try? fileManager.attributesOfFileSystem(forPath: "/") {
                let totalSpace = systemAttributes[.systemSize] as? NSNumber ?? 0
                let freeSpace = systemAttributes[.systemFreeSize] as? NSNumber ?? 0
                
                let storageRatio = Double(freeSpace.int64Value) / Double(totalSpace.int64Value)
                let storageBasedSize = Int(storageRatio * 8192) + 2048
                
                return storageBasedSize
            } else {
                return 2048
            }
            
        default:
            let loadAverage = getSystemLoadAverage()
            return Int(loadAverage * 1024) + 1024
        }
    }
    
 /// 执行真实的数据加载操作
    private func performActualDataLoading(for taskType: SkyBridgeCore.TaskType, chunkSize: Int) async {
        switch taskType {
        case .networkRequest:
            await performNetworkStatusCheck()
            
        case .dataAnalysis:
            await performSystemMonitoringDataCollection()
            
        case .fileIO:
            await performDeviceInfoCollection()
            
        default:
            await performPerformanceMetricsCollection()
        }
    }
    
 /// 执行系统监控数据收集
    private func performSystemMonitoringDataCollection() async {
        let processInfo = ProcessInfo.processInfo
        
        let cpu = await fetchCPUUsage()
        self.cpuUsage = cpu
        
        let memoryUsage = Double(processInfo.physicalMemory) / (1024.0 * 1024.0 * 1024.0)
        let loadAverage = getSystemLoadAverage()
        
        logger.debug("系统监控数据收集完成 - CPU: \(cpu)%, 内存: \(memoryUsage)GB, 负载: \(loadAverage)")
    }
    
 /// 执行设备信息收集
    private func performDeviceInfoCollection() async {
        let processInfo = ProcessInfo.processInfo
        
        let hostName = processInfo.hostName
        let osVersion = processInfo.operatingSystemVersionString
        let processorCount = processInfo.processorCount
        
        let fileManager = FileManager.default
        do {
            let systemAttributes = try fileManager.attributesOfFileSystem(forPath: "/")
            let totalSpace = systemAttributes[.systemSize] as? NSNumber ?? 0
            let freeSpace = systemAttributes[.systemFreeSize] as? NSNumber ?? 0
            
            logger.debug("设备信息收集完成 - 主机: \(hostName), 系统: \(osVersion), CPU核心: \(processorCount), 存储: \(totalSpace.int64Value / (1024*1024*1024))GB (可用: \(freeSpace.int64Value / (1024*1024*1024))GB)")
        } catch {
            logger.error("设备存储信息收集失败: \(error.localizedDescription)")
        }
    }
    
 /// 执行性能指标收集
    private func performPerformanceMetricsCollection() async {
        let memFootprint = fetchMemoryFootprint()
        let cpuT = fetchCPUTime()
        
        logger.debug("性能指标收集完成 - 内存占用: \(memFootprint)MB, CPU时间: \(cpuT)ms")
    }
}

