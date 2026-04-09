package com.skybridge.compass.screenmirroring.model

import android.graphics.Bitmap
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient

/**
 * 屏幕帧数据
 */
@Serializable
data class ScreenFrame(
    // 时间戳
    val timestamp: Long,
    
    // 帧宽度
    val width: Int,
    
    // 帧高度
    val height: Int,
    
    // 数据格式
    val format: Format,
    
    // 帧序号
    val frameNumber: Long = 0,
    
    // 是否为关键帧
    val isKeyFrame: Boolean = false,
    
    // 压缩质量 (0-100)
    val quality: Int = 80,
    
    // 数据大小 (字节)
    val dataSize: Int = 0,
    
    // 编码时间 (毫秒)
    val encodeTime: Long = 0,
    
    // 额外元数据
    val metadata: Map<String, String> = emptyMap(),
    
    // Bitmap 数据 (仅当格式为 BITMAP 时使用)
    @Transient
    val bitmap: Bitmap? = null,
    
    // 字节数据 (仅当格式为 BYTES 或 ENCODED 时使用)
    @Transient
    val data: ByteArray? = null,
    
    // 编码后的数据 (仅当格式为 ENCODED 时使用)
    @Transient
    val encodedData: EncodedData? = null
) {
    
    /**
     * 数据格式
     */
    @Serializable
    enum class Format {
        BITMAP,     // Android Bitmap
        BYTES,      // 原始字节数组
        ENCODED     // 编码后的数据 (H.264, H.265等)
    }
    
    /**
     * 编码后的数据
     */
    data class EncodedData(
        val data: ByteArray,
        val codecType: String,
        val isKeyFrame: Boolean,
        val presentationTimeUs: Long,
        val flags: Int = 0
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (javaClass != other?.javaClass) return false
            
            other as EncodedData
            
            if (!data.contentEquals(other.data)) return false
            if (codecType != other.codecType) return false
            if (isKeyFrame != other.isKeyFrame) return false
            if (presentationTimeUs != other.presentationTimeUs) return false
            if (flags != other.flags) return false
            
            return true
        }
        
        override fun hashCode(): Int {
            var result = data.contentHashCode()
            result = 31 * result + codecType.hashCode()
            result = 31 * result + isKeyFrame.hashCode()
            result = 31 * result + presentationTimeUs.hashCode()
            result = 31 * result + flags
            return result
        }
    }
    
    /**
     * 获取帧的宽高比
     */
    val aspectRatio: Float
        get() = width.toFloat() / height.toFloat()
    
    /**
     * 获取帧的像素数量
     */
    val pixelCount: Int
        get() = width * height
    
    /**
     * 是否为有效帧
     */
    val isValid: Boolean
        get() = when (format) {
            Format.BITMAP -> bitmap != null && !bitmap.isRecycled
            Format.BYTES -> data != null && data.isNotEmpty()
            Format.ENCODED -> encodedData != null && encodedData.data.isNotEmpty()
        }
    
    /**
     * 获取实际数据大小
     */
    val actualDataSize: Int
        get() = when (format) {
            Format.BITMAP -> bitmap?.byteCount ?: 0
            Format.BYTES -> data?.size ?: 0
            Format.ENCODED -> encodedData?.data?.size ?: 0
        }
    
    /**
     * 获取帧率 (基于时间戳计算)
     */
    fun calculateFrameRate(previousFrame: ScreenFrame?): Float {
        if (previousFrame == null) return 0f
        val timeDiff = timestamp - previousFrame.timestamp
        return if (timeDiff > 0) 1000f / timeDiff else 0f
    }
    
    /**
     * 转换为字节数组
     */
    fun toByteArray(): ByteArray? {
        return when (format) {
            Format.BITMAP -> {
                bitmap?.let { bmp ->
                    val bytes = ByteArray(bmp.byteCount)
                    val buffer = java.nio.ByteBuffer.allocate(bmp.byteCount)
                    bmp.copyPixelsToBuffer(buffer)
                    buffer.rewind()
                    buffer.get(bytes)
                    bytes
                }
            }
            Format.BYTES -> data
            Format.ENCODED -> encodedData?.data
        }
    }
    
    /**
     * 获取压缩比
     */
    fun getCompressionRatio(): Float {
        val uncompressedSize = width * height * 4 // ARGB_8888
        val compressedSize = actualDataSize
        return if (compressedSize > 0) uncompressedSize.toFloat() / compressedSize else 0f
    }
    
    /**
     * 创建帧的副本
     */
    fun copy(
        timestamp: Long = this.timestamp,
        width: Int = this.width,
        height: Int = this.height,
        format: Format = this.format,
        frameNumber: Long = this.frameNumber,
        isKeyFrame: Boolean = this.isKeyFrame,
        quality: Int = this.quality,
        dataSize: Int = this.dataSize,
        encodeTime: Long = this.encodeTime,
        metadata: Map<String, String> = this.metadata
    ): ScreenFrame {
        return ScreenFrame(
            timestamp = timestamp,
            width = width,
            height = height,
            format = format,
            frameNumber = frameNumber,
            isKeyFrame = isKeyFrame,
            quality = quality,
            dataSize = dataSize,
            encodeTime = encodeTime,
            metadata = metadata,
            bitmap = this.bitmap,
            data = this.data,
            encodedData = this.encodedData
        )
    }
    
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        
        other as ScreenFrame
        
        if (timestamp != other.timestamp) return false
        if (width != other.width) return false
        if (height != other.height) return false
        if (format != other.format) return false
        if (frameNumber != other.frameNumber) return false
        if (isKeyFrame != other.isKeyFrame) return false
        if (quality != other.quality) return false
        if (dataSize != other.dataSize) return false
        if (encodeTime != other.encodeTime) return false
        if (metadata != other.metadata) return false
        if (bitmap != other.bitmap) return false
        if (data != null) {
            if (other.data == null) return false
            if (!data.contentEquals(other.data)) return false
        } else if (other.data != null) return false
        if (encodedData != other.encodedData) return false
        
        return true
    }
    
    override fun hashCode(): Int {
        var result = timestamp.hashCode()
        result = 31 * result + width
        result = 31 * result + height
        result = 31 * result + format.hashCode()
        result = 31 * result + frameNumber.hashCode()
        result = 31 * result + isKeyFrame.hashCode()
        result = 31 * result + quality
        result = 31 * result + dataSize
        result = 31 * result + encodeTime.hashCode()
        result = 31 * result + metadata.hashCode()
        result = 31 * result + (bitmap?.hashCode() ?: 0)
        result = 31 * result + (data?.contentHashCode() ?: 0)
        result = 31 * result + (encodedData?.hashCode() ?: 0)
        return result
    }
    
    companion object {
        /**
         * 创建 Bitmap 帧
         */
        fun fromBitmap(
            bitmap: Bitmap,
            frameNumber: Long = 0,
            quality: Int = 80,
            metadata: Map<String, String> = emptyMap()
        ): ScreenFrame {
            return ScreenFrame(
                timestamp = System.currentTimeMillis(),
                width = bitmap.width,
                height = bitmap.height,
                format = Format.BITMAP,
                frameNumber = frameNumber,
                quality = quality,
                dataSize = bitmap.byteCount,
                metadata = metadata,
                bitmap = bitmap
            )
        }
        
        /**
         * 创建字节数组帧
         */
        fun fromBytes(
            data: ByteArray,
            width: Int,
            height: Int,
            frameNumber: Long = 0,
            quality: Int = 80,
            metadata: Map<String, String> = emptyMap()
        ): ScreenFrame {
            return ScreenFrame(
                timestamp = System.currentTimeMillis(),
                width = width,
                height = height,
                format = Format.BYTES,
                frameNumber = frameNumber,
                quality = quality,
                dataSize = data.size,
                metadata = metadata,
                data = data
            )
        }
        
        /**
         * 创建编码帧
         */
        fun fromEncodedData(
            encodedData: EncodedData,
            width: Int,
            height: Int,
            frameNumber: Long = 0,
            quality: Int = 80,
            encodeTime: Long = 0,
            metadata: Map<String, String> = emptyMap()
        ): ScreenFrame {
            return ScreenFrame(
                timestamp = System.currentTimeMillis(),
                width = width,
                height = height,
                format = Format.ENCODED,
                frameNumber = frameNumber,
                isKeyFrame = encodedData.isKeyFrame,
                quality = quality,
                dataSize = encodedData.data.size,
                encodeTime = encodeTime,
                metadata = metadata,
                encodedData = encodedData
            )
        }
    }
}