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
import CoreImage
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

private func RemoteDesktopReleasePixelBufferBytes(
    _ releaseRefCon: UnsafeMutableRawPointer?,
    _ baseAddress: UnsafeRawPointer?
) {
    guard let releaseRefCon else { return }
    Unmanaged<NSData>.fromOpaque(releaseRefCon).release()
}

// MARK: - Remote Message Types

/// 远程消息类型（与 macOS `RemoteControlManager` 对齐）
public enum RemoteMessageType: String, Codable, Sendable {
    case screenData = "screenData"
    case mouseEvent = "mouseEvent"
    case keyboardEvent = "keyboardEvent"
    case clipboard = "clipboard"
    case streamConfiguration = "streamConfiguration"
    case damageReport = "damageReport"
    case cursorUpdate = "cursorUpdate"
    case overlayUpdate = "overlayUpdate"
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

@available(iOS 17.0, *)
final class DecodedImageFrame: @unchecked Sendable {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
    }
}

@available(iOS 17.0, *)
final class DecodedPixelBufferFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    let presentationTimeStamp: CMTime

    init(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        presentationTimeStamp: CMTime
    ) {
        self.pixelBuffer = pixelBuffer
        self.width = width
        self.height = height
        self.presentationTimeStamp = presentationTimeStamp
    }
}

@available(iOS 17.0, *)
enum DecodeOutput: Sendable {
    case image(DecodedImageFrame)
    case pixelBuffer(DecodedPixelBufferFrame)
}

@available(iOS 17.0, *)
@MainActor
final class RemoteVideoFrameFeed: ObservableObject {
    @Published private(set) var frameVersion: UInt64 = 0

    private(set) var currentFrame: DecodedPixelBufferFrame?
    private(set) var flushVersion: UInt64 = 0

    var hasFrame: Bool {
        currentFrame != nil
    }

    func update(frame: DecodedPixelBufferFrame) {
        currentFrame = frame
        frameVersion &+= 1
    }

