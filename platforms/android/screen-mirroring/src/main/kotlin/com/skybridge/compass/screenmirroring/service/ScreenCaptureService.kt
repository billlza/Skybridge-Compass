package com.skybridge.compass.screenmirroring.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.app.ServiceCompat
import com.skybridge.compass.screenmirroring.ScreenCaptureManager
import com.skybridge.compass.core.utils.Constants
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.screenmirroring.encoder.VideoEncoder
import com.skybridge.compass.screenmirroring.encoder.HardwareVideoEncoder
import com.skybridge.compass.screenmirroring.model.ScreenCaptureConfig
import com.skybridge.compass.screenmirroring.model.ScreenFrame
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import com.skybridge.compass.mirroring.di.ScreenMirroringDI
import com.skybridge.compass.mirroring.data.services.MirroringNetworkService
import com.skybridge.compass.mirroring.domain.entities.NetworkProtocol

/**
 * 屏幕捕获服务
 * 负责屏幕录制、截图和实时流传输
 */
class ScreenCaptureService : Service() {
    
    private lateinit var screenCaptureManager: ScreenCaptureManager
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var mediaRecorder: MediaRecorder? = null
    
    // 声明视频编码器
    private lateinit var videoEncoder: VideoEncoder
    
    private val _screenFrames = MutableSharedFlow<ScreenFrame>()
    private val _isCapturing = MutableStateFlow(false)
    private val _captureConfig = MutableStateFlow(ScreenCaptureConfig())
    
    val screenFrames: SharedFlow<ScreenFrame> = _screenFrames.asSharedFlow()
    val isCapturing: StateFlow<Boolean> = _isCapturing.asStateFlow()
    
    private var displayMetrics: DisplayMetrics? = null
    private lateinit var mirroringNetworkService: MirroringNetworkService
    private var streamingJob: Job? = null
    private var targetDeviceId: String? = null
    private var targetDeviceHost: String? = null
    private var targetDevicePort: Int = 0
    private var targetProtocol: NetworkProtocol = NetworkProtocol.TCP
    
    companion object {
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "screen_capture_channel"
        private const val VIRTUAL_DISPLAY_NAME = "SkyBridge_Screen_Capture"
        
        const val ACTION_START_CAPTURE = "start_capture"
        const val ACTION_STOP_CAPTURE = "stop_capture"
        const val ACTION_TAKE_SCREENSHOT = "take_screenshot"
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
        const val EXTRA_CAPTURE_CONFIG = "capture_config"
        const val EXTRA_DEVICE_ID = "device_id"
        const val EXTRA_DEVICE_HOST = "device_host"
        const val EXTRA_DEVICE_PORT = "device_port"
        const val EXTRA_NETWORK_PROTOCOL = "network_protocol"
    }
    
    override fun onCreate() {
        super.onCreate()
        Logger.screenMirroring("ScreenCaptureService 创建")
        
        // 手动初始化 ScreenCaptureManager
        screenCaptureManager = ScreenCaptureManager(this)
        
        // 初始化视频编码器（优先使用硬件编码）
        videoEncoder = HardwareVideoEncoder()
        // 初始化网络服务
        mirroringNetworkService = ScreenMirroringDI.getInstance(applicationContext).provideMirroringNetworkService()
        
        // 获取显示指标
        displayMetrics = resources.displayMetrics
        
        createNotificationChannel()
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START_CAPTURE -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, -1)
                val resultData = intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
                val config = intent.getParcelableExtra(EXTRA_CAPTURE_CONFIG, ScreenCaptureConfig::class.java)
                    ?: ScreenCaptureConfig()

                // 读取目标设备和网络参数（可选）
                targetDeviceId = intent.getStringExtra(EXTRA_DEVICE_ID)
                targetDeviceHost = intent.getStringExtra(EXTRA_DEVICE_HOST)
                targetDevicePort = intent.getIntExtra(EXTRA_DEVICE_PORT, 8080)
                targetProtocol = intent.getStringExtra(EXTRA_NETWORK_PROTOCOL)
                    ?.let { runCatching { NetworkProtocol.valueOf(it) }.getOrDefault(NetworkProtocol.TCP) }
                    ?: NetworkProtocol.TCP

