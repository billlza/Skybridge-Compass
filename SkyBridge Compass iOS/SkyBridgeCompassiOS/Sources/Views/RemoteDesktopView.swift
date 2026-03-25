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
            if shouldUseNativeCrossNetworkVideo,
               let remoteTrack = crossNetworkManager.remoteVideoTrack {
                RemoteDesktopNativeVideoSurface(
                    track: remoteTrack,
                    resolution: remoteDesktopManager.resolution,
                    cursorPayload: remoteDesktopManager.currentCursorPayload,
                    cursorImage: remoteDesktopManager.currentCursorImage,
                    overlayPayload: remoteDesktopManager.currentOverlayPayload
                )
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
        .scaleEffect(scale)
        .offset(offset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isUsingNativeCrossNetworkVideo: Bool {
        connection.device.capabilities.contains(RemoteDesktopManager.crossNetworkDeviceCapability)
            || connection.device.advertisedCapabilities.contains(RemoteDesktopManager.crossNetworkDeviceCapability)
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
        Group {
            switch pipeline {
            case .metalRenderer:
                RemoteDesktopMetalVideoView(feed: metalFeed)
            case .sampleBufferDisplayLayer:
                RemoteDesktopSampleBufferVideoView(feed: feed)
            case .stillImageFallback:
                if let fallbackFrame {
                    Image(decorative: fallbackFrame, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if metalFeed.hasFrame {
                    RemoteDesktopMetalVideoView(feed: metalFeed)
                } else if feed.hasFrame {
                    RemoteDesktopSampleBufferVideoView(feed: feed)
                } else {
                    loadingView
                }
            case .waiting:
                if metalFeed.hasFrame {
                    RemoteDesktopMetalVideoView(feed: metalFeed)
                } else if feed.hasFrame {
                    RemoteDesktopSampleBufferVideoView(feed: feed)
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
            RemoteDesktopSampleBufferVideoView(feed: feed)
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
    let feed: RemoteMetalVideoFrameFeed
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
    func updateUIView(_ uiView: MetalVideoContainerView, context: Context) {
        context.coordinator.attach(to: uiView)

        if context.coordinator.lastFlushVersion != feed.flushVersion {
            context.coordinator.lastFlushVersion = feed.flushVersion
            context.coordinator.flush(
                view: uiView,
                removeDisplayedImage: feed.removeDisplayedImageOnFlush
            )
        }

        guard context.coordinator.lastFrameVersion != feed.frameVersion else { return }
        context.coordinator.lastFrameVersion = feed.frameVersion

        if let frame = feed.takeLatestFrame() {
            context.coordinator.display(
                frame: frame,
                version: context.coordinator.lastFrameVersion,
                in: uiView
            )
        }
    }

    @MainActor
    final class Coordinator {
        private let onFrameDisplayed: @Sendable (CMTime) -> Void
        private weak var attachedView: MetalVideoContainerView?
        let renderer = MetalVideoRenderer()
        var lastFrameVersion: UInt64 = 0
        var lastFlushVersion: UInt64 = 0

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
            metalView.enableSetNeedsDisplay = true
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
        private var currentFrame: DecodedPixelBufferFrame?
        private var currentFrameVersion: UInt64 = 0
        private var lastDisplayedFrameVersion: UInt64 = 0
        private var needsClear = true
        private let inFlightSemaphore = DispatchSemaphore(value: 2)
        var onFrameDisplayed: (@Sendable (CMTime) -> Void)?

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
            currentFrame = frame
            currentFrameVersion = version
            needsClear = false
            let drawableScale = view.window?.screen.scale ?? UIScreen.main.scale
            view.contentScaleFactor = drawableScale
            view.drawableSize = CGSize(
                width: max(view.bounds.width * drawableScale, 1),
                height: max(view.bounds.height * drawableScale, 1)
            )
            view.draw()
        }

        @MainActor
        func flush(removeDisplayedImage: Bool, in view: MTKView) {
            if removeDisplayedImage {
                currentFrame = nil
                currentFrameVersion = 0
                lastDisplayedFrameVersion = 0
                needsClear = true
                view.draw()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard view.drawableSize.width > 0, view.drawableSize.height > 0 else {
                return
            }
            let frame = currentFrame
            let frameVersion = currentFrameVersion
            guard needsClear || frame != nil else {
                return
            }
            guard inFlightSemaphore.wait(timeout: .now()) == .success else {
                view.setNeedsDisplay()
                return
            }
            guard let drawable = view.currentDrawable,
                  let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                inFlightSemaphore.signal()
                view.setNeedsDisplay()
                return
            }

            guard let frame, let ciContext else {
                guard needsClear else {
                    inFlightSemaphore.signal()
                    return
                }
                if let passDescriptor = view.currentRenderPassDescriptor,
                   let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
                    encoder.endEncoding()
                }
                commandBuffer.addCompletedHandler { [inFlightSemaphore] _ in
                    inFlightSemaphore.signal()
                }
                commandBuffer.present(drawable)
                commandBuffer.commit()
                needsClear = false
                return
            }

            guard frameVersion != 0, frameVersion != lastDisplayedFrameVersion else {
                inFlightSemaphore.signal()
                return
            }

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
                self?.lastDisplayedFrameVersion = frameVersion
                onFrameDisplayed?(presentationTimeStamp)
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

@available(iOS 17.0, *)
private struct RemoteDesktopSampleBufferVideoView: UIViewRepresentable {
    let feed: RemoteVideoFrameFeed
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
        context.coordinator.attach(to: uiView)

        if context.coordinator.lastFlushVersion != feed.flushVersion {
            context.coordinator.lastFlushVersion = feed.flushVersion
            context.coordinator.flush(
                view: uiView,
                removeDisplayedImage: feed.removeDisplayedImageOnFlush
            )
        }

        guard context.coordinator.lastFrameVersion != feed.frameVersion else { return }
        context.coordinator.lastFrameVersion = feed.frameVersion

        context.coordinator.enqueuePendingFrames(from: feed, view: uiView)
    }

    final class Coordinator: @unchecked Sendable {
        private let rendererQueue = DispatchQueue(
            label: "com.skybridge.remote.samplebuffer.renderer",
            qos: .userInteractive
        )
        private let onDecodeFailure: @Sendable (String?) -> Void
        private let onRequiresFlush: @Sendable () -> Void
        private let onFrameEnqueued: @Sendable (CMTime, Int) -> Void
        private weak var attachedView: SampleBufferDisplayView?
        private weak var attachedRenderer: AVSampleBufferVideoRenderer?
        private var notificationTokens: [NSObjectProtocol] = []
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
            let renderer = view.sampleBufferDisplayLayer.sampleBufferRenderer
            attachedRenderer = renderer
            installObservers(for: renderer)
            if #available(iOS 17.4, *) {
                renderer.presentationTimeExpectation = .none
            }
        }

        @MainActor
        func enqueuePendingFrames(from feed: RemoteVideoFrameFeed, view: SampleBufferDisplayView) {
            attach(to: view)
            let frames = feed.takePendingFrames()
            guard !frames.isEmpty else { return }
            // For displayImmediately mode without a controlTimebase, use
            // direct push: enqueue each frame immediately rather than
            // relying on the pull-based requestMediaDataWhenReady model.
            // Without a running timebase the renderer may never report
            // isReadyForMoreMediaData=true, causing a permanent stall
            // after the first frame.
            rendererQueue.async { [weak self] in
                guard let self,
                      let renderer = self.attachedRenderer else { return }
                if renderer.requiresFlushToResumeDecoding {
                    renderer.flush(removingDisplayedImage: false, completionHandler: nil)
                    self.onRequiresFlush()
                    return
                }
                for (index, frame) in frames.enumerated() {
                    renderer.enqueue(frame.sampleBuffer)
                    let remaining = frames.count - index - 1
                    self.onFrameEnqueued(frame.presentationTimeStamp, remaining)
                }
            }
        }

        @MainActor
        func flush(view: SampleBufferDisplayView, removeDisplayedImage: Bool) {
            attach(to: view)
            rendererQueue.async { [weak self] in
                guard let self,
                      let renderer = self.attachedRenderer else { return }
                renderer.stopRequestingMediaData()
                renderer.flush(removingDisplayedImage: removeDisplayedImage, completionHandler: nil)
                if #available(iOS 17.4, *) {
                    renderer.presentationTimeExpectation = .none
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
        private var controlTimebase: CMTimebase?

        @MainActor
        func configureIfNeeded() {
            guard !didConfigureLayer else { return }
            didConfigureLayer = true
            backgroundColor = .black
            layer.isOpaque = true
            contentMode = .scaleAspectFit

            sampleBufferDisplayLayer.videoGravity = .resizeAspect
            sampleBufferDisplayLayer.preventsDisplaySleepDuringVideoPlayback = false
            // Do NOT set a controlTimebase.  All sample buffers carry the
            // kCMSampleAttachmentKey_DisplayImmediately attachment, which
            // tells the layer to render each frame instantly.  A running
            // controlTimebase conflicts with displayImmediately and can
            // cause the layer to schedule frames "in the future", leading
            // to a first-frame-only-freeze where the IDR is shown but all
            // subsequent P-frames are never displayed.
            sampleBufferDisplayLayer.controlTimebase = nil
            controlTimebase = nil
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
