import SwiftUI
import Combine
import os.log
import Charts

/// ✅ 系统监控视图 - 使用SystemPerformanceMonitor真实性能数据
/// 应用启动后自动开始监控（等待CPU负载平稳）
@available(macOS 14.0, *)
public struct SystemMonitorView: View {
    
 // MARK: - 状态管理
    
    /// ✅ 使用SystemPerformanceMonitor获取真实性能数据
    @State private var systemPerformanceMonitor: SystemPerformanceMonitor?
    @State private var performanceModeManager: PerformanceModeManager?
    @StateObject private var settingsManager = SettingsManager.shared
    
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
    
    private var showDiagnostics: Bool {
        if settingsManager.showDebugInfo {
            return true
        }
        #if DEBUG
        return true
        #else
        let env = ProcessInfo.processInfo.environment["SKYBRIDGE_MONITOR_DIAGNOSTICS"] ?? ""
        return env == "1" || env.lowercased() == "true" || env.lowercased() == "yes"
        #endif
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

    private func metricSourceText(_ source: MetricSource?) -> String {
        switch source {
        case .kernelAPI:
            return LocalizationManager.shared.localizedString("monitor.metric.source.kernelAPI")
        case .ioAccelerator:
            return LocalizationManager.shared.localizedString("monitor.metric.source.ioAccelerator")
        case .smc:
            return LocalizationManager.shared.localizedString("monitor.metric.source.smc")
        case .iohid:
            return LocalizationManager.shared.localizedString("monitor.metric.source.iohid")
        case .ioreport:
            return LocalizationManager.shared.localizedString("monitor.metric.source.ioreport")
        case .powermetrics:
            return LocalizationManager.shared.localizedString("monitor.metric.source.powermetrics")
        case .processInfoThermalState:
            return LocalizationManager.shared.localizedString("monitor.metric.source.processInfoThermalState")
        case .none:
            return LocalizationManager.shared.localizedString("common.unknown")
        }
    }

    private var modeSelection: Binding<MonitoringMode> {
        Binding(
            get: { systemPerformanceMonitor?.monitoringMode ?? .standardPublic },
            set: { mode in
                systemPerformanceMonitor?.setMonitoringMode(mode)
            }
        )
    }

    private func modeLabel(_ mode: MonitoringMode) -> String {
        switch mode {
        case .standardPublic:
            return LocalizationManager.shared.localizedString("monitor.mode.standard")
        case .expertPrivate:
            return LocalizationManager.shared.localizedString("monitor.mode.expert")
        }
    }

    private func unavailableText(for state: MetricState) -> String {
        let reason = metricReasonText(state.reason)
        let template = LocalizationManager.shared.localizedString("monitor.metric.unavailableWithReason")
        return String(format: template, reason)
    }

    private func formatNumericMetric(_ valueText: String?, state: MetricState) -> String {
        switch state.availability {
        case .available:
            return valueText ?? unavailableText(for: state)
        case .stale:
            if let valueText {
                return "\(valueText) \(LocalizationManager.shared.localizedString("monitor.metric.staleSuffix"))"
            }
            return LocalizationManager.shared.localizedString("monitor.metric.stale")
        case .unavailable:
            return unavailableText(for: state)
        }
    }

    private func formatTemperature(_ value: Double, state: MetricState) -> String {
        let valueText = value > 0 ? "\(String(format: "%.1f", value))°C" : nil
        return formatNumericMetric(valueText, state: state)
    }

    private func formatPower(_ value: Double, state: MetricState) -> String {
        let valueText = value > 0 ? "\(String(format: "%.1f", value))W" : nil
        return formatNumericMetric(valueText, state: state)
    }

    @ViewBuilder
    private func powerBreakdownRows(for monitor: SystemPerformanceMonitor) -> some View {
        let readings = orderedPowerReadings(monitor.powerReadings)
        if readings.isEmpty {
            HStack {
                Text("GPU功耗:")
                Spacer()
                Text(formatPower(monitor.gpuPower, state: monitor.gpuPowerState))
            }
        } else {
            ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                HStack {
                    Text("\(powerComponentLabel(reading.component))功耗:")
                    Spacer()
                    Text(formatPowerReading(reading, monitor: monitor))
                }
            }
        }
    }