                startCapture(resultCode, resultData, config)
            }
            ACTION_STOP_CAPTURE -> {
                stopCapture()
            }
            ACTION_TAKE_SCREENSHOT -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, -1)
                val resultData = intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
                takeScreenshot(resultCode, resultData)
            }
        }
        
        return Service.START_STICKY
    }
    
    override fun onBind(intent: Intent?): IBinder? = null
    
    override fun onDestroy() {
        super.onDestroy()
        Logger.screenMirroring("ScreenCaptureService 销毁")
        stopCapture()
        scope.cancel()
    }
    
    /**
     * 开始屏幕捕获
     */
    private fun startCapture(resultCode: Int, resultData: Intent?, config: ScreenCaptureConfig) {
        scope.launch {
            try {
                if (_isCapturing.value) {
                    Logger.screenMirroring("屏幕捕获已在进行中")
                    return@launch
                }
                
                Logger.screenMirroring("开始屏幕捕获")
                _captureConfig.value = config
                
                // 创建前台通知
                (this@ScreenCaptureService as Service).startForeground(NOTIFICATION_ID, createNotification())
                
                // 初始化 MediaProjection
                val projectionManager = ContextCompat.getSystemService(this@ScreenCaptureService as Context, MediaProjectionManager::class.java)!!
                mediaProjection = projectionManager.getMediaProjection(resultCode, resultData!!)
                
                if (mediaProjection == null) {
                    Logger.screenMirroring("MediaProjection 创建失败")
                    return@launch
                }
                
                // 设置回调
                mediaProjection?.registerCallback(object : MediaProjection.Callback() {
                    override fun onStop() {
                        Logger.screenMirroring("MediaProjection 停止")
                        stopCapture()
                    }
                }, null)
                
                // 根据配置选择捕获模式
                when (config.captureMode) {
                    ScreenCaptureConfig.CaptureMode.STREAMING -> startStreamingCapture(config)
                    ScreenCaptureConfig.CaptureMode.RECORDING -> startRecordingCapture(config)
                    ScreenCaptureConfig.CaptureMode.SCREENSHOT -> takeScreenshotInternal()
                }
                
                _isCapturing.value = true
                Logger.screenMirroring("屏幕捕获启动成功")
                
            } catch (e: Exception) {
                Logger.screenMirroring("启动屏幕捕获失败", e)
                stopCapture()
            }
        }
    }
    
    /**
     * 开始流式捕获
     */
    private suspend fun startStreamingCapture(config: ScreenCaptureConfig) {
        val metrics = displayMetrics ?: return
        
        val width = config.getActualWidth(metrics.widthPixels)
        val height = config.getActualHeight(metrics.heightPixels)
        
        if (config.outputFormat == ScreenCaptureConfig.OutputFormat.ENCODED) {
            // 使用硬件编码器 + Surface 输入进行流式传输
            videoEncoder.initialize(
                width = width,
                height = height,
                bitRate = config.getTargetBitRate(),
                frameRate = config.frameRate,
                config = config.encoderConfig
            )
            
            // 创建虚拟显示，直接将图像渲染到编码器的输入Surface
            virtualDisplay = mediaProjection?.createVirtualDisplay(
                VIRTUAL_DISPLAY_NAME,
                width,
                height,
                metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                videoEncoder.getInputSurface(),
                null,
                null
            )
            
            // 启动编码器
            videoEncoder.start()
            
            // 连接网络并发送编码帧（如果提供了设备信息）
            streamingJob = scope.launch {
                val deviceId = targetDeviceId
                val host = targetDeviceHost ?: "192.168.1.100"
                val port = if (targetDevicePort > 0) targetDevicePort else 8080
                
                if (!deviceId.isNullOrEmpty()) {
                    try {
                        mirroringNetworkService.connect(deviceId, targetProtocol, host, port)
                        Logger.screenMirroring("网络连接建立: $deviceId -> $host:$port (${targetProtocol.name})")
                    } catch (e: Exception) {
                        Logger.screenMirroring("建立网络连接失败: $deviceId", e)
                    }
                }
                
                videoEncoder.encodedFrames.collect { frame ->
                    // 向本地观察者发送帧（便于调试或 UI 订阅）
                    _screenFrames.emit(frame)
                    
                    // 发送到网络
                    val encoded = frame.encodedData
                    if (!deviceId.isNullOrEmpty() && encoded != null) {
                        val timestampMs = encoded.presentationTimeUs / 1000
                        val buffer = ByteBuffer.wrap(encoded.data)
                        try {
                            mirroringNetworkService.sendVideoData(
                                deviceId,
                                buffer,
                                timestampMs,
                                encoded.isKeyFrame
                            )
                        } catch (e: Exception) {
                            Logger.screenMirroring("发送视频数据失败: $deviceId", e)
                        }
                    }
                }
            }
            
            Logger.screenMirroring("流式捕获（硬件编码）启动成功: ${width}x${height}@${config.frameRate}fps, bitrate=${config.getTargetBitRate()}")
        } else {
            // 使用 ImageReader 提供 BITMAP/BYTES 数据
            imageReader = ImageReader.newInstance(
                width,
                height,
                PixelFormat.RGBA_8888,
                2
            )
            
            imageReader?.setOnImageAvailableListener({ reader ->
                scope.launch {
                    try {
                        val image = reader.acquireLatestImage()
                        if (image != null) {
                            processImage(image, config)
                            image.close()
                        }
                    } catch (e: Exception) {
                        Logger.screenMirroring("处理图像失败", e)
                    }
                }
            }, null)
            
            virtualDisplay = mediaProjection?.createVirtualDisplay(
                VIRTUAL_DISPLAY_NAME,
                width,
                height,
                metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                imageReader?.surface,
                null,
                null
            )
            
            Logger.screenMirroring("流式捕获（ImageReader）启动成功: ${width}x${height}")
        }
    }
    
    /**
     * 开始录制捕获
     */
    private suspend fun startRecordingCapture(config: ScreenCaptureConfig) {
        val metrics = displayMetrics ?: return
        
        // 初始化视频编码器
        videoEncoder.initialize(
            width = config.width ?: metrics.widthPixels,
            height = config.height ?: metrics.heightPixels,
            bitRate = config.bitRate,
            frameRate = config.frameRate
        )
        
        // 创建虚拟显示用于录制
        virtualDisplay = mediaProjection?.createVirtualDisplay(
            VIRTUAL_DISPLAY_NAME,
            config.width ?: metrics.widthPixels,
            config.height ?: metrics.heightPixels,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            videoEncoder.getInputSurface(),
            null,
            null
        )
        
        // 开始编码
        videoEncoder.start()
        
        Logger.screenMirroring("录制捕获启动成功")
    }
    
    /**
     * 截图
     */
    private fun takeScreenshot(resultCode: Int, resultData: Intent?) {
        scope.launch {
            try {
                Logger.screenMirroring("开始截图")
                
                val projectionManager = ContextCompat.getSystemService(this@ScreenCaptureService as Context, MediaProjectionManager::class.java)!!
                 val projection = projectionManager.getMediaProjection(resultCode, resultData!!)
                
                takeScreenshotWithProjection(projection)
                
            } catch (e: Exception) {
                Logger.screenMirroring("截图失败", e)
            }
        }
    }
    
    /**
     * 内部截图方法
     */
    private suspend fun takeScreenshotInternal() {
        takeScreenshotWithProjection(mediaProjection)
    }
    
    /**
     * 使用 MediaProjection 截图
     */
    private suspend fun takeScreenshotWithProjection(projection: MediaProjection?) {
        if (projection == null) return
        
        val metrics = displayMetrics ?: return
        
        val reader = ImageReader.newInstance(
            metrics.widthPixels,
            metrics.heightPixels,
            PixelFormat.RGBA_8888,
            1
        )
        
        val display = projection.createVirtualDisplay(
            "Screenshot",
            metrics.widthPixels,
            metrics.heightPixels,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            null
        )
        
        // 等待图像可用
        delay(100)
        
        try {
            val image = reader.acquireLatestImage()
            if (image != null) {
                val bitmap = imageToBitmap(image)
                val frame = ScreenFrame(
                    bitmap = bitmap,
                    timestamp = System.currentTimeMillis(),
                    width = bitmap.width,
                    height = bitmap.height,
                    format = ScreenFrame.Format.BITMAP
                )
                _screenFrames.emit(frame)
                image.close()
                Logger.screenMirroring("截图完成")
            }
        } catch (e: Exception) {
            Logger.screenMirroring("截图处理失败", e)
        } finally {
            display?.release()
            reader.close()
            projection.stop()
        }
    }
    
    /**
     * 处理捕获的图像
     */
    private suspend fun processImage(image: Image, config: ScreenCaptureConfig) {
        try {
            when (config.outputFormat) {
                ScreenCaptureConfig.OutputFormat.BITMAP -> {
                    val bitmap = imageToBitmap(image)
                    val frame = ScreenFrame(
                        bitmap = bitmap,
                        timestamp = System.currentTimeMillis(),
                        width = bitmap.width,
                        height = bitmap.height,
                        format = ScreenFrame.Format.BITMAP
                    )
                    _screenFrames.emit(frame)
                }
                ScreenCaptureConfig.OutputFormat.BYTES -> {
                    val bytes = imageToBytes(image)
                    val frame = ScreenFrame(
                        data = bytes,
                        timestamp = System.currentTimeMillis(),
                        width = image.width,
                        height = image.height,
                        format = ScreenFrame.Format.BYTES
                    )
                    _screenFrames.emit(frame)
                }
                ScreenCaptureConfig.OutputFormat.ENCODED -> {
                    // 使用视频编码器编码
                    videoEncoder.encodeFrame(image)
                }
            }
        } catch (e: Exception) {
            Logger.screenMirroring("处理图像失败", e)
        }
    }
    
    /**
     * 将 Image 转换为 Bitmap
     */
    private fun imageToBitmap(image: Image): Bitmap {
        val planes = image.planes
        val buffer = planes[0].buffer
        val pixelStride = planes[0].pixelStride
        val rowStride = planes[0].rowStride
        val rowPadding = rowStride - pixelStride * image.width
        
        val bitmap = Bitmap.createBitmap(
            image.width + rowPadding / pixelStride,
            image.height,
            Bitmap.Config.ARGB_8888
        )
        bitmap.copyPixelsFromBuffer(buffer)
        
        return if (rowPadding == 0) {
            bitmap
        } else {
            Bitmap.createBitmap(bitmap, 0, 0, image.width, image.height)
        }
    }
    
    /**
     * 将 Image 转换为字节数组
     */
    private fun imageToBytes(image: Image): ByteArray {
        val bitmap = imageToBitmap(image)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 80, stream)
        return stream.toByteArray()
    }
    
    /**
     * 停止屏幕捕获
     */
    private fun stopCapture() {
        scope.launch {
            try {
                Logger.screenMirroring("停止屏幕捕获")
                
                _isCapturing.value = false
                
                // 取消编码帧收集任务，避免继续发送
                streamingJob?.cancel()
                streamingJob = null
                
                // 断开网络连接（如已建立）
                targetDeviceId?.let { deviceId ->
                    try {
                        mirroringNetworkService.disconnect(deviceId)
                        Logger.screenMirroring("网络连接已断开: $deviceId")
                    } catch (e: Exception) {
                        Logger.screenMirroring("断开网络连接失败: $deviceId", e)
                    }
                }
                
                // 停止视频编码器
                videoEncoder.stop()
                
                // 释放虚拟显示
                virtualDisplay?.release()
                virtualDisplay = null
                
                // 关闭 ImageReader
                imageReader?.close()
                imageReader = null
                
                // 停止 MediaProjection
                mediaProjection?.stop()
                mediaProjection = null
                
                // 停止前台服务并移除通知
                ServiceCompat.stopForeground(this@ScreenCaptureService as Service, ServiceCompat.STOP_FOREGROUND_REMOVE)
                (this@ScreenCaptureService as Service).stopSelf()
                
                Logger.screenMirroring("屏幕捕获已停止")
                
            } catch (e: Exception) {
                Logger.screenMirroring("停止屏幕捕获失败", e)
            }
        }
    }
    
    /**
     * 创建通知渠道
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "屏幕捕获",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "SkyBridge 屏幕捕获服务"
            channel.setShowBadge(false)
            channel.lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            
            val notificationManager = ContextCompat.getSystemService(this@ScreenCaptureService as Context, NotificationManager::class.java)!!
            notificationManager.createNotificationChannel(channel)
        }
    }
    
    /**
     * 创建前台通知
     */
    private fun createNotification(): Notification {
        return NotificationCompat.Builder(this@ScreenCaptureService as Context, CHANNEL_ID)
            .setContentTitle("SkyBridge 屏幕捕获")
            .setContentText("正在捕获屏幕内容...")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }
}