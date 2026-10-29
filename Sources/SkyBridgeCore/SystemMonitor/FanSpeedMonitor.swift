// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import os.log

/// 风扇转速监控器（统一后端适配器）。
///
/// 不再生成模拟数据，指标全部来自 SystemPerformanceMonitor。
@available(macOS 14.0, *)
public final class FanSpeedMonitor: ObservableObject, @unchecked Sendable {
    @Published public private(set) var fanSpeeds: [FanInfo] = []
    @Published public private(set) var averageFanSpeed: Double = 0
    @Published public private(set) var maxFanSpeed: Double = 0
    @Published public private(set) var isMonitoring: Bool = false

    private let logger = Logger(subsystem: "SkyBridgeCore", category: "FanSpeedMonitor")
    private var monitoringTask: Task<Void, Never>?
    private let updateInterval: TimeInterval = 1.0

    @MainActor
    private weak var systemMonitor: SystemPerformanceMonitor?

    public init() {
        Task { @MainActor [weak self] in
            self?.systemMonitor = PerformanceModeManager.shared.systemPerformanceMonitor ?? SystemPerformanceMonitor()
        }
    }

    deinit {
        stopMonitoring()
    }

    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.systemMonitor == nil {
                self.systemMonitor = PerformanceModeManager.shared.systemPerformanceMonitor ?? SystemPerformanceMonitor()
            }
            if let monitor = self.systemMonitor, !monitor.isMonitoring {
                monitor.startMonitoring(afterDelay: 0)
            }
        }

        monitoringTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isMonitoring {
                await self.updateFanSpeeds()
                try? await Task.sleep(nanoseconds: UInt64(self.updateInterval * 1_000_000_000))
            }
        }

        logger.info("FanSpeedMonitor started")
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
        logger.info("FanSpeedMonitor stopped")
    }

    public func forceUpdate() async {
        await updateFanSpeeds()
    }

    public var fanCount: Int {
        fanSpeeds.count
    }

    public func hasFanExceedingThreshold(_ threshold: Double) -> Bool {
        fanSpeeds.contains { $0.currentSpeed > threshold }
    }

    @MainActor
    private func updateFanSpeeds() async {
        guard let monitor = systemMonitor else { return }

        let values = monitor.fanSpeed
        var infos: [FanInfo] = []

        for (idx, rpm) in values.enumerated() where rpm > 0 {
            infos.append(
                FanInfo(
                    id: idx,
                    name: idx == 0 ? "CPU风扇" : "风扇\(idx + 1)",
                    currentSpeed: Double(rpm),
                    maxSpeed: 7000,
                    minSpeed: 800,
                    targetSpeed: Double(rpm)
                )
            )
        }

        fanSpeeds = infos
        if infos.isEmpty {
            averageFanSpeed = 0
            maxFanSpeed = 0
            if monitor.fanState.availability == .unavailable {
                logger.debug("Fan metrics unavailable: \(monitor.fanState.reason?.rawValue ?? "unknown")")
            }
            return
        }

        averageFanSpeed = infos.map { $0.currentSpeed }.reduce(0, +) / Double(infos.count)
        maxFanSpeed = infos.map { $0.currentSpeed }.max() ?? 0
    }
}

public struct FanInfo: Identifiable, Codable {
    public let id: Int
    public let name: String
    public let currentSpeed: Double
    public let maxSpeed: Double
    public let minSpeed: Double
    public let targetSpeed: Double

    public var speedPercentage: Double {
        guard maxSpeed > minSpeed else { return 0 }
        return (currentSpeed - minSpeed) / (maxSpeed - minSpeed) * 100
    }

    public var formattedSpeed: String {
        String(format: "%.0f RPM", currentSpeed)
    }

    public var speedStatus: FanSpeedStatus {
        let percentage = speedPercentage
        if percentage >= 80 { return .high }
        if percentage >= 60 { return .medium }
        if percentage >= 30 { return .low }
        return .idle
    }
}

public enum FanSpeedStatus: String, CaseIterable {
    case idle = "空闲"
    case low = "低速"
    case medium = "中速"
    case high = "高速"

    public var color: String {
        switch self {
        case .idle: return "blue"
        case .low: return "green"
        case .medium: return "orange"
        case .high: return "red"
        }
    }

    public var icon: String {
        switch self {
        case .idle: return "fan"
        case .low: return "fan.fill"
        case .medium: return "tornado"
        case .high: return "hurricane"
        }
    }
}

public enum FanMonitorError: Error, LocalizedError {
    case serviceUnavailable
    case readFailed
    case permissionDenied
    case timeout

    public var errorDescription: String? {
        switch self {
        case .serviceUnavailable: return "风扇监控服务不可用"
        case .readFailed: return "读取风扇信息失败"
        case .permissionDenied: return "没有权限访问风扇信息"
        case .timeout: return "风扇读取超时"
        }
    }
}
#endif
