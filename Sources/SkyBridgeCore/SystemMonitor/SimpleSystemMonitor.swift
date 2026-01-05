import Foundation
import Darwin

/// 简化的系统监控器 - 使用Apple推荐的ProcessInfo和更安全的API
/// 避免复杂的Mach API调用，减少卡死风险
public class SimpleSystemMonitor {
    
 // MARK: - 私有属性
    
 /// 上次CPU测量时间
    private var lastCPUTime: TimeInterval = 0
    
 /// 上次CPU使用率
    private var lastCPUUsage: Double = 0
    
 // MARK: - 公共方法
    
 /// 获取CPU使用率 - 使用ProcessInfo的简化方式
 /// - Returns: CPU使用率百分比 (0.0-100.0)
    public func getCPUUsage() -> Double {
        let currentTime = ProcessInfo.processInfo.systemUptime
        
 // 如果距离上次测量时间太短，返回缓存值
        if currentTime - lastCPUTime < 0.5 {
            return lastCPUUsage
        }
        
 // 使用系统负载作为CPU使用率的近似值
        let loadAverage = getSystemLoad()
        let cpuCount = ProcessInfo.processInfo.processorCount
        
 // 将负载平均值转换为CPU使用率百分比
        let usage = loadAverage.isEmpty ? 0.0 : min(loadAverage[0] / Double(cpuCount) * 100.0, 100.0)
        
        lastCPUTime = currentTime
        lastCPUUsage = usage
        
        return max(0.0, usage)
    }
    
 /// 获取内存使用情况 - 使用ProcessInfo的简化方式
 /// - Returns: 内存使用信息元组 (已使用字节数, 总内存字节数, 使用百分比)
    public func getMemoryUsage() -> (used: Int64, total: Int64, percentage: Double) {
 // 获取物理内存总量
        let totalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        
 // 使用简单的方式估算内存使用
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let usedMemory = Int64(info.resident_size)
            let percentage = totalMemory > 0 ? Double(usedMemory) / Double(totalMemory) * 100.0 : 0.0
            return (usedMemory, totalMemory, min(max(percentage, 0.0), 100.0))
        }
        
 // 如果获取失败，返回默认值
        return (0, totalMemory, 0.0)
    }
    
 /// 获取系统负载
 /// - Returns: 系统负载数组 [1分钟, 5分钟, 15分钟]
    public func getSystemLoad() -> [Double] {
        var loadAvg = [Double](repeating: 0.0, count: 3)
        
        if getloadavg(&loadAvg, 3) != -1 {
            return loadAvg
        }
        
        return [0.0, 0.0, 0.0]
    }
    
 /// 获取系统运行时间
 /// - Returns: 系统运行时间（秒）
    public func getSystemUptime() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }
    
 /// 获取网络使用情况
 /// - Returns: 网络使用情况元组 (上传速度, 下载速度) 单位: bytes/s
 /// 使用 getifaddrs 获取真实网络接口统计
    public func getNetworkUsage() -> (upload: Double, download: Double) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return (0.0, 0.0)
        }
        defer { freeifaddrs(ifaddr) }
        
        var totalBytesSent: UInt64 = 0
        var totalBytesReceived: UInt64 = 0
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)
            
 // 只统计活跃的网络接口 (en0, en1, etc.)
            if name.hasPrefix("en") || name.hasPrefix("bridge") {
                if let data = interface.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                    totalBytesSent += UInt64(networkData.ifi_obytes)
                    totalBytesReceived += UInt64(networkData.ifi_ibytes)
                }
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
 // 计算速率（与上次采样的差值）
        let currentTime = Date()
        let timeDelta = currentTime.timeIntervalSince(lastNetworkSampleTime)
        
        var uploadSpeed: Double = 0.0
        var downloadSpeed: Double = 0.0
        
        if timeDelta > 0 && lastBytesSent > 0 {
            uploadSpeed = Double(totalBytesSent - lastBytesSent) / timeDelta
            downloadSpeed = Double(totalBytesReceived - lastBytesReceived) / timeDelta
        }
        
 // 更新上次采样值
        lastBytesSent = totalBytesSent
        lastBytesReceived = totalBytesReceived
        lastNetworkSampleTime = currentTime
        
        return (max(0, uploadSpeed), max(0, downloadSpeed))
    }
    
 // 网络统计采样状态
    private var lastBytesSent: UInt64 = 0
    private var lastBytesReceived: UInt64 = 0
    private var lastNetworkSampleTime: Date = Date()
    
 /// 获取磁盘使用情况
 /// - Returns: 磁盘使用情况数组
    public func getDiskUsage() -> [(name: String, totalSpace: Int64, usedSpace: Int64, freeSpace: Int64, usagePercentage: Double)] {
        var diskUsages: [(name: String, totalSpace: Int64, usedSpace: Int64, freeSpace: Int64, usagePercentage: Double)] = []
        
 // 获取主磁盘使用情况
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        
        do {
            let resourceValues = try homeURL.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey
            ])
            
            if let volumeName = resourceValues.volumeName,
               let totalCapacity = resourceValues.volumeTotalCapacity,
               let availableCapacity = resourceValues.volumeAvailableCapacity {
                
                let totalSpace = Int64(totalCapacity)
                let freeSpace = Int64(availableCapacity)
                let usedSpace = totalSpace - freeSpace
                let usagePercentage = totalSpace > 0 ? Double(usedSpace) / Double(totalSpace) * 100.0 : 0.0
                
                diskUsages.append((
                    name: volumeName,
                    totalSpace: totalSpace,
                    usedSpace: usedSpace,
                    freeSpace: freeSpace,
                    usagePercentage: min(max(usagePercentage, 0.0), 100.0)
                ))
            }
        } catch {
            SkyBridgeLogger.performance.error("❌ 获取磁盘使用情况失败: \(error.localizedDescription, privacy: .private)")
        }
        
        return diskUsages
    }
    
 /// 获取热状态 - 简化版本
 /// - Returns: 系统热状态
    public func getThermalState() -> String {
 // 使用ProcessInfo的热状态
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return "正常"
        case .fair, .serious:
            return "警告"
        case .critical:
            return "严重"
        @unknown default:
            return "正常"
        }
    }
}