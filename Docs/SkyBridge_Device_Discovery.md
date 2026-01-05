# SkyBridge 云桥司南 - 跨平台设备发现指南

> 版本: 1.0.0 | 更新日期: 2025-12-13

本文档详细说明如何确保不同平台的云桥司南 APP 能够互相发现。

## 1. 设备发现原理

### 1.1 mDNS/DNS-SD 协议

云桥司南使用 **mDNS (Multicast DNS)** 和 **DNS-SD (DNS Service Discovery)** 协议进行局域网设备发现。

```
┌─────────────────────────────────────────────────────────────┐
│                    局域网 (224.0.0.251:5353)                 │
└─────────────────────────────────────────────────────────────┘
      ▲           ▲           ▲           ▲           ▲
      │           │           │           │           │
   mDNS        mDNS        mDNS        mDNS        mDNS
      │           │           │           │           │
  ┌───┴───┐  ┌───┴───┐  ┌───┴───┐  ┌───┴───┐  ┌───┴───┐
  │ macOS │  │Windows│  │Android│  │ Linux │  │  iOS  │
  └───────┘  └───────┘  └───────┘  └───────┘  └───────┘
```

### 1.2 服务注册流程

```
1. 应用启动
2. 生成设备标识 (deviceId, pubKeyFP, uniqueId)
3. 构建 TXT 记录
4. 注册 Bonjour/mDNS 服务
5. 监听其他设备的服务广播
6. 解析发现的设备信息
```


---

## 2. 服务注册规范

### 2.1 服务类型

```
服务类型: _skybridge._tcp
域: local.
完整名称: <设备名>._skybridge._tcp.local.
```

### 2.2 TXT 记录规范

#### 必需字段

| 字段 | 格式 | 示例 | 说明 |
|------|------|------|------|
| `deviceId` | UUID v4 | `550e8400-e29b-41d4-a716-446655440000` | 设备唯一标识，首次安装时生成并持久化 |
| `pubKeyFP` | hex 小写 | `a1b2c3d4e5f6789012345678` | 设备公钥的 SHA-256 指纹前 24 字符 |
| `uniqueId` | 字符串 | `instance-001` | 当前运行实例的唯一 ID |

#### 可选字段

| 字段 | 格式 | 示例 | 说明 |
|------|------|------|------|
| `platform` | 枚举 | `macos` | 平台类型 |
| `version` | semver | `1.0.0` | 协议版本 |
| `capabilities` | 逗号分隔 | `remote_desktop,file_transfer` | 设备能力 |
| `name` | UTF-8 | `MacBook Pro` | 设备显示名称 |

### 2.3 TXT 记录编码

TXT 记录使用标准 DNS TXT 格式：

```
┌────────┬─────────────────────────────────────────┐
│ 长度   │ 内容 (key=value)                        │
│ (1B)   │                                         │
├────────┼─────────────────────────────────────────┤
│ 0x2C   │ deviceId=550e8400-e29b-41d4-a716-...    │
├────────┼─────────────────────────────────────────┤
│ 0x20   │ pubKeyFP=a1b2c3d4e5f6789012345678       │
├────────┼─────────────────────────────────────────┤
│ 0x14   │ uniqueId=instance-001                   │
├────────┼─────────────────────────────────────────┤
│ 0x0E   │ platform=macos                          │
└────────┴─────────────────────────────────────────┘
```

**注意**: 每个 key=value 对的总长度不能超过 255 字节。

---

## 3. 平台实现详解

### 3.1 macOS / iOS (Network.framework)

```swift
import Network

class SkyBridgeDiscovery {
    private var listener: NWListener?
    private var browser: NWBrowser?
    
    // 注册服务
    func registerService(name: String, txtRecord: [String: String]) throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        listener = try NWListener(using: parameters)
        listener?.service = NWListener.Service(
            name: name,
            type: "_skybridge._tcp"
        )
        
        // 设置 TXT 记录
        let txtData = txtRecord.reduce(into: Data()) { data, pair in
            let entry = "\(pair.key)=\(pair.value)"
            if let entryData = entry.data(using: .utf8), entryData.count < 256 {
                data.append(UInt8(entryData.count))
                data.append(entryData)
            }
        }
        
        listener?.serviceRegistrationUpdateHandler = { change in
            switch change {
            case .add(let endpoint):
                print("服务已注册: \(endpoint)")
            case .remove(let endpoint):
                print("服务已移除: \(endpoint)")
            @unknown default:
                break
            }
        }
        
        listener?.start(queue: .global(qos: .utility))
    }
    
    // 发现服务
    func startDiscovery(onFound: @escaping (NWBrowser.Result) -> Void) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        browser = NWBrowser(
            for: .bonjour(type: "_skybridge._tcp", domain: nil),
            using: parameters
        )
        
        browser?.browseResultsChangedHandler = { results, changes in
            for result in results {
                onFound(result)
            }
        }
        
        browser?.start(queue: .main)
    }
}
```


### 3.2 Android (NsdManager) - 完整实现

#### 3.2.1 项目配置

**build.gradle.kts (Module)**
```kotlin
android {
    namespace = "com.skybridge.compass"
    compileSdk = 34
    
    defaultConfig {
        minSdk = 24  // NsdManager 需要 API 16+，TXT 记录需要 API 21+
        targetSdk = 34
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
}
```

**AndroidManifest.xml**
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- 网络权限 -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
</manifest>
```

#### 3.2.2 数据模型

```kotlin
package com.skybridge.compass.discovery

import java.util.UUID

/**
 * 设备能力枚举 - 与 Swift 端 SBDeviceCapabilities 对应
 */
