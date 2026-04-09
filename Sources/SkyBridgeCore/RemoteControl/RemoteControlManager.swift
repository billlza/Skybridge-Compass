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
import VideoToolbox
import CryptoKit

private enum RemoteControlWireLimits {
    static let aesGCMCombinedOverheadBytes = 28

    static func maxWireMessageBytes(for plaintextLimit: Int) -> Int {
        plaintextLimit + aesGCMCombinedOverheadBytes
    }
}

// MARK: - 基础模型：消息/事件/屏幕帧

/// 远程消息“信封”：所有消息都走它，避免裸 Data 粘包
private struct RemoteMessage: Codable, Sendable {
    let type: MessageType
    let payload: Data

    enum MessageType: String, Codable {
        case screenData
        case mouseEvent
        case keyboardEvent
        case clipboard
        case streamConfiguration
        case damageReport
        case cursorUpdate
        case overlayUpdate
    }
}

/// 屏幕数据（近距镜像主载体）
/// imageData 通常为压缩后的视频帧（H.264 / HEVC），或者退化为静态图像字节
struct ScreenData: Codable, Sendable {
    let width: Int
    let height: Int
    let imageData: Data
    let timestamp: TimeInterval
 /// "hevc" / "h264" / 其他（静态图像）
    let format: String?
 /// 压缩视频帧是否为关键帧；对 JPEG/BGRA 等独立帧固定视为 true。
    let isSyncFrame: Bool?
}

private actor RemoteControlOutboundFramePump {
    struct HealthSnapshot: Sendable {
        let lastSentFrameAt: Date
        let waitingForSyncFrame: Bool
        let waitingForSyncSince: Date?
    }

    private enum FrameTransport: Sendable {
        case legacyJSON
        case binaryWire
    }

    private let peerId: String
    private let connection: NWConnection
    private let maxFramedMessageBytes: Int

    private var frameTransport: FrameTransport = .legacyJSON
    private var damageTrackingEnabled = true
    private var sessionKeys: SessionKeys?
    private var frameQueue = RemoteScreenFrameSendQueue()
    private var latestDamageReport: RemoteDesktopDamageReport?
    private var sending = false
    private var closed = false
    private var onNeedsSyncRefresh: (@Sendable () -> Void)?
    private var lastSentFrameAt: Date = .distantPast
    private var waitingForSyncSince: Date?
    private var lastSyncRefreshRequestAt: Date = .distantPast
    private var syncRecoveryTask: Task<Void, Never>?

    init(peerId: String, connection: NWConnection, maxFramedMessageBytes: Int) {
        self.peerId = peerId
        self.connection = connection
        self.maxFramedMessageBytes = maxFramedMessageBytes
    }

    func updateTransportState(
        requestedStreamConfiguration: RemoteDesktopStreamConfiguration?,
        sessionKeys: SessionKeys?
    ) {
        frameTransport = requestedStreamConfiguration?.screenFrameTransport == "sbrf-v1"
            ? .binaryWire
            : .legacyJSON
        damageTrackingEnabled = requestedStreamConfiguration?.damageTrackingEnabled ?? true
        self.sessionKeys = sessionKeys
    }

    func submitDamageReport(_ report: RemoteDesktopDamageReport) async {
        guard !closed else { return }
        latestDamageReport = report
        await drainIfNeeded()
    }

    func submitFrame(_ frame: ScreenData) async {
        guard !closed else { return }
        let enqueueResult = frameQueue.enqueue(frame)
        if enqueueResult == .droppedPredictiveFrameNeedsSyncRefresh {
            requestSyncRefreshIfNeeded(reason: "send-queue-overflow", minimumInterval: 0)
        }
        updateSyncRecoveryState()
        await drainIfNeeded()
    }

    func setSyncRefreshHandler(_ handler: (@Sendable () -> Void)?) {
        onNeedsSyncRefresh = handler
    }

    func close() {
        closed = true
        frameQueue.clear()
        latestDamageReport = nil
        onNeedsSyncRefresh = nil
        waitingForSyncSince = nil
        syncRecoveryTask?.cancel()
        syncRecoveryTask = nil
    }

    func healthSnapshot() -> HealthSnapshot {
        HealthSnapshot(
            lastSentFrameAt: lastSentFrameAt,
            waitingForSyncFrame: frameQueue.waitingForSyncFrame,
            waitingForSyncSince: waitingForSyncSince
        )
    }

    private func drainIfNeeded() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }

        while !closed, let nextFrame = frameQueue.dequeue() {

            do {
                if damageTrackingEnabled,
                   let report = latestDamageReport {
                    latestDamageReport = nil
                    try await sendControlPayload(report, type: .damageReport)
                }

                let payload = try makeScreenPayload(for: nextFrame)
                guard payload.count <= maxFramedMessageBytes else {
                    Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")
                        .warning(
                            """
                            ⚠️ 已丢弃超限远控屏幕帧: peer=\(self.peerId, privacy: .public) \
                            bytes=\(payload.count, privacy: .public) \
                            max=\(self.maxFramedMessageBytes, privacy: .public) \
                            format=\(nextFrame.format ?? "unknown", privacy: .public) \
                            resolution=\(nextFrame.width, privacy: .public)x\(nextFrame.height, privacy: .public)
                            """
                        )
                    continue
                }

                try await sendRemoteFrame(payload)
                lastSentFrameAt = Date()
                updateSyncRecoveryState()
            } catch {
                Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")
                    .error(
                        "❌ 发送屏幕数据失败: peer=\(self.peerId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                break
            }
        }
    }

    private func updateSyncRecoveryState() {
        if frameQueue.waitingForSyncFrame {
            if waitingForSyncSince == nil {
                waitingForSyncSince = Date()
            }
            ensureSyncRecoveryTaskRunning()
        } else {
            waitingForSyncSince = nil
            syncRecoveryTask?.cancel()
            syncRecoveryTask = nil
        }
    }

    private func ensureSyncRecoveryTaskRunning() {
        guard syncRecoveryTask == nil else { return }
        syncRecoveryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(400))
                } catch {
                    return
                }
                await self.driveSyncRecoveryTick()
            }
        }
    }

    private func driveSyncRecoveryTick() {
        guard !closed else {
            syncRecoveryTask = nil
            return
        }
        guard frameQueue.waitingForSyncFrame else {
            syncRecoveryTask?.cancel()
            syncRecoveryTask = nil
            waitingForSyncSince = nil
            return
        }
        requestSyncRefreshIfNeeded(reason: "waiting-for-sync-frame", minimumInterval: 0.4)
    }

    private func requestSyncRefreshIfNeeded(reason: String, minimumInterval: TimeInterval) {
        let now = Date()
        guard now.timeIntervalSince(lastSyncRefreshRequestAt) >= minimumInterval else { return }
        lastSyncRefreshRequestAt = now
        Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")
            .warning("⚠️ 发送队列等待关键帧，已请求刷新: peer=\(self.peerId, privacy: .public) reason=\(reason, privacy: .public)")
        onNeedsSyncRefresh?()
    }

    private func makeScreenPayload(for frame: ScreenData) throws -> Data {
        switch frameTransport {
        case .binaryWire:
            return RemoteDesktopScreenFrameWire.encode(
                width: frame.width,
                height: frame.height,
                imageData: frame.imageData,
                timestamp: frame.timestamp,
                format: frame.format,
                isSyncFrame: frame.isSyncFrame
            )
        case .legacyJSON:
            let encodedScreen = try JSONEncoder().encode(frame)
            let message = RemoteMessage(type: .screenData, payload: encodedScreen)
            return try JSONEncoder().encode(message)
        }
    }

    func sendControlPayload<T: Encodable & Sendable>(
        _ payload: T,
        type: RemoteMessage.MessageType
    ) async throws {
        let encodedPayload = try JSONEncoder().encode(payload)
        let message = RemoteMessage(type: type, payload: encodedPayload)
        let framedMessage = try JSONEncoder().encode(message)
        guard framedMessage.count <= maxFramedMessageBytes else {
            throw RemoteControlError.invalidMessageLength(framedMessage.count)
        }
        try await sendRemoteFrame(framedMessage)
    }

    private func sendRemoteFrame(_ plaintext: Data) async throws {
        let outboundData: Data
        if #available(macOS 14.0, *), let sessionKeys {
            outboundData = try Self.encryptRemotePayload(plaintext, with: sessionKeys)
        } else {
            outboundData = plaintext
        }
        guard outboundData.count <= RemoteControlWireLimits.maxWireMessageBytes(for: maxFramedMessageBytes) else {
            throw RemoteControlError.invalidMessageLength(outboundData.count)
        }
        try await Self.sendFramed(outboundData, over: connection)
    }

    @available(macOS 14.0, *)
    private static func encryptRemotePayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined ?? Data()
    }

    private static func sendFramed(_ data: Data, over connection: NWConnection) async throws {
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

/// 鼠标事件类型
public enum MouseEventType: String, Codable, Sendable {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case mouseMoved
    case scrollUp
    case scrollDown
}

/// 键盘事件类型
public enum KeyboardEventType: String, Codable, Sendable {
    case keyDown
    case keyUp
}

/// 远程鼠标事件
public struct RemoteMouseEvent: Codable, Sendable {
    public let type: MouseEventType
    public let x: Double
    public let y: Double
    public let timestamp: TimeInterval

    public init(type: MouseEventType, x: Double, y: Double, timestamp: TimeInterval) {
        self.type = type
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }
}

/// 远程键盘事件
public struct RemoteKeyboardEvent: Codable, Sendable {
    public let type: KeyboardEventType
    public let keyCode: Int
    public let timestamp: TimeInterval

    public init(type: KeyboardEventType, keyCode: Int, timestamp: TimeInterval) {
        self.type = type
        self.keyCode = keyCode
        self.timestamp = timestamp
    }
}

/// 远程控制错误
public enum RemoteControlError: Error, LocalizedError {
    case deviceNotConnected
    case connectionClosed
    case invalidMessageLength(Int)
    case permissionDenied
    case screenCaptureFailed
    case handshakeInitializationFailed(String)
    case untrustedPeer(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "设备未连接"
        case .connectionClosed:
            return "连接已关闭"
        case .invalidMessageLength(let length):
            return "消息长度异常: \(length)"
        case .permissionDenied:
            return "权限被拒绝"
        case .screenCaptureFailed:
            return "屏幕捕获失败"
        case .handshakeInitializationFailed(let reason):
            return "远控握手初始化失败: \(reason)"
        case .untrustedPeer(let peerId):
            return "远控目标未建立受信任身份: \(peerId)"
        }
    }
}

