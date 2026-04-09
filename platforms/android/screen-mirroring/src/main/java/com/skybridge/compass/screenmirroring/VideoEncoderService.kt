package com.skybridge.compass.screenmirroring

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.screenmirroring.MirroringError
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.*
import java.nio.ByteBuffer
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface

/**
 * 视频编码器服务
 * 负责H.264/H.265硬件视频编码，支持自适应码率和低延迟优化
 */
/**
 * 视频编码服务
 * 负责屏幕帧的视频编码处理
 */
class VideoEncoderService constructor() {
    
    companion object {
        private const val TAG = "VideoEncoderService"
        private const val TIMEOUT_US = 10000L // 10ms超时
        private const val IFRAME_INTERVAL = 2 // I帧间隔（秒）
    }
    
    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var encoderThread: HandlerThread? = null
    private var encoderHandler: Handler? = null
    
    private val _encoderState = MutableStateFlow<EncoderState>(EncoderState.Idle)
    val encoderState: StateFlow<EncoderState> = _encoderState.asStateFlow()
    
    private val _encodedData = MutableSharedFlow<EncodedVideoData>(
        replay = 0,
        extraBufferCapacity = 20,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val encodedData: SharedFlow<EncodedVideoData> = _encodedData.asSharedFlow()
    
    private val coroutineScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private var encodingJob: Job? = null
    
    private var currentConfiguration: EncoderConfiguration? = null
    private var frameCount = 0L
    private var startTime = 0L
    
    /**
     * 初始化编码器
     */
    suspend fun initializeEncoder(configuration: EncoderConfiguration): Result<Surface> {
        return withContext(Dispatchers.Default) {
            try {
                _encoderState.value = EncoderState.Initializing
                
                // 1. 检查编码器支持
                val codecInfo = findBestEncoder(configuration.codec)
                    ?: return@withContext Result.failure(
                        IllegalStateException("No suitable encoder found for ${configuration.codec}")
                    )
                
                // 2. 创建MediaFormat
                val mediaFormat = createMediaFormat(configuration)
                
                // 3. 创建并配置编码器
                mediaCodec = MediaCodec.createByCodecName(codecInfo.name).apply {
                    configure(mediaFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    inputSurface = createInputSurface()
                }
                
                // 4. 设置编码线程
                setupEncoderThread()
                
                // 5. 启动编码器
                mediaCodec?.start()
                
                currentConfiguration = configuration
                startTime = System.currentTimeMillis()
                frameCount = 0
                
                _encoderState.value = EncoderState.Ready(configuration)
                
                Log.d(TAG, "Video encoder initialized successfully with codec: ${codecInfo.name}")
                Result.success(inputSurface!!)
                
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize video encoder", e)
                cleanup()
                _encoderState.value = EncoderState.Error(
                    MirroringError.EncoderInitializationFailed,
                    e.message ?: "Unknown error"
                )
                Result.failure(e)
            }
        }
    }
    
    /**
     * 开始编码
     */
    fun startEncoding() {
        if (_encoderState.value !is EncoderState.Ready) {
            Log.w(TAG, "Encoder not ready for encoding")
            return
        }
        
        encodingJob = coroutineScope.launch {
            try {
                _encoderState.value = EncoderState.Encoding(
                    configuration = currentConfiguration!!,
                    startTime = System.currentTimeMillis()
                )
                
                processEncodedData()
                
            } catch (e: Exception) {
                Log.e(TAG, "Error during encoding", e)
                _encoderState.value = EncoderState.Error(
                    MirroringError.EncodingError(e.message ?: "Encoding failed"),
                    e.message ?: "Unknown error"
                )
            }
        }
    }
    
    /**
     * 停止编码
     */
    suspend fun stopEncoding() {
        withContext(Dispatchers.Default) {
            try {
                _encoderState.value = EncoderState.Stopping
                
                encodingJob?.cancelAndJoin()
                encodingJob = null
                
                // 发送结束帧
                mediaCodec?.signalEndOfInputStream()
                
                // 等待编码器完成
                drainEncoder(true)
                
                cleanup()
                _encoderState.value = EncoderState.Idle
                
                Log.d(TAG, "Video encoding stopped")
                
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping encoder", e)
                _encoderState.value = EncoderState.Error(
                    MirroringError.UnknownError(e.message ?: "Stop encoding failed"),
                    e.message ?: "Unknown error"
                )
            }
        }
    }
    
    /**
     * 动态调整码率
     */
    fun adjustBitrate(newBitrate: Int) {
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.KITKAT) {
                val bundle = android.os.Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, newBitrate)
                }
                mediaCodec?.setParameters(bundle)
                
                Log.d(TAG, "Bitrate adjusted to: $newBitrate")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to adjust bitrate", e)
        }
    }
    
    /**
     * 请求关键帧
     */
    fun requestKeyFrame() {
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.KITKAT) {
                val bundle = android.os.Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                }
                mediaCodec?.setParameters(bundle)
                
                Log.d(TAG, "Key frame requested")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to request key frame", e)
        }
    }
    
    /**
     * 查找最佳编码器
     */
    private fun findBestEncoder(codec: VideoCodec): MediaCodecInfo? {
        val codecList = MediaCodecList(MediaCodecList.ALL_CODECS)
        
        return codecList.codecInfos
            .filter { it.isEncoder }
            .find { codecInfo ->
                codecInfo.supportedTypes.any { type ->
                    type.equals(codec.mimeType, ignoreCase = true)
                } && isHardwareAccelerated(codecInfo)
            } ?: codecList.codecInfos
            .filter { it.isEncoder }
            .find { codecInfo ->
                codecInfo.supportedTypes.any { type ->
                    type.equals(codec.mimeType, ignoreCase = true)
                }
            }
    }
    
    /**
     * 检查是否为硬件加速编码器
     */
    private fun isHardwareAccelerated(codecInfo: MediaCodecInfo): Boolean {
        return !codecInfo.name.startsWith("OMX.google.") &&
                !codecInfo.name.startsWith("c2.android.")
    }
    
    /**
     * 创建MediaFormat
     */
    private fun createMediaFormat(configuration: EncoderConfiguration): MediaFormat {
        return MediaFormat.createVideoFormat(
            configuration.codec.mimeType,
            currentConfiguration?.let { 
                // 这里应该从MirroringConfiguration获取分辨率
                1920 // 临时硬编码，实际应该从配置获取
            } ?: 1920,
            currentConfiguration?.let { 
                1080 // 临时硬编码，实际应该从配置获取
            } ?: 1080
        ).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, configuration.bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, configuration.frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, configuration.iFrameInterval)
            
            // 设置编码器配置文件和级别
            if (configuration.profile != 0) {
                setInteger(MediaFormat.KEY_PROFILE, configuration.profile)
            }
            if (configuration.level != 0) {
                setInteger(MediaFormat.KEY_LEVEL, configuration.level)
            }
            
            // 设置码率控制模式
            setInteger(MediaFormat.KEY_BITRATE_MODE, configuration.bitrateMode.value)
            
            // 低延迟设置
            setInteger(MediaFormat.KEY_LATENCY, 0)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // 实时优先级
        }
    }
    
    /**
     * 设置编码线程
     */
    private fun setupEncoderThread() {
        encoderThread = HandlerThread("VideoEncoder").apply {
            start()
            encoderHandler = Handler(looper)
        }
    }
    
    /**
     * 处理编码数据
     */
    private suspend fun processEncodedData() {
        while (currentCoroutineContext().isActive) {
            try {
                drainEncoder(false)
                delay(1) // 短暂延迟避免过度占用CPU
            } catch (e: Exception) {
                Log.e(TAG, "Error processing encoded data", e)
                break
            }
        }
    }
    
    /**
     * 提取编码数据
     */
    private fun drainEncoder(endOfStream: Boolean) {
        val codec = mediaCodec ?: return
        val bufferInfo = MediaCodec.BufferInfo()
        
        while (true) {
            val outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
            
            when {
                outputBufferIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) break
                }
                
                outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    Log.d(TAG, "Output format changed: ${codec.outputFormat}")
                }
                
                outputBufferIndex >= 0 -> {
                    val outputBuffer = codec.getOutputBuffer(outputBufferIndex)
                    
                    if (outputBuffer != null && bufferInfo.size > 0) {
                        val data = ByteArray(bufferInfo.size)
                        outputBuffer.get(data)
                        
                        val encodedData = EncodedVideoData(
                            frameId = frameCount++,
                            timestamp = bufferInfo.presentationTimeUs,
                            data = data,
                            isKeyFrame = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0,
                            size = bufferInfo.size
                        )
                        
                        _encodedData.tryEmit(encodedData)
                    }
                    
                    codec.releaseOutputBuffer(outputBufferIndex, false)
                    
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        Log.d(TAG, "End of stream reached")
                        break
                    }
                }
            }
        }
    }
    
    /**
     * 清理资源
     */
    private fun cleanup() {
        try {
            mediaCodec?.stop()
            mediaCodec?.release()
            mediaCodec = null
            
            inputSurface?.release()
            inputSurface = null
            
            encoderThread?.quitSafely()
            encoderThread = null
            encoderHandler = null
            
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        }
    }
    
    /**
     * 获取编码器能力
     */
    fun getEncoderCapabilities(codec: VideoCodec): EncoderCapabilities? {
        return try {
            val codecInfo = findBestEncoder(codec) ?: return null
            val capabilities = codecInfo.getCapabilitiesForType(codec.mimeType)
            val videoCapabilities = capabilities.videoCapabilities
                ?: return null

            EncoderCapabilities(
                codecName = codecInfo.name,
                isHardwareAccelerated = isHardwareAccelerated(codecInfo),
                supportedProfiles = capabilities.profileLevels.map { it.profile },
                maxWidth = videoCapabilities.supportedWidths.upper,
                maxHeight = videoCapabilities.supportedHeights.upper,
                maxFrameRate = videoCapabilities.supportedFrameRates.upper.toInt(),
                maxBitrate = videoCapabilities.bitrateRange.upper
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error getting encoder capabilities", e)
            null
        }
    }
}

