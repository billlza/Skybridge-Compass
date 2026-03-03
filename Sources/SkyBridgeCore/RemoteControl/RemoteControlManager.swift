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

    init(id: String, connection: NWConnection) {
        self.id = id
        self.connection = connection
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
/// - 从连接上接收 .mouseEvent / .keyboardEvent，再用 CGEvent 注入（当前只留接口位）
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
    private var peers: [String: PeerConnection] = [:]
    private let maxFramedMessageBytes = 8_000_000
    private var latestOutboundScreenFrameByPeerId: [String: ScreenData] = [:]
    private var outboundScreenSenderBusy: Set<String> = []

 /// Metal 设备，作为静态图像兜底（ImageIO -> CGImage -> MTLTexture）
    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

 // MARK: 初始化

    public init() {
        super.init(category: "RemoteControl")

        logger.info("🖥️ RemoteControlManager 初始化")

 // 将渲染器输出绑定到纹理流
        renderer.frameHandler = { [weak self] texture in
            guard let self else { return }
            Task { @MainActor in
                self.textureFeed.update(texture: texture)
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
        logger.info("🎮 开始控制远程设备: \(deviceId, privacy: .public)")

        let peer = PeerConnection(id: deviceId, connection: connection)
        peers[deviceId] = peer
        latestOutboundScreenFrameByPeerId.removeValue(forKey: deviceId)
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

 // 1) 开始推送本机屏幕数据
        await startScreenSharing(to: peer)

 // 2) 开始接收对端发来的输入事件
        startReceivingRemoteEvents(from: peer)
    }

 /// 作为被控制端，关闭来自某设备的远程控制
    public func stopRemoteControl(from deviceId: String) {
        logger.info("⏹️ 停止被远程控制来自设备: \(deviceId, privacy: .public)")
        guard let peer = peers[deviceId] else { return }

        peer.connection.cancel()
        peers.removeValue(forKey: deviceId)
        connectedDevices.removeAll { $0 == deviceId }
        latestOutboundScreenFrameByPeerId.removeValue(forKey: deviceId)
        outboundScreenSenderBusy.remove(deviceId)

        if connectedDevices.isEmpty {
            isBeingControlled = false
            screenSharingActive = false
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

        guard await ensureScreenCapturePermission() else {
            logger.error("❌ 屏幕录制权限未授权，无法开始屏幕共享。请在 系统设置 -> 隐私与安全 -> 屏幕录制 中授权 SkyBridge。")
            screenSharingActive = false
            stopRemoteControl(from: peer.id)
            return
        }

        screenSharingActive = true

        let streamer = ScreenCaptureKitStreamer()
        captureStreamer = streamer

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

        // iOS 端目前优先走 JPEG（避免 H.264/HEVC NAL 兼容问题；后续可升级到完整 H26x 解码链路）
        let settings = RemoteDesktopSettingsManager.shared.settings
        let codec: RemoteFrameType = .bgra
        let preferredSize = preferredCaptureSize(for: settings.displaySettings.resolution)
        let fps = max(12, min(settings.displaySettings.targetFrameRate, 30))
        let gop = max(10, min(settings.displaySettings.keyFrameInterval, fps * 2))
        logger.info(
            "📺 推流参数: \(Int(preferredSize.width))x\(Int(preferredSize.height)) @\(fps)fps gop=\(gop)"
        )

        do {
            try await streamer.start(
                preferredCodec: codec,
                preferredSize: preferredSize,
                targetFPS: fps,
                keyFrameInterval: gop
            )
        } catch {
            logger.error("❌ 启动 ScreenCaptureKitStreamer 失败: \(error.localizedDescription, privacy: .public)")
            screenSharingActive = false
            stopRemoteControl(from: peer.id)
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
                break
            }

            do {
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

    private func preferredCaptureSize(for resolution: ResolutionSetting) -> CGSize {
        if let dim = resolution.dimensions {
            return CGSize(width: dim.width, height: dim.height)
        }

        let fallback = CGSize(width: 1280, height: 720)
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else {
            return fallback
        }

        let nativeWidth = CGFloat(mode.width)
        let nativeHeight = CGFloat(mode.height)
        guard nativeWidth > 0, nativeHeight > 0 else {
            return fallback
        }

        let longEdge = max(nativeWidth, nativeHeight)
        let maxLongEdge: CGFloat = 1280
        guard longEdge > maxLongEdge else {
            return CGSize(width: nativeWidth, height: nativeHeight)
        }

        let scale = maxLongEdge / longEdge
        return CGSize(
            width: max(640, floor(nativeWidth * scale)),
            height: max(360, floor(nativeHeight * scale))
        )
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
            try await handleControlMessagePayload(plain)
            return
        }

        // Best-effort: try JSON first (legacy), otherwise treat as handshake bytes if enabled.
        if let _ = try? JSONDecoder().decode(RemoteMessage.self, from: frame) {
            try await handleControlMessagePayload(frame)
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

    private func handleControlMessagePayload(_ messageData: Data) async throws {
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
        }
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
