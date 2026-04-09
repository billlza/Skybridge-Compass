package com.skybridge.compass.screenmirroring.model

import android.os.Parcelable
import kotlinx.parcelize.Parcelize
import kotlinx.serialization.Serializable

/**
 * 屏幕捕获配置
 */
@Parcelize
@Serializable
data class ScreenCaptureConfig(
    // 捕获模式
    val captureMode: CaptureMode = CaptureMode.STREAMING,
    
    // 输出格式
    val outputFormat: OutputFormat = OutputFormat.BITMAP,
    
    // 分辨率
    val width: Int? = null,
    val height: Int? = null,
    
    // 质量设置
    val quality: Quality = Quality.MEDIUM,
    
    // 帧率 (仅用于流式和录制)
    val frameRate: Int = 30,
    
    // 比特率 (仅用于录制)
    val bitRate: Int = 2000000, // 2Mbps
    
    // 是否启用音频捕获
    val enableAudio: Boolean = false,
    
    // 音频采样率
    val audioSampleRate: Int = 44100,
    
    // 音频比特率
    val audioBitRate: Int = 128000,
    
    // 是否启用硬件加速
    val enableHardwareAcceleration: Boolean = true,
    
    // 编码器配置
    val encoderConfig: EncoderConfig = EncoderConfig()
) : Parcelable {
    
    /**
     * 捕获模式
     */
    @Serializable
    enum class CaptureMode {
        STREAMING,    // 实时流式传输
        RECORDING,    // 录制到文件
        SCREENSHOT    // 单次截图
    }
    
    /**
     * 输出格式
     */
    @Serializable
    enum class OutputFormat {
        BITMAP,       // Bitmap 格式
        BYTES,        // 字节数组
        ENCODED       // 编码后的数据
    }
    
    /**
     * 质量等级
     */
    @Serializable
    enum class Quality(
        val scale: Float,
        val compressionQuality: Int,
        val description: String
    ) {
        LOW(0.5f, 60, "低质量"),
        MEDIUM(0.75f, 80, "中等质量"),
        HIGH(1.0f, 90, "高质量"),
        ULTRA(1.0f, 100, "超高质量")
    }
    
    /**
     * 编码器配置
     */
    @Parcelize
    @Serializable
    data class EncoderConfig(
        // 编码器类型
        val codecType: CodecType = CodecType.H264,
        
        // I帧间隔 (秒)
        val iFrameInterval: Int = 2,
        
        // 编码复杂度
        val complexity: Complexity = Complexity.BALANCED,
        
        // 是否使用B帧
        val useBFrames: Boolean = false,
        
        // GOP大小
        val gopSize: Int = 30,
        
        // 编码配置文件
        val profile: String = "baseline",
        
        // 编码级别
        val level: String = "3.1"
    ) : Parcelable {
        
        /**
         * 编码器类型
         */
        @Serializable
        enum class CodecType(val mimeType: String) {
            H264("video/avc"),
            H265("video/hevc"),
            VP8("video/x-vnd.on2.vp8"),
            VP9("video/x-vnd.on2.vp9"),
            AV1("video/av01")
        }
        
        /**
         * 编码复杂度
         */
        @Serializable
        enum class Complexity {
            FAST,      // 快速编码，质量较低
            BALANCED,  // 平衡模式
            QUALITY    // 高质量编码，速度较慢
        }
    }
    
    /**
     * 获取实际的宽度
     */
    fun getActualWidth(defaultWidth: Int): Int {
        return width?.let { (it * quality.scale).toInt() } ?: (defaultWidth * quality.scale).toInt()
    }
    
    /**
     * 获取实际的高度
     */
    fun getActualHeight(defaultHeight: Int): Int {
        return height?.let { (it * quality.scale).toInt() } ?: (defaultHeight * quality.scale).toInt()
    }
    
    /**
     * 获取压缩质量
     */
    fun getCompressionQuality(): Int = quality.compressionQuality
    
    /**
     * 是否为高质量模式
     */
    fun isHighQuality(): Boolean = quality in listOf(Quality.HIGH, Quality.ULTRA)
    
    /**
     * 是否需要实时处理
     */
    fun isRealTime(): Boolean = captureMode == CaptureMode.STREAMING
    
    /**
     * 获取目标比特率
     */
    fun getTargetBitRate(): Int {
        return when (quality) {
            Quality.LOW -> bitRate / 2
            Quality.MEDIUM -> bitRate
            Quality.HIGH -> bitRate * 2
            Quality.ULTRA -> bitRate * 3
        }
    }
    
    companion object {
        /**
         * 创建低质量配置
         */
        fun lowQuality() = ScreenCaptureConfig(
            quality = Quality.LOW,
            frameRate = 15,
            bitRate = 500000
        )
        
        /**
         * 创建中等质量配置
         */
        fun mediumQuality() = ScreenCaptureConfig(
            quality = Quality.MEDIUM,
            frameRate = 30,
            bitRate = 2000000
        )
        
        /**
         * 创建高质量配置
         */
        fun highQuality() = ScreenCaptureConfig(
            quality = Quality.HIGH,
            frameRate = 60,
            bitRate = 5000000
        )
        
        /**
         * 创建超高质量配置
         */
        fun ultraQuality() = ScreenCaptureConfig(
            quality = Quality.ULTRA,
            frameRate = 60,
            bitRate = 10000000
        )
        
        /**
         * 创建截图配置
         */
        fun screenshot() = ScreenCaptureConfig(
            captureMode = CaptureMode.SCREENSHOT,
            outputFormat = OutputFormat.BITMAP,
            quality = Quality.HIGH
        )
        
        /**
         * 创建录制配置
         */
        fun recording(quality: Quality = Quality.MEDIUM) = ScreenCaptureConfig(
            captureMode = CaptureMode.RECORDING,
            outputFormat = OutputFormat.ENCODED,
            quality = quality,
            enableAudio = true
        )
        
        /**
         * 创建流式传输配置
         */
        fun streaming(quality: Quality = Quality.MEDIUM) = ScreenCaptureConfig(
            captureMode = CaptureMode.STREAMING,
            outputFormat = OutputFormat.ENCODED,
            quality = quality,
            frameRate = 30
        )
    }
}