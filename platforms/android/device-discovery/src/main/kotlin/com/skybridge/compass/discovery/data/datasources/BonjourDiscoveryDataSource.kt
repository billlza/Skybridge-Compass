package com.skybridge.compass.discovery.data.datasources

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
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

class BonjourDiscoveryException(
    message: String,
    cause: Throwable? = null
) : IllegalStateException(message, cause)

/**
 * Returns whether an NSD resolve callback belongs to the service type whose listener received it.
 *
 * Android NSD can report a leading-dot variant of a DNS-SD type (for example,
 * `._skybridge-xfer._tcp`). The comparison therefore uses the same canonicalization as the
 * discovery adapter while keeping the stricter shared route-binding parser unchanged.
 */
internal fun matchesBonjourServiceType(
    requestedServiceType: String,
    resolvedServiceType: String?
): Boolean {
    val requestedCanonicalType = AppleBonjourInterop.canonicalServiceType(requestedServiceType)
        ?: return false
    return requestedCanonicalType == AppleBonjourInterop.canonicalServiceType(resolvedServiceType)
}

/**
 * Builds the stable in-memory key used by resolved and lost NSD callbacks.
 *
 * Canonicalizing the type makes aliases such as a leading-dot Android value and the canonical DNS-
 * SD value address the same indexed service.
 */
internal fun canonicalBonjourServiceKey(serviceType: String?, serviceName: String): String {
    val canonicalType = AppleBonjourInterop.canonicalServiceType(serviceType)
    return "${canonicalType ?: serviceType ?: "unknown"}::$serviceName"
}

/**
 * Bonjour/mDNS 设备发现数据源
 *
 * 使用Android NSD API实现Bonjour服务发现
 */
