package com.skybridge.compass.screenmirroring

import android.os.Parcelable
import kotlinx.parcelize.Parcelize
import kotlinx.serialization.Serializable

/**
 * 屏幕镜像配置
 */
@Parcelize
@Serializable
data class MirroringConfiguration(
    val frameRate: Int = 60,
    val bitrate: Int = 8_000_000, // 8Mbps
    val codec: VideoCodec = VideoCodec.H264,
    val audioEnabled: Boolean = true,
    val resolution: Resolution = Resolution.HD_1080P,
    val adaptiveBitrate: Boolean = true,
    val lowLatencyMode: Boolean = true,
    val qualityPreset: QualityPreset = QualityPreset.HIGH
) : Parcelable

/**
 * 视频编码格式
 */
@Serializable
enum class VideoCodec(val mimeType: String) {
    H264("video/avc"),
    H265("video/hevc"),
    VP8("video/x-vnd.on2.vp8"),
    VP9("video/x-vnd.on2.vp9")
}

/**
 * 分辨率配置
 */
@Parcelize
@Serializable
data class Resolution(
    val width: Int,
    val height: Int,
    val displayName: String
) : Parcelable {
    companion object {
        val HD_720P = Resolution(1280, 720, "720p HD")
        val HD_1080P = Resolution(1920, 1080, "1080p Full HD")
        val QHD_1440P = Resolution(2560, 1440, "1440p QHD")
        val UHD_4K = Resolution(3840, 2160, "4K UHD")
        
        fun fromDisplayMetrics(width: Int, height: Int): Resolution {
            return Resolution(width, height, "${width}x${height}")
        }
    }
}

/**
 * 质量预设
 */
@Serializable
enum class QualityPreset(
    val bitrate: Int,
    val frameRate: Int,
    val description: String
) {
    LOW(2_000_000, 30, "低质量 - 省电模式"),
    MEDIUM(4_000_000, 45, "中等质量 - 平衡模式"),
    HIGH(8_000_000, 60, "高质量 - 性能模式"),
    ULTRA(12_000_000, 60, "超高质量 - 极致体验")
}

/**
 * 镜像状态
 */
@Serializable
sealed class MirroringState {
    @Serializable
    object Idle : MirroringState()
    
    @Serializable
    object Initializing : MirroringState()
    
    @Serializable
    data class Active(
        val sessionId: String,
        val targetDevice: String,
        val startTime: Long,
        val currentBitrate: Int,
        val currentFrameRate: Int,
        val networkLatency: Long
    ) : MirroringState()
    
    @Serializable
    data class Paused(
        val sessionId: String,
        val pauseTime: Long
    ) : MirroringState()
    
    @Serializable
    data class Error(
        val error: MirroringError,
        val sessionId: String? = null
    ) : MirroringState()
}

/**
 * 镜像错误类型
 */
@Serializable
sealed class MirroringError {
    @Serializable
    object PermissionDenied : MirroringError()
    
    @Serializable
    object MediaProjectionFailed : MirroringError()
    
    @Serializable
    object EncoderInitializationFailed : MirroringError()
    
    @Serializable
    object NetworkConnectionFailed : MirroringError()
    
    @Serializable
    data class EncodingError(val message: String) : MirroringError()
    
    @Serializable
    data class TransmissionError(val message: String) : MirroringError()
    
    @Serializable
    data class UnknownError(val message: String) : MirroringError()
}

/**
 * 编码器配置
 */
@Parcelize
@Serializable
data class EncoderConfiguration(
    val codec: VideoCodec,
    val bitrate: Int,
    val frameRate: Int,
    val iFrameInterval: Int = 2, // I帧间隔（秒）
    val bitrateMode: BitrateMode = BitrateMode.VBR,
    val profile: Int = 0, // 编码器配置文件
    val level: Int = 0, // 编码器级别
    val colorFormat: Int = 0 // 颜色格式
) : Parcelable

/**
 * 码率模式
 */
