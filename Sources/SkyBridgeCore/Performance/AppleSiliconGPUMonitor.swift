import Foundation
import Metal
import os.log

/// Apple Silicon GPU 监控适配器。
///
/// 该类型保留原有对外 API，但所有数据统一来自 SystemPerformanceMonitor，
/// 不再执行本地估算或随机回退。
@MainActor
public final class AppleSiliconGPUMonitor: ObservableObject {
    @Published public var gpuUsage: Double = 0
    @Published public var gpuMemoryUsed: Int64 = 0
    @Published public var gpuMemoryTotal: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    @Published public var gpuTemperature: Double = 0
    @Published public var gpuPower: Double = 0
    @Published public var gpuFrequency: Double = 0
    @Published public var renderingLoad: Double = 0
    @Published public var computeLoad: Double = 0

    public private(set) var isMonitoring = false

    private let logger = Logger(subsystem: "SkyBridgeCore", category: "AppleSiliconGPUMonitor")
    private let metalDevice: MTLDevice?
    private weak var monitor: SystemPerformanceMonitor?
    private var timer: Timer?

    public init() {
        self.metalDevice = MTLCreateSystemDefaultDevice()
        if let device = metalDevice, !device.hasUnifiedMemory {
            gpuMemoryTotal = Int64(device.recommendedMaxWorkingSetSize)
        }
    }

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
        logger.info("AppleSiliconGPUMonitor started")
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        logger.info("AppleSiliconGPUMonitor stopped")
    }

    public func refreshNow() {
        refreshFromMonitor()
    }

    private func refreshFromMonitor() {
        guard let monitor else { return }

        gpuUsage = monitor.gpuUsage
        gpuTemperature = monitor.gpuTemperature
        gpuPower = monitor.gpuPower

        // 当前统一后端未提供渲染/计算拆分与频率，保持明确 0（不可用）
        renderingLoad = 0
        computeLoad = 0
        gpuFrequency = 0

        // 统一内存架构下无法可靠拆分系统级 GPU 已用内存，保持 0 表示不可用。
        gpuMemoryUsed = 0
    }
}

extension AppleSiliconGPUMonitor {
    public func getFormattedGPUMemoryUsage() -> String {
        guard gpuMemoryUsed > 0, gpuMemoryTotal > 0 else {
            return "Unavailable"
        }

        let usedMB = Double(gpuMemoryUsed) / (1024 * 1024)
        let totalMB = Double(gpuMemoryTotal) / (1024 * 1024)
        if totalMB > 1024 {
            return String(format: "%.1f GB / %.1f GB", usedMB / 1024, totalMB / 1024)
        }
        return String(format: "%.0f MB / %.0f MB", usedMB, totalMB)
    }

    public func getGPULoadDistribution() -> (rendering: Double, compute: Double, idle: Double) {
        let idle = max(0, 100 - renderingLoad - computeLoad)
        return (renderingLoad, computeLoad, idle)
    }

    public func getGPUPerformanceState() -> String {
        switch gpuUsage {
        case 0..<10: return "空闲"
        case 10..<30: return "轻载"
        case 30..<60: return "中载"
        case 60..<85: return "重载"
        default: return "满载"
        }
    }

    public func getGPUEfficiencyRating() -> String {
        guard gpuPower > 0 else { return "未知" }
        let efficiency = gpuUsage / gpuPower
        switch efficiency {
        case 0..<5: return "优秀"
        case 5..<10: return "良好"
        case 10..<20: return "一般"
        default: return "较差"
        }
    }

    public func hasUnifiedMemory() -> Bool {
        metalDevice?.hasUnifiedMemory ?? true
    }

    public func getGPUDeviceName() -> String {
        metalDevice?.name ?? "Unknown GPU"
    }
}