// MARK: - 连接状态封装（每个设备一条 NWConnection）

private final class PeerConnection {
    let id: String
    let connection: NWConnection
    var remoteVideoFormats: Set<String>
    var requestedStreamConfiguration: RemoteDesktopStreamConfiguration?
    var captureCompatibilityOverride: RemoteFrameType?
    let clipboardSessionId: UUID
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

    init(id: String, connection: NWConnection, remoteVideoFormats: Set<String> = []) {
        self.id = id
        self.connection = connection
        self.remoteVideoFormats = Set(remoteVideoFormats.map { $0.lowercased() })
        self.clipboardSessionId = UUID()
        self.outboundFramePump = RemoteControlOutboundFramePump(
            peerId: id,
            connection: connection,
            maxFramedMessageBytes: 8_000_000
        )
        self.queue = DispatchQueue(
            label: "com.skybridge.remote.\(id)",
            qos: .userInitiated
        )
    }
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
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        print("🧪 \(message)")
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
    private var captureStreamer: ScreenCaptureKitStreamer?
    private var screenCaptureWatchdogTask: Task<Void, Never>?
    private var screenCaptureRestartInProgress = false
    private var screenCaptureStartupRetryCountByPeerId: [String: Int] = [:]
    private var deferredScreenSharingFallbackTasksByPeerId: [String: Task<Void, Never>] = [:]
    private var screenSharingAttemptGate = RemoteControlScreenSharingAttemptGate()
    private var peers: [String: PeerConnection] = [:]
    private let maxFramedMessageBytes = 8_000_000
    private var interactionTelemetryTasksByPeerId: [String: Task<Void, Never>] = [:]
    private var activeClipboardPeerId: String?

 /// Metal 设备，作为静态图像兜底（ImageIO -> CGImage -> MTLTexture）
    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

 // MARK: 初始化

    public init() {
        super.init(category: "RemoteControl")

        logger.info("🖥️ RemoteControlManager 初始化")

 // 将渲染器输出绑定到纹理流
        renderer.frameHandler = { [weak self] texture, backing in
            guard let self else { return }
            Task { @MainActor in
                self.textureFeed.update(texture: texture, backing: backing)
            }
        }

        // 稳定渲染器输出同样绑定到纹理流
        stableRenderer.frameHandler = { [weak self] texture, backing in
            guard let self else { return }
            Task { @MainActor in
                self.publishRenderedTexture(texture, backing: backing, from: .stable)
            }
        }

        // 高性能渲染器输出绑定到纹理流
        fluidRenderer.frameHandler = { [weak self] texture, backing in
            guard let self else { return }
            Task { @MainActor in
                self.publishRenderedTexture(texture, backing: backing, from: .fluid)
            }
        }

        // 高保真渲染器输出绑定到纹理流
        referenceRenderer.frameHandler = { [weak self] texture, backing in
            guard let self else { return }
            Task { @MainActor in
                self.publishRenderedTexture(texture, backing: backing, from: .reference)
            }
        }

        renderingModeController.onModeChanged = { [weak self] _, to, _ in
            guard let self else { return }
            Task { @MainActor in
                self.currentRenderingMode = to
                self.synchronizeRendererResources(for: to)
            }
        }
    }

