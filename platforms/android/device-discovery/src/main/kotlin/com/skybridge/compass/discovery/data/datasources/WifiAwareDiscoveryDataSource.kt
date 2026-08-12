package com.skybridge.compass.discovery.data.datasources

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySession
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.WifiAwareManager
import androidx.core.app.ActivityCompat
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import com.skybridge.compass.discovery.data.aware.WifiAwarePeerRegistry
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Wi‑Fi Aware (NAN) 设备发现数据源（骨架）
 *
 * 使用 Android `WifiAwareManager` 进行订阅发现，解析 SSI 为设备元数据。
 */
@Singleton
class WifiAwareDiscoveryDataSource @Inject constructor(@param:dagger.hilt.android.qualifiers.ApplicationContext private val context: Context,
    private val peerRegistry: WifiAwarePeerRegistry
){

    private val wifiAwareManager: WifiAwareManager? =
        context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager

    private val json = Json { ignoreUnknownKeys = true }
    private val serviceName: String = "skybridge" // 与跨平台约定一致的小写服务名

    /**
     * 开始 Wi‑Fi Aware 订阅发现
     */
    @android.annotation.SuppressLint("MissingPermission")
    fun startDiscovery(): Flow<List<DiscoveredDevice>> = callbackFlow {
        val manager = wifiAwareManager
        if (manager == null || !manager.isAvailable) {
            trySend(emptyList())
            close()
            return@callbackFlow
        }

        if (!hasLocationPermission() || !hasNearbyWifiPermission()) {
            trySend(emptyList())
            close()
            return@callbackFlow
        }

        val discovered = mutableMapOf<String, DiscoveredDevice>()
        var discoverySession: DiscoverySession? = null

        val attachCallback = object : AttachCallback() {
            override fun onAttached(session: android.net.wifi.aware.WifiAwareSession?) {
                val subscribeConfig = SubscribeConfig.Builder()
                    .setServiceName(serviceName)
                    // 可选：设置 matchFilter/ttl/subscribeType 等参数
                    .build()

                session?.subscribe(subscribeConfig, object : DiscoverySessionCallback() {
                    override fun onSubscribeStarted(session: android.net.wifi.aware.SubscribeDiscoverySession) {
                        discoverySession = session
                    }

                    override fun onServiceDiscovered(
                        peerHandle: PeerHandle?,
                        serviceSpecificInfo: ByteArray?,
                        matchFilter: MutableList<ByteArray>?
                    ) {
                        val ssi = serviceSpecificInfo?.decodeToString() ?: ""
                        val device = createDeviceFromAware(ssi)
                        discovered[device.id] = device
                        if (peerHandle != null && discoverySession != null) {
                            runCatching { peerRegistry.put(device.id, peerHandle, discoverySession!!) }
                        }
                        trySend(discovered.values.toList())
                    }

                    override fun onSessionTerminated() {
                        discoverySession = null
                        peerRegistry.clear()
                    }
                }, null)
            }

            override fun onAttachFailed() {
                trySend(emptyList())
            }
        }

        // 开始附着到 Aware 服务（捕获可能的权限与其他异常）
        try {
            manager.attach(attachCallback, null)
        } catch (_: SecurityException) {
            // 权限不足时优雅降级为无设备，避免向上抛异常导致崩溃
            trySend(emptyList())
            close()
            return@callbackFlow
        } catch (_: Exception) {
            trySend(emptyList())
            close()
            return@callbackFlow
        }

        awaitClose {
            try {
                discoverySession?.close()
            } catch (_: Exception) {}
        }
    }

    private fun hasLocationPermission(): Boolean {
        return ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasNearbyWifiPermission(): Boolean {
        return ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.NEARBY_WIFI_DEVICES
        ) == PackageManager.PERMISSION_GRANTED
    }

    @Serializable
    private data class AwareSsi(
        val id: String? = null,
        val name: String? = null,
        val type: String? = null,
        val port: Int? = null,
        val capabilities: List<String>? = null
    )

    private fun createDeviceFromAware(ssi: String): DiscoveredDevice {
        val meta = runCatching { json.decodeFromString(AwareSsi.serializer(), ssi) }.getOrNull()
        val id = meta?.id ?: (meta?.name ?: "aware-${System.currentTimeMillis()}")
        val name = meta?.name ?: "Aware Device"
        val type = when (meta?.type?.lowercase()) {
            "ios" -> DeviceType.IOS
            "macos" -> DeviceType.MACOS
            "android" -> DeviceType.ANDROID
            "windows" -> DeviceType.WINDOWS
            "linux" -> DeviceType.LINUX
            else -> DeviceType.UNKNOWN
        }
        val caps = (meta?.capabilities ?: listOf("file_transfer", "screen_sharing")).mapNotNull {
            when (it.lowercase()) {
                "screen_sharing" -> DeviceCapability.SCREEN_SHARING
                "file_transfer" -> DeviceCapability.FILE_TRANSFER
                "remote_control" -> DeviceCapability.REMOTE_CONTROL
                "audio_streaming" -> DeviceCapability.AUDIO_STREAMING
                "video_streaming" -> DeviceCapability.VIDEO_STREAMING
                "clipboard_sync" -> DeviceCapability.CLIPBOARD_SYNC
                "notification_sync" -> DeviceCapability.NOTIFICATION_SYNC
                "camera_access" -> DeviceCapability.CAMERA_ACCESS
                "microphone_access" -> DeviceCapability.MICROPHONE_ACCESS
                else -> null
            }
        }.toSet()

        return DiscoveredDevice(
            id = id,
            name = name,
            type = type,
            capabilities = caps,
            connectionInfo = ConnectionInfo(
                protocol = DiscoveryProtocol.WIFI_AWARE,
                address = "", // Wi‑Fi Aware 初始不提供 IP
                port = meta?.port ?: 0,
                serviceType = serviceName,
                txtRecords = emptyMap()
            ),
            signalStrength = 70,
            lastSeen = System.currentTimeMillis()
        )
    }
}
