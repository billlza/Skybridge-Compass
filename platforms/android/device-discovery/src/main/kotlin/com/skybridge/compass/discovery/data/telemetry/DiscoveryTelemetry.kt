package com.skybridge.compass.discovery.data.telemetry

import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 设备发现 Telemetry 收集器
 * - 统计各协议的启动/发现次数
 * - 采集错误事件与权限缺失
 * - 记录组播锁持有时长（UDP Broadcast）
 */
@Singleton
class DiscoveryTelemetry @Inject constructor() {

    data class Counters(
        val starts: Map<DiscoveryProtocol, Int>,
        val discovered: Map<DiscoveryProtocol, Int>
    )

    sealed class TelemetryEvent {
        data class DiscoveryStarted(val protocol: DiscoveryProtocol) : TelemetryEvent()
        data class DeviceDiscovered(val protocol: DiscoveryProtocol, val deviceId: String) : TelemetryEvent()
        data class Error(val protocol: DiscoveryProtocol, val code: String, val message: String?) : TelemetryEvent()
        data class PermissionMissing(val protocol: DiscoveryProtocol, val permission: String) : TelemetryEvent()
        data class MulticastLock(val event: String, val durationMs: Long?) : TelemetryEvent() // event: acquired/released/held
    }

    private val _counters = MutableStateFlow(Counters(emptyMap(), emptyMap()))
    val counters: StateFlow<Counters> = _counters

    private val _events = MutableSharedFlow<TelemetryEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<TelemetryEvent> = _events

    fun recordDiscoveryStart(protocol: DiscoveryProtocol) {
        _events.tryEmit(TelemetryEvent.DiscoveryStarted(protocol))
        val current = _counters.value
        val updatedStarts = current.starts.toMutableMap()
        updatedStarts[protocol] = (updatedStarts[protocol] ?: 0) + 1
        _counters.value = current.copy(starts = updatedStarts)
    }

    fun recordDeviceDiscovered(protocol: DiscoveryProtocol, deviceId: String) {
        _events.tryEmit(TelemetryEvent.DeviceDiscovered(protocol, deviceId))
        val current = _counters.value
        val updatedDiscovered = current.discovered.toMutableMap()
        updatedDiscovered[protocol] = (updatedDiscovered[protocol] ?: 0) + 1
        _counters.value = current.copy(discovered = updatedDiscovered)
    }

    fun recordError(protocol: DiscoveryProtocol, code: String, message: String?) {
        _events.tryEmit(TelemetryEvent.Error(protocol, code, message))
    }

    fun recordPermissionMissing(protocol: DiscoveryProtocol, permission: String) {
        _events.tryEmit(TelemetryEvent.PermissionMissing(protocol, permission))
    }

    fun recordMulticastLockAcquired() {
        _events.tryEmit(TelemetryEvent.MulticastLock(event = "acquired", durationMs = null))
    }

    fun recordMulticastLockReleased() {
        _events.tryEmit(TelemetryEvent.MulticastLock(event = "released", durationMs = null))
    }

    fun recordMulticastLockHeld(durationMs: Long) {
        _events.tryEmit(TelemetryEvent.MulticastLock(event = "held", durationMs = durationMs))
    }
}