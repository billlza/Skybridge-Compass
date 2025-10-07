package com.yunqiao.sinan.operationshub.service

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import com.yunqiao.sinan.manager.BridgeDevicePlatform
import com.yunqiao.sinan.manager.BridgeTransportHint
import com.yunqiao.sinan.manager.CrossPlatformCompatibilityManager
import com.yunqiao.sinan.operationshub.model.DeviceType
import com.yunqiao.sinan.operationshub.model.DiscoveredDevice
import com.yunqiao.sinan.operationshub.model.DiscoveryStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.concurrent.TimeUnit

/**
 * 设备发现服务
 */
class DeviceDiscoveryService(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _discoveredDevices = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
    val discoveredDevices: StateFlow<List<DiscoveredDevice>> = _discoveredDevices.asStateFlow()
    
    private val _discoveryStatus = MutableStateFlow(DiscoveryStatus.IDLE)
    val discoveryStatus: StateFlow<DiscoveryStatus> = _discoveryStatus.asStateFlow()
    
    private val deviceMap = mutableMapOf<String, DiscoveredDevice>()
    private val compatibilityManager = CrossPlatformCompatibilityManager()
    private var isScanning = false
    
    /**
     * 初始化设备发现服务
     */
    suspend fun initialize(): Boolean {
        return try {
            // 获取本地网络信息
            val localIp = getLocalIpAddress()
            if (localIp.isNotEmpty()) {
                // 开始真实的网络扫描
                startNetworkScan()
                true
            } else {
                _discoveryStatus.value = DiscoveryStatus.ERROR
                false
            }
        } catch (e: Exception) {
            _discoveryStatus.value = DiscoveryStatus.ERROR
            false
        }
    }
    
    /**
     * 开始扫描设备
     */
    suspend fun startDiscovery(): Boolean {
        return try {
            if (isScanning) return true
            
            isScanning = true
            _discoveryStatus.value = DiscoveryStatus.SCANNING
            
            scope.launch {
                performDeviceDiscovery()
            }
            
            true
        } catch (e: Exception) {
            _discoveryStatus.value = DiscoveryStatus.ERROR
            false
        }
    }
    
    /**
     * 停止扫描设备
     */
    fun stopDiscovery() {
        isScanning = false
        _discoveryStatus.value = DiscoveryStatus.IDLE
    }
    
    /**
     * 手动添加设备
     */
    fun addDevice(device: DiscoveredDevice) {
        deviceMap[device.deviceId] = device
        updateDeviceList()
    }
    
    /**
     * 移除设备
     */
    fun removeDevice(deviceId: String) {
        deviceMap.remove(deviceId)
        updateDeviceList()
    }
    
    /**
     * 获取指定设备信息
     */
    fun getDevice(deviceId: String): DiscoveredDevice? {
        return deviceMap[deviceId]
    }
    
    /**
     * 根据类型筛选设备
     */
    fun getDevicesByType(deviceType: DeviceType): List<DiscoveredDevice> {
        return deviceMap.values.filter { it.deviceType == deviceType }
    }
    
    /**
     * 获取在线设备
     */
    fun getOnlineDevices(): List<DiscoveredDevice> {
        return deviceMap.values.filter { it.isOnline }
    }
    
    /**
     * 刷新设备状态
     */
    suspend fun refreshDeviceStatus(deviceId: String): Boolean {
        return try {
            deviceMap[deviceId]?.let { device ->
                // 真实的网络状态检测
                val isOnline = isHostReachable(device.ipAddress)
                
                deviceMap[deviceId] = device.copy(
                    isOnline = isOnline,
                    discoveredTime = System.currentTimeMillis()
                )
                
                updateDeviceList()
                true
            } ?: false
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * 执行设备发现
     */
    private suspend fun performDeviceDiscovery() {
        try {
            _discoveryStatus.value = DiscoveryStatus.SCANNING
            
            // 获取本地网络信息
            val localIp = getLocalIpAddress()
            if (localIp.isEmpty()) {
                _discoveryStatus.value = DiscoveryStatus.ERROR
                return
            }
            
            // 解析网络段
            val networkPrefix = localIp.substringBeforeLast(".") + "."
            
            // 扫描网络段中的设备 (1-254)
            for (i in 1..254) {
                if (!isScanning) break
                
                val targetIp = "$networkPrefix$i"
                
                // 使用协程并发扫描
                scope.launch {
                    scanDevice(targetIp)
                }
                
                // 每10个IP后稍作延迟
                if (i % 10 == 0) {
                    delay(100)
                }
            }
            
            // 等待扫描完成
            delay(5000)
            
            _discoveryStatus.value = DiscoveryStatus.COMPLETED
            isScanning = false
            
        } catch (e: Exception) {
            _discoveryStatus.value = DiscoveryStatus.ERROR
            isScanning = false
        }
    }
    
    /**
     * 开始网络扫描
     */
    private fun startNetworkScan() {
        scope.launch {
            while (true) {
                delay(60000) // 每60秒扫描一次
                if (!isScanning) {
                    startDiscovery()
                }
            }
        }
    }
    
    /**
     * 扫描单个设备
     */
    private suspend fun scanDevice(ipAddress: String) {
        withContext(Dispatchers.IO) {
            try {
                if (isHostReachable(ipAddress)) {
                    val device = createDeviceFromIp(ipAddress)
                    if (device != null && !deviceMap.containsKey(device.deviceId)) {
                        deviceMap[device.deviceId] = device
                        updateDeviceList()
                    }
                }
            } catch (e: Exception) {
                // 扫描失败，忽略此IP
            }
        }
    }
    
    /**
     * 检查主机是否可达
     */
    private suspend fun isHostReachable(ipAddress: String): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val addr = InetAddress.getByName(ipAddress)
                addr.isReachable(1000) // 1秒超时
            } catch (e: Exception) {
                false
            }
        }
    }
    
    /**
     * 从IP地址创建设备对象
     */
    private fun createDeviceFromIp(ipAddress: String): DiscoveredDevice? {
        val deviceId = "device_$ipAddress"
        val baseType = detectDeviceType(ipAddress)
        val deviceName = getDeviceName(ipAddress, baseType)
        if (compatibilityManager.shouldExclude(deviceName, baseType.name)) {
            return null
        }
        val platform = compatibilityManager.resolvePlatform(deviceName, baseType.name)
        val resolvedType = if (baseType == DeviceType.UNKNOWN) mapPlatformToDeviceType(platform) else baseType
        val transports = compatibilityManager.transportsFor(platform).ifEmpty {
            setOf(BridgeTransportHint.UniversalBridge)
        }

        return DiscoveredDevice(
            deviceId = deviceId,
            deviceName = deviceName,
            ipAddress = ipAddress,
            deviceType = resolvedType,
            macAddress = getMacAddress(ipAddress),
            isOnline = true,
            signalStrength = -50, // 默认信号强度
            description = "网络发现的设备",
            availableServices = getAvailableServices(resolvedType),
            platform = platform,
            compatibilityRemark = compatibilityManager.remarkFor(platform),
            supportedTransports = transports
        )
    }
    
    /**
     * 检测设备类型
     */
    private fun detectDeviceType(ipAddress: String): DeviceType {
        return try {
            // 基于端口扫描等方式检测设备类型
            // 这里简化处理，实际可以通过开放端口、服务等进行更精确识别
            DeviceType.UNKNOWN
        } catch (e: Exception) {
            DeviceType.UNKNOWN
        }
    }
    
    /**
     * 获取设备名称
     */
    private fun getDeviceName(ipAddress: String, deviceType: DeviceType): String {
        return try {
            val addr = InetAddress.getByName(ipAddress)
            addr.hostName ?: "Device at $ipAddress"
        } catch (e: Exception) {
            "Device at $ipAddress"
        }
    }
    
    /**
     * 获取MAC地址
     */
    private fun getMacAddress(ipAddress: String): String {
        return try {
            // 在Android中，由于安全限制，获取远程MAC地址比较困难
            // 这里返回一个占位符
            "未知MAC地址"
        } catch (e: Exception) {
            "未知MAC地址"
        }
    }
    
    /**
     * 获取本地IP地址
     */
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
            ""
        } catch (e: Exception) {
            ""
        }
    }
    
    /**
     * 生成可用服务列表
     */
    private fun getAvailableServices(deviceType: DeviceType): List<String> {
        return when (deviceType) {
            DeviceType.ANDROID -> listOf("ADB", "SCRCPY")
            DeviceType.IOS -> listOf("iTunes", "AirPlay")
            DeviceType.WINDOWS -> listOf("RDP", "SSH", "SMB")
            DeviceType.MAC -> listOf("VNC", "SSH", "AFP")
            DeviceType.LINUX -> listOf("SSH", "VNC", "FTP")
            DeviceType.SMART_TV -> listOf("DLNA", "Chromecast")
            DeviceType.IOT_DEVICE -> listOf("HTTP", "MQTT")
            DeviceType.UNKNOWN -> emptyList()
        }
    }

    private fun mapPlatformToDeviceType(platform: BridgeDevicePlatform): DeviceType {
        return when (platform) {
            BridgeDevicePlatform.ANDROID -> DeviceType.ANDROID
            BridgeDevicePlatform.IOS, BridgeDevicePlatform.IPADOS -> DeviceType.IOS
            BridgeDevicePlatform.MAC -> DeviceType.MAC
            BridgeDevicePlatform.WINDOWS -> DeviceType.WINDOWS
            BridgeDevicePlatform.LINUX -> DeviceType.LINUX
            BridgeDevicePlatform.CHROME_OS -> DeviceType.SMART_TV
            BridgeDevicePlatform.UNKNOWN -> DeviceType.UNKNOWN
        }
    }
    
    /**
     * 更新设备列表
     */
    private fun updateDeviceList() {
        _discoveredDevices.value = deviceMap.values.sortedByDescending { it.discoveredTime }
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        stopDiscovery()
        deviceMap.clear()
        _discoveredDevices.value = emptyList()
    }
}
