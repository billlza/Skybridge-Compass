import Foundation

public enum MonitoringMode: String, Codable, Sendable, CaseIterable {
    case standardPublic
    case expertPrivate

    public static let userDefaultsKey = "SkyBridge.MonitoringMode"
}

public enum MetricAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case stale
}

public enum MetricUnavailableReason: String, Codable, Sendable {
    case unsupported
    case permissionDenied
    case notProvidedByOS
    case helperUnavailable
    case helperOutdated
    case parsingFailed
    case sampling
    case requiresExpertMode
    case temporarilyInitializing
}

public enum MetricSource: String, Codable, Sendable {
    case kernelAPI
    case ioAccelerator
    case smc
    case iohid
    case ioreport
    case powermetrics
    case processInfoThermalState
}

public struct MetricState: Codable, Sendable, Equatable {
    public let availability: MetricAvailability
    public let reason: MetricUnavailableReason?
    public let source: MetricSource?
    public let sampledAt: Date?

    public init(
        availability: MetricAvailability,
        reason: MetricUnavailableReason? = nil,
        source: MetricSource? = nil,
        sampledAt: Date? = nil
    ) {
        self.availability = availability
        self.reason = reason
        self.source = source
        self.sampledAt = sampledAt
    }

    public static func available(source: MetricSource, sampledAt: Date = Date()) -> MetricState {
        MetricState(availability: .available, source: source, sampledAt: sampledAt)
    }

    public static func unavailable(
        reason: MetricUnavailableReason,
        source: MetricSource? = nil,
        sampledAt: Date? = nil
    ) -> MetricState {
        MetricState(availability: .unavailable, reason: reason, source: source, sampledAt: sampledAt)
    }

    public static func stale(source: MetricSource?, sampledAt: Date?) -> MetricState {
        MetricState(availability: .stale, source: source, sampledAt: sampledAt)
    }

    public func ageMs(at now: Date = Date()) -> Int? {
        guard let sampledAt else { return nil }
        let interval = now.timeIntervalSince(sampledAt)
        guard interval >= 0 else { return 0 }
        return Int((interval * 1000.0).rounded())
    }
}

public struct PowerMetricsServiceInfo: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let helperVersion: String
    public let helperStartedAt: Date
}

public enum PowerMetricsTemperatureGroup: String, Codable, Sendable, Equatable {
    case cpu
    case gpu
    case memory
    case system
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = PowerMetricsTemperatureGroup(rawValue: rawValue) ?? .unknown
    }
}

public struct PowerMetricsTemperatureReading: Codable, Sendable, Equatable {
    public let key: String
    public let group: PowerMetricsTemperatureGroup
    public let source: MetricSource?
    public let valueCelsius: Double

    public init(
        key: String,
        group: PowerMetricsTemperatureGroup,
        source: MetricSource?,
        valueCelsius: Double
    ) {
        self.key = key
        self.group = group
        self.source = source
        self.valueCelsius = valueCelsius
    }
}

public struct PowerMetricsFanReading: Codable, Sendable, Equatable {
    public let index: Int
    public let key: String
    public let rpm: Int
    public let source: MetricSource?

    public init(index: Int, key: String, rpm: Int, source: MetricSource?) {
        self.index = index
        self.key = key
        self.rpm = rpm
        self.source = source
    }
}

public enum PowerMetricsPowerComponent: String, Codable, Sendable, Equatable {
    case cpu
    case gpu
    case ane
    case ram
    case package
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = PowerMetricsPowerComponent(rawValue: rawValue) ?? .unknown
    }
}

public struct PowerMetricsPowerReading: Codable, Sendable, Equatable {
    public let component: PowerMetricsPowerComponent
    public let source: MetricSource?
    public let watts: Double

    public init(component: PowerMetricsPowerComponent, source: MetricSource?, watts: Double) {
        self.component = component
        self.source = source
        self.watts = watts
    }
}

/// XPC 传输的系统指标（来自提权 Helper 聚合的 powermetrics 输出）
public struct PowerMetricsSnapshot: Codable, Sendable {
    public let timestamp: Date
    public let monitoringMode: MonitoringMode?
    public let cpuUsagePercent: Double?
    public let memoryUsagePercent: Double?
    public let gpuUsagePercent: Double?
    public let cpuPowerWatts: Double?
    public let gpuPowerWatts: Double?
    public let anePowerWatts: Double?
    public let ramPowerWatts: Double?
    public let packagePowerWatts: Double?
    public let cpuTemperatureC: Double?
    public let gpuTemperatureC: Double?
    public let fanRPMs: [Int]?
    public let loadAvg1: Double?
    public let loadAvg5: Double?
    public let loadAvg15: Double?