object DeviceCapabilities {
    const val REMOTE_DESKTOP = "remote_desktop"
    const val FILE_TRANSFER = "file_transfer"
    const val SCREEN_SHARING = "screen_sharing"
    const val INPUT_INJECTION = "input_injection"
    const val SYSTEM_CONTROL = "system_control"
    const val PQC_ENCRYPTION = "pqc_encryption"
    const val HYBRID_ENCRYPTION = "hybrid_encryption"
    const val AUDIO_TRANSFER = "audio_transfer"
    const val CLIPBOARD_SYNC = "clipboard_sync"
    
    /** Android 端默认支持的能力 */
    val DEFAULT = listOf(
        FILE_TRANSFER,
        SCREEN_SHARING,
        CLIPBOARD_SYNC
    )
}

/**
 * 协议版本 - 与 Swift 端 SBProtocolVersion 对应
 */
data class ProtocolVersion(
    val major: Int,
    val minor: Int,
    val patch: Int
) {
    companion object {
        val CURRENT = ProtocolVersion(1, 0, 0)
        val MINIMUM_COMPATIBLE = ProtocolVersion(1, 0, 0)
    }
    
    fun isCompatible(other: ProtocolVersion): Boolean = major == other.major
    
    override fun toString(): String = "$major.$minor.$patch"
}

/**
 * 发现的设备信息
 */
data class DiscoveredDevice(
    val serviceName: String,
    val host: String,
    val port: Int,
    val deviceId: String,
    val pubKeyFP: String,
    val uniqueId: String,
    val platform: String?,
    val version: String?,
    val capabilities: List<String>,
    val displayName: String?,
    val lastSeen: Long = System.currentTimeMillis()
) {
    /** 检查设备是否支持指定能力 */
    fun hasCapability(capability: String): Boolean = capabilities.contains(capability)
    
    /** 获取协商后的共同能力 */
    fun negotiateCapabilities(localCapabilities: List<String>): List<String> {
        return capabilities.intersect(localCapabilities.toSet()).toList()
    }
}

/**
 * TXT 记录构建器 - 与 Swift 端 BonjourTXTRecordBuilder 对应
 */
data class TXTRecordBuilder(
    val deviceId: String,
    val pubKeyFP: String,
    val uniqueId: String,
    val platform: String = "android",
    val version: String = ProtocolVersion.CURRENT.toString(),
    val capabilities: List<String> = DeviceCapabilities.DEFAULT,
    val name: String? = null
) {
    fun build(): Map<String, String> {
        val record = mutableMapOf(
            "deviceId" to deviceId,
            "pubKeyFP" to pubKeyFP,
            "uniqueId" to uniqueId,
            "platform" to platform,
            "version" to version
        )
        
        if (capabilities.isNotEmpty()) {
            record["capabilities"] = capabilities.joinToString(",")
        }
        
        name?.let { record["name"] = it }
        
        return record
    }
    
    companion object {
        /** 验证 TXT 记录是否包含必需字段 */
        fun validate(record: Map<String, ByteArray>): Boolean {
            val requiredFields = listOf("deviceId", "pubKeyFP", "uniqueId")
            return requiredFields.all { field ->
                record[field]?.let { String(it).isNotEmpty() } ?: false
            }
        }
    }
}
```

#### 3.2.3 设备发现服务

```kotlin
package com.skybridge.compass.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * SkyBridge 设备发现服务
 * 
 * 使用 NsdManager 实现 mDNS/DNS-SD 服务发现
 * 与 macOS/iOS 端的 BonjourService 完全兼容
 */
class SkyBridgeDiscovery(private val context: Context) {
    
    companion object {
        private const val TAG = "SkyBridgeDiscovery"
        const val SERVICE_TYPE = "_skybridge._tcp."
        const val SERVICE_DOMAIN = "local."
        
        // 超时和重试配置
        const val DISCOVERY_TIMEOUT_MS = 10_000L
        const val RESOLVE_TIMEOUT_MS = 5_000L
        const val MAX_RETRIES = 3
        const val RETRY_DELAY_MS = 10_000L
        const val DEVICE_OFFLINE_THRESHOLD_MS = 5_000L
    }
    
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    
    // 组播锁 - 防止 WiFi 休眠时丢失 mDNS 包
    private var multicastLock: WifiManager.MulticastLock? = null
    
    // 状态
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var isRegistered = false
    private var isDiscovering = false
    private var retryCount = 0
    
    // 发现的设备缓存
    private val discoveredDevices = ConcurrentHashMap<String, DiscoveredDevice>()
    
    // 事件流
    private val _deviceEvents = MutableSharedFlow<DeviceEvent>(replay = 0, extraBufferCapacity = 64)
    val deviceEvents: SharedFlow<DeviceEvent> = _deviceEvents.asSharedFlow()
    
    private val _serviceState = MutableStateFlow<ServiceState>(ServiceState.Idle)
    val serviceState: StateFlow<ServiceState> = _serviceState.asStateFlow()
    
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // ==================== 服务注册 ====================
    
