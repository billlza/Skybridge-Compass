package com.yunqiao.sinan.operationshub.manager

import android.content.Context
import android.net.TrafficStats
import android.os.BatteryManager
import com.yunqiao.sinan.operationshub.model.SystemPerformance
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.io.RandomAccessFile

/**
 * 系统监控管理器
 */
class SystemMonitorManager(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    private val _systemPerformance = MutableStateFlow(SystemPerformance())
    val systemPerformance: StateFlow<SystemPerformance> = _systemPerformance.asStateFlow()
    
    private var lastTxBytes = 0L
    private var lastRxBytes = 0L
    private var lastUpdateTime = 0L
    
    private var isMonitoring = false
    
    /**
     * 开始监控
     */
    fun startMonitoring() {
        if (isMonitoring) return
        
        isMonitoring = true
        scope.launch {
            while (isActive && isMonitoring) {
                try {
                    val performance = collectSystemPerformance()
                    _systemPerformance.value = performance
                    delay(2000) // 每2秒更新一次
                } catch (e: Exception) {
                    // 在实际使用中应该记录日志
                    delay(5000) // 错误时稍微延长间隔
                }
            }
        }
    }
    
    /**
     * 停止监控
     */
    fun stopMonitoring() {
        isMonitoring = false
    }
    
    /**
     * 获取当前系统性能数据
     */
    suspend fun getCurrentPerformance(): SystemPerformance {
        return collectSystemPerformance()
    }
    
    /**
     * 收集系统性能数据
     */
    private fun collectSystemPerformance(): SystemPerformance {
        return SystemPerformance(
            timestamp = System.currentTimeMillis(),
            cpuUsage = getCpuUsage(),
            memoryUsage = getMemoryUsage(),
            storageUsage = getStorageUsage(),
            batteryLevel = getBatteryLevel(),
            networkUpload = getNetworkUpload(),
            networkDownload = getNetworkDownload(),
            gpuUsage = getGpuUsage(),
            temperature = getSystemTemperature()
        )
    }
    
    /**
     * 获取CPU使用率
     */
    private fun getCpuUsage(): Float {
        return try {
            // 读取 /proc/stat 获取真实CPU使用率
            val statFile = File("/proc/stat")
            if (!statFile.exists()) return 0f
            
            val lines = statFile.readLines()
            val cpuLine = lines.firstOrNull { it.startsWith("cpu ") } ?: return 0f
            
            val cpuData = cpuLine.split("\\s+".toRegex()).drop(1).map { it.toLongOrNull() ?: 0L }
            if (cpuData.size < 4) return 0f
            
            val idle = cpuData[3]
            val total = cpuData.sum()
            
            if (total == 0L) return 0f
            
            val usage = 1.0f - (idle.toFloat() / total.toFloat())
            return maxOf(0f, minOf(1f, usage))
        } catch (e: Exception) {
            0f
        }
    }
    
    /**
     * 获取内存使用率
     */
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
    
    /**
     * 获取存储使用率
     */
    private fun getStorageUsage(): Float {
        return try {
            val dataDir = context.filesDir
            val totalSpace = dataDir.totalSpace
            val freeSpace = dataDir.freeSpace
            val usedSpace = totalSpace - freeSpace
            if (totalSpace > 0) {
                usedSpace.toFloat() / totalSpace.toFloat()
            } else {
                0f
            }
        } catch (e: Exception) {
            0f
        }
    }
    
    /**
     * 获取电池电量
     */
    private fun getBatteryLevel(): Int? {
        return try {
            val batteryManager = context.getSystemService(Context.BATTERY_SERVICE) as? android.os.BatteryManager
            batteryManager?.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
        } catch (e: Exception) {
            null
        }
    }
    
    /**
     * 获取网络上传速度
     */
    private fun getNetworkUpload(): Float {
        return try {
            val currentTxBytes = TrafficStats.getTotalTxBytes()
            val currentTime = System.currentTimeMillis()
            
            if (lastTxBytes > 0 && lastUpdateTime > 0) {
                val bytesDiff = currentTxBytes - lastTxBytes
                val timeDiff = currentTime - lastUpdateTime
                
                if (timeDiff > 0) {
                    val bytesPerSecond = (bytesDiff * 1000f) / timeDiff
                    val kbytesPerSecond = bytesPerSecond / 1024f
                    
                    lastTxBytes = currentTxBytes
                    lastUpdateTime = currentTime
                    
                    return maxOf(0f, kbytesPerSecond)
                }
            }
            
            lastTxBytes = currentTxBytes
            lastUpdateTime = currentTime
            0f
        } catch (e: Exception) {
            0f
        }
    }
    
    /**
     * 获取网络下载速度
     */
    private fun getNetworkDownload(): Float {
        return try {
            val currentRxBytes = TrafficStats.getTotalRxBytes()
            val currentTime = System.currentTimeMillis()
            
            if (lastRxBytes > 0 && lastUpdateTime > 0) {
                val bytesDiff = currentRxBytes - lastRxBytes
                val timeDiff = currentTime - lastUpdateTime
                
                if (timeDiff > 0) {
                    val bytesPerSecond = (bytesDiff * 1000f) / timeDiff
                    val kbytesPerSecond = bytesPerSecond / 1024f
                    
                    lastRxBytes = currentRxBytes
                    
                    return maxOf(0f, kbytesPerSecond)
                }
            }
            
            lastRxBytes = currentRxBytes
            0f
        } catch (e: Exception) {
            0f
        }
    }
    
    /**
     * 获取GPU使用率
     */
    private fun getGpuUsage(): Float {
        return try {
            // 尝试读取GPU频率文件
            val gpuFreqFile = File("/sys/class/kgsl/kgsl-3d0/gpuclk")
            val gpuMaxFreqFile = File("/sys/class/kgsl/kgsl-3d0/max_gpuclk")
            
            if (gpuFreqFile.exists() && gpuMaxFreqFile.exists()) {
                val currentFreq = gpuFreqFile.readText().trim().toLongOrNull() ?: 0L
                val maxFreq = gpuMaxFreqFile.readText().trim().toLongOrNull() ?: 1L
                
                if (maxFreq > 0) {
                    return (currentFreq.toFloat() / maxFreq.toFloat())
                }
            }
            
            // 备选方案：读取GPU负载
            val gpuLoadFile = File("/sys/class/kgsl/kgsl-3d0/gpubusy")
            if (gpuLoadFile.exists()) {
                val busyInfo = gpuLoadFile.readText().trim()
                val parts = busyInfo.split(" ")
                if (parts.size >= 2) {
                    val busy = parts[0].toLongOrNull() ?: 0L
                    val total = parts[1].toLongOrNull() ?: 1L
                    return if (total > 0) (busy.toFloat() / total.toFloat()) else 0f
                }
            }
            
            0f
        } catch (e: Exception) {
            0f
        }
    }
    
    /**
     * 获取系统温度
     */
    private fun getSystemTemperature(): Float {
        return try {
            // 尝试读取不同的温度传感器
            val tempSources = listOf(
                "/sys/class/thermal/thermal_zone0/temp",
                "/sys/class/thermal/thermal_zone1/temp",
                "/sys/class/hwmon/hwmon0/temp1_input",
                "/sys/class/hwmon/hwmon1/temp1_input",
                "/proc/stat", // CPU温度有时在这里
                "/sys/devices/virtual/thermal/thermal_zone0/temp"
            )
            
            for (tempFile in tempSources) {
                try {
                    val file = File(tempFile)
                    if (file.exists()) {
                        val tempStr = file.readText().trim()
                        val temp = tempStr.toFloatOrNull()
                        
                        if (temp != null) {
                            // 温度可能是摄氏度*1000的格式
                            return if (temp > 1000) temp / 1000f else temp
                        }
                    }
                } catch (e: Exception) {
                    continue
                }
            }
            
            // 如果都读取不到，返回一个合理的默认值
            35f // 35°C
        } catch (e: Exception) {
            35f
        }
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        stopMonitoring()
    }
}
