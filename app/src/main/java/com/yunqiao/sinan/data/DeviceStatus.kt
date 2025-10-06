package com.yunqiao.sinan.data

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.TrafficStats
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.HardwarePropertiesManager
import android.os.PowerManager
import android.os.SystemClock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.net.InetAddress
import java.net.NetworkInterface
import java.text.SimpleDateFormat
import java.util.*
import kotlin.math.coerceAtLeast
import kotlin.math.coerceIn
import kotlin.math.roundToInt
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

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
 * 电池充放电状态
 */
enum class BatteryChargeStatus {
    CHARGING,
    DISCHARGING,
    FULL,
    NOT_PRESENT,
    UNKNOWN
}

/**
 * 电源输入类型
 */
enum class BatteryChargeSource {
    AC,
    USB,
    WIRELESS,
    NONE,
    UNKNOWN
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
    val cpuTemperatureC: Float?,
    val gpuUsage: Float, // 0.0-1.0
    val gpuTemperatureC: Float?,
    val memoryUsage: Float, // 0.0-1.0
    val uploadRateKbps: Float,
    val downloadRateKbps: Float,
    val batteryLevel: Int?, // 0-100, null if not available
    val batteryStatus: BatteryChargeStatus,
    val batteryChargeSource: BatteryChargeSource,
    val batteryCurrentMa: Int?,
    val batteryChargeCounterMah: Int?,
    val batteryTemperatureC: Float?,
    val thermalStatus: Int,
    val lastUpdateTime: Long,
    val uptime: Long // 运行时间，毫秒
)

/**
 * 设备状态管理器
 */
class DeviceStatusManager(private val context: Context? = null) {
    private val _deviceStatus = MutableStateFlow(createRealDeviceStatus())
    val deviceStatus: StateFlow<DeviceStatus> = _deviceStatus

    private val hardwarePropertiesManager = context?.getSystemService(Context.HARDWARE_PROPERTIES_SERVICE) as? HardwarePropertiesManager
    private val powerManager = context?.getSystemService(Context.POWER_SERVICE) as? PowerManager

    private var lastCpuSnapshot: CpuSnapshot? = null
    private var lastSampleTimestamp = 0L
    private var lastTxBytes = 0L
    private var lastRxBytes = 0L

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
            val throughput = getNetworkThroughput()
            val battery = getBatteryTelemetry()