    /**
     * 注册 Bonjour 服务
     * 
     * @param serviceName 服务名称（建议格式：用户名-设备型号）
     * @param port 监听端口
     * @param txtRecord TXT 记录
     */
    fun registerService(
        serviceName: String,
        port: Int,
        txtRecord: TXTRecordBuilder
    ) {
        if (isRegistered) {
            Log.w(TAG, "服务已注册，先取消注册")
            unregisterService()
        }
        
        // 验证 TXT 记录
        val txtMap = txtRecord.build()
        
        val serviceInfo = NsdServiceInfo().apply {
            this.serviceName = serviceName
            this.serviceType = SERVICE_TYPE
            this.port = port
            
            // 设置 TXT 记录
            txtMap.forEach { (key, value) ->
                setAttribute(key, value)
            }
        }
        
        registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "✅ 服务已注册: ${info.serviceName}")
                isRegistered = true
                retryCount = 0
                _serviceState.value = ServiceState.Registered(info.serviceName, port)
            }
            
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "❌ 注册失败: errorCode=$errorCode")
                isRegistered = false
                _serviceState.value = ServiceState.Error("注册失败: $errorCode")
                
                // 重试逻辑
                if (retryCount < MAX_RETRIES) {
                    retryCount++
                    Log.i(TAG, "🔄 将在 ${RETRY_DELAY_MS}ms 后重试 (第 $retryCount 次)")
                    scope.launch {
                        delay(RETRY_DELAY_MS)
                        registerService(serviceName, port, txtRecord)
                    }
                }
            }
            
            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "⏹️ 服务已注销: ${info.serviceName}")
                isRegistered = false
                _serviceState.value = ServiceState.Idle
            }
            
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "❌ 注销失败: errorCode=$errorCode")
            }
        }
        
        _serviceState.value = ServiceState.Registering
        nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
    }
    
    /**
     * 取消注册服务
     */
    fun unregisterService() {
        registrationListener?.let {
            try {
                nsdManager.unregisterService(it)
            } catch (e: Exception) {
                Log.w(TAG, "取消注册异常: ${e.message}")
            }
        }
        registrationListener = null
        isRegistered = false
    }
    
    // ==================== 服务发现 ====================
    
    /**
     * 开始发现服务
     */
    fun startDiscovery() {
        if (isDiscovering) {
            Log.w(TAG, "已在发现中")
            return
        }
        
        // 获取组播锁
        acquireMulticastLock()
        
        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.i(TAG, "🔍 开始发现服务: $serviceType")
                isDiscovering = true
                _serviceState.value = ServiceState.Discovering
            }
            
            override fun onServiceFound(service: NsdServiceInfo) {
                Log.d(TAG, "📡 发现服务: ${service.serviceName}")
                
                // 过滤自己的服务
                if (service.serviceName == getLocalServiceName()) {
                    return
                }
                
                // 解析服务获取详细信息
                resolveService(service)
            }
            
            override fun onServiceLost(service: NsdServiceInfo) {
                Log.d(TAG, "📴 服务离线: ${service.serviceName}")
                
                // 从缓存中移除
                val deviceId = findDeviceIdByServiceName(service.serviceName)
                deviceId?.let {
                    discoveredDevices.remove(it)
                    scope.launch {
                        _deviceEvents.emit(DeviceEvent.DeviceLost(it))
                    }
                }
            }
            
            override fun onDiscoveryStopped(serviceType: String) {
                Log.i(TAG, "⏹️ 停止发现服务")
                isDiscovering = false
            }
            
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "❌ 启动发现失败: errorCode=$errorCode")
                isDiscovering = false
                _serviceState.value = ServiceState.Error("发现失败: $errorCode")
            }
            
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "❌ 停止发现失败: errorCode=$errorCode")
            }
        }
        
        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }
    
    /**
     * 停止发现服务
     */
    fun stopDiscovery() {
        discoveryListener?.let {
            try {
                nsdManager.stopServiceDiscovery(it)
            } catch (e: Exception) {
                Log.w(TAG, "停止发现异常: ${e.message}")
            }
        }
        discoveryListener = null
        isDiscovering = false
        
        // 释放组播锁
        releaseMulticastLock()
    }
    
    /**
     * 解析服务获取详细信息
     */
    private fun resolveService(service: NsdServiceInfo) {
        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "❌ 解析失败: ${info.serviceName}, errorCode=$errorCode")
            }
            
            override fun onServiceResolved(info: NsdServiceInfo) {
                Log.i(TAG, "✅ 解析成功: ${info.serviceName}")
                Log.d(TAG, "  Host: ${info.host?.hostAddress}")
                Log.d(TAG, "  Port: ${info.port}")
                
                // 解析 TXT 记录
                val attributes = info.attributes
                
                // 验证必需字段
                if (!TXTRecordBuilder.validate(attributes)) {
                    Log.w(TAG, "⚠️ TXT 记录缺少必需字段，忽略此设备")
                    return
                }
                
                val device = DiscoveredDevice(
                    serviceName = info.serviceName,
                    host = info.host?.hostAddress ?: "",
                    port = info.port,
                    deviceId = attributes["deviceId"]?.let { String(it) } ?: "",
                    pubKeyFP = attributes["pubKeyFP"]?.let { String(it) } ?: "",
                    uniqueId = attributes["uniqueId"]?.let { String(it) } ?: "",
                    platform = attributes["platform"]?.let { String(it) },
                    version = attributes["version"]?.let { String(it) },
                    capabilities = attributes["capabilities"]?.let { 
                        String(it).split(",").filter { it.isNotEmpty() }
                    } ?: emptyList(),
                    displayName = attributes["name"]?.let { String(it) }
                )
                
                // 打印 TXT 记录
                Log.d(TAG, "  deviceId: ${device.deviceId}")
                Log.d(TAG, "  pubKeyFP: ${device.pubKeyFP}")
                Log.d(TAG, "  platform: ${device.platform}")
                Log.d(TAG, "  capabilities: ${device.capabilities}")
                
                // 更新缓存
                val isNew = !discoveredDevices.containsKey(device.deviceId)
                discoveredDevices[device.deviceId] = device
                
                // 发送事件
                scope.launch {
                    if (isNew) {
                        _deviceEvents.emit(DeviceEvent.DeviceFound(device))
                    } else {
                        _deviceEvents.emit(DeviceEvent.DeviceUpdated(device))
                    }
                }
            }
        }
        
        // Android 12+ 使用新 API
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            nsdManager.resolveService(service, Runnable::run, resolveListener)
        } else {
            @Suppress("DEPRECATION")
            nsdManager.resolveService(service, resolveListener)
        }
    }
    
    // ==================== 辅助方法 ====================
    
    /**
     * 获取所有已发现的设备
     */
    fun getDiscoveredDevices(): List<DiscoveredDevice> {
        return discoveredDevices.values.toList()
    }
    
    /**
     * 根据 deviceId 获取设备
     */
    fun getDevice(deviceId: String): DiscoveredDevice? {
        return discoveredDevices[deviceId]
    }
    
    /**
     * 清理过期设备
     */
    fun cleanupStaleDevices() {
        val now = System.currentTimeMillis()
        val staleDevices = discoveredDevices.filter { 
            now - it.value.lastSeen > DEVICE_OFFLINE_THRESHOLD_MS 
        }
        
        staleDevices.forEach { (deviceId, _) ->
            discoveredDevices.remove(deviceId)
            scope.launch {
                _deviceEvents.emit(DeviceEvent.DeviceLost(deviceId))
            }
        }
    }
    
    private fun findDeviceIdByServiceName(serviceName: String): String? {
        return discoveredDevices.entries.find { it.value.serviceName == serviceName }?.key
    }
    
    private fun getLocalServiceName(): String? {
        return (_serviceState.value as? ServiceState.Registered)?.serviceName
    }
    
    private fun acquireMulticastLock() {
        if (multicastLock == null) {
            multicastLock = wifiManager.createMulticastLock("SkyBridge_mDNS")
            multicastLock?.setReferenceCounted(true)
        }
        multicastLock?.acquire()
        Log.d(TAG, "🔒 已获取组播锁")
    }
    
    private fun releaseMulticastLock() {
        multicastLock?.let {
            if (it.isHeld) {
                it.release()
                Log.d(TAG, "🔓 已释放组播锁")
            }
        }
    }
    
    /**
     * 释放所有资源
     */
    fun release() {
        stopDiscovery()
        unregisterService()
        releaseMulticastLock()
        scope.cancel()
    }
    
    // ==================== 事件和状态定义 ====================
    
    sealed class DeviceEvent {
        data class DeviceFound(val device: DiscoveredDevice) : DeviceEvent()
        data class DeviceUpdated(val device: DiscoveredDevice) : DeviceEvent()
        data class DeviceLost(val deviceId: String) : DeviceEvent()
    }
    
    sealed class ServiceState {
        object Idle : ServiceState()
        object Registering : ServiceState()
        data class Registered(val serviceName: String, val port: Int) : ServiceState()
        object Discovering : ServiceState()
        data class Error(val message: String) : ServiceState()
    }
}
```

#### 3.2.4 使用示例

```kotlin
package com.skybridge.compass

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.*
import androidx.lifecycle.lifecycleScope
import com.skybridge.compass.discovery.*
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.util.UUID

