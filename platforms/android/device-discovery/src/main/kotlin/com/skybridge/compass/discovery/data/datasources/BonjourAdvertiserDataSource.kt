package com.skybridge.compass.discovery.data.datasources

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import com.skybridge.compass.discovery.data.codec.BonjourTxtRecordCodec
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.shared.platform.AndroidPlatformMetadata
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.lang.reflect.Method
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.SocketException
import java.util.Enumeration
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Bonjour/mDNS 广播（Android NSD）。
 *
 * 目标：与成熟的 macOS/iOS Pro release 互相发现：
 * - Required TXT keys: `deviceId`, `pubKeyFP`, `uniqueId`
 * - Optional TXT keys: `platform`, `version`, `osVersion`, `name`
 *
 * 注意：Android NSD 的 TXT 键名存在长度/字符限制（不同系统实现差异较大），
 * 对于超过限制的键会自动回退到短键（例如 `cryptoSuites` -> `suites`）。
 */
@Singleton
class BonjourAdvertiserDataSource @Inject constructor(
    @param:ApplicationContext private val context: Context
) {
    private companion object {
        private const val TAG = "BonjourAdvertiser"
        private const val NSD_REGISTRATION_TIMEOUT_MS = 10_000L
    }

    private data class ActiveRegistration(
        val serviceType: String,
        val listener: NsdManager.RegistrationListener
    )

    data class Advertisement(
        val deviceId: String,
        val pubKeyFP: String,
        val uniqueId: String = deviceId,
        val name: String,
        val platform: String = "android",
        val version: String = "1.0.0",
        val osVersion: String = AndroidPlatformMetadata.versionString(Build.VERSION.RELEASE, Build.VERSION.SDK_INT),
        val model: String? = Build.MODEL,
        val capabilities: String? = null,
        val cryptoSuites: String? = null,
        val remoteVideoFormats: Set<String> = emptySet(),
        val supportsSoa: Boolean = true
    )

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val nsdCallbackExecutor = context.mainExecutor

    private val advertisingStatusState =
        MutableStateFlow<BonjourAdvertisingStatus>(BonjourAdvertisingStatus.Idle)

    /**
     * Observable advertising registration status (R3.13). On terminal registration failure this
     * emits [BonjourAdvertisingStatus.Failed] carrying a UI-displayable reason. Browsing is driven
     * by a separate data source and is unaffected by transitions on this flow.
     */
    val advertisingStatus: StateFlow<BonjourAdvertisingStatus> = advertisingStatusState.asStateFlow()

    private val registrationLock = Any()
    private val activeRegistrations = LinkedHashMap<String, ActiveRegistration>()
    @Volatile private var multicastLock: WifiManager.MulticastLock? = null
    private val setAttributeStringMethod: Method? by lazy(LazyThreadSafetyMode.PUBLICATION) {
        runCatching {
            NsdServiceInfo::class.java.getMethod(
                "setAttribute",
                String::class.java,
                String::class.java
            )
        }.getOrNull()
    }
    private val setAttributeBytesMethod: Method? by lazy(LazyThreadSafetyMode.PUBLICATION) {
        runCatching {
            NsdServiceInfo::class.java.getMethod(
                "setAttribute",
                String::class.java,
                ByteArray::class.java
            )
        }.getOrNull()
    }

    suspend fun startAdvertising(
        port: Int,
        advertisement: Advertisement,
        serviceType: String = "_skybridge._tcp"
    ): String = startAdvertising(
        port = port,
        advertisement = advertisement,
        serviceType = serviceType,
        delayMs = { kotlinx.coroutines.delay(it) }
    )

    /**
     * Registration entry point with an injectable backoff clock so the 1s/2s/4s retry schedule
     * (R3.13) can be driven deterministically in unit tests. The initial attempt plus up to 3
     * retries each get their own [NSD_REGISTRATION_TIMEOUT_MS] registration timeout; if the success
     * callback never arrives within that window the attempt is treated as a transient failure and
     * retried. After the retries are exhausted the advertising status is marked failed with a reason
     * and the last error is rethrown so the caller can release resources.
     */
    internal suspend fun startAdvertising(
        port: Int,
        advertisement: Advertisement,
        serviceType: String,
        delayMs: suspend (Long) -> Unit
    ): String {
        stopAdvertising(serviceType)
        BonjourLocalNetworkPolicy.requireAdvertisingNetwork(currentAdvertisingTransports())
        BonjourLocalNetworkPermissionPolicy.requireLocalNetworkPermission(
            context = context,
            sdkInt = Build.VERSION.SDK_INT
        )

        val serviceInfo = buildServiceInfo(
            port = port,
            advertisement = advertisement,
            serviceType = serviceType
        )

        val registrar = BonjourAdvertisingRegistrar(
            status = advertisingStatusState,
            delayMs = delayMs
        )
        return registrar.register(serviceType = serviceType) {
            // Each attempt gets its own registration timeout; a timeout is surfaced as a transient
            // BonjourAdvertisingException so the retry policy (not structured cancellation) handles it.
            acquireMulticastLockIfNeeded()
            try {
                withTimeout(NSD_REGISTRATION_TIMEOUT_MS) {
                    registerService(serviceType = serviceType, serviceInfo = serviceInfo)
                }
            } catch (error: TimeoutCancellationException) {
                stopAdvertising(serviceType)
                throw BonjourAdvertisingException(
                    "NSD registration timed out after ${NSD_REGISTRATION_TIMEOUT_MS}ms for $serviceType",
                    error
                )
            } catch (error: Throwable) {
                stopAdvertising(serviceType)
                throw error
            }
        }
    }

    private suspend fun registerService(
        serviceType: String,
        serviceInfo: NsdServiceInfo
    ): String =
        suspendCancellableCoroutine { cont ->
            val done = AtomicBoolean(false)

            val listener = object : NsdManager.RegistrationListener {
                override fun onRegistrationFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                    Log.e(
                        TAG,
                        "NSD registration failed serviceType=$serviceType " +
                            "serviceName=${serviceInfo?.serviceName ?: "unknown"} errorCode=$errorCode"
                    )
                    if (done.compareAndSet(false, true)) {
                        clearRegistration(serviceType, this)
                        cont.resumeWithException(
                            IllegalStateException("NSD registration failed (errorCode=$errorCode)")
                        )
                    }
                }

                override fun onServiceRegistered(serviceInfo: NsdServiceInfo?) {
                    Log.i(
                        TAG,
                        "NSD service registered serviceType=$serviceType " +
                            "serviceName=${serviceInfo?.serviceName ?: "unknown"} " +
                            "port=${serviceInfo?.port ?: 0}"
                    )
                    if (done.compareAndSet(false, true)) {
                        val name = serviceInfo?.serviceName ?: "unknown"
                        cont.resume(name)
                    }
                }

                override fun onServiceUnregistered(serviceInfo: NsdServiceInfo?) {
                    Log.i(
                        TAG,
                        "NSD service unregistered serviceType=$serviceType " +
                            "serviceName=${serviceInfo?.serviceName ?: "unknown"}"
                    )
                    clearRegistration(serviceType, this)
                }

                override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                    Log.w(
                        TAG,
                        "NSD unregistration failed serviceType=$serviceType " +
                            "serviceName=${serviceInfo?.serviceName ?: "unknown"} errorCode=$errorCode"
                    )
                    clearRegistration(serviceType, this)
                }
            }

            synchronized(registrationLock) {
                activeRegistrations[serviceType] = ActiveRegistration(
                    serviceType = serviceType,
                    listener = listener
                )
            }

            val registrationResult = runCatching {
                Log.i(
                    TAG,
                    "Registering NSD service serviceType=$serviceType " +
                        "serviceName=${serviceInfo.serviceName}"
                )
                registerWithNsdManager(serviceInfo = serviceInfo, listener = listener)
            }

            if (registrationResult.isFailure && done.compareAndSet(false, true)) {
                clearRegistration(serviceType, listener)
                cont.resumeWithException(
                    registrationResult.exceptionOrNull()
                        ?: IllegalStateException("NSD registration failed")
                )
                return@suspendCancellableCoroutine
            }

            cont.invokeOnCancellation {
                if (done.compareAndSet(false, true)) {
                    stopAdvertising(serviceType)
                }
            }
        }

    private fun registerWithNsdManager(
        serviceInfo: NsdServiceInfo,
        listener: NsdManager.RegistrationListener
    ) {
        @Suppress("DEPRECATION")
        nsdManager.registerService(
            serviceInfo,
            NsdManager.PROTOCOL_DNS_SD,
            nsdCallbackExecutor,
            listener
        )
    }

    fun stopAdvertising(serviceType: String) {
        val listener = synchronized(registrationLock) {
            activeRegistrations.remove(serviceType)?.listener
        } ?: return

        try {
            @Suppress("DEPRECATION")
            nsdManager.unregisterService(listener)
        } catch (error: Throwable) {
            Log.w(TAG, "Failed to unregister NSD serviceType=$serviceType", error)
        }
        releaseMulticastLockIfIdle()
    }

    fun stopAdvertising() {
        val registrations = synchronized(registrationLock) {
            val current = activeRegistrations.values.toList()
            activeRegistrations.clear()
            current
        }

        registrations.forEach { registration ->
            try {
                @Suppress("DEPRECATION")
                nsdManager.unregisterService(registration.listener)
            } catch (error: Throwable) {
                Log.w(TAG, "Failed to unregister NSD serviceType=${registration.serviceType}", error)
            }
        }
        releaseMulticastLock()
        advertisingStatusState.value = BonjourAdvertisingStatus.Idle
    }

    private fun currentAdvertisingTransports(): Set<BonjourAdvertisingTransport> =
        BonjourLocalNetworkPolicy.advertisingTransports(
            capabilities = connectivityManager.activeNetwork
                ?.let(connectivityManager::getNetworkCapabilities),
            isAndroidEmulator = AndroidEmulatorNetworkPolicy.isAndroidEmulator(),
            hasEmulatorLocalInterface = AndroidEmulatorNetworkPolicy.hasEmulatorLocalInterface()
        )

    private fun buildServiceInfo(
        port: Int,
        advertisement: Advertisement,
        serviceType: String
    ): NsdServiceInfo {
        val serviceInfo = NsdServiceInfo().apply {
            this.serviceType = serviceType
            this.port = port
            this.serviceName = sanitizeInstanceName(advertisement.uniqueId.ifBlank { advertisement.deviceId })
        }

        // Assemble the intended TXT key/value map and route it through the pure-Kotlin codec so the
        // RFC 6763 byte budget (255 B per pair, 1300 B per record) is enforced BEFORE any bytes are
        // handed to NsdServiceInfo. The map itself is passed to NsdServiceInfo unchanged — the codec
        // only validates; it does not rewrite keys or values. Preserves existing key names and the
        // capabilities/cap and cryptoSuites/suites short-key aliases (no new keys are introduced).
        val pubKeyFingerprint = AppleBonjourInterop.normalizedPubKeyFingerprint(advertisement.pubKeyFP)
            ?: throw BonjourAdvertisingException("Required Bonjour TXT attribute 'pubKeyFP' must be 64 lowercase hex characters")
        BonjourAdvertisementTxtRecord.validateBudget(
            advertisement = advertisement,
            normalizedPubKeyFingerprint = pubKeyFingerprint
        )

        setRequiredTxtAttribute(serviceInfo, "deviceId", advertisement.deviceId.trim())
        setRequiredTxtAttribute(serviceInfo, "pubKeyFP", pubKeyFingerprint)
        setRequiredTxtAttribute(serviceInfo, "uniqueId", advertisement.uniqueId.trim())

        setTxtAttribute(serviceInfo, "platform", advertisement.platform.trim())
        setTxtAttribute(serviceInfo, "version", advertisement.version.trim())
        setTxtAttribute(serviceInfo, "osVersion", advertisement.osVersion.trim())
        setTxtAttribute(serviceInfo, "name", advertisement.name.trim())
        setTxtAttribute(serviceInfo, "model", advertisement.model?.trim())

        // Optional: try long keys, fallback to short keys if Android rejects them.
        setTxtAttributeWithFallback(serviceInfo, "capabilities", "cap", advertisement.capabilities)
        setTxtAttributeWithFallback(serviceInfo, "cryptoSuites", "suites", advertisement.cryptoSuites)
        val remoteFormats = AppleBonjourInterop.remoteVideoFormatsCsv(advertisement.remoteVideoFormats)
        setTxtAttributeWithFallback(
            serviceInfo,
            "remoteVideoFormats",
            AppleBonjourInterop.REMOTE_VIDEO_FORMATS_FALLBACK_KEY,
            remoteFormats
        )
        if (advertisement.supportsSoa) {
            setRequiredTxtAttribute(serviceInfo, AppleBonjourInterop.HS_SOA_KEY, "1")
        }

        return serviceInfo
    }

    private fun setRequiredTxtAttribute(serviceInfo: NsdServiceInfo, key: String, value: String) {
        val v = value.trim()
        if (v.isEmpty()) {
            throw BonjourAdvertisingException("Required Bonjour TXT attribute '$key' is blank")
        }
        if (!trySetAttributeCompat(serviceInfo, key, v)) {
            throw BonjourAdvertisingException("Failed to set required Bonjour TXT attribute '$key'")
        }
    }

    private fun setTxtAttribute(serviceInfo: NsdServiceInfo, key: String, value: String?) {
        val v = value?.trim().orEmpty()
        if (v.isEmpty()) return
        trySetAttributeCompat(serviceInfo, key, v)
    }

    private fun setTxtAttributeWithFallback(
        serviceInfo: NsdServiceInfo,
        primaryKey: String,
        fallbackKey: String,
        value: String?
    ) {
        val v = value?.trim().orEmpty()
        if (v.isEmpty()) return
        if (trySetAttributeCompat(serviceInfo, primaryKey, v)) return
        if (!trySetAttributeCompat(serviceInfo, fallbackKey, v)) {
            throw BonjourAdvertisingException(
                "Failed to set Bonjour TXT attribute '$primaryKey' or fallback '$fallbackKey'"
            )
        }
    }

    private fun trySetAttributeCompat(
        serviceInfo: NsdServiceInfo,
        key: String,
        value: String
    ): Boolean {
        val methodString = setAttributeStringMethod
        if (methodString != null) {
            val ok = runCatching {
                methodString.invoke(serviceInfo, key, value)
            }.isSuccess
            if (ok) return true
        }
        val methodBytes = setAttributeBytesMethod ?: return false
        return runCatching {
            methodBytes.invoke(serviceInfo, key, value.toByteArray(Charsets.UTF_8))
        }.isSuccess
    }

    private fun sanitizeInstanceName(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return "skybridge"

        val sb = StringBuilder(trimmed.length)
        for (ch in trimmed) {
            when {
                ch.isLetterOrDigit() -> sb.append(ch)
                ch == '-' || ch == '_' -> sb.append(ch)
                else -> sb.append('-')
            }
        }
        return sb.toString().trim('-').ifBlank { "skybridge" }.take(63)
    }

    private fun clearRegistration(
        serviceType: String,
        listener: NsdManager.RegistrationListener
    ) {
        synchronized(registrationLock) {
            val active = activeRegistrations[serviceType] ?: return
            if (active.listener === listener) {
                activeRegistrations.remove(serviceType)
            }
        }
        releaseMulticastLockIfIdle()
    }

    private fun acquireMulticastLockIfNeeded() {
        val shouldAcquire = synchronized(registrationLock) {
            activeRegistrations.isEmpty()
        }
        if (shouldAcquire) {
            acquireMulticastLock()
        }
    }

    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        multicastLock = wifi.createMulticastLock("skybridge-mdns-advertise").apply {
            setReferenceCounted(false)
            try {
                acquire()
            } catch (error: Throwable) {
                multicastLock = null
                throw BonjourAdvertisingException("Failed to acquire Wi-Fi multicast lock", error)
            }
        }
    }

    private fun releaseMulticastLockIfIdle() {
        val shouldRelease = synchronized(registrationLock) {
            activeRegistrations.isEmpty()
        }
        if (shouldRelease) {
            releaseMulticastLock()
        }
    }

    private fun releaseMulticastLock() {
        val lock = multicastLock ?: return
        multicastLock = null
        try {
            if (lock.isHeld) lock.release()
        } catch (error: Throwable) {
            Log.w(TAG, "Failed to release Wi-Fi multicast lock", error)
        }
    }
}

