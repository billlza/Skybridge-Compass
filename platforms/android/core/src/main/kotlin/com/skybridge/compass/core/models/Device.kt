package com.skybridge.compass.core.models

import android.os.Parcelable
import kotlinx.parcelize.Parcelize
import kotlinx.serialization.Serializable

@Parcelize
@Serializable
data class Device(
    val id: String,
    val name: String,
    val type: DeviceType,
    val ipAddress: String,
    val port: Int,
    val status: DeviceStatus,
    val capabilities: List<DeviceCapability>,
    val lastSeen: Long = System.currentTimeMillis(),
    val metadata: Map<String, String> = emptyMap()
) : Parcelable

@Serializable
enum class DeviceType {
    ANDROID,
    IOS,
    WINDOWS,
    MACOS,
    LINUX,
    WEB,
    UNKNOWN
}

@Serializable
enum class DeviceStatus {
    ONLINE,
    OFFLINE,
    CONNECTING,
    CONNECTED,
    DISCONNECTED,
    ERROR
}

@Serializable
enum class DeviceCapability {
    SCREEN_MIRRORING,
    REMOTE_CONTROL,
    FILE_TRANSFER,
    AUDIO_STREAMING,
    VIDEO_STREAMING,
    CLIPBOARD_SYNC,
    NOTIFICATION_SYNC,
    CAMERA_ACCESS,
    MICROPHONE_ACCESS
}

@Parcelize
@Serializable
data class DeviceConnection(
    val device: Device,
    val connectionId: String,
    val establishedAt: Long,
    val isSecure: Boolean,
    val quality: ConnectionQuality,
    val latency: Long = 0L,
    val bandwidth: Long = 0L
) : Parcelable

@Serializable
enum class ConnectionQuality {
    EXCELLENT,
    GOOD,
    FAIR,
    POOR,
    UNKNOWN
}