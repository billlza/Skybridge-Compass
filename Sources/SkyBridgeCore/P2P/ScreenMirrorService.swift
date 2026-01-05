//
// ScreenMirrorService.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Screen Mirroring Service
// Requirements: 7.1, 7.2, 7.3, 7.5, 7.6, 7.7
//

import Foundation
import CryptoKit
#if canImport(VideoToolbox)
import VideoToolbox
#endif
#if canImport(CoreMedia)
import CoreMedia
#endif

// MARK: - Video Codec Configuration

/// 视频编解码配置
/// 必须在关键帧前或会话开始时通过 control channel 发送
/// 注意：config 必须进入 transcript（防降级/篡改）
public struct P2PVideoCodecConfig: Codable, Sendable, Equatable, TranscriptEncodable {
 /// 编解码器类型
    public let codec: P2PVideoCodec
    
 /// 参数集（HEVC: VPS/SPS/PPS; H.264: SPS/PPS）
    public let parameterSets: [Data]
    
 /// 视频宽度
    public let width: Int
    
 /// 视频高度
    public let height: Int
    
 /// 帧率
    public let fps: Int
    
 /// 比特率（bps）
    public let bitrate: Int
    
 /// 时间戳（毫秒）
    public let timestampMillis: Int64
    
 /// 协议版本
    public let protocolVersion: Int
    
    public init(
        codec: P2PVideoCodec,
        parameterSets: [Data],
        width: Int,
        height: Int,
        fps: Int = P2PConstants.defaultVideoFPS,
        bitrate: Int = P2PConstants.defaultVideoBitrate,
        timestampMillis: Int64 = P2PTimestamp.nowMillis,
        protocolVersion: Int = P2PProtocolVersion.current.rawValue
    ) {
        self.codec = codec
        self.parameterSets = parameterSets
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.timestampMillis = timestampMillis
        self.protocolVersion = protocolVersion
    }
    
 /// 生成用于 transcript 的确定性编码
    public func deterministicEncode() throws -> Data {
        var data = Data()
        
 // codec (1 byte)
        data.append(codec.rawValue)
        
 // width (4 bytes, big-endian)
        var w = UInt32(width).bigEndian
        data.append(Data(bytes: &w, count: 4))
        
 // height (4 bytes, big-endian)
        var h = UInt32(height).bigEndian
        data.append(Data(bytes: &h, count: 4))
        
 // fps (2 bytes, big-endian)
        var f = UInt16(fps).bigEndian
        data.append(Data(bytes: &f, count: 2))
        
 // bitrate (4 bytes, big-endian)
        var b = UInt32(bitrate).bigEndian
        data.append(Data(bytes: &b, count: 4))
        
 // parameter sets count (2 bytes)
        var count = UInt16(parameterSets.count).bigEndian
        data.append(Data(bytes: &count, count: 2))
        
 // parameter sets (length-prefixed)
        for ps in parameterSets {
            var len = UInt16(ps.count).bigEndian
            data.append(Data(bytes: &len, count: 2))
            data.append(ps)
        }
        
 // timestamp (8 bytes, big-endian)
        var ts = timestampMillis.bigEndian
        data.append(Data(bytes: &ts, count: 8))
        
 // protocol version (2 bytes)
        var ver = UInt16(protocolVersion).bigEndian
        data.append(Data(bytes: &ver, count: 2))
        
        return data
    }
}

/// 视频编解码器类型
public enum P2PVideoCodec: UInt8, Codable, Sendable {
    case h264 = 0x01
    case hevc = 0x02
    
    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
    
    #if canImport(VideoToolbox)
    public var codecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }
    #endif
}

// MARK: - Video Frame Packet