    func flush() {
        currentFrame = nil
        flushVersion &+= 1
        frameVersion &+= 1
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
        private var value: DecodeOutput?
        private var callbackInvoked = false

        func set(_ value: DecodeOutput?) {
            lock.lock()
            self.value = value
            callbackInvoked = true
            lock.unlock()
        }

        func markCallbackInvoked() {
            lock.lock()
            callbackInvoked = true
            lock.unlock()
        }

        func get() -> DecodeOutput? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func didInvokeCallback() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return callbackInvoked
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
    private var activeVideoDimensions: CGSize?
    private var waitingForSyncFrame = false
    private var decodeFrameCounter: Int64 = 0
    private var lastDecodeFailureLogTime: Date = .distantPast
    private var lastDecodeFailureReason: String?
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: false
    ])
    
    /// 解码 H.264/HEVC 帧
    func decode(screenData: ScreenData) async throws -> DecodeOutput? {
        lastDecodeFailureReason = nil
        let format = (screenData.format ?? "").lowercased()
        let payload = screenData.imageData

        if format.isEmpty {
            return decodeStaticImage(payload)
        }

        switch format {
        case "jpeg", "jpg":
            return decodeJPEG(payload)
        case "h264":
            return try decodeVideoFrame(
                payload,
                codec: .h264,
                width: screenData.width,
                height: screenData.height
            )
        case "hevc":
            return try decodeVideoFrame(
                payload,
                codec: .hevc,
                width: screenData.width,
                height: screenData.height
            )
        case "bgra":
            return decodeBGRA(payload, width: screenData.width, height: screenData.height)
        default:
            return decodeStaticImage(payload)
        }
    }
    
    private func decodeJPEG(_ data: Data) -> DecodeOutput? {
        decodeStaticImage(data)
    }
    
    private func decodeStaticImage(_ data: Data) -> DecodeOutput? {
        if let pixelBufferFrame = makeStillImagePixelBufferFrame(from: data) {
            return .pixelBuffer(pixelBufferFrame)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return .image(DecodedImageFrame(image: image))
    }
    
    private func decodeBGRA(_ data: Data, width: Int, height: Int) -> DecodeOutput? {
        guard width > 0, height > 0 else { return nil }
        let expectedMinBytes = width * height * 4
        guard data.count >= expectedMinBytes else { return nil }

        if let pixelBuffer = makeBGRAFramePixelBuffer(data: data, width: width, height: height) {
            return .pixelBuffer(
                DecodedPixelBufferFrame(
                    pixelBuffer: pixelBuffer,
                    width: width,
                    height: height,
                    presentationTimeStamp: nextDecodePresentationTimeStamp()
                )
            )
        }

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let image = CGImage(
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
        ) else {
            return nil
        }
        return .image(DecodedImageFrame(image: image))
    }

    nonisolated func isStillImageFormat(_ format: String) -> Bool {
        switch format {
        case "", "jpeg", "jpg", "bgra":
            return true
        default:
            return false
        }
    }

    func markStreamDisrupted(format: String, width: Int, height: Int) {
        let normalized = format.lowercased()
        guard !isStillImageFormat(normalized) else {
            resetDecoderState(keepLastFrame: true)
            activeCodec = nil
            activeVideoDimensions = nil
            waitingForSyncFrame = false
            clearVideoParameterSets()
            return
        }

        guard let codec = codec(for: normalized) else { return }
        resetDecoderState(keepLastFrame: true)
        activeCodec = codec
        activeVideoDimensions = CGSize(width: width, height: height)
        waitingForSyncFrame = true
        clearVideoParameterSets()
    }

    private func decodeVideoFrame(_ data: Data, codec: Codec, width: Int, height: Int) throws -> DecodeOutput? {
        let dimensions = CGSize(width: width, height: height)
        let streamChanged = activeCodec != codec || activeVideoDimensions != dimensions
        if streamChanged {
            resetDecoderState(keepLastFrame: true)
            activeCodec = codec
            activeVideoDimensions = dimensions
            waitingForSyncFrame = true
            clearVideoParameterSets()
        }

        let nalus = parseNALUnits(from: data)
        let requiresReset = updateParameterSetsIfPresent(from: data, codec: codec, nalus: nalus)
        if requiresReset {
            resetDecoderState(keepLastFrame: true)
        }

        let containsSyncFrame = containsSyncFrame(in: nalus, codec: codec)
        if waitingForSyncFrame, !containsSyncFrame {
            logDecodeFailureIfNeeded(
                codec: codec,
                dataSize: data.count,
                reason: "waiting-for-sync-frame"
            )
            return nil
        }

        if formatDescription == nil {
            try buildFormatDescriptionIfPossible(codec: codec)
        }
        guard let formatDescription else {
            if waitingForSyncFrame {
                logDecodeFailureIfNeeded(
                    codec: codec,
                    dataSize: data.count,
                    reason: "missing-parameter-sets"
                )
                return nil
            }
            return nil
        }

        if decompressionSession == nil {
            try createDecompressionSession(formatDescription: formatDescription)
        }
        guard let session = decompressionSession else { return nil }

        guard let sampleData = makeDecoderSampleData(from: data, codec: codec) else {
            return nil
        }

        let sampleBuffer = try makeSampleBuffer(
            naluData: sampleData,
            formatDescription: formatDescription,
            presentationTimeStamp: nextDecodePresentationTimeStamp()
        )

        let box = DecodeResultBox()
        let presentationTimeStamp = sampleBuffer.presentationTimeStamp
        var decodeInfoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: &decodeInfoFlags
        ) { status, _, imageBuffer, _, _ in
            box.markCallbackInvoked()
            guard status == noErr,
                  let pixelBuffer = imageBuffer else {
                return
            }
            box.set(
                .pixelBuffer(
                    DecodedPixelBufferFrame(
                        pixelBuffer: pixelBuffer,
                        width: width,
                        height: height,
                        presentationTimeStamp: presentationTimeStamp
                    )
                )
            )
        }

        guard status == noErr else {
            logDecodeFailureIfNeeded(
                codec: codec,
                dataSize: data.count,
                reason: "VTDecompressionSessionDecodeFrame status=\(status)"
            )
            return nil
        }

        VTDecompressionSessionWaitForAsynchronousFrames(session)

        let decodedFrame = box.get()
        if decodedFrame != nil {
            activeVideoDimensions = dimensions
            waitingForSyncFrame = false
        } else {
            let callbackState = box.didInvokeCallback() ? "callback-no-image" : "callback-missed"
            logDecodeFailureIfNeeded(
                codec: codec,
                dataSize: data.count,
                reason: callbackState
            )
            if containsSyncFrame {
                resetDecoderState(keepLastFrame: true)
                waitingForSyncFrame = true
            }
        }
        return decodedFrame
    }

    private func resetDecoderState(keepLastFrame: Bool) {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
    }

    private func updateParameterSetsIfPresent(from data: Data, codec: Codec, nalus: [Data]? = nil) -> Bool {
        var didChange = false

        func update(_ current: inout Data?, new: Data) {
            if current != new {
                current = new
                didChange = true
            }
        }

        let units = nalus ?? parseNALUnits(from: data)
        for nalu in units {
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

    private func containsSyncFrame(in nalus: [Data], codec: Codec) -> Bool {
        for nalu in nalus {
            guard let first = nalu.first else { continue }
            switch codec {
            case .h264:
                let type = Int(first & 0x1F)
                if type == 5 {
                    return true
                }
            case .hevc:
                let type = Int((first >> 1) & 0x3F)
                if (16...21).contains(type) {
                    return true
                }
            }
        }
        return false
    }

    private func clearVideoParameterSets() {
        h264SPS = nil
        h264PPS = nil
        hevcVPS = nil
        hevcSPS = nil
        hevcPPS = nil
    }

    private func codec(for format: String) -> Codec? {
        switch format {
        case "h264":
            return .h264
        case "hevc":
            return .hevc
        default:
            return nil
        }
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
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
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

    private func makeSampleBuffer(
        naluData: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTimeStamp: CMTime
    ) throws -> CMSampleBuffer {
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
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            throw RemoteDesktopError.decodingFailed("CMSampleBufferCreate failed (status=\(sbStatus))")
        }
        return sampleBuffer
    }

    private func nextDecodePresentationTimeStamp() -> CMTime {
        defer { decodeFrameCounter += 1 }
        return CMTime(value: decodeFrameCounter, timescale: 120)
    }

    private func makeStillImagePixelBufferFrame(from data: Data) -> DecodedPixelBufferFrame? {
        guard let ciImage = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = ciImage.extent.integral
        guard extent.width > 0, extent.height > 0,
              let pixelBuffer = makeMetalCompatiblePixelBuffer(
                width: Int(extent.width),
                height: Int(extent.height)
              ) else {
            return nil
        }

        let normalizedImage = ciImage.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )
        ciContext.render(
            normalizedImage,
            to: pixelBuffer,
            bounds: CGRect(origin: .zero, size: extent.size),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return DecodedPixelBufferFrame(
            pixelBuffer: pixelBuffer,
            width: Int(extent.width),
            height: Int(extent.height),
            presentationTimeStamp: nextDecodePresentationTimeStamp()
        )
    }

    private func makeBGRAFramePixelBuffer(
        data: Data,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let bytesPerRow = width * 4
        let storage = data as NSData
        let retained = Unmanaged.passRetained(storage)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            UnsafeMutableRawPointer(mutating: storage.bytes),
            bytesPerRow,
            RemoteDesktopReleasePixelBufferBytes,
            retained.toOpaque(),
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else {
            retained.release()
            return nil
        }
        return pixelBuffer
    }

    private func makeMetalCompatiblePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func parseNALUnits(from data: Data) -> [Data] {
        if data.count >= 4, data.starts(with: [0x00, 0x00, 0x00, 0x01]) || data.starts(with: [0x00, 0x00, 0x01]) {
            return parseAnnexBNALUnits(from: data)
        }
        return parseLengthPrefixedNALUnits(from: data)
    }

    private func makeDecoderSampleData(from data: Data, codec: Codec) -> Data? {
        let nalus = parseNALUnits(from: data)
        guard !nalus.isEmpty else { return data.isEmpty ? nil : data }

        var hasRenderableNALU = false
        var output = Data()
        output.reserveCapacity(data.count + (nalus.count * 4))

        for nalu in nalus {
            guard !nalu.isEmpty else { continue }
            if isRenderableNALU(nalu, codec: codec) {
                hasRenderableNALU = true
            }

            var length = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &length) { rawBuffer in
                output.append(contentsOf: rawBuffer)
            }
            output.append(nalu)
        }

        guard hasRenderableNALU else { return nil }
        return output.isEmpty ? nil : output
    }

    private func isRenderableNALU(_ nalu: Data, codec: Codec) -> Bool {
        guard let first = nalu.first else { return false }
        switch codec {
        case .h264:
            let type = Int(first & 0x1F)
            return (1...5).contains(type)
        case .hevc:
            let type = Int((first >> 1) & 0x3F)
            return (0...31).contains(type)
        }
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
        activeVideoDimensions = nil
        waitingForSyncFrame = false
        decodeFrameCounter = 0
        lastDecodeFailureReason = nil
        clearVideoParameterSets()
    }

    func resetPreservingLastFrame() {
        resetDecoderState(keepLastFrame: true)
        waitingForSyncFrame = true
    }

    func consumeLastFailureReason() -> String? {
        defer { lastDecodeFailureReason = nil }
        return lastDecodeFailureReason
    }

    private func logDecodeFailureIfNeeded(codec: Codec, dataSize: Int, reason: String) {
        lastDecodeFailureReason = reason
        let now = Date()
        guard now.timeIntervalSince(lastDecodeFailureLogTime) >= 1.0 else { return }
        lastDecodeFailureLogTime = now
        SkyBridgeLogger.shared.warning("⚠️ 视频解码失败: codec=\(String(describing: codec)) bytes=\(dataSize) reason=\(reason)")
    }
}

struct RemoteClipboardMessagePayload: Codable, Sendable, Equatable {
    let mimeType: String
    let data: Data
    let sentAt: TimeInterval

    init(
        mimeType: String,
        data: Data,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.mimeType = mimeType
        self.data = data
        self.sentAt = sentAt
    }
}

struct RemoteDesktopDamageRectPayload: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct RemoteDesktopDamageReportPayload: Codable, Sendable, Equatable {
    let rects: [RemoteDesktopDamageRectPayload]
    let fullFrameFallback: Bool
    let sentAt: TimeInterval
}