class MainActivity : ComponentActivity() {
    
    private lateinit var discovery: SkyBridgeDiscovery
    
    // 设备标识（首次安装时生成并持久化）
    private val deviceId: String by lazy {
        getSharedPreferences("skybridge", MODE_PRIVATE)
            .getString("device_id", null)
            ?: UUID.randomUUID().toString().also { id ->
                getSharedPreferences("skybridge", MODE_PRIVATE)
                    .edit().putString("device_id", id).apply()
            }
    }
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        discovery = SkyBridgeDiscovery(this)
        
        // 监听设备事件
        lifecycleScope.launch {
            discovery.deviceEvents.collectLatest { event ->
                when (event) {
                    is SkyBridgeDiscovery.DeviceEvent.DeviceFound -> {
                        println("发现新设备: ${event.device.displayName ?: event.device.serviceName}")
                        println("  平台: ${event.device.platform}")
                        println("  能力: ${event.device.capabilities}")
                    }
                    is SkyBridgeDiscovery.DeviceEvent.DeviceUpdated -> {
                        println("设备更新: ${event.device.deviceId}")
                    }
                    is SkyBridgeDiscovery.DeviceEvent.DeviceLost -> {
                        println("设备离线: ${event.deviceId}")
                    }
                }
            }
        }
        
        // 注册服务
        val txtRecord = TXTRecordBuilder(
            deviceId = deviceId,
            pubKeyFP = generatePubKeyFingerprint(), // 实现公钥指纹生成
            uniqueId = "instance-${android.os.Process.myPid()}",
            platform = "android",
            version = ProtocolVersion.CURRENT.toString(),
            capabilities = DeviceCapabilities.DEFAULT,
            name = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}"
        )
        
        discovery.registerService(
            serviceName = "android-${android.os.Build.MODEL}",
            port = 8765,
            txtRecord = txtRecord
        )
        
        // 开始发现
        discovery.startDiscovery()
        
        setContent {
            // UI 实现...
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        discovery.release()
    }
    
    private fun generatePubKeyFingerprint(): String {
        // TODO: 实现真实的公钥指纹生成
        // 应该是设备公钥的 SHA-256 前 24 字符（hex 小写）
        return "a1b2c3d4e5f6789012345678"
    }
}
```

#### 3.2.5 Android 特殊注意事项

| 问题 | 解决方案 |
|------|----------|
| WiFi 休眠导致 mDNS 丢包 | 使用 `WifiManager.MulticastLock` |
| 后台服务限制 | 使用 Foreground Service |
| 电池优化 | 加入电池优化白名单 |
| Android 12+ 权限 | 需要 `NEARBY_WIFI_DEVICES` 权限 |
| 解析并发限制 | Android 限制同时解析数量，需排队处理 |

```kotlin
// Android 12+ 需要额外权限
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
    // 在 AndroidManifest.xml 中添加
    // <uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />
}
```
    
    // 注册服务
    fun registerService(
        serviceName: String,
        port: Int,
        txtRecord: Map<String, String>
    ) {
        val serviceInfo = NsdServiceInfo().apply {
            this.serviceName = serviceName
            this.serviceType = SERVICE_TYPE
            this.port = port
            
            // 设置 TXT 记录
            txtRecord.forEach { (key, value) ->
                setAttribute(key, value)
            }
        }
        
        registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.d("SkyBridge", "服务已注册: ${info.serviceName}")
            }
            
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e("SkyBridge", "注册失败: $errorCode")
            }
            
            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.d("SkyBridge", "服务已注销")
            }
            
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e("SkyBridge", "注销失败: $errorCode")
            }
        }
        
        nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
    }
    
    // 发现服务
    fun startDiscovery(onServiceFound: (NsdServiceInfo) -> Unit) {
        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.d("SkyBridge", "开始发现服务")
            }
            
            override fun onServiceFound(service: NsdServiceInfo) {
                if (service.serviceType == SERVICE_TYPE) {
                    // 解析服务以获取完整信息
                    nsdManager.resolveService(service, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                            Log.e("SkyBridge", "解析失败: $errorCode")
                        }
                        
                        override fun onServiceResolved(info: NsdServiceInfo) {
                            Log.d("SkyBridge", "发现设备: ${info.serviceName}")
                            Log.d("SkyBridge", "  IP: ${info.host?.hostAddress}")
                            Log.d("SkyBridge", "  Port: ${info.port}")
                            
                            // 读取 TXT 记录
                            info.attributes.forEach { (key, value) ->
                                Log.d("SkyBridge", "  $key: ${String(value)}")
                            }
                            
                            onServiceFound(info)
                        }
                    })
                }
            }
            
            override fun onServiceLost(service: NsdServiceInfo) {
                Log.d("SkyBridge", "设备离线: ${service.serviceName}")
            }
            
            override fun onDiscoveryStopped(serviceType: String) {
                Log.d("SkyBridge", "停止发现服务")
            }
            
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e("SkyBridge", "启动发现失败: $errorCode")
            }
            
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e("SkyBridge", "停止发现失败: $errorCode")
            }
        }
        
        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }
    
    fun stopDiscovery() {
        discoveryListener?.let { nsdManager.stopServiceDiscovery(it) }
        registrationListener?.let { nsdManager.unregisterService(it) }
    }
}
```


