import Foundation
import Darwin
import IOKit
import IOKit.pwr_mgt

/// 真实系统监控器 - 使用Apple官方API获取真实硬件数据
/// 符合Apple最佳实践和macOS系统监控规范
public class RealSystemMonitor {
    
 // MARK: - 私有常量
    
 // Mach API常量定义
    private let HOST_BASIC_INFO_COUNT = mach_msg_type_number_t(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    private let HOST_LOAD_INFO_COUNT = mach_msg_type_number_t(MemoryLayout<host_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    private let HOST_CPU_LOAD_INFO_COUNT = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    private let HOST_VM_INFO64_COUNT = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    
 // 网络监控相关
    private var previousNetworkStats: NetworkStats?
    private var lastNetworkUpdateTime: Date?
    
 // CPU监控相关
    private var previousCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    
 // MARK: - 公共方法
    
 /// 获取CPU使用率
 /// - Returns: CPU使用率百分比 (0.0-100.0)
    public func getCPUUsage() -> Double {
        var processorInfo: processor_info_array_t!
        var numProcessorInfo: mach_msg_type_number_t = 0
        var numProcessors: natural_t = 0
        
        let result = host_processor_info(mach_host_self(),
                                       PROCESSOR_CPU_LOAD_INFO,
                                       &numProcessors,
                                       &processorInfo,
                                       &numProcessorInfo)
        
        guard result == KERN_SUCCESS else {
            let err = mach_error_string(result)
            let msg = err.map { String(decoding: Data(bytes: $0, count: strlen($0)), as: UTF8.self) } ?? "unknown"
            SkyBridgeLogger.performance.error("❌ 获取CPU信息失败: \(msg, privacy: .private)")
            return 0.0
        }
        
 // 确保正确释放内存
        defer {
            if processorInfo != nil {
                vm_deallocate(mach_task_self_, 
                            vm_address_t(bitPattern: processorInfo), 
                            vm_size_t(numProcessorInfo) * vm_size_t(MemoryLayout<integer_t>.size))
            }
        }
        
 // 安全地访问处理器信息
        guard numProcessors > 0 else {
            SkyBridgeLogger.performance.error("❌ 未检测到处理器")
            return 0.0
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
                let usage = Double(userDiff + systemDiff + niceDiff) / Double(totalDiff) * 100.0
                previousCPUTicks = currentTicks
                return min(max(usage, 0.0), 100.0) // 确保在0-100范围内
            }
        }
        
        previousCPUTicks = currentTicks
        
 // 首次调用时的计算方法
        let totalTicks = totalUser + totalSystem + totalIdle + totalNice
        if totalTicks > 0 {
            let usage = Double(totalUser + totalSystem + totalNice) / Double(totalTicks) * 100.0
            return min(max(usage, 0.0), 100.0)
        }
        
        return 0.0
    }
    
 /// 获取内存使用情况
 /// - Returns: 内存使用信息元组 (已使用字节数, 总内存字节数, 使用百分比)
    public func getMemoryUsage() -> (used: Int64, total: Int64, percentage: Double) {
        var vmStats = vm_statistics64()
        var count = HOST_VM_INFO64_COUNT
        
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            let err2 = mach_error_string(result)
            let msg2 = err2.map { String(decoding: Data(bytes: $0, count: strlen($0)), as: UTF8.self) } ?? "unknown"
            SkyBridgeLogger.performance.error("❌ 获取内存统计信息失败: \(msg2, privacy: .private)")
            return (0, 0, 0.0)
        }
        
 // 获取页面大小 - 使用更安全的方式
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
        let totalMemory = getPhysicalMemory()
        
 // 计算已使用内存（活跃 + 非活跃 + 有线 + 压缩）
        let usedMemory = (activePages + inactivePages + wiredPages + compressedPages) * pageSizeInt64
        
        let percentage = totalMemory > 0 ? Double(usedMemory) / Double(totalMemory) * 100.0 : 0.0
        
        return (usedMemory, totalMemory, min(max(percentage, 0.0), 100.0))
    }
    
 /// 获取物理内存总量
 /// - Returns: 物理内存总字节数
    public func getPhysicalMemory() -> Int64 {
        var size = MemoryLayout<Int64>.size
        var memorySize: Int64 = 0
        
        let result = sysctlbyname("hw.memsize", &memorySize, &size, nil, 0)
        
        guard result == 0 else {
            SkyBridgeLogger.performance.error("❌ 获取物理内存大小失败")
            return 0
        }
        
        return memorySize
    }
    
 /// 获取系统负载
 /// - Returns: 系统负载数组 [1分钟, 5分钟, 15分钟]
    public func getSystemLoad() -> [Double] {
        var loadAvg = [Double](repeating: 0, count: 3)
        
        guard getloadavg(&loadAvg, 3) != -1 else {
            SkyBridgeLogger.performance.error("❌ 获取系统负载失败")
            return [0.0, 0.0, 0.0]
        }
        
        return loadAvg
    }
    
