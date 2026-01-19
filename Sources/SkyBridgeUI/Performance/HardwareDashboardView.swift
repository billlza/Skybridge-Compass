//
// HardwareDashboardView.swift
// SkyBridgeUI
//
// 硬件性能仪表盘视图
// 支持 macOS 14.0+
//

import SwiftUI
import SkyBridgeCore
import Charts

/// 硬件性能仪表盘主视图
public struct HardwareDashboardView: View {

    @ObservedObject private var monitor: HardwareMonitorService
    @State private var selectedTab: DashboardTab = .overview

    public init(monitor: HardwareMonitorService = .shared) {
        self.monitor = monitor
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 标签页选择器
            Picker("", selection: $selectedTab) {
                ForEach(DashboardTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // 内容区域
            ScrollView {
                switch selectedTab {
                case .overview:
                    overviewContent

                case .cpu:
                    cpuDetailContent

                case .memory:
                    memoryDetailContent

                case .network:
                    networkDetailContent

                case .settings:
                    settingsContent
                }
            }
        }
        .onAppear {
            monitor.startMonitoring()
        }
        .onDisappear {
            // 保持监控，不在这里停止
        }
    }

    // MARK: - Overview Tab

    private var overviewContent: some View {
        VStack(spacing: 16) {
            // 主要指标卡片
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                MetricCard(
                    title: "CPU",
                    value: String(format: "%.1f%%", monitor.currentMetrics.cpu.totalUsage),
                    icon: "cpu",
                    color: cpuColor
                ) {
                    GaugeView(value: monitor.currentMetrics.cpu.totalUsage / 100, color: cpuColor)
                }

                MetricCard(
                    title: "内存",
                    value: String(format: "%.1f%%", monitor.currentMetrics.memory.usagePercent),
                    icon: "memorychip",
                    color: memoryColor
                ) {
                    GaugeView(value: monitor.currentMetrics.memory.usagePercent / 100, color: memoryColor)
                }

                MetricCard(
                    title: "网络下载",
                    value: formatBytesPerSecond(monitor.currentMetrics.network.bytesInPerSecond),
                    icon: "arrow.down.circle",
                    color: .blue
                ) {
                    Image(systemName: "arrow.down")
                        .font(.title)
                        .foregroundColor(.blue)
                }

                MetricCard(
                    title: "网络上传",
                    value: formatBytesPerSecond(monitor.currentMetrics.network.bytesOutPerSecond),
                    icon: "arrow.up.circle",
                    color: .green
                ) {
                    Image(systemName: "arrow.up")
                        .font(.title)
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal)

            // 散热状态
            HStack {
                Image(systemName: thermalIcon)
                    .foregroundColor(thermalColor)
                Text("散热状态: \(monitor.currentMetrics.thermal.thermalState.displayName)")
                Spacer()
            }
            .padding(.horizontal)

            // 磁盘空间
            VStack(alignment: .leading, spacing: 8) {
                Text("磁盘空间")
                    .font(.headline)

                ProgressView(value: monitor.currentMetrics.disk.usagePercent / 100)
                    .tint(diskColor)

                HStack {
                    Text("已用: \(formatBytes(monitor.currentMetrics.disk.usedSpace))")
                    Spacer()
                    Text("可用: \(formatBytes(monitor.currentMetrics.disk.availableSpace))")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)

            Spacer()
        }
        .padding(.vertical)
    }

    // MARK: - CPU Detail Tab

    private var cpuDetailContent: some View {
        VStack(spacing: 16) {
            // 当前使用率
            HStack(spacing: 24) {
                VStack {
                    Text(String(format: "%.1f%%", monitor.currentMetrics.cpu.totalUsage))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(cpuColor)
                    Text("总使用率")
                        .foregroundColor(.secondary)
                }

                Divider()
                    .frame(height: 60)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("用户态:")
                        Spacer()
                        Text(String(format: "%.1f%%", monitor.currentMetrics.cpu.userUsage))
                    }
                    HStack {
                        Text("系统态:")
                        Spacer()
                        Text(String(format: "%.1f%%", monitor.currentMetrics.cpu.systemUsage))
                    }
                    HStack {
                        Text("空闲:")
                        Spacer()
                        Text(String(format: "%.1f%%", monitor.currentMetrics.cpu.idleUsage))
                    }
                }
                .font(.body)
                .frame(width: 150)
            }
            .padding()

            // 历史图表
            if !monitor.cpuHistory.isEmpty {
                VStack(alignment: .leading) {
                    Text("使用率历史")
                        .font(.headline)

                    Chart(Array(monitor.cpuHistory.enumerated()), id: \.offset) { index, metric in
                        LineMark(
                            x: .value("时间", index),
                            y: .value("使用率", metric.totalUsage)
                        )
                        .foregroundStyle(Color.blue.gradient)

                        AreaMark(
                            x: .value("时间", index),
                            y: .value("使用率", metric.totalUsage)
                        )
                        .foregroundStyle(Color.blue.opacity(0.2).gradient)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 200)
                }
                .padding()
            }

            // 核心信息
            HStack {
                Label("\(monitor.currentMetrics.cpu.coreCount) 核心", systemImage: "cpu")
                Spacer()
                Label("\(monitor.currentMetrics.cpu.activeCoreCount) 活跃", systemImage: "bolt.fill")
            }
            .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Memory Detail Tab

    private var memoryDetailContent: some View {
        VStack(spacing: 16) {
            // 内存使用环形图
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 20)
                    .frame(width: 150, height: 150)

                Circle()
                    .trim(from: 0, to: monitor.currentMetrics.memory.usagePercent / 100)
                    .stroke(memoryColor, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(-90))

                VStack {
                    Text(String(format: "%.1f%%", monitor.currentMetrics.memory.usagePercent))
                        .font(.title)
                        .fontWeight(.bold)
                    Text("已使用")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()

            // 内存详情
            VStack(spacing: 12) {
                memoryDetailRow(title: "总内存", value: formatBytes(monitor.currentMetrics.memory.totalMemory))
                memoryDetailRow(title: "已使用", value: formatBytes(monitor.currentMetrics.memory.usedMemory))
                memoryDetailRow(title: "可用", value: formatBytes(monitor.currentMetrics.memory.freeMemory))
                memoryDetailRow(title: "活跃内存", value: formatBytes(monitor.currentMetrics.memory.activeMemory))
                memoryDetailRow(title: "非活跃", value: formatBytes(monitor.currentMetrics.memory.inactiveMemory))
                memoryDetailRow(title: "压缩内存", value: formatBytes(monitor.currentMetrics.memory.compressedMemory))
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)

            // 内存压力状态
            HStack {
                Image(systemName: memoryPressureIcon)
                    .foregroundColor(memoryPressureColor)
                Text("内存压力: \(monitor.currentMetrics.memory.pressureLevel.displayName)")
                Spacer()
            }
            .padding(.horizontal)

            Spacer()
        }
    }

    private func memoryDetailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }

    // MARK: - Network Detail Tab

    private var networkDetailContent: some View {
        VStack(spacing: 16) {
            // 实时速率
            HStack(spacing: 32) {
                VStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title)
                        .foregroundColor(.blue)
                    Text(formatBytesPerSecond(monitor.currentMetrics.network.bytesInPerSecond))
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("下载速率")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundColor(.green)
                    Text(formatBytesPerSecond(monitor.currentMetrics.network.bytesOutPerSecond))
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("上传速率")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()

            // 历史图表
            if !monitor.networkHistory.isEmpty {
                VStack(alignment: .leading) {
                    Text("网络吞吐历史")
                        .font(.headline)

                    Chart {
                        ForEach(Array(monitor.networkHistory.enumerated()), id: \.offset) { index, metric in
                            LineMark(
                                x: .value("时间", index),
                                y: .value("速率", Double(metric.bytesInPerSecond) / 1024 / 1024),
                                series: .value("类型", "下载")
                            )
                            .foregroundStyle(.blue)

                            LineMark(
                                x: .value("时间", index),
                                y: .value("速率", Double(metric.bytesOutPerSecond) / 1024 / 1024),
                                series: .value("类型", "上传")
                            )
                            .foregroundStyle(.green)
                        }
                    }
                    .chartYAxisLabel("MB/s")
                    .frame(height: 200)
                }
                .padding()
            }

            // 累计流量
            VStack(spacing: 12) {
                HStack {
                    Text("总下载")
                    Spacer()
                    Text(formatBytes(monitor.currentMetrics.network.totalBytesIn))
                }
                HStack {
                    Text("总上传")
                    Spacer()
                    Text(formatBytes(monitor.currentMetrics.network.totalBytesOut))
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Settings Tab

    private var settingsContent: some View {
        Form {
            Section {
                Picker("采样间隔", selection: $monitor.configuration.samplingInterval) {
                    Text("0.5 秒").tag(0.5)
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("5 秒").tag(5.0)
                }

                Picker("历史保留时间", selection: $monitor.configuration.historyRetention) {
                    Text("10 分钟").tag(TimeInterval(600))
                    Text("30 分钟").tag(TimeInterval(1800))
                    Text("1 小时").tag(TimeInterval(3600))
                    Text("2 小时").tag(TimeInterval(7200))
                }
            } header: {
                Text("采样设置")
            }

            Section {
                Toggle("CPU 监控", isOn: $monitor.configuration.monitorCPU)
                Toggle("内存监控", isOn: $monitor.configuration.monitorMemory)
                Toggle("GPU 监控", isOn: $monitor.configuration.monitorGPU)
                Toggle("网络监控", isOn: $monitor.configuration.monitorNetwork)
                Toggle("磁盘监控", isOn: $monitor.configuration.monitorDisk)
                Toggle("温度监控", isOn: $monitor.configuration.monitorThermal)
            } header: {
                Text("监控项目")
            }

            Section {
                Button("清空历史数据") {
                    monitor.clearHistory()
                }

                HStack {
                    Text("监控状态")
                    Spacer()
                    Text(monitor.isMonitoring ? "运行中" : "已停止")
                        .foregroundColor(monitor.isMonitoring ? .green : .secondary)
                }
            } header: {
                Text("操作")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var cpuColor: Color {
        let usage = monitor.currentMetrics.cpu.totalUsage
        if usage > 80 { return .red }
        if usage > 60 { return .orange }
        return .green
    }

    private var memoryColor: Color {
        let usage = monitor.currentMetrics.memory.usagePercent
        if usage > 90 { return .red }
        if usage > 75 { return .orange }
        return .blue
    }

    private var diskColor: Color {
        let usage = monitor.currentMetrics.disk.usagePercent
        if usage > 90 { return .red }
        if usage > 75 { return .orange }
        return .green
    }

    private var thermalIcon: String {
        switch monitor.currentMetrics.thermal.thermalState {
        case .nominal: return "thermometer.snowflake"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.sun"
        case .critical: return "thermometer.sun.fill"
        }
    }

    private var thermalColor: Color {
        switch monitor.currentMetrics.thermal.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }

    private var memoryPressureIcon: String {
        switch monitor.currentMetrics.memory.pressureLevel {
        case .normal: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "xmark.octagon"
        }
    }

    private var memoryPressureColor: Color {
        switch monitor.currentMetrics.memory.pressureLevel {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formatBytesPerSecond(_ bytes: UInt64) -> String {
        formatBytes(bytes) + "/s"
    }
}

// MARK: - Supporting Types

private enum DashboardTab: CaseIterable {
    case overview, cpu, memory, network, settings

    var title: String {
        switch self {
        case .overview: return "概览"
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .settings: return "设置"
        }
    }
}

// MARK: - Supporting Views

private struct MetricCard<Content: View>: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            content()
                .frame(height: 50)

            Text(value)
                .font(.headline)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }
}

private struct GaugeView: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 8)

                Circle()
                    .trim(from: 0, to: min(value, 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: min(geometry.size.width, geometry.size.height))
        }
    }
}

// MARK: - Preview

#if DEBUG
struct HardwareDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        HardwareDashboardView()
            .frame(width: 500, height: 600)
    }
}
#endif
