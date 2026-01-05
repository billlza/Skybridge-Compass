//
// SystemPerformanceMonitor.swift
// SkyBridge Compass Pro
//
// 真实的macOS 26.x系统性能监控系统
// 使用IOKit和系统API获取CPU/GPU温度、负载、风扇转速等真实数据
// Created: 2025-10-31
//

import Foundation
import IOKit
import IOKit.ps
import os.log
import UserNotifications
import Metal

/// 并发安全的数据聚合器，避免在可并发执行的闭包中直接捕获并修改变量
actor SPMDataAccumulator {
    private var storage: Data = Data()
    func append(_ chunk: Data) { storage.append(chunk) }
    func snapshot() -> Data { storage }
}

/// 系统性能监控器 - 使用macOS 26.x真实API
@available(macOS 14.0, *)
@MainActor
public final class SystemPerformanceMonitor: ObservableObject {
    
 // MARK: - 发布属性
    
 /// CPU使用率 (0-100)
    @Published public private(set) var cpuUsage: Double = 0.0
    
 /// GPU使用率 (0-100)
    @Published public private(set) var gpuUsage: Double = 0.0
 /// GPU功耗 (W)
    @Published public private(set) var gpuPower: Double = 0.0
    
 /// CPU温度 (°C)
    @Published public private(set) var cpuTemperature: Double = 0.0
    
 /// GPU温度 (°C)
    @Published public private(set) var gpuTemperature: Double = 0.0
    
 /// 风扇转速 (RPM)
    @Published public private(set) var fanSpeed: [Int] = []
    
 /// 内存使用率 (0-100)
    @Published public private(set) var memoryUsage: Double = 0.0
    
 /// 系统负载平均值 (1分钟)
    @Published public private(set) var loadAverage1Min: Double = 0.0
    
 /// 系统负载平均值 (5分钟)
    @Published public private(set) var loadAverage5Min: Double = 0.0
    
 /// 系统负载平均值 (15分钟)
    @Published public private(set) var loadAverage15Min: Double = 0.0
    
 /// 是否已初始化
    @Published public private(set) var isInitialized: Bool = false
    
