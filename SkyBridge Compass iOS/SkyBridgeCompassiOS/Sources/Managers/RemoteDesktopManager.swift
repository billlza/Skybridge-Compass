//
// RemoteDesktopManager.swift
// SkyBridgeCompassiOS
//
// 远程桌面管理器 - iOS 作为查看器/控制端
// 支持查看和控制 macOS、Windows、Linux 设备的屏幕
//
// iOS 限制说明：
// - iOS 不能作为被控端（系统限制，无法注入输入事件）
// - iOS 可以使用 ReplayKit 进行屏幕广播，但只能用于直播
// - iOS 主要作为远程桌面的查看器/控制端
//

import Foundation
import Network
import AVFoundation
import VideoToolbox
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Remote Desktop Constants

/// 远程桌面常量
public enum RemoteDesktopConstants {
    /// 默认端口（5901：避免与系统 VNC 5900 冲突；与 macOS `RemoteControlServer` 对齐）
    public static let defaultPort: UInt16 = 5901
    
    /// 默认帧率
    public static let defaultFrameRate: Int = 30
    
    /// 默认比特率 (5 Mbps)
    public static let defaultBitrate: UInt64 = 5_000_000
    
    /// 心跳间隔（秒）
    public static let heartbeatInterval: TimeInterval = 5
    
    /// 连接超时（秒）
    public static let connectionTimeout: TimeInterval = 30
}

// MARK: - Remote Message Types

/// 远程消息类型（与 macOS `RemoteControlManager` 对齐）
public enum RemoteMessageType: String, Codable, Sendable {
    case screenData = "screenData"
    case mouseEvent = "mouseEvent"
    case keyboardEvent = "keyboardEvent"
}

/// 远程消息（与 macOS `RemoteControlManager.RemoteMessage` 对齐）
public struct RemoteMessage: Codable, Sendable {
    public let type: RemoteMessageType
    public let payload: Data
    
    public init(type: RemoteMessageType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

// MARK: - Screen Data

/// 屏幕数据（与 macOS `RemoteControlManager.ScreenData` 对齐）
public struct ScreenData: Codable, Sendable {
    public let width: Int
    public let height: Int
    public let imageData: Data
    public let timestamp: TimeInterval
    public let format: String? // "jpeg" / "hevc" / "h264" / "bgra"
    
    public init(width: Int, height: Int, imageData: Data, timestamp: TimeInterval, format: String? = nil) {
        self.width = width
        self.height = height
        self.imageData = imageData
        self.timestamp = timestamp
        self.format = format
    }
}

// MARK: - Mouse Event

/// 鼠标事件类型（与 macOS `RemoteControlManager.MouseEventType` 对齐）
public enum MouseEventType: String, Codable, Sendable {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case mouseMoved
    case scrollUp
    case scrollDown
}

/// 鼠标事件（与 macOS `RemoteControlManager.RemoteMouseEvent` 对齐）
public struct MouseEvent: Codable, Sendable {
    public let type: MouseEventType
    public let x: Double
    public let y: Double
    public let timestamp: TimeInterval
    
    public init(type: MouseEventType, x: Double, y: Double, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.type = type
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }
}

// MARK: - Keyboard Event

/// 键盘事件类型（与 macOS `RemoteControlManager.KeyboardEventType` 对齐）
public enum KeyboardEventType: String, Codable, Sendable {
    case keyDown
    case keyUp
}

/// 键盘事件（与 macOS `RemoteControlManager.RemoteKeyboardEvent` 对齐）
public struct KeyboardEvent: Codable, Sendable {
    public let type: KeyboardEventType
    public let keyCode: Int
    public let timestamp: TimeInterval
    
    public init(type: KeyboardEventType, keyCode: Int, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.type = type
        self.keyCode = keyCode
        self.timestamp = timestamp
    }
}

// MARK: - Connection State

/// 远程桌面连接状态
public enum RemoteDesktopState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case streaming
    case error(String)

    public static func == (lhs: RemoteDesktopState, rhs: RemoteDesktopState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.streaming, .streaming):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Remote Desktop Error

/// 远程桌面错误
public enum RemoteDesktopError: Error, LocalizedError, Sendable {
    case connectionFailed(String)
    case streamingFailed(String)
    case decodingFailed(String)
    case timeout
    case notSupported(String)
    case permissionDenied
    case disconnected
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): return "连接失败: \(reason)"
        case .streamingFailed(let reason): return "流媒体失败: \(reason)"
        case .decodingFailed(let reason): return "解码失败: \(reason)"
        case .timeout: return "连接超时"
        case .notSupported(let feature): return "不支持: \(feature)"
        case .permissionDenied: return "权限被拒绝"
        case .disconnected: return "连接已断开"
        }
    }
}

