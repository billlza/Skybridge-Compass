package com.yunqiao.sinan.manager

import com.yunqiao.sinan.config.NotificationConfiguration
import com.yunqiao.sinan.data.ConnectionStatus
import com.yunqiao.sinan.data.DeviceStatus
import com.yunqiao.sinan.data.notification.NotificationType
import com.yunqiao.sinan.data.notification.SystemNotification
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlin.math.max

class NotificationCenter(private val configuration: NotificationConfiguration = NotificationConfiguration()) {
    private val _notifications = MutableStateFlow<List<SystemNotification>>(emptyList())
    val notifications: StateFlow<List<SystemNotification>> = _notifications
    private var lastConnectionStatus: ConnectionStatus? = null
    private var lastThroughputTimestamp = 0L
    private val maxHistory = max(configuration.maxHistory, 1)

    fun onDeviceStatusChanged(status: DeviceStatus) {
        if (lastConnectionStatus != status.connectionStatus) {
            val message = when (status.connectionStatus) {
                ConnectionStatus.ONLINE -> "设备已经成功建立桥接"
                ConnectionStatus.CONNECTING -> "设备正在建立连接"
                ConnectionStatus.OFFLINE -> "设备连接已断开"
            }
            val title = when (status.connectionStatus) {
                ConnectionStatus.ONLINE -> "连接成功"
                ConnectionStatus.CONNECTING -> "连接中"
                ConnectionStatus.OFFLINE -> "连接中断"
            }
            val notification = SystemNotification(
                id = UUID.randomUUID().toString(),
                title = title,
                message = message,
                timestamp = System.currentTimeMillis(),
                type = NotificationType.Connection,
                isRead = status.connectionStatus == ConnectionStatus.CONNECTING
            )
            _notifications.value = (listOf(notification) + _notifications.value).take(maxHistory)
            lastConnectionStatus = status.connectionStatus
            if (status.connectionStatus != ConnectionStatus.ONLINE) {
                lastThroughputTimestamp = 0L
            }
        } else {
            val now = System.currentTimeMillis()
            if (status.connectionStatus == ConnectionStatus.ONLINE && now - lastThroughputTimestamp >= configuration.throughputIntervalMillis) {
                val throughputNotification = SystemNotification(
                    id = UUID.randomUUID().toString(),
                    title = "实时网络状态",
                    message = "上传速率 ${status.uploadRateKbps.toInt()} Kbps / 下载速率 ${status.downloadRateKbps.toInt()} Kbps",
                    timestamp = now,
                    type = NotificationType.Status,
                    isRead = false
                )
                _notifications.value = (listOf(throughputNotification) + _notifications.value).take(maxHistory)
                lastThroughputTimestamp = now
            }
        }
    }

    fun publish(title: String, message: String, type: NotificationType) {
        val notification = SystemNotification(
            id = UUID.randomUUID().toString(),
            title = title,
            message = message,
            timestamp = System.currentTimeMillis(),
            type = type,
            isRead = false
        )
        _notifications.value = (listOf(notification) + _notifications.value).take(maxHistory)
    }

    fun markAllRead() {
        _notifications.value = _notifications.value.map { it.copy(isRead = true) }
    }

    fun markAsRead(id: String) {
        _notifications.value = _notifications.value.map { if (it.id == id) it.copy(isRead = true) else it }
    }
}
