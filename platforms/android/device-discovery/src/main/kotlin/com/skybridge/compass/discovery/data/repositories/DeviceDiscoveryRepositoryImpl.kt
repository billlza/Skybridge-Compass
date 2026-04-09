package com.skybridge.compass.discovery.data.repositories
import kotlinx.coroutines.CompletableDeferred
import com.skybridge.compass.discovery.data.aware.WifiAwarePeerRegistry
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionsClient
import android.net.NetworkRequest
import android.net.NetworkCapabilities
import android.net.Network
import android.net.ConnectivityManager
import android.content.Context

import com.skybridge.compass.discovery.data.services.UnifiedDeviceDiscoveryService
import com.skybridge.compass.discovery.data.nearby.NearbyConnectionsManager
import com.skybridge.compass.discovery.data.aware.WifiAwareDataPathManager
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.repositories.DeviceDiscoveryRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.flow.filter
import com.skybridge.compass.discovery.domain.entities.NearbyPayload
import com.skybridge.compass.discovery.domain.entities.NearbyTransferUpdate
import android.os.ParcelFileDescriptor
import java.io.InputStream
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import javax.inject.Inject
import javax.inject.Singleton
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.skybridge.compass.core.p2p.TcpControlClient
import com.skybridge.compass.core.p2p.TcpControlSession
import java.util.concurrent.ConcurrentHashMap

/**
 * 设备发现仓库实现
 * 
 * 连接数据层和领域层，管理设备发现状态和缓存
 */