// MARK: - Video Decoder

/// 视频解码器
@available(iOS 17.0, *)
actor VideoDecoder {
    private enum Codec: Sendable {
        case h264
        case hevc
    }

    private final class DecodeResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CGImage?

        func set(_ value: CGImage?) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var activeCodec: Codec?
    private var h264SPS: Data?
    private var h264PPS: Data?
    private var hevcVPS: Data?
    private var hevcSPS: Data?
    private var hevcPPS: Data?
    private var lastDecodedFrame: CGImage?
    
    /// 解码 H.264/HEVC 帧
    func decode(screenData: ScreenData) async throws -> CGImage? {
        let format = (screenData.format ?? "").lowercased()
        let payload = screenData.imageData

        if format.isEmpty {
            return decodeStaticImage(payload)
        }

        switch format {
        case "jpeg", "jpg":
            return decodeJPEG(payload)
        case "h264":
            return try decodeVideoFrame(payload, codec: .h264)
        case "hevc":
            return try decodeVideoFrame(payload, codec: .hevc)
        case "bgra":
            return decodeBGRA(payload, width: screenData.width, height: screenData.height)
        default:
            return decodeStaticImage(payload)
        }
    }
    
    private func decodeJPEG(_ data: Data) -> CGImage? {
        guard let dataProvider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                jpegDataProviderSource: dataProvider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return image
    }
    
    private func decodeStaticImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    
    private func decodeBGRA(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let expectedMinBytes = width * height * 4
        guard data.count >= expectedMinBytes else { return nil }

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func decodeVideoFrame(_ data: Data, codec: Codec) throws -> CGImage? {
        let requiresReset = updateParameterSetsIfPresent(from: data, codec: codec)
        if activeCodec != codec || requiresReset {
            resetDecoderState(keepLastFrame: true)
            activeCodec = codec
        }

        if formatDescription == nil {
            try buildFormatDescriptionIfPossible(codec: codec)
        }
        guard let formatDescription else { return lastDecodedFrame }

        if decompressionSession == nil {
            try createDecompressionSession(formatDescription: formatDescription)
        }
        guard let session = decompressionSession else { return lastDecodedFrame }

        let sampleBuffer = try makeSampleBuffer(naluData: data, formatDescription: formatDescription)

        let box = DecodeResultBox()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            var out: CGImage?
            if VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &out) == noErr {
                box.set(out)
            }
        }

        guard status == noErr else {
            return lastDecodedFrame
        }

        let decodedImage = box.get()
        if let decodedImage {
            lastDecodedFrame = decodedImage
        }
        return decodedImage ?? lastDecodedFrame
    }

    private func resetDecoderState(keepLastFrame: Bool) {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        if !keepLastFrame {
            lastDecodedFrame = nil
        }
    }

    private func updateParameterSetsIfPresent(from data: Data, codec: Codec) -> Bool {
        var didChange = false

        func update(_ current: inout Data?, new: Data) {
            if current != new {
                current = new
                didChange = true
            }
        }

        for nalu in parseNALUnits(from: data) {
            guard let first = nalu.first else { continue }
            switch codec {
            case .h264:
                let type = Int(first & 0x1F)
                switch type {
                case 7: update(&h264SPS, new: nalu)
                case 8: update(&h264PPS, new: nalu)
                default: break
                }
            case .hevc:
                let type = Int((first >> 1) & 0x3F)
                switch type {
                case 32: update(&hevcVPS, new: nalu)
                case 33: update(&hevcSPS, new: nalu)
                case 34: update(&hevcPPS, new: nalu)
                default: break
                }
            }
        }

        return didChange
    }

    private func buildFormatDescriptionIfPossible(codec: Codec) throws {
        switch codec {
        case .h264:
            guard let sps = h264SPS, let pps = h264PPS else { return }
            var out: CMFormatDescription?
            let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
                guard let spsBase = spsRaw.baseAddress else { return -1 }
                return pps.withUnsafeBytes { ppsRaw -> OSStatus in
                    guard let ppsBase = ppsRaw.baseAddress else { return -1 }
                    let pointers: [UnsafePointer<UInt8>] = [
                        spsBase.assumingMemoryBound(to: UInt8.self),
                        ppsBase.assumingMemoryBound(to: UInt8.self)
                    ]
                    let sizes: [Int] = [sps.count, pps.count]
                    return pointers.withUnsafeBufferPointer { ptrs in
                        sizes.withUnsafeBufferPointer { sz in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: ptrs.count,
                                parameterSetPointers: ptrs.baseAddress!,
                                parameterSetSizes: sz.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &out
                            )
                        }
                    }
                }
            }
            guard status == noErr, let desc = out else {
                throw RemoteDesktopError.decodingFailed("Failed to build H.264 format description (status=\(status))")
            }
            formatDescription = desc

        case .hevc:
            guard let vps = hevcVPS, let sps = hevcSPS, let pps = hevcPPS else { return }
            var out: CMFormatDescription?
            let status = vps.withUnsafeBytes { vpsRaw -> OSStatus in
                guard let vpsBase = vpsRaw.baseAddress else { return -1 }
                return sps.withUnsafeBytes { spsRaw -> OSStatus in
                    guard let spsBase = spsRaw.baseAddress else { return -1 }
                    return pps.withUnsafeBytes { ppsRaw -> OSStatus in
                        guard let ppsBase = ppsRaw.baseAddress else { return -1 }
                        let pointers: [UnsafePointer<UInt8>] = [
                            vpsBase.assumingMemoryBound(to: UInt8.self),
                            spsBase.assumingMemoryBound(to: UInt8.self),
                            ppsBase.assumingMemoryBound(to: UInt8.self)
                        ]
                        let sizes: [Int] = [vps.count, sps.count, pps.count]
                        return pointers.withUnsafeBufferPointer { ptrs in
                            sizes.withUnsafeBufferPointer { sz in
                                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: ptrs.count,
                                    parameterSetPointers: ptrs.baseAddress!,
                                    parameterSetSizes: sz.baseAddress!,
                                    nalUnitHeaderLength: 4,
                                    extensions: nil,
                                    formatDescriptionOut: &out
                                )
                            }
                        }
                    }
                }
            }
            guard status == noErr, let desc = out else {
                throw RemoteDesktopError.decodingFailed("Failed to build HEVC format description (status=\(status))")
            }
            formatDescription = desc
        }
    }

    private func createDecompressionSession(formatDescription: CMVideoFormatDescription) throws {
        var newSession: VTDecompressionSession?
        let attributes: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let session = newSession else {
            throw RemoteDesktopError.decodingFailed("VTDecompressionSessionCreate failed (status=\(status))")
        }

        _ = VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decompressionSession = session
    }

    private func makeSampleBuffer(naluData: Data, formatDescription: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: naluData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: naluData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw RemoteDesktopError.decodingFailed("CMBlockBufferCreateWithMemoryBlock failed (status=\(status))")
        }

        let replaceStatus = naluData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: naluData.count)
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            throw RemoteDesktopError.decodingFailed("CMBlockBufferReplaceDataBytes failed (status=\(replaceStatus))")
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = naluData.count
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            throw RemoteDesktopError.decodingFailed("CMSampleBufferCreateReady failed (status=\(sbStatus))")
        }
        return sampleBuffer
    }

    private func parseNALUnits(from data: Data) -> [Data] {
        if data.count >= 4, data.starts(with: [0x00, 0x00, 0x00, 0x01]) || data.starts(with: [0x00, 0x00, 0x01]) {
            return parseAnnexBNALUnits(from: data)
        }
        return parseLengthPrefixedNALUnits(from: data)
    }

    private func parseLengthPrefixedNALUnits(from data: Data) -> [Data] {
        var nalus: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let length = data.withUnsafeBytes { raw -> Int in
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Int(UInt32(bigEndian: v))
            }
            offset += 4
            guard length > 0, offset + length <= data.count else { break }
            nalus.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return nalus
    }

    private func parseAnnexBNALUnits(from data: Data) -> [Data] {
        func isStartCode(at i: Int) -> Int? {
            guard i + 3 <= data.count else { return nil }
            if i + 4 <= data.count,
               data[i] == 0x00, data[i + 1] == 0x00, data[i + 2] == 0x00, data[i + 3] == 0x01 {
                return 4
            }
            if data[i] == 0x00, data[i + 1] == 0x00, data[i + 2] == 0x01 {
                return 3
            }
            return nil
        }

        var nalus: [Data] = []
        var i = 0
        var currentStart: Int?
        var currentSkip = 0

        while i < data.count {
            if let skip = isStartCode(at: i) {
                if let start = currentStart {
                    let naluStart = start + currentSkip
                    if naluStart < i {
                        nalus.append(data.subdata(in: naluStart..<i))
                    }
                }
                currentStart = i
                currentSkip = skip
                i += skip
            } else {
                i += 1
            }
        }

        if let start = currentStart {
            let naluStart = start + currentSkip
            if naluStart < data.count {
                nalus.append(data.subdata(in: naluStart..<data.count))
            }
        }
        return nalus
    }
    
    func cleanup() {
        resetDecoderState(keepLastFrame: false)
        activeCodec = nil
        h264SPS = nil
        h264PPS = nil
        hevcVPS = nil
        hevcSPS = nil
        hevcPPS = nil
    }
}