 /// 获取系统运行时间
 /// - Returns: 系统运行时间（秒）
    public func getSystemUptime() -> TimeInterval {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        
        let result = sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        
        guard result == 0 else {
            SkyBridgeLogger.performance.error("❌ 获取系统启动时间失败")
            return 0
        }
        
        let now = Date().timeIntervalSince1970
        let boot = Double(bootTime.tv_sec) + Double(bootTime.tv_usec) / 1_000_000.0
        
        return max(now - boot, 0)
    }
    
 /// 获取网络使用情况
 /// - Returns: 网络使用信息元组 (上传速度 bytes/s, 下载速度 bytes/s)
    public func getNetworkUsage() -> (upload: Double, download: Double) {
        let currentStats = getNetworkStatistics()
        let currentTime = Date()
        
        defer {
            previousNetworkStats = currentStats
            lastNetworkUpdateTime = currentTime
        }
        
        guard let previousStats = previousNetworkStats,
              let lastTime = lastNetworkUpdateTime else {
            return (0.0, 0.0)
        }
        
        let timeDiff = currentTime.timeIntervalSince(lastTime)
        guard timeDiff > 0 else { return (0.0, 0.0) }
        
        let uploadDiff = currentStats.bytesOut - previousStats.bytesOut
        let downloadDiff = currentStats.bytesIn - previousStats.bytesIn
        
        let uploadSpeed = Double(uploadDiff) / timeDiff
        let downloadSpeed = Double(downloadDiff) / timeDiff
        
        return (max(uploadSpeed, 0.0), max(downloadSpeed, 0.0))
    }
    
 /// 获取磁盘使用情况
 /// - Returns: 磁盘使用信息数组
    public func getDiskUsage() -> [(name: String, totalSpace: Int64, usedSpace: Int64, freeSpace: Int64, usagePercentage: Double)] {
        let fileManager = FileManager.default
        var diskUsages: [(name: String, totalSpace: Int64, usedSpace: Int64, freeSpace: Int64, usagePercentage: Double)] = []
        
        let resourceKeys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]
        
        guard let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: resourceKeys) else {
            SkyBridgeLogger.performance.error("❌ 无法获取挂载的卷")
            return diskUsages
        }
        
        for url in urls {
            do {
                let resourceValues = try url.resourceValues(forKeys: Set(resourceKeys))
                
                guard let name = resourceValues.volumeName,
                      let totalCapacity = resourceValues.volumeTotalCapacity,
                      let availableCapacity = resourceValues.volumeAvailableCapacity else {
                    continue
                }
                
                let usedCapacity = totalCapacity - availableCapacity
                let usagePercentage = totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) * 100.0 : 0.0
                
                diskUsages.append((
                    name: name,
                    totalSpace: Int64(totalCapacity),
                    usedSpace: Int64(usedCapacity),
                    freeSpace: Int64(availableCapacity),
                    usagePercentage: min(max(usagePercentage, 0.0), 100.0)
                ))
            } catch {
                SkyBridgeLogger.performance.error("❌ 获取磁盘 \(url.path, privacy: .private) 信息失败: \(error.localizedDescription, privacy: .private)")
            }
        }
        
        return diskUsages
    }
    
 /// 获取热状态
 /// - Returns: 系统热状态
    public func getThermalState() -> SystemMonitorThermalState {
        var thermalLevel: UInt32 = 0
        let result = IOPMGetThermalWarningLevel(&thermalLevel)
        
        if result == kIOReturnNotFound {
            return .normal
        }
        
        guard result == kIOReturnSuccess else {
            SkyBridgeLogger.performance.error("❌ 获取热状态失败: \(String(describing: result), privacy: .private)")
            return .normal
        }
        
 // 根据热警告级别返回相应状态
        switch thermalLevel {
        case 0:
            return .normal
        case 1...2:
            return .warning
        default:
            return .critical
        }
    }
    
 // MARK: - 私有方法
    
 /// 获取网络统计信息
    private func getNetworkStatistics() -> NetworkStats {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        
 // 使用系统调用获取网络接口统计信息
        var mib = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: size_t = 0
        
 // 获取所需缓冲区大小
        if sysctl(&mib, 6, nil, &len, nil, 0) < 0 {
            return NetworkStats(bytesIn: 0, bytesOut: 0)
        }
        
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: len)
        defer { buffer.deallocate() }
        
 // 获取网络接口信息
        if sysctl(&mib, 6, buffer, &len, nil, 0) < 0 {
            return NetworkStats(bytesIn: 0, bytesOut: 0)
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
        
        return NetworkStats(bytesIn: bytesIn, bytesOut: bytesOut)
    }

// MARK: - 辅助结构体和枚举

/// 网络统计信息
private struct NetworkStats {
    let bytesIn: UInt64
    let bytesOut: UInt64
}

} // RealSystemMonitor 类结束

/// 系统监控热状态（用于系统监控）
public enum SystemMonitorThermalState: String, CaseIterable {
    case normal = "正常"
    case warning = "警告"
    case critical = "严重"
    
    public var displayName: String {
        return rawValue
    }
}