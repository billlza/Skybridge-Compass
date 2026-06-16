import SwiftUI
@preconcurrency import AVFoundation
import MetalKit
import CoreImage
import QuartzCore
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
#if canImport(UIKit)
import UIKit
#endif

private enum RemoteDesktopDiagnosticDefaults {
    static let showInteractionOverlayKey = "SkyBridgeRemoteDesktopShowInteractionOverlay"
}

#if canImport(UIKit)
@MainActor
private enum RemoteDesktopIdleTimerCoordinator {
    private static var activeHolders = 0

    static func acquire() {
        activeHolders += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        activeHolders = max(0, activeHolders - 1)
        if activeHolders == 0 {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
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
    @State private var didAutoConnectP2PSmoke = false
    @State private var showUITestRemoteStream = false
    @State private var presentationOwnerToken = UUID()

    private var shouldAutoConnectUITestFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_SCENARIO_REMOTE")
    }

    private var shouldAutoConnectP2PSmoke: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SKYBRIDGE_SMOKE_ROLE"] == "ios-p2p-client"
            && environment["SKYBRIDGE_SMOKE_EXPECT_REMOTE_DESKTOP"] == "1"
            && environment["SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB"] == "1"
            && environment["SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW"] == "1"
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
            remoteDesktopManager.registerPresentationOwner(presentationOwnerToken)
            attemptAutoConnectCrossNetworkSession()
            attemptAutoConnectUITestFixture()
            attemptAutoConnectP2PSmoke()
        }
        .onDisappear {
            let shouldDisconnect = remoteDesktopManager.unregisterPresentationOwner(presentationOwnerToken)
            guard shouldDisconnect else { return }
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
            attemptAutoConnectP2PSmoke()
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

    private func attemptAutoConnectP2PSmoke() {
        guard shouldAutoConnectP2PSmoke else { return }
        guard !didAutoConnectP2PSmoke else { return }
        guard !remoteDesktopManager.isStreaming else { return }
        guard selectedConnection == nil else { return }
        guard let connection = smokeTargetLANConnection() else { return }

        didAutoConnectP2PSmoke = true
        SkyBridgeLogger.shared.info("🧪 P2P smoke RemoteDesktopView auto-connect: \(connection.device.id)")
        connectToDevice(connection)
    }

    private func smokeTargetLANConnection() -> Connection? {
        let environment = ProcessInfo.processInfo.environment
        let targetID = environment["SKYBRIDGE_SMOKE_TARGET_DEVICE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let targetName = environment["SKYBRIDGE_SMOKE_TARGET_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return lanRemoteConnections.first { connection in
            let deviceID = connection.device.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let deviceName = connection.device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let bonjourName = connection.device.bonjourServiceName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if let targetID, !targetID.isEmpty {
                let aliases = PeerIdentityAliasResolver.lookupCandidates(for: connection.device.id)
                if deviceID == targetID
                    || deviceID == "id:\(targetID)"
                    || aliases.contains(targetID)
                    || aliases.contains("id:\(targetID)") {
                    return true
                }
            }
            if let targetName, !targetName.isEmpty {
                return deviceName == targetName
                    || deviceName.contains(targetName)
                    || bonjourName == targetName
                    || bonjourName?.contains(targetName) == true
            }
            return false
        } ?? lanRemoteConnections.first
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
    @State private var idleTimerHeld = false
    @AppStorage(RemoteDesktopDiagnosticDefaults.showInteractionOverlayKey)
    private var showInteractionOverlay = false

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
            acquireIdleTimer()
            resetControlsTimer()
        }
        .onDisappear {
            releaseIdleTimer()
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

    private func acquireIdleTimer() {
        #if canImport(UIKit)
        guard !idleTimerHeld else { return }
        idleTimerHeld = true
        RemoteDesktopIdleTimerCoordinator.acquire()
        #endif
    }

    private func releaseIdleTimer() {
        #if canImport(UIKit)
        guard idleTimerHeld else { return }
        idleTimerHeld = false
        RemoteDesktopIdleTimerCoordinator.release()
        #endif
    }
    
    private func remoteScreenView(geometry: GeometryProxy) -> some View {
        let shouldRenderDiagnosticOverlay = showInteractionOverlay
            && remoteDesktopManager.frameRate >= 5
        let diagnosticOverlayPayload = shouldRenderDiagnosticOverlay
            ? remoteDesktopManager.currentOverlayPayload
            : nil
        return Group {
#if canImport(WebRTC)
            if let remoteTrack = nativeCrossNetworkVideoTrack {
                let probeNativeVideoAboveFallback =
                    crossNetworkManager.nativeVideoProbeActive
                    && !crossNetworkManager.remoteVideoTrackHasRenderedFrame
                let nativeVideoHasInboundFrameEvidence =
                    crossNetworkManager.remoteVideoTrackHasReceiverFrameEvidence
                let nativeVideoOwnsSurface =
                    probeNativeVideoAboveFallback
                    || nativeVideoHasInboundFrameEvidence
                    || crossNetworkManager.remoteVideoTrackHasRenderedFrame
                ZStack {
                    if !crossNetworkManager.remoteVideoTrackHasRenderedFrame {
                        RemoteDesktopCompositedSurface(
                            feed: remoteDesktopManager.videoFrameFeed,
                            metalFeed: remoteDesktopManager.metalVideoFrameFeed,
                            fallbackFrame: remoteDesktopManager.currentFrame,
                            pipeline: remoteDesktopManager.renderPipelineStatus,
                            resolution: remoteDesktopManager.resolution,
                            cursorPayload: remoteDesktopManager.currentCursorPayload,
                            cursorImage: remoteDesktopManager.currentCursorImage,
                            overlayPayload: diagnosticOverlayPayload
                        )
                        .zIndex(probeNativeVideoAboveFallback ? 0 : 1)
                    }

                    RemoteDesktopNativeVideoSurface(
                        track: remoteTrack,
                        acceptsRenderEvidence: nativeVideoOwnsSurface,
                        resolution: remoteDesktopManager.resolution,
                        cursorPayload: remoteDesktopManager.currentCursorPayload,
                        cursorImage: remoteDesktopManager.currentCursorImage,
                        overlayPayload: crossNetworkManager.remoteVideoTrackHasRenderedFrame
                            ? diagnosticOverlayPayload
                            : nil
                    )
                    .zIndex(nativeVideoOwnsSurface ? 2 : 0)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(
                        nativeVideoOwnsSurface
                            ? "remote.native-video.surface.active"
                            : "remote.native-video.surface.prewarmed"
                    )
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
                    overlayPayload: diagnosticOverlayPayload
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
                overlayPayload: diagnosticOverlayPayload
            )
#endif
        }
        .scaleEffect(zoomScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isUsingNativeCrossNetworkVideo: Bool {
        remoteDesktopManager.isStreaming
            && remoteDesktopManager.isUsingCrossNetworkTransport
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
    @AppStorage(RemoteDesktopDiagnosticDefaults.showInteractionOverlayKey)
    private var showInteractionOverlay = false

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
                    Toggle("远端音频", isOn: $remoteDesktopManager.viewerSettings.audioRedirectionEnabled)
                }

                Section("诊断") {
                    Toggle("显示选区/焦点 overlay", isOn: $showInteractionOverlay)
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
    let acceptsRenderEvidence: Bool
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
                RemoteDesktopRTCVideoView(
                    track: track,
                    acceptsRenderEvidence: acceptsRenderEvidence,
                    uiSurface: "remoteDesktopView"
                )
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

#endif

@available(iOS 17.0, *)
private struct RemoteDesktopRenderedSurface: View {
    @ObservedObject var feed: RemoteVideoFrameFeed
    @ObservedObject var metalFeed: RemoteMetalVideoFrameFeed
    let fallbackFrame: CGImage?
    let pipeline: RemoteDesktopRenderPipeline

    var body: some View {
        // SwiftUI only needs to re-evaluate when the Metal surface first becomes
        // available or is flushed; video frames are pushed directly to MTKView.
        let metalSurfaceInvalidationVersion = metalFeed.surfaceInvalidationVersion
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
                    surfaceInvalidationVersion: metalSurfaceInvalidationVersion,
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
                        surfaceInvalidationVersion: metalSurfaceInvalidationVersion,
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
                        surfaceInvalidationVersion: metalSurfaceInvalidationVersion,
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
    let surfaceInvalidationVersion: UInt64
    let frameVersion: UInt64
    let flushVersion: UInt64
    private let remoteDesktopManager = RemoteDesktopManager.instance

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onFramesDisplayed: { [remoteDesktopManager] presentationTimeStamp, displayedFrameCount, completedAt, frameAgeMs in
                remoteDesktopManager.recordMetalRendererDisplayedFramesForSmoke(
                    displayedFrameCount: displayedFrameCount,
                    completedAt: completedAt,
                    frameAgeMs: frameAgeMs
                )
                Task { @MainActor in
                    await remoteDesktopManager.handleMetalRendererDidDisplayFrames(
                        presentationTimeStamp: presentationTimeStamp,
                        displayedFrameCount: displayedFrameCount,
                        completedAt: completedAt
                    )
                }
            },
            onRenderOrientation: { [remoteDesktopManager] orientation in
                Task { @MainActor in
                    remoteDesktopManager.handleMetalRendererOrientation(orientation)
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
        context.coordinator.bind(feed: feed, to: uiView)

        if context.coordinator.lastFlushVersion != flushVersion {
            context.coordinator.lastFlushVersion = flushVersion
            context.coordinator.flush(
                view: uiView,
                removeDisplayedImage: feed.removeDisplayedImageOnFlush
            )
        }

        guard !context.coordinator.isDirectFrameConsumerActive else {
            return
        }
        guard context.coordinator.lastFrameVersion != frameVersion else {
            return
        }

        // takeLatestFrame 不再清空帧，所以 nil 只会在从未 enqueue 过帧时出现
        if let frame = feed.takeLatestFrame() {
            if case .accepted = context.coordinator.display(
                frame: frame,
                version: frameVersion,
                in: uiView
            ) {
                context.coordinator.lastFrameVersion = frameVersion
            }
        }
        // 如果 takeLatestFrame 返回 nil，说明还没有帧到达，等待下一帧
        // 不要打印错误日志，这是正常现象（frameVersion 增加但帧尚未准备好）
    }

    @MainActor
    final class Coordinator {
        private let onFramesDisplayed: @Sendable (CMTime, Int, Date, Int?) -> Void
        private let onRenderOrientation: @Sendable (RemoteDesktopRenderOrientation) -> Void
        private weak var attachedView: MetalVideoContainerView?
        let renderer = MetalVideoRenderer()
        var lastFrameVersion: UInt64 = 0
        var lastFlushVersion: UInt64 = 0
        private weak var directFeed: RemoteMetalVideoFrameFeed?
        private var directFeedConsumerID: UUID?

        var isDirectFrameConsumerActive: Bool {
            directFeedConsumerID != nil
        }

        init(
            onFramesDisplayed: @escaping @Sendable (CMTime, Int, Date, Int?) -> Void,
            onRenderOrientation: @escaping @Sendable (RemoteDesktopRenderOrientation) -> Void
        ) {
            self.onFramesDisplayed = onFramesDisplayed
            self.onRenderOrientation = onRenderOrientation
            renderer.onFramesDisplayed = onFramesDisplayed
            renderer.onRenderOrientation = onRenderOrientation
        }

        deinit {
            let feed = directFeed
            let consumerID = directFeedConsumerID
            Task { @MainActor in
                feed?.removeFrameConsumer(consumerID)
            }
        }

        func attach(to view: MetalVideoContainerView) {
            guard attachedView !== view else { return }
            attachedView = view
            view.configureIfNeeded(renderer: renderer)
        }

        func bind(feed: RemoteMetalVideoFrameFeed, to view: MetalVideoContainerView) {
            attach(to: view)
            guard directFeed !== feed else { return }
            directFeed?.removeFrameConsumer(directFeedConsumerID)
            directFeed = feed
            directFeedConsumerID = feed.addFrameConsumer { [weak self, weak view] frame, version in
                guard let self, let view else { return .staleConsumer }
                switch self.display(frame: frame, version: version, in: view) {
                case .accepted:
                    self.lastFrameVersion = version
                    return .accepted
                case .rejected(let reason):
                    return .rejected(reason: reason)
                }
            }
            if let frame = feed.latestFrame,
               case .accepted = self.display(frame: frame, version: feed.frameVersion, in: view) {
                self.lastFrameVersion = feed.frameVersion
            }
        }

        func display(frame: DecodedPixelBufferFrame, version: UInt64, in view: MetalVideoContainerView) -> MetalVideoRenderer.FrameDisplayResult {
            attach(to: view)
            return renderer.display(frame: frame, version: version, in: view.metalView)
        }

        func flush(view: MetalVideoContainerView, removeDisplayedImage: Bool) {
            attach(to: view)
            renderer.flush(removeDisplayedImage: removeDisplayedImage, in: view.metalView)
        }
    }

    final class MetalVideoContainerView: UIView {
        private static let strictRemoteDisplayFPS = 60
        let metalView = MTKView(frame: .zero)
        private var didConfigure = false
        private weak var cadenceRenderer: MetalVideoRenderer?

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
            cadenceRenderer = renderer
            guard !didConfigure else { return }
            didConfigure = true
            backgroundColor = .black
            metalView.device = renderer.device
            metalView.delegate = renderer
            metalView.colorPixelFormat = .bgra8Unorm
            metalView.framebufferOnly = false
            // MTKView owns the only display cadence. Frame-arrival draws and
            // delayed follow-up draws over-schedule CAMetalDrawable lifetimes.
            metalView.enableSetNeedsDisplay = false
            metalView.isPaused = false
            configureMTKViewCadence()
            metalView.presentsWithTransaction = false
            metalView.isOpaque = true
            metalView.backgroundColor = .black
            metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow != nil, didConfigure {
                configureMTKViewCadence()
            }
        }

        private func configureMTKViewCadence() {
            let screen = window?.screen ?? UIScreen.main
            let targetFPS = Self.displayLinkTargetFPS(for: screen)
            let pumpFPS = Self.displayLinkPumpFPS(for: screen)
            metalView.preferredFramesPerSecond = pumpFPS
            cadenceRenderer?.updateDisplayLinkTiming(
                targetFPS: targetFPS,
                pumpFPS: pumpFPS,
                screenMaxFPS: max(1, screen.maximumFramesPerSecond)
            )
        }

        private static func displayLinkTargetFPS(for screen: UIScreen) -> Int {
            min(strictRemoteDisplayFPS, max(1, screen.maximumFramesPerSecond))
        }

        private static func displayLinkPumpFPS(for screen: UIScreen) -> Int {
            max(displayLinkTargetFPS(for: screen), screen.maximumFramesPerSecond)
        }
    }

    final class MetalVideoRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
        private static let inFlightLimit = 2
        private static let maxQueuedFrames = 3
        private static let realtimeQueuePolicy = "strict-fifo-3-frame-no-drop-no-replacement-vsync"
        private static let realtimeReplacementReason = "none"
        private static let targetFrameInterval: TimeInterval = 1.0 / 60.0
        private static let frameCadenceTolerance: TimeInterval = 0.004
        private static let missedCadenceResetThreshold: TimeInterval = targetFrameInterval
        private static let nativePumpBacklogCatchUpMinimumDepth = 2
        private static let nativePumpBacklogCatchUpFrameAgeMs = 80
        private static let nativePumpBacklogCatchUpMinimumInterval: TimeInterval = 0.5
        let device = MTLCreateSystemDefaultDevice()
        private let commandQueue: MTLCommandQueue?
        private let ciContext: CIContext?
        private var textureCache: CVMetalTextureCache?
        private let passthroughPipelineState: MTLRenderPipelineState?
        private let stateLock = NSLock()
        private struct PassthroughUniforms {
            var uvScale: SIMD2<Float>
        }
        private final class RetainedMetalTexture: @unchecked Sendable {
            private let texture: CVMetalTexture

            init(_ texture: CVMetalTexture) {
                self.texture = texture
            }

            func keepAlive() {}
        }
        private struct PendingRenderFrame {
            let frame: DecodedPixelBufferFrame
            let version: UInt64
            let queuedAt: Date
        }
        enum FrameDisplayResult {
            case accepted
            case rejected(String)
        }
        private var pendingFrames: [PendingRenderFrame] = []
        private var latestEnqueuedFrameVersion: UInt64 = 0
        private var submittedFrameVersion: UInt64 = 0
        private var lastDisplayedFrameVersion: UInt64 = 0
        private var needsClear = true
        private weak var boundView: MTKView?
        private var renderInFlight = false
        private var renderInFlightCount = 0
        private let inFlightSemaphore = DispatchSemaphore(value: MetalVideoRenderer.inFlightLimit)
        private var renderTelemetryWindowStartedAt = Date()
        private var renderDrawCallbacks = 0
        private var renderInputFrames = 0
        private var renderSubmittedFrames = 0
        private var renderDisplayedFrames = 0
        private var renderEmptyQueueSkips = 0
        private var renderDrawableSkips = 0
        private var renderInFlightSkips = 0
        private var renderFailureSkips = 0
        private var renderCadenceHoldSkips = 0
        private var renderNativePumpBacklogCatchUpFrames = 0
        private var renderQueueDrops = 0
        private var renderQueueBackpressure = 0
        private var renderCoalescedFrames = 0
        private var renderMaxQueueDepth = 0
        private var renderTotalMs: Double = 0
        private var renderDirectTextureFrames = 0
        private var renderCIFallbackFrames = 0
        private var renderFrameAgeMaxMs: Int?
        private var displayLinkTargetFPS = 60
        private var displayLinkPumpFPS = 60
        private var screenMaxFPS = 60
        private var nextFrameDueAt = Date.distantPast
        private var lastNativePumpBacklogCatchUpAt = Date.distantPast
        private var lastSourceSize = CGSize.zero
        var onFramesDisplayed: (@Sendable (CMTime, Int, Date, Int?) -> Void)?
        var onRenderOrientation: (@Sendable (RemoteDesktopRenderOrientation) -> Void)?

        override init() {
            if let device = device {
                commandQueue = device.makeCommandQueue()
                ciContext = CIContext(
                    mtlDevice: device,
                    options: [.cacheIntermediates: false]
                )
                var cache: CVMetalTextureCache?
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                textureCache = cache
                passthroughPipelineState = Self.makePassthroughPipelineState(device: device)
            } else {
                commandQueue = nil
                ciContext = nil
                passthroughPipelineState = nil
            }
            super.init()
        }

        @MainActor
        @discardableResult
        func display(frame: DecodedPixelBufferFrame, version: UInt64, in view: MTKView) -> FrameDisplayResult {
            let enqueuedAt = Date()
            stateLock.lock()
            boundView = view
            guard version > lastDisplayedFrameVersion,
                  version > latestEnqueuedFrameVersion else {
                let reason = "nonmonotonic version=\(version) latestEnqueued=\(latestEnqueuedFrameVersion) displayed=\(lastDisplayedFrameVersion) pending=\(pendingFrames.count)"
                stateLock.unlock()
                SkyBridgeSmokeTraceWriter.appendStatus(
                    "metal-renderer-reject reason=\"\(reason)\""
                )
                return .rejected(reason)
            }
            if pendingFrames.count >= Self.maxQueuedFrames {
                let reason = "queue-full depth=\(pendingFrames.count + 1) max=\(Self.maxQueuedFrames) version=\(version) latestEnqueued=\(latestEnqueuedFrameVersion) displayed=\(lastDisplayedFrameVersion)"
                renderQueueBackpressure += 1
                stateLock.unlock()
                SkyBridgeSmokeTraceWriter.appendStatus(
                    "metal-renderer-backpressure reason=\"\(reason)\""
                )
                return .rejected(reason)
            }
            pendingFrames.append(PendingRenderFrame(frame: frame, version: version, queuedAt: enqueuedAt))
            latestEnqueuedFrameVersion = version
            needsClear = false
            renderInputFrames += 1
            renderMaxQueueDepth = max(renderMaxQueueDepth, pendingFrames.count)
            lastSourceSize = CGSize(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
            stateLock.unlock()
            return .accepted
        }

        @MainActor
        func updateDisplayLinkTiming(targetFPS: Int, pumpFPS: Int, screenMaxFPS: Int) {
            stateLock.lock()
            displayLinkTargetFPS = max(1, targetFPS)
            displayLinkPumpFPS = max(1, pumpFPS)
            self.screenMaxFPS = max(1, screenMaxFPS)
            nextFrameDueAt = .distantPast
            stateLock.unlock()
        }

        @MainActor
        private func prepareDrawableSize(for view: MTKView) -> Bool {
            guard view.bounds.width > 0, view.bounds.height > 0 else {
                return false
            }
            let drawableScale = view.window?.screen.scale ?? UIScreen.main.scale
            let nextDrawableSize = CGSize(
                width: max(view.bounds.width * drawableScale, 1),
                height: max(view.bounds.height * drawableScale, 1)
            )
            if view.contentScaleFactor != drawableScale {
                view.contentScaleFactor = drawableScale
            }
            if view.drawableSize != nextDrawableSize {
                view.drawableSize = nextDrawableSize
            }
            return true
        }

        @MainActor
        func flush(removeDisplayedImage: Bool, in view: MTKView) {
            if removeDisplayedImage {
                stateLock.lock()
                boundView = view
                pendingFrames.removeAll(keepingCapacity: true)
                latestEnqueuedFrameVersion = 0
                submittedFrameVersion = 0
                lastDisplayedFrameVersion = 0
                needsClear = true
                renderInFlightCount = 0
                renderInFlight = false
                renderFrameAgeMaxMs = nil
                nextFrameDueAt = .distantPast
                lastNativePumpBacklogCatchUpAt = .distantPast
                stateLock.unlock()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard prepareDrawableSize(for: view) else {
                return
            }
            guard view.drawableSize.width > 0, view.drawableSize.height > 0 else {
                return
            }
            let hasPendingFrame: Bool
            let shouldClear: Bool
            let shouldSubmitFrame: Bool
            let now = Date()
            stateLock.lock()
            renderDrawCallbacks += 1
            hasPendingFrame = !pendingFrames.isEmpty
            shouldClear = needsClear
            shouldSubmitFrame = shouldClear || shouldSubmitFrameForCadenceLocked(now: now)
            stateLock.unlock()

            guard shouldClear || hasPendingFrame else {
                recordRenderSkip(.emptyQueue, drawableSize: view.drawableSize)
                return
            }
            guard shouldClear || shouldSubmitFrame else {
                recordRenderSkip(.cadenceHold, drawableSize: view.drawableSize)
                return
            }
            guard inFlightSemaphore.wait(timeout: .now()) == .success else {
                recordRenderSkip(.inFlight, drawableSize: view.drawableSize)
                return
            }
            stateLock.lock()
            renderInFlightCount += 1
            renderInFlight = renderInFlightCount > 0
            stateLock.unlock()
            var shouldSignalSemaphoreOnExit = true
            defer {
                if shouldSignalSemaphoreOnExit {
                    stateLock.lock()
                    renderInFlightCount = max(0, renderInFlightCount - 1)
                    renderInFlight = renderInFlightCount > 0
                    stateLock.unlock()
                    inFlightSemaphore.signal()
                }
            }
            guard let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                recordRenderSkip(.failure, drawableSize: view.drawableSize)
                return
            }

            let drawableWidth = max(Int(view.drawableSize.width.rounded(.down)), 1)
            let drawableHeight = max(Int(view.drawableSize.height.rounded(.down)), 1)
            guard let renderTarget = makeDrawableRenderTarget(for: view) else {
                recordRenderSkip(.drawableUnavailable, drawableSize: view.drawableSize)
                return
            }
            let drawableSize = CGSize(width: CGFloat(drawableWidth), height: CGFloat(drawableHeight))
            let drawableBounds = CGRect(
                x: 0,
                y: 0,
                width: CGFloat(drawableWidth),
                height: CGFloat(drawableHeight)
            )
            stateLock.lock()
            let pendingFrame = pendingFrames.isEmpty ? nil : pendingFrames.removeFirst()
            let frameVersion = pendingFrame?.version ?? 0
            submittedFrameVersion = frameVersion
            if pendingFrame != nil {
                renderSubmittedFrames += 1
            }
            stateLock.unlock()

            guard let pendingFrame else {
                guard shouldClear else {
                    recordRenderSkip(.emptyQueue, drawableSize: view.drawableSize)
                    return
                }
                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderTarget.renderPassDescriptor) {
                    encoder.endEncoding()
                } else {
                    recordRenderSkip(.failure, drawableSize: view.drawableSize)
                    return
                }
                addClearCommandCompletion(
                    to: commandBuffer,
                    drawableSize: drawableSize
                )
                shouldSignalSemaphoreOnExit = false
                commandBuffer.present(renderTarget.drawable)
                commandBuffer.commit()
                return
            }
            let frame = pendingFrame.frame
            let presentationTimeStamp = frame.presentationTimeStamp
            let frameAgeMs = Self.frameAgeMilliseconds(for: presentationTimeStamp)
                ?? Self.frameAgeMilliseconds(since: pendingFrame.queuedAt)
            let renderStartedAt = DispatchTime.now().uptimeNanoseconds

            if let retainedTexture = encodeDirectTextureFrame(
                frame,
                renderTarget: renderTarget,
                commandBuffer: commandBuffer
            ) {
                stateLock.lock()
                renderDirectTextureFrames += 1
                stateLock.unlock()
                addDisplayedFrameCompletion(
                    to: commandBuffer,
                    frameVersion: frameVersion,
                    presentationTimeStamp: presentationTimeStamp,
                    frameAgeMs: frameAgeMs,
                    renderStartedAt: renderStartedAt,
                    drawableSize: drawableSize,
                    retainedTexture: RetainedMetalTexture(retainedTexture)
                )
                shouldSignalSemaphoreOnExit = false
                commandBuffer.present(renderTarget.drawable)
                commandBuffer.commit()
                return
            }

            guard let ciContext else {
                recordRenderSkip(.failure, drawableSize: view.drawableSize)
                return
            }
            stateLock.lock()
            renderCIFallbackFrames += 1
            stateLock.unlock()
            let backingImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
            let visibleRect = CGRect(
                x: backingImage.extent.minX,
                y: backingImage.extent.minY,
                width: min(max(CGFloat(frame.width), 1), max(backingImage.extent.width, 1)),
                height: min(max(CGFloat(frame.height), 1), max(backingImage.extent.height, 1))
            )
            let image = backingImage.cropped(to: visibleRect)
            let scaleX = drawableBounds.width / max(image.extent.width, 1)
            let scaleY = drawableBounds.height / max(image.extent.height, 1)
            let uprightTransform = CGAffineTransform(
                a: scaleX,
                b: 0,
                c: 0,
                d: scaleY,
                tx: -image.extent.minX * scaleX,
                ty: -image.extent.minY * scaleY
            )
            let renderedImage = image.transformed(
                by: uprightTransform
            )

            ciContext.render(
                renderedImage,
                to: renderTarget.texture,
                commandBuffer: commandBuffer,
                bounds: drawableBounds,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            addDisplayedFrameCompletion(
                to: commandBuffer,
                frameVersion: frameVersion,
                presentationTimeStamp: presentationTimeStamp,
                frameAgeMs: frameAgeMs,
                renderStartedAt: renderStartedAt,
                drawableSize: drawableSize,
                retainedTexture: nil
            )
            shouldSignalSemaphoreOnExit = false
            commandBuffer.present(renderTarget.drawable)
            commandBuffer.commit()
        }

        private func shouldSubmitFrameForCadenceLocked(now: Date) -> Bool {
            guard !pendingFrames.isEmpty else { return false }
            if nextFrameDueAt == .distantPast {
                nextFrameDueAt = now
            }
            let lateBy = now.timeIntervalSince(nextFrameDueAt)
            if lateBy > Self.missedCadenceResetThreshold {
                nextFrameDueAt = now
            }
            let hasNativePumpHeadroom = displayLinkPumpFPS > displayLinkTargetFPS
            let shouldUseNativePumpCatchUp = hasNativePumpHeadroom
                && lateBy > Self.frameCadenceTolerance
                && lateBy <= Self.missedCadenceResetThreshold
            guard nextFrameDueAt.timeIntervalSince(now) <= Self.frameCadenceTolerance
                || !hasNativePumpHeadroom
                || shouldUseNativePumpCatchUp else {
                guard shouldUseNativePumpBacklogCatchUpLocked(
                    now: now,
                    hasNativePumpHeadroom: hasNativePumpHeadroom
                ) else {
                    return false
                }
                lastNativePumpBacklogCatchUpAt = now
                renderNativePumpBacklogCatchUpFrames += 1
                return true
            }
            advanceNextFrameDueAtLocked(submittedAt: Date())
            return true
        }

        private func shouldUseNativePumpBacklogCatchUpLocked(
            now: Date,
            hasNativePumpHeadroom: Bool
        ) -> Bool {
            guard hasNativePumpHeadroom,
                  pendingFrames.count >= Self.nativePumpBacklogCatchUpMinimumDepth,
                  let oldestFrame = pendingFrames.first else {
                return false
            }
            guard now.timeIntervalSince(lastNativePumpBacklogCatchUpAt) >= Self.nativePumpBacklogCatchUpMinimumInterval else {
                return false
            }
            let oldestAgeMs = Self.frameAgeMilliseconds(for: oldestFrame.frame.presentationTimeStamp)
                ?? Self.frameAgeMilliseconds(since: oldestFrame.queuedAt)
            return oldestAgeMs >= Self.nativePumpBacklogCatchUpFrameAgeMs
        }

        private func advanceNextFrameDueAtLocked(submittedAt: Date) {
            if nextFrameDueAt == .distantPast {
                nextFrameDueAt = submittedAt
            }
            let lateBy = submittedAt.timeIntervalSince(nextFrameDueAt)
            if lateBy > Self.missedCadenceResetThreshold {
                nextFrameDueAt = submittedAt
            }
            nextFrameDueAt = nextFrameDueAt.addingTimeInterval(Self.targetFrameInterval)
        }

        private static func makePassthroughPipelineState(device: MTLDevice) -> MTLRenderPipelineState? {
            guard let library = try? device.makeLibrary(source: passthroughShaderSource, options: nil),
                  let vertexFunction = library.makeFunction(name: "skybridgeRemoteDesktopVertex"),
                  let fragmentFunction = library.makeFunction(name: "skybridgeRemoteDesktopFragment") else {
                return nil
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        private static let passthroughShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct Uniforms {
            float2 uvScale;
        };

        vertex VertexOut skybridgeRemoteDesktopVertex(uint vertexID [[vertex_id]]) {
            float2 positions[3] = {
                float2(-1.0, -1.0),
                float2( 3.0, -1.0),
                float2(-1.0,  3.0)
            };
            float2 texCoords[3] = {
                float2(0.0, 1.0),
                float2(2.0, 1.0),
                float2(0.0, -1.0)
            };
            VertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        fragment float4 skybridgeRemoteDesktopFragment(
            VertexOut in [[stage_in]],
            texture2d<float, access::sample> frameTexture [[texture(0)]],
            constant Uniforms& uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(
                mag_filter::linear,
                min_filter::linear,
                address::clamp_to_edge
            );
            float2 uv = clamp(in.texCoord * uniforms.uvScale, float2(0.0), uniforms.uvScale);
            return frameTexture.sample(linearSampler, uv);
        }
        """

        private func encodeDirectTextureFrame(
            _ frame: DecodedPixelBufferFrame,
            renderTarget: DrawableRenderTarget,
            commandBuffer: MTLCommandBuffer
        ) -> CVMetalTexture? {
            guard let textureCache,
                  let passthroughPipelineState else {
                return nil
            }
            let pixelBuffer = frame.pixelBuffer
            let pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
            let pixelHeight = CVPixelBufferGetHeight(pixelBuffer)
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }

            var textureRef: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                pixelWidth,
                pixelHeight,
                0,
                &textureRef
            )
            guard status == kCVReturnSuccess,
                  let textureRef,
                  let sourceTexture = CVMetalTextureGetTexture(textureRef),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderTarget.renderPassDescriptor) else {
                return nil
            }

            var uniforms = PassthroughUniforms(
                uvScale: SIMD2<Float>(
                    min(1.0, max(0.0, Float(frame.width) / Float(pixelWidth))),
                    min(1.0, max(0.0, Float(frame.height) / Float(pixelHeight)))
                )
            )
            encoder.setRenderPipelineState(passthroughPipelineState)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PassthroughUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            return textureRef
        }

        private func addDisplayedFrameCompletion(
            to commandBuffer: MTLCommandBuffer,
            frameVersion: UInt64,
            presentationTimeStamp: CMTime,
            frameAgeMs: Int?,
            renderStartedAt: UInt64,
            drawableSize: CGSize,
            retainedTexture: RetainedMetalTexture?
        ) {
            let inFlightSemaphore = self.inFlightSemaphore
            let onFramesDisplayed = self.onFramesDisplayed
            commandBuffer.addCompletedHandler { [weak self, onFramesDisplayed, inFlightSemaphore, retainedTexture] commandBuffer in
                retainedTexture?.keepAlive()
                guard let self else {
                    inFlightSemaphore.signal()
                    return
                }
                let renderEndedAt = DispatchTime.now().uptimeNanoseconds
                let renderMs = Double(renderEndedAt - renderStartedAt) / 1_000_000
                let telemetrySnapshot: RenderTelemetrySnapshot?
                let completedAt = Date()
                var displayedCallbackCount = 0
                var displayedCallbackPresentationTimeStamp = CMTime.invalid
                var displayedCallbackCompletedAt = completedAt
                self.stateLock.lock()
                if self.submittedFrameVersion == frameVersion {
                    self.submittedFrameVersion = 0
                }
                if commandBuffer.status == .error {
                    self.renderFailureSkips += 1
                } else {
                    self.lastDisplayedFrameVersion = max(self.lastDisplayedFrameVersion, frameVersion)
                    self.renderDisplayedFrames += 1
                    displayedCallbackCount = 1
                    displayedCallbackPresentationTimeStamp = presentationTimeStamp
                    displayedCallbackCompletedAt = completedAt
                    if let frameAgeMs {
                        self.renderFrameAgeMaxMs = max(self.renderFrameAgeMaxMs ?? frameAgeMs, frameAgeMs)
                    }
                }
                self.renderTotalMs += renderMs
                self.renderInFlightCount = max(0, self.renderInFlightCount - 1)
                self.renderInFlight = self.renderInFlightCount > 0
                telemetrySnapshot = self.makeRenderTelemetrySnapshotIfNeededLocked(
                    now: completedAt,
                    drawableSize: drawableSize,
                    frameAgeMs: frameAgeMs
                )
                self.stateLock.unlock()
                inFlightSemaphore.signal()
                self.logRenderTelemetryIfNeeded(telemetrySnapshot)
                if displayedCallbackCount > 0 {
                    onFramesDisplayed?(
                        displayedCallbackPresentationTimeStamp,
                        displayedCallbackCount,
                        displayedCallbackCompletedAt,
                        frameAgeMs
                    )
                }
            }
        }

        private func addClearCommandCompletion(
            to commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize
        ) {
            let inFlightSemaphore = self.inFlightSemaphore
            commandBuffer.addCompletedHandler { [weak self, inFlightSemaphore] commandBuffer in
                inFlightSemaphore.signal()
                guard let self else { return }
                let telemetrySnapshot: RenderTelemetrySnapshot?
                self.stateLock.lock()
                if commandBuffer.status == .error {
                    self.renderFailureSkips += 1
                } else {
                    self.needsClear = false
                }
                self.renderInFlightCount = max(0, self.renderInFlightCount - 1)
                self.renderInFlight = self.renderInFlightCount > 0
                telemetrySnapshot = self.makeRenderTelemetrySnapshotIfNeededLocked(
                    now: Date(),
                    drawableSize: drawableSize,
                    frameAgeMs: nil
                )
                self.stateLock.unlock()
                self.logRenderTelemetryIfNeeded(telemetrySnapshot)
            }
        }

        private struct DrawableRenderTarget {
            let drawable: CAMetalDrawable
            let texture: MTLTexture
            let renderPassDescriptor: MTLRenderPassDescriptor
            let size: CGSize
        }

        @MainActor
        private func makeDrawableRenderTarget(for view: MTKView) -> DrawableRenderTarget? {
            guard let drawable = view.currentDrawable else {
                return nil
            }
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = view.clearColor
            return DrawableRenderTarget(
                drawable: drawable,
                texture: drawable.texture,
                renderPassDescriptor: renderPassDescriptor,
                size: CGSize(
                    width: CGFloat(drawable.texture.width),
                    height: CGFloat(drawable.texture.height)
                )
            )
        }

        private enum RenderSkipReason {
            case emptyQueue
            case cadenceHold
            case drawableUnavailable
            case inFlight
            case failure
        }

        private struct RenderTelemetrySnapshot {
            let interval: TimeInterval
            let drawCallbacks: Int
            let input: Int
            let submitted: Int
            let displayed: Int
            let emptyQueueSkips: Int
            let drawableSkips: Int
            let inFlightSkips: Int
            let failureSkips: Int
            let cadenceHoldSkips: Int
            let queueDrops: Int
            let queueBackpressure: Int
            let maxQueueDepth: Int
            let nativePumpBacklogCatchUpFrames: Int
            let averageRenderMs: Double
            let frameAgeMs: Int?
            let coalescedBeforeDraw: Int
            let directTextureFrames: Int
            let ciFallbackFrames: Int
            let displayLinkTargetFPS: Int
            let displayLinkPumpFPS: Int
            let screenMaxFPS: Int
            let sourceSize: CGSize
            let drawableSize: CGSize
            let submittedFrameVersion: UInt64
            let lastDisplayedFrameVersion: UInt64
        }

        private func recordRenderSkip(_ reason: RenderSkipReason, drawableSize: CGSize) {
            let telemetrySnapshot: RenderTelemetrySnapshot?
            stateLock.lock()
            switch reason {
            case .emptyQueue:
                renderEmptyQueueSkips += 1
            case .cadenceHold:
                renderCadenceHoldSkips += 1
            case .drawableUnavailable:
                renderDrawableSkips += 1
            case .inFlight:
                renderInFlightSkips += 1
            case .failure:
                renderFailureSkips += 1
            }
            telemetrySnapshot = makeRenderTelemetrySnapshotIfNeededLocked(
                now: Date(),
                drawableSize: drawableSize,
                frameAgeMs: nil
            )
            stateLock.unlock()
            logRenderTelemetryIfNeeded(telemetrySnapshot)
        }

        private func makeRenderTelemetrySnapshotIfNeededLocked(
            now: Date,
            drawableSize: CGSize,
            frameAgeMs: Int?
        ) -> RenderTelemetrySnapshot? {
            let interval = now.timeIntervalSince(renderTelemetryWindowStartedAt)
            guard interval >= 1.0 else { return nil }
            let submitted = renderSubmittedFrames
            let averageRenderMs = submitted > 0 ? renderTotalMs / Double(submitted) : 0
            let frameAgeMaxMs = [renderFrameAgeMaxMs, frameAgeMs].compactMap { $0 }.max()
            let snapshot = RenderTelemetrySnapshot(
                interval: interval,
                drawCallbacks: renderDrawCallbacks,
                input: renderInputFrames,
                submitted: submitted,
                displayed: renderDisplayedFrames,
                emptyQueueSkips: renderEmptyQueueSkips,
                drawableSkips: renderDrawableSkips,
                inFlightSkips: renderInFlightSkips,
                failureSkips: renderFailureSkips,
                cadenceHoldSkips: renderCadenceHoldSkips,
                queueDrops: renderQueueDrops,
                queueBackpressure: renderQueueBackpressure,
                maxQueueDepth: renderMaxQueueDepth,
                nativePumpBacklogCatchUpFrames: renderNativePumpBacklogCatchUpFrames,
                averageRenderMs: averageRenderMs,
                frameAgeMs: frameAgeMaxMs,
                coalescedBeforeDraw: renderCoalescedFrames,
                directTextureFrames: renderDirectTextureFrames,
                ciFallbackFrames: renderCIFallbackFrames,
                displayLinkTargetFPS: displayLinkTargetFPS,
                displayLinkPumpFPS: displayLinkPumpFPS,
                screenMaxFPS: screenMaxFPS,
                sourceSize: lastSourceSize,
                drawableSize: drawableSize,
                submittedFrameVersion: submittedFrameVersion,
                lastDisplayedFrameVersion: lastDisplayedFrameVersion
            )
            renderTelemetryWindowStartedAt = now
            renderDrawCallbacks = 0
            renderInputFrames = 0
            renderSubmittedFrames = 0
            renderDisplayedFrames = 0
            renderEmptyQueueSkips = 0
            renderDrawableSkips = 0
            renderInFlightSkips = 0
            renderFailureSkips = 0
            renderCadenceHoldSkips = 0
            renderQueueDrops = 0
            renderQueueBackpressure = 0
            renderNativePumpBacklogCatchUpFrames = 0
            renderCoalescedFrames = 0
            renderMaxQueueDepth = 0
            renderTotalMs = 0
            renderDirectTextureFrames = 0
            renderCIFallbackFrames = 0
            renderFrameAgeMaxMs = nil
            return snapshot
        }

        private func logRenderTelemetryIfNeeded(_ snapshot: RenderTelemetrySnapshot?) {
            guard let snapshot else { return }
            let inputFPS = String(format: "%.1f", Double(snapshot.input) / max(snapshot.interval, 0.001))
            let submittedFPS = String(format: "%.1f", Double(snapshot.submitted) / max(snapshot.interval, 0.001))
            let displayedFPS = String(format: "%.1f", Double(snapshot.displayed) / max(snapshot.interval, 0.001))
            let renderMs = String(format: "%.2f", snapshot.averageRenderMs)
            let frameAgeText = snapshot.frameAgeMs.map(String.init) ?? "-"
            let sampleMs = Int((snapshot.interval * 1000).rounded())
            let renderPath = snapshot.ciFallbackFrames == 0 ? "directBGRA" : "mixed"
            let telemetryLine = "Metal render telemetry: sampleMs=\(sampleMs) input=\(snapshot.input) submitted=\(snapshot.submitted) displayed=\(snapshot.displayed) inputFPS=\(inputFPS) submittedFPS=\(submittedFPS) displayFPS=\(displayedFPS) renderMs=\(renderMs) frameAgeMs=\(frameAgeText) source=\(Int(snapshot.sourceSize.width))x\(Int(snapshot.sourceSize.height)) orientation=upright drawableAccess=single-current-drawable displayLink=mtkview-native displayLinkTargetFPS=\(snapshot.displayLinkTargetFPS) displayLinkPumpFPS=\(snapshot.displayLinkPumpFPS) screenMaxFPS=\(snapshot.screenMaxFPS) displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 frameDriven=mtkview-native-vsync renderPath=\(renderPath) directBGRA=\(snapshot.directTextureFrames) ciFallback=\(snapshot.ciFallbackFrames) drawCallbacks=\(snapshot.drawCallbacks) inFlightLimit=\(Self.inFlightLimit) queuePolicy=\(Self.realtimeQueuePolicy) queueCapacity=\(Self.maxQueuedFrames) queueDepthMax=\(snapshot.maxQueueDepth) queueDrop=\(snapshot.queueDrops) queueBackpressure=\(snapshot.queueBackpressure) nativePumpCatchUp=\(snapshot.nativePumpBacklogCatchUpFrames) coalescedBeforeDraw=\(snapshot.coalescedBeforeDraw) realtimeReplacementBeforeDraw=\(snapshot.coalescedBeforeDraw) realtimeReplacementReason=\(Self.realtimeReplacementReason) emptyQueueTick=\(snapshot.emptyQueueSkips) cadenceHoldTick=\(snapshot.cadenceHoldSkips) drawableSkip=\(snapshot.drawableSkips) inflightSkip=\(snapshot.inFlightSkips) failureSkip=\(snapshot.failureSkips) drawable=\(Int(snapshot.drawableSize.width))x\(Int(snapshot.drawableSize.height)) submittedVersion=\(snapshot.submittedFrameVersion) displayedVersion=\(snapshot.lastDisplayedFrameVersion)"
            onRenderOrientation?(.upright)
            SkyBridgeLogger.shared.debug(
                "📈 \(telemetryLine)"
            )
            SkyBridgeSmokeTraceWriter.appendStatus(telemetryLine)
        }

        private static func frameAgeMilliseconds(for presentationTimeStamp: CMTime) -> Int? {
            guard presentationTimeStamp.flags.contains(.valid) else { return nil }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let ageSeconds = CMTimeGetSeconds(CMTimeSubtract(now, presentationTimeStamp))
            guard ageSeconds.isFinite, ageSeconds >= 0 else { return nil }
            return Int((ageSeconds * 1_000).rounded())
        }

        private static func frameAgeMilliseconds(since queuedAt: Date) -> Int {
            Int(max(0, Date().timeIntervalSince(queuedAt) * 1_000).rounded())
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
            bufferedFrames.append(contentsOf: frames)
            if bufferedFrames.count > Self.maxBufferedFrames {
                bufferedFrames.removeFirst(
                    bufferedFrames.count - Self.maxBufferedFrames
                )
            }
            scheduleBufferedFrameDrain()
        }

        @MainActor
        func flush(view: SampleBufferDisplayView, removeDisplayedImage: Bool) {
            attach(to: view)
            guard let layer = attachedLayer else { return }
            bufferedFrames.removeAll(keepingCapacity: true)
            isDrainScheduled = false
            layer.stopRequestingMediaData()
            if removeDisplayedImage {
                layer.flushAndRemoveImage()
            } else {
                layer.flush()
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

        @MainActor
        private func scheduleBufferedFrameDrain() {
            guard !isDrainScheduled else { return }
            guard let layer = attachedLayer else { return }
            isDrainScheduled = true
            layer.stopRequestingMediaData()
            layer.requestMediaDataWhenReady(on: .main) { [weak self] in
                MainActor.assumeIsolated {
                    self?.drainReadyBufferedFrames()
                }
            }
        }

        @MainActor
        private func drainReadyBufferedFrames() {
            guard let layer = attachedLayer else {
                isDrainScheduled = false
                return
            }

            while layer.isReadyForMoreMediaData {
                if layer.requiresFlushToResumeDecoding {
                    bufferedFrames.removeAll(keepingCapacity: true)
                    isDrainScheduled = false
                    layer.stopRequestingMediaData()
                    layer.flush()
                    onRequiresFlush()
                    return
                }

                guard !bufferedFrames.isEmpty else {
                    isDrainScheduled = false
                    layer.stopRequestingMediaData()
                    return
                }

                let frame = bufferedFrames.removeFirst()
                layer.enqueue(frame.sampleBuffer)
                onFrameEnqueued(frame.presentationTimeStamp, bufferedFrames.count)
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
                ) { [weak self] notification in
                    guard let self,
                          let renderer = notification.object as? AVSampleBufferVideoRenderer,
                          renderer.requiresFlushToResumeDecoding else { return }
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