// MARK: - RemoteDesktopManager

/// 远程桌面管理器 - iOS 作为查看器/控制端
@available(iOS 17.0, *)
@MainActor
public class RemoteDesktopManager: ObservableObject {
    public static let instance = RemoteDesktopManager()
    
    // MARK: - Published Properties
    
    /// 是否正在流媒体
    @Published public private(set) var isStreaming: Bool = false
    
    /// 当前连接
    @Published public private(set) var currentConnection: Connection?
    
    /// 连接状态
    @Published public private(set) var state: RemoteDesktopState = .disconnected
    
    /// 当前帧图像
    @Published public private(set) var currentFrame: CGImage?
    
    /// 帧率
    @Published public private(set) var frameRate: Double = 0
    
    /// 延迟（毫秒）
    @Published public private(set) var latency: Double = 0
    
    /// 分辨率
    @Published public private(set) var resolution: CGSize = .zero

    /// 当前传输方式（用于 UI 提示）
    @Published public private(set) var transportStatusText: String?
    
    /// 是否全屏
    @Published public var isFullscreen: Bool = false
    
    /// 画质设置
    @Published public var quality: StreamQuality = .auto
    
    // MARK: - Private Properties

    private enum ActiveTransportMode {
        case none
        case lan
        case crossNetwork
    }
    
