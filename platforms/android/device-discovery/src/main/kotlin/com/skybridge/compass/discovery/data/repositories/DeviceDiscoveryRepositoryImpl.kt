package com.skybridge.compass.discovery.data.repositories
import com.skybridge.compass.discovery.data.aware.WifiAwarePeerRegistry
import com.google.android.gms.nearby.connection.Payload
import android.net.Network

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
import com.skybridge.compass.discovery.domain.entities.NearbyPayload
import com.skybridge.compass.discovery.domain.entities.NearbyTransferUpdate
import android.os.ParcelFileDescriptor
import java.io.InputStream
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.skybridge.compass.core.data.RuntimeNetworkParametersSource
import com.skybridge.compass.core.network.DisconnectCause
import com.skybridge.compass.core.network.ReconnectAttemptResult
import com.skybridge.compass.core.network.ReconnectCoordinator
import com.skybridge.compass.core.network.RuntimeReconnectPolicyFactory
import com.skybridge.compass.core.p2p.TcpControlClient
import com.skybridge.compass.core.p2p.TcpControlSession
import kotlin.time.Duration
import kotlinx.coroutines.delay
import com.skybridge.compass.discovery.data.services.DiscoveryWindow.withDiscoveryWindow
import com.skybridge.compass.discovery.data.interop.AppleBonjourPeerRoutes
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * 设备发现仓库实现
 * 
 * 连接数据层和领域层，管理设备发现状态和缓存
 */
@Singleton
class DeviceDiscoveryRepositoryImpl @Inject constructor(private val unifiedDiscoveryService: UnifiedDeviceDiscoveryService,
    private val wifiAwarePeerRegistry: WifiAwarePeerRegistry,
    private val nearbyManager: NearbyConnectionsManager,
    private val awareDataPathManager: WifiAwareDataPathManager,
    private val tcpControlClient: TcpControlClient,
    private val runtimeParameters: RuntimeNetworkParametersSource,
    private val reconnectPolicyFactory: RuntimeReconnectPolicyFactory
) : DeviceDiscoveryRepository {

    /**
     * 退避睡眠注入点（R7.4 接线的可测试缝）。生产用 [delay]；测试注入空实现以免真实等待。
     * 不是设置镜像变量，只是时钟缝，故不属 R7.10 的清零对象。
     */
    internal var reconnectSleep: suspend (Duration) -> Unit = { delay(it) }

    private val _discoveredDevices = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
    private val _connectionStates = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    private val deviceIdToEndpointId: MutableMap<String, String> = mutableMapOf()
    private val endpointIdToDeviceId: MutableMap<String, String> = mutableMapOf()
    private val tcpSessionsByDeviceId = TcpSessionOwnerRegistry<String, TcpControlSession>(
        maxOwners = MAX_TCP_SESSION_OWNERS,
        closeOwner = TcpControlSession::close
    )

    private var isDiscovering = false

    override suspend fun startDiscovery(protocols: Set<DiscoveryProtocol>): Flow<List<DiscoveredDevice>> {
        if (isDiscovering) {
            return _discoveredDevices.asStateFlow()
        }
        
        isDiscovering = true

        // R7.4: the discovery window is read once, here at discovery-start time, so this run uses
        // the value that was persisted when it started. Changing the setting affects the next run
        // and never truncates or extends a run that is already in flight.
        val discoveryWindow = runtimeParameters.current().discoveryWindow

        return unifiedDiscoveryService.startDiscovery(protocols)
            .distinctUntilChanged()
            .onEach { devices ->
                _discoveredDevices.value = devices
                updateConnectionStates(devices)
            }
            .withDiscoveryWindow(discoveryWindow)
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
        // 首次尝试立即进行（用户发起的连接不应先等一个退避间隔）。
        val success = performConnection(device) || reconnectAfterFailedConnect(device)

        if (success) {
            updateDeviceConnectionState(device.id, true)
            updateDeviceInList(device.copy(isConnected = true))
        }

        return success
    }

    /**
     * 首次连接失败后按 `max_reconnect_attempts` 退避重试（R7.4 / R4.7）。
     *
     * 该方法是 `max_reconnect_attempts` 的**运行时消费方**：每次新会话都经
     * [RuntimeReconnectPolicyFactory.forNewSession] 重新取当前持久化值构造策略，
     * 因此设置改动对随后建立的连接生效，而进行中的重试仍按其开始时取得的上限运行。
     * 设为 0 时不进行任何重试。
     */
    private suspend fun reconnectAfterFailedConnect(device: DiscoveredDevice): Boolean {
        val policy = reconnectPolicyFactory.forNewSession()
        if (policy.maxAttempts <= 0) return false

        return ReconnectCoordinator(
            policy = policy,
            attemptConnect = {
                if (performConnection(device)) {
                    ReconnectAttemptResult.Established
                } else {
                    ReconnectAttemptResult.Failed(FAILURE_CONNECT_REJECTED)
                }
            },
            sleep = { reconnectSleep(it) }
        ).onDisconnected(DisconnectCause.UNEXPECTED)
    }

    override suspend fun disconnectFromDevice(deviceId: String) {
        performDisconnection(deviceId)
        updateDeviceConnectionState(deviceId, false)

        val updatedDevices = _discoveredDevices.value.map { device ->
            if (device.id == deviceId) {
                device.copy(isConnected = false)
            } else {
                device
            }
        }
        _discoveredDevices.value = updatedDevices
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
                val handshakeEndpoint = AppleBonjourPeerRoutes.from(device).handshake ?: return false
                connectViaTcp(device.id, handshakeEndpoint.host, handshakeEndpoint.port)
            }
            DiscoveryProtocol.WIFI_DIRECT -> {
                connectViaWifiDirect()
            }
            DiscoveryProtocol.BLUETOOTH -> {
                connectViaBluetooth()
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
            // Real Pro-release compatible control channel (length framing + handshake + AES-GCM app frames).
            tcpSessionsByDeviceId.replace(deviceId) { onClosed ->
                tcpControlClient.connect(
                    host = address,
                    port = port,
                    peerDeviceIdHint = deviceId,
                    onClosed = onClosed
                )
            }
            true
        }
    }
    
    /**
     * 通过WiFi Direct连接设备
     */
    private fun connectViaWifiDirect(): Boolean {
        // Wi‑Fi Direct requires WifiP2pManager orchestration and user consent flows.
        // Returning false is safer than reporting success without a real connection.
        return false
    }
    
    /**
     * 通过蓝牙连接设备
     */
    private fun connectViaBluetooth(): Boolean {
        // Bluetooth connection requires pairing + BLUETOOTH_CONNECT permission and a concrete RFCOMM profile.
        return false
    }

    /**
     * 通过 Nearby Connections 连接设备。
     * 连接建立仍依赖 Nearby 管理器与其生命周期回调，但这里不再伪造成功状态。
     */
    private suspend fun connectViaNearby(device: DiscoveredDevice): Boolean {
        val endpointId = device.connectionInfo.address.ifEmpty { device.id }
        rememberNearbyMapping(device.id, endpointId)
        val ok = nearbyManager.requestConnection(device.name.ifEmpty { "SkyBridgeClient" }, endpointId)
        if (ok) {
            val hello = """{"op":"hello","id":"${device.id}","ver":1}"""
            nearbyManager.sendBytes(endpointId, hello.toByteArray())
        }
        return ok
    }
