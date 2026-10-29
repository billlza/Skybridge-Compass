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
    public let temperatureReadings: [PrivateTemperatureReading]
    public let fanReadings: [PrivateFanReading]
    public let powerReadings: [PrivatePowerReading]
    public let cpuPowerWatts: Double?
    public let gpuPowerWatts: Double?
    public let anePowerWatts: Double?
    public let ramPowerWatts: Double?
    public let packagePowerWatts: Double?

    public init(
        timestamp: Date,
        status: PrivateSensorBackendStatus,
        cpuTemperatureC: Double?,
        gpuTemperatureC: Double?,
        cpuTemperatureFromHID: Bool,
        gpuTemperatureFromHID: Bool,
        fanRPMs: [Int],
        temperatureReadings: [PrivateTemperatureReading] = [],
        fanReadings: [PrivateFanReading] = [],
        powerReadings: [PrivatePowerReading] = [],
        cpuPowerWatts: Double? = nil,
        gpuPowerWatts: Double?,
        anePowerWatts: Double? = nil,
        ramPowerWatts: Double? = nil,
        packagePowerWatts: Double? = nil
    ) {
        self.timestamp = timestamp
        self.status = status
        self.cpuTemperatureC = cpuTemperatureC
        self.gpuTemperatureC = gpuTemperatureC
        self.cpuTemperatureFromHID = cpuTemperatureFromHID
        self.gpuTemperatureFromHID = gpuTemperatureFromHID
        self.fanRPMs = fanRPMs
        self.temperatureReadings = temperatureReadings
        self.fanReadings = fanReadings
        self.powerReadings = powerReadings
        self.cpuPowerWatts = cpuPowerWatts
        self.gpuPowerWatts = gpuPowerWatts
        self.anePowerWatts = anePowerWatts
        self.ramPowerWatts = ramPowerWatts
        self.packagePowerWatts = packagePowerWatts
    }
}

public enum PrivateSensorSource: Sendable, Equatable {
    case smc
    case iohid
    case ioreport
}

public enum PrivateTemperatureSensorGroup: Sendable, Equatable {
    case cpu
    case gpu
    case memory
    case system
    case unknown
}

public struct PrivateTemperatureReading: Sendable, Equatable {
    public let key: String
    public let valueCelsius: Double
    public let group: PrivateTemperatureSensorGroup
    public let source: PrivateSensorSource

    public init(
        key: String,
        valueCelsius: Double,
        group: PrivateTemperatureSensorGroup,
        source: PrivateSensorSource = .smc
    ) {
        self.key = key
        self.valueCelsius = valueCelsius
        self.group = group
        self.source = source
    }
}

public struct PrivateFanReading: Sendable, Equatable {
    public let index: Int
    public let key: String
    public let rpm: Int
    public let source: PrivateSensorSource

    public init(
        index: Int,
        key: String,
        rpm: Int,
        source: PrivateSensorSource = .smc
    ) {
        self.index = index
        self.key = key
        self.rpm = rpm
        self.source = source
    }
}

public enum PrivatePowerComponent: Sendable, Equatable {
    case cpu
    case gpu
    case ane
    case ram
    case package
    case unknown
}

public struct PrivatePowerReading: Sendable, Equatable {
    public let component: PrivatePowerComponent
    public let watts: Double
    public let source: PrivateSensorSource

    public init(
        component: PrivatePowerComponent,
        watts: Double,
        source: PrivateSensorSource = .ioreport
    ) {
        self.component = component
        self.watts = watts
        self.source = source
    }
}

public final class PrivateSensorBridge: @unchecked Sendable {
    public static let shared = PrivateSensorBridge()

    private var cpuTemperatureKeys: [String]
    private var gpuTemperatureKeys: [String]
    private var temperatureKeys: [String]
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
        self.temperatureKeys = []
        self.temperatureKeys = dedupe(cpuTemperatureKeys + gpuTemperatureKeys)
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
        var temperatureReadings: [PrivateTemperatureReading] = []
        var fanReadings: [PrivateFanReading] = []
        if smcAvailable {
            discoverAdditionalSensorKeysIfNeeded()
            temperatureReadings = readTemperatureReadings(keys: temperatureKeys, source: .smc)
            smcCPUTemperature = representativeTemperature(temperatureReadings, group: .cpu)
            smcGPUTemperature = representativeTemperature(temperatureReadings, group: .gpu)
            fanReadings = readFanReadings()
        }

