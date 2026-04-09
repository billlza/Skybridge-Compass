package com.skybridge.compass.shared.notifications

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/**
 * 通知严重级别
 */
enum class NotificationSeverity { INFO, SUCCESS, WARNING, ERROR }

/** 模块来源 */
enum class NotificationModule {
    AUTH, DEVICE_DISCOVERY, SCREEN_MIRRORING, REMOTE_CONTROL, FILE_TRANSFER, PERFORMANCE, SYSTEM
}

/**
 * 通知事件模型
 */
data class NotificationEvent(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val message: String,
    val module: NotificationModule,
    val severity: NotificationSeverity = NotificationSeverity.INFO,
    val timestamp: Long = System.currentTimeMillis(),
    val unread: Boolean = true
)

/**
 * 应用内通知中心
 * - 供模块发布事件
 * - 提供历史和未读统计给UI
 * - 可桥接系统通知发布器
 */
object NotificationCenter {
    private val _events = MutableSharedFlow<NotificationEvent>(replay = 32, extraBufferCapacity = 64)
    val events: SharedFlow<NotificationEvent> = _events.asSharedFlow()

    private val _history = MutableStateFlow<List<NotificationEvent>>(emptyList())
    val history: StateFlow<List<NotificationEvent>> = _history.asStateFlow()

    private val _unreadCount = MutableStateFlow(0)
    val unreadCount: StateFlow<Int> = _unreadCount.asStateFlow()

    private const val MAX_HISTORY = 200
    private const val DEFAULT_MIN_INTERVAL_MS = 60_000L // 默认60秒限频以避免刷屏

    // 去重与限频缓存：key=module:title:message -> last timestamp
    private val lastPostMap = mutableMapOf<String, Long>()

    /** 系统通知桥接器（可选） */
    var systemNotifier: ((NotificationEvent) -> Unit)? = null

    /** 发布事件（带默认限频） */
    fun post(event: NotificationEvent) {
        post(event, DEFAULT_MIN_INTERVAL_MS)
    }

    /** 发布事件（可自定义最小间隔） */
    fun post(event: NotificationEvent, minIntervalMs: Long) {
        val key = "${event.module}:${event.title}:${event.message}"
        val now = System.currentTimeMillis()
        val last = lastPostMap[key] ?: 0L
        if (now - last < minIntervalMs) {
            return // 限频：忽略短时间内的重复事件
        }
        lastPostMap[key] = now
        // 更新历史
        val updated = (_history.value + event).takeLast(MAX_HISTORY)
        _history.value = updated
        _unreadCount.value = updated.count { it.unread }
        // 推送流
        _events.tryEmit(event)
        // 桥接系统通知
        try { systemNotifier?.invoke(event) } catch (_: Throwable) {}
    }

    /** 标记单条为已读 */
    fun markRead(id: String) {
        val newHistory = _history.value.map { if (it.id == id) it.copy(unread = false) else it }
        _history.value = newHistory
        _unreadCount.value = newHistory.count { it.unread }
    }

    /** 全部已读 */
    fun markAllRead() {
        val newHistory = _history.value.map { it.copy(unread = false) }
        _history.value = newHistory
        _unreadCount.value = 0
    }

    /** 删除单条通知 */
    fun remove(id: String) {
        val newHistory = _history.value.filterNot { it.id == id }
        _history.value = newHistory
        _unreadCount.value = newHistory.count { it.unread }
    }

    /** 清空所有通知 */
    fun clear() {
        _history.value = emptyList()
        _unreadCount.value = 0
        lastPostMap.clear()
    }
}