import SwiftUI
import Network

/// 连接详情视图 - 显示设备详细信息、连接状态和操作选项
public struct ConnectionDetailsView: View {
    
    // MARK: - 属性
    
    let device: P2PDevice
    @StateObject private var networkManager = P2PNetworkManager.shared
    @StateObject private var securityManager = P2PSecurityManager()
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingSecurityOptions = false
    @State private var showingAdvancedSettings = false
    @State private var isConnecting = false
    @State private var connectionError: String?
    
    // MARK: - 主界面
    
    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 设备信息卡片
                    deviceInfoCard
                    
                    // 连接状态卡片
                    connectionStatusCard
                    
                    // 安全信息卡片
                    securityInfoCard
                    
                    // 操作按钮
                    actionButtons
                    
                    // 高级设置
                    if showingAdvancedSettings {
                        advancedSettingsCard
                    }
                }
                .padding()
            }
            .navigationTitle("设备详情")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button("高级") {
                        showingAdvancedSettings.toggle()
                    }
                }
            }
        }
        .alert("连接错误", isPresented: .constant(connectionError != nil)) {
            Button("确定") {
                connectionError = nil
            }
        } message: {
            if let error = connectionError {
                Text(error)
            }
        }
    }
    
    // MARK: - 设备信息卡片
    
    private var deviceInfoCard: some View {
        VStack(spacing: 16) {
            // 设备图标和名称
            VStack(spacing: 8) {
                Image(systemName: deviceIcon)
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
                
                Text(device.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(device.deviceType.displayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // 设备详细信息
            VStack(spacing: 12) {
                InfoRow(title: "设备ID", value: device.deviceId)
                InfoRow(title: "IP地址", value: device.address)
                InfoRow(title: "端口", value: "\(device.port)")
                InfoRow(title: "系统版本", value: device.osVersion)
                InfoRow(title: "应用版本", value: device.capabilities.joined(separator: ", "))
                InfoRow(title: "上次连接", value: formatDate(device.lastSeen))
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - 连接状态卡片
    
    private var connectionStatusCard: some View {
        VStack(spacing: 16) {
            HStack {
                Text("连接状态")
                    .font(.headline)
                
                Spacer()
                
                connectionStatusBadge
            }
            
            if isConnected {
                // 连接质量信息
                VStack(spacing: 8) {
                    HStack {
                        Text("连接质量")
                        Spacer()
                        connectionQualityView
                    }
                    
                    if let connection = currentConnection {
                        HStack {
                            Text("延迟")
                            Spacer()
                            Text("\(Int(connection.latency * 1000))ms")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("带宽")
                            Spacer()
                            Text(formatBandwidth(connection.bandwidth))
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("数据传输")
                            Spacer()
                            Text("\(formatDataSize(Int64(connection.bytesReceived))) / \(formatDataSize(Int64(connection.bytesSent)))")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - 安全信息卡片
    
    private var securityInfoCard: some View {
        VStack(spacing: 16) {
            HStack {
                Text("安全信息")
                    .font(.headline)
                
                Spacer()
                
                securityStatusBadge
            }
            
            VStack(spacing: 8) {
                HStack {
                    Text("设备信任状态")
                    Spacer()
                    Text(isTrusted ? "已信任" : "未信任")
                        .foregroundColor(isTrusted ? .green : .orange)
                }
                
                HStack {
                    Text("加密状态")
                    Spacer()
                    Text("TLS 1.3")
                        .foregroundColor(.green)
                }
                
                HStack {
                    Text("证书验证")
                    Spacer()
                    Text(hasValidCertificate ? "已验证" : "未验证")
                        .foregroundColor(hasValidCertificate ? .green : .red)
                }
                
                if isTrusted {
                    HStack {
                        Text("信任时间")
                        Spacer()
                        Text(formatDate(device.trustedDate ?? Date()))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - 操作按钮
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if isConnected {
                // 已连接状态的按钮
                HStack(spacing: 12) {
                    Button(action: disconnectDevice) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("断开连接")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    
                    Button(action: showFileTransfer) {
                        HStack {
                            Image(systemName: "folder")
                            Text("文件传输")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                
                Button(action: showRemoteControl) {
                    HStack {
                        Image(systemName: "display")
                        Text("远程控制")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            } else {
                // 未连接状态的按钮
                Button(action: connectDevice) {
                    HStack {
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "play.circle")
                        }
                        Text(isConnecting ? "正在连接..." : "连接设备")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isConnecting ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(isConnecting)
            }
            
            // 安全操作按钮
            HStack(spacing: 12) {
                if isTrusted {
                    Button(action: removeTrust) {
                        HStack {
                            Image(systemName: "shield.slash")
                            Text("移除信任")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                } else {
                    Button(action: addTrust) {
                        HStack {
                            Image(systemName: "shield.checkered")
                            Text("添加信任")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                
                Button(action: { showingSecurityOptions = true }) {
                    HStack {
                        Image(systemName: "gear")
                        Text("安全设置")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
        }
        .sheet(isPresented: $showingSecurityOptions) {
            SecurityOptionsView(device: device, securityManager: securityManager)
        }
    }
    
    // MARK: - 高级设置卡片
    
    private var advancedSettingsCard: some View {
        VStack(spacing: 16) {
            HStack {
                Text("高级设置")
                    .font(.headline)
                Spacer()
            }
            
            VStack(spacing: 12) {
                SettingRow(
                    title: "自动重连",
                    description: "连接断开时自动尝试重连",
                    isOn: .constant(true)
                )
                
                SettingRow(
                    title: "数据压缩",
                    description: "启用数据传输压缩以节省带宽",
                    isOn: .constant(false)
                )
                
                SettingRow(
                    title: "低延迟模式",
                    description: "优化网络设置以降低延迟",
                    isOn: .constant(true)
                )
                
                Button("重置连接设置") {
                    resetConnectionSettings()
                }
                .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - 计算属性
    
    private var deviceIcon: String {
        switch device.deviceType {
        case .macOS:
            return "desktopcomputer"
        case .iOS:
            return "iphone"
        case .iPadOS:
            return "ipad"
        case .android:
            return "smartphone"
        case .windows:
            return "pc"
        case .linux:
            return "server.rack"
        }
    }
    
    private var isConnected: Bool {
        networkManager.isConnected(to: device.deviceId)
    }
    
    private var isTrusted: Bool {
        securityManager.isTrustedDevice(device.deviceId)
    }
    
    private var hasValidCertificate: Bool {
        securityManager.hasValidCertificates
    }
    
    private var currentConnection: P2PConnection? {
        networkManager.activeConnections[device.deviceId]
    }
    
    private var connectionStatusBadge: some View {
        Text(isConnected ? "已连接" : "未连接")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isConnected ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
            .foregroundColor(isConnected ? .green : .gray)
            .cornerRadius(6)
    }
    
    private var securityStatusBadge: some View {
        Text(isTrusted ? "安全" : "未验证")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isTrusted ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
            .foregroundColor(isTrusted ? .green : .orange)
            .cornerRadius(6)
    }
    
    private var connectionQualityView: some View {
        HStack(spacing: 4) {
            if let connection = currentConnection {
                ForEach(0..<5) { index in
                    Circle()
                        .frame(width: 6, height: 6)
                        .foregroundColor(qualityColor(for: index, quality: connection.quality))
                }
            }
        }
    }
    
    // MARK: - 方法实现
    
    private func connectDevice() {
        isConnecting = true
        connectionError = nil
        
        Task {
            networkManager.connectToDevice(device,
                connectionEstablished: {
                    Task { @MainActor in
                        isConnecting = false
                    }
                },
                connectionFailed: { error in
                    Task { @MainActor in
                        isConnecting = false
                        connectionError = error.localizedDescription
                    }
                }
            )
        }
    }
    
    private func disconnectDevice() {
        networkManager.disconnectFromDevice(device.deviceId)
    }
    
    private func addTrust() {
        securityManager.addTrustedDevice(device.deviceId)
    }
    
    private func removeTrust() {
        securityManager.removeTrustedDevice(device.deviceId)
    }
    
    private func showFileTransfer() {
        // TODO: 实现文件传输界面
    }
    
    private func showRemoteControl() {
        // TODO: 实现远程控制界面
    }
    
    private func resetConnectionSettings() {
        // TODO: 实现重置连接设置
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatBandwidth(_ bandwidth: Double) -> String {
        if bandwidth > 1_000_000 {
            return String(format: "%.1f MB/s", bandwidth / 1_000_000)
        } else if bandwidth > 1_000 {
            return String(format: "%.1f KB/s", bandwidth / 1_000)
        } else {
            return String(format: "%.0f B/s", bandwidth)
        }
    }
    
    private func formatDataSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
    
    private func qualityColor(for index: Int, quality: P2PConnectionQuality) -> Color {
        let level = Int(Double(quality.stabilityScore) / 20.0) // 将0-100的稳定性评分转换为0-5的等级
        return index < level ? .green : .gray.opacity(0.3)
    }
}

// MARK: - 信息行视图

private struct InfoRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }
}

// MARK: - 设置行视图

private struct SettingRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Toggle("", isOn: $isOn)
            }
        }
    }
}

// MARK: - 安全选项视图

private struct SecurityOptionsView: View {
    let device: P2PDevice
    let securityManager: P2PSecurityManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                Text("安全选项开发中...")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("安全选项")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 预览

#if DEBUG
struct ConnectionDetailsView_Previews: PreviewProvider {
    static var previews: some View {
        ConnectionDetailsView(device: P2PDevice.mockDevice)
    }
}
#endif