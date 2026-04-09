package com.skybridge.compass.screenmirroring.encoder

import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import android.os.Build
import android.view.Surface
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.screenmirroring.model.ScreenFrame
import com.skybridge.compass.screenmirroring.model.ScreenCaptureConfig
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.nio.ByteBuffer

/**
 * 视频编码器接口
 */
interface VideoEncoder {
    /**
     * 初始化编码器
     */
    suspend fun initialize(
        width: Int,
        height: Int,
        bitRate: Int,
        frameRate: Int,
        config: ScreenCaptureConfig.EncoderConfig = ScreenCaptureConfig.EncoderConfig()
    )
    
    /**
     * 开始编码
     */
    suspend fun start()
    
    /**
     * 停止编码
     */
    suspend fun stop()
    
    /**
     * 编码帧
     */
    suspend fun encodeFrame(image: Image)
    
    /**
     * 获取输入Surface
     */
    fun getInputSurface(): Surface?
    
    /**
     * 编码后的数据流
     */
    val encodedFrames: SharedFlow<ScreenFrame>
    
    /**
     * 编码器状态
     */
    val isEncoding: StateFlow<Boolean>
}

/**
 * 硬件视频编码器实现
 * 使用Android MediaCodec API进行硬件加速编码
 */
class HardwareVideoEncoder constructor() : VideoEncoder {
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var mediaFormat: MediaFormat? = null
    
    private val _encodedFrames = MutableSharedFlow<ScreenFrame>()
    private val _isEncoding = MutableStateFlow(false)
    
    override val encodedFrames: SharedFlow<ScreenFrame> = _encodedFrames.asSharedFlow()
    override val isEncoding: StateFlow<Boolean> = _isEncoding.asStateFlow()
    
    private var width: Int = 0
    private var height: Int = 0
    private var bitRate: Int = 0
    private var frameRate: Int = 0
    private var frameNumber: Long = 0
    
    private var encoderConfig: ScreenCaptureConfig.EncoderConfig = ScreenCaptureConfig.EncoderConfig()
    
    override suspend fun initialize(
        width: Int,
        height: Int,
        bitRate: Int,
        frameRate: Int,
        config: ScreenCaptureConfig.EncoderConfig
    ) {
        withContext(Dispatchers.IO) {
            try {
                Logger.screenMirroring("初始化视频编码器: ${width}x${height}, ${bitRate}bps, ${frameRate}fps")
                
                this@HardwareVideoEncoder.width = width
                this@HardwareVideoEncoder.height = height
                this@HardwareVideoEncoder.bitRate = bitRate
                this@HardwareVideoEncoder.frameRate = frameRate
                this@HardwareVideoEncoder.encoderConfig = config
                
                // 创建MediaFormat
                mediaFormat = MediaFormat.createVideoFormat(config.codecType.mimeType, width, height).apply {
                    setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                    setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
                    setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, config.iFrameInterval)
                    
                    // 设置编码复杂度
                    when (config.complexity) {
                        ScreenCaptureConfig.EncoderConfig.Complexity.FAST -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                setInteger(MediaFormat.KEY_COMPLEXITY, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                            }
                        }
                        ScreenCaptureConfig.EncoderConfig.Complexity.QUALITY -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                setInteger(MediaFormat.KEY_COMPLEXITY, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                            }
                        }
                        else -> {
                            // 默认平衡模式
                        }
                    }
                    
                    // 设置GOP大小
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        setInteger(MediaFormat.KEY_MAX_B_FRAMES, if (config.useBFrames) 2 else 0)
                    }
                    
