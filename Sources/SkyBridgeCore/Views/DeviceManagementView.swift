import SwiftUI
import Combine

/// 设备管理视图 - 集成WiFi、蓝牙、AirPlay设备发现和管理
public struct DeviceManagementView: View {
    
 // MARK: - 状态管理
    @StateObject private var wifiManager = WiFiManager()
    @StateObject private var bluetoothManager = BluetoothManager()
    @StateObject private var airplayManager = AirPlayManager()
    @StateObject private var permissionManager = DevicePermissionManager()
    
 // 状态变量
    @State private var selectedTab: DeviceTab = .all
    @State private var showingPermissionAlert = false
    @State private var showingDeviceSettings = false
    @State private var searchText = ""
    @State private var sortOption: SortOption = .name
    @State private var showOfflineDevices = true
    @State private var showingDetails = false
    @State private var selectedP2PDevice: P2PDevice?
    @StateObject private var p2pManager = P2PNetworkManager.shared
    
 // MARK: - 设备标签页枚举
    enum DeviceTab: String, CaseIterable {
        case all = "全部设备"
        case wifi = "WiFi"
        case bluetooth = "蓝牙"
        case airplay = "AirPlay"
        
        var iconName: String {
            switch self {
            case .all:
                return "externaldrive.connected.to.line.below"
            case .wifi:
                return "wifi"
            case .bluetooth:
                return "bluetooth"
            case .airplay:
                return "airplayvideo"
            }
        }
    }
    
 // MARK: - 排序选项枚举
    enum SortOption: String, CaseIterable {
        case name = "名称"
        case signalStrength = "信号强度"
        case lastSeen = "最近发现"
        case deviceType = "设备类型"
    }
    
    public init() {}
    
