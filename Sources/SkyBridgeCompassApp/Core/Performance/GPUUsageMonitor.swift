import Foundation
import OSLog
@preconcurrency import SkyBridgeCore

/// GPU 利用率监控器（真实值版本）。
///
/// 数据统一来自 UnifiedMetricsBackend，删除所有温度/功耗推算与随机回退。
@available(macOS 14.0, *)
public final class GPUUsageMonitor: @unchecked Sendable {
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "GPUUsageMonitor")

    private var isMonitoring = false
    private var monitoringTask: Task<Void, Never>?

    @MainActor
    public private(set) var currentUsage: Double = 0

    public init() {
        logger.info("GPUUsageMonitor initialized")
    }

    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitoringTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isMonitoring {
                let usage = await self.getCurrentGPUUsage()
                await MainActor.run {
                    self.currentUsage = usage
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        logger.info("GPUUsageMonitor started")
    }

    public func stopMonitoring() {
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
        logger.info("GPUUsageMonitor stopped")
    }

    public func getCurrentGPUUsage() async -> Double {
        let snapshot = await UnifiedMetricsBackend.shared.collectSnapshot(force: false)
        guard snapshot.gpuUsageState.availability != .unavailable else {
            return 0
        }
        return min(max(snapshot.gpuUsage, 0), 100)
    }
}

public struct GPUStats: Sendable {
    public let utilization: Double
    public let temperature: Double?
    public let memoryUsage: GPUMemoryUsage?
    public let timestamp: Date

    public init(
        utilization: Double,
        temperature: Double? = nil,
        memoryUsage: GPUMemoryUsage? = nil,
        timestamp: Date = Date()
    ) {
        self.utilization = utilization
        self.temperature = temperature
        self.memoryUsage = memoryUsage
        self.timestamp = timestamp
    }
}

public struct GPUMemoryUsage: Sendable {
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
