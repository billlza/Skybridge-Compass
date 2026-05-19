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
                        temperature: metricValueText(
                            value: monitor.cpuTemperature,
                            state: monitor.cpuTemperatureState,
                            format: "%.1f°C"
                        ),
                        color: .orange
                    )
                    
                    Divider()
                        .background(themeConfiguration.borderColor)
                    
 // GPU温度和使用率
                    PerformanceMetricRow(
                        title: LocalizationManager.shared.localizedString("monitor.gpu"),
                        value: metricValueText(
                            value: monitor.gpuUsage,
                            state: monitor.gpuUsageState,
                            format: "%.1f%%"
                        ),
                        temperature: metricValueText(
                            value: monitor.gpuTemperature,
                            state: monitor.gpuTemperatureState,
                            format: "%.1f°C"
                        ),
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
                    
                    Divider()
                        .background(themeConfiguration.borderColor)

 // 风扇转速
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizationManager.shared.localizedString("monitor.fanSpeed"))
                                .font(.caption)
                                .foregroundColor(themeConfiguration.secondaryTextColor)
                            Text(fanSpeedText(for: monitor))
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(monitor.fanState.availability == .available ? .cyan : themeConfiguration.secondaryTextColor)
                        }

                        Spacer()

                        Image(systemName: "fanblades.fill")
                            .font(.title2)
                            .foregroundColor(monitor.fanState.availability == .available ? .cyan : themeConfiguration.secondaryTextColor)
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
 // 监控后端未运行时明确显示不可用，避免用默认 normal 状态伪装成健康数据。
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizationManager.shared.localizedString("monitor.thermalState"))
                                .font(.caption)
                                .foregroundColor(themeConfiguration.secondaryTextColor)
                            Text(LocalizationManager.shared.localizedString("monitor.metric.availability.unavailable"))
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(themeConfiguration.secondaryTextColor)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "thermometer")
                            .font(.title2)
                            .foregroundColor(themeConfiguration.secondaryTextColor)
                    }
                    
                    Divider()
                        .background(themeConfiguration.borderColor)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizationManager.shared.localizedString("monitor.powerState"))
                                .font(.caption)
                                .foregroundColor(themeConfiguration.secondaryTextColor)
                            Text(LocalizationManager.shared.localizedString("monitor.metric.availability.unavailable"))
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(themeConfiguration.secondaryTextColor)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "bolt.slash")
                            .font(.title2)
                            .foregroundColor(themeConfiguration.secondaryTextColor)
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
    
 // MARK: - 指标可用性显示

    private func metricValueText(value: Double, state: MetricState, format: String) -> String {
        switch state.availability {
        case .available:
            return String(format: format, value)
        case .stale:
            return String(
                format: "%@ (%@)",
                String(format: format, value),
                LocalizationManager.shared.localizedString("monitor.metric.availability.stale")
            )
        case .unavailable:
            return metricUnavailableText(state)
        }
    }

    private func fanSpeedText(for monitor: SystemPerformanceMonitor) -> String {
        switch monitor.fanState.availability {
        case .available:
            guard !monitor.fanSpeed.isEmpty else {
                return metricUnavailableText(
                    .unavailable(reason: .notProvidedByOS, source: monitor.fanState.source, sampledAt: monitor.fanState.sampledAt)
                )
            }
            return monitor.fanSpeed.map { "\($0) RPM" }.joined(separator: ", ")
        case .stale:
            let value = monitor.fanSpeed.isEmpty
                ? LocalizationManager.shared.localizedString("monitor.metric.availability.unavailable")
                : monitor.fanSpeed.map { "\($0) RPM" }.joined(separator: ", ")
            return String(
                format: "%@ (%@)",
                value,
                LocalizationManager.shared.localizedString("monitor.metric.availability.stale")
            )
        case .unavailable:
            return metricUnavailableText(monitor.fanState)
        }
    }

    private func metricUnavailableText(_ state: MetricState) -> String {
        let reason = metricReasonText(state.reason)
        return String(
            format: LocalizationManager.shared.localizedString("monitor.metric.unavailableWithReason"),
            reason
        )
    }

    private func metricReasonText(_ reason: MetricUnavailableReason?) -> String {
        switch reason {
        case .unsupported:
            return LocalizationManager.shared.localizedString("monitor.metric.reason.unsupported")
        case .permissionDenied:
            return LocalizationManager.shared.localizedString("monitor.metric.reason.permissionDenied")
        case .notProvidedByOS:
            return LocalizationManager.shared.localizedString("monitor.metric.reason.notProvidedByOS")
        case .helperUnavailable:
            return LocalizationManager.shared.localizedString("monitor.metric.reason.helperUnavailable")
        case .helperOutdated:
            return LocalizationManager.shared.localizedString("monitor.metric.reason.helperOutdated")
        case .parsingFailed:
            return LocalizationManager.shared.localizedString("monitor.metric.reason.parsingFailed")
        case .sampling:
            return LocalizationManager.shared.localizedString("monitor.metric.reason.sampling")
        case .requiresExpertMode:
            return LocalizationManager.shared.localizedString("monitor.metric.reason.requiresExpertMode")
        case .temporarilyInitializing:
            return LocalizationManager.shared.localizedString("monitor.metric.reason.temporarilyInitializing")
        case .none:
            return LocalizationManager.shared.localizedString("monitor.metric.reason.notProvidedByOS")
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
