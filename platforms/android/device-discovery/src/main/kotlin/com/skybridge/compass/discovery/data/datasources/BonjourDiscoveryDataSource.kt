package com.skybridge.compass.discovery.data.datasources

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Bonjour/mDNS 设备发现数据源
 * 
 * 使用Android NSD API实现Bonjour服务发现
 */
@Singleton
class BonjourDiscoveryDataSource @Inject constructor(
    @param:dagger.hilt.android.qualifiers.ApplicationContext private val context: Context
) {
    
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE
    
    /**
     * 开始Bonjour服务发现
     */
    fun startDiscovery(): Flow<List<DiscoveredDevice>> = callbackFlow {
        val multicastLock = acquireMulticastLock()
        val discoveredDevices = mutableMapOf<String, DiscoveredDevice>()
        val serviceNameToDeviceId = mutableMapOf<String, String>()
        
        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                // 发现启动失败
            }
            
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {
                // 发现停止失败
            }
            
            override fun onDiscoveryStarted(serviceType: String?) {
                // 发现已启动
            }
            
            override fun onDiscoveryStopped(serviceType: String?) {
                // 发现已停止
            }
            
            override fun onServiceFound(serviceInfo: NsdServiceInfo?) {
                serviceInfo?.let { service ->
                    // 解析服务详细信息（API 34+ 新签名需要传入 Executor）
                    val listener = object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                            // 解析失败
                        }

                        override fun onServiceResolved(serviceInfo: NsdServiceInfo?) {
                            serviceInfo?.let { resolvedService ->
                                val device = createDeviceFromService(resolvedService)
                                discoveredDevices[device.id] = device
                                serviceNameToDeviceId[resolvedService.serviceName] = device.id
                                trySend(discoveredDevices.values.toList())
                            }
                        }
                    }

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        // API 34+ 新签名在当前 SDK 标注为 Deprecated in Java，仅限该分支抑制
                        @Suppress("DEPRECATION")
                        nsdManager.resolveService(service, context.mainExecutor, listener)
                    } else {
                        @Suppress("DEPRECATION")
                        nsdManager.resolveService(service, listener)
                    }
                }
            }
            
            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {
                serviceInfo?.let { service ->
                    val deviceId = serviceNameToDeviceId.remove(service.serviceName) ?: service.serviceName
                    discoveredDevices.remove(deviceId)
                    trySend(discoveredDevices.values.toList())
                }
            }
        }
        
        nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, discoveryListener)

        awaitClose {
            nsdManager.stopServiceDiscovery(discoveryListener)
            multicastLock?.let { releaseMulticastLock(it) }
        }
    }
    
    /**
     * 从NSD服务信息创建设备对象
     */
    private fun createDeviceFromService(serviceInfo: NsdServiceInfo): DiscoveredDevice {
        val txtRecords = extractTxtRecords(serviceInfo)
        val deviceId = AppleBonjourInterop.resolveTxtValue(
            txtRecords,
            "deviceId",
            "device_id",
            "id",
            "uniqueId",
            "unique_id"
        )
            ?: serviceInfo.serviceName
        val pubKeyFP = AppleBonjourInterop.resolveTxtValue(
            txtRecords,
            "pubKeyFP",
            "pub_key_fp",
            "pubKeyFingerprint",
            "publicKeyFingerprint"
        )
        val uniqueId = AppleBonjourInterop.resolveTxtValue(
            txtRecords,
            "uniqueId",
            "unique_id"
        )
            ?: deviceId
        val osVersion = AppleBonjourInterop.resolveTxtValue(
            txtRecords,
            "osVersion",
            "os_version"
        )
        val remoteVideoFormats = AppleBonjourInterop.extractRemoteVideoFormats(txtRecords)
        val supportsSoa = AppleBonjourInterop.supportsSoa(txtRecords)

        // 统一提取 NebulaID 字段（兼容不同命名）
        val nebulaId = AppleBonjourInterop.resolveTxtValue(
            txtRecords,
            "nebula_id",
            "nebulaid",
            "nebulaId",
            "id",
            "sub"
        )

        val extra = buildMap<String, String> {
            if (!nebulaId.isNullOrBlank()) put("nebulaId", nebulaId)
            if (!pubKeyFP.isNullOrBlank()) put("pubKeyFP", pubKeyFP)
            if (!uniqueId.isNullOrBlank()) put("uniqueId", uniqueId)
            if (!osVersion.isNullOrBlank()) put("osVersion", osVersion)
            val suites = AppleBonjourInterop.resolveTxtValue(txtRecords, "cryptoSuites", "suites")
            if (suites != null) put("cryptoSuites", suites)
            if (remoteVideoFormats.isNotEmpty()) {
                put("remoteVideoFormats", remoteVideoFormats.joinToString(","))
            }
            if (supportsSoa) {
                put(AppleBonjourInterop.HS_SOA_KEY, "1")
            }
            put("servicePort:${serviceInfo.serviceType}", serviceInfo.port.toString())
        }
        val resolvedPort = AppleBonjourInterop.preferredPort(
            serviceType = serviceInfo.serviceType,
            resolvedPort = serviceInfo.port,
            txtRecords = txtRecords
        )

        return DiscoveredDevice(
            id = deviceId,
            name = AppleBonjourInterop.resolveTxtValue(txtRecords, "name", "device", "hostname")
                ?: serviceInfo.serviceName,
            type = parseDeviceType(
                AppleBonjourInterop.resolveTxtValue(txtRecords, "platform", "type")
            ),
            capabilities = AppleBonjourInterop.parseCapabilities(
                rawCapabilities = AppleBonjourInterop.resolveTxtValue(txtRecords, "capabilities", "cap"),
                serviceType = serviceInfo.serviceType
            ),
            connectionInfo = ConnectionInfo(
                protocol = DiscoveryProtocol.BONJOUR,
                address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    serviceInfo.hostAddresses.firstOrNull()?.hostAddress ?: ""
                } else {
                    @Suppress("DEPRECATION")
                    serviceInfo.host?.hostAddress ?: ""
                },
                port = resolvedPort,
                serviceType = serviceInfo.serviceType,
                txtRecords = txtRecords,
                extra = extra
            ),
            signalStrength = 100, // Bonjour不提供信号强度信息
            lastSeen = System.currentTimeMillis(),
            osVersion = osVersion,
            batteryLevel = txtRecords["battery"]?.toIntOrNull()
        )
    }
    
    /**
     * 提取TXT记录
     */
    private fun extractTxtRecords(serviceInfo: NsdServiceInfo): Map<String, String> {
        val records = mutableMapOf<String, String>()

        // Android NSD API 的 TXT 记录键值为 Map<String, ByteArray>
        // 之前实现错误地将 key 做了二次字节化，导致 key 失真，无法读取 nebula_id
        // 这里修正为直接使用原始 key，并按 UTF-8 解码 value
        serviceInfo.attributes?.forEach { (key, value) ->
            val k = key.lowercase(Locale.ROOT)
            val v = try {
                String(value, Charsets.UTF_8)
            } catch (_: Throwable) {
                // 兼容非 UTF-8 的情况，按 ISO-8859-1 回退
                try { String(value, Charsets.ISO_8859_1) } catch (_: Throwable) { "" }
            }
            records[k] = v
        }

        return records
    }
    
    /**
     * 解析设备类型
     */
    private fun parseDeviceType(typeString: String?): DeviceType {
        return when (typeString?.lowercase(Locale.ROOT)) {
            "ios" -> DeviceType.IOS
            "macos" -> DeviceType.MACOS
            "android" -> DeviceType.ANDROID
            "windows" -> DeviceType.WINDOWS
            "linux" -> DeviceType.LINUX
            else -> DeviceType.UNKNOWN
        }
    }
    private fun acquireMulticastLock(): WifiManager.MulticastLock? {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        return wifi.createMulticastLock("skybridge-mdns-discovery").apply {
            setReferenceCounted(false)
            runCatching { acquire() }
        }
    }

    private fun releaseMulticastLock(lock: WifiManager.MulticastLock) {
        runCatching {
            if (lock.isHeld) lock.release()
        }
    }
}