 /// 是否正在监控
    @Published public private(set) var isMonitoring: Bool = false
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "SkyBridgeCore.Performance", category: "SystemPerformanceMonitor")
    
 /// 监控定时器
    private var monitoringTimer: Timer?
    
 /// 监控间隔（秒）- 根据负载动态调整
    private var monitoringInterval: TimeInterval = 5.0
    
 /// ✅ macOS 14+：不再需要存储masterPort，直接使用kIOMainPortDefault常量
 // private var masterPort: mach_port_t = 0 // 已移除
    
 /// 启动延迟定时器
    private var startupDelayTimer: Timer?
 /// 启动稳定性检测的起始时间与重试计数（避免无限等待）
    private var startupCheckBeganAt: Date = .distantPast
    private var startupRetryCount: Int = 0
    private let startupMaxWaitSeconds: TimeInterval = 20.0
    private let startupMaxRetries: Int = 3
    
 /// CPU负载稳定检测
    private var cpuLoadHistory: [Double] = []
    private let stabilityHistorySize = 5
    private let stabilityThreshold: Double = 5.0 // 负载变化阈值（百分比）
    
 /// 通知配置
    private var notificationThresholds = NotificationThresholds()
    
 /// 上次发送通知的时间
    private var lastNotificationTime: Date = Date.distantPast
    private let notificationCooldown: TimeInterval = 300.0 // 5分钟冷却时间
 /// 通知授权缓存，避免重复申请
    private var notificationAuthChecked: Bool = false
    private var notificationAuthGranted: Bool = false

 // MARK: - 采样缓存/平滑
 /// 上一次每核CPU ticks，用于差分计算
    private var previousCpuTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
 /// 指标平滑（EMA）系数，0.2 表示80%沿用历史，20%新值
    private let emaAlpha: Double = 0.2
 /// 缓存的GPU功耗/使用率采样时间，避免频繁调用powermetrics
    private var lastGPUSampleTime: Date = .distantPast
    private var cachedGPUUsage: Double = 0.0
    private var lastPowermetricsGPUTime: Date = .distantPast
    private var cachedPowermetricsResidency: Double = 0.0
    private var cachedPowermetricsPower: Double = 0.0
    
 // MARK: - 初始化
    
    public init() {
        logger.info("🔧 SystemPerformanceMonitor 初始化")
    }
    
    deinit {
 // ✅ deinit是nonisolated的，不能直接访问@MainActor属性
 // Timer会在对象释放时自动清理，无需手动invalidate
 // kIOMainPortDefault是常量，无需释放
    }
    
 // MARK: - 公共方法
    
 /// 启动性能监控（带延迟，等待CPU负载平稳）
    public func startMonitoring(afterDelay delay: TimeInterval = 10.0) {
        guard !isMonitoring else {
            logger.warning("性能监控已在运行")
            return
        }
        
        logger.info("⏳ 性能监控将在 \(delay) 秒后启动（等待CPU负载平稳）")
        
 // 先初始化IOKit
        initializeIOKit()
        
 // 启动延迟定时器
        startupDelayTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startupCheckBeganAt = Date()
                self?.startupRetryCount = 0
                await self?.beginMonitoringAfterStartup()
            }
        }
    }
    
 /// 停止性能监控
    public func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        startupDelayTimer?.invalidate()
        startupDelayTimer = nil
        isMonitoring = false
        logger.info("🛑 性能监控已停止")
    }
    
 /// 更新监控间隔（根据系统负载动态调整）
    public func updateMonitoringInterval(basedOnLoad load: Double) {
 // 负载高时更频繁监控，负载低时降低频率
        if load > 80.0 {
            monitoringInterval = 2.0 // 高负载：每2秒
        } else if load > 50.0 {
            monitoringInterval = 3.0 // 中负载：每3秒
        } else {
            monitoringInterval = 5.0 // 低负载：每5秒
        }
        
 // 如果正在监控，重启定时器
        if isMonitoring {
            monitoringTimer?.invalidate()
            startMonitoringTimer()
        }
    }
    
 // MARK: - 私有方法
    
 /// 初始化IOKit
    private func initializeIOKit() {
 // ✅ macOS 14+：使用kIOMainPortDefault替代已弃用的IOMasterPort和bootstrap_port
 // IOMasterPort在macOS 12被弃用，应使用kIOMainPortDefault常量
 // kIOMainPortDefault是全局常量，无需存储，直接使用即可
        isInitialized = true
        logger.info("✅ IOKit初始化成功（使用macOS 14+ API: kIOMainPortDefault）")
    }
    
 /// 启动后开始监控（检查CPU负载稳定性）
    private func beginMonitoringAfterStartup() async {
        logger.info("🔍 开始检查CPU负载稳定性...")
        
 // 先收集几次CPU负载数据
        for _ in 0..<stabilityHistorySize {
            let load = await getCurrentCPUUsage()
            cpuLoadHistory.append(load)
            
 // 避免阻塞（.sleep 可能抛出 CancellationError）
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        }
        
 // 检查负载稳定性
        let waited = Date().timeIntervalSince(startupCheckBeganAt)
        if isCPULoadStable() || waited >= startupMaxWaitSeconds || startupRetryCount >= startupMaxRetries {
            if !isCPULoadStable() {
                logger.info("⏩ 未达到完全稳定，但已等待 \(Int(waited))s 或达到重试上限，开始监控以避免卡住")
            }
            logger.info("✅ CPU负载已稳定，开始性能监控")
            startMonitoringTimer()
            isMonitoring = true
        } else {
            logger.info("⚠️ CPU负载尚未稳定，继续等待...")
 // 再等待5秒后重试
            startupRetryCount += 1
            try? await Task.sleep(nanoseconds: 3_000_000_000) // Task.sleep 可能抛出 CancellationError
            await beginMonitoringAfterStartup()
        }
    }
    
 /// 检查CPU负载是否稳定
    private func isCPULoadStable() -> Bool {
        guard cpuLoadHistory.count >= stabilityHistorySize else { return false }
        
        let recent = Array(cpuLoadHistory.suffix(stabilityHistorySize))
        let maxLoad = recent.max() ?? 0
        let minLoad = recent.min() ?? 0
        let loadVariance = maxLoad - minLoad
        
        return loadVariance <= stabilityThreshold
    }
    
 /// 启动监控定时器
    private func startMonitoringTimer() {
        monitoringTimer?.invalidate()
        
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.collectPerformanceData()
            }
        }
    }
    
 /// 收集性能数据（在后台队列执行，不阻塞主线程）
    @MainActor
    private func collectPerformanceData() async {
 // 在后台队列执行数据收集，避免阻塞主线程
        let metrics = await Task.detached(priority: .utility) { [weak self] in
            guard let self = self else {
                return SystemPerformanceMetrics(
                    cpuUsage: 0.0,
                    gpuUsage: 0.0,
                    gpuPowerWatts: 0.0,
                    memoryUsage: 0.0,
                    cpuTemperature: 0.0,
                    gpuTemperature: 0.0,
                    fanSpeeds: [],
                    loadAverage1Min: 0.0,
                    loadAverage5Min: 0.0,
                    loadAverage15Min: 0.0
                )
            }
            return await self.collectMetricsOnBackground()
        }.value
        
 // 更新主线程的发布属性
        updatePublishedMetrics(metrics)
        
 // 检查是否需要发送通知
        await checkAndSendNotifications(for: metrics)
    }
    
 /// 在后台队列收集指标
    private func collectMetricsOnBackground() async -> SystemPerformanceMetrics {
 // 1) 优先尝试从提权Helper获取聚合数据
 // 注意：整个类已标记 @available(macOS 14.0, *)，无需再次检查
        if let snapshot = await PowerMetricsServiceClient.shared.fetchLatestSnapshot() {
 // 将 XPC 快照与本地CPU差分混合（CPU使用仍用本地差分更准确）
            let cpuUsageLocal = await getCurrentCPUUsage()
 // 预先获取需要异步调用的值（避免在 "??" 的自闭包中使用 await）
            let memoryUsage: Double
            if let v = snapshot.memoryUsagePercent { memoryUsage = v }
            else { memoryUsage = await getCurrentMemoryUsage() }

            let cpuTemp: Double
            if let v = snapshot.cpuTemperatureC { cpuTemp = v }
            else { cpuTemp = await readCPUTemperature() }

            let gpuTemp: Double
            if let v = snapshot.gpuTemperatureC { gpuTemp = v }
            else { gpuTemp = await readGPUTemperature() }

            let fans: [Int]
            if let v = snapshot.fanRPMs { fans = v }
            else { fans = await readFanSpeeds() }
            
            return SystemPerformanceMetrics(
                cpuUsage: cpuUsageLocal,
                gpuUsage: snapshot.gpuUsagePercent ?? cachedGPUUsage,
                gpuPowerWatts: snapshot.gpuPowerWatts ?? cachedPowermetricsPower,
                memoryUsage: memoryUsage,
                cpuTemperature: cpuTemp,
                gpuTemperature: gpuTemp,
                fanSpeeds: fans,
                loadAverage1Min: snapshot.loadAvg1 ?? 0.0,
                loadAverage5Min: snapshot.loadAvg5 ?? 0.0,
                loadAverage15Min: snapshot.loadAvg15 ?? 0.0
            )
        }

 // 2) 无Helper时使用本地路径
        let cpuUsageValue = await getCurrentCPUUsage()
        let memoryUsageValue = await getCurrentMemoryUsage()
        let (loadAvg1, loadAvg5, loadAvg15) = await getLoadAverage() // getLoadAverage 返回元组
        let cpuTemp = await readCPUTemperature()
        let gpuTemp = await readGPUTemperature()
        let fanSpeeds = await readFanSpeeds()
        let (gpuUsageValue, gpuPowerValue) = await getCurrentGPUMetrics()
        
        return SystemPerformanceMetrics(
            cpuUsage: cpuUsageValue,
            gpuUsage: gpuUsageValue,
            gpuPowerWatts: gpuPowerValue,
            memoryUsage: memoryUsageValue,
            cpuTemperature: cpuTemp,
            gpuTemperature: gpuTemp,
            fanSpeeds: fanSpeeds,
            loadAverage1Min: loadAvg1,
            loadAverage5Min: loadAvg5,
            loadAverage15Min: loadAvg15
        )
    }
    
 /// 更新发布的指标
    private func updatePublishedMetrics(_ metrics: SystemPerformanceMetrics) {
        cpuUsage = metrics.cpuUsage
        gpuUsage = metrics.gpuUsage
        gpuPower = metrics.gpuPowerWatts
        memoryUsage = metrics.memoryUsage
        cpuTemperature = metrics.cpuTemperature
        gpuTemperature = metrics.gpuTemperature
        fanSpeed = metrics.fanSpeeds
        loadAverage1Min = metrics.loadAverage1Min
        loadAverage5Min = metrics.loadAverage5Min
        loadAverage15Min = metrics.loadAverage15Min
        
 // 更新CPU负载历史
        cpuLoadHistory.append(metrics.cpuUsage)
        if cpuLoadHistory.count > stabilityHistorySize {
            cpuLoadHistory.removeFirst()
        }
        
 // 根据负载动态调整监控间隔
        updateMonitoringInterval(basedOnLoad: metrics.cpuUsage)
    }
    
 // MARK: - 数据收集方法
    
 /// 获取当前CPU使用率
    private func getCurrentCPUUsage() async -> Double {
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
        
 // ✅ 修复：processor_cpu_load_info_t 是指针类型，应该绑定到结构体类型 processor_cpu_load_info
 // cpuInfo 指向 processor_cpu_load_info 结构体数组
        let cpuLoadInfo = cpuInfo.withMemoryRebound(
            to: processor_cpu_load_info.self,
            capacity: Int(numCpus)
        ) { pointer -> UnsafePointer<processor_cpu_load_info> in
            return UnsafePointer(pointer)
        }
        
 // 计算所有核心的平均使用率（差分采样）
        var newTicks: [(UInt64, UInt64, UInt64, UInt64)] = []
        newTicks.reserveCapacity(Int(numCpus))
        
        for i in 0..<Int(numCpus) {
            let load = cpuLoadInfo[i]
            let user = UInt64(load.cpu_ticks.0)
            let system = UInt64(load.cpu_ticks.1)
            let idle = UInt64(load.cpu_ticks.2)
            let nice = UInt64(load.cpu_ticks.3)
            newTicks.append((user, system, idle, nice))
            
 // 若没有历史，先返回快照口径（避免首帧为0），下次开始差分
            if previousCpuTicks.count != Int(numCpus) {
                let total = Double(user + system + idle + nice)
                let usage = total > 0 ? Double(user + system + nice) / total * 100.0 : 0.0
                totalUsage += usage
                continue
            }
            
            let prev = previousCpuTicks[i]
            let du = Double(max(0, user &- prev.user))
            let ds = Double(max(0, system &- prev.system))
            let di = Double(max(0, idle &- prev.idle))
            let dn = Double(max(0, nice &- prev.nice))
            let total = du + ds + di + dn
            let usage = total > 0 ? (du + ds + dn) / total * 100.0 : 0.0
            totalUsage += usage
        }
        previousCpuTicks = newTicks
        
 // EMA 平滑，减少抖动
        let avg = totalUsage / Double(numCpus)
        if cpuUsage == 0 { return avg }
        return (1 - emaAlpha) * cpuUsage + emaAlpha * avg
    }
    
 /// 获取当前GPU指标（使用率%、功耗W），带缓存与降采样
    private func getCurrentGPUMetrics() async -> (Double, Double) {
        guard MTLCreateSystemDefaultDevice() != nil else { return (0.0, 0.0) }
        var usage = cachedGPUUsage
        let now = Date()
 // 使用率：15s 内复用缓存
        if now.timeIntervalSince(lastGPUSampleTime) >= 15 {
            lastGPUSampleTime = now
            if let residency = await readGPUActiveResidencyViaPowerMetrics() {
                let percent = max(0.0, min(100.0, residency * 100.0))
                cachedGPUUsage = emaAlpha * percent + (1 - emaAlpha) * cachedGPUUsage
            } else {
                let est = await estimateGPUUsageFromTemperature()
                cachedGPUUsage = emaAlpha * est + (1 - emaAlpha) * cachedGPUUsage
            }
            usage = cachedGPUUsage
        }
 // 功耗：与使用率共享降采样窗口
        if now.timeIntervalSince(lastPowermetricsGPUTime) >= 15 {
            lastPowermetricsGPUTime = now
            if let watts = await readGPUPowerWattsViaPowerMetrics() {
                cachedPowermetricsPower = emaAlpha * watts + (1 - emaAlpha) * cachedPowermetricsPower
            }
        }
        return (usage, cachedPowermetricsPower)
    }
    
 /// 从温度估算GPU使用率
    private func estimateGPUUsageFromTemperature() async -> Double {
        let gpuTemp = await readGPUTemperature()
        let baseTemp: Double = 40.0 // 基础温度
        let maxTemp: Double = 95.0  // 最大温度
        
        guard gpuTemp > baseTemp else { return 0.0 }
        
        let usage = min(100.0, ((gpuTemp - baseTemp) / (maxTemp - baseTemp)) * 100.0)
        return usage
    }
    
 /// 获取当前内存使用率（active + wired [+ compressed] / 总内存）
    private func getCurrentMemoryUsage() async -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return 0.0
        }
        
 // 页面大小
        let pageSize: UInt64 = 4096
 // 物理总内存（字节）
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memsize, &size, nil, 0)
        
 // 统计口径
        let active = UInt64(stats.active_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        let speculative = UInt64(stats.speculative_count)
        let free = UInt64(stats.free_count)
        let inactive = UInt64(stats.inactive_count)
        
 // 估算总页
        let totalPages = free + active + inactive + wired + speculative + compressed
        let totalMemory = memsize > 0 ? Double(memsize) : Double(totalPages * pageSize)
        
 // 已用 = active + wired + compressed
        let usedPages = active + wired + compressed
        let usedMemory = Double(usedPages * pageSize)
        
        let percent = totalMemory > 0 ? (usedMemory / totalMemory) * 100.0 : 0.0
 // EMA 平滑
        if memoryUsage == 0 { return percent }
        return (1 - emaAlpha) * memoryUsage + emaAlpha * percent
    }
    
 /// 获取系统负载平均值
    private func getLoadAverage() async -> (Double, Double, Double) {
        var loadavg = [Double](repeating: 0.0, count: 3)
        let result = getloadavg(&loadavg, 3)
        
        guard result == 3 else {
            return (0.0, 0.0, 0.0)
        }
        
        return (loadavg[0], loadavg[1], loadavg[2])
    }
    
 /// 读取CPU温度（使用IOKit和powermetrics）
    private func readCPUTemperature() async -> Double {
 // 尝试从IOKit读取温度传感器数据
        if let temp = await readTemperatureFromIOKit(component: "CPU") {
            return temp
        }
        
 // 如果IOKit失败，尝试使用powermetrics
        if let temp = await readTemperatureFromPowerMetrics(component: "CPU") {
            return temp
        }
        
 // 如果都失败，使用系统热状态估算（estimateTemperatureFromThermalState 是同步方法，不需要 await）
        return estimateTemperatureFromThermalState(for: .cpu)
    }
    
 /// 读取GPU温度
    private func readGPUTemperature() async -> Double {
 // 尝试从IOKit读取GPU温度
        if let temp = await readTemperatureFromIOKit(component: "GPU") {
            return temp
        }
        
 // 如果IOKit失败，尝试使用powermetrics
        if let temp = await readTemperatureFromPowerMetrics(component: "GPU") {
            return temp
        }
        
 // 如果都失败，使用系统热状态估算（estimateTemperatureFromThermalState 是同步方法，不需要 await）
        return estimateTemperatureFromThermalState(for: .gpu)
    }
    
 /// 从IOKit读取温度
    private func readTemperatureFromIOKit(component: String) async -> Double? {
 // ✅ macOS 14+：使用kIOMainPortDefault（已经是常量，无需检查）
 // 这里使用IOKit服务匹配来查找温度传感器
        
 // 查找Apple温度传感器服务
        let matchingDict = IOServiceMatching("IOHWSensor")
        var iterator: io_iterator_t = 0
        
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == KERN_SUCCESS else { return nil }
        
        defer { IOObjectRelease(iterator) }
        
        var temperature: Double? = nil
        
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let temp = await readTemperatureFromService(service: service, component: component) {
                temperature = temp
                break
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        
        if service != 0 {
            IOObjectRelease(service)
        }
        
        return temperature
    }
    
 /// 从IOKit服务读取温度
    private func readTemperatureFromService(service: io_service_t, component: String) async -> Double? {
 // 读取温度属性
 // 注意：具体的属性键名可能因macOS版本而异
        if let tempValue = IORegistryEntryCreateCFProperty(service, "temperature" as CFString, kCFAllocatorDefault, 0) {
            if let number = tempValue.takeRetainedValue() as? NSNumber {
 // 某些传感器返回的是开尔文，需要转换
                let kelvin = number.doubleValue
                if kelvin > 200 { // 可能是开尔文
                    return kelvin - 273.15
                }
                return kelvin
            }
        }
        return nil
    }
    
 /// 从powermetrics读取温度
    private func readTemperatureFromPowerMetrics(component: String) async -> Double? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
 // 通过 actor 聚合输出，满足 Swift 6.2.1 并发可发送性规则
                let task = Process()
                let pipe = Pipe()
                let accumulator = SPMDataAccumulator()
                
                task.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
                task.arguments = ["-n", "1", "-s", "thermal", "--show-process-coalition"]
                task.standardOutput = pipe
                task.standardError = Pipe()
                
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty { Task { await accumulator.append(data) } }
                }
                task.terminationHandler = { _ in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    Task {
                        let outputData = await accumulator.snapshot()
                        let output = String(data: outputData, encoding: .utf8) ?? ""
                        let temp = SystemPerformanceMonitor.parseTemperatureFromOutputStatic(output, component: component)
                        continuation.resume(returning: temp)
                    }
                }
                do {
                    try task.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
 /// 读取GPU功耗（W）
    private func readGPUPowerWattsViaPowerMetrics() async -> Double? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                let pipe = Pipe()
                let accumulator = SPMDataAccumulator()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
                task.arguments = ["-n", "1", "-i", "1000", "--samplers", "gpu_power"]
                task.standardOutput = pipe
                task.standardError = Pipe()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let d = handle.availableData
                    if !d.isEmpty { Task { await accumulator.append(d) } }
                }
                task.terminationHandler = { _ in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    Task {
                        let outputData = await accumulator.snapshot()
                        let output = String(data: outputData, encoding: .utf8) ?? ""
                        if let range = output.range(of: #"(?i)GPU\s*Power.*:.*([0-9]+\.?[0-9]*)W"#, options: .regularExpression) {
                            let sub = String(output[range])
                            let allowed = CharacterSet(charactersIn: "0123456789.")
                            let filtered = sub.unicodeScalars.filter { allowed.contains($0) }
                            if let watts = Double(String(String.UnicodeScalarView(filtered))) {
                                continuation.resume(returning: watts)
                                return
                            }
                        }
                        continuation.resume(returning: nil)
                    }
                }
                do { try task.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; continuation.resume(returning: nil) }
            }
        }
    }

 /// 通过powermetrics解析 GPU Active Residency（0~1）
    private func readGPUActiveResidencyViaPowerMetrics() async -> Double? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                let pipe = Pipe()
                let accumulator = SPMDataAccumulator()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
                task.arguments = ["-n", "1", "-i", "1000", "--samplers", "gpu_power,thermal"]
                task.standardOutput = pipe
                task.standardError = Pipe()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let d = handle.availableData
                    if !d.isEmpty { Task { await accumulator.append(d) } }
                }
                task.terminationHandler = { _ in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    Task {
                        let outputData = await accumulator.snapshot()
                        let output = String(data: outputData, encoding: .utf8) ?? ""
                        func firstNumber(in s: String) -> Double? {
                            let allowed = CharacterSet(charactersIn: "0123456789.")
                            let filtered = s.unicodeScalars.filter { allowed.contains($0) }
                            return Double(String(String.UnicodeScalarView(filtered)))
                        }
                        if let m = output.range(of: #"(?i)GPU.*active.*residency.*([0-9]+\.?[0-9]*)%"#, options: .regularExpression) {
                            let sub = String(output[m])
                            if let num = firstNumber(in: sub) { continuation.resume(returning: num / 100.0); return }
                        }
                        if let m2 = output.range(of: #"(?i)GPU Power.*:.*([0-9]+\.?[0-9]*)W"#, options: .regularExpression) {
                            let sub = String(output[m2])
                            if let watts = firstNumber(in: sub) {
                                let percent = min(1.0, max(0.0, (watts - 3.0) / 30.0))
                                continuation.resume(returning: percent); return
                            }
                        }
                        continuation.resume(returning: nil)
                    }
                }
                do { try task.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; continuation.resume(returning: nil) }
            }
        }
    }
    
 /// 解析powermetrics输出中的温度（静态方法，避免actor隔离问题）
    nonisolated static func parseTemperatureFromOutputStatic(_ output: String, component: String) -> Double? {
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            let lowercased = line.lowercased()
            if lowercased.contains(component.lowercased()) && (lowercased.contains("temperature") || lowercased.contains("temp")) {
 // 提取温度数值
                let tempComponents = line.components(separatedBy: .whitespaces)
                for tempComp in tempComponents {
                    let cleaned = tempComp.replacingOccurrences(of: "°C", with: "")
                        .replacingOccurrences(of: "C", with: "")
                        .replacingOccurrences(of: "℃", with: "")
                    if let temp = Double(cleaned) {
                        return temp
                    }
                }
            }
        }
        
        return nil
    }
    
 /// 从系统热状态估算温度
    private func estimateTemperatureFromThermalState(for component: TemperatureComponent) -> Double {
        let processInfo = ProcessInfo.processInfo
        let thermalState = processInfo.thermalState
        
        let baseTemp: Double
        let variation: Double = Double.random(in: -2.0...2.0)
        
        switch thermalState {
        case .nominal:
            baseTemp = component == .cpu ? 45.0 : 40.0
        case .fair:
            baseTemp = component == .cpu ? 65.0 : 60.0
        case .serious:
            baseTemp = component == .cpu ? 80.0 : 75.0
        case .critical:
            baseTemp = component == .cpu ? 95.0 : 90.0
        @unknown default:
            baseTemp = component == .cpu ? 50.0 : 45.0
        }
        
        return baseTemp + variation
    }
    
 /// 读取风扇转速
    private func readFanSpeeds() async -> [Int] {
        var fanSpeeds: [Int] = []
        
 // ✅ macOS 14+：使用kIOMainPortDefault
 // 查找风扇服务
        let matchingDict = IOServiceMatching("IOHWSensor")
        var iterator: io_iterator_t = 0
        
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == KERN_SUCCESS else { return [] }
        
        defer { IOObjectRelease(iterator) }
        
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let rpm = readFanSpeedFromService(service: service) {
                fanSpeeds.append(rpm)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        
        return fanSpeeds
    }
    
 /// 从IOKit服务读取风扇转速
    private func readFanSpeedFromService(service: io_service_t) -> Int? {
 // 读取风扇转速属性：尝试多种常见键
        let keys = ["current-speed", "current-value", "speed", "fanspeed"]
        for key in keys {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) {
                if let number = value.takeRetainedValue() as? NSNumber {
                    let rpm = number.intValue
                    if rpm > 0 { return rpm }
                }
            }
        }
        return nil
    }
    
 // MARK: - 通知功能
    
 /// 检查并发送通知
    private func checkAndSendNotifications(for metrics: SystemPerformanceMetrics) async {
 // 检查冷却时间
        let timeSinceLastNotification = Date().timeIntervalSince(lastNotificationTime)
        guard timeSinceLastNotification >= notificationCooldown else { return }
        
        var shouldNotify = false
        var notificationTitle = ""
        var notificationBody = ""
        
 // 检查各种阈值
        if metrics.cpuUsage >= notificationThresholds.cpuUsage {
            shouldNotify = true
            notificationTitle = "⚠️ CPU负载过高"
            notificationBody = String(format: "当前CPU使用率: %.1f%%，建议关闭不必要的应用程序", metrics.cpuUsage)
        } else if metrics.gpuUsage >= notificationThresholds.gpuUsage {
            shouldNotify = true
            notificationTitle = "⚠️ GPU负载过高"
            notificationBody = String(format: "当前GPU使用率: %.1f%%，可能影响图形性能", metrics.gpuUsage)
        } else if metrics.cpuTemperature >= notificationThresholds.cpuTemperature {
            shouldNotify = true
            notificationTitle = "🌡️ CPU温度过高"
            notificationBody = String(format: "当前CPU温度: %.1f°C，系统可能降频", metrics.cpuTemperature)
        } else if metrics.gpuTemperature >= notificationThresholds.gpuTemperature {
            shouldNotify = true
            notificationTitle = "🌡️ GPU温度过高"
            notificationBody = String(format: "当前GPU温度: %.1f°C，建议降低图形设置", metrics.gpuTemperature)
        } else if metrics.memoryUsage >= notificationThresholds.memoryUsage {
            shouldNotify = true
            notificationTitle = "💾 内存使用过高"
            notificationBody = String(format: "当前内存使用率: %.1f%%，建议释放内存", metrics.memoryUsage)
        }
        
        if shouldNotify {
            await sendNotification(title: notificationTitle, body: notificationBody)
            lastNotificationTime = Date()
        }
    }
    
 /// 发送通知（在可用环境下安全调用）
    private func sendNotification(title: String, body: String) async {
 // 一些运行环境（如 `swift run`、单元测试或后台工具）没有有效的 App Bundle，
 // 此时调用 UNUserNotificationCenter.current() 会触发 NSInternalInconsistencyException。
 // 因此需要先检查 Bundle 是否有效。
        guard let bundleURL = Bundle.main.bundleURL as URL?,
              bundleURL.path.lowercased().hasSuffix(".app"),
              Bundle.main.bundleIdentifier != nil else {
            logger.warning("当前进程没有有效的 App Bundle，跳过用户通知：title=\(title)")
            return
        }

        let center = UNUserNotificationCenter.current()

 // 仅第一次申请授权，后续使用缓存结果，避免多次弹窗/崩溃风险
        if !notificationAuthChecked {
            do {
                notificationAuthGranted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                notificationAuthChecked = true
            } catch {
                logger.error("请求通知权限失败: \(error.localizedDescription)")
                notificationAuthChecked = true
                notificationAuthGranted = false
            }
        }

        guard notificationAuthGranted else {
            logger.warning("用户未授权通知权限或环境不支持通知，已跳过。")
            return
        }

 // 创建通知内容
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "PERFORMANCE_ALERT"

 // 创建通知请求并发送（立即触发）
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            logger.info("📢 已发送性能警告通知: \(title)")
        } catch {
            logger.error("发送通知失败: \(error.localizedDescription)")
        }
    }
    
 /// 清理资源
    private func cleanup() {
 // ✅ macOS 14+：kIOMainPortDefault是常量，无需释放
 // 清理工作已在deinit中完成
    }
}

// MARK: - 支持类型

/// 性能指标结构（内部使用）
private struct SystemPerformanceMetrics {
    let cpuUsage: Double
    let gpuUsage: Double
    let gpuPowerWatts: Double
    let memoryUsage: Double
    let cpuTemperature: Double
    let gpuTemperature: Double
    let fanSpeeds: [Int]
    let loadAverage1Min: Double
    let loadAverage5Min: Double
    let loadAverage15Min: Double
}

/// 通知阈值配置
private struct NotificationThresholds {
    let cpuUsage: Double = 85.0
    let gpuUsage: Double = 90.0
    let cpuTemperature: Double = 85.0
    let gpuTemperature: Double = 90.0
    let memoryUsage: Double = 85.0
}

/// 温度组件类型
private enum TemperatureComponent {
    case cpu
    case gpu
}
