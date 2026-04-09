package com.skybridge.compass.screenmirroring

import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import com.skybridge.compass.screenmirroring.MirroringConfiguration
import com.skybridge.compass.screenmirroring.FrameData
import com.skybridge.compass.screenmirroring.Resolution
import com.skybridge.compass.screenmirroring.MirroringError

/**
 * 屏幕捕获管理器
 * 负责管理MediaProjection和屏幕录制相关功能
 */
class ScreenCaptureManager constructor(
    private val context: Context
) {
    companion object {
        private const val TAG = "ScreenCaptureManager"
        private const val VIRTUAL_DISPLAY_NAME = "SkyBridge-ScreenMirror"
    }
    
    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null
    
    private val _captureState = MutableStateFlow<CaptureState>(CaptureState.Idle)
    val captureState: StateFlow<CaptureState> = _captureState.asStateFlow()
    
    private val _frameData = MutableSharedFlow<FrameData>(
        replay = 0,
        extraBufferCapacity = 10,
        onBufferOverflow = kotlinx.coroutines.channels.BufferOverflow.DROP_OLDEST
    )
    val frameData: SharedFlow<FrameData> = _frameData.asSharedFlow()
    
    private val coroutineScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    
    /**
     * 开始屏幕捕获
     */
    fun startCapture(resultCode: Int, resultData: Intent, configuration: MirroringConfiguration) {
        coroutineScope.launch {
            try {
                _captureState.value = CaptureState.Initializing
                
                // 1. 创建MediaProjection
                val mediaProjectionManager = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                mediaProjection = mediaProjectionManager.getMediaProjection(resultCode, resultData)
                
                if (mediaProjection == null) {
                    throw IllegalStateException("Failed to create MediaProjection")
                }
                
                // 2. 设置后台线程
                setupBackgroundThread()
                
                // 3. 创建ImageReader
                setupImageReader(configuration)
                
                // 4. 创建VirtualDisplay
                setupVirtualDisplay(configuration)
                
                _captureState.value = CaptureState.Active(
                    sessionId = java.util.UUID.randomUUID().toString(),
                    configuration = configuration,
                    startTime = System.currentTimeMillis()
                )
                
                Log.d(TAG, "Screen capture started successfully")
                
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start screen capture", e)
                _captureState.value = CaptureState.Error(
                    MirroringError.MediaProjectionFailed,
                    e.message ?: "Unknown error"
                )
                cleanup()
            }
        }
    }
    
    /**
     * 停止屏幕捕获
     */
    fun stopCapture() {
        coroutineScope.launch {
            try {
                _captureState.value = CaptureState.Stopping
                cleanup()
                _captureState.value = CaptureState.Idle
                Log.d(TAG, "Screen capture stopped")
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping screen capture", e)
                _captureState.value = CaptureState.Error(
                    MirroringError.UnknownError(e.message ?: "Stop capture failed"),
                    e.message ?: "Unknown error"
                )
            }
        }
    }
    
    /**
     * 设置后台线程
     */
    private fun setupBackgroundThread() {
        backgroundThread = HandlerThread("ScreenCapture").apply {
            start()
            backgroundHandler = Handler(looper)
        }
    }
    
    /**
     * 设置ImageReader
     */
    private fun setupImageReader(configuration: MirroringConfiguration) {
        val resolution = configuration.resolution
        
        imageReader = ImageReader.newInstance(
            resolution.width,
            resolution.height,
            PixelFormat.RGBA_8888,
            2
        ).apply {
            setOnImageAvailableListener({ reader ->
                processImage(reader)
            }, backgroundHandler)
        }
    }
    
    /**
     * 设置VirtualDisplay
     */
    private fun setupVirtualDisplay(configuration: MirroringConfiguration) {
        val resolution = configuration.resolution
        val displayMetrics = context.resources.displayMetrics
        
        virtualDisplay = mediaProjection?.createVirtualDisplay(
            VIRTUAL_DISPLAY_NAME,
            resolution.width,
            resolution.height,
            displayMetrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader?.surface,
            null,
            backgroundHandler
        )
        
        if (virtualDisplay == null) {
            throw IllegalStateException("Failed to create VirtualDisplay")
        }
    }
    
    /**
     * 处理捕获的图像
     */
    private fun processImage(reader: ImageReader) {
        try {
            val image = reader.acquireLatestImage()
            if (image != null) {
                val frameData = convertImageToFrameData(image)
                _frameData.tryEmit(frameData)
                image.close()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error processing image", e)
        }
    }
    
    /**
     * 将Image转换为FrameData
     */
    private fun convertImageToFrameData(image: android.media.Image): FrameData {
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
        
        // 转换为字节数组
        val stream = java.io.ByteArrayOutputStream()
        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream)
        val byteArray = stream.toByteArray()
        
        return FrameData(
            frameId = System.nanoTime(),
            timestamp = System.currentTimeMillis(),
            data = byteArray,
            width = image.width,
            height = image.height,
            format = image.format,
            isKeyFrame = false
        )
    }
    
    /**
     * 清理资源
     */
    private fun cleanup() {
        virtualDisplay?.release()
        virtualDisplay = null
        
        imageReader?.close()
        imageReader = null
        
        mediaProjection?.stop()
        mediaProjection = null
        
        backgroundThread?.quitSafely()
        backgroundThread = null
        backgroundHandler = null
    }
    
    /**
     * 获取屏幕分辨率
     */
    fun getScreenResolution(): Resolution {
        val displayMetrics = context.resources.displayMetrics
        return Resolution.fromDisplayMetrics(displayMetrics.widthPixels, displayMetrics.heightPixels)
    }
    
    /**
     * 检查是否支持屏幕捕获
     */
    fun isScreenCaptureSupported(): Boolean {
        return android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP
    }
}

/**
 * 捕获状态
 */
sealed class CaptureState {
    object Idle : CaptureState()
    object Initializing : CaptureState()
    data class Active(
        val sessionId: String,
        val configuration: MirroringConfiguration,
        val startTime: Long
    ) : CaptureState()
    object Stopping : CaptureState()
    data class Error(
        val error: MirroringError,
        val message: String
    ) : CaptureState()
}