struct RemoteDesktopCursorPayload: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let hotspotX: Double
    let hotspotY: Double
    let hidden: Bool
    let imageData: Data?
    let mimeType: String?
    let sentAt: TimeInterval
}

struct RemoteDesktopOverlayPayload: Codable, Sendable, Equatable {
    let selectionRects: [RemoteDesktopDamageRectPayload]
    let focusRect: RemoteDesktopDamageRectPayload?
    let sentAt: TimeInterval
}

struct RemoteDesktopStreamConfigurationPayload: Codable, Sendable, Equatable {
    let width: Int?
    let height: Int?
    let preferredCodec: String?
    let supportedVideoFormats: [String]
    let qualityPreset: String?
    let adaptiveResolutionEnabled: Bool?
    let targetFrameRate: Int
    let keyFrameInterval: Int
    let lowLatencyMode: Bool
    let enableHardwareAcceleration: Bool
    let enableAppleSiliconOptimization: Bool
    let clipboardSyncEnabled: Bool
    let damageTrackingEnabled: Bool?
    let separateCursorChannelEnabled: Bool?
    let interactionOverlayChannelEnabled: Bool?
    let refreshStrategy: String?
    let jitterBufferFrames: Int?
    let lossRecoveryMode: String?
    let streamRefreshToken: UInt64?
    let sentAt: TimeInterval

    init(
        width: Int? = nil,
        height: Int? = nil,
        preferredCodec: String? = nil,
        supportedVideoFormats: [String],
        qualityPreset: String? = nil,
        adaptiveResolutionEnabled: Bool? = nil,
        targetFrameRate: Int,
        keyFrameInterval: Int,
        lowLatencyMode: Bool,
        enableHardwareAcceleration: Bool,
        enableAppleSiliconOptimization: Bool,
        clipboardSyncEnabled: Bool,
        damageTrackingEnabled: Bool? = nil,
        separateCursorChannelEnabled: Bool? = nil,
        interactionOverlayChannelEnabled: Bool? = nil,
        refreshStrategy: String? = nil,
        jitterBufferFrames: Int? = nil,
        lossRecoveryMode: String? = nil,
        streamRefreshToken: UInt64? = nil,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.width = width
        self.height = height
        self.preferredCodec = preferredCodec
        self.supportedVideoFormats = supportedVideoFormats
        self.qualityPreset = qualityPreset
        self.adaptiveResolutionEnabled = adaptiveResolutionEnabled
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.lowLatencyMode = lowLatencyMode
        self.enableHardwareAcceleration = enableHardwareAcceleration
        self.enableAppleSiliconOptimization = enableAppleSiliconOptimization
        self.clipboardSyncEnabled = clipboardSyncEnabled
        self.damageTrackingEnabled = damageTrackingEnabled
        self.separateCursorChannelEnabled = separateCursorChannelEnabled
        self.interactionOverlayChannelEnabled = interactionOverlayChannelEnabled
        self.refreshStrategy = refreshStrategy
        self.jitterBufferFrames = jitterBufferFrames
        self.lossRecoveryMode = lossRecoveryMode
        self.streamRefreshToken = streamRefreshToken
        self.sentAt = sentAt
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.preferredCodec == rhs.preferredCodec
            && lhs.supportedVideoFormats == rhs.supportedVideoFormats
            && lhs.qualityPreset == rhs.qualityPreset
            && lhs.adaptiveResolutionEnabled == rhs.adaptiveResolutionEnabled
            && lhs.targetFrameRate == rhs.targetFrameRate
            && lhs.keyFrameInterval == rhs.keyFrameInterval
            && lhs.lowLatencyMode == rhs.lowLatencyMode
            && lhs.enableHardwareAcceleration == rhs.enableHardwareAcceleration
            && lhs.enableAppleSiliconOptimization == rhs.enableAppleSiliconOptimization
            && lhs.clipboardSyncEnabled == rhs.clipboardSyncEnabled
            && lhs.damageTrackingEnabled == rhs.damageTrackingEnabled
            && lhs.separateCursorChannelEnabled == rhs.separateCursorChannelEnabled
            && lhs.interactionOverlayChannelEnabled == rhs.interactionOverlayChannelEnabled
            && lhs.refreshStrategy == rhs.refreshStrategy
            && lhs.jitterBufferFrames == rhs.jitterBufferFrames
            && lhs.lossRecoveryMode == rhs.lossRecoveryMode
            && lhs.streamRefreshToken == rhs.streamRefreshToken
    }
}

public enum RemoteDesktopViewerResolution: String, CaseIterable, Codable, Sendable {
    case auto
    case hd720
    case fullHD1080
    case qhd1440
    case uhd4k
    case uhd5k

    public var displayName: String {
        switch self {
        case .auto: return "自动"
        case .hd720: return "1280 × 720"
        case .fullHD1080: return "1920 × 1080"
        case .qhd1440: return "2560 × 1440"
        case .uhd4k: return "3840 × 2160"
        case .uhd5k: return "5120 × 2880"
        }
    }

    var dimensions: (width: Int, height: Int)? {
        switch self {
        case .auto:
            return nil
        case .hd720:
            return (1280, 720)
        case .fullHD1080:
            return (1920, 1080)
        case .qhd1440:
            return (2560, 1440)
        case .uhd4k:
            return (3840, 2160)
        case .uhd5k:
            return (5120, 2880)
        }
    }
}

public enum RemoteDesktopViewerFrameRate: String, CaseIterable, Codable, Sendable {
    case adaptive
    case fps30
    case fps60
    case fps120

    public var displayName: String {
        switch self {
        case .adaptive: return "自适应"
        case .fps30: return "30 FPS"
        case .fps60: return "60 FPS"
        case .fps120: return "120 FPS"
        }
    }

    var targetFPS: Int {
        switch self {
        case .adaptive: return 60
        case .fps30: return 30
        case .fps60: return 60
        case .fps120: return 120
        }
    }
}

public enum RemoteDesktopViewerCodec: String, CaseIterable, Codable, Sendable {
    case automatic
    case hevc
    case h264
    case jpeg

    public var displayName: String {
        switch self {
        case .automatic: return "自动"
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .jpeg: return "JPEG"
        }
    }

    var wireValue: String? {
        switch self {
        case .automatic: return nil
        case .hevc: return "hevc"
        case .h264: return "h264"
        case .jpeg: return "jpeg"
        }
    }

    func resolvedWireValue(supportedFormats: [String]) -> String? {
        switch self {
        case .automatic:
            if supportedFormats.contains("hevc") {
                return "hevc"
            }
            if supportedFormats.contains("h264") {
                return "h264"
            }
            if supportedFormats.contains("jpeg") {
                return "jpeg"
            }
            return supportedFormats.first
        default:
            guard let raw = wireValue else { return nil }
            return supportedFormats.contains(raw) || raw == "jpeg" ? raw : nil
        }
    }
}

private struct RemoteDesktopViewerStrategySignature: Equatable, Sendable {
    let resolution: RemoteDesktopViewerResolution
    let frameRate: RemoteDesktopViewerFrameRate
    let preferredCodec: RemoteDesktopViewerCodec
    let lowLatencyMode: Bool
}

