package com.skybridge.compass.discovery.domain.entities

import kotlinx.serialization.Serializable

/**
 * 发现的设备实体
 * 
 * 表示通过各种发现协议找到的设备信息
 */
@Serializable
data class DiscoveredDevice(
    val id: String,
    val name: String,
    val type: DeviceType,
    val capabilities: Set<DeviceCapability>,
    val connectionInfo: ConnectionInfo,
    val signalStrength: Int,
    val lastSeen: Long,
    val isConnected: Boolean = false,
    val batteryLevel: Int? = null,
    val osVersion: String? = null
)

/**
 * 设备类型枚举
 */
@Serializable
enum class DeviceType {
    IOS,
    MACOS,
    ANDROID,
    WINDOWS,
    LINUX,
    UNKNOWN
}

/**
 * 设备能力枚举
 */
@Serializable
enum class DeviceCapability {
    SCREEN_SHARING,
    FILE_TRANSFER,
    REMOTE_CONTROL,
    AUDIO_STREAMING,
    VIDEO_STREAMING,
    CLIPBOARD_SYNC,
    NOTIFICATION_SYNC,
    CAMERA_ACCESS,
    MICROPHONE_ACCESS
}

/**
 * 连接信息
 */
@Serializable
data class ConnectionInfo(
    val protocol: DiscoveryProtocol,
    val address: String,
    val port: Int,
    val serviceType: String? = null,
    val txtRecords: Map<String, String> = emptyMap(),
    val preferredConnect: PreferredConnect? = null,
    val version: Int? = null,
    val extra: Map<String, String> = emptyMap()
)

/**
 * 发现协议枚举
 */
@Serializable
enum class DiscoveryProtocol {
    BONJOUR,
    WIFI_DIRECT,
    BLUETOOTH,
    UDP_BROADCAST,
    WIFI_AWARE,
    NEARBY_CONNECTIONS
}

/**
 * 首选连接层（用于统一握手策略）
 */
@Serializable
enum class PreferredConnect {
    WEBRTC,
    TCP,
    BLE,
    NAN
}