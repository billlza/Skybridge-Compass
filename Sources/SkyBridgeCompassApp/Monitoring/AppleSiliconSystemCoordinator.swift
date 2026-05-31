import Foundation
import SwiftUI
import Combine
import SkyBridgeCore

/// Apple Silicon系统监控协调器
/// 实现分离的时序策略：CPU、内存、风扇每3秒更新，温度每2秒更新
@MainActor
class AppleSiliconSystemCoordinator: ObservableObject {
 // MARK: - 发布属性
    @Published var isMonitoring = false
    @Published var systemOverview = SystemOverview()
    @Published var performanceRecommendations: [String] = []
    @Published var lastUpdateTime = Date()
    
 // MARK: - 监控组件
    private let systemMonitor = AppleSiliconSystemMonitor()
    private let gpuMonitor = AppleSiliconGPUMonitor()
    private let fanMonitor = AppleSiliconFanMonitor()
    
 // MARK: - 定时器
    private var primaryTimer: Timer? // 3秒间隔：CPU、内存、风扇
    private var temperatureTimer: Timer? // 2秒间隔：温度
    private var loadCalculationTimer: Timer? // 5秒间隔：系统负载计算
    
 // MARK: - 数据订阅
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupDataBindings()
    }
    
    deinit {
 // 在deinit中不能使用async方法，改为同步停止
 // 依赖系统自动清理Timer资源
    }
    
 // MARK: - 公共方法
    func startMonitoring() async {
        guard !isMonitoring else { return }
        
        SkyBridgeLogger.performance.debugOnly("🚀 启动Apple Silicon系统监控协调器")
        isMonitoring = true
        
 // 启动子监控器
        systemMonitor.startMonitoring()
        gpuMonitor.startMonitoring()
        fanMonitor.startMonitoring()
        
 // 设置定时器
        setupTimers()
        
        SkyBridgeLogger.performance.debugOnly("✅ Apple Silicon系统监控协调器启动完成")
    }
    
    func stopMonitoring() async {
        guard isMonitoring else { return }
        
        SkyBridgeLogger.performance.debugOnly("🛑 停止Apple Silicon系统监控协调器")
        isMonitoring = false
        
 // 停止定时器
        primaryTimer?.invalidate()
        temperatureTimer?.invalidate()
        loadCalculationTimer?.invalidate()
        
        primaryTimer = nil
        temperatureTimer = nil
        loadCalculationTimer = nil
        
 // 停止子监控器
        systemMonitor.stopMonitoring()
        gpuMonitor.stopMonitoring()
        fanMonitor.stopMonitoring()
        
        SkyBridgeLogger.performance.debugOnly("✅ Apple Silicon系统监控协调器停止完成")
    }
    
 // MARK: - 私有方法
    private func setupTimers() {
 // 主要数据定时器：每3秒更新CPU、内存、风扇
        primaryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePrimaryData()
            }
        }
        
 // 温度定时器：每2秒更新温度数据
        temperatureTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateTemperatureData()
            }
        }
        
 // 系统负载计算定时器：每5秒计算一次
        loadCalculationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.calculateSystemLoad()
            }
        }
        
 // 立即执行一次更新
        updatePrimaryData()
        updateTemperatureData()
        calculateSystemLoad()
    }
    
    private func updatePrimaryData() {
        systemMonitor.refreshNow()
        gpuMonitor.refreshNow()
        fanMonitor.refreshNow()

        lastUpdateTime = Date()
        SkyBridgeLogger.performance.debugOnly("📊 主要数据更新完成 - CPU: \(systemMonitor.cpuUsage)% 内存压力: \(systemMonitor.memoryPressure)%")
    }
    
    private func updateTemperatureData() {
        systemMonitor.refreshNow()
        gpuMonitor.refreshNow()
        SkyBridgeLogger.performance.debugOnly("🌡️ 温度数据更新完成 - CPU: \(systemMonitor.cpuTemperature)°C GPU: \(gpuMonitor.gpuTemperature)°C")
    }
    
    private func calculateSystemLoad() {
 // 计算系统负载
        let cpuLoad = systemMonitor.cpuUsage
        let memoryLoad = systemMonitor.memoryPressure
        let gpuLoad = gpuMonitor.gpuUsage
        
 // 更新系统概览
        systemOverview = SystemOverview(
            cpuUsage: cpuLoad,
            memoryUsage: memoryLoad,
            gpuUsage: gpuLoad,
            cpuTemperature: systemMonitor.cpuTemperature,
            gpuTemperature: gpuMonitor.gpuTemperature,
            fanSpeed: fanMonitor.fanSpeed,
            powerConsumption: systemMonitor.systemPower + gpuMonitor.gpuPower
        )
        
 // 生成性能建议
        generatePerformanceRecommendations()
        
        SkyBridgeLogger.performance.debugOnly("⚡ 系统负载计算完成 - 总体负载: \((cpuLoad + memoryLoad + gpuLoad) / 3)%")
    }
    
    private func generatePerformanceRecommendations() {
        var recommendations: [String] = []
        
        if systemOverview.cpuUsage > 80 {
            recommendations.append("CPU使用率过高，建议关闭不必要的应用程序")
        }
        
        if systemOverview.memoryUsage > 85 {
            recommendations.append("内存使用率过高，建议释放内存或增加虚拟内存")
        }
        
        if systemOverview.cpuTemperature > 80 {
            recommendations.append("CPU温度过高，建议检查散热系统")
        }
        
        if systemOverview.gpuTemperature > 75 {
            recommendations.append("GPU温度过高，建议降低图形负载")
        }
        
        if systemOverview.fanSpeed > 4000 {
            recommendations.append("风扇转速过高，系统可能过热")
        }
        
        if recommendations.isEmpty {
            recommendations.append("系统运行状态良好")
        }
        
        performanceRecommendations = recommendations
    }
    
    private func setupDataBindings() {
 // 监听系统监控器数据变化
        systemMonitor.$cpuUsage
            .combineLatest(systemMonitor.$memoryPressure)
            .debounce(for: RunLoop.SchedulerTimeType.Stride.milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] (cpuUsage: Double, memoryPressure: Double) in
                Task { @MainActor in
                    self?.calculateSystemLoad()
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - 系统概览数据结构
struct SystemOverview {
    var cpuUsage: Double = 0.0
    var memoryUsage: Double = 0.0
    var gpuUsage: Double = 0.0
    var cpuTemperature: Double = 0.0
    var gpuTemperature: Double = 0.0
    var fanSpeed: Double = 0.0
    var powerConsumption: Double = 0.0
    
    var overallHealth: SystemHealth {
        let maxTemp = max(cpuTemperature, gpuTemperature)
        let maxUsage = max(cpuUsage, memoryUsage, gpuUsage)
        
        if maxTemp > 85 || maxUsage > 90 {
            return .critical
        } else if maxTemp > 75 || maxUsage > 80 {
            return .warning
        } else {
            return .good
        }
    }
}

enum SystemHealth {
    case good
    case warning
    case critical
    
    var color: Color {
        switch self {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
    
    var description: String {
        switch self {
        case .good: return "系统状态良好"
        case .warning: return "系统负载较高"
        case .critical: return "系统负载过高"
        }
    }
}