private struct RemoteDesktopViewerPresetTemplate: Equatable, Sendable {
    let resolution: RemoteDesktopViewerResolution
    let frameRate: RemoteDesktopViewerFrameRate
    let preferredCodec: RemoteDesktopViewerCodec
    let lowLatencyMode: Bool

    var signature: RemoteDesktopViewerStrategySignature {
        .init(
            resolution: resolution,
            frameRate: frameRate,
            preferredCodec: preferredCodec,
            lowLatencyMode: lowLatencyMode
        )
    }
}

struct RemoteDesktopTransportTuning: Equatable, Sendable {
    let qualityPresetWireValue: String
    let damageTrackingEnabled: Bool
    let separateCursorChannelEnabled: Bool
    let interactionOverlayChannelEnabled: Bool
    let refreshStrategy: String
    let jitterBufferFrames: Int
    let lossRecoveryMode: String
}

public enum RemoteDesktopViewerPreset: String, CaseIterable, Codable, Sendable {
    case automatic
    case clarity
    case fluid
    case pro4k120
    case pro5k120
    case custom

    public var displayName: String {
        switch self {
        case .automatic: return "自动"
        case .clarity: return "清晰优先"
        case .fluid: return "流畅优先"
        case .pro4k120: return "Pro 4K 120"
        case .pro5k120: return "Pro 5K 120"
        case .custom: return "自定义"
        }
    }

    public var detailText: String {
        switch self {
        case .automatic:
            return "HEVC 优先，自适应 60 FPS，自动平衡清晰度与流畅度"
        case .clarity:
            return "4K 60 HEVC，优先保住细节与文字锐度"
        case .fluid:
            return "720p 60 H.264 低延迟，弱网下更稳"
        case .pro4k120:
            return "4K 120 HEVC 低延迟，适合高刷直连"
        case .pro5k120:
            return "5K 120 HEVC 低延迟，面向极客旗舰模式"
        case .custom:
            return "手动组合分辨率、帧率、编码器与延迟策略"
        }
    }

    fileprivate var template: RemoteDesktopViewerPresetTemplate? {
        switch self {
        case .automatic:
            return .init(
                resolution: .auto,
                frameRate: .adaptive,
                preferredCodec: .automatic,
                lowLatencyMode: false
            )
        case .clarity:
            return .init(
                resolution: .uhd4k,
                frameRate: .fps60,
                preferredCodec: .hevc,
                lowLatencyMode: false
            )
        case .fluid:
            return .init(
                resolution: .hd720,
                frameRate: .fps60,
                preferredCodec: .h264,
                lowLatencyMode: true
            )
        case .pro4k120:
            return .init(
                resolution: .uhd4k,
                frameRate: .fps120,
                preferredCodec: .hevc,
                lowLatencyMode: true
            )
        case .pro5k120:
            return .init(
                resolution: .uhd5k,
                frameRate: .fps120,
                preferredCodec: .hevc,
                lowLatencyMode: true
            )
        case .custom:
            return nil
        }
    }

    fileprivate var transportTuning: RemoteDesktopTransportTuning {
        switch self {
        case .automatic:
            return .init(
                qualityPresetWireValue: "automatic",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: true,
                refreshStrategy: "balanced",
                jitterBufferFrames: 2,
                lossRecoveryMode: "balanced"
            )
        case .clarity:
            return .init(
                qualityPresetWireValue: "clarity",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: true,
                refreshStrategy: "quality-biased",
                jitterBufferFrames: 2,
                lossRecoveryMode: "balanced"
            )
        case .fluid:
            return .init(
                qualityPresetWireValue: "fluid",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: true,
                refreshStrategy: "aggressive",
                jitterBufferFrames: 3,
                lossRecoveryMode: "resilient"
            )
        case .pro4k120:
            return .init(
                qualityPresetWireValue: "geek4k120",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: true,
                refreshStrategy: "instant",
                jitterBufferFrames: 1,
                lossRecoveryMode: "fast-retransmit"
            )
        case .pro5k120:
            return .init(
                qualityPresetWireValue: "geek5k120",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: true,
                refreshStrategy: "instant",
                jitterBufferFrames: 1,
                lossRecoveryMode: "fast-retransmit"
            )
        case .custom:
            return .init(
                qualityPresetWireValue: "custom",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: true,
                refreshStrategy: "balanced",
                jitterBufferFrames: 2,
                lossRecoveryMode: "balanced"
            )
        }
    }
}

public struct RemoteDesktopViewerSettings: Codable, Sendable, Equatable {
    public var resolution: RemoteDesktopViewerResolution = .auto
    public var frameRate: RemoteDesktopViewerFrameRate = .adaptive
    public var preferredCodec: RemoteDesktopViewerCodec = .automatic
    public var clipboardSyncEnabled: Bool = true
    public var lowLatencyMode: Bool = false

    public init() {}

    var targetFrameRate: Int {
        frameRate.targetFPS
    }

    var keyFrameInterval: Int {
        lowLatencyMode ? max(15, targetFrameRate / 2) : max(30, targetFrameRate)
    }

    fileprivate var strategySignature: RemoteDesktopViewerStrategySignature {
        .init(
            resolution: resolution,
            frameRate: frameRate,
            preferredCodec: preferredCodec,
            lowLatencyMode: lowLatencyMode
        )
    }

    var activePreset: RemoteDesktopViewerPreset {
        RemoteDesktopViewerPreset.allCases.first { preset in
            guard let template = preset.template else { return false }
            return template.signature == strategySignature
        } ?? .custom
    }

    mutating func applyPreset(_ preset: RemoteDesktopViewerPreset) {
        guard let template = preset.template else { return }
        resolution = template.resolution
        frameRate = template.frameRate
        preferredCodec = template.preferredCodec
        lowLatencyMode = template.lowLatencyMode
    }

    var transportTuning: RemoteDesktopTransportTuning {
        let preset = activePreset
        guard preset == .custom else { return preset.transportTuning }
        return .init(
            qualityPresetWireValue: "custom",
            damageTrackingEnabled: true,
            separateCursorChannelEnabled: true,
            interactionOverlayChannelEnabled: true,
            refreshStrategy: lowLatencyMode ? "instant" : "balanced",
            jitterBufferFrames: lowLatencyMode ? 1 : 2,
            lossRecoveryMode: lowLatencyMode ? "fast-retransmit" : "balanced"
        )
    }
}

enum RemoteDesktopCodecGovernanceEvent: Sendable, Equatable {
    case none
    case requestRefresh
    case disableHEVC(until: Date)
    case reenableHEVCProbe
}

struct RemoteDesktopCodecGovernance: Sendable, Equatable {
    private(set) var hevcFailureStreak: Int = 0
    private(set) var hevcDisabledUntil: Date?
    private(set) var hevcDisableCount: Int = 0
    private(set) var stableFallbackFrameCount: Int = 0

    mutating func noteDecodeSuccess(format: String, at now: Date) -> RemoteDesktopCodecGovernanceEvent {
        let normalized = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "hevc" {
            hevcFailureStreak = 0
            stableFallbackFrameCount = 0
            return .none
        }

        guard normalized == "h264"
            || normalized == "jpeg"
            || normalized == "jpg"
            || normalized == "bgra"
            || normalized.isEmpty else {
            return .none
        }

        stableFallbackFrameCount += 1
        guard let disabledUntil = hevcDisabledUntil,
              now >= disabledUntil,
              stableFallbackFrameCount >= 24 else {
            return .none
        }

        hevcDisabledUntil = nil
        hevcFailureStreak = 0
        stableFallbackFrameCount = 0
        return .reenableHEVCProbe
    }

