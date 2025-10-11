import SwiftUI
import CryptoKit

/// 安全设置视图 - 管理设备信任、加密配置和安全策略
public struct SecuritySettingsView: View {
    
    // MARK: - 属性
    
    @ObservedObject var securityManager: P2PSecurityManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingTrustedDevices = true
    @State private var showingEncryptionSettings = false
    @State private var showingSecurityPolicies = false
    @State private var selectedDevice: P2PDevice?
    @State private var showingDeviceDetails = false
    
    // MARK: - 主界面
    
    public var body: some View {
        NavigationView {
            List {
                // 安全概览部分
                Section("安全概览") {
                    securityOverviewCard
                }
                
                // 信任设备部分
                Section("信任设备") {
                    trustedDevicesSection
                }
                
                // 加密设置部分
                Section("加密设置") {
                    encryptionSettingsSection
                }
                
                // 安全策略部分
                Section("安全策略") {
                    securityPoliciesSection
                }
                
                // 高级选项部分
                Section("高级选项") {
                    advancedOptionsSection
                }
            }
            .navigationTitle("安全设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button("重置") {
                        resetSecuritySettings()
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .sheet(isPresented: $showingDeviceDetails) {
            if let device = selectedDevice {
                TrustedDeviceDetailsView(device: device, securityManager: securityManager)
            }
        }
    }
    
    // MARK: - 安全概览卡片
    
    private var securityOverviewCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("安全状态")
                        .font(.headline)
                    
                    Text(securityStatusText)
                        .font(.subheadline)
                        .foregroundColor(securityStatusColor)
                }
                
                Spacer()
                
                Image(systemName: securityStatusIcon)
                    .font(.title)
                    .foregroundColor(securityStatusColor)
            }
            
            Divider()
            
            HStack(spacing: 20) {
                SecurityStatView(
                    title: "信任设备",
                    value: "\(securityManager.trustedDevices.count)",
                    icon: "checkmark.shield"
                )
                
                SecurityStatView(
                    title: "活跃连接",
                    value: "\(securityManager.activeSecureConnections.count)",
                    icon: "lock.shield"
                )
                
                SecurityStatView(
                    title: "证书状态",
                    value: certificateStatusText,
                    icon: "doc.badge.gearshape"
                )
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 信任设备部分
    
    private var trustedDevicesSection: some View {
        VStack(spacing: 8) {
            if securityManager.trustedDevices.isEmpty {
                HStack {
                    Image(systemName: "shield.slash")
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("暂无信任设备")
                            .font(.subheadline)
                        
                        Text("连接设备时可以选择添加信任")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                ForEach(Array(securityManager.trustedDevices), id: \.self) { (deviceId: String) in
                    TrustedDeviceIdRow(
                        deviceId: deviceId,
                        onShowDetails: { showTrustedDeviceDetails(deviceId) },
                        onRemoveTrust: { removeTrust(for: deviceId) }
                    )
                }
            }
            
            Button(action: showTrustManagement) {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("管理信任设备")
                }
                .foregroundColor(.blue)
            }
        }
    }
    
    // MARK: - 加密设置部分
    
    private var encryptionSettingsSection: some View {
        Group {
            EncryptionSettingRow(
                title: "TLS版本",
                value: "TLS 1.3",
                description: "使用最新的TLS 1.3协议确保通信安全",
                isEnabled: true
            )
            
            EncryptionSettingRow(
                title: "端到端加密",
                value: "AES-256-GCM",
                description: "使用AES-256-GCM算法进行端到端加密",
                isEnabled: true
            )
            
            EncryptionSettingRow(
                title: "密钥交换",
                value: "ECDH P-256",
                description: "使用椭圆曲线Diffie-Hellman进行密钥交换",
                isEnabled: true
            )
            
            Button(action: regenerateKeys) {
                HStack {
                    Image(systemName: "key")
                    Text("重新生成密钥")
                }
                .foregroundColor(.blue)
            }
        }
    }
    
    // MARK: - 安全策略部分
    
    private var securityPoliciesSection: some View {
        Group {
            SecurityPolicyRow(
                title: "自动信任",
                description: "自动信任同一网络下的已知设备",
                isEnabled: .constant(false)
            )
            
            SecurityPolicyRow(
                title: "证书验证",
                description: "严格验证设备证书的有效性",
                isEnabled: .constant(true)
            )
            
            SecurityPolicyRow(
                title: "连接超时",
                description: "设置连接超时时间以防止恶意连接",
                isEnabled: .constant(true)
            )
            
            SecurityPolicyRow(
                title: "数据完整性检查",
                description: "验证传输数据的完整性和真实性",
                isEnabled: .constant(true)
            )
        }
    }
    
    // MARK: - 高级选项部分
    
    private var advancedOptionsSection: some View {
        Group {
            Button(action: exportSecurityLogs) {
                HStack {
                    Image(systemName: "doc.text")
                    Text("导出安全日志")
                }
                .foregroundColor(.blue)
            }
            
            Button(action: clearSecurityCache) {
                HStack {
                    Image(systemName: "trash")
                    Text("清除安全缓存")
                }
                .foregroundColor(.orange)
            }
            
            Button(action: resetAllSecurity) {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text("重置所有安全设置")
                }
                .foregroundColor(.red)
            }
        }
    }
    
