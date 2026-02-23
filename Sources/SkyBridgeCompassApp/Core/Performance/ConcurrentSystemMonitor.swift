import Foundation
import IOKit.ps
import OSLog
import SkyBridgeCore

/// App 层并发系统监控器（真实值适配器）。
@available(macOS 14.0, *)
public actor ConcurrentSystemMonitor {
    public static let shared = ConcurrentSystemMonitor()

    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "ConcurrentSystemMonitor")
    private var isMonitoring = false
    private var monitoringTasks: [SystemMonitoringType: Task<Void, Never>] = [:]
    private var cachedData: [SystemMonitoringType: (data: any Sendable, timestamp: Date)] = [:]
    private var monitoringCallbacks: [SystemMonitoringType: [@Sendable (any Sendable) -> Void]] = [:]

    private var previousNetworkSample: (bytesIn: UInt64, bytesOut: UInt64, at: TimeInterval)?

    private init() {}

    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        for type in SystemMonitoringType.allCases {
            startMonitoringForType(type)
        }

        logger.info("ConcurrentSystemMonitor started")
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        for (_, task) in monitoringTasks { task.cancel() }
        monitoringTasks.removeAll()
        logger.info("ConcurrentSystemMonitor stopped")
    }

    public func registerCallback(for type: SystemMonitoringType, callback: @escaping @Sendable (any Sendable) -> Void) {
        monitoringCallbacks[type, default: []].append(callback)
    }

    public func getCachedData(for type: SystemMonitoringType) -> (any Sendable)? {
        guard let cached = cachedData[type] else { return nil }
        if Date().timeIntervalSince(cached.timestamp) > 1.0 {
            cachedData.removeValue(forKey: type)
            return nil
        }
        return cached.data
    }

    private func startMonitoringForType(_ type: SystemMonitoringType) {
        monitoringTasks[type]?.cancel()

        let interval: TimeInterval
        switch type {
        case .cpu: interval = 1.0
        case .gpu: interval = 1.0
        case .memory: interval = 2.0
        case .network: interval = 1.0
        case .battery: interval = 10.0
        case .thermal: interval = 2.0
        }

        let monitorType = type
        monitoringTasks[type] = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.performMonitoring(for: monitorType)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func performMonitoring(for type: SystemMonitoringType) async {
        guard isMonitoring else { return }

        let data: any Sendable
        switch type {
        case .cpu:
            let snapshot = await UnifiedMetricsBackend.shared.collectSnapshot(force: false)
            data = CPUData(usage: snapshot.cpuUsage)
        case .gpu:
            let snapshot = await UnifiedMetricsBackend.shared.collectSnapshot(force: false)
            data = GPUData(usage: snapshot.gpuUsage)
        case .memory:
            let snapshot = await UnifiedMetricsBackend.shared.collectSnapshot(force: false)
            data = MemoryData(usage: snapshot.memoryUsage)
        case .network:
            let net = collectNetworkStats()
            data = NetworkData(bytesIn: net.bytesIn, bytesOut: net.bytesOut)
        case .battery:
            let battery = collectBatteryInfo()
            data = BatteryData(level: battery.level, isCharging: battery.isCharging)
        case .thermal:
            data = ThermalData(state: ProcessInfo.processInfo.thermalState.rawValue)
        }

        cachedData[type] = (data: data, timestamp: Date())
        if let callbacks = monitoringCallbacks[type] {
            await MainActor.run {
                for callback in callbacks {
                    callback(data)
                }
            }
        }
    }

    private func collectNetworkStats() -> (bytesIn: UInt64, bytesOut: UInt64) {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return (0, 0)
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
            totalIn &+= UInt64(info.ifi_ibytes)
            totalOut &+= UInt64(info.ifi_obytes)
        }

        let now = Date().timeIntervalSince1970
        defer { previousNetworkSample = (totalIn, totalOut, now) }

        guard let previous = previousNetworkSample else {
            return (0, 0)
        }

        let dt = max(0.001, now - previous.at)
        let inPerSec = UInt64(Double(totalIn &- previous.bytesIn) / dt)
        let outPerSec = UInt64(Double(totalOut &- previous.bytesOut) / dt)
        return (inPerSec, outPerSec)
    }

    private func collectBatteryInfo() -> (level: Double, isCharging: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (100, true)
        }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
               maxCapacity > 0 {
                let level = min(max(Double(current) / Double(maxCapacity) * 100.0, 0), 100)
                let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
                return (level, charging)
            }
        }

        return (100, true)
    }
}

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

public struct CPUData: Sendable { public let usage: Double; public init(usage: Double) { self.usage = usage } }
public struct GPUData: Sendable { public let usage: Double; public init(usage: Double) { self.usage = usage } }
public struct MemoryData: Sendable { public let usage: Double; public init(usage: Double) { self.usage = usage } }

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
    public init(state: Int) { self.state = state }
}
