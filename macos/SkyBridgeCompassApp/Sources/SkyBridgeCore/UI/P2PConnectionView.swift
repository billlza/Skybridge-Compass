import SwiftUI
import Network
import Combine

/// P2P连接主界面 - 提供设备发现、连接管理和状态监控
public struct P2PConnectionView: View {
    
    // MARK: - 状态管理
    
    @StateObject private var networkManager = P2PNetworkManager.shared
    @StateObject private var securityManager = P2PSecurityManager()
    @State private var selectedDevice: P2PDevice?
    @State private var showingConnectionDetails = false
    @State private var showingSecuritySettings = false
    @State private var connectionPassword = ""
    @State private var isScanning = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    // 防止频繁刷新的状态管理
    @State private var lastRefreshTime = Date()
    @State private var refreshThrottleTimer: Timer?
    
    // MARK: - 主界面
    
    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部状态栏
                statusHeaderView
                
                // 设备列表
                deviceListView
                
                // 底部控制栏
                bottomControlsView
            }
            .navigationTitle("SkyBridge 远程连接")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingSecuritySettings = true }) {
                        Image(systemName: "shield.checkered")
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .sheet(isPresented: $showingConnectionDetails) {
            if let device = selectedDevice {
                ConnectionDetailsView(device: device)
            }
        }
        .sheet(isPresented: $showingSecuritySettings) {
            SecuritySettingsView(securityManager: securityManager)
        }
        .alert("连接提示", isPresented: $showingAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            startDeviceDiscovery()
        }
        .onDisappear {
            // 视图销毁时清理定时器，防止内存泄漏
            refreshThrottleTimer?.invalidate()
            refreshThrottleTimer = nil
        }
    }
    
    // MARK: - 状态头部视图
    
    private var statusHeaderView: some View {
        VStack(spacing: 12) {
            // 网络状态指示器
            HStack {
                Circle()
                    .fill(networkStatusColor)
                    .frame(width: 12, height: 12)
                    .animation(.easeInOut(duration: 0.5), value: networkManager.networkState)
                
                Text(networkStatusText)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                // 扫描按钮
                Button(action: toggleScanning) {
                    HStack(spacing: 6) {
                        Image(systemName: isScanning ? "stop.circle" : "magnifyingglass")
                        Text(isScanning ? "停止扫描" : "扫描设备")
                    }
                    .font(.subheadline)
                    .foregroundColor(.blue)
                }
            }
            
            // 连接统计信息
            HStack(spacing: 20) {
                StatisticView(
                    title: "发现设备",
                    value: "\(networkManager.discoveredDevices.count)",
                    icon: "antenna.radiowaves.left.and.right"
                )
                
                StatisticView(
                    title: "活跃连接",
                    value: "\(networkManager.activeConnections.count)",
                    icon: "link"
                )
                
                StatisticView(
                    title: "信任设备",
                    value: "\(securityManager.trustedDevices.count)",
                    icon: "checkmark.shield"
                )
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
    }
    
    // MARK: - 设备列表视图
    
    private var deviceListView: some View {
        List {
            // 附近设备部分
            Section("附近设备") {
                ForEach(networkManager.discoveredDevices, id: \.deviceId) { device in
                    DeviceRowView(
                        device: device,
                        isConnected: networkManager.isConnected(to: device.deviceId),
                        isTrusted: securityManager.isTrustedDevice(device.deviceId),
                        onConnect: { connectToDevice(device) },
                        onDisconnect: { disconnectFromDevice(device) },
                        onShowDetails: { showDeviceDetails(device) }
                    )
                }
            }
            
            // 历史连接部分
            if !networkManager.connectionHistory.isEmpty {
                Section("历史连接") {
                    ForEach(networkManager.connectionHistory.prefix(5), id: \.deviceId) { device in
                        HistoryDeviceRowView(
                            device: device,
                            onReconnect: { reconnectToDevice(device) }
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await refreshDeviceList()
        }
    }
    
    // MARK: - 底部控制栏
    
    private var bottomControlsView: some View {
        VStack(spacing: 12) {
            // 快速连接按钮
            HStack(spacing: 16) {
                Button(action: showQRCodeScanner) {
                    VStack(spacing: 4) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                        Text("扫码连接")
                            .font(.caption)
                    }
                    .foregroundColor(.blue)
                }
                
                Button(action: showManualConnection) {
                    VStack(spacing: 4) {
                        Image(systemName: "keyboard")
                            .font(.title2)
                        Text("手动连接")
                            .font(.caption)
                    }
                    .foregroundColor(.blue)
                }
                
                Button(action: showConnectionCode) {
                    VStack(spacing: 4) {
                        Image(systemName: "qrcode")
                            .font(.title2)
                        Text("我的连接码")
                            .font(.caption)
                    }
                    .foregroundColor(.blue)
                }
                
                Spacer()
                
                // 网络质量指示器
                NetworkQualityIndicator(quality: networkManager.networkQuality)
            }
            .padding(.horizontal)
            
            // 当前连接信息
            if let activeConnection = networkManager.activeConnections.first {
                ActiveConnectionBanner(connection: activeConnection.value)
            }
        }
        .padding(.vertical, 8)
        .background(Color.white)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(.gray.opacity(0.3)),
            alignment: .top
        )
    }
    
    // MARK: - 计算属性
    
    private var networkStatusColor: Color {
        switch networkManager.networkState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        case .discovering:
            return .blue
        case .idle:
            return .gray
        case .error:
            return .red
        }
    }
    
    private var networkStatusText: String {
        switch networkManager.networkState {
        case .connected:
            return "网络已连接"
        case .connecting:
            return "正在连接..."
        case .disconnected:
            return "网络未连接"
        case .discovering:
            return "正在扫描设备..."
        case .idle:
            return "空闲状态"
        case .error:
            return "网络错误"
        }
    }
    
    // MARK: - 方法实现
    
    private func startDeviceDiscovery() {
        Task {
            await networkManager.startDiscovery()
            isScanning = true
        }
    }
    
    private func toggleScanning() {
        if isScanning {
            networkManager.stopDiscovery()
            isScanning = false
        } else {
            Task {
                await networkManager.startDiscovery()
                isScanning = true
            }
        }
    }
    
    private func connectToDevice(_ device: P2PDevice) {
        networkManager.connectToDevice(device,
                                     connectionEstablished: {
                                         showAlert("连接成功", "已成功连接到 \(device.name)")
                                     },
                                     connectionFailed: { error in
                                         showAlert("连接失败", error.localizedDescription)
                                     })
    }
    
    private func disconnectFromDevice(_ device: P2PDevice) {
        networkManager.disconnectFromDevice(device.deviceId)
        showAlert("已断开连接", "已断开与 \(device.name) 的连接")
    }
    
    private func showDeviceDetails(_ device: P2PDevice) {
        selectedDevice = device
        showingConnectionDetails = true
    }
    
    private func reconnectToDevice(_ device: P2PDevice) {
        connectToDevice(device)
    }
    
    private func refreshDeviceList() async {
        // 防止频繁刷新，最少间隔2秒
        let now = Date()
        let timeSinceLastRefresh = now.timeIntervalSince(lastRefreshTime)
        
        if timeSinceLastRefresh < 2.0 {
            print("⚠️ 刷新过于频繁，跳过本次刷新")
            return
        }
        
        // 取消之前的定时器
        refreshThrottleTimer?.invalidate()
        
        // 设置新的定时器，延迟执行刷新
        refreshThrottleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            Task {
                await networkManager.refreshDiscovery()
                await MainActor.run {
                    lastRefreshTime = Date()
                }
            }
        }
    }
    
    private func showQRCodeScanner() {
        // TODO: 实现二维码扫描功能
        showAlert("功能开发中", "二维码扫描功能正在开发中")
    }
    
    private func showManualConnection() {
        // TODO: 实现手动连接功能
        showAlert("功能开发中", "手动连接功能正在开发中")
    }
    
    private func showConnectionCode() {
        // TODO: 实现连接码显示功能
        showAlert("功能开发中", "连接码功能正在开发中")
    }
    
    private func showAlert(_ title: String, _ message: String) {
        alertMessage = message
        showingAlert = true
    }
}

// MARK: - 统计信息视图

private struct StatisticView: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(value)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.blue)
            
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 设备行视图

