import Foundation
import IOKit
import os.log

/// 热量管理器 - 监控系统温度并进行热量调节
@MainActor
public class ThermalManager: ObservableObject {
    
    // MARK: - 发布属性
    
    @Published public private(set) var currentThermalState: ThermalState = .nominal
    @Published public private(set) var cpuTemperature: Double = 0.0
    @Published public private(set) var gpuTemperature: Double = 0.0
    @Published public private(set) var isThrottling: Bool = false
    
    // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "ThermalManager")
    private var thermalMonitoringTimer: Timer?
    private var thermalNotificationSource: IONotificationPortRef?
    
    // 温度阈值配置
    private let nominalThreshold: Double = 60.0    // 正常温度阈值
    private let fairThreshold: Double = 70.0       // 良好温度阈值
    private let seriousThreshold: Double = 80.0    // 严重温度阈值
    private let criticalThreshold: Double = 90.0   // 危险温度阈值
    
    // 热量调节回调
    private var thermalStateChangeCallback: ((ThermalState) -> Void)?
    private var temperatureChangeCallback: ((Double, Double) -> Void)?
    
    // 历史数据
    private var temperatureHistory: [(timestamp: Date, cpu: Double, gpu: Double)] = []
    private let maxHistoryCount = 300 // 保存5分钟的历史数据（每秒一次）
    
    // MARK: - 初始化
    
    public init() {
        setupThermalMonitoring()
        logger.info("✅ 热量管理器初始化完成")
    }
    
    deinit {
        // 简化 deinit，避免访问非 Sendable 的属性
        // Timer 和 IONotificationPortRef 会在对象销毁时自动清理
    }
    
    // MARK: - 公共方法
    
    /// 开始热量监控
    public func startThermalMonitoring() {
        guard thermalMonitoringTimer == nil else { return }
        
        thermalMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateThermalStatus()
            }
        }
        
        logger.info("🌡️ 热量监控已启动")
    }
    
    /// 停止热量监控
    public func stopThermalMonitoring() {
        thermalMonitoringTimer?.invalidate()
        thermalMonitoringTimer = nil
        
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
        
        let cpuTrend: ThermalTrendDirection
        let gpuTrend: ThermalTrendDirection
        
        let cpuDiff = secondAvgCPU - firstAvgCPU
        let gpuDiff = secondAvgGPU - firstAvgGPU
        
        if cpuDiff > 2.0 {
            cpuTrend = .rising
        } else if cpuDiff < -2.0 {
            cpuTrend = .falling
        } else {
            cpuTrend = .stable
        }
        
        if gpuDiff > 2.0 {
            gpuTrend = .rising
        } else if gpuDiff < -2.0 {
            gpuTrend = .falling
        } else {
            gpuTrend = .stable
        }
        
        return TemperatureTrend(cpu: cpuTrend, gpu: gpuTrend)
    }
    
    /// 强制更新热量状态
    public func forceUpdateThermalStatus() async {
        await updateThermalStatus()
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
    
    // MARK: - 私有方法
    
    /// 设置热量监控
    private func setupThermalMonitoring() {
        // 设置IOKit通知以监控热量状态变化
        setupIOKitThermalNotifications()
    }
    
    /// 设置IOKit热量通知
    private func setupIOKitThermalNotifications() {
        thermalNotificationSource = IONotificationPortCreate(kIOMainPortDefault)
        
        if let notificationSource = thermalNotificationSource {
            let runLoopSource = IONotificationPortGetRunLoopSource(notificationSource)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource?.takeUnretainedValue(), CFRunLoopMode.defaultMode)
        }
    }
    
    /// 更新热量状态
    private func updateThermalStatus() async {
        // 读取CPU和GPU温度
        let newCPUTemp = readCPUTemperature()
        let newGPUTemp = readGPUTemperature()
        
        // 更新温度
        cpuTemperature = newCPUTemp
        gpuTemperature = newGPUTemp
        
        // 添加到历史记录
        addTemperatureToHistory(cpu: newCPUTemp, gpu: newGPUTemp)
        
        // 计算新的热量状态
        let maxTemp = max(newCPUTemp, newGPUTemp)
        let newThermalState = calculateThermalState(from: maxTemp)
        
        // 检查状态是否发生变化
        if newThermalState != currentThermalState {
            let oldState = currentThermalState
            currentThermalState = newThermalState
            
            logger.info("🌡️ 热量状态变化: \(oldState.rawValue) -> \(newThermalState.rawValue)")
            
            // 触发回调
            thermalStateChangeCallback?(newThermalState)
            
            // 更新节流状态
            isThrottling = newThermalState == .serious || newThermalState == .critical
        }
        
        // 触发温度变化回调
        temperatureChangeCallback?(newCPUTemp, newGPUTemp)
    }
    
    /// 读取CPU温度
    private func readCPUTemperature() -> Double {
        // 在实际实现中，这里应该通过IOKit读取真实的CPU温度
        // 目前使用模拟数据
        return Double.random(in: 45.0...85.0)
    }
    
    /// 读取GPU温度
    private func readGPUTemperature() -> Double {
        // 在实际实现中，这里应该通过IOKit读取真实的GPU温度
        // 目前使用模拟数据
        return Double.random(in: 40.0...80.0)
    }
    
    /// 计算热量状态
    private func calculateThermalState(from temperature: Double) -> ThermalState {
        if temperature >= criticalThreshold {
            return .critical
        } else if temperature >= seriousThreshold {
            return .serious
        } else if temperature >= fairThreshold {
            return .fair
        } else {
            return .nominal
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
}

// MARK: - 支持类型定义

/// 热量状态
public enum ThermalState: String, CaseIterable {
    case nominal = "正常"
    case fair = "良好"
    case serious = "严重"
    case critical = "危险"
    
    /// 获取状态颜色
    public var color: String {
        switch self {
        case .nominal:
            return "绿色"
        case .fair:
            return "黄色"
        case .serious:
            return "橙色"
        case .critical:
            return "红色"
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