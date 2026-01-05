import Foundation
import Metal
import MetalKit
import OSLog
import SwiftUI

/// Apple 2025 Metal Performance HUD 集成
/// 提供实时性能监控和可视化界面
@available(macOS 14.0, *)
@MainActor
public final class MetalPerformanceHUD: ObservableObject {
    
 // MARK: - 发布属性
    
    @Published public var isEnabled: Bool = false
    @Published public var isVisible: Bool = false
    @Published public var currentMetrics: PerformanceHUDMetrics = PerformanceHUDMetrics()
    @Published public var hudConfiguration: HUDConfiguration = HUDConfiguration()
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "MetalPerformanceHUD")
    private let metalDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    
 // 性能数据收集
    private var frameTimeHistory: [Double] = []
    private var gpuTimeHistory: [Double] = []
    private var memoryUsageHistory: [Int64] = []
    private let maxHistoryCount = 120 // 2秒的历史数据 (60fps)
    
 // HUD 渲染
    private var hudRenderer: HUDRenderer?
    private var updateTimer: Timer?
    
 // Metal Performance HUD 环境变量控制
    private var isSystemHUDEnabled: Bool = false
    
 // MARK: - 初始化
    
    public init(device: MTLDevice) throws {
        guard device.supportsFamily(.apple7) || device.supportsFamily(.apple8) || device.supportsFamily(.apple9) else {
            throw MetalPerformanceHUDError.unsupportedDevice
        }
        self.metalDevice = device
        self.commandQueue = device.makeCommandQueue()
        self.hudRenderer = try HUDRenderer(device: device)
        checkSystemHUDStatus()
        logger.info("🎯 Metal Performance HUD 初始化完成 - 设备: \(device.name)")
    }
    
    private init(fallback: Void) {
        self.metalDevice = nil
        self.commandQueue = nil
        self.hudRenderer = nil
    }
    
    public static func fallback() -> MetalPerformanceHUD {
        return MetalPerformanceHUD(fallback: ())
    }
    
 // MARK: - 公共方法
    
 /// 启用Performance HUD
    public func enable() {
        guard !isEnabled else { return }
        
        isEnabled = true
        self.isVisible = hudConfiguration.autoShow
        
 // 启用系统级Metal Performance HUD <mcreference link="https://medium.com/@shivashanker7337/apples-metal-4-the-graphics-api-revolution-nobody-saw-coming-a2e272be4d57" index="1">1</mcreference>
        enableSystemHUD()
        
 // 开始数据收集
        startDataCollection()
        
        logger.info("✅ Metal Performance HUD 已启用")
    }
    
 /// 禁用Performance HUD
    public func disable() {
        guard isEnabled else { return }
        
        isEnabled = false
        isVisible = false
        
 // 禁用系统级HUD
        disableSystemHUD()
        
 // 停止数据收集
        stopDataCollection()
        
        logger.info("❌ Metal Performance HUD 已禁用")
    }
    
 /// 切换HUD可见性
    public func toggleVisibility() {
        isVisible.toggle()
        logger.info("👁️ HUD 可见性切换: \(self.isVisible)")
    }
    
 /// 记录帧时间
    public func recordFrameTime(_ frameTime: Double) {
        guard isEnabled else { return }
        
        frameTimeHistory.append(frameTime)
        if frameTimeHistory.count > maxHistoryCount {
            frameTimeHistory.removeFirst()
        }
        
 // 更新当前指标
        updateCurrentMetrics()
    }
    
 /// 记录GPU时间
    public func recordGPUTime(_ gpuTime: Double) {
        guard isEnabled else { return }
        
        gpuTimeHistory.append(gpuTime)
        if gpuTimeHistory.count > maxHistoryCount {
            gpuTimeHistory.removeFirst()
        }
    }
    
 /// 记录内存使用
    public func recordMemoryUsage(_ memoryUsage: Int64) {
        guard isEnabled else { return }
        
        memoryUsageHistory.append(memoryUsage)
        if memoryUsageHistory.count > maxHistoryCount {
            memoryUsageHistory.removeFirst()
        }
    }
    
 /// 更新HUD配置
    public func updateConfiguration(_ configuration: HUDConfiguration) {
        self.hudConfiguration = configuration
        
 // 应用新配置
        applyConfiguration()
        
        logger.info("⚙️ HUD 配置已更新")
    }
    
 /// 获取性能报告
    public func getPerformanceReport() -> PerformanceReport {
        let avgFrameTime = frameTimeHistory.isEmpty ? 0 : frameTimeHistory.reduce(0, +) / Double(frameTimeHistory.count)
        let avgGPUTime = gpuTimeHistory.isEmpty ? 0 : gpuTimeHistory.reduce(0, +) / Double(gpuTimeHistory.count)
        let avgMemoryUsage = memoryUsageHistory.isEmpty ? 0 : memoryUsageHistory.reduce(0, +) / Int64(memoryUsageHistory.count)
        
        let devName = metalDevice?.name ?? "Unknown"
        return PerformanceReport(
            averageFrameTime: avgFrameTime,
            averageGPUTime: avgGPUTime,
            averageMemoryUsage: avgMemoryUsage,
            frameRate: avgFrameTime > 0 ? 1.0 / avgFrameTime : 0,
            deviceName: devName,
            timestamp: Date()
        )
    }
    
 // MARK: - 私有方法
    
 /// 检查系统HUD状态
    private func checkSystemHUDStatus() {
 // 检查MTL_HUD_ENABLED环境变量 <mcreference link="https://medium.com/pixo-co/metal-performance-hud에-대해-6960c47f4174" index="2">2</mcreference>
        if let hudEnabled = ProcessInfo.processInfo.environment["MTL_HUD_ENABLED"],
           hudEnabled != "0" {
            isSystemHUDEnabled = true
            logger.info("🔍 检测到系统级Metal HUD已启用")
        }
    }
    
 /// 启用系统级Metal Performance HUD
    private func enableSystemHUD() {
 // 设置环境变量启用系统HUD <mcreference link="https://medium.com/pixo-co/metal-performance-hud에-대해-6960c47f4174" index="2">2</mcreference>
        setenv("MTL_HUD_ENABLED", "1", 1)
        
 // 加载Metal HUD动态库
        let hudLibPath = "/System/Library/PrivateFrameworks/MetalTools.framework/Versions/A/MetalTools"
        
        if dlopen(hudLibPath, RTLD_NOW) != nil {
            isSystemHUDEnabled = true
            logger.info("✅ 系统级Metal HUD已启用")
        } else {
            logger.warning("⚠️ 无法加载Metal HUD库")
        }
    }
    
 /// 禁用系统级Metal Performance HUD
    private func disableSystemHUD() {
        setenv("MTL_HUD_ENABLED", "0", 1)
        isSystemHUDEnabled = false
        logger.info("❌ 系统级Metal HUD已禁用")
    }
    
 /// 开始数据收集
    private func startDataCollection() {
        updateTimer?.invalidate()
        guard isVisible else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.collectPerformanceData()
            }
        }
    }
    
 /// 停止数据收集
    private func stopDataCollection() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

 // deinit 中不直接访问 MainActor 隔离方法，依赖宿主生命周期关闭
    
 /// 收集性能数据
    private func collectPerformanceData() {
 // 收集GPU内存使用情况
        if let metalDevice = metalDevice, metalDevice.hasUnifiedMemory {
 // 使用更安全的方式获取内存使用情况
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
            
            let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_,
                             task_flavor_t(MACH_TASK_BASIC_INFO),
                             $0,
                             &count)
                }
            }
            
            if kerr == KERN_SUCCESS {
                let memoryUsage = Int64(info.resident_size)
                recordMemoryUsage(memoryUsage)
            }
        }
        
 // 更新当前指标
        updateCurrentMetrics()
    }
    
 /// 更新当前指标
    private func updateCurrentMetrics() {
        let avgFrameTime = frameTimeHistory.isEmpty ? 0 : frameTimeHistory.suffix(60).reduce(0, +) / Double(min(frameTimeHistory.count, 60))
        let avgGPUTime = gpuTimeHistory.isEmpty ? 0 : gpuTimeHistory.suffix(60).reduce(0, +) / Double(min(gpuTimeHistory.count, 60))
        let avgMemoryUsage = memoryUsageHistory.isEmpty ? 0 : memoryUsageHistory.suffix(60).reduce(0, +) / Int64(min(memoryUsageHistory.count, 60))
        
        let deviceName = metalDevice?.name ?? "Unknown"
        let isAS = {
            guard let d = metalDevice else { return false }
            return d.supportsFamily(.apple7) || d.supportsFamily(.apple8) || d.supportsFamily(.apple9)
        }()
        currentMetrics = PerformanceHUDMetrics(
            frameTime: avgFrameTime,
            frameRate: avgFrameTime > 0 ? 1.0 / avgFrameTime : 0,
            gpuTime: avgGPUTime,
            memoryUsage: avgMemoryUsage,
            deviceName: deviceName,
            isAppleSilicon: isAS
        )
    }
    
 /// 应用配置
    private func applyConfiguration() {
        isVisible = hudConfiguration.autoShow && isEnabled
        
 // 更新渲染器配置
        hudRenderer?.updateConfiguration(hudConfiguration)
    }
}