@Singleton
class BonjourDiscoveryDataSource @Inject constructor(
    @param:dagger.hilt.android.qualifiers.ApplicationContext private val context: Context
) {

    private companion object {
        private const val TAG = "BonjourDiscovery"
    }

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val serviceTypes = AppleBonjourInterop.DISCOVERY_SERVICE_TYPES

    /**
     * 开始Bonjour服务发现
     */
    fun startDiscovery(): Flow<List<DiscoveredDevice>> = callbackFlow {
        BonjourLocalNetworkPermissionPolicy.requireLocalNetworkPermission(
            context = context,
            sdkInt = Build.VERSION.SDK_INT
        )
        val multicastLock = acquireMulticastLock()
        val serviceIndex = BonjourDeviceServiceIndex()
        val resolveAttempts = BonjourResolveAttemptIndex()
        val discoveryListeners = mutableListOf<NsdManager.DiscoveryListener>()
        val loggedBoundaryReasons = mutableSetOf<String>()

        fun logBoundaryOnce(reason: String, message: String) {
            val shouldLog = synchronized(loggedBoundaryReasons) {
                loggedBoundaryReasons.add(reason)
            }
            if (shouldLog) Log.w(TAG, message)
        }

        fun discoveryListenerFor(requestedServiceType: String) = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                close(
                    BonjourDiscoveryException(
                        "Bonjour discovery failed for ${serviceType ?: requestedServiceType}: NSD error $errorCode"
                    )
                )
            }

            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {
                Log.w(TAG, "Bonjour discovery stop failed for ${serviceType ?: requestedServiceType}: NSD error $errorCode")
            }

            override fun onDiscoveryStarted(serviceType: String?) {
                // 发现已启动
            }

            override fun onDiscoveryStopped(serviceType: String?) {
                // 发现已停止
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo?) {
                serviceInfo?.let { service ->
                    val serviceKey = canonicalBonjourServiceKey(
                        service.serviceType,
                        service.serviceName
                    )
                    val resolveToken = try {
                        resolveAttempts.begin(serviceKey)
                    } catch (_: BonjourResolveCapacityException) {
                        logBoundaryOnce(
                            "resolve-capacity",
                            "Ignoring Bonjour services because resolve capacity is full"
                        )
                        return
                    } catch (_: BonjourResolveAlreadyPendingException) {
                        logBoundaryOnce(
                            "duplicate-pending-resolve",
                            "Ignoring duplicate Bonjour services while resolution is pending"
                        )
                        return
                    }
                    // 解析服务详细信息（API 34+ 新签名需要传入 Executor）
                    val listener = object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                            resolveAttempts.completeIfCurrent(serviceKey, resolveToken)
                            Log.w(
                                TAG,
                                "Bonjour service resolve failed type=$requestedServiceType " +
                                    "errorCode=$errorCode"
                            )
                        }

                        override fun onServiceResolved(serviceInfo: NsdServiceInfo?) {
                            val resolvedService = serviceInfo ?: run {
                                resolveAttempts.completeIfCurrent(serviceKey, resolveToken)
                                return
                            }
                            val resolvedServiceKey = canonicalBonjourServiceKey(
                                resolvedService.serviceType,
                                resolvedService.serviceName
                            )
                            if (resolvedServiceKey != serviceKey) {
                                resolveAttempts.completeIfCurrent(serviceKey, resolveToken)
                                Log.w(TAG, "Ignoring Bonjour resolve with mismatched service identity")
                                return
                            }
                            if (!resolveAttempts.completeIfCurrent(serviceKey, resolveToken)) {
                                Log.i(TAG, "Ignoring stale Bonjour resolve callback")
                                return
                            }
                            if (!matchesBonjourServiceType(
                                    requestedServiceType = requestedServiceType,
                                    resolvedServiceType = resolvedService.serviceType
                                )
                            ) {
                                Log.w(
                                    TAG,
                                    "Ignoring resolved Bonjour service from unexpected type"
                                )
                                return
                            }
                            val device = try {
                                createDeviceFromService(resolvedService)
                            } catch (e: BonjourDiscoveryException) {
                                Log.w(
                                    TAG,
                                    "Ignoring malformed Bonjour service " +
                                        "exception=${e.javaClass.simpleName}"
                                )
                                return
                            }
                            try {
                                serviceIndex.upsert(
                                    serviceKey = serviceKey,
                                    device = device
                                )
                            } catch (_: BonjourServiceIndexCapacityException) {
                                logBoundaryOnce(
                                    "service-index-capacity",
                                    "Ignoring Bonjour services because index capacity is full"
                                )
                                return
                            }
                            trySend(serviceIndex.devices())
                        }
                    }

                    try {
                        @Suppress("DEPRECATION")
                        nsdManager.resolveService(service, context.mainExecutor, listener)
                    } catch (e: RuntimeException) {
                        resolveAttempts.completeIfCurrent(serviceKey, resolveToken)
                        Log.w(
                            TAG,
                            "Bonjour service resolve could not be started " +
                                "type=$requestedServiceType exception=${e.javaClass.simpleName}"
                        )
                    }
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {
                serviceInfo?.let { service ->
                    if (!matchesBonjourServiceType(
                            requestedServiceType = requestedServiceType,
                            resolvedServiceType = service.serviceType
                        )
                    ) {
                        Log.w(
                            TAG,
                            "Ignoring lost Bonjour service from unexpected type"
                        )
                        return
                    }
                    serviceIndex.remove(
                        serviceKey = canonicalBonjourServiceKey(
                            service.serviceType,
                            service.serviceName
                        ).also(resolveAttempts::invalidateCurrent),
                        fallbackDeviceId = service.serviceName
                    )
                    trySend(serviceIndex.devices())
                }
            }
        }

        serviceTypes.forEach { discoveredServiceType ->
            val listener = discoveryListenerFor(discoveredServiceType)
            discoveryListeners += listener
            try {
                nsdManager.discoverServices(discoveredServiceType, NsdManager.PROTOCOL_DNS_SD, listener)
            } catch (t: Throwable) {
                close(BonjourDiscoveryException("Bonjour discovery could not be started for $discoveredServiceType", t))
            }
        }

        awaitClose {
            resolveAttempts.clear()
            discoveryListeners.forEach { listener ->
                runCatching { nsdManager.stopServiceDiscovery(listener) }
                    .onFailure { Log.w(TAG, "Failed to stop Bonjour discovery listener", it) }
            }
            multicastLock?.let { releaseMulticastLock(it) }
        }
    }

    /**
     * 从NSD服务信息创建设备对象
     */
    private fun createDeviceFromService(serviceInfo: NsdServiceInfo): DiscoveredDevice {
        val canonicalServiceType = AppleBonjourInterop.canonicalServiceType(serviceInfo.serviceType)
            ?: throw BonjourDiscoveryException(
                "Resolved an unsupported Bonjour service type: ${serviceInfo.serviceType}"
            )
        val canonicalInstanceName = AppleBonjourInterop.canonicalDnsSdInstanceName(
            serviceName = serviceInfo.serviceName,
            observedServiceType = serviceInfo.serviceType
        ) ?: throw BonjourDiscoveryException(
            "Resolved Bonjour service has an invalid instance name: ${serviceInfo.serviceName}"
        )
        val txtRecords = extractTxtRecords(serviceInfo)
        val advertisedDeviceId = AppleBonjourInterop.resolveTxtValue(
            txtRecords,
            "deviceId",
            "device_id",
            "id",
            "uniqueId",
            "unique_id"
        )
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        val deviceId = advertisedDeviceId ?: serviceInfo.serviceName
        val pubKeyFP = AppleBonjourInterop.normalizedPubKeyFingerprint(
            AppleBonjourInterop.resolveTxtValue(
                txtRecords,
                "pubKeyFP",
                "pubKeyFp",
                "pub_key_fp",
                "identityFingerprint",
                "pubKeyFingerprint",
                "publicKeyFingerprint"
            )
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
            put("servicePort:$canonicalServiceType", serviceInfo.port.toString())
            advertisedDeviceId?.let {
                put("serviceDeviceId:$canonicalServiceType", it)
            }
            pubKeyFP?.let {
                put("serviceFingerprint:$canonicalServiceType", it)
            }
            put(
                "serviceInstance:$canonicalServiceType",
                canonicalInstanceName
            )
            serviceInfo.hostAddresses.firstOrNull()?.hostAddress?.takeIf { it.isNotBlank() }?.let { address ->
                put("serviceAddress:$canonicalServiceType", address)
            }
        }
        val resolvedPort = AppleBonjourInterop.preferredPort(serviceInfo.port)

        return DiscoveredDevice(
            id = deviceId,
            name = AppleBonjourInterop.resolveTxtValue(txtRecords, "name", "device", "hostname")
                ?: serviceInfo.serviceName,
            type = parseDeviceType(
                AppleBonjourInterop.resolveTxtValue(txtRecords, "platform", "type")
            ),
            capabilities = AppleBonjourInterop.parseCapabilities(
                rawCapabilities = AppleBonjourInterop.resolveTxtValue(txtRecords, "capabilities", "cap")
            ),
            connectionInfo = ConnectionInfo(
                protocol = DiscoveryProtocol.BONJOUR,
                address = serviceInfo.hostAddresses.firstOrNull()?.hostAddress ?: "",
                port = resolvedPort,
                serviceType = canonicalServiceType,
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
            val v = String(value, Charsets.UTF_8)
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
                .onFailure { Log.w(TAG, "Failed to acquire Bonjour multicast lock", it) }
        }
    }

    private fun releaseMulticastLock(lock: WifiManager.MulticastLock) {
        runCatching {
            if (lock.isHeld) lock.release()
        }.onFailure { Log.w(TAG, "Failed to release Bonjour multicast lock", it) }
    }
}

