import Foundation
import Combine
import IOKit
import os.log
import Darwin

/// 系统指标服务，使用苹果真实API获取系统资源使用情况
@MainActor
public final class SystemMetricsService: ObservableObject {
    @Published public private(set) var cpuUsage: Double = 0.0
    @Published public private(set) var memoryUsage: Double = 0.0
    @Published public private(set) var networkSpeed: Double = 0.0
 /// 网络速率（字节/秒）：入站/出站，供仪表盘展示真实上下行
    @Published public private(set) var networkRate: NetworkRateData = NetworkRateData()
    @Published public private(set) var cpuTimeline: [Date: Double] = [:]
    @Published public private(set) var memoryTimeline: [Date: Double] = [:]
    @Published public private(set) var networkTimeline: [Date: Double] = [:]
 /// 入站速率时间线（字节/秒）
    @Published public private(set) var networkInTimeline: [Date: Double] = [:]
 /// 出站速率时间线（字节/秒）
    @Published public private(set) var networkOutTimeline: [Date: Double] = [:]
    
    private let log = Logger(subsystem: "com.skybridge.compass", category: "SystemMetrics")
    private var lastMetricsLogAt: Date?
    @MainActor private var monitoringTimer: Timer?
    private let maxTimelinePoints = 30
    
 // CPU使用率计算所需的前一次采样数据
    private var previousCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    
 // 网络速度计算所需的前一次采样数据
    private var previousNetworkStats: (bytesIn: UInt64, bytesOut: UInt64, timestamp: Date)?
    
    public init() {}
    
