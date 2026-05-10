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
@preconcurrency import AVFoundation
import AudioToolbox
import VideoToolbox
import ImageIO
import CoreImage
import CryptoKit
import SkyBridgeRealtimeMedia
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

    /// 多候选端点探测时，单个候选的建立超时（秒）
    public static let candidateConnectionTimeout: TimeInterval = 12
}

private func RemoteDesktopReleasePixelBufferBytes(
    _ releaseRefCon: UnsafeMutableRawPointer?,
    _ baseAddress: UnsafeRawPointer?
) {
    guard let releaseRefCon else { return }
    Unmanaged<NSData>.fromOpaque(releaseRefCon).release()
}

enum LANRemoteControlTrustResolution: Equatable {
    case missing
    case ambiguous(deviceIds: [String], fingerprints: [String])
    case resolved(record: TrustedDeviceStore.TrustedDevice, canonicalPeerId: String)
}

enum LANRemoteControlTrustResolver {
    static func resolve(
        device: DiscoveredDevice,
        trustedPeerId: String? = nil,
        trustedDevices: [TrustedDeviceStore.TrustedDevice]
    ) -> LANRemoteControlTrustResolution {
        let candidates = candidateAliases(for: device, trustedPeerId: trustedPeerId)
        let matches = trustedDevices.filter { trustedRecord in
            !recordAliases(for: trustedRecord).isDisjoint(with: candidates)
        }

        guard !matches.isEmpty else {
            return .missing
        }

        let deviceIds = Array(
            Set(
                matches
                    .map(resolvedCurrentDeviceId(for:))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        let fingerprints = Array(
            Set(
                matches
                    .compactMap(\.protocolPublicKeyFingerprint)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        ).sorted()

        guard deviceIds.count == 1 && fingerprints.count <= 1 else {
            return .ambiguous(deviceIds: deviceIds, fingerprints: fingerprints)
        }

        let canonicalPeerId = deviceIds[0]
        let preferredFingerprint = fingerprints.first
        let chosenRecord = matches.sorted { lhs, rhs in
            let lhsFingerprint = lhs.protocolPublicKeyFingerprint?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rhsFingerprint = rhs.protocolPublicKeyFingerprint?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            let lhsHasPreferredFingerprint = preferredFingerprint != nil && lhsFingerprint == preferredFingerprint
            let rhsHasPreferredFingerprint = preferredFingerprint != nil && rhsFingerprint == preferredFingerprint
            if lhsHasPreferredFingerprint != rhsHasPreferredFingerprint {
                return lhsHasPreferredFingerprint && !rhsHasPreferredFingerprint
            }

            let lhsHasAuthority = !(lhs.protocolSigningAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let rhsHasAuthority = !(rhs.protocolSigningAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if lhsHasAuthority != rhsHasAuthority {
                return lhsHasAuthority && !rhsHasAuthority
            }

            if lhs.addedAt != rhs.addedAt {
                return lhs.addedAt < rhs.addedAt
            }
            return lhs.id < rhs.id
        }.first!
        return .resolved(record: chosenRecord, canonicalPeerId: canonicalPeerId)
    }

    static func candidateAliases(
        for device: DiscoveredDevice,
        trustedPeerId: String? = nil
    ) -> Set<String> {
        var aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
        aliases.formUnion(PeerIdentityAliasResolver.aliasKeys(for: device))
        aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: trustedPeerId))
        if let ipAddress = device.ipAddress {
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }
        return Set(aliases.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    static func recordAliases(
        for trustedRecord: TrustedDeviceStore.TrustedDevice
    ) -> Set<String> {
        var aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: trustedRecord.id))
        if let currentDeviceId = trustedRecord.currentDeviceId {
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: currentDeviceId))
        }
        for knownDeviceId in trustedRecord.knownDeviceIds ?? [] {
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: knownDeviceId))
        }
        if let ipAddress = trustedRecord.ipAddress {
            aliases.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: ipAddress))
        }
        return aliases
    }

    static func resolvedCurrentDeviceId(
        for trustedRecord: TrustedDeviceStore.TrustedDevice
    ) -> String {
        trustedRecord.currentDeviceId ?? trustedRecord.id
    }
}

// MARK: - Remote Message Types

/// 远程消息类型（与 macOS `RemoteControlManager` 对齐）
public enum RemoteMessageType: String, Codable, Sendable {
    case screenData = "screenData"
    case mouseEvent = "mouseEvent"
    case keyboardEvent = "keyboardEvent"
    case clipboard = "clipboard"
    case streamConfiguration = "streamConfiguration"
    // Compile-compatible future hook. The shared Mac/core wire enums do not
    // define this yet; once they do, iOS LAN receive can consume it below.
    case streamConfigurationAck = "streamConfigurationAck"
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

public struct RemoteDesktopStreamConfigurationAckPayload: Codable, Sendable {
    public let acceptedAt: TimeInterval
    public let streamRefreshToken: UInt64?
    public let audioEndpointPresent: Bool
    public let screenFrameTransport: String?

    public init(
        acceptedAt: TimeInterval,
        streamRefreshToken: UInt64?,
        audioEndpointPresent: Bool,
        screenFrameTransport: String?
    ) {
        self.acceptedAt = acceptedAt
        self.streamRefreshToken = streamRefreshToken
        self.audioEndpointPresent = audioEndpointPresent
        self.screenFrameTransport = screenFrameTransport
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
    public let isSyncFrame: Bool?

    public init(
        width: Int,
        height: Int,
        imageData: Data,
        timestamp: TimeInterval,
        format: String? = nil,
        isSyncFrame: Bool? = nil
    ) {
        self.width = width
        self.height = height
        self.imageData = imageData
        self.timestamp = timestamp
        self.format = format
        self.isSyncFrame = isSyncFrame
    }
}

enum RemoteDesktopScreenFrameWire {
    private static let magic: UInt32 = 0x53425246 // "SBRF"
    private static let version: UInt8 = 1
    private static let headerSize = 28

    private enum CodecTag: UInt8 {
        case unknown = 0
        case jpeg = 1
        case h264 = 2
        case hevc = 3
        case bgra = 4

        init(format: String?) {
            switch (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "jpeg", "jpg":
                self = .jpeg
            case "h264":
                self = .h264
            case "hevc":
                self = .hevc
            case "bgra":
                self = .bgra
            default:
                self = .unknown
            }
        }

        var format: String? {
            switch self {
            case .unknown:
                return nil
            case .jpeg:
                return "jpeg"
            case .h264:
                return "h264"
            case .hevc:
                return "hevc"
            case .bgra:
                return "bgra"
            }
        }
    }

    static func decodeIfPresent(_ data: Data) -> ScreenData? {
        guard data.count >= headerSize else { return nil }
        guard readUInt32(from: data, offset: 0) == magic else { return nil }
        guard data[4] == version else { return nil }
        guard let codecTag = CodecTag(rawValue: data[5]) else { return nil }

        let flags = readUInt16(from: data, offset: 6)
        let width = Int(readUInt32(from: data, offset: 8))
        let height = Int(readUInt32(from: data, offset: 12))
        let timestampMicros = readUInt64(from: data, offset: 16)
        let payloadLength = Int(readUInt32(from: data, offset: 24))
        guard payloadLength >= 0, data.count == headerSize + payloadLength else { return nil }

        return ScreenData(
            width: width,
            height: height,
            imageData: data.subdata(in: headerSize..<data.count),
            timestamp: TimeInterval(timestampMicros) / 1_000_000.0,
            format: codecTag.format,
            isSyncFrame: (flags & 0x0001) != 0
        )
    }

    static func containsSyncFrame(
        format: String?,
        imageData: Data,
        advertisedSyncFrame: Bool?
    ) -> Bool {
        if advertisedSyncFrame == true {
            return true
        }

        switch CodecTag(format: format) {
        case .jpeg, .bgra, .unknown:
            return true
        case .h264:
            return parseNALUnits(from: imageData).contains { nalu in
                guard let first = nalu.first else { return false }
                return Int(first & 0x1F) == 5
            }
        case .hevc:
            return parseNALUnits(from: imageData).contains { nalu in
                guard let first = nalu.first else { return false }
                let type = Int((first >> 1) & 0x3F)
                return (16...21).contains(type)
            }
        }
    }

    private static func parseNALUnits(from data: Data) -> [Data] {
        if data.count >= 4,
           data.starts(with: [0x00, 0x00, 0x00, 0x01]) || data.starts(with: [0x00, 0x00, 0x01]) {
            return parseAnnexBNALUnits(from: data)
        }
        return parseLengthPrefixedNALUnits(from: data)
    }

    private static func parseLengthPrefixedNALUnits(from data: Data) -> [Data] {
        var nalus: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let length = data.withUnsafeBytes { raw -> Int in
                let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Int(UInt32(bigEndian: value))
            }
            offset += 4
            guard length > 0, offset + length <= data.count else { break }
            nalus.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return nalus
    }

    private static func parseAnnexBNALUnits(from data: Data) -> [Data] {
        func startCodeLength(at index: Int) -> Int? {
            guard index + 3 <= data.count else { return nil }
            if index + 4 <= data.count,
               data[index] == 0x00, data[index + 1] == 0x00, data[index + 2] == 0x00, data[index + 3] == 0x01 {
                return 4
            }
            if data[index] == 0x00, data[index + 1] == 0x00, data[index + 2] == 0x01 {
                return 3
            }
            return nil
        }

        var nalus: [Data] = []
        var currentStart: Int?
        var currentSkip = 0
        var index = 0

        while index < data.count {
            if let skip = startCodeLength(at: index) {
                if let start = currentStart {
                    let naluStart = start + currentSkip
                    if naluStart < index {
                        nalus.append(data.subdata(in: naluStart..<index))
                    }
                }
                currentStart = index
                currentSkip = skip
                index += skip
            } else {
                index += 1
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

    private static func readUInt16(from data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { rawBuffer in
            UInt16(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt16.self
                )
            )
        }
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            UInt32(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )
            )
        }
    }

    private static func readUInt64(from data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { rawBuffer in
            UInt64(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt64.self
                )
            )
        }
    }
}

extension ScreenData {
    var normalizedFormat: String {
        (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isCompressedPredictiveVideoFrame: Bool {
        switch normalizedFormat {
        case "h264", "hevc":
            return true
        default:
            return false
        }
    }

    var isIndependentlyDecodableFrame: Bool {
        if isCompressedPredictiveVideoFrame {
            return RemoteDesktopScreenFrameWire.containsSyncFrame(
                format: format,
                imageData: imageData,
                advertisedSyncFrame: isSyncFrame
            )
        }
        return true
    }
}

enum RemoteDesktopDecodeQueuePolicy {
    static let maxPredictiveVideoFrames = 12

    enum EnqueueResult: Equatable {
        case enqueued
        case replacedStillFrame
        case droppedIncomingPredictiveFrame
        case enteredWaitingForSync
        case recoveredWithIndependentFrame
    }

    static func isPredictiveVideoFormat(_ format: String?) -> Bool {
        switch (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "h264", "hevc":
            return true
        default:
            return false
        }
    }

    @discardableResult
    static func enqueue(
        _ screenData: ScreenData,
        into pendingFrames: inout [ScreenData],
        waitingForSyncFrame: inout Bool,
        maxPredictiveVideoFrames: Int = maxPredictiveVideoFrames
    ) -> EnqueueResult {
        guard isPredictiveVideoFormat(screenData.format) else {
            pendingFrames.removeAll(keepingCapacity: true)
            waitingForSyncFrame = false
            pendingFrames.append(screenData)
            return .replacedStillFrame
        }

        if screenData.isIndependentlyDecodableFrame {
            let shouldReportRecovery = waitingForSyncFrame || !pendingFrames.isEmpty
            pendingFrames.removeAll(keepingCapacity: true)
            waitingForSyncFrame = false
            pendingFrames.append(screenData)
            return shouldReportRecovery ? .recoveredWithIndependentFrame : .enqueued
        }

        guard !waitingForSyncFrame else {
            return .droppedIncomingPredictiveFrame
        }

        guard pendingFrames.count < maxPredictiveVideoFrames else {
            pendingFrames.removeAll(keepingCapacity: true)
            waitingForSyncFrame = true
            return .enteredWaitingForSync
        }

        pendingFrames.append(screenData)
        return .enqueued
    }

    static func dequeueNext(from pendingFrames: inout [ScreenData]) -> ScreenData? {
        guard !pendingFrames.isEmpty else { return nil }
        return pendingFrames.removeFirst()
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
final class DisplaySampleBufferFrame: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let width: Int
    let height: Int
    let presentationTimeStamp: CMTime

    init(
        sampleBuffer: CMSampleBuffer,
        width: Int,
        height: Int,
        presentationTimeStamp: CMTime
    ) {
        self.sampleBuffer = sampleBuffer
        self.width = width
        self.height = height
        self.presentationTimeStamp = presentationTimeStamp
    }
}

@available(iOS 17.0, *)
enum DecodeOutput: Sendable {
    case image(DecodedImageFrame)
    case pixelBuffer(DecodedPixelBufferFrame)
    case sampleBuffer(DisplaySampleBufferFrame)
}

@available(iOS 17.0, *)
@MainActor
final class RemoteVideoFrameFeed: ObservableObject {
    private static let maxPendingFrames = 3
    @Published private(set) var frameVersion: UInt64 = 0

    private(set) var pendingFrames: [DisplaySampleBufferFrame] = []
    private(set) var flushVersion: UInt64 = 0
    private(set) var hasDisplayedFrame = false
    private(set) var removeDisplayedImageOnFlush = true

    var hasFrame: Bool {
        hasDisplayedFrame || !pendingFrames.isEmpty
    }

    func enqueue(frame: DisplaySampleBufferFrame) {
        pendingFrames.append(frame)
        if pendingFrames.count > Self.maxPendingFrames {
            pendingFrames.removeFirst(pendingFrames.count - Self.maxPendingFrames)
        }
        frameVersion &+= 1
    }

    func markDisplayedFrame() {
        hasDisplayedFrame = true
    }

    func takePendingFrames() -> [DisplaySampleBufferFrame] {
        let frames = pendingFrames
        pendingFrames.removeAll(keepingCapacity: true)
        return frames
    }

    func flush(removeDisplayedImage: Bool = true) {
        pendingFrames.removeAll(keepingCapacity: true)
        removeDisplayedImageOnFlush = removeDisplayedImage
        if removeDisplayedImage {
            hasDisplayedFrame = false
        }
        flushVersion &+= 1
        frameVersion &+= 1
    }
}

@available(iOS 17.0, *)
@MainActor
final class RemoteMetalVideoFrameFeed: ObservableObject {
    @Published private(set) var frameVersion: UInt64 = 0

    private(set) var latestFrame: DecodedPixelBufferFrame?
    private(set) var flushVersion: UInt64 = 0
    private(set) var hasDisplayedFrame = false
    private(set) var removeDisplayedImageOnFlush = true

    var hasFrame: Bool {
        hasDisplayedFrame || latestFrame != nil
    }

    func enqueue(frame: DecodedPixelBufferFrame) {
        latestFrame = frame
        frameVersion &+= 1
    }

    func markDisplayedFrame() {
        hasDisplayedFrame = true
    }

    func takeLatestFrame() -> DecodedPixelBufferFrame? {
        // 不要清空 latestFrame - 保留它用于重复显示
        // MTKView 的 draw(in:) 可能以 60fps 调用，但帧到达速度可能更低
        // 如果清空，会导致 draw(in:) 取不到帧而显示空白
        return latestFrame
    }

    func flush(removeDisplayedImage: Bool = true) {
        latestFrame = nil
        removeDisplayedImageOnFlush = removeDisplayedImage
        if removeDisplayedImage {
            hasDisplayedFrame = false
        }
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
    private let nominalPresentationStep = CMTime(value: 1, timescale: 60)
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var activeCodec: Codec?
    private var h264SPS: Data?
    private var h264PPS: Data?
    private var hevcVPS: Data?
    private var hevcSPS: Data?
    private var hevcPPS: Data?
    private var activeVideoDimensions: CGSize?
    private var waitingForSyncFrame = false
    private var lastPresentationTimeStamp: CMTime?
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
            return try await decodeVideoFrame(
                payload,
                codec: .h264,
                width: screenData.width,
                height: screenData.height,
                isSyncFrame: screenData.isSyncFrame
            )
        case "hevc":
            return try await decodeVideoFrame(
                payload,
                codec: .hevc,
                width: screenData.width,
                height: screenData.height,
                isSyncFrame: screenData.isSyncFrame
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
            let pixelBufferFrame = DecodedPixelBufferFrame(
                pixelBuffer: pixelBuffer,
                width: width,
                height: height,
                presentationTimeStamp: nextDecodePresentationTimeStamp()
            )
            return .pixelBuffer(pixelBufferFrame)
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

    private func decodeVideoFrame(
        _ data: Data,
        codec: Codec,
        width: Int,
        height: Int,
        isSyncFrame: Bool?
    ) async throws -> DecodeOutput? {
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

        let containsSyncFrame = (isSyncFrame == true) || containsSyncFrame(in: nalus, codec: codec)
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

        guard let sampleData = makeDecoderSampleData(from: data, codec: codec) else {
            return nil
        }

        let sampleBuffer = try makeSampleBuffer(
            naluData: sampleData,
            formatDescription: formatDescription,
            presentationTimeStamp: nextDecodePresentationTimeStamp()
        )
        guard let pixelBufferFrame = try await decodeToPixelBufferFrame(
            sampleBuffer,
            codec: codec,
            width: width,
            height: height
        ) else {
            return nil
        }

        activeVideoDimensions = dimensions
        waitingForSyncFrame = false
        return .pixelBuffer(pixelBufferFrame)
    }

    private func resetDecoderState(keepLastFrame: Bool) {
        _ = keepLastFrame
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
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
	                                guard let parameterSetPointers = ptrs.baseAddress,
	                                      let parameterSetSizes = sz.baseAddress else {
	                                    return -1
	                                }
		                            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
		                                allocator: kCFAllocatorDefault,
		                                parameterSetCount: ptrs.count,
		                                parameterSetPointers: parameterSetPointers,
		                                parameterSetSizes: parameterSetSizes,
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
	                                    guard let parameterSetPointers = ptrs.baseAddress,
	                                          let parameterSetSizes = sz.baseAddress else {
	                                        return -1
	                                    }
		                                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
		                                    allocator: kCFAllocatorDefault,
		                                    parameterSetCount: ptrs.count,
		                                    parameterSetPointers: parameterSetPointers,
		                                    parameterSetSizes: parameterSetSizes,
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

    private func ensureDecompressionSession(
        codec: Codec,
        formatDescription: CMVideoFormatDescription
    ) throws {
        if decompressionSession != nil,
           let activeDescription = self.formatDescription,
           CMFormatDescriptionEqual(activeDescription, otherFormatDescription: formatDescription) {
            _ = codec
            return
        }

        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }

        let decoderSpecification: CFDictionary = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: false
        ] as CFDictionary

        let destinationAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: destinationAttributes,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw RemoteDesktopError.decodingFailed(
                "Failed to create decompression session (status=\(status))"
            )
        }
        decompressionSession = session
    }

    private func decodeToPixelBufferFrame(
        _ sampleBuffer: CMSampleBuffer,
        codec: Codec,
        width: Int,
        height: Int
    ) async throws -> DecodedPixelBufferFrame? {
        guard let formatDescription else {
            return nil
        }
        try ensureDecompressionSession(codec: codec, formatDescription: formatDescription)
        guard let decompressionSession else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            var decodeInfoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                decompressionSession,
                sampleBuffer: sampleBuffer,
                flags: [],
                infoFlagsOut: &decodeInfoFlags
            ) { status, _, imageBuffer, presentationTimeStamp, _ in
                guard status == noErr, let imageBuffer else {
                    continuation.resume(returning: nil)
                    return
                }
                let pixelBuffer = imageBuffer as CVPixelBuffer
                continuation.resume(
                    returning: DecodedPixelBufferFrame(
                        pixelBuffer: pixelBuffer,
                        width: width,
                        height: height,
                        presentationTimeStamp: presentationTimeStamp
                    )
                )
            }

            if status != noErr {
                continuation.resume(
                    throwing: RemoteDesktopError.decodingFailed(
                        "VideoToolbox decode failed (status=\(status))"
                    )
                )
            }
        }
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
            duration: .invalid,
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
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if let lastPresentationTimeStamp {
            let minimumNext = CMTimeAdd(lastPresentationTimeStamp, nominalPresentationStep)
            if now < minimumNext {
                self.lastPresentationTimeStamp = minimumNext
                return minimumNext
            }
        }
        lastPresentationTimeStamp = now
        return now
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

    func makeDisplaySampleBufferFrame(
        from pixelBufferFrame: DecodedPixelBufferFrame,
        format: String?
    ) -> DisplaySampleBufferFrame? {
        guard let sampleBuffer = makeImageBufferSampleBuffer(
            pixelBuffer: pixelBufferFrame.pixelBuffer,
            presentationTimeStamp: pixelBufferFrame.presentationTimeStamp
        ) else {
            return nil
        }
        _ = format
        return DisplaySampleBufferFrame(
            sampleBuffer: sampleBuffer,
            width: pixelBufferFrame.width,
            height: pixelBufferFrame.height,
            presentationTimeStamp: pixelBufferFrame.presentationTimeStamp
        )
    }

    private func makeImageBufferSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard descriptionStatus == noErr, let formatDescription else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }
        setDisplayImmediatelyAttachment(on: sampleBuffer)
        return sampleBuffer
    }

    private func setDisplayImmediatelyAttachment(on sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) else {
            return
        }
        guard CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
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
            // Skip parameter set NALUs — they are already conveyed via
            // CMVideoFormatDescription.  Including them in-band causes
            // AVSampleBufferDisplayLayer to silently stop decoding after
            // the first IDR frame (the "first-frame-only-freeze" symptom).
            if isParameterSetNALU(nalu, codec: codec) {
                continue
            }
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

    private func isParameterSetNALU(_ nalu: Data, codec: Codec) -> Bool {
        guard let first = nalu.first else { return false }
        switch codec {
        case .h264:
            let type = Int(first & 0x1F)
            // 7 = SPS, 8 = PPS
            return type == 7 || type == 8
        case .hevc:
            let type = Int((first >> 1) & 0x3F)
            // 32 = VPS, 33 = SPS, 34 = PPS
            return (32...34).contains(type)
        }
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
        lastPresentationTimeStamp = nil
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

struct RemoteDesktopAudioChunkPayload: Codable, Sendable, Equatable {
    enum Encoding: String, Codable, Sendable {
        case pcmS16LE = "pcm_s16le"
        case aacLC = "aac_lc"
    }

    struct PacketDescription: Codable, Sendable, Equatable {
        let startOffset: Int
        let variableFramesInPacket: UInt32
        let dataByteSize: UInt32
    }

    let encoding: Encoding
    let sampleRate: Int
    let channelCount: Int
    let frameCount: Int
    let packetCount: Int?
    let packetDescriptions: [PacketDescription]?
    let magicCookie: Data?
    let sequenceNumber: UInt64
    let sentAt: TimeInterval
    let data: Data

    init(
        encoding: Encoding = .pcmS16LE,
        sampleRate: Int,
        channelCount: Int,
        frameCount: Int,
        packetCount: Int? = nil,
        packetDescriptions: [PacketDescription]? = nil,
        magicCookie: Data? = nil,
        sequenceNumber: UInt64,
        sentAt: TimeInterval = Date().timeIntervalSince1970,
        data: Data
    ) {
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.packetCount = packetCount
        self.packetDescriptions = packetDescriptions
        self.magicCookie = magicCookie
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt
        self.data = data
    }
}

enum RemoteDesktopAudioChunkWire {
    private static let magic: UInt32 = 0x53425241 // "SBRA"
    private static let version: UInt8 = 2
    private static let version1HeaderSize = 36
    private static let headerSize = 48
    private static let packetDescriptionSize = 12

    private enum EncodingTag: UInt8 {
        case pcmS16LE = 1
        case aacLC = 2

        init?(encoding: RemoteDesktopAudioChunkPayload.Encoding) {
            switch encoding {
            case .pcmS16LE:
                self = .pcmS16LE
            case .aacLC:
                self = .aacLC
            }
        }

        var encoding: RemoteDesktopAudioChunkPayload.Encoding {
            switch self {
            case .pcmS16LE:
                return .pcmS16LE
            case .aacLC:
                return .aacLC
            }
        }
    }

    static func decodeIfPresent(_ data: Data) -> RemoteDesktopAudioChunkPayload? {
        guard data.count >= version1HeaderSize else { return nil }
        guard readUInt32(from: data, offset: 0) == magic else { return nil }
        switch data[4] {
        case 1:
            return decodeVersion1(data)
        case version:
            return decodeVersion2(data)
        default:
            return nil
        }
    }

    private static func decodeVersion1(_ data: Data) -> RemoteDesktopAudioChunkPayload? {
        guard data.count >= version1HeaderSize else { return nil }
        guard let encodingTag = EncodingTag(rawValue: data[5]) else { return nil }

        let channelCount = Int(data[6])
        let sampleRate = Int(readUInt32(from: data, offset: 8))
        let frameCount = Int(readUInt32(from: data, offset: 12))
        let sequenceNumber = readUInt64(from: data, offset: 16)
        let timestampMicros = readUInt64(from: data, offset: 24)
        let payloadLength = Int(readUInt32(from: data, offset: 32))

        guard channelCount > 0, sampleRate > 0, frameCount > 0 else { return nil }
        guard payloadLength >= 0, data.count == version1HeaderSize + payloadLength else { return nil }

        return RemoteDesktopAudioChunkPayload(
            encoding: encodingTag.encoding,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            sequenceNumber: sequenceNumber,
            sentAt: TimeInterval(timestampMicros) / 1_000_000.0,
            data: data.subdata(in: version1HeaderSize..<data.count)
        )
    }

    private static func decodeVersion2(_ data: Data) -> RemoteDesktopAudioChunkPayload? {
        guard data.count >= headerSize else { return nil }
        guard let encodingTag = EncodingTag(rawValue: data[5]) else { return nil }

        let channelCount = Int(data[6])
        let sampleRate = Int(readUInt32(from: data, offset: 8))
        let frameCount = Int(readUInt32(from: data, offset: 12))
        let packetCount = Int(readUInt32(from: data, offset: 16))
        let sequenceNumber = readUInt64(from: data, offset: 20)
        let timestampMicros = readUInt64(from: data, offset: 28)
        let magicCookieLength = Int(readUInt32(from: data, offset: 36))
        let packetDescriptionCount = Int(readUInt32(from: data, offset: 40))
        let payloadLength = Int(readUInt32(from: data, offset: 44))

        guard channelCount > 0, sampleRate > 0, frameCount > 0 else { return nil }
        guard magicCookieLength >= 0, packetDescriptionCount >= 0, payloadLength >= 0 else { return nil }

        let packetDescriptionsByteLength = packetDescriptionCount * packetDescriptionSize
        let metadataLength = magicCookieLength + packetDescriptionsByteLength
        guard data.count == headerSize + metadataLength + payloadLength else { return nil }

        let magicCookieRange = headerSize..<(headerSize + magicCookieLength)
        let packetDescriptionsStart = magicCookieRange.upperBound
        let packetDescriptionsEnd = packetDescriptionsStart + packetDescriptionsByteLength
        let payloadStart = packetDescriptionsEnd

        let magicCookie = magicCookieLength > 0 ? data.subdata(in: magicCookieRange) : nil
        let packetDescriptions: [RemoteDesktopAudioChunkPayload.PacketDescription]? = {
            guard packetDescriptionCount > 0 else { return nil }
            return (0..<packetDescriptionCount).map { index in
                let offset = packetDescriptionsStart + (index * packetDescriptionSize)
                return RemoteDesktopAudioChunkPayload.PacketDescription(
                    startOffset: Int(readUInt32(from: data, offset: offset)),
                    variableFramesInPacket: readUInt32(from: data, offset: offset + 4),
                    dataByteSize: readUInt32(from: data, offset: offset + 8)
                )
            }
        }()

        return RemoteDesktopAudioChunkPayload(
            encoding: encodingTag.encoding,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            packetCount: packetCount > 0 ? packetCount : nil,
            packetDescriptions: packetDescriptions,
            magicCookie: magicCookie,
            sequenceNumber: sequenceNumber,
            sentAt: TimeInterval(timestampMicros) / 1_000_000.0,
            data: data.subdata(in: payloadStart..<(payloadStart + payloadLength))
        )
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            UInt32(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )
            )
        }
    }

