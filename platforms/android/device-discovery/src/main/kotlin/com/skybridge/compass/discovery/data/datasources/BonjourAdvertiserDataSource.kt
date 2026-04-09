package com.skybridge.compass.discovery.data.datasources

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.suspendCancellableCoroutine
import java.lang.reflect.Method
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
        val osVersion: String = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
        val model: String? = Build.MODEL,
        val capabilities: String? = null,
        val cryptoSuites: String? = null,
        val remoteVideoFormats: Set<String> = emptySet(),
        val supportsSoa: Boolean = true
    )

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

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
    ): String {
        stopAdvertising(serviceType)
        acquireMulticastLockIfNeeded()

        val serviceInfo = buildServiceInfo(
            port = port,
            advertisement = advertisement,
            serviceType = serviceType
        )

        return suspendCancellableCoroutine { cont ->
            val done = AtomicBoolean(false)

            val listener = object : NsdManager.RegistrationListener {
                override fun onRegistrationFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                    if (done.compareAndSet(false, true)) {
                        clearRegistration(serviceType, this)
                        cont.resumeWithException(
                            IllegalStateException("NSD registration failed (errorCode=$errorCode)")
                        )
                    }
                }

                override fun onServiceRegistered(serviceInfo: NsdServiceInfo?) {
                    if (done.compareAndSet(false, true)) {
                        val name = serviceInfo?.serviceName ?: "unknown"
                        cont.resume(name)
                    }
                }

                override fun onServiceUnregistered(serviceInfo: NsdServiceInfo?) {
                    clearRegistration(serviceType, this)
                }

                override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
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
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    @Suppress("DEPRECATION")
                    nsdManager.registerService(
                        serviceInfo,
                        NsdManager.PROTOCOL_DNS_SD,
                        context.mainExecutor,
                        listener
                    )
                } else {
                    @Suppress("DEPRECATION")
                    nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
                }
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
    }

    fun stopAdvertising(serviceType: String) {
        val listener = synchronized(registrationLock) {
            activeRegistrations.remove(serviceType)?.listener
        } ?: return

        runCatching {
            @Suppress("DEPRECATION")
            nsdManager.unregisterService(listener)
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
            runCatching {
                @Suppress("DEPRECATION")
                nsdManager.unregisterService(registration.listener)
            }
        }
        releaseMulticastLock()
    }

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

        setTxtAttribute(serviceInfo, "deviceId", advertisement.deviceId.trim())
        setTxtAttribute(serviceInfo, "pubKeyFP", advertisement.pubKeyFP.trim().lowercase(Locale.ROOT))
        setTxtAttribute(serviceInfo, "uniqueId", advertisement.uniqueId.trim())

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
            setTxtAttribute(serviceInfo, AppleBonjourInterop.HS_SOA_KEY, "1")
        }

        return serviceInfo
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
        trySetAttributeCompat(serviceInfo, fallbackKey, v)
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
            runCatching { acquire() }
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
        runCatching {
            if (lock.isHeld) lock.release()
        }
    }
}