### 3.3 Windows (Bonjour SDK / dns-sd)

```cpp
#include <dns_sd.h>
#include <string>
#include <map>

class SkyBridgeDiscovery {
private:
    DNSServiceRef registerRef = nullptr;
    DNSServiceRef browseRef = nullptr;
    
public:
    // 注册服务
    bool registerService(
        const std::string& name,
        uint16_t port,
        const std::map<std::string, std::string>& txtRecord
    ) {
        // 构建 TXT 记录
        TXTRecordRef txtRef;
        TXTRecordCreate(&txtRef, 0, nullptr);
        
        for (const auto& [key, value] : txtRecord) {
            TXTRecordSetValue(&txtRef, key.c_str(), 
                static_cast<uint8_t>(value.length()), value.c_str());
        }
        
        DNSServiceErrorType err = DNSServiceRegister(
            &registerRef,
            0,                          // flags
            0,                          // interface index (0 = all)
            name.c_str(),               // service name
            "_skybridge._tcp",          // service type
            nullptr,                    // domain (nullptr = default)
            nullptr,                    // host (nullptr = default)
            htons(port),                // port (network byte order)
            TXTRecordGetLength(&txtRef),
            TXTRecordGetBytesPtr(&txtRef),
            registerCallback,
            this
        );
        
        TXTRecordDeallocate(&txtRef);
        
        if (err != kDNSServiceErr_NoError) {
            return false;
        }
        
        // 处理事件
        DNSServiceProcessResult(registerRef);
        return true;
    }
    
    // 发现服务
    bool startDiscovery() {
        DNSServiceErrorType err = DNSServiceBrowse(
            &browseRef,
            0,                          // flags
            0,                          // interface index
            "_skybridge._tcp",          // service type
            nullptr,                    // domain
            browseCallback,
            this
        );
        
        if (err != kDNSServiceErr_NoError) {
            return false;
        }
        
        // 在单独线程中处理事件
        std::thread([this]() {
            while (browseRef) {
                DNSServiceProcessResult(browseRef);
            }
        }).detach();
        
        return true;
    }
    
private:
    static void DNSSD_API registerCallback(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        DNSServiceErrorType errorCode,
        const char* name,
        const char* regtype,
        const char* domain,
        void* context
    ) {
        if (errorCode == kDNSServiceErr_NoError) {
            printf("服务已注册: %s.%s%s\n", name, regtype, domain);
        }
    }
    
    static void DNSSD_API browseCallback(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        uint32_t interfaceIndex,
        DNSServiceErrorType errorCode,
        const char* serviceName,
        const char* regtype,
        const char* replyDomain,
        void* context
    ) {
        if (errorCode == kDNSServiceErr_NoError) {
            if (flags & kDNSServiceFlagsAdd) {
                printf("发现设备: %s\n", serviceName);
                // 解析服务获取详细信息
                auto* self = static_cast<SkyBridgeDiscovery*>(context);
                self->resolveService(serviceName, regtype, replyDomain, interfaceIndex);
            } else {
                printf("设备离线: %s\n", serviceName);
            }
        }
    }
    
    void resolveService(
        const char* name,
        const char* regtype,
        const char* domain,
        uint32_t interfaceIndex
    ) {
        DNSServiceRef resolveRef;
        DNSServiceResolve(
            &resolveRef,
            0,
            interfaceIndex,
            name,
            regtype,
            domain,
            resolveCallback,
            this
        );
        DNSServiceProcessResult(resolveRef);
        DNSServiceRefDeallocate(resolveRef);
    }
    
    static void DNSSD_API resolveCallback(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        uint32_t interfaceIndex,
        DNSServiceErrorType errorCode,
        const char* fullname,
        const char* hosttarget,
        uint16_t port,
        uint16_t txtLen,
        const unsigned char* txtRecord,
        void* context
    ) {
        if (errorCode == kDNSServiceErr_NoError) {
            printf("  Host: %s\n", hosttarget);
            printf("  Port: %d\n", ntohs(port));
            
            // 解析 TXT 记录
            uint16_t count = TXTRecordGetCount(txtLen, txtRecord);
            for (uint16_t i = 0; i < count; i++) {
                char key[256];
                uint8_t valueLen;
                const void* value;
                
                if (TXTRecordGetItemAtIndex(txtLen, txtRecord, i, 
                    sizeof(key), key, &valueLen, &value) == kDNSServiceErr_NoError) {
                    printf("  %s: %.*s\n", key, valueLen, (const char*)value);
                }
            }
        }
    }
};
```


