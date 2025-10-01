package com.yunqiao.sinan.data

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.net.InetAddress
import java.net.NetworkInterface
import java.text.SimpleDateFormat
import java.util.*

/**
 * 设备连接状态枚举
 */
enum class ConnectionStatus {
    ONLINE,     // 在线
    OFFLINE,    // 离线
    CONNECTING  // 连接中
}

/**
 * 网络类型枚举
 */
enum class NetworkType {
    WIFI,       // WiFi
    MOBILE,     // 移动网络
    ETHERNET,   // 以太网
    UNKNOWN     // 未知
}

/**
 * 设备状态数据类
 */
data class DeviceStatus(
    val deviceName: String,
    val deviceModel: String,
    val connectionStatus: ConnectionStatus,
    val networkType: NetworkType,
    val ipAddress: String,
    val connectedDevicesCount: Int,
    val totalDevicesCount: Int,
    val cpuUsage: Float, // 0.0-1.0
    val memoryUsage: Float, // 0.0-1.0
    val batteryLevel: Int?, // 0-100, null if not available
    val lastUpdateTime: Long,
    val uptime: Long // 运行时间，毫秒
)

/**
 * 设备状态管理器
 */
class DeviceStatusManager(private val context: Context? = null) {
    private val _deviceStatus = MutableStateFlow(createRealDeviceStatus())
    val deviceStatus: StateFlow<DeviceStatus> = _deviceStatus

    /**
     * 更新设备状态
     */
    fun updateDeviceStatus(status: DeviceStatus) {
        _deviceStatus.value = status
    }

    /**
     * 更新连接的设备数量
     */
    fun updateConnectedDevicesCount(count: Int) {
        _deviceStatus.value = _deviceStatus.value.copy(
            connectedDevicesCount = count,
            lastUpdateTime = System.currentTimeMillis()
        )
    }

    /**
     * 更新连接状态
     */
    fun updateConnectionStatus(status: ConnectionStatus) {
        _deviceStatus.value = _deviceStatus.value.copy(
            connectionStatus = status,
            lastUpdateTime = System.currentTimeMillis()
        )
    }

    /**
     * 更新系统状态
     */
    fun updateSystemStatus() {
        if (context == null) return
        
        try {
            val currentStatus = _deviceStatus.value
            
            _deviceStatus.value = currentStatus.copy(
                connectionStatus = getConnectionStatus(),
                networkType = getNetworkType(),
                ipAddress = getLocalIpAddress(),
                batteryLevel = getBatteryLevel(),
                cpuUsage = getCpuUsage(),
                memoryUsage = getMemoryUsage(),
                lastUpdateTime = System.currentTimeMillis(),
                uptime = getSystemUptime()
            )
        } catch (e: Exception) {
            // 保持当前状态
        }
    }
    
