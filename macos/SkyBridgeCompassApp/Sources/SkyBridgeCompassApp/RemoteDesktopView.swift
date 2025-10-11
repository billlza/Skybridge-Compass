import SwiftUI
import SkyBridgeCore

/// 远程桌面连接管理界面
struct RemoteDesktopView: View {
    @StateObject private var remoteDesktopManager = RemoteDesktopManager()
    @State private var selectedSession: RemoteSessionSummary?
    @State private var isFullScreen = false
    @State private var showingConnectionSheet = false
    @State private var searchText = ""
    @State private var selectedQuality: VideoQuality = .high
    
    var body: some View {
        NavigationSplitView {
            // 侧边栏 - 会话列表
            sessionSidebar
        } detail: {
            // 主内容区域
            if let session = selectedSession {
                remoteDesktopContent(for: session)
            } else {
                emptyStateView
            }
        }
        .navigationTitle("远程桌面")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarButtons
            }
        }
        .sheet(isPresented: $showingConnectionSheet) {
            NewConnectionSheet(isPresented: $showingConnectionSheet)
        }
        .onAppear {
            // 延迟初始化，避免在视图创建时立即启动所有服务
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                remoteDesktopManager.bootstrap()
            }
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
        .frame(minWidth: 280)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("搜索会话...", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
    
    private var sessionList: some View {
        List(selection: $selectedSession) {
            Section("活跃会话") {
                ForEach(filteredActiveSessions) { session in
                    SessionRowView(session: session, isSelected: selectedSession?.id == session.id)
                        .tag(session)
                        .contextMenu {
                            sessionContextMenu(for: session)
                        }
                }
            }
            
            Section("最近连接") {
                ForEach(filteredRecentSessions) { session in
                    RecentSessionRowView(session: session)
                        .contextMenu {
                            recentSessionContextMenu(for: session)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
    
    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            Button(action: { showingConnectionSheet = true }) {
                Label("新建连接", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
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
    
    private func remoteDisplayArea(for session: RemoteSessionSummary) -> some View {
        GeometryReader { geometry in
            RemoteDisplayView(textureFeed: remoteDesktopManager.textureFeed)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay(
                    // 连接状态覆盖层
                    connectionStatusOverlay(for: session),
                    alignment: .center
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
                    
                    Text("正在连接到 \(session.targetName)...")
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
                Text("选择一个会话开始远程桌面")
                    .font(.title2)
                    .fontWeight(.medium)
                
                Text("从左侧列表选择活跃会话，或创建新的远程连接")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button("新建连接") {
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
            .help("新建远程连接")
            
            Button(action: refreshSessions) {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新会话列表")
        }
    }
    
    // MARK: - 上下文菜单
    private func sessionContextMenu(for session: RemoteSessionSummary) -> some View {
        Group {
            Button("聚焦窗口") {
                remoteDesktopManager.focus(on: session.id)
            }
            
            Button("断开连接") {
                disconnectSession(session)
            }
            
            Divider()
            
            Button("复制连接信息") {
                copySessionInfo(session)
            }
        }
    }
    
    private func recentSessionContextMenu(for session: RemoteSessionSummary) -> some View {
        Group {
            Button("重新连接") {
                reconnectToSession(session)
            }
            
            Button("从历史中移除") {
                removeFromHistory(session)
            }
        }
    }
    
    // MARK: - 计算属性
    private var filteredActiveSessions: [RemoteSessionSummary] {
        // TODO: 从 remoteDesktopManager 获取活跃会话并根据搜索文本过滤
        []
    }
    
    private var filteredRecentSessions: [RemoteSessionSummary] {
        // TODO: 从历史记录获取最近会话并根据搜索文本过滤
        []
    }
    
    // MARK: - 操作方法
    private func refreshSessions() {
        // TODO: 刷新会话列表
        print("刷新会话列表")
    }
    
    private func disconnectSession(_ session: RemoteSessionSummary) {
        // TODO: 断开指定会话
        print("断开会话: \(session.targetName)")
    }
    
    private func copySessionInfo(_ session: RemoteSessionSummary) {
        let info = "远程桌面会话: \(session.targetName)\n协议: \(session.protocolDescription)\n带宽: \(session.bandwidthMbps) Mbps"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }
    
    private func reconnectToSession(_ session: RemoteSessionSummary) {
        // TODO: 重新连接到会话
        print("重新连接到: \(session.targetName)")
    }
    
    private func removeFromHistory(_ session: RemoteSessionSummary) {
        // TODO: 从历史记录中移除
        print("从历史中移除: \(session.targetName)")
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
        }
    }
}

// MARK: - 最近会话行视图
struct RecentSessionRowView: View {
    let session: RemoteSessionSummary
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .foregroundColor(.secondary)
                .frame(width: 16, height: 16)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(session.targetName)
                    .font(.subheadline)
                    .lineLimit(1)
                
                Text("上次连接: \(formatLastConnected())")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Button(action: {}) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }
    
    private func formatLastConnected() -> String {
        // TODO: 格式化最后连接时间
        return "刚刚"
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
    
    var body: some View {
        NavigationView {
            Form {
                Section("连接信息") {
                    TextField("主机名或IP地址", text: $hostname)
                    TextField("端口", text: $port)
                    
                    Picker("协议", selection: $selectedProtocol) {
                        ForEach(RemoteProtocol.allCases, id: \.self) { protocolType in
                            Text(protocolType.displayName).tag(protocolType)
                        }
                    }
                }
                
                Section("认证") {
                    TextField("用户名", text: $username)
                    SecureField("密码", text: $password)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("新建远程连接")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        connectToRemote()
                    }
                    .disabled(hostname.isEmpty || username.isEmpty)
                }
            }
        }
        .frame(width: 500, height: 400)
    }
    
    private func connectToRemote() {
        // TODO: 实现远程连接逻辑
        print("连接到: \(hostname):\(port)")
        isPresented = false
    }
}

// MARK: - 远程桌面设置视图
struct RemoteDesktopSettingsView: View {
    @Binding var isPresented: Bool
    @Binding var selectedQuality: VideoQuality
    @State private var enableClipboardSync = true
    @State private var enableAudioRedirection = true
    @State private var compressionLevel = 50.0
    
    var body: some View {
        NavigationView {
            Form {
                Section("显示设置") {
                    Picker("视频质量", selection: $selectedQuality) {
                        ForEach(VideoQuality.allCases, id: \.self) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    
                    VStack(alignment: .leading) {
                        Text("压缩级别: \(Int(compressionLevel))%")
                        Slider(value: $compressionLevel, in: 0...100, step: 10)
                    }
                }
                
                Section("功能设置") {
                    Toggle("剪贴板同步", isOn: $enableClipboardSync)
                    Toggle("音频重定向", isOn: $enableAudioRedirection)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("远程桌面设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        isPresented = false
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
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

// MARK: - 会话状态扩展
extension RemoteSessionSummary {
    var status: SessionStatus {
        // TODO: 从实际会话状态获取
        return .connected
    }
}

enum SessionStatus {
    case connected, connecting, disconnected
}

#Preview {
    RemoteDesktopView()
        .frame(width: 1200, height: 800)
}