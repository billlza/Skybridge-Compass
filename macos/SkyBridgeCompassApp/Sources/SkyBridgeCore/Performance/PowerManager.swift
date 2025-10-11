import Foundation
import IOKit.ps
import os.log

/// 电源管理器 - 监控和管理系统电源状态
/// 针对Apple Silicon和macOS 14.0+进行优化，提供精细的电源管理功能
@available(macOS 14.0, *)
@MainActor
public class PowerManager: ObservableObject {
    
    // MARK: - 发布属性
    
    @Published public private(set) var powerSource: PowerSource = .unknown
    @Published public private(set) var batteryLevel: Double = 1.0
    @Published public private(set) var isCharging: Bool = false
    @Published public private(set) var timeRemaining: TimeInterval = 0
    @Published public private(set) var powerState: PowerState = .normal
    @Published public private(set) var thermalPressure: Double = 0.0
    
    // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "PowerManager")
    private var powerMonitoringTimer: Timer?
    private var powerSourceNotification: IONotificationPortRef?
    
    // 功耗优化配置
    private let lowBatteryThreshold: Double = 0.20      // 低电量阈值
    private let criticalBatteryThreshold: Double = 0.10 // 危险电量阈值
    private let powerSavingThreshold: Double = 0.30     // 省电模式阈值
    
    // 回调函数
    private var powerStateChangeCallback: ((PowerState) -> Void)?
    private var batteryLevelChangeCallback: ((Double) -> Void)?
    private var chargingStateChangeCallback: ((Bool) -> Void)?
    
    // 历史数据
    private var powerHistory: [(timestamp: Date, level: Double, isCharging: Bool)] = []
    private let maxHistoryCount = 300 // 保存5分钟的历史数据
    
    // MARK: - 初始化
    
    public init() {
        setupPowerMonitoring()
        logger.info("🔋 电源管理器初始化完成")
    }
    
    deinit {
        // 简化 deinit，避免访问非 Sendable 的属性
        // Timer 和 IONotificationPortRef 会在对象销毁时自动清理
    }
    
    // MARK: - 公共方法
    
