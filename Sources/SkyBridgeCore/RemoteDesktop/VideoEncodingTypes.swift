import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import QuartzCore

// MARK: - 视频编解码器类型

/// 视频编码器类型
public enum SkyBridgeVideoCodec: String, CaseIterable, Sendable {
    case h264 = "H.264"
    case h265 = "H.265"
    
 /// VideoToolbox编解码器类型
    public var vtCodecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .h265: return kCMVideoCodecType_HEVC
        }
    }
    
 /// 显示名称
    public var displayName: String {
        return rawValue
    }
    
 /// 文件扩展名
    public var fileExtension: String {
        switch self {
        case .h264: return "h264"
        case .h265: return "h265"
        }
    }
    
 /// MIME类型
    public var mimeType: String {
        switch self {
        case .h264: return "video/avc"
        case .h265: return "video/hevc"
        }
    }
}

// MARK: - 视频编码配置文件

/// 视频编码配置文件
public enum SkyBridgeVideoProfile: String, CaseIterable, Sendable {
    case h264Baseline = "H.264 Baseline"
    case h264Main = "H.264 Main"
    case h264High = "H.264 High"
    case h265Main = "H.265 Main"
    case h265Main10 = "H.265 Main 10"
    
 /// VideoToolbox配置文件级别
    public var vtProfileLevel: CFString? {
        switch self {
        case .h264Baseline: return kVTProfileLevel_H264_Baseline_AutoLevel
        case .h264Main: return kVTProfileLevel_H264_Main_AutoLevel
        case .h264High: return kVTProfileLevel_H264_High_AutoLevel
        case .h265Main: return kVTProfileLevel_HEVC_Main_AutoLevel
        case .h265Main10: return kVTProfileLevel_HEVC_Main10_AutoLevel
        }
    }
    
 /// 显示名称
    public var displayName: String {
        return rawValue
    }
    
 /// 是否支持硬件编码
    public var supportsHardwareEncoding: Bool {
        switch self {
        case .h264Baseline, .h264Main, .h264High, .h265Main:
            return true
        case .h265Main10:
            return false // 大多数设备不支持10位硬件编码
        }
    }
}

// MARK: - 视频编码质量级别

/// 视频编码质量级别
public enum VideoQualityLevel: String, CaseIterable, Sendable {
    case low = "低质量"
    case medium = "中等质量"
    case high = "高质量"
    case ultra = "超高质量"
    
 /// 质量值（0.0-1.0）
    public var qualityValue: Float {
        switch self {
        case .low: return 0.3
        case .medium: return 0.6
        case .high: return 0.8
        case .ultra: return 0.95
        }
    }
    
 /// 推荐比特率倍数
    public var bitrateMultiplier: Float {
        switch self {
        case .low: return 0.5
        case .medium: return 1.0
        case .high: return 1.5
        case .ultra: return 2.0
        }
    }
}

// MARK: - 视频编码预设

/// 视频编码预设
public enum VideoEncodingPreset: String, CaseIterable, Sendable {
    case ultraFast = "超快速"
    case fast = "快速"
    case medium = "中等"
    case slow = "慢速"
    case verySlow = "极慢"
    
 /// 编码复杂度（影响CPU使用率和质量）
    public var complexity: Int {
        switch self {
        case .ultraFast: return 1
        case .fast: return 2
        case .medium: return 3
        case .slow: return 4
        case .verySlow: return 5
        }
    }
    
 /// 是否启用B帧
    public var enableBFrames: Bool {
        switch self {
        case .ultraFast, .fast: return false
        case .medium, .slow, .verySlow: return true
        }
    }
    
 /// 关键帧间隔倍数
    public var keyFrameIntervalMultiplier: Float {
        switch self {
        case .ultraFast: return 0.5
        case .fast: return 0.75
        case .medium: return 1.0
        case .slow: return 1.25
        case .verySlow: return 1.5
        }
    }
}

// MARK: - 视频分辨率预设

/// 视频分辨率预设
public enum VideoResolutionPreset: String, CaseIterable, Sendable {
    case sd480p = "480p"
    case hd720p = "720p"
    case fhd1080p = "1080p"
    case qhd1440p = "1440p"
    case uhd4k = "4K"
    case uhd8k = "8K"
    
