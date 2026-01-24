import SwiftUI

// MARK: - 发现诊断面板视图
/// 展示设备发现相关的诊断信息，帮助用户排查问题
@available(macOS 14.0, iOS 17.0, *)
public struct DiscoveryDiagnosticsView: View {
    
    @StateObject private var diagnosticsService = DiscoveryDiagnosticsService.shared
    @State private var showingFailureDetails: DiscoveryDiagnosticsService.DiscoveryFailure?
    @State private var isExpanded = true
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题栏
            headerSection
            
            if isExpanded {
                // 权限与配置状态
                permissionSection
                
                Divider()
                
                // 网络状态
                networkSection
                
                Divider()
                
                // 扫描状态
                scanningSection
                
                // 最近失败记录
                if !diagnosticsService.recentFailures.isEmpty {
                    Divider()
                    failuresSection
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(PlatformColor.controlBackground)
                .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
        )
        .task {
            await diagnosticsService.runDiagnostics()
        }
    }
    
    // MARK: - 子视图
    
    private var headerSection: some View {
        HStack {
            Image(systemName: "stethoscope")
                .font(.title2)
                .foregroundStyle(.blue)
            
            Text("发现诊断")
                .font(.headline)
            
            Spacer()
            
            if diagnosticsService.isRunningDiagnostics {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(action: {
                    Task {
                        await diagnosticsService.runDiagnostics()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新诊断")
            }
            
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
        }
    }
    
    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("权限与配置", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 16) {
                // 本地网络权限
                statusCard(
                    title: "本地网络",
                    status: diagnosticsService.diagnostics.localNetworkPermission.rawValue,
                    emoji: diagnosticsService.diagnostics.localNetworkPermission.emoji,
                    color: colorForPermission(diagnosticsService.diagnostics.localNetworkPermission)
                )
                
                // Bonjour 配置
                let bonjourStatus = diagnosticsService.diagnostics.bonjourWhitelist
                statusCard(
                    title: "Bonjour 白名单",
                    status: bonjourStatus.isConfigured ? "已配置" : "不完整",
                    emoji: bonjourStatus.isConfigured ? "✅" : "⚠️",
                    color: bonjourStatus.isConfigured ? .green : .orange
                )
            }
            
            // 显示缺失的服务
            if !diagnosticsService.diagnostics.bonjourWhitelist.missingServices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("缺失的 Bonjour 服务声明：")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    
                    ForEach(diagnosticsService.diagnostics.bonjourWhitelist.missingServices.prefix(3), id: \.self) { service in
                        Text("• \(service)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    if diagnosticsService.diagnostics.bonjourWhitelist.missingServices.count > 3 {
                        Text("... 还有 \(diagnosticsService.diagnostics.bonjourWhitelist.missingServices.count - 3) 个")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }
    
    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("网络状态", systemImage: "network")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 16) {
                let network = diagnosticsService.diagnostics.networkStatus
                
                // 连接状态
                statusCard(
                    title: "连接",
                    status: network.hasConnectivity ? network.connectionType.rawValue : "无连接",
                    emoji: network.hasConnectivity ? "📶" : "📵",
                    color: network.hasConnectivity ? .green : .red
                )
                
                // 本地网络
                statusCard(
                    title: "本地发现",
                    status: network.isOnLocalNetwork ? "可用" : "不可用",
                    emoji: network.isOnLocalNetwork ? "🏠" : "🌐",
                    color: network.isOnLocalNetwork ? .green : .orange
                )
                
                // IP 地址
                if let ip = network.localIPAddress {
                    statusCard(
                        title: "本地 IP",
                        status: ip,
                        emoji: "🔢",
                        color: .blue
                    )
                }
            }
        }
    }
    
    private var scanningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("扫描状态", systemImage: "antenna.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 16) {
                // 发现的设备
                statusCard(
                    title: "已发现设备",
                    status: "\(diagnosticsService.diagnostics.discoveredDeviceCount)",
                    emoji: "📱",
                    color: .blue
                )
                
                // 扫描服务
                statusCard(
                    title: "扫描服务",
                    status: "\(diagnosticsService.diagnostics.activeServiceTypes.count) 个",
                    emoji: "🔍",
                    color: .purple
                )
                
                // 上次扫描
                if let lastScan = diagnosticsService.diagnostics.lastScanTime {
                    statusCard(
                        title: "上次扫描",
                        status: formatTimeAgo(lastScan),
                        emoji: "🕐",
                        color: .gray
                    )
                }
            }
            
            // 活跃服务类型
            if !diagnosticsService.diagnostics.activeServiceTypes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(diagnosticsService.diagnostics.activeServiceTypes, id: \.self) { service in
                            Text(service.replacingOccurrences(of: "._tcp.", with: ""))
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
            }
        }
    }
    
    private var failuresSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("最近失败记录", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("清除") {
                    diagnosticsService.clearFailureHistory()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            
            ForEach(diagnosticsService.recentFailures.prefix(5)) { failure in
                failureRow(failure)
            }
            
            if diagnosticsService.recentFailures.count > 5 {
                Text("还有 \(diagnosticsService.recentFailures.count - 5) 条记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func failureRow(_ failure: DiscoveryDiagnosticsService.DiscoveryFailure) -> some View {
        Button(action: { showingFailureDetails = failure }) {
            HStack {
                Circle()
                    .fill(colorForCategory(failure.category))
                    .frame(width: 8, height: 8)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.serviceType)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    
                    Text(failure.errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Text(formatTimeAgo(failure.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(PlatformColor.controlBackground)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .popover(item: $showingFailureDetails) { failure in
            failureDetailPopover(failure)
        }
    }
    
    private func failureDetailPopover(_ failure: DiscoveryDiagnosticsService.DiscoveryFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(colorForCategory(failure.category))
                Text(failure.category.rawValue)
                    .font(.headline)
            }
            
            Divider()
            
            Group {
                labeledValue("服务/设备", failure.serviceType)
                labeledValue("时间", failure.timestamp.formatted())
                labeledValue("错误信息", failure.errorMessage)
                
                if let code = failure.errorCode {
                    labeledValue("错误代码", "\(code)")
                }
                
                if let fix = failure.suggestedFix {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("建议解决方案")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(fix)
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 300)
    }
    
    // MARK: - 辅助视图
    
    private func statusCard(title: String, status: String, emoji: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(emoji)
                    .font(.caption)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Text(status)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(8)
        .frame(minWidth: 80)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
        }
    }
    
    // MARK: - 辅助方法
    
    private func colorForPermission(_ status: DiscoveryDiagnosticsService.PermissionStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied, .restricted: return .red
        case .notDetermined, .unknown: return .orange
        }
    }
    
    private func colorForCategory(_ category: DiscoveryDiagnosticsService.DiscoveryFailure.FailureCategory) -> Color {
        switch category {
        case .permission: return .red
        case .network: return .orange
        case .bonjour: return .yellow
        case .timeout: return .gray
        case .peerRejection: return .purple
        case .cryptographic: return .red
        case .unknown: return .gray
        }
    }
    
    private func formatTimeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        
        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)分钟前"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)小时前"
        } else {
            let days = Int(interval / 86400)
            return "\(days)天前"
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, iOS 17.0, *)
#Preview {
    DiscoveryDiagnosticsView()
        .padding()
        .frame(width: 500)
}
#endif

