import Foundation
import IOKit.ps
import OSLog
import QuartzCore

/// 并发系统监控器（真实值版本）。
@available(macOS 14.0, *)
public actor ConcurrentSystemMonitor {
    public static let shared = ConcurrentSystemMonitor()

    private let logger = Logger(subsystem: "SkyBridgeCore", category: "ConcurrentSystemMonitor")

    private var isMonitoring = false
    private var cachedData: [SystemMonitoringType: (data: Any, timestamp: CFTimeInterval)] = [:]
    private var monitoringCallbacks: [SystemMonitoringType: @Sendable (Any) -> Void] = [:]
    private var monitoringTasks: [SystemMonitoringType: Task<Void, Never>] = [:]

    private var previousNetworkSample: (bytesIn: UInt64, bytesOut: UInt64, at: TimeInterval)?

    private init() {
        logger.info("ConcurrentSystemMonitor initialized")
    }

    public func startMonitoring() async {
        guard !isMonitoring else { return }
        isMonitoring = true
        logger.info("ConcurrentSystemMonitor started")
    }

    public func stopMonitoring() async {
        guard isMonitoring else { return }
        isMonitoring = false

        for (_, task) in monitoringTasks {
            task.cancel()
        }
        monitoringTasks.removeAll()
        cachedData.removeAll()

        logger.info("ConcurrentSystemMonitor stopped")
    }

    public func registerCallback(for type: SystemMonitoringType, callback: @escaping @Sendable (Any) -> Void) {
        monitoringCallbacks[type] = callback
        if isMonitoring {
            Task {
                await startMonitoringForType(type)
            }
        }
    }

    public func getCachedData(for type: SystemMonitoringType) -> Any? {
        guard let cached = cachedData[type] else { return nil }
        let currentTime = CACurrentMediaTime()
        if currentTime - cached.timestamp > 1.0 {
            cachedData.removeValue(forKey: type)
            return nil
        }
        return cached.data
    }

    private func startMonitoringForType(_ type: SystemMonitoringType) async {
        monitoringTasks[type]?.cancel()

        let interval: TimeInterval
        let priority: _Concurrency.TaskPriority
        switch type {
        case .cpu:
            interval = 1.0
            priority = .medium
        case .gpu:
            interval = 1.0
            priority = .medium
        case .memory:
            interval = 2.0
            priority = .background
        case .network:
            interval = 1.0
            priority = .medium
        case .battery:
            interval = 10.0
            priority = .background
        case .thermal:
            interval = 2.0
            priority = .background
        }

        let monitorType = type
        monitoringTasks[type] = Task(priority: priority) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.performMonitoring(for: monitorType)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func performMonitoring(for type: SystemMonitoringType) async {
        let start = CACurrentMediaTime()
        let data = await collectDataForType(type)
        cachedData[type] = (data: data, timestamp: start)

        if let callback = monitoringCallbacks[type] {
            callback(data)
        }

        let duration = CACurrentMediaTime() - start
        if duration > 0.1 {
            logger.warning("\(type.rawValue) monitoring took \(duration, privacy: .public)s")
        }
    }

    private func collectDataForType(_ type: SystemMonitoringType) async -> Any {
        switch type {
        case .cpu:
            let snapshot = await UnifiedMetricsBackend.shared.collectSnapshot(force: false)
            return CPUData(usage: snapshot.cpuUsage, cores: ProcessInfo.processInfo.activeProcessorCount)
        case .gpu:
            let snapshot = await UnifiedMetricsBackend.shared.collectSnapshot(force: false)
            let temp = snapshot.gpuTemperatureState.availability == .available ? snapshot.gpuTemperature : 0
            return GPUData(usage: snapshot.gpuUsage, temperature: temp)
        case .memory:
            let snapshot = await UnifiedMetricsBackend.shared.collectSnapshot(force: false)
            let total = ProcessInfo.processInfo.physicalMemory
            let used = UInt64(Double(total) * (snapshot.memoryUsage / 100.0))
            return MemoryData(used: used, total: total)
        case .network:
            return collectNetworkData()
        case .battery:
            return collectBatteryData()
        case .thermal:
            return ThermalData(state: ProcessInfo.processInfo.thermalState.rawValue)
        }
    }

    private func collectNetworkData() -> NetworkData {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return NetworkData(bytesIn: 0, bytesOut: 0)
        }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            if (Int32(current.pointee.ifa_flags) & IFF_LOOPBACK) != 0 { continue }
            guard let data = current.pointee.ifa_data else { continue }
            let info = data.assumingMemoryBound(to: if_data.self).pointee
            bytesIn &+= UInt64(info.ifi_ibytes)
            bytesOut &+= UInt64(info.ifi_obytes)
        }

        let now = Date().timeIntervalSince1970
        defer { previousNetworkSample = (bytesIn, bytesOut, now) }

        guard let previous = previousNetworkSample else {
            return NetworkData(bytesIn: 0, bytesOut: 0)
        }

        let deltaTime = max(0.001, now - previous.at)
        let inPerSec = UInt64(Double(bytesIn &- previous.bytesIn) / deltaTime)
        let outPerSec = UInt64(Double(bytesOut &- previous.bytesOut) / deltaTime)
        return NetworkData(bytesIn: inPerSec, bytesOut: outPerSec)
    }

    private func collectBatteryData() -> BatteryData {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryData(level: 100, isCharging: true)
        }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
               maxCapacity > 0 {
                let level = min(max(Double(current) / Double(maxCapacity) * 100.0, 0), 100)
                let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
                return BatteryData(level: level, isCharging: charging)
            }
        }

        return BatteryData(level: 100, isCharging: true)
    }
}

public struct CPUData: Sendable {
    public let usage: Double
    public let cores: Int

    public init(usage: Double, cores: Int) {
        self.usage = usage
        self.cores = cores
    }
}

public struct GPUData: Sendable {
    public let usage: Double
    public let temperature: Double

    public init(usage: Double, temperature: Double) {
        self.usage = usage
        self.temperature = temperature
    }
}

public struct MemoryData: Sendable {
    public let used: UInt64
    public let total: UInt64

    public var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }

    public init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }
}

public struct NetworkData: Sendable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(bytesIn: UInt64, bytesOut: UInt64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct BatteryData: Sendable {
    public let level: Double
    public let isCharging: Bool

    public init(level: Double, isCharging: Bool) {
        self.level = level
        self.isCharging = isCharging
    }
}

public struct ThermalData: Sendable {
    public let state: Int

    public init(state: Int) {
        self.state = state
    }
}

public enum SystemMonitoringType: String, CaseIterable, Sendable {
    case cpu = "cpu"
    case gpu = "gpu"
    case memory = "memory"
    case network = "network"
    case battery = "battery"
    case thermal = "thermal"
}