/// 视频帧分片包（适配 QUIC Datagram MTU 限制）
/// 使用固定大小头部，避免 Codable 动态大小问题
public struct P2PVideoFramePacket: Sendable, Equatable {
 /// 固定头部大小（字节）
 /// frameSeq(8) + fragIndex(2) + fragCount(2) + flags(2) + timestamp(8) + orientation(1) + reserved(1) = 24
    public static let headerSize: Int = P2PConstants.videoFrameHeaderSize
    
 /// 帧序列号
    public let frameSeq: UInt64
    
 /// 分片索引 (0-based)
    public let fragIndex: UInt16
    
 /// 总分片数
    public let fragCount: UInt16
    
 /// 标志位
    public let flags: P2PVideoFrameFlags
    
 /// 时间戳（毫秒）
    public let timestampMillis: Int64
    
 /// 视频方向
    public let orientation: P2PVideoOrientation
    
 /// 分片数据（不含 parameter sets，需配合 VideoCodecConfig）
    public let payload: Data
    
    public init(
        frameSeq: UInt64,
        fragIndex: UInt16,
        fragCount: UInt16,
        flags: P2PVideoFrameFlags,
        timestampMillis: Int64,
        orientation: P2PVideoOrientation,
        payload: Data
    ) {
        self.frameSeq = frameSeq
        self.fragIndex = fragIndex
        self.fragCount = fragCount
        self.flags = flags
        self.timestampMillis = timestampMillis
        self.orientation = orientation
        self.payload = payload
    }
    
 /// 是否为关键帧
    public var isKeyFrame: Bool {
        flags.contains(.keyFrame)
    }
    
 /// 是否为帧的最后一个分片
    public var isLastFragment: Bool {
        fragIndex == fragCount - 1
    }
    
 /// 编码为二进制（固定头部 + payload）
    public func encode() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        
 // frameSeq (8 bytes)
        var seq = frameSeq.bigEndian
        data.append(Data(bytes: &seq, count: 8))
        
 // fragIndex (2 bytes)
        var fi = fragIndex.bigEndian
        data.append(Data(bytes: &fi, count: 2))
        
 // fragCount (2 bytes)
        var fc = fragCount.bigEndian
        data.append(Data(bytes: &fc, count: 2))
        
 // flags (2 bytes)
        var fl = flags.rawValue.bigEndian
        data.append(Data(bytes: &fl, count: 2))
        
 // timestamp (8 bytes)
        var ts = timestampMillis.bigEndian
        data.append(Data(bytes: &ts, count: 8))
        
 // orientation (1 byte)
        data.append(orientation.rawValue)
        
 // reserved (1 byte)
        data.append(0)
        
 // payload
        data.append(payload)
        
        return data
    }
    
 /// 从二进制解码
    public static func decode(from data: Data) -> P2PVideoFramePacket? {
        guard data.count >= headerSize else { return nil }
        
        var offset = 0
        
 // frameSeq
        let frameSeq = data.withUnsafeBytes { ptr -> UInt64 in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
        offset += 8
        
 // fragIndex
        let fragIndex = data.withUnsafeBytes { ptr -> UInt16 in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian
        }
        offset += 2
        
 // fragCount
        let fragCount = data.withUnsafeBytes { ptr -> UInt16 in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian
        }
        offset += 2
        
 // flags
        let flagsRaw = data.withUnsafeBytes { ptr -> UInt16 in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian
        }
        let flags = P2PVideoFrameFlags(rawValue: flagsRaw)
        offset += 2
        
 // timestamp
        let timestampMillis = data.withUnsafeBytes { ptr -> Int64 in
            ptr.loadUnaligned(fromByteOffset: offset, as: Int64.self).bigEndian
        }
        offset += 8
        
 // orientation
        let orientationRaw = data[offset]
        let orientation = P2PVideoOrientation(rawValue: orientationRaw) ?? .portrait
        offset += 2 // +1 for orientation, +1 for reserved
        
 // payload
        let payload = data.subdata(in: offset..<data.count)
        
        return P2PVideoFramePacket(
            frameSeq: frameSeq,
            fragIndex: fragIndex,
            fragCount: fragCount,
            flags: flags,
            timestampMillis: timestampMillis,
            orientation: orientation,
            payload: payload
        )
    }
}