### 3.4 Linux (Avahi)

```c
#include <avahi-client/client.h>
#include <avahi-client/publish.h>
#include <avahi-client/lookup.h>
#include <avahi-common/simple-watch.h>
#include <avahi-common/malloc.h>
#include <avahi-common/error.h>

static AvahiSimplePoll *simple_poll = NULL;
static AvahiEntryGroup *group = NULL;
static AvahiServiceBrowser *browser = NULL;

// 注册服务
void register_service(AvahiClient *client, const char *name, uint16_t port) {
    if (!group) {
        group = avahi_entry_group_new(client, entry_group_callback, NULL);
    }
    
    // 构建 TXT 记录
    AvahiStringList *txt = NULL;
    txt = avahi_string_list_add_pair(txt, "deviceId", "550e8400-e29b-41d4-a716-446655440000");
    txt = avahi_string_list_add_pair(txt, "pubKeyFP", "a1b2c3d4e5f6789012345678");
    txt = avahi_string_list_add_pair(txt, "uniqueId", "instance-001");
    txt = avahi_string_list_add_pair(txt, "platform", "linux");
    txt = avahi_string_list_add_pair(txt, "version", "1.0.0");
    txt = avahi_string_list_add_pair(txt, "capabilities", "file_transfer,screen_sharing");
    
    int ret = avahi_entry_group_add_service_strlst(
        group,
        AVAHI_IF_UNSPEC,
        AVAHI_PROTO_UNSPEC,
        0,
        name,
        "_skybridge._tcp",
        NULL,
        NULL,
        port,
        txt
    );
    
    avahi_string_list_free(txt);
    
    if (ret < 0) {
        fprintf(stderr, "注册服务失败: %s\n", avahi_strerror(ret));
        return;
    }
    
    ret = avahi_entry_group_commit(group);
    if (ret < 0) {
        fprintf(stderr, "提交服务失败: %s\n", avahi_strerror(ret));
    }
}

// 服务发现回调
static void browse_callback(
    AvahiServiceBrowser *b,
    AvahiIfIndex interface,
    AvahiProtocol protocol,
    AvahiBrowserEvent event,
    const char *name,
    const char *type,
    const char *domain,
    AvahiLookupResultFlags flags,
    void *userdata
) {
    AvahiClient *client = userdata;
    
    switch (event) {
        case AVAHI_BROWSER_NEW:
            printf("发现设备: %s\n", name);
            // 解析服务
            avahi_service_resolver_new(
                client,
                interface,
                protocol,
                name,
                type,
                domain,
                AVAHI_PROTO_UNSPEC,
                0,
                resolve_callback,
                NULL
            );
            break;
            
        case AVAHI_BROWSER_REMOVE:
            printf("设备离线: %s\n", name);
            break;
            
        default:
            break;
    }
}

// 解析回调
static void resolve_callback(
    AvahiServiceResolver *r,
    AvahiIfIndex interface,
    AvahiProtocol protocol,
    AvahiResolverEvent event,
    const char *name,
    const char *type,
    const char *domain,
    const char *host_name,
    const AvahiAddress *address,
    uint16_t port,
    AvahiStringList *txt,
    AvahiLookupResultFlags flags,
    void *userdata
) {
    if (event == AVAHI_RESOLVER_FOUND) {
        char addr[AVAHI_ADDRESS_STR_MAX];
        avahi_address_snprint(addr, sizeof(addr), address);
        
        printf("  Host: %s\n", host_name);
        printf("  Address: %s\n", addr);
        printf("  Port: %d\n", port);
        
        // 解析 TXT 记录
        for (AvahiStringList *l = txt; l; l = avahi_string_list_get_next(l)) {
            char *key, *value;
            if (avahi_string_list_get_pair(l, &key, &value, NULL) >= 0) {
                printf("  %s: %s\n", key, value);
                avahi_free(key);
                avahi_free(value);
            }
        }
    }
    
    avahi_service_resolver_free(r);
}

// 启动发现
void start_discovery(AvahiClient *client) {
    browser = avahi_service_browser_new(
        client,
        AVAHI_IF_UNSPEC,
        AVAHI_PROTO_UNSPEC,
        "_skybridge._tcp",
        NULL,
        0,
        browse_callback,
        client
    );
}
```


---

## 3.5 跨平台互操作性矩阵

### 3.5.1 平台 API 对照表

| 功能 | macOS/iOS | Android | Windows | Linux |
|------|-----------|---------|---------|-------|
| 服务发现 API | `NWBrowser` | `NsdManager` | `DNSServiceBrowse` | `avahi_service_browser_new` |
| 服务注册 API | `NWListener` | `NsdManager` | `DNSServiceRegister` | `avahi_entry_group_add_service` |
| TXT 记录支持 | ✅ 原生 | ✅ API 21+ | ✅ 原生 | ✅ 原生 |
| IPv6 支持 | ✅ | ✅ | ✅ | ✅ |
| 后台运行 | ✅ | ⚠️ 需 Foreground Service | ✅ | ✅ |