    private static func readUInt64(from data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { rawBuffer in
            UInt64(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt64.self
                )
            )
        }
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
    let screenFrameTransport: String?
    let screenDataChannelEnabled: Bool?
    let screenChannelWireFormat: String?
    let nativeVideoTrackReady: Bool?
    let nativeAudioTrackEnabled: Bool?
    let audioRedirectionEnabled: Bool?
    let audioTransport: String?
    let audioMode: String?
    let mediaSessionId: String?
    let mediaAudioEndpoint: SkyBridgeMediaEndpoint?
    let compatibilityAudioFallbackEnabled: Bool?
    let preferredAudioEncoding: String?
    let audioSampleRate: Int?
    let audioChannelCount: Int?
    let performanceValidationMode: String?
    let mediaFallbackPolicy: String?
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
        screenFrameTransport: String? = nil,
        screenDataChannelEnabled: Bool? = nil,
        screenChannelWireFormat: String? = nil,
        nativeVideoTrackReady: Bool? = nil,
        nativeAudioTrackEnabled: Bool? = nil,
        audioRedirectionEnabled: Bool? = nil,
        audioTransport: String? = nil,
        audioMode: String? = nil,
        mediaSessionId: String? = nil,
        mediaAudioEndpoint: SkyBridgeMediaEndpoint? = nil,
        compatibilityAudioFallbackEnabled: Bool? = nil,
        preferredAudioEncoding: String? = nil,
        audioSampleRate: Int? = nil,
        audioChannelCount: Int? = nil,
        performanceValidationMode: String? = nil,
        mediaFallbackPolicy: String? = nil,
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
        self.screenFrameTransport = screenFrameTransport
        self.screenDataChannelEnabled = screenDataChannelEnabled
        self.screenChannelWireFormat = screenChannelWireFormat
        self.nativeVideoTrackReady = nativeVideoTrackReady
        self.nativeAudioTrackEnabled = nativeAudioTrackEnabled
        self.audioRedirectionEnabled = audioRedirectionEnabled
        self.audioTransport = audioTransport
        self.audioMode = audioMode
        self.mediaSessionId = mediaSessionId
        self.mediaAudioEndpoint = mediaAudioEndpoint
        self.compatibilityAudioFallbackEnabled = compatibilityAudioFallbackEnabled
        self.preferredAudioEncoding = preferredAudioEncoding
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.performanceValidationMode = performanceValidationMode
        self.mediaFallbackPolicy = mediaFallbackPolicy
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
            && lhs.screenFrameTransport == rhs.screenFrameTransport
            && lhs.screenDataChannelEnabled == rhs.screenDataChannelEnabled
            && lhs.screenChannelWireFormat == rhs.screenChannelWireFormat
            && lhs.nativeVideoTrackReady == rhs.nativeVideoTrackReady
            && lhs.nativeAudioTrackEnabled == rhs.nativeAudioTrackEnabled
            && lhs.audioRedirectionEnabled == rhs.audioRedirectionEnabled
            && lhs.audioTransport == rhs.audioTransport
            && lhs.audioMode == rhs.audioMode
            && lhs.mediaSessionId == rhs.mediaSessionId
            && lhs.mediaAudioEndpoint == rhs.mediaAudioEndpoint
            && lhs.compatibilityAudioFallbackEnabled == rhs.compatibilityAudioFallbackEnabled
            && lhs.preferredAudioEncoding == rhs.preferredAudioEncoding
            && lhs.audioSampleRate == rhs.audioSampleRate
            && lhs.audioChannelCount == rhs.audioChannelCount
            && lhs.performanceValidationMode == rhs.performanceValidationMode
            && lhs.mediaFallbackPolicy == rhs.mediaFallbackPolicy
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
            if supportedFormats.contains("h264") {
                return "h264"
            }
            if supportedFormats.contains("hevc") {
                return "hevc"
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
            return "稳定优先 H.264，自适应 60 FPS，链路稳定后再探测更激进编码"
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
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "balanced",
                jitterBufferFrames: 2,
                lossRecoveryMode: "balanced"
            )
        case .clarity:
            return .init(
                qualityPresetWireValue: "clarity",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "quality-biased",
                jitterBufferFrames: 2,
                lossRecoveryMode: "balanced"
            )
        case .fluid:
            return .init(
                qualityPresetWireValue: "fluid",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "aggressive",
                jitterBufferFrames: 3,
                lossRecoveryMode: "resilient"
            )
        case .pro4k120:
            return .init(
                qualityPresetWireValue: "geek4k120",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "instant",
                jitterBufferFrames: 1,
                lossRecoveryMode: "fast-retransmit"
            )
        case .pro5k120:
            return .init(
                qualityPresetWireValue: "geek5k120",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "instant",
                jitterBufferFrames: 1,
                lossRecoveryMode: "fast-retransmit"
            )
        case .custom:
            return .init(
                qualityPresetWireValue: "custom",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
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
    public var audioRedirectionEnabled: Bool = true
    public var lowLatencyMode: Bool = false

    private enum CodingKeys: String, CodingKey {
        case resolution
        case frameRate
        case preferredCodec
        case clipboardSyncEnabled
        case audioRedirectionEnabled
        case lowLatencyMode
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try container.decodeIfPresent(RemoteDesktopViewerResolution.self, forKey: .resolution) ?? .auto
        frameRate = try container.decodeIfPresent(RemoteDesktopViewerFrameRate.self, forKey: .frameRate) ?? .adaptive
        preferredCodec = try container.decodeIfPresent(RemoteDesktopViewerCodec.self, forKey: .preferredCodec) ?? .automatic
        clipboardSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .clipboardSyncEnabled) ?? true
        audioRedirectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioRedirectionEnabled) ?? true
        lowLatencyMode = try container.decodeIfPresent(Bool.self, forKey: .lowLatencyMode) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(preferredCodec, forKey: .preferredCodec)
        try container.encode(clipboardSyncEnabled, forKey: .clipboardSyncEnabled)
        try container.encode(audioRedirectionEnabled, forKey: .audioRedirectionEnabled)
        try container.encode(lowLatencyMode, forKey: .lowLatencyMode)
    }

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
            interactionOverlayChannelEnabled: false,
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
            hevcFailureStreak += 1
            guard hevcFailureStreak >= 3 else {
                return .requestRefresh
            }

            hevcDisableCount += 1
            let cooldown = hevcDisableCount == 1 ? 20.0 : 60.0
            let disabledUntil = now.addingTimeInterval(cooldown)
            hevcDisabledUntil = disabledUntil
            hevcFailureStreak = 0
            stableFallbackFrameCount = 0
            return .disableHEVC(until: disabledUntil)
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

@available(iOS 17.0, *)
private struct RemoteAudioPlaybackContext: Sendable {
    let generation: UInt64
    let activeTransportModeIsCrossNetwork: Bool
    let nativeAudioReceiveEnabled: Bool
    let remoteAudioTrackHasReceivedFirstPacket: Bool
    let lastInboundScreenTimestamp: TimeInterval?
}

@available(iOS 17.0, *)
private final class RemoteAudioOneShotDecodeFeedState: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func takeIfAvailable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

@available(iOS 17.0, *)
private enum RemoteAudioPlaybackPolicy {
    private static let insufficientPriorityOSStatus = 561_017_449

    static func fallbackUnlockAt(
        activeTransportModeIsCrossNetwork: Bool,
        nativeAudioReceiveEnabled: Bool,
        remoteAudioTrackHasReceivedFirstPacket: Bool,
        currentUnlockAt: Date?,
        now: Date
    ) -> Date? {
        guard activeTransportModeIsCrossNetwork else { return nil }
        guard nativeAudioReceiveEnabled else { return nil }
        guard !remoteAudioTrackHasReceivedFirstPacket else { return nil }
        if let currentUnlockAt, now < currentUnlockAt {
            return currentUnlockAt
        }
        return now.addingTimeInterval(1.25)
    }

    static func retryDelay(for error: NSError) -> TimeInterval {
        if isInsufficientPriority(error) {
            return 5.0
        }
        return 1.0
    }

    static func isInsufficientPriority(_ error: NSError) -> Bool {
        error.domain == NSOSStatusErrorDomain && error.code == insufficientPriorityOSStatus
    }
}

@available(iOS 17.0, *)
private actor RemoteAudioPlaybackController {
    private struct BufferedChunk {
        let sequenceNumber: UInt64
        let sentAt: TimeInterval
        let enqueuedAt: Date
        let frameLength: AVAudioFrameCount
        let buffer: AVAudioPCMBuffer
    }

    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!
    private let maxAdaptiveQueuedFrames: AVAudioFrameCount = 48_000
    private let hardResetQueuedFrames: AVAudioFrameCount = 48_000 * 2

    private var minimumAcceptedGeneration: UInt64 = 0
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var decodeConverter: AVAudioConverter?
    private var decodeFormatSignature: String?
    private var queuedFrames: AVAudioFrameCount = 0
    private var bufferedChunks: [UInt64: BufferedChunk] = [:]
    private var bufferedChunkOrder: [UInt64] = []
    private var bufferedFrames: AVAudioFrameCount = 0
    private var expectedSequenceNumber: UInt64?
    private var lastArrivalAt: Date?
    private var lastSentAt: TimeInterval?
    private var arrivalJitter: TimeInterval = 0
    private var lastChunkDuration: TimeInterval = 0.02
    private var fallbackUnlockAt: Date?
    private var playbackRetryNotBefore: Date?
    private var lastFailureDescription: String?
    private var lastFailureLogAt: Date?
    private var lastPlaybackBackpressureLogAt: Date = .distantPast

    func handle(_ payload: RemoteDesktopAudioChunkPayload, context: RemoteAudioPlaybackContext) {
        guard context.generation >= minimumAcceptedGeneration else { return }
        if context.activeTransportModeIsCrossNetwork,
           context.nativeAudioReceiveEnabled,
           context.remoteAudioTrackHasReceivedFirstPacket {
            return
        }

        let now = Date()
        if shouldDelayFallbackPlayback(context: context, now: now) {
            return
        }
        if let retryNotBefore = playbackRetryNotBefore, now < retryNotBefore {
            return
        }
        if isChunkTooFarBehindVideo(payload.sentAt, lastScreenTimestamp: context.lastInboundScreenTimestamp) {
            return
        }

        do {
            try ensurePlaybackPipeline()
            playbackRetryNotBefore = nil
            lastFailureDescription = nil
            lastFailureLogAt = nil
        } catch {
            notePlaybackFailure(error, at: now)
            return
        }

        guard let playerNode else { return }
        noteArrival(payload, at: now)
        let buffer: AVAudioPCMBuffer?
        switch payload.encoding {
        case .pcmS16LE:
            buffer = makePCMPlaybackBuffer(from: payload)
        case .aacLC:
            buffer = decodeAACPlaybackBuffer(from: payload)
        }
        guard let buffer else { return }

        guard insertBufferedChunk(buffer, payload: payload, at: now) else { return }
        drainBufferedChunks(on: playerNode, now: now, lastScreenTimestamp: context.lastInboundScreenTimestamp)
    }

    func invalidate(upTo generation: UInt64, deactivateSession: Bool = true, resetFailureState: Bool = true) {
        let nextMinimum = generation == UInt64.max ? UInt64.max : generation + 1
        if nextMinimum > minimumAcceptedGeneration {
            minimumAcceptedGeneration = nextMinimum
        }
        teardown(deactivateSession: deactivateSession, resetFailureState: resetFailureState)
    }

    private func makePCMPlaybackBuffer(from payload: RemoteDesktopAudioChunkPayload) -> AVAudioPCMBuffer? {
        guard payload.sampleRate == Int(playbackFormat.sampleRate.rounded()),
              payload.channelCount == Int(playbackFormat.channelCount),
              payload.frameCount > 0 else {
            return nil
        }

        let bytesPerFrame = payload.channelCount * MemoryLayout<Int16>.size
        let expectedByteCount = payload.frameCount * bytesPerFrame
        guard payload.data.count == expectedByteCount else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(payload.frameCount)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(payload.frameCount)

        guard let channelData = buffer.floatChannelData else { return nil }
        let leftChannel = channelData[0]
        let rightChannel = channelData[1]
        payload.data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard samples.count == payload.frameCount * payload.channelCount else { return }
            for frame in 0..<payload.frameCount {
                let leftSample = Float(Int16(littleEndian: samples[frame * payload.channelCount]))
                leftChannel[frame] = leftSample / Float(Int16.max)
                let rightSample = Float(Int16(littleEndian: samples[(frame * payload.channelCount) + 1]))
                rightChannel[frame] = rightSample / Float(Int16.max)
            }
        }
        return buffer
    }

    private func decodeAACPlaybackBuffer(from payload: RemoteDesktopAudioChunkPayload) -> AVAudioPCMBuffer? {
        guard let packetCount = payload.packetCount, packetCount > 0 else { return nil }
        guard let inputFormat = AVAudioFormat(
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: payload.sampleRate,
                AVNumberOfChannelsKey: payload.channelCount
            ]
        ) else {
            return nil
        }

        let converterSignature = "aac-\(payload.sampleRate)-\(payload.channelCount)"
        if decodeConverter == nil || decodeFormatSignature != converterSignature {
            decodeConverter = AVAudioConverter(from: inputFormat, to: playbackFormat)
            decodeConverter?.primeMethod = .none
            decodeFormatSignature = converterSignature
        }
        guard let decodeConverter else { return nil }
        if let magicCookie = payload.magicCookie {
            decodeConverter.magicCookie = magicCookie
        }

