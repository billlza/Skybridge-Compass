import SwiftUI

/// 远程桌面视图 - 支持触摸控制和手势操作
@available(iOS 17.0, *)
struct RemoteDesktopView: View {
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    @StateObject private var remoteDesktopManager = RemoteDesktopManager.instance
    @StateObject private var crossNetworkManager = CrossNetworkWebRTCManager.instance
    @StateObject private var settings = SettingsManager.instance
    
    @State private var selectedConnection: Connection?
    @State private var isFullScreen = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                if let connection = selectedConnection,
                   remoteDesktopManager.isStreaming {
                    // 远程桌面流
                    RemoteDesktopStreamView(
                        connection: connection,
                        isFullScreen: $isFullScreen
                    )
                } else {
                    // 连接选择界面
                    connectionSelectionView
                }

                if !settings.enableExperimentalFeatures {
                    VStack {
                        BetaBannerView(
                            title: "远程桌面（实验功能）",
                            message: "iOS 端目前作为查看/控制端使用。若与 macOS 端协议不一致，可能无法连接；建议先在设置中开启“实验功能”，并使用真机与同网段设备测试。"
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle("远程桌面")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(isFullScreen)
        }
    }
    
    private var connectionSelectionView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "display.2")
                .font(.system(size: 80))
                .foregroundStyle(.blue.gradient)
            
