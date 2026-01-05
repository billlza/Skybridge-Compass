import SwiftUI
import SkyBridgeCore

/// 统一设备发现集成视图
///
/// 这是一个完整的示例，展示如何在主应用中集成统一设备发现功能
///
/// 功能特性：
/// - 自动扫描网络设备和 USB 设备
/// - 显示连接方式标签（Wi-Fi、有线、USB等）
/// - 智能合并同一设备的多种连接方式
/// - 实时更新设备状态
@available(macOS 14.0, *)
public struct UnifiedDeviceDiscoveryIntegrationView: View {
    
    @StateObject private var discoveryManager = UnifiedDeviceDiscoveryManager()
    @State private var selectedTab: DiscoveryTab = .unified
    @State private var showSettings = false
 // 设置项
    @State private var enableBluetooth = false
    @State private var concurrentLimit = 2
    
    public init() {}
    
    public var body: some View {
        NavigationSplitView {
 // 侧边栏
            sidebar
        } detail: {
 // 主内容区
            mainContent
        }
        .navigationTitle("设备发现与管理")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarControls
            }
        }
        .sheet(isPresented: $showSettings) {
            settingsView
        }
        .onAppear {
 // 应用启动时自动开始扫描（默认禁用蓝牙，避免与网络发现争用）
            discoveryManager.startScanning(options: DiscoveryOptions(enableNetwork: true, enableUSB: true, enableBluetooth: enableBluetooth, concurrentLimit: concurrentLimit))
        }
        .onDisappear {
 // 离开视图时停止扫描以节省资源
            discoveryManager.stopScanning()
        }
    }
    
 // MARK: - 侧边栏
    
    private var sidebar: some View {
        List(selection: $selectedTab) {
            Section("设备发现") {
                Label("统一视图", systemImage: "rectangle.3.group")
                    .tag(DiscoveryTab.unified)
                
                Label("按连接方式", systemImage: "link")
                    .tag(DiscoveryTab.byConnection)
                
                Label("按设备类型", systemImage: "square.grid.2x2")
                    .tag(DiscoveryTab.byType)
            }
            
            Section("统计信息") {
                statisticsSection
            }
        }
        .listStyle(.sidebar)
    }
    
    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            statisticRow(
                label: "总设备数",
                value: "\(discoveryManager.unifiedDevices.count)",
                color: .blue
            )
            
            statisticRow(
                label: "多连接设备",
                value: "\(multiConnectionDevicesCount)",
                color: .purple
            )
            
            statisticRow(
                label: "Wi-Fi 设备",
                value: "\(devicesCount(for: .wifi))",
                color: .blue
            )
            
            statisticRow(
                label: "USB 设备",
                value: "\(devicesCount(for: .usb))",
                color: .green
            )
        }
        .padding(.vertical, 8)
    }
    
 // MARK: - 主内容区
    
    private var mainContent: some View {
        Group {
            switch selectedTab {
            case .unified:
                UnifiedDeviceListView()
            case .byConnection:
                devicesByConnectionView
            case .byType:
                devicesByTypeView
            }
        }
    }
    
 // MARK: - 按连接方式分组
    
    private var devicesByConnectionView: some View {
        ScrollView {
            LazyVStack(spacing: 20, pinnedViews: [.sectionHeaders]) {
                ForEach(DeviceConnectionType.allCases.filter { $0 != .unknown }, id: \.self) { connectionType in
                    let devices = devicesForConnectionType(connectionType)
                    
                    if !devices.isEmpty {
                        Section {
                            LazyVStack(spacing: 12) {
                                ForEach(devices) { device in
                                    deviceCompactCard(device)
                                }
                            }
                        } header: {
                            connectionTypeSectionHeader(connectionType, count: devices.count)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
    
 // MARK: - 按设备类型分组
    
    private var devicesByTypeView: some View {
        ScrollView {
            LazyVStack(spacing: 20, pinnedViews: [.sectionHeaders]) {
                let deviceTypes = Set(discoveryManager.unifiedDevices.map { $0.deviceType })
                    .filter { $0 != .unknown }
                    .sorted { deviceTypeDisplayName($0) < deviceTypeDisplayName($1) }
                
                ForEach(deviceTypes, id: \.self) { deviceType in
                    let devices = devicesForType(deviceType)
                    
                    Section {
                        LazyVStack(spacing: 12) {
                            ForEach(devices) { device in
                                deviceCompactCard(device)
                            }
                        }
                    } header: {
                        deviceTypeSectionHeader(deviceType, count: devices.count)
                    }
                }
            }
            .padding(20)
        }
    }
    
 // MARK: - 工具栏控制
    
    private var toolbarControls: some View {
        Group {
 // 扫描状态指示器
            if discoveryManager.isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(discoveryManager.scanProgress.description)
                        .font(.caption)
                }
            }
            
 // 刷新按钮
            Button(action: {
                discoveryManager.refreshDevices()
            }) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(discoveryManager.isScanning)
            
 // 开始/停止扫描
            Button(action: {
                if discoveryManager.isScanning {
                    discoveryManager.stopScanning()
                } else {
                    discoveryManager.startScanning(options: DiscoveryOptions(enableNetwork: true, enableUSB: true, enableBluetooth: enableBluetooth, concurrentLimit: concurrentLimit))
                }
            }) {
                Label(
                    discoveryManager.isScanning ? "停止" : "开始扫描",
                    systemImage: discoveryManager.isScanning ? "stop.circle" : "play.circle"
                )
            }
            
 // 设置按钮
            Button(action: {
                showSettings = true
            }) {
                Label("设置", systemImage: "gear")
            }
        }
    }
    
 // MARK: - 辅助视图
    
    private func deviceCompactCard(_ device: UnifiedDevice) -> some View {
        HStack(spacing: 12) {
 // 设备图标
            Image(systemName: device.deviceType.icon)
                .font(.title2)
                .foregroundColor(deviceTypeColor(device.deviceType))
                .frame(width: 40, height: 40)
                .background(deviceTypeColor(device.deviceType).opacity(0.1))
                .cornerRadius(8)
            
 // 设备信息
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)
                
                if let ipv4 = device.ipv4 {
                    Text(ipv4)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
 // 连接方式标签（已在 @available(macOS 14.0, *) 作用域内，无需再次检查）
                MultiConnectionTypeBadge(
                    connectionTypes: device.connectionTypes,
                    size: .small,
                    maxDisplay: 2
                )
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
    
    private func connectionTypeSectionHeader(_ type: DeviceConnectionType, count: Int) -> some View {
        HStack {
            Image(systemName: type.iconName)
                .foregroundColor(connectionTypeColor(type))
            
            Text(type.rawValue)
                .font(.headline)
            
            Spacer()
            
            Text("\(count) 台设备")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func deviceTypeSectionHeader(_ type: DeviceClassifier.DeviceType, count: Int) -> some View {
        HStack {
            Image(systemName: type.icon)
                .foregroundColor(deviceTypeColor(type))
            
            Text(deviceTypeDisplayName(type))
                .font(.headline)
            
            Spacer()
            
            Text("\(count) 台设备")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func statisticRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
    }
    
 // MARK: - 设置视图
    
    private var settingsView: some View {
        NavigationView {
            Form {
                Section("扫描设置") {
                    Toggle("启用蓝牙扫描", isOn: $enableBluetooth)
                    Stepper(value: $concurrentLimit, in: 1...3) {
                        HStack {
                            Text("并发度")
                            Spacer()
                            Text("\(concurrentLimit)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section("服务状态") {
                    statusRow(label: "服务运行态", value: discoveryManager.serviceState.rawValue)
                    statusRow(label: "权限汇总", value: discoveryManager.permissionState.rawValue)
                }
                
                Section("详细权限") {
                    detailedPermissionRow(label: "网络", status: discoveryManager.detailedPermissions.network)
                    detailedPermissionRow(label: "USB", status: discoveryManager.detailedPermissions.usb)
                    detailedPermissionRow(label: "蓝牙", status: discoveryManager.detailedPermissions.bluetooth)
                }
                
                Section("高级") {
                    Text("扫描间隔与调试项可在后续版本接入实际配置中心")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("完成") { showSettings = false }
                }
            }
        }
        .frame(width: 500, height: 400)
    }
    
 // MARK: - 辅助方法
    
    private var multiConnectionDevicesCount: Int {
        discoveryManager.unifiedDevices.filter { $0.hasMultipleConnections }.count
    }
    
    private func devicesCount(for type: DeviceConnectionType) -> Int {
        discoveryManager.unifiedDevices.filter { $0.connectionTypes.contains(type) }.count
    }
    
    private func devicesForConnectionType(_ type: DeviceConnectionType) -> [UnifiedDevice] {
        discoveryManager.unifiedDevices
            .filter { $0.connectionTypes.contains(type) }
            .sorted { $0.name < $1.name }
    }
    
    private func devicesForType(_ type: DeviceClassifier.DeviceType) -> [UnifiedDevice] {
        discoveryManager.unifiedDevices
            .filter { $0.deviceType == type }
            .sorted { $0.name < $1.name }
    }
    
    private func deviceTypeDisplayName(_ type: DeviceClassifier.DeviceType) -> String {
        switch type {
        case .computer: return "计算机"
        case .camera: return "摄像头"
        case .router: return "路由器"
        case .printer: return "打印机"
        case .speaker: return "音响"
        case .tv: return "电视"
        case .nas: return "存储设备"
        case .iot: return "物联网设备"
        case .unknown: return "未知设备"
        }
    }
    
    private func deviceTypeColor(_ type: DeviceClassifier.DeviceType) -> Color {
        switch type {
        case .computer: return .blue
        case .camera: return .red
        case .router: return .orange
        case .printer: return .purple
        case .speaker: return .green
        case .tv: return .indigo
        case .nas: return .cyan
        case .iot: return .yellow
        case .unknown: return .gray
        }
    }
    
    private func connectionTypeColor(_ type: DeviceConnectionType) -> Color {
        switch type {
        case .wifi: return .blue
        case .ethernet: return .orange
        case .usb: return .green
        case .thunderbolt: return .purple
        case .bluetooth: return .cyan
        case .unknown: return .gray
        }
    }
}

// MARK: - 小组件

private extension UnifiedDeviceDiscoveryIntegrationView {
    func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
        }
    }
    
    func detailedPermissionRow(label: String, status: DiscoveryPermissionStatus) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(status.rawValue)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(permissionStatusColor(status))
        }
    }
    
    func permissionStatusColor(_ status: DiscoveryPermissionStatus) -> Color {
        switch status {
        case .granted:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        case .unknown:
            return .gray
        }
    }
}

// MARK: - 发现标签页枚举

enum DiscoveryTab: String, Identifiable {
    case unified = "unified"
    case byConnection = "connection"
    case byType = "type"
    
    var id: String { rawValue }
}

// MARK: - 预览

#if DEBUG
@available(macOS 14.0, *)
struct UnifiedDeviceDiscoveryIntegrationView_Previews: PreviewProvider {
    static var previews: some View {
        UnifiedDeviceDiscoveryIntegrationView()
            .frame(width: 1000, height: 700)
    }
}
#endif