/**
 * 编码器状态
 */
sealed class EncoderState {
    object Idle : EncoderState()
    object Initializing : EncoderState()
    
    data class Ready(
        val configuration: EncoderConfiguration
    ) : EncoderState()
    
    data class Encoding(
        val configuration: EncoderConfiguration,
        val startTime: Long
    ) : EncoderState()
    
    object Stopping : EncoderState()
    
    data class Error(
        val error: MirroringError,
        val message: String
    ) : EncoderState()
}

/**
 * 编码视频数据
 */
data class EncodedVideoData(
    val frameId: Long,
    val timestamp: Long, // 微秒
    val data: ByteArray,
    val isKeyFrame: Boolean,
    val size: Int
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as EncodedVideoData

        if (frameId != other.frameId) return false
        if (timestamp != other.timestamp) return false
        if (!data.contentEquals(other.data)) return false
        if (isKeyFrame != other.isKeyFrame) return false
        if (size != other.size) return false

        return true
    }

    override fun hashCode(): Int {
        var result = frameId.hashCode()
        result = 31 * result + timestamp.hashCode()
        result = 31 * result + data.contentHashCode()
        result = 31 * result + isKeyFrame.hashCode()
        result = 31 * result + size
        return result
    }
}

/**
 * 编码器能力信息
 */
