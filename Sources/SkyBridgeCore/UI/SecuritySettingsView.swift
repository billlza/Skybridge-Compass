import SwiftUI
import CryptoKit
import os.log
import AppKit
import UniformTypeIdentifiers

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
    @State private var showingTrustManagement = false
    
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "SecuritySettingsView")
    
 // MARK: - 主界面
    
    public var body: some View {
        NavigationView {
            List {
 // 安全概览部分
                Section("安全概览") {
                    securityOverviewCard
                }

 // API密钥管理部分
                Section("API密钥管理") {
                    NavigationLink(destination: APIKeyManagementView()) {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundColor(.blue)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("管理API密钥")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text("安全管理所有服务的API密钥和配置")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                        }
                    }
                }
                
 // 信任设备部分
                Section("信任设备") {
                    trustedDevicesSection
                }
                
 // 加密设置部分
                Section("加密设置") {
                    encryptionSettingsSection
                }

 // 证书管理部分（PKCS#12 导入、CSR 生成/提交/轮询、自签证书）
                Section("证书管理") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("设备标识（用于证书标签/私钥应用标签）")
                        TextField("Device ID", text: $certDeviceId)

                        HStack {
                            Button("导入 PKCS#12 身份") {
                                importPKCS12()
                            }
                            .buttonStyle(.bordered)
                            SecureField("PKCS#12 密码", text: $p12Password)
                        }

                        Divider()
                        Text("生成 CSR (CN/O/OU/SAN)")
                        TextField("CN", text: $csrCN)
                        TextField("O", text: $csrO)
                        TextField("OU", text: $csrOU)
                        TextField("SAN DNS (逗号分隔)", text: $csrSanDNS)
                        TextField("SAN IP (逗号分隔)", text: $csrSanIP)

                        HStack {
                            Button("生成 CSR 并显示 PEM") { generateCSR() }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button("提交 CSR 到 CA") { submitCSR() }
                            .buttonStyle(.borderedProminent)
                        }
                        TextField("CA 提交/轮询端点 URL", text: $caEndpoint)
                        HStack {
                            Button("轮询签发状态") { pollCertificate() }
                            .buttonStyle(.bordered)
                            Text("请求ID: \(lastCSRRequestId)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text("CSR PEM 预览：")
                        TextEditor(text: $csrPEM)
                            .frame(minHeight: 120)
                            .font(.system(.caption))

                        Divider()
                        HStack {
                            Button("导入已签发证书(PEM)") { importIssuedCertificate() }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button("生成自签证书") { generateSelfSigned() }
                            .buttonStyle(.borderedProminent)
                        }
                        TextEditor(text: $issuedCertPEM)
                            .frame(minHeight: 80)
                            .font(.system(.caption))
                        Text(certStatusMessage)
                            .foregroundColor(.secondary)
                    }
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

 // 证书管理状态
    @State private var certDeviceId: String = ""
    @State private var p12Password: String = ""
    @State private var csrCN: String = ""
    @State private var csrO: String = ""
    @State private var csrOU: String = ""
    @State private var csrSanDNS: String = ""
    @State private var csrSanIP: String = ""
    @State private var csrPEM: String = ""
    @State private var caEndpoint: String = ""
    @State private var lastCSRRequestId: String = ""
    @State private var issuedCertPEM: String = ""
    @State private var certStatusMessage: String = ""

 // 从文件选择并导入 PKCS#12
    private func importPKCS12() {
        let panel = NSOpenPanel()
        if let t1 = UTType(filenameExtension: "p12"), let t2 = UTType(filenameExtension: "pfx") {
            panel.allowedContentTypes = [t1, t2]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            Task { @MainActor in
                let ok = TLSSecurityManager().importIdentityFromPKCS12(data, password: p12Password, for: certDeviceId)
                certStatusMessage = ok ? "✅ PKCS#12 身份已导入" : "❌ PKCS#12 导入失败"
            }
        }
    }

 // 生成 CSR 并显示 PEM
    private func generateCSR() {
        Task { @MainActor in
            let dns = csrSanDNS.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let ip = csrSanIP.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            if let pem = TLSSecurityManager().generateCSRPEM(for: certDeviceId, commonName: csrCN, organization: csrO.isEmpty ? nil : csrO, organizationalUnit: csrOU.isEmpty ? nil : csrOU, sanDNS: dns, sanIP: ip) {
                csrPEM = pem
                certStatusMessage = "✅ CSR 已生成"
            } else {
                certStatusMessage = "❌ CSR 生成失败（请先导入身份或生成自签证书）"
            }
        }
    }

 // 提交 CSR 到 CA
    private func submitCSR() {
        Task {
            guard let url = URL(string: caEndpoint), !csrPEM.isEmpty else { await MainActor.run { certStatusMessage = "❌ 缺少端点或CSR" }; return }
            do {
                let id = try await CAServiceManager().submitCSR(csrPEM, to: url)
                await MainActor.run { lastCSRRequestId = id; certStatusMessage = "✅ CSR 已提交，requestId=\(id)" }
            } catch {
                await MainActor.run { certStatusMessage = "❌ CSR 提交失败：\(error.localizedDescription)" }
            }
        }
    }

 // 轮询签发状态
    private func pollCertificate() {
        Task {
            guard let url = URL(string: caEndpoint), !lastCSRRequestId.isEmpty else { await MainActor.run { certStatusMessage = "❌ 缺少端点或请求ID" }; return }
            do {
                let (issued, pem) = try await CAServiceManager().pollCertificateStatus(requestId: lastCSRRequestId, from: url)
                await MainActor.run {
                    if issued, let pem = pem {
                        issuedCertPEM = pem
                        certStatusMessage = "✅ 证书已签发"
                    } else {
                        certStatusMessage = "⌛ 尚未签发"
                    }
                }
            } catch {
                await MainActor.run { certStatusMessage = "❌ 轮询失败：\(error.localizedDescription)" }
            }
        }
    }

 // 导入已签发证书（PEM）
    private func importIssuedCertificate() {
        Task { @MainActor in
            guard !issuedCertPEM.isEmpty else { certStatusMessage = "❌ PEM 内容为空"; return }
            let ok = CAServiceManager().importIssuedCertificate(issuedCertPEM, for: certDeviceId)
            certStatusMessage = ok ? "✅ 已导入证书" : "❌ 导入失败"
        }
    }

 // 生成自签证书
    private func generateSelfSigned() {
        Task { @MainActor in
            let cert = TLSSecurityManager().generateSelfSignedCertificate(for: certDeviceId)
            certStatusMessage = (cert != nil) ? "✅ 自签证书已生成" : "❌ 自签生成失败"
        }
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
            .sheet(isPresented: $showingTrustManagement) {
                TrustManagementView(securityManager: securityManager)
                    .frame(minWidth: 560, minHeight: 420)
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
            
            Divider()
            
 // 后量子密码学设置
            PostQuantumCryptoSettingsView()
            
            Divider()
            
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
                isEnabled: Binding(
                    get: { securityManager.policyAutoTrustEnabled },
                    set: { newValue in
                        securityManager.updatePolicies(autoTrust: newValue)
                    }
                )
            )
            
            SecurityPolicyRow(
                title: "证书验证",
                description: "严格验证设备证书的有效性",
                isEnabled: Binding(
                    get: { securityManager.policyStrictCertificateValidation },
                    set: { newValue in
                        securityManager.updatePolicies(strictCert: newValue)
                    }
                )
            )
            
            SecurityPolicyRow(
                title: "连接超时",
                description: "设置连接超时时间以防止恶意连接",
                isEnabled: Binding(
                    get: { securityManager.policyConnectionTimeoutEnabled },
                    set: { newValue in
                        securityManager.updatePolicies(connTimeout: newValue)
                    }
                )
            )
            
            SecurityPolicyRow(
                title: "数据完整性检查",
                description: "验证传输数据的完整性和真实性",
                isEnabled: Binding(
                    get: { securityManager.policyDataIntegrityCheckEnabled },
                    set: { newValue in
                        securityManager.updatePolicies(dataIntegrity: newValue)
                    }
                )
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
        showingTrustManagement = true
    }
    
    private func regenerateKeys() {
        Task {
            do {
                try await securityManager.regenerateKeys()
            } catch {
                SkyBridgeLogger.ui.error("❌ 重新生成密钥失败: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
    
    private func exportSecurityLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SecurityReport.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let report = buildSecurityReport()
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
                try data.write(to: url)
            } catch {
                SkyBridgeLogger.ui.error("导出安全日志失败: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
    
    private func clearSecurityCache() {
        securityManager.clearSecurityCache()
    }
    
    private func resetAllSecurity() {
        Task { @MainActor in
            securityManager.resetAllSecuritySettings()
        }
    }
    
    private func resetSecuritySettings() {
        resetAllSecurity()
    }
}

// MARK: - 信任管理视图

private struct TrustManagementView: View {
    @ObservedObject var securityManager: P2PSecurityManager
    @Environment(\.dismiss) private var dismiss
    @State private var newDeviceId: String = ""
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("信任设备列表")
                        .font(.headline)
                    Spacer()
                }
                
                if securityManager.trustedDevices.isEmpty {
                    Text("暂无信任设备")
                        .foregroundColor(.secondary)
                } else {
                    List(Array(securityManager.trustedDevices), id: \.self) { deviceId in
                        HStack {
                            Text(deviceId)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button("移除") {
                                securityManager.removeTrustedDevice(deviceId)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                
                Divider()
                
                HStack(spacing: 12) {
                    TextField("输入设备ID以添加信任…", text: $newDeviceId)
                        .textFieldStyle(.roundedBorder)
                    Button("添加信任") {
                        let trimmed = newDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        securityManager.addTrustedDevice(trimmed)
                        newDeviceId = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("信任管理")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 安全报告生成

private extension SecuritySettingsView {
    func buildSecurityReport() -> [String: Any] {
        var report: [String: Any] = [:]
        report["timestamp"] = ISO8601DateFormatter().string(from: Date())
        report["trustedDevicesCount"] = securityManager.trustedDevices.count
        report["trustedDevices"] = Array(securityManager.trustedDevices)
        report["activeSecureConnectionsCount"] = securityManager.activeSecureConnections.count
        report["activeSecureConnections"] = Array(securityManager.activeSecureConnections)
        report["policies"] = [
            "autoTrustEnabled": securityManager.policyAutoTrustEnabled,
            "strictCertificateValidation": securityManager.policyStrictCertificateValidation,
            "connectionTimeoutEnabled": securityManager.policyConnectionTimeoutEnabled,
            "dataIntegrityCheckEnabled": securityManager.policyDataIntegrityCheckEnabled
        ]
        return report
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

// MARK: - 后量子密码学设置视图

struct PostQuantumCryptoSettingsView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @State private var showingInfo = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
 // PQC标题和说明
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("后量子密码学（PQC）")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        Image(systemName: "atom")
                            .font(.caption)
                            .foregroundColor(.purple)
                    }
                    
                    Text("抵御未来量子计算机攻击的加密技术")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { showingInfo.toggle() }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                }
                .popover(isPresented: $showingInfo) {
                    PQCInfoView()
                        .frame(width: 400, height: 300)
                }
            }
            
 // PQC启用开关
            Toggle(isOn: $settingsManager.enablePQC) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("启用后量子加密")
                        .font(.subheadline)
                    
                    Text(settingsManager.enablePQC ? 
                         "混合模式：P256 + ML-DSA" : 
                         "仅使用传统加密")
                        .font(.caption)
                        .foregroundColor(settingsManager.enablePQC ? .green : .secondary)
                }
            }
            .padding(.vertical, 4)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("• macOS 26+: CryptoKit（含 Secure Enclave PQC）")
                Text("• macOS 14–15: liboqs（ML‑KEM‑768/ML‑DSA‑65）")
                Text("• OQS 不可用: Classic（X25519/Ed25519）")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            
 // 算法选择（仅在启用PQC时显示）
            if settingsManager.enablePQC {
                VStack(alignment: .leading, spacing: 8) {
                    Text("签名算法")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $settingsManager.pqcSignatureAlgorithm) {
                        Text("ML-DSA-65 (推荐)").tag("ML-DSA-65")
                        Text("ML-DSA-87 (高安全)").tag("ML-DSA-87")
                    }
                    .pickerStyle(.segmented)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.blue)
                        
                        Text(algorithmDescription)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }
            
 // 状态指示器
            HStack(spacing: 8) {
                Image(systemName: pqcStatusIcon)
                    .font(.caption)
                    .foregroundColor(pqcStatusColor)
                
                Text(pqcStatusText)
                    .font(.caption)
                    .foregroundColor(pqcStatusColor)
            }
            .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
    }
    
    private var algorithmDescription: String {
        switch settingsManager.pqcSignatureAlgorithm {
        case "ML-DSA-65":
            return "NIST Level 2 安全级别，签名约3.3KB，适合大多数场景"
        case "ML-DSA-87":
            return "NIST Level 4 安全级别，签名约4.6KB，提供更高安全性"
        default:
            return "选择合适的后量子签名算法"
        }
    }
    
    private var pqcStatusIcon: String {
        if !settingsManager.enablePQC {
            return "circle"
        }
        
        if #available(macOS 26.0, *) {
 // macOS 26.0+ Apple原生PQC
            return "apple.logo"
        } else {
            #if canImport(OQSRAII)
            return "checkmark.circle.fill"
            #else
            return "exclamationmark.triangle.fill"
            #endif
        }
    }
    
    private var pqcStatusColor: Color {
        if !settingsManager.enablePQC {
            return .gray
        }
        
        if #available(macOS 26.0, *) {
 // macOS 26.0+ Apple原生PQC
            return .blue  // Apple蓝色
        } else {
            #if canImport(OQSRAII)
            return .green
            #else
            return .orange
            #endif
        }
    }
    
    private var pqcStatusText: String {
        if !settingsManager.enablePQC {
            return "未启用"
        }
        
        if #available(macOS 26.0, *) {
 // macOS 26.0+ 使用Apple原生PQC
            return "Apple CryptoKit (原生)"
        } else {
            #if canImport(OQSRAII)
            return "OQS/liboqs"
            #else
            return "PQC库未安装"
            #endif
        }
    }
}

// MARK: - PQC信息视图

struct PQCInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("后量子密码学")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    InfoSection(
                        title: "什么是PQC？",
                        icon: "atom",
                        color: .purple,
                        content: "后量子密码学（Post-Quantum Cryptography）是指能够抵御量子计算机攻击的加密算法。未来的量子计算机可能破解现有的RSA和ECC加密。"
                    )
                    
                    InfoSection(
                        title: "混合加密模式",
                        icon: "shield.lefthalf.filled",
                        color: .blue,
                        content: "SkyBridge使用混合模式：同时使用传统加密（P256）和后量子加密（ML-DSA）。只有两者都被破解才会失去安全性。"
                    )
                    
                    InfoSection(
                        title: "支持的算法",
                        icon: "cpu",
                        color: .green,
                        content: "• ML-DSA-65: NIST Level 2，平衡安全性和性能\n• ML-DSA-87: NIST Level 4，提供更高安全级别\n• ML-KEM: 用于密钥封装机制"
                    )
                    
                    InfoSection(
                        title: "性能影响",
                        icon: "gauge",
                        color: .orange,
                        content: "PQC签名比传统签名慢约5倍，签名大小增加约50倍。适合中等频率的安全操作。"
                    )
                    
                    InfoSection(
                        title: "何时启用？",
                        icon: "questionmark.circle",
                        color: .purple,
                        content: "推荐在需要长期安全保护的场景中启用PQC，如：敏感数据传输、长期存档、高安全性要求的通信。"
                    )
                }
            }
            .padding()
        }
    }
}

struct InfoSection: View {
    let title: String
    let icon: String
    let color: Color
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(color)
                
                Text(title)
                    .font(.headline)
            }
            
            Text(content)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