            Text("选择要连接的设备")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            if connectionManager.activeConnections.isEmpty && crossNetworkConnection == nil {
                Text("当前没有活动连接\n请先在\"发现\"页面连接设备")
                    .font(.body)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let crossNetworkConnection {
                            ConnectionCardView(connection: crossNetworkConnection)
                                .onTapGesture {
                                    connectToDevice(crossNetworkConnection)
                                }
                        }
                        ForEach(connectionManager.activeConnections) { connection in
                            ConnectionCardView(connection: connection)
                                .onTapGesture {
                                    connectToDevice(connection)
                                }
                        }
                    }
                    .padding()
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.15),
                    Color(red: 0.1, green: 0.1, blue: 0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var crossNetworkConnection: Connection? {
        guard case .connected(let sessionId) = crossNetworkManager.state else { return nil }
        let remoteId = crossNetworkManager.remoteDeviceId ?? "webrtc-\(sessionId)"
        let remoteName = crossNetworkManager.remoteDeviceName ?? "跨网设备"
        let pseudoDevice = DiscoveredDevice(
            id: remoteId,
            name: remoteName,
            modelName: "Remote",
            platform: .macOS,
            osVersion: "",
            ipAddress: nil,
            services: [],
            portMap: [:],
            signalStrength: -50,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )
        return Connection(
            id: "webrtc-\(sessionId)",
            device: pseudoDevice,
            status: .connected,
            encryptionType: .pqc
        )
    }
    
    private func connectToDevice(_ connection: Connection) {
        selectedConnection = connection
        Task {
            do {
                try await remoteDesktopManager.startStreaming(from: connection)
            } catch {
                SkyBridgeLogger.shared.error("❌ 远程桌面连接失败: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Remote Desktop Stream View

/// 远程桌面流视图 - 显示远程设备屏幕并处理触摸输入
@available(iOS 17.0, *)
struct RemoteDesktopStreamView: View {
    let connection: Connection
    @Binding var isFullScreen: Bool
    
    @StateObject private var remoteDesktopManager = RemoteDesktopManager.instance
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    // 触摸控制
    @State private var touchMode: TouchMode = .tap
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 远程屏幕显示
                remoteScreenView(geometry: geometry)
                
                // 触摸控制层
                touchControlOverlay
                
                // 控制工具栏
                if showControls {
                    controlToolbar
                        .transition(.move(edge: .top))
                }
            }
        }
        .background(Color.black)
        .statusBarHidden(isFullScreen)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            startStream()
            resetControlsTimer()
        }
        .onDisappear {
            stopStream()
        }
    }
    
    private func remoteScreenView(geometry: GeometryProxy) -> some View {
        Group {
            if let frame = remoteDesktopManager.currentFrame {
                Image(decorative: frame, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnificationGesture)
                    .gesture(dragGesture)
                    .simultaneousGesture(pointerGesture(in: geometry))
                    .gesture(tapGesture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("正在连接...")
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    private var touchControlOverlay: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                resetControlsTimer()
            }
    }
    
    private var controlToolbar: some View {
        VStack {
            HStack {
                // 全屏切换
                Button(action: toggleFullScreen) {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                }
                
                Spacer()
                
                // 触摸模式选择
                Picker("触摸模式", selection: $touchMode) {
                    ForEach(TouchMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                
                Spacer()
                
                // 断开连接
                Button(action: disconnect) {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            
            Spacer()
        }
    }
    
    // MARK: - Gestures
    
    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = value.magnitude
                resetControlsTimer()
            }
            .onEnded { _ in
                withAnimation {
                    if scale < 1.0 {
                        scale = 1.0
                    } else if scale > 3.0 {
                        scale = 3.0
                    }
                }
            }
    }
    
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                resetControlsTimer()
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }
    
    private var tapGesture: some Gesture {
        TapGesture()
            .onEnded { _ in
                showControls.toggle()
                if showControls {
                    resetControlsTimer()
                }
            }
    }
    
    // MARK: - Actions
    
    private func toggleFullScreen() {
        withAnimation {
            isFullScreen.toggle()
        }
        resetControlsTimer()
    }
    
    private func disconnect() {
        stopStream()
        // 返回到连接选择界面
    }
    
    private func startStream() {
        Task {
            do {
                try await remoteDesktopManager.startStreaming(from: connection)
            } catch {
                SkyBridgeLogger.shared.error("❌ 远程桌面启动失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func stopStream() {
        Task {
            await remoteDesktopManager.disconnect()
        }
    }
    
    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        showControls = true
        
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation {
                    showControls = false
                }
            }
        }
    }
}

// MARK: - Touch Mode

enum TouchMode: String, CaseIterable {
    case tap = "tap"
    case drag = "drag"
    case scroll = "scroll"
    
    var title: String {
        switch self {
        case .tap: return "点击"
        case .drag: return "拖动"
        case .scroll: return "滚动"
        }
    }
    
    var icon: String {
        switch self {
        case .tap: return "hand.tap.fill"
        case .drag: return "hand.draw.fill"
        case .scroll: return "scroll.fill"
        }
    }
}

// MARK: - Connection Card View

struct ConnectionCardView: View {
    let connection: Connection
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: connection.device.platform.iconName)
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 50, height: 50)
                .background(
                    LinearGradient(
                        colors: connection.device.platform.gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(12)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.device.name)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(connection.device.modelName)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                    
                    Text("PQC 加密")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(.gray)
        }
        .padding()
        .background(Color(white: 0.15))
        .cornerRadius(16)
    }
}

// MARK: - Remote Stream Manager

extension RemoteDesktopStreamView {
    /// 触摸/拖动映射为远端鼠标移动 + 点击（最小可用控制）
    private func pointerGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 仅在 tap/drag 模式下发送 mouseMoved（避免和缩放/平移冲突过大）
                guard touchMode != .scroll else { return }
                remoteDesktopManager.handleTouch(at: value.location, in: geometry.frame(in: .local), type: .mouseMoved)
            }
            .onEnded { value in
                switch touchMode {
                case .tap:
                    // 轻触：down + up
                    remoteDesktopManager.handleTouch(at: value.location, in: geometry.frame(in: .local), type: .leftMouseDown)
                    remoteDesktopManager.handleTouch(at: value.location, in: geometry.frame(in: .local), type: .leftMouseUp)
                case .drag:
                    // 拖动结束：抬起
                    remoteDesktopManager.handleTouch(at: value.location, in: geometry.frame(in: .local), type: .leftMouseUp)
                case .scroll:
                    break
                }
            }
    }
}

// MARK: - Preview
#if DEBUG
struct RemoteDesktopView_Previews: PreviewProvider {
    static var previews: some View {
        RemoteDesktopView()
            .environmentObject(P2PConnectionManager.instance)
    }
}
#endif
