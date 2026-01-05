import Foundation

/// XPC 传输的系统指标（来自提权 Helper 聚合的 powermetrics 输出）
public struct PowerMetricsSnapshot: Codable, Sendable {
    public let timestamp: Date
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
}

