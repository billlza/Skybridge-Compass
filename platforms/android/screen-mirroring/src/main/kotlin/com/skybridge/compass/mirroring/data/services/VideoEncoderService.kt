package com.skybridge.compass.mirroring.data.services

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import com.skybridge.compass.mirroring.domain.entities.VideoQuality
import com.skybridge.compass.mirroring.domain.entities.Resolution
import com.skybridge.compass.mirroring.domain.entities.CompressionLevel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.*
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong

/**
 * 视频编码服务
 * 负责屏幕内容的视频编码处理
 */
class VideoEncoderService {
    
    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var isInitialized = false
    private var isEncoding = false
    
    private val encoderScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val stats = EncoderStats()
    
    // 编码参数
    private var currentResolution = Resolution(1920, 1080)
    private var currentBitrate = 2000000
    private var currentFrameRate = 30
    private var currentCompressionLevel = CompressionLevel.BALANCED
    
    // 回调接口
    private var onEncodedDataCallback: ((ByteBuffer, MediaCodec.BufferInfo) -> Unit)? = null
    
    /**
     * 初始化编码器
     */
    suspend fun initialize(
        resolution: Resolution,
        bitrate: Int,
        frameRate: Int,
        compressionLevel: CompressionLevel
    ) = withContext(Dispatchers.IO) {
        try {
            if (isInitialized) {
                release()
            }
            
            currentResolution = resolution
            currentBitrate = bitrate
            currentFrameRate = frameRate
            currentCompressionLevel = compressionLevel
            
            // 创建MediaFormat
            val format = createMediaFormat(resolution, bitrate, frameRate, compressionLevel)
            
            // 创建编码器
            mediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                inputSurface = createInputSurface()
                start()
            }
            
            isInitialized = true
            startEncoding()
            
            Log.d(TAG, "视频编码器初始化成功: ${resolution.width}x${resolution.height}@${frameRate}fps, ${bitrate}bps")
            
        } catch (e: Exception) {
            Log.e(TAG, "视频编码器初始化失败", e)
            throw e
        }
    }
    
    /**
     * 重新配置编码器
     */
    suspend fun reconfigure(
        resolution: Resolution,
        bitrate: Int,
        frameRate: Int
    ) = withContext(Dispatchers.IO) {
        try {
            mediaCodec?.let { codec ->
                // 动态调整比特率
                val bundle = android.os.Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate)
                }
                codec.setParameters(bundle)
                
                currentBitrate = bitrate
                stats.bitrateChanges.incrementAndGet()
                
                Log.d(TAG, "编码器重新配置: 比特率=${bitrate}bps")
            }
            
            // 如果分辨率或帧率改变，需要重新初始化
            if (resolution != currentResolution || frameRate != currentFrameRate) {
                initialize(resolution, bitrate, frameRate, currentCompressionLevel)
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "编码器重新配置失败", e)
            throw e
        }
    }
    
    /**
     * 更新分辨率
     */
    suspend fun updateResolution(resolution: Resolution) {
        if (resolution != currentResolution) {
            reconfigure(resolution, currentBitrate, currentFrameRate)
        }
    }
    
    /**
     * 更新压缩级别
     */
    suspend fun updateCompressionLevel(compressionLevel: CompressionLevel) {
        currentCompressionLevel = compressionLevel
        // 重新配置编码器以应用新的压缩级别
        reconfigure(currentResolution, currentBitrate, currentFrameRate)
    }
    
    /**
     * 更新帧率
     */
    suspend fun updateFrameRate(frameRate: Int) {
        if (frameRate != currentFrameRate) {
            reconfigure(currentResolution, currentBitrate, frameRate)
        }
    }
    
    /**
     * 更新比特率
     */
    suspend fun updateBitrate(bitrate: Int) {
        if (bitrate != currentBitrate) {
            reconfigure(currentResolution, bitrate, currentFrameRate)
        }
    }
    
    /**
     * 获取输入Surface
     */
    fun getInputSurface(): Surface? = inputSurface
    
    /**
     * 设置编码数据回调
     */
    fun setEncodedDataCallback(callback: (ByteBuffer, MediaCodec.BufferInfo) -> Unit) {
        onEncodedDataCallback = callback
    }
    
    /**
     * 获取编码器统计信息
     */
    fun getEncoderStats(): Map<String, Any> {
        return mapOf(
            "framesSent" to stats.framesSent.get(),
            "framesDropped" to stats.framesDropped.get(),
            "averageBitrate" to calculateAverageBitrate(),
            "encodingLatency" to stats.averageEncodingLatency.get(),
            "bitrateChanges" to stats.bitrateChanges.get(),
            "keyFramesSent" to stats.keyFramesSent.get(),
            "totalBytesEncoded" to stats.totalBytesEncoded.get()
        )
    }
    
    /**
     * 释放编码器资源
     */
    fun release() {
        try {
            isEncoding = false
            isInitialized = false
            
            mediaCodec?.let { codec ->
                try {
                    if (isEncoding) {
                        codec.stop()
                    }
                    codec.release()
                } catch (e: Exception) {
                    Log.w(TAG, "编码器释放异常", e)
                }
            }
            
            inputSurface?.release()
            
            mediaCodec = null
            inputSurface = null
            onEncodedDataCallback = null
            
            Log.d(TAG, "视频编码器已释放")
        } catch (e: Exception) {
            Log.e(TAG, "释放视频编码器失败", e)
        }
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        try {
            encoderScope.cancel()
            release()
        } catch (e: Exception) {
            Log.e(TAG, "清理视频编码器失败", e)
        }
    }
    
    /**
     * 创建媒体格式
     */
    private fun createMediaFormat(
        resolution: Resolution,
        bitrate: Int,
        frameRate: Int,
        compressionLevel: CompressionLevel
    ): MediaFormat {
        return MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, resolution.width, resolution.height).apply {
            // 基本参数
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2) // 2秒一个关键帧
            
            // 编码质量设置
            when (compressionLevel) {
                CompressionLevel.NONE -> {
                    setInteger(MediaFormat.KEY_QUALITY, 100)
                    setInteger(MediaFormat.KEY_COMPLEXITY, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CQ)
                }
                CompressionLevel.LOW -> {
                    setInteger(MediaFormat.KEY_QUALITY, 80)
                    setInteger(MediaFormat.KEY_COMPLEXITY, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                }
                CompressionLevel.BALANCED -> {
                    setInteger(MediaFormat.KEY_QUALITY, 60)
                    setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                }
                CompressionLevel.HIGH -> {
                    setInteger(MediaFormat.KEY_QUALITY, 40)
                    setInteger(MediaFormat.KEY_COMPLEXITY, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                }
                CompressionLevel.MAXIMUM -> {
                    setInteger(MediaFormat.KEY_QUALITY, 20)
                    setInteger(MediaFormat.KEY_COMPLEXITY, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                }
            }
            
            // 高级编码设置
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
            setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel41)
            
            // 低延迟设置
            setInteger(MediaFormat.KEY_LATENCY, 0)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // 最高优先级
        }
    }
    
    /**
     * 开始编码循环
     */
    private fun startEncoding() {
        isEncoding = true
        
        encoderScope.launch {
            val codec = mediaCodec ?: return@launch
            val bufferInfo = MediaCodec.BufferInfo()
            
            while (isEncoding) {
                try {
                    // 获取输出缓冲区
                    val outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                    
                    when {
                        outputBufferIndex >= 0 -> {
                            val encodedData = codec.getOutputBuffer(outputBufferIndex)
                            
                            if (encodedData != null && bufferInfo.size > 0) {
                                val startTime = System.nanoTime()
                                
                                // 更新统计信息
                                updateStats(bufferInfo, encodedData.remaining())
                                
                                // 回调编码数据
                                onEncodedDataCallback?.invoke(encodedData, bufferInfo)
                                
                                val encodingLatency = (System.nanoTime() - startTime) / 1_000_000
                                stats.averageEncodingLatency.set(
                                    (stats.averageEncodingLatency.get() + encodingLatency) / 2
                                )
                            }
                            
                            codec.releaseOutputBuffer(outputBufferIndex, false)
                        }
                        
                        outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val newFormat = codec.outputFormat
                            Log.d(TAG, "编码器输出格式改变: $newFormat")
                        }
                        
                        outputBufferIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            // 暂时没有可用的输出缓冲区，继续循环
                        }
                        
                        else -> {
                            Log.w(TAG, "意外的输出缓冲区索引: $outputBufferIndex")
                        }
                    }
                    
                } catch (e: Exception) {
                    Log.e(TAG, "编码过程中出错", e)
                    stats.framesDropped.incrementAndGet()
                }
            }
        }
    }
    
    /**
     * 更新统计信息
     */
    private fun updateStats(bufferInfo: MediaCodec.BufferInfo, dataSize: Int) {
        stats.framesSent.incrementAndGet()
        stats.totalBytesEncoded.addAndGet(dataSize.toLong())
        
        // 检查是否为关键帧
        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) {
            stats.keyFramesSent.incrementAndGet()
        }
        
        // 更新比特率历史
        val currentTime = System.currentTimeMillis()
        stats.bitrateHistory.add(Pair(currentTime, dataSize))
        
        // 清理旧的比特率数据（保留最近5秒）
        stats.bitrateHistory.removeAll { (time, _) -> 
            currentTime - time > 5000 
        }
    }
    
    /**
     * 计算平均比特率
     */
    private fun calculateAverageBitrate(): Long {
        if (stats.bitrateHistory.isEmpty()) return 0L
        
        val totalBytes = stats.bitrateHistory.sumOf { it.second }
        val timeSpan = stats.bitrateHistory.maxOf { it.first } - stats.bitrateHistory.minOf { it.first }
        
        return if (timeSpan > 0) {
            (totalBytes * 8 * 1000L) / timeSpan // 转换为bps
        } else {
            0L
        }
    }
    
    companion object {
        private const val TAG = "VideoEncoderService"
        private const val TIMEOUT_US = 10000L // 10ms超时
    }
}

/**
 * 编码器统计信息
 */
private class EncoderStats {
    val framesSent = AtomicLong(0)
    val framesDropped = AtomicLong(0)
    val keyFramesSent = AtomicLong(0)
    val totalBytesEncoded = AtomicLong(0)
    val bitrateChanges = AtomicLong(0)
    val averageEncodingLatency = AtomicLong(0)
    val bitrateHistory = mutableListOf<Pair<Long, Int>>()
}