package com.skybridge.compass.remotecontrol.transmission

import com.skybridge.compass.core.network.NetworkClient
import com.skybridge.compass.core.repository.ConnectionRepository
import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.remotecontrol.model.*
import dagger.hilt.android.scopes.ServiceScoped
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject

/**
 * 远程控制传输管理器
 * 负责输入事件的网络传输和接收
 */
@ServiceScoped
class RemoteControlTransmissionManager @Inject constructor(
    private val networkClient: NetworkClient,
    private val connectionRepository: ConnectionRepository
) {
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    // 传输状态
    private val _isTransmissionActive = MutableStateFlow(false)
    val isTransmissionActive: StateFlow<Boolean> = _isTransmissionActive.asStateFlow()
    
    // 接收到的输入事件流
    private val _receivedInputEvents = MutableSharedFlow<InputEvent>()
    val receivedInputEvents: SharedFlow<InputEvent> = _receivedInputEvents.asSharedFlow()
    
    // 接收到的输入事件批次流
    private val _receivedInputBatches = MutableSharedFlow<InputEventBatch>()
    val receivedInputBatches: SharedFlow<InputEventBatch> = _receivedInputBatches.asSharedFlow()
    
    // 传输统计
    private val _transmissionStats = MutableStateFlow(TransmissionStats())
    val transmissionStats: StateFlow<TransmissionStats> = _transmissionStats.asStateFlow()
    
    // 活跃的控制会话
    private val _activeControlSessions = MutableStateFlow<Map<String, ControlSession>>(emptyMap())
    val activeControlSessions: StateFlow<Map<String, ControlSession>> = _activeControlSessions.asStateFlow()
    
    /**
     * 开始传输
     */
    fun startTransmission(): Result<Unit> {
        return try {
            Logger.remoteControl("开始远程控制传输")
            
            _isTransmissionActive.value = true
            
            // 监听网络消息
            scope.launch {
                networkClient.receiveMessages()
                    .collect { networkMessage ->
                        handleIncomingMessage(networkMessage.payload)
                    }
            }
            
            // 重置统计
            _transmissionStats.value = TransmissionStats()
            
            Logger.remoteControl("远程控制传输已启动")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.remoteControl("启动远程控制传输失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 停止传输
     */
    fun stopTransmission(): Result<Unit> {
        return try {
            Logger.remoteControl("停止远程控制传输")
            
            _isTransmissionActive.value = false
            
            // 停止所有控制会话
            scope.launch {
                _activeControlSessions.value.values.forEach { session ->
                    stopControlSession(session.deviceId)
                }
            }
            
            Logger.remoteControl("远程控制传输已停止")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.remoteControl("停止远程控制传输失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 发送输入事件到指定设备
     */
    suspend fun sendInputEvent(deviceId: String, event: InputEvent): Result<Unit> {
        return try {
            if (!_isTransmissionActive.value) {
                return Result.failure(IllegalStateException("传输未启动"))
            }
            
            val message = InputEventMessage(
                type = "input_event",
                deviceId = deviceId,
                event = event,
                timestamp = System.currentTimeMillis()
            )
            
            val jsonMessage = Json.encodeToString(message)
            val networkMessage = com.skybridge.compass.core.data.model.NetworkMessage(
                id = java.util.UUID.randomUUID().toString(),
                type = com.skybridge.compass.core.data.model.MessageType.CONTROL_INPUT,
                sourceDeviceId = "local",
                targetDeviceId = deviceId,
                payload = jsonMessage
            )
            networkClient.sendMessage(networkMessage)
            
            // 更新统计
            updateTransmissionStats(sent = true)
            
            Logger.remoteControl("输入事件已发送到设备: $deviceId")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.remoteControl("发送输入事件失败", e)
            updateTransmissionStats(sent = false, error = true)
            Result.failure(e)
        }
    }
    
    /**
     * 发送输入事件批次到指定设备
     */
    suspend fun sendInputEventBatch(deviceId: String, batch: InputEventBatch): Result<Unit> {
        return try {
            if (!_isTransmissionActive.value) {
                return Result.failure(IllegalStateException("传输未启动"))
            }
            
            val message = InputEventBatchMessage(
                type = "input_event_batch",
                deviceId = deviceId,
                batch = batch,
                timestamp = System.currentTimeMillis()
            )
            
            val jsonMessage = Json.encodeToString(message)
            val networkMessage = com.skybridge.compass.core.data.model.NetworkMessage(
                id = java.util.UUID.randomUUID().toString(),
                type = com.skybridge.compass.core.data.model.MessageType.CONTROL_INPUT,
                sourceDeviceId = "local",
                targetDeviceId = deviceId,
                payload = jsonMessage
            )
            networkClient.sendMessage(networkMessage)
            
            // 更新统计
            updateTransmissionStats(sent = true, batchSize = batch.events.size)
            
            Logger.remoteControl("输入事件批次已发送到设备: $deviceId (${batch.events.size}个事件)")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.remoteControl("发送输入事件批次失败", e)
            updateTransmissionStats(sent = false, error = true)
            Result.failure(e)
        }
    }
    
    /**
     * 开始控制会话
     */
    suspend fun startControlSession(deviceId: String, config: RemoteControlConfig = RemoteControlConfig()): Result<ControlSession> {
        return try {
            Logger.remoteControl("开始控制会话: $deviceId")
            
            val session = ControlSession(
                deviceId = deviceId,
                startTime = System.currentTimeMillis(),
                config = config,
                isActive = true
            )
            
            // 发送控制会话开始消息
            val message = ControlSessionMessage(
                type = "control_session_start",
                deviceId = deviceId,
                config = config,
                timestamp = System.currentTimeMillis()
            )
            
            val jsonMessage = Json.encodeToString(message)
            val networkMessage = com.skybridge.compass.core.data.model.NetworkMessage(
                id = java.util.UUID.randomUUID().toString(),
                type = com.skybridge.compass.core.data.model.MessageType.CONTROL_INPUT,
                sourceDeviceId = "local",
                targetDeviceId = deviceId,
                payload = jsonMessage
            )
            networkClient.sendMessage(networkMessage)
            
            // 添加到活跃会话
            _activeControlSessions.value = _activeControlSessions.value + (deviceId to session)
            
            Logger.remoteControl("控制会话已开始: $deviceId")
            Result.success(session)
            
        } catch (e: Exception) {
            Logger.remoteControl("开始控制会话失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 停止控制会话
     */
    suspend fun stopControlSession(deviceId: String): Result<Unit> {
        return try {
            Logger.remoteControl("停止控制会话: $deviceId")
            
            // 发送控制会话停止消息
            val message = ControlSessionMessage(
                type = "control_session_stop",
                deviceId = deviceId,
                timestamp = System.currentTimeMillis()
            )
            
            val jsonMessage = Json.encodeToString(message)
            val networkMessage = com.skybridge.compass.core.data.model.NetworkMessage(
                id = java.util.UUID.randomUUID().toString(),
                type = com.skybridge.compass.core.data.model.MessageType.CONTROL_INPUT,
                sourceDeviceId = "local",
                targetDeviceId = deviceId,
                payload = jsonMessage
            )
            networkClient.sendMessage(networkMessage)
            
            // 从活跃会话中移除
            _activeControlSessions.value = _activeControlSessions.value - deviceId
            
            Logger.remoteControl("控制会话已停止: $deviceId")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.remoteControl("停止控制会话失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 发送输入事件响应
     */
    suspend fun sendInputEventResponse(deviceId: String, response: InputEventResponse): Result<Unit> {
        return try {
            val message = InputEventResponseMessage(
                type = "input_event_response",
                deviceId = deviceId,
                response = response,
                timestamp = System.currentTimeMillis()
            )
            
            val jsonMessage = Json.encodeToString(message)
            val networkMessage = com.skybridge.compass.core.data.model.NetworkMessage(
                id = java.util.UUID.randomUUID().toString(),
                type = com.skybridge.compass.core.data.model.MessageType.CONTROL_INPUT,
                sourceDeviceId = "local",
                targetDeviceId = deviceId,
                payload = jsonMessage
            )
            networkClient.sendMessage(networkMessage)
            
            Logger.remoteControl("输入事件响应已发送: ${response.eventId}")
            Result.success(Unit)
            
        } catch (e: Exception) {
            Logger.remoteControl("发送输入事件响应失败", e)
            Result.failure(e)
        }
    }
    
    /**
     * 处理接收到的消息
     */
    private suspend fun handleIncomingMessage(message: String) {
        try {
            val json = Json.parseToJsonElement(message)
            val type = json.jsonObject["type"]?.jsonPrimitive?.content
            
            when (type) {
                "input_event" -> {
                    val inputMessage = Json.decodeFromString<InputEventMessage>(message)
                    handleInputEvent(inputMessage)
                }
                "input_event_batch" -> {
                    val batchMessage = Json.decodeFromString<InputEventBatchMessage>(message)
                    handleInputEventBatch(batchMessage)
                }
                "control_session_start" -> {
                    val sessionMessage = Json.decodeFromString<ControlSessionMessage>(message)
                    handleControlSessionStart(sessionMessage)
                }
                "control_session_stop" -> {
                    val sessionMessage = Json.decodeFromString<ControlSessionMessage>(message)
                    handleControlSessionStop(sessionMessage)
                }
                "input_event_response" -> {
                    val responseMessage = Json.decodeFromString<InputEventResponseMessage>(message)
                    handleInputEventResponse(responseMessage)
                }
                else -> {
                    Logger.remoteControl("未知的远程控制消息类型: $type")
                }
            }
            
        } catch (e: Exception) {
            Logger.remoteControl("处理远程控制消息失败", e)
        }
    }
    
    /**
     * 处理输入事件
     */
    private suspend fun handleInputEvent(message: InputEventMessage) {
        try {
            Logger.remoteControl("接收到输入事件: ${message.event.eventId}")
            
            // 更新统计
            updateTransmissionStats(received = true)
            
            // 发送到事件流
            _receivedInputEvents.emit(message.event)
            
        } catch (e: Exception) {
            Logger.remoteControl("处理输入事件失败", e)
        }
    }
    
    /**
     * 处理输入事件批次
     */
    private suspend fun handleInputEventBatch(message: InputEventBatchMessage) {
        try {
            Logger.remoteControl("接收到输入事件批次: ${message.batch.batchId} (${message.batch.events.size}个事件)")
            
            // 更新统计
            updateTransmissionStats(received = true, batchSize = message.batch.events.size)
            
            // 发送到事件流
            _receivedInputBatches.emit(message.batch)
            
            // 也发送单个事件到事件流
            message.batch.events.forEach { event ->
                _receivedInputEvents.emit(event)
            }
            
        } catch (e: Exception) {
            Logger.remoteControl("处理输入事件批次失败", e)
        }
    }
    
    /**
     * 处理控制会话开始
     */
    private suspend fun handleControlSessionStart(message: ControlSessionMessage) {
        try {
            Logger.remoteControl("接收到控制会话开始请求: ${message.deviceId}")
            
            val session = ControlSession(
                deviceId = message.deviceId,
                startTime = message.timestamp,
                config = message.config ?: RemoteControlConfig(),
                isActive = true
            )
            
            // 添加到活跃会话
            _activeControlSessions.value = _activeControlSessions.value + (message.deviceId to session)
            
        } catch (e: Exception) {
            Logger.remoteControl("处理控制会话开始失败", e)
        }
    }
    
    /**
     * 处理控制会话停止
     */
    private suspend fun handleControlSessionStop(message: ControlSessionMessage) {
        try {
            Logger.remoteControl("接收到控制会话停止请求: ${message.deviceId}")
            
            // 从活跃会话中移除
            _activeControlSessions.value = _activeControlSessions.value - message.deviceId
            
        } catch (e: Exception) {
            Logger.remoteControl("处理控制会话停止失败", e)
        }
    }
    
    /**
     * 处理输入事件响应
     */
    private suspend fun handleInputEventResponse(message: InputEventResponseMessage) {
        try {
            Logger.remoteControl("接收到输入事件响应: ${message.response.eventId}")
            
            // 这里可以添加响应处理逻辑，比如更新UI状态等
            
        } catch (e: Exception) {
            Logger.remoteControl("处理输入事件响应失败", e)
        }
    }
    
    /**
     * 更新传输统计
     */
    private fun updateTransmissionStats(
        sent: Boolean = false,
        received: Boolean = false,
        error: Boolean = false,
        batchSize: Int = 1
    ) {
        _transmissionStats.value = _transmissionStats.value.let { stats ->
            stats.copy(
                totalEventsSent = if (sent) stats.totalEventsSent + batchSize else stats.totalEventsSent,
                totalEventsReceived = if (received) stats.totalEventsReceived + batchSize else stats.totalEventsReceived,
                totalErrors = if (error) stats.totalErrors + 1 else stats.totalErrors,
                lastActivityTime = System.currentTimeMillis()
            )
        }
    }
    
    /**
     * 获取指定设备的控制会话
     */
    fun getControlSession(deviceId: String): ControlSession? {
        return _activeControlSessions.value[deviceId]
    }
    
    /**
     * 检查设备是否在控制会话中
     */
    fun isDeviceInControlSession(deviceId: String): Boolean {
        return _activeControlSessions.value.containsKey(deviceId)
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        scope.launch {
            try {
                Logger.remoteControl("清理远程控制传输资源")
                
                stopTransmission()
                scope.cancel()
                
                Logger.remoteControl("远程控制传输资源清理完成")
                
            } catch (e: Exception) {
                Logger.remoteControl("清理远程控制传输资源失败", e)
            }
        }
    }
}

/**
 * 传输统计数据
 */
@Serializable
data class TransmissionStats(
    val totalEventsSent: Long = 0,
    val totalEventsReceived: Long = 0,
    val totalErrors: Long = 0,
    val lastActivityTime: Long = 0,
    val averageLatency: Double = 0.0
)

/**
 * 控制会话
 */
@Serializable
data class ControlSession(
    val deviceId: String,
    val startTime: Long,
    val config: RemoteControlConfig,
    val isActive: Boolean = true,
    val endTime: Long? = null
)

/**
 * 远程控制配置
 */
@Serializable
data class RemoteControlConfig(
    val enableTouch: Boolean = true,
    val enableKeyboard: Boolean = true,
    val enableMouse: Boolean = true,
    val enableGesture: Boolean = true,
    val enableTextInput: Boolean = true,
    val enableSystemKeys: Boolean = false,
    val maxBatchSize: Int = 10,
    val batchTimeout: Long = 100,
    val compressionEnabled: Boolean = true,
    val encryptionEnabled: Boolean = true
)

/**
 * 输入事件消息
 */
@Serializable
data class InputEventMessage(
    val type: String,
    val deviceId: String,
    val event: InputEvent,
    val timestamp: Long
)

/**
 * 输入事件批次消息
 */
@Serializable
data class InputEventBatchMessage(
    val type: String,
    val deviceId: String,
    val batch: InputEventBatch,
    val timestamp: Long
)

/**
 * 控制会话消息
 */
@Serializable
data class ControlSessionMessage(
    val type: String,
    val deviceId: String,
    val config: RemoteControlConfig? = null,
    val timestamp: Long
)

/**
 * 输入事件响应消息
 */
@Serializable
data class InputEventResponseMessage(
    val type: String,
    val deviceId: String,
    val response: InputEventResponse,
    val timestamp: Long
)