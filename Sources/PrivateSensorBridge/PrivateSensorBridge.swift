import Foundation
import IOKit
import PrivateSensorBridgeC

public enum PrivateSensorBackendStatus: Sendable {
    case available
    case permissionDenied
    case unsupported
}

public struct PrivateSensorSnapshot: Sendable {
    public let timestamp: Date
    public let status: PrivateSensorBackendStatus
    public let cpuTemperatureC: Double?
    public let gpuTemperatureC: Double?
    public let cpuTemperatureFromHID: Bool
    public let gpuTemperatureFromHID: Bool
    public let fanRPMs: [Int]
    public let gpuPowerWatts: Double?

    public init(
        timestamp: Date,
        status: PrivateSensorBackendStatus,
        cpuTemperatureC: Double?,
        gpuTemperatureC: Double?,
        cpuTemperatureFromHID: Bool,
        gpuTemperatureFromHID: Bool,
        fanRPMs: [Int],
        gpuPowerWatts: Double?
    ) {
        self.timestamp = timestamp
        self.status = status
        self.cpuTemperatureC = cpuTemperatureC
        self.gpuTemperatureC = gpuTemperatureC
        self.cpuTemperatureFromHID = cpuTemperatureFromHID
        self.gpuTemperatureFromHID = gpuTemperatureFromHID
        self.fanRPMs = fanRPMs
        self.gpuPowerWatts = gpuPowerWatts
    }
}

public final class PrivateSensorBridge: @unchecked Sendable {
    public static let shared = PrivateSensorBridge()

    private var cpuTemperatureKeys: [String]
    private var gpuTemperatureKeys: [String]
    private var sensorKeysDiscovered = false

    private init() {
        self.cpuTemperatureKeys = [
            "TC0P", "TC0E", "TC0F", "TC0D", "TC0c", "TC0H", "TC0p",
            "Tp0P", "Tp0E", "Tp0F", "Tp0D", "Tp0C", "Tp09", "Tp1h", "Tp1P", "Tp2P",
            "Te0P", "Te0S", "Te1S", "Te1P"
        ]
        self.gpuTemperatureKeys = [
            "TG0P", "TG0D", "TG0H", "Tg0P", "Tg0D", "Tg0H", "Tg1D", "Tg1P", "Tg2D"
        ]
    }

    deinit {
        sb_smc_close()
        sb_ioreport_close()
    }

    public func sample() -> PrivateSensorSnapshot {
        let now = Date()
        let smcStatus = sb_smc_open()
        let smcAvailable = smcStatus == kIOReturnSuccess

        var smcCPUTemperature: Double?
        var smcGPUTemperature: Double?
        var fans: [Int] = []
        if smcAvailable {
            discoverAdditionalSensorKeysIfNeeded()
            smcCPUTemperature = firstValidTemperature(keys: cpuTemperatureKeys)
            smcGPUTemperature = firstValidTemperature(keys: gpuTemperatureKeys)
            fans = readFanRPMs()
        }

        var hidCPUTemperature: Double = 0
        var hidGPUTemperature: Double = 0
        let hidStatus = sb_hid_read_temperatures(&hidCPUTemperature, &hidGPUTemperature)
        let hidHasCPU = (hidStatus & 1) != 0
        let hidHasGPU = (hidStatus & 2) != 0

        var gpuPowerWatts: Double?
        var rawPower: Double = 0
        if sb_ioreport_read_gpu_power(&rawPower) == kIOReturnSuccess,
           rawPower.isFinite,
           rawPower >= 0,
           rawPower <= 300 {
            gpuPowerWatts = rawPower
        }

        let cpuTemperatureUsesHID = smcCPUTemperature == nil && hidHasCPU
        let gpuTemperatureUsesHID = smcGPUTemperature == nil && hidHasGPU
        let cpuTemperature = smcCPUTemperature ?? (cpuTemperatureUsesHID ? hidCPUTemperature : nil)
        let gpuTemperature = smcGPUTemperature ?? (gpuTemperatureUsesHID ? hidGPUTemperature : nil)

        let status: PrivateSensorBackendStatus
        if cpuTemperature != nil || gpuTemperature != nil || !fans.isEmpty || gpuPowerWatts != nil {
            status = .available
        } else if smcStatus == kIOReturnNotPrivileged || smcStatus == kIOReturnNotPermitted {
            status = .permissionDenied
        } else if hidStatus == kIOReturnNotPrivileged || hidStatus == kIOReturnNotPermitted {
            status = .permissionDenied
        } else {
            status = .unsupported
        }

        return PrivateSensorSnapshot(
            timestamp: now,
            status: status,
            cpuTemperatureC: cpuTemperature,
            gpuTemperatureC: gpuTemperature,
            cpuTemperatureFromHID: cpuTemperatureUsesHID,
            gpuTemperatureFromHID: gpuTemperatureUsesHID,
            fanRPMs: fans,
            gpuPowerWatts: gpuPowerWatts
        )
    }

