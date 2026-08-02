// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import os.log

/// Apple Silicon 风扇监控适配器。
///
/// 数据来源统一为 SystemPerformanceMonitor，移除所有估算路径。
@available(macOS 11.0, *)
@MainActor
public final class AppleSiliconFanMonitor: ObservableObject {
    @Published public var fanSpeed: Double = 0
    @Published public var fanRPM: Int = 0
    @Published public var fanCount: Int = 0
    @Published public var fanControlMode: String = "自动"
    @Published public var maxFanSpeed: Double = 6000
    @Published public var minFanSpeed: Double = 800
    @Published public var fanEfficiency: Double = 0

    public private(set) var isMonitoring = false

    private let logger = Logger(subsystem: "SkyBridgeCore", category: "AppleSiliconFanMonitor")
    private weak var monitor: SystemPerformanceMonitor?
    private var timer: Timer?
    private var lastUpdateTime: Date = .distantPast

    public init() {}

    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let sourceMonitor = PerformanceModeManager.shared.systemPerformanceMonitor ?? SystemPerformanceMonitor()
        monitor = sourceMonitor
        if !sourceMonitor.isMonitoring {
            sourceMonitor.startMonitoring(afterDelay: 0)
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFromMonitor()
            }
        }

        refreshFromMonitor()
        logger.info("AppleSiliconFanMonitor started")
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        logger.info("AppleSiliconFanMonitor stopped")
    }

    public func refreshNow() {
        refreshFromMonitor()
    }

    private func refreshFromMonitor() {
        guard let monitor else { return }

        let fans = monitor.fanSpeed
        fanCount = fans.count

        if let first = fans.first {
            fanRPM = first
            fanSpeed = min(max((Double(first) / maxFanSpeed) * 100, 0), 100)
            fanEfficiency = fanSpeed
            lastUpdateTime = Date()
        } else {
            fanRPM = 0
            fanSpeed = 0
            fanEfficiency = 0
        }

        fanControlMode = monitor.fanState.availability == .available ? "自动" : "不可用"
    }
}

extension AppleSiliconFanMonitor {
    public func getFormattedFanSpeed() -> String {
        guard fanRPM > 0 else { return "Unavailable" }
        return "\(fanRPM) RPM (\(String(format: "%.1f", fanSpeed))%)"
    }

    public func getFanStatusDescription() -> String {
        switch fanSpeed {
        case 0..<20: return "静音"
        case 20..<40: return "低速"
        case 40..<60: return "中速"
        case 60..<80: return "高速"
        default: return "全速"
        }
    }

    public func getFanHealthStatus() -> String {
        guard fanRPM > 0 else { return "不可用" }
        let timeSinceUpdate = Date().timeIntervalSince(lastUpdateTime)
        if timeSinceUpdate > 10 { return "通信异常" }
        if fanRPM < Int(minFanSpeed * 0.8) { return "转速异常" }
        if fanRPM > Int(maxFanSpeed * 1.1) { return "转速过高" }
        return "正常"
    }

    public func getFanNoiseLevel() -> String {
        switch fanSpeed {
        case 0..<25: return "静音"
        case 25..<50: return "轻微"
        case 50..<75: return "中等"
        default: return "较大"
        }
    }

    public func needsCleaning() -> Bool {
        fanRPM > 0 && fanEfficiency < 80
    }

    public func getFanConfiguration() -> (count: Int, maxRPM: Double, minRPM: Double) {
        (fanCount, maxFanSpeed, minFanSpeed)
    }

    public func getEstimatedFanPower() -> Double {
        guard fanRPM > 0 else { return 0 }
        return 0.5 + (fanSpeed / 100.0) * 2.5
    }
}
#endif