    private var networkConnection: NWConnection?
    private var activeTransportMode: ActiveTransportMode = .none
    private let decoder = VideoDecoder()
    private let queue = DispatchQueue(label: "com.skybridge.remotedesktop", qos: .userInteractive)
    
    private var heartbeatTimer: Timer?
    private var frameCount: Int = 0
    private var lastFrameTime: Date?
    private var lastHeartbeatTime: Date?
    private var firstFrameWatchdogTask: Task<Void, Never>?
    private var hasReceivedFrameInCurrentStream: Bool = false
    
    private let maxMessageBytes: Int = 8_000_000
    private let maxPendingFrames: Int = 1
    private var isDecodingFrame: Bool = false
    private var pendingFrames: [ScreenData] = []
    private let crossNetwork = CrossNetworkWebRTCManager.instance
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// 连接到远程桌面
    /// - Parameter device: 目标设备
    public func connect(to device: DiscoveredDevice) async throws {
        let resolvedDevice = resolveLatestRemoteDesktopDevice(from: device)
        if resolvedDevice.id != device.id {
            SkyBridgeLogger.shared.info("ℹ️ 远程桌面连接设备已解析: \(device.id) -> \(resolvedDevice.id)")
        }
        SkyBridgeLogger.shared.info("📺 连接到远程桌面: \(resolvedDevice.name)")
        
        state = .connecting
        
        do {
            // 仅当目标设备就是跨网会话对端时才走 DataChannel。
            // 避免“跨网已连接”误伤局域网远控（会导致画面/输入走错通道）。
            if shouldUseCrossNetworkTransport(for: resolvedDevice) {
                networkConnection?.cancel()
                networkConnection = nil
                activeTransportMode = .crossNetwork
                transportStatusText = currentTransportStatusText()
                currentConnection = Connection(device: resolvedDevice, status: .connected)
                state = .connected
                isStreaming = true
                state = .streaming
                crossNetwork.startRemoteDesktopHeartbeat()
                
                // 订阅跨网屏幕帧
                Task { [weak self] in
                    guard let self else { return }
                    for await _ in NotificationCenter.default.notifications(named: Notification.Name("CrossNetworkScreenDataUpdated")) {
                        if let sd = self.crossNetwork.lastScreenData {
                            await self.handleScreenData(sd)
                        }
                    }
                }
                
                SkyBridgeLogger.shared.info("✅ 远程桌面已切换到 WebRTC(DataChannel) 传输")
                return
            }

            crossNetwork.stopRemoteDesktopHeartbeat()
            // 建立连接：优先 Bonjour service（不依赖 IP/默认端口）
            let endpoint = try makeRemoteDesktopEndpoint(for: resolvedDevice)

            let connection = try await createConnection(to: endpoint)
            networkConnection = connection
            activeTransportMode = .lan
            transportStatusText = currentTransportStatusText()

            // 创建 Connection 对象
            currentConnection = Connection(device: resolvedDevice, status: .connected)
            state = .connected
            
            // 开始接收数据
            startReceiving()

            // 直接进入 streaming（macOS 端无需 connect/heartbeat 握手）
            try await startStreaming()
            
            SkyBridgeLogger.shared.info("✅ 远程桌面连接成功")
            
        } catch {
            activeTransportMode = .none
            transportStatusText = currentTransportStatusText()
            state = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// 开始流媒体
    public func startStreaming() async throws {
        if state == .streaming {
            return
        }
        guard state == .connected else {
            throw RemoteDesktopError.connectionFailed("未连接")
        }
        
        SkyBridgeLogger.shared.info("📺 开始远程桌面流")
        
        isStreaming = true
        state = .streaming
        frameCount = 0
        lastFrameTime = Date()
        hasReceivedFrameInCurrentStream = false
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard self.state == .streaming, !self.hasReceivedFrameInCurrentStream else { return }
            SkyBridgeLogger.shared.warning("⚠️ 远程桌面已连接但 5 秒内未收到屏幕帧，请检查 Mac 端录屏权限与采集状态")
        }
    }

    /// 便捷入口：从 Connection 启动远程桌面（UI 侧直接调用）
    public func startStreaming(from connection: Connection) async throws {
        if currentConnection?.device.id == connection.device.id, state == .streaming {
            return
        }
        // 若当前不是该设备的连接，先建立网络连接
        if currentConnection?.device.id != connection.device.id || state == .disconnected {
            try await connect(to: connection.device)
            // 仅在设备 id 一致时用 UI 传入的 Connection 覆盖展示信息；
            // 若 connect 过程中已解析到更可靠的设备记录（如 bonjour:*），保留解析结果。
            if currentConnection?.device.id == connection.device.id || currentConnection == nil {
                currentConnection = connection
            }
        }
        try await startStreaming()
    }
    
    /// 停止流媒体
    public func stopStreaming() async {
        SkyBridgeLogger.shared.info("⏹️ 停止远程桌面流")
        
        isStreaming = false
        crossNetwork.stopRemoteDesktopHeartbeat()
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        if state == .streaming {
            state = .connected
        }
    }
    
    /// 断开连接
    public func disconnect() async {
        SkyBridgeLogger.shared.info("🔌 断开远程桌面连接")
        crossNetwork.stopRemoteDesktopHeartbeat()
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        
        // 关闭连接
        networkConnection?.cancel()
        networkConnection = nil
        activeTransportMode = .none
        transportStatusText = currentTransportStatusText()
        
        // 清理解码器
        await decoder.cleanup()
        
        // 重置状态
        isStreaming = false
        currentConnection = nil
        currentFrame = nil
        state = .disconnected
        frameRate = 0
        latency = 0
        resolution = .zero
        pendingFrames.removeAll()
        isDecodingFrame = false
    }

    private func currentTransportStatusText() -> String? {
        switch activeTransportMode {
        case .none:
            return nil
        case .lan:
            return "P2P / LAN"
        case .crossNetwork:
            if case .handshakeComplete(_, let negotiatedSuite) = crossNetwork.readiness {
                return "WebRTC · \(negotiatedSuite)"
            }
            return "WebRTC"
        }
    }
    
    // MARK: - Input Events
    
    /// 发送鼠标/触控事件
    public func sendMouseEvent(_ event: MouseEvent) async {
        guard isStreaming else { return }
        
        do {
            let data = try JSONEncoder().encode(event)
            let message = RemoteMessage(type: .mouseEvent, payload: data)
            try await sendMessage(message)
        } catch {
            SkyBridgeLogger.shared.error("❌ 发送鼠标事件失败: \(error.localizedDescription)")
        }
    }
    
    /// 发送键盘事件
    public func sendKeyboardEvent(_ event: KeyboardEvent) async {
        guard isStreaming else { return }
        
        do {
            let data = try JSONEncoder().encode(event)
            let message = RemoteMessage(type: .keyboardEvent, payload: data)
            try await sendMessage(message)
        } catch {
            SkyBridgeLogger.shared.error("❌ 发送键盘事件失败: \(error.localizedDescription)")
        }
    }
    
    /// 从触控转换为鼠标事件
    public func handleTouch(at point: CGPoint, in bounds: CGRect, type: MouseEventType) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // 将触控坐标转换为远程屏幕坐标
        let normalizedX = (point.x - bounds.minX) / bounds.width
        let normalizedY = (point.y - bounds.minY) / bounds.height
        guard normalizedX >= 0, normalizedX <= 1, normalizedY >= 0, normalizedY <= 1 else { return }
        
        let remoteX = normalizedX * resolution.width
        let remoteY = normalizedY * resolution.height
        
        let event = MouseEvent(type: type, x: remoteX, y: remoteY)
        
        Task {
            await sendMouseEvent(event)
        }
    }

