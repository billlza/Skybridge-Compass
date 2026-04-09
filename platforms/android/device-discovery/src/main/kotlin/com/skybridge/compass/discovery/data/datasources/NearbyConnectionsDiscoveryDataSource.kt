package com.skybridge.compass.discovery.data.datasources

import android.content.Context
import android.os.Build
import android.Manifest
import androidx.core.app.ActivityCompat
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Strategy
import com.skybridge.compass.discovery.data.telemetry.DiscoveryTelemetry
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo as DeviceConnectionInfo
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Nearby Connections 设备发现数据源（骨架）
 *
 * 通过 Google Play services Nearby API 进行端点发现。
 */
@Singleton
class NearbyConnectionsDiscoveryDataSource @Inject constructor(
    @param:dagger.hilt.android.qualifiers.ApplicationContext private val context: Context,
    private val telemetry: DiscoveryTelemetry
) {

    private val serviceId: String = "com.skybridge.compass.SKYBRIDGE"
    private val strategy: Strategy = Strategy.P2P_POINT_TO_POINT

    private fun client(): ConnectionsClient = Nearby.getConnectionsClient(context)

    fun startDiscovery(): Flow<List<DiscoveredDevice>> = callbackFlow {
        telemetry.recordDiscoveryStart(DiscoveryProtocol.NEARBY_CONNECTIONS)
        val discovered = mutableMapOf<String, DiscoveredDevice>()

        // 运行时权限检查：Android 12+ 需要 BLUETOOTH_SCAN；更早版本通常需要定位权限以启用 BLE/Wi‑Fi 扫描
        val hasRequired = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_SCAN
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        if (!hasRequired) {
            telemetry.recordPermissionMissing(DiscoveryProtocol.NEARBY_CONNECTIONS, if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) "BLUETOOTH_SCAN" else "ACCESS_FINE_LOCATION")
            trySend(emptyList())
            close()
            return@callbackFlow
        }

        val endpointCallback = object : EndpointDiscoveryCallback() {
            override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
                val device = DiscoveredDevice(
                    id = endpointId,
                    name = info.endpointName,
                    type = inferDeviceType(info.serviceId, info.endpointName),
                    capabilities = defaultCapabilities(),
                    connectionInfo = DeviceConnectionInfo(
                        protocol = DiscoveryProtocol.NEARBY_CONNECTIONS,
                        address = endpointId, // 非网络地址，仅为 Nearby 端点标识
                        port = 0,
                        serviceType = info.serviceId
                    ),
                    signalStrength = 80,
                    lastSeen = System.currentTimeMillis()
                )
                discovered[endpointId] = device
                telemetry.recordDeviceDiscovered(DiscoveryProtocol.NEARBY_CONNECTIONS, endpointId)
                trySend(discovered.values.toList())
            }

            override fun onEndpointLost(endpointId: String) {
                discovered.remove(endpointId)
                trySend(discovered.values.toList())
            }
        }

        val options = DiscoveryOptions.Builder().setStrategy(strategy).build()

        try {
            client().startDiscovery(serviceId, endpointCallback, options)
                .addOnSuccessListener { /* 发现已启动 */ }
                .addOnFailureListener { e ->
                    telemetry.recordError(DiscoveryProtocol.NEARBY_CONNECTIONS, "DISCOVERY_FAILED", e.message)
                    trySend(emptyList())
                }
        } catch (_: SecurityException) {
            telemetry.recordPermissionMissing(DiscoveryProtocol.NEARBY_CONNECTIONS, "BLUETOOTH_SCAN")
            trySend(emptyList())
            close()
            return@callbackFlow
        } catch (_: Exception) {
            trySend(emptyList())
            close()
            return@callbackFlow
        }

        awaitClose {
            try { client().stopDiscovery() } catch (_: Exception) {}
        }
    }

    private fun inferDeviceType(serviceId: String, name: String): DeviceType {
        return when {
            name.contains("iPhone", true) || name.contains("iPad", true) -> DeviceType.IOS
            name.contains("Mac", true) -> DeviceType.MACOS
            name.contains("Android", true) -> DeviceType.ANDROID
            else -> DeviceType.UNKNOWN
        }
    }

    private fun defaultCapabilities(): Set<DeviceCapability> = setOf(
        DeviceCapability.FILE_TRANSFER,
        DeviceCapability.SCREEN_SHARING
    )

    // 预留连接生命周期回调（不在骨架中使用）
    @Suppress("unused")
    private val connectionLifecycle = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, connectionInfo: ConnectionInfo) {}
        override fun onConnectionResult(endpointId: String, result: com.google.android.gms.nearby.connection.ConnectionResolution) {}
        override fun onDisconnected(endpointId: String) {}
    }
}