// MARK: - 数据结构

/// Performance HUD 指标
public struct PerformanceHUDMetrics: Sendable {
    public let frameTime: Double
    public let frameRate: Double
    public let gpuTime: Double
    public let memoryUsage: Int64
    public let deviceName: String
    public let isAppleSilicon: Bool
    
    public init(
        frameTime: Double = 0,
        frameRate: Double = 0,
        gpuTime: Double = 0,
        memoryUsage: Int64 = 0,
        deviceName: String = "",
        isAppleSilicon: Bool = false
    ) {
        self.frameTime = frameTime
        self.frameRate = frameRate
        self.gpuTime = gpuTime
        self.memoryUsage = memoryUsage
        self.deviceName = deviceName
        self.isAppleSilicon = isAppleSilicon
    }
}

/// HUD 配置
public struct HUDConfiguration: Sendable {
    public var autoShow: Bool = true
    public var position: HUDPosition = .topLeft
    public var opacity: Float = 0.8
    public var showFrameRate: Bool = true
    public var showGPUTime: Bool = true
    public var showMemoryUsage: Bool = true
    public var showDeviceInfo: Bool = true
    public var updateInterval: TimeInterval = 1.0/60.0
    
    public init() {}
}

/// HUD 位置
public enum HUDPosition: String, CaseIterable, Sendable {
    case topLeft = "topLeft"
    case topRight = "topRight"
    case bottomLeft = "bottomLeft"
    case bottomRight = "bottomRight"
}

