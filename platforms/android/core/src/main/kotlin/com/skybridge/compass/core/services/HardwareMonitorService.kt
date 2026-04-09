package com.skybridge.compass.core.services

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 网络质量等级
 */
enum class QualityLevel {
    EXCELLENT,  // 优秀: 延迟 < 50ms, 丢包 < 1%
    GOOD,       // 良好: 延迟 < 100ms, 丢包 < 3%
    FAIR,       // 一般: 延迟 < 200ms, 丢包 < 5%
    POOR,       // 较差: 延迟 >= 200ms 或 丢包 >= 5%
    OFFLINE     // 离线
}

/**
 * 网络质量数据
 */
data class NetworkQuality(
    val level: QualityLevel,
    val latencyMs: Long,
    val bandwidthMbps: Float,
    val packetLossPercent: Float
) {
    companion object {
        fun offline() = NetworkQuality(QualityLevel.OFFLINE, -1L, 0f, 100f)
    }
}

/**
 * 网络状态
 */
data class NetworkState(
    val isConnected: Boolean,
    val isWifi: Boolean,
    val isCellular: Boolean,
    val isEthernet: Boolean,
    val ssid: String? = null,
    val linkSpeedMbps: Int = -1
)


/**
 * 数据传输统计
 */
data class TransferStatistics(
    val totalBytesSent: Long,
    val totalBytesReceived: Long,
    val activeTransfers: Int,
    val completedTransfers: Int
)

/**
 * 硬件监控服务接口
 * 负责读取本地设备硬件信息，替代远程 API 调用
 */
interface HardwareMonitorService {
    /**
     * 获取已连接设备数量
     */
    fun getConnectedDeviceCount(): Flow<Int>
    
    /**
     * 测量网络延迟
     * @param targetHost 目标主机地址
     * @param port 目标端口，默认 80
     * @return 延迟毫秒数，-1 表示无法连接
     */
    suspend fun measureNetworkLatency(targetHost: String, port: Int = 80): Long
    
    /**
     * 计算网络质量
     */
    fun calculateNetworkQuality(latencyMs: Long, bandwidthMbps: Float, packetLossPercent: Float): NetworkQuality
    
    /**
     * 获取数据传输统计
     */
    fun getTransferStatistics(): Flow<TransferStatistics>
    
    /**
     * 监听网络状态变化
     */
    fun observeNetworkState(): Flow<NetworkState>
    
    /**
     * 获取当前网络质量
     */
    fun observeNetworkQuality(): Flow<NetworkQuality>
}

/**
 * 硬件监控服务实现
 */