    public override func performInitialization() async {
        logger.info("🖥️ RemoteControlManager performInitialization 完成")
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
        stableRenderer.teardown()
        fluidRenderer.teardown()
        referenceRenderer.teardown()
        textureFeed.update(texture: nil)
        renderingModeController.resetForNewStream()
        let requestedMode = resolvedPreferredRenderingMode()
        currentRenderingMode = renderingModeController.requestMode(requestedMode)
    }

    private func tearDownViewingRenderPipeline() {
        stableRenderer.teardown()
        fluidRenderer.teardown()
        referenceRenderer.teardown()
        textureFeed.update(texture: nil)
        renderingModeController.resetForNewStream()
        currentRenderingMode = .stable
    }

    private func applyPreferredRenderingModeToActiveViewingSession() {
        guard isControlling, !connectedDevices.isEmpty else { return }
        currentRenderingMode = renderingModeController.requestMode(resolvedPreferredRenderingMode())
    }

    private func publishRenderedTexture(
        _ texture: MTLTexture,
        backing: AnyObject?,
        from mode: RenderingMode
    ) {
        guard renderingModeController.currentMode == mode else { return }
        textureFeed.update(texture: texture, backing: backing)
        if renderingModeController.isProbationActive {
            renderingModeController.reportProbationFrameSuccess()
        }
    }

    private func synchronizeRendererResources(for activeMode: RenderingMode) {
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
        logger.info("🎮 开始控制远程设备: \(deviceId, privacy: .public)")
        if !remoteVideoFormats.isEmpty {
            logger.info(
                "🎥 对端声明可接收视频格式: \(remoteVideoFormats.sorted().joined(separator: ","), privacy: .public)"
            )
        }

        let peer = PeerConnection(
            id: deviceId,
            connection: connection,
            remoteVideoFormats: remoteVideoFormats
        )
        replacePeerSessionIfNeeded(with: peer, resetCapturePipeline: false)
        prepareViewingRenderPipelineForNewStream()

        if !connectedDevices.contains(deviceId) {
            connectedDevices.append(deviceId)
        }
        isControlling = true

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
    }

 /// 停止控制指定设备
    public func stopControlling(deviceId: String) {
        logger.info("⏹️ 停止控制远程设备: \(deviceId, privacy: .public)")
        guard let peer = peers[deviceId] else { return }

        peer.connection.cancel()
        peers.removeValue(forKey: deviceId)
        connectedDevices.removeAll { $0 == deviceId }
        Task {
            await peer.outboundFramePump.close()
        }

        if connectedDevices.isEmpty {
            isControlling = false
            tearDownViewingRenderPipeline()
        }
    }

 /// 作为「被控制端」开放远程控制
    public func allowRemoteControl(from deviceId: String, connection: NWConnection) async {
        logger.info("🖥️ 允许远程控制来自设备: \(deviceId, privacy: .public)")

        let peer = PeerConnection(id: deviceId, connection: connection)
        replacePeerSessionIfNeeded(with: peer, resetCapturePipeline: true)

        if #available(macOS 14.0, *) {
            peer.handshakePeer = PeerIdentifier(deviceId: deviceId, displayName: nil, address: nil)
            logger.info("🔐 RemoteControl P2P handshake armed for \(deviceId, privacy: .public); waiting for MessageA")
        }

        if !connectedDevices.contains(deviceId) {
            connectedDevices.append(deviceId)
        }

        isBeingControlled = true

