//
// DashboardView.swift
// SkyBridgeCompassiOS
//
// iOS 主控制台 - 应用启动时的主界面
// 展示设备状态、快捷操作、连接管理等
//

import SwiftUI
import Foundation

// MARK: - Dashboard View

/// iOS 主控制台视图
@available(iOS 17.0, *)
public struct DashboardView: View {
    
    // MARK: - Environment & State
    
    @StateObject private var viewModel = DashboardViewModel.shared
    @StateObject private var discoveryManager = DeviceDiscoveryManager.instance
    @StateObject private var connectionManager = P2PConnectionManager.instance
    @StateObject private var fileTransferManager = FileTransferManager.instance
    @StateObject private var remoteDesktopManager = RemoteDesktopManager.instance
    @StateObject private var settingsManager = SettingsManager.instance
    @StateObject private var crossNetworkManager = CrossNetworkWebRTCManager.instance
    @EnvironmentObject private var authManager: AuthenticationManager
    
    @State private var selectedTab: DashboardTab = .home
    @State private var showingQRScanner = false
    @State private var showingSettings = false
    @State private var showingDeviceDetail: DiscoveredDevice?
    @State private var showingConnectionSheet = false
    @State private var crossNetworkAlertMessage: String?
    
    @Namespace private var animation
    
    // MARK: - Body
    
    public var body: some View {
        ZStack {
            // 背景渐变
            backgroundGradient

            WeatherEffectsBackgroundLayer(
                isActive: settingsManager.enableRealTimeWeather &&
                    !(fileTransferManager.isTransferring || remoteDesktopManager.isStreaming)
            )
            
            // 主内容
            TabView(selection: $selectedTab) {
                // 首页
                homeTab
                    .tabItem {
                        Label("首页", systemImage: "house.fill")
                    }
                    .tag(DashboardTab.home)
                
                // 设备
                devicesTab
                    .tabItem {
                        Label("设备", systemImage: "laptopcomputer.and.iphone")
                    }
                    .tag(DashboardTab.devices)
                
                // 文件
                filesTab
                    .tabItem {
                        Label("文件", systemImage: "folder.fill")
                    }
                    .tag(DashboardTab.files)
                
                // 远程桌面
                remoteTab
                    .tabItem {
                        Label("远程", systemImage: "display")
                    }
                    .tag(DashboardTab.remote)
                
                // 设置
                settingsTab
                    .tabItem {
                        Label("设置", systemImage: "gearshape.fill")
                    }
                    .tag(DashboardTab.settings)
            }
            .tint(.cyan)
        }
        .task {
            await viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .sheet(isPresented: $showingQRScanner) {
            QRCodeHubSheet(
                onScanPairingData: { qrData in
                handleQRCodeScan(qrData)
            },
                onScanConnectLink: { link in
                    Task {
                        await crossNetworkManager.connect(fromScannedString: link)
                        if case .failed(let msg) = crossNetworkManager.state {
                            crossNetworkAlertMessage = msg
                        }
                    }
                },
                onConnectWithCode: { code in
                    Task {
                        await crossNetworkManager.connect(withCode: code)
                        if case .failed(let msg) = crossNetworkManager.state {
                            crossNetworkAlertMessage = msg
                        }
                    }
                }
            )
        }
        .alert("跨网连接", isPresented: Binding(
            get: { crossNetworkAlertMessage != nil },
            set: { if !$0 { crossNetworkAlertMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(crossNetworkAlertMessage ?? "")
        }
        .sheet(item: $showingDeviceDetail) { device in
            DeviceDetailSheet(device: device)
        }
    }
    
    // MARK: - Background
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.05, blue: 0.15),
                Color(red: 0.08, green: 0.08, blue: 0.12),
                Color(red: 0.03, green: 0.03, blue: 0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    // MARK: - Home Tab
    
    private var homeTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 标题下方信息区：iPhone 图标 / iOS 版本 / PQC
                    // （按你的要求放在 SkyBridge Compass 标题下面，天气卡片放在其下方）
                    welcomeSection
                    
                    // 🌤️ 天气卡片 - 放在 iOS 版本信息下方、统计卡片上方
                    WeatherCardView()
                    
                    // 统计卡片
                    statsSection
                    
                    // 快捷操作
                    quickActionsSection
                    
                    // 最近设备
                    recentDevicesSection
                    
                    // 活跃连接
                    if !viewModel.activeConnections.isEmpty {
                        activeConnectionsSection
                    }
                }
                .padding()
            }
            .navigationTitle("SkyBridge Compass")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    UserAvatarButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingQRScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title3)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        if viewModel.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
    }
    
