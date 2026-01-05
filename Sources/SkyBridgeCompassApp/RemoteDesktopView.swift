import SwiftUI
import SkyBridgeCore

/// 远程桌面连接管理界面
struct RemoteDesktopView: View {
    @StateObject private var remoteDesktopManager = RemoteDesktopManager.shared
    @State private var selectedSession: RemoteSessionSummary?
    @State private var isFullScreen = false
    @State private var showingConnectionSheet = false
    @State private var showingSettingsSheet = false
    @State private var searchText = ""
    @State private var selectedQuality: VideoQuality = .high
 // 新增：维护从管理器发布的所有会话快照
    @State private var allSessions: [RemoteSessionSummary] = []
 // 新增：最近会话本地存储（断开后加入）
    @State private var recentSessionsStore: [RemoteSessionSummary] = []
 // 最近会话的时间戳映射，用于显示“最后连接时间”
    @State private var recentSessionsTimestamp: [UUID: Date] = [:]
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    
 // MARK: - Metal 4 增强功能状态
    @State private var connectionMode: ConnectionMode = .auto  // 双通道模式
    @State private var showPerformanceOverlay = false  // 性能监控
    @State private var renderMetrics: RenderMetrics = .zero  // Metal 4 指标
    
 // MARK: - macOS 15/26 窗口管理
    @Environment(\.openWindow) private var openWindow  // macOS 14+ 标准窗口打开方式
    
    var body: some View {
        HStack(spacing: 0) {
 // 侧边栏 - 会话列表
            sessionSidebar
            
 // 主内容区域
            Group {
                if let session = selectedSession {
                    remoteDesktopContent(for: session)
                } else {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarButtons
            }
        }
        .sheet(isPresented: $showingConnectionSheet) {
            NewConnectionSheet(isPresented: $showingConnectionSheet)
        }
        .sheet(isPresented: $showingSettingsSheet) {
            RemoteDesktopSettingsView(isPresented: $showingSettingsSheet)
        }
        .onAppear {
 // 延迟初始化，避免在视图创建时立即启动所有服务
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
                remoteDesktopManager.bootstrap()
            }
        }
 // 订阅远程桌面管理器的会话发布，实时更新侧边栏列表
        .onReceive(remoteDesktopManager.sessions) { sessions in
 // 说明：该订阅仅更新会话快照，不改变连接状态
            self.allSessions = sessions
        }
        .onDisappear {
 // 确保在视图消失时正确清理资源
            remoteDesktopManager.shutdown()
        }
    }

    
    