            _deviceStatus.value = currentStatus.copy(
                connectionStatus = getConnectionStatus(),
                networkType = getNetworkType(),
                ipAddress = getLocalIpAddress(),
                batteryLevel = battery.level,
                batteryStatus = battery.status,
                batteryChargeSource = battery.source,
                batteryCurrentMa = battery.currentMa,
                batteryChargeCounterMah = battery.chargeCounterMah,
                batteryTemperatureC = battery.temperatureC,
                cpuUsage = getCpuUsage(),
                cpuTemperatureC = getCpuTemperature(),
                gpuUsage = getGpuUsage(),
                gpuTemperatureC = getGpuTemperature(),
                memoryUsage = getMemoryUsage(),
                uploadRateKbps = throughput.first,
                downloadRateKbps = throughput.second,
                thermalStatus = getThermalStatus(),
                lastUpdateTime = System.currentTimeMillis(),
                uptime = getSystemUptime()
            )
        } catch (e: Exception) {
            // 保持当前状态
        }
    }

    private fun getNetworkThroughput(): Pair<Float, Float> {
        if (context == null) return 0f to 0f

        return try {
            val now = SystemClock.elapsedRealtime()
            val elapsed = now - lastSampleTimestamp
            val totalTx = TrafficStats.getTotalTxBytes().coerceAtLeast(0L)
            val totalRx = TrafficStats.getTotalRxBytes().coerceAtLeast(0L)
            if (elapsed <= 0 || lastSampleTimestamp == 0L) {
                lastSampleTimestamp = now
                lastTxBytes = totalTx
                lastRxBytes = totalRx
                0f to 0f
            } else {
                val txDelta = (totalTx - lastTxBytes).coerceAtLeast(0L)
                val rxDelta = (totalRx - lastRxBytes).coerceAtLeast(0L)
                lastSampleTimestamp = now
                lastTxBytes = totalTx
                lastRxBytes = totalRx
                val upload = (txDelta * 8f * 1000f) / (elapsed * 1024f)
                val download = (rxDelta * 8f * 1000f) / (elapsed * 1024f)
                upload.coerceAtLeast(0f) to download.coerceAtLeast(0f)
            }
        } catch (e: Exception) {
            0f to 0f
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

    private fun getCpuTemperature(): Float? {
        if (context == null) return null

        val hardwareReading = readHardwareTemperature(HardwarePropertiesManager.DEVICE_TEMPERATURE_CPU)
        if (hardwareReading != null) {
            return hardwareReading
        }
        return readThermalZoneTemperature(listOf("cpu", "soc", "ap"))
    }

    private fun getGpuTemperature(): Float? {
        if (context == null) return null

        val hardwareReading = readHardwareTemperature(HardwarePropertiesManager.DEVICE_TEMPERATURE_GPU)
        if (hardwareReading != null) {
            return hardwareReading
        }
        return readThermalZoneTemperature(listOf("gpu", "gpu-therm", "g3d"))
    }

    private fun getGpuUsage(): Float {
        val candidates = listOf(
            "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage",
            "/sys/devices/platform/kgsl-3d0.0/kgsl/kgsl-3d0/gpu_busy_percentage",
            "/sys/class/devfreq/gpufreq/gpu_busy",
            "/sys/devices/gpu.0/load"
        )
        for (path in candidates) {
            val file = File(path)
            if (!file.exists() || !file.canRead()) continue
            val raw = runCatching { file.readText().trim() }.getOrNull() ?: continue
            val normalized = parseGpuUsage(raw)
            if (normalized != null) {
                return normalized
            }
        }
        return 0f
    }

    private fun parseGpuUsage(raw: String): Float? {
        if (raw.isEmpty()) return null
        val sanitized = raw.replace("%", "").trim()
        val parts = sanitized.split(" ", ",", "/").filter { it.isNotBlank() }
        val value = when {
            parts.size >= 2 && parts[0].toFloatOrNull() != null && parts[1].toFloatOrNull() != null -> {
                val active = parts[0].toFloat()
                val total = parts[1].toFloat()
                if (total <= 0f) return null else (active / total)
            }
            sanitized.contains(":") -> {
                sanitized.substringAfterLast(":").toFloatOrNull()
            }
            else -> sanitized.toFloatOrNull()
        } ?: return null

        return when {
            value.isNaN() || value.isInfinite() -> null
            value > 1f -> (value / 100f).coerceIn(0f, 1f)
            value < 0f -> 0f
            else -> value.coerceIn(0f, 1f)
        }
    }

    private fun getBatteryTelemetry(): BatteryTelemetry {
        if (context == null) return BatteryTelemetry()

        return try {
            val ctx = context
            val intent = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val batteryManager = ctx.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager

            val intentLevel = intent?.let {
                val level = it.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = it.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                if (level >= 0 && scale > 0) ((level / scale.toFloat()) * 100).toInt() else null
            }

            val level = intentLevel ?: batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)?.takeIf { it >= 0 }

            val status = when (intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)) {
                BatteryManager.BATTERY_STATUS_CHARGING -> BatteryChargeStatus.CHARGING
                BatteryManager.BATTERY_STATUS_DISCHARGING -> BatteryChargeStatus.DISCHARGING
                BatteryManager.BATTERY_STATUS_FULL -> BatteryChargeStatus.FULL
                BatteryManager.BATTERY_STATUS_NOT_CHARGING -> BatteryChargeStatus.DISCHARGING
                BatteryManager.BATTERY_STATUS_UNKNOWN -> BatteryChargeStatus.UNKNOWN
                else -> BatteryChargeStatus.UNKNOWN
            }

            val present = intent?.getBooleanExtra(BatteryManager.EXTRA_PRESENT, true) ?: true
            val resolvedStatus = if (!present) BatteryChargeStatus.NOT_PRESENT else status

            val plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
            val source = when {
                plugged and BatteryManager.BATTERY_PLUGGED_AC != 0 -> BatteryChargeSource.AC
                plugged and BatteryManager.BATTERY_PLUGGED_USB != 0 -> BatteryChargeSource.USB
                plugged and BatteryManager.BATTERY_PLUGGED_WIRELESS != 0 -> BatteryChargeSource.WIRELESS
                resolvedStatus == BatteryChargeStatus.NOT_PRESENT -> BatteryChargeSource.NONE
                plugged == 0 -> BatteryChargeSource.NONE
                else -> BatteryChargeSource.UNKNOWN
            }

            val currentNow = batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)?.takeIf { it != Int.MIN_VALUE }
            val currentMa = currentNow?.let { (it / 1000f).roundToInt() }

            val chargeCounter = batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)?.takeIf { it != Int.MIN_VALUE }
            val chargeCounterMah = chargeCounter?.let { (it / 1000f).roundToInt() }

            val temperatureExtra = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
            val temperatureC = when {
                temperatureExtra != null && temperatureExtra != Int.MIN_VALUE -> temperatureExtra / 10f
                else -> readThermalZoneTemperature(listOf("battery", "batt"))
            }

            BatteryTelemetry(
                level = level,
                status = resolvedStatus,
                source = source,
                currentMa = currentMa,
                chargeCounterMah = chargeCounterMah,
                temperatureC = temperatureC
            )
        } catch (e: Exception) {
            BatteryTelemetry(level = getBatteryLevel(), status = BatteryChargeStatus.UNKNOWN, source = BatteryChargeSource.UNKNOWN)
        }
    }

    private fun getThermalStatus(): Int {
        if (powerManager == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return PowerManager.THERMAL_STATUS_NONE
        }
        return try {
            powerManager.currentThermalStatus
        } catch (e: Exception) {
            PowerManager.THERMAL_STATUS_NONE
        }
    }

    private fun readHardwareTemperature(type: Int): Float? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return null
        val manager = hardwarePropertiesManager ?: return null
        return runCatching {
            @Suppress("DEPRECATION")
            val readings = manager.getDeviceTemperatures(type, HardwarePropertiesManager.TEMPERATURE_CURRENT)
            val unavailable = HardwarePropertiesManager.TEMPERATURE_UNAVAILABLE.toFloat()
            readings?.firstOrNull { !it.isNaN() && it != unavailable }
        }.getOrNull()
    }

    private fun readThermalZoneTemperature(keywords: List<String>): Float? {
        val base = File("/sys/class/thermal")
        if (!base.exists() || !base.isDirectory) return null
        val lowerKeywords = keywords.map { it.lowercase(Locale.getDefault()) }
        base.listFiles { file -> file.name.startsWith("thermal_zone") }?.forEach { zone ->
            val typeFile = File(zone, "type")
            val tempFile = File(zone, "temp")
            if (!typeFile.exists() || !tempFile.exists()) return@forEach
            val typeName = runCatching { typeFile.readText().trim().lowercase(Locale.getDefault()) }.getOrNull() ?: return@forEach
            if (lowerKeywords.none { keyword -> typeName.contains(keyword) }) return@forEach
            val raw = runCatching { tempFile.readText().trim() }.getOrNull() ?: return@forEach
            val numeric = raw.toFloatOrNull() ?: raw.toIntOrNull()?.toFloat() ?: return@forEach
            val value = when {
                numeric > 1000f -> numeric / 1000f
                numeric > 200f -> numeric / 10f
                else -> numeric
            }
            if (!value.isNaN() && value > 0f) {
                return value
            }
        }
        return null
    }

    private fun getCpuUsage(): Float {
        return try {
            val snapshot = readCpuSnapshot() ?: return 0f
            val previous = lastCpuSnapshot
            lastCpuSnapshot = snapshot

            if (previous == null) {
                0f
            } else {
                val idleDiff = snapshot.idle - previous.idle
                val totalDiff = snapshot.total - previous.total
                if (totalDiff <= 0L) {
                    0f
                } else {
                    ((totalDiff - idleDiff).toFloat() / totalDiff.toFloat()).coerceIn(0f, 1f)
                }
            }
        } catch (e: Exception) {
            0f
        }
    }

    private fun getMemoryUsage(): Float {
        if (context == null) return 0f

        return try {
            val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val info = ActivityManager.MemoryInfo()
            activityManager.getMemoryInfo(info)
            val total = info.totalMem.toFloat()
            if (total <= 0f) {
                0f
            } else {
                ((total - info.availMem.toFloat()) / total).coerceIn(0f, 1f)
            }
        } catch (e: Exception) {
            0f
        }
    }

    private fun getSystemUptime(): Long {
        return try {
            SystemClock.elapsedRealtime()
        } catch (e: Exception) {
            0L
        }
    }

    private fun readCpuSnapshot(): CpuSnapshot? {
        return try {
            val reader = java.io.RandomAccessFile("/proc/stat", "r")
            val load = reader.readLine()
            reader.close()
            val tokens = load.split(" ").filter { it.isNotBlank() }
            if (tokens.size < 8) return null
            val user = tokens[1].toLong()
            val nice = tokens[2].toLong()
            val system = tokens[3].toLong()
            val idle = tokens[4].toLong()
            val iowait = tokens.getOrNull(5)?.toLong() ?: 0L
            val irq = tokens.getOrNull(6)?.toLong() ?: 0L
            val softIrq = tokens.getOrNull(7)?.toLong() ?: 0L
            val total = user + nice + system + idle + iowait + irq + softIrq
            CpuSnapshot(total = total, idle = idle)
        } catch (e: Exception) {
            null
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
                cpuTemperatureC = null,
                gpuUsage = 0f,
                gpuTemperatureC = null,
                memoryUsage = 0f,
                uploadRateKbps = 0f,
                downloadRateKbps = 0f,
                batteryLevel = null,
                batteryStatus = BatteryChargeStatus.UNKNOWN,
                batteryChargeSource = BatteryChargeSource.UNKNOWN,
                batteryCurrentMa = null,
                batteryChargeCounterMah = null,
                batteryTemperatureC = null,
                thermalStatus = PowerManager.THERMAL_STATUS_NONE,
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

private data class CpuSnapshot(
    val total: Long,
    val idle: Long
)

private data class BatteryTelemetry(
    val level: Int? = null,
    val status: BatteryChargeStatus = BatteryChargeStatus.UNKNOWN,
    val source: BatteryChargeSource = BatteryChargeSource.UNKNOWN,
    val currentMa: Int? = null,
    val chargeCounterMah: Int? = null,
    val temperatureC: Float? = null
)

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

fun formatTemperatureC(value: Float?): String {
    return value?.let { String.format(Locale.getDefault(), "%.1f°C", it) } ?: "--"
}

fun describeBatteryStatus(status: BatteryChargeStatus, source: BatteryChargeSource): String {
    val state = when (status) {
        BatteryChargeStatus.CHARGING -> "充电中"
        BatteryChargeStatus.DISCHARGING -> "放电中"
        BatteryChargeStatus.FULL -> "已充满"
        BatteryChargeStatus.NOT_PRESENT -> "未装电池"
        BatteryChargeStatus.UNKNOWN -> "未知状态"
    }
    val channel = when (source) {
        BatteryChargeSource.AC -> "交流供电"
        BatteryChargeSource.USB -> "USB供电"
        BatteryChargeSource.WIRELESS -> "无线充电"
        BatteryChargeSource.NONE -> "电池供电"
        BatteryChargeSource.UNKNOWN -> ""
    }
    return if (channel.isBlank()) state else "$state · $channel"
}

fun formatBatteryCurrent(currentMa: Int?): String {
    if (currentMa == null) return "--"
    return if (currentMa > 0) {
        String.format(Locale.getDefault(), "+%d mA", currentMa)
    } else {
        String.format(Locale.getDefault(), "%d mA", currentMa)
    }
}

fun formatBatteryCapacityMah(chargeCounterMah: Int?): String {
    return chargeCounterMah?.let { String.format(Locale.getDefault(), "%d mAh", it) } ?: "--"
}

fun getThermalStatusText(status: Int): String {
    return when (status) {
        PowerManager.THERMAL_STATUS_NONE -> "正常"
        PowerManager.THERMAL_STATUS_LIGHT -> "轻微升温"
        PowerManager.THERMAL_STATUS_MODERATE -> "温度偏高"
        PowerManager.THERMAL_STATUS_SEVERE -> "高温限制"
        PowerManager.THERMAL_STATUS_CRITICAL -> "临界高温"
        PowerManager.THERMAL_STATUS_EMERGENCY -> "紧急降频"
        PowerManager.THERMAL_STATUS_SHUTDOWN -> "即将关机"
        else -> "未知"
    }
}

/**
 * Composable函数：记住设备状态管理器
 */
@Composable
fun rememberDeviceStatusManager(): DeviceStatusManager {
    val context = LocalContext.current.applicationContext
    return remember { DeviceStatusManager(context) }
}