internal class BonjourDeviceServiceIndex {
    private val serviceKeyToDeviceId = LinkedHashMap<String, String>()
    private val serviceDevicesByDeviceId = LinkedHashMap<String, LinkedHashMap<String, DiscoveredDevice>>()
    private val revisionsByDeviceId = LinkedHashMap<String, Long>()

    @Synchronized
    fun upsert(serviceKey: String, device: DiscoveredDevice) {
        val targetServices = serviceDevicesByDeviceId[device.id].orEmpty()
        val projectedServices = targetServices.filterKeys { it != serviceKey }
        val canonicalServiceType = AppleBonjourInterop.canonicalServiceType(
            device.connectionInfo.serviceType
        ) ?: throw IllegalArgumentException("Bonjour service type is unsupported")
        if (
            serviceKey !in serviceKeyToDeviceId &&
            serviceKeyToDeviceId.size >= MAX_INDEXED_SERVICES
        ) {
            throw BonjourServiceIndexCapacityException()
        }
        if (projectedServices.size >= MAX_SERVICES_PER_DEVICE) {
            throw BonjourServiceIndexCapacityException()
        }
        val sameTypeCount = projectedServices.values.count {
            AppleBonjourInterop.canonicalServiceType(it.connectionInfo.serviceType) ==
                canonicalServiceType
        }
        if (sameTypeCount >= MAX_INSTANCES_PER_CANONICAL_TYPE) {
            throw BonjourServiceIndexCapacityException()
        }
        val previousDeviceId = serviceKeyToDeviceId[serviceKey]
        if (previousDeviceId == device.id) {
            val services = requireNotNull(serviceDevicesByDeviceId[device.id])
            val previousDevice = services[serviceKey]
            services[serviceKey] = device
            if (previousDevice == null || !previousDevice.hasSameSecurityRoute(device)) {
                assignNewRevision(device.id)
            }
            return
        }
        previousDeviceId?.let {
            serviceDevicesByDeviceId[previousDeviceId]?.remove(serviceKey)
            if (serviceDevicesByDeviceId[previousDeviceId]?.isEmpty() == true) {
                serviceDevicesByDeviceId.remove(previousDeviceId)
                revisionsByDeviceId.remove(previousDeviceId)
            }
            if (
                previousDeviceId != device.id &&
                serviceDevicesByDeviceId.containsKey(previousDeviceId)
            ) {
                assignNewRevision(previousDeviceId)
            }
        }
        serviceKeyToDeviceId[serviceKey] = device.id
        val services = serviceDevicesByDeviceId.getOrPut(device.id) { LinkedHashMap() }
        services[serviceKey] = device
        assignNewRevision(device.id)
    }