                    // 设置编码配置文件和级别
                    if (config.codecType == ScreenCaptureConfig.EncoderConfig.CodecType.H264) {
                        when (config.profile) {
                            "baseline" -> setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
                            "main" -> setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileMain)
                            "high" -> setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
                        }
                    }
                }
                
                // 创建编码器
                mediaCodec = MediaCodec.createEncoderByType(config.codecType.mimeType)
                mediaCodec?.configure(mediaFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                
                // 获取输入Surface
                inputSurface = mediaCodec?.createInputSurface()
                
                Logger.screenMirroring("视频编码器初始化成功")
                
            } catch (e: Exception) {
                Logger.screenMirroring("视频编码器初始化失败", e)
                throw e
            }
        }
    }
    
    override suspend fun start() {
        withContext(Dispatchers.IO) {
            try {
                Logger.screenMirroring("启动视频编码器")
                
                mediaCodec?.start()
                _isEncoding.value = true
                frameNumber = 0
                
                // 启动输出处理协程
                scope.launch {
                    processEncodedOutput()
                }
                
                Logger.screenMirroring("视频编码器启动成功")
                
            } catch (e: Exception) {
                Logger.screenMirroring("启动视频编码器失败", e)
                throw e
            }
        }
    }
    
    override suspend fun stop() {
        withContext(Dispatchers.IO) {
            try {
                Logger.screenMirroring("停止视频编码器")
                
                _isEncoding.value = false
                
                // 发送结束信号
                mediaCodec?.signalEndOfInputStream()
                
                // 等待一段时间让编码器处理完剩余数据
                delay(100)
                
                // 停止并释放编码器
                mediaCodec?.stop()
                mediaCodec?.release()
                mediaCodec = null
                
                // 释放Surface
                inputSurface?.release()
                inputSurface = null
                
                Logger.screenMirroring("视频编码器已停止")
                
            } catch (e: Exception) {
                Logger.screenMirroring("停止视频编码器失败", e)
            }
        }
    }
    
    override suspend fun encodeFrame(image: Image) {
        // 对于Surface输入，这个方法不需要实现
        // 帧数据直接通过Surface传递给编码器
    }
    
    override fun getInputSurface(): Surface? = inputSurface
    
    /**
     * 处理编码后的输出
     */
    private suspend fun processEncodedOutput() {
        val codec = mediaCodec ?: return
        val bufferInfo = MediaCodec.BufferInfo()
        
        try {
            while (_isEncoding.value) {
                val outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, 10000)
                
                when {
                    outputBufferIndex >= 0 -> {
                        val outputBuffer = codec.getOutputBuffer(outputBufferIndex)
                        
                        if (outputBuffer != null && bufferInfo.size > 0) {
                            // 创建数据副本
                            val data = ByteArray(bufferInfo.size)
                            outputBuffer.get(data)
                            outputBuffer.rewind()
                            
                            // 创建编码数据
                            val encodedData = ScreenFrame.EncodedData(
                                data = data,
                                codecType = encoderConfig.codecType.mimeType,
                                isKeyFrame = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0,
                                presentationTimeUs = bufferInfo.presentationTimeUs,
                                flags = bufferInfo.flags
                            )
                            
                            // 创建屏幕帧
                            val frame = ScreenFrame.fromEncodedData(
                                encodedData = encodedData,
                                width = width,
                                height = height,
                                frameNumber = frameNumber++,
                                quality = calculateQuality(bufferInfo.size),
                                metadata = mapOf(
                                    "codec" to encoderConfig.codecType.name,
                                    "bitrate" to bitRate.toString(),
                                    "framerate" to frameRate.toString()
                                )
                            )
                            
                            // 发送编码后的帧
                            _encodedFrames.emit(frame)
                        }
                        
                        // 释放输出缓冲区
                        codec.releaseOutputBuffer(outputBufferIndex, false)
                        
                        // 检查是否结束
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            Logger.screenMirroring("编码器输出结束")
                            break
                        }
                    }
                    
                    outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val newFormat = codec.outputFormat
                        Logger.screenMirroring("编码器输出格式改变: $newFormat")
                    }
                    
                    outputBufferIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        // 暂时没有输出，继续等待
                        delay(5)
                    }
                    
                    else -> {
                        Logger.screenMirroring("意外的输出缓冲区索引: $outputBufferIndex")
                    }
                }
            }
        } catch (e: Exception) {
            Logger.screenMirroring("处理编码输出时出错", e)
        }
    }
    
    /**
     * 根据数据大小计算质量分数
     */
    private fun calculateQuality(dataSize: Int): Int {
        val expectedSize = (width * height * 3) / 8 // 估算的压缩后大小
        val ratio = dataSize.toFloat() / expectedSize
        return when {
            ratio > 1.5f -> 90
            ratio > 1.0f -> 80
            ratio > 0.5f -> 70
            else -> 60
        }.coerceIn(0, 100)
    }
}

/**
 * 软件视频编码器实现
 * 使用 JPEG 压缩作为简化的软件编码方案
 * 适用于硬件编码不可用的情况
 */
class SoftwareVideoEncoder constructor() : VideoEncoder {
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    
    private val _encodedFrames = MutableSharedFlow<ScreenFrame>(
        replay = 0,
        extraBufferCapacity = 10
    )
    private val _isEncoding = MutableStateFlow(false)
    
    override val encodedFrames: SharedFlow<ScreenFrame> = _encodedFrames.asSharedFlow()
    override val isEncoding: StateFlow<Boolean> = _isEncoding.asStateFlow()
    
    private var width: Int = 0
    private var height: Int = 0
    private var bitRate: Int = 0
    private var frameRate: Int = 0
    private var frameNumber: Long = 0
    private var quality: Int = 80 // JPEG 质量 0-100
    private var keyFrameInterval: Int = 30 // 每30帧一个关键帧
    
    private var encoderConfig: ScreenCaptureConfig.EncoderConfig = ScreenCaptureConfig.EncoderConfig()
    
    override suspend fun initialize(
        width: Int,
        height: Int,
        bitRate: Int,
        frameRate: Int,
        config: ScreenCaptureConfig.EncoderConfig
    ) {
        withContext(Dispatchers.Default) {
            Logger.screenMirroring("软件编码器初始化: ${width}x${height}, ${bitRate}bps, ${frameRate}fps")
            
            this@SoftwareVideoEncoder.width = width
            this@SoftwareVideoEncoder.height = height
            this@SoftwareVideoEncoder.bitRate = bitRate
            this@SoftwareVideoEncoder.frameRate = frameRate
            this@SoftwareVideoEncoder.encoderConfig = config
            
            // 根据比特率计算 JPEG 质量
            // 较高比特率 = 较高质量
            quality = when {
                bitRate > 8_000_000 -> 90
                bitRate > 4_000_000 -> 80
                bitRate > 2_000_000 -> 70
                bitRate > 1_000_000 -> 60
                else -> 50
            }
            
            keyFrameInterval = config.iFrameInterval * frameRate
            
            Logger.screenMirroring("软件编码器初始化完成，JPEG质量: $quality")
        }
    }
    