/// 视频帧标志位
public struct P2PVideoFrameFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
    
 /// 关键帧
    public static let keyFrame = P2PVideoFrameFlags(rawValue: 1 << 0)
    
 /// 帧结束
    public static let endOfFrame = P2PVideoFrameFlags(rawValue: 1 << 1)
    
 /// 包含参数集
    public static let hasParameterSets = P2PVideoFrameFlags(rawValue: 1 << 2)
    
 /// 方向已变化
    public static let orientationChanged = P2PVideoFrameFlags(rawValue: 1 << 3)
}

/// 视频方向
public enum P2PVideoOrientation: UInt8, Codable, Sendable {
    case portrait = 0
    case landscapeLeft = 1
    case landscapeRight = 2
    case portraitUpsideDown = 3
    
    public var displayName: String {
        switch self {
        case .portrait: return "竖屏"
        case .landscapeLeft: return "横屏（左）"
        case .landscapeRight: return "横屏（右）"
        case .portraitUpsideDown: return "倒置竖屏"
        }
    }
}


// MARK: - Video Frame Fragmenter

/// 视频帧分片器
public struct P2PVideoFrameFragmenter: Sendable {
    
 /// 最大 datagram 大小
    private let maxDatagramSize: Int
    
 /// 计算的最大 payload 大小
    public var maxPayloadSize: Int {
        maxDatagramSize - P2PVideoFramePacket.headerSize
    }
    
    public init(maxDatagramSize: Int) {
        self.maxDatagramSize = maxDatagramSize
    }
    
 /// 分片视频帧
    public func fragment(
        frameData: Data,
        frameSeq: UInt64,
        isKeyFrame: Bool,
        timestampMillis: Int64,
        orientation: P2PVideoOrientation
    ) -> [P2PVideoFramePacket] {
        let payloadMax = maxPayloadSize
        guard payloadMax > 0 else { return [] }
        
        let fragCount = UInt16((frameData.count + payloadMax - 1) / payloadMax)
        var packets: [P2PVideoFramePacket] = []
        
        for i in 0..<Int(fragCount) {
            let start = i * payloadMax
            let end = min(start + payloadMax, frameData.count)
            let payload = frameData.subdata(in: start..<end)
            
            var flags = P2PVideoFrameFlags()
            if isKeyFrame && i == 0 {
                flags.insert(.keyFrame)
            }
            if i == Int(fragCount) - 1 {
                flags.insert(.endOfFrame)
            }
            
            let packet = P2PVideoFramePacket(
                frameSeq: frameSeq,
                fragIndex: UInt16(i),
                fragCount: fragCount,
                flags: flags,
                timestampMillis: timestampMillis,
                orientation: orientation,
                payload: payload
            )
            packets.append(packet)
        }
        
        return packets
    }
}

// MARK: - Video Frame Reassembler