        let maximumPacketSize = max(
            payload.packetDescriptions?.map { Int($0.dataByteSize) }.max() ?? 0,
            payload.data.count
        )
        let compressedBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: AVAudioPacketCount(packetCount),
            maximumPacketSize: max(1, maximumPacketSize)
        )
        compressedBuffer.packetCount = AVAudioPacketCount(packetCount)
        compressedBuffer.byteLength = UInt32(payload.data.count)
        payload.data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(compressedBuffer.data, baseAddress, payload.data.count)
        }

        if let packetDescriptions = payload.packetDescriptions,
           let packetDescriptionsPointer = compressedBuffer.packetDescriptions,
           packetDescriptions.count == packetCount {
            for (index, packetDescription) in packetDescriptions.enumerated() {
                packetDescriptionsPointer[index] = AudioStreamPacketDescription(
                    mStartOffset: Int64(packetDescription.startOffset),
                    mVariableFramesInPacket: packetDescription.variableFramesInPacket,
                    mDataByteSize: packetDescription.dataByteSize
                )
            }
        }

        let outputCapacity = AVAudioFrameCount(max(payload.frameCount + 256, 2048))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        let inputState = RemoteAudioOneShotDecodeFeedState()
        var decodeError: NSError?
        let status = decodeConverter.convert(to: outputBuffer, error: &decodeError) { _, outStatus in
            if !inputState.takeIfAvailable() {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return compressedBuffer
        }

        guard decodeError == nil else {
            SkyBridgeLogger.shared.debug("ℹ️ 远端 AAC 音频解码失败: \(decodeError?.localizedDescription ?? "unknown")")
            return nil
        }
        guard status == .haveData || status == .inputRanDry else { return nil }
        guard outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }

    private func shouldDelayFallbackPlayback(context: RemoteAudioPlaybackContext, now: Date) -> Bool {
        guard let unlockAt = RemoteAudioPlaybackPolicy.fallbackUnlockAt(
            activeTransportModeIsCrossNetwork: context.activeTransportModeIsCrossNetwork,
            nativeAudioReceiveEnabled: context.nativeAudioReceiveEnabled,
            remoteAudioTrackHasReceivedFirstPacket: context.remoteAudioTrackHasReceivedFirstPacket,
            currentUnlockAt: fallbackUnlockAt,
            now: now
        ) else {
            fallbackUnlockAt = nil
            return false
        }
        fallbackUnlockAt = unlockAt
        return now < unlockAt
    }

    private func notePlaybackFailure(_ error: Error, at now: Date) {
        let nsError = error as NSError
        playbackRetryNotBefore = now.addingTimeInterval(Self.retryDelay(for: nsError))
        let description = "\(error.localizedDescription) [domain=\(nsError.domain) code=\(nsError.code)]"
        let shouldLog: Bool
        if let lastFailureDescription,
           let lastFailureLogAt,
           lastFailureDescription == description,
           now.timeIntervalSince(lastFailureLogAt) < 2.0 {
            shouldLog = false
        } else {
            shouldLog = true
        }

        if shouldLog {
            SkyBridgeLogger.shared.error("❌ 初始化远端音频播放失败: \(description)")
            lastFailureDescription = description
            lastFailureLogAt = now
        }
    }

    private static func retryDelay(for error: NSError) -> TimeInterval {
        RemoteAudioPlaybackPolicy.retryDelay(for: error)
    }

    private func setSessionPreferences(_ session: AVAudioSession) {
        do {
            try session.setPreferredSampleRate(playbackFormat.sampleRate)
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ 远端音频播放采样率偏好未生效: \(error.localizedDescription)")
        }

        do {
            try session.setPreferredIOBufferDuration(0.02)
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ 远端音频播放 I/O 缓冲偏好未生效: \(error.localizedDescription)")
        }
    }

    private func configureSession(_ session: AVAudioSession) throws {
        do {
            do {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.mixWithOthers]
                )
            } catch {
                let nsError = error as NSError
                SkyBridgeLogger.shared.warning(
                    "⚠️ 远端音频阶段失败 stage=playback_set_category domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
                )
                throw error
            }
            setSessionPreferences(session)
            do {
                try session.setActive(true)
            } catch {
                let nsError = error as NSError
                SkyBridgeLogger.shared.warning(
                    "⚠️ 远端音频阶段失败 stage=playback_set_active domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
                )
                throw error
            }
            return
        } catch {
            let nsError = error as NSError
            SkyBridgeLogger.shared.warning(
                "⚠️ 远端音频 playback mixed 会话初始化失败: domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
            )
            guard RemoteAudioPlaybackPolicy.isInsufficientPriority(nsError)
                    || (nsError.domain == NSOSStatusErrorDomain && nsError.code == -50) else {
                throw error
            }

            SkyBridgeLogger.shared.warning(
                "⚠️ 远端音频尝试 ambient fallback: \(error.localizedDescription)"
            )
        }

        do {
            try session.setCategory(
                .ambient,
                mode: .default,
                options: []
            )
        } catch {
            let nsError = error as NSError
            SkyBridgeLogger.shared.warning(
                "⚠️ 远端音频阶段失败 stage=ambient_set_category domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
            )
            throw error
        }
        setSessionPreferences(session)
        do {
            try session.setActive(true)
        } catch {
            let nsError = error as NSError
            SkyBridgeLogger.shared.warning(
                "⚠️ 远端音频阶段失败 stage=ambient_set_active domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
            )
            throw error
        }
    }

    private func ensurePlaybackPipeline() throws {
        if let engine, engine.isRunning, playerNode != nil {
            return
        }

        teardown(deactivateSession: false, resetFailureState: false)

        let session = AVAudioSession.sharedInstance()
        try configureSession(session)

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            let nsError = error as NSError
            SkyBridgeLogger.shared.warning(
                "⚠️ 远端音频阶段失败 stage=engine_start domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
            )
            throw error
        }
        playerNode.play()

        self.engine = engine
        self.playerNode = playerNode
        decodeConverter = nil
        decodeFormatSignature = nil
        queuedFrames = 0
        resetBufferedState()
    }

    private func teardown(deactivateSession: Bool, resetFailureState: Bool) {
        let oldPlayerNode = playerNode
        let oldEngine = engine

        playerNode = nil
        engine = nil
        decodeConverter = nil
        decodeFormatSignature = nil
        queuedFrames = 0
        fallbackUnlockAt = nil
        if resetFailureState {
            playbackRetryNotBefore = nil
            lastFailureDescription = nil
            lastFailureLogAt = nil
        }
        resetBufferedState()

        oldPlayerNode?.stop()
        oldPlayerNode?.reset()
        oldEngine?.stop()
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func resetBufferedState() {
        bufferedChunks.removeAll(keepingCapacity: false)
        bufferedChunkOrder.removeAll(keepingCapacity: false)
        bufferedFrames = 0
        expectedSequenceNumber = nil
        lastArrivalAt = nil
        lastSentAt = nil
        arrivalJitter = 0
        lastChunkDuration = 0.02
        lastPlaybackBackpressureLogAt = .distantPast
    }

    private func noteArrival(_ payload: RemoteDesktopAudioChunkPayload, at now: Date) {
        let chunkDuration = TimeInterval(payload.frameCount) / max(Double(payload.sampleRate), 1)
        if let lastArrivalAt, let lastSentAt {
            let arrivalDelta = now.timeIntervalSince(lastArrivalAt)
            let sentDelta = max(0, payload.sentAt - lastSentAt)
            let transitDelta = arrivalDelta - sentDelta
            arrivalJitter = (arrivalJitter * 0.875) + (abs(transitDelta) * 0.125)
        }
        lastArrivalAt = now
        lastSentAt = payload.sentAt
        lastChunkDuration = chunkDuration.isFinite && chunkDuration > 0 ? chunkDuration : 0.02
    }

    private func insertBufferedChunk(
        _ buffer: AVAudioPCMBuffer,
        payload: RemoteDesktopAudioChunkPayload,
        at now: Date
    ) -> Bool {
        guard bufferedChunks[payload.sequenceNumber] == nil else { return false }
        let chunk = BufferedChunk(
            sequenceNumber: payload.sequenceNumber,
            sentAt: payload.sentAt,
            enqueuedAt: now,
            frameLength: buffer.frameLength,
            buffer: buffer
        )
        bufferedChunks[payload.sequenceNumber] = chunk
        bufferedChunkOrder.append(payload.sequenceNumber)
        bufferedChunkOrder.sort()
        bufferedFrames += chunk.frameLength
        if expectedSequenceNumber == nil {
            expectedSequenceNumber = bufferedChunkOrder.first
        }
        return true
    }

    private func drainBufferedChunks(
        on playerNode: AVAudioPlayerNode,
        now: Date,
        lastScreenTimestamp: TimeInterval?
    ) {
        normalizeBufferedStateIfNeeded()

        while let firstSequenceNumber = bufferedChunkOrder.first {
            if shouldHoldBufferedAudioForStartup(firstSequenceNumber: firstSequenceNumber, now: now) {
                break
            }

            if expectedSequenceNumber == nil {
                expectedSequenceNumber = firstSequenceNumber
            }
            guard let expectedSequenceNumber else { break }

            if let chunk = bufferedChunks[expectedSequenceNumber] {
                removeBufferedChunk(sequenceNumber: expectedSequenceNumber)

                if isChunkTooFarBehindVideo(chunk.sentAt, lastScreenTimestamp: lastScreenTimestamp) {
                    continue
                }

                if queuedFrames > currentHardResetQueuedFrames {
                    resetPlayerQueue(on: playerNode, reason: "queued-audio-runaway")
                    continue
                }

                if queuedFrames + chunk.frameLength > currentMaxQueuedFrames {
                    logPlaybackBackpressureIfNeeded(
                        queuedFrames: queuedFrames,
                        droppedFrames: chunk.frameLength,
                        now: now
                    )
                    self.expectedSequenceNumber = expectedSequenceNumber &+ 1
                    continue
                }

                scheduleBufferedChunk(chunk, on: playerNode)
                self.expectedSequenceNumber = expectedSequenceNumber &+ 1
                continue
            }

            if firstSequenceNumber < expectedSequenceNumber {
                removeBufferedChunk(sequenceNumber: firstSequenceNumber)
                continue
            }

            let oldestWait = bufferedChunks[firstSequenceNumber].map { now.timeIntervalSince($0.enqueuedAt) } ?? 0
            if bufferedChunkOrder.count >= 10 || oldestWait >= 0.20 {
                self.expectedSequenceNumber = firstSequenceNumber
                continue
            }
            break
        }
    }

    private func shouldHoldBufferedAudioForStartup(firstSequenceNumber: UInt64, now: Date) -> Bool {
        guard queuedFrames == 0 else { return false }
        guard bufferedFrames > 0 else { return false }
        guard bufferedFrames < currentStartupQueuedFrames else { return false }
        guard let firstChunk = bufferedChunks[firstSequenceNumber] else { return false }
        return now.timeIntervalSince(firstChunk.enqueuedAt) < 0.22
    }

    private func scheduleBufferedChunk(_ chunk: BufferedChunk, on playerNode: AVAudioPlayerNode) {
        let scheduledFrameLength = chunk.frameLength
        queuedFrames += scheduledFrameLength
        playerNode.scheduleBuffer(chunk.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { [weak self] in
                await self?.decrementQueuedFrames(by: scheduledFrameLength)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func decrementQueuedFrames(by frameLength: AVAudioFrameCount) {
        queuedFrames = queuedFrames > frameLength ? queuedFrames - frameLength : 0
    }

    private func removeBufferedChunk(sequenceNumber: UInt64) {
        guard let chunk = bufferedChunks.removeValue(forKey: sequenceNumber) else { return }
        bufferedChunkOrder.removeAll { $0 == sequenceNumber }
        bufferedFrames = bufferedFrames > chunk.frameLength ? bufferedFrames - chunk.frameLength : 0
    }

    private func normalizeBufferedStateIfNeeded() {
        while bufferedChunkOrder.count > 16 {
            guard let firstSequenceNumber = bufferedChunkOrder.first else { break }
            removeBufferedChunk(sequenceNumber: firstSequenceNumber)
            expectedSequenceNumber = bufferedChunkOrder.first
        }
    }

    private func resetPlayerQueue(on playerNode: AVAudioPlayerNode, reason: String) {
        playerNode.stop()
        playerNode.reset()
        playerNode.play()
        queuedFrames = 0
        resetBufferedState()
        SkyBridgeLogger.shared.debug("ℹ️ 已重置远端音频播放队列: \(reason)")
    }

    private func logPlaybackBackpressureIfNeeded(
        queuedFrames: AVAudioFrameCount,
        droppedFrames: AVAudioFrameCount,
        now: Date
    ) {
        guard now.timeIntervalSince(lastPlaybackBackpressureLogAt) >= 2.0 else { return }
        lastPlaybackBackpressureLogAt = now
        let queuedMs = Int((Double(queuedFrames) / playbackFormat.sampleRate) * 1_000)
        let droppedMs = Int((Double(droppedFrames) / playbackFormat.sampleRate) * 1_000)
        SkyBridgeLogger.shared.debug(
            "ℹ️ 远端音频播放队列背压: queuedMs=\(queuedMs) droppedMs=\(droppedMs)"
        )
    }

    private func isChunkTooFarBehindVideo(_ sentAt: TimeInterval, lastScreenTimestamp: TimeInterval?) -> Bool {
        guard let lastScreenTimestamp else { return false }
        let allowedBehind = max(0.25, currentTargetBufferedDuration + 0.18)
        return sentAt + allowedBehind < lastScreenTimestamp
    }

    private var currentStartupQueuedFrames: AVAudioFrameCount {
        frames(for: min(max(currentTargetBufferedDuration, 0.20), 0.32))
    }

    private var currentMaxQueuedFrames: AVAudioFrameCount {
        frames(for: min(0.75, currentTargetBufferedDuration + 0.35))
    }

    private var currentHardResetQueuedFrames: AVAudioFrameCount {
        hardResetQueuedFrames
    }

    private var currentTargetBufferedDuration: TimeInterval {
        let adaptive = min(0.24, max(0, arrivalJitter * 4.0))
        return min(0.42, max(0.16, (lastChunkDuration * 6.0) + adaptive))
    }

    private func frames(for duration: TimeInterval) -> AVAudioFrameCount {
        AVAudioFrameCount(
            max(
                1,
                min(
                    Double(maxAdaptiveQueuedFrames),
                    (playbackFormat.sampleRate * max(duration, 0)).rounded()
                )
            )
        )
    }
}

// MARK: - RemoteDesktopManager

/// 远程桌面管理器 - iOS 作为查看器/控制端
@available(iOS 17.0, *)
@MainActor
public class RemoteDesktopManager: ObservableObject {
    public static let instance = RemoteDesktopManager()
    public static let crossNetworkDeviceCapability = "cross_network_remote"
    private static let crossNetworkNativeAudioReceiveEnabled = false
    private static let realtimeMediaAudioReceiverSlowDiagnosticDelay: Duration = .seconds(3)
    private static let realtimeMediaAudioReceiverStageTimeout: Duration = .seconds(8)
    private static let realtimeMediaAudioReceiverTotalTimeout: Duration = .seconds(15)
    private static let realtimeMediaAudioRelayBindAckGraceDelay: Duration = .seconds(5)
    private static let realtimeMediaAudioNoTrafficRecoveryDelay: Duration = .seconds(10)
    private static let realtimeMediaAudioNoTrafficRecoveryMaxAttempts: Int = 2
    private static let realtimeMediaAudioRelayRolloverGraceDelay: Duration = .seconds(15)
    private static let realtimeMediaAudioEndpointRenewalLeadTime: TimeInterval = 12
    private static let viewerSettingsStore = CodablePersistenceStore<RemoteDesktopViewerSettings>(
        location: .protectedApplicationSupport(
            path: "RemoteDesktop/viewer-settings.json",
            legacyUserDefaultsKey: "com.skybridge.remoteDesktop.viewerSettings.v1"
        )
    )

    nonisolated static func fallbackRemoteAudioUnlockAt(
        activeTransportModeIsCrossNetwork: Bool,
        nativeAudioReceiveEnabled: Bool,
        remoteAudioTrackHasReceivedFirstPacket: Bool,
        currentUnlockAt: Date?,
        now: Date
    ) -> Date? {
        RemoteAudioPlaybackPolicy.fallbackUnlockAt(
            activeTransportModeIsCrossNetwork: activeTransportModeIsCrossNetwork,
            nativeAudioReceiveEnabled: nativeAudioReceiveEnabled,
            remoteAudioTrackHasReceivedFirstPacket: remoteAudioTrackHasReceivedFirstPacket,
            currentUnlockAt: currentUnlockAt,
            now: now
        )
    }

    nonisolated static func remoteAudioPlaybackRetryDelay(for error: NSError) -> TimeInterval {
        RemoteAudioPlaybackPolicy.retryDelay(for: error)
    }

    private struct IncomingStreamSignature: Equatable {
        let format: String
        let width: Int
        let height: Int
    }

    nonisolated static func shouldIgnoreFallbackFrameAfterNativeVideoRendered(
        activeTransportModeIsCrossNetwork: Bool,
        nativeVideoTrackHasRenderedFrame: Bool
    ) -> Bool {
        activeTransportModeIsCrossNetwork && nativeVideoTrackHasRenderedFrame
    }

    nonisolated static func shouldDropNativeWarmupNonJPEGFallbackFrame(
        activeTransportModeIsCrossNetwork: Bool,
        hasRemoteNativeVideoTrack: Bool,
        nativeVideoTrackHasRenderedFrame: Bool,
        format: String?
    ) -> Bool {
        guard activeTransportModeIsCrossNetwork,
              hasRemoteNativeVideoTrack,
              !nativeVideoTrackHasRenderedFrame else {
            return false
        }
        let normalizedFormat = format?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedFormat != "jpeg" && normalizedFormat != "jpg"
    }

    nonisolated static func shouldUseJPEGOnlyFallbackDuringNativeWarmup(
        activeTransportModeIsCrossNetwork: Bool,
        hasRemoteNativeVideoTrack: Bool,
        nativeVideoTrackHasRenderedFrame: Bool
    ) -> Bool {
        activeTransportModeIsCrossNetwork
            && hasRemoteNativeVideoTrack
            && !nativeVideoTrackHasRenderedFrame
    }

    nonisolated static func shouldRequestExtremeMediaValidation(
        activeTransportModeIsCrossNetwork: Bool,
        viewerSettings: RemoteDesktopViewerSettings,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["SKYBRIDGE_WEBRTC_EXTREME_MEDIA"] == "1"
            || environment["SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK"] == "1" {
            return true
        }
        guard activeTransportModeIsCrossNetwork else { return false }
        switch viewerSettings.activePreset {
        case .clarity, .pro4k120, .pro5k120:
            return true
        case .custom:
            return viewerSettings.targetFrameRate >= 60
                && viewerSettings.preferredCodec != .jpeg
                && viewerSettings.resolution != .hd720
        case .automatic, .fluid:
            return false
        }
    }

    private struct CurrentPathRemoteAuthority: Sendable {
        let deviceId: String
        let protocolPublicKeyFingerprint: String
    }

    private struct LANHandshakeTrustProvider: HandshakeTrustProvider, Sendable {
        let expectedRemoteAuthority: CurrentPathRemoteAuthority
        let fallbackPeerIDs: [String]

        func trustedFingerprint(for deviceId: String) async -> String? {
            if deviceId == expectedRemoteAuthority.deviceId || fallbackPeerIDs.contains(deviceId) {
                return expectedRemoteAuthority.protocolPublicKeyFingerprint
            }
            return nil
        }

        func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite : Data] {
            await KEMTrustStore.shared.kemPublicKeys(for: deviceId)
        }

        func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
            _ = deviceId
            return nil
        }
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
    private var lastGoodFrozenFrame: CGImage?
    let videoFrameFeed = RemoteVideoFrameFeed()
    let metalVideoFrameFeed = RemoteMetalVideoFrameFeed()
    
    /// 帧率
    @Published public private(set) var frameRate: Double = 0
    
    /// 延迟（毫秒）
    @Published public private(set) var latency: Double = 0
    
    /// 分辨率
    @Published public private(set) var resolution: CGSize = .zero

    /// 当前传输方式（用于 UI 提示）
    @Published public private(set) var transportStatusText: String?
    @Published public private(set) var renderPipelineStatus: RemoteDesktopRenderPipeline = .waiting
    @Published public private(set) var isUsingCrossNetworkTransport = false
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
            if oldValue.audioRedirectionEnabled && !viewerSettings.audioRedirectionEnabled {
                teardownRemoteAudioPlayback()
            }
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

    private enum DecodedVideoRendererPreference {
        case metal
        case sampleBuffer
        case cgImage
    }

    private enum RealtimeMediaAudioReceiverStartPhase: String {
        case pending
        case lease
        case udpConnection
        case relayBindAck
        case receiverReady
    }

    private enum RealtimeMediaAudioReceiverStartFailureReason: String {
        case stageTimeout
        case totalTimeout
    }

    private enum OptimisticRelayBindState: Equatable {
        case idle
        case ackPending(sessionId: String, endpoint: SkyBridgeMediaEndpoint)
        case accepted(sessionId: String, endpoint: SkyBridgeMediaEndpoint)
        case trafficObserved(sessionId: String, endpoint: SkyBridgeMediaEndpoint)
        case failed(sessionId: String, endpoint: SkyBridgeMediaEndpoint, reason: String)
    }

    private let skyBridgeCore = SkyBridgeiOSCore.shared
    private var networkConnection: NWConnection?
    private var lanHandshakeTransport: NWConnectionTransport?
    private var lanHandshakeDriver: HandshakeDriver?
    private var lanSessionKeys: SessionKeys?
    private var lanHandshakePeerId: String?
    private var activeTransportMode: ActiveTransportMode = .none
    private let decoder = VideoDecoder()
    private let queue = DispatchQueue(label: "com.skybridge.remotedesktop", qos: .userInteractive)
    private let fallbackImageContext = CIContext(options: [.cacheIntermediates: false])
    private let remoteAudioPlayback = RemoteAudioPlaybackController()
    private var remoteAudioPlaybackGeneration: UInt64 = 0
    
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
    private let maxEncryptedLANMessageOverheadBytes: Int = 28
    private let maxConcurrentVideoDecodes: Int = 3
    private let sampleBufferNoEnqueueWindowThreshold: Int = 3
    private let sampleBufferDisplayStallRecoveryThreshold: Int = 3
    private var inFlightDecodeCount: Int = 0
    private var decodeGeneration: UInt64 = 0
    private var pendingFrames: [ScreenData] = []
    private var decodeQueueWaitingForSyncFrame = false
    private var lastDecodeQueueOverflowLogTime: Date = .distantPast
    private let connectionManager = P2PConnectionManager.instance
    private let crossNetwork = CrossNetworkWebRTCManager.instance
    private var clipboardSessionId: UUID?
    private var clipboardListenerToken: UUID?
    private var pendingViewerSettingsTask: Task<Void, Never>?
    private var lastSentStreamConfiguration: RemoteDesktopStreamConfigurationPayload?
    private var realtimeMediaAudioReceiver: SkyBridgeUDPRealtimeMediaReceiver?
    private var realtimeMediaAudioRelayTransport: SkyBridgeUDPRealtimeMediaTransport?
    private var realtimeMediaAudioRenderer: IOSRealtimeMediaAudioReceiver?
    private var realtimeMediaAudioReceiverSessionId: String?
    private var realtimeMediaAudioEndpoint: SkyBridgeMediaEndpoint?
    private var realtimeMediaAudioReceiverStartTask: Task<Void, Never>?
    private var realtimeMediaAudioReceiverStartGeneration: UInt64 = 0
    private var realtimeMediaAudioReceiverStartPhase: RealtimeMediaAudioReceiverStartPhase?
    private var realtimeMediaAudioRelayBindState: OptimisticRelayBindState = .idle
    private var realtimeMediaAudioRelayBindGraceTask: Task<Void, Never>?
    private var realtimeMediaAudioRelayRenewalTask: Task<Void, Never>?
    private var realtimeMediaAudioNoTrafficRecoveryTask: Task<Void, Never>?
    private var realtimeMediaAudioNoTrafficRecoveryAttemptsBySessionId: [String: Int] = [:]
    private var streamConfigurationAckTask: Task<Void, Never>?
    private var streamConfigurationAckGeneration: UInt64 = 0
    private var streamConfigurationAckSatisfied: Bool = false
    private var lastHandledSessionAuthorityLostStreamEpoch: UInt64?
    private var lastCrossNetworkNativeReadyAnnouncementAt: Date?
    private var lastIncomingStreamSignature: IncomingStreamSignature?
    private var lastStreamTopologyChangeAt: Date = .distantPast
    private var streamTopologyFlapSuppressedUntil: Date = .distantPast
    private var streamTopologyFlapCount: Int = 0
    private var lastStreamTopologyRefreshSignature: IncomingStreamSignature?
    private var streamRefreshTokenCounter: UInt64 = 0
    private var lastRefreshRequestAt: Date?
    private var lastRequestedStreamRefreshToken: UInt64?
    private var lastRequestedStreamRefreshReason: String?
    private var lastRequestedStreamRefreshAt: Date?
    private var lastRefreshRequestFailureDescription: String?
    private var hevcDisableRefreshSuppressedUntil: Date?
    private var hevcDisableRefreshTokenInFlight: UInt64?
    private var lastWaitingSyncDiagnosticLogTime: Date = .distantPast
    private var lastNativePrimaryIgnoredFallbackDiagnosticAt: Date = .distantPast
    private var lastNativeWarmupNonJPEGFallbackDropDiagnosticAt: Date = .distantPast
    private let streamDecodeStallRefreshMinimumInterval: TimeInterval = 3.0
    private var codecGovernance = RemoteDesktopCodecGovernance()
    private var decodedVideoRendererPreference: DecodedVideoRendererPreference = .metal
    private var streamEpoch: UInt64 = 0
    private var lastFrameArrivalAt: Date?
    private var lastDecodedFrameTime: Date?
    private var lastAcceptedDecodedPresentationTimeStamp: CMTime?
    private var lastVideoRendererEnqueueAt: Date?
    private var lastDisplayedFrameTime: Date?
    private let latencyPublishInterval: TimeInterval = 0.25
    private var lastLatencyPublishAt: Date = .distantPast
    private var metalAwaitingFirstDisplaySince: Date?
    private var receivedFrameCountInCurrentStream: Int = 0
    private var statsWindowStartTime: Date?
    private var receivedFramesInStatsWindow: Int = 0
    private var decodedFramesInStatsWindow: Int = 0
    private var rendererEnqueuedFramesInStatsWindow: Int = 0
    private var displayedFramesInStatsWindow: Int = 0
    private var consecutiveSampleBufferNoEnqueueWindows: Int = 0
    private var consecutiveSampleBufferDisplayStalls: Int = 0
    private var lastInboundScreenTimestamp: TimeInterval?
    private var lastViewerInteractionAt: Date?
    private var lastContinuityRecoveryAt: Date?
    private var streamContinuityWatchdogTask: Task<Void, Never>?
    private var firstFrameContinuityTask: Task<Void, Never>?
    private var interactionContinuityTask: Task<Void, Never>?
    private var lastMetalFallbackAt: Date?
    private let metalFallbackRestoreCooldown: TimeInterval = 0.75
    private let metalFallbackStableFrameRestoreThreshold = 2
    private let metalFallbackPersistentFailureThreshold = 3
    private let metalFallbackPersistentFailureCooldown: TimeInterval = 6
    private let metalFallbackExpectedRestoreWindow: TimeInterval = 2
    private var metalRestoreFailureCount: Int = 0
    private var metalRestoreSuppressedUntil: Date?
    private var metalFallbackReason: String?
    private var stableSampleBufferFramesSinceMetalFallback: Int = 0
    private var crossNetworkFrameSubscriptionTask: Task<Void, Never>?
    private var crossNetworkFrameSubscriptionSessionId: String?
    private var activePresentationOwnerTokens: Set<UUID> = []
    
    private init() {
        viewerSettings = Self.loadViewerSettings()
        crossNetwork.nativeAudioReceiveEnabled = Self.crossNetworkNativeAudioReceiveEnabled
    }

    private static var remoteDesktopBuildFingerprint: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "-"
        let build = (info["CFBundleVersion"] as? String) ?? "-"
        let bundleId = Bundle.main.bundleIdentifier ?? "-"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return "bundle=\(bundleId) version=\(version) build=\(build) os=\(osVersion)"
    }

    private func invalidateDecodePipelineState() {
        decodeGeneration &+= 1
        inFlightDecodeCount = 0
        lastDecodedFrameTime = nil
        lastAcceptedDecodedPresentationTimeStamp = nil
    }

    private func resetFrameTelemetry() {
        frameCount = 0
        lastFrameTime = nil
        lastRenderedFrameTime = nil
        frameRate = 0
        lastFrameArrivalAt = nil
        lastDecodedFrameTime = nil
        lastVideoRendererEnqueueAt = nil
        lastDisplayedFrameTime = nil
        lastAcceptedDecodedPresentationTimeStamp = nil
        receivedFrameCountInCurrentStream = 0
        statsWindowStartTime = nil
        receivedFramesInStatsWindow = 0
        decodedFramesInStatsWindow = 0
        rendererEnqueuedFramesInStatsWindow = 0
        displayedFramesInStatsWindow = 0
        consecutiveSampleBufferNoEnqueueWindows = 0
        consecutiveSampleBufferDisplayStalls = 0
        lastInboundScreenTimestamp = nil
        lastCrossNetworkNativeReadyAnnouncementAt = nil
        lastNativePrimaryIgnoredFallbackDiagnosticAt = .distantPast
        lastNativeWarmupNonJPEGFallbackDropDiagnosticAt = .distantPast
        lastMetalFallbackAt = nil
        metalFallbackReason = nil
        stableSampleBufferFramesSinceMetalFallback = 0
        decodedVideoRendererPreference = preferredDecodedVideoRenderer()
        metalAwaitingFirstDisplaySince = nil
        invalidateDecodePipelineState()
    }

    private func updateLastGoodFrozenFrame(_ image: CGImage?) {
        guard let image else { return }
        lastGoodFrozenFrame = image
    }

    private var maxLANWireMessageBytes: Int {
        maxMessageBytes + maxEncryptedLANMessageOverheadBytes
    }
    
    // MARK: - Public Methods
    
    /// 连接到远程桌面
    /// - Parameter device: 目标设备
    public func connect(to device: DiscoveredDevice) async throws {
        let resolvedDevice = shouldUseCrossNetworkTransport(for: device)
            ? device
            : resolveLatestRemoteDesktopDevice(from: device)
        if !shouldUseCrossNetworkTransport(for: resolvedDevice),
           !(await canResolveLANRemoteDesktopEndpoint(for: resolvedDevice)) {
            state = .error("设备未发现可用远程桌面端点")
            throw RemoteDesktopError.notSupported("设备未发现可用远程桌面端点")
        }
        if resolvedDevice.id != device.id {
            SkyBridgeLogger.shared.info("ℹ️ 远程桌面连接设备已解析: \(device.id) -> \(resolvedDevice.id)")
        }
        SkyBridgeLogger.shared.info("📺 连接到远程桌面: \(resolvedDevice.name)")
        
        state = .connecting
        
        do {
            // 仅当目标设备就是跨网会话对端时才走 DataChannel。
            // 避免“跨网已连接”误伤局域网远控（会导致画面/输入走错通道）。
            if shouldUseCrossNetworkTransport(for: resolvedDevice) {
                await clearLANSecureChannelState()
                networkConnection?.cancel()
                networkConnection = nil
                activeTransportMode = .crossNetwork
                isUsingCrossNetworkTransport = true
                decodedVideoRendererPreference = preferredDecodedVideoRenderer()
                transportStatusText = currentTransportStatusText()
                currentConnection = Connection(device: resolvedDevice, status: .connected)
                state = .connected
                hasReceivedFrameInCurrentStream = false
                resetStreamConfigurationAckState()
                lastLatencyPublishAt = .distantPast
                beginRemoteAudioPlaybackSession()
                isStreaming = true
                state = .streaming
                crossNetwork.startRemoteDesktopHeartbeat()
                configureSessionClipboardSync()

                if let sessionId = crossNetwork.activeRemoteDesktopSessionId {
                    subscribeToCrossNetworkFrames(sessionId: sessionId)
                } else {
                    cancelCrossNetworkFrameSubscription()
                }
                
                SkyBridgeLogger.shared.info("✅ 远程桌面已切换到 WebRTC 传输（控制走 DataChannel，视频优先原生轨）")
                lastRequestedStreamRefreshReason = "cross-network-startup"
                await pushViewerStreamConfiguration(force: true, refreshStream: true)
                return
            }

            crossNetwork.stopRemoteDesktopHeartbeat()
            cancelCrossNetworkFrameSubscription()
            // Tear down any prior LAN socket before we install a new one.
            // Otherwise stale callbacks from the previous NWConnection can
            // race in later and incorrectly tear down the fresh session.
            networkConnection?.stateUpdateHandler = nil
            networkConnection?.cancel()
            networkConnection = nil
            await clearLANSecureChannelState()
            try await ensureLANRemoteControlTrustBootstrap(for: resolvedDevice)
            let refreshedLANDevice = resolveLatestRemoteDesktopDevice(from: resolvedDevice)
            if refreshedLANDevice.id != resolvedDevice.id
                || refreshedLANDevice.ipAddress != resolvedDevice.ipAddress
                || refreshedLANDevice.remoteControlPort != resolvedDevice.remoteControlPort {
                SkyBridgeLogger.shared.info(
                    "ℹ️ LAN 远控 bootstrap 后重新解析目标: \(resolvedDevice.id) -> \(refreshedLANDevice.id)"
                )
            }
            // 建立连接：优先 Bonjour service（不依赖 IP/默认端口），失败时回退到等价 IP/会话地址。
            let endpoints = try await makeRemoteDesktopEndpointCandidates(for: refreshedLANDevice)

            let connection = try await createConnection(toAnyOf: endpoints)
            networkConnection = connection
            connection.stateUpdateHandler = { [weak self] connectionState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.isCurrentLANConnection(connection) else {
                        SkyBridgeLogger.shared.debug("ℹ️ 忽略过期 LAN 连接状态回调: \(String(describing: connectionState))")
                        return
                    }
                    switch connectionState {
                    case .failed(let error):
                        await self.handleTransportFailure(error.localizedDescription)
                    case .cancelled:
                        await self.handleTransportFailure(
                            RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                        )
                    default:
                        break
                    }
                }
            }
            activeTransportMode = .lan
            isUsingCrossNetworkTransport = false
            decodedVideoRendererPreference = preferredDecodedVideoRenderer()
            transportStatusText = currentTransportStatusText()

            // 创建 Connection 对象
            currentConnection = Connection(device: refreshedLANDevice, status: .connected)
            state = .connected
            
            // 开始接收数据
            startReceiving()
            try ensureLANBootstrapStillActive(for: connection)

            try await establishLANSecureChannel(for: refreshedLANDevice, over: connection)
            try ensureLANBootstrapStillActive(for: connection)

            // 在进入 streaming 前先主动发送一次 viewer 能力，避免 Mac 端首个会话默认退回到 JPEG。
            await pushViewerStreamConfiguration(force: true)
            try ensureLANBootstrapStillActive(for: connection)

            // 直接进入 streaming（macOS 端无需 connect/heartbeat 握手）
            try await startStreaming()
            try ensureLANBootstrapStillActive(for: connection)
            
            SkyBridgeLogger.shared.info("✅ 远程桌面连接成功")
            
        } catch {
            networkConnection?.stateUpdateHandler = nil
            networkConnection?.cancel()
            networkConnection = nil
            await clearLANSecureChannelState()
            currentConnection = nil
            activeTransportMode = .none
            isUsingCrossNetworkTransport = false
            transportStatusText = currentTransportStatusText()
            state = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// 开始流媒体
    public func startStreaming() async throws {
        if state == .streaming {
            await pushViewerStreamConfiguration(force: true)
            guard activeTransportMode != .lan || networkConnection != nil else {
                throw RemoteDesktopError.disconnected
            }
            return
        }
        guard state == .connected else {
            throw RemoteDesktopError.connectionFailed("未连接")
        }
        
        SkyBridgeLogger.shared.info("📺 开始远程桌面流")
        SkyBridgeLogger.shared.info("🧾 远控 viewer build fingerprint: \(Self.remoteDesktopBuildFingerprint)")
        
        isStreaming = true
        beginRemoteAudioPlaybackSession()
        crossNetwork.disarmIdleConnectionReminder(clearPrompt: true)
        state = .streaming
        streamEpoch &+= 1
        lastHandledSessionAuthorityLostStreamEpoch = nil
        consecutiveDecodeMisses = 0
        hasReceivedFrameInCurrentStream = false
        resetStreamConfigurationAckState()
        lastLatencyPublishAt = .distantPast
        configureSessionClipboardSync()
        lastDecoderResetTime = nil
        lastIncomingStreamSignature = nil
        resetRefreshDiagnostics()
        codecGovernance = .init()
        resetFrameTelemetry()
        lastViewerInteractionAt = nil
        lastContinuityRecoveryAt = nil
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = false
        currentFrame = nil
        lastGoodFrozenFrame = nil
        flushRenderedVideoFeeds()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
        firstFrameWatchdogTask?.cancel()
        firstFrameContinuityTask?.cancel()
        interactionContinuityTask?.cancel()
        streamContinuityWatchdogTask?.cancel()
        startStreamContinuityWatchdog(for: streamEpoch)
        if activeTransportMode == .crossNetwork {
            if let sessionId = crossNetwork.activeRemoteDesktopSessionId {
                subscribeToCrossNetworkFrames(sessionId: sessionId)
            } else {
                cancelCrossNetworkFrameSubscription()
            }
            lastRequestedStreamRefreshReason = "cross-network-startup"
        }
        await pushViewerStreamConfiguration(
            force: true,
            refreshStream: activeTransportMode == .crossNetwork
        )
        scheduleFirstFrameWatchdog(for: streamEpoch)
        guard activeTransportMode != .lan || networkConnection != nil else {
            firstFrameWatchdogTask?.cancel()
            firstFrameWatchdogTask = nil
            isStreaming = false
            throw RemoteDesktopError.disconnected
        }
    }

    private func scheduleFirstFrameWatchdog(for epoch: UInt64) {
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard self.streamEpoch == epoch,
                  self.state == .streaming,
                  !self.hasReceivedFrameInCurrentStream else { return }
            guard !self.handleCrossNetworkSessionAuthorityLostIfNeeded(source: "first-frame-watchdog") else {
                return
            }
            await self.requestStreamRefreshIfNeeded(reason: "first-frame-timeout", minimumInterval: 0)
            SkyBridgeLogger.shared.warning("⚠️ 远程桌面已发送流配置但 5 秒内未收到屏幕帧，已主动请求流刷新；若仍无画面，请检查 Mac 端录屏权限与采集状态")
        }
    }

    /// 便捷入口：从 Connection 启动远程桌面（UI 侧直接调用）
    public func startStreaming(from connection: Connection) async throws {
        if ProcessInfo.processInfo.arguments.contains("UITEST_SCENARIO_REMOTE") {
            currentConnection = connection
            activeTransportMode = .none
            isUsingCrossNetworkTransport = false
            hasReceivedFrameInCurrentStream = false
            isStreaming = true
            state = .streaming
            transportStatusText = "UITest Fixture"
            frameRate = 30
            latency = 12
            resolution = CGSize(width: 1440, height: 900)
            renderPipelineStatus = .stillImageFallback
            lastDamageRectCount = 0
            lastDamageUsesFullFrameFallback = false
            currentFrame = nil
            lastGoodFrozenFrame = nil
            flushRenderedVideoFeeds()
            configureSessionClipboardSync()
            return
        }

        if currentConnection?.device.id == connection.device.id, state == .streaming {
            await pushViewerStreamConfiguration(force: true)
            return
        }
        let matchesCurrentConnection = currentConnection.map { existing in
            areEquivalentRemoteDesktopDevices(existing.device, connection.device)
        } ?? false

        if matchesCurrentConnection {
            switch state {
            case .streaming:
                await pushViewerStreamConfiguration(force: true)
                return
            case .connecting:
                SkyBridgeLogger.shared.info(
                    "ℹ️ 远程桌面连接进行中，复用现有建连: \(currentConnection?.device.id ?? connection.device.id)"
                )
                return
            case .connected:
                try await startStreaming()
                return
            case .disconnected, .error:
                break
            }
        }

        // 若当前不是该设备的连接，或现有会话已失效，则建立新连接。
        switch state {
        case .disconnected, .error:
            try await connect(to: connection.device)
            return
        case .connecting, .connected, .streaming:
            break
        }

        if currentConnection == nil || matchesCurrentConnection == false {
            try await connect(to: connection.device)
            return
        }

        try await startStreaming()
    }
    
    /// 停止流媒体
    public func stopStreaming() async {
        SkyBridgeLogger.shared.info("⏹️ 停止远程桌面流")
        
        await sendViewerStreamStopConfigurationIfNeeded()
        isStreaming = false
        crossNetwork.stopRemoteDesktopHeartbeat()
        cancelCrossNetworkFrameSubscription()
        teardownRemoteAudioPlayback()
        realtimeMediaAudioReceiverStartTask?.cancel()
        realtimeMediaAudioReceiverStartTask = nil
        stopRealtimeMediaAudioReceiver()
        resetStreamConfigurationAckState()
        configureSessionClipboardSync()
        lastSentStreamConfiguration = nil
        lastIncomingStreamSignature = nil
        resetRefreshDiagnostics()
        codecGovernance = .init()
        currentFrame = nil
        lastGoodFrozenFrame = nil
        flushRenderedVideoFeeds()
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = false
        resetFrameTelemetry()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
        firstFrameWatchdogTask?.cancel()
        firstFrameContinuityTask?.cancel()
        interactionContinuityTask?.cancel()
        streamContinuityWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        firstFrameContinuityTask = nil
        interactionContinuityTask = nil
        streamContinuityWatchdogTask = nil
        if state == .streaming {
            state = .connected
        }
    }
    
    /// 断开远程桌面流。
    /// - Parameter tearDownTransport: 为 `true` 时连带关闭底层跨网会话；默认仅停止视频/控制流，保留连接。
    public func disconnect(tearDownTransport: Bool = false) async {
        SkyBridgeLogger.shared.info(
            tearDownTransport ? "🔌 断开远程桌面连接" : "⏹️ 停止远程桌面流（保留连接）"
        )
        let wasCrossNetworkTransport = activeTransportMode == .crossNetwork
        let shouldDisconnectCrossNetworkSession = tearDownTransport && activeTransportMode == .crossNetwork
        await sendViewerStreamStopConfigurationIfNeeded()
        crossNetwork.stopRemoteDesktopHeartbeat()
        cancelCrossNetworkFrameSubscription()
        firstFrameWatchdogTask?.cancel()
        firstFrameContinuityTask?.cancel()
        interactionContinuityTask?.cancel()
        streamContinuityWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        firstFrameContinuityTask = nil
        interactionContinuityTask = nil
        streamContinuityWatchdogTask = nil
        lastSentStreamConfiguration = nil
        lastIncomingStreamSignature = nil
        resetRefreshDiagnostics()
        codecGovernance = .init()
        isStreaming = false
        teardownRemoteAudioPlayback()
        realtimeMediaAudioReceiverStartTask?.cancel()
        realtimeMediaAudioReceiverStartTask = nil
        stopRealtimeMediaAudioReceiver()
        resetStreamConfigurationAckState()
        configureSessionClipboardSync()

        if !tearDownTransport {
            await decoder.cleanup()

            currentFrame = nil
            lastGoodFrozenFrame = nil
            flushRenderedVideoFeeds()
            renderPipelineStatus = .waiting
            lastDamageRectCount = 0
            lastDamageUsesFullFrameFallback = false
            currentCursorPayload = nil
            currentOverlayPayload = nil
#if canImport(UIKit)
            currentCursorImage = nil
#endif
            latency = 0
            resolution = .zero
            pendingFrames.removeAll()
            decodeQueueWaitingForSyncFrame = false
            resetFrameTelemetry()
            lastViewerInteractionAt = nil
            lastContinuityRecoveryAt = nil
            transportStatusText = currentTransportStatusText()

            let hasPreservedTransport = currentConnection != nil && activeTransportMode != .none
            state = hasPreservedTransport ? .connected : .disconnected

            if wasCrossNetworkTransport && hasPreservedTransport {
                crossNetwork.armIdleConnectionReminderIfNeeded()
            }
            return
        }

        // 关闭连接
        networkConnection?.stateUpdateHandler = nil
        networkConnection?.cancel()
        networkConnection = nil
        await clearLANSecureChannelState()
        activeTransportMode = .none
        isUsingCrossNetworkTransport = false
        transportStatusText = currentTransportStatusText()

        if shouldDisconnectCrossNetworkSession {
            await crossNetwork.disconnect(clearSnapshot: true)
        }
        
        // 清理解码器
        await decoder.cleanup()
        
        // 重置状态
        currentConnection = nil
        currentFrame = nil
        lastGoodFrozenFrame = nil
        flushRenderedVideoFeeds()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
        state = .disconnected
        latency = 0
        resolution = .zero
        pendingFrames.removeAll()
        decodeQueueWaitingForSyncFrame = false
        resetFrameTelemetry()
        lastViewerInteractionAt = nil
        lastContinuityRecoveryAt = nil

        if wasCrossNetworkTransport && !shouldDisconnectCrossNetworkSession {
            crossNetwork.armIdleConnectionReminderIfNeeded()
        }
    }

    public func registerPresentationOwner(_ token: UUID) {
        activePresentationOwnerTokens.insert(token)
    }

    @discardableResult
    public func unregisterPresentationOwner(_ token: UUID) -> Bool {
        activePresentationOwnerTokens.remove(token)
        return activePresentationOwnerTokens.isEmpty
    }

    nonisolated static func shouldProcessCrossNetworkFrameNotification(
        isStreaming: Bool,
        subscribedSessionId: String?,
        expectedSessionId: String,
        updateSessionId: String
    ) -> Bool {
        guard isStreaming else { return false }
        guard subscribedSessionId == expectedSessionId else { return false }
        return updateSessionId == expectedSessionId
    }

    private func subscribeToCrossNetworkFrames(sessionId: String) {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else {
            cancelCrossNetworkFrameSubscription()
            return
        }

        if crossNetworkFrameSubscriptionSessionId == normalizedSessionId,
           crossNetworkFrameSubscriptionTask != nil {
            return
        }

        cancelCrossNetworkFrameSubscription()
        crossNetworkFrameSubscriptionSessionId = normalizedSessionId
        crossNetworkFrameSubscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await notification in NotificationCenter.default.notifications(named: .crossNetworkScreenDataUpdated) {
                guard !Task.isCancelled else { return }
                guard let updateSessionId = notification.userInfo?[CrossNetworkNotificationUserInfoKey.sessionId] as? String,
                      let screenData = notification.userInfo?[CrossNetworkNotificationUserInfoKey.screenData] as? ScreenData else {
                    continue
                }
                guard Self.shouldProcessCrossNetworkFrameNotification(
                    isStreaming: self.isStreaming,
                    subscribedSessionId: self.crossNetworkFrameSubscriptionSessionId,
                    expectedSessionId: normalizedSessionId,
                    updateSessionId: updateSessionId
                ) else {
                    continue
                }
                await self.handleScreenData(screenData)
            }
        }
    }

    private func cancelCrossNetworkFrameSubscription() {
        crossNetworkFrameSubscriptionTask?.cancel()
        crossNetworkFrameSubscriptionTask = nil
        crossNetworkFrameSubscriptionSessionId = nil
    }

    private func currentTransportStatusText() -> String? {
        switch activeTransportMode {
        case .none:
            return nil
        case .lan:
            if let lanSessionKeys {
                return "P2P / LAN · \(lanSessionKeys.negotiatedSuite.rawValue)"
            }
            return "P2P / LAN"
        case .crossNetwork:
            if case .handshakeComplete(_, let negotiatedSuite) = crossNetwork.readiness {
                return "WebRTC · \(negotiatedSuite)"
            }
            return "WebRTC"
        }
    }

    @MainActor
    func updateCrossNetworkNativeVideoResolution(_ size: CGSize) {
        guard activeTransportMode == .crossNetwork else { return }
        guard isStreaming else { return }
        guard size.width > 0, size.height > 0 else { return }
        let visibleSize = normalizedCrossNetworkNativeVideoVisibleFrameSize(forCodedSize: size)
        resolution = visibleSize
        crossNetwork.noteRemoteVideoTrackResolutionAvailable(
            visibleSize,
            source: "remote-desktop-resolution"
        )
    }

    @MainActor
    private func normalizedCrossNetworkNativeVideoVisibleFrameSize(forCodedSize codedSize: CGSize) -> CGSize {
        guard let expectedVisibleSize = expectedCrossNetworkNativeVideoVisibleFrameSize() else {
            return codedSize
        }
        let expectedWidth = Int(expectedVisibleSize.width)
        let expectedHeight = Int(expectedVisibleSize.height)
        let codedWidth = Int(codedSize.width)
        let codedHeight = Int(codedSize.height)
        let expectedCodedWidth = Self.evenNativeVideoBackingDimension(expectedWidth)
        let expectedCodedHeight = Self.evenNativeVideoBackingDimension(expectedHeight)
        if codedWidth == expectedCodedWidth, codedHeight == expectedCodedHeight {
            return expectedVisibleSize
        }
        if codedWidth == expectedWidth, codedHeight == expectedHeight {
            return expectedVisibleSize
        }
        return codedSize
    }

    private static func evenNativeVideoBackingDimension(_ visibleDimension: Int) -> Int {
        let sanitized = max(1, visibleDimension)
        return sanitized.isMultiple(of: 2) ? sanitized : sanitized + 1
    }

    @MainActor
    func expectedCrossNetworkNativeVideoVisibleFrameSize() -> CGSize? {
        guard activeTransportMode == .crossNetwork else { return nil }
        guard let payload = lastSentStreamConfiguration,
              payload.adaptiveResolutionEnabled != true,
              let width = payload.width,
              let height = payload.height,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    @MainActor
    func noteCrossNetworkNativeVideoFrame(_ size: CGSize) {
        guard activeTransportMode == .crossNetwork else { return }
        guard isStreaming else { return }
        let now = Date()
        if size.width > 0, size.height > 0 {
            resolution = size
        }
        hasReceivedFrameInCurrentStream = true
        noteReceivedFrame(at: now)
        noteDecodedFrame(at: now)
        noteDisplayedFrame(at: now)
        updateRenderPipeline(.webrtcNativeVideo)
        announceCrossNetworkNativeVideoReadyIfNeeded(force: false, now: now)
    }

    static func shouldAnnounceCrossNetworkNativeVideoReady(
        activeTransportModeIsCrossNetwork: Bool,
        hasCurrentConnection: Bool,
        hasRenderedNativeFrame: Bool,
        lastSentNativeVideoTrackReady: Bool,
        force: Bool,
        lastAnnouncementAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = 0.5
    ) -> Bool {
        guard activeTransportModeIsCrossNetwork, hasCurrentConnection, hasRenderedNativeFrame else {
            return false
        }
        if !force && lastSentNativeVideoTrackReady {
            return false
        }
        if !force,
           let lastAnnouncementAt,
           now.timeIntervalSince(lastAnnouncementAt) < minimumInterval {
            return false
        }
        return true
    }

    static func advertisedCrossNetworkNativeVideoReadyFlag(
        activeTransportModeIsCrossNetwork: Bool,
        hasRenderedNativeFrame: Bool
    ) -> Bool? {
        guard activeTransportModeIsCrossNetwork else { return nil }
        return hasRenderedNativeFrame
    }

    @MainActor
    private func announceCrossNetworkNativeVideoReadyIfNeeded(force: Bool, now: Date = Date()) {
        guard isStreaming else { return }
        let hasRenderedNativeFrame = crossNetwork.remoteVideoTrackHasRenderedFrame
        let shouldAnnounce = Self.shouldAnnounceCrossNetworkNativeVideoReady(
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            hasCurrentConnection: currentConnection != nil,
            hasRenderedNativeFrame: hasRenderedNativeFrame,
            lastSentNativeVideoTrackReady: lastSentStreamConfiguration?.nativeVideoTrackReady == true,
            force: force,
            lastAnnouncementAt: lastCrossNetworkNativeReadyAnnouncementAt,
            now: now
        )
        guard shouldAnnounce else { return }
        lastCrossNetworkNativeReadyAnnouncementAt = now
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pushViewerStreamConfiguration(force: true)
        }
    }

    func canPresentRemoteDesktopOption(for device: DiscoveredDevice) -> Bool {
        if isCrossNetworkDevice(device) {
            return true
        }

        let resolved = resolveLatestRemoteDesktopDevice(from: device)
        if hasPeerAddressBackedRemoteDesktopFallback(for: resolved)
            || hasPeerAddressBackedRemoteDesktopFallback(for: device) {
            return true
        }

        if resolved.platform == .macOS,
           resolved.isConnected,
           resolved.isTrusted {
            return true
        }

        if hasReachableLANRemoteDesktopEndpoint(resolved)
            || resolved.supportsRemoteControl
            || preferredRemoteDesktopServiceName(for: resolved) != nil {
            return true
        }

        return false
    }

    private func isCurrentLANConnection(_ connection: NWConnection) -> Bool {
        guard let current = networkConnection else { return false }
        return current === connection
    }

    public static func shouldContinueLANBootstrap(
        activeTransportModeIsLAN: Bool,
        isCurrentLANConnection: Bool,
        state: RemoteDesktopState
    ) -> Bool {
        guard activeTransportModeIsLAN, isCurrentLANConnection else { return false }
        if case .error = state {
            return false
        }
        return true
    }

    private func ensureLANBootstrapStillActive(for connection: NWConnection) throws {
        guard Self.shouldContinueLANBootstrap(
            activeTransportModeIsLAN: activeTransportMode == .lan,
            isCurrentLANConnection: isCurrentLANConnection(connection),
            state: state
        ) else {
            throw RemoteDesktopError.disconnected
        }
    }

    private func handleTransportFailure(_ reason: String) async {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorMessage = normalizedReason.isEmpty
            ? (RemoteDesktopError.disconnected.errorDescription ?? "连接已断开")
            : normalizedReason
        let failedTransport = transportStatusText ?? currentTransportStatusText() ?? "unknown"
        let failedConnection = currentConnection?.device.id ?? "-"
        let shouldDisconnectCrossNetworkSession = activeTransportMode == .crossNetwork

        SkyBridgeLogger.shared.error(
            "❌ 远程桌面传输失败: device=\(failedConnection) transport=\(failedTransport) reason=\(errorMessage)"
        )

        crossNetwork.stopRemoteDesktopHeartbeat()
        firstFrameWatchdogTask?.cancel()
        firstFrameContinuityTask?.cancel()
        interactionContinuityTask?.cancel()
        streamContinuityWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        firstFrameContinuityTask = nil
        interactionContinuityTask = nil
        streamContinuityWatchdogTask = nil
        networkConnection?.stateUpdateHandler = nil
        networkConnection?.cancel()
        networkConnection = nil
        await clearLANSecureChannelState()
        activeTransportMode = .none
        isUsingCrossNetworkTransport = false
        transportStatusText = currentTransportStatusText()
        lastSentStreamConfiguration = nil
        lastIncomingStreamSignature = nil
        resetRefreshDiagnostics()
        codecGovernance = .init()
        isStreaming = false
        teardownRemoteAudioPlayback()
        configureSessionClipboardSync()
        if shouldDisconnectCrossNetworkSession {
            await crossNetwork.disconnect(clearSnapshot: true)
        }
        await decoder.cleanup()
        currentFrame = nil
        lastGoodFrozenFrame = nil
        flushRenderedVideoFeeds()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
        currentConnection = nil
        frameCount = 0
        lastFrameTime = nil
        lastRenderedFrameTime = nil
        consecutiveDecodeMisses = 0
        lastDecoderResetTime = nil
        hasReceivedFrameInCurrentStream = false
        lastViewerInteractionAt = nil
        lastContinuityRecoveryAt = nil
        latency = 0
        resolution = .zero
        pendingFrames.removeAll()
        decodeQueueWaitingForSyncFrame = false
        resetFrameTelemetry()
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

    func handleInboundRemoteAudioChunk(_ payload: RemoteDesktopAudioChunkPayload) {
        guard viewerSettings.audioRedirectionEnabled, isStreaming else { return }
        guard acceptsLegacyRemoteAudioChunks else {
            SkyBridgeLogger.shared.debug("ℹ️ 已丢弃 legacy 远控音频块：当前会话要求 PQC media plane")
            return
        }
        let context = RemoteAudioPlaybackContext(
            generation: remoteAudioPlaybackGeneration,
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            nativeAudioReceiveEnabled: Self.crossNetworkNativeAudioReceiveEnabled,
            remoteAudioTrackHasReceivedFirstPacket: crossNetwork.remoteAudioTrackHasReceivedFirstPacket,
            lastInboundScreenTimestamp: lastInboundScreenTimestamp
        )
        Task.detached(priority: .utility) { [remoteAudioPlayback] in
            await remoteAudioPlayback.handle(payload, context: context)
        }
    }

    var acceptsLegacyRemoteAudioChunks: Bool {
        guard lastSentStreamConfiguration?.audioRedirectionEnabled == true else { return false }
        let transport = lastSentStreamConfiguration?.audioTransport?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return lastSentStreamConfiguration?.compatibilityAudioFallbackEnabled == true
            || transport == "legacy-chunk-v1"
    }

    private var strictCrossNetworkMediaValidationActive: Bool {
        guard activeTransportMode == .crossNetwork else { return false }
        let mode = lastSentStreamConfiguration?.performanceValidationMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fallbackPolicy = lastSentStreamConfiguration?.mediaFallbackPolicy?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mode == "extreme"
            || mode == "strict"
            || fallbackPolicy == "fail-fast"
            || fallbackPolicy == "disabled"
            || fallbackPolicy == "forbidden"
    }

    private func beginRemoteAudioPlaybackSession() {
        remoteAudioPlaybackGeneration &+= 1
    }

    private func teardownRemoteAudioPlayback(
        deactivateSession: Bool = true,
        resetFailureState: Bool = true
    ) {
        let generation = remoteAudioPlaybackGeneration
        remoteAudioPlaybackGeneration &+= 1
        Task.detached(priority: .utility) { [remoteAudioPlayback] in
            await remoteAudioPlayback.invalidate(
                upTo: generation,
                deactivateSession: deactivateSession,
                resetFailureState: resetFailureState
            )
        }
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

    func handleCrossNetworkNativeVideoTrackRenderedFirstFrame() {
        announceCrossNetworkNativeVideoReadyIfNeeded(force: true)
    }

    @MainActor
    func handleCrossNetworkNativeVideoWarmupEvidence(reason: String) {
        guard activeTransportMode == .crossNetwork,
              isStreaming,
              currentConnection != nil,
              !crossNetwork.remoteVideoTrackHasRenderedFrame else {
            return
        }
        let now = Date()
        let canRequest = lastRefreshRequestAt.map { now.timeIntervalSince($0) >= 0.5 } ?? true
        guard canRequest else { return }
        lastRefreshRequestAt = now
        lastRequestedStreamRefreshReason = reason
        Task { @MainActor [weak self] in
            await self?.pushViewerStreamConfiguration(force: true, refreshStream: true)
        }
    }

    func handleCrossNetworkNativeVideoTrackPromotionReady() {
        SkyBridgeLogger.shared.debug("ℹ️ WebRTC 原生视频轨 promotion-ready 仅作诊断，nativeReady 等待真实渲染帧")
    }

    func handleCrossNetworkNativeAudioTrackReceivedFirstPacket() {
        teardownRemoteAudioPlayback(deactivateSession: false)
    }

    private func configureSessionClipboardSync() {
        let clipboard = ClipboardManager.shared
        let shouldEnable = viewerSettings.clipboardSyncEnabled
            && isStreaming
            && hasReceivedFrameInCurrentStream

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

    private func prepareRealtimeMediaAudioReceiverIfNeeded(
        mode: SkyBridgeMediaAudioMode,
        startGeneration: UInt64? = nil,
        startTime: Date = Date()
    ) async -> (endpoint: SkyBridgeMediaEndpoint, mediaSessionId: String)? {
        guard viewerSettings.audioRedirectionEnabled, isStreaming else {
            stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
            return nil
        }
        guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }

        let snapshot: RemoteRealtimeMediaKeySnapshot?
        switch activeTransportMode {
        case .lan:
            snapshot = lanRealtimeMediaKeySnapshot()
        case .crossNetwork:
            snapshot = crossNetwork.realtimeMediaKeySnapshot()
        case .none:
            snapshot = nil
        }
        guard let snapshot else {
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio receiver skipped: transport=\(activeTransportModeLabel()) reason=missingMediaKeys"
            )
            stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
            return nil
        }

        if (realtimeMediaAudioReceiver != nil || realtimeMediaAudioRelayTransport != nil),
           realtimeMediaAudioRenderer != nil,
           realtimeMediaAudioReceiverSessionId == snapshot.sessionId,
           let endpoint = realtimeMediaAudioEndpoint,
           Self.isUsableRealtimeMediaAudioEndpoint(endpoint) {
            return (endpoint, snapshot.sessionId)
        }
        guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }

        do {
            let renderer: IOSRealtimeMediaAudioReceiver
            let endpoint: SkyBridgeMediaEndpoint
            switch activeTransportMode {
            case .crossNetwork:
                updateRealtimeMediaAudioReceiverStartPhase(.lease, generation: startGeneration)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media relay lease request: session=\(snapshot.sessionId) mode=\(mode.rawValue) transport=\(activeTransportModeLabel())"
                )
                let leaseTimeoutTask = scheduleRealtimeMediaAudioReceiverStageTimeout(
                    phase: .lease,
                    mode: mode,
                    generation: startGeneration,
                    startTime: startTime
                )
                let relayEndpointPair: CrossNetworkWebRTCManager.RealtimeMediaRelayEndpointPair?
                do {
                    relayEndpointPair = try await crossNetwork.requestRealtimeMediaRelayEndpointForActiveSession()
                } catch {
                    leaseTimeoutTask?.cancel()
                    throw error
                }
                leaseTimeoutTask?.cancel()
                guard let relayEndpointPair else {
                    let reason = crossNetwork.mediaRelayLeaseDiagnosticForActiveSession() ?? "unknown"
                    SkyBridgeLogger.shared.info("🎧 PQC media relay lease unavailable; keeping WebRTC video-only reason=\(reason)")
                    return nil
                }
                let relayEndpoint = relayEndpointPair.localEndpoint
                guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio receiver lease ready: event=leaseReady session=\(snapshot.sessionId) role=\(relayEndpointPair.localRole) relay=\(relayEndpoint.host):\(relayEndpoint.port) token=\(relayEndpoint.relayToken == nil ? "missing" : "present") transport=\(activeTransportModeLabel())"
                )
                stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
                renderer = try IOSRealtimeMediaAudioReceiver(snapshot: snapshot, mode: mode)
                realtimeMediaAudioRenderer = renderer
                realtimeMediaAudioReceiverSessionId = snapshot.sessionId
                realtimeMediaAudioEndpoint = relayEndpoint
                let strictRelayBindRequired = Self.shouldRequestExtremeMediaValidation(
                    activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
                    viewerSettings: viewerSettings
                )
                let relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy =
                    strictRelayBindRequired ? .requireAcknowledgement : .optimisticAfterSend
                let relayTransport = SkyBridgeUDPRealtimeMediaTransport(
                    endpoint: relayEndpoint,
                    receiveHandler: { [renderer] datagram in
                        Task.detached(priority: .utility) {
                            await renderer.handle(datagram: datagram)
                        }
                    },
                    relayBindPolicy: relayBindPolicy,
                    startEventHandler: { [weak self] event in
                        Task { @MainActor [weak self] in
                            self?.handleRealtimeMediaAudioRelayTransportEvent(
                                event,
                                sessionId: snapshot.sessionId,
                                endpoint: relayEndpoint,
                                generation: startGeneration
                            )
                        }
                    }
                )
                updateRealtimeMediaAudioReceiverStartPhase(.udpConnection, generation: startGeneration)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio receiver UDP connection started: event=udpConnectionStarted session=\(snapshot.sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) transport=\(activeTransportModeLabel())"
                )
                let udpBindTimeoutTask = scheduleRealtimeMediaAudioReceiverStageTimeout(
                    phase: .udpConnection,
                    mode: mode,
                    generation: startGeneration,
                    startTime: startTime
                )
                do {
                    try await relayTransport.start()
                } catch {
                    udpBindTimeoutTask?.cancel()
                    throw error
                }
                udpBindTimeoutTask?.cancel()
                updateRealtimeMediaAudioReceiverStartPhase(.receiverReady, generation: startGeneration)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio receiver UDP path ready: event=udpPathReady session=\(snapshot.sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) transport=\(activeTransportModeLabel())"
                )
                guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else {
                    await relayTransport.stop()
                    await renderer.close()
                    return nil
                }
                realtimeMediaAudioRelayTransport = relayTransport
                endpoint = relayEndpoint
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio endpoint published after relay bind policy satisfied: event=audioEndpointPrepared session=\(snapshot.sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) token=\(relayEndpoint.relayToken == nil ? "missing" : "present") transport=\(activeTransportModeLabel())"
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx endpointPrepared session=\(snapshot.sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointPrepared",
                        "session": snapshot.sessionId,
                        "session_id": snapshot.sessionId,
                        "relay": "\(relayEndpoint.host):\(relayEndpoint.port)",
                        "role": relayEndpointPair.localRole,
                        "relayTokenPresent": relayEndpoint.relayToken != nil
                    ]
                )
                await pushViewerStreamConfiguration(force: false, refreshStream: false)
            case .lan:
                updateRealtimeMediaAudioReceiverStartPhase(.lease, generation: startGeneration)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio receiver lease ready: event=leaseReady session=\(snapshot.sessionId) transport=\(activeTransportModeLabel()) source=lan-session-keys"
                )
                guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }
                stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
                renderer = try IOSRealtimeMediaAudioReceiver(snapshot: snapshot, mode: mode)
                let receiver = SkyBridgeUDPRealtimeMediaReceiver()
                updateRealtimeMediaAudioReceiverStartPhase(.udpConnection, generation: startGeneration)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio receiver UDP bind started: event=udpBindStarted session=\(snapshot.sessionId) transport=\(activeTransportModeLabel())"
                )
                let udpBindTimeoutTask = scheduleRealtimeMediaAudioReceiverStageTimeout(
                    phase: .udpConnection,
                    mode: mode,
                    generation: startGeneration,
                    startTime: startTime
                )
                do {
                    endpoint = try await receiver.start { [renderer] datagram in
                        Task.detached(priority: .utility) {
                            await renderer.handle(datagram: datagram)
                        }
                    }
                } catch {
                    udpBindTimeoutTask?.cancel()
                    throw error
                }
                udpBindTimeoutTask?.cancel()
                guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else {
                    receiver.stop()
                    await renderer.close()
                    return nil
                }
                realtimeMediaAudioReceiver = receiver
            case .none:
                return nil
            }
            guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }
            realtimeMediaAudioRenderer = renderer
            realtimeMediaAudioReceiverSessionId = snapshot.sessionId
            realtimeMediaAudioEndpoint = endpoint
            scheduleRealtimeMediaAudioEndpointRenewal(
                sessionId: snapshot.sessionId,
                endpoint: endpoint,
                mode: mode
            )
            scheduleRealtimeMediaAudioNoTrafficRecovery(
                sessionId: snapshot.sessionId,
                endpoint: endpoint,
                renderer: renderer,
                mode: mode
            )
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio receiver ready: session=\(snapshot.sessionId) port=\(endpoint.port) mode=\(mode.rawValue) transport=\(activeTransportModeLabel()) codec=opus audioPath=pqc-opus-source-node-ring relayToken=\(endpoint.relayToken == nil ? "missing" : "present") legacyFallback=false"
            )
            Task.detached(priority: .utility) { [renderer, sessionId = snapshot.sessionId, endpoint, mode] in
                try? await Task.sleep(for: .seconds(3))
                let snapshot = await renderer.startupDiagnosticSnapshot()
                if snapshot.received == 0 {
                    let probable: String = {
                        if snapshot.datagramsSeen == 0 {
                            return "host-not-sending-or-relay-blocked"
                        }
                        if snapshot.sessionHashRejected > 0 {
                            return "session-hash-rejected"
                        }
                        if snapshot.authRejected > 0 {
                            return "auth-decrypt-rejected"
                        }
                        if snapshot.sourceRejected > 0 {
                            return "source-rejected"
                        }
                        if snapshot.replayRejected > 0 {
                            return "replay-rejected"
                        }
                        return "rx-not-accepted"
                    }()
                    SkyBridgeLogger.shared.warning(
                        "🎧 PQC media audio rx startup stalled: session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) mode=\(mode.rawValue) audioRxDatagrams=\(snapshot.datagramsSeen) audioRxRecv=0 audioRxDecoded=\(snapshot.decoded) audioRxPlayed=\(snapshot.played) rejected=\(snapshot.rejected) authRejected=\(snapshot.authRejected) sessionHashRejected=\(snapshot.sessionHashRejected) replayRejected=\(snapshot.replayRejected) sourceReject=\(snapshot.sourceRejected) sourceMigrate=\(snapshot.sourceMigrated) probable=\(probable)"
                    )
                    SkyBridgeSmokeTraceWriter.append(
                        "audio-rx session=\(sessionId) audioRxDatagrams=\(snapshot.datagramsSeen) audioRxRecv=0 audioRxDecoded=\(snapshot.decoded) audioRxPlayed=\(snapshot.played) recvTotal=\(snapshot.received) decodeTotal=\(snapshot.decoded) playTotal=\(snapshot.played) rejected=\(snapshot.rejected) authRejected=\(snapshot.authRejected) sessionHashRejected=\(snapshot.sessionHashRejected) replayRejected=\(snapshot.replayRejected) sourceReject=\(snapshot.sourceRejected) sourceMigrate=\(snapshot.sourceMigrated) relay=\(endpoint.host):\(endpoint.port) mode=\(mode.rawValue) probable=\(probable)"
                    )
                    SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                        [
                            "kind": "audioRxStartup",
                            "session": sessionId,
                            "session_id": sessionId,
                            "audioRxDatagrams": snapshot.datagramsSeen,
                            "audioRxRecv": UInt64(0),
                            "audioRxDecoded": snapshot.decoded,
                            "audioRxPlayed": snapshot.played,
                            "recvTotal": snapshot.received,
                            "decodeTotal": snapshot.decoded,
                            "playTotal": snapshot.played,
                            "rejected": snapshot.rejected,
                            "authRejected": snapshot.authRejected,
                            "sessionHashRejected": snapshot.sessionHashRejected,
                            "replayRejected": snapshot.replayRejected,
                            "sourceReject": snapshot.sourceRejected,
                            "sourceMigrate": snapshot.sourceMigrated,
                            "relay": "\(endpoint.host):\(endpoint.port)",
                            "mode": mode.rawValue,
                            "probable": probable
                        ]
                    )
                }
            }
            return (endpoint, snapshot.sessionId)
        } catch {
            guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }
            SkyBridgeLogger.shared.warning(
                "⚠️ PQC media audio receiver unavailable; keeping video-only: \(error.localizedDescription)"
            )
            stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
            return nil
        }
    }

    private func isCurrentRealtimeMediaAudioReceiverStart(_ generation: UInt64?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let generation else { return true }
        return realtimeMediaAudioReceiverStartGeneration == generation
    }

    private func lanRealtimeMediaKeySnapshot() -> RemoteRealtimeMediaKeySnapshot? {
        guard activeTransportMode == .lan,
              let keys = lanSessionKeys else {
            return nil
        }
        return RemoteRealtimeMediaKeySnapshot(
            sessionId: Self.lanRealtimeMediaSessionId(for: keys),
            sendKey: keys.sendKey,
            receiveKey: keys.receiveKey,
            transcriptHash: keys.transcriptHash,
            mediaAdmissionToken: nil
        )
    }

    private static func lanRealtimeMediaSessionId(for keys: SessionKeys) -> String {
        var material = Data("skybridge-lan-remote-media-session-v1".utf8)
        material.append(keys.transcriptHash)
        let digest = SHA256.hash(data: material)
        let prefix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "lan-rc-\(prefix)"
    }

    private func stopRealtimeMediaAudioReceiver(cancelPendingStart: Bool = true) {
        if cancelPendingStart {
            realtimeMediaAudioReceiverStartGeneration &+= 1
            realtimeMediaAudioReceiverStartTask?.cancel()
            realtimeMediaAudioReceiverStartTask = nil
            realtimeMediaAudioReceiverStartPhase = nil
        }
        realtimeMediaAudioRelayBindGraceTask?.cancel()
        realtimeMediaAudioRelayBindGraceTask = nil
        realtimeMediaAudioRelayRenewalTask?.cancel()
        realtimeMediaAudioRelayRenewalTask = nil
        realtimeMediaAudioNoTrafficRecoveryTask?.cancel()
        realtimeMediaAudioNoTrafficRecoveryTask = nil
        realtimeMediaAudioRelayBindState = .idle
        realtimeMediaAudioReceiver?.stop()
        if let relayTransport = realtimeMediaAudioRelayTransport {
            Task(priority: .utility) {
                await relayTransport.stop()
            }
        }
        if let renderer = realtimeMediaAudioRenderer {
            Task(priority: .utility) {
                await renderer.close()
            }
        }
        realtimeMediaAudioReceiver = nil
        realtimeMediaAudioRelayTransport = nil
        realtimeMediaAudioRenderer = nil
        realtimeMediaAudioReceiverSessionId = nil
        realtimeMediaAudioEndpoint = nil
    }

    private static func isUsableRealtimeMediaAudioEndpoint(
        _ endpoint: SkyBridgeMediaEndpoint,
        now: Date = Date(),
        minimumRemainingTime: TimeInterval = 10
    ) -> Bool {
        guard let expiresAt = endpoint.expiresAt else { return true }
        return expiresAt - now.timeIntervalSince1970 > minimumRemainingTime
    }

    private func pushViewerStreamConfiguration(force: Bool, refreshStream: Bool = false) async {
        guard isStreaming else { return }
        guard !handleCrossNetworkSessionAuthorityLostIfNeeded(source: "stream-config") else { return }
        let canSendOverWebRTC = activeTransportMode == .crossNetwork && currentConnection != nil
        let canSendOverLAN = activeTransportMode == .lan && networkConnection != nil
        guard canSendOverWebRTC || canSendOverLAN else { return }
        let mediaAudioMode: SkyBridgeMediaAudioMode = viewerSettings.lowLatencyMode ? .lowLatency : .highFidelity
        let mediaAudioBinding = currentRealtimeMediaAudioBindingIfUsable()
        if viewerSettings.audioRedirectionEnabled {
            ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mediaAudioMode)
        } else {
            realtimeMediaAudioReceiverStartTask?.cancel()
            realtimeMediaAudioReceiverStartTask = nil
            stopRealtimeMediaAudioReceiver()
        }
        let includeAudioEndpointInStreamConfig = !refreshStream
        let payload = makeViewerStreamConfigurationPayload(
            refreshStream: refreshStream,
            mediaAudioEndpoint: includeAudioEndpointInStreamConfig ? mediaAudioBinding?.endpoint : nil,
            mediaSessionId: includeAudioEndpointInStreamConfig ? mediaAudioBinding?.mediaSessionId : nil
        )
        guard force || payload != lastSentStreamConfiguration else { return }
        do {
            try await sendViewerStreamConfigurationPayload(payload, retryAttempt: nil)
            lastSentStreamConfiguration = payload
            if includeAudioEndpointInStreamConfig, payload.mediaAudioEndpoint != nil {
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio-present config sent: event=audioPresentConfigSent refreshStream=\(payload.streamRefreshToken != nil) mediaSession=\(payload.mediaSessionId ?? "-") audioRelayToken=\(payload.mediaAudioEndpoint?.relayToken == nil ? "missing" : "present") transport=\(activeTransportModeLabel())"
                )
            }
            if let token = payload.streamRefreshToken {
                let now = Date()
                lastRequestedStreamRefreshToken = token
                lastRequestedStreamRefreshAt = now
                lastRefreshRequestFailureDescription = nil
                lastWaitingSyncDiagnosticLogTime = .distantPast
                SkyBridgeLogger.shared.info(
                    "🪄 viewer 已发送关键帧刷新请求: token=\(token) reason=\(lastRequestedStreamRefreshReason ?? "unspecified") transport=\(activeTransportModeLabel()) summary=\(crossNetwork.remoteDesktopRecoveryDebugSummary())"
                )
            }
            scheduleStreamConfigurationAckRetryIfNeeded(for: payload)
        } catch {
            if let token = payload.streamRefreshToken {
                lastRefreshRequestFailureDescription = error.localizedDescription
                SkyBridgeLogger.shared.error(
                    "❌ viewer 关键帧刷新请求发送失败: token=\(token) reason=\(lastRequestedStreamRefreshReason ?? "unspecified") err=\(error.localizedDescription) transport=\(activeTransportModeLabel()) summary=\(crossNetwork.remoteDesktopRecoveryDebugSummary())"
                )
            }
            SkyBridgeLogger.shared.error("❌ 发送远控流配置失败: \(error.localizedDescription)")
        }
    }

    private func sendViewerStreamConfigurationPayload(
        _ payload: RemoteDesktopStreamConfigurationPayload,
        retryAttempt: Int?
    ) async throws {
        let encoded = try JSONEncoder().encode(payload)
        let message = RemoteMessage(type: .streamConfiguration, payload: encoded)
        try await sendMessage(message)
        let retrySuffix = retryAttempt.map { " retryAttempt=\($0)" } ?? ""
        SkyBridgeLogger.shared.info(
            "📤 已发送远控流配置: event=streamConfigSent\(retrySuffix) preset=\(viewerSettings.activePreset.displayName), preferred=\(payload.preferredCodec ?? "auto"), formats=\(payload.supportedVideoFormats.joined(separator: ",")), fps=\(payload.targetFrameRate), jitter=\(payload.jitterBufferFrames ?? 0), refresh=\(payload.streamRefreshToken != nil) token=\(payload.streamRefreshToken.map(String.init) ?? "-") transport=\(payload.screenFrameTransport ?? "legacy") screenChannel=\(payload.screenDataChannelEnabled == true) screenWire=\(payload.screenChannelWireFormat ?? "length-framed") nativeReady=\(payload.nativeVideoTrackReady == true) streamConfigIncludesAudio=\(payload.mediaAudioEndpoint != nil) audioTransport=\(payload.audioTransport ?? "nil") mediaSession=\(payload.mediaSessionId ?? "-") audioRelayToken=\(payload.mediaAudioEndpoint?.relayToken == nil ? "missing" : "present")"
        )
    }

    private func scheduleStreamConfigurationAckRetryIfNeeded(
        for payload: RemoteDesktopStreamConfigurationPayload
    ) {
        // Retry only video/main configs. A startup refresh token is resent as
        // the same stable payload, so this does not allocate new keyframes.
        guard activeTransportMode == .crossNetwork,
              isStreaming,
              !hasReceivedFrameInCurrentStream,
              payload.mediaAudioEndpoint == nil else {
            return
        }
        streamConfigurationAckSatisfied = false
        streamConfigurationAckGeneration &+= 1
        let generation = streamConfigurationAckGeneration
        streamConfigurationAckTask?.cancel()
        streamConfigurationAckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delays = [1, 2, 4]
            for (index, delay) in delays.enumerated() {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard self.streamConfigurationAckGeneration == generation,
                      self.isStreaming,
                      self.activeTransportMode == .crossNetwork,
                      !self.hasReceivedFrameInCurrentStream,
                      !self.streamConfigurationAckSatisfied else {
                    return
                }
                guard !self.handleCrossNetworkSessionAuthorityLostIfNeeded(source: "stream-config-ack-retry") else {
                    return
                }
                do {
                    try await self.sendViewerStreamConfigurationPayload(payload, retryAttempt: index + 1)
                } catch {
                    SkyBridgeLogger.shared.warning("⚠️ streamConfigurationAck 等待期间重发远控流配置失败: attempt=\(index + 1) err=\(error.localizedDescription)")
                }
            }
        }
    }

    public func handleStreamConfigurationAck(_ ack: RemoteDesktopStreamConfigurationAckPayload) {
        guard isStreaming else { return }
        streamConfigurationAckSatisfied = true
        streamConfigurationAckTask?.cancel()
        streamConfigurationAckTask = nil
        SkyBridgeLogger.shared.info(
            "✅ 收到远控流配置 ACK: event=streamConfigAck token=\(ack.streamRefreshToken.map(String.init) ?? "-") audioEndpoint=\(ack.audioEndpointPresent) transport=\(ack.screenFrameTransport ?? "legacy")"
        )
    }

    private func sendViewerStreamStopConfigurationIfNeeded() async {
        let canSendOverWebRTC = activeTransportMode == .crossNetwork && currentConnection != nil
        let canSendOverLAN = activeTransportMode == .lan && networkConnection != nil
        guard canSendOverWebRTC || canSendOverLAN else { return }

        let payload = makeViewerStreamStopConfigurationPayload()
        do {
            let encoded = try JSONEncoder().encode(payload)
            let message = RemoteMessage(type: .streamConfiguration, payload: encoded)
            try await sendMessage(message)
            lastSentStreamConfiguration = payload
            SkyBridgeLogger.shared.info("📤 已发送远控停止流配置: transport=\(activeTransportModeLabel())")
        } catch {
            SkyBridgeLogger.shared.error("❌ 发送远控停止流配置失败: \(error.localizedDescription)")
        }
    }

    private func makeViewerStreamStopConfigurationPayload() -> RemoteDesktopStreamConfigurationPayload {
        RemoteDesktopStreamConfigurationPayload(
            supportedVideoFormats: [],
            targetFrameRate: 0,
            keyFrameInterval: 0,
            lowLatencyMode: false,
            enableHardwareAcceleration: false,
            enableAppleSiliconOptimization: false,
            clipboardSyncEnabled: false,
            damageTrackingEnabled: false,
            separateCursorChannelEnabled: false,
            interactionOverlayChannelEnabled: false,
            refreshStrategy: "stop",
            jitterBufferFrames: 0,
            lossRecoveryMode: "stop",
            screenFrameTransport: "stopped",
            screenDataChannelEnabled: false,
            nativeVideoTrackReady: false,
            nativeAudioTrackEnabled: false,
            audioRedirectionEnabled: false,
            audioTransport: "disabled",
            audioMode: nil,
            compatibilityAudioFallbackEnabled: false,
            preferredAudioEncoding: nil,
            audioSampleRate: nil,
            audioChannelCount: nil,
            streamRefreshToken: nil
        )
    }

    func makeViewerStreamConfigurationPayload() -> RemoteDesktopStreamConfigurationPayload {
        makeViewerStreamConfigurationPayload(refreshStream: false)
    }

    func makeViewerStreamConfigurationPayload(
        refreshStream: Bool,
        mediaAudioEndpoint: SkyBridgeMediaEndpoint? = nil,
        mediaSessionId: String? = nil
    ) -> RemoteDesktopStreamConfigurationPayload {
        let now = Date()
        let strictMediaValidationEnabled = Self.shouldRequestExtremeMediaValidation(
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            viewerSettings: viewerSettings
        )
        let nativeWarmupRequiresJPEGFallback: Bool
#if canImport(WebRTC)
        nativeWarmupRequiresJPEGFallback = !strictMediaValidationEnabled
            && Self.shouldUseJPEGOnlyFallbackDuringNativeWarmup(
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            hasRemoteNativeVideoTrack: crossNetwork.remoteVideoTrack != nil,
            nativeVideoTrackHasRenderedFrame: crossNetwork.remoteVideoTrackHasRenderedFrame
        )
#else
        nativeWarmupRequiresJPEGFallback = false
#endif
        let supportedFormats = nativeWarmupRequiresJPEGFallback
            ? ["jpeg"]
            : effectiveSupportedRemoteVideoFormats(at: now)
        let preferredCodec = nativeWarmupRequiresJPEGFallback
            ? "jpeg"
            : codecGovernance.effectivePreferredCodec(
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
            screenFrameTransport: activeTransportMode == .crossNetwork
                ? (strictMediaValidationEnabled ? "webrtc-native-main" : "webrtc-native-main+sbrf-fallback")
                : "sbrf-v1",
            // Keep fallback screen frames off the control channel. The iOS
            // screen-channel receive loop is nonisolated; the control channel
            // also carries handshake, heartbeat, input, rekey, and file traffic.
            screenDataChannelEnabled: true,
            screenChannelWireFormat: activeTransportMode == .crossNetwork
                ? "sbc2-chunked-v1"
                : nil,
            nativeVideoTrackReady: Self.advertisedCrossNetworkNativeVideoReadyFlag(
                activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
                hasRenderedNativeFrame: crossNetwork.remoteVideoTrackHasRenderedFrame
            ),
            // Keep iOS viewer on the transport-owned fallback audio path for now.
            // Native WebRTC audio on iOS still competes for AVAudioSession ownership
            // during startup and has been causing crashy/privacy-sensitive behavior.
            nativeAudioTrackEnabled: Self.crossNetworkNativeAudioReceiveEnabled,
            audioRedirectionEnabled: viewerSettings.audioRedirectionEnabled,
            audioTransport: viewerSettings.audioRedirectionEnabled ? "pqc-media-v1" : "disabled",
            audioMode: viewerSettings.lowLatencyMode ? "low-latency" : "high-fidelity",
            mediaSessionId: mediaSessionId,
            mediaAudioEndpoint: mediaAudioEndpoint,
            compatibilityAudioFallbackEnabled: false,
            preferredAudioEncoding: nil,
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            performanceValidationMode: strictMediaValidationEnabled ? "extreme" : nil,
            mediaFallbackPolicy: strictMediaValidationEnabled ? "fail-fast" : "explicit-degraded",
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

    private func resetRefreshDiagnostics() {
        lastRefreshRequestAt = nil
        lastRequestedStreamRefreshToken = nil
        lastRequestedStreamRefreshReason = nil
        lastRequestedStreamRefreshAt = nil
        lastRefreshRequestFailureDescription = nil
        hevcDisableRefreshSuppressedUntil = nil
        hevcDisableRefreshTokenInFlight = nil
        lastWaitingSyncDiagnosticLogTime = .distantPast
    }

    private func resetStreamConfigurationAckState() {
        streamConfigurationAckGeneration &+= 1
        streamConfigurationAckTask?.cancel()
        streamConfigurationAckTask = nil
        streamConfigurationAckSatisfied = false
    }

    private var crossNetworkSessionAuthorityLost: Bool {
        guard activeTransportMode == .crossNetwork else { return false }
        if case .failed(let message) = crossNetwork.state {
            return message == "sessionAuthorityLost"
        }
        return false
    }

    @discardableResult
    private func handleCrossNetworkSessionAuthorityLostIfNeeded(source: String) -> Bool {
        guard crossNetworkSessionAuthorityLost else { return false }
        resetStreamConfigurationAckState()
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        firstFrameContinuityTask?.cancel()
        firstFrameContinuityTask = nil
        realtimeMediaAudioReceiverStartGeneration &+= 1
        realtimeMediaAudioReceiverStartTask?.cancel()
        realtimeMediaAudioReceiverStartTask = nil
        realtimeMediaAudioReceiverStartPhase = nil
        realtimeMediaAudioRelayBindGraceTask?.cancel()
        realtimeMediaAudioRelayBindGraceTask = nil
        realtimeMediaAudioRelayBindState = .idle
        stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
        isStreaming = false
        state = .error("sessionAuthorityLost")
        renderPipelineStatus = .waiting
        if lastHandledSessionAuthorityLostStreamEpoch != streamEpoch {
            lastHandledSessionAuthorityLostStreamEpoch = streamEpoch
            SkyBridgeLogger.shared.warning(
                "🎧 远控流停止等待完整 WebRTC rejoin: event=sessionAuthorityLost source=\(source) transport=\(activeTransportModeLabel()) summary=\(crossNetwork.remoteDesktopRecoveryDebugSummary())"
            )
        }
        return true
    }

    private func currentRealtimeMediaAudioBindingIfUsable() -> (endpoint: SkyBridgeMediaEndpoint, mediaSessionId: String)? {
        guard let endpoint = realtimeMediaAudioEndpoint,
              let mediaSessionId = realtimeMediaAudioReceiverSessionId,
              realtimeMediaAudioRenderer != nil,
              Self.isUsableRealtimeMediaAudioEndpoint(endpoint) else {
            return nil
        }
        return (endpoint, mediaSessionId)
    }

    private func scheduleRealtimeMediaAudioNoTrafficRecovery(
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint,
        renderer: IOSRealtimeMediaAudioReceiver,
        mode: SkyBridgeMediaAudioMode
    ) {
        realtimeMediaAudioNoTrafficRecoveryTask?.cancel()
        realtimeMediaAudioNoTrafficRecoveryTask = nil
        guard activeTransportMode == .crossNetwork else { return }
        realtimeMediaAudioNoTrafficRecoveryTask = Task { @MainActor [weak self, renderer] in
            do {
                try await Task.sleep(for: Self.realtimeMediaAudioNoTrafficRecoveryDelay)
            } catch {
                return
            }
            guard let self,
                  self.activeTransportMode == .crossNetwork,
                  self.isStreaming,
                  self.viewerSettings.audioRedirectionEnabled,
                  self.realtimeMediaAudioReceiverSessionId == sessionId,
                  self.realtimeMediaAudioEndpoint == endpoint,
                  self.realtimeMediaAudioRenderer != nil else {
                return
            }
            let snapshot = await renderer.startupDiagnosticSnapshot()
            if snapshot.datagramsSeen > 0 || snapshot.received > 0 {
                self.realtimeMediaAudioNoTrafficRecoveryAttemptsBySessionId.removeValue(forKey: sessionId)
                return
            }

            let attempt = (self.realtimeMediaAudioNoTrafficRecoveryAttemptsBySessionId[sessionId] ?? 0) + 1
            self.realtimeMediaAudioNoTrafficRecoveryAttemptsBySessionId[sessionId] = attempt
            let relay = "\(endpoint.host):\(endpoint.port)"
            guard attempt <= Self.realtimeMediaAudioNoTrafficRecoveryMaxAttempts else {
                SkyBridgeLogger.shared.warning(
                    "🎧 PQC media audio relay no-traffic recovery exhausted: event=relayNoTrafficRecoveryExhausted session=\(sessionId) relay=\(relay) attempts=\(attempt - 1) action=doctor-fail transport=\(self.activeTransportModeLabel())"
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayNoTrafficRecoveryExhausted session=\(sessionId) relay=\(relay) attempts=\(attempt - 1) probable=relay-bound-but-no-datagrams"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxNoTrafficRecovery",
                        "session": sessionId,
                        "session_id": sessionId,
                        "relay": relay,
                        "attempt": attempt - 1,
                        "action": "exhausted",
                        "probable": "relay-bound-but-no-datagrams"
                    ]
                )
                return
            }

            SkyBridgeLogger.shared.warning(
                "🎧 PQC media audio relay accepted but delivered no datagrams: event=relayNoTrafficRecovery session=\(sessionId) relay=\(relay) attempt=\(attempt) action=lease-refresh transport=\(self.activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayNoTrafficRecovery session=\(sessionId) relay=\(relay) attempt=\(attempt) action=lease-refresh probable=relay-bound-but-no-datagrams"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxNoTrafficRecovery",
                    "session": sessionId,
                    "session_id": sessionId,
                    "relay": relay,
                    "attempt": attempt,
                    "action": "lease-refresh",
                    "probable": "relay-bound-but-no-datagrams"
                ]
            )
            self.crossNetwork.clearCachedRealtimeMediaRelayEndpointForActiveSession(
                reason: "relayNoTrafficAfterBindAccepted"
            )
            self.stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
            self.ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mode)
        }
    }

    private func scheduleRealtimeMediaAudioEndpointRenewal(
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint,
        mode: SkyBridgeMediaAudioMode
    ) {
        realtimeMediaAudioRelayRenewalTask?.cancel()
        realtimeMediaAudioRelayRenewalTask = nil
        guard activeTransportMode == .crossNetwork,
              let expiresAt = endpoint.expiresAt else {
            return
        }
        let nowSeconds = Date().timeIntervalSince1970
        let delaySeconds = max(1, expiresAt - nowSeconds - Self.realtimeMediaAudioEndpointRenewalLeadTime)
        let delayNanos = UInt64(delaySeconds * 1_000_000_000)
        let delayMs = Int((delaySeconds * 1000).rounded())
        let expiresInMs = Int(((expiresAt - nowSeconds) * 1000).rounded())
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio relay renewal scheduled: event=relayLeaseRenewalScheduled session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) delayMs=\(delayMs) expiresInMs=\(expiresInMs) transport=\(activeTransportModeLabel())"
        )
        SkyBridgeSmokeTraceWriter.append(
            "audio-rx relayLeaseRenewalScheduled session=\(sessionId) delayMs=\(delayMs) relay=\(endpoint.host):\(endpoint.port)"
        )
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
            [
                "kind": "audioRxEndpointRenewalScheduled",
                "session": sessionId,
                "session_id": sessionId,
                "relay": "\(endpoint.host):\(endpoint.port)",
                "delayMs": delayMs,
                "expiresInMs": expiresInMs
            ]
        )
        realtimeMediaAudioRelayRenewalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanos)
            } catch {
                return
            }
            guard let self,
                  self.activeTransportMode == .crossNetwork,
                  self.isStreaming,
                  self.viewerSettings.audioRedirectionEnabled,
                  self.realtimeMediaAudioReceiverSessionId == sessionId,
                  self.realtimeMediaAudioEndpoint == endpoint else {
                return
            }
            await self.renewRealtimeMediaAudioRelayEndpoint(
                sessionId: sessionId,
                currentEndpoint: endpoint,
                mode: mode
            )
        }
    }

    private static func isSameRealtimeMediaRelayAddress(
        _ lhs: SkyBridgeMediaEndpoint,
        _ rhs: SkyBridgeMediaEndpoint
    ) -> Bool {
        lhs.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == rhs.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && lhs.port == rhs.port
    }

    private func renewRealtimeMediaAudioRelayEndpoint(
        sessionId: String,
        currentEndpoint: SkyBridgeMediaEndpoint,
        mode: SkyBridgeMediaAudioMode
    ) async {
        guard activeTransportMode == .crossNetwork,
              isStreaming,
              viewerSettings.audioRedirectionEnabled,
              realtimeMediaAudioReceiverSessionId == sessionId,
              realtimeMediaAudioEndpoint == currentEndpoint,
              let renderer = realtimeMediaAudioRenderer else {
            return
        }
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio relay renewal started: event=relayLeaseRenewalStart session=\(sessionId) oldRelay=\(currentEndpoint.host):\(currentEndpoint.port) transport=\(activeTransportModeLabel())"
        )
        crossNetwork.clearCachedRealtimeMediaRelayEndpointForActiveSession(reason: "lease-renewal")
        let relayEndpointPair: CrossNetworkWebRTCManager.RealtimeMediaRelayEndpointPair?
        do {
            relayEndpointPair = try await crossNetwork.requestRealtimeMediaRelayEndpointForActiveSession()
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ PQC media audio relay renewal lease request failed: session=\(sessionId) error=\(error.localizedDescription)"
            )
            scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: currentEndpoint, mode: mode)
            return
        }
        guard let relayEndpointPair else {
            let reason = crossNetwork.mediaRelayLeaseDiagnosticForActiveSession() ?? "unknown"
            SkyBridgeLogger.shared.warning(
                "⚠️ PQC media audio relay renewal lease unavailable: session=\(sessionId) reason=\(reason)"
            )
            scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: currentEndpoint, mode: mode)
            return
        }
        let relayEndpoint = relayEndpointPair.localEndpoint
        let relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy =
            strictCrossNetworkMediaValidationActive ? .requireAcknowledgement : .optimisticAfterSend
        if Self.isSameRealtimeMediaRelayAddress(currentEndpoint, relayEndpoint),
           let relayToken = relayEndpoint.relayToken,
           let currentTransport = realtimeMediaAudioRelayTransport {
            do {
                try await currentTransport.rebindRelayToken(
                    relayToken,
                    relayBindPolicy: relayBindPolicy
                )
                realtimeMediaAudioEndpoint = relayEndpoint
                realtimeMediaAudioRelayBindState = relayBindPolicy == .requireAcknowledgement
                    ? .accepted(sessionId: sessionId, endpoint: relayEndpoint)
                    : .ackPending(sessionId: sessionId, endpoint: relayEndpoint)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio relay renewed in place: event=relayLeaseRenewed session=\(sessionId) role=\(relayEndpointPair.localRole) relay=\(relayEndpoint.host):\(relayEndpoint.port) token=present transport=\(activeTransportModeLabel())"
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewed session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) mode=in-place"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointRenewed",
                        "session": sessionId,
                        "session_id": sessionId,
                        "relay": "\(relayEndpoint.host):\(relayEndpoint.port)",
                        "role": relayEndpointPair.localRole,
                        "relayTokenPresent": true,
                        "probable": "relay-lease-renewed-in-place"
                    ]
                )
                scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: relayEndpoint, mode: mode)
                return
            } catch {
                SkyBridgeLogger.shared.warning(
                    "⚠️ PQC media audio in-place relay renewal failed; falling back to transport rollover: session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) error=\(error.localizedDescription)"
                )
            }
        }
        let relayTransport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: relayEndpoint,
            receiveHandler: { [renderer] datagram in
                Task.detached(priority: .utility) {
                    await renderer.handle(datagram: datagram)
                }
            },
            relayBindPolicy: relayBindPolicy,
            startEventHandler: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleRealtimeMediaAudioRelayTransportEvent(
                        event,
                        sessionId: sessionId,
                        endpoint: relayEndpoint,
                        generation: nil
                    )
                }
            }
        )
        do {
            try await relayTransport.start()
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ PQC media audio relay renewal UDP start failed: session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) error=\(error.localizedDescription)"
            )
            crossNetwork.markRealtimeMediaRelayEndpointUnusableForActiveSession(reason: "renewalStartFailed")
            scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: currentEndpoint, mode: mode)
            return
        }
        guard activeTransportMode == .crossNetwork,
              isStreaming,
              viewerSettings.audioRedirectionEnabled,
              realtimeMediaAudioReceiverSessionId == sessionId,
              realtimeMediaAudioEndpoint == currentEndpoint else {
            await relayTransport.stop()
            return
        }
        let oldTransport = realtimeMediaAudioRelayTransport
        realtimeMediaAudioRelayTransport = relayTransport
        realtimeMediaAudioEndpoint = relayEndpoint
        realtimeMediaAudioRelayBindState = .idle
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio relay renewed: event=relayLeaseRenewed session=\(sessionId) role=\(relayEndpointPair.localRole) relay=\(relayEndpoint.host):\(relayEndpoint.port) token=\(relayEndpoint.relayToken == nil ? "missing" : "present") transport=\(activeTransportModeLabel())"
        )
        SkyBridgeSmokeTraceWriter.append(
            "audio-rx relayLeaseRenewed session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port)"
        )
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
            [
                "kind": "audioRxEndpointRenewed",
                "session": sessionId,
                "session_id": sessionId,
                "relay": "\(relayEndpoint.host):\(relayEndpoint.port)",
                "role": relayEndpointPair.localRole,
                "relayTokenPresent": relayEndpoint.relayToken != nil,
                "probable": "relay-lease-renewed"
            ]
        )
        scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: relayEndpoint, mode: mode)
        await pushViewerStreamConfiguration(force: true, refreshStream: false)
        if let oldTransport {
            Task(priority: .utility) {
                try? await Task.sleep(for: Self.realtimeMediaAudioRelayRolloverGraceDelay)
                await oldTransport.stop()
            }
        }
    }

    private func handleRealtimeMediaAudioRelayBindFailure(
        reason: String,
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint
    ) {
        let endpointMatches = realtimeMediaAudioEndpoint == endpoint
        guard realtimeMediaAudioReceiverSessionId == sessionId,
              endpointMatches else {
            let currentRelayLabel = realtimeMediaAudioEndpoint.map { "\($0.host):\($0.port)" } ?? "-"
            SkyBridgeLogger.shared.debug(
                "ℹ️ ignore stale PQC media relay bind failure: session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) reason=\(reason) currentSession=\(realtimeMediaAudioReceiverSessionId ?? "-") currentRelay=\(currentRelayLabel)"
            )
            return
        }
        realtimeMediaAudioRelayBindGraceTask?.cancel()
        realtimeMediaAudioRelayBindGraceTask = nil
        realtimeMediaAudioRelayBindState = .failed(sessionId: sessionId, endpoint: endpoint, reason: reason)
        crossNetwork.markRealtimeMediaRelayEndpointUnusableForActiveSession(reason: reason)
        stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
        realtimeMediaAudioRelayBindState = .failed(sessionId: sessionId, endpoint: endpoint, reason: reason)
        Task { @MainActor [weak self] in
            await self?.pushViewerStreamConfiguration(force: false, refreshStream: false)
        }
    }

    private func scheduleRealtimeMediaAudioRelayBindGrace(
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint
    ) {
        realtimeMediaAudioRelayBindGraceTask?.cancel()
        realtimeMediaAudioRelayBindGraceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.realtimeMediaAudioRelayBindAckGraceDelay)
            } catch {
                return
            }
            guard let self else { return }
            guard self.realtimeMediaAudioReceiverSessionId == sessionId,
                  self.realtimeMediaAudioEndpoint == endpoint,
                  let renderer = self.realtimeMediaAudioRenderer else {
                return
            }
            let snapshot = await renderer.startupDiagnosticSnapshot()
            if snapshot.received > 0 {
                self.realtimeMediaAudioRelayBindState = .trafficObserved(
                    sessionId: sessionId,
                    endpoint: endpoint
                )
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio relay bind ack timeout tolerated: event=relayBindAckGraceTrafficObserved session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) audioRxDatagrams=\(snapshot.datagramsSeen) audioRxRecv=\(snapshot.received) transport=\(self.activeTransportModeLabel())"
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayBindAckGraceTrafficObserved session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) audioRxDatagrams=\(snapshot.datagramsSeen) audioRxRecv=\(snapshot.received)"
                )
                return
            }
            if snapshot.datagramsSeen > 0 {
                SkyBridgeLogger.shared.warning(
                    "🎧 PQC media audio relay bind grace saw only rejected traffic: event=relayBindGraceUnauthenticatedTraffic session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) audioRxDatagrams=\(snapshot.datagramsSeen) audioRxRecv=0 rejected=\(snapshot.rejected) authRejected=\(snapshot.authRejected) sessionHashRejected=\(snapshot.sessionHashRejected) replayRejected=\(snapshot.replayRejected) action=endpoint-backoff transport=\(self.activeTransportModeLabel())"
                )
                self.handleRealtimeMediaAudioRelayBindFailure(
                    reason: "relayBindAckTimedOutNoAuthenticatedTraffic",
                    sessionId: sessionId,
                    endpoint: endpoint
                )
                return
            }
            SkyBridgeLogger.shared.warning(
                "🎧 PQC media audio relay bind grace expired with no traffic: event=relayBindAckGraceTimedOut session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) action=endpoint-backoff transport=\(self.activeTransportModeLabel())"
            )
            self.handleRealtimeMediaAudioRelayBindFailure(
                reason: "relayBindAckTimedOutNoTraffic",
                sessionId: sessionId,
                endpoint: endpoint
            )
        }
    }

    private func handleRealtimeMediaAudioRelayTransportEvent(
        _ event: SkyBridgeRealtimeMediaTransportEvent,
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint,
        generation: UInt64?
    ) {
        guard isCurrentRealtimeMediaAudioReceiverStart(generation)
                || realtimeMediaAudioReceiverSessionId == sessionId else {
            return
        }
        let relay = "\(endpoint.host):\(endpoint.port)"
        switch event {
        case .udpConnectionReady:
            updateRealtimeMediaAudioReceiverStartPhase(.relayBindAck, generation: generation)
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio receiver UDP connection ready: event=udpConnectionReady session=\(sessionId) relay=\(relay) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append("audio-rx udpConnectionReady session=\(sessionId) relay=\(relay)")
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "udpConnectionReady",
                    "relay": relay,
                    "probable": "relay-bind-pending"
                ]
            )
        case .relayBindSent:
            updateRealtimeMediaAudioReceiverStartPhase(.relayBindAck, generation: generation)
            realtimeMediaAudioRelayBindState = .ackPending(sessionId: sessionId, endpoint: endpoint)
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio relay bind sent: event=relayBindSent session=\(sessionId) relay=\(relay) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append("audio-rx relayBindSent session=\(sessionId) relay=\(relay)")
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "relayBindSent",
                    "relay": relay,
                    "probable": "relay-bind-pending"
                ]
            )
        case .relayBindAccepted:
            updateRealtimeMediaAudioReceiverStartPhase(.receiverReady, generation: generation)
            realtimeMediaAudioRelayBindGraceTask?.cancel()
            realtimeMediaAudioRelayBindGraceTask = nil
            realtimeMediaAudioRelayBindState = .accepted(sessionId: sessionId, endpoint: endpoint)
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio relay bind accepted: event=relayBindAccepted session=\(sessionId) relay=\(relay) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append("audio-rx relayBindAccepted session=\(sessionId) relay=\(relay)")
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "relayBindAccepted",
                    "relay": relay,
                    "probable": "relay-bind-ok"
                ]
            )
        case .relayBindAckTimedOut:
            realtimeMediaAudioRelayBindState = .ackPending(sessionId: sessionId, endpoint: endpoint)
            scheduleRealtimeMediaAudioRelayBindGrace(sessionId: sessionId, endpoint: endpoint)
            SkyBridgeLogger.shared.warning(
                "🎧 PQC media audio relay bind ack pending: event=relayBindAckTimedOut session=\(sessionId) relay=\(relay) action=optimistic-grace probable=ack-lost-or-relay-late transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayBindAckTimedOut session=\(sessionId) relay=\(relay) action=optimistic-grace probable=ack-lost-or-relay-late"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "relayBindAckTimedOut",
                    "relay": relay,
                    "probable": "ack-lost-or-relay-late",
                    "action": "optimistic-grace"
                ]
            )
        case .relayBindRejected(let reason):
            handleRealtimeMediaAudioRelayBindFailure(
                reason: "relayBindRejected:\(reason)",
                sessionId: sessionId,
                endpoint: endpoint
            )
            SkyBridgeLogger.shared.warning(
                "🎧 PQC media audio relay bind rejected: event=relayBindRejected session=\(sessionId) relay=\(relay) reason=\(reason) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayBindRejected session=\(sessionId) relay=\(relay) reason=\(reason)"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "relayBindRejected",
                    "relay": relay,
                    "reason": reason,
                    "probable": "relay-token-rejected"
                ]
            )
        case .relayBindMalformed:
            handleRealtimeMediaAudioRelayBindFailure(
                reason: "relayBindMalformed",
                sessionId: sessionId,
                endpoint: endpoint
            )
            SkyBridgeLogger.shared.warning(
                "🎧 PQC media audio relay bind malformed: event=relayBindMalformed session=\(sessionId) relay=\(relay) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append("audio-rx relayBindMalformed session=\(sessionId) relay=\(relay)")
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "relayBindMalformed",
                    "relay": relay,
                    "probable": "relay-control-protocol-mismatch"
                ]
            )
        }
    }

    private func updateRealtimeMediaAudioReceiverStartPhase(
        _ phase: RealtimeMediaAudioReceiverStartPhase,
        generation: UInt64?
    ) {
        guard let generation else {
            realtimeMediaAudioReceiverStartPhase = phase
            return
        }
        guard realtimeMediaAudioReceiverStartGeneration == generation,
              realtimeMediaAudioReceiverStartTask != nil else {
            return
        }
        realtimeMediaAudioReceiverStartPhase = phase
    }

    private func scheduleRealtimeMediaAudioReceiverStageTimeout(
        phase: RealtimeMediaAudioReceiverStartPhase,
        mode: SkyBridgeMediaAudioMode,
        generation: UInt64?,
        startTime: Date
    ) -> Task<Void, Never>? {
        scheduleRealtimeMediaAudioReceiverTimeoutDiagnostic(
            delay: Self.realtimeMediaAudioReceiverStageTimeout,
            reason: .stageTimeout,
            expectedPhase: phase,
            mode: mode,
            generation: generation,
            startTime: startTime
        )
    }

    private func scheduleRealtimeMediaAudioReceiverTimeoutDiagnostic(
        delay: Duration,
        reason: RealtimeMediaAudioReceiverStartFailureReason,
        expectedPhase: RealtimeMediaAudioReceiverStartPhase?,
        mode: SkyBridgeMediaAudioMode,
        generation: UInt64?,
        startTime: Date
    ) -> Task<Void, Never>? {
        guard let generation else { return nil }
        return Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.realtimeMediaAudioReceiverStartGeneration == generation,
                  self.realtimeMediaAudioReceiverStartTask != nil,
                  self.currentRealtimeMediaAudioBindingIfUsable() == nil else {
                return
            }
            if let expectedPhase,
               self.realtimeMediaAudioReceiverStartPhase != expectedPhase {
                return
            }
            self.markRealtimeMediaAudioReceiverStartupFailed(
                generation: generation,
                mode: mode,
                reason: reason,
                phase: expectedPhase ?? self.realtimeMediaAudioReceiverStartPhase,
                startTime: startTime
            )
        }
    }

    private func markRealtimeMediaAudioReceiverStartupFailed(
        generation: UInt64,
        mode: SkyBridgeMediaAudioMode,
        reason: RealtimeMediaAudioReceiverStartFailureReason,
        phase: RealtimeMediaAudioReceiverStartPhase?,
        startTime: Date
    ) {
        guard realtimeMediaAudioReceiverStartGeneration == generation,
              realtimeMediaAudioReceiverStartTask != nil,
              currentRealtimeMediaAudioBindingIfUsable() == nil else {
            return
        }
        let elapsedMs = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
        let stage = phase?.rawValue ?? realtimeMediaAudioReceiverStartPhase?.rawValue ?? "unknown"
        SkyBridgeLogger.shared.warning(
            "🎧 PQC media audio receiver start failed: event=receiverStartFailed reason=\(reason.rawValue) stage=\(stage) mode=\(mode.rawValue) elapsedMs=\(elapsedMs) transport=\(activeTransportModeLabel())"
        )
        let failedTask = realtimeMediaAudioReceiverStartTask
        realtimeMediaAudioReceiverStartGeneration &+= 1
        realtimeMediaAudioReceiverStartTask = nil
        realtimeMediaAudioReceiverStartPhase = nil
        failedTask?.cancel()
        stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
    }

    private func ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: SkyBridgeMediaAudioMode) {
        guard !handleCrossNetworkSessionAuthorityLostIfNeeded(source: "audio-receiver-start") else {
            return
        }
        guard viewerSettings.audioRedirectionEnabled, isStreaming else {
            realtimeMediaAudioReceiverStartTask?.cancel()
            realtimeMediaAudioReceiverStartTask = nil
            stopRealtimeMediaAudioReceiver()
            return
        }
        guard currentRealtimeMediaAudioBindingIfUsable() == nil else { return }
        guard realtimeMediaAudioReceiverStartTask == nil else { return }

        let startTime = Date()
        SkyBridgeLogger.shared.info("🎧 PQC media audio receiver start pending: event=receiverStartPending mode=\(mode.rawValue) transport=\(activeTransportModeLabel())")
        realtimeMediaAudioReceiverStartGeneration &+= 1
        let generation = realtimeMediaAudioReceiverStartGeneration
        let streamGeneration = streamEpoch
        realtimeMediaAudioReceiverStartPhase = .pending
        realtimeMediaAudioReceiverStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let slowDiagnosticTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: Self.realtimeMediaAudioReceiverSlowDiagnosticDelay)
                } catch {
                    return
                }
                guard let self,
                      self.realtimeMediaAudioReceiverStartGeneration == generation,
                      self.streamEpoch == streamGeneration,
                      self.realtimeMediaAudioReceiverStartTask != nil,
                      self.currentRealtimeMediaAudioBindingIfUsable() == nil else {
                    return
                }
                let elapsedMs = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
                let phase = self.realtimeMediaAudioReceiverStartPhase?.rawValue ?? "unknown"
                SkyBridgeLogger.shared.warning("🎧 PQC media audio receiver start slow: event=receiverStartSlow phase=\(phase) mode=\(mode.rawValue) elapsedMs=\(elapsedMs) transport=\(self.activeTransportModeLabel())")
            }
            let totalTimeoutTask = self.scheduleRealtimeMediaAudioReceiverTimeoutDiagnostic(
                delay: Self.realtimeMediaAudioReceiverTotalTimeout,
                reason: .totalTimeout,
                expectedPhase: nil,
                mode: mode,
                generation: generation,
                startTime: startTime
            )
            let binding = await self.prepareRealtimeMediaAudioReceiverIfNeeded(
                mode: mode,
                startGeneration: generation,
                startTime: startTime
            )
            slowDiagnosticTask.cancel()
            totalTimeoutTask?.cancel()
            guard self.realtimeMediaAudioReceiverStartGeneration == generation else {
                if binding != nil {
                    self.stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
                }
                return
            }
            let finalPhase = self.realtimeMediaAudioReceiverStartPhase?.rawValue ?? "unknown"
            self.realtimeMediaAudioReceiverStartTask = nil
            self.realtimeMediaAudioReceiverStartPhase = nil
            guard self.streamEpoch == streamGeneration, self.isStreaming else {
                if binding != nil {
                    self.stopRealtimeMediaAudioReceiver(cancelPendingStart: false)
                }
                return
            }
            if let binding {
                SkyBridgeLogger.shared.info("🎧 PQC media audio receiver started: event=receiverStarted session=\(binding.mediaSessionId) relay=\(binding.endpoint.host):\(binding.endpoint.port) token=\(binding.endpoint.relayToken == nil ? "missing" : "present")")
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx receiverStarted session=\(binding.mediaSessionId) relay=\(binding.endpoint.host):\(binding.endpoint.port)"
                )
                await self.pushViewerStreamConfiguration(force: false, refreshStream: false)
            } else {
                SkyBridgeLogger.shared.info("🎧 PQC media audio receiver start failed: event=receiverStartFailed reason=unavailable stage=\(finalPhase) transport=\(self.activeTransportModeLabel())")
            }
        }
    }

    private func activeTransportModeLabel() -> String {
        switch activeTransportMode {
        case .none:
            return "none"
        case .lan:
            return "lan"
        case .crossNetwork:
            return "cross_network"
        }
    }

    private func preferredDecodedVideoRenderer() -> DecodedVideoRendererPreference {
        return .metal
    }

    private func persistViewerSettings() {
        try? Self.viewerSettingsStore.save(viewerSettings)
    }

    private static func loadViewerSettings() -> RemoteDesktopViewerSettings {
        guard let settings = viewerSettingsStore.load() else {
            return RemoteDesktopViewerSettings()
        }
        var migrated = settings
        if migrated.preferredCodec == .jpeg {
            migrated.preferredCodec = .h264
        }
        return migrated
    }

    private func updateRenderPipeline(_ pipeline: RemoteDesktopRenderPipeline) {
        if activeTransportMode == .crossNetwork,
           crossNetwork.remoteVideoTrackHasRenderedFrame,
           renderPipelineStatus == .webrtcNativeVideo,
           pipeline != .webrtcNativeVideo {
            return
        }
        guard renderPipelineStatus != pipeline else { return }
        renderPipelineStatus = pipeline
        switch pipeline {
        case .waiting:
            break
        case .webrtcNativeVideo:
            SkyBridgeLogger.shared.info("🎬 远控渲染管线已切换到 WebRTC 原生视频轨")
        case .metalRenderer:
            SkyBridgeLogger.shared.info("🎬 远控渲染管线已切换到 Metal Renderer")
        case .sampleBufferDisplayLayer:
            SkyBridgeLogger.shared.info("🎬 远控渲染管线已切换到 AVSampleBufferDisplayLayer")
        case .stillImageFallback:
            SkyBridgeLogger.shared.info("🖼️ 远控渲染管线已切换到静态帧回退")
        }
    }

    private func flushRenderedVideoFeeds(removeDisplayedImage: Bool = true) {
        videoFrameFeed.flush(removeDisplayedImage: removeDisplayedImage)
        metalVideoFrameFeed.flush(removeDisplayedImage: removeDisplayedImage)
    }

    func handleVideoRendererDidFailToDecode(_ errorDescription: String?) async {
        let reason = (errorDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = reason.isEmpty ? "video-renderer-decode-failed" : reason
        let now = Date()
        let format = lastIncomingStreamSignature?.format ?? ""
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(format)
        await decoder.resetPreservingLastFrame()
        let governanceEvent = codecGovernance.noteDecodeFailure(
            format: format,
            reason: normalizedReason,
            at: now
        )
        let governanceHandled = await handleCodecGovernanceEvent(governanceEvent, at: now)
        if !governanceHandled {
            await requestStreamRefreshIfNeeded(reason: "sample-buffer-decode-failed", minimumInterval: 0.25)
        }
        SkyBridgeLogger.shared.warning("⚠️ AVSampleBufferDisplayLayer 解码失败: \(normalizedReason)")
    }

    func handleVideoRendererRequiresFlushToResumeDecoding() async {
        flushRenderedVideoFeeds(removeDisplayedImage: false)
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(
            lastIncomingStreamSignature?.format
        )
        await decoder.resetPreservingLastFrame()
        let now = Date()
        let format = lastIncomingStreamSignature?.format ?? ""
        let governanceEvent = codecGovernance.noteDecodeFailure(
            format: format,
            reason: "renderer-requires-flush",
            at: now
        )
        let governanceHandled = await handleCodecGovernanceEvent(governanceEvent, at: now)
        if !governanceHandled {
            await requestStreamRefreshIfNeeded(reason: "renderer-flush-required", minimumInterval: 0.25)
        }
        SkyBridgeLogger.shared.warning("⚠️ AVSampleBufferDisplayLayer 需要 flush 后才能继续解码，已请求关键帧刷新")
    }
    
    // MARK: - Input Events
    
    /// 发送鼠标/触控事件
    public func sendMouseEvent(_ event: MouseEvent) async {
        guard isStreaming else { return }
        
        do {
            let data = try JSONEncoder().encode(event)
            let message = RemoteMessage(type: .mouseEvent, payload: data)
            try await sendMessage(message)
            noteViewerInteraction(kind: "mouse")
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
            noteViewerInteraction(kind: "keyboard")
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

    private func makeRemoteDesktopEndpointCandidates(for device: DiscoveredDevice) async throws -> [NWEndpoint] {
        let remoteServiceType = DiscoveredDevice.remoteControlServiceType
        var endpoints: [NWEndpoint] = []
        var seen = Set<String>()

        if let bonjour = remoteDesktopBonjourServiceIdentity(for: device) {
            appendRemoteDesktopEndpoint(
                .service(
                    name: bonjour.name,
                    type: remoteServiceType,
                    domain: bonjour.domain,
                    interface: nil
                ),
                to: &endpoints,
                seen: &seen
            )
        }

        if let activePeerAddress = peerAddressBackedRemoteDesktopAddress(for: device) {
            if let port = device.remoteControlPort {
                SkyBridgeLogger.shared.info(
                    "📡 远控使用已建立 P2P 会话的对端地址回退连接: host=\(activePeerAddress) port=\(port)"
                )
                appendRemoteDesktopEndpoint(
                    .hostPort(host: .init(activePeerAddress), port: .init(integerLiteral: port)),
                    to: &endpoints,
                    seen: &seen
                )
            } else {
                SkyBridgeLogger.shared.warning(
                    "⚠️ 远控目标缺少显式端口，拒绝猜测默认端口: host=\(activePeerAddress)"
                )
            }
        }

        if let ip = bestIPAddress(for: device),
           hasReachableLANRemoteDesktopEndpoint(device),
           let port = device.remoteControlPort {
            appendRemoteDesktopEndpoint(
                .hostPort(host: .init(ip), port: .init(integerLiteral: port)),
                to: &endpoints,
                seen: &seen
            )
        }

        if let resolvedIP = await resolveRemoteDesktopIPAddress(for: device) {
            guard hasReachableLANRemoteDesktopEndpoint(device) else {
                if endpoints.isEmpty {
                    throw RemoteDesktopError.connectionFailed("设备未发现可用远程桌面端点")
                }
                return endpoints
            }
            guard let port = device.remoteControlPort else {
                if endpoints.isEmpty {
                    throw RemoteDesktopError.connectionFailed("设备未声明远程桌面端口")
                }
                return endpoints
            }
            SkyBridgeLogger.shared.info(
                "📡 远控已解析到主服务地址: name=\(device.name) ip=\(resolvedIP) port=\(port)"
            )
            appendRemoteDesktopEndpoint(
                .hostPort(host: .init(resolvedIP), port: .init(integerLiteral: port)),
                to: &endpoints,
                seen: &seen
            )
        }

        if !endpoints.isEmpty {
            return endpoints
        }

        throw RemoteDesktopError.connectionFailed("设备缺少可连接地址（Bonjour/IP）")
    }

    private func appendRemoteDesktopEndpoint(
        _ endpoint: NWEndpoint,
        to endpoints: inout [NWEndpoint],
        seen: inout Set<String>
    ) {
        let key = String(describing: endpoint)
        guard seen.insert(key).inserted else { return }
        endpoints.append(endpoint)
    }

    private func resolveLatestRemoteDesktopDevice(from device: DiscoveredDevice) -> DiscoveredDevice {
        if isCrossNetworkDevice(device) {
            return device
        }

        var candidates = deduplicatedRemoteDesktopCandidates(
            DeviceDiscoveryManager.instance.discoveredDevices
                + P2PConnectionManager.instance.activeConnections.map(\.device)
        )
        let peerResolved = connectionManager.resolvedPeerDevice(for: device)
        if !candidates.contains(where: { areEquivalentRemoteDesktopDevices($0, peerResolved) }) {
            candidates.insert(peerResolved, at: 0)
        }
        if let canonical = DeviceDiscoveryManager.instance.canonicalDiscoveredDevice(for: device) {
            candidates.insert(canonical, at: 0)
        }

        var best = Self.resolveBestRemoteDesktopDevice(target: device, discovered: candidates)

        if shouldUseUniqueRemoteCandidateFallback(for: best) {
            let remoteCandidates = candidates.filter { hasReachableLANRemoteDesktopEndpoint($0) }
            if remoteCandidates.count == 1, let only = remoteCandidates.first {
                best = preferredRemoteDesktopDevice(best, only)
            }
        }

        return best
    }

    private func deduplicatedRemoteDesktopCandidates(_ candidates: [DiscoveredDevice]) -> [DiscoveredDevice] {
        var deduplicated: [DiscoveredDevice] = []

        for candidate in candidates {
            let candidateId = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidateId.isEmpty else { continue }

            let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
            if let index = deduplicated.firstIndex(where: { existing in
                if existing.id == candidate.id {
                    return true
                }
                let existingAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: existing))
                return !candidateAliases.isEmpty
                    && !existingAliases.isEmpty
                    && !candidateAliases.isDisjoint(with: existingAliases)
            }) {
                deduplicated[index] = preferredRemoteDesktopDevice(deduplicated[index], candidate)
            } else {
                deduplicated.append(candidate)
            }
        }
        return deduplicated
    }

    private func preferredRemoteDesktopServiceName(for device: DiscoveredDevice) -> String? {
        remoteDesktopBonjourServiceIdentity(for: device)?.name
    }

    private func remoteDesktopBonjourServiceIdentity(for device: DiscoveredDevice) -> (name: String, domain: String)? {
        for candidate in remoteDesktopIdentityCandidates(for: device) {
            let hasRemoteServiceEvidence = candidate.bonjourServiceType == DiscoveredDevice.remoteControlServiceType
                || candidate.services.contains(DiscoveredDevice.remoteControlServiceType)
                || candidate.id.hasPrefix("bonjour:")

            guard hasRemoteServiceEvidence else { continue }

            if let bonjourServiceName = candidate.bonjourServiceName,
               isPlausibleRemoteServiceInstanceName(bonjourServiceName) {
                let domain = candidate.bonjourServiceDomain?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    name: bonjourServiceName.trimmingCharacters(in: .whitespacesAndNewlines),
                    domain: domain?.isEmpty == false ? domain! : "local."
                )
            }
            if let parsed = parseBonjourIdentity(from: candidate.id),
               isPlausibleRemoteServiceInstanceName(parsed.name) {
                return (name: parsed.name.trimmingCharacters(in: .whitespacesAndNewlines), domain: parsed.domain)
            }
        }
        return nil
    }

    private func preferredRemoteDesktopServiceDomain(for device: DiscoveredDevice) -> String {
        for candidate in remoteDesktopIdentityCandidates(for: device) {
            if let domain = candidate.bonjourServiceDomain?.trimmingCharacters(in: .whitespacesAndNewlines),
               !domain.isEmpty {
                return domain
            }
            if let parsed = parseBonjourIdentity(from: candidate.id) {
                return parsed.domain
            }
        }
        return "local."
    }

    private func remoteDesktopIdentityCandidates(for device: DiscoveredDevice) -> [DiscoveredDevice] {
        var candidates: [DiscoveredDevice] = []

        func append(_ candidate: DiscoveredDevice?) {
            guard let candidate else { return }
            if candidates.contains(where: { areEquivalentRemoteDesktopDevices($0, candidate) }) {
                return
            }
            candidates.append(candidate)
        }

        append(device)
        append(connectionManager.resolvedPeerDevice(for: device))
        append(DeviceDiscoveryManager.instance.canonicalDiscoveredDevice(for: device))
        for active in connectionManager.activeConnections.map(\.device) where areEquivalentRemoteDesktopDevices(active, device) {
            append(active)
        }
        return candidates
    }

    private func isPlausibleRemoteServiceInstanceName(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return false
        }
        let lowercased = raw.lowercased()
        if lowercased == "unknown device" || lowercased == "未知设备" {
            return false
        }
        if lowercased.hasPrefix("id:")
            || lowercased.hasPrefix("host:")
            || lowercased.hasPrefix("peer:")
            || lowercased.hasPrefix("recent:") {
            return false
        }
        if UUID(uuidString: raw) != nil {
            return false
        }
        if let sanitized = sanitizeAddress(raw),
           sanitized == lowercased || sanitized == raw {
            return false
        }
        return true
    }

    private func preferredRemoteDesktopDevice(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> DiscoveredDevice {
        remoteDesktopDeviceScore(rhs) > remoteDesktopDeviceScore(lhs) ? rhs : lhs
    }

    private func areEquivalentRemoteDesktopDevices(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        let lhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: lhs))
        let rhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: rhs))
        return !lhsAliases.isEmpty && !rhsAliases.isEmpty && !lhsAliases.isDisjoint(with: rhsAliases)
    }

    private func remoteDesktopDeviceScore(_ device: DiscoveredDevice) -> Int {
        var score = 0
        if device.services.contains(DiscoveredDevice.remoteControlServiceType)
            || device.bonjourServiceType == DiscoveredDevice.remoteControlServiceType {
            score += 120
        }
        if device.remoteControlPort != nil {
            score += 100
        }
        if bestIPAddress(for: device) != nil {
            score += 80
        }
        if device.supportsRemoteControl {
            score += 40
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

        if hasAdvertisedRemoteDesktopService(device) {
            return false
        }

        guard device.supportsRemoteControl || device.remoteControlPort != nil else {
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

    private func hasAdvertisedRemoteDesktopService(_ device: DiscoveredDevice) -> Bool {
        remoteDesktopBonjourServiceIdentity(for: device) != nil
    }

    static func hasExplicitLANRemoteDesktopEndpoint(_ device: DiscoveredDevice) -> Bool {
        device.remoteControlPort != nil
            || device.services.contains(DiscoveredDevice.remoteControlServiceType)
            || device.bonjourServiceType == DiscoveredDevice.remoteControlServiceType
    }

    private func hasReachableLANRemoteDesktopEndpoint(_ device: DiscoveredDevice) -> Bool {
        if remoteDesktopBonjourServiceIdentity(for: device) != nil {
            return true
        }
        if peerAddressBackedRemoteDesktopAddress(for: device) != nil,
           device.remoteControlPort != nil {
            return true
        }
        return device.remoteControlPort != nil && bestIPAddress(for: device) != nil
    }

    private func canResolveLANRemoteDesktopEndpoint(for device: DiscoveredDevice) async -> Bool {
        if hasReachableLANRemoteDesktopEndpoint(device) {
            return true
        }

        if hasPeerAddressBackedRemoteDesktopFallback(for: device) {
            return true
        }

        if preferredRemoteDesktopServiceName(for: device) != nil {
            return true
        }

        if device.supportsRemoteControl {
            if bestIPAddress(for: device) != nil {
                return true
            }
            if preferredRemoteDesktopServiceName(for: device) != nil {
                return true
            }
            if await resolveRemoteDesktopIPAddress(for: device) != nil {
                return true
            }
        }

        return false
    }

    private func hasPeerAddressBackedRemoteDesktopFallback(for device: DiscoveredDevice) -> Bool {
        device.remoteControlPort != nil
            && peerAddressBackedRemoteDesktopAddress(for: device) != nil
    }

    private func peerAddressBackedRemoteDesktopAddress(for device: DiscoveredDevice) -> String? {
        let resolved = connectionManager.resolvedPeerDevice(for: device)
        let status = connectionManager.resolvedConnectionStatus(for: resolved)
            ?? connectionManager.resolvedConnectionStatus(for: device)
        guard status == .connected else {
            return nil
        }

        let candidate = resolved.platform == .macOS ? resolved : device
        guard candidate.platform == .macOS || candidate.supportsRemoteControl else {
            return nil
        }

        if let activePeerAddress = connectionManager.activePeerHostAddress(for: resolved),
           let sanitized = sanitizeAddress(activePeerAddress) {
            return sanitized
        }

        if let activePeerAddress = connectionManager.activePeerHostAddress(for: device),
           let sanitized = sanitizeAddress(activePeerAddress) {
            return sanitized
        }

        return nil
    }

    private func resolveRemoteDesktopIPAddress(for device: DiscoveredDevice) async -> String? {
        var candidates: [DiscoveredDevice] = []

        func append(_ candidate: DiscoveredDevice?) {
            guard let candidate else { return }
            if candidates.contains(where: { areEquivalentRemoteDesktopDevices($0, candidate) }) {
                return
            }
            candidates.append(candidate)
        }

        append(device)
        append(connectionManager.resolvedPeerDevice(for: device))
        append(DeviceDiscoveryManager.instance.canonicalDiscoveredDevice(for: device))
        append(Self.resolveBestRemoteDesktopDevice(
            target: device,
            discovered: deduplicatedRemoteDesktopCandidates(
                DeviceDiscoveryManager.instance.discoveredDevices
                    + P2PConnectionManager.instance.activeConnections.map(\.device)
            )
        ))

        for candidate in candidates {
            if let ip = bestIPAddress(for: candidate) {
                return ip
            }
            if let activePeerIP = connectionManager.activePeerHostAddress(for: candidate),
               let sanitized = sanitizeAddress(activePeerIP) {
                return sanitized
            }
            if let resolved = await DeviceDiscoveryManager.instance.resolveEndpoint(candidate),
               let sanitized = sanitizeAddress(resolved) {
                return sanitized
            }
        }

        return nil
    }

    public static func resolveBestRemoteDesktopDevice(
        target: DiscoveredDevice,
        discovered: [DiscoveredDevice]
    ) -> DiscoveredDevice {
        let targetScore = remoteDesktopResolutionScore(candidate: target, target: target)
        let bestCandidate = discovered.max { lhs, rhs in
            remoteDesktopResolutionScore(candidate: lhs, target: target)
                < remoteDesktopResolutionScore(candidate: rhs, target: target)
        }

        guard let bestCandidate else { return target }
        let bestScore = remoteDesktopResolutionScore(candidate: bestCandidate, target: target)
        return bestScore > targetScore ? bestCandidate : target
    }

    private static func remoteDesktopResolutionScore(
        candidate: DiscoveredDevice,
        target: DiscoveredDevice
    ) -> Int {
        let targetIdentity = normalizedRemoteDesktopIdentity(target.id)
        let candidateIdentity = normalizedRemoteDesktopIdentity(candidate.id)
        let exactIdMatch = !targetIdentity.isEmpty && targetIdentity == candidateIdentity
        let stableExactIdMatch = exactIdMatch && isStableRemoteDesktopIdentity(candidate.id)

        let targetIP = bestRemoteDesktopIPAddress(for: target)
        let candidateIP = bestRemoteDesktopIPAddress(for: candidate)
        let ipMatch = targetIP != nil && targetIP == candidateIP

        let targetBonjour = bonjourIdentityComponents(for: target)
        let candidateBonjour = bonjourIdentityComponents(for: candidate)
        let bonjourMatch = targetBonjour != nil && targetBonjour == candidateBonjour

        let targetName = normalizedRemoteDesktopDeviceName(target.name)
        let candidateName = normalizedRemoteDesktopDeviceName(candidate.name)
        let nameMatch = !targetName.isEmpty && targetName == candidateName

        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: target))
        let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
        let aliasMatch = !targetAliases.isEmpty && !candidateAliases.isDisjoint(with: targetAliases)

        guard exactIdMatch || ipMatch || bonjourMatch || nameMatch || aliasMatch else {
            return 0
        }

        var score = 0
        if stableExactIdMatch {
            score += 300
        } else if exactIdMatch {
            score += 80
        }
        if ipMatch { score += 250 }
        if bonjourMatch { score += 220 }
        if nameMatch { score += 160 }
        if aliasMatch { score += 260 }

        if candidate.services.contains(DiscoveredDevice.remoteControlServiceType)
            || candidate.bonjourServiceType == DiscoveredDevice.remoteControlServiceType {
            score += 260
        }
        if candidate.remoteControlPort != nil { score += 180 }
        if candidateIP != nil { score += 120 }
        if candidate.supportsRemoteControl { score += 60 }
        if !candidate.services.isEmpty { score += 40 }

        return score
    }

    private static func isStableRemoteDesktopIdentity(_ raw: String?) -> Bool {
        let normalized = normalizedRemoteDesktopIdentity(raw)
        guard !normalized.isEmpty else {
            return false
        }
        return !(normalized.hasPrefix("host:")
            || normalized.hasPrefix("peer:")
            || normalized.hasPrefix("bonjour:")
            || normalized.hasPrefix("recent:"))
    }

    private static func normalizedRemoteDesktopIdentity(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func normalizedRemoteDesktopDeviceName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static func bonjourIdentityComponents(for device: DiscoveredDevice) -> String? {
        let name = device.bonjourServiceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = device.bonjourServiceDomain?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            let normalizedDomain = (domain?.isEmpty == false ? domain! : "local.")
            return "\(name.lowercased())@\(normalizedDomain.lowercased())"
        }

        if let parsed = parseRemoteDesktopBonjourIdentity(from: device.id) {
            return "\(parsed.name.lowercased())@\(parsed.domain.lowercased())"
        }

        return nil
    }

    private static func parseRemoteDesktopBonjourIdentity(
        from identifier: String
    ) -> (name: String, domain: String)? {
        guard identifier.hasPrefix("bonjour:") else { return nil }
        let payload = String(identifier.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return (name, domain)
    }

    private static func bestRemoteDesktopIPAddress(for device: DiscoveredDevice) -> String? {
        sanitizeRemoteDesktopAddress(device.ipAddress)
            ?? sanitizeRemoteDesktopAddress(addressFromRemoteDesktopIdentifier(device.id))
    }

    private static func addressFromRemoteDesktopIdentifier(_ identifier: String) -> String? {
        if identifier.hasPrefix("host:") {
            return String(identifier.dropFirst("host:".count))
        }
        if identifier.hasPrefix("peer:") {
            return String(identifier.dropFirst("peer:".count))
        }
        return nil
    }

    private static func sanitizeRemoteDesktopAddress(_ raw: String?) -> String? {
        ConnectableAddressCanonicalizer.lookupKey(raw)
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
        ConnectableAddressCanonicalizer.connectionTarget(raw)
    }

    private func clearLANSecureChannelState() async {
        if let lanHandshakeTransport, let lanHandshakePeerId {
            await lanHandshakeTransport.removeConnection(for: lanHandshakePeerId)
        }
        lanHandshakeDriver = nil
        lanSessionKeys = nil
        lanHandshakePeerId = nil
        lanHandshakeTransport = nil
    }

    private func ensureLANRemoteControlTrustBootstrap(
        for device: DiscoveredDevice
    ) async throws {
        guard !shouldUseCrossNetworkTransport(for: device) else {
            return
        }

        let bootstrapDevice = connectionManager.resolvedPeerDevice(for: device)
        let bootstrapPeerId = bootstrapDevice.id
        let bootstrapStatus = connectionManager.resolvedConnectionStatus(for: bootstrapDevice)

        if bootstrapStatus != .connected {
            SkyBridgeLogger.shared.info(
                "🧩 LAN 远控前置 bootstrap：先建立通用 P2P 会话以同步 authority peer=\(bootstrapPeerId)"
            )
            try await connectionManager.connect(to: bootstrapDevice)
        }

        let resolvedBootstrapPeer = connectionManager.resolvedPeerDevice(for: bootstrapDevice)
        let observedAt = Date()
        try await connectionManager.sendPairingIdentityExchange(to: resolvedBootstrapPeer.id)

        let observedReply = await connectionManager.waitForPairingIdentityExchangeActivity(
            with: resolvedBootstrapPeer.id,
            since: observedAt,
            timeout: .seconds(8)
        )
        let bootstrapReady = await connectionManager.waitForPairingIdentityExchangeBootstrapReadiness(
            with: resolvedBootstrapPeer.id,
            since: observedAt,
            timeout: .seconds(8)
        )
        if bootstrapReady {
            SkyBridgeLogger.shared.info(
                "🧩 LAN 远控前置 bootstrap 完成：reply=\(observedReply) ready=\(bootstrapReady) peer=\(resolvedBootstrapPeer.id)"
            )
        } else {
            SkyBridgeLogger.shared.info(
                "🧩 LAN 远控前置 bootstrap：未在超时内完成 metadata/KEM 就绪，继续远控握手 peer=\(resolvedBootstrapPeer.id)"
            )
            try? await Task.sleep(for: .milliseconds(600))
        }
    }

    private func establishLANSecureChannel(
        for device: DiscoveredDevice,
        over connection: NWConnection
    ) async throws {
        let trustedPeerId = try resolveTrustedLANPeerIdentifier(for: device)
        let trustedAuthority = try resolveTrustedRemoteAuthority(
            for: device,
            trustedPeerId: trustedPeerId
        )
        let trustProvider = LANHandshakeTrustProvider(
            expectedRemoteAuthority: trustedAuthority,
            fallbackPeerIDs: Array(
                LANRemoteControlTrustResolver.candidateAliases(for: device, trustedPeerId: trustedPeerId)
            )
        )

        try await skyBridgeCore.initialize(policy: .preferPQC)

        let transport = NWConnectionTransport()
        await transport.setConnection(connection, for: trustedPeerId)
        lanHandshakeTransport = transport
        lanHandshakePeerId = trustedPeerId
        lanSessionKeys = nil
        lanHandshakeDriver = nil

        let localDeviceId = resolvedLocalRemoteControlDeviceId()
        guard let localSOAPeerId = Self.remoteControlSOAPeerId(for: localDeviceId),
              let expectedRemoteSOAPeerId = Self.remoteControlSOAPeerId(for: trustedPeerId),
              let soaMetadata = try? HandshakeSOAMetadata(
                initiatorPeerId: localSOAPeerId,
                targetPeerId: expectedRemoteSOAPeerId,
                attemptId: Self.randomRemoteControlAttemptId()
              ) else {
            throw RemoteDesktopError.connectionFailed("LAN 远控缺少稳定身份，无法建立安全通道")
        }

        let connectionID = ObjectIdentifier(connection)
        let keys = try await skyBridgeCore.performHandshake(
            deviceId: trustedPeerId,
            transport: transport,
            preferPQC: true,
            soaMetadata: soaMetadata,
            localSOAPeerId: localSOAPeerId,
            expectedRemoteSOAPeerId: expectedRemoteSOAPeerId,
            trustProvider: trustProvider,
            onDriverCreated: { driver in
                await MainActor.run {
                    RemoteDesktopManager.instance.installLANHandshakeDriver(
                        driver,
                        forConnectionID: connectionID,
                        peerId: trustedPeerId
                    )
                }
            }
        )

        try ensureLANBootstrapStillActive(for: connection)
        lanSessionKeys = keys
        lanHandshakeDriver = nil
        transportStatusText = currentTransportStatusText()
        SkyBridgeLogger.shared.info(
            "🔐 LAN 远控安全通道已建立: peer=\(trustedPeerId) suite=\(keys.negotiatedSuite.rawValue)"
        )
    }

    private func installLANHandshakeDriver(
        _ driver: HandshakeDriver,
        forConnectionID connectionID: ObjectIdentifier,
        peerId: String
    ) {
        guard let current = networkConnection,
              ObjectIdentifier(current) == connectionID else {
            return
        }
        lanHandshakeDriver = driver
        lanHandshakePeerId = peerId
    }

    private func syncLANSecureChannelState(
        after driver: HandshakeDriver,
        forConnectionID connectionID: ObjectIdentifier
    ) async throws {
        guard let current = networkConnection,
              ObjectIdentifier(current) == connectionID else {
            return
        }

        switch await driver.getCurrentState() {
        case .established(let keys):
            lanSessionKeys = keys
            lanHandshakeDriver = nil
            transportStatusText = currentTransportStatusText()
            SkyBridgeLogger.shared.info(
                "🔐 LAN 远控握手完成: peer=\(lanHandshakePeerId ?? "-") suite=\(keys.negotiatedSuite.rawValue)"
            )
        case .failed(let reason):
            throw RemoteDesktopError.connectionFailed("LAN 远控握手失败: \(String(describing: reason))")
        default:
            break
        }
    }

    private func unwrapLANInboundPayload(
        _ data: Data,
        from connection: NWConnection
    ) async throws -> Data? {
        guard activeTransportMode == .lan else { return data }

        if let lanSessionKeys {
            return try decryptLANPayload(data, with: lanSessionKeys)
        }

        guard let lanHandshakeDriver, let lanHandshakePeerId else {
            throw RemoteDesktopError.connectionFailed("收到未认证的 LAN 远控帧")
        }

        await lanHandshakeDriver.handleMessage(data, from: PeerIdentifier(deviceId: lanHandshakePeerId))
        try await syncLANSecureChannelState(
            after: lanHandshakeDriver,
            forConnectionID: ObjectIdentifier(connection)
        )
        return nil
    }

    private func encryptLANPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw RemoteDesktopError.streamingFailed("LAN 远控加密失败")
        }
        return combined
    }

    private func decryptLANPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    private func resolveTrustedLANPeerIdentifier(for device: DiscoveredDevice) throws -> String {
        switch LANRemoteControlTrustResolver.resolve(
            device: device,
            trustedPeerId: device.id,
            trustedDevices: TrustedDeviceStore.shared.trustedDevices
        ) {
        case .resolved(_, let canonicalPeerId):
            return PeerIdentityAliasResolver.persistentDeviceId(from: canonicalPeerId) ?? canonicalPeerId
        case .missing:
            throw RemoteDesktopError.connectionFailed("远控目标未建立受信任身份")
        case .ambiguous(let deviceIds, let fingerprints):
            let summary = [
                "deviceIds=\(deviceIds.joined(separator: ","))",
                "fingerprints=\(fingerprints.joined(separator: ","))"
            ].joined(separator: " ")
            throw RemoteDesktopError.connectionFailed("远控目标匹配到多条受信任身份记录: \(summary)")
        }
    }

    private func resolveTrustedRemoteAuthority(
        for device: DiscoveredDevice,
        trustedPeerId: String
    ) throws -> CurrentPathRemoteAuthority {
        let record: TrustedDeviceStore.TrustedDevice
        let deviceId: String
        switch LANRemoteControlTrustResolver.resolve(
            device: device,
            trustedPeerId: trustedPeerId,
            trustedDevices: TrustedDeviceStore.shared.trustedDevices
        ) {
        case .resolved(let matchedRecord, let canonicalPeerId):
            record = matchedRecord
            deviceId = canonicalPeerId
        case .missing:
            throw RemoteDesktopError.connectionFailed("远控目标缺少受信任指纹")
        case .ambiguous(let deviceIds, let fingerprints):
            let summary = [
                "deviceIds=\(deviceIds.joined(separator: ","))",
                "fingerprints=\(fingerprints.joined(separator: ","))"
            ].joined(separator: " ")
            throw RemoteDesktopError.connectionFailed("远控目标受信任指纹映射不唯一: \(summary)")
        }

        guard let fingerprint = record.protocolPublicKeyFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fingerprint.isEmpty else {
            throw RemoteDesktopError.connectionFailed("远控目标缺少受信任指纹")
        }

        return CurrentPathRemoteAuthority(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: fingerprint.lowercased()
        )
    }

    private func resolvedLocalRemoteControlDeviceId() -> String {
        let rawDeviceId = KeychainManager.shared.getOrGenerateDeviceId()
        return PeerIdentityAliasResolver.persistentDeviceId(from: rawDeviceId) ?? rawDeviceId
    }

    private static func remoteControlSOAPeerId(for identifier: String?) -> Data? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        let persistentIdentifier = PeerIdentityAliasResolver.persistentDeviceId(from: identifier) ?? identifier
        var normalized = persistentIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") {
            normalized.removeFirst(3)
        }
        guard !normalized.isEmpty else { return nil }
        return Data(SHA256.hash(data: Data(normalized.utf8)))
    }

    private static func randomRemoteControlAttemptId() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }
    
    // MARK: - Private Methods - Connection
    
    private func createConnection(toAnyOf endpoints: [NWEndpoint]) async throws -> NWConnection {
        guard !endpoints.isEmpty else {
            throw RemoteDesktopError.connectionFailed("设备缺少可连接地址（Bonjour/IP）")
        }

        var lastError: Error?
        let perEndpointTimeout: TimeInterval
        if endpoints.count > 1 {
            perEndpointTimeout = RemoteDesktopConstants.candidateConnectionTimeout
        } else {
            perEndpointTimeout = RemoteDesktopConstants.connectionTimeout
        }

        for (index, endpoint) in endpoints.enumerated() {
            let endpointDescription = String(describing: endpoint)
            SkyBridgeLogger.shared.info(
                "🔗 LAN 远控连接候选[\(index + 1)/\(endpoints.count)]: endpoint=\(endpointDescription)"
            )

            do {
                let connection = try await createConnection(to: endpoint, timeout: perEndpointTimeout)
                SkyBridgeLogger.shared.info(
                    "✅ LAN 远控连接就绪: endpoint=\(endpointDescription)"
                )
                return connection
            } catch {
                lastError = error
                SkyBridgeLogger.shared.warning(
                    "⚠️ LAN 远控候选连接失败[\(index + 1)/\(endpoints.count)]: endpoint=\(endpointDescription) error=\(error.localizedDescription)"
                )
            }
        }

        if let lastError {
            throw lastError
        }
        throw RemoteDesktopError.connectionFailed("所有 LAN 远控端点均不可用")
    }

    private func createConnection(
        to endpoint: NWEndpoint,
        timeout: TimeInterval = RemoteDesktopConstants.connectionTimeout
    ) async throws -> NWConnection {
        let endpointDescription = String(describing: endpoint)
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
                case .waiting(let error):
                    SkyBridgeLogger.shared.warning(
                        "⏳ LAN 远控连接等待: endpoint=\(endpointDescription) error=\(error.localizedDescription)"
                    )
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
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.runOnce {
                    connection.stateUpdateHandler = nil
                    SkyBridgeLogger.shared.error(
                        "❌ LAN 远控连接超时: endpoint=\(endpointDescription) timeout=\(Int(timeout))s"
                    )
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

        let plaintext = try JSONEncoder().encode(message)
        if plaintext.count > maxMessageBytes {
            throw RemoteDesktopError.streamingFailed("消息过大：\(plaintext.count) bytes")
        }
        guard let lanSessionKeys else {
            throw RemoteDesktopError.connectionFailed("LAN 远控安全通道尚未建立")
        }
        let payload = try encryptLANPayload(plaintext, with: lanSessionKeys)
        if payload.count > maxLANWireMessageBytes {
            throw RemoteDesktopError.streamingFailed("加密后的消息过大：\(payload.count) bytes")
        }

        var length = UInt32(payload.count).bigEndian
        var framedData = Data(bytes: &length, count: 4)
        framedData.append(payload)
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrentLANConnection(connection) else { return }

                if let error = error {
                    await self.handleTransportFailure(error.localizedDescription)
                    return
                }

                guard let lengthData = data, lengthData.count == 4 else {
                    if isComplete {
                        await self.handleTransportFailure(
                            RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                        )
                        return
                    }
                    self.receiveNextMessage(from: connection)
                    return
                }

                let length = Int(lengthData.withUnsafeBytes { raw -> UInt32 in
                    raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
                })
                if length <= 0 || length > self.maxLANWireMessageBytes {
                    await self.handleTransportFailure("消息长度异常：\(length) bytes")
                    return
                }

                self.receiveMessageBody(of: length, from: connection)
            }
        }
    }

    private func receiveMessageBody(of length: Int, from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] messageData, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrentLANConnection(connection) else { return }

                if let error = error {
                    await self.handleTransportFailure(error.localizedDescription)
                    return
                }

                guard let data = messageData else {
                    if isComplete {
                        await self.handleTransportFailure(
                            RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                        )
                    } else {
                        self.receiveMessageBody(of: length, from: connection)
                    }
                    return
                }

                do {
                    let payload = try await self.unwrapLANInboundPayload(data, from: connection)
                    guard let payload else {
                        self.receiveNextMessage(from: connection)
                        return
                    }

                    if let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(payload) {
                        self.handleInboundRemoteAudioChunk(audioChunk)
                    } else if let screenData = RemoteDesktopScreenFrameWire.decodeIfPresent(payload) {
                        await self.handleScreenData(screenData)
                    } else {
                        let message = try JSONDecoder().decode(RemoteMessage.self, from: payload)
                        switch message.type {
                        case .screenData:
                            let screenData = try JSONDecoder().decode(ScreenData.self, from: message.payload)
                            await self.handleScreenData(screenData)
                        case .clipboard:
                            let payload = try JSONDecoder().decode(RemoteClipboardMessagePayload.self, from: message.payload)
                            self.handleInboundRemoteClipboard(
                                data: payload.data,
                                mimeType: payload.mimeType,
                                fromDeviceId: self.currentConnection?.device.id
                            )
                        case .damageReport:
                            let report = try JSONDecoder().decode(RemoteDesktopDamageReportPayload.self, from: message.payload)
                            self.handleInboundDamageReport(report)
                        case .cursorUpdate:
                            let payload = try JSONDecoder().decode(RemoteDesktopCursorPayload.self, from: message.payload)
                            self.handleInboundCursorUpdate(payload)
                        case .overlayUpdate:
                            let payload = try JSONDecoder().decode(RemoteDesktopOverlayPayload.self, from: message.payload)
                            self.handleInboundOverlayUpdate(payload)
                        case .streamConfigurationAck:
                            let ack = try JSONDecoder().decode(RemoteDesktopStreamConfigurationAckPayload.self, from: message.payload)
                            self.handleStreamConfigurationAck(ack)
                        case .mouseEvent, .keyboardEvent, .streamConfiguration:
                            break
                        }
                    }
                } catch let error as RemoteDesktopError {
                    await self.handleTransportFailure(error.localizedDescription)
                    return
                } catch {
                    SkyBridgeLogger.shared.error("❌ 解析消息失败: \(error.localizedDescription)")
                }

                self.receiveNextMessage(from: connection)
            }
        }
    }
    
    private func handleScreenData(_ screenData: ScreenData) async {
        if strictCrossNetworkMediaValidationActive {
            let reason = "strict media validation failed: fallback screen frame received"
            SkyBridgeLogger.shared.error(
                "⛔️ WebRTC strict media validation failed on viewer: reason=fallback-screen-frame-received size=\(screenData.width)x\(screenData.height) format=\(screenData.format ?? "unknown")"
            )
            SkyBridgeSmokeTraceWriter.appendStatus(
                "strict-media-failed session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") reason=fallback-screen-frame-received format=\(screenData.format ?? "unknown") size=\(screenData.width)x\(screenData.height)"
            )
            await handleTransportFailure(reason)
            return
        }
        let hasRemoteNativeVideoTrack: Bool
