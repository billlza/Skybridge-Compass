// macOS-exclusive: built on macOS-only frameworks (see SkyBridgeCore iOS portability
// notes). Excluded from other platforms; no behaviour changes on macOS.
#if os(macOS)
//
// RemoteControlManager.swift
// SkyBridgeCore
//
// 近距硬件级镜像栈（macOS 14.0 – 26.x）
// 依赖：BaseManager / RemoteTextureFeed / RemoteFrameRenderer / ScreenCaptureKitStreamer
//

import Foundation
import Network
import OSLog
import Combine
import Metal
import CoreGraphics
import ApplicationServices
import ImageIO
import ScreenCaptureKit
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia

// MARK: - 连接状态封装（每个设备一条 NWConnection）

private final class PeerConnection {
    let id: String
    let role: RemoteControlSessionRole
    let connection: NWConnection
    var remoteVideoFormats: Set<String>
    var requestedStreamConfiguration: RemoteDesktopStreamConfiguration?
    var pendingRequestedStreamConfiguration: RemoteDesktopStreamConfiguration?
    var lastAcceptedRawStreamConfiguration: RemoteDesktopStreamConfiguration?
    var streamConfigurationApplicationGeneration: UInt64 = 0
    var captureCompatibilityOverride: RemoteFrameType?
    var lastViewerStreamRefreshAt: Date = .distantPast
    var securityNoticeId: UUID?
    var securityAdmissionApproved = false
    let clipboardSessionId: UUID
    let audioSessionId: UUID
    let outboundFramePump: RemoteControlOutboundFramePump
 /// 专用收包队列，避免和 UI/MainActor 混在一起
    let queue: DispatchQueue

    // Optional: P2P v1 handshake over this TCP connection to derive SessionKeys, then AES-GCM app payload.
    // Backward compatible: if peer never speaks handshake frames, we keep plaintext RemoteMessage JSON.
    @available(macOS 14.0, *)
    var handshakeDriver: HandshakeDriver?
    @available(macOS 14.0, *)
    var handshakePeer: PeerIdentifier?
    @available(macOS 14.0, *)
    var sessionKeys: SessionKeys?
    @available(macOS 14.0, *)
    var soaPairKey: Data?
    @available(macOS 14.0, *)
    var soaEstablishedLease: PeerSessionArbiter.EstablishedLease?
    @available(macOS 14.0, *)
    let secureEnvelopeSendSequencer = RemoteControlSecureEnvelopeSendSequencer()
    @available(macOS 14.0, *)
    var secureEnvelopeReplayWindow = RemoteControlSecureReplayWindow()
    @available(macOS 14.0, *)
    var realtimeAudioSender: RemoteRealtimeMediaAudioSender?
    @available(macOS 14.0, *)
    var realtimeAudioSenderOwnership = RemoteControlRealtimeAudioSenderOwnership()

    init(
        id: String,
        role: RemoteControlSessionRole,
        connection: NWConnection,
        remoteVideoFormats: Set<String> = []
    ) {
        self.id = id
        self.role = role
        self.connection = connection
        self.remoteVideoFormats = Set(remoteVideoFormats.map { $0.lowercased() })
        self.clipboardSessionId = UUID()
        self.audioSessionId = UUID()
        self.outboundFramePump = RemoteControlOutboundFramePump(
            peerId: id,
            connection: connection,
            maxFramedMessageBytes: 8_000_000,
            secureEnvelopeSendSequencer: secureEnvelopeSendSequencer
        )
        self.queue = DispatchQueue(
            label: "com.skybridge.remote.\(id)",
            qos: .userInitiated
        )
    }
}

@available(macOS 14.0, *)
struct RemoteControlRealtimeAudioSenderOwnership: Sendable {
    struct Lease: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private(set) var currentLease: Lease?

    mutating func reserve() -> Lease {
        generation &+= 1
        let lease = Lease(generation: generation)
        currentLease = lease
        return lease
    }

    mutating func invalidate() {
        generation &+= 1
        currentLease = nil
    }

    func isCurrent(_ lease: Lease) -> Bool {
        currentLease == lease && lease.generation == generation
    }
}

@available(macOS 14.0, *)
private enum RemoteControlStrictMediaFailureOwner {
    case screenSharingAttempt(UInt64)
    case realtimeAudioSender(RemoteControlRealtimeAudioSenderOwnership.Lease)
}

@available(macOS 14.0, *)
struct RemoteControlRealtimeAudioReceiverReuseKey: Equatable, Sendable {
    let peerId: String
    let peerIdentity: ObjectIdentifier
    let secureSessionId: String
    let sendKey: Data
    let receiveKey: Data
    let role: HandshakeRole
    let transcriptHash: Data
    let mode: SkyBridgeMediaAudioMode
    let interfaceBindingIdentity: SkyBridgeRealtimeMediaInterfaceBinding.Identity
    let authenticatedRemoteHost: String
}

@available(macOS 14.0, *)
private final class RemoteControlHandshakeTransport: DiscoveryTransport, @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(to peer: PeerIdentifier, data: Data) async throws {
        _ = peer
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }
}

// MARK: - 硬件级远程控制 / 近距镜像管理器

/// 说明：
/// - 角色1：控制别人的机器（isControlling = true）
/// - 从连接上接收 .screenData（ScreenData）
/// - 向对端发送 .mouseEvent / .keyboardEvent
/// - 角色2：被别人控制（isBeingControlled = true）
/// - 本机用 ScreenCaptureKit + 硬件编码推送 .screenData
/// - 从连接上接收 .mouseEvent / .keyboardEvent / .clipboard / .streamConfiguration，并在本机应用
@MainActor
public final class RemoteControlManager: BaseManager {

    private static func streamRefreshTokenLogState(_ token: UInt64?) -> String {
        token == nil ? "missing" : "present"
    }

    enum HandshakeSyncResult: Equatable {
        case pending
        case established
        case retryableFailure(String)
    }

    enum SecureChannelWaitResult: Equatable {
        case established
        case aborted(String)
        case timedOut
    }

    static func shouldKeepTransportAliveAfterHandshakeFailure(
        for _: RemoteControlSessionRole
    ) -> Bool {
        false
    }

 // MARK: 发布给 UI 的状态

    @Published public private(set) var isControlling: Bool = false
    @Published public private(set) var isBeingControlled: Bool = false
    @Published public private(set) var connectedDevices: [String] = []
    @Published public private(set) var screenSharingActive: Bool = false
    @Published public private(set) var currentRenderingMode: RenderingMode = .stable
    public var preferredRenderingMode: RenderingMode = .stable {
        didSet {
            guard preferredRenderingMode != oldValue else { return }
            applyPreferredRenderingModeToActiveViewingSession()
        }
    }

 /// 近距镜像纹理（供 SwiftUI / AppKit 直接渲染）
    public let textureFeed = RemoteTextureFeed()

 /// 实时性能指标
    @Published public private(set) var bandwidthMbps: Double = 0
    @Published public private(set) var latencyMs: Double = 0
    @Published public private(set) var estimatedFPS: Int = 0

 /// 指标历史（UI 折线用）
    @Published public private(set) var bandwidthHistory: [Double] = []
    @Published public private(set) var fpsHistory: [Int] = []
    private let historyCapacity = 120

    private func emitSmokeTrace(_ message: String) {
        RemoteControlSmokeStatusWriter.append(message)
    }

 // MARK: 内部组件

    private let renderer = RemoteFrameRenderer()
    /// 三层渲染模式控制器
    public let renderingModeController = RenderingModeController()
    /// 稳定渲染器（Phase 1 正式产品化）
    private lazy var stableRenderer: StableRenderer = {
        StableRenderer(healthMonitor: renderingModeController.healthMonitor)
    }()
    /// 高性能渲染器（Phase 2 显示驱动拉帧）
    private lazy var fluidRenderer: FluidRenderer = {
        FluidRenderer(healthMonitor: renderingModeController.healthMonitor)
    }()
    /// 高保真渲染器（Phase 3 HDR/色彩管线）
    private lazy var referenceRenderer: ReferenceRenderer = {
        let r = ReferenceRenderer(healthMonitor: renderingModeController.healthMonitor)
        r.onDegradationNeeded = { [weak self] reason in
            self?.renderingModeController.triggerAutoDegradation(reason: reason)
        }
        return r
    }()
    private var viewingRenderersConfigured = false
    private lazy var textureFeedDeliveryGate = LatestTextureDeliveryGate(feed: textureFeed)
    private var captureStreamer: ScreenCaptureKitStreamer?
    private var realtimeAudioCaptureStreamer: ScreenCaptureKitStreamer?
    private var realtimeAudioCaptureStrictMediaFallbacks: Bool?
    private var screenCaptureWatchdogTask: Task<Void, Never>?
    private var screenCaptureRestartInProgress = false
    private var screenCaptureStartupRetryCountByPeerId: [String: Int] = [:]
    private var screenSharingAttemptGate = RemoteControlScreenSharingAttemptGate()
#if os(macOS)
    private var realtimeStreamingActivity: NSObjectProtocol?
    private var realtimeStreamingActivityPeerId: String?
#endif
    private var controllingPeers: [String: PeerConnection] = [:]
    private var beingControlledPeers: [String: PeerConnection] = [:]
    private var controllingDeviceIds: Set<String> = []
    private var beingControlledDeviceIds: Set<String> = []
    private let maxFramedMessageBytes = 8_000_000
    private var interactionTelemetryTasksByPeerId: [String: Task<Void, Never>] = [:]
    private var activeClipboardPeerId: String?
    private let viewingAudioSessionId = UUID()
    private var lastViewingInboundScreenTimestamp: TimeInterval?
    private var lastSentViewerStreamConfiguration: RemoteDesktopStreamConfiguration?
    private var outboundMouseClickClassifier = RemoteMouseClickClassifier()
    @available(macOS 14.0, *)
    private var p2pRealtimeAudioReceiver: SkyBridgeUDPRealtimeMediaReceiver?
    @available(macOS 14.0, *)
    private var p2pRealtimeAudioRenderer: RemoteRealtimeMediaAudioReceiver?
    @available(macOS 14.0, *)
    private var p2pRealtimeAudioReceiverReuseKey: RemoteControlRealtimeAudioReceiverReuseKey?
    private var p2pRealtimeAudioReceiverEndpoint: SkyBridgeMediaEndpoint?
    private var p2pRealtimeAudioReceiverStartGeneration: UInt64 = 0
    private var p2pRealtimeAudioReceiverPendingPeerId: String?

 /// Metal 设备，作为静态图像兜底（ImageIO -> CGImage -> MTLTexture）
    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

 // MARK: 初始化

    public init() {
        super.init(category: "RemoteControl")

        logger.info("🖥️ RemoteControlManager 初始化")

 // 将渲染器输出绑定到纹理流
        renderer.frameHandler = { [weak self] texture, backing in
            guard let self else { return }
            self.textureFeedDeliveryGate.submit(texture: texture, backing: backing)
        }

        renderingModeController.onModeChanged = { [weak self] _, to, _ in
            guard let self else { return }
            Task { @MainActor in
                self.currentRenderingMode = to
                self.synchronizeRendererResources(for: to)
            }
        }
    }

    private func configureViewingRenderersIfNeeded() {
        guard !viewingRenderersConfigured else { return }
        viewingRenderersConfigured = true

        // 稳定渲染器输出同样绑定到纹理流
        stableRenderer.frameHandler = { [weak self] texture, backing in
            guard let self else { return }
            self.publishRenderedTexture(texture, backing: backing, from: .stable)
        }

        // 高性能渲染器输出绑定到纹理流
        fluidRenderer.frameHandler = { [weak self] texture, backing in
            guard let self else { return }
            self.publishRenderedTexture(texture, backing: backing, from: .fluid)
        }

        // 高保真渲染器输出绑定到纹理流
        referenceRenderer.frameHandler = { [weak self] texture, backing in
            guard let self else { return }
            self.publishRenderedTexture(texture, backing: backing, from: .reference)
        }
    }

    public override func performInitialization() async {
        logger.info("🖥️ RemoteControlManager performInitialization 完成")
    }

    private func currentPeer(
        for role: RemoteControlSessionRole,
        deviceId: String
    ) -> PeerConnection? {
        switch role {
        case .controlling:
            return controllingPeers[deviceId]
        case .beingControlled:
            return beingControlledPeers[deviceId]
        }
    }

    private func registerPeer(_ peer: PeerConnection) {
        switch peer.role {
        case .controlling:
            controllingPeers[peer.id] = peer
        case .beingControlled:
            beingControlledPeers[peer.id] = peer
        }
        registerConnectedDevice(peer.id, for: peer.role)
    }

    @discardableResult
    private func removePeer(
        deviceId: String,
        role: RemoteControlSessionRole
    ) -> PeerConnection? {
        let removedPeer: PeerConnection?
        switch role {
        case .controlling:
            removedPeer = controllingPeers.removeValue(forKey: deviceId)
        case .beingControlled:
            removedPeer = beingControlledPeers.removeValue(forKey: deviceId)
        }
        unregisterConnectedDevice(deviceId, for: role)
        return removedPeer
    }

    private func registerConnectedDevice(_ deviceId: String, for role: RemoteControlSessionRole) {
        switch role {
        case .controlling:
            controllingDeviceIds.insert(deviceId)
        case .beingControlled:
            beingControlledDeviceIds.insert(deviceId)
        }
        refreshPublishedConnectionState()
    }

    private func unregisterConnectedDevice(_ deviceId: String, for role: RemoteControlSessionRole) {
        switch role {
        case .controlling:
            controllingDeviceIds.remove(deviceId)
        case .beingControlled:
            beingControlledDeviceIds.remove(deviceId)
        }
        refreshPublishedConnectionState()
    }

    private func refreshPublishedConnectionState() {
        let activeDeviceIds = controllingDeviceIds.union(beingControlledDeviceIds)
        var mergedDeviceIds = connectedDevices.filter { activeDeviceIds.contains($0) }

        for deviceId in controllingDeviceIds.sorted() where !mergedDeviceIds.contains(deviceId) {
            mergedDeviceIds.append(deviceId)
        }
        for deviceId in beingControlledDeviceIds.sorted() where !mergedDeviceIds.contains(deviceId) {
            mergedDeviceIds.append(deviceId)
        }

        connectedDevices = mergedDeviceIds
        isControlling = !controllingDeviceIds.isEmpty
        isBeingControlled = !beingControlledDeviceIds.isEmpty
    }

    private func finishRoleTeardownIfNeeded(for role: RemoteControlSessionRole) {
        switch role {
        case .controlling:
            guard controllingDeviceIds.isEmpty else { return }
            tearDownViewingRenderPipeline()
        case .beingControlled:
            guard beingControlledDeviceIds.isEmpty else { return }
            clearBeingControlledResources()
        }
    }

    private func clearBeingControlledResources() {
        let clipboard = ClipboardRedirectionManager.shared
        clipboard.onLocalClipboardChanged = nil
        clipboard.disable()
        activeClipboardPeerId = nil

        screenSharingActive = false
        screenCaptureWatchdogTask?.cancel()
        screenCaptureWatchdogTask = nil
        screenCaptureRestartInProgress = false
        captureStreamer?.stop()
        captureStreamer = nil
        realtimeAudioCaptureStreamer?.stop()
        realtimeAudioCaptureStreamer = nil
        realtimeAudioCaptureStrictMediaFallbacks = nil
        endRealtimeStreamingActivity(reason: "being-controlled-resources-cleared")

        screenCaptureStartupRetryCountByPeerId.removeAll()

        interactionTelemetryTasksByPeerId.values.forEach { $0.cancel() }
        interactionTelemetryTasksByPeerId.removeAll()
    }

