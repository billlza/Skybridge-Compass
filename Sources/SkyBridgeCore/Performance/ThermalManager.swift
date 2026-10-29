// macOS-exclusive: this file is built on frameworks that exist only on macOS
// (AppKit / IOKit / ScreenCaptureKit / CoreWLAN / MetalFX / ServiceManagement /
// ApplicationServices). It is excluded from other platforms so SkyBridgeCore can be
// the single shared core for iOS as well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import IOKit
import os.log

/// 热量管理器 - 专为Apple Silicon优化的温度监控和热量调节
public class ThermalManager: BaseManager {
    
 // MARK: - 发布属性
    
    @Published public private(set) var currentThermalState: ThermalState = .nominal
    @Published public private(set) var currentCPUTemperature: Double = 0.0
    @Published public private(set) var currentGPUTemperature: Double = 0.0
    @Published public private(set) var isThrottling: Bool = false
    
 // MARK: - 私有属性
    
    private var temperatureTimer: Timer?
    private var lastTemperatureLogAt: Date?
    private var lastLoggedCPUTemp: Double?
    private var lastLoggedGPUTemp: Double?
    private var thermalNotificationSource: IONotificationPortRef?
    
 // Apple Silicon专用配置
    private let appleSiliconConfig = AppleSiliconThermalConfig()
    private let chipType: ChipType
    
 // 热量调节回调
    private var thermalStateChangeCallback: ((ThermalState) -> Void)?
    private var temperatureChangeCallback: ((Double, Double) -> Void)?
    
 // 历史数据
    private var temperatureHistory: [(timestamp: Date, cpu: Double, gpu: Double)] = []
    private let maxHistoryCount = 300 // 保存5分钟的历史数据
    
 // MARK: - 初始化
    
    public init() {
 // 检测Apple Silicon芯片类型
        self.chipType = Self.detectAppleSiliconChipType()
        
        super.init(category: "ThermalManager")
        
        logger.info("✅ Apple Silicon热量管理器初始化完成 - 芯片: \(self.chipType.description)")
        logger.info("🔧 GPU核心数: \(self.chipType.gpuCoreCount), 内存带宽: \(self.chipType.memoryBandwidth) GB/s")
    }
    
 // MARK: - BaseManager重写方法
    
    override public func performInitialization() async {
        await super.performInitialization()
        setupAppleSiliconThermalMonitoring()
    }
    
    override public func performStart() async throws {
        try await super.performStart()
        startThermalMonitoring()
    }
    
    override public func performStop() async {
        await super.performStop()
        stopThermalMonitoring()
    }
    
    override public func cleanup() {
        super.cleanup()
        temperatureTimer?.invalidate()
        temperatureTimer = nil
        
        if let notificationSource = thermalNotificationSource {
            IONotificationPortDestroy(notificationSource)
            thermalNotificationSource = nil
        }
    }
    
 // MARK: - 公共方法
    
 /// 开始热量监控
    public func startThermalMonitoring() {
        guard temperatureTimer == nil else { return }
        
 // Apple Silicon专用热监控设置
        setupAppleSiliconThermalMonitoring()
        
        logger.info("🌡️ Apple Silicon热量监控已启动")
    }
    
 /// 停止热量监控
    public func stopThermalMonitoring() {
        temperatureTimer?.invalidate()
        temperatureTimer = nil
        
        if let notificationSource = thermalNotificationSource {
            IONotificationPortDestroy(notificationSource)
            thermalNotificationSource = nil
        }
        
        logger.info("🛑 热量监控已停止")
    }
    
 /// 设置热量状态变化回调
    public func setThermalStateChangeCallback(_ callback: @escaping (ThermalState) -> Void) {
        thermalStateChangeCallback = callback
    }
    
 /// 设置温度变化回调
    public func setTemperatureChangeCallback(_ callback: @escaping (Double, Double) -> Void) {
        temperatureChangeCallback = callback
    }
    
 /// 获取温度历史数据
    public func getTemperatureHistory() -> [(timestamp: Date, cpu: Double, gpu: Double)] {
        return temperatureHistory
    }
    