@Serializable
enum class BitrateMode(val value: Int) {
    CQ(0), // 恒定质量
    VBR(1), // 可变码率
    CBR(2) // 恒定码率
}

/**
 * 网络传输配置
 */
/**
 * 镜像会话信息
 */
@Parcelize
@Serializable
data class MirroringSession(
    val sessionId: String,
    val targetDeviceId: String,
    val targetDeviceName: String,
    val configuration: MirroringConfiguration,
    val startTime: Long,
    val endTime: Long? = null,
    val status: SessionStatus = SessionStatus.ACTIVE
) : Parcelable

/**
 * 会话状态
 */
@Serializable
enum class SessionStatus {
    ACTIVE,
    PAUSED,
    COMPLETED,
    FAILED
}

/**
 * 性能统计
 */
@Serializable
data class MirroringStats(
    val sessionId: String,
    val duration: Long, // 会话持续时间（毫秒）
    val framesSent: Long, // 发送的帧数
    val framesDropped: Long, // 丢弃的帧数
    val averageBitrate: Int, // 平均码率
    val averageFrameRate: Float, // 平均帧率
    val networkLatency: Long, // 网络延迟（毫秒）
    val encodingLatency: Long, // 编码延迟（毫秒）
    val totalDataSent: Long, // 总发送数据量（字节）
    val compressionRatio: Float, // 压缩比
    val errorCount: Int, // 错误次数
    val lastUpdateTime: Long = System.currentTimeMillis()
)

/**
 * 帧数据
 */
@Serializable
data class FrameData(
    val frameId: Long,
    val timestamp: Long,
    val data: ByteArray,
    val width: Int,
    val height: Int,
    val format: Int,
    val isKeyFrame: Boolean = false
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as FrameData

        if (frameId != other.frameId) return false
        if (timestamp != other.timestamp) return false
        if (!data.contentEquals(other.data)) return false
        if (width != other.width) return false
        if (height != other.height) return false
        if (format != other.format) return false
        if (isKeyFrame != other.isKeyFrame) return false

        return true
    }

    override fun hashCode(): Int {
        var result = frameId.hashCode()
        result = 31 * result + timestamp.hashCode()
        result = 31 * result + data.contentHashCode()
        result = 31 * result + width
        result = 31 * result + height
        result = 31 * result + format
        result = 31 * result + isKeyFrame.hashCode()
        return result
    }
}

/**
 * 音频配置
 */
@Parcelize
@Serializable
data class AudioConfiguration(
    val enabled: Boolean = true,
    val sampleRate: Int = 44100,
    val channelCount: Int = 2,
    val bitrate: Int = 128_000, // 128kbps
    val codec: AudioCodec = AudioCodec.AAC
) : Parcelable

/**
 * 音频编码格式
 */
@Serializable
enum class AudioCodec(val mimeType: String) {
    AAC("audio/mp4a-latm"),
    OPUS("audio/opus"),
    MP3("audio/mpeg")
}

/**
 * 设备能力信息
 */
@Serializable
data class DeviceCapabilities(
    val supportedCodecs: List<VideoCodec>,
    val maxResolution: Resolution,
    val maxFrameRate: Int,
    val maxBitrate: Int,
    val hardwareAcceleration: Boolean,
    val audioSupport: Boolean,
    val lowLatencySupport: Boolean
)

/**
 * 镜像请求
 */
@Serializable
data class MirroringRequest(
    val targetDeviceId: String,
    val configuration: MirroringConfiguration,
    val requestId: String = java.util.UUID.randomUUID().toString(),
    val timestamp: Long = System.currentTimeMillis()
)

/**
 * 镜像响应
 */
@Serializable
data class MirroringResponse(
    val requestId: String,
    val accepted: Boolean,
    val sessionId: String? = null,
    val error: String? = null,
    val supportedConfiguration: MirroringConfiguration? = null,
    val timestamp: Long = System.currentTimeMillis()
)