    private func stopScreenSharingForViewerStop(peer: PeerConnection, reason: String) async {
        logger.info(
            "⏹️ viewer 请求停止 LAN 远控推流: peer=\(peer.id, privacy: .public) reason=\(reason, privacy: .public)"
        )
        screenCaptureWatchdogTask?.cancel()
        screenCaptureWatchdogTask = nil
        screenCaptureRestartInProgress = false
        captureStreamer?.stop()
        captureStreamer = nil
        realtimeAudioCaptureStreamer?.stop()
        realtimeAudioCaptureStreamer = nil
        realtimeAudioCaptureStrictMediaFallbacks = nil
        screenSharingActive = false
        endRealtimeStreamingActivity(reason: "viewer-stop-\(reason)")
        stopInteractionTelemetry(for: peer.id)
        screenCaptureStartupRetryCountByPeerId.removeValue(forKey: peer.id)
        invalidateScreenSharingStartupState(for: peer.id)
        let realtimeAudioSender: RemoteRealtimeMediaAudioSender?
        if #available(macOS 14.0, *) {
            realtimeAudioSender = detachRealtimeAudioSender(from: peer)
        } else {
            realtimeAudioSender = nil
        }
        await peer.outboundFramePump.updateTransportState(
            requestedStreamConfiguration: peer.requestedStreamConfiguration,
            sessionKeys: peer.sessionKeys,
            allowsInsecureLegacy: Self.allowsInsecureLegacyRemoteControl
        )
        if #available(macOS 14.0, *), let realtimeAudioSender {
            await realtimeAudioSender.close(reason: "viewer-stream-stop")
        }
    }

    private func failStrictMediaCapture(
        for peer: PeerConnection,
        reason: String,
        component: String,
        owner: RemoteControlStrictMediaFailureOwner
    ) async {
        switch owner {
        case .screenSharingAttempt(let attemptGeneration):
            guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                logger.info(
                    "ℹ️ 忽略过期屏幕共享 attempt 的严格媒体失败: \(peer.id, privacy: .public)"
                )
                return
            }
        case .realtimeAudioSender(let senderLease):
            guard isCurrentPeer(peer),
                  peer.realtimeAudioSenderOwnership.isCurrent(senderLease) else {
                logger.info(
                    "ℹ️ 忽略过期 realtime audio sender 的严格媒体失败: \(peer.id, privacy: .public)"
                )
                return
            }
        }
        let sanitizedReason = Self.sanitizeTelemetryToken(reason)
        logger.error(
            """
            ⛔️ 严格媒体策略禁止远控采集/编码降级或静默重启: peer=\(peer.id, privacy: .public) \
            component=\(component, privacy: .public) reason=\(reason, privacy: .public)
            """
        )
        RemoteControlSmokeStatusWriter.append(
            "strict-media-failed session=\(peer.id) component=\(component) reason=\(sanitizedReason)"
        )

        screenCaptureWatchdogTask?.cancel()
        screenCaptureWatchdogTask = nil
        screenCaptureRestartInProgress = false
        captureStreamer?.stop()
        captureStreamer = nil
        realtimeAudioCaptureStreamer?.stop()
        realtimeAudioCaptureStreamer = nil
        realtimeAudioCaptureStrictMediaFallbacks = nil
        screenSharingActive = false
        endRealtimeStreamingActivity(reason: "strict-media-\(component)-\(sanitizedReason)")
        invalidateScreenSharingStartupState(for: peer.id)

        guard let retiredResources = retireConnectionClosedResources(
            peer: peer,
            error: RemoteControlError.screenCaptureFailed
        ) else {
            return
        }
        await closeRetiredConnectionResources(retiredResources)
    }

    private func resolvedPreferredRenderingMode() -> RenderingMode {
        switch preferredRenderingMode {
        case .stable:
            return .stable
        case .fluid:
            return MTLCreateSystemDefaultDevice() == nil ? .stable : .fluid
        case .reference:
            let report = HardwareCapabilityProbe.probe(requireExternalPower: true)
            if report.isReferenceCapable {
                return .reference
            }
            return MTLCreateSystemDefaultDevice() == nil ? .stable : .fluid
        }
    }

    private func prepareViewingRenderPipelineForNewStream() {
        // 应用用户在设置中选择的首选渲染层级（Stable/Fluid/Reference）。
        // RemoteControlManager 不是单例，因此从共享设置读取，保证所有实例都遵循同一选择；
        // resolvedPreferredRenderingMode() 会按硬件能力把不可达的层级单向降级。
        preferredRenderingMode = RemoteDesktopSettingsManager.shared.settings.displaySettings.renderingMode
        if #available(macOS 14.0, *) {
            stopP2PRealtimeAudioReceiverIfNeeded(peerId: nil)
        }
        AudioRedirectionManager.shared.disable()
        configureViewingRenderersIfNeeded()
        stableRenderer.teardown()
        fluidRenderer.teardown()
        referenceRenderer.teardown()
        textureFeedDeliveryGate.clear()
        renderingModeController.resetForNewStream()
        let requestedMode = resolvedPreferredRenderingMode()
        currentRenderingMode = renderingModeController.requestMode(requestedMode)
    }

    private func tearDownViewingRenderPipeline() {
        AudioRedirectionManager.shared.disable()
        lastViewingInboundScreenTimestamp = nil
        if viewingRenderersConfigured {
            stableRenderer.teardown()
            fluidRenderer.teardown()
            referenceRenderer.teardown()
        }
        textureFeedDeliveryGate.clear()
        renderingModeController.resetForNewStream()
        currentRenderingMode = .stable
    }

    private func applyPreferredRenderingModeToActiveViewingSession() {
        guard !controllingDeviceIds.isEmpty else { return }
        currentRenderingMode = renderingModeController.requestMode(resolvedPreferredRenderingMode())
    }

    private func publishRenderedTexture(
        _ texture: MTLTexture,
        backing: AnyObject?,
        from mode: RenderingMode
    ) {
        guard renderingModeController.currentMode == mode else { return }
        textureFeedDeliveryGate.submit(texture: texture, backing: backing)
        if renderingModeController.isProbationActive {
            renderingModeController.reportProbationFrameSuccess()
        }
    }

    private func synchronizeRendererResources(for activeMode: RenderingMode) {
        guard viewingRenderersConfigured else { return }
        switch activeMode {
        case .stable:
            fluidRenderer.teardown()
            referenceRenderer.teardown()
        case .fluid:
            stableRenderer.teardown()
            referenceRenderer.teardown()
        case .reference:
            stableRenderer.teardown()
            fluidRenderer.teardown()
        }
    }

    private func evaluateHighPerformanceRenderHealth(afterPullFor mode: RenderingMode, rendered: Bool) {
        guard renderingModeController.currentMode == mode else { return }
        guard !rendered else { return }
        guard renderingModeController.isProbationActive else { return }
        if renderingModeController.healthMonitor.isFrozen {
            renderingModeController.reportProbationFrameFailure()
        }
    }

 // MARK: - 公共控制接口

 /// 作为「控制端」连接一个远程设备
 /// - 注意：NWConnection 必须在外部已 start(queue:)，这里不再重复 start
    public func startControlling(deviceId: String, connection: NWConnection) async {
        await startControlling(
            deviceId: deviceId,
            connection: connection,
            remoteVideoFormats: []
        )
    }

    public func startControlling(device: DiscoveredDevice, connection: NWConnection) async {
        await startControlling(
            deviceId: Self.controlPeerIdentifier(for: device),
            connection: connection,
            remoteVideoFormats: device.remoteVideoFormats
        )
    }

    public static func controlPeerIdentifier(for device: DiscoveredDevice) -> String {
        if let deviceId = device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !deviceId.isEmpty {
            return deviceId
        }
        if let uniqueIdentifier = device.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !uniqueIdentifier.isEmpty {
            if #available(macOS 14.0, *) {
                return PeerTrustLookup.persistentDeviceId(from: uniqueIdentifier) ?? uniqueIdentifier
            }
            return uniqueIdentifier
        }
        return device.id.uuidString
    }

    private func startControlling(
        deviceId: String,
        connection: NWConnection,
        remoteVideoFormats: Set<String>
    ) async {
        // The viewing renderer, input focus, and realtime-audio sink are
        // manager-global. Make that product invariant explicit: a new target
        // supersedes the previous controlling session rather than silently
        // stealing only its audio endpoint.
        for existingDeviceId in Array(controllingPeers.keys) where existingDeviceId != deviceId {
            stopControlling(deviceId: existingDeviceId)
        }
        logger.info("🎮 开始控制远程设备: \(deviceId, privacy: .public)")
        if !remoteVideoFormats.isEmpty {
            logger.info(
                "🎥 对端声明可接收视频格式: \(remoteVideoFormats.sorted().joined(separator: ","), privacy: .public)"
            )
        }

        let peer = PeerConnection(
            id: deviceId,
            role: .controlling,
            connection: connection,
            remoteVideoFormats: remoteVideoFormats
        )
        replacePeerSessionIfNeeded(with: peer, resetCapturePipeline: false)
        prepareViewingRenderPipelineForNewStream()

        if #available(macOS 14.0, *) {
            peer.handshakePeer = PeerIdentifier(deviceId: deviceId, displayName: nil, address: nil)
        }

 // 启动屏幕数据接收循环
        startReceivingScreenData(from: peer)

        if #available(macOS 14.0, *), peer.handshakePeer != nil {
            guard await establishOutboundSecureChannel(for: peer) else {
                return
            }
        }

        beginRemoteControlTerminalNotificationTracking(for: peer)
        await sendViewerStreamConfigurationIfPossible(to: peer)
    }

 /// 停止控制指定设备
    public func stopControlling(deviceId: String) {
        logger.info("⏹️ 停止控制远程设备: \(deviceId, privacy: .public)")
        guard let peer = currentPeer(for: .controlling, deviceId: deviceId) else {
            _ = removePeer(deviceId: deviceId, role: .controlling)
            finishRoleTeardownIfNeeded(for: .controlling)
            return
        }

        notifyRemoteControlTerminalSessionIfNeeded(
            peer: peer,
            kind: .normal,
            reason: "p2p_user_stop"
        )
        peer.connection.cancel()
        _ = removePeer(deviceId: deviceId, role: .controlling)
        if #available(macOS 14.0, *) {
            releaseSOAState(for: peer)
        }
        lastSentViewerStreamConfiguration = nil
        stopP2PRealtimeAudioReceiverIfNeeded(peerId: deviceId)
        Task {
            await peer.outboundFramePump.close()
        }
        finishRoleTeardownIfNeeded(for: .controlling)
    }

 /// 作为「被控制端」开放远程控制
    public func allowRemoteControl(
        from deviceId: String,
        connection: NWConnection,
        initialData: Data? = nil
    ) async {
        logger.info("🖥️ 允许远程控制来自设备: \(deviceId, privacy: .public)")

        let peer = PeerConnection(id: deviceId, role: .beingControlled, connection: connection)
        replacePeerSessionIfNeeded(with: peer, resetCapturePipeline: true)

        if #available(macOS 14.0, *) {
            peer.handshakePeer = PeerIdentifier(deviceId: deviceId, displayName: nil, address: nil)
            logger.info("🔐 RemoteControl P2P handshake armed for \(deviceId, privacy: .public); waiting for MessageA")
        }

        // 1) 先开始接收对端发来的输入事件 / 流配置
        startReceivingRemoteEvents(from: peer, initialData: initialData)
        if #available(macOS 14.0, *), peer.handshakePeer != nil {
            logger.info("🔐 RemoteControl waiting for secure channel: peer=\(peer.id, privacy: .public)")
            switch await waitForSecureChannelIfNeeded(for: peer) {
            case .established:
                break
            case .aborted(let reason):
                logger.warning("⚠️ RemoteControl secure channel aborted for \(peer.id, privacy: .public): \(reason, privacy: .public)")
                await handleConnectionClosed(
                    peer: peer,
                    error: RemoteControlError.handshakeInitializationFailed(reason)
                )
                return
            case .timedOut:
                logger.warning("⚠️ RemoteControl secure channel was not established in time for \(peer.id, privacy: .public)")
                await handleConnectionClosed(
                    peer: peer,
                    error: RemoteControlError.handshakeInitializationFailed("secure channel timeout")
                )
                return
            }
        }

        guard await requestRemoteControlSecurityApproval(for: peer) else {
            await handleConnectionClosed(peer: peer, error: RemoteControlError.permissionDenied)
            return
        }

        beginRemoteControlTerminalNotificationTracking(for: peer)
        let hasInitialStreamConfiguration = await waitForInitialStreamConfigurationIfAvailable(for: peer)
        guard isCurrentPeer(peer), isBeingControlled else { return }
        if peer.requestedStreamConfiguration?.isStopRequest == true {
            logger.info("⏸️ viewer 初始配置要求停止推流，保持被控会话待机: peer=\(peer.id, privacy: .public)")
            return
        }

        switch RemoteControlScreenSharingStartupPolicy.decision(
            hasInitialStreamConfiguration: hasInitialStreamConfiguration
        ) {
        case .startImmediately:
            if screenSharingActive || captureStreamer != nil {
                logger.info(
                    "ℹ️ viewer 配置已先行启动推流，跳过 secure-channel 后的重复启动: peer=\(peer.id, privacy: .public)"
                )
            } else {
                await startScreenSharing(to: peer)
            }
        case .awaitViewerConfiguration:
            logger.info(
                "📺 viewer 首个流配置尚未就绪，保持待机并继续等待已认证配置: peer=\(peer.id, privacy: .public)"
            )
        }
    }

 /// 作为被控制端，关闭来自某设备的远程控制
    public func stopRemoteControl(from deviceId: String) {
        logger.info("⏹️ 停止被远程控制来自设备: \(deviceId, privacy: .public)")
        guard let peer = currentPeer(for: .beingControlled, deviceId: deviceId) else {
            RemoteControlSecurityNoticeCenter.shared.endNotice(
                sessionId: deviceId,
                transportKind: .p2p
            )
            _ = removePeer(deviceId: deviceId, role: .beingControlled)
            finishRoleTeardownIfNeeded(for: .beingControlled)
            return
        }

        notifyRemoteControlTerminalSessionIfNeeded(
            peer: peer,
            kind: .normal,
            reason: "p2p_user_stop"
        )
        RemoteControlSecurityNoticeCenter.shared.endNotice(
            sessionId: peer.id,
            transportKind: .p2p
        )

        if activeClipboardPeerId == deviceId {
            let clipboard = ClipboardRedirectionManager.shared
            clipboard.onLocalClipboardChanged = nil
            clipboard.disable()
            activeClipboardPeerId = nil
        }

        peer.connection.cancel()
        _ = removePeer(deviceId: deviceId, role: .beingControlled)
        if #available(macOS 14.0, *) {
            releaseSOAState(for: peer)
        }
        Task {
            await peer.outboundFramePump.close()
        }
        if #available(macOS 14.0, *),
           let sender = detachRealtimeAudioSender(from: peer) {
            Task { await sender.close(reason: "remote-control-stopped") }
        }
        stopInteractionTelemetry(for: deviceId)
        screenCaptureStartupRetryCountByPeerId.removeValue(forKey: deviceId)
        invalidateScreenSharingStartupState(for: deviceId)

        finishRoleTeardownIfNeeded(for: .beingControlled)
    }

    private func isCurrentPeer(_ peer: PeerConnection) -> Bool {
        guard let current = currentPeer(for: peer.role, deviceId: peer.id) else { return false }
        return current === peer
    }

    private func replacePeerSessionIfNeeded(
        with peer: PeerConnection,
        resetCapturePipeline: Bool
    ) {
        let previousPeer = currentPeer(for: peer.role, deviceId: peer.id)
        registerPeer(peer)

        guard let previousPeer, previousPeer !== peer else { return }

        if previousPeer.role == .controlling {
            stopP2PRealtimeAudioReceiverIfNeeded(peerId: previousPeer.id)
        }

        logger.warning(
            "🔁 RemoteControl superseding existing session for \(peer.id, privacy: .public)"
        )

        notifyRemoteControlTerminalSessionIfNeeded(
            peer: previousPeer,
            kind: .normal,
            reason: "p2p_superseded_by_new_session"
        )
        if previousPeer.role == .beingControlled {
            RemoteControlSecurityNoticeCenter.shared.endNotice(
                sessionId: previousPeer.id,
                transportKind: .p2p
            )
        }

        if activeClipboardPeerId == previousPeer.id {
            let clipboard = ClipboardRedirectionManager.shared
            clipboard.onLocalClipboardChanged = nil
            clipboard.disable()
            activeClipboardPeerId = nil
        }

        stopInteractionTelemetry(for: previousPeer.id)
        Task {
            await previousPeer.outboundFramePump.close()
        }
        if #available(macOS 14.0, *),
           let sender = detachRealtimeAudioSender(from: previousPeer) {
            Task { await sender.close(reason: "session-superseded") }
        }
        if #available(macOS 14.0, *) {
            releaseSOAState(for: previousPeer)
        }

        if resetCapturePipeline {
            screenCaptureWatchdogTask?.cancel()
            screenCaptureWatchdogTask = nil
            screenCaptureRestartInProgress = false
            captureStreamer?.stop()
            captureStreamer = nil
            realtimeAudioCaptureStreamer?.stop()
            realtimeAudioCaptureStreamer = nil
            realtimeAudioCaptureStrictMediaFallbacks = nil
            screenSharingActive = false
            screenCaptureStartupRetryCountByPeerId.removeValue(forKey: previousPeer.id)
            invalidateScreenSharingStartupState(for: previousPeer.id)
        } else {
            tearDownViewingRenderPipeline()
        }

        previousPeer.connection.cancel()
    }

    @available(macOS 14.0, *)
    private func recordSOAState(_ pairKey: Data, for peer: PeerConnection) {
        peer.soaPairKey = pairKey
    }

    @available(macOS 14.0, *)
    private func releaseStaleSOAStateBeforeHandshake(for peer: PeerConnection) async throws {
        if let staleDriver = peer.handshakeDriver {
            peer.handshakeDriver = nil
            switch await staleDriver.getCurrentState() {
            case .idle, .established, .failed:
                break
            default:
                await staleDriver.cancel()
            }
        }
        if let staleLease = peer.soaEstablishedLease {
            guard await PeerSessionArbiter.shared.clearEstablished(staleLease) else {
                logger.error(
                    "⛔️ RemoteControl could not release its exact stale SOA lease for \(peer.id, privacy: .public)"
                )
                throw RemoteControlError.handshakeInitializationFailed(
                    "could not release exact stale remote-control SOA lease"
                )
            }
            peer.soaEstablishedLease = nil
        }
    }

    @available(macOS 14.0, *)
    private func releaseSOAState(for peer: PeerConnection) {
        let driverToCancel = peer.handshakeDriver
        let establishedLease = peer.soaEstablishedLease
        guard peer.soaPairKey != nil || driverToCancel != nil || establishedLease != nil else {
            return
        }
        peer.soaPairKey = nil
        peer.handshakeDriver = nil
        peer.soaEstablishedLease = nil
        Task {
            if let driverToCancel {
                switch await driverToCancel.getCurrentState() {
                case .idle, .established, .failed:
                    break
                default:
                    await driverToCancel.cancel()
                }
            }
            if let establishedLease {
                _ = await PeerSessionArbiter.shared.clearEstablished(establishedLease)
            }
        }
    }

 // MARK: - 输入事件发送（控制端 -> 被控制端）

    public func sendMouseEvent(_ event: RemoteMouseEvent, to deviceId: String) async throws {
        guard let peer = currentPeer(for: .controlling, deviceId: deviceId) else {
            throw RemoteControlError.deviceNotConnected
        }
        try ensureSecureChannelEstablished(for: peer)
        let doubleClickInterval = RemoteDesktopSettingsManager.shared.settings
            .interactionSettings
            .boundedDoubleClickIntervalMilliseconds
        let classifiedEvent = outboundMouseClickClassifier.classify(
            event,
            peerKey: deviceId,
            doubleClickIntervalMilliseconds: doubleClickInterval
        )
        try await peer.outboundFramePump.sendControlPayload(classifiedEvent, type: .mouseEvent)
        logger.debug(
            "🖱️ 发送鼠标事件 \(classifiedEvent.type.rawValue, privacy: .public) clickCount=\(classifiedEvent.clickCount ?? 1, privacy: .public) -> \(deviceId, privacy: .public)"
        )
    }

    public func sendKeyboardEvent(_ event: RemoteKeyboardEvent, to deviceId: String) async throws {
        guard let peer = currentPeer(for: .controlling, deviceId: deviceId) else {
            throw RemoteControlError.deviceNotConnected
        }
        try ensureSecureChannelEstablished(for: peer)
        try await peer.outboundFramePump.sendControlPayload(event, type: .keyboardEvent)
        logger.debug("⌨️ 发送键盘事件 keyCode=\(event.keyCode) -> \(deviceId, privacy: .public)")
    }

 // MARK: - 屏幕共享（被控制端 -> 控制端）

    @available(macOS 14.0, *)
    private func makeP2PRealtimeAudioSenderIfNeeded(
        for peer: PeerConnection
    ) async throws -> RemoteRealtimeMediaAudioSender? {
        guard let config = peer.requestedStreamConfiguration,
              config.requestsRealtimeMediaAudio,
              config.allowsLegacyAudioChunkFallback == false else {
            return nil
        }
        guard let keys = peer.sessionKeys else {
            throw RemoteControlRealtimeMediaStartupError
                .missingAuthenticatedMediaSessionKeys
        }
        guard let advertisedEndpoint = config.mediaAudioEndpoint else {
            throw RemoteControlRealtimeMediaStartupError
                .missingAuthenticatedMediaAudioEndpoint
        }
        let interfaceBinding = try SkyBridgeRealtimeMediaInterfaceBinding
            .resolveAuthenticatedControlPath(
                connection: peer.connection,
                advertisedHost: advertisedEndpoint.host,
                authenticatedSessionEstablished: peer.securityAdmissionApproved
            )
        let endpoint = SkyBridgeMediaEndpoint(
            host: interfaceBinding.authenticatedRemoteHost,
            port: advertisedEndpoint.port,
            relayToken: advertisedEndpoint.relayToken,
            expiresAt: advertisedEndpoint.expiresAt
        )
        let mediaSessionId = config.mediaSessionId ?? keys.sessionId
        var senderToClose: RemoteRealtimeMediaAudioSender?
        if let existingSender = peer.realtimeAudioSender {
            let matchesExistingSender = await existingSender.matches(
                sessionId: mediaSessionId,
                endpoint: endpoint,
                mode: config.requestedMediaAudioMode,
                interfaceBindingIdentity: interfaceBinding.identity
            )
            guard isCurrentPeer(peer),
                  peer.realtimeAudioSender === existingSender else {
                throw CancellationError()
            }
            if matchesExistingSender,
               let existingLease = peer.realtimeAudioSenderOwnership.currentLease,
               peer.realtimeAudioSenderOwnership.isCurrent(existingLease) {
                logger.info(
                    "🎧 P2P PQC media audio sender reused across video refresh: peer=\(peer.id, privacy: .public) interfaceBound=true"
                )
                return existingSender
            }
            guard let detachedSender = detachRealtimeAudioSender(
                from: peer,
                ifOwnedBy: existingSender
            ) else {
                throw CancellationError()
            }
            senderToClose = detachedSender
        }

        // Reserve and publish the pending lease before the first suspension.
        // Teardown can therefore invalidate an in-flight sender start even
        // though the concrete sender has not been installed yet.
        let senderLease = peer.realtimeAudioSenderOwnership.reserve()
        if let senderToClose {
            await senderToClose.close(reason: "stream-config-endpoint-or-mode-changed")
            guard isCurrentPeer(peer),
                  peer.realtimeAudioSenderOwnership.isCurrent(senderLease) else {
                throw CancellationError()
            }
        }

        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: keys.sendKey,
            receiveSecret: keys.receiveKey,
            sessionId: mediaSessionId,
            transcriptHash: keys.transcriptHash,
            localRole: keys.role == .initiator ? .initiator : .responder
        )
        let terminalPeerId = peer.id
        let terminalPeerRole = peer.role
        let terminalPeerIdentity = ObjectIdentifier(peer)
        let sender = try RemoteRealtimeMediaAudioSender(
            sessionId: mediaSessionId,
            endpoint: endpoint,
            keys: keyMaterial.send,
            mode: config.requestedMediaAudioMode,
            interfaceBinding: interfaceBinding,
            transportTerminalFailureHandler: { [weak self, terminalPeerId, terminalPeerRole, terminalPeerIdentity, senderLease] error in
                Task { @MainActor [weak self] in
                    guard let self,
                          let peer = self.currentPeer(
                            for: terminalPeerRole,
                            deviceId: terminalPeerId
                          ),
                          ObjectIdentifier(peer) == terminalPeerIdentity,
                          peer.realtimeAudioSenderOwnership.isCurrent(senderLease) else {
                        return
                    }
                    await self.failStrictMediaCapture(
                        for: peer,
                        reason: Self.realtimeAudioStartupFailureReason(error),
                        component: "audio-transport-runtime",
                        owner: .realtimeAudioSender(senderLease)
                    )
                }
            }
        )
        do {
            try await sender.start()
        } catch {
            if peer.realtimeAudioSenderOwnership.isCurrent(senderLease) {
                peer.realtimeAudioSenderOwnership.invalidate()
            }
            await sender.close(reason: "sender-start-failed")
            throw error
        }
        guard isCurrentPeer(peer),
              peer.realtimeAudioSenderOwnership.isCurrent(senderLease) else {
            await sender.close(reason: "stale-sender-start")
            throw CancellationError()
        }
        peer.realtimeAudioSender = sender
        RemoteControlSmokeStatusWriter.append(
            "audio-route-binding-derived session=\(peer.id) source=authenticated-control-path interfaceBound=1 interfaceClass=infrastructure scopeMatch=1"
        )
        return sender
    }

    @available(macOS 14.0, *)
    private func detachRealtimeAudioSender(
        from peer: PeerConnection,
        ifOwnedBy expectedSender: RemoteRealtimeMediaAudioSender? = nil
    ) -> RemoteRealtimeMediaAudioSender? {
        let sender = peer.realtimeAudioSender
        if let expectedSender {
            guard let sender, sender === expectedSender else {
                return nil
            }
        }
        peer.realtimeAudioSender = nil
        peer.realtimeAudioSenderOwnership.invalidate()
        return sender
    }

    private static func remoteHost(from endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        return "\(host)"
    }

    private func remoteControlSecurityIdentityAliases(for peer: PeerConnection) -> [String] {
        var aliases: [String] = [
            peer.id,
            Self.remoteHost(from: peer.connection.endpoint),
            peer.connection.currentPath?.remoteEndpoint.flatMap(Self.remoteHost(from:))
        ].compactMap { $0 }

        if #available(macOS 14.0, *), let handshakePeer = peer.handshakePeer {
            aliases.append(contentsOf: [
                handshakePeer.deviceId,
                handshakePeer.displayName,
                handshakePeer.address
            ].compactMap { $0 })
        }

        var deduped: [String] = []
        var seen = Set<String>()
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            deduped.append(trimmed)
        }
        return deduped
    }

    private func recordRemoteControlSecurityIdentity(
        _ identity: RemoteControlSecurityIdentity?,
        from source: String,
        for peer: PeerConnection
    ) {
        guard let identity, !identity.isEmpty else { return }

        let aliases = remoteControlSecurityIdentityAliases(for: peer)
            + [identity.deviceId, identity.deviceName].compactMap { $0 }
        RemoteControlSecurityPeerIdentityStore.record(identity: identity, aliases: aliases)
        RemoteControlSmokeStatusWriter.append(
            """
            remoteControlSecurityIdentityRecorded session=\(peer.id) source=\(source) \
            account=\(Self.noticeMetadataPresent(identity.accountDisplayName) ? "present" : "missing") \
            nebula=\(Self.noticeMetadataPresent(identity.nebulaId) ? "present" : "missing") \
            device=\(Self.noticeMetadataPresent(identity.deviceId) || Self.noticeMetadataPresent(identity.deviceName) ? "present" : "missing")
            """
        )
    }

    private func waitForRemoteControlSecurityIdentityMetadata(
        for peer: PeerConnection,
        aliases: [String],
        timeout: Duration = .seconds(2)
    ) async -> RemoteControlSecurityIdentity? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var identity = RemoteControlSecurityPeerIdentityStore.identity(forAliases: aliases)

        while clock.now < deadline {
            guard isCurrentPeer(peer) else { return nil }
            if Self.noticeMetadataPresent(identity?.accountDisplayName),
               Self.noticeMetadataPresent(identity?.nebulaId) {
                return identity
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return nil
            }
            identity = RemoteControlSecurityPeerIdentityStore.identity(forAliases: aliases)
        }

        return identity
    }

    private static func noticeMetadataPresent(_ value: String?) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !trimmed.isEmpty && trimmed != "missing" && trimmed != "-"
    }

    private func hasUserVisibleRemoteControlSession(_ peer: PeerConnection) -> Bool {
        if peer.securityAdmissionApproved {
            return true
        }
        if #available(macOS 14.0, *), peer.sessionKeys != nil {
            return true
        }
        return false
    }

    private func remoteControlNotificationDeviceName(for peer: PeerConnection) -> String? {
        if let identity = RemoteControlSecurityPeerIdentityStore.identity(
            forAliases: remoteControlSecurityIdentityAliases(for: peer)
        ) {
            if Self.noticeMetadataPresent(identity.deviceName) {
                return identity.deviceName
            }
            if Self.noticeMetadataPresent(identity.deviceId) {
                return identity.deviceId
            }
        }

        if #available(macOS 14.0, *), let handshakePeer = peer.handshakePeer {
            if Self.noticeMetadataPresent(handshakePeer.displayName) {
                return handshakePeer.displayName
            }
            if Self.noticeMetadataPresent(handshakePeer.deviceId) {
                return handshakePeer.deviceId
            }
        }

        return Self.noticeMetadataPresent(peer.id) ? peer.id : nil
    }

    private func beginRemoteControlTerminalNotificationTracking(for peer: PeerConnection) {
        RemoteDesktopSessionNotificationService.shared.beginSession(
            sessionID: peer.id,
            transport: "p2p",
            role: peer.role.rawValue
        )
    }

    private func notifyRemoteControlTerminalSessionIfNeeded(
        peer: PeerConnection,
        kind: RemoteDesktopSessionTerminationKind,
        reason: String
    ) {
        guard hasUserVisibleRemoteControlSession(peer) else { return }
        RemoteDesktopSessionNotificationService.shared.sendTerminalNotificationIfNeeded(
            sessionID: peer.id,
            deviceName: remoteControlNotificationDeviceName(for: peer),
            transport: "p2p",
            role: peer.role.rawValue,
            kind: kind,
            reason: reason
        )
    }

    private func requestRemoteControlSecurityApproval(for peer: PeerConnection) async -> Bool {
        guard isCurrentPeer(peer) else { return false }

        let noticeCenter = RemoteControlSecurityNoticeCenter.shared
        let localIdentity = noticeCenter.localIdentitySnapshot()
        let remoteIdentity = await waitForRemoteControlSecurityIdentityMetadata(
            for: peer,
            aliases: remoteControlSecurityIdentityAliases(for: peer)
        )
        let handshakePeer: PeerIdentifier? = {
            if #available(macOS 14.0, *) {
                return peer.handshakePeer
            }
            return nil
        }()
        let cryptoSuite = remoteControlSecurityCryptoSuite(for: peer)
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: peer.id,
            sessionEvidenceReference: peer.sessionKeys.flatMap {
                P2PEvidenceReference.sessionIncarnation(
                    sessionID: $0.sessionId,
                    transcriptHash: $0.transcriptHash
                )
            },
            transportKind: .p2p,
            remoteIPAddress: Self.remoteHost(from: peer.connection.endpoint),
            remoteDeviceId: remoteIdentity?.deviceId ?? handshakePeer?.deviceId ?? peer.id,
            remoteDeviceName: remoteIdentity?.deviceName ?? handshakePeer?.displayName,
            remoteAccountDisplayName: remoteIdentity?.accountDisplayName,
            remoteNebulaId: remoteIdentity?.nebulaId,
            localAccountDisplayName: localIdentity?.accountDisplayName,
            localNebulaId: localIdentity?.nebulaId,
            cryptoSuite: cryptoSuite ?? ""
        )
        peer.securityNoticeId = descriptor.id
        let peerId = peer.id
        noticeCenter.setDisconnectHandler(for: descriptor.id) { [weak self] in
            self?.stopRemoteControl(from: peerId)
        }

        let decision = await noticeCenter.requestApproval(descriptor)
        guard decision == .approved, isCurrentPeer(peer) else {
            peer.securityAdmissionApproved = false
            return false
        }
        peer.securityAdmissionApproved = true
        if let pendingConfiguration = peer.pendingRequestedStreamConfiguration {
            peer.pendingRequestedStreamConfiguration = nil
            do {
                try await applyViewerStreamConfiguration(pendingConfiguration, for: peer)
            } catch {
                peer.securityAdmissionApproved = false
                logger.error(
                    "⛔️ 已批准会话的暂存流配置事务无效: peer=\(peer.id, privacy: .public)"
                )
                return false
            }
        }
        return true
    }

    private func remoteControlSecurityCryptoSuite(for peer: PeerConnection) -> String? {
        if #available(macOS 14.0, *), let keys = peer.sessionKeys {
            guard keys.negotiatedSuite.isKnown else { return nil }
            let rawValue = keys.negotiatedSuite.rawValue
            return keys.negotiatedSuite.isPQCGroup ? "\(rawValue) PQC" : "\(rawValue) secure channel"
        }
        return nil
    }

 /// 启动本机屏幕捕获 + 硬件编码 + 推流
    private func startScreenSharing(to peer: PeerConnection) async {
        guard isCurrentPeer(peer) else {
            logger.info("ℹ️ 忽略过期远控会话的推流启动: \(peer.id, privacy: .public)")
            return
        }
        guard peer.role != .beingControlled || peer.securityAdmissionApproved else {
            logger.warning("⛔️ 未经批准的远控推流启动被阻断: peer=\(peer.id, privacy: .public)")
            RemoteControlSmokeStatusWriter.append(
                "remoteControlStartBlocked session=\(peer.id) transport=p2p reason=awaiting_security_notice"
            )
            return
        }
        guard let acknowledgedConfiguration = peer.requestedStreamConfiguration else {
            logger.info("⏳ 忽略尚无已确认 viewer 配置的推流启动: peer=\(peer.id, privacy: .public)")
            return
        }
        if acknowledgedConfiguration.isStopRequest {
            logger.info("⏸️ 忽略 viewer 已停止会话的推流启动: peer=\(peer.id, privacy: .public)")
            return
        }
        guard let attemptGeneration = screenSharingAttemptGate.beginAttemptIfIdle(for: peer.id) else {
            logger.info(
                "ℹ️ 忽略重复的远控推流启动：peer=\(peer.id, privacy: .public) reason=start-already-in-progress"
            )
            return
        }
        defer {
            let shouldRestartLatest = screenSharingAttemptGate.finishAttempt(
                attemptGeneration,
                for: peer.id
            )
            if shouldRestartLatest {
                Task { @MainActor [weak self, weak peer] in
                    guard let self, let peer,
                          self.isCurrentPeer(peer),
                          peer.requestedStreamConfiguration?.isStopRequest != true else {
                        return
                    }
                    await self.startScreenSharing(to: peer)
                }
            }
        }
        logger.info("📺 开始屏幕共享（ScreenCaptureKit + 硬件编码） -> \(peer.id, privacy: .public)")

        if !(await ensureScreenCapturePermission()) {
            logger.warning(
                "⚠️ 屏幕录制权限预检未通过；若你刚授权，请先完整退出并重新打开 App。仍将继续尝试启动采集。"
            )
        }
        guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
            logger.info("ℹ️ 推流启动在权限预检后已过期，取消: peer=\(peer.id, privacy: .public)")
            return
        }

        screenCaptureWatchdogTask?.cancel()
        screenCaptureWatchdogTask = nil
        captureStreamer?.stop()
        captureStreamer = nil
        screenSharingActive = false

        let streamer = ScreenCaptureKitStreamer()
        let request = effectiveStreamRequest(for: peer)
        let streamConfiguration = peer.requestedStreamConfiguration
        let strictMediaFallbacks = streamConfiguration?.allowsDegradedMediaFallbacks == false
            || streamConfiguration?.requiresExtremePerformanceValidation == true
        let audioRedirectionEnabled = streamConfiguration?.audioRedirectionEnabled == true
        let realtimeMediaAudioRequested = streamConfiguration?.requestsRealtimeMediaAudio == true
        let legacyAudioFallbackEnabled = streamConfiguration?.allowsLegacyAudioChunkFallback == true
        let existingRealtimeAudioSender: RemoteRealtimeMediaAudioSender?
        if #available(macOS 14.0, *) {
            existingRealtimeAudioSender = peer.realtimeAudioSender
        } else {
            existingRealtimeAudioSender = nil
        }
        let realtimeAudioSender: RemoteRealtimeMediaAudioSender?
        if #available(macOS 14.0, *) {
            do {
                realtimeAudioSender = try await makeP2PRealtimeAudioSenderIfNeeded(for: peer)
            } catch {
                guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                    logger.info(
                        "ℹ️ 忽略过期屏幕共享 attempt 的 audio sender 启动结果: peer=\(peer.id, privacy: .public)"
                    )
                    return
                }
                let reason = Self.realtimeAudioStartupFailureReason(error)
                let failureAction = RemoteControlRealtimeMediaStartupPolicy
                    .failureAction(
                        strictMediaFallbacks: strictMediaFallbacks,
                        audioRedirectionEnabled: audioRedirectionEnabled,
                        realtimeMediaAudioRequested: realtimeMediaAudioRequested,
                        legacyAudioFallbackEnabled: legacyAudioFallbackEnabled
                    )
                let strictAudioRequired = failureAction == .failSession
                RemoteControlSmokeStatusWriter.append(
                    "audioTxSenderStartFailed session=\(peer.id) reason=\(reason) strict=\(strictAudioRequired ? 1 : 0) action=\(strictAudioRequired ? "strict-fail-closed" : "video-preserved")"
                )
                if failureAction == .failSession {
                    await failStrictMediaCapture(
                        for: peer,
                        reason: "audio-sender-start-\(reason)",
                        component: "audio",
                        owner: .screenSharingAttempt(attemptGeneration)
                    )
                    return
                }
                logger.warning(
                    "⚠️ P2P PQC media audio sender unavailable; explicit non-strict video-only policy applied: peer=\(peer.id, privacy: .public) reason=\(reason, privacy: .public)"
                )
                realtimeAudioSender = nil
            }
        } else {
            realtimeAudioSender = nil
        }
        guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
            if let realtimeAudioSender,
               let detachedSender = detachRealtimeAudioSender(
                from: peer,
                ifOwnedBy: realtimeAudioSender
               ) {
                await detachedSender.close(reason: "stale-screen-sharing-audio-sender-start")
            }
            logger.info(
                "ℹ️ 推流启动在 audio sender 准备后已过期，取消: peer=\(peer.id, privacy: .public)"
            )
            return
        }
        let didReuseRealtimeAudioSender = existingRealtimeAudioSender != nil
            && realtimeAudioSender != nil
            && existingRealtimeAudioSender === realtimeAudioSender
        let shouldPreserveRealtimeAudioCaptureStreamer = didReuseRealtimeAudioSender
            && realtimeAudioCaptureStrictMediaFallbacks == strictMediaFallbacks
        let preservedRealtimeAudioCaptureStreamer = shouldPreserveRealtimeAudioCaptureStreamer
            ? realtimeAudioCaptureStreamer
            : nil
        if !shouldPreserveRealtimeAudioCaptureStreamer {
            realtimeAudioCaptureStreamer?.stop()
            realtimeAudioCaptureStreamer = nil
            realtimeAudioCaptureStrictMediaFallbacks = nil
        }
        let preferredAudioEncoding = RemoteDesktopAudioChunkPayload.Encoding(
            rawValue: peer.requestedStreamConfiguration?.preferredAudioEncoding ?? ""
        ) ?? .pcmS16LE
        let activeAudioPath: String
        if realtimeAudioSender != nil {
            activeAudioPath = "pqc-opus"
        } else if legacyAudioFallbackEnabled {
            activeAudioPath = "legacy-\(preferredAudioEncoding.rawValue)"
        } else if audioRedirectionEnabled {
            activeAudioPath = "requested-no-media-endpoint"
        } else {
            activeAudioPath = "disabled"
        }
        var policy = RemoteControlStreamPolicySelector.select(
            request: request,
            peerFormats: effectiveRemoteVideoFormats(for: peer),
            thermalState: ProcessInfo.processInfo.thermalState,
            isAppleSilicon: RemoteControlStreamRequestPolicy.isAppleSiliconRuntime
        )
        policy = effectiveCapturePolicy(policy, for: peer)
        if legacyAudioFallbackEnabled {
            policy = policy.protectingRealtimeAudio()
        }
        streamer.onCaptureIssue = { [weak self, weak peer, strictMediaFallbacks, attemptGeneration] reason in
            guard let self, let peer else { return }
            Task { @MainActor [weak self, weak peer] in
                guard let self, let peer,
                      self.isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                    return
                }
                if strictMediaFallbacks,
                   reason.hasPrefix("strict-") || self.captureEncodeStatus(from: reason) != nil {
                    await self.failStrictMediaCapture(
                        for: peer,
                        reason: reason,
                        component: "video",
                        owner: .screenSharingAttempt(attemptGeneration)
                    )
                    return
                }
                if !strictMediaFallbacks {
                    self.applyCaptureCompatibilityOverrideIfNeeded(
                        for: peer,
                        reason: reason,
                        activePolicy: policy
                    )
                }
                await self.restartScreenSharingIfNeeded(
                    for: peer,
                    reason: reason,
                    expectedAttemptGeneration: attemptGeneration
                )
            }
        }

        let outboundFramePump = peer.outboundFramePump
        let videoFrameSequence = RemoteControlFrameSequenceGenerator()
        let videoFrameSubmissionPipe = RemoteControlEncodedFrameSubmissionPipe(
            outboundFramePump: outboundFramePump
        )
        streamer.onEncodedFrame = { data, width, height, frameType, isSyncFrame in
            let fmt: String
            switch frameType {
            case .hevc: fmt = "hevc"
            case .h264: fmt = "h264"
            case .bgra:
                // 兼容 iOS：当 ScreenCaptureKitStreamer 运行在“JPEG 模式”时仍会用 .bgra 标记
                if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 {
                    fmt = "jpeg"
                } else {
                    fmt = "bgra"
                }
            }
            let encodedAt = Date().timeIntervalSince1970
            let frame = ScreenData(
                width: width,
                height: height,
                imageData: data,
                timestamp: encodedAt,
                format: fmt,
                isSyncFrame: isSyncFrame,
                sequenceNumber: videoFrameSequence.next()
            )
            videoFrameSubmissionPipe.submit(frame)
        }
        await outboundFramePump.setSyncRefreshHandler { [weak streamer] in
            Task { @MainActor [weak streamer] in
                streamer?.requestKeyFrameRefresh(reason: "outbound-frame-drop", count: 1)
            }
        }
        streamer.onDamageReport = { report in
            Task.detached(priority: .utility) {
                await outboundFramePump.submitDamageReport(report)
            }
        }
        if legacyAudioFallbackEnabled {
            streamer.onCapturedAudioChunk = { [outboundFramePump] chunk in
                let wirePayload = RemoteDesktopAudioChunkWire.encode(chunk)
                Task.detached(priority: .userInitiated) {
                    await outboundFramePump.submitAudioPayload(wirePayload)
                }
            }
        } else {
            streamer.onCapturedAudioChunk = nil
        }
        let realtimeAudioCaptureStreamerForAttempt: ScreenCaptureKitStreamer?
        if let realtimeAudioSender {
            peer.realtimeAudioSender = realtimeAudioSender
            if preservedRealtimeAudioCaptureStreamer != nil {
                realtimeAudioCaptureStreamerForAttempt = nil
            } else {
                let realtimePCMSubmissionPipe = RemoteRealtimePCM16SubmissionPipe(sender: realtimeAudioSender)
                let audioStreamer = ScreenCaptureKitStreamer()
                audioStreamer.onCapturedPCM16AudioChunk = { [realtimePCMSubmissionPipe] chunk in
                    realtimePCMSubmissionPipe.submit(chunk)
                }
                audioStreamer.onCaptureIssue = { [weak self, weak peer, strictMediaFallbacks, attemptGeneration] reason in
                    guard let self, let peer else { return }
                    Task { @MainActor [weak self, weak peer] in
                        guard let self, let peer,
                              self.isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                            return
                        }
                        if strictMediaFallbacks {
                            await self.failStrictMediaCapture(
                                for: peer,
                                reason: reason,
                                component: "audio",
                                owner: .screenSharingAttempt(attemptGeneration)
                            )
                            return
                        }
                        await self.restartScreenSharingIfNeeded(
                            for: peer,
                            reason: "p2p-realtime-audio-\(reason)",
                            expectedAttemptGeneration: attemptGeneration
                        )
                    }
                }
                realtimeAudioCaptureStreamerForAttempt = audioStreamer
            }
            streamer.onCapturedPCM16AudioChunk = nil
        } else {
            realtimeAudioCaptureStreamerForAttempt = nil
            streamer.onCapturedPCM16AudioChunk = nil
        }
        if audioRedirectionEnabled && realtimeMediaAudioRequested && !legacyAudioFallbackEnabled && realtimeAudioSender == nil {
            logger.info(
                "🎧 P2P 音频请求 PQC media plane，但媒体端点不可用；保持视频优先并禁用 legacy 音频: peer=\(peer.id, privacy: .public)"
            )
        } else if realtimeAudioSender != nil {
            logger.info(
                "🎧 P2P 音频已接入 PQC media plane，禁止回退共享远控通道: peer=\(peer.id, privacy: .public)"
            )
        }
        logger.info(
            """
            📺 推流参数: \(Int(policy.preferredSize.width))x\(Int(policy.preferredSize.height)) \
            @\(policy.targetFrameRate)fps gop=\(policy.keyFrameInterval) \
            codec=\(Self.codecName(policy.codec), privacy: .public) \
            reason=\(policy.reason, privacy: .public) \
            audio=\(audioRedirectionEnabled, privacy: .public) \
            audioTransport=\(peer.requestedStreamConfiguration?.audioTransport ?? "legacy-default", privacy: .public) \
            legacyAudioFallback=\(legacyAudioFallbackEnabled, privacy: .public) \
            audioCodec=\(preferredAudioEncoding.rawValue, privacy: .public) \
            activeAudioPath=\(activeAudioPath, privacy: .public) \
            videoCapturesAudio=\(legacyAudioFallbackEnabled, privacy: .public) \
            realtimeAudioCapture=\(preservedRealtimeAudioCaptureStreamer != nil ? "preserved-sck" : (realtimeAudioCaptureStreamerForAttempt == nil ? "none" : "separate-sck"), privacy: .public) \
            mediaFallbackPolicy=\(streamConfiguration?.mediaFallbackPolicy ?? "default", privacy: .public) \
            strictMediaFallbacks=\(strictMediaFallbacks, privacy: .public) \
            preserveExactVisibleSize=\(policy.preserveExactVisibleSize, privacy: .public) \
            build=\(Self.remoteControlBuildFingerprint, privacy: .public)
            """
        )

        var startedRealtimeAudioCaptureStreamer: ScreenCaptureKitStreamer?
        var didCloseRealtimeAudioSenderForAudioStartFailure = false

        do {
            beginRealtimeStreamingActivity(for: peer, strictMediaFallbacks: strictMediaFallbacks)
            await syncOutboundFramePump(for: peer)
            guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                throw CancellationError()
            }
            try await streamer.start(
                preferredCodec: policy.codec,
                preferredSize: policy.preferredSize,
                targetFPS: policy.targetFrameRate,
                keyFrameInterval: policy.keyFrameInterval,
                captureCursorInVideo: !(peer.requestedStreamConfiguration?.separateCursorChannelEnabled ?? false),
                captureSystemAudio: legacyAudioFallbackEnabled,
                audioEncoding: preferredAudioEncoding,
                failFastOnMediaFallbacks: strictMediaFallbacks,
                preserveExactVisibleSize: policy.preserveExactVisibleSize,
                lowLatencyMode: peer.requestedStreamConfiguration?.lowLatencyMode
                    ?? RemoteDesktopSettingsManager.shared.settings.displaySettings.lowLatencyMode,
                videoCompressionLevelPercent: streamConfiguration?.videoCompressionLevel
                    ?? RemoteDesktopSettingsManager.shared.settings.displaySettings.boundedCompressionLevelPercent,
                bitstreamFormat: .annexB,
                // 采集哪块显示器：优先控制端选择，其次本机设置；nil = 主屏。
                preferredDisplayID: (peer.requestedStreamConfiguration?.captureDisplayID).map { CGDirectDisplayID($0) }
                    ?? RemoteDesktopSettingsManager.shared.settings.displaySettings.captureDisplayID.map { CGDirectDisplayID($0) }
            )
            guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                throw CancellationError()
            }
            if let realtimeAudioCaptureStreamerForAttempt {
                logger.info(
                    "🎧 启动独立 P2P realtime 音频采集流，主视频流保持 capturesAudio=false: peer=\(peer.id, privacy: .public)"
                )
                do {
                    try await realtimeAudioCaptureStreamerForAttempt.start(
                        preferredCodec: .h264,
                        preferredSize: CGSize(width: 16, height: 16),
                        targetFPS: 1,
                        keyFrameInterval: 10,
                        captureCursorInVideo: false,
                        captureVideoOutput: false,
                        captureSystemAudio: true,
                        audioEncoding: .pcmS16LE,
                        failFastOnMediaFallbacks: strictMediaFallbacks,
                        lowLatencyMode: true,
                        bitstreamFormat: .annexB
                    )
                    startedRealtimeAudioCaptureStreamer = realtimeAudioCaptureStreamerForAttempt
                } catch {
                    guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                        throw CancellationError()
                    }
                    if strictMediaFallbacks {
                        logger.error(
                            "⛔️ 严格媒体策略要求远控音频成功启动，已终止远控推流: peer=\(peer.id, privacy: .public) reason=p2p-realtime-audio-start-failed err=\(error.localizedDescription, privacy: .public)"
                        )
                        RemoteControlSmokeStatusWriter.append(
                            "audioTxCaptureStartFailed peer=\(peer.id) reason=p2p-realtime-audio-start-failed action=strict-fail-closed error=\(Self.sanitizeTelemetryToken(error.localizedDescription))"
                        )
                        streamer.stop()
                        realtimeAudioCaptureStreamerForAttempt.stop()
                        await failStrictMediaCapture(
                            for: peer,
                            reason: "p2p-realtime-audio-start-failed",
                            component: "audio",
                            owner: .screenSharingAttempt(attemptGeneration)
                        )
                        return
                    }
                    logger.error(
                        "❌ 启动独立 P2P realtime 音频采集流失败，保留视频远控主路径: peer=\(peer.id, privacy: .public) reason=p2p-realtime-audio-start-failed err=\(error.localizedDescription, privacy: .public)"
                    )
                    RemoteControlSmokeStatusWriter.append(
                        "audioTxCaptureStartFailed peer=\(peer.id) reason=p2p-realtime-audio-start-failed action=video-preserved error=\(Self.sanitizeTelemetryToken(error.localizedDescription))"
                    )
                    realtimeAudioCaptureStreamerForAttempt.stop()
                    if #available(macOS 14.0, *), let realtimeAudioSender {
                        _ = detachRealtimeAudioSender(
                            from: peer,
                            ifOwnedBy: realtimeAudioSender
                        )
                        await realtimeAudioSender.close(reason: "p2p-realtime-audio-start-failed")
                        didCloseRealtimeAudioSenderForAudioStartFailure = true
                    }
                }
            }
            guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                logger.info("ℹ️ 已忽略过期的屏幕采集启动完成: peer=\(peer.id, privacy: .public)")
                streamer.stop()
                startedRealtimeAudioCaptureStreamer?.stop()
                if #available(macOS 14.0, *),
                   let realtimeAudioSender,
                   !didReuseRealtimeAudioSender,
                   !didCloseRealtimeAudioSenderForAudioStartFailure {
                    _ = detachRealtimeAudioSender(
                        from: peer,
                        ifOwnedBy: realtimeAudioSender
                    )
                    await realtimeAudioSender.close(reason: "stale-screen-sharing-attempt")
                }
                return
            }
            captureStreamer = streamer
            if let startedRealtimeAudioCaptureStreamer {
                preservedRealtimeAudioCaptureStreamer?.stop()
                realtimeAudioCaptureStreamer = startedRealtimeAudioCaptureStreamer
                realtimeAudioCaptureStrictMediaFallbacks = strictMediaFallbacks
            } else {
                realtimeAudioCaptureStreamer = preservedRealtimeAudioCaptureStreamer
                realtimeAudioCaptureStrictMediaFallbacks = preservedRealtimeAudioCaptureStreamer == nil
                    ? nil
                    : strictMediaFallbacks
            }
            screenSharingActive = true
            screenCaptureStartupRetryCountByPeerId[peer.id] = 0
            configureClipboardSync(for: peer)
            startInteractionTelemetryIfNeeded(for: peer)
            screenCaptureWatchdogTask = Task { [weak self, weak streamer] in
                guard let self, let streamer else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { break }
                    guard self.captureStreamer === streamer,
                          self.isBeingControlled else { break }

                    let health = streamer.healthSnapshot()
                    let framePumpHealth = await outboundFramePump.healthSnapshot()
                    guard self.captureStreamer === streamer,
                          self.isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                        break
                    }
                    let now = Date()
                    let sampleAge = now.timeIntervalSince(health.lastSampleBufferAt)
                    let meaningfulSampleAge = now.timeIntervalSince(health.lastMeaningfulSampleAt)
                    let encodedAge = now.timeIntervalSince(health.lastEncodedFrameAt)
                    let sentAge = now.timeIntervalSince(framePumpHealth.lastSentFrameAt)
                    let hasSampleFlow = health.lastSampleBufferAt != .distantPast
                    let hasMeaningfulSampleFlow = health.lastMeaningfulSampleAt != .distantPast

                    if hasMeaningfulSampleFlow && meaningfulSampleAge < 1.5 && encodedAge > 2.0 {
                        self.logger.warning(
                            """
                            ⚠️ 检测到录屏编码停滞：peer=\(peer.id, privacy: .public) \
                            sampleAge=\(sampleAge, privacy: .public) \
                            meaningfulSampleAge=\(meaningfulSampleAge, privacy: .public) \
                            encodedAge=\(encodedAge, privacy: .public)
                            """
                        )
                        if strictMediaFallbacks {
                            await self.failStrictMediaCapture(
                                for: peer,
                                reason: "strict-encoded-stall",
                                component: "video",
                                owner: .screenSharingAttempt(attemptGeneration)
                            )
                        } else {
                            await self.restartScreenSharingIfNeeded(
                                for: peer,
                                reason: "encoded-stall",
                                expectedAttemptGeneration: attemptGeneration
                            )
                        }
                        break
                    } else if hasMeaningfulSampleFlow,
                              encodedAge < 1.0,
                              sentAge > 2.0 {
                        self.logger.warning(
                            """
                            ⚠️ 检测到录屏发送停滞：peer=\(peer.id, privacy: .public) \
                            encodedAge=\(encodedAge, privacy: .public) \
                            sentAge=\(sentAge, privacy: .public) \
                            waitingForSync=\(framePumpHealth.waitingForSyncFrame, privacy: .public)
                            """
                        )
                        if strictMediaFallbacks {
                            await self.failStrictMediaCapture(
                                for: peer,
                                reason: "strict-frame-send-stall",
                                component: "video",
                                owner: .screenSharingAttempt(attemptGeneration)
                            )
                        } else {
                            streamer.requestKeyFrameRefresh(reason: "frame-send-stall")
                            await self.restartScreenSharingIfNeeded(
                                for: peer,
                                reason: "frame-send-stall",
                                expectedAttemptGeneration: attemptGeneration
                            )
                        }
                        break
                    } else if hasSampleFlow,
                              !hasMeaningfulSampleFlow,
                              encodedAge > 2.0 {
                        self.logger.debug(
                            """
                            ℹ️ 录屏流处于 idle 状态，暂不将未编码判定为故障：peer=\(peer.id, privacy: .public) \
                            sampleAge=\(sampleAge, privacy: .public) \
                            encodedAge=\(encodedAge, privacy: .public)
                            """
                        )
                    }
                }
            }
        } catch {
            guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                logger.info("ℹ️ 已忽略过期的屏幕采集启动错误: peer=\(peer.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                streamer.stop()
                startedRealtimeAudioCaptureStreamer?.stop()
                if startedRealtimeAudioCaptureStreamer == nil {
                    realtimeAudioCaptureStreamerForAttempt?.stop()
                }
                if #available(macOS 14.0, *),
                   let realtimeAudioSender,
                   !didReuseRealtimeAudioSender,
                   !didCloseRealtimeAudioSenderForAudioStartFailure {
                    _ = detachRealtimeAudioSender(
                        from: peer,
                        ifOwnedBy: realtimeAudioSender
                    )
                    await realtimeAudioSender.close(reason: "stale-screen-sharing-start-error")
                }
                return
            }
            logger.error(
                "❌ 启动 ScreenCaptureKitStreamer 失败: \(error.localizedDescription, privacy: .public). 请确认已在“系统设置 > 隐私与安全 > 录屏与系统录音”中为当前运行的 App 条目授权，必要时完全退出后重开。"
            )
            streamer.stop()
            startedRealtimeAudioCaptureStreamer?.stop()
            if startedRealtimeAudioCaptureStreamer == nil {
                realtimeAudioCaptureStreamerForAttempt?.stop()
            }
            if #available(macOS 14.0, *),
               let realtimeAudioSender,
               !didReuseRealtimeAudioSender,
               !didCloseRealtimeAudioSenderForAudioStartFailure {
                _ = detachRealtimeAudioSender(
                    from: peer,
                    ifOwnedBy: realtimeAudioSender
                )
                await realtimeAudioSender.close(reason: "screen-sharing-start-failed")
            }
            guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                logger.info(
                    "ℹ️ 已忽略关闭过期音频 sender 后的屏幕采集启动错误: peer=\(peer.id, privacy: .public)"
                )
                return
            }
            if !scheduleScreenSharingStartupRetry(
                for: peer,
                error: error,
                replacing: streamer,
                strictMediaFallbacks: strictMediaFallbacks
            ) {
                screenSharingActive = false
                endRealtimeStreamingActivity(reason: "screen-sharing-start-failed")
            }
        }
    }

    private func beginRealtimeStreamingActivity(
        for peer: PeerConnection,
        strictMediaFallbacks: Bool
    ) {
#if os(macOS)
        if realtimeStreamingActivity != nil {
            realtimeStreamingActivityPeerId = peer.id
            return
        }

        realtimeStreamingActivity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiatedAllowingIdleSystemSleep,
                .latencyCritical,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled
            ],
            reason: "SkyBridge remote desktop realtime stream"
        )
        realtimeStreamingActivityPeerId = peer.id
        logger.info(
            """
            📺 远控 realtime activity 已启用: peer=\(peer.id, privacy: .public) \
            appNapDisabled=1 idleSleepAllowed=0 strictMediaFallbacks=\(strictMediaFallbacks, privacy: .public)
            """
        )
        RemoteControlSmokeStatusWriter.append(
            "mac-remote-realtime-activity active=1 appNapDisabled=1 idleSleepAllowed=0 peer=\(peer.id) strictMediaFallbacks=\(strictMediaFallbacks)"
        )