/// 视频帧重组器
public actor P2PVideoFrameReassembler {
    
 /// 过期帧丢弃窗口（毫秒）
    private let staleFrameWindowMs: Int
    
 /// 最新关键帧序列号
    private var latestKeyFrameSeq: UInt64 = 0
    
 /// 待重组的帧缓冲
    private var pendingFrames: [UInt64: PendingFrame] = [:]
    
 /// 已完成帧回调
    public var onFrameReassembled: (@Sendable (ReassembledFrame) -> Void)?
    
 /// 请求关键帧回调
    public var onKeyFrameNeeded: (@Sendable (P2PKeyFrameRequestReason) -> Void)?
    
    public init(staleFrameWindowMs: Int = P2PConstants.staleFrameWindowMs) {
        self.staleFrameWindowMs = staleFrameWindowMs
    }
    
 /// 接收分片
    public func receivePacket(_ packet: P2PVideoFramePacket) -> ReassembledFrame? {
        let frameSeq = packet.frameSeq
        
 // 丢弃过期帧（非关键帧且序列号小于最新关键帧）
        if !packet.isKeyFrame && frameSeq < latestKeyFrameSeq {
            return nil
        }
        
 // 更新关键帧序列号
        if packet.isKeyFrame {
            latestKeyFrameSeq = max(latestKeyFrameSeq, frameSeq)
 // 清理所有旧帧
            pendingFrames = pendingFrames.filter { $0.key >= frameSeq }
        }
        
 // 获取或创建待重组帧
        var pending = pendingFrames[frameSeq] ?? PendingFrame(
            frameSeq: frameSeq,
            fragCount: Int(packet.fragCount),
            isKeyFrame: packet.isKeyFrame,
            timestampMillis: packet.timestampMillis,
            orientation: packet.orientation,
            receivedAt: P2PTimestamp.nowMillis
        )
        
 // 添加分片
        pending.fragments[Int(packet.fragIndex)] = packet.payload
        
 // 检查是否完成
        if pending.isComplete {
            pendingFrames.removeValue(forKey: frameSeq)
            return pending.reassemble()
        }
        
        pendingFrames[frameSeq] = pending
        return nil
    }
    
 /// 清理超时帧
    public func cleanupStaleFrames() {
        let now = P2PTimestamp.nowMillis
        let threshold = Int64(staleFrameWindowMs)
        
        var needKeyFrame = false
        
        pendingFrames = pendingFrames.filter { (seq, frame) in
            let age = now - frame.receivedAt
            if age > threshold {
 // 超时帧，需要请求关键帧
                if !frame.isKeyFrame {
                    needKeyFrame = true
                }
                return false
            }
            return true
        }
        
        if needKeyFrame {
            onKeyFrameNeeded?(.loss)
        }
    }
    
 /// 重置状态
    public func reset() {
        latestKeyFrameSeq = 0
        pendingFrames.removeAll()
    }
    
 /// 当前待重组帧数
    public var pendingCount: Int {
        pendingFrames.count
    }
}

/// 待重组帧
private struct PendingFrame: Sendable {
    let frameSeq: UInt64
    let fragCount: Int
    let isKeyFrame: Bool
    let timestampMillis: Int64
    let orientation: P2PVideoOrientation
    let receivedAt: Int64
    var fragments: [Int: Data] = [:]
    
    var isComplete: Bool {
        fragments.count == fragCount
    }
    
    func reassemble() -> ReassembledFrame? {
        guard isComplete else { return nil }
        
        var data = Data()
        for i in 0..<fragCount {
            guard let frag = fragments[i] else { return nil }
            data.append(frag)
        }
        
        return ReassembledFrame(
            frameSeq: frameSeq,
            isKeyFrame: isKeyFrame,
            data: data,
            timestampMillis: timestampMillis,
            orientation: orientation
        )
    }
}

/// 重组后的完整帧
public struct ReassembledFrame: Sendable {
    public let frameSeq: UInt64
    public let isKeyFrame: Bool
    public let data: Data
    public let timestampMillis: Int64
    public let orientation: P2PVideoOrientation
}

// MARK: - Request Key Frame

/// 关键帧请求消息
public struct P2PRequestKeyFrame: Codable, Sendable, Equatable {
 /// 请求原因
    public let reason: P2PKeyFrameRequestReason
    
 /// 时间戳（毫秒）
    public let timestampMillis: Int64
    
 /// 最后收到的帧序列号
    public let lastReceivedFrameSeq: UInt64?
    
    public init(
        reason: P2PKeyFrameRequestReason,
        timestampMillis: Int64 = P2PTimestamp.nowMillis,
        lastReceivedFrameSeq: UInt64? = nil
    ) {
        self.reason = reason
        self.timestampMillis = timestampMillis
        self.lastReceivedFrameSeq = lastReceivedFrameSeq
    }
}