@Singleton
class DeviceDiscoveryRepositoryImpl @Inject constructor(private val unifiedDiscoveryService: UnifiedDeviceDiscoveryService,
    private val nearbyClient: ConnectionsClient,
    private val appContext: Context,
    private val wifiAwarePeerRegistry: WifiAwarePeerRegistry,
    private val nearbyManager: NearbyConnectionsManager,
    private val awareDataPathManager: WifiAwareDataPathManager,
    private val tcpControlClient: TcpControlClient
) : DeviceDiscoveryRepository {
    
    private val _discoveredDevices = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
    private val _connectionStates = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    private val deviceIdToEndpointId: MutableMap<String, String> = mutableMapOf()
    private val endpointIdToDeviceId: MutableMap<String, String> = mutableMapOf()
    private val tcpSessionsByDeviceId: MutableMap<String, TcpControlSession> = ConcurrentHashMap()
    
    private var isDiscovering = false
    
    override suspend fun startDiscovery(protocols: Set<DiscoveryProtocol>): Flow<List<DiscoveredDevice>> {
        if (isDiscovering) {
            return _discoveredDevices.asStateFlow()
        }
        
        isDiscovering = true
        
        return unifiedDiscoveryService.startDiscovery(protocols)
            .distinctUntilChanged()
            .onEach { devices ->
                _discoveredDevices.value = devices
                updateConnectionStates(devices)
            }
            .onCompletion {
                isDiscovering = false
            }
    }
    
    override suspend fun stopDiscovery() {
        isDiscovering = false
        // 注意：实际实现中需要停止底层的发现服务
    }
    
    override suspend fun getDiscoveredDevices(): List<DiscoveredDevice> {
        return _discoveredDevices.value
    }
    
    override suspend fun connectToDevice(device: DiscoveredDevice): Boolean {
        return try {
            // 这里应该实现实际的连接逻辑
            // 根据设备的连接信息和协议建立连接
            val success = performConnection(device)
            
            if (success) {
                updateDeviceConnectionState(device.id, true)
                updateDeviceInList(device.copy(isConnected = true))
            }
            
            success
        } catch (e: Exception) {
            false
        }
    }
    
    override suspend fun disconnectFromDevice(deviceId: String) {
        try {
            // 实现断开连接逻辑
            performDisconnection(deviceId)
            updateDeviceConnectionState(deviceId, false)
            
            // 更新设备列表中的连接状态
            val updatedDevices = _discoveredDevices.value.map { device ->
                if (device.id == deviceId) {
                    device.copy(isConnected = false)
                } else {
                    device
                }
            }
            _discoveredDevices.value = updatedDevices
        } catch (e: Exception) {
            // 处理断开连接错误
        }
    }
    
    override fun getDeviceConnectionStatus(deviceId: String): Flow<Boolean> {
        return _connectionStates.asStateFlow().map { states ->
            states[deviceId] ?: false
        }.distinctUntilChanged()
    }
    
    override suspend fun clearDeviceCache() {
        _discoveredDevices.value = emptyList()
        _connectionStates.value = emptyMap()
    }
    
    /**
     * 执行设备连接
     */
    private suspend fun performConnection(device: DiscoveredDevice): Boolean {
        return when (device.connectionInfo.protocol) {
            DiscoveryProtocol.BONJOUR -> {
                connectViaTcp(device.id, device.connectionInfo.address, device.connectionInfo.port)
            }
            DiscoveryProtocol.WIFI_DIRECT -> {
                connectViaWifiDirect(device)
            }
            DiscoveryProtocol.BLUETOOTH -> {
                connectViaBluetooth(device)
            }
            DiscoveryProtocol.NEARBY_CONNECTIONS -> {
                connectViaNearby(device)
            }
            DiscoveryProtocol.WIFI_AWARE -> {
                connectViaWifiAware(device)
            }
            else -> false
        }
    }
    
    /**
     * 通过TCP连接设备
     */
    private suspend fun connectViaTcp(deviceId: String, address: String, port: Int): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                // Real Pro-release compatible control channel (length framing + handshake + AES-GCM app frames).
                val session = tcpControlClient.connect(
                    host = address,
                    port = port,
                    peerDeviceIdHint = deviceId
                )
                tcpSessionsByDeviceId[deviceId] = session
                true
            } catch (_: Exception) {
                false
            }
        }
    }
    
    /**
     * 通过WiFi Direct连接设备
     */
    private suspend fun connectViaWifiDirect(device: DiscoveredDevice): Boolean {
        return try {
            // Wi‑Fi Direct requires WifiP2pManager orchestration and user consent flows.
            // Returning false is safer than reporting success without a real connection.
            false
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * 通过蓝牙连接设备
     */
    private suspend fun connectViaBluetooth(device: DiscoveredDevice): Boolean {
        return try {
            // Bluetooth connection requires pairing + BLUETOOTH_CONNECT permission and a concrete RFCOMM profile.
            false
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 通过 Nearby Connections 连接设备。
     * 连接建立仍依赖 Nearby 管理器与其生命周期回调，但这里不再伪造成功状态。
     */
    private suspend fun connectViaNearby(device: DiscoveredDevice): Boolean {
        return try {
            val endpointId = device.connectionInfo.address.ifEmpty { device.id }
            rememberNearbyMapping(device.id, endpointId)
            val ok = nearbyManager.requestConnection(device.name.ifEmpty { "SkyBridgeClient" }, endpointId)
            if (ok) {
                val hello = """{"op":"hello","id":"${device.id}","ver":1}"""
                nearbyManager.sendBytes(endpointId, hello.toByteArray())
            }
            ok
        } catch (e: Exception) {
            false
        }
    }
/**
     * 通过 Wi‑Fi Aware 连接设备。
     * 连接建立仍依赖 Aware 会话中的数据通道，但这里不再伪造成功状态。
     */
    private suspend fun connectViaWifiAware(device: DiscoveredDevice): Boolean {
        return try {
            awareDataPathManager.initiateDataPath(device.id)
        } catch (e: Exception) {
            false
        }
    }
/**
     * 执行设备断开连接
     */
    private suspend fun performDisconnection(deviceId: String) {
        // 实现断开连接逻辑
        // 根据设备ID找到对应的连接并关闭
        tcpSessionsByDeviceId.remove(deviceId)?.close()
        deviceIdToEndpointId[deviceId]?.let { endpointId ->
            try {
                nearbyManager.disconnect(endpointId)
            } catch (_: Exception) {}
            endpointIdToDeviceId.remove(endpointId)
        }
        deviceIdToEndpointId.remove(deviceId)
    }
    
    /**
     * 更新连接状态
     */
    private fun updateConnectionStates(devices: List<DiscoveredDevice>) {
        val states = devices.associate { device ->
            device.id to device.isConnected
        }
        _connectionStates.value = states
    }
    
    /**
     * 更新单个设备的连接状态
     */
    private fun updateDeviceConnectionState(deviceId: String, isConnected: Boolean) {
        val currentStates = _connectionStates.value.toMutableMap()
        currentStates[deviceId] = isConnected
        _connectionStates.value = currentStates
    }
    
    /**
     * 更新设备列表中的设备信息
     */
    private fun updateDeviceInList(updatedDevice: DiscoveredDevice) {
        val updatedDevices = _discoveredDevices.value.map { device ->
            if (device.id == updatedDevice.id) {
                updatedDevice
            } else {
                device
            }
        }
        _discoveredDevices.value = updatedDevices
    }

    /**
     * 观察 Nearby 端点的负载（BYTES/FILE/STREAM），并进行类型包装。
     */
    override fun observeNearbyPayloads(deviceId: String): Flow<NearbyPayload> {
        val endpointId = resolveEndpointId(deviceId)
        return nearbyManager
            .observePayloads(endpointId)
            .map { payload ->
                when (payload.type) {
                    Payload.Type.BYTES -> {
                        val bytes = payload.asBytes()
                        NearbyPayload.Bytes(bytes ?: ByteArray(0))
                    }
                    Payload.Type.FILE -> {
                        val file = payload.asFile()
                        val pfd: ParcelFileDescriptor? = file?.asParcelFileDescriptor()
                        NearbyPayload.FilePayload(payload.id, pfd)
                    }
                    Payload.Type.STREAM -> {
                        val stream = payload.asStream()
                        val input = stream?.asInputStream()
                        if (input != null) {
                            NearbyPayload.StreamPayload(payload.id, input)
                        } else {
                            NearbyPayload.Bytes(ByteArray(0))
                        }
                    }
                    else -> NearbyPayload.Bytes(ByteArray(0))
                }
            }
    }

    /**
     * 发送字节数据到 Nearby 端点。
     */
    override suspend fun sendNearbyBytes(deviceId: String, data: ByteArray): Boolean {
        val endpointId = resolveEndpointId(deviceId)
        return nearbyManager.sendBytes(endpointId, data)
    }

    /**
     * 发送文件到 Nearby 端点。
     */
    override suspend fun sendNearbyFile(deviceId: String, pfd: ParcelFileDescriptor): Long? {
        val endpointId = resolveEndpointId(deviceId)
        return nearbyManager.sendFile(endpointId, pfd)
    }

    /**
     * 发送流到 Nearby 端点。
     */
    override suspend fun sendNearbyStream(deviceId: String, input: InputStream): Long? {
        val endpointId = resolveEndpointId(deviceId)
        return nearbyManager.sendStream(endpointId, input)
    }

    /**
     * 观察传输进度并映射为领域模型。
     */
    override fun observeNearbyTransferUpdates(deviceId: String): Flow<NearbyTransferUpdate> {
        val endpointId = resolveEndpointId(deviceId)
        return nearbyManager.observeTransferUpdates(endpointId).map { update ->
            val status = when (update.status) {
                PayloadTransferUpdate.Status.IN_PROGRESS -> NearbyTransferUpdate.Status.IN_PROGRESS
                PayloadTransferUpdate.Status.SUCCESS -> NearbyTransferUpdate.Status.SUCCESS
                PayloadTransferUpdate.Status.FAILURE -> NearbyTransferUpdate.Status.FAILURE
                else -> NearbyTransferUpdate.Status.FAILURE
            }
            NearbyTransferUpdate(
                payloadId = update.payloadId,
                status = status,
                bytesTransferred = update.bytesTransferred,
                totalBytes = update.totalBytes
            )
        }
    }

    /**
     * 取消指定 payload 的传输。
     */
    override suspend fun cancelNearbyPayload(payloadId: Long): Boolean {
        return nearbyManager.cancelPayload(payloadId)
    }

    /**
     * 获取 Wi‑Fi Aware 的 Network（若已建立数据通道）。
     */
    override fun getWifiAwareNetwork(deviceId: String): Network? {
        return wifiAwarePeerRegistry.getNetwork(deviceId)
    }

    private fun rememberNearbyMapping(deviceId: String, endpointId: String) {
        deviceIdToEndpointId[deviceId] = endpointId
        endpointIdToDeviceId[endpointId] = deviceId
    }

    private fun resolveEndpointId(deviceId: String): String {
        return deviceIdToEndpointId[deviceId] ?: deviceId
    }
}