    private func firstValidTemperature(keys: [String]) -> Double? {
        for key in keys {
            guard let value = readKeyValue(key), isValidTemperature(value) else { continue }
            return value
        }
        return nil
    }

    private func readFanRPMs() -> [Int] {
        var count: Int32 = 0
        let countStatus = sb_smc_read_fan_count(&count)

        var fanValues = Set<Int>()

        if countStatus == kIOReturnSuccess, count > 0 {
            for index in 0..<Int(count) {
                var rpm: Double = 0
                if sb_smc_read_fan_speed(Int32(index), &rpm) == kIOReturnSuccess,
                   rpm.isFinite,
                   rpm > 0,
                   rpm < 20_000 {
                    fanValues.insert(Int(rpm.rounded()))
                }
            }
        }

        if fanValues.isEmpty {
            for index in 0..<4 {
                var rpm: Double = 0
                if sb_smc_read_fan_speed(Int32(index), &rpm) == kIOReturnSuccess,
                   rpm.isFinite,
                   rpm > 0,
                   rpm < 20_000 {
                    fanValues.insert(Int(rpm.rounded()))
                }
            }
        }

        return fanValues.sorted()
    }

    private func discoverAdditionalSensorKeysIfNeeded() {
        guard !sensorKeysDiscovered else { return }
        sensorKeysDiscovered = true

        guard let keyCountValue = readKeyValue("#KEY"),
              keyCountValue.isFinite,
              keyCountValue > 0 else {
            return
        }

        let keyCount = min(Int(keyCountValue.rounded()), 4096)
        guard keyCount > 0 else { return }

        var discoveredCPU: [String] = []
        var discoveredGPU: [String] = []
        for index in 0..<keyCount {
            var rawKey = [CChar](repeating: 0, count: 5)
            let status = sb_smc_read_key_at_index(Int32(index), &rawKey)
            guard status == kIOReturnSuccess else { continue }

            let keyBytes = rawKey.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let key = String(decoding: keyBytes, as: UTF8.self)
            guard key.count == 4, key.hasPrefix("T") else { continue }

            if isPotentialCPUTemperatureKey(key) {
                discoveredCPU.append(key)
            } else if isPotentialGPUTemperatureKey(key) {
                discoveredGPU.append(key)
            }
        }

        if !discoveredCPU.isEmpty {
            cpuTemperatureKeys = dedupe(cpuTemperatureKeys + discoveredCPU)
        }
        if !discoveredGPU.isEmpty {
            gpuTemperatureKeys = dedupe(gpuTemperatureKeys + discoveredGPU)
        }
    }

    private func isPotentialCPUTemperatureKey(_ key: String) -> Bool {
        key.hasPrefix("TC")
            || key.hasPrefix("Tp")
            || key.hasPrefix("Te")
            || key.hasPrefix("Tf")
            || key.hasPrefix("Tm")
    }

    private func isPotentialGPUTemperatureKey(_ key: String) -> Bool {
        key.hasPrefix("TG") || key.hasPrefix("Tg")
    }

    private func dedupe(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(keys.count)
        for key in keys where seen.insert(key).inserted {
            ordered.append(key)
        }
        return ordered
    }

    private func readKeyValue(_ key: String) -> Double? {
        var value: Double = 0
        var type = [CChar](repeating: 0, count: 5)
        let status = key.withCString { cString -> Int32 in
            sb_smc_read_key(cString, &value, &type)
        }
        guard status == kIOReturnSuccess else { return nil }
        guard value.isFinite else { return nil }
        return value
    }

    private func isValidTemperature(_ value: Double) -> Bool {
        value >= -10 && value <= 130
    }
}
