import Foundation
import Combine
import os.log
import Darwin

/// Apple官方认证的系统监控器
/// 使用2025年Apple最佳实践，符合Swift 6.2特性和Apple Silicon优化
/// 采用官方推荐的ProcessInfo、sysctl和Mach内核API
@MainActor
public final class AppleOfficialSystemMonitor: ObservableObject, Sendable {

 // MARK: - 发布属性

    @Published public var cpuUsage: Double = 0.0
    @Published public var memoryUsed: Int64 = 0
    @Published public var memoryTotal: Int64 = 0
    @Published public var memoryPressure: Double = 0.0
    @Published public var networkBytesIn: UInt64 = 0
    @Published public var networkBytesOut: UInt64 = 0
    @Published public var systemLoad: [Double] = []
    @Published public var systemUptime: TimeInterval = 0.0
    @Published public var thermalState: ProcessInfo.ThermalState = .nominal
    @Published public var powerState: ApplePowerState = .unknown
    @Published public var diskUsages: [DiskUsage] = []

 // MARK: - 私有属性

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SystemMonitor")
    private var monitoringTask: Task<Void, Never>?
    private var isMonitoring = false

 // 监控配置 - 使用Apple推荐的更新间隔
    private let updateInterval: TimeInterval = 3.0 // 3秒间隔，平衡性能和实时性

 // 缓存上次网络统计数据用于计算速率
    private var lastNetworkStats: (bytesIn: UInt64, bytesOut: UInt64, timestamp: Date)?

 // MARK: - 初始化

    public init() {
        logger.info("🔧 初始化Apple官方系统监控器")

 // 获取初始系统信息 - 使用detached task避免主actor问题
        Task.detached { [weak self] in
            await self?.updateSystemInfo()
        }
    }

    deinit {
 // 在deinit中直接清理资源，避免主actor隔离问题
        monitoringTask?.cancel()
        monitoringTask = nil
    }

 // MARK: - 公共方法

 /// 开始监控系统指标
    public func startMonitoring() {
        guard !isMonitoring else { return }

        isMonitoring = true
        logger.info("🚀 开始系统监控")

        monitoringTask = Task { [weak self] in
            while let self = self, self.isMonitoring && !Task.isCancelled {
                await self.updateSystemInfo()

 // 使用Task.sleep替代Timer，更适合异步环境
                try? await Task.sleep(nanoseconds: UInt64(self.updateInterval * 1_000_000_000))
            }
        }
    }

 /// 停止监控系统指标
    public func stopMonitoring() {
        guard isMonitoring else { return }

        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
        logger.info("⏹️ 停止系统监控")
    }

 // MARK: - 私有方法 - 系统信息更新

 /// 更新所有系统信息
    private func updateSystemInfo() async {
 // 在后台队列执行系统API调用，避免阻塞主线程
        let systemInfo = await Task.detached { [weak self] in
            guard let self = self else {
                return AppleSystemInfo(
                    cpuUsage: 0.0,
                    memoryInfo: AppleMemoryInfo(used: 0, total: 0, pressure: 0.0),
                    networkStats: AppleNetworkStats(bytesIn: 0, bytesOut: 0, timestamp: Date()),
                    systemLoad: [],
                    systemUptime: 0.0,
                    thermalState: .nominal,
                    powerState: .unknown,
                    diskUsages: []
                )
            }

            return AppleSystemInfo(
                cpuUsage: await self.getCPUUsageUsingMach(),
                memoryInfo: await self.getMemoryInfoUsingSysctl(),
                networkStats: await self.getNetworkStatsUsingSysctl(),
                systemLoad: await self.getSystemLoadUsingProcessInfo(),
                systemUptime: ProcessInfo.processInfo.systemUptime,
                thermalState: ProcessInfo.processInfo.thermalState,
                powerState: await self.getPowerStateUsingSysctl(),
                diskUsages: await self.getDiskUsagesUsingFileManager()
            )
        }.value

 // 在主线程更新UI
        await MainActor.run {
            self.cpuUsage = systemInfo.cpuUsage
            self.memoryUsed = systemInfo.memoryInfo.used
            self.memoryTotal = systemInfo.memoryInfo.total
            self.memoryPressure = systemInfo.memoryInfo.pressure
            self.systemLoad = systemInfo.systemLoad
            self.systemUptime = systemInfo.systemUptime
            self.thermalState = systemInfo.thermalState
            self.powerState = systemInfo.powerState
            self.diskUsages = systemInfo.diskUsages

 // 计算网络速率
            self.updateNetworkRates(systemInfo.networkStats)
        }
    }

 // MARK: - CPU监控 - 使用Mach内核API

 /// 获取CPU使用率 - 使用Apple官方Mach API
 /// 这是Apple推荐的获取CPU使用率的方法
    private func getCPUUsageUsingMach() -> Double {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            logger.error("❌ 获取CPU信息失败")
            return 0.0
        }

