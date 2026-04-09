package com.skybridge.compass.screenmirroring.display

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.util.DisplayMetrics
import android.util.Log
import android.view.Surface
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.State
import com.skybridge.compass.core.data.model.NetworkMessage
import com.skybridge.compass.core.data.model.MessageType
import com.skybridge.compass.core.network.NetworkClient
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.screenmirroring.model.ScreenCaptureConfig
import com.skybridge.compass.screenmirroring.model.ScreenFrame

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import java.util.concurrent.ConcurrentHashMap

/**
 * 屏幕显示管理器
 * 负责管理屏幕显示相关功能，包括分辨率、旋转等
 */
class ScreenDisplayManager constructor(
    private val networkClient: NetworkClient
) {
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    
    // 显示会话
    private val displaySessions = ConcurrentHashMap<String, DisplaySession>()
    
    // 当前显示的屏幕帧
    private val _currentFrame = mutableStateOf<ScreenFrame?>(null)
    val currentFrame: State<ScreenFrame?> = _currentFrame
    
    // 显示统计
    private val _displayStats = MutableStateFlow(DisplayStats())
    val displayStats: StateFlow<DisplayStats> = _displayStats.asStateFlow()
    
    // 显示状态
    private val _isDisplaying = MutableStateFlow(false)
    val isDisplaying: StateFlow<Boolean> = _isDisplaying.asStateFlow()
    
    // 帧缓冲区
    private val frameBuffer = mutableMapOf<String, MutableList<ScreenFrame>>()
    
    /**
     * 显示会话
     */
    data class DisplaySession(
        val deviceId: String,
        val config: ScreenCaptureConfig?,
        val startTime: Long = System.currentTimeMillis(),
        var lastFrameTime: Long = 0,
        var framesReceived: Long = 0,
        var bytesReceived: Long = 0,
        var droppedFrames: Long = 0,
        val job: Job
    )
    
    /**
     * 显示统计信息
     */
    data class DisplayStats(
        val activeSessions: Int = 0,
        val totalFramesReceived: Long = 0,
        val totalBytesReceived: Long = 0,
        val averageFps: Float = 0f,
        val averageBitrate: Long = 0,
        val droppedFrames: Long = 0,
        val latency: Long = 0,
        val uptime: Long = 0
    )
    
    init {
        // 监听网络消息
        scope.launch {
            networkClient.receiveMessages()
                .filter { msg -> msg.type == MessageType.SCREEN_DATA || msg.type == MessageType.STREAM_CONTROL }
                .collect { message ->
                    handleNetworkMessage(message)
                }
        }
        
        // 定期更新统计信息
        scope.launch {
            while (true) {
                delay(1000)
                updateStats()
            }
        }
    }
    
    /**
     * 开始显示来自指定设备的屏幕
     */
    suspend fun startDisplay(deviceId: String): Result<Unit> {
        return try {
            Logger.screenMirroring("开始显示设备 $deviceId 的屏幕")
            
            // 检查是否已存在会话
            if (displaySessions.containsKey(deviceId)) {
                Logger.screenMirroring("设备 $deviceId 已存在显示会话")
                return Result.success(Unit)
            }
            
            // 创建显示会话
            val sessionJob = scope.launch {
                processFramesFromDevice(deviceId)
            }
            
            val session = DisplaySession(
                deviceId = deviceId,
                config = null,
                job = sessionJob
            )
            
            displaySessions[deviceId] = session
            _isDisplaying.value = displaySessions.isNotEmpty()
            
            // 初始化帧缓冲区
            frameBuffer[deviceId] = mutableListOf()
            
            Logger.screenMirroring("设备 $deviceId 的屏幕显示已启动")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.screenMirroring("启动屏幕显示失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 停止显示指定设备的屏幕
     */
    suspend fun stopDisplay(deviceId: String): Result<Unit> {
        return try {
            Logger.screenMirroring("停止显示设备 $deviceId 的屏幕")
            
            val session = displaySessions.remove(deviceId)
            if (session != null) {
                session.job.cancel()
                Logger.screenMirroring("设备 $deviceId 的屏幕显示已停止")
            }
            
            // 清理帧缓冲区
            frameBuffer.remove(deviceId)
            
            // 如果是当前显示的设备，清除当前帧
            if (_currentFrame.value?.metadata?.get("deviceId") == deviceId) {
                _currentFrame.value = null
            }
            
            _isDisplaying.value = displaySessions.isNotEmpty()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.screenMirroring("停止屏幕显示失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 停止所有屏幕显示
     */
    suspend fun stopAllDisplay(): Result<Unit> {
        return try {
            Logger.screenMirroring("停止所有屏幕显示")
            
            val sessions = displaySessions.values.toList()
            displaySessions.clear()
            frameBuffer.clear()
            
            sessions.forEach { session ->
                session.job.cancel()
            }
            
            _currentFrame.value = null
            _isDisplaying.value = false
            
            Logger.screenMirroring("所有屏幕显示已停止")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.screenMirroring("停止所有屏幕显示失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 切换显示的设备
     */
    fun switchDisplayDevice(deviceId: String) {
        scope.launch {
            val buffer = frameBuffer[deviceId]
            if (buffer != null && buffer.isNotEmpty()) {
                val latestFrame = buffer.last()
                _currentFrame.value = latestFrame.copy(
                    metadata = latestFrame.metadata + ("deviceId" to deviceId)
                )
                Logger.screenMirroring("切换显示到设备 $deviceId")
            }
        }
    }
    
    /**
     * 获取活跃的显示会话
     */
    fun getActiveDisplays(): List<String> {
        return displaySessions.keys.toList()
    }
    
    /**
     * 获取指定设备的显示统计
     */
    fun getDisplayStats(deviceId: String): DisplaySession? {
        return displaySessions[deviceId]
    }
    
    /**
     * 处理网络消息
     */
    private suspend fun handleNetworkMessage(message: NetworkMessage) {
        try {
            when (message.type) {
                MessageType.SCREEN_DATA -> {
                    handleFrameMessage(message)
                }
                MessageType.STREAM_CONTROL -> {
                    handleStreamControlMessage(message)
                }
                else -> {
                    // 忽略其他类型的消息
                }
            }
        } catch (e: Exception) {
            Logger.screenMirroring("处理网络消息失败", e)
        }
    }
    
    /**
     * 处理帧消息
     */
    private suspend fun handleFrameMessage(message: NetworkMessage) {
        try {
            val frameMessage = Json.decodeFromString<FrameMessage>(message.payload)
            val deviceId = message.sourceDeviceId
            
            // 解码帧数据
            val frame = decodeFrame(frameMessage, deviceId)
            
            // 添加到缓冲区
            val buffer = frameBuffer[deviceId]
            if (buffer != null) {
                // 保持缓冲区大小
                if (buffer.size >= 10) {
                    buffer.removeAt(0)
                }
                buffer.add(frame)
                
                // 更新会话统计
                displaySessions[deviceId]?.let { session ->
                    session.lastFrameTime = System.currentTimeMillis()
                    session.framesReceived++
                    session.bytesReceived += frame.actualDataSize
                }
                
                // 如果是当前显示的设备，更新显示
                if (_currentFrame.value?.metadata?.get("deviceId") == deviceId || 
                    displaySessions.size == 1) {
                    _currentFrame.value = frame.copy(
                        metadata = frame.metadata + ("deviceId" to deviceId)
                    )
                }
            }
            
        } catch (e: Exception) {
            Logger.screenMirroring("处理帧消息失败", e)
        }
    }
    
    /**
     * 处理流控制消息
     */
    private suspend fun handleStreamControlMessage(message: NetworkMessage) {
        try {
            val controlMessage = Json.decodeFromString<StreamControlMessage>(message.payload)
            val deviceId = message.sourceDeviceId
            
            when (controlMessage.action) {
                "start" -> {
                    Logger.screenMirroring("收到设备 $deviceId 的流开始消息")
                    // 更新会话配置
                    displaySessions[deviceId]?.let { session ->
                        displaySessions[deviceId] = session.copy(config = controlMessage.config)
                    }
                }
                "stop" -> {
                    Logger.screenMirroring("收到设备 $deviceId 的流结束消息")
                    stopDisplay(deviceId)
                }
            }
            
        } catch (e: Exception) {
            Logger.screenMirroring("处理流控制消息失败", e)
        }
    }
    
    /**
     * 解码帧数据
     */
    private fun decodeFrame(frameMessage: FrameMessage, deviceId: String): ScreenFrame {
        val format = ScreenFrame.Format.valueOf(frameMessage.format)
        
        return when (format) {
            ScreenFrame.Format.BITMAP -> {
                val bitmap = BitmapFactory.decodeByteArray(
                    frameMessage.data, 0, frameMessage.data.size
                )
                ScreenFrame.fromBitmap(
                    bitmap = bitmap,
                    frameNumber = frameMessage.sequence,
                    quality = frameMessage.quality,
                    metadata = mapOf(
                        "deviceId" to deviceId,
                        "latency" to (System.currentTimeMillis() - frameMessage.timestamp).toString()
                    )
                )
            }
            ScreenFrame.Format.BYTES -> {
                ScreenFrame.fromBytes(
                    data = frameMessage.data,
                    width = frameMessage.width,
                    height = frameMessage.height,
                    frameNumber = frameMessage.sequence,
                    quality = frameMessage.quality,
                    metadata = mapOf(
                        "deviceId" to deviceId,
                        "latency" to (System.currentTimeMillis() - frameMessage.timestamp).toString()
                    )
                )
            }
            ScreenFrame.Format.ENCODED -> {
                val encodedData = ScreenFrame.EncodedData(
                    data = frameMessage.data,
                    codecType = "unknown", // 需要从消息中获取
                    isKeyFrame = frameMessage.isKeyFrame,
                    presentationTimeUs = frameMessage.timestamp * 1000
                )
                ScreenFrame.fromEncodedData(
                    encodedData = encodedData,
                    width = frameMessage.width,
                    height = frameMessage.height,
                    frameNumber = frameMessage.sequence,
                    quality = frameMessage.quality,
                    metadata = mapOf(
                        "deviceId" to deviceId,
                        "latency" to (System.currentTimeMillis() - frameMessage.timestamp).toString()
                    )
                )
            }
        }
    }
    
    /**
     * 处理来自设备的帧数据
     */
    private suspend fun processFramesFromDevice(deviceId: String) {
        try {
            Logger.screenMirroring("开始处理设备 $deviceId 的帧数据")
            
            // 这里可以添加帧处理逻辑，如帧率控制、质量调整等
            while (displaySessions.containsKey(deviceId)) {
                delay(16) // 约60fps的处理频率
                
                // 检查帧缓冲区
                val buffer = frameBuffer[deviceId]
                if (buffer != null && buffer.isNotEmpty()) {
                    // 可以在这里添加帧处理逻辑
                    // 例如：丢帧、插值、质量调整等
                }
            }
            
        } catch (e: Exception) {
            Logger.screenMirroring("处理设备 $deviceId 帧数据时出错", e)
        }
    }
    
    /**
     * 更新统计信息
     */
    private fun updateStats() {
        val sessions = displaySessions.values
        val currentTime = System.currentTimeMillis()
        
        val totalFrames = sessions.sumOf { it.framesReceived }
        val totalBytes = sessions.sumOf { it.bytesReceived }
        val totalDropped = sessions.sumOf { it.droppedFrames }
        
        // 计算平均FPS
        val avgFps = if (sessions.isNotEmpty()) {
            sessions.map { session ->
                val duration = (currentTime - session.startTime) / 1000f
                if (duration > 0) session.framesReceived / duration else 0f
            }.average().toFloat()
        } else 0f
        
        // 计算平均比特率
        val avgBitrate = if (sessions.isNotEmpty()) {
            sessions.map { session ->
                val duration = (currentTime - session.startTime) / 1000f
                if (duration > 0) (session.bytesReceived * 8) / duration.toLong() else 0L
            }.average().toLong()
        } else 0L
        
        // 计算平均延迟
        val avgLatency = _currentFrame.value?.metadata?.get("latency")?.toLongOrNull() ?: 0L
        
        _displayStats.value = DisplayStats(
            activeSessions = sessions.size,
            totalFramesReceived = totalFrames,
            totalBytesReceived = totalBytes,
            averageFps = avgFps,
            averageBitrate = avgBitrate,
            droppedFrames = totalDropped,
            latency = avgLatency,
            uptime = if (sessions.isNotEmpty()) {
                sessions.minOfOrNull { currentTime - it.startTime } ?: 0
            } else 0
        )
    }
    
    /**
     * 帧消息数据类
     */
    @kotlinx.serialization.Serializable
    private data class FrameMessage(
        val sequence: Long,
        val timestamp: Long,
        val width: Int,
        val height: Int,
        val format: String,
        val isKeyFrame: Boolean,
        val quality: Int,
        val dataSize: Int,
        val data: ByteArray
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (javaClass != other?.javaClass) return false
            
            other as FrameMessage
            
            if (sequence != other.sequence) return false
            if (timestamp != other.timestamp) return false
            if (width != other.width) return false
            if (height != other.height) return false
            if (format != other.format) return false
            if (isKeyFrame != other.isKeyFrame) return false
            if (quality != other.quality) return false
            if (dataSize != other.dataSize) return false
            if (!data.contentEquals(other.data)) return false
            
            return true
        }
        
        override fun hashCode(): Int {
            var result = sequence.hashCode()
            result = 31 * result + timestamp.hashCode()
            result = 31 * result + width
            result = 31 * result + height
            result = 31 * result + format.hashCode()
            result = 31 * result + isKeyFrame.hashCode()
            result = 31 * result + quality
            result = 31 * result + dataSize
            result = 31 * result + data.contentHashCode()
            return result
        }
    }
    
    /**
     * 流控制消息数据类
     */
    @kotlinx.serialization.Serializable
    private data class StreamControlMessage(
        val action: String,
        val config: ScreenCaptureConfig? = null,
        val timestamp: Long = System.currentTimeMillis()
    )
}