/// 性能报告
public struct PerformanceReport: Sendable {
    public let averageFrameTime: Double
    public let averageGPUTime: Double
    public let averageMemoryUsage: Int64
    public let frameRate: Double
    public let deviceName: String
    public let timestamp: Date
    
    public init(
        averageFrameTime: Double,
        averageGPUTime: Double,
        averageMemoryUsage: Int64,
        frameRate: Double,
        deviceName: String,
        timestamp: Date
    ) {
        self.averageFrameTime = averageFrameTime
        self.averageGPUTime = averageGPUTime
        self.averageMemoryUsage = averageMemoryUsage
        self.frameRate = frameRate
        self.deviceName = deviceName
        self.timestamp = timestamp
    }
}

// MARK: - HUD 渲染器

@MainActor
private class HUDRenderer {
    private let device: MTLDevice
    private var renderPipelineState: MTLRenderPipelineState?
    
    init(device: MTLDevice) throws {
        self.device = device
        try setupRenderPipeline()
    }
    
    private func setupRenderPipeline() throws {
 // 设置HUD渲染管线
 // 这里可以实现自定义的HUD渲染逻辑
    }
    
    func updateConfiguration(_ configuration: HUDConfiguration) {
 // 更新渲染器配置
    }
}

// MARK: - 错误类型

public enum MetalPerformanceHUDError: Error, LocalizedError {
    case unsupportedDevice
    case hudInitializationFailed
    
    public var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            return "设备不支持Metal Performance HUD"
        case .hudInitializationFailed:
            return "HUD初始化失败"
        }
    }
}

// MARK: - 扩展

extension MTLDevice {
 /// 检查是否支持Metal Performance HUD
    var supportsPerformanceHUD: Bool {
        return supportsFamily(.apple7) || supportsFamily(.apple8) || supportsFamily(.apple9) || supportsFamily(.mac2)
    }
}
