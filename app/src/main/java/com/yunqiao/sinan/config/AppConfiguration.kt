package com.yunqiao.sinan.config

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class AppConfiguration(
    @SerialName("remote_desktop") val remoteDesktop: RemoteDesktopConfiguration = RemoteDesktopConfiguration(),
    @SerialName("file_transfer") val fileTransfer: FileTransferConfiguration = FileTransferConfiguration(),
    @SerialName("notification") val notification: NotificationConfiguration = NotificationConfiguration(),
    @SerialName("discovery") val discovery: DiscoveryConfiguration = DiscoveryConfiguration()
)

@Serializable
data class RemoteDesktopConfiguration(
    @SerialName("max_sessions") val maxSessions: Int = 4,
    @SerialName("quality_profile") val qualityProfile: String = "adaptive",
    @SerialName("hardware_acceleration") val hardwareAcceleration: Boolean = true
)

@Serializable
data class FileTransferConfiguration(
    @SerialName("parallel_uploads") val parallelUploads: Int = 2,
    @SerialName("chunk_bytes") val chunkBytes: Long = 2L * 1024L * 1024L,
    @SerialName("media_types") val mediaTypes: Set<String> = setOf("image", "video", "audio", "document")
)

@Serializable
data class NotificationConfiguration(
    @SerialName("max_history") val maxHistory: Int = 10,
    @SerialName("throughput_interval_ms") val throughputIntervalMillis: Long = 5000
)

@Serializable
data class DiscoveryConfiguration(
    @SerialName("ble_scan_duration_ms") val bleScanDurationMillis: Long = 15000,
    @SerialName("wifi_scan_interval_ms") val wifiScanIntervalMillis: Long = 20000
)
