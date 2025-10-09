import Foundation
import Metal
import Observation
import os.log
import UIKit
import Darwin

@MainActor
final class DeviceStatusService: @unchecked Sendable {
    static let shared = DeviceStatusService()

    private let statusStore = DeviceStatusStore()
    private let log = Logger(subsystem: "com.skybridge.compass", category: "DeviceStatusService")

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func statusStream(interval: Duration = .seconds(3)) -> AsyncStream<DeviceStatus> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let status = await self.captureStatus()
                    continuation.yield(status)
                    try? await Task.sleep(for: interval)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func captureStatus() async -> DeviceStatus {
        let summary = fetchSummary()
        let cpu = fetchCPUStatus()
        let memory = fetchMemoryStatus()
        let battery = fetchBatteryStatus()
        let status = DeviceStatus(summary: summary, cpu: cpu, memory: memory, battery: battery, timestamp: .now)
        statusStore.persist(status)
        return status
    }

    private func fetchSummary() -> DeviceSummary {
        let device = UIDevice.current
        let systemName = "\(device.systemName) \(device.systemVersion)"
        let architecture = sysctlString(for: "hw.machine") ?? "arm64"
        let chip = sysctlString(for: "machdep.cpu.brand_string") ?? "Apple SoC"
        let gpu = MTLCreateSystemDefaultDevice()?.name ?? "Apple GPU"
        return DeviceSummary(
            deviceName: device.name,
            systemName: systemName,
            architecture: architecture,
            chipset: chip,
            gpuName: gpu
        )
    }

    private func fetchCPUStatus() -> CPUStatus {
        let coreCount = ProcessInfo.processInfo.processorCount
        let frequency = sysctlFrequency(for: "hw.cpufrequency")
        let load = computeCPULoad()
        let loads = computeLoadAverages(count: 3)
        let temperature = estimateCPUTemperature()
        return CPUStatus(usage: load, cores: coreCount, frequencyMHz: frequency, temperatureCelsius: temperature, loadAverages: loads)
    }

    private func fetchMemoryStatus() -> MemoryStatus {
        var stats = vm_statistics64()
        var count = HOST_VM_INFO64_COUNT
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound -> kern_return_t in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            log.error("Failed to fetch memory stats: \(result)")
            let physical = ProcessInfo.processInfo.physicalMemory
            return MemoryStatus(totalBytes: physical, usedBytes: physical / 2, pressure: .warning)
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count + stats.inactive_count + stats.wire_count)
        let total = UInt64(stats.active_count + stats.inactive_count + stats.free_count + stats.wire_count)
        let used = active * pageSize
        let totalBytes = total * pageSize
        let pressureLevel: MemoryStatus.Pressure
        if #available(iOS 16.0, *) {
            let pressure = ProcessInfo.processInfo.physicalMemoryPressureLevel
            switch pressure {
            case .normal: pressureLevel = .normal
            case .warning: pressureLevel = .warning
            case .critical: pressureLevel = .critical
            @unknown default:
                pressureLevel = .warning
            }
        } else {
            pressureLevel = .warning
        }
        return MemoryStatus(totalBytes: totalBytes, usedBytes: used, pressure: pressureLevel)
    }

    private func fetchBatteryStatus() -> BatteryStatus {
        let device = UIDevice.current
        let rawLevel = Double(device.batteryLevel)
        let level = rawLevel >= 0 ? rawLevel : 0
        let state: BatteryStatus.State
        switch device.batteryState {
        case .charging: state = .charging
        case .full: state = .full
        case .unplugged: state = .unplugged
        default: state = .unknown
        }
        let thermal = ProcessInfo.processInfo.thermalState
        let temperature: Double?
        switch thermal {
        case .nominal: temperature = 32
        case .fair: temperature = 36
        case .serious: temperature = 40
        case .critical: temperature = 45
        @unknown default: temperature = nil
        }
        let health: BatteryStatus.Health
        if level >= 0.9 {
            health = .excellent
        } else if level >= 0.7 {
            health = .good
        } else if level >= 0.4 {
            health = .fair
        } else {
            health = .poor
        }
        return BatteryStatus(level: level, state: state, temperatureCelsius: temperature, health: health)
    }

    private func computeCPULoad() -> Double {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &cpuInfo, &cpuInfoCount)
        guard result == KERN_SUCCESS, let cpuInfo else { return 0 }
        defer {
            let pointer = vm_address_t(UInt(bitPattern: cpuInfo))
            vm_deallocate(mach_task_self_, pointer, vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        let array = Array(UnsafeBufferPointer(start: cpuInfo, count: Int(cpuInfoCount)))
        var totalTicks = 0
        var totalUsed = 0
        for cpu in 0..<Int(processorCount) {
            let base = cpu * Int(PROCESSOR_CPU_LOAD_INFO_COUNT)
            let user = array[base + Int(CPU_STATE_USER)]
            let system = array[base + Int(CPU_STATE_SYSTEM)]
            let nice = array[base + Int(CPU_STATE_NICE)]
            let idle = array[base + Int(CPU_STATE_IDLE)]
            let used = user + system + nice
            totalUsed += Int(used)
            totalTicks += Int(used + idle)
        }
        guard totalTicks > 0 else { return 0 }
        return Double(totalUsed) / Double(totalTicks)
    }

    private func computeLoadAverages(count: Int) -> [Double] {
        var loads = Array(repeating: 0.0, count: count)
        let result = getloadavg(&loads, Int32(count))
        guard result > 0 else { return Array(loads.prefix(count)) }
        return Array(loads.prefix(result))
    }

    private func estimateCPUTemperature() -> Double? {
        let thermal = ProcessInfo.processInfo.thermalState
        switch thermal {
        case .nominal: return 32
        case .fair: return 36
        case .serious: return 42
        case .critical: return 48
        @unknown default: return nil
        }
    }

    private func sysctlString(for key: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private func sysctlFrequency(for key: String) -> Double? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        guard value > 0 else { return nil }
        return Double(value) / 1_000_000
    }
}