/// 关键帧请求原因
public enum P2PKeyFrameRequestReason: String, Codable, Sendable {
 /// 丢失关键帧
    case loss = "loss"
    
 /// 新订阅者加入
    case newSubscriber = "new_subscriber"
    
 /// 分辨率变化
    case resize = "resize"
    
 /// 质量调整
    case qualityChange = "quality_change"
    
 /// 重组超时
    case reassembleTimeout = "reassemble_timeout"
}

// MARK: - Screen Mirror Capture State

/// 屏幕镜像捕获状态
public enum P2PScreenCaptureState: String, Sendable {
 /// 空闲
    case idle = "idle"
    
 /// 正在捕获
    case capturing = "capturing"
    
 /// 已暂停
    case paused = "paused"
    
 /// 已停止
    case stopped = "stopped"
    
 /// 错误
    case error = "error"
}

// MARK: - Screen Mirror Configuration

/// 屏幕镜像配置
public struct P2PScreenMirrorConfig: Sendable {
 /// 目标分辨率宽度（0 表示原始分辨率）
    public let targetWidth: Int
    
 /// 目标分辨率高度（0 表示原始分辨率）
    public let targetHeight: Int
    
 /// 目标帧率
    public let targetFPS: Int
    
 /// 目标比特率（bps）
    public let targetBitrate: Int
    
 /// 编解码器
    public let codec: P2PVideoCodec
    
 /// 是否启用硬件编码
    public let useHardwareEncoder: Bool
    
    public init(
        targetWidth: Int = 0,
        targetHeight: Int = 0,
        targetFPS: Int = P2PConstants.defaultVideoFPS,
        targetBitrate: Int = P2PConstants.defaultVideoBitrate,
        codec: P2PVideoCodec = .hevc,
        useHardwareEncoder: Bool = true
    ) {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.targetFPS = targetFPS
        self.targetBitrate = targetBitrate
        self.codec = codec
        self.useHardwareEncoder = useHardwareEncoder
    }
}

// MARK: - Screen Mirror Service

