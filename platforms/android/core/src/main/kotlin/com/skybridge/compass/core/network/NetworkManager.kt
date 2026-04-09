package com.skybridge.compass.core.network

import io.ktor.client.*
import io.ktor.client.engine.android.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.plugins.websocket.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.websocket.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.time.Duration.Companion.milliseconds

class NetworkManager {
    private val _connectionState = MutableStateFlow(NetworkState.DISCONNECTED)
    val connectionState: StateFlow<NetworkState> = _connectionState.asStateFlow()

    private val json = Json {
        prettyPrint = true
        isLenient = true
        ignoreUnknownKeys = true
    }

    private val httpClient = HttpClient(Android) {
        install(ContentNegotiation) {
            json(json)
        }
        install(WebSockets) {
            // Ktor 3: pingInterval 使用 Duration
            pingInterval = 20_000.milliseconds
        }
    }

    private var webSocketSession: DefaultWebSocketSession? = null
    private var receiveJob: Job? = null
    private val messageChannel = Channel<NetworkMessage>(Channel.BUFFERED)
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // 当前连接信息
    private var currentHost: String? = null
    private var currentPort: Int? = null

    suspend fun connect(host: String, port: Int): Result<Unit> {
        return try {
            _connectionState.value = NetworkState.CONNECTING
            currentHost = host
            currentPort = port

            // 建立 WebSocket 连接
            httpClient.webSocket(
                host = host,
                port = port,
                path = "/skybridge/v2"
            ) {
                webSocketSession = this
                _connectionState.value = NetworkState.CONNECTED

                // 发送设备信息
                val deviceInfo = NetworkMessage.DeviceInfo(
                    deviceId = android.os.Build.MODEL,
                    capabilities = listOf("screen_mirroring", "remote_control", "file_transfer", "pqc")
                )
                sendMessage(deviceInfo)

                // 启动消息接收循环
                receiveJob = scope.launch {
                    try {
                        for (frame in incoming) {
                            when (frame) {
                                is Frame.Text -> {
                                    val text = frame.readText()
                                    val message = parseMessage(text)
                                    messageChannel.send(message)
                                }
                                is Frame.Binary -> {
                                    val data = frame.readBytes()
                                    // 处理二进制帧（屏幕帧等）
                                    val screenFrame = NetworkMessage.ScreenFrame(
                                        data = data,
                                        timestamp = System.currentTimeMillis()
                                    )
                                    messageChannel.send(screenFrame)
                                }
                                is Frame.Ping -> {
                                    send(Frame.Pong(frame.data))
                                }
                                is Frame.Pong -> {
                                    messageChannel.send(NetworkMessage.Pong)
                                }
                                is Frame.Close -> {
                                    _connectionState.value = NetworkState.DISCONNECTED
                                }
                            }
                        }
                    } catch (e: ClosedReceiveChannelException) {
                        _connectionState.value = NetworkState.DISCONNECTED
                    } catch (e: Exception) {
                        _connectionState.value = NetworkState.ERROR
                        messageChannel.send(NetworkMessage.Error(e.message ?: "Unknown error", -1))
                    }
                }

                // 保持连接直到关闭
                receiveJob?.join()
            }

            Result.success(Unit)
        } catch (e: Exception) {
            _connectionState.value = NetworkState.ERROR
            Result.failure(e)
        }
    }

    suspend fun disconnect() {
        _connectionState.value = NetworkState.DISCONNECTING
        try {
            receiveJob?.cancel()
            webSocketSession?.close(CloseReason(CloseReason.Codes.NORMAL, "User requested disconnect"))
            webSocketSession = null
            currentHost = null
            currentPort = null
        } finally {
            _connectionState.value = NetworkState.DISCONNECTED
        }
    }

    suspend fun sendMessage(message: NetworkMessage): Result<Unit> {
        return try {
            val session = webSocketSession
                ?: return Result.failure(IllegalStateException("Not connected"))

            when (message) {
                is NetworkMessage.Ping -> {
                    session.send(Frame.Ping(byteArrayOf()))
                }
                is NetworkMessage.Pong -> {
                    session.send(Frame.Pong(byteArrayOf()))
                }
                is NetworkMessage.ScreenFrame -> {
                    session.send(Frame.Binary(true, message.data))
                }
                else -> {
                    val jsonText = serializeMessage(message)
                    session.send(Frame.Text(jsonText))
                }
            }
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun observeMessages(): Flow<NetworkMessage> {
        return messageChannel.receiveAsFlow()
    }

    private fun parseMessage(text: String): NetworkMessage {
        return try {
            val wrapper = json.decodeFromString<MessageWrapper>(text)
            when (wrapper.type) {
                "ping" -> NetworkMessage.Ping
                "pong" -> NetworkMessage.Pong
                "device_info" -> {
                    val data = json.decodeFromString<DeviceInfoData>(wrapper.data)
                    NetworkMessage.DeviceInfo(data.deviceId, data.capabilities)
                }
                "touch_event" -> {
                    val data = json.decodeFromString<TouchEventData>(wrapper.data)
                    NetworkMessage.TouchEvent(data.x, data.y, data.action)
                }
                "error" -> {
                    val data = json.decodeFromString<ErrorData>(wrapper.data)
                    NetworkMessage.Error(data.message, data.code)
                }
                else -> NetworkMessage.Error("Unknown message type: ${wrapper.type}", -1)
            }
        } catch (e: Exception) {
            NetworkMessage.Error("Parse error: ${e.message}", -1)
        }
    }

    private fun serializeMessage(message: NetworkMessage): String {
        val (type, data) = when (message) {
            is NetworkMessage.Ping -> "ping" to "{}"
            is NetworkMessage.Pong -> "pong" to "{}"
            is NetworkMessage.DeviceInfo -> "device_info" to json.encodeToString(
                DeviceInfoData(message.deviceId, message.capabilities)
            )
            is NetworkMessage.TouchEvent -> "touch_event" to json.encodeToString(
                TouchEventData(message.x, message.y, message.action)
            )
            is NetworkMessage.Error -> "error" to json.encodeToString(
                ErrorData(message.message, message.code)
            )
            is NetworkMessage.ScreenFrame -> "screen_frame" to "{}"
        }
        return json.encodeToString(MessageWrapper(type, data))
    }

    fun close() {
        scope.cancel()
        httpClient.close()
    }
}

// 消息包装器
@Serializable
private data class MessageWrapper(
    val type: String,
    val data: String
)

@Serializable
private data class DeviceInfoData(
    val deviceId: String,
    val capabilities: List<String>
)

@Serializable
private data class TouchEventData(
    val x: Float,
    val y: Float,
    val action: Int
)

@Serializable
private data class ErrorData(
    val message: String,
    val code: Int
)

enum class NetworkState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    DISCONNECTING,
    ERROR
}

sealed class NetworkMessage {
    object Ping : NetworkMessage()
    object Pong : NetworkMessage()
    data class DeviceInfo(val deviceId: String, val capabilities: List<String>) : NetworkMessage()
    data class ScreenFrame(val data: ByteArray, val timestamp: Long) : NetworkMessage() {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is ScreenFrame) return false
            return data.contentEquals(other.data) && timestamp == other.timestamp
        }
        override fun hashCode(): Int {
            var result = data.contentHashCode()
            result = 31 * result + timestamp.hashCode()
            return result
        }
    }
    data class TouchEvent(val x: Float, val y: Float, val action: Int) : NetworkMessage()
    data class Error(val message: String, val code: Int) : NetworkMessage()
}