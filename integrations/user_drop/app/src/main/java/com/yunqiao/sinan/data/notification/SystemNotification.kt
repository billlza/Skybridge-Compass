package com.yunqiao.sinan.data.notification

data class SystemNotification(
    val id: String,
    val title: String,
    val message: String,
    val timestamp: Long,
    val type: NotificationType,
    val isRead: Boolean
)

enum class NotificationType {
    Connection,
    Status,
    Security,
    Permission
}
