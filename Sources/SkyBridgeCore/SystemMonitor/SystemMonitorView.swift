import SwiftUI
import Combine
import os.log

/// ✅ 系统监控视图 - 使用SystemPerformanceMonitor真实性能数据
/// 应用启动后自动开始监控（等待CPU负载平稳）
@available(macOS 14.0, *)
public struct SystemMonitorView: View {
    
 // MARK: - 状态管理
    
 /// ✅ 使用SystemPerformanceMonitor获取真实性能数据
    @State private var systemPerformanceMonitor: SystemPerformanceMonitor?
    @State private var performanceModeManager: PerformanceModeManager?
    
    @State private var isMonitoring = false
    @State private var systemLoad: Double = 0.0
    @State private var overallHealth: String = "正常"
    @State private var thermalStatus: String = "正常"
    @State private var helperInstalled: Bool = false
    @State private var pollingStarted: Bool = false
    
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "SystemMonitorView")
    
 // MARK: - 初始化器
    
 /// 公共初始化器，允许外部模块创建实例
    public init() {}
    
 // MARK: - 辅助方法
    
 /// 获取热状态描述
    private func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return LocalizationManager.shared.localizedString("thermal.nominal")
        case .fair:
            return LocalizationManager.shared.localizedString("thermal.fair")
        case .serious:
            return LocalizationManager.shared.localizedString("thermal.serious")
        case .critical:
            return LocalizationManager.shared.localizedString("thermal.critical")
        @unknown default:
            return LocalizationManager.shared.localizedString("common.unknown")
        }
    }
    
 // MARK: - 监控控制视图主体
    
    public var body: some View {
        VStack(spacing: 20) {
 // 标题和状态
            HStack {
                Text(LocalizationManager.shared.localizedString("monitor.title"))
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
 // ✅ 显示监控状态（自动启动，无需手动按钮）
                HStack(spacing: 8) {
                    Circle()
                        .fill(isMonitoring ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(isMonitoring ? LocalizationManager.shared.localizedString("monitor.status.monitoring") : LocalizationManager.shared.localizedString("monitor.status.initializing"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
 // 可选：提供手动停止按钮（如果需要）
                if isMonitoring {
                    Button(action: stopMonitoring) {
                    HStack {
                            Image(systemName: "stop.circle.fill")
                            Text(LocalizationManager.shared.localizedString("monitor.action.stop"))
                    }
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
            
 // 高级监控提示（XPC Helper 未连接时显示）
            advancedMonitoringNotice
            
 // ✅ 自动开始监控（无需手动点击）
            if systemPerformanceMonitor != nil && isMonitoring {
 // 系统概览卡片
                systemOverviewCard
                
 // 详细监控数据
                detailMonitoringCards
                
 // 系统状态指示器
                systemStatusIndicators
            } else {
 // 等待监控启动
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .padding()
                    
                    Text(LocalizationManager.shared.localizedString("monitor.waiting.cpuStable"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text(LocalizationManager.shared.localizedString("monitor.waiting.tip"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .task {
            await initializeAndStartMonitoring()
            helperInstalled = HelperInstaller.isHelperInstalled()
        }
        .task {
            if pollingStarted { return }
            pollingStarted = true
            for await _ in Timer.publish(every: 1.0, on: .main, in: .common).autoconnect().values {
                if let monitor = systemPerformanceMonitor, monitor.isMonitoring {
                    if !isMonitoring {
                        isMonitoring = true
                        logger.info("✅ 系统监控已自动启动")
                    }
                    updateSystemData()
                } else if isMonitoring && systemPerformanceMonitor?.isMonitoring == false {
                    isMonitoring = false
                }
            }
        }
        .onDisappear {
            stopMonitoring()
        }
    }
    
 // MARK: - 子视图组件
    
 // 高级监控提示
    @ViewBuilder
    private var advancedMonitoringNotice: some View {
 // 根据是否已安装 Helper 显示提示，避免在视图构建期间做 XPC 调用
            if !helperInstalled {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundColor(.orange)
                    Text(LocalizationManager.shared.localizedString("monitor.helper.suggest"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(LocalizationManager.shared.localizedString("monitor.helper.enable")) { enableAdvancedMonitoring() }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.ultraThinMaterial)
                )
            } else {
 // 提供卸载入口
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "externaldrive.fill.trianglebadge.exclamationmark")
                        .foregroundColor(.red)
                    Text(LocalizationManager.shared.localizedString("monitor.helper.uninstall.tip"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(LocalizationManager.shared.localizedString("monitor.helper.uninstall")) { uninstallAdvancedMonitoring() }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.ultraThinMaterial)
                )
            }
    }
    
 /// 系统概览卡片
    private var systemOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LocalizationManager.shared.localizedString("monitor.overview"))
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Text(overallHealth)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(healthColor.opacity(0.2))
                    .foregroundColor(healthColor)
                    .cornerRadius(8)
            }
            
            HStack(spacing: 20) {
 // ✅ 使用SystemPerformanceMonitor的真实数据
                if let monitor = systemPerformanceMonitor {
 // CPU使用率
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", monitor.cpuUsage))%")
                        .font(.title3)
                        .fontWeight(.medium)
                }
                
 // 内存使用率
                VStack(alignment: .leading, spacing: 4) {
                    Text("内存")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", monitor.memoryUsage))%")
                        .font(.title3)
                        .fontWeight(.medium)
                }
                
 // GPU使用率
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPU")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", monitor.gpuUsage))%")
                        .font(.title3)
                        .fontWeight(.medium)
                }
                
 // 系统负载（归一化为百分比）
                VStack(alignment: .leading, spacing: 4) {
                    Text("系统负载")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        let cpuCount = Double(ProcessInfo.processInfo.activeProcessorCount)
                        let normalized = (monitor.loadAverage1Min / max(cpuCount, 1.0)) * 100.0
                        Text("\(String(format: "%.1f", min(max(normalized, 0.0), 100.0)))%")
                        .font(.title3)
                        .fontWeight(.medium)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
    
 /// 详细监控卡片
    private var detailMonitoringCards: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
 // CPU详细信息
            cpuDetailCard
            
 // 内存详细信息
            memoryDetailCard
            
 // GPU详细信息
            gpuDetailCard
            
 // 温度和风扇信息
            thermalDetailCard
        }
    }
    
 /// CPU详细卡片
    private var cpuDetailCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizationManager.shared.localizedString("monitor.cpu.details"))
                .font(.headline)
                .fontWeight(.semibold)
            
 // ✅ 使用SystemPerformanceMonitor的真实CPU数据
            if let monitor = systemPerformanceMonitor {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("总使用率:")
                    Spacer()
                        Text("\(String(format: "%.1f", monitor.cpuUsage))%")
                }
                
                HStack {
                        Text("温度:")
                    Spacer()
                        Text("\(String(format: "%.1f", monitor.cpuTemperature))°C")
                }
                
 // 系统负载平均值
                HStack {
                        Text("负载 (1分钟):")
                    Spacer()
                        Text("\(String(format: "%.2f", monitor.loadAverage1Min))")
                }
                
                HStack {
                        Text("负载 (5分钟):")
                    Spacer()
                        Text("\(String(format: "%.2f", monitor.loadAverage5Min))")
                    }
                }
                .font(.caption)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
    
 /// 内存详情卡片
    private var memoryDetailCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizationManager.shared.localizedString("monitor.memory.details"))
                .font(.headline)
                .fontWeight(.semibold)
            
 // ✅ 使用SystemPerformanceMonitor的真实内存数据
            if let monitor = systemPerformanceMonitor {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                        Text("使用率:")
                    Spacer()
                        Text("\(String(format: "%.1f", monitor.memoryUsage))%")
                }
                
                HStack {
                        Text("负载 (15分钟):")
                    Spacer()
                        Text("\(String(format: "%.2f", monitor.loadAverage15Min))")
                }
                
                HStack {
                    Text("热状态:")
                    Spacer()
                        Text(thermalStatus)
                    }
                }
                .font(.caption)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
    
 /// GPU详细卡片
    private var gpuDetailCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizationManager.shared.localizedString("monitor.gpu.details"))
                .font(.headline)
                .fontWeight(.semibold)
            
 // ✅ 使用SystemPerformanceMonitor的真实GPU数据
            if let monitor = systemPerformanceMonitor {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("使用率:")
                    Spacer()
                        Text("\(String(format: "%.1f", monitor.gpuUsage))%")
                }
                
                HStack {
                    Text("温度:")
                    Spacer()
                        Text("\(String(format: "%.1f", monitor.gpuTemperature))°C")
                }
                
 // GPU功耗通过温度估算（如果需要更精确需要其他API）
                    let estimatedPower = max(5.0, (monitor.gpuTemperature - 40.0) * 0.2)
                HStack {
                        Text("功耗 (估算):")
                    Spacer()
                        Text("\(String(format: "%.1f", estimatedPower))W")
                    }
                }
                .font(.caption)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
    
 /// 散热详情卡片
    private var thermalDetailCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizationManager.shared.localizedString("monitor.thermal.details"))
                .font(.headline)
                .fontWeight(.semibold)
            
 // ✅ 使用SystemPerformanceMonitor的真实风扇和温度数据
            if let monitor = systemPerformanceMonitor {
            VStack(alignment: .leading, spacing: 4) {
 // 风扇转速
                    if !monitor.fanSpeed.isEmpty {
                        HStack {
                            Text("风扇转速:")
                            Spacer()
                            Text("\(monitor.fanSpeed.first ?? 0) RPM")
                        }
                    } else {
                HStack {
                    Text("风扇转速:")
                    Spacer()
                            Text("未检测到")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack {
                        Text("CPU温度:")
                        Spacer()
                        Text("\(String(format: "%.1f", monitor.cpuTemperature))°C")
                }
                
                HStack {
                        Text("GPU温度:")
                    Spacer()
                        Text("\(String(format: "%.1f", monitor.gpuTemperature))°C")
                }
                
                HStack {
                    Text("热状态:")
                    Spacer()
                    Text(thermalStatus)
                }
                }
                .font(.caption)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
    
 /// 系统状态指示器
    private var systemStatusIndicators: some View {
        HStack(spacing: 16) {
 // 整体健康状态
            VStack(spacing: 4) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 12, height: 12)
                Text(LocalizationManager.shared.localizedString("monitor.indicator.health"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(overallHealth)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            
 // 热状态
            VStack(spacing: 4) {
                Circle()
                    .fill(thermalColor)
                    .frame(width: 12, height: 12)
                Text(LocalizationManager.shared.localizedString("monitor.indicator.thermal"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(thermalStatus)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            
 // 系统负载
            VStack(spacing: 4) {
                Circle()
                    .fill(loadColor)
                    .frame(width: 12, height: 12)
                Text(LocalizationManager.shared.localizedString("monitor.indicator.load"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(String(format: "%.0f", systemLoad))%")
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
    
 // MARK: - 颜色计算
    
 /// 健康状态颜色
    private var healthColor: Color {
        switch overallHealth {
        case LocalizationManager.shared.localizedString("health.excellent"):
            return .green
        case LocalizationManager.shared.localizedString("health.good"):
            return .blue
        case LocalizationManager.shared.localizedString("health.fair"):
            return .yellow
        case LocalizationManager.shared.localizedString("health.caution"):
            return .orange
        default:
            return .red
        }
    }
    
 /// 热状态颜色
    private var thermalColor: Color {
        switch thermalStatus {
        case LocalizationManager.shared.localizedString("thermal.low"), LocalizationManager.shared.localizedString("thermal.nominal"):
            return .green
        case LocalizationManager.shared.localizedString("thermal.fair"):
            return .orange
        case LocalizationManager.shared.localizedString("thermal.serious"):
            return .red
        default:
            return .pink
        }
    }
    
 /// 负载颜色
    private var loadColor: Color {
        switch systemLoad {
        case 0..<30:
            return .green
        case 30..<60:
            return .yellow
        case 60..<80:
            return .orange
        default:
            return .red
        }
    }
    
 // MARK: - 方法
    
 /// ✅ 初始化并自动启动监控（应用启动后等待CPU负载平稳）
    private func initializeAndStartMonitoring() async {
        logger.info("🔧 初始化SystemPerformanceMonitor...")
        
 // 获取PerformanceModeManager实例（PerformanceModeManager.shared 是静态属性，非可选类型）
        let manager = PerformanceModeManager.shared
        performanceModeManager = manager
        
 // 获取SystemPerformanceMonitor实例
        var monitor = manager.systemPerformanceMonitor
        
 // 如果monitor还未初始化（可能需要先启用自适应模式），等待一下
        if monitor == nil {
            logger.info("⏳ SystemPerformanceMonitor尚未初始化，等待...")
 // 等待2秒后重试（给PerformanceModeManager时间初始化）
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
 // 重新获取
            monitor = manager.systemPerformanceMonitor
            
            if monitor == nil {
                logger.warning("⚠️ SystemPerformanceMonitor获取失败，创建独立实例")
                let newMonitor = SystemPerformanceMonitor()
                systemPerformanceMonitor = newMonitor
                newMonitor.startMonitoring(afterDelay: 10.0)
                observeMonitoringStatus()
                return
            }
        }
        
        systemPerformanceMonitor = monitor
        
 // ✅ 自动启动监控（延迟启动，等待CPU负载平稳）
        monitor?.startMonitoring(afterDelay: 10.0)
        
 // 监听监控状态变化
        observeMonitoringStatus()
        
        logger.info("✅ SystemPerformanceMonitor初始化完成，将在10秒后自动启动")
    }
    
 /// 监听监控状态
    private func observeMonitoringStatus() {}
    
 /// 启用高级监控（使用现代 SMAppService API 安装 Helper）
    private func enableAdvancedMonitoring() {
        #if canImport(AppKit)
            let ok = HelperInstaller.installHelper()
            let alert = NSAlert()
            if ok {
                alert.messageText = "已提交安装请求"
                alert.informativeText = "Helper 已注册。如果状态为 '需要批准'，系统会打开设置页面供您批准。"
                alert.alertStyle = .informational
            } else {
                alert.messageText = "安装失败"
                let errorMsg = HelperInstaller.getLastError() ?? "未知错误"
                alert.informativeText = "错误: \(errorMsg)\n\n请检查:\n1. Helper 是否已正确打包到 App bundle\n2. launchd plist 文件是否存在\n3. 签名是否正确\n\n查看 Console.app 获取详细日志。"
                alert.alertStyle = .critical
            }
            alert.addButton(withTitle: "好")
            alert.runModal()
        #endif
    }

 /// 卸载高级监控（移除 Helper）
    private func uninstallAdvancedMonitoring() {
        #if canImport(AppKit)
            let ok = HelperInstaller.uninstallHelper()
        let alert = NSAlert()
            alert.messageText = ok ? "已卸载 Helper" : "卸载失败"
            alert.informativeText = ok ? "提权 Helper 已从系统移除。" : "请确认 Helper 正在运行且权限允许移除。"
            alert.alertStyle = ok ? .informational : .warning
            alert.addButton(withTitle: "好")
        alert.runModal()
        #endif
    }
    
 /// 更新系统数据（从SystemPerformanceMonitor）
    private func updateSystemData() {
        guard let monitor = systemPerformanceMonitor else { return }
        
 // 更新系统负载（将 load average 归一化为百分比：负载/逻辑CPU数*100）
        let cpuCount = Double(ProcessInfo.processInfo.activeProcessorCount)
        let normalized = (monitor.loadAverage1Min / max(cpuCount, 1.0)) * 100.0
        systemLoad = min(max(normalized, 0.0), 100.0)
        
 // 更新热状态
        updateThermalStatus(monitor: monitor)
        
 // 更新整体健康状态
        updateOverallHealth(monitor: monitor)
    }
    
 /// 停止监控
    private func stopMonitoring() {
        guard isMonitoring else { return }
        
        isMonitoring = false
        systemPerformanceMonitor?.stopMonitoring()
        
        logger.info("⏹️ 系统监控已停止")
    }
    
 /// 更新热状态
    private func updateThermalStatus(monitor: SystemPerformanceMonitor) {
        let maxTemp = max(monitor.cpuTemperature, monitor.gpuTemperature)
        
        switch maxTemp {
        case 0..<45:
            thermalStatus = LocalizationManager.shared.localizedString("thermal.low")
        case 45..<65:
            thermalStatus = LocalizationManager.shared.localizedString("thermal.nominal")
        case 65..<80:
            thermalStatus = LocalizationManager.shared.localizedString("thermal.fair")
        case 80..<90:
            thermalStatus = LocalizationManager.shared.localizedString("thermal.serious")
        default:
            thermalStatus = LocalizationManager.shared.localizedString("thermal.critical")
        }
    }
    
 /// 更新整体健康状态
    private func updateOverallHealth(monitor: SystemPerformanceMonitor) {
        var healthScore = 100.0
        
 // 根据CPU使用率扣分
        if monitor.cpuUsage > 80 {
            healthScore -= 30
        } else if monitor.cpuUsage > 60 {
            healthScore -= 15
        } else if monitor.cpuUsage > 40 {
            healthScore -= 5
        }
        
 // 根据内存使用率扣分
        if monitor.memoryUsage > 85 {
            healthScore -= 20
        } else if monitor.memoryUsage > 70 {
            healthScore -= 10
        }
        
 // 根据GPU使用率扣分
        if monitor.gpuUsage > 90 {
            healthScore -= 15
        }
        
 // 根据热状态扣分
        switch thermalStatus {
        case "过热":
            healthScore -= 25
        case "偏热":
            healthScore -= 10
        case "危险":
            healthScore -= 50
        default:
            break
        }
        
 // 确定健康状态
        switch healthScore {
        case 90...100:
            overallHealth = LocalizationManager.shared.localizedString("health.excellent")
        case 75..<90:
            overallHealth = LocalizationManager.shared.localizedString("health.good")
        case 60..<75:
            overallHealth = LocalizationManager.shared.localizedString("health.fair")
        case 40..<60:
            overallHealth = LocalizationManager.shared.localizedString("health.caution")
        default:
            overallHealth = LocalizationManager.shared.localizedString("health.warning")
        }
    }
}

// MARK: - 时间范围枚举

enum TimeRange: String, CaseIterable {
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case sixHours = "6h"
    case oneDay = "24h"
    
    var displayName: String {
        switch self {
        case .fifteenMinutes: return "15分钟"
        case .oneHour: return "1小时"
        case .sixHours: return "6小时"
        case .oneDay: return "24小时"
        }
    }
    
    var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .sixHours: return 6 * 60 * 60
        case .oneDay: return 24 * 60 * 60
        }
    }
}

// MARK: - 图表数据点结构（已移除，使用PerformanceChartCard中的定义）

// MARK: - 预览

struct SystemMonitorView_Previews: PreviewProvider {
    static var previews: some View {
        SystemMonitorView()
            .frame(width: 800, height: 600)
    }
}
