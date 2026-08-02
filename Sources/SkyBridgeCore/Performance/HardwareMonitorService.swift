// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
//
// HardwareMonitorService.swift
// SkyBridgeCore
//
// 硬件性能监控服务
// 支持 macOS 14.0+, Apple Silicon 优化
//
// 使用技术:
// - host_processor_info() for CPU
// - vm_statistics64 for Memory
// - IOKit for GPU/Thermal
// - getifaddrs for Network
// - statvfs for Disk
//

import Foundation
import OSLog
import Darwin

// MARK: - 硬件监控服务

/// 硬件性能监控服务
@MainActor
public final class HardwareMonitorService: ObservableObject {

    // MARK: - Singleton

    public static let shared = HardwareMonitorService()
    private static let configurationStore = CodablePersistenceStore<HardwareMonitorConfiguration>(
        location: .protectedApplicationSupport(
            path: "HardwareMonitor/configuration.json",
            legacyUserDefaultsKey: "com.skybridge.hardware.config"
        )
    )

    // MARK: - Published Properties

    /// 当前指标快照
    @Published public private(set) var currentMetrics: SystemMetricsSnapshot = .zero

    /// CPU 使用率历史
    @Published public private(set) var cpuHistory: [CPUMetrics] = []

    /// 内存使用历史
    @Published public private(set) var memoryHistory: [MemoryMetrics] = []

    /// 网络吞吐历史
    @Published public private(set) var networkHistory: [NetworkMetrics] = []

    /// 是否正在监控
    @Published public private(set) var isMonitoring: Bool = false