    // 指标状态元数据（兼容旧版本 Helper：全部可选）
    public let gpuUsageState: MetricState?
    public let gpuPowerState: MetricState?
    public let cpuTemperatureState: MetricState?
    public let gpuTemperatureState: MetricState?
    public let fanState: MetricState?

    // Helper 元信息（兼容旧版本 Helper：全部可选）
    public let protocolVersion: Int?
    public let helperVersion: String?
    public let helperStartedAt: Date?

    // 指标年龄（毫秒，兼容旧版本 Helper：全部可选）
    public let gpuUsageAgeMs: Int?
    public let gpuPowerAgeMs: Int?
    public let cpuTemperatureAgeMs: Int?
    public let gpuTemperatureAgeMs: Int?
    public let fanAgeMs: Int?

    // 原始传感器目录（兼容旧版本 Helper：全部可选）
    public let temperatureReadings: [PowerMetricsTemperatureReading]?
    public let fanReadings: [PowerMetricsFanReading]?
    public let cpuTemperatureHottestC: Double?
    public let gpuTemperatureHottestC: Double?
    public let cpuTemperatureAverageC: Double?
    public let gpuTemperatureAverageC: Double?
    public let powerReadings: [PowerMetricsPowerReading]?

    public init(
        timestamp: Date,
        monitoringMode: MonitoringMode? = nil,
        cpuUsagePercent: Double?,
        memoryUsagePercent: Double?,
        gpuUsagePercent: Double?,
        cpuPowerWatts: Double? = nil,
        gpuPowerWatts: Double?,
        anePowerWatts: Double? = nil,
        ramPowerWatts: Double? = nil,
        packagePowerWatts: Double? = nil,
        cpuTemperatureC: Double?,
        gpuTemperatureC: Double?,
        fanRPMs: [Int]?,
        loadAvg1: Double?,
        loadAvg5: Double?,
        loadAvg15: Double?,
        gpuUsageState: MetricState? = nil,
        gpuPowerState: MetricState? = nil,
        cpuTemperatureState: MetricState? = nil,
        gpuTemperatureState: MetricState? = nil,
        fanState: MetricState? = nil,
        protocolVersion: Int? = nil,
        helperVersion: String? = nil,
        helperStartedAt: Date? = nil,
        gpuUsageAgeMs: Int? = nil,
        gpuPowerAgeMs: Int? = nil,
        cpuTemperatureAgeMs: Int? = nil,
        gpuTemperatureAgeMs: Int? = nil,
        fanAgeMs: Int? = nil,
        temperatureReadings: [PowerMetricsTemperatureReading]? = nil,
        fanReadings: [PowerMetricsFanReading]? = nil,
        cpuTemperatureHottestC: Double? = nil,
        gpuTemperatureHottestC: Double? = nil,
        cpuTemperatureAverageC: Double? = nil,
        gpuTemperatureAverageC: Double? = nil,
        powerReadings: [PowerMetricsPowerReading]? = nil
    ) {
        self.timestamp = timestamp
        self.monitoringMode = monitoringMode
        self.cpuUsagePercent = cpuUsagePercent
        self.memoryUsagePercent = memoryUsagePercent
        self.gpuUsagePercent = gpuUsagePercent
        self.cpuPowerWatts = cpuPowerWatts
        self.gpuPowerWatts = gpuPowerWatts
        self.anePowerWatts = anePowerWatts
        self.ramPowerWatts = ramPowerWatts
        self.packagePowerWatts = packagePowerWatts
        self.cpuTemperatureC = cpuTemperatureC
        self.gpuTemperatureC = gpuTemperatureC
        self.fanRPMs = fanRPMs
        self.loadAvg1 = loadAvg1
        self.loadAvg5 = loadAvg5
        self.loadAvg15 = loadAvg15
        self.gpuUsageState = gpuUsageState
        self.gpuPowerState = gpuPowerState
        self.cpuTemperatureState = cpuTemperatureState
        self.gpuTemperatureState = gpuTemperatureState
        self.fanState = fanState
        self.protocolVersion = protocolVersion
        self.helperVersion = helperVersion
        self.helperStartedAt = helperStartedAt
        self.gpuUsageAgeMs = gpuUsageAgeMs
        self.gpuPowerAgeMs = gpuPowerAgeMs
        self.cpuTemperatureAgeMs = cpuTemperatureAgeMs
        self.gpuTemperatureAgeMs = gpuTemperatureAgeMs
        self.fanAgeMs = fanAgeMs
        self.temperatureReadings = temperatureReadings
        self.fanReadings = fanReadings
        self.cpuTemperatureHottestC = cpuTemperatureHottestC
        self.gpuTemperatureHottestC = gpuTemperatureHottestC
        self.cpuTemperatureAverageC = cpuTemperatureAverageC
        self.gpuTemperatureAverageC = gpuTemperatureAverageC
        self.powerReadings = powerReadings
    }
}
