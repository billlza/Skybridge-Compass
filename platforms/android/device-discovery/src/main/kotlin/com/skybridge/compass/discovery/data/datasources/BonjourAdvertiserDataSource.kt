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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
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
        private const val NSD_UNREGISTRATION_TIMEOUT_MS = 10_000L
    }

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
    private val registrationLeases = BonjourRegistrationLeaseRegistry<NsdManager.RegistrationListener>()
    private var multicastLock: WifiManager.MulticastLock? = null
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
            // A previous timed-out callback can still own the exact lease. Every retry first
            // completes that lease's stop transaction instead of creating a parallel registration.
            stopAdvertising(serviceType)
            // Each attempt gets its own registration timeout; a timeout is surfaced as a transient
            // BonjourAdvertisingException so the retry policy (not structured cancellation) handles it.
            try {
                withTimeoutOrNull(NSD_REGISTRATION_TIMEOUT_MS) {
                    registerService(serviceType = serviceType, serviceInfo = serviceInfo)
                } ?: throw BonjourAdvertisingException(
                    "NSD registration timed out after ${NSD_REGISTRATION_TIMEOUT_MS}ms for $serviceType"
                )
            } catch (error: CancellationException) {
                withContext(NonCancellable) {
                    runCatching { stopAdvertising(serviceType) }
                        .exceptionOrNull()
                        ?.let(error::addSuppressed)
                }
                throw error
            } catch (error: Exception) {
                runCatching { stopAdvertising(serviceType) }
                    .exceptionOrNull()
                    ?.let(error::addSuppressed)
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
            lateinit var registration: BonjourRegistrationLeaseRegistry.Lease<NsdManager.RegistrationListener>

            val listener = object : NsdManager.RegistrationListener {
                override fun onRegistrationFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                    Log.e(
                        TAG,
                        "NSD registration failed serviceType=$serviceType " +
                            "serviceName=${serviceInfo?.serviceName ?: "unknown"} errorCode=$errorCode"
                    )
                    val failure = IllegalStateException(
                        "NSD registration failed (errorCode=$errorCode)"
                    )
                    retireRegistration(registration)?.let(failure::addSuppressed)
                    if (done.compareAndSet(false, true)) {
                        cont.resumeWithException(failure)
                    }
                }

                override fun onServiceRegistered(serviceInfo: NsdServiceInfo?) {
                    Log.i(
                        TAG,
                        "NSD service registered serviceType=$serviceType " +
                            "serviceName=${serviceInfo?.serviceName ?: "unknown"} " +
                            "port=${serviceInfo?.port ?: 0}"
                    )
                    val shouldUnregister = synchronized(registrationLock) {
                        registrationLeases.markRegistered(registration)
                    }
                    if (done.compareAndSet(false, true)) {
                        val name = serviceInfo?.serviceName ?: "unknown"
                        cont.resume(name)
                    }
                    if (shouldUnregister) requestUnregisterExact(registration)
                }

                override fun onServiceUnregistered(serviceInfo: NsdServiceInfo?) {
                    Log.i(
                        TAG,
                        "NSD service unregistered serviceType=$serviceType " +
                            "serviceName=${serviceInfo?.serviceName ?: "unknown"}"
                    )
                    completeUnregistration(registration)
                }

                override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                    Log.w(
                        TAG,
                        "NSD unregistration failed serviceType=$serviceType " +
                            "serviceName=${serviceInfo?.serviceName ?: "unknown"} errorCode=$errorCode"
                    )
                    failUnregistration(
                        registration = registration,
                        error = BonjourAdvertisingException(
                            "NSD unregistration failed (errorCode=$errorCode) for $serviceType"
                        )
                    )
                }
            }

            synchronized(registrationLock) {
                acquireMulticastLockLockedIfNeeded()
                registration = registrationLeases.install(serviceType, listener)
            }

            val registrationResult = runCatching {
                Log.i(
                    TAG,
                    "Registering NSD service serviceType=$serviceType " +
                        "serviceName=${serviceInfo.serviceName}"
                )
                registerWithNsdManager(serviceInfo = serviceInfo, listener = listener)
            }

            if (registrationResult.isFailure) {
                val failure = registrationResult.exceptionOrNull()
                    ?: IllegalStateException("NSD registration failed")
                retireRegistration(registration)?.let(failure::addSuppressed)
                if (done.compareAndSet(false, true)) {
                    cont.resumeWithException(failure)
                }
                return@suspendCancellableCoroutine
            }

            cont.invokeOnCancellation {
                done.compareAndSet(false, true)
                val claim = synchronized(registrationLock) {
                    registrationLeases.claimStop(registration)
                }
                if (claim?.shouldUnregister == true) requestUnregisterExact(registration)
            }
        }

    private fun registerWithNsdManager(
        serviceInfo: NsdServiceInfo,
        listener: NsdManager.RegistrationListener
    ) {
        nsdManager.registerService(
            serviceInfo,
            NsdManager.PROTOCOL_DNS_SD,
            nsdCallbackExecutor,
            listener
        )
    }

    suspend fun stopAdvertising(serviceType: String) {
        val registration = synchronized(registrationLock) {
            registrationLeases.current(serviceType)
        }
        if (registration == null) {
            releaseOrphanMulticastLockIfIdle()
        } else {
            unregisterAndAwait(registration)
        }
    }

    suspend fun stopAdvertising() {
        val registrations = synchronized(registrationLock) {
            registrationLeases.snapshot()
        }
        var failure: Exception? = null
        registrations.forEach { registration ->
            try {
                unregisterAndAwait(registration)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                val firstFailure = failure
                if (firstFailure == null) failure = error else firstFailure.addSuppressed(error)
            }
        }
        try {
            releaseOrphanMulticastLockIfIdle()
        } catch (error: Exception) {
            val firstFailure = failure
            if (firstFailure == null) failure = error else firstFailure.addSuppressed(error)
        }
        failure?.let { throw it }
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

    private suspend fun unregisterAndAwait(
        registration: BonjourRegistrationLeaseRegistry.Lease<NsdManager.RegistrationListener>
    ) {
        val claim = synchronized(registrationLock) {
            registrationLeases.claimStop(registration)
        }
            ?: return
        if (claim.shouldUnregister) requestUnregisterExact(registration)
        val completed = withTimeoutOrNull(NSD_UNREGISTRATION_TIMEOUT_MS) {
            claim.attempt.await()
            true
        } ?: false
        if (!completed) {
            // The callback carries only the listener, not a per-request ID. Keep the exact
            // UNREGISTERING lease and waiter alive: later callers reuse it without issuing a
            // duplicate unregister that a late callback could accidentally complete.
            throw BonjourAdvertisingException(
                "NSD unregistration timed out after ${NSD_UNREGISTRATION_TIMEOUT_MS}ms " +
                    "for ${registration.serviceType}"
            )
        }
    }

    private fun requestUnregisterExact(
        registration: BonjourRegistrationLeaseRegistry.Lease<NsdManager.RegistrationListener>
    ) {
        try {
            nsdManager.unregisterService(registration.resource)
        } catch (error: Exception) {
            failUnregistration(
                registration,
                BonjourAdvertisingException(
                    "Failed to unregister NSD serviceType=${registration.serviceType}",
                    error
                )
            )
        }
    }

    private fun completeUnregistration(
        registration: BonjourRegistrationLeaseRegistry.Lease<NsdManager.RegistrationListener>
    ) {
        val (retired, cleanupError) = synchronized(registrationLock) {
            val exact = registrationLeases.completeStop(registration) ?: return
            exact to runCatching { releaseMulticastLockLockedIfIdle() }.exceptionOrNull()
        }
        if (cleanupError == null) {
            retired.attempt?.complete(Unit)
        } else {
            retired.attempt?.completeExceptionally(cleanupError)
            Log.e(TAG, "Failed to release multicast lock after NSD unregistration", cleanupError)
        }
    }

    private fun failUnregistration(
        registration: BonjourRegistrationLeaseRegistry.Lease<NsdManager.RegistrationListener>,
        error: Throwable
    ) {
        val attempt = synchronized(registrationLock) {
            if (!registrationLeases.isCurrent(registration)) return
            registrationLeases.failStop(registration)
        }
        attempt?.completeExceptionally(error)
    }

    private fun retireRegistration(
        registration: BonjourRegistrationLeaseRegistry.Lease<NsdManager.RegistrationListener>
    ): Throwable? {
        val (retired, cleanupError) = synchronized(registrationLock) {
            val exact = registrationLeases.retireIfCurrent(registration) ?: return null
            exact to runCatching { releaseMulticastLockLockedIfIdle() }.exceptionOrNull()
        }
        val terminalError = BonjourAdvertisingException(
            "NSD registration ended before unregistration completed for ${registration.serviceType}"
        )
        cleanupError?.let(terminalError::addSuppressed)
        retired.attempt?.completeExceptionally(terminalError)
        return cleanupError
    }

    private fun acquireMulticastLockLockedIfNeeded() {
        multicastLock?.let { existing ->
            if (existing.isHeld) return
            try {
                existing.acquire()
                return
            } catch (error: Exception) {
                throw BonjourAdvertisingException("Failed to reacquire Wi-Fi multicast lock", error)
            }
        }
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        multicastLock = wifi.createMulticastLock("skybridge-mdns-advertise").apply {
            setReferenceCounted(false)
            try {
                acquire()
            } catch (error: Exception) {
                multicastLock = null
                throw BonjourAdvertisingException("Failed to acquire Wi-Fi multicast lock", error)
            }
        }
    }

    private fun releaseMulticastLockLockedIfIdle() {
        if (registrationLeases.hasActiveLeases()) return
        val lock = multicastLock ?: return
        try {
            if (lock.isHeld) lock.release()
            multicastLock = null
        } catch (error: Exception) {
            throw BonjourAdvertisingException("Failed to release Wi-Fi multicast lock", error)
        }
    }

    private fun releaseOrphanMulticastLockIfIdle() {
        synchronized(registrationLock) { releaseMulticastLockLockedIfIdle() }
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