    private func orderedPowerReadings(_ readings: [PowerMetricsPowerReading]) -> [PowerMetricsPowerReading] {
        let preferredOrder: [PowerMetricsPowerComponent] = [.cpu, .gpu, .ane, .ram, .package]
        return preferredOrder.compactMap { component in
            readings.first { $0.component == component }
        }
    }

    private func powerComponentLabel(_ component: PowerMetricsPowerComponent) -> String {
        switch component {
        case .cpu:
            return "CPU"
        case .gpu:
            return "GPU"
        case .ane:
            return "ANE"
        case .ram:
            return "RAM"
        case .package:
            return "Package"
        case .unknown:
            return "Unknown"
        }
    }

    private func formatPowerReading(_ reading: PowerMetricsPowerReading, monitor: SystemPerformanceMonitor) -> String {
        let valueText = "\(String(format: "%.1f", reading.watts))W"
        guard monitor.gpuPowerState.availability == .stale else { return valueText }
        return "\(valueText) \(LocalizationManager.shared.localizedString("monitor.metric.staleSuffix"))"
    }

    private func formatPercent(_ value: Double, state: MetricState) -> String {
        let valueText = value >= 0 ? "\(String(format: "%.1f", value))%" : nil
        return formatNumericMetric(valueText, state: state)
    }

    private func formatFanRPM(_ fans: [Int], state: MetricState) -> String {
        let valueText = fans.isEmpty ? nil : "\(fans.first ?? 0) RPM"
        return formatNumericMetric(valueText, state: state)
    }

    private func compactMetricText(_ valueText: String?, state: MetricState) -> String {
        switch state.availability {
        case .available:
            return valueText ?? LocalizationManager.shared.localizedString("monitor.metric.availability.unavailable")
        case .stale:
            if let valueText {
                return "\(valueText) \(LocalizationManager.shared.localizedString("monitor.metric.staleSuffix"))"
            }
            return LocalizationManager.shared.localizedString("monitor.metric.availability.stale")
        case .unavailable:
            return LocalizationManager.shared.localizedString("monitor.metric.availability.unavailable")
        }
    }

    private func formatPercentCompact(_ value: Double, state: MetricState) -> String {
        compactMetricText("\(String(format: "%.1f", value))%", state: state)
    }

    private func metricDiagnosticText(_ state: MetricState) -> String {
        let availability = LocalizationManager.shared.localizedString("monitor.metric.availability.\(state.availability.rawValue)")
        let source = metricSourceText(state.source)
        let reason = metricReasonText(state.reason)
        let age = metricAgeText(sampledAt: state.sampledAt)
        if state.availability == .unavailable {
            return "\(availability) · \(source) · \(reason) · \(age)"
        }
        return "\(availability) · \(source) · \(age)"
    }

    private func metricAgeText(sampledAt: Date?) -> String {
        guard let sampledAt else { return LocalizationManager.shared.localizedString("common.unknown") }
        let age = max(0, Int(Date().timeIntervalSince(sampledAt)))
        let template = LocalizationManager.shared.localizedString("monitor.metric.age.seconds")
        return String(format: template, age)
    }
    
