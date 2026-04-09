package com.skybridge.compass.screenmirroring.streaming

import android.util.Log
import com.skybridge.compass.core.data.model.Connection
import com.skybridge.compass.core.data.model.Device
import com.skybridge.compass.core.data.model.NetworkMessage
import com.skybridge.compass.core.data.model.MessageType
import com.skybridge.compass.core.data.model.MessagePriority
import com.skybridge.compass.core.repository.ConnectionRepository
import com.skybridge.compass.core.network.NetworkClient
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.screenmirroring.model.ScreenFrame
import com.skybridge.compass.screenmirroring.model.ScreenCaptureConfig
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * 屏幕流传输管理器
 * 负责管理屏幕流的传输、编码和网络发送
 */
class ScreenStreamingManager constructor(
    private val networkClient: NetworkClient,
    private val connectionRepository: ConnectionRepository
) {
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    // 活跃的流传输会话
    private val activeStreams = ConcurrentHashMap<String, StreamSession>()
    
    // 传输统计
    private val _streamingStats = MutableStateFlow(StreamingStats())
    val streamingStats: StateFlow<StreamingStats> = _streamingStats.asStateFlow()
    
    // 传输状态
    private val _isStreaming = MutableStateFlow(false)
    val isStreaming: StateFlow<Boolean> = _isStreaming.asStateFlow()
    
    // 帧序号生成器
    private val frameSequence = AtomicLong(0)
    
    /**
     * 流传输会话
     */
    internal data class StreamSession(
        val deviceId: String,
        val connection: Connection,
        val config: ScreenCaptureConfig,
        val startTime: Long = System.currentTimeMillis(),
        var lastFrameTime: Long = 0,
        var framesSent: Long = 0,
        var bytesSent: Long = 0,
        var errors: Int = 0,
        val job: Job
    )
    
    /**
     * 传输统计信息
     */
    data class StreamingStats(
        val activeSessions: Int = 0,
        val totalFramesSent: Long = 0,
        val totalBytesSent: Long = 0,
        val averageFps: Float = 0f,
        val averageBitrate: Long = 0,
        val totalErrors: Int = 0,
        val uptime: Long = 0
    )
    
    /**
     * 开始向指定设备流传输
     */
    suspend fun startStreaming(
        device: Device,
        config: ScreenCaptureConfig,
        frameSource: Flow<ScreenFrame>
    ): Result<Unit> {
        return try {
            Logger.screenMirroring("开始向设备 ${device.name} 流传输屏幕")
            
            // 检查是否已存在会话
            if (activeStreams.containsKey(device.id)) {
                Logger.screenMirroring("设备 ${device.name} 已存在流传输会话")
                return Result.success(Unit)
            }
            
            // 获取或创建连接
            val connection = getOrCreateConnection(device)
            
            // 创建流传输会话
            val sessionJob = scope.launch {
                streamToDevice(device, connection, config, frameSource)
            }
            
            val session = StreamSession(
                deviceId = device.id,
                connection = connection,
                config = config,
                job = sessionJob
            )
            
            activeStreams[device.id] = session
            _isStreaming.value = activeStreams.isNotEmpty()
            
            // 更新统计信息
            updateStats()
            
            Logger.screenMirroring("向设备 ${device.name} 的流传输已启动")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.screenMirroring("启动流传输失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 停止向指定设备的流传输
     */
    suspend fun stopStreaming(deviceId: String): Result<Unit> {
        return try {
            Logger.screenMirroring("停止向设备 $deviceId 的流传输")
            
            val session = activeStreams.remove(deviceId)
            if (session != null) {
                session.job.cancel()
                
                // 发送流结束消息
                sendStreamEndMessage(session.connection)
                
                Logger.screenMirroring("设备 $deviceId 的流传输已停止")
            }
            
            _isStreaming.value = activeStreams.isNotEmpty()
            updateStats()
            
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.screenMirroring("停止流传输失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 停止所有流传输
     */
    suspend fun stopAllStreaming(): Result<Unit> {
        return try {
            Logger.screenMirroring("停止所有流传输")
            
            val sessions = activeStreams.values.toList()
            activeStreams.clear()
            
            sessions.forEach { session ->
                session.job.cancel()
                sendStreamEndMessage(session.connection)
            }
            
            _isStreaming.value = false
            updateStats()
            
            Logger.screenMirroring("所有流传输已停止")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.screenMirroring("停止所有流传输失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 获取活跃的流传输会话
     */
    fun getActiveStreams(): List<String> {
        return activeStreams.keys.toList()
    }
    
    /**
     * 获取指定设备的流传输统计
     */
    internal fun getStreamStats(deviceId: String): StreamSession? {
        return activeStreams[deviceId]
    }
    
    /**
     * 向设备流传输屏幕帧
     */
    private suspend fun streamToDevice(
        device: Device,
        connection: Connection,
        config: ScreenCaptureConfig,
        frameSource: Flow<ScreenFrame>
    ) {
        try {
            Logger.screenMirroring("开始向设备 ${device.name} 传输帧数据")
            
            // 发送流开始消息
            sendStreamStartMessage(connection, config)
            
            // 处理帧数据流
            frameSource
                .filter { it.isValid }
                .collect { frame ->
                    try {
                        sendFrame(device.id, connection, frame)
                        
                        // 更新会话统计
                        activeStreams[device.id]?.let { session ->
                            session.lastFrameTime = System.currentTimeMillis()
                            session.framesSent++
                            session.bytesSent += frame.actualDataSize
                        }
                        
                    } catch (e: Exception) {
                        Logger.screenMirroring("发送帧到设备 ${device.name} 失败", e)
                        
                        // 更新错误计数
                        activeStreams[device.id]?.let { session ->
                            session.errors++
                        }
                        
                        // 如果错误过多，停止流传输
                        if (activeStreams[device.id]?.errors ?: 0 > 10) {
                            Logger.screenMirroring("设备 ${device.name} 错误过多，停止流传输")
                            scope.launch {
                                stopStreaming(device.id)
                            }
                        }
                    }
                }
                
        } catch (e: Exception) {
            Logger.screenMirroring("流传输到设备 ${device.name} 时出错", e)
        }
    }
    
    /**
     * 发送帧数据
     */
    private suspend fun sendFrame(
        deviceId: String,
        connection: Connection,
        frame: ScreenFrame
    ) {
        val frameData = when (frame.format) {
            ScreenFrame.Format.BITMAP -> {
                // 将Bitmap转换为字节数组
                frame.toByteArray() ?: return
            }
            ScreenFrame.Format.BYTES -> {
                frame.data ?: return
            }
            ScreenFrame.Format.ENCODED -> {
                frame.encodedData?.data ?: return
            }
        }
        
        // 创建帧消息
        val frameMessage = FrameMessage(
            sequence = frameSequence.incrementAndGet(),
            timestamp = frame.timestamp,
            width = frame.width,
            height = frame.height,
            format = frame.format.name,
            isKeyFrame = frame.isKeyFrame,
            quality = frame.quality,
            dataSize = frameData.size,
            data = frameData
        )
        
        // 序列化消息
        val messageJson = Json.encodeToString(frameMessage)
        
        // 创建网络消息
        val networkMessage = NetworkMessage(
            id = "frame_${frameMessage.sequence}",
            type = MessageType.SCREEN_DATA,
            sourceDeviceId = "", // 本设备ID
            targetDeviceId = deviceId,
            payload = messageJson,
            priority = MessagePriority.HIGH,
            timestamp = System.currentTimeMillis()
        )
        
        // 发送消息
        networkClient.sendMessage(networkMessage)
    }
    
    /**
     * 发送流开始消息
     */
    private suspend fun sendStreamStartMessage(
        connection: Connection,
        config: ScreenCaptureConfig
    ) {
        val startMessage = StreamControlMessage(
            action = "start",
            config = config
        )
        
        val messageJson = Json.encodeToString(startMessage)
        
        val networkMessage = NetworkMessage(
            id = "stream_start_${System.currentTimeMillis()}",
            type = MessageType.STREAM_CONTROL,
            sourceDeviceId = "",
            targetDeviceId = connection.deviceId,
            payload = messageJson,
            priority = MessagePriority.HIGH,
            timestamp = System.currentTimeMillis()
        )
        
        networkClient.sendMessage(networkMessage)
    }
    
    /**
     * 发送流结束消息
     */
    private suspend fun sendStreamEndMessage(connection: Connection) {
        val endMessage = StreamControlMessage(
            action = "stop"
        )
        
        val messageJson = Json.encodeToString(endMessage)
        
        val networkMessage = NetworkMessage(
            id = "stream_end_${System.currentTimeMillis()}",
            type = MessageType.STREAM_CONTROL,
            sourceDeviceId = "",
            targetDeviceId = connection.deviceId,
            payload = messageJson,
            priority = MessagePriority.HIGH,
            timestamp = System.currentTimeMillis()
        )
        
        networkClient.sendMessage(networkMessage)
    }
    
    /**
     * 获取或创建连接
     */
    private suspend fun getOrCreateConnection(device: Device): Connection {
        // 尝试获取现有连接
        val existingConnections = connectionRepository.getConnectionsByDevice(device.id).first()
        val activeConnection = existingConnections.find { 
            it.status == com.skybridge.compass.core.data.model.ConnectionStatus.CONNECTED 
        }
        
        if (activeConnection != null) {
            return activeConnection
        }
        
        // 创建新连接
        val newConnection = Connection(
            id = "stream_${device.id}_${System.currentTimeMillis()}",
            deviceId = device.id,
            status = com.skybridge.compass.core.data.model.ConnectionStatus.CONNECTING,
            protocol = com.skybridge.compass.core.data.model.ConnectionProtocol.TCP,
            establishedAt = System.currentTimeMillis(),
            lastActivity = System.currentTimeMillis(),
            latency = 0L,
            bandwidth = 0L,
            errorCount = 0,
            metadata = mapOf(
                "address" to device.ipAddress,
                "port" to "8080"
            )
        )
        
        connectionRepository.saveConnection(newConnection)
        return newConnection
    }
    
    /**
     * 更新统计信息
     */
    private fun updateStats() {
        val sessions = activeStreams.values
        val currentTime = System.currentTimeMillis()
        
        val totalFrames = sessions.sumOf { it.framesSent }
        val totalBytes = sessions.sumOf { it.bytesSent }
        val totalErrors = sessions.sumOf { it.errors }
        
        // 计算平均FPS
        val avgFps = if (sessions.isNotEmpty()) {
            sessions.map { session ->
                val duration = (currentTime - session.startTime) / 1000f
                if (duration > 0) session.framesSent / duration else 0f
            }.average().toFloat()
        } else 0f
        
        // 计算平均比特率
        val avgBitrate = if (sessions.isNotEmpty()) {
            sessions.map { session ->
                val duration = (currentTime - session.startTime) / 1000f
                if (duration > 0) (session.bytesSent * 8) / duration.toLong() else 0L
            }.average().toLong()
        } else 0L
        
        _streamingStats.value = StreamingStats(
            activeSessions = sessions.size,
            totalFramesSent = totalFrames,
            totalBytesSent = totalBytes,
            averageFps = avgFps,
            averageBitrate = avgBitrate,
            totalErrors = totalErrors,
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