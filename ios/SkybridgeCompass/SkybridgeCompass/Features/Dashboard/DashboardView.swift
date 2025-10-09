import SwiftUI
private enum SidebarItem: Hashable {
    case dashboard
    case remoteDesktop
    case fileTransfer
    case remoteShell
    case activity
    case settings
}

struct DashboardView: View {
    @Environment(DashboardViewModel.self) private var viewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("云桥") {
                    Label("主控制台", systemImage: "speedometer")
                        .tag(SidebarItem.dashboard)
                    Label("远程桌面", systemImage: "display")
                        .tag(SidebarItem.remoteDesktop)
                    Label("文件传输", systemImage: "externaldrive")
                        .tag(SidebarItem.fileTransfer)
                    Label("远程 Shell", systemImage: "terminal")
                        .tag(SidebarItem.remoteShell)
                    Label("灵动岛", systemImage: "livephoto")
                        .tag(SidebarItem.activity)
                }
                Section("系统") {
                    Label("系统设置", systemImage: "gear")
                        .tag(SidebarItem.settings)
                }
            }
            .navigationTitle("云桥司南")
            .toolbarBackground(.visible, for: .navigationBar)
        } detail: {
            ZStack {
                StarfieldBackground()
                switch selection ?? .dashboard {
                case .dashboard:
                    DashboardMainPanel()
                        .transition(.opacity)
                case .remoteDesktop:
                    RemoteDesktopView()
                        .transition(.move(edge: .trailing))
                case .fileTransfer:
                    FileTransferView()
                        .transition(.move(edge: .trailing))
                case .remoteShell:
                    RemoteShellView()
                        .transition(.move(edge: .trailing))
                case .activity:
                    ActivityStatusView()
                case .settings:
                    SettingsView()
                }
            }
            .animation(.easeInOut(duration: 0.35), value: selection)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refreshOnce() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear { viewModel.startMonitoring() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                viewModel.startMonitoring()
            case .background:
                viewModel.stopMonitoring()
            default:
                break
            }
        }
    }
}

private struct DashboardMainPanel: View {
    @Environment(DashboardViewModel.self) private var viewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HeaderView(status: viewModel.status, lastUpdated: viewModel.lastUpdated)
                StatusGrid(status: viewModel.status)
            }
            .padding(24)
        }
    }
}

private struct HeaderView: View {
    let status: DeviceStatus
    let lastUpdated: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("云桥司南")
                        .font(.largeTitle.bold())
                    Text("Skybridge Compass")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("上次更新 \(lastUpdated, style: .relative)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(status.summary.deviceName)
                    .font(.title2.bold())
                Text("\(status.summary.systemName) | \(status.summary.chipset)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .liquidGlass()
    }
}

private struct StatusGrid: View {
    let status: DeviceStatus

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 20)], spacing: 20) {
            ControlCenterCard(status: status)
            CPUCard(cpu: status.cpu)
            MemoryCard(memory: status.memory)
            BatteryCard(battery: status.battery)
        }
    }
}

private struct ControlCenterCard: View {
    let status: DeviceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("主控制台", systemImage: "cpu")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(title: "设备标识", value: status.summary.deviceName)
                StatusRow(title: "处理器", value: status.summary.chipset)
                StatusRow(title: "体系架构", value: status.summary.architecture)
                StatusRow(title: "GPU", value: status.summary.gpuName)
            }
        }
        .padding(24)
        .liquidGlass()
    }
}

private struct CPUCard: View {
    let cpu: CPUStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("CPU 状态", systemImage: "waveform.path.ecg")
                .font(.headline)
            if #available(iOS 17.0, *) {
                Gauge(value: cpu.usage) {
                    Text("占用率")
                } currentValueLabel: {
                    Text(cpu.formattedUsage)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .frame(height: 120)
            } else {
                Gauge(value: cpu.usage) {
                    Text("占用率")
                }
                .frame(height: 80)
            }
            HStack {
                StatusPill(icon: "speedometer", title: "主频", value: cpu.formattedFrequency)
                StatusPill(icon: "thermometer", title: "温度", value: cpu.formattedTemperature)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("负载平均值")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach(Array(cpu.loadAverages.enumerated()), id: \.offset) { index, value in
                        VStack {
                            Text(index == 0 ? "1m" : index == 1 ? "5m" : "15m")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.2f", value))
                                .font(.callout)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(24)
        .liquidGlass()
    }
}

private struct MemoryCard: View {
    let memory: MemoryStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("内存状态", systemImage: "memorychip")
                .font(.headline)
            ProgressView(value: memory.usageFraction) {
                Text("占用率")
            }
            .tint(.blue)
            .padding(.vertical, 8)
            StatusRow(title: "已使用", value: ByteCountFormatter.string(fromByteCount: Int64(memory.usedBytes), countStyle: .memory))
            StatusRow(title: "总容量", value: ByteCountFormatter.string(fromByteCount: Int64(memory.totalBytes), countStyle: .memory))
            StatusPill(icon: "exclamationmark.triangle", title: "压力", value: memory.pressure.displayName)
        }
        .padding(24)
        .liquidGlass()
    }
}

private struct BatteryCard: View {
    let battery: BatteryStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("电池信息", systemImage: "battery.100.bolt")
                .font(.headline)
            if #available(iOS 17.0, *) {
                Gauge(value: battery.level) {
                    Text("电量")
                } currentValueLabel: {
                    Text("\(Int(battery.level * 100))%")
                }
                .gaugeStyle(.accessoryLinear)
            } else {
                ProgressView(value: battery.level) {
                    Text("电量")
                }
                Text("\(Int(battery.level * 100))%")
                    .font(.headline)
            }
            StatusRow(title: "状态", value: battery.state.displayName)
            StatusRow(title: "健康", value: battery.health.displayName)
            if let temperature = battery.temperatureCelsius {
                StatusRow(title: "温度", value: String(format: "%.0f℃", temperature))
            }
        }
        .padding(24)
        .liquidGlass()
    }
}

private struct StatusRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospaced())
        }
    }
}

private struct StatusPill: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.bold())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct StarfieldBackground: View {
    var body: some View {
        LinearGradient(colors: [Color.black.opacity(0.95), Color.blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}