/**
 * Pure-Kotlin (Android-free) assembly + length-budget validation of the advertised TXT record.
 *
 * The advertiser writes each TXT pair to [NsdServiceInfo] with its existing required/optional/
 * fallback semantics; this helper mirrors that exact key/value set into a `Map<String, ByteArray>`
 * and routes it through [BonjourTxtRecordCodec] so the RFC 6763 byte budget (255 B per pair, 1300 B
 * per whole record) is enforced before registration. It introduces no new keys — only the existing
 * `deviceId`, `pubKeyFP`, `uniqueId`, `platform`, `version`, `osVersion`, `name`, `model`,
 * `capabilities`, `cryptoSuites`, `remoteVideoFormats` primary keys plus the `hs_soa` flag — and it
 * validates against the (larger) primary keys so a record that fits the primary keys also fits the
 * `cap` / `suites` short-key aliases the advertiser may fall back to.
 */
internal object BonjourAdvertisementTxtRecord {

    /** Builds the intended primary-key TXT map exactly as the advertiser writes it (blank pairs omitted). */
    fun buildFields(
        advertisement: BonjourAdvertiserDataSource.Advertisement,
        normalizedPubKeyFingerprint: String
    ): Map<String, ByteArray> {
        val fields = LinkedHashMap<String, ByteArray>()

        putNonBlank(fields, "deviceId", advertisement.deviceId)
        putNonBlank(fields, "pubKeyFP", normalizedPubKeyFingerprint)
        putNonBlank(fields, "uniqueId", advertisement.uniqueId)
        putNonBlank(fields, "platform", advertisement.platform)
        putNonBlank(fields, "version", advertisement.version)
        putNonBlank(fields, "osVersion", advertisement.osVersion)
        putNonBlank(fields, "name", advertisement.name)
        putNonBlank(fields, "model", advertisement.model)
        putNonBlank(fields, "capabilities", advertisement.capabilities)
        putNonBlank(fields, "cryptoSuites", advertisement.cryptoSuites)
        putNonBlank(
            fields,
            AppleBonjourInterop.REMOTE_VIDEO_FORMATS_KEY,
            AppleBonjourInterop.remoteVideoFormatsCsv(advertisement.remoteVideoFormats)
        )
        if (advertisement.supportsSoa) {
            putNonBlank(fields, AppleBonjourInterop.HS_SOA_KEY, "1")
        }
        return fields
    }