data class EncoderCapabilities(
    val codecName: String,
    val isHardwareAccelerated: Boolean,
    val supportedProfiles: List<Int>,
    val maxWidth: Int,
    val maxHeight: Int,
    val maxFrameRate: Int,
    val maxBitrate: Int
)

/**
 * 自适应码率控制器
 * 根据网络状况动态调整编码码率
 */
class AdaptiveBitrateController constructor() {    
    companion object {
        private const val TAG = "AdaptiveBitrateController"
        private const val BITRATE_ADJUSTMENT_THRESHOLD = 0.1f // 10%调整阈值
        private const val MIN_BITRATE = 500_000 // 500kbps
        private const val MAX_BITRATE = 20_000_000 // 20Mbps
    }
    
    private var targetBitrate = 0
    private var currentBitrate = 0
    private val networkStats = mutableListOf<NetworkSample>()
    
    /**
     * 根据网络状况调整码率
     */
    fun adjustBitrate(
        networkLatency: Long,
        packetLoss: Float,
        bandwidth: Long
    ): Int? {
        val sample = NetworkSample(
            timestamp = System.currentTimeMillis(),
            latency = networkLatency,
            packetLoss = packetLoss,
            bandwidth = bandwidth
        )
        
        networkStats.add(sample)
        
        // 保持最近10个样本
        if (networkStats.size > 10) {
            networkStats.removeAt(0)
        }
        
        val newBitrate = calculateOptimalBitrate()
        
        return if (shouldAdjustBitrate(newBitrate)) {
            currentBitrate = newBitrate
            Log.d(TAG, "Bitrate adjusted to: $newBitrate")
            newBitrate
        } else {
            null
        }
    }
    
    /**
     * 计算最优码率
     */
    private fun calculateOptimalBitrate(): Int {
        if (networkStats.isEmpty()) return currentBitrate
        
        val avgLatency = networkStats.map { it.latency }.average()
        val avgPacketLoss = networkStats.map { it.packetLoss }.average()
        val avgBandwidth = networkStats.map { it.bandwidth }.average()
        
        // 基于网络状况计算码率
        var optimalBitrate = (avgBandwidth * 0.8).toInt() // 使用80%带宽
        
        // 根据延迟调整
        when {
            avgLatency > 200 -> optimalBitrate = (optimalBitrate * 0.7).toInt()
            avgLatency > 100 -> optimalBitrate = (optimalBitrate * 0.85).toInt()
        }
        
        // 根据丢包率调整
        when {
            avgPacketLoss > 0.05 -> optimalBitrate = (optimalBitrate * 0.6).toInt()
            avgPacketLoss > 0.02 -> optimalBitrate = (optimalBitrate * 0.8).toInt()
        }
        
        return optimalBitrate.coerceIn(MIN_BITRATE, MAX_BITRATE)
    }
    
    /**
     * 判断是否需要调整码率
     */
    private fun shouldAdjustBitrate(newBitrate: Int): Boolean {
        if (currentBitrate == 0) {
            return true
        }
        
        val changeRatio = kotlin.math.abs(newBitrate - currentBitrate).toFloat() / currentBitrate
        return changeRatio > BITRATE_ADJUSTMENT_THRESHOLD
    }
    
    /**
     * 设置目标码率
     */
    fun setTargetBitrate(bitrate: Int) {
        targetBitrate = bitrate
        currentBitrate = bitrate
    }
}

/**
 * 网络采样数据
 */
private data class NetworkSample(
    val timestamp: Long,
    val latency: Long,
    val packetLoss: Float,
    val bandwidth: Long
)