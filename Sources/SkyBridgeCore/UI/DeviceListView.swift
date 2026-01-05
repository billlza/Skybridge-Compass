import SwiftUI
import Combine

/// 设备列表视图 - 现代化的设备管理界面
public struct DeviceListView: View {
    
 // MARK: - 状态管理
    
    @StateObject private var deviceDiscovery = DeviceDiscoveryManagerOptimized() // 高性能设备发现（2025年优化版）
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var deviceFilterManager = DeviceFilterManager()
    @State private var selectedDevice: DiscoveredDevice?
    @State private var showingConnectionOptions = false
    @State private var isScanning = false
    @State private var showingFilterOptions = false
    
 // MARK: - 视图主体
    
    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
 // 顶部工具栏
                topToolbar
                
 // 设备分组列表
                deviceGroupList
            }
            .navigationTitle("设备发现")
            .sheet(isPresented: $showingConnectionOptions) {
                if let device = selectedDevice {
                    ConnectionOptionsView(
                        device: device,
                        availableConnections: connectionManager.availableConnections,
                        onConnect: { method in
                            Task {
                                try await connectionManager.establishConnection(method: method, to: device)
                            }
                        }
                    )
                }
            }
            .sheet(isPresented: $showingFilterOptions) {
                DeviceFilterOptionsView(filterManager: deviceFilterManager)
            }
        }
        .onAppear {
            startDiscovery()
        }
        .onChange(of: deviceDiscovery.discoveredDevices) { _, devices in
 // 当设备列表更新时，更新过滤管理器
            deviceFilterManager.updateDevices(devices)
        }
    }
    
 // MARK: - 设备类型相关方法
    
 /// 获取设备类型显示名称
    private func deviceTypeDisplayName(_ deviceType: DeviceClassifier.DeviceType) -> String {
        switch deviceType {
        case .computer:
            return "计算机"
        case .camera:
            return "摄像头"
        case .router:
            return "路由器"
        case .printer:
            return "打印机"
        case .speaker:
            return "音响"
        case .tv:
            return "电视"
        case .nas:
            return "存储"
        case .iot:
            return "物联网"
        case .unknown:
            return "未知"
        }
    }
    
 /// 获取设备类型颜色
    private func deviceTypeColor(_ deviceType: DeviceClassifier.DeviceType) -> Color {
        switch deviceType {
        case .computer:
            return .blue
        case .camera:
            return .red
        case .router:
            return .orange
        case .printer:
            return .purple
        case .speaker:
            return .green
        case .tv:
            return .indigo
        case .nas:
            return .cyan
        case .iot:
            return .yellow
        case .unknown:
            return .gray
        }
    }
    
 // MARK: - 子视图
    
 /// 顶部工具栏
    private var topToolbar: some View {
        HStack {
 // 扫描状态指示器
            HStack(spacing: 8) {
                if isScanning {
                    ProgressView()
                        .scaleEffect(0.8)
                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                } else {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                }
                
                Text(isScanning ? "正在扫描..." : "扫描完成")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
 // 工具按钮
            HStack(spacing: 12) {
 // 过滤设置按钮
                Button(action: {
                    showingFilterOptions = true
                }) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.title2)
                        .foregroundColor(.purple)
                }
                
 // 开始扫描按钮
                Button(action: {
                    deviceDiscovery.startScanning()
                    isScanning = true
                }) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
                .disabled(isScanning)
                
 // 刷新按钮
                Button(action: refreshDevices) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                }
                
 // 停止扫描按钮
                Button(action: {
                    deviceDiscovery.stopScanning()
                    isScanning = false
                }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                }
                .disabled(!isScanning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.clear)
    }
    
 /// 设备分组列表
    private var deviceGroupList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(deviceFilterManager.deviceGroups, id: \.type) { group in
                    DeviceGroupView(
                        group: group,
                        isExpanded: group.isExpanded,
                        onToggleExpanded: {
                            deviceFilterManager.toggleGroupExpansion(for: group.type)
                        },
                        onConnect: { device in
                            selectedDevice = device
                            showingConnectionOptions = true
                        },
                        onDisconnect: { device in
                            disconnectDevice(device)
                        },
                        getConnectionStatus: getConnectionStatus
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .refreshable {
            await refreshDevicesAsync()
        }
    }
    
 // MARK: - 私有方法
    
 /// 开始设备发现（门闩去重）
    private func startDiscovery() {
        deviceDiscovery.startScanningIfNeeded()
        isScanning = deviceDiscovery.isScanning
    }
    
 /// 刷新设备列表（避免 stop→start 风暴）
    private func refreshDevices() {
        deviceDiscovery.stopScanningIfNeeded()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            deviceDiscovery.startScanningIfNeeded()
            isScanning = deviceDiscovery.isScanning
        }
    }
    
 /// 异步刷新设备列表
    private func refreshDevicesAsync() async {
        deviceDiscovery.stopScanning()
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        deviceDiscovery.startScanning()
        await MainActor.run {
            isScanning = deviceDiscovery.isScanning
        }
    }
    
 /// 获取设备连接状态
    private func getConnectionStatus(for device: DiscoveredDevice) -> ConnectionStatus {
        let isConnected = connectionManager.activeConnections.contains { connection in
            connection.device.id == device.id
        }
        return isConnected ? .connected : .disconnected
    }
    
 /// 断开设备连接
    private func disconnectDevice(_ device: DiscoveredDevice) {
        if let connection = connectionManager.activeConnections.first(where: { $0.device.id == device.id }) {
            Task {
                await connectionManager.disconnectConnection(connection.id)
            }
        }
    }
    
 /// 获取连接状态描述
    private func connectionStatusDescription(_ status: ConnectionStatus) -> String {
        switch status {
        case .disconnected:
            return "未连接"
        case .connecting:
            return "连接中"
        case .connected:
            return "已连接"
        case .reconnecting:
            return "重连中"
        case .failed:
            return "连接失败"
        case .timeout:
            return "连接超时"
        case .error:
            return "连接错误"
        }
    }
}

