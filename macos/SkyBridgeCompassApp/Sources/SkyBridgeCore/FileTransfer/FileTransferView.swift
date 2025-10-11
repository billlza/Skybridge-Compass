import SwiftUI
import UniformTypeIdentifiers

/// 现代化文件传输主界面 - 支持拖拽上传、进度监控和历史记录
/// 采用Apple设计规范和macOS最佳实践
public struct FileTransferView: View {
    
    // MARK: - 初始化器
    
    /// 公共初始化器，允许外部模块创建实例
    public init() {}
    
    // MARK: - 状态管理
    
    @StateObject private var transferEngine = FileTransferEngine()
    @StateObject private var networkManager = P2PNetworkManager.shared
    @State private var selectedTab: TransferTab = .active
    @State private var showingFilePicker = false

    @State private var dragOver = false
    @State private var selectedDevice: P2PDevice?
    @State private var searchText = ""
    
    // MARK: - 主视图
    
    public var body: some View {
        NavigationSplitView {
            // 现代化侧边栏
            modernSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } detail: {
            // 主内容区域
            VStack(spacing: 0) {
                // 现代化顶部工具栏
                modernTopToolbar
                
                // 搜索栏
                modernSearchBar
                
                // 主要内容区域
                mainContentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
                handleDroppedFiles(providers)
            }
            .overlay(
                modernDragOverlay,
                alignment: .center
            )
        }
        .navigationTitle("文件传输")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { refreshDevices() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新设备列表")
            }
        }
        .sheet(isPresented: $showingFilePicker) {
            ModernFilePickerView { urls in
                handleSelectedFiles(urls)
            }
        }
        .onDisappear {
            // 视图销毁时清理FileTransferEngine资源，防止内存泄漏
            transferEngine.cleanup()
        }
    }
    
    // MARK: - 现代化侧边栏
    
    private var modernSidebar: some View {
        VStack(spacing: 0) {
            // 侧边栏标题
            HStack {
                Text("文件传输")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            // 快速统计
            quickStatsCard
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            
            // 导航选项
            VStack(spacing: 4) {
                ForEach(TransferTab.allCases, id: \.self) { tab in
                    SidebarNavigationItem(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        count: getTabCount(for: tab)
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 12)
            
            Spacer()
            
            // 底部快速操作
            quickActionsSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    // MARK: - 快速统计卡片
    
    private var quickStatsCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("活跃传输")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(transferEngine.activeTransfers.count)")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("传输速度")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatSpeed(transferEngine.transferSpeed))
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                }
            }
            
            if !transferEngine.activeTransfers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("总体进度")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatProgress(transferEngine.totalProgress))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    ProgressView(value: transferEngine.totalProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                        .scaleEffect(y: 0.8)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        )
    }
    
    // MARK: - 现代化顶部工具栏
    
    private var modernTopToolbar: some View {
        HStack {
            // 页面标题和描述
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedTab.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(selectedTab.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 操作按钮组
            HStack(spacing: 8) {
                if selectedTab == .active && !transferEngine.activeTransfers.isEmpty {
                    Button("暂停全部") {
                        pauseAllTransfers()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("取消全部") {
                        cancelAllTransfers()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                
                Button("选择文件") {
                    showingFilePicker = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            Color(NSColor.windowBackgroundColor)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color(NSColor.separatorColor)),
                    alignment: .bottom
                )
        )
    }
    
    // MARK: - 现代化搜索栏
    
    private var modernSearchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("搜索文件或设备...", text: $searchText)
                .textFieldStyle(.plain)
            
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
    
    // MARK: - 主内容区域
    
    private var mainContentArea: some View {
        Group {
            switch selectedTab {
            case .active:
                modernActiveTransfersView
            case .history:
                modernTransferHistoryView
            case .devices:
                modernDeviceSelectionView
            }
        }
    }
    
    // MARK: - 现代化活跃传输视图
    
    private var modernActiveTransfersView: some View {
        Group {
            if transferEngine.activeTransfers.isEmpty {
                modernEmptyActiveTransfersView
            } else {
                modernActiveTransfersList
            }
        }
    }
    
    private var modernEmptyActiveTransfersView: some View {
        VStack(spacing: 32) {
            // 拖拽区域
            modernDropZone
            
            // 快速操作
            modernQuickActions
        }
        .padding(20)
    }
    
    private var modernDropZone: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    dragOver ? Color.accentColor : Color(NSColor.separatorColor),
                    style: StrokeStyle(lineWidth: 2, dash: [12, 8])
                )
                .frame(height: 200)
                .overlay(
                    VStack(spacing: 16) {
                        Image(systemName: dragOver ? "doc.badge.plus.fill" : "doc.badge.plus")
                            .font(.system(size: 56))
                            .foregroundColor(dragOver ? .accentColor : .secondary)
                        
                        VStack(spacing: 8) {
                            Text("拖拽文件到此处")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            
                            Text("支持多文件同时传输，最大单文件 2GB")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        
                        Button("或点击选择文件") {
                            showingFilePicker = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(dragOver ? Color.accentColor.opacity(0.08) : Color.clear)
                )
                .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
                    handleDroppedFiles(providers)
                }
                .animation(.easeInOut(duration: 0.2), value: dragOver)
        }
    }
    
    private var modernQuickActions: some View {
        VStack(spacing: 16) {
            Text("快速操作")
                .font(.headline)
                .fontWeight(.medium)
            
            HStack(spacing: 16) {
                ModernQuickActionCard(
                    title: "发送到附近设备",
                    subtitle: "自动发现并连接",
                    icon: "antenna.radiowaves.left.and.right",
                    color: .blue
                ) {
                    showNearbyDevices()
                }
                
                ModernQuickActionCard(
                    title: "创建传输链接",
                    subtitle: "生成分享链接",
                    icon: "link",
                    color: .green
                ) {
                    createTransferLink()
                }
                
                ModernQuickActionCard(
                    title: "扫描二维码",
                    subtitle: "快速连接设备",
                    icon: "qrcode.viewfinder",
                    color: .orange
                ) {
                    scanQRCode()
                }
            }
        }
    }
    
    private var modernActiveTransfersList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(transferEngine.activeTransfers.values), id: \.id) { session in
                    ModernTransferSessionCard(session: session, engine: transferEngine)
                }
            }
            .padding(20)
        }
    }
    
    // MARK: - 现代化传输历史视图
    
    private var modernTransferHistoryView: some View {
        Group {
            if transferEngine.transferHistory.isEmpty {
                modernEmptyHistoryView
            } else {
                modernHistoryList
            }
        }
    }
    
    private var modernEmptyHistoryView: some View {
        VStack(spacing: 24) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("暂无传输历史")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Text("完成的传输记录将显示在这里")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
    
    private var modernHistoryList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(transferEngine.transferHistory) { record in
                    ModernTransferHistoryCard(record: record)
                }
            }
            .padding(20)
        }
    }
    
    // MARK: - 现代化设备选择视图
    
    private var modernDeviceSelectionView: some View {
        VStack(spacing: 0) {
            if networkManager.discoveredDevices.isEmpty {
                modernEmptyDevicesView
            } else {
                modernDevicesList
            }
        }
    }
    
    private var modernEmptyDevicesView: some View {
        VStack(spacing: 24) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("未发现附近设备")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Text("确保目标设备已开启SkyBridge并在同一网络")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button("刷新设备列表") {
                refreshDevices()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
    
    private var modernDevicesList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(networkManager.discoveredDevices) { device in
                    ModernDeviceCard(
                        device: device,
                        isSelected: selectedDevice?.deviceId == device.deviceId
                    ) {
                        selectedDevice = device
                    }
                }
            }
            .padding(20)
        }
    }
    
    // MARK: - 快速操作区域
    
    private var quickActionsSection: some View {
        VStack(spacing: 12) {
            Divider()
            
            VStack(spacing: 8) {
                Button(action: { showingFilePicker = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("添加文件")
                        Spacer()
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                
                Button(action: { refreshDevices() }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新设备")
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - 现代化拖拽覆盖层
    
    private var modernDragOverlay: some View {
        Group {
            if dragOver {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.accentColor.opacity(0.1))
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "doc.badge.plus.fill")
                                .font(.system(size: 72))
                                .foregroundColor(.accentColor)
                            
                            Text("释放以添加文件")
                                .font(.title2)
                                .fontWeight(.medium)
                                .foregroundColor(.accentColor)
                        }
                    )
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: dragOver)
    }
    
    // MARK: - 辅助方法
    
    private func getTabCount(for tab: TransferTab) -> Int {
        switch tab {
        case .active:
            return transferEngine.activeTransfers.count
        case .history:
            return transferEngine.transferHistory.count
        case .devices:
            return networkManager.discoveredDevices.count
        }
    }
    
    private func handleSelectedFiles(_ urls: [URL]) {
        guard let device = selectedDevice else {
            showDeviceSelectionAlert()
            return
        }
        
        for url in urls {
            Task {
                do {
                    // TODO: 实现文件传输启动逻辑
                    print("开始传输文件: \(url.lastPathComponent) 到设备: \(device.name)")
                } catch {
                    print("传输启动失败: \(error)")
                }
            }
        }
    }
    
    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                provider.loadObject(ofClass: URL.self) { url, error in
                    if let url = url {
                        urls.append(url)
                    }
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            if !urls.isEmpty {
                handleSelectedFiles(urls)
            }
        }
        
        return true
    }
    
    private func pauseAllTransfers() {
        for session in transferEngine.activeTransfers.values {
            transferEngine.pauseTransfer(session.id)
        }
    }
    
    private func cancelAllTransfers() {
        for session in transferEngine.activeTransfers.values {
            transferEngine.cancelTransfer(session.id)
        }
    }
    
    private func showNearbyDevices() {
        selectedTab = .devices
        refreshDevices()
    }
    
    private func createTransferLink() {
        // TODO: 实现创建传输链接功能
        print("创建传输链接")
    }
    
    private func scanQRCode() {
        // TODO: 实现扫描二维码功能
        print("扫描二维码")
    }
    
    private func refreshDevices() {
        Task {
            await networkManager.startDiscovery()
        }
    }
    
    private func showDeviceSelectionAlert() {
        // TODO: 显示设备选择提醒
        print("请先选择目标设备")
    }
    
    private func formatProgress(_ progress: Double) -> String {
        return String(format: "%.1f%%", progress * 100)
    }
    
    private func formatSpeed(_ speed: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return "\(formatter.string(fromByteCount: Int64(speed)))/s"
    }
}

// MARK: - 传输标签页枚举

enum TransferTab: String, CaseIterable {
    case active = "active"
    case history = "history"
    case devices = "devices"
    
    var displayName: String {
        switch self {
        case .active:
            return "活跃传输"
        case .history:
            return "传输历史"
        case .devices:
            return "设备选择"
        }
    }
    
    var description: String {
        switch self {
        case .active:
            return "正在进行的文件传输"
        case .history:
            return "已完成的传输记录"
        case .devices:
            return "可用的传输目标设备"
        }
    }
    
    var iconName: String {
        switch self {
        case .active:
            return "arrow.up.arrow.down.circle"
        case .history:
            return "clock.arrow.circlepath"
        case .devices:
            return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - 侧边栏导航项

struct SidebarNavigationItem: View {
    let tab: TransferTab
    let isSelected: Bool
    let count: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 20)
                
                Text(tab.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
                
                Spacer()
                
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.15))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 现代化快速操作卡片

struct ModernQuickActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(color)
                
                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                    
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 120, height: 100)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(1.0)
        .animation(.easeInOut(duration: 0.1), value: false)
    }
}

