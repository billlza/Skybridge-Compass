//
// HardwareMetricsTypes.swift
// SkyBridgeCore
//
// 硬件性能监控 - 类型定义
// 支持 macOS 14.0+, Apple Silicon 优化
//

import Foundation

// MARK: - CPU 指标

/// CPU 使用率指标
public struct CPUMetrics: Sendable, Equatable {
    /// 用户态使用率 (0-100)
    public let userUsage: Double

    /// 系统态使用率 (0-100)
    public let systemUsage: Double

    /// 空闲率 (0-100)
    public let idleUsage: Double

    /// 总使用率 (0-100)
    public var totalUsage: Double {
        userUsage + systemUsage
    }

    /// 核心数
    public let coreCount: Int

    /// 活跃核心数
    public let activeCoreCount: Int

    /// 时间戳
    public let timestamp: Date

    public init(
        userUsage: Double,
        systemUsage: Double,
        idleUsage: Double,
        coreCount: Int,
        activeCoreCount: Int
    ) {
        self.userUsage = userUsage
        self.systemUsage = systemUsage
        self.idleUsage = idleUsage
        self.coreCount = coreCount
        self.activeCoreCount = activeCoreCount
        self.timestamp = Date()
    }

    public static let zero = CPUMetrics(
        userUsage: 0,
        systemUsage: 0,
        idleUsage: 100,
        coreCount: ProcessInfo.processInfo.processorCount,
        activeCoreCount: ProcessInfo.processInfo.activeProcessorCount
    )
}

// MARK: - 内存指标

/// 内存使用指标
public struct MemoryMetrics: Sendable, Equatable {
    /// 物理内存总量 (bytes)
    public let totalMemory: UInt64

    /// 已使用内存 (bytes)
    public let usedMemory: UInt64

    /// 可用内存 (bytes)
    public let freeMemory: UInt64

    /// 活跃内存 (bytes)
    public let activeMemory: UInt64

    /// 非活跃内存 (bytes)
    public let inactiveMemory: UInt64

    /// 压缩内存 (bytes)
    public let compressedMemory: UInt64

    /// 内存压力等级
    public let pressureLevel: MemoryPressureLevel

    /// 使用率 (0-100)
    public var usagePercent: Double {
        guard totalMemory > 0 else { return 0 }
        return Double(usedMemory) / Double(totalMemory) * 100
    }

    /// 时间戳
    public let timestamp: Date

    public init(
        totalMemory: UInt64,
        usedMemory: UInt64,
        freeMemory: UInt64,
        activeMemory: UInt64,
        inactiveMemory: UInt64,
        compressedMemory: UInt64,
        pressureLevel: MemoryPressureLevel
    ) {
        self.totalMemory = totalMemory
        self.usedMemory = usedMemory
        self.freeMemory = freeMemory
        self.activeMemory = activeMemory
        self.inactiveMemory = inactiveMemory
        self.compressedMemory = compressedMemory
        self.pressureLevel = pressureLevel
        self.timestamp = Date()
    }

    public static let zero = MemoryMetrics(
        totalMemory: 0,
        usedMemory: 0,
        freeMemory: 0,
        activeMemory: 0,
        inactiveMemory: 0,
        compressedMemory: 0,
        pressureLevel: .normal
    )
}

/// 内存压力等级
public enum MemoryPressureLevel: String, Sendable, Codable {
    case normal = "normal"
    case warning = "warning"
    case critical = "critical"

    public var displayName: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "警告"
        case .critical: return "紧急"
        }
    }
}

// MARK: - GPU 指标

/// GPU 使用指标
public struct GPUMetrics: Sendable, Equatable {
    /// GPU 名称
    public let gpuName: String

    /// 渲染器使用率 (0-100)
    public let rendererUtilization: Double

    /// 总线使用率 (0-100)
    public let tilerUtilization: Double

    /// 设备使用率 (0-100)
    public let deviceUtilization: Double

    /// 显存使用量 (bytes)
    public let vramUsed: UInt64

    /// 显存总量 (bytes)
    public let vramTotal: UInt64

    /// 是否为集成显卡
    public let isIntegrated: Bool