#else
        _ = peer
        _ = strictMediaFallbacks
#endif
    }

    private func endRealtimeStreamingActivity(reason: String) {
#if os(macOS)
        guard let activity = realtimeStreamingActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        let peerId = realtimeStreamingActivityPeerId ?? "unknown"
        realtimeStreamingActivity = nil
        realtimeStreamingActivityPeerId = nil
        logger.info(
            "📺 远控 realtime activity 已释放: peer=\(peerId, privacy: .public) reason=\(reason, privacy: .public)"
        )
        RemoteControlSmokeStatusWriter.append(
            "mac-remote-realtime-activity active=0 appNapDisabled=0 peer=\(peerId) reason=\(Self.sanitizeTelemetryToken(reason))"
        )
#else
        _ = reason
#endif
    }

    private func invalidateScreenSharingStartupState(for peerId: String) {
        screenSharingAttemptGate.invalidateAttempts(for: peerId)
    }

    private func isCurrentScreenSharingAttempt(
        _ attemptGeneration: UInt64,
        for peer: PeerConnection
    ) -> Bool {
        isCurrentPeer(peer)
            && isBeingControlled
            && screenSharingAttemptGate.isCurrentAttempt(attemptGeneration, for: peer.id)
    }

    private func scheduleScreenSharingStartupRetry(
        for peer: PeerConnection,
        error: Error,
        replacing streamer: ScreenCaptureKitStreamer,
        strictMediaFallbacks: Bool
    ) -> Bool {
        let nextAttempt = (screenCaptureStartupRetryCountByPeerId[peer.id] ?? 0) + 1
        screenCaptureStartupRetryCountByPeerId[peer.id] = nextAttempt

        let nsError = error as NSError
        logger.error(
            """
            ❌ 屏幕采集启动失败: peer=\(peer.id, privacy: .public) \
            attempt=\(nextAttempt, privacy: .public) \
            domain=\(nsError.domain, privacy: .public) \
            code=\(nsError.code, privacy: .public)
            """
        )

        screenCaptureWatchdogTask?.cancel()
        screenCaptureWatchdogTask = nil
        streamer.stop()
        if captureStreamer === streamer {
            captureStreamer = nil
        }
        screenSharingActive = false

        guard !strictMediaFallbacks else {
            logger.error(
                "⛔️ 严格媒体策略禁止屏幕采集启动失败后自动重试: peer=\(peer.id, privacy: .public)"
            )
            RemoteControlSmokeStatusWriter.append(
                "mac-sck-start result=failed-closed reason=strict-startup-retry-forbidden peer=\(peer.id) domain=\(Self.sanitizeTelemetryToken(nsError.domain)) code=\(nsError.code)"
            )
            return false
        }

        guard nextAttempt <= 2 else {
            logger.error(
                "❌ 屏幕采集启动已连续失败，保留远控会话等待人工重试: peer=\(peer.id, privacy: .public)"
            )
            return false
        }

        let delay: Duration = nextAttempt == 1 ? .milliseconds(250) : .seconds(1)
        logger.warning(
            "⚠️ 屏幕采集启动失败，保留远控会话并准备自动重试: peer=\(peer.id, privacy: .public) delay=\(String(describing: delay), privacy: .public)"
        )

        Task { @MainActor [weak self, weak peer] in
            guard let self, let peer else { return }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard self.isCurrentPeer(peer), self.isBeingControlled else { return }
            guard self.captureStreamer == nil else { return }
            await self.startScreenSharing(to: peer)
        }
        return true
    }

    private func restartScreenSharingIfNeeded(
        for peer: PeerConnection,
        reason: String,
        expectedAttemptGeneration: UInt64
    ) async {
        guard !screenCaptureRestartInProgress else { return }
        guard isCurrentScreenSharingAttempt(expectedAttemptGeneration, for: peer),
              isBeingControlled else { return }
        guard peer.requestedStreamConfiguration?.isStopRequest != true else { return }
        guard captureStreamer != nil else { return }

        screenCaptureRestartInProgress = true
        defer { screenCaptureRestartInProgress = false }

        logger.info("🔁 重新启动屏幕采集：peer=\(peer.id, privacy: .public) reason=\(reason, privacy: .public)")
        screenCaptureWatchdogTask?.cancel()
        screenCaptureWatchdogTask = nil
        captureStreamer?.stop()
        captureStreamer = nil
        if reason.hasPrefix("p2p-realtime-audio-") {
            realtimeAudioCaptureStreamer?.stop()
            realtimeAudioCaptureStreamer = nil
            realtimeAudioCaptureStrictMediaFallbacks = nil
        }

        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        guard isCurrentScreenSharingAttempt(expectedAttemptGeneration, for: peer),
              isBeingControlled,
              peer.requestedStreamConfiguration?.isStopRequest != true else {
            return
        }
        await startScreenSharing(to: peer)
    }

    private func effectiveCapturePolicy(
        _ selectedPolicy: RemoteControlStreamPolicy,
        for peer: PeerConnection
    ) -> RemoteControlStreamPolicy {
        guard let override = peer.captureCompatibilityOverride,
              override != selectedPolicy.codec else {
            return selectedPolicy
        }

        let normalizedSize = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            selectedPolicy.preferredSize,
            for: override,
            preserveExactVisibleSize: selectedPolicy.preserveExactVisibleSize
        )
        return RemoteControlStreamPolicy(
            codec: override,
            targetFrameRate: selectedPolicy.targetFrameRate,
            keyFrameInterval: selectedPolicy.keyFrameInterval,
            preferredSize: normalizedSize,
            preserveExactVisibleSize: selectedPolicy.preserveExactVisibleSize,
            reason: "\(selectedPolicy.reason)+compat-\(Self.codecName(override))"
        )
    }

    private func applyCaptureCompatibilityOverrideIfNeeded(
        for peer: PeerConnection,
        reason: String,
        activePolicy: RemoteControlStreamPolicy
    ) {
        guard let status = captureEncodeStatus(from: reason),
              let override = RemoteControlCaptureCompatibility.fallbackCodec(
                  afterEncodeFailure: status,
                  activeCodec: activePolicy.codec
              ),
              override != peer.captureCompatibilityOverride else {
            return
        }

        peer.captureCompatibilityOverride = override
        logger.warning(
            """
            ⚠️ 检测到远控编码器兼容性故障，已对当前会话降级: \
            peer=\(peer.id, privacy: .public) \
            status=\(status, privacy: .public) \
            from=\(Self.codecName(activePolicy.codec), privacy: .public) \
            to=\(Self.codecName(override), privacy: .public)
            """
        )
    }

    private func captureEncodeStatus(from reason: String) -> OSStatus? {
        let prefix = "encode-status-"
        guard reason.hasPrefix(prefix) else { return nil }
        guard let value = Int32(reason.dropFirst(prefix.count)) else { return nil }
        return OSStatus(value)
    }

    private func startInteractionTelemetryIfNeeded(for peer: PeerConnection) {
        guard isCurrentPeer(peer) else { return }
        guard interactionTelemetryTasksByPeerId[peer.id] == nil else { return }

        interactionTelemetryTasksByPeerId[peer.id] = Task { @MainActor [weak self] in
            guard let self else { return }

#if os(macOS)
            let sampler = RemoteDesktopInteractionTelemetrySampler()
            let overlaySampleStride = 6
            var loopIndex = 0
            var cursorChannelWasEnabled = false
            var overlayChannelWasEnabled = false

            defer {
                self.interactionTelemetryTasksByPeerId.removeValue(forKey: peer.id)
            }

            while !Task.isCancelled {
                guard self.isCurrentPeer(peer), self.isBeingControlled else { break }

                let wantsCursorChannel = peer.requestedStreamConfiguration?.separateCursorChannelEnabled ?? false
                let wantsOverlayChannel = peer.requestedStreamConfiguration?.interactionOverlayChannelEnabled ?? false

                if !wantsCursorChannel && cursorChannelWasEnabled {
                    sampler.resetCursorState()
                    do {
                        try await self.sendRemoteControlPayload(
                            RemoteDesktopCursorPayload(
                                x: 0,
                                y: 0,
                                width: 1,
                                height: 1,
                                hidden: true
                            ),
                            type: .cursorUpdate,
                            to: peer
                        )
                    } catch {
                        self.logger.debug("ℹ️ 光标通道停用清空失败: \(error.localizedDescription, privacy: .public)")
                    }
                }

                if !wantsOverlayChannel && overlayChannelWasEnabled {
                    sampler.resetOverlayState()
                    do {
                        try await self.sendRemoteControlPayload(
                            RemoteDesktopOverlayPayload(),
                            type: .overlayUpdate,
                            to: peer
                        )
                    } catch {
                        self.logger.debug("ℹ️ overlay 通道停用清空失败: \(error.localizedDescription, privacy: .public)")
                    }
                }

                cursorChannelWasEnabled = wantsCursorChannel
                overlayChannelWasEnabled = wantsOverlayChannel

                guard wantsCursorChannel || wantsOverlayChannel else {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
                    continue
                }

                guard let captureContext = captureStreamer?.captureContextSnapshot() else {
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        return
                    }
                    continue
                }

                let context = RemoteDesktopInteractionTelemetrySampler.CaptureContext(
                    displayID: captureContext.displayID,
                    displayPixelSize: captureContext.displayPixelSize,
                    streamSize: captureContext.streamSize
                )

                if wantsCursorChannel,
                   let cursorPayload = sampler.sampleCursor(context: context) {
                    do {
                        try await self.sendRemoteControlPayload(
                            cursorPayload,
                            type: .cursorUpdate,
                            to: peer
                        )
                    } catch {
                        self.logger.debug("ℹ️ cursorUpdate 发送失败: \(error.localizedDescription, privacy: .public)")
                    }
                }

                loopIndex = (loopIndex + 1) % overlaySampleStride
                if wantsOverlayChannel,
                   loopIndex == 0,
                   let overlayPayload = sampler.sampleOverlay(context: context) {
                    do {
                        try await self.sendRemoteControlPayload(
                            overlayPayload,
                            type: .overlayUpdate,
                            to: peer
                        )
                    } catch {
                        self.logger.debug("ℹ️ overlayUpdate 发送失败: \(error.localizedDescription, privacy: .public)")
                    }
                }

                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
            }
#endif
        }
    }

    private func stopInteractionTelemetry(for deviceId: String) {
        if let task = interactionTelemetryTasksByPeerId.removeValue(forKey: deviceId) {
            task.cancel()
        }
    }

    private static var allowsInsecureLegacyRemoteControl: Bool {
        RemoteControlSOABindingPolicy.allowsInsecureLegacyRemoteControl
    }

    @available(macOS 14.0, *)
    typealias RemoteControlSOABinding = RemoteControlSOABindingPolicy.Binding

    @available(macOS 14.0, *)
    nonisolated static func remoteControlSOABinding(
        localDeviceId: String?,
        remoteDeviceId: String?
    ) -> RemoteControlSOABinding? {
        RemoteControlSOABindingPolicy.binding(
            localDeviceId: localDeviceId,
            remoteDeviceId: remoteDeviceId
        )
    }

    @available(macOS 14.0, *)
    private nonisolated static func randomRemoteControlAttemptId() -> Data {
        RemoteControlSOABindingPolicy.randomAttemptId()
    }

    private func ensureSecureChannelEstablished(for peer: PeerConnection) throws {
        if #available(macOS 14.0, *) {
            guard peer.sessionKeys != nil || Self.allowsInsecureLegacyRemoteControl else {
                throw RemoteControlError.handshakeInitializationFailed("secure channel not established")
            }
        }
    }

    @available(macOS 14.0, *)
    private func makeRemoteControlTrustProvider(for deviceId: String) async throws -> DefaultHandshakeTrustProvider {
        let trustProvider = DefaultHandshakeTrustProvider(
            trustRecordsSnapshot: TrustSyncService.shared.activeTrustRecords
        )
        let trustedFingerprints = await trustProvider.trustedFingerprintSet(for: deviceId)
        guard !trustedFingerprints.isEmpty else {
            throw RemoteControlError.untrustedPeer(deviceId)
        }
        return trustProvider
    }

    @available(macOS 14.0, *)
    private func syncSecureChannelState(
        after driver: HandshakeDriver,
        for peer: PeerConnection
    ) async throws -> HandshakeSyncResult {
        switch await driver.getCurrentState() {
        case .established(let keys):
            try await bindEstablishedSOALease(
                from: driver,
                sessionKeys: keys,
                for: peer
            )
            let installed = try await installSecureSessionKeys(
                keys,
                for: peer,
                source: "handshake-driver-established"
            )
            if installed {
                logger.info("🔐 RemoteControl handshake established for \(peer.id, privacy: .public)")
                let remoteDeviceId = DiagnosticFieldSanitizer.fieldValue(
                    peer.handshakePeer?.deviceId
                )
                emitSmokeTrace(
                    "mac remote established peer=\(peer.id) remoteDeviceId=\(remoteDeviceId) suite=\(keys.negotiatedSuite.rawValue)"
                )
            }
            return .established
        case .failed(let reason):
            let renderedReason = String(describing: reason)
            if Self.shouldKeepTransportAliveAfterHandshakeFailure(for: peer.role) {
                logger.warning(
                    "⚠️ RemoteControl inbound handshake failed but keeping transport for retry: peer=\(peer.id, privacy: .public) reason=\(renderedReason, privacy: .public)"
                )
                emitSmokeTrace("mac remote inbound-handshake-retry peer=\(peer.id) reason=\(renderedReason)")
                peer.handshakeDriver = nil
                return .retryableFailure(renderedReason)
            }
            throw RemoteControlError.handshakeInitializationFailed(renderedReason)
        default:
            return .pending
        }
    }

    @available(macOS 14.0, *)
    private func bindEstablishedSOALease(
        from driver: HandshakeDriver?,
        sessionKeys: SessionKeys,
        for peer: PeerConnection
    ) async throws {
        let lease = if let driver {
            await driver.getEstablishedArbiterLease()
        } else {
            peer.soaEstablishedLease
        }
        guard let pairKey = peer.soaPairKey,
              let lease,
              lease.pairKey == pairKey,
              lease.sessionId == sessionKeys.sessionId else {
            throw RemoteControlError.handshakeInitializationFailed(
                "established remote-control session missing exact SOA lease"
            )
        }

        if let previousLease = peer.soaEstablishedLease,
           previousLease != lease {
            _ = await PeerSessionArbiter.shared.clearEstablished(previousLease)
        }
        peer.soaEstablishedLease = lease
    }

    @available(macOS 14.0, *)
    private func installSecureSessionKeys(
        _ keys: SessionKeys,
        for peer: PeerConnection,
        source: String
    ) async throws -> Bool {
        if let existing = peer.sessionKeys {
            if Self.isSameRemoteControlSecureSession(existing, keys) {
                peer.handshakeDriver = nil
                logger.debug(
                    "ℹ️ RemoteControl duplicate secure session install ignored for \(peer.id, privacy: .public) source=\(source, privacy: .public)"
                )
                return false
            }

            let reason = "RemoteControl secure channel attempted to replace active session for \(peer.id): existing=\(existing.sessionId) incoming=\(keys.sessionId) source=\(source)"
            logger.error("⛔️ \(reason, privacy: .public)")
            throw RemoteControlError.handshakeInitializationFailed(reason)
        }

        peer.sessionKeys = keys
        peer.secureEnvelopeSendSequencer.resetIfSessionChanged(sessionId: keys.sessionId)
        peer.secureEnvelopeReplayWindow = RemoteControlSecureReplayWindow()
        peer.handshakeDriver = nil
        await syncOutboundFramePump(for: peer)
        return true
    }

    @available(macOS 14.0, *)
    private static func isSameRemoteControlSecureSession(_ lhs: SessionKeys, _ rhs: SessionKeys) -> Bool {
        lhs.sessionId == rhs.sessionId
            && lhs.negotiatedSuite.rawValue == rhs.negotiatedSuite.rawValue
            && lhs.role.rawValue == rhs.role.rawValue
            && lhs.transcriptHash == rhs.transcriptHash
            && lhs.sendKey == rhs.sendKey
            && lhs.receiveKey == rhs.receiveKey
    }

    @available(macOS 14.0, *)
    private func establishOutboundSecureChannel(for peer: PeerConnection) async -> Bool {
        guard isCurrentPeer(peer),
              let handshakePeer = peer.handshakePeer else {
            return false
        }
        let peerID = peer.id
        let peerRole = peer.role
        let peerIdentity = ObjectIdentifier(peer)

        let localDeviceId: String
        do {
            localDeviceId = try await SelfIdentityProvider.shared
                .protocolIdentityDeviceId(allowCreate: true)
        } catch {
            logger.error(
                "❌ RemoteControl outbound identity unavailable: \(error.localizedDescription, privacy: .public)"
            )
            await handleConnectionClosed(
                peer: peer,
                error: RemoteControlError.handshakeInitializationFailed(
                    "local identity authority unavailable"
                )
            )
            return false
        }
        guard let soaBinding = Self.remoteControlSOABinding(
            localDeviceId: localDeviceId,
            remoteDeviceId: handshakePeer.deviceId
        ) else {
            logger.error("❌ RemoteControl outbound handshake missing stable SOA identity for \(handshakePeer.deviceId, privacy: .public)")
            await handleConnectionClosed(peer: peer, error: RemoteControlError.untrustedPeer(handshakePeer.deviceId))
            return false
        }
        let soaPairKey = PeerSessionArbiter.pairKey(
            localPeerId: soaBinding.localPeerId,
            remotePeerId: soaBinding.expectedRemotePeerId,
            scope: .remoteControl
        )
        recordSOAState(soaPairKey, for: peer)

        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let policy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        let selection: CryptoProviderFactory.SelectionPolicy = policy.requirePQC ? .requirePQC : .preferPQC
        let baseProvider = CryptoProviderFactory.make(policy: selection)

        do {
            try await releaseStaleSOAStateBeforeHandshake(for: peer)
            let trustProvider = try await makeRemoteControlTrustProvider(for: handshakePeer.deviceId)
            let transport = RemoteControlHandshakeTransport(connection: peer.connection)
            let configuration = try await SettingsManager.shared
                .committedProtocolIdentityConfiguration()
            let peerAlgorithm = TrustSyncService.shared.outboundPQCSignatureAlgorithm(
                deviceId: handshakePeer.deviceId,
                requestedAlgorithm: configuration.algorithm
            )
            let outboundProtocolIdentity = (
                requestedAlgorithm: configuration.algorithm,
                requestedProtection: configuration.protection,
                selectedAlgorithm: peerAlgorithm
            )
            let keys = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: handshakePeer.deviceId,
                preferPQC: true,
                policy: policy,
                cryptoProvider: baseProvider,
                executor: { [weak self] preparation in
                    let isStillCurrent = await MainActor.run { [weak self] in
                        guard let self,
                              let current = self.currentPeer(for: peerRole, deviceId: peerID) else { return false }
                        return ObjectIdentifier(current) == peerIdentity
                    }
                    guard isStillCurrent else {
                        throw RemoteControlError.connectionClosed
                    }

                    let cryptoProvider: any CryptoProvider = {
                        switch preparation.strategy {
                        case .pqcOnly:
                            return CryptoProviderFactory.make(policy: selection)
                        case .classicOnly:
                            return CryptoProviderFactory.make(policy: .classicOnly)
                        }
                    }()

                    let identityProvider = DeviceIdentityHandshakeProvider(
                        sigAAlgorithm: preparation.sigAAlgorithm,
                        protocolSigningKeyProtection: preparation.sigAAlgorithm
                            == outboundProtocolIdentity.requestedAlgorithm
                            ? outboundProtocolIdentity.requestedProtection
                            : .softwareKeychain,
                        includeSecureEnclavePoP: policy.requireSecureEnclavePoP
                    )
                    let cryptoPolicy = HandshakeCryptoPolicyResolver.policy(for: preparation.offeredSuites)
                    let soaMetadata = try HandshakeSOAMetadata(
                        initiatorPeerId: soaBinding.localPeerId,
                        targetPeerId: soaBinding.expectedRemotePeerId,
                        attemptId: Self.randomRemoteControlAttemptId()
                    )
                    let driver = try HandshakeDriver(
                        transport: transport,
                        cryptoProvider: cryptoProvider,
                        protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: preparation.sigAAlgorithm),
                        identityProvider: identityProvider,
                        sigAAlgorithm: preparation.sigAAlgorithm,
                        offeredSuites: preparation.offeredSuites,
                        policy: policy,
                        cryptoPolicy: cryptoPolicy,
                        trustProvider: trustProvider,
                        soaMetadata: soaMetadata,
                        localSOAPeerId: soaBinding.localPeerId,
                        expectedRemoteSOAPeerId: soaBinding.expectedRemotePeerId,
                        soaSessionScope: .remoteControl
                    )
                    await MainActor.run { [weak self] in
                        guard let self,
                              let current = self.currentPeer(for: peerRole, deviceId: peerID),
                              ObjectIdentifier(current) == peerIdentity else { return }
                        current.handshakeDriver = driver
                    }
                    return try await driver.initiateHandshake(with: handshakePeer)
                },
                pqcSignatureAlgorithm: outboundProtocolIdentity.selectedAlgorithm
            )

            try await bindEstablishedSOALease(
                from: peer.handshakeDriver,
                sessionKeys: keys,
                for: peer
            )
            let installed = try await installSecureSessionKeys(
                keys,
                for: peer,
                source: "performHandshake-return"
            )
            if installed {
                logger.info("🔐 RemoteControl outbound handshake established for \(peer.id, privacy: .public)")
                emitSmokeTrace("mac remote outbound-established peer=\(peer.id) suite=\(keys.negotiatedSuite.rawValue)")
            }
            return true
        } catch {
            logger.error("❌ RemoteControl outbound handshake failed for \(peer.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await handleConnectionClosed(peer: peer, error: error)
            return false
        }
    }

    private func waitForInitialStreamConfigurationIfAvailable(
        for peer: PeerConnection,
        timeout: Duration = RemoteControlScreenSharingStartupPolicy.initialConfigurationGrace
    ) async -> Bool {
        guard isCurrentPeer(peer) else { return false }
        if peer.requestedStreamConfiguration != nil {
            return true
        }

        let deadline = ContinuousClock.now + timeout
        while isCurrentPeer(peer),
              peer.requestedStreamConfiguration == nil,
              ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }

        guard isCurrentPeer(peer) else { return false }

        if let config = peer.requestedStreamConfiguration {
            logger.info(
                """
                📺 已收到 viewer 流配置: preferred=\(config.preferredCodec ?? "auto", privacy: .public) \
                formats=\(config.supportedVideoFormats.joined(separator: ","), privacy: .public) \
                fps=\(config.targetFrameRate, privacy: .public)
                """
            )
            return true
        } else {
            logger.info("📺 未在配置等待窗口内收到 viewer 流配置，继续等待已认证 viewer 配置")
            return false
        }
    }

    private func ensureScreenCapturePermission() async -> Bool {
        let authorized = await ScreenCaptureAuthorizationProbe.shared.requestAuthorizationIfNeeded {
            ScreenCapturePermissionSettingsOpener.open()
        }
        if !authorized {
            logger.warning("⚠️ 屏幕录制权限预检失败：系统仍未确认授权")
        }
        return authorized
    }

    private func syncOutboundFramePump(for peer: PeerConnection) async {
        guard isCurrentPeer(peer) else { return }
        if #available(macOS 14.0, *) {
            await peer.outboundFramePump.updateTransportState(
                requestedStreamConfiguration: peer.requestedStreamConfiguration,
                sessionKeys: peer.sessionKeys,
                allowsInsecureLegacy: Self.allowsInsecureLegacyRemoteControl
            )
        } else {
            await peer.outboundFramePump.updateTransportState(
                requestedStreamConfiguration: peer.requestedStreamConfiguration,
                sessionKeys: nil,
                allowsInsecureLegacy: true
            )
        }
    }

    private func usesBinaryScreenFrameTransport(for peer: PeerConnection) -> Bool {
        peer.requestedStreamConfiguration?.screenFrameTransport == "sbrf-v1"
    }

    private func sendRemoteControlPayload<T: Encodable & Sendable>(
        _ payload: T,
        type: RemoteMessage.MessageType,
        to peer: PeerConnection
    ) async throws {
        try ensureSecureChannelEstablished(for: peer)
        try await peer.outboundFramePump.sendControlPayload(payload, type: type)
    }

    private func sendRemoteControlWirePayload(_ payload: Data, to peer: PeerConnection) async throws {
        try ensureSecureChannelEstablished(for: peer)
        try await peer.outboundFramePump.sendRawPayload(payload)
    }

    @available(macOS 14.0, *)
    private func prepareP2PRealtimeAudioReceiverIfNeeded(
        for peer: PeerConnection,
        audioEnabled: Bool,
        mode: SkyBridgeMediaAudioMode
    ) async throws -> SkyBridgeMediaEndpoint? {
        guard isCurrentPeer(peer) else { throw CancellationError() }
        guard audioEnabled else {
            stopP2PRealtimeAudioReceiverIfNeeded(peerId: peer.id)
            return nil
        }
        guard let keys = peer.sessionKeys else {
            throw RemoteControlRealtimeMediaStartupError
                .missingAuthenticatedMediaSessionKeys
        }
        let interfaceBinding = try SkyBridgeRealtimeMediaInterfaceBinding
            .resolveAuthenticatedControlPath(
                connection: peer.connection,
                advertisedHost: nil,
                authenticatedSessionEstablished: true
            )

        let reuseKey = RemoteControlRealtimeAudioReceiverReuseKey(
            peerId: peer.id,
            peerIdentity: ObjectIdentifier(peer),
            secureSessionId: keys.sessionId,
            sendKey: keys.sendKey,
            receiveKey: keys.receiveKey,
            role: keys.role,
            transcriptHash: keys.transcriptHash,
            mode: mode,
            interfaceBindingIdentity: interfaceBinding.identity,
            authenticatedRemoteHost: interfaceBinding.authenticatedRemoteHost
        )
        if p2pRealtimeAudioReceiver != nil,
           p2pRealtimeAudioRenderer != nil,
           p2pRealtimeAudioReceiverReuseKey == reuseKey {
            return p2pRealtimeAudioReceiverEndpoint
        }

        stopP2PRealtimeAudioReceiverIfNeeded(
            peerId: p2pRealtimeAudioReceiverReuseKey?.peerId
        )
        p2pRealtimeAudioReceiverStartGeneration &+= 1
        let startGeneration = p2pRealtimeAudioReceiverStartGeneration
        p2pRealtimeAudioReceiverPendingPeerId = peer.id
        defer {
            if p2pRealtimeAudioReceiverStartGeneration == startGeneration {
                p2pRealtimeAudioReceiverPendingPeerId = nil
            }
        }

        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: keys.sendKey,
            receiveSecret: keys.receiveKey,
            sessionId: keys.sessionId,
            transcriptHash: keys.transcriptHash,
            localRole: keys.role == .initiator ? .initiator : .responder
        )
        let renderer = try RemoteRealtimeMediaAudioReceiver(
            sessionId: keys.sessionId,
            keys: keyMaterial.receive,
            mode: mode
        )
        let terminalPeerId = peer.id
        let terminalPeerIdentity = ObjectIdentifier(peer)
        let receiver = SkyBridgeUDPRealtimeMediaReceiver(
            interfaceBinding: interfaceBinding,
            terminalFailureHandler: { [weak self, terminalPeerId, terminalPeerIdentity] error in
                Task { @MainActor [weak self] in
                    guard let self,
                          let peer = self.controllingPeers[terminalPeerId],
                          ObjectIdentifier(peer) == terminalPeerIdentity else {
                        return
                    }
                    await self.handleP2PRealtimeAudioReceiverTerminalFailure(
                        error,
                        peer: peer,
                        peerIdentity: terminalPeerIdentity,
                        startGeneration: startGeneration
                    )
                }
            }
        )
        let endpoint: SkyBridgeMediaEndpoint
        do {
            endpoint = try await receiver.start { [weak self, renderer] datagram in
                Task(priority: .userInitiated) { [weak self, renderer] in
                    let latestVideoTimestamp = await MainActor.run { [weak self] in
                        self?.lastViewingInboundScreenTimestamp
                    }
                    await renderer.handle(
                        datagram: datagram,
                        latestVideoTimestamp: latestVideoTimestamp
                    )
                }
            }
        } catch {
            renderer.retire()
            receiver.stop()
            await renderer.close(
                reason: "p2p-realtime-audio-receiver-start-failed-before-install"
            )
            throw error
        }

        guard isCurrentPeer(peer) else {
            renderer.retire()
            receiver.stop()
            await renderer.close(
                reason: "p2p-realtime-audio-receiver-start-stale-before-install"
            )
            throw CancellationError()
        }
        guard p2pRealtimeAudioReceiverStartGeneration == startGeneration,
              p2pRealtimeAudioReceiverPendingPeerId == peer.id,
              let currentKeys = peer.sessionKeys,
              Self.isSameRemoteControlSecureSession(currentKeys, keys),
              interfaceBinding.validatesReadyPath(peer.connection.currentPath) else {
            renderer.retire()
            receiver.stop()
            await renderer.close(
                reason: "p2p-realtime-audio-receiver-session-changed-before-install"
            )
            throw RemoteControlRealtimeMediaStartupError.transportUnavailable
        }

        p2pRealtimeAudioReceiver = receiver
        p2pRealtimeAudioRenderer = renderer
        p2pRealtimeAudioReceiverReuseKey = reuseKey
        p2pRealtimeAudioReceiverEndpoint = endpoint
        logger.info(
            "🎧 P2P PQC media audio receiver ready: peer=\(peer.id, privacy: .public) port=\(endpoint.port, privacy: .public) mode=\(mode.rawValue, privacy: .public)"
        )
        return endpoint
    }

    private func handleP2PRealtimeAudioReceiverTerminalFailure(
        _ error: Error,
        peer: PeerConnection,
        peerIdentity: ObjectIdentifier,
        startGeneration: UInt64
    ) async {
        guard isCurrentPeer(peer) else { return }
        let ownsGeneration = p2pRealtimeAudioReceiverStartGeneration == startGeneration
        let ownsPending = ownsGeneration
            && p2pRealtimeAudioReceiverPendingPeerId == peer.id
        let ownsInstalled = ownsGeneration
            && p2pRealtimeAudioReceiverReuseKey?.peerId == peer.id
            && p2pRealtimeAudioReceiverReuseKey?.peerIdentity == peerIdentity
        guard ownsPending || ownsInstalled else { return }
        if ownsPending {
            p2pRealtimeAudioReceiverStartGeneration &+= 1
            p2pRealtimeAudioReceiverPendingPeerId = nil
        }
        stopP2PRealtimeAudioReceiverIfNeeded(peerId: peer.id)
        let reason = Self.realtimeAudioStartupFailureReason(error)
        RemoteControlSmokeStatusWriter.append(
            "audioRxReceiverTerminalFailure reason=\(reason) strict=1 action=strict-fail-closed"
        )
        await handleConnectionClosed(peer: peer, error: error)
    }

    private func stopP2PRealtimeAudioReceiverIfNeeded(peerId: String?) {
        if let peerId {
            let ownsInstalled = p2pRealtimeAudioReceiverReuseKey?.peerId == peerId
            let ownsPending = p2pRealtimeAudioReceiverPendingPeerId == peerId
            guard ownsInstalled || ownsPending else { return }
        }
        p2pRealtimeAudioReceiverStartGeneration &+= 1
        p2pRealtimeAudioReceiverPendingPeerId = nil
        guard p2pRealtimeAudioReceiver != nil || p2pRealtimeAudioRenderer != nil else { return }
        if #available(macOS 14.0, *) {
            let renderer = p2pRealtimeAudioRenderer
            renderer?.retire()
            p2pRealtimeAudioReceiver?.stop()
            if let renderer {
                Task(priority: .utility) {
                    await renderer.close(reason: "p2p-realtime-audio-stop")
                }
            }
            p2pRealtimeAudioReceiver = nil
            p2pRealtimeAudioRenderer = nil
            p2pRealtimeAudioReceiverReuseKey = nil
            p2pRealtimeAudioReceiverEndpoint = nil
        }
    }

    private func sendViewerStreamConfigurationIfPossible(to peer: PeerConnection) async {
        let settings = RemoteDesktopSettingsManager.shared.settings
        let dimensions = settings.displaySettings.resolution.dimensions
        let supportedVideoFormats = RemoteControlStreamRequestPolicy.supportedViewerVideoFormats()
        let mediaAudioMode = settings.displaySettings.lowLatencyMode
            ? SkyBridgeMediaAudioMode.lowLatency
            : SkyBridgeMediaAudioMode.highFidelity
        let audioRedirectionEnabled = settings.interactionSettings.enableAudioRedirection
        let mediaAudioEndpoint: SkyBridgeMediaEndpoint?
        if #available(macOS 14.0, *) {
            do {
                mediaAudioEndpoint = try await prepareP2PRealtimeAudioReceiverIfNeeded(
                    for: peer,
                    audioEnabled: audioRedirectionEnabled,
                    mode: mediaAudioMode
                )
            } catch {
                guard isCurrentPeer(peer) else { return }
                let failureAction = RemoteControlRealtimeMediaStartupPolicy.failureAction(
                    strictMediaFallbacks: true,
                    audioRedirectionEnabled: audioRedirectionEnabled,
                    realtimeMediaAudioRequested: audioRedirectionEnabled,
                    legacyAudioFallbackEnabled: false
                )
                let reason = Self.realtimeAudioStartupFailureReason(error)
                RemoteControlSmokeStatusWriter.append(
                    "audioRxReceiverStartFailed reason=\(reason) strict=\(failureAction == .failSession ? 1 : 0) action=\(failureAction == .failSession ? "strict-fail-closed" : "video-preserved")"
                )
                if failureAction == .failSession {
                    await handleConnectionClosed(peer: peer, error: error)
                    return
                }
                logger.warning(
                    "⚠️ P2P PQC media audio receiver unavailable; explicit non-strict video-only policy applied: reason=\(reason, privacy: .public)"
                )
                mediaAudioEndpoint = nil
            }
        } else {
            mediaAudioEndpoint = nil
        }
        let mediaSessionId: String?
        if #available(macOS 14.0, *) {
            mediaSessionId = peer.sessionKeys?.sessionId
        } else {
            mediaSessionId = nil
        }
        let realtimeMediaAudioReady = audioRedirectionEnabled
            && mediaAudioEndpoint != nil
            && mediaSessionId != nil
        let payload = RemoteDesktopStreamConfiguration(
            width: dimensions?.width,
            height: dimensions?.height,
            preferredCodec: settings.displaySettings.preferredCodec.rawValue,
            supportedVideoFormats: supportedVideoFormats,
            qualityPreset: settings.displaySettings.videoQuality.rawValue,
            videoCompressionLevel: settings.displaySettings.boundedCompressionLevelPercent,
            adaptiveResolutionEnabled: settings.displaySettings.resolution == .auto,
            targetFrameRate: settings.displaySettings.targetFrameRate,
            keyFrameInterval: settings.displaySettings.keyFrameInterval,
            lowLatencyMode: settings.displaySettings.lowLatencyMode,
            enableHardwareAcceleration: settings.displaySettings.enableHardwareAcceleration,
            enableAppleSiliconOptimization: settings.displaySettings.enableAppleSiliconOptimization,
            clipboardSyncEnabled: settings.interactionSettings.enableClipboardSync,
            damageTrackingEnabled: true,
            separateCursorChannelEnabled: true,
            interactionOverlayChannelEnabled: true,
            refreshStrategy: settings.displaySettings.lowLatencyMode ? "instant" : "balanced",
            jitterBufferFrames: settings.displaySettings.lowLatencyMode ? 1 : 2,
            lossRecoveryMode: settings.displaySettings.lowLatencyMode ? "fast-retransmit" : "balanced",
            screenFrameTransport: "sbrf-v1",
            screenDataChannelEnabled: true,
            screenChannelWireFormat: nil,
            nativeVideoTrackReady: false,
            nativeAudioTrackEnabled: false,
            audioRedirectionEnabled: realtimeMediaAudioReady,
            audioTransport: realtimeMediaAudioReady
                ? SkyBridgeRealtimeMediaConstants.audioTransportPQCv1
                : SkyBridgeRealtimeMediaConstants.audioTransportDisabled,
            audioMode: realtimeMediaAudioReady ? mediaAudioMode.rawValue : nil,
            mediaSessionId: realtimeMediaAudioReady ? mediaSessionId : nil,
            mediaAudioEndpoint: realtimeMediaAudioReady ? mediaAudioEndpoint : nil,
            compatibilityAudioFallbackEnabled: false,
            preferredAudioEncoding: nil,
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            mediaFallbackPolicy: "fail-fast",
            remoteControlSecurityIdentity: RemoteControlSecurityNoticeCenter.cachedLocalIdentitySnapshot(),
            streamConfigurationTransaction: RemoteDesktopStreamConfigurationTransaction(),
            // 多显示器开启时携带所选显示器（控制端选屏）；否则 nil = 主屏。
            captureDisplayID: settings.displaySettings.multiMonitorSupport
                ? settings.displaySettings.captureDisplayID : nil
        )

        do {
            try await sendRemoteControlPayload(payload, type: .streamConfiguration, to: peer)
            lastSentViewerStreamConfiguration = payload
            logger.info(
                """
                📤 已发送 macOS viewer 流配置: peer=\(peer.id, privacy: .public) \
                preferred=\(payload.preferredCodec ?? "auto", privacy: .public) \
                formats=\(supportedVideoFormats.joined(separator: ","), privacy: .public) \
                fps=\(payload.targetFrameRate, privacy: .public) \
                audio=\(payload.audioRedirectionEnabled == true, privacy: .public)
                """
            )
        } catch {
            logger.warning(
                "⚠️ 发送 macOS viewer 流配置失败: peer=\(peer.id, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func effectiveRemoteVideoFormats(for peer: PeerConnection) -> Set<String> {
        if let config = peer.requestedStreamConfiguration,
           config.preferredCodec?.lowercased() == "jpeg" {
            return ["jpeg"]
        }

        var formats = peer.remoteVideoFormats
        if let config = peer.requestedStreamConfiguration {
            formats.formUnion(config.supportedVideoFormats.map { $0.lowercased() })
            if let preferred = config.preferredCodec?.lowercased(),
               preferred == "h264" || preferred == "hevc" || preferred == "jpeg" {
                formats.insert(preferred)
            }
        }
        return formats
    }

    private func effectiveStreamRequest(for peer: PeerConnection) -> RemoteControlStreamRequest {
        RemoteControlStreamRequestPolicy.request(
            streamConfiguration: peer.requestedStreamConfiguration,
            settings: RemoteDesktopSettingsManager.shared.settings.displaySettings
        )
    }

    private func configureClipboardSync(for peer: PeerConnection) {
        guard isCurrentPeer(peer) else { return }
        guard peer.role != .beingControlled || peer.securityAdmissionApproved else {
            disableClipboardSyncIfActive(for: peer.id)
            RemoteControlSmokeStatusWriter.append(
                "remoteControlClipboardSyncBlocked session=\(peer.id) transport=p2p reason=awaiting_security_notice"
            )
            return
        }
        let shouldEnable = peer.requestedStreamConfiguration?.clipboardSyncEnabled
            ?? RemoteDesktopSettingsManager.shared.settings.interactionSettings.enableClipboardSync

        if shouldEnable {
            activeClipboardPeerId = peer.id
            let clipboard = ClipboardRedirectionManager.shared
            clipboard.enable(for: peer.clipboardSessionId)
            clipboard.onLocalClipboardChanged = { [weak self] data, mimeType in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeClipboardPeerId == peer.id else { return }
                    await self.sendClipboardPayload(data: data, mimeType: mimeType, to: peer.id)
                }
            }
        } else if activeClipboardPeerId == peer.id {
            let clipboard = ClipboardRedirectionManager.shared
            clipboard.onLocalClipboardChanged = nil
            clipboard.disable()
            activeClipboardPeerId = nil
        }
    }

    private func disableClipboardSyncIfActive(for deviceId: String) {
        guard activeClipboardPeerId == deviceId else { return }
        let clipboard = ClipboardRedirectionManager.shared
        clipboard.onLocalClipboardChanged = nil
        clipboard.disable()
        activeClipboardPeerId = nil
    }

    private func sendClipboardPayload(data: Data, mimeType: String, to deviceId: String) async {
        guard let peer = currentPeer(for: .beingControlled, deviceId: deviceId) else { return }
        guard peer.role != .beingControlled || peer.securityAdmissionApproved else {
            RemoteControlSmokeStatusWriter.append(
                "remoteControlClipboardSendBlocked session=\(peer.id) transport=p2p reason=awaiting_security_notice"
            )
            return
        }
        do {
            try await sendRemoteControlPayload(
                RemoteClipboardPayload(mimeType: mimeType, data: data),
                type: .clipboard,
                to: peer
            )
        } catch {
            logger.error("❌ 会话剪贴板发送失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var remoteControlBuildFingerprint: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "-"
        let build = (info["CFBundleVersion"] as? String) ?? "-"
        let bundleId = Bundle.main.bundleIdentifier ?? "-"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return "bundle=\(bundleId) version=\(version) build=\(build) os=\(osVersion)"
    }

    private static func codecName(_ codec: RemoteFrameType) -> String {
        switch codec {
        case .bgra: return "jpeg"
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }

 /// 控制端：从对端接收屏幕数据并渲染
    private func startReceivingScreenData(from peer: PeerConnection) {
        logger.info("📺 开始接收屏幕数据 <- \(peer.id, privacy: .public)")

        Task { [weak self, weak peer] in
            guard let self, let peer else { return }
            var buffer = Data()

            while true {
                do {
                    let chunk = try await self.receiveChunk(from: peer.connection)
                    if chunk.isEmpty {
                        throw RemoteControlError.connectionClosed
                    }
                    buffer.append(chunk)
                    if buffer.count > RemoteControlWireLimits.maxWireMessageBytes(for: self.maxFramedMessageBytes) * 2 {
                        throw RemoteControlError.invalidMessageLength(buffer.count)
                    }

                    guard self.isCurrentPeer(peer) else { break }

                    while let messageData = try self.nextFramedMessage(
                        from: &buffer,
                        maxMessageBytes: self.maxFramedMessageBytes
                    ) {
                        if #available(macOS 14.0, *),
                           let driver = peer.handshakeDriver,
                           let handshakePeer = peer.handshakePeer {
                            await driver.handleMessage(messageData, from: handshakePeer)
                            let syncResult = try await self.syncSecureChannelState(after: driver, for: peer)
                            if case .retryableFailure = syncResult {
                                continue
                            }
                            guard peer.sessionKeys != nil else {
                                continue
                            }
                        } else if #available(macOS 14.0, *),
                                  peer.sessionKeys == nil,
                                  !Self.allowsInsecureLegacyRemoteControl {
                            throw RemoteControlError.handshakeInitializationFailed("rejected pre-auth screen payload")
                        }

                        let plain: Data
                        if #available(macOS 14.0, *), let keys = peer.sessionKeys {
                            let decryptResult = try self.decryptRemotePayload(
                                messageData,
                                with: keys,
                                replayWindow: &peer.secureEnvelopeReplayWindow,
                                allowedPacketTypes: [.screen, .audio]
                            )
                            switch decryptResult {
                            case .payload(let payload):
                                plain = payload
                            case .replayDrop(let drop):
                                self.logRemoteSecureReplayDrop(drop, peer: peer)
                                continue
                            }
                        } else {
                            plain = messageData
                        }
                        guard self.isCurrentPeer(peer) else { break }
                        try await self.handleScreenMessagePayload(plain)
                    }
                } catch {
                    await self.handleConnectionClosed(peer: peer, error: error)
                    break
                }
            }
        }
    }

 /// 处理收到的 .screenData 消息
    private func handleScreenMessagePayload(_ messageData: Data) async throws {
        if let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(messageData) {
            handleInboundRemoteAudioChunk(audioChunk)
            return
        }

        if let screenData = RemoteDesktopScreenFrameWire.decodeIfPresent(messageData) {
            try await handleInboundScreenData(
                ScreenData(
                    width: screenData.width,
                    height: screenData.height,
                    imageData: screenData.imageData,
                    timestamp: screenData.timestamp,
                    format: screenData.format,
                    isSyncFrame: screenData.isSyncFrame,
                    sequenceNumber: screenData.sequenceNumber
                )
            )
            return
        }

        let message = try JSONDecoder().decode(RemoteMessage.self, from: messageData)
        switch message.type {
        case .screenData:
            let screenData = try JSONDecoder().decode(ScreenData.self, from: message.payload)
            try await handleInboundScreenData(screenData)
        case .damageReport:
            let report = try JSONDecoder().decode(RemoteDesktopDamageReport.self, from: message.payload)
            stableRenderer.setDamageReport(report)
        default:
            logger.debug("📺 收到非 screenData 消息，丢弃: \(message.type.rawValue, privacy: .public)")
        }
    }

    private func handleInboundRemoteAudioChunk(_ payload: RemoteDesktopAudioChunkPayload) {
        guard RemoteDesktopSettingsManager.shared.settings.interactionSettings.enableAudioRedirection else {
            return
        }
        guard lastSentViewerStreamConfiguration?.allowsLegacyAudioChunkFallback == true else {
            logger.debug("ℹ️ 已丢弃 legacy P2P 远控音频块：当前会话要求 PQC media plane")
            return
        }
        if let lastViewingInboundScreenTimestamp,
           payload.sentAt + 0.45 < lastViewingInboundScreenTimestamp {
            return
        }

        do {
            try AudioRedirectionManager.shared.enable(for: viewingAudioSessionId)
            AudioRedirectionManager.shared.updateRemoteVideoTimestamp(lastViewingInboundScreenTimestamp)
            AudioRedirectionManager.shared.playRemoteAudioChunk(payload)
        } catch {
            logger.error("❌ 播放远控音频失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleInboundScreenData(_ screenData: ScreenData) async throws {
        logger.debug("📺 接收到屏幕数据: \(screenData.width)x\(screenData.height)")
        lastViewingInboundScreenTimestamp = screenData.timestamp
        AudioRedirectionManager.shared.updateRemoteVideoTimestamp(screenData.timestamp)

        guard !screenData.imageData.isEmpty else { return }
        configureViewingRenderersIfNeeded()

        if let fmt = screenData.format?.lowercased(), fmt == "hevc" || fmt == "h264" || fmt == "bgra" {
            let frameType: RemoteFrameType
            switch fmt {
            case "hevc": frameType = .hevc
            case "h264": frameType = .h264
            default: frameType = .bgra
            }

            let metrics: RenderMetrics
            switch renderingModeController.currentMode {
            case .stable:
                metrics = stableRenderer.processFrame(
                    data: screenData.imageData,
                    width: screenData.width,
                    height: screenData.height,
                    stride: 0,
                    type: frameType
                )
            case .fluid:
                metrics = fluidRenderer.processFrame(
                    data: screenData.imageData,
                    width: screenData.width,
                    height: screenData.height,
                    stride: 0,
                    type: frameType
                )
                // Fluid 模式下也触发拉帧，保证 texture 输出到 textureFeed
                let fluidRendered = fluidRenderer.pullAndRender()
                evaluateHighPerformanceRenderHealth(afterPullFor: .fluid, rendered: fluidRendered)
            case .reference:
                metrics = referenceRenderer.processFrame(
                    data: screenData.imageData,
                    width: screenData.width,
                    height: screenData.height,
                    stride: 0,
                    type: frameType
                )
                let refRendered = referenceRenderer.pullAndRender()
                evaluateHighPerformanceRenderHealth(afterPullFor: .reference, rendered: refRendered)
            }
            await MainActor.run {
                self.updateMetrics(metrics)
            }
        } else {
 // 兜底：静态图像通过 StableRenderer 处理
            switch renderingModeController.currentMode {
            case .stable:
                let metrics = stableRenderer.processStaticImage(data: screenData.imageData)
                await MainActor.run {
                    self.updateMetrics(metrics)
                }
            case .fluid, .reference:
                await handleStaticImageFallback(screenData)
            }
        }
    }

 /// 静态图像兜底路径：ImageIO -> CGImage -> MTLTexture -> 纹理流
    private func handleStaticImageFallback(_ screenData: ScreenData) async {
        guard let device = metalDevice else { return }

        let cfData = screenData.imageData as CFData
        guard
            let source = CGImageSourceCreateWithData(cfData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            logger.error("❌ 图像数据解析失败（静态兜底）")
            return
        }

        do {
            let texture = try createTexture(from: cgImage, device: device)
            await MainActor.run {
                self.textureFeed.update(texture: texture)
                self.bandwidthMbps = 0
                self.latencyMs = 0
                self.estimatedFPS = 0
            }
        } catch {
            logger.error("❌ 静态图像转纹理失败: \(error.localizedDescription, privacy: .public)")
        }
    }

 // MARK: - 被控制端：接收远程事件

    private func startReceivingRemoteEvents(from peer: PeerConnection, initialData: Data? = nil) {
        logger.info("🎮 开始接收远程事件 <- \(peer.id, privacy: .public)")

        Task { [weak self, weak peer] in
            guard let self, let peer else { return }
            var buffer = Data()
            var pendingInitialData = initialData

            while true {
                do {
                    if let initialData = pendingInitialData {
                        pendingInitialData = nil
                        let shouldContinue = try await self.processInboundRemoteEventChunk(
                            initialData,
                            from: peer,
                            buffer: &buffer
                        )
                        if !shouldContinue { break }
                    }

                    let chunk = try await self.receiveChunk(from: peer.connection)
                    let shouldContinue = try await self.processInboundRemoteEventChunk(
                        chunk,
                        from: peer,
                        buffer: &buffer
                    )
                    if !shouldContinue { break }
                } catch {
                    await self.handleConnectionClosed(peer: peer, error: error)
                    break
                }
            }
        }
    }

    private func processInboundRemoteEventChunk(
        _ chunk: Data,
        from peer: PeerConnection,
        buffer: inout Data
    ) async throws -> Bool {
        if chunk.isEmpty {
            throw RemoteControlError.connectionClosed
        }
        buffer.append(chunk)
        emitSmokeTrace("mac remote chunk peer=\(peer.id) bytes=\(chunk.count) buffered=\(buffer.count)")
        if buffer.count > RemoteControlWireLimits.maxWireMessageBytes(for: maxFramedMessageBytes) * 2 {
            throw RemoteControlError.invalidMessageLength(buffer.count)
        }

        guard isCurrentPeer(peer) else { return false }

        while let messageData = try nextFramedMessage(
            from: &buffer,
            maxMessageBytes: maxFramedMessageBytes
        ) {
            emitSmokeTrace("mac remote framed peer=\(peer.id) bytes=\(messageData.count)")
            try await handleInboundRemoteFrame(from: peer, frame: messageData)
        }
        return true
    }

    private func handleInboundRemoteFrame(from peer: PeerConnection, frame: Data) async throws {
        guard isCurrentPeer(peer) else { return }
        if #available(macOS 14.0, *) {
            let secure = peer.sessionKeys != nil
            let hasDriver = peer.handshakeDriver != nil
            logger.info(
                "🔐 RemoteControl frame: peer=\(peer.id, privacy: .public) bytes=\(frame.count, privacy: .public) secure=\(secure, privacy: .public) driver=\(hasDriver, privacy: .public)"
            )
            emitSmokeTrace("mac remote frame peer=\(peer.id) bytes=\(frame.count) secure=\(secure) driver=\(hasDriver)")
        }
        // If handshake established, frames become AES-GCM ciphertext of RemoteMessage JSON.
        if #available(macOS 14.0, *), let keys = peer.sessionKeys {
            let decryptResult = try decryptRemotePayload(
                frame,
                with: keys,
                replayWindow: &peer.secureEnvelopeReplayWindow,
                allowedPacketTypes: [.control]
            )
            let plain: Data
            switch decryptResult {
            case .payload(let payload):
                plain = payload
            case .replayDrop(let drop):
                logRemoteSecureReplayDrop(drop, peer: peer)
                return
            }
            do {
                try await handleControlMessagePayload(plain, from: peer)
            } catch let error as DecodingError {
                logDroppedMalformedControlPayload(error, from: peer, secure: true, bytes: plain.count)
            }
            return
        }

        if #available(macOS 14.0, *), peer.handshakeDriver == nil {
            if let messageA = try? HandshakeMessageA.decode(from: frame) {
                let suiteSummary = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
                logger.info("🔐 RemoteControl received MessageA: peer=\(peer.id, privacy: .public) suites=\(suiteSummary, privacy: .public)")
                emitSmokeTrace("mac remote rx MessageA peer=\(peer.id) suites=\(suiteSummary)")
                do {
                    peer.handshakeDriver = try await makeInboundHandshakeDriver(
                        for: peer,
                        messageA: messageA
                    )
                    logger.info("🔐 RemoteControl inbound handshake driver ready for \(peer.id, privacy: .public)")
                } catch {
                    emitSmokeTrace("mac remote inbound-init-failed peer=\(peer.id) reason=\(error.localizedDescription)")
                    logger.error("❌ RemoteControl inbound handshake init failed for \(peer.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    if Self.shouldKeepTransportAliveAfterHandshakeFailure(for: peer.role) {
                        emitSmokeTrace("mac remote inbound-init-retry peer=\(peer.id) reason=\(error.localizedDescription)")
                        peer.handshakeDriver = nil
                        return
                    }
                    throw error
                }
            } else if Self.allowsInsecureLegacyRemoteControl,
                      let _ = try? JSONDecoder().decode(RemoteMessage.self, from: frame) {
                do {
                    try await handleControlMessagePayload(frame, from: peer)
                } catch let error as DecodingError {
                    logDroppedMalformedControlPayload(error, from: peer, secure: false, bytes: frame.count)
                }
                return
            } else {
                throw RemoteControlError.handshakeInitializationFailed("rejected pre-auth control payload")
            }
        }

        if #available(macOS 14.0, *), let driver = peer.handshakeDriver, let hPeer = peer.handshakePeer {
            await driver.handleMessage(frame, from: hPeer)
            let syncResult = try await syncSecureChannelState(after: driver, for: peer)
            if case .retryableFailure = syncResult {
                return
            }
            return
        }
    }

    private func logDroppedMalformedControlPayload(
        _ error: DecodingError,
        from peer: PeerConnection,
        secure: Bool,
        bytes: Int
    ) {
        logger.warning(
            """
            ⚠️ 已丢弃无法解析的远控消息: peer=\(peer.id, privacy: .public) \
            secure=\(secure, privacy: .public) \
            bytes=\(bytes, privacy: .public) \
            error=\(String(reflecting: error), privacy: .public)
            """
        )
    }

    private func waitForSecureChannelIfNeeded(
        for peer: PeerConnection,
        timeoutSeconds: TimeInterval = 30.0
    ) async -> SecureChannelWaitResult {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !isCurrentPeer(peer) {
                logger.info("ℹ️ RemoteControl secure-channel wait aborted for stale peer \(peer.id, privacy: .public)")
                return .aborted("secure channel aborted: stale peer")
            }
            if peer.sessionKeys != nil {
                logger.info("🔐 RemoteControl secure channel ready: peer=\(peer.id, privacy: .public)")
                emitSmokeTrace("mac remote secure-ready peer=\(peer.id)")
                return .established
            }
            if Self.allowsInsecureLegacyRemoteControl {
                logger.notice("🔓 RemoteControl legacy plaintext mode enabled for \(peer.id, privacy: .public)")
                return .established
            }
            if currentPeer(for: peer.role, deviceId: peer.id) == nil {
                return .aborted("secure channel aborted: peer closed before establishment")
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return .aborted("secure channel establishment cancelled")
            }
        }
        emitSmokeTrace("mac remote secure-timeout peer=\(peer.id)")
        return peer.sessionKeys != nil ? .established : .timedOut
    }

    @available(macOS 14.0, *)
    private func makeInboundHandshakeDriver(
        for peer: PeerConnection,
        messageA: HandshakeMessageA
    ) async throws -> HandshakeDriver {
        let trustedPeerId: String
        switch RemoteControlInboundTrustResolver.resolve(
            remoteSOAPeerId: messageA.soaExtension?.initiatorPeerId,
            records: TrustSyncService.shared.activeTrustRecords
        ) {
        case .resolved(let deviceId, _):
            trustedPeerId = deviceId
        case .missing:
            throw RemoteControlError.untrustedPeer(peer.id)
        case .ambiguous(let deviceIds, let fingerprints):
            let summary = [
                "deviceIds=\(deviceIds.joined(separator: ","))",
                "fingerprints=\(fingerprints.joined(separator: ","))"
            ].joined(separator: " ")
            throw RemoteControlError.handshakeInitializationFailed(
                "ambiguous trusted inbound remote-control identity: \(summary)"
            )
        }
        let localDeviceId = try await SelfIdentityProvider.shared
            .protocolIdentityDeviceId(allowCreate: true)
        guard let soaBinding = Self.remoteControlSOABinding(
            localDeviceId: localDeviceId,
            remoteDeviceId: trustedPeerId
        ) else {
            throw RemoteControlError.handshakeInitializationFailed(
                "inbound remote control handshake missing stable SOA identities"
            )
        }
        let soaPairKey = PeerSessionArbiter.pairKey(
            localPeerId: soaBinding.localPeerId,
            remotePeerId: soaBinding.expectedRemotePeerId,
            scope: .remoteControl
        )
        recordSOAState(soaPairKey, for: peer)
        try await releaseStaleSOAStateBeforeHandshake(for: peer)
        peer.handshakePeer = PeerIdentifier(deviceId: trustedPeerId, displayName: nil, address: nil)
        let trustProvider = try await makeRemoteControlTrustProvider(for: trustedPeerId)
        #if !os(macOS)
        let peerHasClassicGroup = messageA.supportedSuites.contains { !$0.isPQCGroup }
        #endif
        let configuration = try await SettingsManager.shared
            .committedProtocolIdentityConfiguration()
        let inboundProtocolIdentity = try InboundProtocolIdentitySelectionPolicy.resolve(
            messageA: messageA,
            candidateDeviceIds: [trustedPeerId],
            activeLocalAlgorithm: configuration.algorithm,
            activeLocalProtection: configuration.protection
        )
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let requestedPolicy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        let capability = CryptoProviderFactory.detectCapability()
        let localPQCAvailable = capability.hasApplePQC || capability.hasLiboqs

        var effectivePolicy = requestedPolicy
        var cryptoProvider: any CryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
        var sigAAlgorithm: ProtocolSigningAlgorithm = .ed25519
        var offeredSuites: [CryptoSuite] = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }

        if let rejection = StrictPQCAdmissionGate.inboundRejection(
            policy: requestedPolicy,
            peerSupportedSuites: messageA.supportedSuites,
            localPQCSuitesAvailable: localPQCAvailable
        ), rejection == .peerOfferedClassicOnly {
            throw RemoteControlError.handshakeInitializationFailed(rejection.diagnosticMessage)
        }

        if inboundProtocolIdentity.algorithm != .ed25519 {
            let pqcSelection: CryptoProviderFactory.SelectionPolicy = requestedPolicy.requirePQC ? .requirePQC : .preferPQC
            cryptoProvider = CryptoProviderFactory.makeInboundPQCResponderProvider(
                policy: pqcSelection,
                peerSupportedSuites: messageA.supportedSuites
            )
            let localPQCSuites = CryptoProviderFactory.handshakeOfferedPQCSuites(using: cryptoProvider)

            if let rejection = StrictPQCAdmissionGate.inboundRejection(
                policy: requestedPolicy,
                peerSupportedSuites: messageA.supportedSuites,
                localPQCSuitesAvailable: !localPQCSuites.isEmpty
            ) {
                throw RemoteControlError.handshakeInitializationFailed(rejection.diagnosticMessage)
            }

            if localPQCSuites.isEmpty {
                #if os(macOS)
                throw InboundProtocolIdentitySelectionError.noCompatibleResponderSuite(
                    inboundProtocolIdentity.algorithm
                )
                #else
                if requestedPolicy.requirePQC {
                    throw RemoteControlError.handshakeInitializationFailed(
                        "strictPQC enabled but local PQC provider is unavailable"
                    )
                }
                guard peerHasClassicGroup else {
                    throw RemoteControlError.handshakeInitializationFailed(
                        "peer offered PQC-only suites but local PQC provider is unavailable"
                    )
                }
                cryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
                sigAAlgorithm = .ed25519
                offeredSuites = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
                effectivePolicy = HandshakePolicy(
                    requirePQC: false,
                    allowClassicFallback: false,
                    minimumTier: .classic,
                    requireSecureEnclavePoP: requestedPolicy.requireSecureEnclavePoP
                )
                logger.info("🧩 RemoteControl inbound fallback(classic): local PQC unavailable for \(peer.id, privacy: .public)")
                #endif
            } else {
                let compatibleSuites = InboundProtocolIdentitySelectionPolicy
                    .compatibleResponderPQCSuites(
                        localPQCSuites,
                        algorithm: inboundProtocolIdentity.algorithm
                    )
                guard !compatibleSuites.isEmpty else {
                    throw InboundProtocolIdentitySelectionError.noCompatibleResponderSuite(
                        inboundProtocolIdentity.algorithm
                    )
                }
                sigAAlgorithm = inboundProtocolIdentity.algorithm
                offeredSuites = compatibleSuites
            }
        } else {
            if requestedPolicy.requirePQC {
                throw RemoteControlError.handshakeInitializationFailed(
                    "strictPQC enabled but peer offered classic-only suites"
                )
            }
            cryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
            sigAAlgorithm = .ed25519
            offeredSuites = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
            effectivePolicy = HandshakePolicy(
                requirePQC: false,
                allowClassicFallback: false,
                minimumTier: .classic,
                requireSecureEnclavePoP: requestedPolicy.requireSecureEnclavePoP
            )
        }

        let identityProvider = DeviceIdentityHandshakeProvider(
            sigAAlgorithm: sigAAlgorithm,
            protocolSigningKeyProtection: inboundProtocolIdentity.protection,
            includeSecureEnclavePoP: effectivePolicy.requireSecureEnclavePoP
        )
        let peerSuitesSummary = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
        let localSuitesSummary = offeredSuites.map(\.rawValue).joined(separator: ",")
        let providerName = String(describing: type(of: cryptoProvider))
        let cryptoPolicy = HandshakeCryptoPolicyResolver.policy(for: offeredSuites)
        logger.info(
            "🔐 RemoteControl driver selection: peer=\(peer.id, privacy: .public) peerSuites=\(peerSuitesSummary, privacy: .public) localSuites=\(localSuitesSummary, privacy: .public) provider=\(providerName, privacy: .public) sigA=\(sigAAlgorithm.rawValue, privacy: .public) requirePQC=\(effectivePolicy.requirePQC, privacy: .public)"
        )
        emitSmokeTrace("mac remote driver peer=\(peer.id) peerSuites=\(peerSuitesSummary) localSuites=\(localSuitesSummary) provider=\(providerName) sigA=\(sigAAlgorithm.rawValue) requirePQC=\(effectivePolicy.requirePQC)")
        let transport = RemoteControlHandshakeTransport(connection: peer.connection)
        return try HandshakeDriver(
            transport: transport,
            cryptoProvider: cryptoProvider,
            protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: sigAAlgorithm),
            identityProvider: identityProvider,
            sigAAlgorithm: sigAAlgorithm,
            offeredSuites: offeredSuites,
            policy: effectivePolicy,
            cryptoPolicy: cryptoPolicy,
            trustProvider: trustProvider,
            localSOAPeerId: soaBinding.localPeerId,
            expectedRemoteSOAPeerId: soaBinding.expectedRemotePeerId,
            soaSessionScope: .remoteControl
        )
    }

    private func handleControlMessagePayload(_ messageData: Data, from peer: PeerConnection) async throws {
        guard isCurrentPeer(peer) else { return }
        let message = try JSONDecoder().decode(RemoteMessage.self, from: messageData)
        let isPreApprovalStreamConfiguration = message.type == .streamConfiguration
            && peer.role == .beingControlled
            && !peer.securityAdmissionApproved
        guard isPreApprovalStreamConfiguration || RemoteControlSecurityAdmissionPolicy.allowsInboundPayload(
            message.type,
            isApproved: peer.role != .beingControlled || peer.securityAdmissionApproved
        ) else {
            logger.warning(
                "⛔️ 未经批准的远控控制消息被阻断: peer=\(peer.id, privacy: .public) type=\(message.type.rawValue, privacy: .public)"
            )
            RemoteControlSmokeStatusWriter.append(
                "remoteControlPayloadBlocked session=\(peer.id) transport=p2p type=\(message.type.rawValue)"
            )
            return
        }

        switch message.type {
        case .mouseEvent:
            guard peer.requestedStreamConfiguration?.isStopRequest == false else {
                throw RemoteControlError.handshakeInitializationFailed(
                    "mouse input arrived before acknowledged stream configuration"
                )
            }
            let evt = try JSONDecoder().decode(RemoteMouseEvent.self, from: message.payload)
            await handleRemoteMouseEvent(evt)
        case .keyboardEvent:
            guard peer.requestedStreamConfiguration?.isStopRequest == false else {
                throw RemoteControlError.handshakeInitializationFailed(
                    "keyboard input arrived before acknowledged stream configuration"
                )
            }
            let evt = try JSONDecoder().decode(RemoteKeyboardEvent.self, from: message.payload)
            await handleRemoteKeyboardEvent(evt)
        case .screenData:
 // 正常情况下，被控制端不会收到 screenData；有就丢掉
            logger.debug("🎮 被控制端收到 screenData，忽略")
        case .clipboard:
            guard let acceptedConfiguration = peer.requestedStreamConfiguration,
                  !acceptedConfiguration.isStopRequest else {
                throw RemoteControlError.handshakeInitializationFailed(
                    "clipboard arrived before acknowledged stream configuration"
                )
            }
            let shouldAcceptClipboard = acceptedConfiguration.clipboardSyncEnabled
            logger.debug(
                "📋 收到远控剪贴板消息: peer=\(peer.id, privacy: .public) enabled=\(shouldAcceptClipboard, privacy: .public) bytes=\(message.payload.count, privacy: .public)"
            )
            guard shouldAcceptClipboard else { break }
            let payload = try JSONDecoder().decode(RemoteClipboardPayload.self, from: message.payload)
            let clipboard = ClipboardRedirectionManager.shared
            clipboard.enable(for: peer.clipboardSessionId)
            clipboard.setRemoteClipboard(data: payload.data, mimeType: payload.mimeType)
        case .streamConfiguration:
            let config = try JSONDecoder().decode(RemoteDesktopStreamConfiguration.self, from: message.payload)
            if peer.role == .beingControlled {
                recordRemoteControlSecurityIdentity(
                    config.remoteControlSecurityIdentity,
                    from: "streamConfiguration",
                    for: peer
                )
            }
            guard peer.role != .beingControlled || peer.securityAdmissionApproved else {
                let decision = RemoteDesktopStreamConfigurationTransactionPolicy
                    .ingressDecision(
                        incoming: config.streamConfigurationTransaction,
                        lastAccepted: peer.pendingRequestedStreamConfiguration?
                            .streamConfigurationTransaction,
                        payloadMatchesLastAccepted:
                            peer.pendingRequestedStreamConfiguration == config
                    )
                switch decision {
                case .apply:
                    peer.pendingRequestedStreamConfiguration = config
                case .acknowledgeDuplicate:
                    break
                case .rejectMissingTransaction, .rejectConflictingDuplicate:
                    throw RemoteControlError.handshakeInitializationFailed(
                        "invalid stream configuration transaction: \(String(describing: decision))"
                    )
                }
                logger.info(
                    "⏳ viewer 流配置已暂存，等待远控安全提示批准后再应用: peer=\(peer.id, privacy: .public)"
                )
                RemoteControlSmokeStatusWriter.append(
                    "remoteControlStreamConfigDeferred session=\(peer.id) transport=p2p reason=awaiting_security_notice"
                )
                break
            }
            try await applyViewerStreamConfiguration(config, for: peer)
        case .streamConfigurationAck:
            _ = try JSONDecoder().decode(
                RemoteDesktopStreamConfigurationAcknowledgement.self,
                from: message.payload
            )
        case .damageReport, .cursorUpdate, .overlayUpdate:
            guard peer.requestedStreamConfiguration?.isStopRequest == false else {
                throw RemoteControlError.handshakeInitializationFailed(
                    "remote media metadata arrived before acknowledged stream configuration"
                )
            }
        }
    }

    private func applyViewerStreamConfiguration(
        _ config: RemoteDesktopStreamConfiguration,
        for peer: PeerConnection
    ) async throws {
        guard isCurrentPeer(peer) else { return }
        let decision = RemoteDesktopStreamConfigurationTransactionPolicy
            .ingressDecision(
                incoming: config.streamConfigurationTransaction,
                lastAccepted: peer.lastAcceptedRawStreamConfiguration?
                    .streamConfigurationTransaction,
                payloadMatchesLastAccepted:
                    peer.lastAcceptedRawStreamConfiguration == config
            )
        switch decision {
        case .acknowledgeDuplicate:
            guard let effectiveConfig = peer.requestedStreamConfiguration else {
                throw RemoteControlError.handshakeInitializationFailed(
                    "duplicate stream configuration has no accepted state"
                )
            }
            guard try await sendStreamConfigurationAcknowledgement(
                for: effectiveConfig,
                transaction: config.streamConfigurationTransaction,
                to: peer
            ) else { return }
            return
        case .rejectMissingTransaction, .rejectConflictingDuplicate:
            throw RemoteControlError.handshakeInitializationFailed(
                "invalid stream configuration transaction: \(String(describing: decision))"
            )
        case .apply:
            break
        }

        let previousConfig = peer.requestedStreamConfiguration
        let previousRawConfig = peer.lastAcceptedRawStreamConfiguration
        let effectiveConfig = RemoteControlStreamRequestPolicy
            .streamConfigurationByPreservingAudioEndpointForVideoRefresh(
                config,
                previous: previousConfig
            )
        peer.streamConfigurationApplicationGeneration &+= 1
        let applicationGeneration = peer.streamConfigurationApplicationGeneration

        // ACK is the commit receipt for this stream operation. Do not detach senders, publish the
        // configuration, enable the pump, or start capture until the exact ACK was sent.
        guard try await sendStreamConfigurationAcknowledgement(
            for: effectiveConfig,
            transaction: config.streamConfigurationTransaction,
            to: peer
        ) else { return }
        guard isCurrentPeer(peer),
              peer.streamConfigurationApplicationGeneration == applicationGeneration,
              peer.lastAcceptedRawStreamConfiguration == previousRawConfig,
              peer.requestedStreamConfiguration == previousConfig else {
            return
        }

        let supersededInFlightStart = screenSharingAttemptGate
            .supersedeInFlightAttemptAndRequestRestart(for: peer.id)
        let supersededSender = supersededInFlightStart
            ? detachRealtimeAudioSender(from: peer)
            : nil
        peer.lastAcceptedRawStreamConfiguration = config
        if config.mediaAudioEndpoint == nil,
           effectiveConfig.mediaAudioEndpoint != nil,
           config.streamRefreshToken != nil {
            RemoteControlSmokeStatusWriter.append(
                "audioEndpointPreservedForVideoRefresh peer=\(peer.id) refreshTokenState=\(Self.streamRefreshTokenLogState(config.streamRefreshToken))"
            )
        }
        peer.requestedStreamConfiguration = effectiveConfig
        peer.remoteVideoFormats = effectiveRemoteVideoFormats(for: peer)
        if let supersededSender {
            await supersededSender.close(
                reason: "stream-configuration-superseded-in-flight-start"
            )
            guard isCurrentPeer(peer),
                  peer.streamConfigurationApplicationGeneration == applicationGeneration,
                  peer.lastAcceptedRawStreamConfiguration?.streamConfigurationTransaction
                    == config.streamConfigurationTransaction else {
                return
            }
        }
        await syncOutboundFramePump(for: peer)
        guard isCurrentPeer(peer),
              peer.streamConfigurationApplicationGeneration == applicationGeneration,
              peer.lastAcceptedRawStreamConfiguration?.streamConfigurationTransaction
                == config.streamConfigurationTransaction else {
            return
        }
            if effectiveConfig.isStopRequest {
                configureClipboardSync(for: peer)
                await stopScreenSharingForViewerStop(peer: peer, reason: "viewer-stream-configuration")
                logger.info(
                    "🎛️ 应用 viewer 停止流配置: peer=\(peer.id, privacy: .public) previousTransport=\(previousConfig?.screenFrameTransport ?? "none", privacy: .public)"
                )
                return
            }
            logger.info(
                "🎛️ 应用 viewer 流配置: peer=\(peer.id, privacy: .public) first=\(previousConfig == nil, privacy: .public) screenSharingActive=\(self.screenSharingActive, privacy: .public) transport=\(effectiveConfig.screenFrameTransport ?? "legacy", privacy: .public)"
            )
            logger.info(
                """
                🎛️ 收到远控流策略: preset=\(effectiveConfig.qualityPreset ?? "unknown", privacy: .public) \
                damage=\(effectiveConfig.damageTrackingEnabled ?? false, privacy: .public) \
                cursor=\(effectiveConfig.separateCursorChannelEnabled ?? false, privacy: .public) \
                overlay=\(effectiveConfig.interactionOverlayChannelEnabled ?? false, privacy: .public) \
                jitter=\(effectiveConfig.jitterBufferFrames ?? 0, privacy: .public) \
                recovery=\(effectiveConfig.lossRecoveryMode ?? "unknown", privacy: .public)
                """
            )
            RemoteControlSmokeStatusWriter.append(
                """
                mac-stream-config peer=\(peer.id) \
                session_ref=\(peer.sessionKeys.flatMap { P2PEvidenceReference.sessionIncarnation(sessionID: $0.sessionId, transcriptHash: $0.transcriptHash) } ?? "-") \
                stream_ref=\(effectiveConfig.streamConfigurationTransaction.map { P2PEvidenceReference.transaction($0.id) } ?? "-") \
                transport=\(effectiveConfig.screenFrameTransport ?? "legacy") \
                codec=\(effectiveConfig.preferredCodec ?? "auto") fps=\(effectiveConfig.targetFrameRate) \
                damage=\(effectiveConfig.damageTrackingEnabled ?? false) \
                perf=\(effectiveConfig.performanceValidationMode ?? "normal") \
                fallback=\(effectiveConfig.mediaFallbackPolicy ?? "default") \
                audioEndpoint=\(effectiveConfig.mediaAudioEndpoint == nil ? "missing" : "present") \
                refreshTokenState=\(Self.streamRefreshTokenLogState(effectiveConfig.streamRefreshToken))
                """
            )
            configureClipboardSync(for: peer)
            if !screenSharingActive {
                await startScreenSharing(to: peer)
            } else {
                let requiresRestart = RemoteControlStreamRequestPolicy.shouldRestartCapture(
                    previous: previousConfig,
                    current: effectiveConfig
                )
                let requestedRefresh = effectiveConfig.streamRefreshToken != previousConfig?.streamRefreshToken
                if requiresRestart {
                    if previousConfig != nil, peer.captureCompatibilityOverride != nil {
                        logger.info(
                            "ℹ️ viewer 流配置已变化，清除当前会话的编码兼容性降级: peer=\(peer.id, privacy: .public)"
                        )
                        peer.captureCompatibilityOverride = nil
                    }
                    captureStreamer?.stop()
                    captureStreamer = nil
                    await startScreenSharing(to: peer)
                } else if requestedRefresh {
                    let now = Date()
                    if now.timeIntervalSince(peer.lastViewerStreamRefreshAt) >= 2.0 {
                        peer.lastViewerStreamRefreshAt = now
                        captureStreamer?.requestKeyFrameRefresh(reason: "viewer-stream-refresh", count: 1)
                    } else {
                        logger.debug(
                            "ℹ️ 已抑制过密 viewer 关键帧刷新请求: peer=\(peer.id, privacy: .public)"
                        )
                    }
                }
                startInteractionTelemetryIfNeeded(for: peer)
            }
    }

    private func sendStreamConfigurationAcknowledgement(
        for effectiveConfig: RemoteDesktopStreamConfiguration,
        transaction: RemoteDesktopStreamConfigurationTransaction?,
        to peer: PeerConnection
    ) async throws -> Bool {
        guard isCurrentPeer(peer),
              peer.securityAdmissionApproved,
              let sessionKeys = peer.sessionKeys,
              let expectedSessionReference = P2PEvidenceReference.sessionIncarnation(
                sessionID: sessionKeys.sessionId,
                transcriptHash: sessionKeys.transcriptHash
              ),
              let transaction else {
            throw RemoteControlError.handshakeInitializationFailed(
                "stream configuration acknowledgement has no current authenticated owner"
            )
        }
        let acknowledgement = RemoteDesktopStreamConfigurationAcknowledgement(
            acceptedAt: Date().timeIntervalSince1970,
            transaction: transaction,
            streamRefreshToken: effectiveConfig.streamRefreshToken,
            audioEndpointPresent: effectiveConfig.mediaAudioEndpoint != nil,
            screenFrameTransport: effectiveConfig.screenFrameTransport
        )
        do {
            try await sendRemoteControlPayload(
                acknowledgement,
                type: .streamConfigurationAck,
                to: peer
            )
        } catch {
            guard isCurrentPeer(peer),
                  peer.sessionKeys.flatMap({
                    P2PEvidenceReference.sessionIncarnation(
                        sessionID: $0.sessionId,
                        transcriptHash: $0.transcriptHash
                    )
                  }) == expectedSessionReference else {
                return false
            }
            throw error
        }
        guard isCurrentPeer(peer),
              peer.sessionKeys.flatMap({
                P2PEvidenceReference.sessionIncarnation(
                    sessionID: $0.sessionId,
                    transcriptHash: $0.transcriptHash
                )
              }) == expectedSessionReference else {
            return false
        }
        RemoteControlSmokeStatusWriter.append(
            "mac-stream-config-ack session_ref=\(expectedSessionReference) stream_ref=\(P2PEvidenceReference.transaction(transaction.id)) transport=\(effectiveConfig.screenFrameTransport ?? "legacy")"
        )
        return true
    }

    private func sendRemoteFrame(_ plaintext: Data, to peer: PeerConnection) async throws {
        if #available(macOS 14.0, *), let keys = peer.sessionKeys {
            let counter = try peer.secureEnvelopeSendSequencer.nextCounter(for: keys)
            let enc = try encryptRemotePayload(
                plaintext,
                with: keys,
                packetType: .control,
                counter: counter
            )
            try await sendFramed(enc, over: peer.connection)
        } else {
            try await sendFramed(plaintext, over: peer.connection)
        }
    }

    private func encryptRemotePayload(
        _ plaintext: Data,
        with keys: SessionKeys,
        packetType: RemoteControlSecurePacketType,
        counter: UInt64
    ) throws -> Data {
        try RemoteControlSecureEnvelope.seal(
            plaintext,
            keys: keys,
            packetType: packetType,
            counter: counter
        )
    }

    private struct RemoteControlSecureReplayDrop {
        let packetType: RemoteControlSecurePacketType
        let counter: UInt64
        let highestCounter: UInt64
        let reason: RemoteControlSecureReplayRejectionReason
    }

    private enum RemoteControlSecureDecryptResult {
        case payload(Data)
        case replayDrop(RemoteControlSecureReplayDrop)
    }

    private func decryptRemotePayload(
        _ ciphertext: Data,
        with keys: SessionKeys,
        replayWindow: inout RemoteControlSecureReplayWindow,
        allowedPacketTypes: Set<RemoteControlSecurePacketType>
    ) throws -> RemoteControlSecureDecryptResult {
        let openedPayload = try RemoteControlSecureEnvelope.open(
            ciphertext,
            keys: keys,
            allowedPacketTypes: allowedPacketTypes
        )
        do {
            try replayWindow.validateAndRecord(openedPayload)
            return .payload(openedPayload.payload)
        } catch let replayError as RemoteControlSecureEnvelopeError {
            guard case .replayDetected(let packetType, let counter, let highestCounter, let reason) = replayError else {
                throw replayError
            }
            return .replayDrop(
                .init(
                    packetType: packetType,
                    counter: counter,
                    highestCounter: highestCounter,
                    reason: reason
                )
            )
        }
    }

    private func logRemoteSecureReplayDrop(
        _ drop: RemoteControlSecureReplayDrop,
        peer: PeerConnection
    ) {
        let message = """
        mac-remote-secure-replay-drop peer=\(peer.id) packetType=\(drop.packetType.rawValue) \
        counter=\(drop.counter) highestCounter=\(drop.highestCounter) reason=\(drop.reason.rawValue) \
        action=drop-authenticated-replay
        """
        logger.info("\(message, privacy: .public)")
        emitSmokeTrace(message)
    }

    private func handleRemoteMouseEvent(_ event: RemoteMouseEvent) async {
        logger.debug("🖱️ 处理远程鼠标事件: \(event.type.rawValue, privacy: .public)")
        guard RemoteControlInputEventInjector.ensureAccessibilityPermission() else {
            logger.warning("⚠️ 未获得辅助功能权限，无法注入鼠标事件")
            return
        }

        RemoteControlInputEventInjector.postMouseEvent(event)
    }

    nonisolated static func mouseInjectionPoint(for event: RemoteMouseEvent) -> CGPoint {
        RemoteControlInputEventInjector.mouseInjectionPoint(for: event)
    }

    private func handleRemoteKeyboardEvent(_ event: RemoteKeyboardEvent) async {
        logger.debug("⌨️ 处理远程键盘事件: keyCode=\(event.keyCode)")
        guard RemoteControlInputEventInjector.ensureAccessibilityPermission() else {
            logger.warning("⚠️ 未获得辅助功能权限，无法注入键盘事件")
            return
        }

        RemoteControlInputEventInjector.postKeyboardEvent(event)
    }

 // MARK: - 性能指标更新

    private func updateMetrics(_ metrics: RenderMetrics) {
        bandwidthMbps = metrics.bandwidthMbps
        latencyMs = metrics.latencyMilliseconds

        if metrics.latencyMilliseconds > 0 {
            estimatedFPS = max(1, Int(1000.0 / metrics.latencyMilliseconds))
        } else {
            estimatedFPS = 0
        }

        bandwidthHistory.append(bandwidthMbps)
        if bandwidthHistory.count > historyCapacity {
            bandwidthHistory.removeFirst(bandwidthHistory.count - historyCapacity)
        }

        fpsHistory.append(estimatedFPS)
        if fpsHistory.count > historyCapacity {
            fpsHistory.removeFirst(fpsHistory.count - historyCapacity)
        }
    }

 // MARK: - NWConnection 长度前缀封装

 /// 发送一条「带 4 字节长度前缀」的数据帧
    private func sendFramed(_ data: Data, over connection: NWConnection) async throws {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// 尝试从缓冲区提取下一条完整的长度前缀帧
    /// - Returns: 完整 payload；若数据还不完整返回 nil
    private func nextFramedMessage(
        from buffer: inout Data,
        maxMessageBytes: Int
    ) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = parseFrameLength(from: buffer)
        let maxWireMessageBytes = RemoteControlWireLimits.maxWireMessageBytes(for: maxMessageBytes)
        guard length > 0, length <= maxWireMessageBytes else {
            throw RemoteControlError.invalidMessageLength(length)
        }

        let headerSize = 4
        let totalSize = headerSize + length
        guard totalSize <= buffer.count else { return nil }

        let payloadStart = buffer.index(buffer.startIndex, offsetBy: headerSize)
        let payloadEnd = buffer.index(payloadStart, offsetBy: length)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        return payload
    }

    private func parseFrameLength(from buffer: Data) -> Int {
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            let rawLength = base.loadUnaligned(as: UInt32.self)
            return Int(UInt32(bigEndian: rawLength))
        }
    }

 /// 读取一块原始数据，交由上层做粘包处理
    private func receiveChunk(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            final class EmptyReadLimiter: @unchecked Sendable {
                private let lock = NSLock()
                private var count = 0
                private let limit: Int

                init(limit: Int) {
                    self.limit = limit
                }

                func recordAndShouldFail() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    count += 1
                    return count > limit
                }
            }

            let emptyReadLimiter = EmptyReadLimiter(limit: 8)

            @Sendable func receiveNextChunk() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, data.isEmpty == false {
                        cont.resume(returning: data)
                    } else if isComplete {
 // 仅在 Network 明确报告 EOF 时才视为连接关闭，避免把建立期的空回调误判为断链。
                        cont.resume(returning: Data())
                    } else {
                        guard !emptyReadLimiter.recordAndShouldFail() else {
                            cont.resume(
                                throwing: RemoteControlError.handshakeInitializationFailed("remote-control receive returned repeated empty reads")
                            )
                            return
                        }
                        self.logger.debug("ℹ️ RemoteControl receive returned no payload before completion; awaiting next chunk")
                        receiveNextChunk()
                    }
                }
            }

            receiveNextChunk()
        }
    }

    private struct RetiredConnectionResources {
        let outboundFramePump: RemoteControlOutboundFramePump
        let realtimeAudioSender: RemoteRealtimeMediaAudioSender?
    }

    /// Atomically retires every manager-owned handle for one exact peer before
    /// any suspension. This is shared by transport callbacks and strict media
    /// failures so a same-ID replacement cannot appear between owner
    /// validation and teardown commitment.
    private func retireConnectionClosedResources(
        peer: PeerConnection,
        error: Error
    ) -> RetiredConnectionResources? {
        guard isCurrentPeer(peer) else {
            logger.info("ℹ️ 忽略过期远控会话的关闭回调: \(peer.id, privacy: .public)")
            return nil
        }

        logger.error(
            "🔌 连接 \(peer.id, privacy: .public) 关闭或出错: \(error.localizedDescription, privacy: .public) screenSharingActive=\(self.screenSharingActive, privacy: .public) hasCaptureStreamer=\(self.captureStreamer != nil, privacy: .public)"
        )

        notifyRemoteControlTerminalSessionIfNeeded(
            peer: peer,
            kind: .interrupted,
            reason: error.localizedDescription
        )
        peer.connection.cancel()
        if peer.role == .beingControlled {
            RemoteControlSecurityNoticeCenter.shared.endNotice(
                sessionId: peer.id,
                transportKind: .p2p
            )
        }
        _ = removePeer(deviceId: peer.id, role: peer.role)
        if #available(macOS 14.0, *) {
            releaseSOAState(for: peer)
        }
        let realtimeAudioSender = detachRealtimeAudioSender(from: peer)
        if peer.role == .controlling {
            stopP2PRealtimeAudioReceiverIfNeeded(peerId: peer.id)
        }
        stopInteractionTelemetry(for: peer.id)
        screenCaptureStartupRetryCountByPeerId.removeValue(forKey: peer.id)
        invalidateScreenSharingStartupState(for: peer.id)

        if activeClipboardPeerId == peer.id {
            let clipboard = ClipboardRedirectionManager.shared
            clipboard.onLocalClipboardChanged = nil
            clipboard.disable()
            activeClipboardPeerId = nil
        }

        finishRoleTeardownIfNeeded(for: peer.role)

        return RetiredConnectionResources(
            outboundFramePump: peer.outboundFramePump,
            realtimeAudioSender: realtimeAudioSender
        )
    }

    private func closeRetiredConnectionResources(
        _ resources: RetiredConnectionResources
    ) async {
        await resources.outboundFramePump.close()
        if let realtimeAudioSender = resources.realtimeAudioSender {
            await realtimeAudioSender.close(reason: "peer-connection-closed")
        }
    }

    /// 统一处理连接关闭 / 错误
    private func handleConnectionClosed(peer: PeerConnection, error: Error) async {
        guard let resources = retireConnectionClosedResources(
            peer: peer,
            error: error
        ) else {
            return
        }

        // From this point onward, only resources captured from the retired
        // peer may be awaited. No manager-global or peer-id keyed state is
        // mutated after suspension, so a same-id replacement cannot be torn
        // down by this callback when it resumes.
        await closeRetiredConnectionResources(resources)
    }

 // MARK: - 静态图像 -> Metal 纹理

    private func createTexture(from image: CGImage, device: MTLDevice) throws -> MTLTexture {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8

        let colorSpace = ColorPipelineConfiguration.sdr.makeSourceColorSpace() ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
        CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw RemoteControlError.screenCaptureFailed
        }

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.draw(image, in: rect)
        guard let data = context.data else {
            throw RemoteControlError.screenCaptureFailed
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw RemoteControlError.screenCaptureFailed
        }

        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    private static func sanitizeTelemetryToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func realtimeAudioStartupFailureReason(_ error: Error) -> String {
        if let transportError = error as? SkyBridgeRealtimeMediaTransportError {
            return transportError.stableCode
        }
        if let startupError = error as? RemoteControlRealtimeMediaStartupError {
            return startupError.stableCode
        }
        return sanitizeTelemetryToken(error.localizedDescription)
    }
}