 /// 开始监控系统指标
    public func startMonitoring() {
        guard monitoringTimer == nil else { return }
        
 // 立即获取一次指标
        updateMetrics()
        
 // 每5秒更新一次指标
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMetrics()
            }
        }
        
        log.info("系统指标监控已启动")

 // 订阅清除历史与导出数据通知，实现设置视图到服务的闭环。
        NotificationCenter.default.addObserver(forName: .systemMonitorClearHistory, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.clearHistory()
            }
        }
        NotificationCenter.default.addObserver(forName: .systemMonitorExport, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.exportDataToDesktop()
            }
        }
    }
    
 /// 停止监控系统指标
    public func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        log.info("系统指标监控已停止")
    }
    
 /// 更新系统指标
 /// 更新系统指标
    @MainActor
    private func updateMetrics() {
        let currentTime = Date()
        
 // 获取CPU使用率
        let newCpuUsage = fetchCpuUsage()
        cpuUsage = newCpuUsage
        
 // 获取内存使用率
        let newMemoryUsage = fetchMemoryUsage()
        memoryUsage = newMemoryUsage
        
 // 获取网络上下行速率（字节/秒），并计算总速率（Mbps）用于现有展示
        let newNetworkRate = fetchNetworkRates()
        networkRate = newNetworkRate
        let totalBitsPerSecond = (newNetworkRate.inBps + newNetworkRate.outBps) * 8.0
        let newNetworkSpeed = totalBitsPerSecond / (1024.0 * 1024.0) // Mbps
        networkSpeed = max(0.0, newNetworkSpeed)
        
 // 更新时间线数据
        cpuTimeline[currentTime] = newCpuUsage
        memoryTimeline[currentTime] = newMemoryUsage
        networkTimeline[currentTime] = newNetworkSpeed
        networkInTimeline[currentTime] = newNetworkRate.inBps
        networkOutTimeline[currentTime] = newNetworkRate.outBps
        
 // 限制时间线数据点数量，保留最新的数据点
        if cpuTimeline.count > maxTimelinePoints {
            let sortedKeys = cpuTimeline.keys.sorted()
            let keysToRemove = sortedKeys.prefix(cpuTimeline.count - maxTimelinePoints)
            for key in keysToRemove {
                cpuTimeline.removeValue(forKey: key)
            }
        }
        if memoryTimeline.count > maxTimelinePoints {
            let sortedKeys = memoryTimeline.keys.sorted()
            let keysToRemove = sortedKeys.prefix(memoryTimeline.count - maxTimelinePoints)
            for key in keysToRemove {
                memoryTimeline.removeValue(forKey: key)
            }
        }
        if networkTimeline.count > maxTimelinePoints {
            let sortedKeys = networkTimeline.keys.sorted()
            let keysToRemove = sortedKeys.prefix(networkTimeline.count - maxTimelinePoints)
            for key in keysToRemove {
                networkTimeline.removeValue(forKey: key)
            }
        }
        if networkInTimeline.count > maxTimelinePoints {
            let sortedKeys = networkInTimeline.keys.sorted()
            let keysToRemove = sortedKeys.prefix(networkInTimeline.count - maxTimelinePoints)
            for key in keysToRemove { networkInTimeline.removeValue(forKey: key) }
        }
        if networkOutTimeline.count > maxTimelinePoints {
            let sortedKeys = networkOutTimeline.keys.sorted()
            let keysToRemove = sortedKeys.prefix(networkOutTimeline.count - maxTimelinePoints)
            for key in keysToRemove { networkOutTimeline.removeValue(forKey: key) }
        }
        
        // Throttle noisy logs: metrics update frequently and can flood logs / waste CPU.
        let now = Date()
        if lastMetricsLogAt == nil || now.timeIntervalSince(lastMetricsLogAt!) >= 10 {
            lastMetricsLogAt = now
            log.debug("系统指标已更新 - CPU: \(String(format: "%.1f", newCpuUsage * 100))%, 内存: \(String(format: "%.1f", newMemoryUsage * 100))%, 网络: \(String(format: "%.1f", newNetworkSpeed)) Mbps")
        }
    }

 /// 清除所有时间线历史数据。
    private func clearHistory() {
        cpuTimeline.removeAll()
        memoryTimeline.removeAll()
        networkTimeline.removeAll()
        networkInTimeline.removeAll()
        networkOutTimeline.removeAll()
        log.info("🗑️ 已清除系统监控历史数据")
    }

 /// 导出当前监控数据到桌面 JSON 文件。
    private func exportDataToDesktop() {
        let snapshot: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "cpuUsage": cpuUsage,
            "memoryUsage": memoryUsage,
            "networkSpeedMbps": networkSpeed,
            "networkRate": ["inBps": networkRate.inBps, "outBps": networkRate.outBps],
            "cpuTimeline": cpuTimeline.map { [$0.key.timeIntervalSince1970, $0.value] },
            "memoryTimeline": memoryTimeline.map { [$0.key.timeIntervalSince1970, $0.value] },
            "networkTimeline": networkTimeline.map { [$0.key.timeIntervalSince1970, $0.value] },
            "networkInTimeline": networkInTimeline.map { [$0.key.timeIntervalSince1970, $0.value] },
            "networkOutTimeline": networkOutTimeline.map { [$0.key.timeIntervalSince1970, $0.value] }
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted])
            let home = NSHomeDirectory()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let name = "system_monitor_export_\(formatter.string(from: Date())).json"
            let url = URL(fileURLWithPath: home).appendingPathComponent("Desktop").appendingPathComponent(name)
            try data.write(to: url)
            log.info("📤 监控数据已导出: \(url.path)")
        } catch {
            log.error("导出监控数据失败: \(error.localizedDescription)")
        }
    }
    
 /// 获取CPU使用率（使用苹果系统API，改进版本）
    private func fetchCpuUsage() -> Double {
        var processorInfo: processor_info_array_t!
        var numProcessorInfo: mach_msg_type_number_t = 0
        var numProcessors: natural_t = 0
        
        let result = host_processor_info(mach_host_self(),
                                       PROCESSOR_CPU_LOAD_INFO,
                                       &numProcessors,
                                       &processorInfo,
                                       &numProcessorInfo)
        
        guard result == KERN_SUCCESS else {
            log.error("获取CPU信息失败: \(result)")
            return 0.0
        }
        
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: processorInfo), vm_size_t(numProcessorInfo))
        }
        
        let cpuLoadInfo = processorInfo.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(numProcessors)) {
            Array(UnsafeBufferPointer(start: $0, count: Int(numProcessors)))
        }
        
        var totalUser: UInt32 = 0
        var totalSystem: UInt32 = 0
        var totalIdle: UInt32 = 0
        var totalNice: UInt32 = 0
        
        for cpu in cpuLoadInfo {
            totalUser += cpu.cpu_ticks.0    // CPU_STATE_USER
            totalSystem += cpu.cpu_ticks.1  // CPU_STATE_SYSTEM
            totalIdle += cpu.cpu_ticks.2    // CPU_STATE_IDLE
            totalNice += cpu.cpu_ticks.3    // CPU_STATE_NICE
        }
        
        let currentTicks = (user: totalUser, system: totalSystem, idle: totalIdle, nice: totalNice)
        
 // 如果有之前的数据，计算差值来获得更准确的CPU使用率
        if let previousTicks = previousCPUTicks {
            let userDiff = currentTicks.user - previousTicks.user
            let systemDiff = currentTicks.system - previousTicks.system
            let idleDiff = currentTicks.idle - previousTicks.idle
            let niceDiff = currentTicks.nice - previousTicks.nice
            
            let totalDiff = userDiff + systemDiff + idleDiff + niceDiff
            
            if totalDiff > 0 {
                let usage = Double(userDiff + systemDiff + niceDiff) / Double(totalDiff)
                previousCPUTicks = currentTicks
                return min(max(usage, 0.0), 1.0) // 返回0-1之间的值
            }
        }
        
        previousCPUTicks = currentTicks
        
 // 首次调用时的计算方法
        let totalTicks = totalUser + totalSystem + totalIdle + totalNice
        if totalTicks > 0 {
            let usage = Double(totalUser + totalSystem + totalNice) / Double(totalTicks)
            return min(max(usage, 0.0), 1.0)
        }
        
        return 0.0
    }
    
 /// 获取内存使用率（使用苹果系统API）
    private func fetchMemoryUsage() -> Double {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vmStats) / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &vmStats) { statsPtr -> kern_return_t in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            log.error("获取内存统计失败: \(result)")
            return 0.0
        }
        
 // 获取页面大小
        var pageSize: vm_size_t = 0
        let pageSizeResult = host_page_size(mach_host_self(), &pageSize)
        guard pageSizeResult == KERN_SUCCESS else {
            log.error("获取页面大小失败: \(pageSizeResult)")
            return 0.0
        }
        
 // 计算内存使用情况（以字节为单位）
        let freePages = UInt64(vmStats.free_count)
        let activePages = UInt64(vmStats.active_count)
        let inactivePages = UInt64(vmStats.inactive_count)
        let wiredPages = UInt64(vmStats.wire_count)
        let compressedPages = UInt64(vmStats.compressor_page_count)
        
        let totalPages = freePages + activePages + inactivePages + wiredPages + compressedPages
        let usedPages = activePages + inactivePages + wiredPages + compressedPages
        
        guard totalPages > 0 else { return 0.0 }
        
        let usage = Double(usedPages) / Double(totalPages)
        return max(0.0, min(1.0, usage))
    }
    
 /// 获取格式化的CPU使用率字符串
    public func formattedCpuUsage() -> String {
        return String(format: "%.1f%%", cpuUsage * 100)
    }
    
 /// 获取格式化的内存使用率字符串
    public func formattedMemoryUsage() -> String {
        return String(format: "%.1f%%", memoryUsage * 100)
    }
    
 /// 获取网络上下行速率（字节/秒），使用真实系统API (sysctl + NET_RT_IFLIST2)
 /// 返回值单位为 Bps（Bytes per second），分别表示入站/出站。
    private func fetchNetworkRates() -> NetworkRateData {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        let currentTime = Date()
        
 // 使用系统调用获取网络接口统计信息
        var mib = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: size_t = 0
        
 // 获取所需缓冲区大小
        if sysctl(&mib, 6, nil, &len, nil, 0) < 0 {
            log.error("获取网络接口缓冲区大小失败")
            return NetworkRateData(inBps: 0.0, outBps: 0.0)
        }
        
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: len)
        defer { buffer.deallocate() }
        
 // 获取网络接口信息
        if sysctl(&mib, 6, buffer, &len, nil, 0) < 0 {
            log.error("获取网络接口信息失败")
            return NetworkRateData(inBps: 0.0, outBps: 0.0)
        }
        
        var offset = 0
        while offset < len {
            let ifm = buffer.advanced(by: offset).withMemoryRebound(to: if_msghdr.self, capacity: 1) { $0.pointee }
            
            if ifm.ifm_type == RTM_IFINFO2 {
                let if2m = buffer.advanced(by: offset).withMemoryRebound(to: if_msghdr2.self, capacity: 1) { $0.pointee }
                
 // 累加所有网络接口的数据
                bytesIn += if2m.ifm_data.ifi_ibytes
                bytesOut += if2m.ifm_data.ifi_obytes
            }
            
            offset += Int(ifm.ifm_msglen)
        }
        
        let currentStats = (bytesIn: bytesIn, bytesOut: bytesOut, timestamp: currentTime)
        
 // 如果有之前的数据，计算速率
        if let previousStats = previousNetworkStats {
            let timeDiff = currentTime.timeIntervalSince(previousStats.timestamp)
            
            if timeDiff > 0 {
 // 使用安全差值，避免计数器回绕或重置导致的无符号下溢
                let inDiff: UInt64 = currentStats.bytesIn >= previousStats.bytesIn ? (currentStats.bytesIn - previousStats.bytesIn) : 0
                let outDiff: UInt64 = currentStats.bytesOut >= previousStats.bytesOut ? (currentStats.bytesOut - previousStats.bytesOut) : 0
                
                let inRateBps = Double(inDiff) / timeDiff
                let outRateBps = Double(outDiff) / timeDiff
                
                previousNetworkStats = currentStats
                return NetworkRateData(inBps: max(0.0, inRateBps), outBps: max(0.0, outRateBps))
            }
        }
        
        previousNetworkStats = currentStats
        return NetworkRateData(inBps: 0.0, outBps: 0.0) // 首次调用返回0
    }
    
 /// 获取网络速度（使用真实系统API获取网络接口统计信息）
    private func fetchNetworkSpeed() -> Double {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        let currentTime = Date()
        
 // 使用系统调用获取网络接口统计信息
        var mib = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: size_t = 0
        
 // 获取所需缓冲区大小
        if sysctl(&mib, 6, nil, &len, nil, 0) < 0 {
            log.error("获取网络接口缓冲区大小失败")
            return 0.0
        }
        
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: len)
        defer { buffer.deallocate() }
        
 // 获取网络接口信息
        if sysctl(&mib, 6, buffer, &len, nil, 0) < 0 {
            log.error("获取网络接口信息失败")
            return 0.0
        }
        
        var offset = 0
        while offset < len {
            let ifm = buffer.advanced(by: offset).withMemoryRebound(to: if_msghdr.self, capacity: 1) { $0.pointee }
            
            if ifm.ifm_type == RTM_IFINFO2 {
                let if2m = buffer.advanced(by: offset).withMemoryRebound(to: if_msghdr2.self, capacity: 1) { $0.pointee }
                
 // 累加所有网络接口的数据
                bytesIn += if2m.ifm_data.ifi_ibytes
                bytesOut += if2m.ifm_data.ifi_obytes
            }
            
            offset += Int(ifm.ifm_msglen)
        }
        
        let currentStats = (bytesIn: bytesIn, bytesOut: bytesOut, timestamp: currentTime)
        
 // 如果有之前的数据，计算速度
        if let previousStats = previousNetworkStats {
            let timeDiff = currentTime.timeIntervalSince(previousStats.timestamp)
            
            if timeDiff > 0 {
 // 使用安全差值，避免计数器回绕或重置导致的无符号下溢
                let inDiff: UInt64 = currentStats.bytesIn >= previousStats.bytesIn ? (currentStats.bytesIn - previousStats.bytesIn) : 0
                let outDiff: UInt64 = currentStats.bytesOut >= previousStats.bytesOut ? (currentStats.bytesOut - previousStats.bytesOut) : 0
                let (sumDiff, overflow) = inDiff.addingReportingOverflow(outDiff)
                let safeBytesDiff: UInt64 = overflow ? UInt64.max : sumDiff
                
 // 计算速度（字节/秒转换为Mbps）
                let bytesPerSecond = Double(safeBytesDiff) / timeDiff
                let mbps = bytesPerSecond * 8.0 / (1024.0 * 1024.0) // 转换为Mbps
                
                previousNetworkStats = currentStats
                return max(0.0, mbps)
            }
        }
        
        previousNetworkStats = currentStats
        return 0.0 // 首次调用返回0
    }
    
 /// 获取格式化的网络速度字符串
    public func formattedNetworkSpeed() -> String {
        return String(format: "%.1f Mbps", networkSpeed)
    }
    
    deinit {
 // 在 deinit 中不访问 MainActor 隔离的属性，避免并发问题
 // Timer 会在对象销毁时自动失效
    }
}

/// 系统监控通知名称扩展。
extension Notification.Name {
    static let systemMonitorClearHistory = Notification.Name("SystemMonitor.ClearHistory")
    static let systemMonitorExport = Notification.Name("SystemMonitor.Export")
}
