import SwiftUI
import OrderedCollections
import SkyBridgeCore

/// 主仪表盘界面，展示来自真实环境的遥测信息与操作入口。
struct DashboardView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel
    @State private var selectedSession: RemoteSessionSummary?

    private let columnSpacing: CGFloat = 16

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            mainContent
                .padding(24)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.prominentDetail)
        .task {
            await viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSession) {
            Section("在线会话") {
                ForEach(viewModel.sessions) { session in
                    RemoteSessionRow(session: session)
                        .tag(session as RemoteSessionSummary?)
                }
            }
            Section("常用操作") {
                Button(action: viewModel.triggerDiscoveryRefresh) {
                    Label("重新扫描设备", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Button(action: viewModel.openSettings) {
                    Label("打开设置", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 260)
    }

    private var mainContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: columnSpacing) {
                systemMetrics
                remoteSessionsPanel
                discoveryPanel
                fileTransfersPanel
            }
        }
        .background(LinearGradient(gradient: Gradient(colors: [Color(red: 12/255, green: 24/255, blue: 58/255), Color(red: 11/255, green: 15/255, blue: 32/255)]), startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var systemMetrics: some View {
        DashboardCard(title: "主控状态", iconName: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                    MetricView(title: "在线设备", value: viewModel.metrics.onlineDevices)
                    MetricView(title: "活跃会话", value: viewModel.metrics.activeSessions)
                    MetricView(title: "传输任务", value: viewModel.metrics.fileTransfers)
                    MetricView(title: "警报", value: viewModel.metrics.alerts)
                }
                MetricsTimelineView(dataPoints: viewModel.metrics.timeline)
                    .frame(height: 120)
            }
        }
    }

    private var remoteSessionsPanel: some View {
        DashboardCard(title: "远程桌面", iconName: "display") {
            if viewModel.sessions.isEmpty {
                EmptyStateView(title: "暂无远程会话", subtitle: "请先从设备列表中建立连接")
            } else {
                ForEach(viewModel.sessions) { session in
                    RemoteSessionStatusView(session: session, action: {
                        viewModel.focus(on: session)
                    }, endAction: {
                        Task { await viewModel.terminate(session: session) }
                    })
                    Divider()
                }
            }
        }
    }

    private var discoveryPanel: some View {
        DashboardCard(title: "设备发现", iconName: "dot.radiowaves.left.and.right") {
            if viewModel.discoveredDevices.isEmpty {
                EmptyStateView(title: "正在扫描真实设备", subtitle: viewModel.discoveryStatus)
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.discoveredDevices) { device in
                        DiscoveredDeviceRow(device: device, connectAction: {
                            Task { await viewModel.connect(to: device) }
                        })
                        Divider()
                    }
                }
            }
        }
    }

    private var fileTransfersPanel: some View {
        DashboardCard(title: "文件传输", iconName: "folder") {
            if viewModel.transferTasks.isEmpty {
                EmptyStateView(title: "暂无传输任务", subtitle: "当下所有数据均来自真实任务")
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.transferTasks) { task in
                        FileTransferRow(task: task)
                        Divider()
                    }
                }
            }
        }
    }
}

struct DashboardCard<Content: View>: View {
    let title: String
    let iconName: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(title, systemImage: iconName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }
            content()
        }
        .padding(20)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct MetricView: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.bold())
                .foregroundStyle(.white)
        }
    }
}

struct MetricsTimelineView: View {
    let dataPoints: OrderedDictionary<Date, Double>

    var body: some View {
        GeometryReader { geometry in
            let sorted = dataPoints.sorted(by: { $0.key < $1.key })
            Path { path in
                guard let first = sorted.first else { return }
                let width = geometry.size.width
                let height = geometry.size.height
                let times = sorted.map { $0.key.timeIntervalSince1970 }
                guard let minTime = times.min(), let maxTime = times.max(), let minValue = sorted.map({ $0.value }).min(), let maxValue = sorted.map({ $0.value }).max(), maxTime > minTime, maxValue > minValue else {
                    return
                }

                func position(for index: Int) -> CGPoint {
                    let timeRatio = (times[index] - minTime) / (maxTime - minTime)
                    let valueRatio = (sorted[index].value - minValue) / (maxValue - minValue)
                    let x = width * timeRatio
                    let y = height * (1 - valueRatio)
                    return CGPoint(x: x, y: y)
                }

                path.move(to: position(for: 0))
                for idx in sorted.indices {
                    path.addLine(to: position(for: idx))
                }
            }
            .stroke(Color.green, lineWidth: 2)
        }
    }
}

struct RemoteSessionRow: View {
    let session: RemoteSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.targetName)
                .font(.headline)
            Text(session.protocolDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct RemoteSessionStatusView: View {
    let session: RemoteSessionSummary
    let action: () -> Void
    let endAction: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.targetName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(session.protocolDescription) · 带宽 \(session.bandwidthMbps, specifier: "%.1f") Mbps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView(value: session.frameLatencyMilliseconds, total: 80)
                    .progressViewStyle(.linear)
                    .tint(.cyan)
            }
            Spacer()
            VStack(spacing: 8) {
                Button("查看") { action() }
                    .buttonStyle(.borderedProminent)
                Button("断开") { endAction() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
    }
}

struct DiscoveredDeviceRow: View {
    let device: DiscoveredDevice
    let connectAction: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(device.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("IP: \(device.ipv4 ?? device.ipv6 ?? "未知") · 服务: \(device.services.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("连接") {
                connectAction()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct FileTransferRow: View {
    let task: FileTransferTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.fileName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(task.progress.formatted(.percent.precision(.fractionLength(1))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: task.progress)
                .tint(.purple)
            Text("速度: \(task.throughputMbps, specifier: "%.2f") Mbps · 剩余: \(task.remainingTimeDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}
