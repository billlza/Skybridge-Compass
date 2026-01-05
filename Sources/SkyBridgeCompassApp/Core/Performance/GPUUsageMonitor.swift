import Foundation
import Metal
import OSLog
import IOKit
import IOKit.ps
@preconcurrency import SkyBridgeCore
import QuartzCore
import CoreFoundation

/// GPU利用率监控器
/// 使用IOKit和Metal API获取真实的GPU使用情况
@available(macOS 14.0, *)
public final class GPUUsageMonitor: @unchecked Sendable {
    
 // MARK: - 属性
    
 /// 日志记录器
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "GPUUsageMonitor")
    
 /// Metal设备
    private let metalDevice: MTLDevice?
    
 /// 命令队列
    private let commandQueue: MTLCommandQueue?
    
 /// GPU统计信息
    private var previousGPUTime: CFTimeInterval = 0
    private var previousSystemTime: CFTimeInterval = 0
    
 /// 监控状态
    private var isMonitoring: Bool = false
    
 /// 监控任务
    private var monitoringTask: Task<Void, Never>?
    
 /// 当前GPU利用率
    @MainActor
    public private(set) var currentUsage: Double = 0.0

 // Powermetrics缓存（避免频繁调用外部工具导致阻塞或高开销）
    private var lastGPUSampleTime: Date = .distantPast
    private var cachedResidencyPercent: Double = 0.0
    private var lastPowermetricsGPUTime: Date = .distantPast
    private var cachedGPUWatts: Double = 0.0
    private let emaAlpha: Double = 0.3 // 指数平滑系数，增强峰值识别灵敏度
    
 // MARK: - 初始化
    
    public init() {
        self.metalDevice = MTLCreateSystemDefaultDevice()
        self.commandQueue = metalDevice?.makeCommandQueue()
        
        logger.info("GPU使用率监控器初始化完成")
    }
    
 // MARK: - 公共方法
    
 /// 开始GPU监控
    public func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        
 // 使用并发系统监控器进行GPU监控
        Task {
            await ConcurrentSystemMonitor.shared.registerCallback(for: .gpu) { [weak self] data in
                 if let gpuData = data as? GPUData {
                     Task { @MainActor in
                         self?.currentUsage = gpuData.usage
                     }
                 }
             }
            await ConcurrentSystemMonitor.shared.startMonitoring()
        }
        
 // 同时启动传统监控作为备用
        startLegacyMonitoring()
        
        logger.debugOnly("🎮 GPU监控已启动")
    }
    
 /// 启动传统GPU监控方式（用于旧版本macOS）
    private func startLegacyMonitoring() {
        monitoringTask = Task {
            while !Task.isCancelled && isMonitoring {
                await performMonitoring()
                
 // 根据用户要求，将GPU监控频率调整为5秒，避免卡顿
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    
 /// 停止监控GPU使用率
    public func stopMonitoring() {
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
        
        logger.info("停止监控GPU使用率")
    }
    
 /// 获取当前GPU使用率
    public func getCurrentGPUUsage() async -> Double {
 // 优先读取Apple Silicon的powermetrics活跃驻留率（异步、带缓存），与Metal估算融合
        let metalEstimate = await getGPUUsageFromMetal()

        var residencyPercent = cachedResidencyPercent
        let now = Date()
        if now.timeIntervalSince(lastGPUSampleTime) >= 12.0 { // 12秒更新一次powermetrics缓存
            lastGPUSampleTime = now
            if let residency = await readGPUActiveResidencyViaPowerMetrics() {
 // 转为百分比并做EMA平滑
                let percent = max(0.0, min(100.0, residency * 100.0))
                cachedResidencyPercent = emaAlpha * percent + (1 - emaAlpha) * cachedResidencyPercent
                residencyPercent = cachedResidencyPercent
            } else if let tempEst = await estimateGPUUsageFromTemperatureViaPowerMetrics() {
 // 没有residency时，用温度估算与Metal融合
                cachedResidencyPercent = emaAlpha * tempEst + (1 - emaAlpha) * cachedResidencyPercent
                residencyPercent = cachedResidencyPercent
            }
        }

 // 融合策略——有residency时以其为主，无则以Metal与温度估算融合
        let fused: Double
        if residencyPercent > 0 {
            fused = min(max(0.7 * residencyPercent + 0.3 * metalEstimate, 0.0), 100.0)
        } else {
            fused = min(max(0.6 * metalEstimate + 0.4 * cachedResidencyPercent, 0.0), 100.0)
        }
        return fused
    }
    
 // MARK: - 私有方法
    
 /// 执行监控循环
    private func performMonitoring() async {
        while isMonitoring && !Task.isCancelled {
            let usage = await getGPUUsageFromMetal()
            
            await MainActor.run {
                self.currentUsage = usage
            }
            
 // 根据用户要求，将GPU使用率更新频率调整为5秒一次
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
    
 /// 从Metal获取GPU使用率
    private func getGPUUsageFromMetal() async -> Double {
        guard let device = metalDevice,
              let commandQueue = commandQueue else {
            return 0.0
        }
        
 // 方法1: 使用Metal命令缓冲区执行时间估算
        let usage = await estimateGPUUsageFromCommandBuffer(device: device, commandQueue: commandQueue)
        
 // 方法2: 如果Metal方法不可用，尝试使用IOKit
        if usage == 0.0 {
            return getGPUUsageFromIOKit()
        }
        
        return usage
    }
    
 /// 通过Metal命令缓冲区估算GPU使用率
    private func estimateGPUUsageFromCommandBuffer(device: MTLDevice, commandQueue: MTLCommandQueue) async -> Double {
        return await withCheckedContinuation { continuation in
 // 创建一个简单的计算任务来测量GPU响应时间
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                continuation.resume(returning: 0.0)
                return
            }
            
            let startTime = CACurrentMediaTime()
            
            commandBuffer.addCompletedHandler { _ in
                let endTime = CACurrentMediaTime()
                let executionTime = endTime - startTime
                
 // 基于执行时间估算GPU使用率
 // 这是一个简化的估算方法
                let estimatedUsage = min(executionTime * 100.0, 100.0)
                continuation.resume(returning: estimatedUsage)
            }
            
            commandBuffer.commit()
 // 避免阻塞线程，移除waitUntilCompleted；通过完成回调异步返回结果
        }
    }
    
 /// 使用IOKit获取GPU使用率
    private func getGPUUsageFromIOKit() -> Double {
        var iterator: io_iterator_t = 0
        var usage: Double = 0.0
        
 // 查找GPU设备
        let matchingDict = IOServiceMatching("IOPCIDevice")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        
        guard result == KERN_SUCCESS else {
            logger.warning("无法获取IOKit服务")
            return 0.0
        }
        
        defer {
            IOObjectRelease(iterator)
        }
        
 // 正确遍历迭代器，避免重复调用IOIteratorNext导致跳项
        var service: io_registry_entry_t = IOIteratorNext(iterator)
        while service != 0 {
            
 // 检查是否为GPU设备
            if let deviceName = getIORegistryProperty(service: service, key: "model") as? Data,
               let nameString = String(data: deviceName, encoding: .utf8),
               (nameString.contains("GPU") || nameString.contains("Graphics")) {
                
 // 尝试获取GPU利用率信息
                if let utilizationData = getIORegistryProperty(service: service, key: "PerformanceStatistics") as? [String: Any] {
 // 解析性能统计数据
                    usage = parseGPUUtilization(from: utilizationData)
                    break
                }
            }
            
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        
        return usage
    }
    
 /// 获取IORegistry属性
    private func getIORegistryProperty(service: io_registry_entry_t, key: String) -> Any? {
        let cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, CFStringBuiltInEncodings.UTF8.rawValue)
        let property = IORegistryEntryCreateCFProperty(service, cfKey, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue()
    }
    
 /// 解析GPU利用率数据
    private func parseGPUUtilization(from data: [String: Any]) -> Double {
 // 尝试从性能统计数据中提取GPU利用率
 // 不同的GPU驱动可能有不同的键名
        let possibleKeys = [
            "Device Utilization %",
            "GPU Utilization",
            "utilization",
            "usage",
            "load"
        ]
        
        for key in possibleKeys {
            if let value = data[key] as? NSNumber {
                return min(max(value.doubleValue, 0.0), 100.0)
            }
        }
        
 // 如果没有直接的利用率数据，尝试从其他指标推算
        if let coreCount = data["Core Count"] as? NSNumber,
           let activeCores = data["Active Cores"] as? NSNumber {
            let utilization = (activeCores.doubleValue / coreCount.doubleValue) * 100.0
            return min(max(utilization, 0.0), 100.0)
        }
        
        return 0.0
    }
    
 /// 获取系统GPU统计信息（备用方法）
    private func getSystemGPUStats() -> Double {
 // 使用系统调用获取GPU统计信息
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpuInfo = host_cpu_load_info_data_t()
        
        let result = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return 0.0
        }
        
 // 这里返回一个基于CPU负载的GPU使用率估算
 // 实际应用中可能需要更复杂的算法
        let totalTicks = cpuInfo.cpu_ticks.0 + cpuInfo.cpu_ticks.1 + cpuInfo.cpu_ticks.2 + cpuInfo.cpu_ticks.3
        let idleTicks = cpuInfo.cpu_ticks.2
        
        if totalTicks > 0 {
            let usage = Double(totalTicks - idleTicks) / Double(totalTicks) * 100.0
            return min(max(usage * 0.7, 0.0), 100.0) // GPU通常比CPU使用率低一些
        }
        
        return 0.0
    }

 // MARK: - Apple Silicon Powermetrics 集成

 /// 通过powermetrics解析 GPU Active Residency（0~1），异步且带缓存
    private func readGPUActiveResidencyViaPowerMetrics() async -> Double? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                let pipe = Pipe()
                task.launchPath = "/usr/bin/powermetrics"
                task.arguments = ["-n", "1", "-i", "1000", "--samplers", "gpu_power,thermal"]
                task.standardOutput = pipe
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
 // 匹配 "GPU Average active residency" 或类似字段
                    if let m = output.range(of: #"(?i)GPU.*active.*residency.*([0-9]+\.?[0-9]*)%"#, options: .regularExpression) {
                        let sub = String(output[m])
                        let allowed = CharacterSet(charactersIn: "0123456789.")
                        let filtered = sub.unicodeScalars.filter { allowed.contains($0) }
                        if let num = Double(String(String.UnicodeScalarView(filtered))) {
                            continuation.resume(returning: num / 100.0)
                            return
                        }
                    }
 // 退化：尝试GPU Power范围映射
                    if let m2 = output.range(of: #"(?i)GPU\s*Power.*:.*([0-9]+\.?[0-9]*)W"#, options: .regularExpression) {
                        let sub = String(output[m2])
                        let allowed = CharacterSet(charactersIn: "0123456789.")
                        let filtered = sub.unicodeScalars.filter { allowed.contains($0) }
                        if let watts = Double(String(String.UnicodeScalarView(filtered))) {
 // 简单线性映射：3W≈0%，33W≈100%
                            let percent = min(1.0, max(0.0, (watts - 3.0) / 30.0))
                            continuation.resume(returning: percent)
                            return
                        }
                    }
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

 /// 通过powermetrics估算GPU使用率（基于温度），返回百分比0~100
    private func estimateGPUUsageFromTemperatureViaPowerMetrics() async -> Double? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                let pipe = Pipe()
                task.launchPath = "/usr/bin/powermetrics"
                task.arguments = ["-n", "1", "-s", "thermal", "--show-process-coalition"]
                task.standardOutput = pipe
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
 // 提取以摄氏度结尾的数值（粗略解析）
                    if let range = output.range(of: #"(?i)GPU.*temperature.*([0-9]+\.?[0-9]*)"#, options: .regularExpression) {
                        let sub = String(output[range])
                        let allowed = CharacterSet(charactersIn: "0123456789.")
                        let filtered = sub.unicodeScalars.filter { allowed.contains($0) }
                        if let temp = Double(String(String.UnicodeScalarView(filtered))) {
                            let base: Double = 40.0
                            let maxT: Double = 95.0
                            if temp <= base { continuation.resume(returning: 0.0); return }
                            let percent = min(100.0, ((temp - base) / (maxT - base)) * 100.0)
                            continuation.resume(returning: percent)
                            return
                        }
                    }
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - GPU统计数据结构

/// GPU统计信息
public struct GPUStats: Sendable {
 /// GPU利用率百分比 (0-100)
    public let utilization: Double
    
 /// GPU温度 (摄氏度)
    public let temperature: Double?
    
 /// GPU内存使用情况
    public let memoryUsage: GPUMemoryUsage?
    
 /// 时间戳
    public let timestamp: Date
    
    public init(
        utilization: Double,
        temperature: Double? = nil,
        memoryUsage: GPUMemoryUsage? = nil,
        timestamp: Date = Date()
    ) {
        self.utilization = utilization
        self.temperature = temperature
        self.memoryUsage = memoryUsage
        self.timestamp = timestamp
    }
}

/// GPU内存使用情况
public struct GPUMemoryUsage: Sendable {
 /// 已使用内存 (字节)
    public let used: UInt64
    
 /// 总内存 (字节)
    public let total: UInt64
    
 /// 使用率百分比
    public var percentage: Double {
        guard total > 0 else { return 0.0 }
        return Double(used) / Double(total) * 100.0
    }
    
    public init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }
}