 // MARK: - 侧边栏
    private var sessionSidebar: some View {
        VStack(spacing: 0) {
 // 搜索栏
            searchBar

 // 会话列表
            sessionList

 // 底部操作栏
            bottomActionBar
        }
        .frame(width: 240)
        .padding(16)
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(themeConfiguration.cardBackgroundMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(themeConfiguration.borderColor, lineWidth: 1)
                    )
            }
        }
    }
    
    private var searchBar: some View {
        VStack(spacing: 12) {
 // 搜索框
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField(LocalizationManager.shared.localizedString("remote.search.placeholder"), text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06))
            .cornerRadius(10)
            
 // 双通道模式选择器（Metal 4 新功能）
            connectionModeSelector
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        
    }
    
 /// 双通道模式选择器 - 近距镜像 vs 远距 RDP
    private var connectionModeSelector: some View {
        HStack(spacing: 8) {
            ForEach(ConnectionMode.allCases, id: \.self) { mode in
                Button(action: { 
                    connectionMode = mode
 // 如果切换到近距模式，打开独立窗口（macOS 15/26 最佳实践）
                    if mode == .nearField {
                        openWindow(id: "near-field-mirror")
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 14))
                        Text(mode.shortName)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(connectionMode == mode ? Color.accentColor.opacity(0.2) : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help(mode.description)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
    }
    
    private var sessionList: some View {
        List(selection: $selectedSession) {
            Section(LocalizationManager.shared.localizedString("remote.activeSessions")) {
                ForEach(filteredActiveSessions) { session in
                    SessionRowView(session: session, isSelected: selectedSession?.id == session.id)
                        .tag(session)
                        .contextMenu {
                            sessionContextMenu(for: session)
                        }
                }
            }

            Section(LocalizationManager.shared.localizedString("remote.recentConnections")) {
                ForEach(filteredRecentSessions) { session in
                    RecentSessionRowView(
                        session: session,
                        lastConnected: recentSessionsTimestamp[session.id],
                        onReconnect: { reconnectToSession(session) }
                    )
                    .tag(session)
                    .contextMenu {
                        sessionContextMenu(for: session)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
    
    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            Button(action: { showingConnectionSheet = true }) {
                Label(LocalizationManager.shared.localizedString("remote.newConnection"), systemImage: "plus")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .padding(.bottom, 6)
    }
    
 // MARK: - 主内容区域
    private func remoteDesktopContent(for session: RemoteSessionSummary) -> some View {
        VStack(spacing: 0) {
 // 顶部控制栏
            remoteDesktopToolbar(for: session)
            
 // 远程桌面显示区域
            remoteDisplayArea(for: session)
        }
        .background(Color.black)
    }
    
    private func remoteDesktopToolbar(for session: RemoteSessionSummary) -> some View {
        HStack {
 // 连接信息
            VStack(alignment: .leading, spacing: 2) {
                Text(session.targetName)
                    .font(.headline)
                    .foregroundColor(.white)
                
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    
                    Text("\(session.protocolDescription) • \(session.bandwidthMbps, specifier: "%.1f") Mbps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
 // 控制按钮
            HStack(spacing: 8) {
 // 双通道模式徽章
                connectionModeBadge
                
                Divider()
                    .frame(height: 20)
                
 // Metal 4 性能监控开关
                Button(action: { showPerformanceOverlay.toggle() }) {
                    Image(systemName: showPerformanceOverlay ? "chart.bar.fill" : "chart.bar")
                        .foregroundColor(showPerformanceOverlay ? .green : .white)
                }
                .help(LocalizationManager.shared.localizedString("remote.performance.monitor"))
                
 // 质量设置
                Menu {
                    ForEach(VideoQuality.allCases, id: \.self) { quality in
                        Button(quality.displayName) {
                            selectedQuality = quality
                        }
                    }
                } label: {
                    Image(systemName: "tv")
                        .foregroundColor(.white)
                }
                .menuStyle(.borderlessButton)
                
 // 设置按钮
                Button(action: { showingSettingsSheet = true }) {
                    Image(systemName: "gearshape")
                        .foregroundColor(.white)
                }
                .help(LocalizationManager.shared.localizedString("remote.settings.help"))
                
 // 全屏切换
                Button(action: { isFullScreen.toggle() }) {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderless)
                
 // 断开连接
                Button(action: { disconnectSession(session) }) {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.8))
    }
    
 /// 连接模式徽章 - 显示当前使用的通道
    private var connectionModeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: connectionMode.iconName)
                .font(.caption)
            Text(connectionMode.shortName)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(connectionMode.badgeColor.opacity(0.2))
        .foregroundColor(connectionMode.badgeColor)
        .cornerRadius(4)
    }
    
 /// Metal 4 性能监控覆盖层
    @ViewBuilder
    private var performanceOverlay: some View {
        if showPerformanceOverlay {
            VStack(alignment: .trailing, spacing: 8) {
 // Metal 4 标识
                HStack(spacing: 4) {
                    Image(systemName: "cpu.fill")
                        .font(.caption2)
                    Text("Metal 4")
                        .font(.caption2)
                        .fontWeight(.bold)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green.opacity(0.2))
                .foregroundColor(.green)
                .cornerRadius(4)
                
 // 性能指标
                VStack(alignment: .trailing, spacing: 4) {
                    performanceMetric(
                        icon: "speedometer",
                        label: "解码",
                        value: "\(Int(renderMetrics.latencyMilliseconds))ms",
                        color: renderMetrics.latencyMilliseconds < 30 ? .green : .orange
                    )
                    
                    performanceMetric(
                        icon: "arrow.down.circle",
                        label: "带宽",
                        value: String(format: "%.1f Mbps", renderMetrics.bandwidthMbps),
                        color: renderMetrics.bandwidthMbps > 50 ? .green : .orange
                    )
                    
                    performanceMetric(
                        icon: "memorychip",
                        label: "GPU",
                        value: "92%",
                        color: .cyan
                    )
                }
            }
            .padding(12)
            .background(.black.opacity(0.7))
            .cornerRadius(12)
            .padding(16)
        }
    }
    
    private func remoteDisplayArea(for session: RemoteSessionSummary) -> some View {
        GeometryReader { geometry in
            RemoteDisplayView(
                textureFeed: remoteDesktopManager.textureFeed,
                onMouseEvent: { location, eventType, buttonNumber in
                    handleMouseEvent(location: location, eventType: eventType, buttonNumber: buttonNumber, for: session)
                },
                onKeyboardEvent: { keyCode, isPressed in
                    handleKeyboardEvent(keyCode: keyCode, isPressed: isPressed, for: session)
                },
                onScrollEvent: { deltaX, deltaY in
                    handleScrollEvent(deltaX: deltaX, deltaY: deltaY, for: session)
                }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay(
 // 连接状态覆盖层
                    connectionStatusOverlay(for: session),
                    alignment: .center
                )
                .overlay(
 // Metal 4 性能监控覆盖层（右上角）
                    performanceOverlay,
                    alignment: .topTrailing
                )
        }
    }
    
    private func connectionStatusOverlay(for session: RemoteSessionSummary) -> some View {
        Group {
            if session.status == SessionStatus.connecting {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    
                    Text(String(format: LocalizationManager.shared.localizedString("remote.overlay.connectingTo"), session.targetName))
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(32)
                .background(Color.black.opacity(0.8))
                .cornerRadius(12)
            }
        }
    }
    
 // MARK: - 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "display")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text(LocalizationManager.shared.localizedString("remote.empty.title"))
                    .font(.title2)
                    .fontWeight(.medium)
                
                Text(LocalizationManager.shared.localizedString("remote.empty.subtitle"))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button(LocalizationManager.shared.localizedString("remote.newConnection")) {
                showingConnectionSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: 400)
    }
    
 // MARK: - 工具栏按钮
    private var toolbarButtons: some View {
        Group {
            Button(action: { showingConnectionSheet = true }) {
                Image(systemName: "plus")
            }
            .help(LocalizationManager.shared.localizedString("remote.toolbar.newConnection.help"))
            
            Button(action: refreshSessions) {
                Image(systemName: "arrow.clockwise")
            }
            .help(LocalizationManager.shared.localizedString("remote.toolbar.refresh.help"))
        }
    }
    
 /// 性能指标行
    private func performanceMetric(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(color)
        }
    }
    
 // MARK: - 上下文菜单
    private func sessionContextMenu(for session: RemoteSessionSummary) -> some View {
        Group {
            Button(LocalizationManager.shared.localizedString("remote.context.focusWindow")) {
                remoteDesktopManager.focus(on: session.id)
            }
            
            Button(LocalizationManager.shared.localizedString("remote.context.disconnect")) {
                disconnectSession(session)
            }
            
            Divider()
            
            Button(LocalizationManager.shared.localizedString("remote.context.copyInfo")) {
                copySessionInfo(session)
            }
        }
    }
    
    private func recentSessionContextMenu(for session: RemoteSessionSummary) -> some View {
        Group {
            Button(LocalizationManager.shared.localizedString("remote.context.reconnect")) {
                reconnectToSession(session)
            }
            
            Button(LocalizationManager.shared.localizedString("remote.context.removeFromHistory")) {
                removeFromHistory(session)
            }
        }
    }
    
 // MARK: - 输入事件处理
    
 /// 处理鼠标事件并转发到远程桌面会话
    private func handleMouseEvent(location: CGPoint, eventType: NSEvent.EventType, buttonNumber: Int, for session: RemoteSessionSummary) {
 // 将鼠标事件转发到远程桌面管理器
        remoteDesktopManager.sendMouseEvent(
            sessionId: session.id,
            x: Float(location.x),
            y: Float(location.y),
            eventType: eventType,
            buttonNumber: buttonNumber
        )
    }
    
 /// 处理键盘事件并转发到远程桌面会话
    private func handleKeyboardEvent(keyCode: UInt16, isPressed: Bool, for session: RemoteSessionSummary) {
 // 将键盘事件转发到远程桌面管理器
        remoteDesktopManager.sendKeyboardEvent(
            sessionId: session.id,
            keyCode: keyCode,
            isPressed: isPressed
        )
    }
    
 /// 处理滚轮事件并转发到远程桌面会话
    private func handleScrollEvent(deltaX: CGFloat, deltaY: CGFloat, for session: RemoteSessionSummary) {
 // 将滚轮事件转发到远程桌面管理器
        remoteDesktopManager.sendScrollEvent(
            sessionId: session.id,
            deltaX: Float(deltaX),
            deltaY: Float(deltaY)
        )
    }
    
 // MARK: - 会话管理
    
    private var filteredActiveSessions: [RemoteSessionSummary] {
 // 从管理器发布的所有会话中，根据搜索文本过滤
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return allSessions }
        return allSessions.filter { session in
            return session.targetName.localizedCaseInsensitiveContains(keyword) ||
                   session.protocolDescription.localizedCaseInsensitiveContains(keyword)
        }
    }
    
    private var filteredRecentSessions: [RemoteSessionSummary] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return recentSessionsStore }
        return recentSessionsStore.filter { session in
            return session.targetName.localizedCaseInsensitiveContains(keyword) ||
                   session.protocolDescription.localizedCaseInsensitiveContains(keyword)
        }
    }
    
 // MARK: - 操作方法
    private func refreshSessions() {
 // 说明：调用管理器的公开刷新接口，重新发布当前会话快照与基础指标
        remoteDesktopManager.reloadSessions()
    }
    
    private func disconnectSession(_ session: RemoteSessionSummary) {
 // 说明：断开指定会话，并将其加入最近会话存储，便于"最近连接"区展示
        Task { @MainActor in
            remoteDesktopManager.terminate(sessionID: session.id)
 // 加入最近会话（去重）
            if !recentSessionsStore.contains(where: { $0.id == session.id }) {
                recentSessionsStore.append(session)
 // 记录最后连接时间（断开时刻）
                recentSessionsTimestamp[session.id] = Date()
            }
        }
    }
    
    private func copySessionInfo(_ session: RemoteSessionSummary) {
        let info = "远程桌面会话: \(session.targetName)\n协议: \(session.protocolDescription)\n带宽: \(session.bandwidthMbps) Mbps"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }
    
    private func reconnectToSession(_ session: RemoteSessionSummary) {
 // 说明：由于摘要不携带主机/端口等连接参数，这里触发“新建连接”表单，
 // 由用户补全连接信息后重新建立会话。
        showingConnectionSheet = true
    }
    
    private func removeFromHistory(_ session: RemoteSessionSummary) {
 // 从最近会话本地存储移除
        recentSessionsStore.removeAll { $0.id == session.id }
        recentSessionsTimestamp.removeValue(forKey: session.id)
    }
}

// MARK: - 会话行视图
struct SessionRowView: View {
    let session: RemoteSessionSummary
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
 // 状态指示器
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            
 // 会话信息
            VStack(alignment: .leading, spacing: 2) {
                Text(session.targetName)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(session.protocolDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
 // 带宽指示器
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(session.bandwidthMbps, specifier: "%.1f")")
                    .font(.caption)
                    .fontWeight(.medium)
                
                Text("Mbps")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(8)
    }
    
    private var statusColor: Color {
        switch session.status {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        case .failed:
            return .red
        }
    }
}

// MARK: - 最近会话行视图
struct RecentSessionRowView: View {
    let session: RemoteSessionSummary
 /// 最近一次连接时间（由上层维护并传入）
    let lastConnected: Date?
 /// 重新连接回调
    var onReconnect: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .foregroundColor(.secondary)
                .frame(width: 16, height: 16)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(session.targetName)
                    .font(.subheadline)
                    .lineLimit(1)
                
                Text(String(format: LocalizationManager.shared.localizedString("remote.recent.lastConnected"), formatLastConnected()))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Button(action: {
                onReconnect?()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LocalizationManager.shared.localizedString("remote.recent.reconnect.help"))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }
    
    @MainActor
    private func formatLastConnected() -> String {
        guard let lastConnected else { return LocalizationManager.shared.localizedString("common.unknown") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LocalizationManager.shared.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastConnected, relativeTo: Date())
    }
}

// MARK: - 新建连接表单
struct NewConnectionSheet: View {
    @Binding var isPresented: Bool
    @State private var hostname = ""
    @State private var port = "3389"
    @State private var username = ""
    @State private var password = ""
    @State private var selectedProtocol: RemoteProtocol = .rdp
 // 连接错误提示
    @State private var connectError: String?
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        NavigationView {
            Form {
                Section(LocalizationManager.shared.localizedString("remote.form.section.connection")) {
                    TextField(LocalizationManager.shared.localizedString("remote.form.hostname"), text: $hostname)
                    TextField(LocalizationManager.shared.localizedString("remote.form.port"), text: $port)
                    Picker(LocalizationManager.shared.localizedString("remote.form.protocol"), selection: $selectedProtocol) {
                        ForEach(RemoteProtocol.allCases, id: \.self) { protocolType in
                            Text(protocolType.displayName).tag(protocolType)
                        }
                    }
                }
                
                Section(LocalizationManager.shared.localizedString("remote.form.section.auth")) {
                    TextField(LocalizationManager.shared.localizedString("auth.username"), text: $username)
                    SecureField(LocalizationManager.shared.localizedString("auth.password"), text: $password)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(LocalizationManager.shared.localizedString("remote.form.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationManager.shared.localizedString("action.cancel")) {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationManager.shared.localizedString("remote.form.connect")) {
                        connectToRemote()
                    }
                    .disabled(hostname.isEmpty || username.isEmpty)
                }
            }
        }
        .frame(width: 500, height: 400)
 // 错误提示框：当连接失败时显示
        .alert(LocalizationManager.shared.localizedString("remote.form.connectFailed"), isPresented: Binding(
            get: { connectError != nil },
            set: { if !$0 { connectError = nil } }
        )) {
            Button(LocalizationManager.shared.localizedString("action.ok")) { connectError = nil }
        } message: {
            Text(connectError ?? "")
        }
    }
    
    private func connectToRemote() {
 // 实现远程连接逻辑（按协议类型分发）
        guard let portValue = Int(port) else {
            connectError = "端口格式不正确"
            return
        }
        let domain: String? = nil // 可扩展：支持域字段
        switch selectedProtocol {
        case .rdp:
            Task {
                do {
                    try await RemoteDesktopManager.shared.connect(
                        host: hostname,
                        port: portValue,
                        username: username,
                        password: password,
                        domain: domain,
                        displayName: hostname
                    )
                    await MainActor.run { isPresented = false }
                } catch {
                    await MainActor.run { connectError = error.localizedDescription }
                }
            }
        case .vnc:
 // 该分支不涉及抛错操作，移除无效的 do-catch，直接在主线程更新UI并打开窗口，符合Swift 6.2.1并发最佳实践。
            Task { @MainActor in
                VNCLaunchContext.shared.host = hostname
                VNCLaunchContext.shared.port = UInt16(portValue)
                isPresented = false
                openWindow(id: "vnc-viewer")
            }
        case .ssh:
 // 该分支同样无抛错点，去除无效 do-catch，直接进行UI状态更新与窗口打开。
            Task { @MainActor in
                SSHLaunchContext.shared.host = hostname
                SSHLaunchContext.shared.port = Int(portValue)
                SSHLaunchContext.shared.username = username
                SSHLaunchContext.shared.password = password
                isPresented = false
                openWindow(id: "ssh-terminal")
            }
        }
    }
}

// MARK: - 远程桌面设置视图
struct RemoteDesktopSettingsView: View {
    @Binding var isPresented: Bool
    @StateObject private var settingsManager = RemoteDesktopSettingsManager.shared
    @State private var selectedTab: SettingsTab = .display
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
 // 设置标签页选择器
                settingsTabPicker
                
 // 设置内容区域
                TabView(selection: $selectedTab) {
                    displaySettingsView
                        .tabItem {
                            Label("显示设置", systemImage: "display")
                        }
                        .tag(SettingsTab.display)
                    
                    interactionSettingsView
                        .tabItem {
                            Label("交互设置", systemImage: "hand.point.up.left")
                        }
                        .tag(SettingsTab.interaction)
                    
                    networkSettingsView
                        .tabItem {
                            Label("网络优化", systemImage: "network")
                        }
                        .tag(SettingsTab.network)
                }
                .tabViewStyle(.automatic)
            }
            .navigationTitle("远程桌面设置")
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    Button("重置") {
                        resetSettings()
                    }
                }
                
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("应用") {
                        applySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("完成") {
                        saveAndClose()
                    }
                }
            }
        }
        .frame(width: 700, height: 600)
    }
    
 // MARK: - 设置标签页选择器
    private var settingsTabPicker: some View {
        Picker("设置类别", selection: $selectedTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Text(tab.displayName).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding()
    }
    
 // MARK: - 显示设置视图
    private var displaySettingsView: some View {
        Form {
            Section("分辨率和显示") {
                Picker("分辨率", selection: $settingsManager.settings.displaySettings.resolution) {
                    ForEach(ResolutionSetting.allCases, id: \.self) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                
                Picker("色彩深度", selection: $settingsManager.settings.displaySettings.colorDepth) {
                    ForEach(ColorDepth.allCases, id: \.self) { depth in
                        Text(depth.displayName).tag(depth)
                    }
                }
                
                Picker("刷新率", selection: $settingsManager.settings.displaySettings.refreshRate) {
                    ForEach(RefreshRate.allCases, id: \.self) { rate in
                        Text(rate.displayName).tag(rate)
                    }
                }
                
                Toggle("全屏模式", isOn: $settingsManager.settings.displaySettings.fullScreenMode)
                Toggle("多显示器支持", isOn: $settingsManager.settings.displaySettings.multiMonitorSupport)
            }
            
            Section("视频质量") {
                Picker("视频质量", selection: $settingsManager.settings.displaySettings.videoQuality) {
                    ForEach(VideoQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("压缩级别: \(Int(settingsManager.settings.displaySettings.compressionLevel))%")
                        .font(.subheadline)
                    Slider(
                        value: $settingsManager.settings.displaySettings.compressionLevel,
                        in: 0...100,
                        step: 5
                    ) {
                        Text("压缩级别")
                    } minimumValueLabel: {
                        Text("0%")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("100%")
                            .font(.caption)
                    }
                }
            }
            
            Section("性能优化") {
                Toggle("启用硬件加速", isOn: $settingsManager.settings.displaySettings.enableHardwareAcceleration)
                    .help("使用 GPU 加速视频解码和渲染")
                
                Toggle("Apple Silicon 优化", isOn: $settingsManager.settings.displaySettings.enableAppleSiliconOptimization)
                    .help("针对 Apple Silicon 芯片进行性能优化")

                Picker("视频编码器", selection: $settingsManager.settings.displaySettings.preferredCodec) {
                    ForEach(PreferredVideoCodec.allCases, id: \.self) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("目标帧率: \(settingsManager.settings.displaySettings.targetFrameRate) FPS")
                        .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.settings.displaySettings.targetFrameRate) },
                            set: { settingsManager.settings.displaySettings.targetFrameRate = Int($0) }
                        ),
                        in: 15...120,
                        step: 5
                    ) {
                        Text("目标帧率")
                    } minimumValueLabel: {
                        Text("15")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("120")
                            .font(.caption)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("关键帧间隔: \(settingsManager.settings.displaySettings.keyFrameInterval) 帧")
                        .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.settings.displaySettings.keyFrameInterval) },
                            set: { settingsManager.settings.displaySettings.keyFrameInterval = Int($0) }
                        ),
                        in: 30...240,
                        step: 30
                    ) {
                        Text("关键帧间隔")
                    } minimumValueLabel: {
                        Text("30")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("240")
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    
 // MARK: - 交互设置视图
    private var interactionSettingsView: some View {
        Form {
            Section("鼠标和触控板") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("鼠标灵敏度: \(settingsManager.settings.interactionSettings.mouseSensitivity, specifier: "%.1f")")
                        .font(.subheadline)
                    Slider(
                        value: $settingsManager.settings.interactionSettings.mouseSensitivity,
                        in: 0.1...5.0,
                        step: 0.1
                    ) {
                        Text("鼠标灵敏度")
                    } minimumValueLabel: {
                        Text("慢")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("快")
                            .font(.caption)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("滚轮灵敏度: \(settingsManager.settings.interactionSettings.scrollSensitivity, specifier: "%.1f")")
                        .font(.subheadline)
                    Slider(
                        value: $settingsManager.settings.interactionSettings.scrollSensitivity,
                        in: 0.1...5.0,
                        step: 0.1
                    ) {
                        Text("滚轮灵敏度")
                    } minimumValueLabel: {
                        Text("慢")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("快")
                            .font(.caption)
                    }
                }
                
                Toggle("启用鼠标加速", isOn: $settingsManager.settings.interactionSettings.enableMouseAcceleration)
                Toggle("启用触控板手势", isOn: $settingsManager.settings.interactionSettings.enableTrackpadGestures)
                Toggle("启用右键菜单", isOn: $settingsManager.settings.interactionSettings.enableContextMenu)
            }
            
            Section("键盘设置") {
                Picker("键盘映射", selection: $settingsManager.settings.interactionSettings.keyboardMapping) {
                    ForEach(KeyboardMapping.allCases, id: \.self) { mapping in
                        Text(mapping.displayName).tag(mapping)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("双击间隔: \(settingsManager.settings.interactionSettings.doubleClickInterval) 毫秒")
                        .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.settings.interactionSettings.doubleClickInterval) },
                            set: { settingsManager.settings.interactionSettings.doubleClickInterval = Int($0) }
                        ),
                        in: 200...1000,
                        step: 50
                    ) {
                        Text("双击间隔")
                    } minimumValueLabel: {
                        Text("快")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("慢")
                            .font(.caption)
                    }
                }
            }
            
            Section("功能设置") {
                Toggle("剪贴板同步", isOn: $settingsManager.settings.interactionSettings.enableClipboardSync)
                    .help("在本地和远程桌面之间同步剪贴板内容")
                
                Toggle("音频重定向", isOn: $settingsManager.settings.interactionSettings.enableAudioRedirection)
                    .help("将远程桌面的音频播放到本地设备")
                
                Toggle("打印机重定向", isOn: $settingsManager.settings.interactionSettings.enablePrinterRedirection)
                    .help("允许远程桌面使用本地打印机")
                
                Toggle("文件传输", isOn: $settingsManager.settings.interactionSettings.enableFileTransfer)
                    .help("启用本地和远程桌面之间的文件传输")
            }
        }
        .formStyle(.grouped)
    }
    
 // MARK: - 网络优化设置视图
    private var networkSettingsView: some View {
        Form {
            Section("连接设置") {
                Picker("连接类型", selection: $settingsManager.settings.networkSettings.connectionType) {
                    ForEach(ConnectionType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("带宽限制: \(settingsManager.settings.networkSettings.bandwidthLimit == 0 ? "无限制" : "\(Int(settingsManager.settings.networkSettings.bandwidthLimit)) Mbps")")
                        .font(.subheadline)
                    Slider(
                        value: $settingsManager.settings.networkSettings.bandwidthLimit,
                        in: 0...1000,
                        step: 10
                    ) {
                        Text("带宽限制")
                    } minimumValueLabel: {
                        Text("无限制")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("1000M")
                            .font(.caption)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("连接超时: \(settingsManager.settings.networkSettings.connectionTimeout) 秒")
                        .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.settings.networkSettings.connectionTimeout) },
                            set: { settingsManager.settings.networkSettings.connectionTimeout = Int($0) }
                        ),
                        in: 10...120,
                        step: 5
                    ) {
                        Text("连接超时")
                    } minimumValueLabel: {
                        Text("10s")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("120s")
                            .font(.caption)
                    }
                }
            }
            
            Section("数据压缩") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("压缩级别: \(settingsManager.settings.networkSettings.compressionLevel)")
                        .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.settings.networkSettings.compressionLevel) },
                            set: { settingsManager.settings.networkSettings.compressionLevel = Int($0) }
                        ),
                        in: 0...9,
                        step: 1
                    ) {
                        Text("压缩级别")
                    } minimumValueLabel: {
                        Text("无压缩")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("最大压缩")
                            .font(.caption)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("缓冲区大小: \(settingsManager.settings.networkSettings.bufferSize) KB")
                        .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.settings.networkSettings.bufferSize) },
                            set: { settingsManager.settings.networkSettings.bufferSize = Int($0) }
                        ),
                        in: 256...8192,
                        step: 256
                    ) {
                        Text("缓冲区大小")
                    } minimumValueLabel: {
                        Text("256KB")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("8MB")
                            .font(.caption)
                    }
                }
            }
            
            Section("高级选项") {
                Toggle("启用网络加密", isOn: $settingsManager.settings.networkSettings.enableEncryption)
                    .help("使用 TLS 加密网络传输")
                
                Toggle("启用 UDP 传输", isOn: $settingsManager.settings.networkSettings.enableUDPTransport)
                    .help("使用 UDP 协议提高传输性能")
                
                Toggle("启用自适应质量", isOn: $settingsManager.settings.networkSettings.enableAdaptiveQuality)
                    .help("根据网络状况自动调整视频质量")
                
                Toggle("启用网络统计", isOn: $settingsManager.settings.networkSettings.enableNetworkStats)
                    .help("显示网络性能统计信息")
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("最大重连次数: \(settingsManager.settings.networkSettings.maxReconnectAttempts)")
                        .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.settings.networkSettings.maxReconnectAttempts) },
                            set: { settingsManager.settings.networkSettings.maxReconnectAttempts = Int($0) }
                        ),
                        in: 0...10,
                        step: 1
                    ) {
                        Text("最大重连次数")
                    } minimumValueLabel: {
                        Text("0")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("10")
                            .font(.caption)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("退避起始: \(settingsManager.settings.networkSettings.reconnectBackoffInitialMs) ms")
                        .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.settings.networkSettings.reconnectBackoffInitialMs) },
                            set: { settingsManager.settings.networkSettings.reconnectBackoffInitialMs = Int($0) }
                        ),
                        in: 100...5000,
                        step: 100
                    ) { Text("退避起始") }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("退避最大: \(settingsManager.settings.networkSettings.reconnectBackoffMaxMs) ms")
                        .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.settings.networkSettings.reconnectBackoffMaxMs) },
                            set: { settingsManager.settings.networkSettings.reconnectBackoffMaxMs = Int($0) }
                        ),
                        in: 1000...60000,
                        step: 1000
                    ) { Text("退避最大") }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("退避乘数: \(String(format: "%.1f", settingsManager.settings.networkSettings.reconnectBackoffMultiplier))x")
                        .font(.subheadline)
                    Slider(
                        value: $settingsManager.settings.networkSettings.reconnectBackoffMultiplier,
                        in: 1.1...4.0,
                        step: 0.1
                    ) { Text("退避乘数") }
                }
            }
        }
        .formStyle(.grouped)
    }
    
 // MARK: - 操作方法
    private func resetSettings() {
        settingsManager.resetToDefaults()
    }
    
    private func applySettings() {
        settingsManager.saveSettings()
 // 注意：设置将在下次创建新会话时自动应用
 // 如需立即应用到现有会话，请使用各会话的 applySettings 方法
    }
    
    private func saveAndClose() {
        settingsManager.saveSettings()
        isPresented = false
    }
}