#if DEBUG || SKYBRIDGE_TESTING
struct RemoteControlManagerRoleSnapshot: Equatable {
    let controllingDeviceIds: [String]
    let beingControlledDeviceIds: [String]
    let connectedDevices: [String]
    let isControlling: Bool
    let isBeingControlled: Bool
    let currentRenderingMode: RenderingMode
    let screenSharingActive: Bool
    let activeClipboardPeerId: String?
    let hasScreenCaptureWatchdogTask: Bool
    let screenCaptureRestartInProgress: Bool
    let interactionTelemetryPeerIds: [String]
    let screenCaptureRetryPeerIds: [String]
}

extension RemoteControlManager {
    func testingRegisterRole(_ role: RemoteControlSessionRole, deviceId: String) {
        registerConnectedDevice(deviceId, for: role)
    }

    func testingRemoveRole(_ role: RemoteControlSessionRole, deviceId: String) {
        unregisterConnectedDevice(deviceId, for: role)
        finishRoleTeardownIfNeeded(for: role)
    }

    func testingSetViewingRenderPipelineMode(_ mode: RenderingMode) {
        currentRenderingMode = mode
    }

    func testingSeedBeingControlledResources(
        activeClipboardPeerId: String? = nil,
        screenSharingActive: Bool = true,
        screenCaptureRestartInProgress: Bool = true,
        interactionTelemetryPeerIds: [String] = [],
        screenCaptureRetryPeerIds: [String] = []
    ) {
        self.activeClipboardPeerId = activeClipboardPeerId
        self.screenSharingActive = screenSharingActive
        self.screenCaptureRestartInProgress = screenCaptureRestartInProgress

        screenCaptureWatchdogTask?.cancel()
        screenCaptureWatchdogTask = Task {}

        interactionTelemetryTasksByPeerId.values.forEach { $0.cancel() }
        interactionTelemetryTasksByPeerId = Dictionary(
            uniqueKeysWithValues: interactionTelemetryPeerIds.map { deviceId in
                (deviceId, Task {})
            }
        )

        screenCaptureStartupRetryCountByPeerId = Dictionary(
            uniqueKeysWithValues: screenCaptureRetryPeerIds.map { ($0, 1) }
        )
    }

    var testingRoleSnapshot: RemoteControlManagerRoleSnapshot {
        RemoteControlManagerRoleSnapshot(
            controllingDeviceIds: controllingDeviceIds.sorted(),
            beingControlledDeviceIds: beingControlledDeviceIds.sorted(),
            connectedDevices: connectedDevices,
            isControlling: isControlling,
            isBeingControlled: isBeingControlled,
            currentRenderingMode: currentRenderingMode,
            screenSharingActive: screenSharingActive,
            activeClipboardPeerId: activeClipboardPeerId,
            hasScreenCaptureWatchdogTask: screenCaptureWatchdogTask != nil,
            screenCaptureRestartInProgress: screenCaptureRestartInProgress,
            interactionTelemetryPeerIds: interactionTelemetryTasksByPeerId.keys.sorted(),
            screenCaptureRetryPeerIds: screenCaptureStartupRetryCountByPeerId.keys.sorted()
        )
    }
}
#endif
#endif