    mutating func noteDecodeFailure(
        format: String,
        reason: String?,
        at now: Date
    ) -> RemoteDesktopCodecGovernanceEvent {
        let normalizedFormat = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedFormat == "hevc" else { return .none }

        let normalizedReason = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        stableFallbackFrameCount = 0

        if normalizedReason.contains("waiting-for-sync-frame") {
            hevcFailureStreak = max(hevcFailureStreak, 1)
            return .requestRefresh
        }

        hevcFailureStreak += 1
        guard hevcFailureStreak >= 3 else { return .none }

        hevcDisableCount += 1
        let cooldown = hevcDisableCount == 1 ? 20.0 : 60.0
        let disabledUntil = now.addingTimeInterval(cooldown)
        hevcDisabledUntil = disabledUntil
        hevcFailureStreak = 0
        stableFallbackFrameCount = 0
        return .disableHEVC(until: disabledUntil)
    }

    func effectiveSupportedFormats(from formats: [String], at now: Date) -> [String] {
        guard let disabledUntil = hevcDisabledUntil,
              now < disabledUntil else {
            return formats
        }

        return formats.filter { $0.lowercased() != "hevc" }
    }

    func effectivePreferredCodec(
        userPreference: RemoteDesktopViewerCodec,
        supportedFormats: [String],
        at now: Date
    ) -> String? {
        let effectiveFormats = effectiveSupportedFormats(from: supportedFormats, at: now)
        let hevcDisabled = effectiveFormats.contains("hevc") == false && supportedFormats.contains("hevc")

        if hevcDisabled {
            switch userPreference {
            case .automatic, .hevc:
                if effectiveFormats.contains("h264") {
                    return "h264"
                }
                if effectiveFormats.contains("jpeg") {
                    return "jpeg"
                }
            case .h264, .jpeg:
                break
            }
        }

        return userPreference.resolvedWireValue(supportedFormats: effectiveFormats)
    }
}

// MARK: - RemoteDesktopManager

/// 远程桌面管理器 - iOS 作为查看器/控制端
@available(iOS 17.0, *)
@MainActor
public class RemoteDesktopManager: ObservableObject {
    public static let instance = RemoteDesktopManager()
    public static let crossNetworkDeviceCapability = "cross_network_remote"
    private static let viewerSettingsStorageKey = "com.skybridge.remoteDesktop.viewerSettings.v1"

    private struct IncomingStreamSignature: Equatable {
        let format: String
        let width: Int
        let height: Int
    }
    
    // MARK: - Published Properties
    
    /// 是否正在流媒体
    @Published public private(set) var isStreaming: Bool = false
    
    /// 当前连接
    @Published public private(set) var currentConnection: Connection?
    
    /// 连接状态
    @Published public private(set) var state: RemoteDesktopState = .disconnected
    
    /// 当前帧图像
    @Published public private(set) var currentFrame: CGImage?
    let videoFrameFeed = RemoteVideoFrameFeed()
    
    /// 帧率
    @Published public private(set) var frameRate: Double = 0
    
    /// 延迟（毫秒）
    @Published public private(set) var latency: Double = 0
    
    /// 分辨率
    @Published public private(set) var resolution: CGSize = .zero

    /// 当前传输方式（用于 UI 提示）
    @Published public private(set) var transportStatusText: String?
    @Published public private(set) var renderPipelineStatus: RemoteDesktopRenderPipeline = .waiting
    @Published public private(set) var lastDamageRectCount: Int = 0
    @Published public private(set) var lastDamageUsesFullFrameFallback: Bool = false
    @Published private(set) var currentCursorPayload: RemoteDesktopCursorPayload?
    @Published private(set) var currentOverlayPayload: RemoteDesktopOverlayPayload?
#if canImport(UIKit)
    @Published private(set) var currentCursorImage: UIImage?
#endif
    
    /// 是否全屏
    @Published public var isFullscreen: Bool = false
    
    /// 画质设置
    @Published public var quality: StreamQuality = .auto
    @Published public var viewerSettings: RemoteDesktopViewerSettings = .init() {
        didSet {
            persistViewerSettings()
            scheduleViewerSettingsUpdate()
        }
    }
    
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
    private var lastRenderedFrameTime: Date?
    private var consecutiveDecodeMisses: Int = 0
    private var lastDecoderResetTime: Date?
    private var lastHeartbeatTime: Date?
    private var firstFrameWatchdogTask: Task<Void, Never>?
    private var hasReceivedFrameInCurrentStream: Bool = false
    
    private let maxMessageBytes: Int = 8_000_000
    private let maxPendingFrames: Int = 1
    private var isDecodingFrame: Bool = false
    private var pendingFrames: [ScreenData] = []
    private let crossNetwork = CrossNetworkWebRTCManager.instance
    private var clipboardSessionId: UUID?
    private var clipboardListenerToken: UUID?
    private var pendingViewerSettingsTask: Task<Void, Never>?
    private var lastSentStreamConfiguration: RemoteDesktopStreamConfigurationPayload?
    private var lastIncomingStreamSignature: IncomingStreamSignature?
    private var streamRefreshTokenCounter: UInt64 = 0
    private var lastRefreshRequestAt: Date?
    private var codecGovernance = RemoteDesktopCodecGovernance()
    
    private init() {
        viewerSettings = Self.loadViewerSettings()
    }
    
    // MARK: - Public Methods
    
    /// 连接到远程桌面
    /// - Parameter device: 目标设备
    public func connect(to device: DiscoveredDevice) async throws {
        let resolvedDevice = shouldUseCrossNetworkTransport(for: device)
            ? device
            : resolveLatestRemoteDesktopDevice(from: device)
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
                configureSessionClipboardSync()
                
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
                await pushViewerStreamConfiguration(force: true)
                return
            }

            crossNetwork.stopRemoteDesktopHeartbeat()
            // 建立连接：优先 Bonjour service（不依赖 IP/默认端口）
            let endpoint = try makeRemoteDesktopEndpoint(for: resolvedDevice)

