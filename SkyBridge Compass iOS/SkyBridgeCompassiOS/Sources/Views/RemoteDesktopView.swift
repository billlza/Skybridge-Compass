import SwiftUI
@preconcurrency import AVFoundation
import MetalKit
import CoreImage
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
#if canImport(UIKit)
import UIKit
#endif

/// 远程桌面视图 - 支持触摸控制和手势操作
@available(iOS 17.0, *)
struct RemoteDesktopView: View {
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    @StateObject private var remoteDesktopManager = RemoteDesktopManager.instance
    @StateObject private var crossNetworkManager = CrossNetworkWebRTCManager.instance
    
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
                        isFullScreen: $isFullScreen,
                        onDisconnect: {
                            showUITestRemoteStream = false
                            selectedConnection = nil
                        }
                    )
                } else {
                    // 连接选择界面
                    connectionSelectionView
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
        .onDisappear {
            Task {
                await remoteDesktopManager.disconnect()
                await MainActor.run {
                    selectedConnection = nil
                }
            }
        }
        .onChange(of: crossNetworkManager.state) { _, _ in
            attemptAutoConnectCrossNetworkSession()
        }
        .onChange(of: remoteDesktopManager.currentConnection?.device.id) { _, _ in
            guard let activeConnection = remoteDesktopManager.currentConnection else { return }
            selectedConnection = activeConnection
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
            
            if lanRemoteConnections.isEmpty && crossNetworkConnection == nil {
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
                        ForEach(lanRemoteConnections) { connection in
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

    private var lanRemoteConnections: [Connection] {
        connectionManager.activeConnections.filter {
            isRemoteDesktopEligible($0.device)
        }
    }

    private func connectToDevice(_ connection: Connection) {
        selectedConnection = connection
        if shouldAutoConnectUITestFixture {
            showUITestRemoteStream = true
        }
        Task {
            do {
                try await remoteDesktopManager.startStreaming(from: connection)
                await MainActor.run {
                    if let activeConnection = remoteDesktopManager.currentConnection {
                        selectedConnection = activeConnection
                    }
                }
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

    private func isRemoteDesktopEligible(_ device: DiscoveredDevice) -> Bool {
        remoteDesktopManager.canPresentRemoteDesktopOption(for: device)
    }
}

// MARK: - Remote Desktop Stream View

/// 远程桌面流视图 - 显示远程设备屏幕并处理触摸输入
@available(iOS 17.0, *)
struct RemoteDesktopStreamView: View {
    let connection: Connection
    @Binding var isFullScreen: Bool
    let onDisconnect: () -> Void
    
    @StateObject private var p2pConnectionManager = P2PConnectionManager.instance
    @StateObject private var remoteDesktopManager = RemoteDesktopManager.instance
    @StateObject private var crossNetworkManager = CrossNetworkWebRTCManager.instance
    @State private var zoomScale: CGFloat = 1.0
    
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
            resetControlsTimer()
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
        Group {
#if canImport(WebRTC)
            if let remoteTrack = nativeCrossNetworkVideoTrack {
                ZStack {
                    RemoteDesktopNativeVideoSurface(
                        track: remoteTrack,
                        resolution: remoteDesktopManager.resolution,
                        cursorPayload: remoteDesktopManager.currentCursorPayload,
                        cursorImage: remoteDesktopManager.currentCursorImage,
                        overlayPayload: remoteDesktopManager.currentOverlayPayload
                    )

                    if !crossNetworkManager.remoteVideoTrackHasRenderedFrame {
                        RemoteDesktopCompositedSurface(
                            feed: remoteDesktopManager.videoFrameFeed,
                            metalFeed: remoteDesktopManager.metalVideoFrameFeed,
                            fallbackFrame: remoteDesktopManager.currentFrame,
                            pipeline: remoteDesktopManager.renderPipelineStatus,
                            resolution: remoteDesktopManager.resolution,
                            cursorPayload: remoteDesktopManager.currentCursorPayload,
                            cursorImage: remoteDesktopManager.currentCursorImage,
                            overlayPayload: remoteDesktopManager.currentOverlayPayload
                        )
                    }
                }
            } else {
                RemoteDesktopCompositedSurface(
                    feed: remoteDesktopManager.videoFrameFeed,
                    metalFeed: remoteDesktopManager.metalVideoFrameFeed,
                    fallbackFrame: remoteDesktopManager.currentFrame,
                    pipeline: remoteDesktopManager.renderPipelineStatus,
                    resolution: remoteDesktopManager.resolution,
                    cursorPayload: remoteDesktopManager.currentCursorPayload,
                    cursorImage: remoteDesktopManager.currentCursorImage,
                    overlayPayload: remoteDesktopManager.currentOverlayPayload
                )
            }
#else
            RemoteDesktopCompositedSurface(
                feed: remoteDesktopManager.videoFrameFeed,
                metalFeed: remoteDesktopManager.metalVideoFrameFeed,
                fallbackFrame: remoteDesktopManager.currentFrame,
                pipeline: remoteDesktopManager.renderPipelineStatus,
                resolution: remoteDesktopManager.resolution,
                cursorPayload: remoteDesktopManager.currentCursorPayload,
                cursorImage: remoteDesktopManager.currentCursorImage,
                overlayPayload: remoteDesktopManager.currentOverlayPayload
            )
#endif
        }
        .scaleEffect(zoomScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isUsingNativeCrossNetworkVideo: Bool {
        connection.device.capabilities.contains(RemoteDesktopManager.crossNetworkDeviceCapability)
            || connection.device.advertisedCapabilities.contains(RemoteDesktopManager.crossNetworkDeviceCapability)
    }

    private var nativeCrossNetworkVideoTrack: RTCVideoTrack? {
#if canImport(WebRTC)
        guard isUsingNativeCrossNetworkVideo else { return nil }
        return crossNetworkManager.remoteVideoTrack
#else
        return nil
#endif
    }

    private var shouldUseNativeCrossNetworkVideo: Bool {
#if canImport(WebRTC)
        return isUsingNativeCrossNetworkVideo
            && crossNetworkManager.remoteVideoTrack != nil
            && crossNetworkManager.remoteVideoTrackHasRenderedFrame
#else
        return false
#endif
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
                zoomScale = value.magnitude
                resetControlsTimer()
            }
            .onEnded { _ in
                withAnimation {
                    zoomScale = min(max(zoomScale, 1.0), 3.0)
                }
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
        Task {
            if isUsingNativeCrossNetworkVideo {
                await remoteDesktopManager.disconnect()
            } else {
                await remoteDesktopManager.disconnect(tearDownTransport: false)
            }
            await MainActor.run {
                onDisconnect()
            }
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
                            return overlay.selectionRects.isEmpty ? "无选区" : "\(overlay.selectionRects.count) 选区"
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
    @ObservedObject var metalFeed: RemoteMetalVideoFrameFeed
    let fallbackFrame: CGImage?
    let pipeline: RemoteDesktopRenderPipeline
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
            let hasRenderableContent =
                pipeline == .metalRenderer
                || pipeline == .sampleBufferDisplayLayer
                || metalFeed.hasFrame
                || feed.hasFrame
                || fallbackFrame != nil

            ZStack {
                RemoteDesktopRenderedSurface(
                    feed: feed,
                    metalFeed: metalFeed,
                    fallbackFrame: fallbackFrame,
                    pipeline: pipeline
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

#if canImport(WebRTC)
@available(iOS 17.0, *)
private struct RemoteDesktopNativeVideoSurface: View {
    let track: RTCVideoTrack
    let resolution: CGSize
    let cursorPayload: RemoteDesktopCursorPayload?
    let cursorImage: UIImage?
    let overlayPayload: RemoteDesktopOverlayPayload?

    var body: some View {
        GeometryReader { geometry in
            let referenceSize = remoteReferenceCanvasSize(
                preferredResolution: resolution,
                fallbackFrame: nil
            )
            let canvasSize = remoteAspectFitSize(
                contentSize: referenceSize,
                containerSize: geometry.size
            )

            ZStack {
                RemoteDesktopRTCVideoView(track: track)
                    .frame(width: canvasSize.width, height: canvasSize.height)

                RemoteDesktopInteractionOverlayView(
                    resolution: referenceSize,
                    cursorPayload: cursorPayload,
                    cursorImage: cursorImage,
                    overlayPayload: overlayPayload
                )
                .frame(width: canvasSize.width, height: canvasSize.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }
}

@available(iOS 17.0, *)
private struct RemoteDesktopRTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        view.delegate = context.coordinator
        context.coordinator.bind(track: track, to: view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.delegate = context.coordinator
        context.coordinator.bind(track: track, to: uiView)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.unbind()
        uiView.delegate = nil
    }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        private weak var boundTrack: RTCVideoTrack?
        private weak var boundView: RTCMTLVideoView?

        func bind(track: RTCVideoTrack, to view: RTCMTLVideoView) {
            if boundTrack === track, boundView === view {
                return
            }
            unbind()
            boundTrack = track
            boundView = view
            track.add(view)
        }

        func unbind() {
            if let boundTrack, let boundView {
                boundTrack.remove(boundView)
            }
            boundTrack = nil
            boundView = nil
        }

        func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            Task { @MainActor in
                CrossNetworkWebRTCManager.instance.noteRemoteVideoTrackRenderedFrame(
                    size,
                    source: "rtc-mtl-video-view"
                )
                RemoteDesktopManager.instance.updateCrossNetworkNativeVideoResolution(size)
            }
        }
    }
}
#endif

@available(iOS 17.0, *)
private struct RemoteDesktopRenderedSurface: View {
    @ObservedObject var feed: RemoteVideoFrameFeed
    @ObservedObject var metalFeed: RemoteMetalVideoFrameFeed
    let fallbackFrame: CGImage?
    let pipeline: RemoteDesktopRenderPipeline

    var body: some View {
        // 显式访问 frameVersion 以触发 SwiftUI 在每帧到达时重新计算 body
        // 通过将 frameVersion 作为参数传递给 UIViewRepresentable，
        // SwiftUI 会在每帧到达时调用 updateUIView
        let metalFrameVersion = metalFeed.frameVersion
        let metalFlushVersion = metalFeed.flushVersion
        let feedFrameVersion = feed.frameVersion
        let feedFlushVersion = feed.flushVersion

        Group {
            switch pipeline {
            case .webrtcNativeVideo:
                if let fallbackFrame {
                    Image(decorative: fallbackFrame, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    loadingView
                }
            case .metalRenderer:
                RemoteDesktopMetalVideoView(
                    feed: metalFeed,
                    frameVersion: metalFrameVersion,
                    flushVersion: metalFlushVersion
                )
            case .sampleBufferDisplayLayer:
                RemoteDesktopSampleBufferVideoView(
                    feed: feed,
                    frameVersion: feedFrameVersion,
                    flushVersion: feedFlushVersion
                )
            case .stillImageFallback:
                if let fallbackFrame {
                    Image(decorative: fallbackFrame, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if metalFeed.hasFrame {
                    RemoteDesktopMetalVideoView(
                        feed: metalFeed,
                        frameVersion: metalFrameVersion,
                        flushVersion: metalFlushVersion
                    )
                } else if feed.hasFrame {
                    RemoteDesktopSampleBufferVideoView(
                        feed: feed,
                        frameVersion: feedFrameVersion,
                        flushVersion: feedFlushVersion
                    )
                } else {
                    loadingView
                }
            case .waiting:
                if metalFeed.hasFrame {
                    RemoteDesktopMetalVideoView(
                        feed: metalFeed,
                        frameVersion: metalFrameVersion,
                        flushVersion: metalFlushVersion
                    )
                } else if feed.hasFrame {
                    RemoteDesktopSampleBufferVideoView(
                        feed: feed,
                        frameVersion: feedFrameVersion,
                        flushVersion: feedFlushVersion
                    )
                } else if let fallbackFrame {
                    Image(decorative: fallbackFrame, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    loadingView
                }
            }
        }
    }

    @ViewBuilder
    private var fallbackContent: some View {
        if let fallbackFrame {
            Image(decorative: fallbackFrame, scale: 1.0, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if feed.hasFrame {
            RemoteDesktopSampleBufferVideoView(
                feed: feed,
                frameVersion: feed.frameVersion,
                flushVersion: feed.flushVersion
            )
        } else {
            loadingView
        }
    }

    private var loadingView: some View {
        ProgressView(RuntimeLocalization.string("正在连接..."))
            .tint(.white)
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
    let feed: RemoteMetalVideoFrameFeed
    let frameVersion: UInt64
    let flushVersion: UInt64
    private let remoteDesktopManager = RemoteDesktopManager.instance

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onFrameDisplayed: { [remoteDesktopManager] presentationTimeStamp in
                Task { @MainActor in
                    await remoteDesktopManager.handleMetalRendererDidDisplayFrame(
                        presentationTimeStamp: presentationTimeStamp
                    )
                }
            }
        )
    }

    @MainActor
    func makeUIView(context: Context) -> MetalVideoContainerView {
        let view = MetalVideoContainerView()
        context.coordinator.attach(to: view)
        view.isUserInteractionEnabled = false
        return view
    }

    @MainActor
    static func dismantleUIView(_ uiView: MetalVideoContainerView, coordinator: Coordinator) {
        coordinator.teardown(view: uiView)
    }

    @MainActor
    func updateUIView(_ uiView: MetalVideoContainerView, context: Context) {
        // 诊断日志：追踪 updateUIView 调用
        if context.coordinator.updateCallCount % 50 == 0 {
            print("[Metal] updateUIView called, frameVersion=\(frameVersion), flushVersion=\(flushVersion)")
        }
        context.coordinator.updateCallCount &+= 1

        context.coordinator.attach(to: uiView)

        if context.coordinator.lastFlushVersion != flushVersion {
            print("[Metal] flush triggered, flushVersion=\(flushVersion)")
            context.coordinator.lastFlushVersion = flushVersion
            context.coordinator.flush(
                view: uiView,
                removeDisplayedImage: feed.removeDisplayedImageOnFlush
            )
        }

        guard context.coordinator.lastFrameVersion != frameVersion else {
            return
        }
        context.coordinator.lastFrameVersion = frameVersion

        // takeLatestFrame 不再清空帧，所以 nil 只会在从未 enqueue 过帧时出现
        if let frame = feed.takeLatestFrame() {
            print("[Metal] ✅ displaying frame version=\(frameVersion)")
            context.coordinator.display(
                frame: frame,
                version: context.coordinator.lastFrameVersion,
                in: uiView
            )
        }
        // 如果 takeLatestFrame 返回 nil，说明还没有帧到达，等待下一帧
        // 不要打印错误日志，这是正常现象（frameVersion 增加但帧尚未准备好）
    }

    @MainActor
    final class Coordinator {
        private let onFrameDisplayed: @Sendable (CMTime) -> Void
        private weak var attachedView: MetalVideoContainerView?
        let renderer = MetalVideoRenderer()
        var lastFrameVersion: UInt64 = 0
        var lastFlushVersion: UInt64 = 0
        var updateCallCount: UInt64 = 0

        init(onFrameDisplayed: @escaping @Sendable (CMTime) -> Void) {
            self.onFrameDisplayed = onFrameDisplayed
            renderer.onFrameDisplayed = onFrameDisplayed
        }

        func attach(to view: MetalVideoContainerView) {
            guard attachedView !== view else { return }
            attachedView = view
            view.configureIfNeeded(renderer: renderer)
        }

        func display(frame: DecodedPixelBufferFrame, version: UInt64, in view: MetalVideoContainerView) {
            attach(to: view)
            renderer.display(frame: frame, version: version, in: view.metalView)
        }

        func flush(view: MetalVideoContainerView, removeDisplayedImage: Bool) {
            attach(to: view)
            renderer.flush(removeDisplayedImage: removeDisplayedImage, in: view.metalView)
        }

        func teardown(view: MetalVideoContainerView) {
            if attachedView === view {
                attachedView = nil
            }
            renderer.teardown(view: view.metalView)
        }
    }

    final class MetalVideoContainerView: UIView {
        let metalView = MTKView(frame: .zero)
        private var didConfigure = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(metalView)
            metalView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
                metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
                metalView.topAnchor.constraint(equalTo: topAnchor),
                metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configureIfNeeded(renderer: MetalVideoRenderer) {
            guard !didConfigure else { return }
            didConfigure = true
            backgroundColor = .black
            metalView.device = renderer.device
            metalView.delegate = renderer
            metalView.framebufferOnly = false
            // Remote desktop frames arrive event-by-event rather than from a game loop.
            // Drive MTKView explicitly so we only acquire drawables when a new frame or
            // a clear is actually needed, which avoids stale drawable reuse after fallback.
            metalView.enableSetNeedsDisplay = false
            metalView.isPaused = true
            metalView.preferredFramesPerSecond = 60
            metalView.isOpaque = true
            metalView.backgroundColor = .black
            metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
    }

    final class MetalVideoRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
        let device = MTLCreateSystemDefaultDevice()
        private let commandQueue: MTLCommandQueue?
        private let ciContext: CIContext?
        private let stateLock = NSLock()
        private var currentFrame: DecodedPixelBufferFrame?
        private var currentFrameVersion: UInt64 = 0
        private var lastDisplayedFrameVersion: UInt64 = 0
        private var lastSubmittedFrameVersion: UInt64 = 0
        private var renderEpoch: UInt64 = 0
        private var needsClear = true
        private let inFlightSemaphore = DispatchSemaphore(value: 2)
        var onFrameDisplayed: (@Sendable (CMTime) -> Void)?
        var drawCallCount: UInt64 = 0

        override init() {
            if let device = device {
                commandQueue = device.makeCommandQueue()
                ciContext = CIContext(
                    mtlDevice: device,
                    options: [.cacheIntermediates: false]
                )
            } else {
                commandQueue = nil
                ciContext = nil
            }
            super.init()
        }

        @MainActor
        func display(frame: DecodedPixelBufferFrame, version: UInt64, in view: MTKView) {
            stateLock.lock()
            currentFrame = frame
            currentFrameVersion = version
            needsClear = false
            stateLock.unlock()

            // 修复：确保 drawableSize 有效，避免 draw(in:) 因尺寸为零而跳过
            guard view.bounds.width > 0, view.bounds.height > 0 else {
                // view 尚未布局完成，等待下一帧
                return
            }

            let drawableScale = view.window?.screen.scale ?? UIScreen.main.scale
            view.contentScaleFactor = drawableScale
            view.drawableSize = CGSize(
                width: max(view.bounds.width * drawableScale, 1),
                height: max(view.bounds.height * drawableScale, 1)
            )

            // 显式绘制模式：新帧到达时立即触发一次 draw(in:)，避免持续 60fps 轮询。
            view.draw()
        }

        @MainActor
        func flush(removeDisplayedImage: Bool, in view: MTKView) {
            if removeDisplayedImage {
                stateLock.lock()
                currentFrame = nil
                currentFrameVersion = 0
                lastDisplayedFrameVersion = 0
                lastSubmittedFrameVersion = 0
                renderEpoch &+= 1
                needsClear = true
                stateLock.unlock()

                guard view.bounds.width > 0, view.bounds.height > 0 else { return }
                view.draw()
            }
        }

        @MainActor
        func teardown(view: MTKView) {
            flush(removeDisplayedImage: true, in: view)
            view.isPaused = true
            view.delegate = nil
            view.releaseDrawables()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            drawCallCount &+= 1
            if drawCallCount % 30 == 1 {
                print("[Metal] draw(in:) called, drawableSize=\(view.drawableSize), drawCount=\(drawCallCount)")
            }

            guard view.drawableSize.width > 0, view.drawableSize.height > 0 else {
                return
            }
            let frame: DecodedPixelBufferFrame?
            let frameVersion: UInt64
            let lastDisplayedVersion: UInt64
            let lastSubmittedVersion: UInt64
            let shouldClear: Bool
            let renderEpoch: UInt64
            stateLock.lock()
            frame = currentFrame
            frameVersion = currentFrameVersion
            lastDisplayedVersion = lastDisplayedFrameVersion
            lastSubmittedVersion = lastSubmittedFrameVersion
            shouldClear = needsClear
            renderEpoch = self.renderEpoch
            stateLock.unlock()

            // 调试日志：降低日志频率
            if frameVersion != lastDisplayedVersion || shouldClear {
                print("[Metal] draw: frameVersion=\(frameVersion), lastDisplayed=\(lastDisplayedVersion), hasFrame=\(frame != nil ? "yes" : "no"), shouldClear=\(shouldClear)")
            }

            guard shouldClear || frame != nil else {
                return
            }

            if frame != nil {
                guard frameVersion != 0,
                      frameVersion != lastDisplayedVersion,
                      frameVersion != lastSubmittedVersion else {
                    return
                }
            }

            guard inFlightSemaphore.wait(timeout: .now() + .milliseconds(50)) == .success else {
                return
            }
            var shouldSignalSemaphoreOnExit = true
            defer {
                if shouldSignalSemaphoreOnExit {
                    inFlightSemaphore.signal()
                }
            }
            guard let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }

            guard let frame, let ciContext else {
                guard let drawable = view.currentDrawable else { return }
                guard shouldClear else { return }
                if let passDescriptor = view.currentRenderPassDescriptor,
                   let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
                    encoder.endEncoding()
                }
                commandBuffer.addCompletedHandler { [inFlightSemaphore] _ in
                    inFlightSemaphore.signal()
                }
                shouldSignalSemaphoreOnExit = false
                commandBuffer.present(drawable)
                commandBuffer.commit()
                stateLock.lock()
                needsClear = false
                stateLock.unlock()
                return
            }

            guard let drawable = view.currentDrawable else {
                return
            }

            print("[Metal] ✅ rendering frame version=\(frameVersion)")  // 保留关键渲染日志

            stateLock.lock()
            if self.renderEpoch != renderEpoch {
                stateLock.unlock()
                return
            }
            lastSubmittedFrameVersion = frameVersion
            stateLock.unlock()

            let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
            let drawableBounds = CGRect(
                x: 0,
                y: 0,
                width: view.drawableSize.width,
                height: view.drawableSize.height
            )
            let scaleX = drawableBounds.width / max(image.extent.width, 1)
            let scaleY = drawableBounds.height / max(image.extent.height, 1)
            let renderedImage = image.transformed(
                by: CGAffineTransform(scaleX: scaleX, y: scaleY)
            )

            ciContext.render(
                renderedImage,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: drawableBounds,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )

            let presentationTimeStamp = frame.presentationTimeStamp
            commandBuffer.addCompletedHandler { [weak self, onFrameDisplayed, inFlightSemaphore] _ in
                inFlightSemaphore.signal()
                guard let self else { return }

                var shouldNotifyDisplay = false
                self.stateLock.lock()
                if self.renderEpoch == renderEpoch {
                    self.lastDisplayedFrameVersion = max(self.lastDisplayedFrameVersion, frameVersion)
                    shouldNotifyDisplay = true
                }
                self.stateLock.unlock()

                if shouldNotifyDisplay {
                    onFrameDisplayed?(presentationTimeStamp)
                }
            }
            shouldSignalSemaphoreOnExit = false
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

@available(iOS 17.0, *)
private struct RemoteDesktopSampleBufferVideoView: UIViewRepresentable {
    let feed: RemoteVideoFrameFeed
    let frameVersion: UInt64
    let flushVersion: UInt64
    private let remoteDesktopManager = RemoteDesktopManager.instance

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onDecodeFailure: { [remoteDesktopManager] description in
                Task { @MainActor in
                    await remoteDesktopManager.handleVideoRendererDidFailToDecode(description)
                }
            },
            onRequiresFlush: { [remoteDesktopManager] in
                Task { @MainActor in
                    await remoteDesktopManager.handleVideoRendererRequiresFlushToResumeDecoding()
                }
            },
            onFrameEnqueued: { [remoteDesktopManager] presentationTimeStamp, remainingQueueDepth in
                Task { @MainActor in
                    await remoteDesktopManager.handleVideoRendererDidEnqueueFrame(
                        presentationTimeStamp: presentationTimeStamp,
                        remainingQueueDepth: remainingQueueDepth
                    )
                }
            }
        )
    }

    @MainActor
    func makeUIView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        context.coordinator.attach(to: view)
        view.isUserInteractionEnabled = false
        return view
    }

    @MainActor
    func updateUIView(_ uiView: SampleBufferDisplayView, context: Context) {
        context.coordinator.bind(feed: feed, to: uiView)

        if context.coordinator.lastFlushVersion != flushVersion {
            context.coordinator.lastFlushVersion = flushVersion
            context.coordinator.flush(
                view: uiView,
                removeDisplayedImage: feed.removeDisplayedImageOnFlush
            )
        }

        guard context.coordinator.lastFrameVersion != frameVersion else { return }
        context.coordinator.lastFrameVersion = frameVersion

        context.coordinator.enqueuePendingFrames(from: feed, view: uiView)
    }

    final class Coordinator: @unchecked Sendable {
        private static let maxBufferedFrames = 3
        private let rendererQueue = DispatchQueue(
            label: "com.skybridge.remote.samplebuffer.renderer",
            qos: .userInteractive
        )
        private let onDecodeFailure: @Sendable (String?) -> Void
        private let onRequiresFlush: @Sendable () -> Void
        private let onFrameEnqueued: @Sendable (CMTime, Int) -> Void
        private weak var activeFeed: RemoteVideoFrameFeed?
        private weak var attachedView: SampleBufferDisplayView?
        private weak var attachedLayer: AVSampleBufferDisplayLayer?
        private var notificationTokens: [NSObjectProtocol] = []
        private var bufferedFrames: [DisplaySampleBufferFrame] = []
        private var isDrainScheduled = false
        private var framePumpTask: Task<Void, Never>?
        var lastFrameVersion: UInt64 = 0
        var lastFlushVersion: UInt64 = 0

        init(
            onDecodeFailure: @escaping @Sendable (String?) -> Void,
            onRequiresFlush: @escaping @Sendable () -> Void,
            onFrameEnqueued: @escaping @Sendable (CMTime, Int) -> Void
        ) {
            self.onDecodeFailure = onDecodeFailure
            self.onRequiresFlush = onRequiresFlush
            self.onFrameEnqueued = onFrameEnqueued
        }

        @MainActor
        func attach(to view: SampleBufferDisplayView) {
            guard attachedView !== view else { return }
            detachObservers()
            attachedView = view
            view.configureIfNeeded()
            let layer = view.sampleBufferDisplayLayer
            attachedLayer = layer
        }

        @MainActor
        func bind(feed: RemoteVideoFrameFeed, to view: SampleBufferDisplayView) {
            activeFeed = feed
            attach(to: view)
            ensureFramePumpRunning()
        }

        @MainActor
        func enqueuePendingFrames(from feed: RemoteVideoFrameFeed, view: SampleBufferDisplayView) {
            attach(to: view)
            let frames = feed.takePendingFrames()
            guard !frames.isEmpty else { return }
            rendererQueue.async { [weak self] in
                guard let self else { return }
                self.bufferedFrames.append(contentsOf: frames)
                if self.bufferedFrames.count > Self.maxBufferedFrames {
                    self.bufferedFrames.removeFirst(
                        self.bufferedFrames.count - Self.maxBufferedFrames
                    )
                }
                self.drainBufferedFrames()
            }
        }

        @MainActor
        func flush(view: SampleBufferDisplayView, removeDisplayedImage: Bool) {
            attach(to: view)
            rendererQueue.async { [weak self] in
                guard let self,
                      let layer = self.attachedLayer else { return }
                self.bufferedFrames.removeAll(keepingCapacity: true)
                self.isDrainScheduled = false
                layer.stopRequestingMediaData()
                if removeDisplayedImage {
                    layer.flushAndRemoveImage()
                } else {
                    layer.flush()
                }
            }
        }

        @MainActor
        private func ensureFramePumpRunning() {
            guard framePumpTask == nil else { return }
            framePumpTask = Task { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    if let feed = self.activeFeed,
                       let view = self.attachedView {
                        self.enqueuePendingFrames(from: feed, view: view)
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(16))
                    } catch {
                        return
                    }
                }
            }
        }

        private func drainBufferedFrames() {
            guard !isDrainScheduled else { return }
            guard let layer = attachedLayer else { return }
            isDrainScheduled = true
            layer.stopRequestingMediaData()
            layer.requestMediaDataWhenReady(on: rendererQueue) { [weak self] in
                guard let self,
                      let layer = self.attachedLayer else { return }
                while layer.isReadyForMoreMediaData {
                    if layer.requiresFlushToResumeDecoding {
                        self.bufferedFrames.removeAll(keepingCapacity: true)
                        self.isDrainScheduled = false
                        layer.stopRequestingMediaData()
                        layer.flush()
                        self.onRequiresFlush()
                        return
                    }

                    guard !self.bufferedFrames.isEmpty else {
                        self.isDrainScheduled = false
                        layer.stopRequestingMediaData()
                        return
                    }

                    let frame = self.bufferedFrames.removeFirst()
                    layer.enqueue(frame.sampleBuffer)
                    self.onFrameEnqueued(frame.presentationTimeStamp, self.bufferedFrames.count)
                }
            }
        }

        private func installObservers(for renderer: AVSampleBufferVideoRenderer) {
            let center = NotificationCenter.default
            notificationTokens.append(
                center.addObserver(
                    forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
                    object: renderer,
                    queue: nil
                ) { [weak self] notification in
                    guard let self else { return }
                    let error = notification.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey]
                        as? NSError
                    self.onDecodeFailure(error?.localizedDescription)
                }
            )
            notificationTokens.append(
                center.addObserver(
                    forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                    object: renderer,
                    queue: nil
                ) { [weak self] _ in
                    guard let self, renderer.requiresFlushToResumeDecoding else { return }
                    self.onRequiresFlush()
                }
            )
        }

        private func detachObservers() {
            let center = NotificationCenter.default
            notificationTokens.forEach(center.removeObserver)
            notificationTokens.removeAll()
        }

        deinit {
            framePumpTask?.cancel()
            detachObservers()
        }
    }

    final class SampleBufferDisplayView: UIView {
        override class var layerClass: AnyClass {
            AVSampleBufferDisplayLayer.self
        }

        fileprivate var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
            layer as! AVSampleBufferDisplayLayer
        }

        private var didConfigureLayer = false

        @MainActor
        func configureIfNeeded() {
            guard !didConfigureLayer else { return }
            didConfigureLayer = true
            backgroundColor = .black
            layer.isOpaque = true
            contentMode = .scaleAspectFit

            sampleBufferDisplayLayer.videoGravity = .resizeAspect
            sampleBufferDisplayLayer.preventsDisplaySleepDuringVideoPlayback = false
            // All display sample buffers are tagged with
            // kCMSampleAttachmentKey_DisplayImmediately, so an active control
            // timebase can cause later frames to be scheduled instead of shown.
            sampleBufferDisplayLayer.controlTimebase = nil
        }

        func flush(removeDisplayedImage: Bool) {
            let renderer = sampleBufferDisplayLayer.sampleBufferRenderer
            renderer.stopRequestingMediaData()
            renderer.flush(removingDisplayedImage: removeDisplayedImage, completionHandler: nil)
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
    private static let tapMovementTolerance: CGFloat = 10

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
                let distance = hypot(value.translation.width, value.translation.height)
                switch touchMode {
                case .tap:
                    guard distance <= Self.tapMovementTolerance else { break }
                    remoteDesktopManager.handleTouch(
                        at: value.location,
                        in: frame,
                        type: .leftMouseDown
                    )
                    remoteDesktopManager.handleTouch(
                        at: value.location,
                        in: frame,
                        type: .leftMouseUp
                    )
                case .secondaryClick:
                    guard distance <= Self.tapMovementTolerance else { break }
                    remoteDesktopManager.handleTouch(
                        at: value.location,
                        in: frame,
                        type: .rightMouseDown
                    )
                    remoteDesktopManager.handleTouch(
                        at: value.location,
                        in: frame,
                        type: .rightMouseUp
                    )
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

        let aspectFitScale = min(
            full.width / resolution.width,
            full.height / resolution.height
        )
        let renderWidth = resolution.width * aspectFitScale
        let renderHeight = resolution.height * aspectFitScale
        let baseFrame = CGRect(
            x: full.minX + (full.width - renderWidth) / 2.0,
            y: full.minY + (full.height - renderHeight) / 2.0,
            width: renderWidth,
            height: renderHeight
        )

        let scaledWidth = baseFrame.width * zoomScale
        let scaledHeight = baseFrame.height * zoomScale
        return CGRect(
            x: baseFrame.midX - (scaledWidth / 2),
            y: baseFrame.midY - (scaledHeight / 2),
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