    public var body: some View {
        NavigationSplitView {
 // 侧边栏
            deviceSidebar
        } detail: {
 // 主内容区域
            deviceContent
        }
        .navigationTitle("设备管理")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
 // 刷新按钮
                Button(action: refreshAllDevices) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新设备列表")
                
 // 设备管理设置按钮
                Button(action: { showingDeviceSettings = true }) {
                    Image(systemName: "gearshape")
                }
                .help("设备管理设置")
            }
        }
        .alert("权限设置", isPresented: $showingPermissionAlert) {
            Button("打开系统偏好设置") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
                NSWorkspace.shared.open(url)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("某些设备发现功能需要系统权限。请在系统偏好设置中授权相关权限。")
        }
        .sheet(isPresented: $showingDeviceSettings) {
            DeviceManagementSettingsView()
                .frame(minWidth: 600, minHeight: 500)
        }
        .sheet(isPresented: $showingDetails) {
            if let device = selectedP2PDevice {
                ConnectionDetailsView(device: device)
                    .frame(minWidth: 720, minHeight: 560)
            }
        }
        .onAppear {
            checkPermissionsAndStartScanning()
        }
    }
    
 // MARK: - 侧边栏视图
    private var deviceSidebar: some View {
        VStack(spacing: 0) {
 // 标签页选择
            List(DeviceTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.iconName)
                    .tag(tab)
            }
            .listStyle(SidebarListStyle())
            
            Divider()
            
 // 控制面板
            VStack(alignment: .leading, spacing: 12) {
                Text("扫描控制")
                    .font(.headline)
                    .padding(.horizontal)
                
                VStack(spacing: 8) {
 // WiFi扫描控制
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundColor(.blue)
                        Text("WiFi")
                        Spacer()
                        Button(wifiManager.isScanning ? "停止" : "扫描") {
                            if wifiManager.isScanning {
                                wifiManager.stopScanning()
                            } else {
                                Task {
                                    await wifiManager.startScanning()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
 // 蓝牙扫描控制
                    HStack {
 // 使用通用符号视图，确保蓝牙图标在不同环境下稳定显示
                        SystemSymbolIcon(name: "bluetooth", color: .blue, size: 16)
                        Text("蓝牙")
                        Spacer()
                        Button(bluetoothManager.isScanning ? "停止" : "扫描") {
                            if bluetoothManager.isScanning {
                                bluetoothManager.stopScanning()
                            } else {
                                bluetoothManager.startScanning()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(bluetoothManager.managerState != BluetoothManagerState.poweredOn)
                    }
                    
 // AirPlay扫描控制
                    HStack {
                        Image(systemName: "airplayvideo")
                            .foregroundColor(.blue)
                        Text("AirPlay")
                        Spacer()
                        Button(airplayManager.isScanning ? "停止" : "扫描") {
                            if airplayManager.isScanning {
                                airplayManager.stopScanning()
                            } else {
                                airplayManager.startScanning()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)
                
                Divider()
                
 // 统计信息
                VStack(alignment: .leading, spacing: 8) {
                    Text("设备统计")
                        .font(.headline)
                    
                    HStack {
                        Text("WiFi:")
                        Spacer()
                        Text("\(wifiManager.availableNetworks.count)")
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("蓝牙:")
                        Spacer()
                        Text("\(bluetoothManager.discoveredDevices.count)")
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("AirPlay:")
                        Spacer()
                        Text("\(airplayManager.discoveredDevices.count)")
                            .fontWeight(.medium)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.vertical)
        }
        .frame(minWidth: 250)
    }
    
 // MARK: - 主内容视图
    private var deviceContent: some View {
        VStack(spacing: 0) {
 // 搜索和过滤栏
            HStack {
 // 搜索框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索设备...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
                
 // 排序选择
                Picker("排序", selection: $sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(width: 120)
                
 // 显示离线设备开关
                Toggle("显示离线", isOn: $showOfflineDevices)
                    .toggleStyle(SwitchToggleStyle())
            }
            .padding()
            .background(Color(.windowBackgroundColor))
            
            Divider()
            
 // 设备列表
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredDevices, id: \.id) { device in
                        DeviceRowView(
                            device: device,
                            onConnect: { handleConnect(device) },
                            onDisconnect: { handleDisconnect(device) },
                            onDetails: { handleDetails(device) }
                        )
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
        }
    }
    
 // MARK: - 设备行视图
    private struct DeviceRowView: View {
        let device: AnyDevice
        let onConnect: () -> Void
        let onDisconnect: () -> Void
        let onDetails: () -> Void
        
        var body: some View {
            HStack(spacing: 16) {
 // 设备图标
 // 设备行图标统一使用通用符号视图，避免出现蓝牙等符号缺失
                SystemSymbolIcon(name: device.iconName, color: device.statusColor, size: 20)
                    .frame(width: 32, height: 32)
                
 // 设备信息
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(device.displayName)
                            .font(.headline)
                        
                        if device.isConnected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    }
                    
                    Text(device.typeDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if let signalInfo = device.signalInfo {
                        HStack {
                            Text(signalInfo)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if let signalStrength = device.signalStrength {
                                ProgressView(value: signalStrength, total: 100)
                                    .frame(width: 60)
                            }
                        }
                    }
                }
                
                Spacer()
                
 // 操作按钮
                VStack(spacing: 8) {
                    if device.isConnectable {
                        Button(device.isConnected ? "断开" : "连接") {
                            device.isConnected ? onDisconnect() : onConnect()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Button("详情", action: onDetails)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .padding()
            .background(Color(.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
    
 // MARK: - 计算属性
    
 /// 过滤后的设备列表
    private var filteredDevices: [AnyDevice] {
        var devices: [AnyDevice] = []
        
 // 根据选中的标签页添加设备
        switch selectedTab {
        case .all:
            devices.append(contentsOf: wifiManager.availableNetworks.map { AnyDevice.wifi($0) })
            devices.append(contentsOf: bluetoothManager.discoveredDevices.map { AnyDevice.bluetooth($0) })
            devices.append(contentsOf: airplayManager.discoveredDevices.map { AnyDevice.airplay($0) })
        case .wifi:
            devices.append(contentsOf: wifiManager.availableNetworks.map { AnyDevice.wifi($0) })
        case .bluetooth:
            devices.append(contentsOf: bluetoothManager.discoveredDevices.map { AnyDevice.bluetooth($0) })
        case .airplay:
            devices.append(contentsOf: airplayManager.discoveredDevices.map { AnyDevice.airplay($0) })
        }
        
 // 应用搜索过滤
        if !searchText.isEmpty {
            devices = devices.filter { device in
                device.displayName.localizedCaseInsensitiveContains(searchText) ||
                device.typeDescription.localizedCaseInsensitiveContains(searchText)
            }
        }
        
 // 应用离线设备过滤
        if !showOfflineDevices {
            devices = devices.filter { $0.isOnline }
        }
        
 // 应用排序
        switch sortOption {
        case .name:
            devices.sort { $0.displayName < $1.displayName }
        case .signalStrength:
            devices.sort { ($0.signalStrength ?? 0) > ($1.signalStrength ?? 0) }
        case .lastSeen:
            devices.sort { $0.lastSeen > $1.lastSeen }
        case .deviceType:
            devices.sort { $0.typeDescription < $1.typeDescription }
        }
        
        return devices
    }
    
 // MARK: - 方法
    
 /// 检查权限并开始扫描
    private func checkPermissionsAndStartScanning() {
        permissionManager.checkAllPermissions()
        
 // 如果有权限，自动开始扫描
        if permissionManager.allRequiredPermissionsGranted {
            refreshAllDevices()
        }
    }
    
 /// 刷新所有设备
    @MainActor
    private func refreshAllDevices() {
        Task {
            await wifiManager.startScanning()
        }
        
        if bluetoothManager.managerState == BluetoothManagerState.poweredOn {
            bluetoothManager.startScanning()
        }
        
        airplayManager.startScanning()
    }

 // MARK: - 交互处理
    private func handleConnect(_ any: AnyDevice) {
        switch any {
        case .bluetooth(let bt):
            Task { try? await bluetoothManager.connect(to: bt) }
        case .wifi, .airplay:
            break
        }
    }
    
    private func handleDisconnect(_ any: AnyDevice) {
        switch any {
        case .bluetooth(let bt):
            bluetoothManager.disconnect(from: bt)
        case .wifi, .airplay:
            break
        }
    }
    
    private func handleDetails(_ any: AnyDevice) {
        if let device = mapToP2P(any) {
            selectedP2PDevice = device
            showingDetails = true
        }
    }
    
    private func mapToP2P(_ any: AnyDevice) -> P2PDevice? {
        switch any {
        case .bluetooth(let bt):
            return p2pManager.discoveredDevices.first { $0.name == (bt.name ?? "") }
        case .wifi(let net):
            return p2pManager.discoveredDevices.first { $0.name == net.ssid }
        case .airplay(let ap):
            return p2pManager.discoveredDevices.first { $0.name == ap.name }
        }
    }
}

// MARK: - 设备统一模型

/// 统一设备模型，用于在界面中统一显示不同类型的设备
enum AnyDevice: Identifiable {
    case wifi(WiFiNetwork)
    case bluetooth(BluetoothDevice)
    case airplay(AirPlayDevice)
    
    var id: String {
        switch self {
        case .wifi(let network):
            return "wifi_\(network.ssid)"
        case .bluetooth(let device):
            return "bluetooth_\(device.identifier)"
        case .airplay(let device):
            return "airplay_\(device.id)"
        }
    }
    
    var displayName: String {
        switch self {
        case .wifi(let network):
            return network.ssid
        case .bluetooth(let device):
            return device.displayName
        case .airplay(let device):
            return device.name
        }
    }
    
    var typeDescription: String {
        switch self {
        case .wifi(let network):
            return "WiFi网络 - \(network.securityTypeDescription)"
        case .bluetooth(let device):
            return device.deviceTypeDescription
        case .airplay(let device):
            return device.deviceTypeDescription
        }
    }
    
    var iconName: String {
        switch self {
        case .wifi:
            return "wifi"
        case .bluetooth:
            return "bluetooth"
        case .airplay:
            return "airplayvideo"
        }
    }
    
    var statusColor: Color {
        switch self {
        case .wifi(let network):
            return network.isConnected ? .green : .blue
        case .bluetooth(let device):
            return device.isConnected ? .green : .blue
        case .airplay:
            return .blue
        }
    }
    
    var isConnected: Bool {
        switch self {
        case .wifi(let network):
            return network.isConnected
        case .bluetooth(let device):
            return device.isConnected
        case .airplay:
            return false // AirPlay设备连接状态需要额外实现
        }
    }
    
    var isConnectable: Bool {
        switch self {
        case .wifi:
            return true
        case .bluetooth(let device):
            return device.isConnectable
        case .airplay:
            return true
        }
    }
    
    var isOnline: Bool {
        switch self {
        case .wifi:
            return true // WiFi网络默认在线
        case .bluetooth:
            return true // 发现的蓝牙设备默认在线
        case .airplay:
            return true // 发现的AirPlay设备默认在线
        }
    }
    
    var signalStrength: Double? {
        switch self {
        case .wifi(let network):
            return network.signalStrengthPercentage
        case .bluetooth(let device):
            return device.signalStrengthPercentage
        case .airplay:
            return nil // AirPlay设备暂不显示信号强度
        }
    }
    
    var signalInfo: String? {
        switch self {
        case .wifi(let network):
            return network.signalStrengthDescription
        case .bluetooth(let device):
            return "\(device.signalStrengthDescription) (\(device.rssi) dBm)"
        case .airplay:
            return nil
        }
    }
    
    var lastSeen: Date {
        switch self {
        case .wifi:
            return Date() // WiFi网络使用当前时间
        case .bluetooth(let device):
            return device.lastSeen
        case .airplay:
            return Date() // AirPlay设备使用当前时间
        }
    }
}