 /// 分辨率尺寸
    public var size: CGSize {
        switch self {
        case .sd480p: return CGSize(width: 854, height: 480)
        case .hd720p: return CGSize(width: 1280, height: 720)
        case .fhd1080p: return CGSize(width: 1920, height: 1080)
        case .qhd1440p: return CGSize(width: 2560, height: 1440)
        case .uhd4k: return CGSize(width: 3840, height: 2160)
        case .uhd8k: return CGSize(width: 7680, height: 4320)
        }
    }
    
 /// 推荐比特率（bps）
    public var recommendedBitrate: Int {
        switch self {
        case .sd480p: return 1_000_000    // 1 Mbps
        case .hd720p: return 2_500_000    // 2.5 Mbps
        case .fhd1080p: return 5_000_000  // 5 Mbps
        case .qhd1440p: return 10_000_000 // 10 Mbps
        case .uhd4k: return 25_000_000    // 25 Mbps
        case .uhd8k: return 100_000_000   // 100 Mbps
        }
    }
    
 /// 推荐帧率
    public var recommendedFrameRate: Int {
        switch self {
        case .sd480p, .hd720p: return 30
        case .fhd1080p: return 60
        case .qhd1440p: return 60
        case .uhd4k: return 30
        case .uhd8k: return 24
        }
    }
    
 /// 显示名称
    public var displayName: String {
        return rawValue
    }
}

// MARK: - 视频编码配置

/// 视频编码配置结构体 - 遵循 Sendable 协议以确保并发安全
public struct SkyBridgeVideoEncodingConfiguration: Sendable {
 /// 编解码器类型
    public let codec: SkyBridgeVideoCodec
 /// 视频分辨率
    public let resolution: CGSize
 /// 目标比特率（bps）
    public let bitrate: Int
 /// 帧率（fps）
    public let frameRate: Int
 /// 关键帧间隔
    public let keyFrameInterval: Int
 /// 编码质量（0.0-1.0）
    public let quality: Float
 /// 编码配置文件
    public let profile: SkyBridgeVideoProfile
 /// 是否启用B帧
    public let enableBFrames: Bool
 /// 是否启用硬件加速
    public let enableHardwareAcceleration: Bool
 /// 编码预设
    public let preset: VideoEncodingPreset
 /// 最大比特率（可选）
    public let maxBitrate: Int?
 /// 缓冲区大小（秒）
    public let bufferSize: TimeInterval
    
    public init(codec: SkyBridgeVideoCodec,
                resolution: CGSize,
                bitrate: Int,
                frameRate: Int,
                keyFrameInterval: Int,
                quality: Float,
                profile: SkyBridgeVideoProfile,
                enableBFrames: Bool,
                enableHardwareAcceleration: Bool,
                preset: VideoEncodingPreset = .medium,
                maxBitrate: Int? = nil,
                bufferSize: TimeInterval = 2.0) {
        self.codec = codec
        self.resolution = resolution
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.keyFrameInterval = keyFrameInterval
        self.quality = quality
        self.profile = profile
        self.enableBFrames = enableBFrames
        self.enableHardwareAcceleration = enableHardwareAcceleration
        self.preset = preset
        self.maxBitrate = maxBitrate ?? (bitrate * 2)
        self.bufferSize = bufferSize
    }
    
 /// 默认配置
    public static func defaultConfiguration() -> SkyBridgeVideoEncodingConfiguration {
        return SkyBridgeVideoEncodingConfiguration(
            codec: .h264,
            resolution: VideoResolutionPreset.fhd1080p.size,
            bitrate: VideoResolutionPreset.fhd1080p.recommendedBitrate,
            frameRate: VideoResolutionPreset.fhd1080p.recommendedFrameRate,
            keyFrameInterval: VideoResolutionPreset.fhd1080p.recommendedFrameRate,
            quality: VideoQualityLevel.high.qualityValue,
            profile: .h264Main,
            enableBFrames: false,
            enableHardwareAcceleration: true
        )
    }
    