 /// 获取平均温度
    public func getAverageTemperature(for duration: TimeInterval) -> (cpu: Double, gpu: Double) {
        let cutoffTime = Date().addingTimeInterval(-duration)
        let recentData = temperatureHistory.filter { $0.timestamp >= cutoffTime }
        
        guard !recentData.isEmpty else {
            return (cpu: 0.0, gpu: 0.0)
        }
        
        let avgCPU = recentData.map { $0.cpu }.reduce(0, +) / Double(recentData.count)
        let avgGPU = recentData.map { $0.gpu }.reduce(0, +) / Double(recentData.count)
        
        return (cpu: avgCPU, gpu: avgGPU)
    }
    
 /// 获取温度趋势
    public func getTemperatureTrend(for duration: TimeInterval) -> TemperatureTrend {
        let cutoffTime = Date().addingTimeInterval(-duration)
        let recentData = temperatureHistory.filter { $0.timestamp >= cutoffTime }
        
        guard recentData.count >= 2 else {
            return TemperatureTrend(cpu: .stable, gpu: .stable)
        }
        
        let firstHalf = recentData.prefix(recentData.count / 2)
        let secondHalf = recentData.suffix(recentData.count / 2)
        
        let firstAvgCPU = firstHalf.map { $0.cpu }.reduce(0, +) / Double(firstHalf.count)
        let secondAvgCPU = secondHalf.map { $0.cpu }.reduce(0, +) / Double(secondHalf.count)
        
        let firstAvgGPU = firstHalf.map { $0.gpu }.reduce(0, +) / Double(firstHalf.count)
        let secondAvgGPU = secondHalf.map { $0.gpu }.reduce(0, +) / Double(secondHalf.count)
        
        let cpuTrend: ThermalTrendDirection = {
            let diff = secondAvgCPU - firstAvgCPU
            if diff > 2.0 { return .rising }
            else if diff < -2.0 { return .falling }
            else { return .stable }
        }()
        
        let gpuTrend: ThermalTrendDirection = {
            let diff = secondAvgGPU - firstAvgGPU
            if diff > 2.0 { return .rising }
            else if diff < -2.0 { return .falling }
            else { return .stable }
        }()
        
        return TemperatureTrend(cpu: cpuTrend, gpu: gpuTrend)
    }
    
 /// 强制更新热量状态
    public func forceUpdateThermalStatus() async {
        await updateAppleSiliconTemperatures()
    }
    
 /// 获取推荐的性能调整
    public func getRecommendedPerformanceAdjustment() -> PerformanceAdjustment {
        switch currentThermalState {
        case .nominal:
            return PerformanceAdjustment(
                renderScale: 1.0,
                frameRateLimit: nil,
                qualityReduction: 0
            )
        case .fair:
            return PerformanceAdjustment(
                renderScale: 0.9,
                frameRateLimit: nil,
                qualityReduction: 1
            )
        case .serious:
            return PerformanceAdjustment(
                renderScale: 0.75,
                frameRateLimit: 60,
                qualityReduction: 2
            )
        case .critical:
            return PerformanceAdjustment(
                renderScale: 0.5,
                frameRateLimit: 30,
                qualityReduction: 3
            )
        }
    }
    
 // MARK: - Apple Silicon专用方法
    
 /// Apple Silicon专用热监控设置
    private func setupAppleSiliconThermalMonitoring() {
 // 设置基于Apple Silicon优化的监控间隔
        let optimizedInterval = appleSiliconConfig.getOptimalMonitoringInterval(for: chipType)
        
 // 启动优化的温度监控定时器
        temperatureTimer = Timer.scheduledTimer(withTimeInterval: optimizedInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateAppleSiliconTemperatures()
            }
        }
        
 // 设置Apple Silicon热状态通知
        setupAppleSiliconThermalNotifications()
        