    @Synchronized
    fun remove(serviceKey: String, fallbackDeviceId: String) {
        val indexedDeviceId = serviceKeyToDeviceId.remove(serviceKey)
        val deviceId = indexedDeviceId ?: fallbackDeviceId
        val services = serviceDevicesByDeviceId[deviceId] ?: return
        if (services.remove(serviceKey) == null && indexedDeviceId == null) return
        if (services.isEmpty()) {
            serviceDevicesByDeviceId.remove(deviceId)
            revisionsByDeviceId.remove(deviceId)
        } else {
            assignNewRevision(deviceId)
        }
    }

    @Synchronized
    fun devices(): List<DiscoveredDevice> =
        serviceDevicesByDeviceId.mapNotNull { (deviceId, serviceDevices) ->
            serviceDevices.values.reduceOrNull(::mergeBonjourDevice)
                ?.let { markAmbiguousServiceTypes(it, serviceDevices.values) }
                ?.let { stampCurrentRevision(deviceId, it) }
        }

    @Synchronized
    internal fun retainedRevisionCount(): Int = revisionsByDeviceId.size

    @Synchronized
    internal fun indexedServiceCountForTest(): Int = serviceKeyToDeviceId.size

    private fun assignNewRevision(deviceId: String) {
        revisionsByDeviceId[deviceId] = ProcessBonjourRevisionAllocator.next()
    }

    private fun stampCurrentRevision(deviceId: String, device: DiscoveredDevice): DiscoveredDevice =
        device.copy(
            connectionInfo = device.connectionInfo.copy(
                extra = device.connectionInfo.extra +
                    (BONJOUR_SERVICE_INDEX_REVISION_KEY to
                        requireNotNull(revisionsByDeviceId[deviceId]).toString())
            )
        )

    private fun markAmbiguousServiceTypes(
        device: DiscoveredDevice,
        services: Collection<DiscoveredDevice>
    ): DiscoveredDevice {
        val ambiguousTypes = services
            .mapNotNull { AppleBonjourInterop.canonicalServiceType(it.connectionInfo.serviceType) }
            .groupingBy { it }
            .eachCount()
            .filterValues { it != 1 }
            .keys
        if (ambiguousTypes.isEmpty()) return device
        return device.copy(
            connectionInfo = device.connectionInfo.copy(
                extra = device.connectionInfo.extra + ambiguousTypes.associate {
                    "serviceAmbiguous:$it" to "true"
                }
            )
        )
    }

    private companion object {
        const val BONJOUR_SERVICE_INDEX_REVISION_KEY = "serviceIndexRevision"
        const val MAX_INDEXED_SERVICES = 256
        const val MAX_SERVICES_PER_DEVICE = 6
        const val MAX_INSTANCES_PER_CANONICAL_TYPE = 2
    }
}