    /**
     * Validates the assembled TXT record against the codec's length budget, translating a codec
     * length violation into a [BonjourAdvertisingException] so registration fails fast and loudly.
     */
    fun validateBudget(
        advertisement: BonjourAdvertiserDataSource.Advertisement,
        normalizedPubKeyFingerprint: String
    ) {
        val fields = buildFields(advertisement, normalizedPubKeyFingerprint)
        when (val validation = BonjourTxtRecordCodec.validate(fields)) {
            is BonjourTxtRecordCodec.TxtValidation.Valid -> Unit
            is BonjourTxtRecordCodec.TxtValidation.PairTooLarge -> throw BonjourAdvertisingException(
                "Bonjour TXT pair '${validation.key}' encodes to ${validation.encodedPairBytes} bytes, " +
                    "exceeding the ${BonjourTxtRecordCodec.MAX_PAIR_BYTES} byte per-pair limit"
            )
            is BonjourTxtRecordCodec.TxtValidation.RecordTooLarge -> throw BonjourAdvertisingException(
                "Bonjour TXT record encodes to ${validation.encodedRecordBytes} bytes, " +
                    "exceeding the ${BonjourTxtRecordCodec.MAX_RECORD_BYTES} byte record limit"
            )
        }
    }

    private fun putNonBlank(fields: MutableMap<String, ByteArray>, key: String, value: String?) {
        val trimmed = value?.trim().orEmpty()
        if (trimmed.isNotEmpty()) {
            fields[key] = trimmed.toByteArray(Charsets.UTF_8)
        }
    }
}