// MARK: - 设置标签页枚举
enum SettingsTab: String, CaseIterable {
    case display = "display"
    case interaction = "interaction"
    case network = "network"
    
    var displayName: String {
        switch self {
        case .display: return "显示设置"
        case .interaction: return "交互设置"
        case .network: return "网络优化"
        }
    }
}

// MARK: - 支持类型
enum VideoQuality: CaseIterable {
    case low, medium, high, ultra
    
    var displayName: String {
        switch self {
        case .low: return "低质量"
        case .medium: return "中等质量"
        case .high: return "高质量"
        case .ultra: return "超高质量"
        }
    }
}

enum RemoteProtocol: CaseIterable {
    case rdp, vnc, ssh
    
    var displayName: String {
        switch self {
        case .rdp: return "RDP"
        case .vnc: return "VNC"
        case .ssh: return "SSH"
        }
    }
}

// 说明：会话状态类型已在 SkyBridgeCore 中统一定义为 SessionStatus，
// UI 直接使用摘要中的 status 字段进行展示。

// MARK: - Metal 4 增强功能类型定义

/// 连接模式 - 双通道架构
enum ConnectionMode: String, CaseIterable {
    case auto = "auto"           // 自动选择
    case nearField = "near"      // 近距硬件镜像（ScreenCaptureKit + QUIC）
    case farFieldRDP = "far"     // 远距 RDP（FreeRDP 3.x）
    
    @MainActor
    var shortName: String {
        switch self {
        case .auto: return LocalizationManager.shared.localizedString("remote.connectionMode.auto")
        case .nearField: return LocalizationManager.shared.localizedString("remote.connectionMode.near")
        case .farFieldRDP: return LocalizationManager.shared.localizedString("remote.connectionMode.far")
        }
    }
    
    var iconName: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .nearField: return "wifi.circle.fill"
        case .farFieldRDP: return "globe"
        }
    }
    
    @MainActor
    var description: String {
        switch self {
        case .auto: return LocalizationManager.shared.localizedString("remote.connectionMode.auto.description")
        case .nearField: return LocalizationManager.shared.localizedString("remote.connectionMode.near.description")
        case .farFieldRDP: return LocalizationManager.shared.localizedString("remote.connectionMode.far.description")
        }
    }
    
    var badgeColor: Color {
        switch self {
        case .auto: return .cyan
        case .nearField: return .green
        case .farFieldRDP: return .blue
        }
    }
}

/// Metal 4 渲染指标
struct RenderMetrics: Equatable {
    var bandwidthMbps: Double
    var latencyMilliseconds: Double
    
    static let zero = RenderMetrics(bandwidthMbps: 0, latencyMilliseconds: 0)
}