### 3.5.2 TXT 记录字段完整规范

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        TXT 记录字段规范 v1.0                             │
├─────────────┬──────────┬─────────────────────────────────────────────────┤
│ 字段名       │ 必需     │ 格式说明                                        │
├─────────────┼──────────┼─────────────────────────────────────────────────┤
│ deviceId    │ ✅       │ UUID v4，首次安装生成，持久化存储                  │
│ pubKeyFP    │ ✅       │ 公钥 SHA-256 前 24 字符，hex 小写                 │
│ uniqueId    │ ✅       │ 运行实例 ID，格式: instance-{pid}                 │
│ platform    │ ❌       │ 枚举: macos, ios, android, windows, linux        │
│ version     │ ❌       │ 协议版本，semver 格式: 1.0.0                      │
│ capabilities│ ❌       │ 逗号分隔能力列表                                  │
│ name        │ ❌       │ 设备显示名称，UTF-8 编码                          │
└─────────────┴──────────┴─────────────────────────────────────────────────┘
```

### 3.5.3 能力字符串标准定义

| 能力标识 | 说明 | macOS | iOS | Android |
|----------|------|-------|-----|---------|
| `remote_desktop` | 远程桌面控制 | ✅ | ❌ | ⚠️ 需 root |
| `file_transfer` | 文件传输 | ✅ | ✅ | ✅ |
| `screen_sharing` | 屏幕共享（只读） | ✅ | ✅ | ✅ |
| `input_injection` | 输入注入 | ✅ | ❌ | ⚠️ 需辅助功能 |
| `system_control` | 系统控制 | ✅ | ❌ | ❌ |
| `pqc_encryption` | 后量子加密 | ✅ iOS 26+ | ✅ iOS 26+ | ⚠️ 需 liboqs |
| `hybrid_encryption` | 混合加密 | ✅ | ✅ | ✅ |
| `audio_transfer` | 音频传输 | ✅ | ✅ | ✅ |
| `clipboard_sync` | 剪贴板同步 | ✅ | ✅ | ✅ |

### 3.5.4 协议版本协商流程

```
┌─────────────┐                              ┌─────────────┐
│   Device A  │                              │   Device B  │
│  (Android)  │                              │   (macOS)   │
└──────┬──────┘                              └──────┬──────┘
       │                                            │
       │  1. mDNS 广播 (version=1.0.0)              │
       │ ──────────────────────────────────────────>│
       │                                            │
       │  2. mDNS 响应 (version=1.0.0)              │
       │ <──────────────────────────────────────────│
       │                                            │
       │  3. 版本兼容性检查                          │
       │     major 版本必须相同                      │
       │                                            │
       │  4. TCP 连接建立                           │
       │ <─────────────────────────────────────────>│
       │                                            │
       │  5. 能力协商请求                           │
       │     {capabilities, encryptionModes, ...}   │
       │ ──────────────────────────────────────────>│
       │                                            │
       │  6. 能力协商响应                           │
       │     {negotiatedCapabilities, ...}          │
       │ <──────────────────────────────────────────│
       │                                            │
       │  7. 使用协商后的能力集进行通信              │
       │ <─────────────────────────────────────────>│
       │                                            │
```

---

## 4. 互操作性检查清单

### 4.1 服务注册检查

- [ ] 服务类型为 `_skybridge._tcp`
- [ ] TXT 记录包含 `deviceId` (UUID 格式)
- [ ] TXT 记录包含 `pubKeyFP` (hex 小写)
- [ ] TXT 记录包含 `uniqueId`
- [ ] 每个 TXT 条目长度 < 256 字节
- [ ] 端口号正确设置

### 4.2 服务发现检查

- [ ] 能发现同一局域网内的其他设备
- [ ] 能正确解析 TXT 记录
- [ ] 能处理设备上线/离线事件
- [ ] 能处理 IPv4 和 IPv6 地址

### 4.3 网络环境检查

- [ ] 防火墙允许 mDNS 流量 (UDP 5353)
- [ ] 设备在同一子网或 mDNS 可达
- [ ] 路由器未阻止组播流量

---

## 5. 常见问题排查

### 5.1 设备无法发现

**可能原因**:
1. 防火墙阻止 UDP 5353 端口
2. 设备不在同一子网
3. 路由器禁用了组播
4. 服务类型拼写错误

**排查步骤**:
```bash
# macOS/Linux: 检查 mDNS 服务
dns-sd -B _skybridge._tcp

# Windows: 使用 Bonjour Browser
# 或安装 dns-sd 命令行工具

# 检查防火墙
# macOS
sudo pfctl -s rules | grep 5353

# Linux
sudo iptables -L -n | grep 5353

# Windows
netsh advfirewall firewall show rule name=all | findstr 5353
```

### 5.2 TXT 记录解析失败

**可能原因**:
1. TXT 记录编码错误
2. 字段名大小写不一致
3. 值包含特殊字符

**解决方案**:
- 确保使用 UTF-8 编码
- 字段名使用 camelCase
- 避免在值中使用 `=` 字符

### 5.3 服务注册失败

**可能原因**:
1. 端口被占用
2. 服务名冲突
3. 权限不足

**解决方案**:
```bash
# 检查端口占用
lsof -i :7002

# 使用动态端口
# 让系统分配可用端口，然后在 TXT 记录中声明
```

---

## 6. 测试工具

### 6.1 命令行工具

```bash
# macOS/Linux: dns-sd
dns-sd -B _skybridge._tcp              # 浏览服务
dns-sd -L "设备名" _skybridge._tcp     # 查看详情
dns-sd -R "测试" _skybridge._tcp . 7002 deviceId=test pubKeyFP=abc uniqueId=001

# Linux: avahi-browse
avahi-browse -art _skybridge._tcp

# Windows: dns-sd (需安装 Bonjour SDK)
dns-sd -B _skybridge._tcp
```

### 6.2 图形化工具

| 平台 | 工具 |
|------|------|
| macOS | Discovery - DNS-SD Browser (App Store) |
| Windows | Bonjour Browser |
| Linux | avahi-discover |
| 跨平台 | Wireshark (过滤 mdns) |

---

## 7. 最佳实践

### 7.1 设备标识生成

```swift
// 首次安装时生成并持久化
let deviceId = UUID().uuidString