    private fun getConnectionStatus(): ConnectionStatus {
        if (context == null) return ConnectionStatus.OFFLINE
        
        return try {
            val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = connectivityManager.activeNetwork
            val networkCapabilities = connectivityManager.getNetworkCapabilities(network)
            
            if (networkCapabilities != null && 
                (networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                 networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))) {
                ConnectionStatus.ONLINE
            } else {
                ConnectionStatus.OFFLINE
            }
        } catch (e: Exception) {
            ConnectionStatus.OFFLINE
        }
    }
    
    private fun getNetworkType(): NetworkType {
        if (context == null) return NetworkType.UNKNOWN
        
        return try {
            val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = connectivityManager.activeNetwork
            val networkCapabilities = connectivityManager.getNetworkCapabilities(network)
            
            when {
                networkCapabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> NetworkType.WIFI
                networkCapabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> NetworkType.MOBILE
                networkCapabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> NetworkType.ETHERNET
                else -> NetworkType.UNKNOWN
            }
        } catch (e: Exception) {
            NetworkType.UNKNOWN
        }
    }
    
    private fun getLocalIpAddress(): String {
        return try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            for (intf in interfaces) {
                val addresses = intf.inetAddresses
                for (addr in addresses) {
                    if (!addr.isLoopbackAddress && addr is InetAddress) {
                        val hostAddress = addr.hostAddress
                        if (hostAddress?.contains(":") == false) { // IPv4
                            return hostAddress
                        }
                    }
                }
            }
            "未知"
        } catch (e: Exception) {
            "未知"
        }
    }
    
    private fun getBatteryLevel(): Int? {
        if (context == null) return null
        
        return try {
            val batteryManager = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        } catch (e: Exception) {
            null
        }
    }
    
    private fun getCpuUsage(): Float {
        return try {
            val runtime = Runtime.getRuntime()
            runtime.availableProcessors().toFloat() * 0.1f // 简化的CPU使用率估算
        } catch (e: Exception) {
            0f
        }
    }
    
    private fun getMemoryUsage(): Float {
        return try {
            val runtime = Runtime.getRuntime()
            val usedMemory = runtime.totalMemory() - runtime.freeMemory()
            val maxMemory = runtime.maxMemory()
            usedMemory.toFloat() / maxMemory.toFloat()
        } catch (e: Exception) {
            0f
        }
    }
    
    private fun getSystemUptime(): Long {
        return try {
            android.os.SystemClock.elapsedRealtime()
        } catch (e: Exception) {
            0L
        }
    }

    companion object {
        /**
         * 创建真实设备状态
         */
        private fun createRealDeviceStatus(): DeviceStatus {
            return DeviceStatus(
                deviceName = getDeviceName(),
                deviceModel = getDeviceModel(),
                connectionStatus = ConnectionStatus.ONLINE,
                networkType = NetworkType.UNKNOWN,
                ipAddress = "获取中...",
                connectedDevicesCount = 0,
                totalDevicesCount = 0,
                cpuUsage = 0f,
                memoryUsage = 0f,
                batteryLevel = null,
                lastUpdateTime = System.currentTimeMillis(),
                uptime = 0L
            )
        }
        
        private fun getDeviceName(): String {
            return try {
                Build.MODEL ?: "未知设备"
            } catch (e: Exception) {
                "云桥司南主机"
            }
        }
        
        private fun getDeviceModel(): String {
            return try {
                "${Build.MANUFACTURER} ${Build.MODEL}" ?: "未知型号"
            } catch (e: Exception) {
                "Android Device"
            }
        }
    }
}

/**
 * 格式化运行时间
 */
fun formatUptime(uptimeMillis: Long): String {
    val hours = uptimeMillis / (1000 * 60 * 60)
    val minutes = (uptimeMillis % (1000 * 60 * 60)) / (1000 * 60)
    return when {
        hours > 0 -> "${hours}h ${minutes}m"
        minutes > 0 -> "${minutes}m"
        else -> "< 1m"
    }
}

/**
 * 格式化最后更新时间
 */
fun formatLastUpdate(timestamp: Long): String {
    val formatter = SimpleDateFormat("HH:mm:ss", Locale.getDefault())
    return formatter.format(Date(timestamp))
}

/**
 * 获取连接状态显示文本
 */
fun getConnectionStatusText(status: ConnectionStatus): String {
    return when (status) {
        ConnectionStatus.ONLINE -> "在线"
        ConnectionStatus.OFFLINE -> "离线"
        ConnectionStatus.CONNECTING -> "连接中"
    }
}

/**
 * 获取网络类型显示文本
 */
fun getNetworkTypeText(type: NetworkType): String {
    return when (type) {
        NetworkType.WIFI -> "WiFi"
        NetworkType.MOBILE -> "移动网络"
        NetworkType.ETHERNET -> "以太网"
        NetworkType.UNKNOWN -> "未知"
    }
}

/**
 * Composable函数：记住设备状态管理器
 */
@Composable
fun rememberDeviceStatusManager(): DeviceStatusManager {
    return remember { DeviceStatusManager(null) }
}