    /// 配置
    @Published public var configuration: HardwareMonitorConfiguration {
        didSet { saveConfiguration() }
    }

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "HardwareMonitor")
    private var monitorTask: Task<Void, Never>?

    // CPU 统计缓存
    private var previousCPUInfo: host_cpu_load_info?

    // 网络统计缓存
    private var previousNetworkBytes: (in: UInt64, out: UInt64)?
    private var previousNetworkPackets: (in: UInt64, out: UInt64)?
    private var previousNetworkTime: Date?

    // 磁盘统计缓存
    private var previousDiskBytes: (read: UInt64, write: UInt64)?
    private var previousDiskTime: Date?

    // MARK: - Initialization

    private init() {
        self.configuration = Self.loadConfiguration() ?? .default
        logger.info("📊 硬件监控服务已初始化")
    }

    // MARK: - Public Methods

    /// 开始监控
    public func startMonitoring() {
        guard !isMonitoring else { return }

        isMonitoring = true
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.collectMetrics()

                let interval = self?.configuration.samplingInterval ?? 1.0
                try? await Task.sleep(for: .seconds(interval))
            }
        }

        logger.info("📊 开始硬件性能监控")
    }

    /// 停止监控
    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        isMonitoring = false

        logger.info("📊 停止硬件性能监控")
    }

    /// 手动采集一次指标
    public func collectOnce() async -> SystemMetricsSnapshot {
        await collectMetrics()
        return currentMetrics
    }

    /// 清空历史记录
    public func clearHistory() {
        cpuHistory.removeAll()
        memoryHistory.removeAll()
        networkHistory.removeAll()
    }

    // MARK: - Private Methods - Collection

    private func collectMetrics() async {
        let unifiedSnapshot = await UnifiedMetricsBackend.shared.collectSnapshot(force: false)
        let cpu = configuration.monitorCPU ? collectCPUMetrics() : .zero
        let memory = configuration.monitorMemory ? collectMemoryMetrics() : .zero
        let gpu = configuration.monitorGPU ? collectGPUMetrics(from: unifiedSnapshot) : .zero
        let network = configuration.monitorNetwork ? collectNetworkMetrics() : .zero
        let disk = configuration.monitorDisk ? collectDiskMetrics() : .zero
        let thermal = configuration.monitorThermal ? collectThermalMetrics(from: unifiedSnapshot) : .normal

        let snapshot = SystemMetricsSnapshot(
            cpu: cpu,
            memory: memory,
            gpu: gpu,
            network: network,
            disk: disk,
            thermal: thermal
        )

        currentMetrics = snapshot

        // 更新历史
        updateHistory(cpu: cpu, memory: memory, network: network)
    }

    // MARK: - CPU Metrics

    private func collectCPUMetrics() -> CPUMetrics {
        var cpuLoadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return .zero
        }

        let userTicks = cpuLoadInfo.cpu_ticks.0
        let systemTicks = cpuLoadInfo.cpu_ticks.1
        let idleTicks = cpuLoadInfo.cpu_ticks.2
        let niceTicks = cpuLoadInfo.cpu_ticks.3

        let totalTicks = userTicks + systemTicks + idleTicks + niceTicks

        var userUsage: Double = 0
        var systemUsage: Double = 0
        var idleUsage: Double = 100

        if let previous = previousCPUInfo {
            let prevUser = previous.cpu_ticks.0
            let prevSystem = previous.cpu_ticks.1
            let prevIdle = previous.cpu_ticks.2
            let prevNice = previous.cpu_ticks.3
            let prevTotal = prevUser + prevSystem + prevIdle + prevNice

            let deltaTotal = Double(totalTicks - prevTotal)
            if deltaTotal > 0 {
                userUsage = Double(userTicks - prevUser) / deltaTotal * 100
                systemUsage = Double(systemTicks - prevSystem) / deltaTotal * 100
                idleUsage = Double(idleTicks - prevIdle) / deltaTotal * 100
            }
        }

        previousCPUInfo = cpuLoadInfo

        return CPUMetrics(
            userUsage: max(0, min(100, userUsage)),
            systemUsage: max(0, min(100, systemUsage)),
            idleUsage: max(0, min(100, idleUsage)),
            coreCount: ProcessInfo.processInfo.processorCount,
            activeCoreCount: ProcessInfo.processInfo.activeProcessorCount
        )
    }

    // MARK: - Memory Metrics

    private func collectMemoryMetrics() -> MemoryMetrics {
        let totalMemory = ProcessInfo.processInfo.physicalMemory

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return .zero
        }

        // 使用固定页面大小（macOS 上通常是 4096 或 16384）
        let pageSize: UInt64 = UInt64(getpagesize())
        let free = UInt64(vmStats.free_count) * pageSize
        let active = UInt64(vmStats.active_count) * pageSize
        let inactive = UInt64(vmStats.inactive_count) * pageSize
        let wired = UInt64(vmStats.wire_count) * pageSize
        let compressed = UInt64(vmStats.compressor_page_count) * pageSize

        let used = active + wired + compressed

        // 内存压力检测
        let pressure: MemoryPressureLevel
        let usageRatio = Double(used) / Double(totalMemory)
        if usageRatio > 0.9 {
            pressure = .critical
        } else if usageRatio > 0.75 {
            pressure = .warning
        } else {
            pressure = .normal
        }

        return MemoryMetrics(
            totalMemory: totalMemory,
            usedMemory: used,
            freeMemory: free,
            activeMemory: active,
            inactiveMemory: inactive,
            compressedMemory: compressed,
            pressureLevel: pressure
        )
    }

    // MARK: - GPU Metrics

    private func collectGPUMetrics(from snapshot: UnifiedMetricsSnapshot) -> GPUMetrics {
        let deviceUtil = snapshot.gpuUsageState.availability == .unavailable ? 0 : snapshot.gpuUsage
        let vramTotal = ProcessInfo.processInfo.physicalMemory
        return GPUMetrics(
            gpuName: "Apple Silicon GPU",
            rendererUtilization: 0,
            tilerUtilization: 0,
            deviceUtilization: deviceUtil,
            vramUsed: 0,
            vramTotal: vramTotal,
            isIntegrated: true
        )
    }

    // MARK: - Network Metrics

    private func collectNetworkMetrics() -> NetworkMetrics {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var packetsIn: UInt64 = 0
        var packetsOut: UInt64 = 0

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            return .zero
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            let addr = current.pointee
            ptr = addr.ifa_next
            guard let addressPtr = addr.ifa_addr else { continue }

            // 只统计物理接口
            if addressPtr.pointee.sa_family == UInt8(AF_LINK) {
                if let data = addr.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                    bytesIn += UInt64(networkData.ifi_ibytes)
                    bytesOut += UInt64(networkData.ifi_obytes)
                    packetsIn += UInt64(networkData.ifi_ipackets)
                    packetsOut += UInt64(networkData.ifi_opackets)
                }
            }
        }

        // 计算速率
        var bytesInPerSec: UInt64 = 0
        var bytesOutPerSec: UInt64 = 0
        var packetsInPerSec: UInt64 = 0
        var packetsOutPerSec: UInt64 = 0

        let now = Date()
        if let prevBytes = previousNetworkBytes,
           let prevPackets = previousNetworkPackets,
           let prevTime = previousNetworkTime {
            let elapsed = now.timeIntervalSince(prevTime)
            if elapsed > 0 {
                bytesInPerSec = UInt64(Double(bytesIn - prevBytes.in) / elapsed)
                bytesOutPerSec = UInt64(Double(bytesOut - prevBytes.out) / elapsed)
                packetsInPerSec = UInt64(Double(packetsIn - prevPackets.in) / elapsed)
                packetsOutPerSec = UInt64(Double(packetsOut - prevPackets.out) / elapsed)
            }
        }

        previousNetworkBytes = (bytesIn, bytesOut)
        previousNetworkPackets = (packetsIn, packetsOut)
        previousNetworkTime = now

        return NetworkMetrics(
            bytesInPerSecond: bytesInPerSec,
            bytesOutPerSecond: bytesOutPerSec,
            totalBytesIn: bytesIn,
            totalBytesOut: bytesOut,
            packetsInPerSecond: packetsInPerSec,
            packetsOutPerSecond: packetsOutPerSec,
            activeConnections: 0 // 需要 netstat 或 lsof
        )
    }

    // MARK: - Disk Metrics

    private func collectDiskMetrics() -> DiskMetrics {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser

        var totalSpace: UInt64 = 0
        var availableSpace: UInt64 = 0

        if let attributes = try? fileManager.attributesOfFileSystem(forPath: homeURL.path) {
            totalSpace = (attributes[.systemSize] as? UInt64) ?? 0
            availableSpace = (attributes[.systemFreeSize] as? UInt64) ?? 0
        }

        // 磁盘 I/O 需要 IOKit 或读取 /proc (macOS 没有)
        // 这里返回简化版本
        return DiskMetrics(
            readBytesPerSecond: 0,
            writeBytesPerSecond: 0,
            totalReadBytes: 0,
            totalWriteBytes: 0,
            totalSpace: totalSpace,
            availableSpace: availableSpace
        )
    }

    // MARK: - Thermal Metrics

    private func collectThermalMetrics(from snapshot: UnifiedMetricsSnapshot) -> ThermalMetrics {
        return ThermalMetrics(
            thermalState: HardwareThermalState.from(ProcessInfo.processInfo.thermalState),
            cpuTemperature: snapshot.cpuTemperatureState.availability == .unavailable ? nil : snapshot.cpuTemperature,
            gpuTemperature: snapshot.gpuTemperatureState.availability == .unavailable ? nil : snapshot.gpuTemperature,
            fanSpeed: snapshot.fanState.availability == .unavailable ? nil : snapshot.fanRPMs.first
        )
    }

    // MARK: - History Management

    private func updateHistory(cpu: CPUMetrics, memory: MemoryMetrics, network: NetworkMetrics) {
        let maxHistoryCount = Int(configuration.historyRetention / configuration.samplingInterval)

        cpuHistory.append(cpu)
        if cpuHistory.count > maxHistoryCount {
            cpuHistory.removeFirst(cpuHistory.count - maxHistoryCount)
        }

        memoryHistory.append(memory)
        if memoryHistory.count > maxHistoryCount {
            memoryHistory.removeFirst(memoryHistory.count - maxHistoryCount)
        }

        networkHistory.append(network)
        if networkHistory.count > maxHistoryCount {
            networkHistory.removeFirst(networkHistory.count - maxHistoryCount)
        }
    }

    // MARK: - Persistence

    private func saveConfiguration() {
        try? Self.configurationStore.save(configuration)
    }

    private static func loadConfiguration() -> HardwareMonitorConfiguration? {
        Self.configurationStore.load()
    }
}
#endif