/// 屏幕镜像服务（iOS 端）
/// 负责屏幕捕获和编码
@available(macOS 14.0, iOS 17.0, *)
public actor P2PScreenMirrorService {
    
 // MARK: - Properties
    
 /// 当前状态
    private var _state: P2PScreenCaptureState = .idle
    
 /// 当前配置
    private var config: P2PScreenMirrorConfig?
    
 /// 当前编解码配置
    private var codecConfig: P2PVideoCodecConfig?
    
 /// 帧序列号
    private var frameSeq: UInt64 = 0
    
 /// 当前方向
    private var currentOrientation: P2PVideoOrientation = .portrait
    
 /// 分片器
    private var fragmenter: P2PVideoFrameFragmenter?
    
 /// 编码帧回调
    public var onEncodedFrame: (@Sendable ([P2PVideoFramePacket]) -> Void)?
    
 /// 状态变化回调
    public var onStateChanged: (@Sendable (P2PScreenCaptureState) -> Void)?
    
 /// 编解码配置变化回调
    public var onCodecConfigChanged: (@Sendable (P2PVideoCodecConfig) -> Void)?
    
 // MARK: - Public Interface
    
    public init() {}
    
 /// 当前状态
    public var state: P2PScreenCaptureState {
        _state
    }
    
 /// 开始捕获
    public func startCapture(config: P2PScreenMirrorConfig, maxDatagramSize: Int) async throws {
        guard _state == .idle || _state == .stopped else {
            throw P2PScreenMirrorError.invalidState("无法从 \(_state) 状态开始捕获")
        }
        
        self.config = config
        self.fragmenter = P2PVideoFrameFragmenter(maxDatagramSize: maxDatagramSize)
        self.frameSeq = 0
        
 // 创建编解码配置
        let codecConfig = P2PVideoCodecConfig(
            codec: config.codec,
            parameterSets: [], // 实际实现中从编码器获取
            width: config.targetWidth > 0 ? config.targetWidth : 1920,
            height: config.targetHeight > 0 ? config.targetHeight : 1080,
            fps: config.targetFPS,
            bitrate: config.targetBitrate
        )
        self.codecConfig = codecConfig
        
        setState(.capturing)
        onCodecConfigChanged?(codecConfig)
        
 // 注意：实际的 ReplayKit 捕获需要在 iOS 端实现
 // 这里提供框架结构
    }
    
 /// 停止捕获
    public func stopCapture() async {
        guard _state == .capturing || _state == .paused else { return }
        setState(.stopped)
    }
    
 /// 暂停捕获
    public func pauseCapture() async {
        guard _state == .capturing else { return }
        setState(.paused)
    }
    
 /// 恢复捕获
    public func resumeCapture() async {
        guard _state == .paused else { return }
        setState(.capturing)
    }
    
 /// 处理编码后的帧数据
    public func processEncodedFrame(
        data: Data,
        isKeyFrame: Bool,
        timestampMillis: Int64
    ) {
        guard _state == .capturing, let fragmenter = fragmenter else { return }
        
        let packets = fragmenter.fragment(
            frameData: data,
            frameSeq: frameSeq,
            isKeyFrame: isKeyFrame,
            timestampMillis: timestampMillis,
            orientation: currentOrientation
        )
        
        frameSeq += 1
        onEncodedFrame?(packets)
    }
    
 /// 强制生成关键帧
    public func forceKeyFrame() {
 // 实际实现中触发编码器生成 IDR 帧
 // VideoToolbox: VTCompressionSessionCompleteFrames + kVTEncodeFrameOptionKey_ForceKeyFrame
    }
    
 /// 更新方向
    public func updateOrientation(_ orientation: P2PVideoOrientation) {
        currentOrientation = orientation
    }
    
 /// 调整质量
    public func adjustQuality(targetBitrate: Int, targetFPS: Int) async {
        guard var config = self.config else { return }
        
        config = P2PScreenMirrorConfig(
            targetWidth: config.targetWidth,
            targetHeight: config.targetHeight,
            targetFPS: targetFPS,
            targetBitrate: targetBitrate,
            codec: config.codec,
            useHardwareEncoder: config.useHardwareEncoder
        )
        self.config = config
        
 // 更新编解码配置
        if var codecConfig = self.codecConfig {
            codecConfig = P2PVideoCodecConfig(
                codec: codecConfig.codec,
                parameterSets: codecConfig.parameterSets,
                width: codecConfig.width,
                height: codecConfig.height,
                fps: targetFPS,
                bitrate: targetBitrate
            )
            self.codecConfig = codecConfig
            onCodecConfigChanged?(codecConfig)
        }
    }
    
 // MARK: - Private Methods
    
    private func setState(_ newState: P2PScreenCaptureState) {
        _state = newState
        onStateChanged?(newState)
    }
}

// MARK: - Screen Mirror Errors

/// 屏幕镜像错误
public enum P2PScreenMirrorError: Error, Sendable {
 /// 无效状态
    case invalidState(String)
    
 /// 捕获失败
    case captureFailed(String)
    
 /// 编码失败
    case encodingFailed(String)
    
 /// 权限被拒绝
    case permissionDenied
    
 /// 不支持的编解码器
    case unsupportedCodec(P2PVideoCodec)
}

extension P2PScreenMirrorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidState(let reason):
            return "无效状态: \(reason)"
        case .captureFailed(let reason):
            return "捕获失败: \(reason)"
        case .encodingFailed(let reason):
            return "编码失败: \(reason)"
        case .permissionDenied:
            return "屏幕录制权限被拒绝"
        case .unsupportedCodec(let codec):
            return "不支持的编解码器: \(codec.displayName)"
        }
    }
}