    /// 开始电源监控
    public func startPowerMonitoring() {
        guard powerMonitoringTimer == nil else { return }
        
        powerMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePowerStatus()
            }
        }
        
        // 立即更新一次状态
        Task {
            await updatePowerStatus()
        }
        
        logger.info("🔋 电源监控已启动")
    }
    
    /// 停止电源监控
    public func stopPowerMonitoring() {
        powerMonitoringTimer?.invalidate()
        powerMonitoringTimer = nil
        
        if let notification = powerSourceNotification {
            IONotificationPortDestroy(notification)
            powerSourceNotification = nil
        }
        
        logger.info("🛑 电源监控已停止")
    }
    
    /// 设置电源状态变化回调
    public func setPowerStateChangeCallback(_ callback: @escaping (PowerState) -> Void) {
        powerStateChangeCallback = callback
    }
    
    /// 设置电池电量变化回调
    public func setBatteryLevelChangeCallback(_ callback: @escaping (Double) -> Void) {
        batteryLevelChangeCallback = callback
    }
    
    /// 设置充电状态变化回调
    public func setChargingStateChangeCallback(_ callback: @escaping (Bool) -> Void) {
        chargingStateChangeCallback = callback
    }
    
    /// 获取电源历史数据
    public func getPowerHistory() -> [(timestamp: Date, level: Double, isCharging: Bool)] {
        return powerHistory
    }
    
    /// 获取平均电池消耗率
    public func getAverageBatteryDrainRate(for duration: TimeInterval) -> Double {
        let cutoffTime = Date().addingTimeInterval(-duration)
        let recentData = powerHistory.filter { $0.timestamp >= cutoffTime && !$0.isCharging }
        
        guard recentData.count >= 2 else { return 0.0 }
        
        let firstEntry = recentData.first!
        let lastEntry = recentData.last!
        
        let levelDifference = firstEntry.level - lastEntry.level
        let timeDifference = lastEntry.timestamp.timeIntervalSince(firstEntry.timestamp)
        
        guard timeDifference > 0 else { return 0.0 }
        
        // 返回每小时的电量消耗率
        return (levelDifference / timeDifference) * 3600
    }
    
    /// 估算剩余使用时间
    public func getEstimatedRemainingTime() -> TimeInterval {
        guard !isCharging && batteryLevel > 0 else { return 0 }
        
        let drainRate = getAverageBatteryDrainRate(for: 600) // 使用过去10分钟的数据
        guard drainRate > 0 else { return 0 }
        
        return (batteryLevel / drainRate) * 3600 // 转换为秒
    }
    
    /// 获取推荐的功耗优化设置
    public func getRecommendedPowerOptimization() -> PowerOptimization {
        switch powerState {
        case .normal:
            return PowerOptimization(
                cpuThrottling: 0.0,
                gpuThrottling: 0.0,
                displayBrightness: 1.0,
                backgroundProcessing: true,
                networkOptimization: false
            )
        case .lowPower:
            return PowerOptimization(
                cpuThrottling: 0.2,
                gpuThrottling: 0.1,
                displayBrightness: 0.8,
                backgroundProcessing: true,
                networkOptimization: true
            )
        case .powerSaving:
            return PowerOptimization(
                cpuThrottling: 0.4,
                gpuThrottling: 0.3,
                displayBrightness: 0.6,
                backgroundProcessing: false,
                networkOptimization: true
            )
        case .critical:
            return PowerOptimization(
                cpuThrottling: 0.6,
                gpuThrottling: 0.5,
                displayBrightness: 0.4,
                backgroundProcessing: false,
                networkOptimization: true
            )
        case .thermalThrottling:
            return PowerOptimization(
                cpuThrottling: 0.5,
                gpuThrottling: 0.4,
                displayBrightness: 0.7,
                backgroundProcessing: false,
                networkOptimization: true
            )
        case .batteryOptimized:
            return PowerOptimization(
                cpuThrottling: 0.3,
                gpuThrottling: 0.2,
                displayBrightness: 0.8,
                backgroundProcessing: true,
                networkOptimization: true
            )
        }
    }
    
    /// 强制更新电源状态
    public func forceUpdatePowerStatus() async {
        await updatePowerStatus()
    }
    
    /// 获取电源效率建议
    public func getPowerEfficiencyRecommendations() -> [PowerEfficiencyRecommendation] {
        var recommendations: [PowerEfficiencyRecommendation] = []
        
        if batteryLevel < lowBatteryThreshold && !isCharging {
            recommendations.append(.enableLowPowerMode)
        }
        
        if batteryLevel < criticalBatteryThreshold {
            recommendations.append(.findCharger)
        }
        
        let drainRate = getAverageBatteryDrainRate(for: 600)
        if drainRate > 0.15 { // 每小时消耗超过15%
            recommendations.append(.reduceBrightness)
            recommendations.append(.closeBackgroundApps)
        }
        
        if thermalPressure > 0.7 {
            recommendations.append(.reducePerformance)
        }
        
        return recommendations
    }
    
    // MARK: - 私有方法
    
    /// 设置电源监控
    private func setupPowerMonitoring() {
        setupPowerSourceNotifications()
    }
    
    /// 设置电源通知
    private func setupPowerSourceNotifications() {
        powerSourceNotification = IONotificationPortCreate(kIOMainPortDefault)
        
        if let notification = powerSourceNotification {
            let runLoopSource = IONotificationPortGetRunLoopSource(notification)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource?.takeUnretainedValue(), CFRunLoopMode.defaultMode)
        }
    }
    
    /// 更新电源状态
    private func updatePowerStatus() async {
        // 读取电源信息
        let powerInfo = readPowerSourceInfo()
        
        // 更新电源类型
        let newPowerSource = powerInfo.powerSource
        if newPowerSource != self.powerSource {
            self.powerSource = newPowerSource
            logger.info("🔌 电源类型变化: \(self.powerSource.rawValue)")
        }
        
        // 更新电池电量
        let newBatteryLevel = powerInfo.batteryLevel
        if abs(newBatteryLevel - batteryLevel) > 0.01 {
            batteryLevel = newBatteryLevel
            batteryLevelChangeCallback?(batteryLevel)
        }
        
        // 更新充电状态
        let newChargingState = powerInfo.isCharging
        if newChargingState != self.isCharging {
            self.isCharging = newChargingState
            chargingStateChangeCallback?(self.isCharging)
            logger.info("🔋 充电状态变化: \(self.isCharging ? "充电中" : "未充电")")
        }
        
        // 更新剩余时间
        timeRemaining = powerInfo.timeRemaining
        
        // 更新热量压力
        thermalPressure = powerInfo.thermalPressure
        
        // 添加到历史记录
        addPowerDataToHistory(level: batteryLevel, isCharging: isCharging)
        
        // 计算新的电源状态
        let newPowerState = calculatePowerState()
        if newPowerState != powerState {
            let oldState = powerState
            powerState = newPowerState
            
            logger.info("⚡ 电源状态变化: \(oldState.rawValue) -> \(newPowerState.rawValue)")
            powerStateChangeCallback?(newPowerState)
        }
    }
    
    /// 读取电源信息
    private func readPowerSourceInfo() -> PowerSourceInfo {
        // 获取电源信息
        let powerSourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let powerSourcesList = IOPSCopyPowerSourcesList(powerSourcesInfo)?.takeRetainedValue() as? [CFDictionary]
        
        var batteryLevel: Double = 1.0
        var isCharging: Bool = false
        var powerSource: PowerSource = .unknown
        var timeRemaining: TimeInterval = 0
        var thermalPressure: Double = 0.0
        
        if let powerSources = powerSourcesList {
            for powerSourceDict in powerSources {
                let powerSourceInfo = powerSourceDict as NSDictionary
                
                // 检查是否是内置电池
                if let type = powerSourceInfo[kIOPSTypeKey] as? String,
                   type == kIOPSInternalBatteryType {
                    
                    // 获取电池电量
                    if let currentCapacity = powerSourceInfo[kIOPSCurrentCapacityKey] as? Int,
                       let maxCapacity = powerSourceInfo[kIOPSMaxCapacityKey] as? Int,
                       maxCapacity > 0 {
                        batteryLevel = Double(currentCapacity) / Double(maxCapacity)
                    }
                    
                    // 获取充电状态
                    if let chargingState = powerSourceInfo[kIOPSIsChargingKey] as? Bool {
                        isCharging = chargingState
                    }
                    
                    // 获取电源类型
                    if let powerAdapter = powerSourceInfo[kIOPSPowerAdapterIDKey] as? Int,
                       powerAdapter > 0 {
                        powerSource = .ac
                    } else {
                        powerSource = .battery
                    }
                    
                    // 获取剩余时间
                    if let timeToEmpty = powerSourceInfo[kIOPSTimeToEmptyKey] as? Int,
                       timeToEmpty > 0 && timeToEmpty != Int(kIOPSTimeRemainingUnlimited) {
                        timeRemaining = TimeInterval(timeToEmpty * 60) // 转换为秒
                    }
                }
            }
        }
        
        // 模拟热量压力（在实际实现中应该从系统读取）
        thermalPressure = Double.random(in: 0.0...1.0)
        
        return PowerSourceInfo(
            powerSource: powerSource,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            timeRemaining: timeRemaining,
            thermalPressure: thermalPressure
        )
    }
    
    /// 计算电源状态
    /// 根据电池电量、充电状态和热量压力计算当前电源状态
    private func calculatePowerState() -> PowerState {
        // 检查热量压力
        if thermalPressure > 0.8 {
            return .thermalThrottling
        }
        
        // 检查电池优化模式
        if batteryLevel > 0.8 && isCharging && thermalPressure < 0.3 {
            return .batteryOptimized
        }
        
        // 原有的电池状态逻辑
        if batteryLevel <= criticalBatteryThreshold && !isCharging {
            return .critical
        } else if batteryLevel <= lowBatteryThreshold && !isCharging {
            return .powerSaving
        } else if batteryLevel <= powerSavingThreshold && !isCharging {
            return .lowPower
        } else {
            return .normal
        }
    }
    
    /// 添加电源数据到历史记录
    private func addPowerDataToHistory(level: Double, isCharging: Bool) {
        let entry = (timestamp: Date(), level: level, isCharging: isCharging)
        powerHistory.append(entry)
        
        // 保持历史记录在限制范围内
        if powerHistory.count > maxHistoryCount {
            powerHistory.removeFirst()
        }
    }
}