 /// 高质量配置
    public static func highQualityConfiguration() -> SkyBridgeVideoEncodingConfiguration {
        return SkyBridgeVideoEncodingConfiguration(
            codec: .h265,
            resolution: VideoResolutionPreset.qhd1440p.size,
            bitrate: VideoResolutionPreset.qhd1440p.recommendedBitrate,
            frameRate: VideoResolutionPreset.qhd1440p.recommendedFrameRate,
            keyFrameInterval: VideoResolutionPreset.qhd1440p.recommendedFrameRate,
            quality: VideoQualityLevel.ultra.qualityValue,
            profile: .h265Main,
            enableBFrames: true,
            enableHardwareAcceleration: true,
            preset: .slow
        )
    }
    
 /// 低延迟配置
    public static func lowLatencyConfiguration() -> SkyBridgeVideoEncodingConfiguration {
        return SkyBridgeVideoEncodingConfiguration(
            codec: .h264,
            resolution: VideoResolutionPreset.hd720p.size,
            bitrate: VideoResolutionPreset.hd720p.recommendedBitrate,
            frameRate: 60,
            keyFrameInterval: 15, // 更频繁的关键帧以减少延迟
            quality: VideoQualityLevel.medium.qualityValue,
            profile: .h264Baseline,
            enableBFrames: false, // 禁用B帧以减少延迟
            enableHardwareAcceleration: true,
            preset: .ultraFast,
            bufferSize: 0.5 // 更小的缓冲区
        )
    }
    
 /// 从分辨率预设创建配置
    public static func configuration(for preset: VideoResolutionPreset,
                                   quality: VideoQualityLevel = .high,
                                   codec: SkyBridgeVideoCodec = .h264) -> SkyBridgeVideoEncodingConfiguration {
        let profile: SkyBridgeVideoProfile = codec == .h264 ? .h264Main : .h265Main
        let adjustedBitrate = Int(Float(preset.recommendedBitrate) * quality.bitrateMultiplier)
        
        return SkyBridgeVideoEncodingConfiguration(
            codec: codec,
            resolution: preset.size,
            bitrate: adjustedBitrate,
            frameRate: preset.recommendedFrameRate,
            keyFrameInterval: preset.recommendedFrameRate,
            quality: quality.qualityValue,
            profile: profile,
            enableBFrames: codec == .h265,
            enableHardwareAcceleration: true
        )
    }
}

// MARK: - 编码帧数据结构

/// 编码后的视频帧数据结构体 - 遵循 Sendable 协议以确保并发安全
public struct SkyBridgeEncodedVideoFrame: Sendable {
 /// 编码数据
    public let data: Data
 /// 显示时间戳
    public let presentationTime: CMTime
 /// 帧持续时间
    public let duration: CMTime
 /// 是否为关键帧
    public let isKeyFrame: Bool
 /// 编解码器
    public let codec: SkyBridgeVideoCodec
 /// 分辨率
    public let resolution: CGSize
 /// 编码时间戳
    public let encodingTimestamp: CFTimeInterval
 /// 序列号
    public let sequenceNumber: UInt64
    
    public init(data: Data,
                presentationTime: CMTime,
                duration: CMTime,
                isKeyFrame: Bool,
                codec: SkyBridgeVideoCodec,
                resolution: CGSize,
                encodingTimestamp: CFTimeInterval = CACurrentMediaTime(),
                sequenceNumber: UInt64) {
        self.data = data
        self.presentationTime = presentationTime
        self.duration = duration
        self.isKeyFrame = isKeyFrame
        self.codec = codec
        self.resolution = resolution
        self.encodingTimestamp = encodingTimestamp
        self.sequenceNumber = sequenceNumber
    }
    
 /// 数据大小（字节）
    public var size: Int {
        return data.count
    }
    
 /// 比特率（基于帧大小和持续时间）
    public var bitrate: UInt64 {
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds > 0 else { return 0 }
        return UInt64(Double(data.count * 8) / durationSeconds)
    }
    
 /// 帧类型描述
    public var frameTypeDescription: String {
        return isKeyFrame ? "关键帧" : "普通帧"
    }
}

// MARK: - 编码统计信息

