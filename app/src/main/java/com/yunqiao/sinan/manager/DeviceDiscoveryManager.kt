package com.yunqiao.sinan.manager

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import androidx.core.app.ActivityCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.net.*
import java.util.concurrent.ConcurrentHashMap

/**
 * 蓝牙权限状态
 */
enum class BluetoothPermissionStatus {
    UNKNOWN,
    GRANTED,
    DENIED,
    PARTIAL_LEGACY, // 仅有传统蓝牙权限
    PARTIAL_NEW     // 仅有部分新权限
}

/**
 * 设备发现管理器 - 集成现有的多协议设备发现功能
 * 基于 YunQiaoSiNan/src/seamless_switching/device_discovery/discovery_manager.py
 */
data class DeviceCapabilities(
    val computePower: Int = 50,
    val memoryCapacity: Long = 4096L,
    val storageCapacity: Long = 32768L,
    val networkBandwidth: Int = 100,
    val batteryLevel: Int? = null,
    val supportedCodecs: List<String> = listOf("h264", "aac"),
    val aiAcceleration: Boolean = false,
    val displayCapability: Map<String, Any>? = null,
    val audioCapability: Map<String, Any>? = null
)

data class DiscoveredDevice(
    val deviceId: String,
    val deviceName: String,
    val deviceType: String,
    val ipAddress: String,
    val port: Int = 0,
    val capabilities: DeviceCapabilities,
    val discoveryProtocol: String,
    val lastSeen: Long = System.currentTimeMillis(),
    val trustLevel: Float = 0.5f,
    val connectionQuality: Float = 0.8f,
    val rssi: Int = 0
) {
    fun isExpired(timeoutMs: Long = 300000L): Boolean {
        return System.currentTimeMillis() - lastSeen > timeoutMs
    }
}

class DeviceDiscoveryManager(private val context: Context) {
    
    private val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
    
    private val _discoveredDevices = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
    val discoveredDevices: StateFlow<List<DiscoveredDevice>> = _discoveredDevices.asStateFlow()
    
    // 权限状态管理
    private val _bluetoothPermissionStatus = MutableStateFlow(BluetoothPermissionStatus.UNKNOWN)
    val bluetoothPermissionStatus: StateFlow<BluetoothPermissionStatus> = _bluetoothPermissionStatus.asStateFlow()
    
    private val _locationPermissionGranted = MutableStateFlow(false)
    val locationPermissionGranted: StateFlow<Boolean> = _locationPermissionGranted.asStateFlow()
    
    private var isInitialized = false
    private val deviceMap = ConcurrentHashMap<String, DiscoveredDevice>()
    private var discoveryJob: Job? = null
    private var isDiscovering = false
    
    // 蓝牙扫描相关
    private var bluetoothLeScanner: BluetoothLeScanner? = null
    private var bluetoothScanCallback: ScanCallback? = null
    
    // WiFi P2P相关
    private var wifiP2pManager: WifiP2pManager? = null
    private var wifiP2pChannel: WifiP2pManager.Channel? = null
    
    init {
        // 仅进行权限检查，不自动初始化组件
        checkAllPermissions()
    }
    
    /**
     * 检查所有权限
     */
    private fun checkAllPermissions() {
        checkBluetoothPermissions()
        checkLocationPermissions()
    }
    