        var hidCPUTemperature: Double = 0
        var hidGPUTemperature: Double = 0
        let hidStatus = sb_hid_read_temperatures(&hidCPUTemperature, &hidGPUTemperature)
        let hidHasCPU = (hidStatus & 1) != 0
        let hidHasGPU = (hidStatus & 2) != 0
        if hidHasCPU, isValidTemperature(hidCPUTemperature) {
            temperatureReadings.append(
                PrivateTemperatureReading(
                    key: "IOHID:CPU",
                    valueCelsius: hidCPUTemperature,
                    group: .cpu,
                    source: .iohid
                )
            )
        }
        if hidHasGPU, isValidTemperature(hidGPUTemperature) {
            temperatureReadings.append(
                PrivateTemperatureReading(
                    key: "IOHID:GPU",
                    valueCelsius: hidGPUTemperature,
                    group: .gpu,
                    source: .iohid
                )
            )
        }

        let powerReadings = readPowerReadings()
        let cpuPowerWatts = Self.powerValue(powerReadings, component: .cpu)
        let gpuPowerWatts = Self.powerValue(powerReadings, component: .gpu)
        let anePowerWatts = Self.powerValue(powerReadings, component: .ane)
        let ramPowerWatts = Self.powerValue(powerReadings, component: .ram)
        let packagePowerWatts = Self.powerValue(powerReadings, component: .package)

        let cpuTemperatureUsesHID = smcCPUTemperature == nil && hidHasCPU
        let gpuTemperatureUsesHID = smcGPUTemperature == nil && hidHasGPU
        let cpuTemperature = smcCPUTemperature ?? (cpuTemperatureUsesHID ? hidCPUTemperature : nil)
        let gpuTemperature = smcGPUTemperature ?? (gpuTemperatureUsesHID ? hidGPUTemperature : nil)
        let fanRPMs = fanReadings.map(\.rpm)