#if canImport(WebRTC)
        hasRemoteNativeVideoTrack = crossNetwork.remoteVideoTrack != nil
#else
        hasRemoteNativeVideoTrack = false
#endif
        if Self.shouldDropNativeWarmupNonJPEGFallbackFrame(
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            hasRemoteNativeVideoTrack: hasRemoteNativeVideoTrack,
            nativeVideoTrackHasRenderedFrame: crossNetwork.remoteVideoTrackHasRenderedFrame,
            format: screenData.format
        ) {
            let now = Date()
            if now.timeIntervalSince(lastNativeWarmupNonJPEGFallbackDropDiagnosticAt) >= 1.0 {
                lastNativeWarmupNonJPEGFallbackDropDiagnosticAt = now
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC native warmup dropped non-JPEG fallback before viewer topology/decode: \(screenData.width)x\(screenData.height) format=\(screenData.format ?? "unknown") dropReason=native-warmup-non-jpeg-fallback"
                )
                SkyBridgeSmokeTraceWriter.appendStatus(
                    "screen-drop session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") dropReason=native-warmup-non-jpeg-fallback format=\(screenData.format ?? "unknown") size=\(screenData.width)x\(screenData.height)"
                )
            }
            return
        }
        if Self.shouldIgnoreFallbackFrameAfterNativeVideoRendered(
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            nativeVideoTrackHasRenderedFrame: crossNetwork.remoteVideoTrackHasRenderedFrame
        ) {
            let now = Date()
            noteReceivedFrame(at: now)
            if now.timeIntervalSince(lastNativePrimaryIgnoredFallbackDiagnosticAt) >= 1.0 {
                lastNativePrimaryIgnoredFallbackDiagnosticAt = now
                SkyBridgeLogger.shared.debug(
                    "ℹ️ 忽略 native WebRTC 主链期间的 fallback screen frame: \(screenData.width)x\(screenData.height) format=\(screenData.format ?? "unknown")"
                )
            }
            return
        }
        let now = Date()
        let isFirstFrameInStream = !hasReceivedFrameInCurrentStream
        noteReceivedFrame(at: now)
        lastInboundScreenTimestamp = screenData.timestamp
        if isFirstFrameInStream {
            hasReceivedFrameInCurrentStream = true
            streamConfigurationAckSatisfied = true
            streamConfigurationAckTask?.cancel()
            streamConfigurationAckTask = nil
            configureSessionClipboardSync()
            SkyBridgeLogger.shared.info(
                "✅ 收到首帧: \(screenData.width)x\(screenData.height), format=\(screenData.format ?? "unknown"), bytes=\(screenData.imageData.count)"
            )
            scheduleFirstFrameContinuityCheck(for: streamEpoch, firstFrameAt: now)
        } else {
            firstFrameContinuityTask?.cancel()
            firstFrameContinuityTask = nil
        }
        await handleIncomingStreamTopologyChangeIfNeeded(for: screenData)
        let frameResolution = CGSize(width: screenData.width, height: screenData.height)
        let didChangeResolution = resolution != frameResolution
        if didChangeResolution {
            resolution = frameResolution
        }
        if activeTransportMode == .crossNetwork, isFirstFrameInStream || didChangeResolution {
            crossNetwork.noteRemoteVideoTrackResolutionAvailable(
                frameResolution,
                source: "fallback-screen-data"
            )
        }

        if isFirstFrameInStream || now.timeIntervalSince(lastLatencyPublishAt) >= latencyPublishInterval {
            latency = (now.timeIntervalSince1970 - screenData.timestamp) * 1000
            lastLatencyPublishAt = now
        }
        
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
            lastStreamTopologyRefreshSignature = nil
            streamTopologyFlapCount = 0
            streamTopologyFlapSuppressedUntil = .distantPast
            return
        }

        guard previousSignature != newSignature else { return }
        lastIncomingStreamSignature = newSignature
        let now = Date()
        let recentTopologyChange = now.timeIntervalSince(lastStreamTopologyChangeAt) < 2.0
        let isFallbackProducerFormatSwap =
            (previousSignature.format == "jpeg" && newSignature.format == "hevc")
            || (previousSignature.format == "hevc" && newSignature.format == "jpeg")
            || (previousSignature.format == "jpeg" && newSignature.format == "h264")
            || (previousSignature.format == "h264" && newSignature.format == "jpeg")
        let nearlySameDimensions =
            abs(previousSignature.width - newSignature.width) <= 2
            && abs(previousSignature.height - newSignature.height) <= 2
        let isFallbackProducerFlap = isFallbackProducerFormatSwap
            && (recentTopologyChange || nearlySameDimensions || now < streamTopologyFlapSuppressedUntil)
        lastStreamTopologyChangeAt = now

        if isFallbackProducerFlap {
            streamTopologyFlapCount += 1
            streamTopologyFlapSuppressedUntil = now.addingTimeInterval(10)
        } else if now >= streamTopologyFlapSuppressedUntil {
            streamTopologyFlapCount = 0
        }

        let incomingFrameIsIndependent = RemoteDesktopScreenFrameWire.containsSyncFrame(
            format: screenData.format,
            imageData: screenData.imageData,
            advertisedSyncFrame: screenData.isSyncFrame
        )
        let lightweightFlapTransition = isFallbackProducerFlap && incomingFrameIsIndependent

        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(normalizedFormat)
            && !incomingFrameIsIndependent
        consecutiveDecodeMisses = 0
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false

        if lightweightFlapTransition {
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC fallback producer flap suppressed: \(previousSignature.format) \(previousSignature.width)x\(previousSignature.height) -> \(newSignature.format) \(newSignature.width)x\(newSignature.height) count=\(streamTopologyFlapCount)"
            )
        } else {
            invalidateDecodePipelineState()
            decodedVideoRendererPreference = preferredDecodedVideoRenderer()
            frameRate = 0
            lastRenderedFrameTime = nil
            metalAwaitingFirstDisplaySince = nil
            flushRenderedVideoFeeds()
            updateRenderPipeline(.waiting)
            await decoder.markStreamDisrupted(
                format: normalizedFormat,
                width: screenData.width,
                height: screenData.height
            )
        }

        let canRequestRefresh = lastRefreshRequestAt.map { now.timeIntervalSince($0) >= 2.0 } ?? true
        let topologyRefreshSuppressed = isFallbackProducerFlap
            || now < streamTopologyFlapSuppressedUntil
            || lastStreamTopologyRefreshSignature == newSignature
        if canRequestRefresh && !topologyRefreshSuppressed {
            lastRefreshRequestAt = now
            lastStreamTopologyRefreshSignature = newSignature
            lastRequestedStreamRefreshReason = "stream-topology-changed"
            await pushViewerStreamConfiguration(force: true, refreshStream: true)
        }

        if lightweightFlapTransition {
            SkyBridgeLogger.shared.info(
                "🔄 WebRTC fallback producer transition: \(previousSignature.format) \(previousSignature.width)x\(previousSignature.height) -> \(newSignature.format) \(newSignature.width)x\(newSignature.height) decoderReset=false refresh=false"
            )
        } else {
            SkyBridgeLogger.shared.info(
                "🔄 远控视频流拓扑变化: \(previousSignature.format) \(previousSignature.width)x\(previousSignature.height) -> \(newSignature.format) \(newSignature.width)x\(newSignature.height)"
            )
        }
    }

    private func enqueueFrameForDecode(_ screenData: ScreenData) {
        let enqueueResult = RemoteDesktopDecodeQueuePolicy.enqueue(
            screenData,
            into: &pendingFrames,
            waitingForSyncFrame: &decodeQueueWaitingForSyncFrame
        )
        if enqueueResult == .enteredWaitingForSync {
            let now = Date()
            if now.timeIntervalSince(lastDecodeQueueOverflowLogTime) >= 1.0 {
                lastDecodeQueueOverflowLogTime = now
                SkyBridgeLogger.shared.warning(
                    "⚠️ 视频解码队列拥塞，已清空预测帧并等待关键帧恢复"
                )
            }
            Task { @MainActor [weak self] in
                await self?.requestStreamRefreshIfNeeded(reason: "decode-queue-overflow", minimumInterval: 0.25)
            }
        } else if enqueueResult == .droppedIncomingPredictiveFrame {
            let now = Date()
            if now.timeIntervalSince(lastDecodeQueueOverflowLogTime) >= 1.0 {
                lastDecodeQueueOverflowLogTime = now
                SkyBridgeLogger.shared.warning(
                    "⚠️ 视频解码队列正在等待关键帧，已暂时丢弃预测帧"
                )
            }
        } else if enqueueResult == .recoveredWithIndependentFrame {
            if let token = lastRequestedStreamRefreshToken,
               let requestedAt = lastRequestedStreamRefreshAt {
                let waitMs = Int((Date().timeIntervalSince(requestedAt) * 1000).rounded())
                SkyBridgeLogger.shared.info(
                    "♻️ viewer 已收到恢复关键帧: token=\(token) reason=\(lastRequestedStreamRefreshReason ?? "unspecified") waitMs=\(waitMs) transport=\(activeTransportModeLabel())"
                )
                lastRequestedStreamRefreshToken = nil
                lastRequestedStreamRefreshReason = nil
                lastRequestedStreamRefreshAt = nil
                lastRefreshRequestFailureDescription = nil
                hevcDisableRefreshTokenInFlight = nil
                lastWaitingSyncDiagnosticLogTime = .distantPast
            }
            SkyBridgeLogger.shared.info("♻️ 视频解码队列已收到关键帧，恢复连续解码")
        }
        startDecodeLoopIfNeeded()
    }

    private func requestStreamRefreshIfNeeded(
        reason: String = "unspecified",
        minimumInterval: TimeInterval = 0.5
    ) async {
        guard !handleCrossNetworkSessionAuthorityLostIfNeeded(source: "stream-refresh:\(reason)") else {
            return
        }
        let now = Date()
        let canRequestRefresh = lastRefreshRequestAt.map { now.timeIntervalSince($0) >= minimumInterval } ?? true
        guard canRequestRefresh else { return }
        lastRefreshRequestAt = now
        lastRequestedStreamRefreshReason = reason
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
            await requestStreamRefreshIfNeeded(reason: "codec-governance-request")
            return false
        case .disableHEVC(let until):
            if let suppressedUntil = hevcDisableRefreshSuppressedUntil,
               suppressedUntil > now {
                let remaining = max(1, Int(suppressedUntil.timeIntervalSince(now).rounded(.up)))
                let tokenLabel = hevcDisableRefreshTokenInFlight.map(String.init) ?? "-"
                SkyBridgeLogger.shared.debug(
                    "ℹ️ HEVC 降级冷却仍有效，跳过重复 codec-governance 刷新: remaining=\(remaining)s token=\(tokenLabel)"
                )
                return true
            }
            hevcDisableRefreshSuppressedUntil = until
            invalidateDecodePipelineState()
            pendingFrames.removeAll(keepingCapacity: true)
            decodeQueueWaitingForSyncFrame = true
            await decoder.resetPreservingLastFrame()
            lastDecoderResetTime = now
            consecutiveDecodeMisses = 0
            lastRequestedStreamRefreshReason = "codec-governance-disable-hevc"
            lastRefreshRequestAt = now
            await pushViewerStreamConfiguration(force: true, refreshStream: true)
            hevcDisableRefreshTokenInFlight = lastRequestedStreamRefreshToken
            let remaining = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
            SkyBridgeLogger.shared.warning(
                "⚠️ HEVC 解码连续失败，已临时降级到 H.264（冷却 \(remaining)s 后再自动探测恢复）"
            )
            return true
        case .reenableHEVCProbe:
            hevcDisableRefreshSuppressedUntil = nil
            hevcDisableRefreshTokenInFlight = nil
            await requestStreamRefreshIfNeeded(reason: "codec-governance-reenable-hevc", minimumInterval: 1.0)
            SkyBridgeLogger.shared.info("♻️ H.264 回退流已稳定，准备重新探测 HEVC")
            return false
        }
    }

    private func noteFrameProgress(at now: Date) {
        lastRenderedFrameTime = now
        if let lastFrameTime {
            frameCount += 1
            let elapsed = now.timeIntervalSince(lastFrameTime)
            if elapsed >= 1.0 {
                frameRate = Double(frameCount) / elapsed
                frameCount = 0
                self.lastFrameTime = now
            }
        } else {
            frameCount = 1
            lastFrameTime = now
            frameRate = 0
        }
    }

    private func noteReceivedFrame(at now: Date) {
        lastFrameArrivalAt = now
        receivedFrameCountInCurrentStream += 1
        receivedFramesInStatsWindow += 1
        logRemoteDesktopPipelineStatsIfNeeded(at: now)
    }

    private func noteDecodedFrame(at now: Date) {
        lastDecodedFrameTime = now
        decodedFramesInStatsWindow += 1
        logRemoteDesktopPipelineStatsIfNeeded(at: now)
    }

    private func noteVideoRendererEnqueuedFrame(at now: Date) {
        lastVideoRendererEnqueueAt = now
        rendererEnqueuedFramesInStatsWindow += 1
        if renderPipelineStatus == .sampleBufferDisplayLayer {
            consecutiveSampleBufferNoEnqueueWindows = 0
            consecutiveSampleBufferDisplayStalls = 0
        }
        noteFrameProgress(at: now)
    }

    private func noteDisplayedFrame(at now: Date) {
        lastDisplayedFrameTime = now
        displayedFramesInStatsWindow += 1
        logRemoteDesktopPipelineStatsIfNeeded(at: now)
        noteFrameProgress(at: now)
    }

    private func logRemoteDesktopPipelineStatsIfNeeded(at now: Date) {
        guard state == .streaming else { return }
        guard let statsWindowStartTime else {
            self.statsWindowStartTime = now
            return
        }
        let elapsed = now.timeIntervalSince(statsWindowStartTime)
        guard elapsed >= 1.0 else { return }
        if decodeQueueWaitingForSyncFrame,
           let token = lastRequestedStreamRefreshToken,
           let requestedAt = lastRequestedStreamRefreshAt,
           now.timeIntervalSince(requestedAt) >= 1.0,
           now.timeIntervalSince(lastWaitingSyncDiagnosticLogTime) >= 1.0 {
            lastWaitingSyncDiagnosticLogTime = now
            let waitMs = Int((now.timeIntervalSince(requestedAt) * 1000).rounded())
            let failureSuffix = lastRefreshRequestFailureDescription.map { " refreshErr=\($0)" } ?? ""
            SkyBridgeLogger.shared.warning(
                "⚠️ viewer 关键帧恢复仍在等待: token=\(token) reason=\(lastRequestedStreamRefreshReason ?? "unspecified") waitMs=\(waitMs) recv=\(receivedFramesInStatsWindow) decode=\(decodedFramesInStatsWindow) display=\(displayedFramesInStatsWindow) probable=missing-keyframe transport=\(activeTransportModeLabel()) summary=\(crossNetwork.remoteDesktopRecoveryDebugSummary())\(failureSuffix)"
            )
        }
        if renderPipelineStatus == .sampleBufferDisplayLayer,
           decodedFramesInStatsWindow > 0 {
            if rendererEnqueuedFramesInStatsWindow == 0 {
                consecutiveSampleBufferNoEnqueueWindows += 1
                Task { @MainActor [weak self] in
                    await self?.handleStreamContinuityStall(reason: "sample-buffer-no-enqueue")
                }
            } else {
                consecutiveSampleBufferNoEnqueueWindows = 0
            }
        }
        let videoRenderAgeMs = lastInboundScreenTimestamp.map {
            Int(max(0, now.timeIntervalSince1970 - $0) * 1_000)
        }
        SkyBridgeLogger.shared.debug(
            "📈 远控链路统计: recv=\(receivedFramesInStatsWindow) decode=\(decodedFramesInStatsWindow) enqueue=\(rendererEnqueuedFramesInStatsWindow) display=\(displayedFramesInStatsWindow) pending=\(pendingFrames.count) inflight=\(inFlightDecodeCount) waitingSync=\(decodeQueueWaitingForSyncFrame) pipeline=\(renderPipelineStatus.rawValue) videoRenderAgeMs=\(videoRenderAgeMs.map(String.init) ?? "-")"
        )
        self.statsWindowStartTime = now
        receivedFramesInStatsWindow = 0
        decodedFramesInStatsWindow = 0
        rendererEnqueuedFramesInStatsWindow = 0
        displayedFramesInStatsWindow = 0
    }

    private func shouldAcceptDecodedFrame(presentationTimeStamp: CMTime) -> Bool {
        guard presentationTimeStamp.flags.contains(.valid) else { return true }
        if let lastAcceptedDecodedPresentationTimeStamp,
           lastAcceptedDecodedPresentationTimeStamp.flags.contains(.valid),
           CMTimeCompare(presentationTimeStamp, lastAcceptedDecodedPresentationTimeStamp) <= 0 {
            return false
        }
        lastAcceptedDecodedPresentationTimeStamp = presentationTimeStamp
        return true
    }

    private func completeDecodeTask(for generation: UInt64) {
        guard generation == decodeGeneration else { return }
        inFlightDecodeCount = max(0, inFlightDecodeCount - 1)
    }

    private func maxConcurrentDecodeTasks(for screenData: ScreenData) -> Int {
        RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(screenData.format)
            ? maxConcurrentVideoDecodes
            : 1
    }

    private func activateSampleBufferFallbackForDecodedVideo(reason: String) {
        guard decodedVideoRendererPreference != .sampleBuffer else { return }
        let now = Date()
        if let lastMetalFallbackAt, now.timeIntervalSince(lastMetalFallbackAt) < 5 {
            metalRestoreFailureCount += 1
        } else {
            metalRestoreFailureCount = 1
        }
        if metalRestoreFailureCount >= metalFallbackPersistentFailureThreshold {
            metalRestoreSuppressedUntil = now.addingTimeInterval(metalFallbackPersistentFailureCooldown)
            let cooldownMs = Int(metalFallbackPersistentFailureCooldown * 1000)
            SkyBridgeLogger.shared.warning(
                "⚠️ Metal restore repeated failures suppressed: reason=\(reason) failures=\(metalRestoreFailureCount) cooldownMs=\(cooldownMs)"
            )
        }
        decodedVideoRendererPreference = .sampleBuffer
        metalAwaitingFirstDisplaySince = nil
        lastMetalFallbackAt = now
        metalFallbackReason = reason
        stableSampleBufferFramesSinceMetalFallback = 0
        consecutiveSampleBufferNoEnqueueWindows = 0
        consecutiveSampleBufferDisplayStalls = 0
        metalVideoFrameFeed.flush(removeDisplayedImage: false)
        if currentFrame == nil, let lastGoodFrozenFrame {
            currentFrame = lastGoodFrozenFrame
        }
        updateRenderPipeline(.sampleBufferDisplayLayer)
        SkyBridgeLogger.shared.warning(
            "⚠️ Metal 渲染未消费新帧，已立即回退到 AVSampleBufferDisplayLayer: reason=\(reason) restoreProbeMs=\(Int(metalFallbackRestoreCooldown * 1000)) expectedRestoreMs=\(Int(metalFallbackExpectedRestoreWindow * 1000)) failures=\(metalRestoreFailureCount)"
        )
    }

    private func activateCGImageFallbackForDecodedVideo() {
        guard decodedVideoRendererPreference != .cgImage else { return }
        decodedVideoRendererPreference = .cgImage
        metalAwaitingFirstDisplaySince = nil
        lastMetalFallbackAt = nil
        metalFallbackReason = nil
        stableSampleBufferFramesSinceMetalFallback = 0
        consecutiveSampleBufferNoEnqueueWindows = 0
        consecutiveSampleBufferDisplayStalls = 0
        flushRenderedVideoFeeds(removeDisplayedImage: true)
        if let lastGoodFrozenFrame {
            currentFrame = lastGoodFrozenFrame
        }
        updateRenderPipeline(.stillImageFallback)
        SkyBridgeLogger.shared.warning("⚠️ 视频渲染层未消费新帧，已回退到逐帧 CGImage 渲染")
    }

    private func maybeRestoreMetalRendererAfterStableSampleBuffer(at now: Date) async {
        guard preferredDecodedVideoRenderer() == .metal else { return }
        guard decodedVideoRendererPreference == .sampleBuffer else { return }
        guard renderPipelineStatus == .sampleBufferDisplayLayer else { return }
        guard RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(lastIncomingStreamSignature?.format) else {
            return
        }
        guard let lastMetalFallbackAt else { return }
        guard now.timeIntervalSince(lastMetalFallbackAt) >= metalFallbackRestoreCooldown else { return }
        if let suppressedUntil = metalRestoreSuppressedUntil,
           now < suppressedUntil {
            let cooldownMs = Int(suppressedUntil.timeIntervalSince(now) * 1000)
            SkyBridgeLogger.shared.debug(
                "Metal restore probe suppressed: reason=\(metalFallbackReason ?? "unknown") cooldownMs=\(cooldownMs)"
            )
            return
        }

        stableSampleBufferFramesSinceMetalFallback += 1
        guard stableSampleBufferFramesSinceMetalFallback >= metalFallbackStableFrameRestoreThreshold else { return }

        decodedVideoRendererPreference = .metal
        stableSampleBufferFramesSinceMetalFallback = 0
        self.lastMetalFallbackAt = nil
        metalAwaitingFirstDisplaySince = nil
        let restoreReason = metalFallbackReason ?? "unknown"
        metalFallbackReason = nil
        await requestStreamRefreshIfNeeded(
            reason: "sample-buffer-stable-restore-metal",
            minimumInterval: metalFallbackRestoreCooldown
        )
        SkyBridgeLogger.shared.info(
            "♻️ AVSampleBufferDisplayLayer 已稳定，准备恢复 Metal Renderer: transport=\(activeTransportModeLabel()) reason=\(restoreReason) elapsedMs=\(Int(now.timeIntervalSince(lastMetalFallbackAt) * 1000)) expectedMs=\(Int(metalFallbackExpectedRestoreWindow * 1000)) cooldownMs=\(Int(metalFallbackRestoreCooldown * 1000)) stableFrames=\(metalFallbackStableFrameRestoreThreshold)"
        )
    }

    private func makeCGImage(from pixelBufferFrame: DecodedPixelBufferFrame) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBufferFrame.pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: pixelBufferFrame.width, height: pixelBufferFrame.height)
        return fallbackImageContext.createCGImage(image, from: rect)
    }

    private func zeroMeasuredFrameRate(at now: Date) {
        guard frameRate != 0 || frameCount != 0 else { return }
        frameRate = 0
        frameCount = 0
        lastFrameTime = now
    }

    private func startStreamContinuityWatchdog(for epoch: UInt64) {
        streamContinuityWatchdogTask?.cancel()
        streamContinuityWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard self.streamEpoch == epoch else { return }
                guard self.state == .streaming else { continue }
                let now = Date()
                let lastProgressAt = self.lastDisplayedFrameTime ?? self.lastVideoRendererEnqueueAt ?? self.lastRenderedFrameTime ?? self.lastFrameArrivalAt
                if let lastProgressAt,
                   now.timeIntervalSince(lastProgressAt) >= 1.0 {
                    self.zeroMeasuredFrameRate(at: now)
                }
                // 修复：增加 Metal 首帧超时阈值到 2.5 秒，给 MTKView 更多时间完成首帧渲染
                // 原代码 1.0 秒在设备热启动或 GPU 繁忙时过于激进
                if self.renderPipelineStatus == .metalRenderer,
                   self.lastDisplayedFrameTime == nil,
                   let firstAwaitingDisplayAt = self.metalAwaitingFirstDisplaySince,
                   now.timeIntervalSince(firstAwaitingDisplayAt) >= 2.5 {
                    await self.handleStreamContinuityStall(reason: "metal-first-display-timeout")
                    continue
                }
                if let lastFrameArrivalAt = self.lastFrameArrivalAt,
                   let lastDisplayedFrameTime = self.lastDisplayedFrameTime,
                   lastFrameArrivalAt > lastDisplayedFrameTime,
                   now.timeIntervalSince(lastDisplayedFrameTime) >= 1.0 {
                    await self.handleStreamContinuityStall(reason: "frames-arriving-without-display")
                    continue
                }
                if self.renderPipelineStatus == .metalRenderer,
                   let lastDecodedFrameTime = self.lastDecodedFrameTime,
                   let lastDisplayedFrameTime = self.lastDisplayedFrameTime,
                   lastDecodedFrameTime > lastDisplayedFrameTime,
                   now.timeIntervalSince(lastDisplayedFrameTime) >= 1.0 {
                    await self.handleStreamContinuityStall(reason: "frames-decoding-without-display")
                    continue
                }
                if let lastFrameArrivalAt = self.lastFrameArrivalAt,
                   let lastDecodedFrameTime = self.lastDecodedFrameTime,
                   lastFrameArrivalAt > lastDecodedFrameTime,
                   now.timeIntervalSince(lastDecodedFrameTime) >= 1.0 {
                    await self.handleStreamContinuityStall(reason: "frames-arriving-without-decode")
                }
            }
        }
    }

    private func scheduleFirstFrameContinuityCheck(for epoch: UInt64, firstFrameAt: Date) {
        firstFrameContinuityTask?.cancel()
        firstFrameContinuityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(1.2))
            } catch {
                return
            }
            guard self.streamEpoch == epoch else { return }
            guard self.state == .streaming else { return }
            guard self.receivedFrameCountInCurrentStream <= 1 else { return }
            guard self.lastFrameArrivalAt == firstFrameAt else { return }
            await self.handleStreamContinuityStall(reason: "first-frame-only-freeze")
        }
    }

    private func noteViewerInteraction(kind: String) {
        let interactionAt = Date()
        lastViewerInteractionAt = interactionAt
        let epoch = streamEpoch
        interactionContinuityTask?.cancel()
        interactionContinuityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard self.streamEpoch == epoch else { return }
            guard self.state == .streaming else { return }
            guard self.hasReceivedFrameInCurrentStream else { return }
            guard let lastFrameArrivalAt = self.lastFrameArrivalAt,
                  lastFrameArrivalAt <= interactionAt else { return }
            await self.handleStreamContinuityStall(reason: "post-\(kind)-no-frame")
        }
    }

    private func shouldEscalateSampleBufferStall(reason: String) -> Bool {
        switch reason {
        case "sample-buffer-no-enqueue":
            return consecutiveSampleBufferNoEnqueueWindows >= sampleBufferNoEnqueueWindowThreshold
        case "frames-arriving-without-display", "frames-decoding-without-display":
            consecutiveSampleBufferDisplayStalls += 1
            return consecutiveSampleBufferDisplayStalls >= sampleBufferDisplayStallRecoveryThreshold
        default:
            return false
        }
    }

    private func recoverSampleBufferPipeline(reason: String, at now: Date) async {
        lastContinuityRecoveryAt = now
        metalAwaitingFirstDisplaySince = nil
        zeroMeasuredFrameRate(at: now)
        invalidateDecodePipelineState()
        flushRenderedVideoFeeds(removeDisplayedImage: false)
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(
            lastIncomingStreamSignature?.format
        )
        await decoder.resetPreservingLastFrame()
        lastDecoderResetTime = now
        consecutiveDecodeMisses = 0
        await requestStreamRefreshIfNeeded(reason: reason, minimumInterval: 0.25)
        SkyBridgeLogger.shared.warning(
            "⚠️ AVSampleBufferDisplayLayer 连续性异常: \(reason)，已刷新解码管线并暂缓静态帧降级"
        )
    }

    private func handleStreamContinuityStall(reason: String) async {
        let now = Date()
        if let lastContinuityRecoveryAt,
           now.timeIntervalSince(lastContinuityRecoveryAt) < 0.75 {
            return
        }
        if (reason == "frames-arriving-without-display"
            || reason == "frames-decoding-without-display"
            || reason == "metal-first-display-timeout"),
           renderPipelineStatus == .metalRenderer {
            lastContinuityRecoveryAt = now
            zeroMeasuredFrameRate(at: now)
            activateSampleBufferFallbackForDecodedVideo(reason: reason)
            return
        }
        if (reason == "frames-arriving-without-display"
            || reason == "frames-decoding-without-display"
            || reason == "sample-buffer-no-enqueue"),
           renderPipelineStatus == .sampleBufferDisplayLayer {
            if shouldEscalateSampleBufferStall(reason: reason) {
                lastContinuityRecoveryAt = now
                zeroMeasuredFrameRate(at: now)
                activateCGImageFallbackForDecodedVideo()
                return
            }
            await recoverSampleBufferPipeline(reason: reason, at: now)
            return
        }
        lastContinuityRecoveryAt = now
        metalAwaitingFirstDisplaySince = nil
        zeroMeasuredFrameRate(at: now)
        if renderPipelineStatus == .sampleBufferDisplayLayer || renderPipelineStatus == .metalRenderer {
            invalidateDecodePipelineState()
            flushRenderedVideoFeeds(removeDisplayedImage: false)
            pendingFrames.removeAll(keepingCapacity: true)
            decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(
                lastIncomingStreamSignature?.format
            )
            await decoder.resetPreservingLastFrame()
            lastDecoderResetTime = now
            consecutiveDecodeMisses = 0
        }
        let format = lastIncomingStreamSignature?.format ?? ""
        let governanceEvent = codecGovernance.noteDecodeFailure(
            format: format,
            reason: reason,
            at: now
        )
        _ = await handleCodecGovernanceEvent(governanceEvent, at: now)
        await requestStreamRefreshIfNeeded(reason: reason, minimumInterval: 0.25)
        SkyBridgeLogger.shared.warning("⚠️ 检测到远控视频连续性异常: \(reason)，已请求关键帧刷新")
    }

    func handleVideoRendererDidEnqueueFrame(
        presentationTimeStamp _: CMTime,
        remainingQueueDepth _: Int
    ) async {
        let now = Date()
        videoFrameFeed.markDisplayedFrame()
        noteVideoRendererEnqueuedFrame(at: now)
        noteDisplayedFrame(at: now)
        await maybeRestoreMetalRendererAfterStableSampleBuffer(at: now)
    }

    func handleMetalRendererDidDisplayFrame(
        presentationTimeStamp _: CMTime
    ) async {
        metalAwaitingFirstDisplaySince = nil
        lastMetalFallbackAt = nil
        metalFallbackReason = nil
        metalRestoreFailureCount = 0
        metalRestoreSuppressedUntil = nil
        stableSampleBufferFramesSinceMetalFallback = 0
        metalVideoFrameFeed.markDisplayedFrame()
        noteDisplayedFrame(at: Date())
    }

    @MainActor
    private func applyDecodedOutput(
        _ decoded: DecodeOutput,
        sourceFrame: ScreenData,
        format: String,
        decoder: VideoDecoder,
        generation: UInt64,
        now: Date
    ) async -> Bool {
        guard generation == decodeGeneration else { return false }

        switch decoded {
        case .image(let frame):
            metalAwaitingFirstDisplaySince = nil
            flushRenderedVideoFeeds()
            currentFrame = frame.image
            updateLastGoodFrozenFrame(frame.image)
            updateRenderPipeline(.stillImageFallback)
            noteDecodedFrame(at: now)
            noteDisplayedFrame(at: now)
        case .pixelBuffer(let frame):
            guard shouldAcceptDecodedFrame(presentationTimeStamp: frame.presentationTimeStamp) else {
                return false
            }
            let independentlyDecodableFrame = sourceFrame.isIndependentlyDecodableFrame
            let frozenCandidate = independentlyDecodableFrame ? makeCGImage(from: frame) : nil
            if independentlyDecodableFrame {
                updateLastGoodFrozenFrame(frozenCandidate)
            }
            currentFrame = nil
            switch decodedVideoRendererPreference {
            case .metal:
                if lastDisplayedFrameTime == nil {
                    metalAwaitingFirstDisplaySince = metalAwaitingFirstDisplaySince ?? now
                } else {
                    metalAwaitingFirstDisplaySince = nil
                }
                videoFrameFeed.flush(removeDisplayedImage: false)
                metalVideoFrameFeed.enqueue(frame: frame)
                updateRenderPipeline(.metalRenderer)
            case .sampleBuffer:
                metalAwaitingFirstDisplaySince = nil
                if let displayFrame = await decoder.makeDisplaySampleBufferFrame(
                    from: frame,
                    format: format
                ) {
                    metalVideoFrameFeed.flush(removeDisplayedImage: true)
                    videoFrameFeed.enqueue(frame: displayFrame)
                    updateRenderPipeline(.sampleBufferDisplayLayer)
                } else {
                    videoFrameFeed.flush(removeDisplayedImage: false)
                    metalVideoFrameFeed.enqueue(frame: frame)
                    updateRenderPipeline(.metalRenderer)
                }
            case .cgImage:
                metalAwaitingFirstDisplaySince = nil
                if independentlyDecodableFrame,
                   let image = frozenCandidate {
                    flushRenderedVideoFeeds(removeDisplayedImage: true)
                    currentFrame = image
                    updateLastGoodFrozenFrame(image)
                    updateRenderPipeline(.stillImageFallback)
                    noteDisplayedFrame(at: now)
                } else {
                    if let lastGoodFrozenFrame {
                        currentFrame = lastGoodFrozenFrame
                    }
                    updateRenderPipeline(.stillImageFallback)
                }
            }
            noteDecodedFrame(at: now)
        case .sampleBuffer(let frame):
            guard shouldAcceptDecodedFrame(presentationTimeStamp: frame.presentationTimeStamp) else {
                return false
            }
            if sourceFrame.isIndependentlyDecodableFrame {
                updateLastGoodFrozenFrame(
                    makeCGImage(
                        from: DecodedPixelBufferFrame(
                            pixelBuffer: CMSampleBufferGetImageBuffer(frame.sampleBuffer)!,
                            width: frame.width,
                            height: frame.height,
                            presentationTimeStamp: frame.presentationTimeStamp
                        )
                    )
                )
            }
            metalAwaitingFirstDisplaySince = nil
            currentFrame = nil
            metalVideoFrameFeed.flush(removeDisplayedImage: true)
            videoFrameFeed.enqueue(frame: frame)
            updateRenderPipeline(.sampleBufferDisplayLayer)
            noteDecodedFrame(at: now)
        }

        consecutiveDecodeMisses = 0
        return true
    }

    private func startDecodeLoopIfNeeded() {
        while let next = pendingFrames.first {
            let maxConcurrentDecodeTasks = maxConcurrentDecodeTasks(for: next)
            guard inFlightDecodeCount < maxConcurrentDecodeTasks else { return }
            guard let screenData = RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pendingFrames) else { return }
            inFlightDecodeCount += 1

            let decoder = self.decoder
            let decodeGeneration = self.decodeGeneration

            Task { @MainActor [weak self] in
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

                defer {
                    self.completeDecodeTask(for: decodeGeneration)
                    self.startDecodeLoopIfNeeded()
                }

                guard decodeGeneration == self.decodeGeneration else { return }

                if let decoded {
                    let now = Date()
                    let applied = await self.applyDecodedOutput(
                        decoded,
                        sourceFrame: screenData,
                        format: format,
                        decoder: decoder,
                        generation: decodeGeneration,
                        now: now
                    )
                    guard applied else { return }
                    let governanceEvent = self.codecGovernance.noteDecodeSuccess(format: format, at: now)
                    _ = await self.handleCodecGovernanceEvent(governanceEvent, at: now)
                    return
                }

                self.consecutiveDecodeMisses += 1
                let now = Date()
                if let lastRenderedFrameTime,
                   now.timeIntervalSince(lastRenderedFrameTime) >= 1.0 {
                    self.frameRate = 0
                }
                if isStillImageFrame {
                    self.consecutiveDecodeMisses = 0
                    return
                }
                let governanceEvent = self.codecGovernance.noteDecodeFailure(
                    format: format,
                    reason: decodeFailureReason,
                    at: now
                )
                let governanceHandled = await self.handleCodecGovernanceEvent(governanceEvent, at: now)
                if governanceHandled {
                    return
                }
                let canResetDecoder = self.lastDecoderResetTime.map { now.timeIntervalSince($0) >= 1.0 } ?? true
                if self.consecutiveDecodeMisses >= 6, canResetDecoder {
                    self.invalidateDecodePipelineState()
                    self.pendingFrames.removeAll(keepingCapacity: true)
                    self.decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(format)
                    await self.decoder.resetPreservingLastFrame()
                    self.lastDecoderResetTime = now
                    self.consecutiveDecodeMisses = 0
                    await self.requestStreamRefreshIfNeeded(
                        reason: "decode-stall-reset",
                        minimumInterval: self.streamDecodeStallRefreshMinimumInterval
                    )
                    SkyBridgeLogger.shared.warning("⚠️ 检测到远控视频解码停滞，已自动重置解码器")
                }
            }
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
    case webrtcNativeVideo
    case metalRenderer
    case sampleBufferDisplayLayer
    case stillImageFallback

    public var displayName: String {
        switch self {
        case .waiting: return "等待首帧"
        case .webrtcNativeVideo: return "WebRTC 原生视频轨"
        case .metalRenderer: return "Metal Renderer"
        case .sampleBufferDisplayLayer: return "AVSampleBufferDisplayLayer"
        case .stillImageFallback: return "静态帧回退"
        }
    }
}