class BonjourAdvertisingException(
    message: String,
    cause: Throwable? = null
) : IllegalStateException(message, cause)

class BonjourLocalNetworkPermissionException(message: String) : SecurityException(message)

internal enum class BonjourAdvertisingTransport {
    WIFI,
    ETHERNET,
    LOCAL_NETWORK,
    ANDROID_EMULATOR_NAT
}

internal object BonjourLocalNetworkPolicy {
    fun requireAdvertisingNetwork(transports: Set<BonjourAdvertisingTransport>) {
        if (transports.any(::isSupportedAdvertisingTransport)) return
        val activeTransports = transports.sortedBy { it.name }.joinToString(",").ifBlank { "none" }
        val emulatorHint = if (BonjourAdvertisingTransport.ANDROID_EMULATOR_NAT in transports) {
            "; Android emulator NAT is diagnostic-only and does not prove Mac/iOS Bonjour visibility"
        } else {
            ""
        }
        throw BonjourAdvertisingException(
            "Bonjour advertising requires an active default Wi-Fi, Ethernet, or Android local network; " +
                "active transports=$activeTransports$emulatorHint"
        )
    }

    fun advertisingTransports(capabilities: NetworkCapabilities): Set<BonjourAdvertisingTransport> = buildSet {
        addPlatformTransports(capabilities)
    }