        let status: PrivateSensorBackendStatus
        if cpuTemperature != nil || gpuTemperature != nil || !fanRPMs.isEmpty || !powerReadings.isEmpty {
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
            fanRPMs: fanRPMs,
            temperatureReadings: temperatureReadings,
            fanReadings: fanReadings,
            powerReadings: powerReadings,
            cpuPowerWatts: cpuPowerWatts,
            gpuPowerWatts: gpuPowerWatts,
            anePowerWatts: anePowerWatts,
            ramPowerWatts: ramPowerWatts,
            packagePowerWatts: packagePowerWatts
        )
    }

    private func representativeTemperature(
        _ readings: [PrivateTemperatureReading],
        group: PrivateTemperatureSensorGroup
    ) -> Double? {
        Self.hottestTemperature(readings.filter { $0.group == group && $0.source == .smc })
    }

    private func readTemperatureReadings(
        keys: [String],
        source: PrivateSensorSource
    ) -> [PrivateTemperatureReading] {
        var readings: [PrivateTemperatureReading] = []
        for key in keys {
            let group = Self.classifyTemperatureKey(key)
            guard group != .unknown else { continue }
            guard let value = readKeyValue(key), isValidTemperature(value) else { continue }
            readings.append(PrivateTemperatureReading(key: key, valueCelsius: value, group: group, source: source))
        }
        return readings
    }

    public static func hottestTemperature(_ readings: [PrivateTemperatureReading]) -> Double? {
        readings
            .filter { isValidTemperature($0.valueCelsius) }
            .map(\.valueCelsius)
            .max()
    }

    public static func averageTemperature(_ readings: [PrivateTemperatureReading]) -> Double? {
        let values = readings
            .filter { isValidTemperature($0.valueCelsius) }
            .map(\.valueCelsius)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func powerValue(
        _ readings: [PrivatePowerReading],
        component: PrivatePowerComponent
    ) -> Double? {
        readings.first { $0.component == component }?.watts
    }

    private func readPowerReadings() -> [PrivatePowerReading] {
        var cpu = 0.0
        var gpu = 0.0
        var ane = 0.0
        var ram = 0.0
        var package = 0.0
        var mask: Int32 = 0

        let status = sb_ioreport_read_power(&cpu, &gpu, &ane, &ram, &package, &mask)
        guard status == kIOReturnSuccess else { return [] }

        var readings: [PrivatePowerReading] = []
        appendPowerReading(&readings, mask: mask, flag: SB_IOREPORT_POWER_CPU_FLAG, component: .cpu, watts: cpu)
        appendPowerReading(&readings, mask: mask, flag: SB_IOREPORT_POWER_GPU_FLAG, component: .gpu, watts: gpu)
        appendPowerReading(&readings, mask: mask, flag: SB_IOREPORT_POWER_ANE_FLAG, component: .ane, watts: ane)
        appendPowerReading(&readings, mask: mask, flag: SB_IOREPORT_POWER_RAM_FLAG, component: .ram, watts: ram)
        appendPowerReading(&readings, mask: mask, flag: SB_IOREPORT_POWER_PACKAGE_FLAG, component: .package, watts: package)
        return readings
    }

    private func appendPowerReading(
        _ readings: inout [PrivatePowerReading],
        mask: Int32,
        flag: Int32,
        component: PrivatePowerComponent,
        watts: Double
    ) {
        guard (mask & flag) != 0,
              watts.isFinite,
              watts >= 0,
              watts <= 500 else {
            return
        }
        readings.append(PrivatePowerReading(component: component, watts: watts, source: .ioreport))
    }

    private func readFanReadings() -> [PrivateFanReading] {
        var count: Int32 = 0
        let countStatus = sb_smc_read_fan_count(&count)

        var fanValues: [Int: PrivateFanReading] = [:]

        if countStatus == kIOReturnSuccess, count > 0 {
            for index in 0..<Int(count) {
                var rpm: Double = 0
                if sb_smc_read_fan_speed(Int32(index), &rpm) == kIOReturnSuccess,
                   rpm.isFinite,
                   rpm > 0,
                   rpm < 20_000 {
                    fanValues[index] = PrivateFanReading(
                        index: index,
                        key: "F\(index)Ac",
                        rpm: Int(rpm.rounded())
                    )
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
                    fanValues[index] = PrivateFanReading(
                        index: index,
                        key: "F\(index)Ac",
                        rpm: Int(rpm.rounded())
                    )
                }
            }
        }

        return fanValues.keys.sorted().compactMap { fanValues[$0] }
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
        var discoveredTemperature: [String] = []
        for index in 0..<keyCount {
            var rawKey = [CChar](repeating: 0, count: 5)
            let status = sb_smc_read_key_at_index(Int32(index), &rawKey)
            guard status == kIOReturnSuccess else { continue }

            let keyBytes = rawKey.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let key = String(decoding: keyBytes, as: UTF8.self)
            guard key.count == 4, key.hasPrefix("T") else { continue }

            switch Self.classifyTemperatureKey(key) {
            case .cpu:
                discoveredCPU.append(key)
                discoveredTemperature.append(key)
            case .gpu:
                discoveredGPU.append(key)
                discoveredTemperature.append(key)
            case .memory, .system:
                discoveredTemperature.append(key)
            case .unknown:
                continue
            }
        }

        if !discoveredCPU.isEmpty {
            cpuTemperatureKeys = dedupe(cpuTemperatureKeys + discoveredCPU)
        }
        if !discoveredGPU.isEmpty {
            gpuTemperatureKeys = dedupe(gpuTemperatureKeys + discoveredGPU)
        }
        if !discoveredTemperature.isEmpty {
            temperatureKeys = dedupe(temperatureKeys + discoveredTemperature)
        }
    }

    public static func classifyTemperatureKey(_ key: String) -> PrivateTemperatureSensorGroup {
        guard key.count == 4, key.hasPrefix("T") else { return .unknown }
        if key.hasPrefix("TC")
            || key.hasPrefix("Tp")
            || key.hasPrefix("Te")
            || key.hasPrefix("Tf") {
            return .cpu
        }
        if key.hasPrefix("TG") || key.hasPrefix("Tg") {
            return .gpu
        }
        if key.hasPrefix("Tm") {
            return .memory
        }
        if key.hasPrefix("TB") || key.hasPrefix("Ts") || key.hasPrefix("Ta") {
            return .system
        }
        return .unknown
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

    private static func isValidTemperature(_ value: Double) -> Bool {
        value >= -10 && value <= 130
    }

    private func isValidTemperature(_ value: Double) -> Bool {
        Self.isValidTemperature(value)
    }
}