        logger.info("🌡️ Apple Silicon热监控已启动 - 间隔: \(optimizedInterval)秒")
    }
    
 /// Apple Silicon专用温度更新
    @MainActor
    private func updateAppleSiliconTemperatures() async {
 // ✅ 优先使用SystemPerformanceMonitor的真实温度数据
        let cpuTemp: Double
        let gpuTemp: Double
        
        if let systemMonitor = await getSystemPerformanceMonitor(), systemMonitor.isMonitoring {
            cpuTemp = systemMonitor.cpuTemperature
            gpuTemp = systemMonitor.gpuTemperature
            currentCPUTemperature = cpuTemp
            currentGPUTemperature = gpuTemp
        } else {
            let sampled = await readAppleSiliconTemperatures()
            cpuTemp = sampled.cpu
            gpuTemp = sampled.gpu
        
 // 更新温度数据
        currentCPUTemperature = cpuTemp
        currentGPUTemperature = gpuTemp
        }
        
 // 添加到历史记录
        addTemperatureToHistory(cpu: cpuTemp, gpu: gpuTemp)
        
 // Apple Silicon专用的热状态分析
        analyzeAppleSiliconThermalState(cpu: cpuTemp, gpu: gpuTemp)
        
 // 触发回调
        temperatureChangeCallback?(cpuTemp, gpuTemp)
        
        // Temperature logs are extremely noisy and make it hard to spot security/connection events.
        // Default: OFF in all builds. Enable explicitly via env:
        //   SKYBRIDGE_LOG_TEMPERATURE=1
        let env = ProcessInfo.processInfo.environment["SKYBRIDGE_LOG_TEMPERATURE"] ?? "0"
        let temperatureLogsEnabled = (env == "1" || env.lowercased() == "true" || env.lowercased() == "yes")
        if temperatureLogsEnabled {
            // Throttle to at most once per 30s, or when temperature changes materially (>= 2°C).
            let now = Date()
            let shouldLogByTime: Bool = {
                guard let last = lastTemperatureLogAt else { return true }
                return now.timeIntervalSince(last) >= 30
            }()
            let shouldLogByDelta: Bool = {
                let cpuDelta = abs((lastLoggedCPUTemp ?? cpuTemp) - cpuTemp)
                let gpuDelta = abs((lastLoggedGPUTemp ?? gpuTemp) - gpuTemp)
                return cpuDelta >= 2.0 || gpuDelta >= 2.0
            }()
            if shouldLogByTime || shouldLogByDelta {
                lastTemperatureLogAt = now
                lastLoggedCPUTemp = cpuTemp
                lastLoggedGPUTemp = gpuTemp
                logger.debug("🌡️ Apple Silicon温度更新 - CPU: \(String(format: "%.1f", cpuTemp))°C, GPU: \(String(format: "%.1f", gpuTemp))°C")
            }
        }
    }
    
 /// 读取Apple Silicon CPU/GPU温度（统一后端一次采样）
    private func readAppleSiliconTemperatures() async -> (cpu: Double, gpu: Double) {
        let snapshot = await UnifiedMetricsBackend.shared.collectSnapshot(force: false)
        let cpu = snapshot.cpuTemperatureState.availability == .unavailable ? 0.0 : snapshot.cpuTemperature
        let gpu = snapshot.gpuTemperatureState.availability == .unavailable ? 0.0 : snapshot.gpuTemperature
        return (cpu: cpu, gpu: gpu)
    }
    
 /// 设置Apple Silicon热状态通知
    private func setupAppleSiliconThermalNotifications() {
 // 监听系统热状态变化通知
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleAppleSiliconThermalStateChange()
            }
        }
    }
    
 /// 处理Apple Silicon热状态变化
    private func handleAppleSiliconThermalStateChange() async {
        let processInfo = ProcessInfo.processInfo
        let systemThermalState = processInfo.thermalState
        
 // 将系统热状态映射到我们的热状态
        let newThermalState: ThermalState
        switch systemThermalState {
        case .nominal:
            newThermalState = .nominal
        case .fair:
            newThermalState = .fair
        case .serious:
            newThermalState = .serious
        case .critical:
            newThermalState = .critical
        @unknown default:
            newThermalState = .nominal
        }
        
 // 更新状态
        if newThermalState != currentThermalState {
            let oldState = currentThermalState
            currentThermalState = newThermalState
            
            logger.info("🌡️ Apple Silicon热状态变化: \(oldState.rawValue) -> \(newThermalState.rawValue)")
            
 // 触发回调
            thermalStateChangeCallback?(newThermalState)
            
 // 更新节流状态
            isThrottling = newThermalState == .serious || newThermalState == .critical
        }
    }
    
 /// Apple Silicon专用的热状态分析
    private func analyzeAppleSiliconThermalState(cpu: Double, gpu: Double) {
        let maxTemp = max(cpu, gpu)
        let thermalThresholds = appleSiliconConfig.thermalThresholds
        
        let newThermalState: ThermalState
        if maxTemp >= thermalThresholds.critical {
            newThermalState = .critical
        } else if maxTemp >= thermalThresholds.warning {
            newThermalState = .serious
        } else if maxTemp >= 70.0 {
            newThermalState = .fair
        } else {
            newThermalState = .nominal
        }
        
        if newThermalState != currentThermalState {
            let oldState = currentThermalState
            currentThermalState = newThermalState
            
            logger.info("🌡️ Apple Silicon热状态分析变化: \(oldState.rawValue) -> \(newThermalState.rawValue)")
            thermalStateChangeCallback?(newThermalState)
            isThrottling = newThermalState == .serious || newThermalState == .critical
        }
    }
    
 /// 添加温度到历史记录
    private func addTemperatureToHistory(cpu: Double, gpu: Double) {
        let entry = (timestamp: Date(), cpu: cpu, gpu: gpu)
        temperatureHistory.append(entry)
        
 // 保持历史记录在限制范围内
        if temperatureHistory.count > maxHistoryCount {
            temperatureHistory.removeFirst()
        }
    }
    
 /// ✅ 获取SystemPerformanceMonitor实例（如果可用）
    private func getSystemPerformanceMonitor() async -> SystemPerformanceMonitor? {
 // ✅ 尝试从PerformanceModeManager获取真实的性能监控器（在MainActor上执行）
        return await MainActor.run {
 // PerformanceModeManager.shared 是静态属性，不需要 try
            let manager = PerformanceModeManager.shared
            return manager.systemPerformanceMonitor
        }
    }
    
 /// 检测Apple Silicon芯片类型
    private static func detectAppleSiliconChipType() -> ChipType {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        
        var brandString = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brandString, &size, nil, 0)
        
 // 使用推荐的String初始化方法，明确指定类型并处理null终止符
        let cpuBrand: String = String(decoding: brandString.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        
        if cpuBrand.contains("M4") {
            return .m4
        } else if cpuBrand.contains("M3") {
            return .m3
        } else if cpuBrand.contains("M2") {
            return .m2
        } else if cpuBrand.contains("M1") {
            return .m1
        } else {
            return .appleSiliconUnknown
        }
    }
}

