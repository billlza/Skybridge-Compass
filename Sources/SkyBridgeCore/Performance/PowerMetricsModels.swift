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

/// XPC 传输的系统指标（来自提权 Helper 聚合的 powermetrics 输出）
public struct PowerMetricsSnapshot: Codable, Sendable {
    public let timestamp: Date
    public let monitoringMode: MonitoringMode?
    public let cpuUsagePercent: Double?
    public let memoryUsagePercent: Double?
    public let gpuUsagePercent: Double?
    public let gpuPowerWatts: Double?
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

    public init(
        timestamp: Date,
        monitoringMode: MonitoringMode? = nil,
        cpuUsagePercent: Double?,
        memoryUsagePercent: Double?,
        gpuUsagePercent: Double?,
        gpuPowerWatts: Double?,
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
        fanAgeMs: Int? = nil
    ) {
        self.timestamp = timestamp
        self.monitoringMode = monitoringMode
        self.cpuUsagePercent = cpuUsagePercent
        self.memoryUsagePercent = memoryUsagePercent
        self.gpuUsagePercent = gpuUsagePercent
        self.gpuPowerWatts = gpuPowerWatts
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
    }
}