private struct DeviceRowView: View {
    let device: P2PDevice
    let isConnected: Bool
    let isTrusted: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onShowDetails: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // 设备图标
            VStack {
                Image(systemName: deviceIcon)
                    .font(.title2)
                    .foregroundColor(deviceIconColor)
                
                if isTrusted {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
            .frame(width: 40)
            
            // 设备信息
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(device.deviceType.displayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    // 信号强度
                    SignalStrengthView(strength: device.signalStrength)
                    
                    // 连接状态
                    Text(isConnected ? "已连接" : "可连接")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isConnected ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                        .foregroundColor(isConnected ? .green : .blue)
                        .cornerRadius(4)
                }
            }
            
            Spacer()
            
            // 操作按钮
            VStack(spacing: 8) {
                Button(action: isConnected ? onDisconnect : onConnect) {
                    Image(systemName: isConnected ? "xmark.circle" : "play.circle")
                        .font(.title3)
                        .foregroundColor(isConnected ? .red : .green)
                }
                
                Button(action: onShowDetails) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onShowDetails()
        }
    }
    
    private var deviceIcon: String {
        switch device.deviceType {
        case .macOS:
            return "desktopcomputer"
        case .iOS:
            return "iphone"
        case .iPadOS:
            return "ipad"
        case .windows:
            return "pc"
        case .android:
            return "smartphone"
        case .linux:
            return "server.rack"
        }
    }
    