    // MARK: - 计算属性
    
    private var securityStatusText: String {
        if securityManager.trustedDevices.isEmpty {
            return "需要配置信任设备"
        } else if securityManager.hasValidCertificates {
            return "安全配置正常"
        } else {
            return "证书需要更新"
        }
    }
    
    private var securityStatusColor: Color {
        if securityManager.trustedDevices.isEmpty {
            return .orange
        } else if securityManager.hasValidCertificates {
            return .green
        } else {
            return .red
        }
    }
    
    private var securityStatusIcon: String {
        if securityManager.trustedDevices.isEmpty {
            return "shield.slash"
        } else if securityManager.hasValidCertificates {
            return "shield.checkered"
        } else {
            return "shield.slash.fill"
        }
    }
    
    private var certificateStatusText: String {
        securityManager.hasValidCertificates ? "有效" : "过期"
    }
    
    // MARK: - 方法实现
    
    private func showTrustedDeviceDetails(_ deviceId: String) {
        // 根据deviceId创建模拟设备对象用于显示详情
        let mockDevice = P2PDevice(
            id: deviceId,
            name: "信任设备",
            type: .macOS,
            address: "未知",
            port: 0,
            osVersion: "未知",
            capabilities: [],
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: []
        )
        selectedDevice = mockDevice
        showingDeviceDetails = true
    }
    
    private func removeTrust(for deviceId: String) {
        securityManager.removeTrustedDevice(deviceId)
    }
    
    private func showTrustManagement() {
        // TODO: 实现信任管理界面
    }
    
    private func regenerateKeys() {
        Task {
            await securityManager.regenerateKeys()
        }
    }
    
    private func exportSecurityLogs() {
        // TODO: 实现安全日志导出
    }
    
    private func clearSecurityCache() {
        securityManager.clearSecurityCache()
    }
    
    private func resetAllSecurity() {
        securityManager.resetAllSecuritySettings()
    }
    
    private func resetSecuritySettings() {
        resetAllSecurity()
    }
}

// MARK: - 安全统计视图

private struct SecurityStatView: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.blue)
            
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
            
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 信任设备行视图（基于设备ID）

private struct TrustedDeviceIdRow: View {
    let deviceId: String
    let onShowDetails: () -> Void
    let onRemoveTrust: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundColor(.green)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("信任设备")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("设备ID: \(deviceId.prefix(8))...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Menu {
                Button("查看详情", action: onShowDetails)
                Button("移除信任", role: .destructive, action: onRemoveTrust)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 信任设备行视图

private struct TrustedDeviceRow: View {
    let device: P2PDevice
    let onShowDetails: () -> Void
    let onRemoveTrust: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceIcon)
                .font(.title3)
                .foregroundColor(.green)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("信任时间: \(formatTrustDate(device.trustedDate))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Menu {
                Button("查看详情", action: onShowDetails)
                Button("移除信任", role: .destructive, action: onRemoveTrust)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 2)
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
    
    private func formatTrustDate(_ date: Date?) -> String {
        guard let date = date else { return "未知" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 加密设置行视图

private struct EncryptionSettingRow: View {
    let title: String
    let value: String
    let description: String
    let isEnabled: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text(value)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isEnabled ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                    .foregroundColor(isEnabled ? .green : .gray)
                    .cornerRadius(4)
            }
            
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 安全策略行视图

private struct SecurityPolicyRow: View {
    let title: String
    let description: String
    @Binding var isEnabled: Bool
    
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
                
                Toggle("", isOn: $isEnabled)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 信任设备详情视图

private struct TrustedDeviceDetailsView: View {
    let device: P2PDevice
    let securityManager: P2PSecurityManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                Text("设备详情开发中...")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("设备详情")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 预览

#if DEBUG
struct SecuritySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SecuritySettingsView(securityManager: P2PSecurityManager())
    }
}
#endif