private fun DiscoveredDevice.hasSameSecurityRoute(other: DiscoveredDevice): Boolean {
    val canonicalType = AppleBonjourInterop.canonicalServiceType(connectionInfo.serviceType)
        ?: return false
    if (canonicalType != AppleBonjourInterop.canonicalServiceType(other.connectionInfo.serviceType)) {
        return false
    }
    val routeKeys = listOf(
        "servicePort:$canonicalType",
        "serviceAddress:$canonicalType",
        "serviceInstance:$canonicalType",
        "serviceDeviceId:$canonicalType",
        "serviceFingerprint:$canonicalType"
    )
    return id == other.id &&
        connectionInfo.address == other.connectionInfo.address &&
        connectionInfo.port == other.connectionInfo.port &&
        routeKeys.all { key -> connectionInfo.extra[key] == other.connectionInfo.extra[key] }
}

/** Prevents an old snapshot from comparing equal after discovery is restarted in this process. */
private object ProcessBonjourRevisionAllocator {
    private var nextRevision = 0L

    @Synchronized
    fun next(): Long {
        check(nextRevision != Long.MAX_VALUE) { "Bonjour discovery revision exhausted" }
        nextRevision += 1L
        return nextRevision
    }
}

internal class BonjourServiceIndexCapacityException : IllegalStateException(
    "Bonjour service index capacity is full"
)

/** Rejects late/out-of-order NSD resolve callbacks after loss or a newer resolve attempt. */
internal class BonjourResolveAttemptIndex {
    private val lock = Any()
    private val currentTokens = LinkedHashMap<String, Long>()
    private val outstandingTokens = LinkedHashMap<String, Long>()
    private var nextToken = 0L

    fun begin(serviceKey: String): Long = synchronized(lock) {
        if (serviceKey in outstandingTokens) {
            throw BonjourResolveAlreadyPendingException()
        }
        if (outstandingTokens.size >= MAX_PENDING_RESOLVES) {
            throw BonjourResolveCapacityException()
        }
        check(nextToken != Long.MAX_VALUE) { "Bonjour resolve token exhausted" }
        val token = ++nextToken
        currentTokens[serviceKey] = token
        outstandingTokens[serviceKey] = token
        token
    }

    fun completeIfCurrent(serviceKey: String, token: Long): Boolean = synchronized(lock) {
        val isCurrent = currentTokens[serviceKey] == token
        if (isCurrent) {
            currentTokens.remove(serviceKey)
        }
        if (outstandingTokens[serviceKey] == token) {
            outstandingTokens.remove(serviceKey)
        }
        isCurrent
    }

    /** Marks the current generation stale without pretending the OS resolve has completed. */
    fun invalidateCurrent(serviceKey: String) {
        synchronized(lock) {
            currentTokens.remove(serviceKey)
        }
    }

    fun clear() {
        synchronized(lock) {
            currentTokens.clear()
            outstandingTokens.clear()
        }
    }

    internal fun pendingCountForTest(): Int = synchronized(lock) { outstandingTokens.size }

    internal fun currentCountForTest(): Int = synchronized(lock) { currentTokens.size }

    private companion object {
        const val MAX_PENDING_RESOLVES = 256
    }
}

internal class BonjourResolveCapacityException : IllegalStateException(
    "Bonjour resolve capacity is full"
)

internal class BonjourResolveAlreadyPendingException : IllegalStateException(
    "Bonjour service already has an outstanding resolve"
)

internal fun mergeBonjourDevice(existing: DiscoveredDevice, incoming: DiscoveredDevice): DiscoveredDevice {
    val incomingIsMain = incoming.connectionInfo.serviceType == AppleBonjourInterop.MAIN_SERVICE_TYPE
    val existingIsMain = existing.connectionInfo.serviceType == AppleBonjourInterop.MAIN_SERVICE_TYPE
    val primary = if (incomingIsMain || !existingIsMain) incoming else existing
    val secondary = if (primary == incoming) existing else incoming
    return primary.copy(
        capabilities = existing.capabilities + incoming.capabilities,
        connectionInfo = primary.connectionInfo.copy(
            txtRecords = existing.connectionInfo.txtRecords + incoming.connectionInfo.txtRecords,
            extra = existing.connectionInfo.extra + incoming.connectionInfo.extra
        ),
        signalStrength = maxOf(existing.signalStrength, incoming.signalStrength),
        lastSeen = maxOf(existing.lastSeen, incoming.lastSeen),
        isConnected = existing.isConnected || incoming.isConnected,
        batteryLevel = primary.batteryLevel ?: secondary.batteryLevel,
        osVersion = primary.osVersion ?: secondary.osVersion
    )
}
