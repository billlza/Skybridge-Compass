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

// MARK: - 基础模型：消息/事件/屏幕帧

/// 远程消息“信封”：所有消息都走它，避免裸 Data 粘包
private struct RemoteMessage: Codable {
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
private struct ScreenData: Codable {
    let width: Int
    let height: Int
    let imageData: Data
    let timestamp: TimeInterval
 /// "hevc" / "h264" / 其他（静态图像）
    let format: String?
}

/// 鼠标事件类型
public enum MouseEventType: String, Codable {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case mouseMoved
    case scrollUp
    case scrollDown
}

/// 键盘事件类型
public enum KeyboardEventType: String, Codable {
    case keyDown
    case keyUp
}

/// 远程鼠标事件
public struct RemoteMouseEvent: Codable {
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
public struct RemoteKeyboardEvent: Codable {
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

    init(id: String, connection: NWConnection) {
        self.id = id
        self.connection = connection
        self.queue = DispatchQueue(
            label: "com.skybridge.remote.\(id)",
            qos: .userInitiated
        )
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

        if connectedDevices.isEmpty {
            isControlling = false
        }
    }

 /// 作为「被控制端」开放远程控制
    public func allowRemoteControl(from deviceId: String, connection: NWConnection) async {
        logger.info("🖥️ 允许远程控制来自设备: \(deviceId, privacy: .public)")

        let peer = PeerConnection(id: deviceId, connection: connection)
        peers[deviceId] = peer

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
        try await sendFramed(payload, over: peer.connection)
        logger.debug("🖱️ 发送鼠标事件 \(event.type.rawValue, privacy: .public) -> \(deviceId, privacy: .public)")
    }

    public func sendKeyboardEvent(_ event: RemoteKeyboardEvent, to deviceId: String) async throws {
        guard let peer = peers[deviceId] else {
            throw RemoteControlError.deviceNotConnected
        }
        let eventData = try JSONEncoder().encode(event)
        let message = RemoteMessage(type: .keyboardEvent, payload: eventData)
        let payload = try JSONEncoder().encode(message)
        try await sendFramed(payload, over: peer.connection)
        logger.debug("⌨️ 发送键盘事件 keyCode=\(event.keyCode) -> \(deviceId, privacy: .public)")
    }

 // MARK: - 屏幕共享（被控制端 -> 控制端）

 /// 启动本机屏幕捕获 + 硬件编码 + 推流
    private func startScreenSharing(to peer: PeerConnection) async {
        logger.info("📺 开始屏幕共享（ScreenCaptureKit + 硬件编码） -> \(peer.id, privacy: .public)")
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
                do {
                    let screen = ScreenData(
                        width: width,
                        height: height,
                        imageData: data,
                        timestamp: Date().timeIntervalSince1970,
                        format: fmt
                    )
                    let encodedScreen = try JSONEncoder().encode(screen)
                    let message = RemoteMessage(type: .screenData, payload: encodedScreen)
                    let payload = try JSONEncoder().encode(message)

                    try await self.sendFramed(payload, over: peer.connection)
                } catch {
                    self.logger.error("❌ 发送屏幕数据失败: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // iOS 端目前优先走 JPEG（避免 H.264/HEVC NAL 兼容问题；后续可升级到完整 H26x 解码链路）
        let settings = RemoteDesktopSettingsManager.shared.settings
        let codec: RemoteFrameType = .bgra
        let fps = settings.displaySettings.targetFrameRate
        let gop = settings.displaySettings.keyFrameInterval

        do {
            try await streamer.start(
                preferredCodec: codec,
                preferredSize: nil,
                targetFPS: fps,
                keyFrameInterval: gop
            )
        } catch {
            logger.error("❌ 启动 ScreenCaptureKitStreamer 失败: \(error.localizedDescription, privacy: .public)")
            screenSharingActive = false
        }
    }

 /// 控制端：从对端接收屏幕数据并渲染
    private func startReceivingScreenData(from peer: PeerConnection) {
        logger.info("📺 开始接收屏幕数据 <- \(peer.id, privacy: .public)")

        Task { [weak self, weak peer] in
            guard let self, let peer else { return }

            let maxMessageBytes = 8_000_000
            var buffer = Data()

            while true {
                do {
                    let chunk = try await self.receiveChunk(from: peer.connection)
                    if chunk.isEmpty {
                        throw RemoteControlError.connectionClosed
                    }
                    buffer.append(chunk)
                    if buffer.count > maxMessageBytes * 2 {
                        throw RemoteControlError.invalidMessageLength(buffer.count)
                    }

                    while buffer.count >= 4 {
                        let length = buffer.prefix(4).withUnsafeBytes { ptr -> Int in
                            let raw = ptr.load(as: UInt32.self)
                            return Int(UInt32(bigEndian: raw))
                        }
                        guard length > 0, length <= maxMessageBytes else {
                            throw RemoteControlError.invalidMessageLength(length)
                        }
                        guard buffer.count >= 4 + length else { break }

                        let messageData = buffer.subdata(in: 4 ..< 4 + length)
                        buffer.removeFirst(4 + length)

                        try await self.handleScreenMessagePayload(messageData)
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

                    while buffer.count >= 4 {
                        let length = buffer.prefix(4).withUnsafeBytes { ptr -> Int in
                            let raw = ptr.load(as: UInt32.self)
                            return Int(UInt32(bigEndian: raw))
                        }
                        guard buffer.count >= 4 + length else { break }

                        let messageData = buffer.subdata(in: 4 ..< 4 + length)
                        buffer.removeFirst(4 + length)

                        try await self.handleControlMessagePayload(messageData)
                    }
                } catch {
                    await self.handleConnectionClosed(peerId: peer.id, error: error)
                    break
                }
            }
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