    // MARK: - Private Methods - Device Resolution

    private func makeRemoteDesktopEndpoint(for device: DiscoveredDevice) throws -> NWEndpoint {
        let remoteServiceType = DiscoveredDevice.remoteControlServiceType
        let parsedBonjour = parseBonjourIdentity(from: device.id)
        let hasRemoteService = device.services.contains(remoteServiceType)
            || device.bonjourServiceType == remoteServiceType

        if hasRemoteService {
            return .service(
                name: device.bonjourServiceName ?? parsedBonjour?.name ?? device.name,
                type: remoteServiceType,
                domain: device.bonjourServiceDomain ?? parsedBonjour?.domain ?? "local.",
                interface: nil
            )
        }

        if let ip = bestIPAddress(for: device) {
            let port = device.remoteControlPort ?? RemoteDesktopConstants.defaultPort
            return .hostPort(host: .init(ip), port: .init(integerLiteral: port))
        }

        throw RemoteDesktopError.connectionFailed("设备缺少可连接地址（Bonjour/IP）")
    }

    private func resolveLatestRemoteDesktopDevice(from device: DiscoveredDevice) -> DiscoveredDevice {
        var best = device
        let discovered = DeviceDiscoveryManager.instance.discoveredDevices

        if let exact = discovered.first(where: { $0.id == device.id }) {
            best = preferredRemoteDesktopDevice(best, exact)
        }

        if let currentIP = bestIPAddress(for: best),
           let byIP = discovered.first(where: { bestIPAddress(for: $0) == currentIP }) {
            best = preferredRemoteDesktopDevice(best, byIP)
        }

        if let bonjourName = best.bonjourServiceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bonjourName.isEmpty,
           let byBonjour = discovered.first(where: { $0.bonjourServiceName == bonjourName }) {
            best = preferredRemoteDesktopDevice(best, byBonjour)
        }

        if let parsedBonjour = parseBonjourIdentity(from: best.id),
           let byParsedBonjour = discovered.first(where: {
               $0.bonjourServiceName == parsedBonjour.name
                   && (($0.bonjourServiceDomain ?? "local.") == parsedBonjour.domain)
           }) {
            best = preferredRemoteDesktopDevice(best, byParsedBonjour)
        }

        let normalizedName = normalizeDeviceName(best.name)
        if !normalizedName.isEmpty,
           let byName = discovered.first(where: { normalizeDeviceName($0.name) == normalizedName }) {
            best = preferredRemoteDesktopDevice(best, byName)
        }

        if shouldUseUniqueRemoteCandidateFallback(for: best) {
            let remoteCandidates = discovered.filter {
                $0.services.contains(DiscoveredDevice.remoteControlServiceType)
                    || $0.bonjourServiceType == DiscoveredDevice.remoteControlServiceType
                    || $0.supportsRemoteControl
            }
            if remoteCandidates.count == 1, let only = remoteCandidates.first {
                best = preferredRemoteDesktopDevice(best, only)
            }
        }

        return best
    }