    private var deviceIconColor: Color {
        isConnected ? .green : .blue
    }
}

// MARK: - 历史设备行视图

private struct HistoryDeviceRowView: View {
    let device: P2PDevice
    let onReconnect: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.title3)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                
                Text("上次连接: \(formatLastConnection(device.lastSeen))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("重连") {
                onReconnect()
            }
            .font(.caption)
            .foregroundColor(.blue)
        }
        .padding(.vertical, 2)
    }
    
    private func formatLastConnection(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 信号强度视图

private struct SignalStrengthView: View {
    let strength: Double // 0.0 - 1.0
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { index in
                Rectangle()
                    .frame(width: 3, height: CGFloat(4 + index * 2))
                    .foregroundColor(barColor(for: index))
            }
        }
    }
    
    private func barColor(for index: Int) -> Color {
        let threshold = Double(index + 1) / 4.0
        if strength >= threshold {
            return strength > 0.7 ? .green : strength > 0.4 ? .orange : .red
        } else {
            return .gray.opacity(0.3)
        }
    }
}

// MARK: - 网络质量指示器

private struct NetworkQualityIndicator: View {
    let quality: P2PConnectionQuality
    
    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(qualityColor)
                .frame(width: 8, height: 8)
            
            Text(qualityText)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var qualityColor: Color {
        switch quality.qualityLevel {
        case .excellent:
            return .green
        case .good:
            return .blue
        case .fair:
            return .orange
        case .poor:
            return .red
        }
    }
    
    private var qualityText: String {
        switch quality.qualityLevel {
        case .excellent:
            return "优秀"
        case .good:
            return "良好"
        case .fair:
            return "一般"
        case .poor:
            return "较差"
        }
    }
}

// MARK: - 活跃连接横幅

private struct ActiveConnectionBanner: View {
    let connection: P2PConnection
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.circle.fill")
                .foregroundColor(.green)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("已连接到 \(connection.device.name)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("延迟: \(Int(connection.latency * 1000))ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("断开") {
                // TODO: 实现断开连接
            }
            .font(.caption)
            .foregroundColor(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
    }
}

// MARK: - 预览

#if DEBUG
struct P2PConnectionView_Previews: PreviewProvider {
    static var previews: some View {
        P2PConnectionView()
    }
}
#endif