/// 设备卡片视图 - 显示单个设备的详细信息
struct DeviceCardView: View {
    let device: DiscoveredDevice
    let connectionStatus: ConnectionStatus
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let showDeviceType: Bool
    
 // 设备类型检测器
    @StateObject private var deviceTypeDetector = DeviceTypeDetector()
    @State private var detailedDeviceInfo: DeviceTypeDetector.DetailedDeviceInfo?
    
    init(device: DiscoveredDevice, connectionStatus: ConnectionStatus, onConnect: @escaping () -> Void, onDisconnect: @escaping () -> Void, showDeviceType: Bool = false) {
        self.device = device
        self.connectionStatus = connectionStatus
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
        self.showDeviceType = showDeviceType
    }
    
 /// 获取设备类型显示名称
    private func deviceTypeDisplayName(_ deviceType: DeviceClassifier.DeviceType) -> String {
        switch deviceType {
        case .computer:
            return "计算机"
        case .camera:
            return "摄像头"
        case .router:
            return "路由器"
        case .printer:
            return "打印机"
        case .speaker:
            return "音响"
        case .tv:
            return "电视"
        case .nas:
            return "存储"
        case .iot:
            return "物联网"
        case .unknown:
            return "未知"
        }
    }
    
 /// 获取设备类型颜色
    private func deviceTypeColor(_ deviceType: DeviceClassifier.DeviceType) -> Color {
        switch deviceType {
        case .computer:
            return .blue
        case .camera:
            return .red
        case .router:
            return .orange
        case .printer:
            return .purple
        case .speaker:
            return .green
        case .tv:
            return .indigo
        case .nas:
            return .cyan
        case .iot:
            return .yellow
        case .unknown:
            return .gray
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
 // 设备信息头部
            HStack {
 // 设备图标 - 使用检测到的设备类型图标
                Image(systemName: deviceIcon)
                    .font(.title2)
                    .foregroundColor(deviceIconColor)
                    .frame(width: 32, height: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
 // 显示设备名称，优先使用检测到的显示名称
                        Text(displayDeviceName)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
 // 设备类型标签（如果启用显示）
                        if showDeviceType {
 // 使用DeviceClassifier获取设备类型
                            let deviceType = device.deviceType
                            if deviceType != .unknown && deviceType != .computer {
                                Text(deviceTypeDisplayName(deviceType))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(deviceTypeColor(deviceType).opacity(0.2))
                                    .foregroundColor(deviceTypeColor(deviceType))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    
 // IP地址和制造商信息
                    HStack {
                        Text(device.ipv4 ?? device.ipv6 ?? "未知地址")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
 // 显示制造商信息
                        if let deviceInfo = detailedDeviceInfo, 
                           deviceInfo.manufacturer != .unknown {
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(deviceInfo.manufacturer.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
 // 连接状态指示器
                connectionStatusIndicator
            }
            
 // 设备详细信息和能力
            if let deviceInfo = detailedDeviceInfo, !deviceInfo.capabilities.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备能力")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 80), spacing: 4)
                    ], spacing: 4) {
                        ForEach(deviceInfo.capabilities, id: \.self) { capability in
                            Text(capability)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                    }
                }
                .padding(.top, 4)
            }
            
 // 可用服务（如果有）
            if !device.services.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("可用服务")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ForEach(Array(device.services.enumerated()), id: \.offset) { index, service in
                        HStack {
                            Image(systemName: serviceIcon(for: service))
                                .font(.caption)
                                .foregroundColor(.blue)
                                .frame(width: 12)
                            
                            Text(service)
                                .font(.caption)
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
 // 显示端口信息
                            if let port = device.portMap[service] {
                                Text(":\(port)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            
 // 操作按钮
            HStack {
                if connectionStatus == .connected {
                    Button("断开连接", action: onDisconnect)
                        .buttonStyle(SecondaryButtonStyle())
                } else {
 // 当设备未公开任何端口时，标记为“不可连接”并禁用按钮，避免徒劳的尝试
                    let availablePort = device.portMap.values.first ?? 0
                    Button(availablePort > 0 ? "连接" : "不可连接", action: onConnect)
                        .disabled(availablePort == 0)
                        .buttonStyle(PrimaryButtonStyle())
                }
                
                Spacer()
                
 // 显示更多统计信息
                HStack(spacing: 8) {
                    if !device.services.isEmpty {
                        Text("服务: \(device.services.count)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    if let deviceInfo = detailedDeviceInfo, !deviceInfo.capabilities.isEmpty {
                        Text("能力: \(deviceInfo.capabilities.count)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
        .onAppear {
 // 异步获取设备详细信息
            Task {
                await loadDeviceDetails()
            }
        }
    }
    
 // MARK: - 私有方法
    
 /// 异步加载设备详细信息
    private func loadDeviceDetails() async {
        guard let ipAddress = device.ipv4 ?? device.ipv6 else { return }
        
 // 使用设备类型检测器获取详细信息
        let deviceInfo = deviceTypeDetector.detectDeviceInfo(
            hostname: device.name,
            ipAddress: ipAddress,
            macAddress: nil,
            openPorts: Array(device.portMap.values)
        )
        
        await MainActor.run {
            self.detailedDeviceInfo = deviceInfo
        }
    }
    
 /// 显示的设备名称
    private var displayDeviceName: String {
        if let deviceInfo = detailedDeviceInfo {
            return deviceInfo.displayName
        }
        return device.name
    }
    
 /// 设备图标
    private var deviceIcon: String {
 // 优先使用检测到的设备类型图标
        if let deviceInfo = detailedDeviceInfo {
            return deviceInfo.deviceType.icon
        }
        
 // 回退到基于服务的图标推断
        if device.services.contains("ssh") {
            return "desktopcomputer"
        } else if device.services.contains("vnc") {
            return "display"
        } else {
            return "network"
        }
    }
    
 /// 获取服务对应的图标
    private func serviceIcon(for service: String) -> String {
        switch service.lowercased() {
        case "ssh":
            return "terminal"
        case "vnc", "rfb":
            return "display"
        case "ftp", "sftp":
            return "folder"
        case "http", "https":
            return "globe"
        case "smb":
            return "externaldrive.connected.to.line.below"
        case "airplay":
            return "airplayvideo"
        case "airdrop":
            return "wifi.circle"
        default:
            return "network"
        }
    }
    
 /// 设备图标颜色
    private var deviceIconColor: Color {
 // 优先使用检测到的设备类型图标颜色
        if let deviceInfo = detailedDeviceInfo {
 // 根据设备类型返回对应颜色
            switch deviceInfo.deviceType {
            case .iPhone, .iPad:
                return .blue
            case .mac:
                return .gray
            case .appleTV:
                return .purple
            case .androidPhone, .androidTablet:
                return .green
            case .windowsPC, .linuxPC:
                return .orange
            case .router:
                return .red
            case .printer:
                return .purple
            default:
                return connectionStatusColor
            }
        }
        
 // 回退到连接状态颜色
        return connectionStatusColor
    }
    
 /// 连接状态颜色
    private var connectionStatusColor: Color {
        switch connectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .reconnecting:
            return .orange
        case .failed:
            return .red
        case .timeout:
            return .red
        case .error:
            return .red
        case .disconnected:
            return .gray
        }
    }
    
 /// 连接状态指示器
    private var connectionStatusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(connectionStatusDescription)
                .font(.caption)
                .foregroundColor(statusColor)
        }
    }
    
 /// 状态颜色
    private var statusColor: Color {
        switch connectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .reconnecting:
            return .orange
        case .failed:
            return .red
        case .timeout:
            return .red
        case .error:
            return .red
        case .disconnected:
            return .gray
        }
    }
    
 /// 连接状态描述
    private var connectionStatusDescription: String {
        switch connectionStatus {
        case .disconnected:
            return "未连接"
        case .connecting:
            return "连接中"
        case .connected:
            return "已连接"
        case .reconnecting:
            return "重连中"
        case .failed:
            return "连接失败"
        case .timeout:
            return "连接超时"
        case .error:
            return "连接错误"
        }
    }
}

/// 连接选项视图
struct ConnectionOptionsView: View {
    let device: DiscoveredDevice
    let availableConnections: [ConnectionMethod]
    let onConnect: (ConnectionMethod) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
 // 设备信息
                VStack(alignment: .leading, spacing: 8) {
                    Text("连接到")
                        .font(.headline)
                    
                    HStack {
                        Image(systemName: "display")
                            .font(.title2)
                            .foregroundColor(.blue)
                        
                        VStack(alignment: .leading) {
                            Text(device.name)
                                .font(.title3)
                                .fontWeight(.medium)
                            Text(device.ipv4 ?? device.ipv6 ?? "未知地址")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Divider()
                
 // 连接方式选择
                VStack(alignment: .leading, spacing: 12) {
                    Text("选择连接方式")
                        .font(.headline)
                    
                    ForEach(availableConnections.sorted(by: { $0.priority > $1.priority }), id: \.self) { method in
                        ConnectionMethodRow(method: method) {
                            onConnect(method)
                            dismiss()
                        }
                    }
                }
                
                Spacer()
            }
            .padding(20)
            .navigationTitle("连接选项")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 连接方式行视图
struct ConnectionMethodRow: View {
    let method: ConnectionMethod
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: methodIcon)
                    .font(.title2)
                    .foregroundColor(methodColor)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(method.description)
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    Text(methodDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(NSColor.quaternaryLabelColor))
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var methodIcon: String {
        switch method {
        case .wifi:
            return "wifi"
        case .thunderbolt:
            return "bolt"
        case .usbc:
            return "cable.connector"
        }
    }
    
    private var methodColor: Color {
        switch method {
        case .wifi:
            return .blue
        case .thunderbolt:
            return .purple
        case .usbc:
            return .orange
        }
    }
    
    private var methodDescription: String {
        switch method {
        case .wifi:
            return "无线连接，适合一般用途"
        case .thunderbolt:
            return "高速连接，最佳性能"
        case .usbc:
            return "有线连接，稳定可靠"
        }
    }
}

// MARK: - 按钮样式

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.blue)
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .fontWeight(.medium)
            .foregroundColor(.blue)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - 预览

struct DeviceListView_Previews: PreviewProvider {
    static var previews: some View {
        DeviceListView()
    }
}
