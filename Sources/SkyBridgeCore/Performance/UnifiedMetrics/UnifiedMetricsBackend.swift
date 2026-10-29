// macOS-exclusive: this file is built on frameworks that exist only on macOS
// (AppKit / IOKit / ScreenCaptureKit / CoreWLAN / MetalFX / ServiceManagement /
// ApplicationServices). It is excluded from other platforms so SkyBridgeCore can be
// the single shared core for iOS as well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import IOKit
import os.log

@available(macOS 14.0, *)
public struct UnifiedMetricsSnapshot: Sendable {
    public let timestamp: Date
    public let mode: MonitoringMode
    public let serviceInfo: PowerMetricsServiceInfo?

    public let cpuUsage: Double
    public let memoryUsage: Double
    public let loadAvg1: Double
    public let loadAvg5: Double
    public let loadAvg15: Double

    public let gpuUsage: Double
    public let cpuPower: Double
    public let gpuPower: Double
    public let anePower: Double
    public let ramPower: Double
    public let packagePower: Double
    public let powerReadings: [PowerMetricsPowerReading]
    public let cpuTemperature: Double
    public let gpuTemperature: Double
    public let fanRPMs: [Int]

    public let gpuUsageState: MetricState
    public let gpuPowerState: MetricState
    public let cpuTemperatureState: MetricState
    public let gpuTemperatureState: MetricState
    public let fanState: MetricState

    public static func bootstrap(mode: MonitoringMode) -> UnifiedMetricsSnapshot {
        let now = Date()
        return UnifiedMetricsSnapshot(
            timestamp: now,
            mode: mode,
            serviceInfo: nil,
            cpuUsage: 0,
            memoryUsage: 0,
            loadAvg1: 0,
            loadAvg5: 0,
            loadAvg15: 0,
            gpuUsage: 0,
            cpuPower: 0,
            gpuPower: 0,
            anePower: 0,
            ramPower: 0,
            packagePower: 0,
            powerReadings: [],
            cpuTemperature: 0,
            gpuTemperature: 0,
            fanRPMs: [],
            gpuUsageState: .unavailable(reason: .temporarilyInitializing, source: .ioAccelerator, sampledAt: now),
            gpuPowerState: .unavailable(reason: .temporarilyInitializing, source: .powermetrics, sampledAt: now),
            cpuTemperatureState: .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: now),
            gpuTemperatureState: .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: now),
            fanState: .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: now)
        )
    }
}