    /**
     * 检查蓝牙权限 - 支持Android 12+新权限模型
     */
    private fun checkBluetoothPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+ 新蓝牙权限模型
            val scanPermission = ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_SCAN
            ) == PackageManager.PERMISSION_GRANTED
            
            val connectPermission = ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            
            val advertisePermission = ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_ADVERTISE
            ) == PackageManager.PERMISSION_GRANTED
            
            _bluetoothPermissionStatus.value = when {
                scanPermission && connectPermission && advertisePermission -> BluetoothPermissionStatus.GRANTED
                scanPermission || connectPermission -> BluetoothPermissionStatus.PARTIAL_NEW
                else -> BluetoothPermissionStatus.DENIED
            }
        } else {
            // Android 12以下传统蓝牙权限模型
            val bluetoothPermission = ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH
            ) == PackageManager.PERMISSION_GRANTED
            
            val bluetoothAdminPermission = ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_ADMIN
            ) == PackageManager.PERMISSION_GRANTED
            
            _bluetoothPermissionStatus.value = when {
                bluetoothPermission && bluetoothAdminPermission -> BluetoothPermissionStatus.GRANTED
                bluetoothPermission || bluetoothAdminPermission -> BluetoothPermissionStatus.PARTIAL_LEGACY
                else -> BluetoothPermissionStatus.DENIED
            }
        }
    }
    
    /**
     * 检查位置权限
     */
    private fun checkLocationPermissions() {
        val fineLocationPermission = ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        
        val coarseLocationPermission = ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        
        _locationPermissionGranted.value = fineLocationPermission || coarseLocationPermission
    }
    
    /**
     * 安全初始化 - 在权限验证后调用
     */
    fun initializeWithPermissions(): Boolean {
        if (isInitialized) return true
        
        checkAllPermissions()
        
        // 只有在权限充足的情况下才初始化组件
        return when {
            _bluetoothPermissionStatus.value == BluetoothPermissionStatus.GRANTED && 
            _locationPermissionGranted.value -> {
                initializeDiscoveryComponents()
                isInitialized = true
                true
            }
            _bluetoothPermissionStatus.value in listOf(
                BluetoothPermissionStatus.PARTIAL_LEGACY,
                BluetoothPermissionStatus.PARTIAL_NEW
            ) -> {
                // 部分权限，初始化可用的组件
                initializeDiscoveryComponentsPartial()
                isInitialized = true
                false
            }
            else -> {
                // 权限不足，仅初始化网络发现
                initializeNetworkDiscoveryOnly()
                isInitialized = true
                false
            }
        }
    }
    
    /**
     * 重新检查权限并初始化
     */
    fun recheckPermissionsAndInitialize(): Boolean {
        isInitialized = false
        return initializeWithPermissions()
    }
    
    /**
     * 初始化发现组件 - 完整权限版本
     */
    private fun initializeDiscoveryComponents() {
        try {
            // 初始化蓝牙LE扫描器
            if (bluetoothAdapter?.isEnabled == true) {
                bluetoothLeScanner = bluetoothAdapter.bluetoothLeScanner
            }
            
            // 初始化WiFi P2P
            wifiP2pManager = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
            wifiP2pChannel = wifiP2pManager?.initialize(context, context.mainLooper, null)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 部分初始化 - 仅初始化有权限的组件
     */
    private fun initializeDiscoveryComponentsPartial() {
        try {
            // 根据权限状态决定初始化的组件
            when (_bluetoothPermissionStatus.value) {
                BluetoothPermissionStatus.PARTIAL_LEGACY -> {
                    // 仅初始化传统蓝牙，不初始化BLE
                    if (bluetoothAdapter?.isEnabled == true) {
                        // 可以做基本的蓝牙操作，但不能扫描
                    }
                }
                BluetoothPermissionStatus.PARTIAL_NEW -> {
                    // 初始化部分新权限支持的组件
                    if (bluetoothAdapter?.isEnabled == true) {
                        bluetoothLeScanner = bluetoothAdapter.bluetoothLeScanner
                    }
                }
                else -> {}
            }
            
            // WiFi P2P不需要特殊蓝牙权限
            if (_locationPermissionGranted.value) {
                wifiP2pManager = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
                wifiP2pChannel = wifiP2pManager?.initialize(context, context.mainLooper, null)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 仅初始化网络发现 - 没有蓝牙权限时的降级方案
     */
    private fun initializeNetworkDiscoveryOnly() {
        try {
            // 仅初始化WiFi相关组件，不初始化蓝牙
            // WiFi扫描不需要特殊权限
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 开始设备发现
     */
    fun startDiscovery() {
        if (isDiscovering) return
        
        isDiscovering = true
        discoveryJob = CoroutineScope(Dispatchers.IO).launch {
            while (isDiscovering) {
                try {
                    // 并行执行多种发现协议
                    launch { discoverNetworkDevices() }
                    launch { discoverBluetoothDevices() }
                    launch { discoverWifiP2pDevices() }
                    launch { discoverUPnPDevices() }
                    
                    // 清理过期设备
                    cleanupExpiredDevices()
                    
                    delay(10000) // 每10秒扫描一次
                } catch (e: Exception) {
                    e.printStackTrace()
                    delay(5000)
                }
            }
        }
    }
    
    /**
     * 停止设备发现
     */
    fun stopDiscovery() {
        isDiscovering = false
        discoveryJob?.cancel()
        
        // 停止蓝牙扫描
        stopBluetoothScan()
    }
    
    /**
     * 网络设备发现 - 扫描局域网
     */
    private suspend fun discoverNetworkDevices() = withContext(Dispatchers.IO) {
        try {
            val wifiInfo = wifiManager.connectionInfo
            val dhcpInfo = wifiManager.dhcpInfo
            
            // 获取网络信息
            val gateway = intToIp(dhcpInfo.gateway)
            val subnet = getSubnetFromGateway(gateway)
            
            // 扫描局域网IP范围
            val jobs = mutableListOf<Job>()
            for (i in 1..254) {
                jobs.add(launch {
                    val ip = "$subnet.$i"
                    if (isHostReachable(ip)) {
                        val deviceInfo = probeDevice(ip)
                        if (deviceInfo != null) {
                            addDiscoveredDevice(deviceInfo)
                        }
                    }
                })
            }
            jobs.joinAll()
            
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 蓝牙设备发现
     */
    private suspend fun discoverBluetoothDevices() = withContext(Dispatchers.Main) {
        if (!hasBluetoothPermission()) return@withContext
        
        try {
            // 经典蓝牙发现
            discoverClassicBluetooth()
            
            // BLE设备发现
            discoverBLEDevices()
            
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 经典蓝牙发现
     */
    private fun discoverClassicBluetooth() {
        if (bluetoothAdapter?.isEnabled != true) return
        
        val bluetoothReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        if (ActivityCompat.checkSelfPermission(
                                context!!,
                                Manifest.permission.BLUETOOTH_CONNECT
                            ) != PackageManager.PERMISSION_GRANTED
                        ) {
                            return
                        }
                        val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                        val rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE).toInt()
                        
                        device?.let {
                            val discoveredDevice = DiscoveredDevice(
                                deviceId = it.address,
                                deviceName = it.name ?: "Unknown Bluetooth Device",
                                deviceType = "bluetooth",
                                ipAddress = "",
                                capabilities = estimateBluetoothCapabilities(it),
                                discoveryProtocol = "bluetooth_classic",
                                rssi = rssi
                            )
                            addDiscoveredDevice(discoveredDevice)
                        }
                    }
                }
            }
        }
        
        val filter = IntentFilter(BluetoothDevice.ACTION_FOUND)
        context.registerReceiver(bluetoothReceiver, filter)
        
        if (ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_SCAN
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            bluetoothAdapter.startDiscovery()
        }
    }
    
    /**
     * BLE设备发现
     */
    private fun discoverBLEDevices() {
        if (bluetoothLeScanner == null || !hasBluetoothPermission()) return
        
        bluetoothScanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult?) {
                result?.let { scanResult ->
                    if (ActivityCompat.checkSelfPermission(
                            context,
                            Manifest.permission.BLUETOOTH_CONNECT
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        return
                    }
                    
                    val device = scanResult.device
                    val discoveredDevice = DiscoveredDevice(
                        deviceId = device.address,
                        deviceName = device.name ?: "Unknown BLE Device",
                        deviceType = "ble",
                        ipAddress = "",
                        capabilities = estimateBLECapabilities(scanResult),
                        discoveryProtocol = "bluetooth_le",
                        rssi = scanResult.rssi
                    )
                    addDiscoveredDevice(discoveredDevice)
                }
            }
            
            override fun onScanFailed(errorCode: Int) {
                super.onScanFailed(errorCode)
            }
        }
        
        if (ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_SCAN
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            bluetoothLeScanner?.startScan(bluetoothScanCallback)
        }
    }
    
    /**
     * WiFi P2P设备发现
     */
    private suspend fun discoverWifiP2pDevices() = withContext(Dispatchers.Main) {
        if (wifiP2pManager == null || wifiP2pChannel == null) return@withContext
        
        try {
            if (ActivityCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_FINE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                wifiP2pManager?.discoverPeers(wifiP2pChannel, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        // 发现成功
                    }
                    
                    override fun onFailure(reason: Int) {
                        // 发现失败
                    }
                })
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * UPnP设备发现
     */
    private suspend fun discoverUPnPDevices() = withContext(Dispatchers.IO) {
        try {
            val multicastAddress = InetAddress.getByName("239.255.255.250")
            val port = 1900
            val message = "M-SEARCH * HTTP/1.1\r\n" +
                    "HOST: 239.255.255.250:1900\r\n" +
                    "MAN: \"ssdp:discover\"\r\n" +
                    "ST: upnp:rootdevice\r\n" +
                    "MX: 3\r\n\r\n"
            
            val socket = DatagramSocket()
            val packet = DatagramPacket(
                message.toByteArray(),
                message.length,
                multicastAddress,
                port
            )
            
            socket.send(packet)
            
            // 监听响应
            val buffer = ByteArray(1024)
            val responsePacket = DatagramPacket(buffer, buffer.size)
            
            socket.soTimeout = 3000 // 3秒超时
            
            try {
                while (true) {
                    socket.receive(responsePacket)
                    val response = String(responsePacket.data, 0, responsePacket.length)
                    parseUPnPResponse(response, responsePacket.address.hostAddress)
                }
            } catch (e: SocketTimeoutException) {
                // 超时，正常结束
            }
            
            socket.close()
            
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 探测设备信息
     */
    private suspend fun probeDevice(ip: String): DiscoveredDevice? = withContext(Dispatchers.IO) {
        try {
            // 尝试常见端口
            val commonPorts = listOf(22, 80, 443, 8080, 5000, 3000)
            var openPort = 0
            
            for (port in commonPorts) {
                if (isPortOpen(ip, port, 1000)) {
                    openPort = port
                    break
                }
            }
            
            if (openPort > 0) {
                // 尝试获取设备信息
                val deviceName = getDeviceNameFromIP(ip)
                val capabilities = estimateNetworkDeviceCapabilities(ip, openPort)
                
                DiscoveredDevice(
                    deviceId = ip,
                    deviceName = deviceName,
                    deviceType = "network",
                    ipAddress = ip,
                    port = openPort,
                    capabilities = capabilities,
                    discoveryProtocol = "network_scan"
                )
            } else {
                null
            }
        } catch (e: Exception) {
            null
        }
    }
    
    /**
     * 检查主机是否可达
     */
    private suspend fun isHostReachable(ip: String): Boolean = withContext(Dispatchers.IO) {
        try {
            val address = InetAddress.getByName(ip)
            address.isReachable(2000) // 2秒超时
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * 检查端口是否开放
     */
    private suspend fun isPortOpen(ip: String, port: Int, timeoutMs: Int): Boolean = withContext(Dispatchers.IO) {
        try {
            val socket = Socket()
            socket.connect(InetSocketAddress(ip, port), timeoutMs)
            socket.close()
            true
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * 从IP获取设备名称
     */
    private suspend fun getDeviceNameFromIP(ip: String): String = withContext(Dispatchers.IO) {
        try {
            val address = InetAddress.getByName(ip)
            address.hostName ?: "Network Device ($ip)"
        } catch (e: Exception) {
            "Network Device ($ip)"
        }
    }
    
    /**
     * 估算网络设备能力
     */
    private fun estimateNetworkDeviceCapabilities(ip: String, port: Int): DeviceCapabilities {
        // 基于端口推断设备类型和能力
        val computePower = when (port) {
            22 -> 70  // SSH服务器，可能是电脑
            80, 443, 8080 -> 60  // Web服务器
            else -> 50
        }
        
        return DeviceCapabilities(
            computePower = computePower,
            memoryCapacity = 8192L,
            storageCapacity = 65536L,
            networkBandwidth = 100,
            supportedCodecs = listOf("h264", "h265", "aac", "opus"),
            aiAcceleration = false
        )
    }
    
    /**
     * 估算蓝牙设备能力
     */
    private fun estimateBluetoothCapabilities(device: BluetoothDevice): DeviceCapabilities {
        // 基于蓝牙设备类型估算能力
        val deviceClass = device.bluetoothClass?.majorDeviceClass
        
        val computePower = when (deviceClass) {
            android.bluetooth.BluetoothClass.Device.Major.COMPUTER -> 80
            android.bluetooth.BluetoothClass.Device.Major.PHONE -> 60
            android.bluetooth.BluetoothClass.Device.Major.AUDIO_VIDEO -> 40
            else -> 30
        }
        
        return DeviceCapabilities(
            computePower = computePower,
            memoryCapacity = 4096L,
            storageCapacity = 32768L,
            networkBandwidth = 50,
            supportedCodecs = listOf("aac", "sbc"),
            aiAcceleration = false
        )
    }
    
    /**
     * 估算BLE设备能力
     */
    private fun estimateBLECapabilities(scanResult: ScanResult): DeviceCapabilities {
        return DeviceCapabilities(
            computePower = 20,
            memoryCapacity = 512L,
            storageCapacity = 4096L,
            networkBandwidth = 10,
            supportedCodecs = listOf("aac"),
            aiAcceleration = false
        )
    }
    
    /**
     * 解析UPnP响应
     */
    private fun parseUPnPResponse(response: String, ip: String) {
        try {
            // 简单解析UPnP响应
            val lines = response.split("\r\n")
            var deviceType = "upnp"
            var deviceName = "UPnP Device"
            
            for (line in lines) {
                when {
                    line.startsWith("SERVER:") -> {
                        deviceName = line.substring(7).trim()
                    }
                    line.startsWith("ST:") -> {
                        deviceType = line.substring(3).trim()
                    }
                }
            }
            
            val device = DiscoveredDevice(
                deviceId = ip,
                deviceName = deviceName,
                deviceType = deviceType,
                ipAddress = ip,
                capabilities = DeviceCapabilities(
                    computePower = 50,
                    memoryCapacity = 2048L,
                    storageCapacity = 16384L,
                    networkBandwidth = 100
                ),
                discoveryProtocol = "upnp"
            )
            
            addDiscoveredDevice(device)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 添加发现的设备
     */
    private fun addDiscoveredDevice(device: DiscoveredDevice) {
        deviceMap[device.deviceId] = device
        updateDeviceList()
    }
    
    /**
     * 更新设备列表
     */
    private fun updateDeviceList() {
        _discoveredDevices.value = deviceMap.values.toList().sortedByDescending { it.lastSeen }
    }
    
    /**
     * 清理过期设备
     */
    private fun cleanupExpiredDevices() {
        val iterator = deviceMap.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (entry.value.isExpired()) {
                iterator.remove()
            }
        }
        updateDeviceList()
    }
    
    /**
     * 停止蓝牙扫描
     */
    private fun stopBluetoothScan() {
        bluetoothScanCallback?.let { callback ->
            if (ActivityCompat.checkSelfPermission(
                    context,
                    Manifest.permission.BLUETOOTH_SCAN
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                bluetoothLeScanner?.stopScan(callback)
            }
        }
        bluetoothScanCallback = null
    }
    
    /**
     * 检查蓝牙权限
     */
    private fun hasBluetoothPermission(): Boolean {
        return ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.BLUETOOTH_SCAN
        ) == PackageManager.PERMISSION_GRANTED
    }
    
    /**
     * 工具函数
     */
    private fun intToIp(ip: Int): String {
        return String.format(
            "%d.%d.%d.%d",
            ip and 0xff,
            ip shr 8 and 0xff,
            ip shr 16 and 0xff,
            ip shr 24 and 0xff
        )
    }
    
    private fun getSubnetFromGateway(gateway: String): String {
        val parts = gateway.split(".")
        return "${parts[0]}.${parts[1]}.${parts[2]}"
    }
}