    fun advertisingTransports(
        capabilities: NetworkCapabilities?,
        isAndroidEmulator: Boolean,
        hasEmulatorLocalInterface: Boolean
    ): Set<BonjourAdvertisingTransport> = buildSet {
        if (capabilities == null) return@buildSet
        addPlatformTransports(capabilities)
        addAll(
            emulatorAdvertisingTransports(
                isAndroidEmulator = isAndroidEmulator,
                hasCellularActiveNetwork = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
                hasEmulatorLocalInterface = hasEmulatorLocalInterface
            )
        )
    }

    fun emulatorAdvertisingTransports(
        isAndroidEmulator: Boolean,
        hasCellularActiveNetwork: Boolean,
        hasEmulatorLocalInterface: Boolean
    ): Set<BonjourAdvertisingTransport> {
        if (!isAndroidEmulator || !hasCellularActiveNetwork || !hasEmulatorLocalInterface) {
            return emptySet()
        }
        return setOf(BonjourAdvertisingTransport.ANDROID_EMULATOR_NAT)
    }

    private fun MutableSet<BonjourAdvertisingTransport>.addPlatformTransports(
        capabilities: NetworkCapabilities
    ) {
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            add(BonjourAdvertisingTransport.WIFI)
        }
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
            add(BonjourAdvertisingTransport.ETHERNET)
        }
        if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_LOCAL_NETWORK)) {
            add(BonjourAdvertisingTransport.LOCAL_NETWORK)
        }
    }

    private fun isSupportedAdvertisingTransport(transport: BonjourAdvertisingTransport): Boolean =
        when (transport) {
            BonjourAdvertisingTransport.WIFI,
            BonjourAdvertisingTransport.ETHERNET,
            BonjourAdvertisingTransport.LOCAL_NETWORK -> true
            BonjourAdvertisingTransport.ANDROID_EMULATOR_NAT -> false
        }
}