    override suspend fun start() {
        withContext(Dispatchers.Default) {
            Logger.screenMirroring("软件编码器启动")
            _isEncoding.value = true
            frameNumber = 0
        }
    }
    
    override suspend fun stop() {
        withContext(Dispatchers.Default) {
            Logger.screenMirroring("软件编码器停止")
            _isEncoding.value = false
        }
    }
    
    override suspend fun encodeFrame(image: Image) {
        if (!_isEncoding.value) return
        
        withContext(Dispatchers.Default) {
            try {
                val startTime = System.nanoTime()
                
                // 将 Image 转换为 Bitmap
                val bitmap = imageToBitmap(image)
                
                // 压缩为 JPEG
                val outputStream = java.io.ByteArrayOutputStream()
                bitmap.compress(
                    android.graphics.Bitmap.CompressFormat.JPEG,
                    quality,
                    outputStream
                )
                val encodedData = outputStream.toByteArray()
                
                // 判断是否为关键帧
                val isKeyFrame = (frameNumber % keyFrameInterval) == 0L
                
                // 计算时间戳
                val presentationTimeUs = (frameNumber * 1_000_000L) / frameRate
                
                // 创建编码数据
                val frameData = ScreenFrame.EncodedData(
                    data = encodedData,
                    codecType = "image/jpeg", // 使用 JPEG 作为软件编码格式
                    isKeyFrame = isKeyFrame,
                    presentationTimeUs = presentationTimeUs,
                    flags = if (isKeyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                )
                
                // 创建屏幕帧
                val frame = ScreenFrame.fromEncodedData(
                    encodedData = frameData,
                    width = width,
                    height = height,
                    frameNumber = frameNumber,
                    quality = quality,
                    metadata = mapOf(
                        "codec" to "jpeg",
                        "software_encoder" to "true",
                        "encode_time_ms" to ((System.nanoTime() - startTime) / 1_000_000).toString()
                    )
                )
                
                // 发送编码后的帧
                _encodedFrames.emit(frame)
                
                frameNumber++
                
                // 回收 Bitmap
                bitmap.recycle()
                
            } catch (e: Exception) {
                Logger.screenMirroring("软件编码帧失败", e)
            }
        }
    }
    
    override fun getInputSurface(): Surface? = null // 软件编码器不使用 Surface
    
    /**
     * 将 Image 转换为 Bitmap
     */
    private fun imageToBitmap(image: Image): android.graphics.Bitmap {
        val planes = image.planes
        val buffer = planes[0].buffer
        val pixelStride = planes[0].pixelStride
        val rowStride = planes[0].rowStride
        val rowPadding = rowStride - pixelStride * image.width
        
        val bitmap = android.graphics.Bitmap.createBitmap(
            image.width + rowPadding / pixelStride,
            image.height,
            android.graphics.Bitmap.Config.ARGB_8888
        )
        
        bitmap.copyPixelsFromBuffer(buffer)
        
        // 如果有 padding，裁剪到正确尺寸
        return if (rowPadding > 0) {
            android.graphics.Bitmap.createBitmap(bitmap, 0, 0, image.width, image.height)
        } else {
            bitmap
        }
    }
    
    /**
     * 动态调整质量以适应比特率
     */
    fun adjustQuality(targetBitRate: Int) {
        quality = when {
            targetBitRate > 8_000_000 -> 90
            targetBitRate > 4_000_000 -> 80
            targetBitRate > 2_000_000 -> 70
            targetBitRate > 1_000_000 -> 60
            else -> 50
        }
        Logger.screenMirroring("软件编码器质量调整为: $quality")
    }
}

/**
 * 视频编码器工厂
 * 根据设备能力选择合适的编码器
 */
object VideoEncoderFactory {
    
    /**
     * 创建视频编码器
     * 优先使用硬件编码器，不可用时回退到软件编码器
     */
    fun createEncoder(preferHardware: Boolean = true): VideoEncoder {
        if (preferHardware && isHardwareEncoderAvailable()) {
            Logger.screenMirroring("使用硬件视频编码器")
            return HardwareVideoEncoder()
        }
        
        Logger.screenMirroring("使用软件视频编码器")
        return SoftwareVideoEncoder()
    }
    
    /**
     * 检查硬件编码器是否可用
     */
    fun isHardwareEncoderAvailable(): Boolean {
        return try {
            val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val encoderName = codecList.findEncoderForFormat(
                MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080)
            )
            encoderName != null
        } catch (e: Exception) {
            Logger.screenMirroring("检查硬件编码器失败", e)
            false
        }
    }
}