// MARK: - 支持类型定义

/// 芯片类型枚举 - 专注于Apple Silicon
public enum ChipType {
    case m1
    case m2
    case m3
    case m4  // 为未来的M4芯片预留
    case appleSiliconUnknown
    
    var description: String {
        switch self {
        case .m1:
            return "Apple M1"
        case .m2:
            return "Apple M2"
        case .m3:
            return "Apple M3"
        case .m4:
            return "Apple M4"
        case .appleSiliconUnknown:
            return "Apple Silicon (未知型号)"
        }
    }
    
 /// 获取芯片的GPU核心数 - 用于性能优化
    var gpuCoreCount: Int {
        switch self {
        case .m1:
            return 8  // M1 基础版
        case .m2:
            return 10 // M2 基础版
        case .m3:
            return 10 // M3 基础版
        case .m4:
            return 10 // M4 预估
        case .appleSiliconUnknown:
            return 8  // 保守估计
        }
    }
    
 /// 获取统一内存带宽 (GB/s) - 用于内存优化
    var memoryBandwidth: Double {
        switch self {
        case .m1:
            return 68.25
        case .m2:
            return 100.0
        case .m3:
            return 100.0
        case .m4:
            return 120.0  // 预估
        case .appleSiliconUnknown:
            return 68.25  // 保守估计
        }
    }
}


/// 温度趋势方向
public enum ThermalTrendDirection: String {
    case rising = "上升"
    case falling = "下降"
    case stable = "稳定"
}

/// 温度趋势
public struct TemperatureTrend {
    public let cpu: ThermalTrendDirection
    public let gpu: ThermalTrendDirection
}

/// 性能调整建议
public struct PerformanceAdjustment {
    public let renderScale: Float      // 渲染缩放比例
    public let frameRateLimit: Int?    // 帧率限制
    public let qualityReduction: Int   // 质量降低级别 (0-3)
}

/// Apple Silicon专用热管理配置
private struct AppleSiliconThermalConfig {
 /// 根据芯片类型获取最优监控间隔
    func getOptimalMonitoringInterval(for chipType: ChipType) -> TimeInterval {
        switch chipType {
        case .m1:
            return 12.0  // M1功耗较低，可以稍微放宽
        case .m2, .m3:
            return 10.0  // M2/M3平衡性能和功耗
        case .m4:
            return 8.0   // M4性能更强，需要更频繁监控
        case .appleSiliconUnknown:
            return 10.0  // 默认值
        }
    }
    
 /// Apple Silicon热阈值配置
    var thermalThresholds: (warning: Double, critical: Double) {
        return (warning: 80.0, critical: 95.0)
    }
}
#endif
