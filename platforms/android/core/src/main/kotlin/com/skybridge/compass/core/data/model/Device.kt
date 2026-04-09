package com.skybridge.compass.core.data.model

import android.os.Parcelable
import androidx.room.Entity
import androidx.room.PrimaryKey
import kotlinx.parcelize.Parcelize
import kotlinx.serialization.Serializable

/**
 * 设备数据模型
 * 用于表示网络中发现的设备信息
 */
@Entity(tableName = "devices")
@Parcelize
@Serializable
data class Device(
    @PrimaryKey
    val id: String,
    val name: String,
    val type: DeviceType,
    val ipAddress: String,
    val port: Int,
    val macAddress: String? = null,
    val isOnline: Boolean = false,
    val lastSeen: Long = System.currentTimeMillis(),
    val capabilities: List<DeviceCapability> = emptyList(),
    val osInfo: OSInfo? = null,
    val batteryLevel: Int? = null,
    val isConnected: Boolean = false,
    val connectionQuality: ConnectionQuality = ConnectionQuality.default()
) : Parcelable

/**
 * 设备类型枚举
 */
@Serializable
enum class DeviceType {
    ANDROID,
    IOS,
    WINDOWS,
    MACOS,
    LINUX,
    UNKNOWN
}

/**
 * 设备能力枚举
 */
@Serializable
enum class DeviceCapability {
    SCREEN_MIRRORING,
    REMOTE_CONTROL,
    FILE_TRANSFER,
    AUDIO_STREAMING,
    CLIPBOARD_SYNC,
    NOTIFICATION_SYNC
}



/**
 * 操作系统信息
 */
@Parcelize
@Serializable
data class OSInfo(
    val name: String,
    val version: String,
    val architecture: String
) : Parcelable