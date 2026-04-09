package com.skybridge.compass.mirroring.domain.entities

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * 屏幕镜像会话实体
 */
@Serializable
data class MirroringSession(
    val id: String = UUID.randomUUID().toString(),
    val deviceId: String,
    val deviceName: String,
    val sessionType: MirroringType,
    val quality: VideoQuality,
    val status: MirroringStatus,
    val startTime: Long = System.currentTimeMillis(),
    val endTime: Long? = null,
    val frameRate: Int = 30,
    val bitrate: Int = 2000000, // 2 Mbps
    val resolution: Resolution,
    val audioEnabled: Boolean = true,
    val compressionLevel: CompressionLevel = CompressionLevel.BALANCED,
    val encryptionEnabled: Boolean = true,
    val networkProtocol: NetworkProtocol = NetworkProtocol.TCP,
    val latency: Long = 0, // 延迟（毫秒）
    val packetLoss: Float = 0f, // 丢包率
    val bandwidth: Long = 0, // 带宽使用（字节/秒）
    val errorCount: Int = 0,
    val reconnectCount: Int = 0
) {
    /**
     * 会话持续时间（毫秒）
     */
    val duration: Long
        get() = (endTime ?: System.currentTimeMillis()) - startTime
    
    /**
     * 是否为活跃会话
     */
    val isActive: Boolean
        get() = status == MirroringStatus.CONNECTED || status == MirroringStatus.STREAMING
    
    /**
     * 连接质量评分（0-100）
     */
    val qualityScore: Int
        get() {
            var score = 100
            
            // 延迟影响
            when {
                latency > 200 -> score -= 30
                latency > 100 -> score -= 15
                latency > 50 -> score -= 5
            }
            
            // 丢包率影响
            when {
                packetLoss > 0.05f -> score -= 25
                packetLoss > 0.02f -> score -= 10
                packetLoss > 0.01f -> score -= 5
            }
            
            // 错误次数影响
            score -= (errorCount * 2).coerceAtMost(20)
            
            return score.coerceAtLeast(0)
        }
}

/**
 * 镜像类型
 */
@Serializable
enum class MirroringType {
    SCREEN_ONLY,    // 仅屏幕
    AUDIO_ONLY,     // 仅音频
    SCREEN_AUDIO,   // 屏幕+音频
    CAMERA,         // 摄像头
    FULL_DEVICE     // 完整设备镜像
}

/**
 * 镜像状态
 */
@Serializable
enum class MirroringStatus {
    INITIALIZING,   // 初始化中
    CONNECTING,     // 连接中
    CONNECTED,      // 已连接
    STREAMING,      // 流媒体传输中
    PAUSED,         // 暂停
    RECONNECTING,   // 重连中
    DISCONNECTED,   // 已断开
    ERROR,          // 错误
    TIMEOUT         // 超时
}

/**
 * 视频质量
 */
@Serializable
enum class VideoQuality(
    val displayName: String,
    val width: Int,
    val height: Int,
    val bitrate: Int,
    val frameRate: Int
) {
    LOW("低质量", 640, 480, 500000, 15),
    MEDIUM("中等质量", 1280, 720, 1500000, 24),
    HIGH("高质量", 1920, 1080, 3000000, 30),
    ULTRA("超高质量", 2560, 1440, 6000000, 60),
    AUTO("自动调节", 0, 0, 0, 0); // 根据网络条件自动调节
    
    val resolution: Resolution
        get() = Resolution(width, height)
}

/**
 * 分辨率
 */
@Serializable
data class Resolution(
    val width: Int,
    val height: Int
) {
    val aspectRatio: Float
        get() = width.toFloat() / height.toFloat()
    
    val pixelCount: Int
        get() = width * height
    
    override fun toString(): String = "${width}x${height}"
    
    companion object {
        val HD = Resolution(1280, 720)
        val FULL_HD = Resolution(1920, 1080)
        val QHD = Resolution(2560, 1440)
        val UHD_4K = Resolution(3840, 2160)
    }
}

/**
 * 压缩级别
 */
@Serializable
enum class CompressionLevel(
    val displayName: String,
    val compressionRatio: Float,
    val qualityLoss: Float
) {
    NONE("无压缩", 1.0f, 0.0f),
    LOW("低压缩", 0.8f, 0.1f),
    BALANCED("平衡", 0.6f, 0.2f),
    HIGH("高压缩", 0.4f, 0.3f),
    MAXIMUM("最大压缩", 0.2f, 0.5f)
}

/**
 * 网络协议
 */
@Serializable
enum class NetworkProtocol(
    val displayName: String,
    val isReliable: Boolean,
    val overhead: Float
) {
    TCP("TCP", true, 0.1f),
    UDP("UDP", false, 0.05f),
    QUIC("QUIC", true, 0.08f),
    WEBRTC("WebRTC", true, 0.12f)
}