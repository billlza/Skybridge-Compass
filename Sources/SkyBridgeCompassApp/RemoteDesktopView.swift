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
    @State private var newConnectionPrefersAdvanced: Bool = false
    @State private var hasRequestedManagerBootstrap = false
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

 // MARK: - macOS 15/26 窗口管理
    @Environment(\.openWindow) private var openWindow  // macOS 14+ 标准窗口打开方式

    var body: some View {
        HStack(spacing: 0) {
// 侧边栏 - 会话列表
            sessionSidebar

// 主内容区域
            remoteWorkspaceContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarButtons
            }
        }
        .sheet(isPresented: $showingConnectionSheet) {
            NewConnectionSheet(
                isPresented: $showingConnectionSheet,
                initiallyShowAdvanced: newConnectionPrefersAdvanced
            )
        }
        .sheet(isPresented: $showingSettingsSheet) {
            RemoteDesktopSettingsView(isPresented: $showingSettingsSheet)
        }
        .onAppear(perform: bootstrapRemoteDesktopManagerIfNeeded)
// 订阅远程桌面管理器的会话发布，实时更新侧边栏列表
        .onReceive(remoteDesktopManager.sessions) { sessions in
// 说明：该订阅仅更新会话快照，不改变连接状态
            self.allSessions = sessions
            syncSelectedSession(with: sessions)
        }
        .onReceive(RemoteDesktopSettingsManager.shared.settings.$displaySettings) { displaySettings in
            applyRemoteDesktopFullScreen(displaySettings.fullScreenMode, persist: false)
        }
    }

    private func bootstrapRemoteDesktopManagerIfNeeded() {
        guard !hasRequestedManagerBootstrap else { return }
        hasRequestedManagerBootstrap = true

 // 延迟初始化，避免在视图创建时立即启动所有服务；管理器自身保证幂等。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            remoteDesktopManager.bootstrap()
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
 // 让模式真正路由到对应的连接入口（此前仅 .nearField 有动作，其余只更新徽章=仅显示）：
 // 自动→设备发现（推荐 P2P，自动选路）；近距→近距硬件镜像窗口（NearFieldMirrorView 真实实现）；
 // 远距→高级手动 RDP/VNC/SSH 连接表单。三个目标均为已落地能力。
                    switch mode {
                    case .auto:
                        NotificationCenter.default.post(name: .skybridgeNavigateToDeviceDiscovery, object: nil)
                    case .nearField:
                        openWindow(id: "near-field-mirror")
                    case .farFieldRDP:
                        newConnectionPrefersAdvanced = true
                        showingConnectionSheet = true
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
            Button(action: {
                newConnectionPrefersAdvanced = false
                showingConnectionSheet = true
            }) {
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
    private var remoteWorkspaceContent: some View {
 // 用 ScrollView 包裹，与其它标签页一致：窗口变窄/变矮时内容可滚动，
 // 避免面板（previewPanel minHeight 420）溢出被裁剪、导致控件点不到（非响应式问题的根因之一）。
        ScrollView {
            VStack(spacing: 16) {
                trustedActiveSessionsPanel
                previewPanel
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
 // 背景透明，由 DashboardBackgroundView 统一提供主题背景；各面板自带玻璃/材质表面，
 // 不再叠加不透明深色渐变（那会形成与全局主题割裂的硬边深色矩形）。
        .background(Color.clear)
        .scrollIndicators(.hidden)
    }

    private var trustedActiveSessionsPanel: some View {
        remoteSurfacePanel(
            title: "Trusted Active Sessions",
            trailing: filteredActiveSessions.isEmpty ? "No active session" : "\(filteredActiveSessions.count) active"
        ) {
            if filteredActiveSessions.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Trusted peers will appear here once a verified remote session is established.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Button(LocalizationManager.shared.localizedString("remote.connect.recommended")) {
                            NotificationCenter.default.post(name: .skybridgeNavigateToDeviceDiscovery, object: nil)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(LocalizationManager.shared.localizedString("remote.connect.advanced")) {
                            newConnectionPrefersAdvanced = true
                            showingConnectionSheet = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    ForEach(filteredActiveSessions.prefix(3)) { session in
                        remoteSessionSummaryCard(for: session)
                    }
                }
            }
        }
    }

    private var previewPanel: some View {
        remoteSurfacePanel(
            title: "Preview",
            trailing: previewSession.map { "\(String(format: "%.0f", $0.frameLatencyMilliseconds)) ms" } ?? "Idle"
        ) {
            if let session = previewSession {
                VStack(spacing: 14) {
                    remoteDesktopToolbar(for: session)
                    remoteDisplayArea(for: session)
                        .frame(maxWidth: .infinity, minHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            } else {
                emptyStateView
                    .frame(maxWidth: .infinity, minHeight: 420)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.black.opacity(0.22))
                    )
            }
        }
    }

    private func remoteDesktopToolbar(for session: RemoteSessionSummary) -> some View {
        HStack {
// 连接信息
            VStack(alignment: .leading, spacing: 2) {
                Text(session.targetName)
                    .font(.headline)
                    .foregroundColor(.primary)

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor(for: session))
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
                        .foregroundColor(showPerformanceOverlay ? .green : .primary)
                }
                .help(LocalizationManager.shared.localizedString("remote.performance.monitor"))

// 质量设置
                Menu {
                    ForEach(VideoQuality.allCases, id: \.self) { quality in
                        Button {
 // 写入真实设置并下发到活跃会话；此前只设置一个从不被读取的 selectedQuality（=假阳性）。
                            RemoteDesktopSettingsManager.shared.settings.displaySettings.videoQuality = quality
                            RemoteDesktopSettingsManager.shared.saveSettings()
                            remoteDesktopManager.reapplyCurrentSettingsToActiveSessions()
                        } label: {
                            Label(
                                quality.displayName,
                                systemImage: RemoteDesktopSettingsManager.shared.settings.displaySettings.videoQuality == quality ? "checkmark" : ""
                            )
                        }
                    }
                } label: {
                    Image(systemName: "tv")
                        .foregroundColor(.primary)
                }
                .menuStyle(.borderlessButton)

// 设置按钮
                Button(action: { showingSettingsSheet = true }) {
                    Image(systemName: "gearshape")
                        .foregroundColor(.primary)
                }
                .help(LocalizationManager.shared.localizedString("remote.settings.help"))

// 全屏切换
                Button(action: toggleRemoteDesktopFullScreen) {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .foregroundColor(.primary)
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
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
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
 /// 指标来自当前会话的真实测量（RemoteFrameRenderer → RemoteSessionSummary），
 /// 不再使用恒为 0 的占位 renderMetrics 与硬编码的 "92% GPU"（那是假数据 / 假阳性）。
    @ViewBuilder
    private func performanceOverlay(for session: RemoteSessionSummary) -> some View {
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

 // 真实性能指标（会话级测量）
                VStack(alignment: .trailing, spacing: 4) {
                    performanceMetric(
                        icon: "speedometer",
                        label: "解码",
                        value: "\(Int(session.frameLatencyMilliseconds))ms",
                        color: session.frameLatencyMilliseconds < 30 ? .green : .orange
                    )

                    performanceMetric(
                        icon: "arrow.down.circle",
                        label: "带宽",
                        value: String(format: "%.1f Mbps", session.bandwidthMbps),
                        color: session.bandwidthMbps > 50 ? .green : .orange
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
                    performanceOverlay(for: session),
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

            HStack(spacing: 12) {
                Button(LocalizationManager.shared.localizedString("remote.connect.recommended")) {
                    NotificationCenter.default.post(name: .skybridgeNavigateToDeviceDiscovery, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(LocalizationManager.shared.localizedString("remote.connect.advanced")) {
                    newConnectionPrefersAdvanced = true
                    showingConnectionSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: 400)
    }

    private var previewSession: RemoteSessionSummary? {
        if let selectedSession,
           let refreshedSession = allSessions.first(where: { $0.id == selectedSession.id }) {
            return refreshedSession
        }
        return filteredActiveSessions.first
    }

    private func remoteSessionSummaryCard(for session: RemoteSessionSummary) -> some View {
        Button {
            selectedSession = session
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.targetName)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(session.protocolDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Label(session.status.rawValue.capitalized, systemImage: "checkmark.shield")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(statusColor(for: session).opacity(0.16), in: Capsule())
                        .foregroundColor(statusColor(for: session))
                }

                HStack(spacing: 12) {
                    remoteMetricPill(
                        title: "Transport",
                        value: "\(String(format: "%.1f", session.bandwidthMbps)) Mbps",
                        icon: "arrow.left.arrow.right",
                        color: .blue
                    )
                    remoteMetricPill(
                        title: "Latency",
                        value: "\(String(format: "%.0f", session.frameLatencyMilliseconds)) ms",
                        icon: "waveform.path.ecg",
                        color: .green
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selectedSession?.id == session.id ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(selectedSession?.id == session.id ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func remoteMetricPill(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.10))
        )
    }

    private func remoteSurfacePanel<Content: View>(title: String, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.primary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }

            content()
        }
        .padding(20)
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(themeConfiguration.cardBackgroundMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(themeConfiguration.borderColor, lineWidth: 1)
                    )
            }
        }
    }

    private func syncSelectedSession(with sessions: [RemoteSessionSummary]) {
        if let selectedSession,
           let refreshedSession = sessions.first(where: { $0.id == selectedSession.id }) {
            self.selectedSession = refreshedSession
            return
        }
        self.selectedSession = sessions.first
    }

    private func statusColor(for session: RemoteSessionSummary) -> Color {
        switch session.status {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected, .failed:
            return .red
        }
    }

// MARK: - 工具栏按钮
    private var toolbarButtons: some View {
        Group {
            Menu {
                Button(LocalizationManager.shared.localizedString("remote.connect.recommended")) {
                    NotificationCenter.default.post(name: .skybridgeNavigateToDeviceDiscovery, object: nil)
                }
                Button(LocalizationManager.shared.localizedString("remote.connect.advanced")) {
                    newConnectionPrefersAdvanced = true
                    showingConnectionSheet = true
                }
            } label: {
                Image(systemName: "plus")
            }
            .help(LocalizationManager.shared.localizedString("remote.toolbar.newConnection.help"))

            Button(action: refreshSessions) {
                Image(systemName: "arrow.clockwise")
            }
            .help(LocalizationManager.shared.localizedString("remote.toolbar.refresh.help"))

 // 设置入口：此前仅在“有活跃会话”的预览工具栏里出现，空闲时根本点不到。
 // 移到始终可见的顶部工具栏，保证任何时候都能打开远程桌面设置。
            Button(action: { showingSettingsSheet = true }) {
                Image(systemName: "gearshape")
            }
            .help(LocalizationManager.shared.localizedString("remote.settings.help"))
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

    private func toggleRemoteDesktopFullScreen() {
        applyRemoteDesktopFullScreen(!isFullScreen, persist: true)
    }

    private func applyRemoteDesktopFullScreen(_ enabled: Bool, persist: Bool) {
        let targetWindow = NSApp.mainWindow ?? NSApp.keyWindow
        let windowIsFullScreen = targetWindow?.styleMask.contains(.fullScreen) ?? false
        isFullScreen = enabled
        if persist {
            RemoteDesktopSettingsManager.shared.settings.displaySettings.fullScreenMode = enabled
        }
        if windowIsFullScreen != enabled {
            targetWindow?.toggleFullScreen(nil)
        }
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
        newConnectionPrefersAdvanced = true
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
    let initiallyShowAdvanced: Bool
    @State private var hostname = ""
    @State private var port = "3389"
    @State private var username = ""
    @State private var password = ""
    @State private var selectedProtocol: RemoteProtocol = .rdp
    @State private var showAdvanced: Bool
 // 连接错误提示
    @State private var connectError: String?
    @Environment(\.openWindow) private var openWindow

    init(isPresented: Binding<Bool>, initiallyShowAdvanced: Bool = false) {
        self._isPresented = isPresented
        self.initiallyShowAdvanced = initiallyShowAdvanced
        self._showAdvanced = State(initialValue: initiallyShowAdvanced)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(LocalizationManager.shared.localizedString("remote.form.recommended.section")) {
                    Text(LocalizationManager.shared.localizedString("remote.form.recommended.body"))
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(LocalizationManager.shared.localizedString("remote.form.openDeviceDiscovery")) {
                        NotificationCenter.default.post(name: .skybridgeNavigateToDeviceDiscovery, object: nil)
                        isPresented = false
                    }
                }

                Section {
                    DisclosureGroup(
                        LocalizationManager.shared.localizedString("remote.form.advanced.section"),
                        isExpanded: $showAdvanced
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(LocalizationManager.shared.localizedString("remote.form.protocol"), selection: $selectedProtocol) {
                                ForEach(RemoteProtocol.allCases, id: \.self) { protocolType in
                                    Text(protocolType.displayName).tag(protocolType)
                                }
                            }

                            TextField(LocalizationManager.shared.localizedString("remote.form.hostname"), text: $hostname)
                            TextField(LocalizationManager.shared.localizedString("remote.form.port"), text: $port)

                            Divider()

                            TextField(LocalizationManager.shared.localizedString("auth.username"), text: $username)
                            SecureField(LocalizationManager.shared.localizedString("auth.password"), text: $password)
                        }
                        .padding(.vertical, 6)
                    }
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
                    .disabled(!showAdvanced || hostname.isEmpty || username.isEmpty)
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
        .onChange(of: selectedProtocol) { _, newValue in
            switch newValue {
            case .rdp:
                if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || port == "22" || port == "5900" {
                    port = "3389"
                }
            case .ssh:
                if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || port == "3389" || port == "5900" {
                    port = "22"
                }
            case .vnc:
                if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || port == "3389" || port == "22" {
                    port = "5900"
                }
            }
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
 // macOS 规范：表单类 sheet 不要用 NavigationView + TabView(.tabItem)。
 // 这两者叠加会：①重复渲染出第二条原生标签栏（与下方分段选择器重复）；
 // ②在固定尺寸 sheet 内与 TabView 互相争夺布局，导致内容区空白并卡死（你截图里的现象）。
 // 改为标准结构：标题 + 单一分段选择器 + 按所选标签切换的单一内容区 + 底部操作栏。
        VStack(spacing: 0) {
            HStack {
                Text("远程桌面设置")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)

            settingsTabPicker

            Divider()

 // 只构建当前选中的设置页（不再让 TabView 一次性预建三个 Form）
            Group {
                switch selectedTab {
                case .display:
                    displaySettingsView
                case .interaction:
                    interactionSettingsView
                case .network:
                    networkSettingsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

 // 底部操作栏（替代 NavigationView 的 toolbar）
            HStack {
                Button("重置") { resetSettings() }
                Spacer()
                Button("应用") { applySettings() }
                    .buttonStyle(.bordered)
                Button("完成") { saveAndClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
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

                Picker("渲染层级", selection: $settingsManager.settings.displaySettings.renderingMode) {
                    ForEach(RenderingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .help("P2P 远程桌面观看的渲染层级；高保真层级会按本机硬件能力自动降级。修改在下次开流时生效。")

                Picker("编码档位", selection: $settingsManager.settings.displaySettings.encodingProfile) {
                    ForEach(EncodingProfile.allCases, id: \.self) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .help("视频编码 ProfileLevel；自动会按编码器与内容选择合适档位。")

                Toggle("低延迟模式", isOn: $settingsManager.settings.displaySettings.lowLatencyMode)
                    .help("减小 GOP、关闭 B 帧以降低端到端延迟，可能略微增加码率。")

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

                Toggle(
                    LocalizationManager.shared.localizedString("settings.remote.interaction.audioRedirection"),
                    isOn: $settingsManager.settings.interactionSettings.enableAudioRedirection
                )
                .help("播放远端桌面中的系统音频")

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
                Text(settingsManager.settings.networkSettings.connectionType.remoteDesktopScopeDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)

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
                HStack {
                    Text("启用网络加密")
                    Spacer()
                    Text("Strict-PQC / TLS 1.3")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.green)
                }
                .help("远程桌面传输强制使用加密，不能在生产环境关闭")

                Toggle("启用 UDP 传输", isOn: $settingsManager.settings.networkSettings.enableUDPTransport)
                    .help("远程桌面推流（WebRTC）依赖 UDP 传输：关闭后将无法建立远程桌面画面推流，并非可选的性能优化项")

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
// 说明：视频质量统一使用 SkyBridgeCore 的 VideoQuality（与设置/会话下发一致），
// 不再保留本文件内同名的本地副本（此前是无人使用的死代码）。

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