@Singleton
class HardwareMonitorServiceImpl @Inject constructor(
    @ApplicationContext private val context: Context
) : HardwareMonitorService {
    
    private val connectivityManager: ConnectivityManager by lazy {
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    
    private val wifiManager: WifiManager by lazy {
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    }
    
    // 已连接设备数量（由 DeviceDiscovery 模块更新）
    private val _connectedDeviceCount = MutableStateFlow(0)
    
    // 传输统计（由 FileTransfer 模块更新）
    private val _transferStatistics = MutableStateFlow(TransferStatistics(0L, 0L, 0, 0))
    
    // 当前网络质量
    private val _networkQuality = MutableStateFlow(NetworkQuality.offline())
    
    /**
     * 更新已连接设备数量（供其他模块调用）
     */
    fun updateConnectedDeviceCount(count: Int) {
        _connectedDeviceCount.value = count
    }
    
    /**
     * 更新传输统计（供其他模块调用）
     */
    fun updateTransferStatistics(stats: TransferStatistics) {
        _transferStatistics.value = stats
    }
    
    override fun getConnectedDeviceCount(): Flow<Int> = _connectedDeviceCount.asStateFlow()
    
    override suspend fun measureNetworkLatency(targetHost: String, port: Int): Long {
        return withContext(Dispatchers.IO) {
            try {
                val startTime = System.currentTimeMillis()
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(targetHost, port), 5000)
                }
                System.currentTimeMillis() - startTime
            } catch (e: Exception) {
                -1L
            }
        }
    }
    
    override fun calculateNetworkQuality(
        latencyMs: Long,
        bandwidthMbps: Float,
        packetLossPercent: Float
    ): NetworkQuality {
        val level = when {
            latencyMs < 0 -> QualityLevel.OFFLINE
            latencyMs < 50 && packetLossPercent < 1f -> QualityLevel.EXCELLENT
            latencyMs < 100 && packetLossPercent < 3f -> QualityLevel.GOOD
            latencyMs < 200 && packetLossPercent < 5f -> QualityLevel.FAIR
            else -> QualityLevel.POOR
        }
        return NetworkQuality(level, latencyMs, bandwidthMbps, packetLossPercent)
    }
    
    override fun getTransferStatistics(): Flow<TransferStatistics> = _transferStatistics.asStateFlow()

    
    override fun observeNetworkState(): Flow<NetworkState> = callbackFlow {
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                trySend(getCurrentNetworkState())
            }
            
            override fun onLost(network: Network) {
                trySend(NetworkState(
                    isConnected = false,
                    isWifi = false,
                    isCellular = false,
                    isEthernet = false
                ))
            }
            
            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities
            ) {
                trySend(getCurrentNetworkState())
            }
        }
        
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        
        connectivityManager.registerNetworkCallback(request, callback)
        
        // 发送初始状态
        trySend(getCurrentNetworkState())
        
        awaitClose {
            connectivityManager.unregisterNetworkCallback(callback)
        }
    }
    
    override fun observeNetworkQuality(): Flow<NetworkQuality> = _networkQuality.asStateFlow()
    
    /**
     * 更新网络质量（供内部或外部调用）
     */
    fun updateNetworkQuality(quality: NetworkQuality) {
        _networkQuality.value = quality
    }
    
    private fun getCurrentNetworkState(): NetworkState {
        val network = connectivityManager.activeNetwork
        val capabilities = network?.let { connectivityManager.getNetworkCapabilities(it) }
        
        if (capabilities == null) {
            return NetworkState(
                isConnected = false,
                isWifi = false,
                isCellular = false,
                isEthernet = false
            )
        }
        
        val isWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        val isCellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        val isEthernet = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        
        var ssid: String? = null
        var linkSpeed = -1
        
        if (isWifi) {
            @Suppress("DEPRECATION")
            val wifiInfo = wifiManager.connectionInfo
            if (wifiInfo != null) {
                ssid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    // Android 10+ 需要位置权限才能获取 SSID
                    wifiInfo.ssid?.replace("\"", "")
                } else {
                    @Suppress("DEPRECATION")
                    wifiInfo.ssid?.replace("\"", "")
                }
                linkSpeed = wifiInfo.linkSpeed
            }
        }
        
        return NetworkState(
            isConnected = true,
            isWifi = isWifi,
            isCellular = isCellular,
            isEthernet = isEthernet,
            ssid = ssid,
            linkSpeedMbps = linkSpeed
        )
    }
    
    /**
     * 测量丢包率（简化实现）
     */
    suspend fun measurePacketLoss(targetHost: String, attempts: Int = 10): Float {
        return withContext(Dispatchers.IO) {
            var failures = 0
            repeat(attempts) {
                val latency = measureNetworkLatency(targetHost)
                if (latency < 0) failures++
            }
            (failures.toFloat() / attempts) * 100f
        }
    }
    
    /**
     * 估算带宽（基于 WiFi 链路速度或默认值）
     */
    fun estimateBandwidth(): Float {
        val state = getCurrentNetworkState()
        return when {
            !state.isConnected -> 0f
            state.isWifi && state.linkSpeedMbps > 0 -> state.linkSpeedMbps.toFloat()
            state.isEthernet -> 100f // 假设 100Mbps
            state.isCellular -> 10f  // 假设 10Mbps
            else -> 1f
        }
    }
}