@available(macOS 14.0, *)
public actor UnifiedMetricsBackend {
    public static let shared = UnifiedMetricsBackend()

    private let logger = Logger(subsystem: "SkyBridgeCore.Performance", category: "UnifiedMetricsBackend")
    private let helperStaleThreshold: TimeInterval = 3.5
    private let minSampleInterval: TimeInterval = 1.0

    private var mode: MonitoringMode
    private var lastSnapshot: UnifiedMetricsSnapshot
    private var lastSampledAt: Date = .distantPast
    private var previousCpuTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
    private var lastServiceInfoRefresh: Date = .distantPast
    private var cachedServiceInfo: PowerMetricsServiceInfo?
    private var lastModeLog: String = ""

    private init() {
        let raw = UserDefaults.standard.string(forKey: MonitoringMode.userDefaultsKey)
        let selectedMode = raw.flatMap { MonitoringMode(rawValue: $0) } ?? .standardPublic
        self.mode = selectedMode
        self.lastSnapshot = UnifiedMetricsSnapshot.bootstrap(mode: selectedMode)
    }

    public func monitoringMode() -> MonitoringMode {
        mode
    }

    public func setMonitoringMode(_ newMode: MonitoringMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: MonitoringMode.userDefaultsKey)
        logger.info("Unified monitoring mode changed: \(newMode.rawValue, privacy: .public)")
    }

    public func collectSnapshot(force: Bool = false) async -> UnifiedMetricsSnapshot {
        let now = Date()
        if !force, now.timeIntervalSince(lastSampledAt) < minSampleInterval {
            return lastSnapshot
        }
        lastSampledAt = now

        let cpuUsage = readCPUUsagePercent()
        let memoryUsage = readMemoryUsagePercent()
        let loadAverages = readLoadAverages()
        let ioAcceleratorUsage = readGPUUsageFromIOAccelerator()

        let gpuUsageState: MetricState
        let gpuUsageValue: Double
        if let ioAcceleratorUsage {
            gpuUsageValue = ioAcceleratorUsage
            gpuUsageState = .available(source: .ioAccelerator, sampledAt: now)
        } else {
            gpuUsageValue = 0
            gpuUsageState = .unavailable(reason: .notProvidedByOS, source: .ioAccelerator, sampledAt: now)
        }

        var snapshot = UnifiedMetricsSnapshot(
            timestamp: now,
            mode: mode,
            serviceInfo: cachedServiceInfo,
            cpuUsage: cpuUsage,
            memoryUsage: memoryUsage,
            loadAvg1: loadAverages.0,
            loadAvg5: loadAverages.1,
            loadAvg15: loadAverages.2,
            gpuUsage: gpuUsageValue,
            cpuPower: 0,
            gpuPower: 0,
            anePower: 0,
            ramPower: 0,
            packagePower: 0,
            powerReadings: [],
            cpuTemperature: 0,
            gpuTemperature: 0,
            fanRPMs: [],
            gpuUsageState: gpuUsageState,
            gpuPowerState: mode == .expertPrivate
                ? .unavailable(reason: .temporarilyInitializing, source: .powermetrics, sampledAt: now)
                : .unavailable(reason: .requiresExpertMode, source: .powermetrics, sampledAt: now),
            cpuTemperatureState: mode == .expertPrivate
                ? .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: now)
                : .unavailable(reason: .requiresExpertMode, source: .smc, sampledAt: now),
            gpuTemperatureState: mode == .expertPrivate
                ? .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: now)
                : .unavailable(reason: .requiresExpertMode, source: .smc, sampledAt: now),
            fanState: mode == .expertPrivate
                ? .unavailable(reason: .temporarilyInitializing, source: .smc, sampledAt: now)
                : .unavailable(reason: .requiresExpertMode, source: .smc, sampledAt: now)
        )

        if mode == .expertPrivate {
            if now.timeIntervalSince(lastServiceInfoRefresh) >= 15 || cachedServiceInfo == nil {
                if let info = await PowerMetricsServiceClient.shared.fetchServiceInfo() {
                    cachedServiceInfo = info
                }
                lastServiceInfoRefresh = now
            }

            if let helperSnapshot = await PowerMetricsServiceClient.shared.fetchLatestSnapshot() {
                let helperStale = now.timeIntervalSince(helperSnapshot.timestamp) > helperStaleThreshold
                let protocolVersion = helperSnapshot.protocolVersion
                    ?? cachedServiceInfo?.protocolVersion
                    ?? 1
                let helperOutdated = protocolVersion < PowerMetricsProtocol.currentVersion

                let unavailableReason: MetricUnavailableReason = helperOutdated ? .helperOutdated : .notProvidedByOS
                snapshot = UnifiedMetricsSnapshot(
                    timestamp: now,
                    mode: mode,
                    serviceInfo: cachedServiceInfo,
                    cpuUsage: cpuUsage,
                    memoryUsage: helperSnapshot.memoryUsagePercent ?? memoryUsage,
                    loadAvg1: helperSnapshot.loadAvg1 ?? loadAverages.0,
                    loadAvg5: helperSnapshot.loadAvg5 ?? loadAverages.1,
                    loadAvg15: helperSnapshot.loadAvg15 ?? loadAverages.2,
                    gpuUsage: resolveGPUUsage(
                        preferred: ioAcceleratorUsage,
                        helperValue: helperSnapshot.gpuUsagePercent,
                        helperStale: helperStale
                    ).value,
                    cpuPower: helperSnapshot.cpuPowerWatts ?? 0,
                    gpuPower: helperSnapshot.gpuPowerWatts ?? 0,
                    anePower: helperSnapshot.anePowerWatts ?? 0,
                    ramPower: helperSnapshot.ramPowerWatts ?? 0,
                    packagePower: helperSnapshot.packagePowerWatts ?? 0,
                    powerReadings: helperSnapshot.powerReadings ?? [],
                    cpuTemperature: helperSnapshot.cpuTemperatureC ?? 0,
                    gpuTemperature: helperSnapshot.gpuTemperatureC ?? 0,
                    fanRPMs: helperSnapshot.fanRPMs ?? [],
                    gpuUsageState: resolveGPUUsage(
                        preferred: ioAcceleratorUsage,
                        helperValue: helperSnapshot.gpuUsagePercent,
                        helperStale: helperStale
                    ).state,
                    gpuPowerState: resolveState(
                        valueExists: helperSnapshot.gpuPowerWatts != nil,
                        provided: helperSnapshot.gpuPowerState,
                        fallbackSource: .powermetrics,
                        fallbackReason: unavailableReason,
                        helperTimestamp: helperSnapshot.timestamp,
                        stale: helperStale,
                        helperOutdated: helperOutdated
                    ),
                    cpuTemperatureState: resolveState(
                        valueExists: helperSnapshot.cpuTemperatureC != nil,
                        provided: helperSnapshot.cpuTemperatureState,
                        fallbackSource: .smc,
                        fallbackReason: unavailableReason,
                        helperTimestamp: helperSnapshot.timestamp,
                        stale: helperStale,
                        helperOutdated: helperOutdated
                    ),
                    gpuTemperatureState: resolveState(
                        valueExists: helperSnapshot.gpuTemperatureC != nil,
                        provided: helperSnapshot.gpuTemperatureState,
                        fallbackSource: .smc,
                        fallbackReason: unavailableReason,
                        helperTimestamp: helperSnapshot.timestamp,
                        stale: helperStale,
                        helperOutdated: helperOutdated
                    ),
                    fanState: resolveState(
                        valueExists: (helperSnapshot.fanRPMs?.isEmpty == false),
                        provided: helperSnapshot.fanState,
                        fallbackSource: .smc,
                        fallbackReason: unavailableReason,
                        helperTimestamp: helperSnapshot.timestamp,
                        stale: helperStale,
                        helperOutdated: helperOutdated
                    )
                )
            } else {
                snapshot = UnifiedMetricsSnapshot(
                    timestamp: now,
                    mode: mode,
                    serviceInfo: cachedServiceInfo,
                    cpuUsage: cpuUsage,
                    memoryUsage: memoryUsage,
                    loadAvg1: loadAverages.0,
                    loadAvg5: loadAverages.1,
                    loadAvg15: loadAverages.2,
                    gpuUsage: gpuUsageValue,
                    cpuPower: 0,
                    gpuPower: 0,
                    anePower: 0,
                    ramPower: 0,
                    packagePower: 0,
                    powerReadings: [],
                    cpuTemperature: 0,
                    gpuTemperature: 0,
                    fanRPMs: [],
                    gpuUsageState: gpuUsageState,
                    gpuPowerState: .unavailable(reason: .helperUnavailable, source: .powermetrics, sampledAt: now),
                    cpuTemperatureState: .unavailable(reason: .helperUnavailable, source: .smc, sampledAt: now),
                    gpuTemperatureState: .unavailable(reason: .helperUnavailable, source: .smc, sampledAt: now),
                    fanState: .unavailable(reason: .helperUnavailable, source: .smc, sampledAt: now)
                )
            }
        }

        let logSignature = "\(snapshot.mode.rawValue)|\(snapshot.gpuUsageState.availability.rawValue)|\(snapshot.gpuPowerState.availability.rawValue)|\(snapshot.cpuTemperatureState.availability.rawValue)|\(snapshot.fanState.availability.rawValue)"
        if logSignature != lastModeLog {
            logger.info("Unified snapshot state: \(logSignature, privacy: .public)")
            lastModeLog = logSignature
        }

        lastSnapshot = snapshot
        return snapshot
    }

    private func resolveGPUUsage(
        preferred: Double?,
        helperValue: Double?,
        helperStale: Bool
    ) -> (value: Double, state: MetricState) {
        let now = Date()
        if let preferred {
            return (preferred, .available(source: .ioAccelerator, sampledAt: now))
        }
        if let helperValue {
            if helperStale {
                return (helperValue, .stale(source: .powermetrics, sampledAt: now))
            }
            return (helperValue, .available(source: .powermetrics, sampledAt: now))
        }
        return (0, .unavailable(reason: .notProvidedByOS, source: .ioAccelerator, sampledAt: now))
    }

    private func resolveState(
        valueExists: Bool,
        provided: MetricState?,
        fallbackSource: MetricSource,
        fallbackReason: MetricUnavailableReason,
        helperTimestamp: Date,
        stale: Bool,
        helperOutdated: Bool
    ) -> MetricState {
        var resolved: MetricState
        if let provided {
            resolved = MetricState(
                availability: provided.availability,
                reason: provided.reason,
                source: provided.source ?? fallbackSource,
                sampledAt: provided.sampledAt ?? helperTimestamp
            )
        } else if valueExists {
            resolved = .available(source: fallbackSource, sampledAt: helperTimestamp)
        } else {
            resolved = .unavailable(reason: fallbackReason, source: fallbackSource, sampledAt: helperTimestamp)
        }

        if helperOutdated {
            return .unavailable(reason: .helperOutdated, source: resolved.source ?? fallbackSource, sampledAt: resolved.sampledAt ?? helperTimestamp)
        }
        if stale, resolved.availability == .available {
            return .stale(source: resolved.source, sampledAt: resolved.sampledAt ?? helperTimestamp)
        }
        return resolved
    }

    private func readLoadAverages() -> (Double, Double, Double) {
        var averages = [Double](repeating: 0, count: 3)
        let result = getloadavg(&averages, 3)
        guard result == 3 else { return (0, 0, 0) }
        return (averages[0], averages[1], averages[2])
    }

    private func readCPUUsagePercent() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard result == KERN_SUCCESS, let cpuInfo else {
            return lastSnapshot.cpuUsage
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(numCPUInfo))
        }

        let info = cpuInfo.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(numCPUs)) {
            UnsafeBufferPointer(start: $0, count: Int(numCPUs))
        }

        var newTicks: [(UInt64, UInt64, UInt64, UInt64)] = []
        newTicks.reserveCapacity(Int(numCPUs))
        var totalUsage = 0.0

        for idx in 0..<Int(numCPUs) {
            let load = info[idx]
            let user = UInt64(load.cpu_ticks.0)
            let system = UInt64(load.cpu_ticks.1)
            let idle = UInt64(load.cpu_ticks.2)
            let nice = UInt64(load.cpu_ticks.3)
            newTicks.append((user, system, idle, nice))

            if previousCpuTicks.count != Int(numCPUs) {
                let total = Double(user + system + idle + nice)
                let usage = total > 0 ? Double(user + system + nice) / total * 100.0 : 0.0
                totalUsage += usage
                continue
            }

            let prev = previousCpuTicks[idx]
            let du = Double(max(0, user &- prev.0))
            let ds = Double(max(0, system &- prev.1))
            let di = Double(max(0, idle &- prev.2))
            let dn = Double(max(0, nice &- prev.3))
            let total = du + ds + di + dn
            let usage = total > 0 ? (du + ds + dn) / total * 100.0 : 0.0
            totalUsage += usage
        }

        previousCpuTicks = newTicks
        guard numCPUs > 0 else { return 0 }
        return min(max(totalUsage / Double(numCPUs), 0), 100)
    }

    private func readMemoryUsagePercent() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return lastSnapshot.memoryUsage }

        var physicalMemory: UInt64 = 0
        var memSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &physicalMemory, &memSize, nil, 0) == 0, physicalMemory > 0 else {
            return lastSnapshot.memoryUsage
        }

        var pageSizeValue: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSizeValue) == KERN_SUCCESS else {
            return lastSnapshot.memoryUsage
        }

        let pageSize = Double(pageSizeValue)
        let usedPages = Double(stats.active_count + stats.wire_count + stats.compressor_page_count)
        let used = usedPages * pageSize
        return min(max((used / Double(physicalMemory)) * 100.0, 0.0), 100.0)
    }

    private func readGPUUsageFromIOAccelerator() -> Double? {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        )
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var samples: [Double] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            if let valueRef = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            ),
               let stats = valueRef.takeRetainedValue() as? [String: Any],
               let usage = parseGPUUtilization(from: stats) {
                samples.append(usage)
            }
            service = IOIteratorNext(iterator)
        }

        guard !samples.isEmpty else { return nil }
        let avg = samples.reduce(0, +) / Double(samples.count)
        return min(max(avg, 0), 100)
    }

    private func parseGPUUtilization(from stats: [String: Any]) -> Double? {
        let primaryKeys = [
            "Device Utilization %",
            "GPU Activity(%)",
            "GPU Utilization",
            "GPU Usage %",
            "Device Utilization",
            "GPU Busy",
            "utilization",
            "usage",
            "load"
        ]

        for key in primaryKeys {
            guard let raw = stats[key] else { continue }
            guard let value = numberValue(from: raw) else { continue }
            if let normalized = normalizePercent(value) {
                return normalized
            }
        }

        let rendererKeys = ["Renderer Utilization %", "Renderer Utilization", "rendererUtilization"]
        let tilerKeys = ["Tiler Utilization %", "Tiler Utilization", "tilerUtilization"]

        let renderer = firstNormalizedPercent(in: stats, keys: rendererKeys)
        let tiler = firstNormalizedPercent(in: stats, keys: tilerKeys)
        switch (renderer, tiler) {
        case let (.some(r), .some(t)):
            return (r + t) / 2.0
        case let (.some(r), .none):
            return r
        case let (.none, .some(t)):
            return t
        case (.none, .none):
            return nil
        }
    }

    private func numberValue(from raw: Any) -> Double? {
        if let number = raw as? NSNumber {
            return number.doubleValue
        }
        if let string = raw as? String {
            let filtered = string.filter { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(filtered)
        }
        return nil
    }

    private func firstNormalizedPercent(in stats: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let raw = stats[key], let value = numberValue(from: raw) else { continue }
            if let normalized = normalizePercent(value) {
                return normalized
            }
        }
        return nil
    }

    private func normalizePercent(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        if value < 0 { return nil }
        if value <= 1.0 {
            return value * 100.0
        }
        if value <= 100.0 {
            return value
        }
        if value <= 10_000.0 {
            return value / 100.0
        }
        return nil
    }
}

public enum PowerMetricsProtocol {
    public static let currentVersion: Int = 3
}
#endif