    // MARK: - Welcome Section
    
    private var welcomeSection: some View {
        HStack(spacing: 16) {
            // 设备图标
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)
                
                Image(systemName: "iphone")
                    .font(.title)
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                // 设备名称（单独一行，避免被挤没）
                Text(UIDevice.current.name)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)

                // 型号 + 芯片（第二行）
                Text("\(Self.currentModelDisplayName) · \(Self.currentChipDisplayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                Text("iOS \(UIDevice.current.systemVersion)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                // 网络状态
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.networkStatus.color)
                        .frame(width: 8, height: 8)
                    Text(viewModel.networkStatus.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // PQC 状态徽章
            VStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                Text("PQC")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.green)
            }
            .padding(8)
            .background(Color.green.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Device Model / Chip (best-effort)

    private static var currentModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(cString: ptr)
            }
        }
    }

    private static var currentModelDisplayName: String {
        // 只维护你当前机型/常见机型；其余回退到 identifier
        switch currentModelIdentifier {
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone17,2": return "iPhone 16 Pro Max"
        case "iPhone17,3": return "iPhone 16"
        case "iPhone17,4": return "iPhone 16 Plus"
        default:
            return currentModelIdentifier
        }
    }

    private static var currentChipDisplayName: String {
        switch currentModelIdentifier {
        case "iPhone17,1", "iPhone17,2": return "A18 Pro"
        case "iPhone17,3", "iPhone17,4": return "A18"
        default:
            return "Apple Silicon"
        }
    }
    
    // MARK: - Stats Section
    
    private var statsSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            StatCardView(
                title: "在线设备",
                value: "\(viewModel.metrics.onlineDevices)",
                icon: "laptopcomputer",
                color: .blue
            )
            
            StatCardView(
                title: "活跃会话",
                value: "\(viewModel.metrics.activeSessions)",
                icon: "display",
                color: .green
            )
            
            StatCardView(
                title: "传输任务",
                value: "\(viewModel.metrics.fileTransfers)",
                icon: "folder",
                color: .orange
            )
            
            StatCardView(
                title: "性能状态",
                value: viewModel.performanceStatus.displayName,
                icon: viewModel.performanceStatus.icon,
                color: viewModel.performanceStatus.color
            )
        }
    }
    
    // MARK: - Quick Actions Section
    
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷操作")
                .font(.headline)
                .foregroundColor(.white)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                QuickActionButtonView(
                    title: "扫描",
                    icon: "magnifyingglass",
                    color: .blue
                ) {
                    viewModel.triggerDiscoveryRefresh()
                }
                
                QuickActionButtonView(
                    title: "传输",
                    icon: "arrow.up.arrow.down",
                    color: .orange
                ) {
                    selectedTab = .files
                }
                
                QuickActionButtonView(
                    title: "远程",
                    icon: "display",
                    color: .cyan
                ) {
                    selectedTab = .remote
                }
                
                QuickActionButtonView(
                    title: "二维码",
                    icon: "qrcode",
                    color: .purple
                ) {
                    showingQRScanner = true
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Recent Devices Section
    
    private var recentDevicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("附近设备")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Button("查看全部") {
                    selectedTab = .devices
                }
                .font(.subheadline)
                .foregroundColor(.cyan)
            }
            
            if viewModel.discoveredDevices.isEmpty {
                EmptyDevicesView()
            } else {
                ForEach(viewModel.discoveredDevices.prefix(3)) { device in
                    DeviceRowView(
                        device: device,
                        connectionStatus: connectionManager.connectionStatusByDeviceId[device.id]
                    ) {
                        showingDeviceDetail = device
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Active Connections Section
    
    private var activeConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("活跃连接")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Text("\(viewModel.activeConnections.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.2))
                    .clipShape(Capsule())
            }
            
            ForEach(viewModel.activeConnections) { connection in
                ConnectionRowView(connection: connection) {
                    // 断开连接
                    Task {
                        await viewModel.disconnect(from: connection.device)
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Devices Tab
    
    private var devicesTab: some View {
        DeviceDiscoveryView()
    }
    
    // MARK: - Files Tab
    
    private var filesTab: some View {
        FileTransferView()
    }
    
    // MARK: - Remote Tab
    
    private var remoteTab: some View {
        RemoteDesktopView()
    }
    
    // MARK: - Settings Tab
    
    private var settingsTab: some View {
        SettingsView()
    }
    
    // MARK: - Methods
    
    private func handleQRCodeScan(_ data: QRCodeData) {
        showingQRScanner = false
        
        // 处理扫描到的二维码数据
        if data.type == .devicePairing {
            // 连接到设备
            if let ip = data.ipAddress, let _ = data.port {
                Task {
                    let skybridgeTCP = DiscoveryServiceType.skybridge.rawValue
                    let portMap: [String: UInt16] = data.port.map { [skybridgeTCP: $0] } ?? [:]
                    let device = DiscoveredDevice(
                        id: data.deviceId,
                        name: data.deviceName,
                        modelName: "Unknown",
                        platform: .unknown,
                        osVersion: "Unknown",
                        ipAddress: ip,
                        services: [skybridgeTCP],
                        portMap: portMap,
                        signalStrength: -50,
                        lastSeen: Date()
                    )
                    try? await viewModel.quickConnect(to: device)
                }
            }
        }
    }
}

// MARK: - User Avatar (Supabase)

@available(iOS 17.0, *)
private struct UserAvatarButton: View {
    @EnvironmentObject private var authManager: AuthenticationManager

    private var displayName: String {
        authManager.currentUser?.displayName ?? "用户"
    }

    private var avatarURL: URL? {
        authManager.currentUser?.avatarURL
    }

    private var initials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "U" }
        // 取前 2 个可见字符
        return String(trimmed.prefix(2)).uppercased()
    }

    var body: some View {
        Button {
            // 预留：进入个人资料/账号页（与 macOS 保持一致）
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.08))

                if let url = avatarURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView().controlSize(.mini)
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Text(initials)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(initials)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("用户：\(displayName)"))
    }
}

// MARK: - QR Hub Sheet (Scan / My QR)

@available(iOS 17.0, *)
private struct QRCodeHubSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case scan = "扫描"
        case myQR = "我的二维码"
        case code = "连接码"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .scan
    @State private var pendingPairing: QRCodeData?
    @State private var scannerSessionID = UUID()
    @State private var isConnecting = false
    @State private var codeInput: String = ""

    let onScanPairingData: (QRCodeData) -> Void
    let onScanConnectLink: (String) -> Void
    let onConnectWithCode: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("mode", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Group {
                    switch mode {
                    case .scan:
                        ZStack {
                            QRCodeScannerView(
                                onScan: { data in
                                    // 扫到配对码：先弹确认卡片，不直接连接
                                    pendingPairing = data
                                },
                                onScanString: { string in
                                    // 兼容 macOS 跨网二维码：skybridge://connect/<base64>
                                    if string.hasPrefix("skybridge://connect/") {
                                        SkyBridgeLogger.shared.info("🌐 扫描到跨网连接二维码")
                                        onScanConnectLink(string)
                                        dismiss()
                                        return
                                    }
                                    // 非配对二维码：先简单提示（后续可扩展文件分享等）
                                    SkyBridgeLogger.shared.info("📷 扫描到字符串二维码: \(string)")
                                },
                                onError: { error in
                                    SkyBridgeLogger.shared.error("❌ 扫码失败: \(error.localizedDescription)")
                                }
                            )
                            // 用 id 强制重建 VC，从而支持“重新扫描”
                            .id(scannerSessionID)
                            .ignoresSafeArea()

                            if let pendingPairing {
                                // 半透明遮罩
                                Color.black.opacity(0.35)
                                    .ignoresSafeArea()

                                QRCodePairingConfirmCard(
                                    data: pendingPairing,
                                    isConnecting: isConnecting,
                                    onCancel: {
                                        self.pendingPairing = nil
                                        self.isConnecting = false
                                        self.scannerSessionID = UUID() // 重新开始扫描
                                    },
                                    onConnect: {
                                        isConnecting = true
                                        onScanPairingData(pendingPairing)
                                        dismiss()
                                    }
                                )
                                .padding(.horizontal, 20)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }

                    case .myQR:
                        MyPairingQRCodeView()
                        
                    case .code:
                        VStack(spacing: 16) {
                            Spacer()
                            
                            VStack(spacing: 10) {
                                Image(systemName: "number.square")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.cyan)
                                
                                Text("输入连接码")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.primary)
                                
                                Text("请输入 macOS 显示的 6 位智能连接码")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 20)
                            
                            TextField("例如：AB12CD", text: $codeInput)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 18)
                                .padding(.horizontal, 16)
                                .background(Color(white: 1.0).opacity(0.08))
                                .cornerRadius(14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                )
                                .padding(.horizontal, 24)
                                .onChange(of: codeInput) { _, newValue in
                                    codeInput = String(newValue.prefix(6).uppercased().filter { $0.isLetter || $0.isNumber })
                                }
                            
                            Button {
                                let code = codeInput
                                onConnectWithCode(code)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.right.circle.fill")
                                    Text("连接")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                            .disabled(codeInput.count != 6)
                            .padding(.horizontal, 24)
                            
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

@available(iOS 17.0, *)
private struct QRCodePairingConfirmCard: View {
    let data: QRCodeData
    let isConnecting: Bool
    let onCancel: () -> Void
    let onConnect: () -> Void

    private var addressText: String {
        let ip = data.ipAddress ?? "未知地址"
        if let port = data.port {
            return "\(ip):\(port)"
        }
        return ip
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("确认连接")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("扫描到设备配对信息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                InfoRow(label: "设备", value: data.deviceName)
                InfoRow(label: "地址", value: addressText)
                InfoRow(label: "端口", value: data.port.map(String.init) ?? "—")
            }
            .padding(.top, 4)

            HStack(spacing: 12) {
                Button("取消") { onCancel() }
                    .buttonStyle(.bordered)

                Button {
                    onConnect()
                } label: {
                    HStack(spacing: 8) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isConnecting ? "连接中..." : "连接")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting || data.ipAddress == nil)
            }
            .padding(.top, 6)

            if data.ipAddress == nil {
                Text("此二维码未包含可连接的 IP/端口信息。请使用新版配对码。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        // 液态玻璃卡片（iOS 26+ 使用 glassEffect；旧系统回退 ultraThinMaterial）
        .liquidGlassCard(cornerRadius: 22, padding: 0)
    }
}

@available(iOS 17.0, *)
private struct MyPairingQRCodeView: View {
    @State private var qrImage: UIImage?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if let errorText {
                Text(errorText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                ProgressView()
            }

            Text("让 macOS / 其他设备扫描此二维码以配对连接")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("刷新") {
                Task { await generate() }
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
        .task { await generate() }
    }

    private func generate() async {
        errorText = nil
        qrImage = nil

        // 本机局域网 IP（best-effort）
        guard let ip = LocalIP.bestEffortIPv4() else {
            errorText = "未能获取本机局域网 IP（请连接 Wi‑Fi 或热点）"
            return
        }

        // 端口：与 P2PConnectionManager / DeviceDiscovery 广播一致
        let port: UInt16 = 9527

        // 设备 ID：使用 identifierForVendor（足够用于本地配对；卸载重装会变化）
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

        // 公钥（可选：失败不阻塞二维码生成）
        var publicKeyB64: String?
        if let key = try? await PQCCryptoManager.instance.getKEMPublicKey() {
            publicKeyB64 = key.base64EncodedString()
        }

        let data = QRCodeGenerator.shared.createPairingData(
            deviceId: deviceId,
            deviceName: UIDevice.current.name,
            ipAddress: ip,
            port: port,
            publicKey: publicKeyB64
        )

        let image = QRCodeGenerator.shared.generateQRCode(
            from: data,
            size: CGSize(width: 420, height: 420),
            foregroundColor: .black,
            backgroundColor: .white
        )

        if let image {
            qrImage = image
        } else {
            errorText = "生成二维码失败"
        }
    }
}

private enum LocalIP {
    static func bestEffortIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = String(cString: ptr.pointee.ifa_name)
            let addrFamily = ptr.pointee.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }

            // 优先 Wi‑Fi (en0)，其次蜂窝/热点 (pdp_ip0)
            if interface == "en0" || interface.hasPrefix("pdp_ip") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    ptr.pointee.ifa_addr,
                    socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                address = String(cString: hostname)
                break
            }
        }
        return address
    }
}

// MARK: - Weather Effects (iOS)

@available(iOS 17.0, *)
private enum WeatherEffectsFrameRatePolicy {
    static func targetFPS() -> Double {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPower { return 30 }

        return min(60, Double(UIScreen.main.maximumFramesPerSecond))
    }

    static func minimumInterval() -> TimeInterval {
        let fps = max(10, targetFPS())
        return 1.0 / fps
    }
}

@available(iOS 17.0, *)
private struct WeatherEffectsBackgroundLayer: View {
    @StateObject private var weatherManager = WeatherManager.shared
    private let isActive: Bool

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        Group {
            if isActive {
                WeatherEffectsContent(condition: weatherManager.currentWeather?.condition)
                    .task {
                        if !weatherManager.isInitialized {
                            await weatherManager.start()
                        }
                    }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

@available(iOS 17.0, *)
private struct WeatherEffectsContent: View {
    let condition: WeatherCondition?

    var body: some View {
        let minimumInterval = WeatherEffectsFrameRatePolicy.minimumInterval()

        ZStack {
            if let condition {
                WeatherEffectsTintGradient(condition: condition)
                    .opacity(0.40)

                Group {
                    switch condition {
                    case .clear:
                        CinematicClearSkyEffectView_iOS(minimumInterval: minimumInterval)
                    case .cloudy:
                        CinematicCloudySkyEffectView_iOS(minimumInterval: minimumInterval)
                    case .rainy:
                        CinematicRainEffectView_iOS(minimumInterval: minimumInterval, isStorm: false)
                    case .snowy:
                        CinematicSnowEffectView_iOS(minimumInterval: minimumInterval)
                    case .foggy:
                        CinematicFogEffectView_iOS(minimumInterval: minimumInterval, tint: .white, seed: 0xF06F_0001)
                    case .haze:
                        CinematicFogEffectView_iOS(
                            minimumInterval: minimumInterval,
                            tint: Color(red: 0.95, green: 0.86, blue: 0.72),
                            seed: 0xBEEF_0001
                        )
                    case .stormy:
                        CinematicRainEffectView_iOS(minimumInterval: minimumInterval, isStorm: true)
                    case .unknown:
                        EmptyView()
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: condition?.rawValue ?? "")
    }
}

@available(iOS 17.0, *)
private struct WeatherEffectsTintGradient: View {
    let condition: WeatherCondition

    var body: some View {
        LinearGradient(
            colors: colors(for: condition),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private func colors(for condition: WeatherCondition) -> [Color] {
        switch condition {
        case .clear:
            return [Color.orange.opacity(0.35), Color.yellow.opacity(0.18)]
        case .cloudy:
            return [Color.gray.opacity(0.25), Color.blue.opacity(0.10)]
        case .rainy:
            return [Color.blue.opacity(0.26), Color.cyan.opacity(0.12)]
        case .snowy:
            return [Color.cyan.opacity(0.18), Color.white.opacity(0.10)]
        case .foggy:
            return [Color.gray.opacity(0.16), Color.white.opacity(0.08)]
        case .haze:
            return [Color.orange.opacity(0.14), Color.gray.opacity(0.14)]
        case .stormy:
            return [Color.purple.opacity(0.22), Color.blue.opacity(0.18)]
        case .unknown:
            return [Color.gray.opacity(0.10), Color.clear]
        }
    }
}

@available(iOS 17.0, *)
private struct CinematicClearSkyEffectView_iOS: View {
    private struct Particle: Hashable {
        let id: Int
        let origin: CGPoint
        let speed: Double
        let phase: Double
        let size: Double
        let hueShift: Double
        let twinkle: Double
    }

    private let particles: [Particle]
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
        var tmp: [Particle] = []
        tmp.reserveCapacity(120)
        for i in 0..<120 {
            tmp.append(
                Particle(
                    id: i,
                    origin: CGPoint(x: Double.random(in: 0...1), y: Double.random(in: 0...1)),
                    speed: Double.random(in: 0.02...0.10),
                    phase: Double.random(in: 0...(2 * .pi)),
                    size: Double.random(in: 0.8...2.0),
                    hueShift: Double.random(in: -0.08...0.08),
                    twinkle: Double.random(in: 0.6...1.4)
                )
            )
        }
        self.particles = tmp
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval, paused: false)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                for p in particles {
                    let x = (p.origin.x + sin(t * p.speed + p.phase) * 0.05) * size.width
                    let y = (p.origin.y + cos(t * p.speed + p.phase) * 0.05) * size.height
                    let tw = (sin(t * p.twinkle + p.phase) * 0.5 + 0.5)

                    var resolved = ctx.resolve(Text("•").font(.system(size: p.size)))
                    resolved.shading = .color(
                        Color(hue: 0.60 + p.hueShift, saturation: 0.35, brightness: 1.0, opacity: 0.20 + 0.18 * tw)
                    )
                    ctx.draw(resolved, at: CGPoint(x: x, y: y))
                }
            }
        }
        .ignoresSafeArea()
    }
}

@available(iOS 17.0, *)
private struct CinematicCloudySkyEffectView_iOS: View {
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval, paused: false)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let base = Color.white.opacity(0.10)

                for layer in 0..<3 {
                    let progress = (t * (0.02 + Double(layer) * 0.01)).truncatingRemainder(dividingBy: 1.0)
                    let xOffset = CGFloat(progress) * size.width
                    let yOffset = CGFloat(layer) * 40

                    let rect = CGRect(x: -size.width + xOffset, y: yOffset, width: size.width * 2, height: size.height * 0.7)
                    let path = Path(roundedRect: rect, cornerRadius: 220)
                    ctx.fill(path, with: .color(base.opacity(0.35 - Double(layer) * 0.08)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

@available(iOS 17.0, *)
private struct CinematicRainEffectView_iOS: View {
    private struct Drop: Hashable {
        let id: Int
        let x: Double
        let y: Double
        let speed: Double
        let length: Double
        let width: Double
        let alpha: Double
        let drift: Double
    }

    private let drops: [Drop]
    private let minimumInterval: TimeInterval
    private let isStorm: Bool

    init(minimumInterval: TimeInterval, isStorm: Bool) {
        self.minimumInterval = minimumInterval
        self.isStorm = isStorm
        let count = isStorm ? 520 : 360
        var tmp: [Drop] = []
        tmp.reserveCapacity(count)
        for i in 0..<count {
            tmp.append(
                Drop(
                    id: i,
                    x: Double.random(in: 0...1),
                    y: Double.random(in: 0...1),
                    speed: Double.random(in: isStorm ? 1.6...2.6 : 1.0...2.1),
                    length: Double.random(in: isStorm ? 20...55 : 14...40),
                    width: Double.random(in: 0.7...1.4),
                    alpha: Double.random(in: 0.12...0.26),
                    drift: Double.random(in: -0.08...0.08)
                )
            )
        }
        self.drops = tmp
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval, paused: false)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let wind = sin(t * 0.15) * (isStorm ? 0.35 : 0.20)
                let color = Color.white.opacity(isStorm ? 0.26 : 0.20)

                for d in drops {
                    let px = (d.x + (wind + d.drift) * 0.04) * size.width
                    let py = (d.y + t * d.speed * 0.10).truncatingRemainder(dividingBy: 1.0) * size.height

                    var path = Path()
                    path.move(to: CGPoint(x: px, y: py))
                    path.addLine(to: CGPoint(x: px + CGFloat(wind * d.length * 0.25), y: py + d.length))

                    ctx.stroke(path, with: .color(color.opacity(d.alpha)), lineWidth: d.width)
                }

                if isStorm {
                    let flash = max(0, sin(t * 1.6) - 0.82) * 2.0
                    if flash > 0 {
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.white.opacity(0.12 * flash)))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

@available(iOS 17.0, *)
private struct CinematicSnowEffectView_iOS: View {
    private struct Flake: Hashable {
        let id: Int
        let x: Double
        let y: Double
        let speed: Double
        let size: Double
        let sway: Double
        let alpha: Double
        let phase: Double
    }

    private let flakes: [Flake]
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
        var tmp: [Flake] = []
        tmp.reserveCapacity(260)
        for i in 0..<260 {
            tmp.append(
                Flake(
                    id: i,
                    x: Double.random(in: 0...1),
                    y: Double.random(in: 0...1),
                    speed: Double.random(in: 0.10...0.32),
                    size: Double.random(in: 1.2...3.2),
                    sway: Double.random(in: 0.18...0.60),
                    alpha: Double.random(in: 0.10...0.22),
                    phase: Double.random(in: 0...(2 * .pi))
                )
            )
        }
        self.flakes = tmp
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval, paused: false)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                for f in flakes {
                    let x = (f.x + sin(t * f.sway + f.phase) * 0.03) * size.width
                    let y = (f.y + t * f.speed).truncatingRemainder(dividingBy: 1.0) * size.height

                    let rect = CGRect(x: x, y: y, width: f.size, height: f.size)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(f.alpha)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

@available(iOS 17.0, *)
private struct CinematicFogEffectView_iOS: View {
    private struct Puff: Hashable {
        let id: Int
        let origin: CGPoint
        let radius: Double
        let speed: Double
        let phase: Double
        let alpha: Double
    }

    private let puffs: [Puff]
    private let minimumInterval: TimeInterval
    private let tint: Color
    private let seed: UInt64

    init(minimumInterval: TimeInterval, tint: Color, seed: UInt64) {
        self.minimumInterval = minimumInterval
        self.tint = tint
        self.seed = seed

        var rng = SeededGenerator(seed: seed)
        var tmp: [Puff] = []
        tmp.reserveCapacity(46)
        for i in 0..<46 {
            tmp.append(
                Puff(
                    id: i,
                    origin: CGPoint(x: Double.random(in: 0...1, using: &rng), y: Double.random(in: 0...1, using: &rng)),
                    radius: Double.random(in: 140...340, using: &rng),
                    speed: Double.random(in: 0.02...0.10, using: &rng),
                    phase: Double.random(in: 0...(2 * .pi), using: &rng),
                    alpha: Double.random(in: 0.05...0.12, using: &rng)
                )
            )
        }
        self.puffs = tmp
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval, paused: false)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                for p in puffs {
                    let x = (p.origin.x + sin(t * p.speed + p.phase) * 0.06) * size.width
                    let y = (p.origin.y + cos(t * p.speed + p.phase) * 0.06) * size.height
                    let r = p.radius * (0.92 + 0.08 * sin(t * p.speed + p.phase))

                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(tint.opacity(p.alpha)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEAD_BEEF : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Dashboard Tab

/// 仪表板标签页
public enum DashboardTab: String, CaseIterable {
    case home
    case devices
    case files
    case remote
    case settings
}

// MARK: - Preview
#if DEBUG
@available(iOS 17.0, *)
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
            .preferredColorScheme(.dark)
    }
}
#endif
