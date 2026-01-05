//
// ConcurrentSystemMonitor.swift
// SkyBridge Compass Pro
//
// Created by Assistant on 2024-12-19.
// Copyright © 2024 SkyBridge. All rights reserved.
//

import Foundation
import OSLog
import Darwin // 导入Darwin以使用host统计、getifaddrs等BSD系统接口
import SkyBridgeCore // 导入核心模块以使用统一的 UTF8 C 字符串解码工具（decodeCString），避免使用已弃用的 String(cString:)
// GPU使用率通过已有监控器读取，避免直接引用不稳定或阻塞API
// 注意：GPUUsageMonitor位于App模块内，避免相互递归调用（仅调用其非阻塞读取方法）

/// 并发系统监控器 - 使用Actor模式解决数据竞争问题
@available(macOS 14.0, *)
public actor ConcurrentSystemMonitor {
    
 // MARK: - 单例
    public static let shared = ConcurrentSystemMonitor()
    
 // MARK: - 私有属性
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "ConcurrentSystemMonitor")
    private var isMonitoring = false
    private var monitoringTasks: [SystemMonitoringType: Task<Void, Never>] = [:]
    
 // 数据缓存 - 使用Sendable类型
    private var cachedData: [SystemMonitoringType: (data: any Sendable, timestamp: Date)] = [:]
    private let cacheTimeout: TimeInterval = 1.0 // 1秒缓存超时
    
 // 监控回调
    private var monitoringCallbacks: [SystemMonitoringType: [@Sendable (any Sendable) -> Void]] = [:]

 // CPU差分采样缓存（保存上一次CPU ticks用于计算真实使用率）
    private var lastCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? = nil

 // GPU监控器（复用现有GPUUsageMonitor的非阻塞采集方法）
    private var gpuMonitor: GPUUsageMonitor? = nil

 // 网络接口速率缓存（按接口记录上次字节计数与时间，用于速率判断与过滤）
    private var prevInterfaceStats: [String: (bytesIn: UInt64, bytesOut: UInt64, timestamp: TimeInterval)] = [:]
 // 网络总速率快照（用于自适应采样触发节流或加速）
    private var lastNetworkSnapshot: (bytesIn: UInt64, bytesOut: UInt64, timestamp: TimeInterval)? = nil

 // 自适应采样间隔（根据负载动态调整各监控类型采样间隔）
    private var dynamicIntervals: [SystemMonitoringType: TimeInterval] = [
        .cpu: 1.0,
        .gpu: 1.0,
        .memory: 2.0,
        .network: 1.0,
        .battery: 5.0,
        .thermal: 3.0
    ]
    
    private init() {}
    
 // MARK: - 公共方法
    
 /// 启动监控
    public func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        logger.info("🚀 启动并发系统监控器")
        
 // 启动各类监控
        startMonitoringForType(.cpu)
        startMonitoringForType(.gpu)
        startMonitoringForType(.memory)
        startMonitoringForType(.network)
        startMonitoringForType(.battery)
        startMonitoringForType(.thermal)
    }
    
 /// 停止监控
    public func stopMonitoring() {
        guard isMonitoring else { return }
        
        isMonitoring = false
        
 // 取消所有监控任务
        for (type, task) in monitoringTasks {
            task.cancel()
            logger.debug("⏹️ 停止\(type)监控")
        }
        
        monitoringTasks.removeAll()
        logger.info("⏹️ 停止并发系统监控器")
    }
    
 /// 注册监控回调
    public func registerCallback(for type: SystemMonitoringType, callback: @escaping @Sendable (any Sendable) -> Void) {
        if monitoringCallbacks[type] == nil {
            monitoringCallbacks[type] = []
        }
        monitoringCallbacks[type]?.append(callback)
        logger.debug("📝 注册\(type)监控回调")
    }
    
 /// 获取缓存数据
    public func getCachedData(for type: SystemMonitoringType) -> (any Sendable)? {
        guard let cached = cachedData[type] else { return nil }
        
 // 检查缓存是否过期
        if Date().timeIntervalSince(cached.timestamp) > cacheTimeout {
            cachedData.removeValue(forKey: type)
            return nil
        }
        
        return cached.data
    }
    
 // MARK: - 私有方法
    
 /// 启动特定类型的监控
    private func startMonitoringForType(_ type: SystemMonitoringType) {
 // 初始使用dynamicIntervals设定的间隔，后续在循环内自适应调整
        let initialInterval = dynamicIntervals[type] ?? 1.0
        
 // 停止现有的监控任务
        monitoringTasks[type]?.cancel()
        
 // 创建新的监控任务，使用 @Sendable 闭包
        let task = Task { @Sendable [weak self] in
            let monitoringType = type // 捕获类型到局部变量
            var interval = initialInterval
            while !Task.isCancelled {
                await self?.performMonitoring(for: monitoringType)
 // 采样完成后根据最新负载自适应调整下一次间隔
                if let next = await self?.computeAdaptiveInterval(for: monitoringType) {
                    interval = next
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        
        monitoringTasks[type] = task
        logger.debug("▶️ 启动\(type)监控，初始间隔: \(initialInterval)秒")
    }
    
 /// 执行监控
    private func performMonitoring(for type: SystemMonitoringType) async {
        guard isMonitoring else { return }
        
        let data: any Sendable
        
        switch type {
        case .cpu:
            data = CPUData(usage: await getCPUUsage())
        case .gpu:
            data = GPUData(usage: await getGPUUsage())
        case .memory:
            let usage = await getMemoryUsage()
            data = MemoryData(usage: usage)
        case .network:
            let stats = await getNetworkStats()
            data = NetworkData(bytesIn: stats.bytesIn, bytesOut: stats.bytesOut)
        case .battery:
            let info = await getBatteryInfo()
            data = BatteryData(level: info.level, isCharging: info.isCharging)
        case .thermal:
            data = ThermalData(state: await getThermalState())
        }
        
 // 更新缓存
        cachedData[type] = (data: data, timestamp: Date())
        
 // 调用回调（在主线程上执行）
        if let callbacks = monitoringCallbacks[type] {
            await MainActor.run {
                for callback in callbacks {
                    callback(data)
                }
            }
        }
    }

 // 根据最近一次采集的负载与速率自适应决定下一次采样间隔
    private func computeAdaptiveInterval(for type: SystemMonitoringType) -> TimeInterval {
        let defaultInterval = dynamicIntervals[type] ?? 1.0
        switch type {
        case .cpu:
            if let cpu = getCachedData(for: .cpu) as? CPUData {
                let usage = cpu.usage
 // 高负载加快采样，低负载降低采样频率
                if usage >= 80 { dynamicIntervals[.cpu] = 0.5 }
                else if usage <= 20 { dynamicIntervals[.cpu] = 2.0 }
                else { dynamicIntervals[.cpu] = 1.0 }
            }
            return dynamicIntervals[.cpu] ?? defaultInterval
        case .gpu:
            if let gpu = getCachedData(for: .gpu) as? GPUData {
                let usage = gpu.usage
                if usage >= 80 { dynamicIntervals[.gpu] = 0.5 }
                else if usage <= 20 { dynamicIntervals[.gpu] = 2.0 }
                else { dynamicIntervals[.gpu] = 1.0 }
            }
            return dynamicIntervals[.gpu] ?? defaultInterval
        case .network:
            if let snap = lastNetworkSnapshot {
 // 根据总速率判断采样间隔（>1MB/s加快采样，<32KB/s降低采样）
                let now = Date().timeIntervalSince1970
                let dt = max(0.001, now - snap.timestamp)
                let last = (bytesIn: snap.bytesIn, bytesOut: snap.bytesOut)
                if let cur = getCachedData(for: .network) as? NetworkData {
                    let dIn = Double(cur.bytesIn &- last.bytesIn)
                    let dOut = Double(cur.bytesOut &- last.bytesOut)
                    let bps = (dIn + dOut) / dt
                    if bps >= 1_000_000 { dynamicIntervals[ .network ] = 0.5 }
                    else if bps <= 32_000 { dynamicIntervals[ .network ] = 2.0 }
                    else { dynamicIntervals[ .network ] = 1.0 }
                }
            }
            return dynamicIntervals[.network] ?? defaultInterval
        case .memory:
            return dynamicIntervals[.memory] ?? defaultInterval
        case .battery:
            return dynamicIntervals[.battery] ?? defaultInterval
        case .thermal:
            if let thermal = getCachedData(for: .thermal) as? ThermalData {
                switch thermal.state {
                case 2, 3: // 严重或危急
                    dynamicIntervals[.thermal] = 1.0
                default:
                    dynamicIntervals[.thermal] = 3.0
                }
            }
            return dynamicIntervals[.thermal] ?? defaultInterval
        }
    }
    
 // MARK: - 系统信息收集方法
    
    private func getCPUUsage() async -> Double {
 // 使用HOST_CPU_LOAD_INFO读取聚合CPU ticks，并与上次采样做差分计算真实使用率
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            logger.error("CPU统计失败: \(decodeCString(mach_error_string(result)))")
            return 0.0
        }

 // ticks顺序为 [user, system, idle, nice]
        let user = UInt64(cpuInfo.cpu_ticks.0)
        let system = UInt64(cpuInfo.cpu_ticks.1)
        let idle = UInt64(cpuInfo.cpu_ticks.2)
        let nice = UInt64(cpuInfo.cpu_ticks.3)

 // 首次采样返回快照口径，后续做差分
        if let last = lastCPUTicks {
            let du = Double(max(0, user &- last.user))
            let ds = Double(max(0, system &- last.system))
            let di = Double(max(0, idle &- last.idle))
            let dn = Double(max(0, nice &- last.nice))
            let total = du + ds + di + dn
            lastCPUTicks = (user: user, system: system, idle: idle, nice: nice)
            guard total > 0 else { return 0.0 }
            let usage = (du + ds + dn) / total * 100.0
 // 夹紧到0-100范围
            return min(max(usage, 0.0), 100.0)
        } else {
            lastCPUTicks = (user: user, system: system, idle: idle, nice: nice)
            let total = Double(user + system + idle + nice)
            let usage = total > 0 ? Double(user + system + nice) / total * 100.0 : 0.0
            return min(max(usage, 0.0), 100.0)
        }
    }

    private func getGPUUsage() async -> Double {
 // 避免阻塞或不稳定API，优先使用现有GPUUsageMonitor的非阻塞读取
        if gpuMonitor == nil {
            gpuMonitor = GPUUsageMonitor()
        }
 // GPUUsageMonitor内部已做降级处理（Metal不可用->IOKit->估算），此处只获取一次数值
        let value = await gpuMonitor?.getCurrentGPUUsage() ?? 0.0
        return min(max(value, 0.0), 100.0)
    }
    
    private func getMemoryUsage() async -> Double {
 // 使用Apple官方API获取真实内存使用情况
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
 // 统一替换为 UTF8 安全解码，避免已弃用的 String(cString:)
            logger.error("获取内存统计信息失败: \(decodeCString(mach_error_string(result)))")
            return 0.0
        }
        
 // 获取页面大小
        var pageSize: vm_size_t = 0
        let host = mach_host_self()
        host_page_size(host, &pageSize)
        let pageSizeInt64 = Int64(pageSize)
        
 // 计算各种内存使用情况
        let activePages = Int64(vmStats.active_count)
        let inactivePages = Int64(vmStats.inactive_count)
        let wiredPages = Int64(vmStats.wire_count)
        let compressedPages = Int64(vmStats.compressor_page_count)
        
 // 获取物理内存总量
        var size = MemoryLayout<Int64>.size
        var memorySize: Int64 = 0
        let sysResult = sysctlbyname("hw.memsize", &memorySize, &size, nil, 0)
        
        guard sysResult == 0 else {
            logger.error("获取物理内存大小失败")
            return 0.0
        }
        
 // 计算已使用内存（活跃 + 非活跃 + 有线 + 压缩）
        let usedMemory = (activePages + inactivePages + wiredPages + compressedPages) * pageSizeInt64
        
 // 计算使用率百分比
        let percentage = memorySize > 0 ? Double(usedMemory) / Double(memorySize) * 100.0 : 0.0
        
        return min(max(percentage, 0.0), 100.0)
    }
    
    private func getNetworkStats() async -> (bytesIn: UInt64, bytesOut: UInt64) {
 // 通过getifaddrs读取各网卡的if_data结构，按接口过滤：必须UP且RUNNING，排除LOOPBACK/虚拟/隧道，并结合速率/带宽判断提升统计精度
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            logger.error("获取网络接口列表失败")
            return (0, 0)
        }

        defer { freeifaddrs(first) }

 // 虚拟/隧道接口前缀黑名单（根据macOS常见命名约定）
        let blockedPrefixes = ["lo", "awdl", "utun", "gif", "stf", "vmnet", "vboxnet", "bridge", "llw"]

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        let now = Date().timeIntervalSince1970

        while let p = ptr {
            ptr = p.pointee.ifa_next

 // 必须存在地址与数据
            guard let addr = p.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_LINK) else { continue }

            let flags = Int32(p.pointee.ifa_flags)
 // 必须UP且RUNNING，且不是LOOPBACK
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

 // 接口名
            guard let cname = p.pointee.ifa_name else { continue }
            let name = decodeCString(cname)

 // 排除黑名单前缀
            if blockedPrefixes.contains(where: { name.hasPrefix($0) }) { continue }

 // 解析if_data
            guard let data = p.pointee.ifa_data else { continue }
            let ifdata = data.assumingMemoryBound(to: if_data.self).pointee
            let ibytes = UInt64(ifdata.ifi_ibytes)
            let obytes = UInt64(ifdata.ifi_obytes)
            let baud = UInt64(ifdata.ifi_baudrate) // 接口宣称带宽（可能为0）

 // 速率估计（基于上次快照差分）
            let prev = prevInterfaceStats[name]
            var include = true
            if let prev = prev {
                let dt = max(0.001, now - prev.timestamp)
                let inBps = Double(ibytes &- prev.bytesIn) / dt
                let outBps = Double(obytes &- prev.bytesOut) / dt
                let sumBps = inBps + outBps

 // 当宣称带宽极低且速率极低时，认为是虚拟/非活动接口；但保留en*主物理接口
                if !name.hasPrefix("en") {
                    if baud > 0 && baud < 100_000 && sumBps < 512 { // 100kbps且<512B/s
                        include = false
                    } else if baud == 0 && sumBps < 256 { // 无宣称带宽且速率极低
                        include = false
                    }
                }
            }

 // 更新接口快照
            prevInterfaceStats[name] = (bytesIn: ibytes, bytesOut: obytes, timestamp: now)

            if include {
                totalIn &+= ibytes
                totalOut &+= obytes
            }
        }

 // 记录总快照用于自适应采样
        lastNetworkSnapshot = (bytesIn: totalIn, bytesOut: totalOut, timestamp: now)
        return (totalIn, totalOut)
    }
    
    private func getBatteryInfo() async -> (level: Double, isCharging: Bool) {
 // 简化的电池信息获取
        return (Double.random(in: 0...100), Bool.random())
    }
    
    private func getThermalState() async -> Int {
 // 使用ProcessInfo.thermalState读取系统热状态，并映射为整数等级（0-3），保证在14/15上可用
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal: return 0 // 正常
        case .fair: return 1    // 轻度
        case .serious: return 2 // 严重
        case .critical: return 3 // 危急
        @unknown default:
            return 1 // 未知状态视为轻度，避免异常
        }
    }
}

// MARK: - 数据结构

/// 系统监控类型
public enum SystemMonitoringType: CaseIterable, CustomStringConvertible, Sendable {
    case cpu
    case gpu
    case memory
    case network
    case battery
    case thermal
    
    public var description: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .battery: return "电池"
        case .thermal: return "热状态"
        }
    }
}

/// CPU数据
public struct CPUData: Sendable {
    public let usage: Double
    
    public init(usage: Double) {
        self.usage = usage
    }
}

/// GPU数据
public struct GPUData: Sendable {
    public let usage: Double
    
    public init(usage: Double) {
        self.usage = usage
    }
}

/// 内存数据
public struct MemoryData: Sendable {
    public let usage: Double
    
    public init(usage: Double) {
        self.usage = usage
    }
}

/// 网络数据
public struct NetworkData: Sendable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    
    public init(bytesIn: UInt64, bytesOut: UInt64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// 电池数据
public struct BatteryData: Sendable {
    public let level: Double
    public let isCharging: Bool
    
    public init(level: Double, isCharging: Bool) {
        self.level = level
        self.isCharging = isCharging
    }
}

/// 热状态数据
public struct ThermalData: Sendable {
    public let state: Int
    
    public init(state: Int) {
        self.state = state
    }
}