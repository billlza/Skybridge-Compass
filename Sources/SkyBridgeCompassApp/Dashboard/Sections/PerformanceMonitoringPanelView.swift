import SwiftUI
import SkyBridgeCore

/// 性能监控面板（使用真实性能监控数据）
@available(macOS 14.0, *)
public struct PerformanceMonitoringPanelView: View {
    @EnvironmentObject var appModel: DashboardViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    
    @Binding var systemPerformanceMonitor: SystemPerformanceMonitor?
    
    public init(systemPerformanceMonitor: Binding<SystemPerformanceMonitor?>) {
        self._systemPerformanceMonitor = systemPerformanceMonitor
    }
    
    public var body: some View {
        themedCard(title: LocalizationManager.shared.localizedString("dashboard.performanceMonitor"), iconName: "speedometer") {
            VStack(spacing: 16) {
 // ✅ 优先显示真实性能数据
                if let monitor = systemPerformanceMonitor, monitor.isMonitoring {
 // CPU温度和使用率
                    PerformanceMetricRow(
                        title: LocalizationManager.shared.localizedString("monitor.cpu"),
                        value: String(format: "%.1f%%", monitor.cpuUsage),
                        temperature: String(format: "%.1f°C", monitor.cpuTemperature),
                        color: .orange
                    )
                    
                    Divider()
                        .background(themeConfiguration.borderColor)
                    
 // GPU温度和使用率
                    PerformanceMetricRow(
                        title: LocalizationManager.shared.localizedString("monitor.gpu"),
                        value: String(format: "%.1f%%", monitor.gpuUsage),
                        temperature: String(format: "%.1f°C", monitor.gpuTemperature),
                        color: .purple
                    )
                    
                    Divider()
                        .background(themeConfiguration.borderColor)
                    
 // 内存使用率
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizationManager.shared.localizedString("monitor.memoryUsage"))
                                .font(.caption)
                                .foregroundColor(themeConfiguration.secondaryTextColor)
                            Text(String(format: "%.1f%%", monitor.memoryUsage))
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.blue)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "memorychip.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                    
                    if !monitor.fanSpeed.isEmpty {
                        Divider()
                            .background(themeConfiguration.borderColor)
                        
 // 风扇转速
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizationManager.shared.localizedString("monitor.fanSpeed"))
                                    .font(.caption)
                                    .foregroundColor(themeConfiguration.secondaryTextColor)
                                Text(monitor.fanSpeed.map { "\($0) RPM" }.joined(separator: ", "))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.cyan)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "fanblades.fill")
                                .font(.title2)
                                .foregroundColor(.cyan)
                        }
                    }
                    
                    Divider()
                        .background(themeConfiguration.borderColor)
                    
 // 系统负载平均值
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizationManager.shared.localizedString("monitor.systemLoad"))
                                .font(.caption)
                                .foregroundColor(themeConfiguration.secondaryTextColor)
                            Text(String(format: "%.2f / %.2f / %.2f",
                                      monitor.loadAverage1Min,
                                      monitor.loadAverage5Min,
                                      monitor.loadAverage15Min))
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.green)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.title2)
                            .foregroundColor(.green)
                    }
                } else {
 // 回退到原有显示（当SystemPerformanceMonitor不可用时）
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizationManager.shared.localizedString("monitor.thermalState"))
                                .font(.caption)
                                .foregroundColor(themeConfiguration.secondaryTextColor)
                            Text(thermalStateDescription)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(thermalStateColor)
                        }
                        
                        Spacer()
                        
                        Image(systemName: thermalStateIcon)
                            .font(.title2)
                            .foregroundColor(thermalStateColor)
                    }
                    
                    Divider()
                        .background(themeConfiguration.borderColor)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizationManager.shared.localizedString("monitor.powerState"))
                                .font(.caption)
                                .foregroundColor(themeConfiguration.secondaryTextColor)
                            Text(powerStateDescription)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(powerStateColor)
                        }
                        
                        Spacer()
                        
                        Image(systemName: powerStateIcon)
                            .font(.title2)
                            .foregroundColor(powerStateColor)
                    }
                }
                
                Divider()
                    .background(themeConfiguration.borderColor)
                
 // 性能建议
                if !appModel.performanceRecommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizationManager.shared.localizedString("monitor.recommendations"))
                            .font(.caption)
                            .foregroundColor(themeConfiguration.secondaryTextColor)
                        
                        ForEach(Array(appModel.performanceRecommendations.prefix(3)), id: \.self) { recommendation in
                            HStack(spacing: 8) {
                                Image(systemName: "lightbulb.fill")
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                                
                                Text(recommendation.rawValue)
                                    .font(.caption)
                                    .foregroundColor(themeConfiguration.primaryTextColor)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 200)
    }
    
 // MARK: - 热量和电源状态计算属性
    
    private var thermalStateDescription: String {
        switch appModel.thermalState {
        case .nominal: return LocalizationManager.shared.localizedString("state.normal")
        case .fair: return LocalizationManager.shared.localizedString("state.fair")
        case .serious: return LocalizationManager.shared.localizedString("state.serious")
        case .critical: return LocalizationManager.shared.localizedString("state.critical")
        @unknown default: return LocalizationManager.shared.localizedString("state.unknown")
        }
    }
    
    private var thermalStateColor: Color {
        switch appModel.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
    
    private var thermalStateIcon: String {
        switch appModel.thermalState {
        case .nominal: return "thermometer.low"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "thermometer.high.fill"
        @unknown default: return "thermometer"
        }
    }
    
    private var powerStateDescription: String {
        switch appModel.powerState {
        case .normal: return LocalizationManager.shared.localizedString("state.normal")
        case .lowPower: return LocalizationManager.shared.localizedString("state.lowPower")
        case .powerSaving: return LocalizationManager.shared.localizedString("state.powerSaving")
        case .critical: return LocalizationManager.shared.localizedString("state.critical")
        case .thermalThrottling: return LocalizationManager.shared.localizedString("state.thermalThrottling")
        case .batteryOptimized: return LocalizationManager.shared.localizedString("state.batteryOptimized")
        @unknown default: return LocalizationManager.shared.localizedString("state.unknown")
        }
    }
    
    private var powerStateColor: Color {
        switch appModel.powerState {
        case .normal: return .green
        case .lowPower: return .blue
        case .powerSaving: return .yellow
        case .critical: return .red
        case .thermalThrottling: return .orange
        case .batteryOptimized: return .blue
        @unknown default: return .gray
        }
    }
    
    private var powerStateIcon: String {
        switch appModel.powerState {
        case .normal: return "bolt.fill"
        case .lowPower: return "battery.25"
        case .powerSaving: return "battery.0"
        case .critical: return "battery.0.fill"
        case .thermalThrottling: return "slowmo"
        case .batteryOptimized: return "leaf.fill"
        @unknown default: return "questionmark"
        }
    }
    
 // MARK: - Helper
    
    private func themedCard<Content: View>(title: String, iconName: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: HorizontalAlignment.leading, spacing: 16) {
            HStack {
                Label(title, systemImage: iconName)
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()
            }
            content()
        }
        .padding(20)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
}

