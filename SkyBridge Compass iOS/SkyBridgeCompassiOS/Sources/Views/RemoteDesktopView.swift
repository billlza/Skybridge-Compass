import SwiftUI
import Metal
import MetalKit
#if canImport(UIKit)
import UIKit
#endif

/// 远程桌面视图 - 支持触摸控制和手势操作
@available(iOS 17.0, *)
struct RemoteDesktopView: View {
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    @StateObject private var remoteDesktopManager = RemoteDesktopManager.instance
    @StateObject private var crossNetworkManager = CrossNetworkWebRTCManager.instance
    @StateObject private var settings = SettingsManager.instance
    
    @State private var selectedConnection: Connection?
    @State private var isFullScreen = false
    @State private var lastAutoConnectedCrossNetworkSessionID: String?
    @State private var showRemoteDesktopSettings = false
    @State private var didAutoConnectUITestFixture = false
    @State private var showUITestRemoteStream = false

    private var shouldAutoConnectUITestFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_SCENARIO_REMOTE")
    }
    
    var body: some View {
        let displayedConnection = selectedConnection ?? (
            shouldAutoConnectUITestFixture ? connectionManager.activeConnections.first : nil
        )

        NavigationStack {
            ZStack {
                DashboardView.QuantumGlassBackground()

                if let connection = displayedConnection,
                   (remoteDesktopManager.isStreaming || showUITestRemoteStream || shouldAutoConnectUITestFixture) {
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
                            title: RuntimeLocalization.string("远程桌面（实验功能）"),
                            message: RuntimeLocalization.string("iOS 端目前作为查看/控制端使用。若与 macOS 端协议不一致，可能无法连接；建议先在设置中开启“实验功能”，并使用真机与同网段设备测试。")
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
            .accessibilityIdentifier("remote.root")
            .navigationTitle(RuntimeLocalization.string("远程桌面"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(isFullScreen)
            .toolbar {
                if !isFullScreen {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showRemoteDesktopSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showRemoteDesktopSettings) {
            RemoteDesktopStreamSettingsSheet()
        }
        .onAppear {
            attemptAutoConnectCrossNetworkSession()
            attemptAutoConnectUITestFixture()
        }
        .onChange(of: crossNetworkManager.state) { _, _ in
            attemptAutoConnectCrossNetworkSession()
        }
        .onChange(of: connectionManager.activeConnections.count) { _, _ in
            attemptAutoConnectUITestFixture()
        }
    }
    
    private var connectionSelectionView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "display.2")
                .font(.system(size: 80))
                .foregroundStyle(.blue.gradient)
            
            Text(RuntimeLocalization.string("选择要连接的设备"))
                .font(.title2.bold())
                .foregroundColor(.white)
            
            if connectionManager.activeConnections.isEmpty && crossNetworkConnection == nil {
                Text(
                    "\(RuntimeLocalization.string("当前没有活动连接"))\n\(RuntimeLocalization.string("请先在发现页面连接设备"))"
                )
                    .font(.body)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let crossNetworkConnection {
                            Button {
                                connectToDevice(crossNetworkConnection)
                            } label: {
                                ConnectionCardView(connection: crossNetworkConnection)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("remote.connection.\(crossNetworkConnection.device.id)")
                            .accessibilityElement(children: .combine)
                        }
                        ForEach(connectionManager.activeConnections) { connection in
                            Button {
                                connectToDevice(connection)
                            } label: {
                                ConnectionCardView(connection: connection)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("remote.connection.\(connection.device.id)")
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding()
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("remote.selection")
    }

    private var crossNetworkConnection: Connection? {
        guard let snapshot = crossNetworkManager.activeSessionSnapshot else { return nil }
        switch snapshot.phase {
        case .handshakeComplete:
            break
        case .connecting, .reconnecting, .disconnecting:
            return nil
        case .transportReady:
            return nil
        }
        let sessionId = snapshot.sessionId
        let syntheticDeviceId = snapshot.deviceId ?? "webrtc-\(sessionId)"
        let remoteName = snapshot.deviceName ?? crossNetworkManager.remoteDeviceName ?? RuntimeLocalization.string("跨网设备")
        let pseudoDevice = DiscoveredDevice(
            id: syntheticDeviceId,
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
            advertisedCapabilities: ["remote_desktop", RemoteDesktopManager.crossNetworkDeviceCapability],
            capabilities: ["remote_desktop", RemoteDesktopManager.crossNetworkDeviceCapability]
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
        if shouldAutoConnectUITestFixture {
            showUITestRemoteStream = true
        }
        Task {
            do {
                try await remoteDesktopManager.startStreaming(from: connection)
            } catch {
                await MainActor.run {
                    if selectedConnection?.id == connection.id,
                       !remoteDesktopManager.isStreaming,
                       !showUITestRemoteStream {
                        selectedConnection = nil
                    }
                    if lastAutoConnectedCrossNetworkSessionID == connection.id {
                        lastAutoConnectedCrossNetworkSessionID = nil
                    }
                }
                SkyBridgeLogger.shared.error("❌ 远程桌面连接失败: \(error.localizedDescription)")
            }
        }
    }

    private func attemptAutoConnectCrossNetworkSession() {
        guard let connection = crossNetworkConnection else { return }
        guard !remoteDesktopManager.isStreaming else { return }
        guard selectedConnection == nil else { return }
        guard lastAutoConnectedCrossNetworkSessionID != connection.id else { return }

        lastAutoConnectedCrossNetworkSessionID = connection.id
        connectToDevice(connection)
    }

    private func attemptAutoConnectUITestFixture() {
        guard shouldAutoConnectUITestFixture else { return }
        guard !didAutoConnectUITestFixture else { return }
        guard !remoteDesktopManager.isStreaming else { return }
        guard selectedConnection == nil else { return }
        guard let firstConnection = connectionManager.activeConnections.first else { return }

        didAutoConnectUITestFixture = true
        connectToDevice(firstConnection)
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
    @State private var showStreamSettings = false
    @State private var dragMouseDownSent = false
    @State private var lastScrollTranslationHeight: CGFloat = 0
    @State private var scrollAccumulator: CGFloat = 0

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_MODE")
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 远程屏幕显示
                remoteScreenView(geometry: geometry)

                if isUITesting {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityLabel("remote.stream.ready")
                        .accessibilityIdentifier("remote.stream.ready")
                }
                
                // 触摸控制层
                touchControlOverlay(geometry: geometry)
                
                // 控制工具栏
                if showControls {
                    controlToolbar
                        .transition(.move(edge: .top))
                }
            }
        }
        .accessibilityIdentifier("remote.stream.root")
        .background(Color.black)
        .statusBarHidden(isFullScreen)
        .persistentSystemOverlays(isFullScreen ? .hidden : .visible)
        .onAppear {
            startStream()
            resetControlsTimer()
        }
        .onDisappear {
            stopStream()
        }
        .onChange(of: touchMode) { _, _ in
            dragMouseDownSent = false
            lastScrollTranslationHeight = 0
            scrollAccumulator = 0
        }
        .sheet(isPresented: $showStreamSettings) {
            RemoteDesktopStreamSettingsSheet()
        }
    }
    
    private func remoteScreenView(geometry: GeometryProxy) -> some View {
        RemoteDesktopCompositedSurface(
            feed: remoteDesktopManager.videoFrameFeed,
            fallbackFrame: remoteDesktopManager.currentFrame,
            resolution: remoteDesktopManager.resolution,
            cursorPayload: remoteDesktopManager.currentCursorPayload,
            cursorImage: remoteDesktopManager.currentCursorImage,
            overlayPayload: remoteDesktopManager.currentOverlayPayload
        )
        .scaleEffect(scale)
        .offset(offset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func touchControlOverlay(geometry: GeometryProxy) -> some View {
        let remoteFrame = effectiveRemoteFrame(in: geometry)

        return ZStack {
            nonRemoteInteractionOverlay(in: geometry, remoteFrame: remoteFrame)

            Color.clear
                .frame(width: remoteFrame.width, height: remoteFrame.height)
                .position(x: remoteFrame.midX, y: remoteFrame.midY)
                .contentShape(Rectangle())
                .gesture(magnificationGesture)
                .gesture(dragGesture)
                .simultaneousGesture(pointerGesture(in: remoteFrame))
                .gesture(tapGesture)
        }
    }
    
    private var controlToolbar: some View {
        VStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Button(action: toggleFullScreen) {
                        Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }

                    if let transportStatusText = remoteDesktopManager.transportStatusText {
                        HStack(spacing: 6) {
                            Image(systemName: transportStatusText.contains("WebRTC") ? "dot.radiowaves.left.and.right" : "network")
                                .font(.caption)
                            Text(transportStatusText)
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.12))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                    }

                    if remoteDesktopManager.resolution.width > 0,
                       remoteDesktopManager.resolution.height > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "display")
                                .font(.caption)
                            Text(
                                "\(Int(remoteDesktopManager.resolution.width))×\(Int(remoteDesktopManager.resolution.height)) · \(Int(remoteDesktopManager.frameRate.rounded()))fps"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.12))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                    }

                    Spacer(minLength: 0)

                    Button {
                        showStreamSettings = true
                        resetControlsTimer()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }

                    Button(action: disconnect) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }
                    .accessibilityIdentifier("remote.stream.disconnect")
                }

                Picker(RuntimeLocalization.string("触摸模式"), selection: $touchMode) {
                    ForEach(TouchMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
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
        TapGesture(count: 2)
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

        guard !isUITesting else { return }
        
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation {
                    showControls = false
                }
            }
        }
    }

    private func revealControlsFromLocalChromeTap() {
        resetControlsTimer()
    }

    private func nonRemoteInteractionOverlay(
        in geometry: GeometryProxy,
        remoteFrame: CGRect
    ) -> some View {
        ZStack {
            if remoteFrame.minY > 0 {
                Color.clear
                    .frame(width: geometry.size.width, height: remoteFrame.minY)
                    .position(x: geometry.size.width / 2, y: remoteFrame.minY / 2)
                    .contentShape(Rectangle())
                    .onTapGesture { revealControlsFromLocalChromeTap() }
            }

            let bottomHeight = max(geometry.size.height - remoteFrame.maxY, 0)
            if bottomHeight > 0 {
                Color.clear
                    .frame(width: geometry.size.width, height: bottomHeight)
                    .position(
                        x: geometry.size.width / 2,
                        y: remoteFrame.maxY + bottomHeight / 2
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { revealControlsFromLocalChromeTap() }
            }

            if remoteFrame.minX > 0 {
                Color.clear
                    .frame(width: remoteFrame.minX, height: remoteFrame.height)
                    .position(x: remoteFrame.minX / 2, y: remoteFrame.midY)
                    .contentShape(Rectangle())
                    .onTapGesture { revealControlsFromLocalChromeTap() }
            }

            let rightWidth = max(geometry.size.width - remoteFrame.maxX, 0)
            if rightWidth > 0 {
                Color.clear
                    .frame(width: rightWidth, height: remoteFrame.height)
                    .position(
                        x: remoteFrame.maxX + rightWidth / 2,
                        y: remoteFrame.midY
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { revealControlsFromLocalChromeTap() }
            }
        }
    }
}

// MARK: - Touch Mode

enum TouchMode: String, CaseIterable {
    case tap = "tap"
    case drag = "drag"
    case secondaryClick = "secondaryClick"
    case scroll = "scroll"
    
    var title: String {
        switch self {
        case .tap: return RuntimeLocalization.string("点击")
        case .drag: return RuntimeLocalization.string("拖动")
        case .secondaryClick: return RuntimeLocalization.string("右键")
        case .scroll: return RuntimeLocalization.string("滚动")
        }
    }
    
    var icon: String {
        switch self {
        case .tap: return "hand.tap.fill"
        case .drag: return "hand.draw.fill"
        case .secondaryClick: return "cursorarrow.click.2"
        case .scroll: return "scroll.fill"
        }
    }
}

@available(iOS 17.0, *)
private struct RemoteDesktopStreamSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var remoteDesktopManager = RemoteDesktopManager.instance

    var body: some View {
        NavigationStack {
            Form {
                Section("策略预设") {
                    Picker(
                        "模式",
                        selection: Binding(
                            get: { remoteDesktopManager.viewerSettings.activePreset },
                            set: { preset in
                                var updated = remoteDesktopManager.viewerSettings
                                updated.applyPreset(preset)
                                remoteDesktopManager.viewerSettings = updated
                            }
                        )
                    ) {
                        ForEach(RemoteDesktopViewerPreset.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }

                    Text(remoteDesktopManager.viewerSettings.activePreset.detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("手动调节") {
                    if remoteDesktopManager.viewerSettings.activePreset != .custom {
                        Text("修改下面任一项后，会自动切换为“自定义”。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Picker("分辨率", selection: $remoteDesktopManager.viewerSettings.resolution) {
                        ForEach(RemoteDesktopViewerResolution.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }

                    Picker("帧率", selection: $remoteDesktopManager.viewerSettings.frameRate) {
                        ForEach(RemoteDesktopViewerFrameRate.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }

                    Picker("编码器", selection: $remoteDesktopManager.viewerSettings.preferredCodec) {
                        ForEach(RemoteDesktopViewerCodec.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }

                    Toggle("低延迟模式", isOn: $remoteDesktopManager.viewerSettings.lowLatencyMode)
                }

                Section("交互") {
                    Toggle("共享剪贴板", isOn: $remoteDesktopManager.viewerSettings.clipboardSyncEnabled)
                }

                Section("当前流") {
                    LabeledContent("策略", value: remoteDesktopManager.viewerSettings.activePreset.displayName)
                    LabeledContent("传输", value: remoteDesktopManager.transportStatusText ?? "未连接")
                    LabeledContent("渲染", value: remoteDesktopManager.renderPipelineStatus.displayName)
                    LabeledContent("刷新策略", value: remoteDesktopManager.viewerSettings.transportTuning.refreshStrategy)
                    LabeledContent("丢包恢复", value: remoteDesktopManager.viewerSettings.transportTuning.lossRecoveryMode)
                    LabeledContent("抖动缓冲", value: "\(remoteDesktopManager.viewerSettings.transportTuning.jitterBufferFrames) 帧")
                    LabeledContent(
                        "脏区更新",
                        value: remoteDesktopManager.lastDamageRectCount > 0
                            ? "\(remoteDesktopManager.lastDamageRectCount) 块" + (remoteDesktopManager.lastDamageUsesFullFrameFallback ? " · 全帧回退" : "")
                            : "等待脏区"
                    )
                    LabeledContent(
                        "独立光标",
                        value: {
                            guard let payload = remoteDesktopManager.currentCursorPayload else {
                                return "等待独立光标"
                            }
                            return payload.hidden ? "隐藏" : "独立显示"
                        }()
                    )
                    LabeledContent(
                        "交互图层",
                        value: {
                            guard let overlay = remoteDesktopManager.currentOverlayPayload else {
                                return "等待 overlay"
                            }
                            let selectionSummary = overlay.selectionRects.isEmpty ? "无选区" : "\(overlay.selectionRects.count) 选区"
                            return overlay.focusRect == nil ? selectionSummary : selectionSummary + " · 焦点框"
                        }()
                    )
                    LabeledContent(
                        "实际分辨率",
                        value: remoteDesktopManager.resolution.width > 0
                            ? "\(Int(remoteDesktopManager.resolution.width)) × \(Int(remoteDesktopManager.resolution.height))"
                            : "等待首帧"
                    )
                    LabeledContent("实际帧率", value: "\(Int(remoteDesktopManager.frameRate.rounded())) FPS")
                    LabeledContent("延迟", value: "\(Int(remoteDesktopManager.latency.rounded())) ms")
                }
            }
            .navigationTitle("远控设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

@available(iOS 17.0, *)
private struct RemoteDesktopCompositedSurface: View {
    @ObservedObject var feed: RemoteVideoFrameFeed
    let fallbackFrame: CGImage?
    let resolution: CGSize
    let cursorPayload: RemoteDesktopCursorPayload?
    let cursorImage: UIImage?
    let overlayPayload: RemoteDesktopOverlayPayload?

    var body: some View {
        GeometryReader { geometry in
            let referenceSize = remoteReferenceCanvasSize(
                preferredResolution: resolution,
                fallbackFrame: fallbackFrame
            )
            let canvasSize = remoteAspectFitSize(
                contentSize: referenceSize,
                containerSize: geometry.size
            )
            let hasRenderableContent = feed.hasFrame || fallbackFrame != nil

            ZStack {
                RemoteDesktopRenderedSurface(
                    feed: feed,
                    fallbackFrame: fallbackFrame
                )
                .frame(width: canvasSize.width, height: canvasSize.height)

                RemoteDesktopInteractionOverlayView(
                    resolution: referenceSize,
                    cursorPayload: hasRenderableContent ? cursorPayload : nil,
                    cursorImage: hasRenderableContent ? cursorImage : nil,
                    overlayPayload: hasRenderableContent ? overlayPayload : nil
                )
                .frame(width: canvasSize.width, height: canvasSize.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }
}

@available(iOS 17.0, *)
private struct RemoteDesktopRenderedSurface: View {
    @ObservedObject var feed: RemoteVideoFrameFeed
    let fallbackFrame: CGImage?

    var body: some View {
        Group {
            if feed.hasFrame {
                RemoteDesktopMetalVideoView(feed: feed)
            } else if let fallbackFrame {
                Image(decorative: fallbackFrame, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView(RuntimeLocalization.string("正在连接..."))
                    .tint(.white)
            }
        }
    }
}

@available(iOS 17.0, *)
private struct RemoteDesktopInteractionOverlayView: View {
    let resolution: CGSize
    let cursorPayload: RemoteDesktopCursorPayload?
    let cursorImage: UIImage?
    let overlayPayload: RemoteDesktopOverlayPayload?

    var body: some View {
        GeometryReader { geometry in
            let scaleX = geometry.size.width / max(resolution.width, 1)
            let scaleY = geometry.size.height / max(resolution.height, 1)

            ZStack(alignment: .topLeading) {
                if let overlayPayload {
                    if let focusRect = overlayPayload.focusRect {
                        let rect = mappedRect(focusRect, scaleX: scaleX, scaleY: scaleY)
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.cyan.opacity(0.95), lineWidth: 2)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.cyan.opacity(0.08))
                            )
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }

                    ForEach(Array(overlayPayload.selectionRects.enumerated()), id: \.offset) { entry in
                        let rect = mappedRect(entry.element, scaleX: scaleX, scaleY: scaleY)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.yellow.opacity(0.95), lineWidth: 2)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.yellow.opacity(0.12))
                            )
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }

                if let cursorPayload,
                   !cursorPayload.hidden {
                    let cursorFrame = mappedCursorFrame(
                        cursorPayload,
                        scaleX: scaleX,
                        scaleY: scaleY
                    )

                    Group {
                        if let cursorImage {
                            Image(uiImage: cursorImage)
                                .resizable()
                                .interpolation(.none)
                        } else {
                            Image(systemName: "cursorarrow")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.white)
                                .padding(2)
                        }
                    }
                    .frame(width: cursorFrame.width, height: cursorFrame.height)
                        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
                        .offset(x: cursorFrame.minX, y: cursorFrame.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    private func mappedRect(
        _ payload: RemoteDesktopDamageRectPayload,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CGRect {
        CGRect(
            x: CGFloat(payload.x) * scaleX,
            y: CGFloat(payload.y) * scaleY,
            width: max(CGFloat(payload.width) * scaleX, 1),
            height: max(CGFloat(payload.height) * scaleY, 1)
        ).integral
    }

    private func mappedCursorFrame(
        _ payload: RemoteDesktopCursorPayload,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CGRect {
        CGRect(
            x: CGFloat(payload.x - payload.hotspotX) * scaleX,
            y: CGFloat(payload.y - payload.hotspotY) * scaleY,
            width: max(CGFloat(payload.width) * scaleX, 1),
            height: max(CGFloat(payload.height) * scaleY, 1)
        ).integral
    }
}

private func remoteReferenceCanvasSize(
    preferredResolution: CGSize,
    fallbackFrame: CGImage?
) -> CGSize {
    if preferredResolution.width > 0, preferredResolution.height > 0 {
        return preferredResolution
    }
    if let fallbackFrame {
        return CGSize(width: fallbackFrame.width, height: fallbackFrame.height)
    }
    return CGSize(width: 1280, height: 720)
}

private func remoteAspectFitSize(contentSize: CGSize, containerSize: CGSize) -> CGSize {
    guard contentSize.width > 0,
          contentSize.height > 0,
          containerSize.width > 0,
          containerSize.height > 0 else {
        return containerSize
    }

    let scale = min(
        containerSize.width / contentSize.width,
        containerSize.height / contentSize.height
    )
    return CGSize(
        width: contentSize.width * scale,
        height: contentSize.height * scale
    )
}

@available(iOS 17.0, *)
private struct RemoteDesktopMetalVideoView: UIViewRepresentable {
    @ObservedObject var feed: RemoteVideoFrameFeed

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        context.coordinator.attach(to: view)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.attach(to: uiView)

        if context.coordinator.lastFlushVersion != feed.flushVersion {
            context.coordinator.lastFlushVersion = feed.flushVersion
            context.coordinator.flush(view: uiView)
        }

        guard context.coordinator.lastFrameVersion != feed.frameVersion else { return }
        context.coordinator.lastFrameVersion = feed.frameVersion

        guard let frame = feed.currentFrame else {
            context.coordinator.flush(view: uiView)
            return
        }
        context.coordinator.display(frame: frame, view: uiView)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private var textureCache: CVMetalTextureCache?
        private var pipelineState: MTLRenderPipelineState?
        private var vertexBuffer: MTLBuffer?
        private weak var attachedView: MTKView?
        private var currentTextureRef: CVMetalTexture?
        private var currentTexture: MTLTexture?
        var lastFrameVersion: UInt64 = 0
        var lastFlushVersion: UInt64 = 0

        override init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            super.init()

            guard let device else { return }
            var textureCache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            self.textureCache = textureCache

            let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library?.makeFunction(name: "passthroughVertex")
            descriptor.fragmentFunction = library?.makeFunction(name: "blitFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)

            struct Vertex {
                var position: SIMD2<Float>
                var uv: SIMD2<Float>
            }

            let quad: [Vertex] = [
                .init(position: [-1, -1], uv: [0, 1]),
                .init(position: [ 1, -1], uv: [1, 1]),
                .init(position: [-1,  1], uv: [0, 0]),
                .init(position: [-1,  1], uv: [0, 0]),
                .init(position: [ 1, -1], uv: [1, 1]),
                .init(position: [ 1,  1], uv: [1, 0])
            ]
            vertexBuffer = device.makeBuffer(
                bytes: quad,
                length: MemoryLayout<Vertex>.stride * quad.count,
                options: .storageModeShared
            )
        }

        func attach(to view: MTKView) {
            guard attachedView !== view else { return }
            attachedView = view
            view.device = device
            view.delegate = self
            view.colorPixelFormat = .bgra8Unorm
            view.clearColor = MTLClearColorMake(0, 0, 0, 1)
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.framebufferOnly = true
            view.contentMode = .scaleAspectFit
            view.layer.isOpaque = true
            view.backgroundColor = .black
        }

        func display(frame: DecodedPixelBufferFrame, view: MTKView) {
            attach(to: view)
            guard let textureCache else { return }

            var textureRef: CVMetalTexture?
            let width = CVPixelBufferGetWidth(frame.pixelBuffer)
            let height = CVPixelBufferGetHeight(frame.pixelBuffer)
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                frame.pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &textureRef
            )

            guard status == kCVReturnSuccess,
                  let textureRef,
                  let texture = CVMetalTextureGetTexture(textureRef) else {
                return
            }

            currentTextureRef = textureRef
            currentTexture = texture
            view.setNeedsDisplay()
        }

        func flush(view: MTKView) {
            attach(to: view)
            currentTexture = nil
            currentTextureRef = nil
            if let textureCache {
                CVMetalTextureCacheFlush(textureCache, 0)
            }
            view.setNeedsDisplay()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let commandQueue,
                  let pipelineState,
                  let drawable = view.currentDrawable else {
                return
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = drawable.texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            encoder.setRenderPipelineState(pipelineState)
            if let vertexBuffer {
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            }

            if let texture = currentTexture {
                encoder.setViewport(Self.aspectFitViewport(texture: texture, drawableSize: view.drawableSize))
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }

            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private static func aspectFitViewport(texture: MTLTexture, drawableSize: CGSize) -> MTLViewport {
            let drawableWidth = max(drawableSize.width, 1)
            let drawableHeight = max(drawableSize.height, 1)
            let textureAspect = Double(texture.width) / Double(max(texture.height, 1))
            let drawableAspect = Double(drawableWidth) / Double(drawableHeight)

            if drawableAspect > textureAspect {
                let width = Double(drawableHeight) * textureAspect
                return MTLViewport(
                    originX: (Double(drawableWidth) - width) / 2.0,
                    originY: 0,
                    width: width,
                    height: Double(drawableHeight),
                    znear: 0,
                    zfar: 1
                )
            } else {
                let height = Double(drawableWidth) / textureAspect
                return MTLViewport(
                    originX: 0,
                    originY: (Double(drawableHeight) - height) / 2.0,
                    width: Double(drawableWidth),
                    height: height,
                    znear: 0,
                    zfar: 1
                )
            }
        }

        private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 position [[attribute(0)]];
            float2 uv [[attribute(1)]];
        };

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut passthroughVertex(
            uint vertexID [[vertex_id]],
            const device VertexIn *vertices [[buffer(0)]]
        ) {
            VertexOut out;
            out.position = float4(vertices[vertexID].position, 0.0, 1.0);
            out.uv = vertices[vertexID].uv;
            return out;
        }

        fragment float4 blitFragment(
            VertexOut in [[stage_in]],
            texture2d<float> textureIn [[texture(0)]]
        ) {
            constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
            return textureIn.sample(textureSampler, in.uv);
        }
        """
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
                    
                    Text(RuntimeLocalization.string("PQC 加密"))
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
    private func pointerGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                resetControlsTimer()
                switch touchMode {
                case .tap, .secondaryClick:
                    break
                case .drag:
                    let distance = hypot(value.translation.width, value.translation.height)
                    if !dragMouseDownSent, distance >= 6 {
                        dragMouseDownSent = true
                        remoteDesktopManager.handleTouch(
                            at: value.startLocation,
                            in: frame,
                            type: .leftMouseDown
                        )
                    }
                    if dragMouseDownSent {
                        remoteDesktopManager.handleTouch(
                            at: value.location,
                            in: frame,
                            type: .mouseMoved
                        )
                    }
                case .scroll:
                    let delta = value.translation.height - lastScrollTranslationHeight
                    lastScrollTranslationHeight = value.translation.height
                    scrollAccumulator += delta

                    let threshold: CGFloat = 26
                    while scrollAccumulator <= -threshold {
                        remoteDesktopManager.handleTouch(
                            at: value.location,
                            in: frame,
                            type: .scrollUp
                        )
                        scrollAccumulator += threshold
                    }
                    while scrollAccumulator >= threshold {
                        remoteDesktopManager.handleTouch(
                            at: value.location,
                            in: frame,
                            type: .scrollDown
                        )
                        scrollAccumulator -= threshold
                    }
                }
            }
            .onEnded { value in
                switch touchMode {
                case .tap:
                    // 轻触：down + up
                    remoteDesktopManager.handleTouch(at: value.location, in: frame, type: .leftMouseDown)
                    remoteDesktopManager.handleTouch(at: value.location, in: frame, type: .leftMouseUp)
                case .secondaryClick:
                    remoteDesktopManager.handleTouch(at: value.location, in: frame, type: .rightMouseDown)
                    remoteDesktopManager.handleTouch(at: value.location, in: frame, type: .rightMouseUp)
                case .drag:
                    if dragMouseDownSent {
                        remoteDesktopManager.handleTouch(
                            at: value.location,
                            in: frame,
                            type: .leftMouseUp
                        )
                    }
                    dragMouseDownSent = false
                case .scroll:
                    lastScrollTranslationHeight = 0
                    scrollAccumulator = 0
                }
            }
    }

    private func effectiveRemoteFrame(in geometry: GeometryProxy) -> CGRect {
        let full = geometry.frame(in: .local)
        let resolution = remoteDesktopManager.resolution
        guard resolution.width > 0, resolution.height > 0 else { return full }

        let scale = min(
            full.width / resolution.width,
            full.height / resolution.height
        )
        let renderWidth = resolution.width * scale
        let renderHeight = resolution.height * scale
        let baseFrame = CGRect(
            x: full.minX + (full.width - renderWidth) / 2.0,
            y: full.minY + (full.height - renderHeight) / 2.0,
            width: renderWidth,
            height: renderHeight
        )

        let scaledWidth = baseFrame.width * scale
        let scaledHeight = baseFrame.height * scale
        return CGRect(
            x: baseFrame.midX - (scaledWidth / 2) + offset.width,
            y: baseFrame.midY - (scaledHeight / 2) + offset.height,
            width: scaledWidth,
            height: scaledHeight
        )
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
