import SwiftUI
import SkyBridgeCore

/// 系统指标面板
@available(macOS 14.0, *)
public struct SystemMetricsPanelView: View {
    @EnvironmentObject var appModel: DashboardViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    
    public init() {}
    
    public var body: some View {
        themedCard(title: LocalizationManager.shared.localizedString("dashboard.systemMetrics"), iconName: "chart.line.uptrend.xyaxis") {
            VStack(spacing: 16) {
 // CPU使用率图表
                MetricChartView(
                    title: LocalizationManager.shared.localizedString("metrics.cpuUsage"),
                    value: appModel.systemMetricsService.cpuUsage,
                    color: .orange,
                    timeline: appModel.systemMetricsService.cpuTimeline
                )
                
                Divider()
                    .background(themeConfiguration.borderColor)
                
 // 内存使用率图表
                MetricChartView(
                    title: LocalizationManager.shared.localizedString("metrics.memoryUsage"), 
                    value: appModel.systemMetricsService.memoryUsage,
                    color: .blue,
                    timeline: appModel.systemMetricsService.memoryTimeline
                )
                
                Divider()
                    .background(themeConfiguration.borderColor)
                
 // 网络速率图表（入/出，真实数据）
 // 动态单位显示：当速率低于 1000 kbps 使用 kbps，否则使用 Mbps
 // 下行速率（选择单位并换算）
                MetricChartView(
                    title: LocalizationManager.shared.localizedString("metrics.downloadRate"),
                    value: {
                        let bitsPerSecond = appModel.systemMetricsService.networkRate.inBps * 8.0
                        let kbps = bitsPerSecond / 1000.0
                        if kbps < 1000.0 {
                            return kbps
                        } else {
                            return kbps / 1000.0 // 即 Mbps
                        }
                    }(),
                    color: .green,
                    timeline: {
                        let bitsPerSecond = appModel.systemMetricsService.networkRate.inBps * 8.0
                        let kbpsCurrent = bitsPerSecond / 1000.0
                        let useKbps = kbpsCurrent < 1000.0
                        return appModel.systemMetricsService.networkInTimeline.mapValues { valueBps in
                            let valueBits = valueBps * 8.0
                            let valueKbps = valueBits / 1000.0
                            return useKbps ? valueKbps : (valueKbps / 1000.0)
                        }
                    }(),
                    unit: {
                        let bitsPerSecond = appModel.systemMetricsService.networkRate.inBps * 8.0
                        let kbps = bitsPerSecond / 1000.0
                        return kbps < 1000.0 ? "kbps" : "Mbps"
                    }()
                )
                
                Divider()
                    .background(themeConfiguration.borderColor)
                
 // 上行速率（选择单位并换算）
                MetricChartView(
                    title: LocalizationManager.shared.localizedString("metrics.uploadRate"),
                    value: {
                        let bitsPerSecond = appModel.systemMetricsService.networkRate.outBps * 8.0
                        let kbps = bitsPerSecond / 1000.0
                        if kbps < 1000.0 {
                            return kbps
                        } else {
                            return kbps / 1000.0 // 即 Mbps
                        }
                    }(),
                    color: .mint,
                    timeline: {
                        let bitsPerSecond = appModel.systemMetricsService.networkRate.outBps * 8.0
                        let kbpsCurrent = bitsPerSecond / 1000.0
                        let useKbps = kbpsCurrent < 1000.0
                        return appModel.systemMetricsService.networkOutTimeline.mapValues { valueBps in
                            let valueBits = valueBps * 8.0
                            let valueKbps = valueBits / 1000.0
                            return useKbps ? valueKbps : (valueKbps / 1000.0)
                        }
                    }(),
                    unit: {
                        let bitsPerSecond = appModel.systemMetricsService.networkRate.outBps * 8.0
                        let kbps = bitsPerSecond / 1000.0
                        return kbps < 1000.0 ? "kbps" : "Mbps"
                    }()
                )
            }
        }
        .frame(minHeight: 320)
    }
    
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