 // MARK: - 监控控制视图主体
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            liveSnapshotPanel
                .padding()
        }
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

    private var liveSnapshotPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            liveSnapshotHeader
            advancedMonitoringNotice
            monitoringModeCard

            if let monitor = systemPerformanceMonitor, isMonitoring {
                if hasEnabledMonitorDisplayMetric {
                    liveSnapshotMetrics(for: monitor)
                    liveSnapshotHighlights(for: monitor)

                    if settingsManager.showTrendIndicators {
                        liveSnapshotTrend(for: monitor)
                    }

                    liveSnapshotStatusStrip
                } else {
                    monitorDisplayDisabledStateCard
                }

                if showDiagnostics {
                    liveSnapshotDiagnostics(for: monitor)
                }
            } else {
                liveSnapshotWaitingState
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var liveSnapshotHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Live Snapshot")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Unified monitor view for current health, load, network and thermal headroom.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Label(
                    isMonitoring
                        ? LocalizationManager.shared.localizedString("monitor.status.monitoring")
                        : LocalizationManager.shared.localizedString("monitor.status.initializing"),
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((isMonitoring ? Color.green : Color.gray).opacity(0.16), in: Capsule())
                .foregroundColor(isMonitoring ? .green : .secondary)

                if isMonitoring {
                    Button(action: stopMonitoring) {
                        Label(LocalizationManager.shared.localizedString("monitor.action.stop"), systemImage: "stop.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func liveSnapshotMetrics(for monitor: SystemPerformanceMonitor) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: 12
        ) {
            liveSnapshotMetricCard(
                title: "CPU",
                value: String(format: "%.1f%%", monitor.cpuUsage),
                subtitle: "System load",
                color: loadColor,
                icon: "cpu"
            )
            liveSnapshotMetricCard(
                title: "Memory",
                value: String(format: "%.1f%%", monitor.memoryUsage),
                subtitle: "Pressure",
                color: .blue,
                icon: "memorychip"
            )
            liveSnapshotMetricCard(
                title: "Bandwidth",
                value: String(format: "%.2f Mbps", monitor.networkThroughputMbps),
                subtitle: "Live traffic",
                color: .green,
                icon: "network"
            )
            liveSnapshotMetricCard(
                title: "Thermal",
                value: formatTemperature(max(monitor.cpuTemperature, monitor.gpuTemperature), state: preferredTemperatureState(for: monitor)),
                subtitle: thermalStatus,
                color: thermalColor,
                icon: "thermometer"
            )
        }
    }

    private func liveSnapshotHighlights(for monitor: SystemPerformanceMonitor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            liveSnapshotInsightRow(
                title: "Overall Health",
                detail: overallHealth,
                caption: "Aggregates CPU, memory, disk and thermal headroom.",
                color: healthColor
            )
            liveSnapshotInsightRow(
                title: "Thermal Envelope",
                detail: thermalStatus,
                caption: "CPU \(formatTemperature(monitor.cpuTemperature, state: monitor.cpuTemperatureState)) • GPU \(formatTemperature(monitor.gpuTemperature, state: monitor.gpuTemperatureState))",
                color: thermalColor
            )
            liveSnapshotInsightRow(
                title: "Cooling + Transport",
                detail: "Fan \(formatFanRPM(monitor.fanSpeed, state: monitor.fanState))",
                caption: "Network throughput \(String(format: "%.2f", monitor.networkThroughputMbps)) Mbps",
                color: .cyan
            )
        }
    }

    private func liveSnapshotTrend(for monitor: SystemPerformanceMonitor) -> some View {
        let points = Array(monitor.historyPoints.suffix(20))

        return VStack(alignment: .leading, spacing: 12) {
            Text("Trend")
                .font(.headline)
            if points.isEmpty {
                Text(LocalizationManager.shared.localizedString("monitor.noData"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("CPU", point.cpuUsage)
                        )
                        .foregroundStyle(.orange)

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Memory", point.memoryUsage)
                        )
                        .foregroundStyle(.blue)
                    }
                }
                .chartLegend(.visible)
                .frame(height: 180)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.08))
        )
    }

    private var liveSnapshotStatusStrip: some View {
        HStack(spacing: 12) {
            liveSnapshotStatusPill(
                title: LocalizationManager.shared.localizedString("monitor.indicator.health"),
                value: overallHealth,
                color: healthColor
            )
            liveSnapshotStatusPill(
                title: LocalizationManager.shared.localizedString("monitor.indicator.thermal"),
                value: thermalStatus,
                color: thermalColor
            )
            liveSnapshotStatusPill(
                title: LocalizationManager.shared.localizedString("monitor.indicator.load"),
                value: "\(String(format: "%.0f", systemLoad))%",
                color: loadColor
            )
        }
    }

    private func liveSnapshotDiagnostics(for monitor: SystemPerformanceMonitor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizationManager.shared.localizedString("monitor.diagnostics.title"))
                .font(.headline)
            diagnosticRow(title: "GPU Usage", detail: metricDiagnosticText(monitor.gpuUsageState))
            diagnosticRow(title: "GPU Power", detail: metricDiagnosticText(monitor.gpuPowerState))
            diagnosticRow(title: "CPU Temp", detail: metricDiagnosticText(monitor.cpuTemperatureState))
            diagnosticRow(title: "GPU Temp", detail: metricDiagnosticText(monitor.gpuTemperatureState))
            diagnosticRow(title: "Fan", detail: metricDiagnosticText(monitor.fanState))
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.08))
        )
    }

    private var liveSnapshotWaitingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .padding(.top, 8)

            Text(LocalizationManager.shared.localizedString("monitor.waiting.cpuStable"))
                .font(.headline)

            Text(LocalizationManager.shared.localizedString("monitor.waiting.tip"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func liveSnapshotMetricCard(title: String, value: String, subtitle: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(color.opacity(0.10))
        )
    }

    private func liveSnapshotInsightRow(title: String, detail: String, caption: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(detail)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(color)
                }
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.06))
        )
    }

    private func liveSnapshotStatusPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(color.opacity(0.10))
        )
    }

    private func diagnosticRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func preferredTemperatureState(for monitor: SystemPerformanceMonitor) -> MetricState {
        if monitor.cpuTemperatureState.availability != .unavailable {
            return monitor.cpuTemperatureState
        }
        return monitor.gpuTemperatureState
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

    @ViewBuilder
    private var monitoringModeCard: some View {
        HStack(spacing: 12) {
            Text(LocalizationManager.shared.localizedString("monitor.mode.title"))
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: modeSelection) {
                Text(modeLabel(.standardPublic)).tag(MonitoringMode.standardPublic)
                Text(modeLabel(.expertPrivate)).tag(MonitoringMode.expertPrivate)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
    }

    private var hasEnabledMonitorDisplayMetric: Bool {
        settingsManager.showMonitorCPU ||
        settingsManager.showMonitorMemory ||
        settingsManager.showMonitorDisk ||
        settingsManager.showMonitorNetwork ||
        settingsManager.showMonitorTemperature ||
        settingsManager.showMonitorFanSpeed
    }

    private var monitorDisplayDisabledStateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizationManager.shared.localizedString("settings.systemMonitor.display.noneEnabled"))
                .font(.headline)
            Text(LocalizationManager.shared.localizedString("settings.systemMonitor.display.noneEnabled.detail"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
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
                    if settingsManager.showMonitorCPU {
 // CPU使用率
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CPU")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(String(format: "%.1f", monitor.cpuUsage))%")
                                .font(.title3)
                                .fontWeight(.medium)
                        }
                    }

                    if settingsManager.showMonitorMemory {
// 内存使用率
                        VStack(alignment: .leading, spacing: 4) {
                            Text("内存")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(String(format: "%.1f", monitor.memoryUsage))%")
                                .font(.title3)
                                .fontWeight(.medium)
                        }
                    }

                    if settingsManager.showMonitorDisk {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("磁盘")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(String(format: "%.1f", monitor.diskUsage))%")
                                .font(.title3)
                                .fontWeight(.medium)
                        }
                    }

                    if settingsManager.showMonitorNetwork {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("网络")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(String(format: "%.2f", monitor.networkThroughputMbps)) Mbps")
                                .font(.title3)
                                .fontWeight(.medium)
                        }
                    }

                    if settingsManager.showMonitorTemperature || settingsManager.showMonitorFanSpeed {
// GPU使用率
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GPU")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(formatPercentCompact(monitor.gpuUsage, state: monitor.gpuUsageState))
                                .font(.title3)
                                .fontWeight(.medium)
                        }
                    }

                    if settingsManager.showMonitorCPU {
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
            if settingsManager.showMonitorCPU {
 // CPU详细信息
                cpuDetailCard
            }

            if settingsManager.showMonitorMemory {
// 内存详细信息
                memoryDetailCard
            }

            if settingsManager.showMonitorDisk {
                diskDetailCard
            }

            if settingsManager.showMonitorNetwork {
                networkDetailCard
            }

            if settingsManager.showMonitorTemperature || settingsManager.showMonitorFanSpeed {
// GPU详细信息
                gpuDetailCard

 // 温度和风扇信息
                thermalDetailCard
            }
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
                        Text(formatTemperature(monitor.cpuTemperature, state: monitor.cpuTemperatureState))
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

    private var diskDetailCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("磁盘详情")
                .font(.headline)
                .fontWeight(.semibold)

            if let monitor = systemPerformanceMonitor {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("使用率:")
                        Spacer()
                        Text("\(String(format: "%.1f", monitor.diskUsage))%")
                    }
                    HStack {
                        Text("告警阈值:")
                        Spacer()
                        Text("\(Int(settingsManager.diskThreshold))%")
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

    private var networkDetailCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("网络详情")
                .font(.headline)
                .fontWeight(.semibold)

            if let monitor = systemPerformanceMonitor {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("吞吐:")
                        Spacer()
                        Text("\(String(format: "%.2f", monitor.networkThroughputMbps)) Mbps")
                    }
                    HStack {
                        Text("刷新:")
                        Spacer()
                        Text("\(String(format: "%.1f", settingsManager.systemMonitorRefreshInterval))s")
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
                        Text(formatPercent(monitor.gpuUsage, state: monitor.gpuUsageState))
                }
                
                HStack {
                    Text("温度:")
                    Spacer()
                        Text(formatTemperature(monitor.gpuTemperature, state: monitor.gpuTemperatureState))
                }
                
                    powerBreakdownRows(for: monitor)
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
                    if settingsManager.showMonitorFanSpeed {
                        HStack {
                            Text("风扇转速:")
                            Spacer()
                            Text(formatFanRPM(monitor.fanSpeed, state: monitor.fanState))
                        }
                    }

                    if settingsManager.showMonitorTemperature {
                        HStack {
                            Text("CPU温度:")
                            Spacer()
                            Text(formatTemperature(monitor.cpuTemperature, state: monitor.cpuTemperatureState))
                        }

                        HStack {
                            Text("GPU温度:")
                            Spacer()
                            Text(formatTemperature(monitor.gpuTemperature, state: monitor.gpuTemperatureState))
                        }
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

    @ViewBuilder
    private var systemTrendChartCard: some View {
        if let monitor = systemPerformanceMonitor, !monitor.historyPoints.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizationManager.shared.localizedString("settings.systemMonitor.display.chartType"))
                    .font(.headline)
                    .fontWeight(.semibold)

                switch settingsManager.systemMonitorChartType {
                case .line:
                    Chart(monitor.historyPoints.suffix(120)) { point in
                        if settingsManager.showMonitorCPU {
                            LineMark(x: .value("Time", point.timestamp), y: .value("CPU", point.cpuUsage))
                                .foregroundStyle(.red)
                        }
                        if settingsManager.showMonitorMemory {
                            LineMark(x: .value("Time", point.timestamp), y: .value("Memory", point.memoryUsage))
                                .foregroundStyle(.blue)
                        }
                        if settingsManager.showMonitorDisk {
                            LineMark(x: .value("Time", point.timestamp), y: .value("Disk", point.diskUsage))
                                .foregroundStyle(.orange)
                        }
                        if settingsManager.showMonitorNetwork {
                            LineMark(x: .value("Time", point.timestamp), y: .value("Network", point.networkThroughputMbps))
                                .foregroundStyle(.green)
                        }
                    }
                case .bar:
                    Chart(monitor.historyPoints.suffix(60)) { point in
                        if settingsManager.showMonitorCPU {
                            BarMark(x: .value("Time", point.timestamp), y: .value("CPU", point.cpuUsage))
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        if settingsManager.showMonitorMemory {
                            BarMark(x: .value("Time", point.timestamp), y: .value("Memory", point.memoryUsage))
                                .foregroundStyle(.blue.opacity(0.7))
                        }
                        if settingsManager.showMonitorDisk {
                            BarMark(x: .value("Time", point.timestamp), y: .value("Disk", point.diskUsage))
                                .foregroundStyle(.orange.opacity(0.7))
                        }
                        if settingsManager.showMonitorNetwork {
                            BarMark(x: .value("Time", point.timestamp), y: .value("Network", point.networkThroughputMbps))
                                .foregroundStyle(.green.opacity(0.7))
                        }
                    }
                case .area:
                    Chart(monitor.historyPoints.suffix(120)) { point in
                        if settingsManager.showMonitorCPU {
                            AreaMark(x: .value("Time", point.timestamp), y: .value("CPU", point.cpuUsage))
                                .foregroundStyle(.red.opacity(0.25))
                        }
                        if settingsManager.showMonitorMemory {
                            AreaMark(x: .value("Time", point.timestamp), y: .value("Memory", point.memoryUsage))
                                .foregroundStyle(.blue.opacity(0.25))
                        }
                        if settingsManager.showMonitorDisk {
                            AreaMark(x: .value("Time", point.timestamp), y: .value("Disk", point.diskUsage))
                                .foregroundStyle(.orange.opacity(0.25))
                        }
                        if settingsManager.showMonitorNetwork {
                            AreaMark(x: .value("Time", point.timestamp), y: .value("Network", point.networkThroughputMbps))
                                .foregroundStyle(.green.opacity(0.25))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 220)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
        }
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizationManager.shared.localizedString("monitor.diagnostics.title"))
                .font(.headline)
                .fontWeight(.semibold)
            if let monitor = systemPerformanceMonitor {
                HStack {
                    Text(LocalizationManager.shared.localizedString("monitor.mode.title"))
                    Spacer()
                    Text(modeLabel(monitor.monitoringMode))
                }
                if let info = monitor.helperServiceInfo {
                    HStack {
                        Text("Helper")
                        Spacer()
                        Text("v\(info.helperVersion) / p\(info.protocolVersion)")
                    }
                }
                HStack {
                    Text("GPU使用率")
                    Spacer()
                    Text(metricDiagnosticText(monitor.gpuUsageState))
                }
                HStack {
                    Text("GPU功耗")
                    Spacer()
                    Text(metricDiagnosticText(monitor.gpuPowerState))
                }
                HStack {
                    Text("CPU温度")
                    Spacer()
                    Text(metricDiagnosticText(monitor.cpuTemperatureState))
                }
                HStack {
                    Text("GPU温度")
                    Spacer()
                    Text(metricDiagnosticText(monitor.gpuTemperatureState))
                }
                HStack {
                    Text("风扇")
                    Spacer()
                    Text(metricDiagnosticText(monitor.fanState))
                }
            }
        }
        .font(.caption)
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
        let tempStates = [monitor.cpuTemperatureState, monitor.gpuTemperatureState]
        if tempStates.allSatisfy({ $0.availability == .unavailable }) {
            thermalStatus = LocalizationManager.shared.localizedString("monitor.metric.availability.unavailable")
            return
        }
        if tempStates.allSatisfy({ $0.availability == .stale }) {
            thermalStatus = LocalizationManager.shared.localizedString("monitor.metric.availability.stale")
            return
        }
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

        if monitor.diskUsage > settingsManager.diskThreshold {
            healthScore -= 15
        } else if monitor.diskUsage > 80 {
            healthScore -= 8
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