    private func preferredRemoteDesktopDevice(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> DiscoveredDevice {
        remoteDesktopDeviceScore(rhs) > remoteDesktopDeviceScore(lhs) ? rhs : lhs
    }

    private func remoteDesktopDeviceScore(_ device: DiscoveredDevice) -> Int {
        var score = 0
        if device.services.contains(DiscoveredDevice.remoteControlServiceType)
            || device.bonjourServiceType == DiscoveredDevice.remoteControlServiceType {
            score += 120
        }
        if bestIPAddress(for: device) != nil {
            score += 80
        }
        if let serviceName = device.bonjourServiceName, !serviceName.isEmpty {
            score += 40
        }
        if !device.services.isEmpty {
            score += 20
        }
        if !normalizeDeviceName(device.name).isEmpty {
            score += 10
        }
        return score
    }

    private func shouldUseUniqueRemoteCandidateFallback(for device: DiscoveredDevice) -> Bool {
        let hasRemoteService = device.services.contains(DiscoveredDevice.remoteControlServiceType)
            || device.bonjourServiceType == DiscoveredDevice.remoteControlServiceType
        if hasRemoteService {
            return false
        }

        if device.id.hasPrefix("host:") || device.id.hasPrefix("peer:") {
            return true
        }
        if bestIPAddress(for: device) != nil {
            return true
        }
        return normalizeDeviceName(device.name).contains(":")
    }

    private func shouldUseCrossNetworkTransport(for device: DiscoveredDevice) -> Bool {
        guard case .connected(let sessionId) = crossNetwork.state else { return false }

        if device.id == "webrtc-\(sessionId)" || device.id.hasPrefix("webrtc-") {
            return true
        }

        if let remoteId = crossNetwork.remoteDeviceId, !remoteId.isEmpty, remoteId == device.id {
            return true
        }

        if let remoteName = crossNetwork.remoteDeviceName {
            let normalizedRemoteName = normalizeDeviceName(remoteName)
            if !normalizedRemoteName.isEmpty,
               normalizeDeviceName(device.name) == normalizedRemoteName,
               device.services.isEmpty,
               device.ipAddress == nil {
                return true
            }
        }

        return false
    }

    private func normalizeDeviceName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private func parseBonjourIdentity(from identifier: String) -> (name: String, domain: String)? {
        guard identifier.hasPrefix("bonjour:") else { return nil }
        let payload = String(identifier.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return (name, domain)
    }

    private func bestIPAddress(for device: DiscoveredDevice) -> String? {
        sanitizeAddress(device.ipAddress)
            ?? sanitizeAddress(addressFromIdentifier(device.id))
    }

    private func addressFromIdentifier(_ identifier: String) -> String? {
        if identifier.hasPrefix("host:") {
            return String(identifier.dropFirst("host:".count))
        }
        if identifier.hasPrefix("peer:") {
            return String(identifier.dropFirst("peer:".count))
        }
        return nil
    }

    private func sanitizeAddress(_ raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("host:") {
            token = String(token.dropFirst("host:".count))
        } else if token.hasPrefix("peer:") {
            token = String(token.dropFirst("peer:".count))
        } else if token.hasPrefix("ip:") {
            token = String(token.dropFirst("ip:".count))
        }

        if token.hasPrefix("[") && token.hasSuffix("]") {
            token = String(token.dropFirst().dropLast())
        }

        if let zoneIndex = token.firstIndex(of: "%") {
            token = String(token[..<zoneIndex])
        }

        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""),
               (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }

        let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }
    
    // MARK: - Private Methods - Connection
    
    private func createConnection(to endpoint: NWEndpoint) async throws -> NWConnection {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
        final class ContinuationGate: @unchecked Sendable {
            private let lock = NSLock()
            private var didResume = false
            func runOnce(_ body: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                body()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate()
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.runOnce { continuation.resume(returning: connection) }
                case .failed(let error):
                    gate.runOnce {
                        continuation.resume(throwing: RemoteDesktopError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    gate.runOnce { continuation.resume(throwing: RemoteDesktopError.disconnected) }
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
            
            // 超时处理
            queue.asyncAfter(deadline: .now() + RemoteDesktopConstants.connectionTimeout) {
                gate.runOnce {
                    connection.cancel()
                    continuation.resume(throwing: RemoteDesktopError.timeout)
                }
            }
        }
    }
    
    private func sendMessage(_ message: RemoteMessage) async throws {
        // WebRTC DataChannel path
        if activeTransportMode == .crossNetwork {
            try await crossNetwork.sendRemoteDesktopMessage(message)
            return
        }
        
        // NWConnection path (LAN)
        guard let connection = networkConnection else {
            if activeTransportMode == .none, case .connected = crossNetwork.state {
                // 兼容旧状态：transport 尚未设置但 DataChannel 已连上时，回退走 WebRTC。
                try await crossNetwork.sendRemoteDesktopMessage(message)
                return
            }
            throw RemoteDesktopError.disconnected
        }
        let data = try JSONEncoder().encode(message)
        if data.count > maxMessageBytes { throw RemoteDesktopError.streamingFailed("消息过大：\(data.count) bytes") }
        var length = UInt32(data.count).bigEndian
        var framedData = Data(bytes: &length, count: 4)
        framedData.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framedData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: RemoteDesktopError.streamingFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    // MARK: - Private Methods - Receiving
    
    private func startReceiving() {
        guard let connection = networkConnection else { return }
        
        receiveNextMessage(from: connection)
    }
    
    private func receiveNextMessage(from connection: NWConnection) {
        // 先接收长度（4字节）
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                Task { @MainActor in
                    self.state = .error(error.localizedDescription)
                }
                return
            }
            
            guard let lengthData = data, lengthData.count == 4 else {
                if !isComplete {
                    Task { @MainActor in
                        self.receiveNextMessage(from: connection)
                    }
                }
                return
            }
            
	            let length = Int(lengthData.withUnsafeBytes { raw -> UInt32 in
	                raw.baseAddress!.loadUnaligned(as: UInt32.self).bigEndian
	            })
	            if length <= 0 || length > maxMessageBytes {
                Task { @MainActor in
                    self.state = .error("消息长度异常：\(length) bytes")
                }
                connection.cancel()
                return
            }
            
            // 接收消息体
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] messageData, _, _, error in
                guard let self = self else { return }
                
                if let error = error {
                    Task { @MainActor in
                        self.state = .error(error.localizedDescription)
                    }
                    return
                }
                
                if let data = messageData {
                    Task.detached(priority: .userInitiated) { [weak self] in
                        guard let self else { return }
                        do {
                            let message = try JSONDecoder().decode(RemoteMessage.self, from: data)
                            guard message.type == .screenData else { return }
                            let screenData = try JSONDecoder().decode(ScreenData.self, from: message.payload)
                            await self.handleScreenData(screenData)
                        } catch {
                            SkyBridgeLogger.shared.error("❌ 解析消息失败: \(error.localizedDescription)")
                        }
                    }
                }
                
                // 继续接收下一条消息
                Task { @MainActor in
                    self.receiveNextMessage(from: connection)
                }
            }
        }
    }
    
    private func handleScreenData(_ screenData: ScreenData) async {
        if !hasReceivedFrameInCurrentStream {
            hasReceivedFrameInCurrentStream = true
            SkyBridgeLogger.shared.info(
                "✅ 收到首帧: \(screenData.width)x\(screenData.height), format=\(screenData.format ?? "unknown"), bytes=\(screenData.imageData.count)"
            )
        }
        // 更新分辨率
        resolution = CGSize(width: screenData.width, height: screenData.height)
        
        // 计算延迟
        let now = Date().timeIntervalSince1970
        latency = (now - screenData.timestamp) * 1000 // 转换为毫秒
        
        enqueueFrameForDecode(screenData)
    }

    private func enqueueFrameForDecode(_ screenData: ScreenData) {
        if pendingFrames.isEmpty {
            pendingFrames.append(screenData)
        } else {
            pendingFrames[pendingFrames.count - 1] = screenData
            if pendingFrames.count > maxPendingFrames {
                pendingFrames.removeFirst(pendingFrames.count - maxPendingFrames)
            }
        }
        startDecodeLoopIfNeeded()
    }

    private func startDecodeLoopIfNeeded() {
        guard !isDecodingFrame else { return }
        guard let next = pendingFrames.popLast() else { return }
        isDecodingFrame = true

        let decoder = self.decoder
        let screenData = next

        Task { [weak self] in
            guard let self else { return }
            let frame = try? await decoder.decode(screenData: screenData)
            if let frame {
                self.currentFrame = frame
                self.frameCount += 1
                if let lastTime = self.lastFrameTime {
                    let elapsed = Date().timeIntervalSince(lastTime)
                    if elapsed >= 1.0 {
                        self.frameRate = Double(self.frameCount) / elapsed
                        self.frameCount = 0
                        self.lastFrameTime = Date()
                    }
                }
            }
            self.isDecodingFrame = false
            self.startDecodeLoopIfNeeded()
        }
    }
    
    // 心跳/剪贴板/连接握手：当前与 macOS 端的最小闭环协议不启用
}

// MARK: - Stream Quality

/// 流媒体画质
public enum StreamQuality: String, CaseIterable, Sendable {
    case auto = "自动"
    case low = "低 (720p)"
    case medium = "中 (1080p)"
    case high = "高 (4K)"
    
    public var resolution: CGSize {
        switch self {
        case .auto: return .zero
        case .low: return CGSize(width: 1280, height: 720)
        case .medium: return CGSize(width: 1920, height: 1080)
        case .high: return CGSize(width: 3840, height: 2160)
        }
    }
    
    public var bitrate: UInt64 {
        switch self {
        case .auto: return 0
        case .low: return 2_000_000
        case .medium: return 5_000_000
        case .high: return 15_000_000
        }
    }
}