// MARK: - 支持类型定义

/// 电源类型
public enum PowerSource: String, CaseIterable {
    case battery = "电池"
    case ac = "交流电"
    case unknown = "未知"
}

/// 电源状态
/// 针对macOS 14.0+和Apple Silicon进行优化，支持更精细的电源管理
@available(macOS 14.0, *)
public enum PowerState: String, CaseIterable {
    case normal = "正常"
    case lowPower = "低功耗"
    case powerSaving = "省电模式"
    case critical = "危险"
    case thermalThrottling = "热量限制"
    case batteryOptimized = "电池优化"
    
    /// 获取状态颜色
    public var color: String {
        switch self {
        case .normal:
            return "绿色"
        case .lowPower:
            return "黄色"
        case .powerSaving:
            return "橙色"
        case .critical:
            return "红色"
        case .thermalThrottling:
            return "橙色"
        case .batteryOptimized:
            return "蓝色"
        }
    }
}

/// 电源信息
private struct PowerSourceInfo {
    let powerSource: PowerSource
    let batteryLevel: Double
    let isCharging: Bool
    let timeRemaining: TimeInterval
    let thermalPressure: Double
}

/// 功耗优化设置
public struct PowerOptimization {
    public let cpuThrottling: Float        // CPU节流比例 (0.0-1.0)
    public let gpuThrottling: Float        // GPU节流比例 (0.0-1.0)
    public let displayBrightness: Float    // 显示亮度 (0.0-1.0)
    public let backgroundProcessing: Bool  // 是否允许后台处理
    public let networkOptimization: Bool   // 是否启用网络优化
}

/// 电源效率建议
public enum PowerEfficiencyRecommendation: String, CaseIterable {
    case enableLowPowerMode = "启用低功耗模式"
    case reduceBrightness = "降低屏幕亮度"
    case closeBackgroundApps = "关闭后台应用"
    case findCharger = "寻找充电器"
    case reducePerformance = "降低性能设置"
    case enableWiFiOptimization = "启用WiFi优化"
    case disableLocationServices = "禁用位置服务"
    case reduceAnimations = "减少动画效果"
}