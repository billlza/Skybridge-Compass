package com.skybridge.compass.discovery.data.datasources

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pManager
import androidx.core.app.ActivityCompat
import com.skybridge.compass.discovery.data.telemetry.DiscoveryTelemetry
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * WiFi Direct 设备发现数据源
 * 
 * 使用Android WiFi P2P API实现WiFi Direct设备发现
 */
@Singleton
class WiFiDirectDiscoveryDataSource @Inject constructor(
    @param:dagger.hilt.android.qualifiers.ApplicationContext private val context: Context,
    private val telemetry: DiscoveryTelemetry
) {
    
    private val wifiP2pManager = context.getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
    private var wifiChannel: WifiP2pManager.Channel? = null
    
    /**
     * 开始WiFi Direct设备发现
     */
    fun startDiscovery(): Flow<List<DiscoveredDevice>> = callbackFlow {
        telemetry.recordDiscoveryStart(DiscoveryProtocol.WIFI_DIRECT)
        if (!hasRequiredPermissions()) {
            if (ActivityCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                telemetry.recordPermissionMissing(DiscoveryProtocol.WIFI_DIRECT, Manifest.permission.ACCESS_FINE_LOCATION)
            }
            if (ActivityCompat.checkSelfPermission(context, Manifest.permission.ACCESS_WIFI_STATE) != PackageManager.PERMISSION_GRANTED) {
                telemetry.recordPermissionMissing(DiscoveryProtocol.WIFI_DIRECT, Manifest.permission.ACCESS_WIFI_STATE)
            }
            if (ActivityCompat.checkSelfPermission(context, Manifest.permission.CHANGE_WIFI_STATE) != PackageManager.PERMISSION_GRANTED) {
                telemetry.recordPermissionMissing(DiscoveryProtocol.WIFI_DIRECT, Manifest.permission.CHANGE_WIFI_STATE)
            }
            trySend(emptyList())
            close()
            return@callbackFlow
        }
        
        wifiChannel = wifiP2pManager.initialize(context, context.mainLooper, null)
        val discoveredDevices = mutableMapOf<String, DiscoveredDevice>()
        
        val peerListListener = WifiP2pManager.PeerListListener { peerList ->
            val devices = peerList.deviceList.map { device ->
                createDeviceFromWifiP2pDevice(device)
            }
            
            discoveredDevices.clear()
            devices.forEach { device ->
                discoveredDevices[device.id] = device
                telemetry.recordDeviceDiscovered(DiscoveryProtocol.WIFI_DIRECT, device.id)
            }
            
            trySend(discoveredDevices.values.toList())
        }
        
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                        if (ActivityCompat.checkSelfPermission(
                                context!!,
                                Manifest.permission.ACCESS_FINE_LOCATION
                            ) == PackageManager.PERMISSION_GRANTED
                        ) {
                            val currentChannel = wifiChannel
                            if (currentChannel != null) {
                                wifiP2pManager.requestPeers(currentChannel, peerListListener)
                            }
                        }
                    }
                    WifiP2pManager.WIFI_P2P_DISCOVERY_CHANGED_ACTION -> {
                        val state = intent.getIntExtra(WifiP2pManager.EXTRA_DISCOVERY_STATE, -1)
                        if (state == WifiP2pManager.WIFI_P2P_DISCOVERY_STARTED) {
                            // 发现已开始
                        } else if (state == WifiP2pManager.WIFI_P2P_DISCOVERY_STOPPED) {
                            // 发现已停止
                        }
                    }
                }
            }
        }
        
        val intentFilter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_DISCOVERY_CHANGED_ACTION)
        }
        
        context.registerReceiver(receiver, intentFilter)
        
        // 开始发现
        if (ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            val currentChannel = wifiChannel
            if (currentChannel != null) {
                wifiP2pManager.discoverPeers(currentChannel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    // 发现启动成功
                }
                
                override fun onFailure(reason: Int) {
                    // 发现启动失败
                    telemetry.recordError(DiscoveryProtocol.WIFI_DIRECT, "DISCOVERY_FAILED", reason.toString())
                    trySend(emptyList())
                }
            })
            }
        }
        
        awaitClose {
            context.unregisterReceiver(receiver)
            if (ActivityCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_FINE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                val currentChannel = wifiChannel
                if (currentChannel != null) {
                    wifiP2pManager.stopPeerDiscovery(currentChannel, null)
                }
            }
        }
    }
    
    /**
     * 从WiFi P2P设备创建设备对象
     */
    private fun createDeviceFromWifiP2pDevice(wifiP2pDevice: WifiP2pDevice): DiscoveredDevice {
        return DiscoveredDevice(
            id = wifiP2pDevice.deviceAddress,
            name = wifiP2pDevice.deviceName,
            type = inferDeviceType(wifiP2pDevice.deviceName),
            capabilities = getDefaultCapabilities(),
            connectionInfo = ConnectionInfo(
                protocol = DiscoveryProtocol.WIFI_DIRECT,
                address = wifiP2pDevice.deviceAddress,
                port = 0, // WiFi Direct不使用固定端口
                txtRecords = mapOf(
                    "status" to wifiP2pDevice.status.toString(),
                    "primaryDeviceType" to wifiP2pDevice.primaryDeviceType
                )
            ),
            signalStrength = calculateSignalStrength(wifiP2pDevice.status),
            lastSeen = System.currentTimeMillis()
        )
    }
    
    /**
     * 推断设备类型
     */
    private fun inferDeviceType(deviceName: String): DeviceType {
        return when {
            deviceName.contains("iPhone", ignoreCase = true) ||
            deviceName.contains("iPad", ignoreCase = true) -> DeviceType.IOS
            deviceName.contains("Mac", ignoreCase = true) -> DeviceType.MACOS
            deviceName.contains("Android", ignoreCase = true) -> DeviceType.ANDROID
            deviceName.contains("Windows", ignoreCase = true) -> DeviceType.WINDOWS
            deviceName.contains("Linux", ignoreCase = true) -> DeviceType.LINUX
            else -> DeviceType.UNKNOWN
        }
    }
    
    /**
     * 获取默认设备能力
     */
    private fun getDefaultCapabilities(): Set<DeviceCapability> {
        return setOf(
            DeviceCapability.FILE_TRANSFER,
            DeviceCapability.SCREEN_SHARING
        )
    }
    
    /**
     * 计算信号强度
     */
    private fun calculateSignalStrength(status: Int): Int {
        return when (status) {
            WifiP2pDevice.CONNECTED -> 100
            WifiP2pDevice.INVITED -> 80
            WifiP2pDevice.AVAILABLE -> 60
            WifiP2pDevice.UNAVAILABLE -> 20
            WifiP2pDevice.FAILED -> 0
            else -> 50
        }
    }
    
    /**
     * 检查是否有必要的权限
     */
    private fun hasRequiredPermissions(): Boolean {
        return ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED &&
        ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_WIFI_STATE
        ) == PackageManager.PERMISSION_GRANTED &&
        ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.CHANGE_WIFI_STATE
        ) == PackageManager.PERMISSION_GRANTED
    }
}