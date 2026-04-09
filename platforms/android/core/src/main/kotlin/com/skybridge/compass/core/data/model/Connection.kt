package com.skybridge.compass.core.data.model

import android.os.Parcelable
import androidx.room.Entity
import androidx.room.PrimaryKey
import kotlinx.parcelize.Parcelize
import kotlinx.serialization.Serializable

/**
 * 连接状态数据模型
 */
@Entity(tableName = "connections")
@Parcelize
@Serializable
data class Connection(
    @PrimaryKey
    val id: String,
    val deviceId: String,
    val status: ConnectionStatus,
    val protocol: ConnectionProtocol,
    val establishedAt: Long = System.currentTimeMillis(),
    val lastActivity: Long = System.currentTimeMillis(),
    val latency: Long = 0L,
    val bandwidth: Long = 0L,
    val errorCount: Int = 0,
    val metadata: Map<String, String> = emptyMap()
) : Parcelable

/**
 * 连接状态枚举
 */
@Serializable
enum class ConnectionStatus {
    CONNECTING,
    CONNECTED,
    DISCONNECTING,
    DISCONNECTED,
    ERROR,
    TIMEOUT
}

/**
 * 连接协议枚举
 */
@Serializable
enum class ConnectionProtocol {
    TCP,
    UDP,
    WEBSOCKET,
    HTTP,
    HTTPS
}

/**
 * 网络消息数据模型
 */
@Parcelize
@Serializable
data class NetworkMessage(
    val id: String,
    val type: MessageType,
    val sourceDeviceId: String,
    val targetDeviceId: String,
    val payload: String,
    val timestamp: Long = System.currentTimeMillis(),
    val priority: MessagePriority = MessagePriority.NORMAL
) : Parcelable

/**
 * 消息类型枚举
 */
@Serializable
enum class MessageType {
    DEVICE_DISCOVERY,
    DEVICE_INFO,
    SCREEN_DATA,
    CONTROL_INPUT,
    FILE_TRANSFER,
    STREAM_CONTROL,
    HEARTBEAT,
    ERROR,
    ACK
}

/**
 * 消息优先级枚举
 */
@Serializable
enum class MessagePriority {
    LOW,
    NORMAL,
    HIGH,
    CRITICAL
}