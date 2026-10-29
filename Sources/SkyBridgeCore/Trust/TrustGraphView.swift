import SwiftUI

// MARK: - 信任图谱视图
/// 展示设备信任关系图谱，支持管理信任的设备
@available(macOS 14.0, iOS 17.0, *)
public struct TrustGraphView: View {
    
    @StateObject private var trustManager = TrustGraphManager.shared
    @State private var selectedDevice: TrustGraphDevice?
    @State private var showingRevokeConfirmation = false
    @State private var showingClearAllConfirmation = false
    @State private var showingKeyRotationSheet = false
    @State private var keyRotationTargetDevice: TrustGraphDevice?
    @State private var keyRotationCertificateText = ""
    @State private var keyRotationErrorMessage: String?
    @State private var isApplyingKeyRotation = false
    @State private var searchText = ""
    
    public init() {}
    
    public var body: some View {
        NavigationSplitView {
            // 左侧列表
            sidebarContent
        } detail: {
            // 右侧详情
            if let device = selectedDevice {
                deviceDetailView(device)
            } else {
                emptyDetailView
            }
        }
        .navigationTitle("信任图谱")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarItems
            }
        }
        .confirmationDialog(
            "确定要撤销此设备的信任吗？",
            isPresented: $showingRevokeConfirmation,
            titleVisibility: .visible
        ) {
            Button("撤销信任", role: .destructive) {
                if let device = selectedDevice {
                    Task {
                        try? await trustManager.revokeDevice(device.deviceId)
                        selectedDevice = nil
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("撤销后，此设备将需要重新请求信任才能连接。")
        }
        .confirmationDialog(
            "确定要清除所有信任记录吗？",
            isPresented: $showingClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除全部", role: .destructive) {
                Task {
                    await trustManager.clearAllTrust()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这将撤销所有已信任设备的信任关系。此操作不可撤销。")
        }
        .sheet(isPresented: $showingKeyRotationSheet) {
            keyRotationSheet
        }
    }
    
    // MARK: - 子视图
    
    private var sidebarContent: some View {
        List(selection: $selectedDevice) {
            // 待处理请求
            if !trustManager.pendingRequests.isEmpty {
                Section("待处理请求 (\(trustManager.pendingRequests.count))") {
                    ForEach(trustManager.pendingRequests) { request in
                        pendingRequestRow(request)
                    }
                }
            }
            
            // 已信任设备
            Section("已信任设备 (\(filteredDevices.count))") {
                ForEach(filteredDevices) { device in
                    deviceRow(device)
                        .tag(device)
                }
            }
            
            // 最近事件
            if !trustManager.recentEvents.isEmpty {
                Section("最近活动") {
                    ForEach(trustManager.recentEvents.prefix(5)) { event in
                        eventRow(event)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "搜索设备")
        .refreshable {
            await trustManager.refresh()
        }
    }
    
    private var filteredDevices: [TrustGraphDevice] {
        if searchText.isEmpty {
            return trustManager.trustedDevices
        }
        return trustManager.trustedDevices.filter { device in
            device.displayName.localizedCaseInsensitiveContains(searchText) ||
            device.deviceId.localizedCaseInsensitiveContains(searchText) ||
            device.shortFingerprint.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private func deviceRow(_ device: TrustGraphDevice) -> some View {
        HStack(spacing: 12) {
            // 设备图标
            ZStack {
                Circle()
                    .fill(statusColor(for: device.trustStatus).opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: deviceIcon(for: device))
                    .font(.system(size: 18))
                    .foregroundStyle(statusColor(for: device.trustStatus))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.callout.weight(.medium))
                
                HStack(spacing: 4) {
                    Text(device.shortFingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    
                    if device.attestationLevel == .appAttest {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
            
            Spacer()
            
            // 状态标签
            statusBadge(device.trustStatus)
        }
        .padding(.vertical, 4)
    }
    
    private func pendingRequestRow(_ request: TrustRequest) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(request.deviceName ?? "未知设备")
                    .font(.callout.weight(.medium))
                
                Text("请求信任")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                Button(action: {
                    Task {
                        try? await trustManager.acceptRequest(request.id)
                    }
                }) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                
                Button(action: {
                    trustManager.rejectRequest(request.id)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func eventRow(_ event: TrustEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: event.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text(event.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
    
    private func deviceDetailView(_ device: TrustGraphDevice) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 设备头部
                deviceHeader(device)
                
                Divider()
                
                // 安全信息
                securitySection(device)
                
                Divider()
                
                // 能力与权限
                capabilitiesSection(device)
                
                Divider()
                
                // 操作按钮
                actionsSection(device)
            }
            .padding(24)
        }
    }
    
    private func deviceHeader(_ device: TrustGraphDevice) -> some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(statusColor(for: device.trustStatus).opacity(0.15))
                    .frame(width: 80, height: 80)
                
                Image(systemName: deviceIcon(for: device))
                    .font(.system(size: 36))
                    .foregroundStyle(statusColor(for: device.trustStatus))
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text(device.displayName)
                    .font(.title2.weight(.semibold))
                
                HStack(spacing: 8) {
                    statusBadge(device.trustStatus)
                    
                    if device.attestationLevel == .appAttest {
                        Label("硬件验证", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .cornerRadius(4)
                    }
                }
                
                Text("信任于 \(device.trustedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
    }
    
    private func securitySection(_ device: TrustGraphDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("安全信息", systemImage: "lock.shield")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                infoCard(
                    title: "公钥指纹",
                    value: device.shortFingerprint,
                    icon: "key",
                    color: .blue
                )
                
                infoCard(
                    title: "信任等级",
                    value: device.securityLevelDescription,
                    icon: "shield.checkered",
                    color: .green
                )
                
                infoCard(
                    title: "签名算法",
                    value: device.signatureAlgorithm?.rawValue ?? "Ed25519",
                    icon: "signature",
                    color: .purple
                )
                
                infoCard(
                    title: "最后活动",
                    value: formatTimeAgo(device.lastSeenAt),
                    icon: "clock",
                    color: .gray
                )
            }
            
            // 完整指纹
            VStack(alignment: .leading, spacing: 4) {
                Text("完整公钥指纹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(device.pubKeyFP)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(PlatformColor.controlBackground)
                    .cornerRadius(6)
            }
        }
    }
    
    private func capabilitiesSection(_ device: TrustGraphDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("设备能力", systemImage: "checklist")
                .font(.headline)
            
            if device.capabilities.isEmpty {
                Text("无特殊能力声明")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TrustGraphFlowLayout(spacing: 8) {
                    ForEach(device.capabilities, id: \.self) { capability in
                        Text(capability)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .cornerRadius(6)
                    }
                }
            }
        }
    }
    
    private func actionsSection(_ device: TrustGraphDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("操作", systemImage: "gearshape")
                .font(.headline)
            
            HStack(spacing: 12) {
                Button(action: {
                    keyRotationTargetDevice = device
                    keyRotationCertificateText = ""
                    keyRotationErrorMessage = nil
                    isApplyingKeyRotation = false
                    showingKeyRotationSheet = true
                }) {
                    Label("轮换密钥", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    showingRevokeConfirmation = true
                }) {
                    Label("撤销信任", systemImage: "xmark.shield")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }

    // MARK: - Key rotation sheet

    @ViewBuilder
    private var keyRotationSheet: some View {
        NavigationStack {
            Form {
                Section {
                    if let target = keyRotationTargetDevice {
                        Text("目标设备：\(target.displayName)")
                            .font(.callout.weight(.medium))
                        Text("旧设备 ID：\(target.deviceId)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text("未选择目标设备")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("新证书（P2PIdentityCertificate）") {
                    TextEditor(text: $keyRotationCertificateText)
                        .font(.caption.monospaced())
                        .frame(minHeight: 180)
                        .textSelection(.enabled)

                    Text("支持粘贴 JSON 或 base64(JSON)。安全起见，建议使用“pairing-confirmed”证书，并且 signerId 指向旧设备 ID。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let msg = keyRotationErrorMessage, !msg.isEmpty {
                    Section("错误") {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("轮换密钥")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showingKeyRotationSheet = false
                    }
                    .disabled(isApplyingKeyRotation)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isApplyingKeyRotation ? "处理中…" : "应用") {
                        applyKeyRotationFromSheet()
                    }
                    .disabled(isApplyingKeyRotation || keyRotationTargetDevice == nil || keyRotationCertificateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func applyKeyRotationFromSheet() {
        guard let target = keyRotationTargetDevice else { return }
        let input = keyRotationCertificateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        isApplyingKeyRotation = true
        keyRotationErrorMessage = nil

        Task {
            defer { isApplyingKeyRotation = false }
            do {
                let cert = try parseIdentityCertificate(from: input)
                try await trustManager.applyKeyRotation(oldDeviceId: target.deviceId, newCertificate: cert)
                // 轮换后旧记录会被撤销并从列表里消失；尽量把 UI selection 切到新设备
                selectedDevice = trustManager.trustedDevices.first(where: { $0.deviceId == cert.deviceId })
                showingKeyRotationSheet = false
            } catch {
                keyRotationErrorMessage = error.localizedDescription
            }
        }
    }

    private func parseIdentityCertificate(from text: String) throws -> P2PIdentityCertificate {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TrustGraphError.invalidPublicKey }

        var candidates: [Data] = []
        if let utf8 = trimmed.data(using: .utf8) {
            candidates.append(utf8)
        }
        if let b64 = Data(base64Encoded: trimmed) {
            candidates.append(b64)
        }

        for data in candidates {
            if let cert = decodeIdentityCertificate(data) {
                return cert
            }
        }
        throw TrustGraphError.invalidPublicKey
    }

    private func decodeIdentityCertificate(_ data: Data) -> P2PIdentityCertificate? {
        // 尽量兼容多种 date 编码格式
        let decoders: [JSONDecoder] = [
            {
                let d = JSONDecoder()
                d.dateDecodingStrategy = .millisecondsSince1970
                return d
            }(),
            {
                let d = JSONDecoder()
                d.dateDecodingStrategy = .secondsSince1970
                return d
            }(),
            {
                let d = JSONDecoder()
                d.dateDecodingStrategy = .iso8601
                return d
            }(),
            JSONDecoder()
        ]

        for decoder in decoders {
            if let cert = try? decoder.decode(P2PIdentityCertificate.self, from: data) {
                return cert
            }
        }
        return nil
    }
    
    private var emptyDetailView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            Text("选择一个设备查看详情")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private var toolbarItems: some View {
        // 同步状态
        switch trustManager.syncStatus {
        case .syncing:
            ProgressView()
                .controlSize(.small)
        case .completed(let date):
            Button(action: {
                Task {
                    await trustManager.syncWithiCloud()
                }
            }) {
                Image(systemName: "icloud.and.arrow.down")
            }
            .help("上次同步: \(date.formatted(date: .omitted, time: .shortened))")
        case .failed:
            Button(action: {
                Task {
                    await trustManager.syncWithiCloud()
                }
            }) {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.red)
            }
            .help("同步失败，点击重试")
        case .idle:
            Button(action: {
                Task {
                    await trustManager.syncWithiCloud()
                }
            }) {
                Image(systemName: "icloud.and.arrow.down")
            }
            .help("同步到 iCloud")
        }
        
        Button(action: {
            showingClearAllConfirmation = true
        }) {
            Image(systemName: "trash")
        }
        .help("清除所有信任")
        .disabled(trustManager.trustedDevices.isEmpty)
    }
    
    // MARK: - 辅助视图
    
    private func statusBadge(_ status: TrustGraphDevice.TrustStatus) -> some View {
        Text(status.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor(for: status).opacity(0.15))
            .foregroundStyle(statusColor(for: status))
            .cornerRadius(4)
    }
    
    private func infoCard(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
            }
            
            Spacer()
        }
        .padding(12)
        .background(PlatformColor.controlBackground)
        .cornerRadius(8)
    }
    
    // MARK: - 辅助方法
    
    private func statusColor(for status: TrustGraphDevice.TrustStatus) -> Color {
        switch status {
        case .active: return .green
        case .expired: return .orange
        case .revoked: return .red
        }
    }
    
    private func deviceIcon(for device: TrustGraphDevice) -> String {
        // 根据能力推断设备类型
        if device.capabilities.contains("mac") {
            return "desktopcomputer"
        } else if device.capabilities.contains("iphone") {
            return "iphone"
        } else if device.capabilities.contains("ipad") {
            return "ipad"
        } else {
            return "laptopcomputer"
        }
    }
    
    private func formatTimeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        
        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            return "\(Int(interval / 60))分钟前"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))小时前"
        } else {
            return "\(Int(interval / 86400))天前"
        }
    }
}

// MARK: - 流式布局

@available(macOS 14.0, iOS 17.0, *)
struct TrustGraphFlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var width: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if rowWidth + size.width > containerWidth && rowWidth > 0 {
                height += rowHeight + spacing
                width = max(width, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        
        height += rowHeight
        width = max(width, rowWidth - spacing)
        
        return CGSize(width: width, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, iOS 17.0, *)
#Preview {
    TrustGraphView()
        .frame(width: 900, height: 600)
}
#endif