    /// 时间戳
    public let timestamp: Date

    public var vramUsagePercent: Double {
        guard vramTotal > 0 else { return 0 }
        return Double(vramUsed) / Double(vramTotal) * 100
    }

    public init(
        gpuName: String,
        rendererUtilization: Double,
        tilerUtilization: Double,
        deviceUtilization: Double,
        vramUsed: UInt64,
        vramTotal: UInt64,
        isIntegrated: Bool
    ) {
        self.gpuName = gpuName
        self.rendererUtilization = rendererUtilization
        self.tilerUtilization = tilerUtilization
        self.deviceUtilization = deviceUtilization
        self.vramUsed = vramUsed
        self.vramTotal = vramTotal
        self.isIntegrated = isIntegrated
        self.timestamp = Date()
    }

    public static let zero = GPUMetrics(
        gpuName: "Unknown",
        rendererUtilization: 0,
        tilerUtilization: 0,
        deviceUtilization: 0,
        vramUsed: 0,
        vramTotal: 0,
        isIntegrated: true
    )
}

// MARK: - 网络指标

/// 网络吞吐量指标
public struct NetworkMetrics: Sendable, Equatable {
    /// 接收速率 (bytes/sec)
    public let bytesInPerSecond: UInt64

    /// 发送速率 (bytes/sec)
    public let bytesOutPerSecond: UInt64

    /// 总接收量 (bytes)
    public let totalBytesIn: UInt64

    /// 总发送量 (bytes)
    public let totalBytesOut: UInt64

    /// 接收数据包/秒
    public let packetsInPerSecond: UInt64

    /// 发送数据包/秒
    public let packetsOutPerSecond: UInt64

    /// 活跃连接数
    public let activeConnections: Int

    /// 时间戳
    public let timestamp: Date

    public init(
        bytesInPerSecond: UInt64,
        bytesOutPerSecond: UInt64,
        totalBytesIn: UInt64,
        totalBytesOut: UInt64,
        packetsInPerSecond: UInt64,
        packetsOutPerSecond: UInt64,
        activeConnections: Int
    ) {
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
        self.totalBytesIn = totalBytesIn
        self.totalBytesOut = totalBytesOut
        self.packetsInPerSecond = packetsInPerSecond
        self.packetsOutPerSecond = packetsOutPerSecond
        self.activeConnections = activeConnections
        self.timestamp = Date()
    }

    public static let zero = NetworkMetrics(
        bytesInPerSecond: 0,
        bytesOutPerSecond: 0,
        totalBytesIn: 0,
        totalBytesOut: 0,
        packetsInPerSecond: 0,
        packetsOutPerSecond: 0,
        activeConnections: 0
    )
}

// MARK: - 磁盘指标

/// 磁盘 I/O 指标
public struct DiskMetrics: Sendable, Equatable {
    /// 读取速率 (bytes/sec)
    public let readBytesPerSecond: UInt64

    /// 写入速率 (bytes/sec)
    public let writeBytesPerSecond: UInt64

    /// 总读取量 (bytes)
    public let totalReadBytes: UInt64

    /// 总写入量 (bytes)
    public let totalWriteBytes: UInt64

    /// 磁盘总空间 (bytes)
    public let totalSpace: UInt64

    /// 可用空间 (bytes)
    public let availableSpace: UInt64

    /// 已用空间 (bytes)
    public var usedSpace: UInt64 {
        totalSpace - availableSpace
    }

    /// 使用率 (0-100)
    public var usagePercent: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace) * 100
    }

    /// 时间戳
    public let timestamp: Date

    public init(
        readBytesPerSecond: UInt64,
        writeBytesPerSecond: UInt64,
        totalReadBytes: UInt64,
        totalWriteBytes: UInt64,
        totalSpace: UInt64,
        availableSpace: UInt64
    ) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.totalReadBytes = totalReadBytes
        self.totalWriteBytes = totalWriteBytes
        self.totalSpace = totalSpace
        self.availableSpace = availableSpace
        self.timestamp = Date()
    }

    public static let zero = DiskMetrics(
        readBytesPerSecond: 0,
        writeBytesPerSecond: 0,
        totalReadBytes: 0,
        totalWriteBytes: 0,
        totalSpace: 0,
        availableSpace: 0
    )
}

