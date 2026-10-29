// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import os.log

/// Apple Silicon 系统监控适配器。
///
/// 保留原 API 兼容性，内部统一从 SystemPerformanceMonitor 读取真实指标。
@MainActor
public final class AppleSiliconSystemMonitor: ObservableObject {
    @Published public var cpuUsage: Double = 0
    @Published public var ecoreUsage: Double = 0
    @Published public var pcoreUsage: Double = 0
    @Published public var gpuUsage: Double = 0
    @Published public var memoryUsed: Int64 = 0
    @Published public var memoryTotal: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    @Published public var memoryPressure: Double = 0
    @Published public var cpuTemperature: Double = 0
    @Published public var gpuTemperature: Double = 0
    @Published public var systemPower: Double = 0
    @Published public var cpuPower: Double = 0
    @Published public var gpuPower: Double = 0
    @Published public var anePower: Double = 0
    @Published public var ramPower: Double = 0
    @Published public var packagePower: Double = 0
    @Published public var thermalState: ProcessInfo.ThermalState = .nominal

    public private(set) var isMonitoring = false

    private let logger = Logger(subsystem: "SkyBridgeCore", category: "AppleSiliconSystemMonitor")
    private weak var monitor: SystemPerformanceMonitor?
    private var timer: Timer?

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
        logger.info("AppleSiliconSystemMonitor started")
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        logger.info("AppleSiliconSystemMonitor stopped")
    }

    public func refreshNow() {
        refreshFromMonitor()
    }

    private func refreshFromMonitor() {
        guard let monitor else { return }

        cpuUsage = monitor.cpuUsage
        gpuUsage = monitor.gpuUsage
        memoryPressure = monitor.memoryUsage
        cpuTemperature = monitor.cpuTemperature
        gpuTemperature = monitor.gpuTemperature
        cpuPower = monitor.cpuPower
        gpuPower = monitor.gpuPower
        anePower = monitor.anePower
        ramPower = monitor.ramPower
        packagePower = monitor.packagePower

        memoryUsed = Int64((memoryPressure / 100.0) * Double(memoryTotal))

        // 当前统一后端不提供 E/P core 拆分，保持 0 明确表示不可用。
        ecoreUsage = 0
        pcoreUsage = 0
        systemPower = packagePower > 0 ? packagePower : cpuPower + gpuPower + anePower + ramPower

        thermalState = ProcessInfo.processInfo.thermalState
    }
}

extension AppleSiliconSystemMonitor {
    public func getFormattedMemoryUsage() -> String {
        let usedGB = Double(memoryUsed) / (1024.0 * 1024.0 * 1024.0)
        let totalGB = Double(memoryTotal) / (1024.0 * 1024.0 * 1024.0)
        return String(format: "%.1f GB / %.1f GB", usedGB, totalGB)
    }

    public func getCoreUsageInfo() -> (ecore: Double, pcore: Double) {
        (ecoreUsage, pcoreUsage)
    }

    public func getTemperatureStatus() -> String {
        let maxTemp = max(cpuTemperature, gpuTemperature)
        switch maxTemp {
        case 0..<40: return "低温"
        case 40..<60: return "正常"
        case 60..<80: return "偏热"
        case 80..<90: return "过热"
        default: return "危险"
        }
    }

    public func getPowerEfficiencyRating() -> String {
        guard systemPower > 0 else { return "未知" }
        let efficiency = (cpuUsage + gpuUsage) / systemPower
        switch efficiency {
        case 0..<5: return "优秀"
        case 5..<10: return "良好"
        case 10..<20: return "一般"
        default: return "较差"
        }
    }
}
#endif