/**
     * 通过 Wi‑Fi Aware 连接设备。
     * 连接建立仍依赖 Aware 会话中的数据通道，但这里不再伪造成功状态。
     */
    private suspend fun connectViaWifiAware(device: DiscoveredDevice): Boolean {
        return awareDataPathManager.initiateDataPath(device.id)
    }
/**
     * 执行设备断开连接
     */
    private suspend fun performDisconnection(deviceId: String) {
        // 实现断开连接逻辑
        // 根据设备ID找到对应的连接并关闭
        tcpSessionsByDeviceId.disconnect(deviceId)
        deviceIdToEndpointId[deviceId]?.let { endpointId ->
            nearbyManager.disconnect(endpointId)
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

    private companion object {
        /**
         * 单次重连尝试失败的原因分类，交给 [ReconnectCoordinator] 汇总到
         * [com.skybridge.compass.core.network.ReconnectState.GaveUp.failureCategory]。
         *
         * 这里的失败是「连接未能建立」这一可重试类别（对端拒绝/无响应），不是 R4.13 的安全终态
         * 失败——后者由 [DisconnectCause.TERMINAL] 表达，不进入重连循环。
         */
        private const val FAILURE_CONNECT_REJECTED = "CONNECT_REJECTED"
        private const val MAX_TCP_SESSION_OWNERS = 64
    }
}

internal class TcpSessionOwnerRegistry<K : Any, V : Any>(
    private val maxOwners: Int,
    stripeCount: Int = 16,
    closeOwner: (V) -> Unit
) {
    private val owners = ConcurrentHashMap<K, V>()
    private val ownerCount = AtomicInteger()
    private val stripes: Array<Mutex>
    private val closeOwner: (V) -> Unit = closeOwner

    init {
        require(maxOwners > 0) { "TCP session owner capacity must be positive" }
        require(stripeCount > 0) { "TCP session owner stripe count must be positive" }
        stripes = Array(stripeCount) { Mutex() }
    }

    suspend fun replace(
        key: K,
        createOwner: suspend (onClosed: (V) -> Unit) -> V
    ): V = withKeyLock(key) {
        val predecessor = owners[key]
        if (predecessor != null) {
            closeOwner(predecessor)
            retire(key, predecessor)
        }
        reserveSlot()

        var installed = false
        val publicationLock = Any()
        var closedBeforeInstall = false
        try {
            val successor = createOwner { closedOwner ->
                val retireInstalledOwner = synchronized(publicationLock) {
                    if (installed) {
                        true
                    } else {
                        closedBeforeInstall = true
                        false
                    }
                }
                if (retireInstalledOwner) retire(key, closedOwner)
            }
            synchronized(publicationLock) {
                check(!closedBeforeInstall) {
                    "TCP session closed before exact ownership publication"
                }
                check(owners.putIfAbsent(key, successor) == null) {
                    "TCP session successor ownership changed inside its serialized slot"
                }
                installed = true
            }
            return@withKeyLock successor
        } finally {
            if (!installed) ownerCount.decrementAndGet()
        }
    }

    suspend fun disconnect(key: K) = withKeyLock(key) {
        val owner = owners[key] ?: return@withKeyLock
        closeOwner(owner)
        retire(key, owner)
    }

    internal fun retire(key: K, owner: V): Boolean {
        if (!owners.remove(key, owner)) return false
        ownerCount.decrementAndGet()
        return true
    }

    internal fun owner(key: K): V? = owners[key]
    internal fun size(): Int = ownerCount.get()

    private fun reserveSlot() {
        val reserved = ownerCount.incrementAndGet()
        if (reserved > maxOwners) {
            ownerCount.decrementAndGet()
            error("TCP session owner capacity of $maxOwners is exhausted")
        }
    }

    private suspend fun <T> withKeyLock(key: K, action: suspend () -> T): T {
        val stripeIndex = Math.floorMod(key.hashCode(), stripes.size)
        return stripes[stripeIndex].withLock { action() }
    }
}