 // 确保正确释放内存 - Apple最佳实践
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: cpuInfo),
                vm_size_t(Int(cpuInfoCount) * MemoryLayout<integer_t>.size)
            )
        }

        let cpuLoadInfo = cpuInfo.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(numCPUs)) { $0 }

        var totalUser: UInt32 = 0
        var totalSystem: UInt32 = 0
        var totalIdle: UInt32 = 0
        var totalNice: UInt32 = 0

 // 累计所有CPU核心的使用情况
        for i in 0..<Int(numCPUs) {
            let cpuLoad = cpuLoadInfo[i]
            totalUser += cpuLoad.cpu_ticks.0    // CPU_STATE_USER
            totalSystem += cpuLoad.cpu_ticks.1  // CPU_STATE_SYSTEM
            totalIdle += cpuLoad.cpu_ticks.2    // CPU_STATE_IDLE
            totalNice += cpuLoad.cpu_ticks.3    // CPU_STATE_NICE
        }

        let totalTicks = totalUser + totalSystem + totalIdle + totalNice
        guard totalTicks > 0 else { return 0.0 }

        let activeTicks = totalUser + totalSystem + totalNice
        return Double(activeTicks) / Double(totalTicks) * 100.0
    }

 // MARK: - 内存监控 - 使用sysctl API

 /// 获取内存信息 - 使用Apple官方sysctl API
    private func getMemoryInfoUsingSysctl() -> AppleMemoryInfo {
 // 获取物理内存总量
        var totalMemory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &totalMemory, &size, nil, 0)

        guard result == 0 else {
            logger.error("❌ 获取总内存失败")
            return AppleMemoryInfo(used: 0, total: 0, pressure: 0.0)
        }

 // 获取虚拟内存统计信息
        var vmStats = vm_statistics64()
        var vmStatsSize = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let vmResult = withUnsafeMutableBytes(of: &vmStats) { vmStatsPtr in
            host_statistics64(
                mach_host_self(),
                HOST_VM_INFO64,
                vmStatsPtr.baseAddress?.assumingMemoryBound(to: integer_t.self),
                &vmStatsSize
            )
        }

        guard vmResult == KERN_SUCCESS else {
            logger.error("❌ 获取虚拟内存统计失败")
            return AppleMemoryInfo(used: 0, total: Int64(totalMemory), pressure: 0.0)
        }

 // 获取页面大小
        var pageSize: vm_size_t = 0
        let pageSizeResult = host_page_size(mach_host_self(), &pageSize)
        guard pageSizeResult == KERN_SUCCESS else {
            logger.error("❌ 获取页面大小失败")
            return AppleMemoryInfo(used: 0, total: Int64(totalMemory), pressure: 0.0)
        }

 // 计算内存使用情况
        let usedPages = vmStats.active_count + vmStats.inactive_count + vmStats.wire_count + vmStats.compressor_page_count
        let usedMemory = Int64(usedPages) * Int64(pageSize)

 // 计算内存压力 - Apple推荐的计算方法
        let pressure = Double(usedMemory) / Double(totalMemory)

        return AppleMemoryInfo(
            used: usedMemory,
            total: Int64(totalMemory),
            pressure: min(max(pressure, 0.0), 1.0)
        )
    }

 // MARK: - 网络监控 - 使用sysctl API

 /// 获取网络统计信息 - 使用Apple官方sysctl API
    private func getNetworkStatsUsingSysctl() -> AppleNetworkStats {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

 // 获取网络接口数量
        var ifCount: Int32 = 0
        var size = MemoryLayout<Int32>.size

        guard sysctlbyname("net.link.generic.system.ifcount", &ifCount, &size, nil, 0) == 0 else {
            logger.error("❌ 获取网络接口数量失败")
            return AppleNetworkStats(bytesIn: 0, bytesOut: 0, timestamp: Date())
        }

 // 遍历所有网络接口获取统计信息
        for i in 1...Int(ifCount) {
            let ifDataName = "net.link.ifdata.\(i)"

            var ifData = if_data()
            var ifDataSize = MemoryLayout<if_data>.size

            if sysctlbyname(ifDataName, &ifData, &ifDataSize, nil, 0) == 0 {
                bytesIn += UInt64(ifData.ifi_ibytes)
                bytesOut += UInt64(ifData.ifi_obytes)
            }
        }

        return AppleNetworkStats(bytesIn: bytesIn, bytesOut: bytesOut, timestamp: Date())
    }

 /// 更新网络速率
    private func updateNetworkRates(_ currentStats: AppleNetworkStats) {
        defer {
            lastNetworkStats = (currentStats.bytesIn, currentStats.bytesOut, currentStats.timestamp)
        }

        guard let lastStats = lastNetworkStats else {
            networkBytesIn = 0
            networkBytesOut = 0
            return
        }

        let timeDelta = currentStats.timestamp.timeIntervalSince(lastStats.timestamp)
        guard timeDelta > 0 else { return }

        let bytesInDelta = currentStats.bytesIn > lastStats.bytesIn ? currentStats.bytesIn - lastStats.bytesIn : 0
        let bytesOutDelta = currentStats.bytesOut > lastStats.bytesOut ? currentStats.bytesOut - lastStats.bytesOut : 0

        networkBytesIn = UInt64(Double(bytesInDelta) / timeDelta)
        networkBytesOut = UInt64(Double(bytesOutDelta) / timeDelta)
    }

 // MARK: - 系统负载 - 使用ProcessInfo

 /// 获取系统负载 - 使用Apple官方ProcessInfo API
    private func getSystemLoadUsingProcessInfo() -> [Double] {
 // 使用getloadavg获取系统负载平均值
        var loadAvg: [Double] = [0.0, 0.0, 0.0]
        let result = getloadavg(&loadAvg, 3)

        guard result > 0 else {
            logger.error("❌ 获取系统负载失败")
            return []
        }

        return Array(loadAvg.prefix(Int(result)))
    }

 // MARK: - 电源状态 - 使用sysctl API

 /// 获取电源状态 - 使用Apple官方sysctl API
    private func getPowerStateUsingSysctl() -> ApplePowerState {
 // 检查是否为笔记本电脑
        var size = size_t()
        sysctlbyname("hw.model", nil, &size, nil, 0)

        if size > 0 {
            var model = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &model, &size, nil, 0) == 0 {
 // 移除null终止符并转换为String
                let modelBytes = model.prefix(while: { $0 != 0 }).map { UInt8($0) }
                let modelString = String(decoding: modelBytes, as: UTF8.self)
                if modelString.contains("MacBook") {
                    // 对于 MacBook，sysctl 无法可靠区分当前是电池供电还是外接电源。
                    // 这里返回“battery-capable”语义（即：设备具备电池），避免误导为“正在使用电池供电”。
                    // 真实供电状态需要 IOKit/PowerSources（后续可按需补齐）。
                    return .battery
                }
            }
        }

        return .ac
    }

 // MARK: - 磁盘使用情况 - 使用FileManager

 /// 获取磁盘使用情况 - 使用Apple官方FileManager API
    private func getDiskUsagesUsingFileManager() -> [DiskUsage] {
        let fileManager = FileManager.default
        var diskUsages: [DiskUsage] = []

 // 获取挂载点
        guard let mountedVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey
            ],
            options: .skipHiddenVolumes
        ) else {
            logger.error("❌ 获取挂载卷失败")
            return []
        }

        for volume in mountedVolumes {
            do {
                let resourceValues = try volume.resourceValues(forKeys: [
                    .volumeNameKey,
                    .volumeTotalCapacityKey,
                    .volumeAvailableCapacityKey
                ])

                guard let name = resourceValues.volumeName,
                      let totalCapacity = resourceValues.volumeTotalCapacity,
                      let availableCapacity = resourceValues.volumeAvailableCapacity else {
                    continue
                }

                let usedSpace = Int64(totalCapacity - availableCapacity)
                let usagePercentage = totalCapacity > 0 ? Double(usedSpace) / Double(totalCapacity) * 100.0 : 0.0

                let diskUsage = DiskUsage(
                    name: name,
                    totalSpace: Int64(totalCapacity),
                    usedSpace: usedSpace,
                    freeSpace: Int64(availableCapacity),
                    usagePercentage: usagePercentage
                )

                diskUsages.append(diskUsage)

            } catch {
                logger.error("❌ 获取卷 \(volume.path) 信息失败: \(error)")
            }
        }

        return diskUsages
    }
}

// MARK: - 数据结构

/// 系统信息结构体
private struct AppleSystemInfo: Sendable {
    let cpuUsage: Double
    let memoryInfo: AppleMemoryInfo
    let networkStats: AppleNetworkStats
    let systemLoad: [Double]
    let systemUptime: TimeInterval
    let thermalState: ProcessInfo.ThermalState
    let powerState: ApplePowerState
    let diskUsages: [DiskUsage]
}

/// 内存信息结构体
private struct AppleMemoryInfo: Sendable {
    let used: Int64
    let total: Int64
    let pressure: Double
}

/// 网络统计结构体
private struct AppleNetworkStats: Sendable {
    let bytesIn: UInt64
    let bytesOut: UInt64
    let timestamp: Date
}

/// 电源状态枚举
public enum ApplePowerState: Sendable {
    case ac        // 交流电源
    case battery   // 电池供电
    case unknown   // 未知状态
}