// MARK: - 温度/散热指标

/// 温度和散热指标
public struct ThermalMetrics: Sendable, Equatable {
    /// 散热状态
    public let thermalState: HardwareThermalState

    /// CPU 温度 (摄氏度, 可选)
    public let cpuTemperature: Double?

    /// GPU 温度 (摄氏度, 可选)
    public let gpuTemperature: Double?

    /// 风扇转速 (RPM, 可选)
    public let fanSpeed: Int?

    /// 时间戳
    public let timestamp: Date

    public init(
        thermalState: HardwareThermalState,
        cpuTemperature: Double? = nil,
        gpuTemperature: Double? = nil,
        fanSpeed: Int? = nil
    ) {
        self.thermalState = thermalState
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.fanSpeed = fanSpeed
        self.timestamp = Date()
    }

    public static let normal = ThermalMetrics(thermalState: .nominal)
}

/// 散热状态
public enum HardwareThermalState: String, Sendable, Codable, Equatable {
    case nominal = "nominal"
    case fair = "fair"
    case serious = "serious"
    case critical = "critical"

    public var displayName: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "轻微发热"
        case .serious: return "严重发热"
        case .critical: return "过热"
        }
    }

    /// 从 ProcessInfo.ThermalState 转换
    public static func from(_ state: ProcessInfo.ThermalState) -> HardwareThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}

// MARK: - 综合指标快照

/// 系统硬件指标综合快照
public struct SystemMetricsSnapshot: Sendable {
    public let cpu: CPUMetrics
    public let memory: MemoryMetrics
    public let gpu: GPUMetrics
    public let network: NetworkMetrics
    public let disk: DiskMetrics
    public let thermal: ThermalMetrics
    public let timestamp: Date

    public init(
        cpu: CPUMetrics,
        memory: MemoryMetrics,
        gpu: GPUMetrics,
        network: NetworkMetrics,
        disk: DiskMetrics,
        thermal: ThermalMetrics
    ) {
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.network = network
        self.disk = disk
        self.thermal = thermal
        self.timestamp = Date()
    }

    public static let zero = SystemMetricsSnapshot(
        cpu: .zero,
        memory: .zero,
        gpu: .zero,
        network: .zero,
        disk: .zero,
        thermal: .normal
    )
}

// MARK: - 监控配置

/// 硬件监控配置
public struct HardwareMonitorConfiguration: Codable, Sendable {
    /// 采样间隔（秒）
    public var samplingInterval: TimeInterval

    /// 是否监控 CPU
    public var monitorCPU: Bool

    /// 是否监控内存
    public var monitorMemory: Bool

    /// 是否监控 GPU
    public var monitorGPU: Bool

    /// 是否监控网络
    public var monitorNetwork: Bool

    /// 是否监控磁盘
    public var monitorDisk: Bool

    /// 是否监控温度
    public var monitorThermal: Bool

    /// 历史记录保留时间（秒）
    public var historyRetention: TimeInterval

    /// 默认配置
    public static let `default` = HardwareMonitorConfiguration(
        samplingInterval: 1.0,
        monitorCPU: true,
        monitorMemory: true,
        monitorGPU: true,
        monitorNetwork: true,
        monitorDisk: true,
        monitorThermal: true,
        historyRetention: 3600 // 1小时
    )

    public init(
        samplingInterval: TimeInterval = 1.0,
        monitorCPU: Bool = true,
        monitorMemory: Bool = true,
        monitorGPU: Bool = true,
        monitorNetwork: Bool = true,
        monitorDisk: Bool = true,
        monitorThermal: Bool = true,
        historyRetention: TimeInterval = 3600
    ) {
        self.samplingInterval = samplingInterval
        self.monitorCPU = monitorCPU
        self.monitorMemory = monitorMemory
        self.monitorGPU = monitorGPU
        self.monitorNetwork = monitorNetwork
        self.monitorDisk = monitorDisk
        self.monitorThermal = monitorThermal
        self.historyRetention = historyRetention
    }
}