            let connection = try await createConnection(to: endpoint)
            networkConnection = connection
            connection.stateUpdateHandler = { [weak self] connectionState in
                guard let self else { return }
                switch connectionState {
                case .failed(let error):
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleTransportFailure(error.localizedDescription)
                    }
                case .cancelled:
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleTransportFailure(
                            RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                        )
                    }
                default:
                    break
                }
            }
            activeTransportMode = .lan
            transportStatusText = currentTransportStatusText()

            // 创建 Connection 对象
            currentConnection = Connection(device: resolvedDevice, status: .connected)
            state = .connected
            
            // 开始接收数据
            startReceiving()

            // 在进入 streaming 前先主动发送一次 viewer 能力，避免 Mac 端首个会话默认退回到 JPEG。
            await pushViewerStreamConfiguration(force: true)

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
            await pushViewerStreamConfiguration(force: true)
            return
        }
        guard state == .connected else {
            throw RemoteDesktopError.connectionFailed("未连接")
        }
        
        SkyBridgeLogger.shared.info("📺 开始远程桌面流")
        
        isStreaming = true
        state = .streaming
        configureSessionClipboardSync()
        frameCount = 0
        lastFrameTime = Date()
        lastRenderedFrameTime = nil
        consecutiveDecodeMisses = 0
        frameRate = 0
        hasReceivedFrameInCurrentStream = false
        lastDecoderResetTime = nil
        lastIncomingStreamSignature = nil
        lastRefreshRequestAt = nil
        codecGovernance = .init()
        currentFrame = nil
        videoFrameFeed.flush()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
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
        await pushViewerStreamConfiguration(force: true)
    }

    /// 便捷入口：从 Connection 启动远程桌面（UI 侧直接调用）
    public func startStreaming(from connection: Connection) async throws {
        if currentConnection?.device.id == connection.device.id, state == .streaming {
            await pushViewerStreamConfiguration(force: true)
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
        configureSessionClipboardSync()
        lastSentStreamConfiguration = nil
        lastIncomingStreamSignature = nil
        lastRefreshRequestAt = nil
        codecGovernance = .init()
        currentFrame = nil
        videoFrameFeed.flush()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
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
        networkConnection?.stateUpdateHandler = nil
        networkConnection?.cancel()
        networkConnection = nil
        activeTransportMode = .none
        transportStatusText = currentTransportStatusText()
        lastSentStreamConfiguration = nil
        lastIncomingStreamSignature = nil
        lastRefreshRequestAt = nil
        codecGovernance = .init()
        isStreaming = false
        configureSessionClipboardSync()
        
        // 清理解码器
        await decoder.cleanup()
        
        // 重置状态
        currentConnection = nil
        currentFrame = nil
        videoFrameFeed.flush()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
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

    private func handleTransportFailure(_ reason: String) async {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorMessage = normalizedReason.isEmpty
            ? (RemoteDesktopError.disconnected.errorDescription ?? "连接已断开")
            : normalizedReason

        crossNetwork.stopRemoteDesktopHeartbeat()
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        networkConnection?.stateUpdateHandler = nil
        networkConnection?.cancel()
        networkConnection = nil
        activeTransportMode = .none
        transportStatusText = currentTransportStatusText()
        lastSentStreamConfiguration = nil
        lastIncomingStreamSignature = nil
        lastRefreshRequestAt = nil
        codecGovernance = .init()
        isStreaming = false
        configureSessionClipboardSync()
        await decoder.cleanup()
        currentFrame = nil
        videoFrameFeed.flush()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
        frameCount = 0
        lastFrameTime = nil
        lastRenderedFrameTime = nil
        consecutiveDecodeMisses = 0
        lastDecoderResetTime = nil
        hasReceivedFrameInCurrentStream = false
        frameRate = 0
        latency = 0
        resolution = .zero
        pendingFrames.removeAll()
        isDecodingFrame = false
        state = .error(errorMessage)
    }

    public static func supportedRemoteVideoFormats() -> [String] {
        var formats = ["jpeg", "h264"]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            formats.insert("hevc", at: 0)
        }
        var seen: Set<String> = []
        return formats.filter { seen.insert($0).inserted }
    }

    private func effectiveSupportedRemoteVideoFormats(at now: Date = Date()) -> [String] {
        codecGovernance.effectiveSupportedFormats(from: Self.supportedRemoteVideoFormats(), at: now)
    }

    public func handleInboundRemoteClipboard(
        data: Data,
        mimeType: String,
        fromDeviceId: String? = nil
    ) {
        guard viewerSettings.clipboardSyncEnabled else { return }
        configureSessionClipboardSync()
        ClipboardManager.shared.setRemoteClipboard(
            data: data,
            mimeType: mimeType,
            fromDeviceId: fromDeviceId
        )
    }

    func handleInboundDamageReport(_ report: RemoteDesktopDamageReportPayload) {
        lastDamageRectCount = report.rects.count
        lastDamageUsesFullFrameFallback = report.fullFrameFallback
    }

    func handleInboundCursorUpdate(_ payload: RemoteDesktopCursorPayload) {
        currentCursorPayload = payload
#if canImport(UIKit)
        if let imageData = payload.imageData,
           let image = UIImage(data: imageData, scale: 1.0) {
            currentCursorImage = image
        }
#endif
    }

    func handleInboundOverlayUpdate(_ payload: RemoteDesktopOverlayPayload) {
        currentOverlayPayload = payload
    }

    private func scheduleViewerSettingsUpdate() {
        pendingViewerSettingsTask?.cancel()
        pendingViewerSettingsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self.configureSessionClipboardSync()
            await self.pushViewerStreamConfiguration(force: false)
        }
    }

    private func configureSessionClipboardSync() {
        let clipboard = ClipboardManager.shared
        let shouldEnable = viewerSettings.clipboardSyncEnabled && isStreaming

        if shouldEnable {
            if clipboardSessionId == nil {
                clipboardSessionId = UUID()
            }
            if let clipboardSessionId {
                clipboard.enable(for: clipboardSessionId)
            }
            if clipboardListenerToken == nil {
                clipboardListenerToken = clipboard.addLocalClipboardListener { [weak self] data, mimeType in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleLocalClipboardChange(data: data, mimeType: mimeType)
                    }
                }
            }
        } else {
            if let token = clipboardListenerToken {
                clipboard.removeLocalClipboardListener(token)
                clipboardListenerToken = nil
            }
            if let clipboardSessionId {
                clipboard.disable(for: clipboardSessionId)
                self.clipboardSessionId = nil
            }
        }
    }

    private func handleLocalClipboardChange(data: Data, mimeType: String) async {
        guard viewerSettings.clipboardSyncEnabled, isStreaming else { return }
        do {
            let payload = RemoteClipboardMessagePayload(mimeType: mimeType, data: data)
            let encoded = try JSONEncoder().encode(payload)
            let message = RemoteMessage(type: .clipboard, payload: encoded)
            try await sendMessage(message)
        } catch {
            SkyBridgeLogger.shared.error("❌ 发送会话剪贴板失败: \(error.localizedDescription)")
        }
    }

    private func pushViewerStreamConfiguration(force: Bool, refreshStream: Bool = false) async {
        let canSendOverWebRTC = activeTransportMode == .crossNetwork && currentConnection != nil
        let canSendOverLAN = activeTransportMode == .lan && networkConnection != nil
        guard canSendOverWebRTC || canSendOverLAN else { return }
        let payload = makeViewerStreamConfigurationPayload(refreshStream: refreshStream)
        guard force || payload != lastSentStreamConfiguration else { return }
        do {
            let encoded = try JSONEncoder().encode(payload)
            let message = RemoteMessage(type: .streamConfiguration, payload: encoded)
            try await sendMessage(message)
            lastSentStreamConfiguration = payload
            SkyBridgeLogger.shared.info(
                "📤 已发送远控流配置: preset=\(viewerSettings.activePreset.displayName), preferred=\(payload.preferredCodec ?? "auto"), formats=\(payload.supportedVideoFormats.joined(separator: ",")), fps=\(payload.targetFrameRate), jitter=\(payload.jitterBufferFrames ?? 0), refresh=\(payload.streamRefreshToken != nil)"
            )
        } catch {
            SkyBridgeLogger.shared.error("❌ 发送远控流配置失败: \(error.localizedDescription)")
        }
    }

    private func makeViewerStreamConfigurationPayload(refreshStream: Bool = false) -> RemoteDesktopStreamConfigurationPayload {
        let now = Date()
        let supportedFormats = effectiveSupportedRemoteVideoFormats(at: now)
        let preferredCodec = codecGovernance.effectivePreferredCodec(
            userPreference: viewerSettings.preferredCodec,
            supportedFormats: Self.supportedRemoteVideoFormats(),
            at: now
        )
        let dimensions = viewerSettings.resolution.dimensions
        let transportTuning = viewerSettings.transportTuning
        return RemoteDesktopStreamConfigurationPayload(
            width: dimensions?.width,
            height: dimensions?.height,
            preferredCodec: preferredCodec,
            supportedVideoFormats: supportedFormats,
            qualityPreset: transportTuning.qualityPresetWireValue,
            adaptiveResolutionEnabled: viewerSettings.resolution == .auto,
            targetFrameRate: viewerSettings.targetFrameRate,
            keyFrameInterval: viewerSettings.keyFrameInterval,
            lowLatencyMode: viewerSettings.lowLatencyMode,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: viewerSettings.clipboardSyncEnabled,
            damageTrackingEnabled: transportTuning.damageTrackingEnabled,
            separateCursorChannelEnabled: transportTuning.separateCursorChannelEnabled,
            interactionOverlayChannelEnabled: transportTuning.interactionOverlayChannelEnabled,
            refreshStrategy: transportTuning.refreshStrategy,
            jitterBufferFrames: transportTuning.jitterBufferFrames,
            lossRecoveryMode: transportTuning.lossRecoveryMode,
            streamRefreshToken: refreshStream ? nextStreamRefreshToken() : nil
        )
    }

    private func nextStreamRefreshToken() -> UInt64 {
        streamRefreshTokenCounter &+= 1
        if streamRefreshTokenCounter == 0 {
            streamRefreshTokenCounter = 1
        }
        return streamRefreshTokenCounter
    }

    private func persistViewerSettings() {
        guard let data = try? JSONEncoder().encode(viewerSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.viewerSettingsStorageKey)
    }

    private static func loadViewerSettings() -> RemoteDesktopViewerSettings {
        guard let data = UserDefaults.standard.data(forKey: viewerSettingsStorageKey),
              let settings = try? JSONDecoder().decode(RemoteDesktopViewerSettings.self, from: data) else {
            return RemoteDesktopViewerSettings()
        }
        var migrated = settings
        if migrated.preferredCodec == .jpeg {
            migrated.preferredCodec = .h264
        }
        return migrated
    }

    private func updateRenderPipeline(_ pipeline: RemoteDesktopRenderPipeline) {
        guard renderPipelineStatus != pipeline else { return }
        renderPipelineStatus = pipeline
        switch pipeline {
        case .waiting:
            break
        case .metalZeroCopy:
            SkyBridgeLogger.shared.info("🎬 远控渲染管线已切换到 Metal 零拷贝显示")
        case .stillImageFallback:
            SkyBridgeLogger.shared.info("🖼️ 远控渲染管线已切换到静态帧回退")
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
        let bonjourName = device.bonjourServiceName ?? parsedBonjour?.name
        let bonjourDomain = device.bonjourServiceDomain ?? parsedBonjour?.domain ?? "local."

        if hasRemoteService {
            return .service(
                name: bonjourName ?? device.name,
                type: remoteServiceType,
                domain: bonjourDomain,
                interface: nil
            )
        }

        if let ip = bestIPAddress(for: device) {
            let port = device.remoteControlPort ?? RemoteDesktopConstants.defaultPort
            return .hostPort(host: .init(ip), port: .init(integerLiteral: port))
        }

        if let bonjourName, !bonjourName.isEmpty {
            SkyBridgeLogger.shared.info(
                "📡 远控未发现独立端口，尝试使用 Bonjour 名称回退连接: name=\(bonjourName) domain=\(bonjourDomain)"
            )
            return .service(
                name: bonjourName,
                type: remoteServiceType,
                domain: bonjourDomain,
                interface: nil
            )
        }

        throw RemoteDesktopError.connectionFailed("设备缺少可连接地址（Bonjour/IP）")
    }

    private func resolveLatestRemoteDesktopDevice(from device: DiscoveredDevice) -> DiscoveredDevice {
        if isCrossNetworkDevice(device) {
            return device
        }

        var best = device
        let discovered = deduplicatedRemoteDesktopCandidates(DeviceDiscoveryManager.instance.discoveredDevices)

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

        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: device))
        if !targetAliases.isEmpty {
            for candidate in discovered {
                let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
                if !candidateAliases.isDisjoint(with: targetAliases) {
                    best = preferredRemoteDesktopDevice(best, candidate)
                }
            }
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

    private func deduplicatedRemoteDesktopCandidates(_ candidates: [DiscoveredDevice]) -> [DiscoveredDevice] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
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
        if isCrossNetworkDevice(device) {
            return false
        }

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

        if isCrossNetworkDevice(device) {
            return true
        }

        if device.id == "webrtc-\(sessionId)" || device.id.hasPrefix("webrtc-") {
            return true
        }

        if let remoteId = crossNetwork.remoteDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !remoteId.isEmpty,
           remoteId == device.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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

    private func isCrossNetworkDevice(_ device: DiscoveredDevice) -> Bool {
        device.capabilities.contains(Self.crossNetworkDeviceCapability)
            || device.advertisedCapabilities.contains(Self.crossNetworkDeviceCapability)
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
                    await self.handleTransportFailure(error.localizedDescription)
                }
                return
            }
            
            guard let lengthData = data, lengthData.count == 4 else {
                if isComplete {
                    Task { @MainActor in
                        await self.handleTransportFailure(
                            RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                        )
                    }
                    return
                }
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
                    await self.handleTransportFailure("消息长度异常：\(length) bytes")
                }
                return
            }
            
            // 接收消息体
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] messageData, _, _, error in
                guard let self = self else { return }
                
                if let error = error {
                    Task { @MainActor in
                        await self.handleTransportFailure(error.localizedDescription)
                    }
                    return
                }
                
                if let data = messageData {
                    Task.detached(priority: .userInitiated) { [weak self] in
                        guard let self else { return }
                        do {
                            let message = try JSONDecoder().decode(RemoteMessage.self, from: data)
                            switch message.type {
                            case .screenData:
                                let screenData = try JSONDecoder().decode(ScreenData.self, from: message.payload)
                                await self.handleScreenData(screenData)
                            case .clipboard:
                                let payload = try JSONDecoder().decode(RemoteClipboardMessagePayload.self, from: message.payload)
                                await MainActor.run {
                                    self.handleInboundRemoteClipboard(
                                        data: payload.data,
                                        mimeType: payload.mimeType,
                                        fromDeviceId: self.currentConnection?.device.id
                                    )
                                }
                            case .damageReport:
                                let report = try JSONDecoder().decode(RemoteDesktopDamageReportPayload.self, from: message.payload)
                                await MainActor.run {
                                    self.handleInboundDamageReport(report)
                                }
                            case .cursorUpdate:
                                let payload = try JSONDecoder().decode(RemoteDesktopCursorPayload.self, from: message.payload)
                                await MainActor.run {
                                    self.handleInboundCursorUpdate(payload)
                                }
                            case .overlayUpdate:
                                let payload = try JSONDecoder().decode(RemoteDesktopOverlayPayload.self, from: message.payload)
                                await MainActor.run {
                                    self.handleInboundOverlayUpdate(payload)
                                }
                            case .mouseEvent, .keyboardEvent, .streamConfiguration:
                                break
                            }
                        } catch {
                            SkyBridgeLogger.shared.error("❌ 解析消息失败: \(error.localizedDescription)")
                        }
                    }
                } else {
                    Task { @MainActor in
                        await self.handleTransportFailure(
                            RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                        )
                    }
                    return
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
        await handleIncomingStreamTopologyChangeIfNeeded(for: screenData)
        // 更新分辨率
        resolution = CGSize(width: screenData.width, height: screenData.height)
        
        // 计算延迟
        let now = Date().timeIntervalSince1970
        latency = (now - screenData.timestamp) * 1000 // 转换为毫秒
        
        enqueueFrameForDecode(screenData)
    }

    private func handleIncomingStreamTopologyChangeIfNeeded(for screenData: ScreenData) async {
        let normalizedFormat = (screenData.format ?? "").lowercased()
        let newSignature = IncomingStreamSignature(
            format: normalizedFormat,
            width: screenData.width,
            height: screenData.height
        )

        guard let previousSignature = lastIncomingStreamSignature else {
            lastIncomingStreamSignature = newSignature
            return
        }

        guard previousSignature != newSignature else { return }
        lastIncomingStreamSignature = newSignature

        pendingFrames.removeAll(keepingCapacity: true)
        consecutiveDecodeMisses = 0
        frameRate = 0
        lastRenderedFrameTime = nil
        currentFrame = nil
        videoFrameFeed.flush()
        updateRenderPipeline(.waiting)
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        await decoder.markStreamDisrupted(
            format: normalizedFormat,
            width: screenData.width,
            height: screenData.height
        )

        let now = Date()
        let canRequestRefresh = lastRefreshRequestAt.map { now.timeIntervalSince($0) >= 0.5 } ?? true
        if canRequestRefresh {
            lastRefreshRequestAt = now
            await pushViewerStreamConfiguration(force: true, refreshStream: true)
        }

        SkyBridgeLogger.shared.info(
            "🔄 远控视频流拓扑变化: \(previousSignature.format) \(previousSignature.width)x\(previousSignature.height) -> \(newSignature.format) \(newSignature.width)x\(newSignature.height)"
        )
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

    private func requestStreamRefreshIfNeeded(minimumInterval: TimeInterval = 0.5) async {
        let now = Date()
        let canRequestRefresh = lastRefreshRequestAt.map { now.timeIntervalSince($0) >= minimumInterval } ?? true
        guard canRequestRefresh else { return }
        lastRefreshRequestAt = now
        await pushViewerStreamConfiguration(force: true, refreshStream: true)
    }

    private func handleCodecGovernanceEvent(
        _ event: RemoteDesktopCodecGovernanceEvent,
        at now: Date
    ) async -> Bool {
        switch event {
        case .none:
            return false
        case .requestRefresh:
            await requestStreamRefreshIfNeeded()
            return false
        case .disableHEVC(let until):
            await decoder.resetPreservingLastFrame()
            lastDecoderResetTime = now
            consecutiveDecodeMisses = 0
            await pushViewerStreamConfiguration(force: true, refreshStream: true)
            let remaining = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
            SkyBridgeLogger.shared.warning(
                "⚠️ HEVC 解码连续失败，已临时降级到 H.264（冷却 \(remaining)s 后再自动探测恢复）"
            )
            return true
        case .reenableHEVCProbe:
            await requestStreamRefreshIfNeeded(minimumInterval: 1.0)
            SkyBridgeLogger.shared.info("♻️ H.264 回退流已稳定，准备重新探测 HEVC")
            return false
        }
    }

    private func startDecodeLoopIfNeeded() {
        guard !isDecodingFrame else { return }
        guard let next = pendingFrames.popLast() else { return }
        isDecodingFrame = true

        let decoder = self.decoder
        let screenData = next

        Task { [weak self] in
            guard let self else { return }
            let format = (screenData.format ?? "").lowercased()
            let isStillImageFrame = self.decoder.isStillImageFormat(format)
            let decoded: DecodeOutput?
            let decodeFailureReason: String?
            do {
                decoded = try await decoder.decode(screenData: screenData)
                decodeFailureReason = await decoder.consumeLastFailureReason()
            } catch {
                decoded = nil
                decodeFailureReason = error.localizedDescription
            }
            if let decoded {
                switch decoded {
                case .image(let frame):
                    self.videoFrameFeed.flush()
                    self.currentFrame = frame.image
                    self.updateRenderPipeline(.stillImageFallback)
                case .pixelBuffer(let frame):
                    self.currentFrame = nil
                    self.videoFrameFeed.update(frame: frame)
                    self.updateRenderPipeline(.metalZeroCopy)
                }
                let now = Date()
                self.lastRenderedFrameTime = now
                self.consecutiveDecodeMisses = 0
                let governanceEvent = self.codecGovernance.noteDecodeSuccess(format: format, at: now)
                _ = await self.handleCodecGovernanceEvent(governanceEvent, at: now)
                self.frameCount += 1
                if let lastTime = self.lastFrameTime {
                    let elapsed = now.timeIntervalSince(lastTime)
                    if elapsed >= 1.0 {
                        self.frameRate = Double(self.frameCount) / elapsed
                        self.frameCount = 0
                        self.lastFrameTime = now
                    }
                }
            } else {
                self.consecutiveDecodeMisses += 1
                let now = Date()
                if let lastRenderedFrameTime,
                   now.timeIntervalSince(lastRenderedFrameTime) >= 1.0 {
                    self.frameRate = 0
                }
                if isStillImageFrame {
                    self.consecutiveDecodeMisses = 0
                    self.isDecodingFrame = false
                    self.startDecodeLoopIfNeeded()
                    return
                }
                let governanceEvent = self.codecGovernance.noteDecodeFailure(
                    format: format,
                    reason: decodeFailureReason,
                    at: now
                )
                let governanceHandled = await self.handleCodecGovernanceEvent(governanceEvent, at: now)
                if governanceHandled {
                    self.isDecodingFrame = false
                    self.startDecodeLoopIfNeeded()
                    return
                }
                let canResetDecoder = self.lastDecoderResetTime.map { now.timeIntervalSince($0) >= 1.0 } ?? true
                if self.consecutiveDecodeMisses >= 6, canResetDecoder {
                    await self.decoder.resetPreservingLastFrame()
                    self.lastDecoderResetTime = now
                    self.consecutiveDecodeMisses = 0
                    await self.requestStreamRefreshIfNeeded()
                    SkyBridgeLogger.shared.warning("⚠️ 检测到远控视频解码停滞，已自动重置解码器")
                }
            }
            self.isDecodingFrame = false
            self.startDecodeLoopIfNeeded()
        }
    }
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

public enum RemoteDesktopRenderPipeline: String, Sendable {
    case waiting
    case metalZeroCopy
    case stillImageFallback

    public var displayName: String {
        switch self {
        case .waiting: return "等待首帧"
        case .metalZeroCopy: return "Metal 零拷贝"
        case .stillImageFallback: return "静态帧回退"
        }
    }
}
