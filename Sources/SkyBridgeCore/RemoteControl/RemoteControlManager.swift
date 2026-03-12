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
private struct ScreenData: Codable, Sendable {
    let width: Int
    let height: Int
    let imageData: Data
    let timestamp: TimeInterval
 /// "hevc" / "h264" / 其他（静态图像）
    let format: String?
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
        }
    }
}

// MARK: - 连接状态封装（每个设备一条 NWConnection）

private final class PeerConnection {
    let id: String
    let connection: NWConnection
    var remoteVideoFormats: Set<String>
    var requestedStreamConfiguration: RemoteDesktopStreamConfiguration?
    let clipboardSessionId: UUID
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

 // MARK: 内部组件

    private let renderer = RemoteFrameRenderer()
    private var captureStreamer: ScreenCaptureKitStreamer?
    private var screenCaptureWatchdogTask: Task<Void, Never>?
    private var screenCaptureRestartInProgress = false
    private var peers: [String: PeerConnection] = [:]
    private let maxFramedMessageBytes = 8_000_000
    private var latestOutboundScreenFrameByPeerId: [String: ScreenData] = [:]
    private var latestOutboundDamageReportByPeerId: [String: RemoteDesktopDamageReport] = [:]
    private var outboundScreenSenderBusy: Set<String> = []
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
    }

    public override func performInitialization() async {
        logger.info("🖥️ RemoteControlManager performInitialization 完成")
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
            deviceId: device.id.uuidString,
            connection: connection,
            remoteVideoFormats: device.remoteVideoFormats
        )
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
        peers[deviceId] = peer
        latestOutboundScreenFrameByPeerId.removeValue(forKey: deviceId)
        latestOutboundDamageReportByPeerId.removeValue(forKey: deviceId)
        outboundScreenSenderBusy.remove(deviceId)

        if !connectedDevices.contains(deviceId) {
            connectedDevices.append(deviceId)
        }
        isControlling = true

 // 启动屏幕数据接收循环
        startReceivingScreenData(from: peer)
    }

 /// 停止控制指定设备
    public func stopControlling(deviceId: String) {
        logger.info("⏹️ 停止控制远程设备: \(deviceId, privacy: .public)")
        guard let peer = peers[deviceId] else { return }

        peer.connection.cancel()
        peers.removeValue(forKey: deviceId)
        connectedDevices.removeAll { $0 == deviceId }
        latestOutboundScreenFrameByPeerId.removeValue(forKey: deviceId)
        latestOutboundDamageReportByPeerId.removeValue(forKey: deviceId)
        outboundScreenSenderBusy.remove(deviceId)

        if connectedDevices.isEmpty {
            isControlling = false
        }
    }

 /// 作为「被控制端」开放远程控制
    public func allowRemoteControl(from deviceId: String, connection: NWConnection) async {
        logger.info("🖥️ 允许远程控制来自设备: \(deviceId, privacy: .public)")

        let peer = PeerConnection(id: deviceId, connection: connection)
        peers[deviceId] = peer

        // Optional: enable P2P handshake over this TCP channel (best-effort).
        if #available(macOS 14.0, *) {
            Task { [weak self, weak peer] in
                guard let self, let peer else { return }
                do {
                    let identity = try await DeviceIdentityKeyManager.shared.getOrCreateProtocolSigningKey()
                    let offeredSuites = ClassicCryptoProvider().supportedSuites
                    let transport = RemoteControlHandshakeTransport(connection: peer.connection)
                    let driver = try HandshakeDriver(
                        transport: transport,
                        cryptoProvider: ClassicCryptoProvider(),
                        protocolSignatureProvider: ClassicSignatureProvider(),
                        protocolSigningKeyHandle: identity.keyHandle,
                        sigAAlgorithm: .ed25519,
                        identityPublicKey: identity.publicKey,
                        offeredSuites: offeredSuites,
                        policy: .default,
                        cryptoPolicy: .default
                    )
                    peer.handshakeDriver = driver
                    peer.handshakePeer = PeerIdentifier(deviceId: deviceId, displayName: nil, address: nil)
                    self.logger.info("🔐 RemoteControl P2P handshake enabled for \(deviceId, privacy: .public)")
                } catch {
                    self.logger.info("🔐 RemoteControl P2P handshake disabled (best-effort init failed): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if !connectedDevices.contains(deviceId) {
            connectedDevices.append(deviceId)
        }

        isBeingControlled = true

 // 1) 先开始接收对端发来的输入事件 / 流配置
        startReceivingRemoteEvents(from: peer)
        await waitForInitialStreamConfigurationIfAvailable(for: peer)

 // 2) 再启动首个推流，尽量避免在未拿到 viewer 能力前回退到 JPEG
        await startScreenSharing(to: peer)
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
        latestOutboundScreenFrameByPeerId.removeValue(forKey: deviceId)
        latestOutboundDamageReportByPeerId.removeValue(forKey: deviceId)
        outboundScreenSenderBusy.remove(deviceId)
        stopInteractionTelemetry(for: deviceId)

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

 // MARK: - 输入事件发送（控制端 -> 被控制端）

    public func sendMouseEvent(_ event: RemoteMouseEvent, to deviceId: String) async throws {
        guard let peer = peers[deviceId] else {
            throw RemoteControlError.deviceNotConnected
        }
        let eventData = try JSONEncoder().encode(event)
        let message = RemoteMessage(type: .mouseEvent, payload: eventData)
        let payload = try JSONEncoder().encode(message)
        try await sendRemoteFrame(payload, to: peer)
        logger.debug("🖱️ 发送鼠标事件 \(event.type.rawValue, privacy: .public) -> \(deviceId, privacy: .public)")
    }

    public func sendKeyboardEvent(_ event: RemoteKeyboardEvent, to deviceId: String) async throws {
        guard let peer = peers[deviceId] else {
            throw RemoteControlError.deviceNotConnected
        }
        let eventData = try JSONEncoder().encode(event)
        let message = RemoteMessage(type: .keyboardEvent, payload: eventData)
        let payload = try JSONEncoder().encode(message)
        try await sendRemoteFrame(payload, to: peer)
        logger.debug("⌨️ 发送键盘事件 keyCode=\(event.keyCode) -> \(deviceId, privacy: .public)")
    }

 // MARK: - 屏幕共享（被控制端 -> 控制端）

 /// 启动本机屏幕捕获 + 硬件编码 + 推流
    private func startScreenSharing(to peer: PeerConnection) async {
        logger.info("📺 开始屏幕共享（ScreenCaptureKit + 硬件编码） -> \(peer.id, privacy: .public)")

        if !(await ensureScreenCapturePermission()) {
            logger.warning(
                "⚠️ 屏幕录制权限预检未通过；若你刚授权，请先完整退出并重新打开 App。仍将继续尝试启动采集。"
            )
        }

        screenSharingActive = true

        let streamer = ScreenCaptureKitStreamer()
        captureStreamer = streamer
        screenCaptureWatchdogTask?.cancel()
        screenCaptureWatchdogTask = nil
        streamer.onCaptureIssue = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.restartScreenSharingIfNeeded(for: peer.id, reason: reason)
            }
        }

        streamer.onEncodedFrame = { [weak self] data, width, height, frameType in
            guard let self else { return }
            // 在主线程捕获必要的值
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
            Task { [weak self] in
                guard let self else { return }
                let frame = ScreenData(
                    width: width,
                    height: height,
                    imageData: data,
                    timestamp: Date().timeIntervalSince1970,
                    format: fmt
                )
                await self.enqueueOutboundScreenFrame(frame, to: peer)
            }
        }
        streamer.onDamageReport = { [weak self] report in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.noteOutboundDamageReport(report, to: peer)
            }
        }

        let request = effectiveStreamRequest(for: peer)
        let policy = RemoteControlStreamPolicySelector.select(
            request: request,
            peerFormats: effectiveRemoteVideoFormats(for: peer),
            thermalState: ProcessInfo.processInfo.thermalState,
            isAppleSilicon: Self.isAppleSiliconRuntime
        )
        logger.info(
            """
            📺 推流参数: \(Int(policy.preferredSize.width))x\(Int(policy.preferredSize.height)) \
            @\(policy.targetFrameRate)fps gop=\(policy.keyFrameInterval) \
            codec=\(Self.codecName(policy.codec), privacy: .public) \
            reason=\(policy.reason, privacy: .public)
            """
        )

        do {
            try await streamer.start(
                preferredCodec: policy.codec,
                preferredSize: policy.preferredSize,
                targetFPS: policy.targetFrameRate,
                keyFrameInterval: policy.keyFrameInterval,
                captureCursorInVideo: !(peer.requestedStreamConfiguration?.separateCursorChannelEnabled ?? false),
                bitstreamFormat: .annexB
            )
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
                    let now = Date()
                    let sampleAge = now.timeIntervalSince(health.lastSampleBufferAt)
                    let encodedAge = now.timeIntervalSince(health.lastEncodedFrameAt)
                    let hasSampleFlow = health.lastSampleBufferAt != .distantPast

                    if hasSampleFlow && sampleAge < 1.5 && encodedAge > 2.0 {
                        self.logger.warning(
                            "⚠️ 检测到录屏编码停滞：peer=\(peer.id, privacy: .public) sampleAge=\(sampleAge, privacy: .public) encodedAge=\(encodedAge, privacy: .public)"
                        )
                        await self.restartScreenSharingIfNeeded(for: peer.id, reason: "encoded-stall")
                        break
                    }
                }
            }
        } catch {
            logger.error(
                "❌ 启动 ScreenCaptureKitStreamer 失败: \(error.localizedDescription, privacy: .public). 请确认已在“系统设置 > 隐私与安全 > 录屏与系统录音”中为当前运行的 App 条目授权，必要时完全退出后重开。"
            )
            screenSharingActive = false
            stopRemoteControl(from: peer.id)
        }
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

    private func startInteractionTelemetryIfNeeded(for peer: PeerConnection) {
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
                guard self.peers[peer.id] != nil, self.isBeingControlled else { break }

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

    private func waitForInitialStreamConfigurationIfAvailable(
        for peer: PeerConnection,
        timeout: Duration = .milliseconds(900)
    ) async {
        guard peer.requestedStreamConfiguration == nil else { return }

        let deadline = ContinuousClock.now + timeout
        while peer.requestedStreamConfiguration == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if let config = peer.requestedStreamConfiguration {
            logger.info(
                """
                📺 已收到 viewer 流配置: preferred=\(config.preferredCodec ?? "auto", privacy: .public) \
                formats=\(config.supportedVideoFormats.joined(separator: ","), privacy: .public) \
                fps=\(config.targetFrameRate, privacy: .public)
                """
            )
        } else {
            logger.info("📺 未在首帧前收到 viewer 流配置，先使用兼容默认值启动推流")
        }
    }

    private func ensureScreenCapturePermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        // Best effort: prompt once if the app has not been granted Screen Recording yet.
        let requested = await MainActor.run { CGRequestScreenCaptureAccess() }
        if requested {
            return true
        }

        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            logger.warning("⚠️ SCShareableContent.excludingDesktopWindows 预检失败: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func enqueueOutboundScreenFrame(_ frame: ScreenData, to peer: PeerConnection) async {
        latestOutboundScreenFrameByPeerId[peer.id] = frame
        guard !outboundScreenSenderBusy.contains(peer.id) else { return }
        outboundScreenSenderBusy.insert(peer.id)

        while true {
            guard let next = latestOutboundScreenFrameByPeerId.removeValue(forKey: peer.id) else { break }
            guard peers[peer.id] != nil else {
                latestOutboundScreenFrameByPeerId.removeValue(forKey: peer.id)
                latestOutboundDamageReportByPeerId.removeValue(forKey: peer.id)
                break
            }

            do {
                if let damageReport = latestOutboundDamageReportByPeerId.removeValue(forKey: peer.id),
                   peer.requestedStreamConfiguration?.damageTrackingEnabled ?? true {
                    try await sendRemoteControlPayload(
                        damageReport,
                        type: .damageReport,
                        to: peer
                    )
                }
                let encodedScreen = try JSONEncoder().encode(next)
                let message = RemoteMessage(type: .screenData, payload: encodedScreen)
                let payload = try JSONEncoder().encode(message)
                try await sendRemoteFrame(payload, to: peer)
            } catch {
                logger.error("❌ 发送屏幕数据失败: \(error.localizedDescription, privacy: .public)")
                break
            }
        }

        outboundScreenSenderBusy.remove(peer.id)
    }

    private func noteOutboundDamageReport(
        _ report: RemoteDesktopDamageReport,
        to peer: PeerConnection
    ) async {
        latestOutboundDamageReportByPeerId[peer.id] = report
    }

    private func sendRemoteControlPayload<T: Encodable>(
        _ payload: T,
        type: RemoteMessage.MessageType,
        to peer: PeerConnection
    ) async throws {
        let encodedPayload = try JSONEncoder().encode(payload)
        let message = RemoteMessage(type: type, payload: encodedPayload)
        let framedMessage = try JSONEncoder().encode(message)
        try await sendRemoteFrame(framedMessage, to: peer)
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
            let payload = RemoteClipboardPayload(mimeType: mimeType, data: data)
            let encoded = try JSONEncoder().encode(payload)
            let message = RemoteMessage(type: .clipboard, payload: encoded)
            let plaintext = try JSONEncoder().encode(message)
            try await sendRemoteFrame(plaintext, to: peer)
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
                    if buffer.count > self.maxFramedMessageBytes * 2 {
                        throw RemoteControlError.invalidMessageLength(buffer.count)
                    }

                    while let messageData = try self.nextFramedMessage(
                        from: &buffer,
                        maxMessageBytes: self.maxFramedMessageBytes
                    ) {

                        let plain: Data
                        if #available(macOS 14.0, *), let keys = peer.sessionKeys {
                            plain = try self.decryptRemotePayload(messageData, with: keys)
                        } else {
                            plain = messageData
                        }
                        try await self.handleScreenMessagePayload(plain)
                    }
                } catch {
                    await self.handleConnectionClosed(peerId: peer.id, error: error)
                    break
                }
            }
        }
    }

 /// 处理收到的 .screenData 消息
    private func handleScreenMessagePayload(_ messageData: Data) async throws {
        let message = try JSONDecoder().decode(RemoteMessage.self, from: messageData)
        guard message.type == .screenData else {
            logger.debug("📺 收到非 screenData 消息，丢弃: \(message.type.rawValue, privacy: .public)")
            return
        }

        let screenData = try JSONDecoder().decode(ScreenData.self, from: message.payload)
        logger.debug("📺 接收到屏幕数据: \(screenData.width)x\(screenData.height)")

        guard !screenData.imageData.isEmpty else { return }

        if let fmt = screenData.format?.lowercased(), fmt == "hevc" || fmt == "h264" || fmt == "bgra" {
            let frameType: RemoteFrameType
            switch fmt {
            case "hevc": frameType = .hevc
            case "h264": frameType = .h264
            default: frameType = .bgra
            }

            let metrics = renderer.processFrame(
                data: screenData.imageData,
                width: screenData.width,
                height: screenData.height,
                stride: 0,
                type: frameType
            )
            await MainActor.run {
                self.updateMetrics(metrics)
            }
        } else {
 // 兜底：当成静态图像用 ImageIO 解码
            await handleStaticImageFallback(screenData)
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
                    if buffer.count > self.maxFramedMessageBytes * 2 {
                        throw RemoteControlError.invalidMessageLength(buffer.count)
                    }

                    while let messageData = try self.nextFramedMessage(
                        from: &buffer,
                        maxMessageBytes: self.maxFramedMessageBytes
                    ) {

                        try await self.handleInboundRemoteFrame(from: peer, frame: messageData)
                    }
                } catch {
                    await self.handleConnectionClosed(peerId: peer.id, error: error)
                    break
                }
            }
        }
    }

    private func handleInboundRemoteFrame(from peer: PeerConnection, frame: Data) async throws {
        // If handshake established, frames become AES-GCM ciphertext of RemoteMessage JSON.
        if #available(macOS 14.0, *), let keys = peer.sessionKeys {
            let plain = try decryptRemotePayload(frame, with: keys)
            try await handleControlMessagePayload(plain, from: peer)
            return
        }

        // Best-effort: try JSON first (legacy), otherwise treat as handshake bytes if enabled.
        if let _ = try? JSONDecoder().decode(RemoteMessage.self, from: frame) {
            try await handleControlMessagePayload(frame, from: peer)
            return
        }

        if #available(macOS 14.0, *), let driver = peer.handshakeDriver, let hPeer = peer.handshakePeer {
            await driver.handleMessage(frame, from: hPeer)
            let st = await driver.getCurrentState()
            if case .established(let keys) = st {
                peer.sessionKeys = keys
                peer.handshakeDriver = nil
                self.logger.info("🔐 RemoteControl handshake established for \(peer.id, privacy: .public)")
            }
            return
        }
    }

    private func handleControlMessagePayload(_ messageData: Data, from peer: PeerConnection) async throws {
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
            if screenSharingActive {
                let requiresRestart = shouldRestartCapture(
                    previous: previousConfig,
                    current: config
                )
                let requestedRefresh = config.streamRefreshToken != previousConfig?.streamRefreshToken
                if requiresRestart {
                    captureStreamer?.stop()
                    captureStreamer = nil
                    Task { [weak self] in
                        guard let self else { return }
                        await self.startScreenSharing(to: peer)
                    }
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

        let displayID = CGMainDisplayID()
        let screenH = Double(CGDisplayPixelsHigh(displayID))
        let point = CGPoint(x: event.x, y: screenH - event.y) // iOS 触摸通常以左上为原点，macOS CGEvent 以左下为原点

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
        guard length > 0, length <= maxMessageBytes else {
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data {
                    cont.resume(returning: data)
                } else {
 // data == nil 且无 error，一般视为连接关闭
                    cont.resume(returning: Data())
                }
            }
        }
    }

 /// 统一处理连接关闭 / 错误
    private func handleConnectionClosed(peerId: String, error: Error) async {
        logger.error("🔌 连接 \(peerId, privacy: .public) 关闭或出错: \(error.localizedDescription, privacy: .public)")

        peers[peerId]?.connection.cancel()
        peers.removeValue(forKey: peerId)
        connectedDevices.removeAll { $0 == peerId }
        latestOutboundScreenFrameByPeerId.removeValue(forKey: peerId)
        outboundScreenSenderBusy.remove(peerId)

        if connectedDevices.isEmpty {
            isControlling = false
            isBeingControlled = false
            screenSharingActive = false
        }
    }

 // MARK: - 静态图像 -> Metal 纹理

    private func createTexture(from image: CGImage, device: MTLDevice) throws -> MTLTexture {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8

        let colorSpace = CGColorSpaceCreateDeviceRGB()
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