        // 1) 先开始接收对端发来的输入事件 / 流配置
        startReceivingRemoteEvents(from: peer)
        if #available(macOS 14.0, *), peer.handshakePeer != nil {
            logger.info("🔐 RemoteControl waiting for secure channel: peer=\(peer.id, privacy: .public)")
            guard await waitForSecureChannelIfNeeded(for: peer) else {
                logger.warning("⚠️ RemoteControl secure channel was not established in time for \(peer.id, privacy: .public)")
                await handleConnectionClosed(
                    peer: peer,
                    error: RemoteControlError.handshakeInitializationFailed("secure channel timeout")
                )
                return
            }
        }
        let hasInitialStreamConfiguration = await waitForInitialStreamConfigurationIfAvailable(for: peer)
        guard isCurrentPeer(peer), isBeingControlled else { return }

        switch RemoteControlScreenSharingStartupPolicy.decision(
            hasInitialStreamConfiguration: hasInitialStreamConfiguration
        ) {
        case .startImmediately:
            await startScreenSharing(to: peer)
        case .awaitViewerConfiguration(let fallbackAfter):
            logger.info(
                """
                📺 viewer 首个流配置尚未就绪，先保持待机: peer=\(peer.id, privacy: .public) \
                fallbackDelay=\(String(describing: fallbackAfter), privacy: .public)
                """
            )
            scheduleDeferredScreenSharingFallback(for: peer, after: fallbackAfter)
        }
    }

 /// 作为被控制端，关闭来自某设备的远程控制
    public func stopRemoteControl(from deviceId: String) {
        logger.info("⏹️ 停止被远程控制来自设备: \(deviceId, privacy: .public)")
        guard let peer = peers[deviceId] else { return }

        if activeClipboardPeerId == deviceId {
            let clipboard = ClipboardRedirectionManager.shared
            clipboard.onLocalClipboardChanged = nil
            clipboard.disable()
            activeClipboardPeerId = nil
        }

        peer.connection.cancel()
        peers.removeValue(forKey: deviceId)
        connectedDevices.removeAll { $0 == deviceId }
        Task {
            await peer.outboundFramePump.close()
        }
        stopInteractionTelemetry(for: deviceId)
        screenCaptureStartupRetryCountByPeerId.removeValue(forKey: deviceId)
        invalidateScreenSharingStartupState(for: deviceId)

        if connectedDevices.isEmpty {
            isBeingControlled = false
            screenSharingActive = false
            screenCaptureWatchdogTask?.cancel()
            screenCaptureWatchdogTask = nil
            screenCaptureRestartInProgress = false
            captureStreamer?.stop()
            captureStreamer = nil
            interactionTelemetryTasksByPeerId.values.forEach { $0.cancel() }
            interactionTelemetryTasksByPeerId.removeAll()
        }
    }

    private func isCurrentPeer(_ peer: PeerConnection) -> Bool {
        guard let current = peers[peer.id] else { return false }
        return current === peer
    }

    private func replacePeerSessionIfNeeded(
        with peer: PeerConnection,
        resetCapturePipeline: Bool
    ) {
        let previousPeer = peers[peer.id]
        peers[peer.id] = peer

        guard let previousPeer, previousPeer !== peer else { return }

        logger.warning(
            "🔁 RemoteControl superseding existing session for \(peer.id, privacy: .public)"
        )

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

        if resetCapturePipeline {
            screenCaptureWatchdogTask?.cancel()
            screenCaptureWatchdogTask = nil
            screenCaptureRestartInProgress = false
            captureStreamer?.stop()
            captureStreamer = nil
            screenSharingActive = false
            screenCaptureStartupRetryCountByPeerId.removeValue(forKey: previousPeer.id)
            invalidateScreenSharingStartupState(for: previousPeer.id)
        } else {
            tearDownViewingRenderPipeline()
        }

        previousPeer.connection.cancel()
    }

 // MARK: - 输入事件发送（控制端 -> 被控制端）

    public func sendMouseEvent(_ event: RemoteMouseEvent, to deviceId: String) async throws {
        guard let peer = peers[deviceId] else {
            throw RemoteControlError.deviceNotConnected
        }
        try ensureSecureChannelEstablished(for: peer)
        try await peer.outboundFramePump.sendControlPayload(event, type: .mouseEvent)
        logger.debug("🖱️ 发送鼠标事件 \(event.type.rawValue, privacy: .public) -> \(deviceId, privacy: .public)")
    }

    public func sendKeyboardEvent(_ event: RemoteKeyboardEvent, to deviceId: String) async throws {
        guard let peer = peers[deviceId] else {
            throw RemoteControlError.deviceNotConnected
        }
        try ensureSecureChannelEstablished(for: peer)
        try await peer.outboundFramePump.sendControlPayload(event, type: .keyboardEvent)
        logger.debug("⌨️ 发送键盘事件 keyCode=\(event.keyCode) -> \(deviceId, privacy: .public)")
    }

 // MARK: - 屏幕共享（被控制端 -> 控制端）

 /// 启动本机屏幕捕获 + 硬件编码 + 推流
    private func startScreenSharing(to peer: PeerConnection) async {
        guard isCurrentPeer(peer) else {
            logger.info("ℹ️ 忽略过期远控会话的推流启动: \(peer.id, privacy: .public)")
            return
        }
        cancelDeferredScreenSharingFallback(for: peer.id)
        let attemptGeneration = screenSharingAttemptGate.beginAttempt(for: peer.id)
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
        var policy = RemoteControlStreamPolicySelector.select(
            request: request,
            peerFormats: effectiveRemoteVideoFormats(for: peer),
            thermalState: ProcessInfo.processInfo.thermalState,
            isAppleSilicon: Self.isAppleSiliconRuntime
        )
        policy = effectiveCapturePolicy(policy, for: peer)
        streamer.onCaptureIssue = { [weak self, weak peer] reason in
            guard let self, let peer else { return }
            Task { @MainActor [weak self, weak peer] in
                guard let self, let peer else { return }
                self.applyCaptureCompatibilityOverrideIfNeeded(
                    for: peer,
                    reason: reason,
                    activePolicy: policy
                )
                await self.restartScreenSharingIfNeeded(for: peer.id, reason: reason)
            }
        }

        let outboundFramePump = peer.outboundFramePump
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
            peer.queue.async {
                let frame = ScreenData(
                    width: width,
                    height: height,
                    imageData: data,
                    timestamp: Date().timeIntervalSince1970,
                    format: fmt,
                    isSyncFrame: isSyncFrame
                )
                Task {
                    await outboundFramePump.submitFrame(frame)
                }
            }
        }
        await outboundFramePump.setSyncRefreshHandler { [weak streamer] in
            Task { @MainActor [weak streamer] in
                streamer?.requestKeyFrameRefresh(reason: "outbound-frame-drop")
            }
        }
        streamer.onDamageReport = { report in
            Task.detached(priority: .utility) {
                await outboundFramePump.submitDamageReport(report)
            }
        }
        logger.info(
            """
            📺 推流参数: \(Int(policy.preferredSize.width))x\(Int(policy.preferredSize.height)) \
            @\(policy.targetFrameRate)fps gop=\(policy.keyFrameInterval) \
            codec=\(Self.codecName(policy.codec), privacy: .public) \
            reason=\(policy.reason, privacy: .public)
            """
        )

        do {
            await syncOutboundFramePump(for: peer)
            try await streamer.start(
                preferredCodec: policy.codec,
                preferredSize: policy.preferredSize,
                targetFPS: policy.targetFrameRate,
                keyFrameInterval: policy.keyFrameInterval,
                captureCursorInVideo: !(peer.requestedStreamConfiguration?.separateCursorChannelEnabled ?? false),
                bitstreamFormat: .annexB
            )
            guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else {
                logger.info("ℹ️ 已忽略过期的屏幕采集启动完成: peer=\(peer.id, privacy: .public)")
                streamer.stop()
                return
            }
            captureStreamer = streamer
            screenSharingActive = true
            screenCaptureStartupRetryCountByPeerId[peer.id] = 0
            configureClipboardSync(for: peer)
            startInteractionTelemetryIfNeeded(for: peer)
            screenCaptureWatchdogTask = Task { [weak self, weak streamer] in
                guard let self, let streamer else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { break }
                    guard self.captureStreamer === streamer,
                          self.isBeingControlled else { break }

                    let health = streamer.healthSnapshot()
                    let framePumpHealth = await outboundFramePump.healthSnapshot()
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
                        await self.restartScreenSharingIfNeeded(for: peer.id, reason: "encoded-stall")
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
                        streamer.requestKeyFrameRefresh(reason: "frame-send-stall")
                        await self.restartScreenSharingIfNeeded(for: peer.id, reason: "frame-send-stall")
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
                return
            }
            logger.error(
                "❌ 启动 ScreenCaptureKitStreamer 失败: \(error.localizedDescription, privacy: .public). 请确认已在“系统设置 > 隐私与安全 > 录屏与系统录音”中为当前运行的 App 条目授权，必要时完全退出后重开。"
            )
            guard isCurrentPeer(peer) else { return }
            if !scheduleScreenSharingStartupRetry(
                for: peer,
                error: error,
                replacing: streamer
            ) {
                screenSharingActive = false
            }
        }
    }

    private func cancelDeferredScreenSharingFallback(for peerId: String) {
        deferredScreenSharingFallbackTasksByPeerId[peerId]?.cancel()
        deferredScreenSharingFallbackTasksByPeerId.removeValue(forKey: peerId)
    }

    private func invalidateScreenSharingStartupState(for peerId: String) {
        cancelDeferredScreenSharingFallback(for: peerId)
        screenSharingAttemptGate.invalidateAttempts(for: peerId)
    }

    private func scheduleDeferredScreenSharingFallback(
        for peer: PeerConnection,
        after delay: Duration
    ) {
        guard isCurrentPeer(peer), isBeingControlled else { return }
        cancelDeferredScreenSharingFallback(for: peer.id)
        deferredScreenSharingFallbackTasksByPeerId[peer.id] = Task { @MainActor [weak self, weak peer] in
            guard let self, let peer else { return }
            defer { self.deferredScreenSharingFallbackTasksByPeerId.removeValue(forKey: peer.id) }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard self.isCurrentPeer(peer), self.isBeingControlled else { return }
            guard peer.requestedStreamConfiguration == nil else { return }
            guard self.captureStreamer == nil, !self.screenSharingActive else { return }
            self.logger.warning(
                """
                ⚠️ viewer 流配置迟迟未到，按兼容模式启动远控推流: peer=\(peer.id, privacy: .public) \
                delay=\(String(describing: delay), privacy: .public)
                """
            )
            await self.startScreenSharing(to: peer)
        }
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
        replacing streamer: ScreenCaptureKitStreamer
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
            try? await Task.sleep(for: delay)
            guard self.isCurrentPeer(peer), self.isBeingControlled else { return }
            guard self.captureStreamer == nil else { return }
            await self.startScreenSharing(to: peer)
        }
        return true
    }

    private func restartScreenSharingIfNeeded(for deviceId: String, reason: String) async {
        guard !screenCaptureRestartInProgress else { return }
        guard let peer = peers[deviceId] else { return }
        guard isBeingControlled else { return }
        guard captureStreamer != nil else { return }

        screenCaptureRestartInProgress = true
        defer { screenCaptureRestartInProgress = false }

        logger.info("🔁 重新启动屏幕采集：peer=\(deviceId, privacy: .public) reason=\(reason, privacy: .public)")
        screenCaptureWatchdogTask?.cancel()
        screenCaptureWatchdogTask = nil
        captureStreamer?.stop()
        captureStreamer = nil

        try? await Task.sleep(for: .milliseconds(150))
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
            for: override
        )
        return RemoteControlStreamPolicy(
            codec: override,
            targetFrameRate: selectedPolicy.targetFrameRate,
            keyFrameInterval: selectedPolicy.keyFrameInterval,
            preferredSize: normalizedSize,
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
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                guard let captureContext = captureStreamer?.captureContextSnapshot() else {
                    try? await Task.sleep(for: .milliseconds(50))
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

                try? await Task.sleep(for: .milliseconds(16))
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
        let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_ALLOW_INSECURE_REMOTE_CONTROL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    @available(macOS 14.0, *)
    private nonisolated static func remoteControlSOAPeerId(for identifier: String?) -> Data? {
        RemoteControlInboundTrustResolver.soaPeerId(for: identifier)
    }

    @available(macOS 14.0, *)
    struct RemoteControlSOABinding: Sendable, Equatable {
        let localPeerId: Data
        let expectedRemotePeerId: Data
    }

    @available(macOS 14.0, *)
    nonisolated static func remoteControlSOABinding(
        localDeviceId: String?,
        remoteDeviceId: String?
    ) -> RemoteControlSOABinding? {
        guard let localPeerId = remoteControlSOAPeerId(for: localDeviceId),
              let expectedRemotePeerId = remoteControlSOAPeerId(for: remoteDeviceId) else {
            return nil
        }
        return RemoteControlSOABinding(
            localPeerId: localPeerId,
            expectedRemotePeerId: expectedRemotePeerId
        )
    }

    @available(macOS 14.0, *)
    private nonisolated static func randomRemoteControlAttemptId() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
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
        let trustProvider = DefaultHandshakeTrustProvider()
        guard await trustProvider.trustedFingerprint(for: deviceId) != nil else {
            throw RemoteControlError.untrustedPeer(deviceId)
        }
        return trustProvider
    }

    @available(macOS 14.0, *)
    private func syncSecureChannelState(after driver: HandshakeDriver, for peer: PeerConnection) async throws {
        switch await driver.getCurrentState() {
        case .established(let keys):
            peer.sessionKeys = keys
            peer.handshakeDriver = nil
            await syncOutboundFramePump(for: peer)
            logger.info("🔐 RemoteControl handshake established for \(peer.id, privacy: .public)")
            emitSmokeTrace("mac remote established peer=\(peer.id) suite=\(keys.negotiatedSuite.rawValue)")
        case .failed(let reason):
            throw RemoteControlError.handshakeInitializationFailed(String(describing: reason))
        default:
            break
        }
    }

    @available(macOS 14.0, *)
    private func establishOutboundSecureChannel(for peer: PeerConnection) async -> Bool {
        guard isCurrentPeer(peer),
              let handshakePeer = peer.handshakePeer else {
            return false
        }
        let peerID = peer.id
        let peerIdentity = ObjectIdentifier(peer)

        let localDeviceId = await SelfIdentityProvider.shared.snapshot().deviceId
        guard let soaBinding = Self.remoteControlSOABinding(
            localDeviceId: localDeviceId,
            remoteDeviceId: handshakePeer.deviceId
        ) else {
            logger.error("❌ RemoteControl outbound handshake missing stable SOA identity for \(handshakePeer.deviceId, privacy: .public)")
            await handleConnectionClosed(peer: peer, error: RemoteControlError.untrustedPeer(handshakePeer.deviceId))
            return false
        }

        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let policy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        let selection: CryptoProviderFactory.SelectionPolicy = policy.requirePQC ? .requirePQC : .preferPQC
        let baseProvider = CryptoProviderFactory.make(policy: selection)

        do {
            let trustProvider = try await makeRemoteControlTrustProvider(for: handshakePeer.deviceId)
            let transport = RemoteControlHandshakeTransport(connection: peer.connection)
            let keys = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: handshakePeer.deviceId,
                preferPQC: true,
                policy: policy,
                cryptoProvider: baseProvider
            ) { [weak self] preparation in
                let isStillCurrent = await MainActor.run { [weak self] in
                    guard let self,
                          let current = self.peers[peerID] else { return false }
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
                    expectedRemoteSOAPeerId: soaBinding.expectedRemotePeerId
                )
                await MainActor.run { [weak self] in
                    guard let self,
                          let current = self.peers[peerID],
                          ObjectIdentifier(current) == peerIdentity else { return }
                    current.handshakeDriver = driver
                }
                return try await driver.initiateHandshake(with: handshakePeer)
            }

            peer.sessionKeys = keys
            peer.handshakeDriver = nil
            await syncOutboundFramePump(for: peer)
            logger.info("🔐 RemoteControl outbound handshake established for \(peer.id, privacy: .public)")
            emitSmokeTrace("mac remote outbound-established peer=\(peer.id) suite=\(keys.negotiatedSuite.rawValue)")
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
            try? await Task.sleep(for: .milliseconds(50))
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
            logger.info("📺 未在配置等待窗口内收到 viewer 流配置，继续等待 viewer 就绪或兼容回退")
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
                sessionKeys: peer.sessionKeys
            )
        } else {
            await peer.outboundFramePump.updateTransportState(
                requestedStreamConfiguration: peer.requestedStreamConfiguration,
                sessionKeys: nil
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

    private func preferredCaptureSize(for resolution: ResolutionSetting) -> CGSize {
        if let dim = resolution.dimensions {
            return CGSize(width: dim.width, height: dim.height)
        }

        let settings = RemoteDesktopSettingsManager.shared.settings.displaySettings
        return adaptiveCaptureSizeForDirectDisplay(
            preferredCodec: settings.preferredCodec,
            lowLatencyMode: settings.lowLatencyMode,
            enableHardwareAcceleration: settings.enableHardwareAcceleration,
            enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization
        )
    }

    private func adaptiveCaptureSizeForDirectDisplay(
        preferredCodec: PreferredVideoCodec,
        lowLatencyMode: Bool,
        enableHardwareAcceleration: Bool,
        enableAppleSiliconOptimization: Bool
    ) -> CGSize {
        let fallback = CGSize(width: 1920, height: 1080)
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else {
            return fallback
        }

        let nativeWidth = CGFloat(mode.width)
        let nativeHeight = CGFloat(mode.height)
        guard nativeWidth > 0, nativeHeight > 0 else {
            return fallback
        }

        let longEdge = max(nativeWidth, nativeHeight)
        let prefersHEVC = preferredCodec == .hevc
        let canPushHighRes = prefersHEVC && enableHardwareAcceleration
            && enableAppleSiliconOptimization && Self.isAppleSiliconRuntime

        let targetLongEdge: CGFloat
        if longEdge <= 1920 {
            return CGSize(width: nativeWidth, height: nativeHeight)
        } else if longEdge <= 2560 {
            targetLongEdge = lowLatencyMode ? 1920 : longEdge
        } else if longEdge <= 3840 {
            targetLongEdge = lowLatencyMode ? 1920 : (canPushHighRes ? 2560 : 1920)
        } else {
            targetLongEdge = lowLatencyMode ? 1920 : (canPushHighRes ? 3200 : 2560)
        }

        let scale = min(1.0, targetLongEdge / longEdge)
        return CGSize(
            width: max(960, floor(nativeWidth * scale)),
            height: max(540, floor(nativeHeight * scale))
        )
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
        let settings = RemoteDesktopSettingsManager.shared.settings.displaySettings
        let adaptiveResolutionEnabled = peer.requestedStreamConfiguration?.adaptiveResolutionEnabled
            ?? (peer.requestedStreamConfiguration?.width == nil || peer.requestedStreamConfiguration?.height == nil)
        let preferredCodec: PreferredVideoCodec = {
            switch peer.requestedStreamConfiguration?.preferredCodec?.lowercased() {
            case "h264":
                return .h264
            case "hevc":
                return .hevc
            default:
                return settings.preferredCodec
            }
        }()
        let preferredSize: CGSize = {
            if !adaptiveResolutionEnabled,
               let width = peer.requestedStreamConfiguration?.width,
               let height = peer.requestedStreamConfiguration?.height,
               width > 0,
               height > 0 {
                return CGSize(width: width, height: height)
            }
            if adaptiveResolutionEnabled {
                return adaptiveCaptureSizeForDirectDisplay(
                    preferredCodec: preferredCodec,
                    lowLatencyMode: peer.requestedStreamConfiguration?.lowLatencyMode ?? settings.lowLatencyMode,
                    enableHardwareAcceleration: peer.requestedStreamConfiguration?.enableHardwareAcceleration ?? settings.enableHardwareAcceleration,
                    enableAppleSiliconOptimization: peer.requestedStreamConfiguration?.enableAppleSiliconOptimization ?? settings.enableAppleSiliconOptimization
                )
            }
            return preferredCaptureSize(for: settings.resolution)
        }()

        return RemoteControlStreamRequest(
            preferredSize: preferredSize,
            preferredCodec: preferredCodec,
            targetFrameRate: max(12, min(peer.requestedStreamConfiguration?.targetFrameRate ?? settings.targetFrameRate, 120)),
            keyFrameInterval: max(10, min(peer.requestedStreamConfiguration?.keyFrameInterval ?? settings.keyFrameInterval, 240)),
            lowLatencyMode: peer.requestedStreamConfiguration?.lowLatencyMode ?? settings.lowLatencyMode,
            enableHardwareAcceleration: peer.requestedStreamConfiguration?.enableHardwareAcceleration ?? settings.enableHardwareAcceleration,
            enableAppleSiliconOptimization: peer.requestedStreamConfiguration?.enableAppleSiliconOptimization ?? settings.enableAppleSiliconOptimization
        )
    }

    private func configureClipboardSync(for peer: PeerConnection) {
        guard isCurrentPeer(peer) else { return }
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

    private func sendClipboardPayload(data: Data, mimeType: String, to deviceId: String) async {
        guard let peer = peers[deviceId] else { return }
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

    private static var isAppleSiliconRuntime: Bool {
        #if arch(arm64) || arch(arm64e)
        true
        #else
        false
        #endif
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
                            try await self.syncSecureChannelState(after: driver, for: peer)
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
                            plain = try self.decryptRemotePayload(messageData, with: keys)
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
        if let screenData = RemoteDesktopScreenFrameWire.decodeIfPresent(messageData) {
            try await handleInboundScreenData(
                ScreenData(
                    width: screenData.width,
                    height: screenData.height,
                    imageData: screenData.imageData,
                    timestamp: screenData.timestamp,
                    format: screenData.format,
                    isSyncFrame: screenData.isSyncFrame
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

    private func handleInboundScreenData(_ screenData: ScreenData) async throws {
        logger.debug("📺 接收到屏幕数据: \(screenData.width)x\(screenData.height)")

        guard !screenData.imageData.isEmpty else { return }

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

    private func startReceivingRemoteEvents(from peer: PeerConnection) {
        logger.info("🎮 开始接收远程事件 <- \(peer.id, privacy: .public)")

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
                    self.emitSmokeTrace("mac remote chunk peer=\(peer.id) bytes=\(chunk.count) buffered=\(buffer.count)")
                    if buffer.count > RemoteControlWireLimits.maxWireMessageBytes(for: self.maxFramedMessageBytes) * 2 {
                        throw RemoteControlError.invalidMessageLength(buffer.count)
                    }

                    guard self.isCurrentPeer(peer) else { break }

                    while let messageData = try self.nextFramedMessage(
                        from: &buffer,
                        maxMessageBytes: self.maxFramedMessageBytes
                    ) {
                        self.emitSmokeTrace("mac remote framed peer=\(peer.id) bytes=\(messageData.count)")
                        try await self.handleInboundRemoteFrame(from: peer, frame: messageData)
                    }
                } catch {
                    await self.handleConnectionClosed(peer: peer, error: error)
                    break
                }
            }
        }
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
            let plain = try decryptRemotePayload(frame, with: keys)
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
                    logger.error("❌ RemoteControl inbound handshake init failed for \(peer.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            try await syncSecureChannelState(after: driver, for: peer)
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
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !isCurrentPeer(peer) {
                logger.info("ℹ️ RemoteControl secure-channel wait aborted for stale peer \(peer.id, privacy: .public)")
                return false
            }
            if peer.sessionKeys != nil {
                logger.info("🔐 RemoteControl secure channel ready: peer=\(peer.id, privacy: .public)")
                emitSmokeTrace("mac remote secure-ready peer=\(peer.id)")
                return true
            }
            if Self.allowsInsecureLegacyRemoteControl {
                logger.notice("🔓 RemoteControl legacy plaintext mode enabled for \(peer.id, privacy: .public)")
                return true
            }
            if peers[peer.id] == nil {
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        emitSmokeTrace("mac remote secure-timeout peer=\(peer.id)")
        return peer.sessionKeys != nil
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
        let localDeviceId = await SelfIdentityProvider.shared.snapshot().deviceId
        guard let soaBinding = Self.remoteControlSOABinding(
            localDeviceId: localDeviceId,
            remoteDeviceId: trustedPeerId
        ) else {
            throw RemoteControlError.handshakeInitializationFailed(
                "inbound remote control handshake missing stable SOA identities"
            )
        }
        peer.handshakePeer = PeerIdentifier(deviceId: trustedPeerId, displayName: nil, address: nil)
        let trustProvider = try await makeRemoteControlTrustProvider(for: trustedPeerId)
        let peerHasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let peerHasClassicGroup = messageA.supportedSuites.contains { !$0.isPQCGroup }
        let peerHasHybridGroup = messageA.supportedSuites.contains { $0.isHybrid }
        let peerOnlyOffersHybrid = peerHasHybridGroup && messageA.supportedSuites.allSatisfy { $0.isHybrid }
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let requestedPolicy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        let capability = CryptoProviderFactory.detectCapability()
        let remotePrefersLiboqs = messageA.capabilities.providerType == .liboqs

        var effectivePolicy = requestedPolicy
        var cryptoProvider: any CryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
        var sigAAlgorithm: ProtocolSigningAlgorithm = .ed25519
        var offeredSuites: [CryptoSuite] = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }

        if peerHasPQCGroup {
            if remotePrefersLiboqs, capability.hasLiboqs {
                cryptoProvider = OQSPQCCryptoProvider()
                logger.info("🧩 RemoteControl inbound preferring liboqs provider for peer \(peer.id, privacy: .public)")
            } else {
                let pqcSelection: CryptoProviderFactory.SelectionPolicy = requestedPolicy.requirePQC ? .requirePQC : .preferPQC
                cryptoProvider = CryptoProviderFactory.make(policy: pqcSelection)
            }
            let localPQCSuites = DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(using: cryptoProvider)

            if localPQCSuites.isEmpty {
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
            } else {
                sigAAlgorithm = .mlDSA65
                offeredSuites = localPQCSuites
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
            includeSecureEnclavePoP: effectivePolicy.requireSecureEnclavePoP
        )
        let peerSuitesSummary = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
        let localSuitesSummary = offeredSuites.map(\.rawValue).joined(separator: ",")
        let providerName = String(describing: type(of: cryptoProvider))
        let cryptoPolicy: CryptoPolicy = peerHasHybridGroup
            ? CryptoPolicy(
                minimumSecurityTier: peerOnlyOffersHybrid ? .hybridPreferred : .pqcPreferred,
                allowExperimentalHybrid: true,
                advertiseHybrid: true,
                requireHybridIfAvailable: peerOnlyOffersHybrid
            )
            : .default
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
            expectedRemoteSOAPeerId: soaBinding.expectedRemotePeerId
        )
    }

    private func handleControlMessagePayload(_ messageData: Data, from peer: PeerConnection) async throws {
        guard isCurrentPeer(peer) else { return }
        let message = try JSONDecoder().decode(RemoteMessage.self, from: messageData)

        switch message.type {
        case .mouseEvent:
            let evt = try JSONDecoder().decode(RemoteMouseEvent.self, from: message.payload)
            await handleRemoteMouseEvent(evt)
        case .keyboardEvent:
            let evt = try JSONDecoder().decode(RemoteKeyboardEvent.self, from: message.payload)
            await handleRemoteKeyboardEvent(evt)
        case .screenData:
 // 正常情况下，被控制端不会收到 screenData；有就丢掉
            logger.debug("🎮 被控制端收到 screenData，忽略")
        case .clipboard:
            let shouldAcceptClipboard = peer.requestedStreamConfiguration?.clipboardSyncEnabled
                ?? RemoteDesktopSettingsManager.shared.settings.interactionSettings.enableClipboardSync
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
            let previousConfig = peer.requestedStreamConfiguration
            peer.requestedStreamConfiguration = config
            peer.remoteVideoFormats = effectiveRemoteVideoFormats(for: peer)
            await syncOutboundFramePump(for: peer)
            logger.info(
                "🎛️ 应用 viewer 流配置: peer=\(peer.id, privacy: .public) first=\(previousConfig == nil, privacy: .public) screenSharingActive=\(self.screenSharingActive, privacy: .public) transport=\(config.screenFrameTransport ?? "legacy", privacy: .public)"
            )
            logger.info(
                """
                🎛️ 收到远控流策略: preset=\(config.qualityPreset ?? "unknown", privacy: .public) \
                damage=\(config.damageTrackingEnabled ?? false, privacy: .public) \
                cursor=\(config.separateCursorChannelEnabled ?? false, privacy: .public) \
                overlay=\(config.interactionOverlayChannelEnabled ?? false, privacy: .public) \
                jitter=\(config.jitterBufferFrames ?? 0, privacy: .public) \
                recovery=\(config.lossRecoveryMode ?? "unknown", privacy: .public)
                """
            )
            configureClipboardSync(for: peer)
            cancelDeferredScreenSharingFallback(for: peer.id)
            if !screenSharingActive {
                await startScreenSharing(to: peer)
            } else {
                let requiresRestart = shouldRestartCapture(
                    previous: previousConfig,
                    current: config
                )
                let requestedRefresh = config.streamRefreshToken != previousConfig?.streamRefreshToken
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
                    captureStreamer?.requestKeyFrameRefresh(reason: "viewer-stream-refresh")
                }
                startInteractionTelemetryIfNeeded(for: peer)
            }
        case .damageReport, .cursorUpdate, .overlayUpdate:
            break
        }
    }

    private func shouldRestartCapture(
        previous: RemoteDesktopStreamConfiguration?,
        current: RemoteDesktopStreamConfiguration
    ) -> Bool {
        guard let previous else { return true }
        return previous.width != current.width
            || previous.height != current.height
            || previous.preferredCodec != current.preferredCodec
            || previous.supportedVideoFormats != current.supportedVideoFormats
            || previous.adaptiveResolutionEnabled != current.adaptiveResolutionEnabled
            || previous.targetFrameRate != current.targetFrameRate
            || previous.keyFrameInterval != current.keyFrameInterval
            || previous.lowLatencyMode != current.lowLatencyMode
            || previous.enableHardwareAcceleration != current.enableHardwareAcceleration
            || previous.enableAppleSiliconOptimization != current.enableAppleSiliconOptimization
            || previous.separateCursorChannelEnabled != current.separateCursorChannelEnabled
    }

    private func sendRemoteFrame(_ plaintext: Data, to peer: PeerConnection) async throws {
        if #available(macOS 14.0, *), let keys = peer.sessionKeys {
            let enc = try encryptRemotePayload(plaintext, with: keys)
            try await sendFramed(enc, over: peer.connection)
        } else {
            try await sendFramed(plaintext, over: peer.connection)
        }
    }

    private func encryptRemotePayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined ?? Data()
    }

    private func decryptRemotePayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    private func handleRemoteMouseEvent(_ event: RemoteMouseEvent) async {
        logger.debug("🖱️ 处理远程鼠标事件: \(event.type.rawValue, privacy: .public)")
        guard ensureAccessibilityPermission() else {
            logger.warning("⚠️ 未获得辅助功能权限，无法注入鼠标事件")
            return
        }

        // Viewer input and stream-side cursor/damage telemetry already share a top-left
        // display coordinate space. Do not flip Y again on injection, or taps in the
        // upper half land in the lower half (and vice versa).
        let point = Self.mouseInjectionPoint(for: event)

        func post(_ cgEvent: CGEvent?) {
            guard let cgEvent else { return }
            cgEvent.post(tap: .cghidEventTap)
        }

        switch event.type {
        case .mouseMoved:
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
        case .leftMouseDown:
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
        case .leftMouseUp:
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
        case .rightMouseDown:
            post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right))
        case .rightMouseUp:
            post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right))
        case .scrollUp:
            post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 24, wheel2: 0, wheel3: 0))
        case .scrollDown:
            post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -24, wheel2: 0, wheel3: 0))
        }
    }

    nonisolated static func mouseInjectionPoint(for event: RemoteMouseEvent) -> CGPoint {
        CGPoint(x: event.x, y: event.y)
    }

    private func handleRemoteKeyboardEvent(_ event: RemoteKeyboardEvent) async {
        logger.debug("⌨️ 处理远程键盘事件: keyCode=\(event.keyCode)")
        guard ensureAccessibilityPermission() else {
            logger.warning("⚠️ 未获得辅助功能权限，无法注入键盘事件")
            return
        }

        let down = (event.type == .keyDown)
        let code = CGKeyCode(event.keyCode)
        let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        cgEvent?.post(tap: .cghidEventTap)
    }

    private func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() { return true }
        // 触发系统弹窗（用户需要在系统设置中手动勾选）
        // 避免在严格并发下直接引用非 Sendable 的全局 CFStringRef
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        return AXIsProcessTrusted()
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
                        self.logger.debug("ℹ️ RemoteControl receive returned no payload before completion; awaiting next chunk")
                        receiveNextChunk()
                    }
                }
            }

            receiveNextChunk()
        }
    }

 /// 统一处理连接关闭 / 错误
    private func handleConnectionClosed(peer: PeerConnection, error: Error) async {
        guard isCurrentPeer(peer) else {
            logger.info("ℹ️ 忽略过期远控会话的关闭回调: \(peer.id, privacy: .public)")
            return
        }

        logger.error(
            "🔌 连接 \(peer.id, privacy: .public) 关闭或出错: \(error.localizedDescription, privacy: .public) screenSharingActive=\(self.screenSharingActive, privacy: .public) hasCaptureStreamer=\(self.captureStreamer != nil, privacy: .public)"
        )

        peer.connection.cancel()
        peers.removeValue(forKey: peer.id)
        connectedDevices.removeAll { $0 == peer.id }
        await peer.outboundFramePump.close()
        stopInteractionTelemetry(for: peer.id)
        screenCaptureStartupRetryCountByPeerId.removeValue(forKey: peer.id)
        invalidateScreenSharingStartupState(for: peer.id)

        if activeClipboardPeerId == peer.id {
            let clipboard = ClipboardRedirectionManager.shared
            clipboard.onLocalClipboardChanged = nil
            clipboard.disable()
            activeClipboardPeerId = nil
        }

        if connectedDevices.isEmpty {
            isControlling = false
            isBeingControlled = false
            screenSharingActive = false
            tearDownViewingRenderPipeline()
            screenCaptureWatchdogTask?.cancel()
            screenCaptureWatchdogTask = nil
            screenCaptureRestartInProgress = false
            captureStreamer?.stop()
            captureStreamer = nil
            interactionTelemetryTasksByPeerId.values.forEach { $0.cancel() }
            interactionTelemetryTasksByPeerId.removeAll()
        }
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
}