/// 视频编码统计信息结构体 - 遵循 Sendable 协议以确保并发安全
public struct VideoEncodingStatistics: Sendable {
 /// 总编码帧数
    public let totalFrames: UInt64
 /// 关键帧数
    public let keyFrames: UInt64
 /// 总编码字节数
    public let totalBytes: UInt64
 /// 平均帧率
    public let averageFrameRate: Double
 /// 平均比特率
    public let averageBitrate: UInt64
 /// 瞬时比特率
    public let instantaneousBitrate: UInt64
 /// 压缩比
    public let compressionRatio: Double
 /// 平均编码延迟
    public let averageEncodingLatency: TimeInterval
 /// 丢帧数
    public let droppedFrames: UInt64
 /// 编码错误数
    public let encodingErrors: UInt64
 /// 开始时间
    public let startTime: Date
 /// 持续时间
    public let duration: TimeInterval
    
    public init(totalFrames: UInt64,
                keyFrames: UInt64,
                totalBytes: UInt64,
                averageFrameRate: Double,
                averageBitrate: UInt64,
                instantaneousBitrate: UInt64,
                compressionRatio: Double,
                averageEncodingLatency: TimeInterval,
                droppedFrames: UInt64,
                encodingErrors: UInt64,
                startTime: Date,
                duration: TimeInterval) {
        self.totalFrames = totalFrames
        self.keyFrames = keyFrames
        self.totalBytes = totalBytes
        self.averageFrameRate = averageFrameRate
        self.averageBitrate = averageBitrate
        self.instantaneousBitrate = instantaneousBitrate
        self.compressionRatio = compressionRatio
        self.averageEncodingLatency = averageEncodingLatency
        self.droppedFrames = droppedFrames
        self.encodingErrors = encodingErrors
        self.startTime = startTime
        self.duration = duration
    }
    
 /// 关键帧比例
    public var keyFrameRatio: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(keyFrames) / Double(totalFrames)
    }
    
 /// 丢帧率
    public var dropFrameRate: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(droppedFrames) / Double(totalFrames + droppedFrames)
    }
    
 /// 错误率
    public var errorRate: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(encodingErrors) / Double(totalFrames)
    }
}

// MARK: - 编码错误定义

/// 视频编码错误
public enum SkyBridgeVideoEncodingError: LocalizedError {
    case sessionCreationFailed(OSStatus)
    case sessionPreparationFailed(OSStatus)
    case sessionNotInitialized
    case encoderNotReady
    case encodingFailed(OSStatus)
    case propertySetFailed(String, OSStatus)
    case propertyUpdateFailed(OSStatus)
    case unsupportedCodec(SkyBridgeVideoCodec)
    case unsupportedResolution(CGSize)
    case unsupportedProfile(SkyBridgeVideoProfile)
    case invalidConfiguration(String)
    case hardwareNotAvailable
    case memoryAllocationFailed
    case bufferOverflow
    case timeoutError
    
    public var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "压缩会话创建失败: \(status)"
        case .sessionPreparationFailed(let status):
            return "压缩会话准备失败: \(status)"
        case .sessionNotInitialized:
            return "压缩会话未初始化"
        case .encoderNotReady:
            return "编码器未就绪"
        case .encodingFailed(let status):
            return "视频编码失败: \(status)"
        case .propertySetFailed(let property, let status):
            return "设置属性 \(property) 失败: \(status)"
        case .propertyUpdateFailed(let status):
            return "更新属性失败: \(status)"
        case .unsupportedCodec(let codec):
            return "不支持的编解码器: \(codec.displayName)"
        case .unsupportedResolution(let resolution):
            return "不支持的分辨率: \(Int(resolution.width))x\(Int(resolution.height))"
        case .unsupportedProfile(let profile):
            return "不支持的编码配置文件: \(profile.displayName)"
        case .invalidConfiguration(let reason):
            return "无效的编码配置: \(reason)"
        case .hardwareNotAvailable:
            return "硬件编码器不可用"
        case .memoryAllocationFailed:
            return "内存分配失败"
        case .bufferOverflow:
            return "缓冲区溢出"
        case .timeoutError:
            return "编码超时"
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .hardwareNotAvailable:
            return "尝试使用软件编码器"
        case .unsupportedCodec:
            return "尝试使用H.264编解码器"
        case .unsupportedResolution:
            return "尝试使用较低的分辨率"
        case .memoryAllocationFailed:
            return "释放内存后重试"
        case .bufferOverflow:
            return "降低比特率或帧率"
        default:
            return nil
        }
    }
}