// MARK: - 现代化传输会话卡片

struct ModernTransferSessionCard: View {
    @ObservedObject var session: FileTransferSession
    let engine: FileTransferEngine
    
    var body: some View {
        VStack(spacing: 16) {
            // 文件信息头部
            HStack(spacing: 12) {
                Image(systemName: fileIcon)
                    .font(.system(size: 24))
                    .foregroundColor(fileColor)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(fileColor.opacity(0.1))
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.fileName)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 8) {
                        Text(session.type.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                            .foregroundColor(.accentColor)
                        
                        Text(formatFileSize(session.fileSize))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // 状态指示器
                HStack(spacing: 8) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                    
                    Text(session.state.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(stateColor)
                }
            }
            
            // 进度信息
            VStack(spacing: 8) {
                HStack {
                    Text("进度")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(formatProgress(session.progress))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                ProgressView(value: session.progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: stateColor))
                    .scaleEffect(y: 1.2)
            }
            
            // 传输统计
            HStack {
                if session.speed > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("传输速度")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(formatSpeed(session.speed))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
                
                Spacer()
                
                if session.estimatedTimeRemaining > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("剩余时间")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(formatTime(session.estimatedTimeRemaining))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
                
                // 操作菜单
                Menu {
                    if session.state == .transferring {
                        Button("暂停") {
                            engine.pauseTransfer(session.id)
                        }
                    } else if session.state == .paused {
                        Button("恢复") {
                            Task {
                                try await engine.resumeTransfer(session.id)
                            }
                        }
                    }
                    
                    Button("取消", role: .destructive) {
                        engine.cancelTransfer(session.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        )
    }
    
    private var fileIcon: String {
        let ext = (session.fileName as NSString).pathExtension.lowercased()
        let fileType = FileType.from(extension: ext)
        return fileType.iconName
    }
    
    private var fileColor: Color {
        let ext = (session.fileName as NSString).pathExtension.lowercased()
        let fileType = FileType.from(extension: ext)
        return Color(fileType.color)
    }
    
    private var stateColor: Color {
        return Color(session.state.color)
    }
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: size)
    }
    
    private func formatProgress(_ progress: Double) -> String {
        return String(format: "%.1f%%", progress * 100)
    }
    
    private func formatSpeed(_ speed: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return "\(formatter.string(fromByteCount: Int64(speed)))/s"
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = Int(time) % 3600 / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - 现代化传输历史卡片

struct ModernTransferHistoryCard: View {
    let record: FileTransferRecord
    
    var body: some View {
        HStack(spacing: 12) {
            // 文件图标
            Image(systemName: fileIcon)
                .font(.system(size: 20))
                .foregroundColor(fileColor)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(fileColor.opacity(0.1))
                )
            
            // 文件信息
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.fileName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(record.success ? .green : .red)
                }
                
                HStack(spacing: 8) {
                    Text(record.type.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Text(record.formattedFileSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(formatDate(record.endTime))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    private var fileIcon: String {
        let ext = (record.fileName as NSString).pathExtension.lowercased()
        let fileType = FileType.from(extension: ext)
        return fileType.iconName
    }
    
    private var fileColor: Color {
        let ext = (record.fileName as NSString).pathExtension.lowercased()
        let fileType = FileType.from(extension: ext)
        return Color(fileType.color)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - 现代化设备卡片

struct ModernDeviceCard: View {
    let device: P2PDevice
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                // 设备图标
                Image(systemName: device.deviceType.iconName)
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.1))
                    )
                
                // 设备信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 8) {
                        Text(device.deviceType.displayName)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        Text("•")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        ModernSignalStrengthIndicator(strength: device.signalStrength)
                    }
                }
                
                Spacer()
                
                // 选择指示器
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 现代化信号强度指示器

struct ModernSignalStrengthIndicator: View {
    let strength: Double
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: index))
                    .frame(width: 3, height: CGFloat(4 + index * 2))
            }
        }
    }
    
    private func barColor(for index: Int) -> Color {
        let threshold = Double(index + 1) / 4.0
        return strength >= threshold ? signalColor : Color.secondary.opacity(0.3)
    }
    
    private var signalColor: Color {
        if strength > 0.75 {
            return .green
        } else if strength > 0.5 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - 现代化文件选择器

struct ModernFilePickerView: NSViewControllerRepresentable {
    let onFilesSelected: ([URL]) -> Void
    
    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowedContentTypes = [.data, .image, .movie, .audio, .text, .pdf]
            
            panel.begin { response in
                if response == .OK {
                    self.onFilesSelected(panel.urls)
                }
            }
        }
        
        return controller
    }
    
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        // 无需更新
    }
}

// MARK: - 现代化传输设置视图

struct ModernTransferSettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 24) {
            // 标题
            HStack {
                Text("传输设置")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("完成") {
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            
            // 设置内容
            VStack(spacing: 16) {
                Text("设置界面开发中...")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Text("即将支持传输速度限制、自动重试、文件过滤等功能")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .frame(width: 500, height: 400)
        .padding(24)
        .background(Color(NSColor.windowBackgroundColor))
    }
}