// 公钥指纹计算
let publicKeyData: Data = ...
let hash = SHA256.hash(data: publicKeyData)
let pubKeyFP = hash.prefix(12).map { String(format: "%02x", $0) }.joined()

// 实例 ID (每次启动生成)
let uniqueId = "instance-\(ProcessInfo.processInfo.processIdentifier)"
```

### 7.2 服务名称策略

```
推荐格式: <用户名>-<设备型号>
示例: john-macbook-pro

避免:
- 过长的名称 (> 63 字符)
- 特殊字符
- 纯数字
```

### 7.3 重试机制

```swift
// 注册失败后重试
let maxRetries = 3
let retryDelay: TimeInterval = 10.0

func registerWithRetry() async {
    for attempt in 1...maxRetries {
        do {
            try await register()
            return
        } catch {
            if attempt < maxRetries {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
    }
}
```

---

## 附录: 参考资料

- [RFC 6762 - Multicast DNS](https://tools.ietf.org/html/rfc6762)
- [RFC 6763 - DNS-Based Service Discovery](https://tools.ietf.org/html/rfc6763)
- [Apple Bonjour Overview](https://developer.apple.com/bonjour/)
- [Android NSD Guide](https://developer.android.com/training/connect-devices-wirelessly/nsd)
- [Avahi Documentation](https://avahi.org/)

---

## 8. Android 开发快速入门

### 8.1 最小可行实现

```kotlin
// 1. 初始化
val discovery = SkyBridgeDiscovery(context)

// 2. 构建 TXT 记录
val txtRecord = TXTRecordBuilder(
    deviceId = UUID.randomUUID().toString(),
    pubKeyFP = "your_public_key_fingerprint_hex",
    uniqueId = "instance-${Process.myPid()}"
)

// 3. 注册服务
discovery.registerService("my-android-device", 8765, txtRecord)

// 4. 开始发现
discovery.startDiscovery()

// 5. 监听事件
lifecycleScope.launch {
    discovery.deviceEvents.collect { event ->
        when (event) {
            is DeviceEvent.DeviceFound -> handleNewDevice(event.device)
            is DeviceEvent.DeviceLost -> handleDeviceLost(event.deviceId)
        }
    }
}
```

### 8.2 Android 常见问题

#### Q: 为什么发现不到 macOS/iOS 设备？

**检查清单：**
1. 确保设备在同一 WiFi 网络
2. 确保服务类型完全一致：`_skybridge._tcp.`（注意末尾的点）
3. 检查是否获取了 MulticastLock
4. 检查路由器是否允许 mDNS 组播（UDP 5353）

```kotlin
// 调试：打印所有发现的服务
nsdManager.discoverServices("_services._dns-sd._udp", NsdManager.PROTOCOL_DNS_SD, listener)
```

#### Q: TXT 记录读取为空？

Android 的 `NsdServiceInfo.attributes` 在 `onServiceFound` 时可能为空，必须在 `onServiceResolved` 后才能读取。

```kotlin
// ❌ 错误：在 onServiceFound 中读取
override fun onServiceFound(service: NsdServiceInfo) {
    val deviceId = service.attributes["deviceId"] // 可能为空！
}

// ✅ 正确：在 onServiceResolved 中读取
override fun onServiceResolved(info: NsdServiceInfo) {
    val deviceId = info.attributes["deviceId"]?.let { String(it) }
}
```

#### Q: 后台运行时发现失败？

Android 8.0+ 限制后台网络活动，需要使用 Foreground Service：

```kotlin
class DiscoveryService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = createNotification()
        startForeground(NOTIFICATION_ID, notification)
        
        // 启动发现...
        
        return START_STICKY
    }
}
```

### 8.3 推荐的项目结构

```
app/
├── src/main/java/com/skybridge/compass/
│   ├── discovery/
│   │   ├── SkyBridgeDiscovery.kt      # 设备发现服务
│   │   ├── DiscoveredDevice.kt        # 设备数据模型
│   │   ├── TXTRecordBuilder.kt        # TXT 记录构建
│   │   └── DeviceCapabilities.kt      # 能力定义
│   ├── crypto/
│   │   ├── KeyManager.kt              # 密钥管理
│   │   └── HybridCrypto.kt            # 混合加密
│   ├── connection/
│   │   ├── P2PConnectionManager.kt    # P2P 连接管理
│   │   └── CapabilityNegotiator.kt    # 能力协商
│   └── ui/
│       ├── DeviceListScreen.kt        # 设备列表 UI
│       └── ConnectionScreen.kt        # 连接 UI
└── src/main/AndroidManifest.xml
```

### 8.4 与 macOS 端的互操作测试

```bash
# 1. 在 macOS 上启动云桥司南

# 2. 在 Android 上运行 APP

# 3. 使用 dns-sd 验证 Android 服务是否可见
dns-sd -B _skybridge._tcp

# 4. 查看 Android 设备的 TXT 记录
dns-sd -L "android-device-name" _skybridge._tcp

# 预期输出：
# deviceId=550e8400-e29b-41d4-a716-446655440000
# pubKeyFP=a1b2c3d4e5f6789012345678
# uniqueId=instance-12345
# platform=android
# version=1.0.0
# capabilities=file_transfer,screen_sharing,clipboard_sync
```

---

## 9. 后续开发路线图

### 9.1 Phase 1: 基础发现（当前）
- [x] mDNS/DNS-SD 服务注册
- [x] 设备发现和 TXT 记录解析
- [x] 跨平台互操作性

### 9.2 Phase 2: 安全连接
- [ ] PAKE 配对（6 位数字码）
- [ ] 混合加密握手（X25519 + ML-KEM-768）
- [ ] 设备信任存储

### 9.3 Phase 3: 功能实现
- [ ] 文件传输
- [ ] 屏幕共享
- [ ] 剪贴板同步

---

**文档维护**: SkyBridge Compass Team  
**最后更新**: 2025-12-16