object BonjourLocalNetworkPermissionPolicy {
    // ACCESS_LOCAL_NETWORK was added in Android 17 (API 37). The app targets API 37, so it must
    // declare and request this runtime permission on API 37+, but it must not require an unknown
    // API-37 permission on Android 16 (API 36). Android 16's optional compatibility restriction is
    // covered separately by NEARBY_WIFI_DEVICES in PermissionManager.Feature.DEVICE_DISCOVERY.
    private const val LOCAL_NETWORK_PERMISSION_API = 37

    // Use the stable platform permission name instead of referencing the API-37 field from code
    // whose minSdk is 36. This keeps the API boundary explicit and avoids an unsafe inlined-API
    // reference on Android 16.
    private const val ACCESS_LOCAL_NETWORK_PERMISSION =
        "android.permission.ACCESS_LOCAL_NETWORK"

    fun isLocalNetworkPermissionRequired(sdkInt: Int): Boolean =
        sdkInt >= LOCAL_NETWORK_PERMISSION_API

    fun requiredPermission(sdkInt: Int): String? =
        ACCESS_LOCAL_NETWORK_PERMISSION
            .takeIf { isLocalNetworkPermissionRequired(sdkInt) }

    fun isGranted(context: Context, sdkInt: Int): Boolean {
        val permission = requiredPermission(sdkInt) ?: return true
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    fun requireLocalNetworkPermission(context: Context, sdkInt: Int) {
        if (isGranted(context, sdkInt)) return
        throw BonjourLocalNetworkPermissionException(
            "Bonjour requires android.permission.ACCESS_LOCAL_NETWORK on Android API 37+"
        )
    }
}

private object AndroidEmulatorNetworkPolicy {
    fun isAndroidEmulator(): Boolean {
        val fingerprint = Build.FINGERPRINT.lowercase(Locale.ROOT)
        val model = Build.MODEL.lowercase(Locale.ROOT)
        val product = Build.PRODUCT.lowercase(Locale.ROOT)
        val manufacturer = Build.MANUFACTURER.lowercase(Locale.ROOT)
        return fingerprint.contains("generic") ||
            fingerprint.contains("emulator") ||
            model.contains("sdk") ||
            model.contains("emulator") ||
            product.contains("sdk") ||
            manufacturer.contains("genymotion")
    }

    fun hasEmulatorLocalInterface(): Boolean =
        networkInterfaces()
            ?.asSequence()
            ?.filter(::isEligibleEmulatorInterface)
            ?.flatMap { it.inetAddresses.asSequence() }
            ?.filterIsInstance<Inet4Address>()
            ?.map { it.hostAddress.orEmpty() }
            ?.any { address ->
                address.startsWith("10.0.2.") || address.startsWith("10.0.3.")
            } == true

    private fun networkInterfaces(): Enumeration<NetworkInterface>? =
        try {
            NetworkInterface.getNetworkInterfaces()
        } catch (error: SocketException) {
            throw BonjourAdvertisingException(
                "Failed to inspect local network interfaces for Android emulator Bonjour policy",
                error
            )
        }

    private fun isEligibleEmulatorInterface(networkInterface: NetworkInterface): Boolean =
        try {
            networkInterface.isUp &&
                !networkInterface.isLoopback &&
                networkInterface.supportsMulticast()
        } catch (error: SocketException) {
            throw BonjourAdvertisingException(
                "Failed to inspect local network interface '${networkInterface.name}' " +
                    "for Android emulator Bonjour policy",
                error
            )
        }
}
