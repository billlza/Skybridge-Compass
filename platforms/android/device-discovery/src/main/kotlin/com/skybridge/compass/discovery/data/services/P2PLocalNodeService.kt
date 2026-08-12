package com.skybridge.compass.discovery.data.services

import android.os.Build
import com.skybridge.compass.core.data.RuntimeNetworkParametersSource
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.TcpControlServer
import com.skybridge.compass.discovery.data.datasources.BonjourAdvertiserDataSource
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.shared.platform.AndroidPlatformMetadata
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Starts the Android LAN "control endpoint" compatible with macOS/iOS Pro release:
 * - Listens on a plain TCP port (`_skybridge._tcp`)
 * - Advertises mDNS TXT records including `deviceId` and `pubKeyFP`
 */
@Singleton
class P2PLocalNodeService @Inject constructor(
    private val advertiser: BonjourAdvertiserDataSource,
    private val identity: LocalP2PIdentity,
    private val tcpServer: TcpControlServer,
    private val runtimeParameters: RuntimeNetworkParametersSource
) {
    private companion object {
        private const val PROTOCOL_VERSION = "1.0.0"
    }

    private val started = AtomicBoolean(false)
    private val lifecycleMutex = Mutex()
    @Volatile private var boundPort: Int? = null
    @Volatile private var currentAdvertisementConfig: P2PLocalNodeAdvertisementConfig? = null

    /**
     * Advertising registration status (R3.13), surfaced from the underlying advertiser so the
     * discovery UI can present a terminal advertising failure reason as a leaf-level fact. Browsing
     * is a separate flow and keeps running regardless of this status.
     */
    val advertisingStatus: kotlinx.coroutines.flow.StateFlow<
        com.skybridge.compass.discovery.data.datasources.BonjourAdvertisingStatus
        > get() = advertiser.advertisingStatus

    /**
     * @param showDeviceName honors the privacy "Show Device Name" toggle; when false the advertiser
     * publishes a generic non-identifying name instead of the real device model. Owned by the
     * app-module SecuritySettingsStore and passed by the caller (defaults to ON).
     * @param verifiedCapabilities are capabilities already proven ready by the caller. This service
     * must not infer remote-control or screen-sharing readiness because those gates live in the app
     * module and depend on runtime permission/accessibility state.
     */
    suspend fun start(
        showDeviceName: Boolean = true,
        verifiedCapabilities: Set<DeviceCapability> = emptySet()
    ): Int {
        // The advertised crypto-suite set is derived from the local identity. Snapshot it into the
        // advertisement config so a change in the negotiable suite set (not just the capability set)
        // is detected by the config comparison below and triggers a TXT rewrite (R3.12). Resolving it
        // here — rather than inside advertise() — is what lets a suite-only change re-advertise.
        val desiredConfig = P2PLocalNodeAdvertisementPolicy.config(
            showDeviceName = showDeviceName,
            verifiedCapabilities = verifiedCapabilities,
            cryptoSuitesCsv = P2PLocalNodeAdvertisementPolicy.cryptoSuitesTxt(
                identity.discoveryCryptoSuitesCsv()
            )
        )
        return withContext(Dispatchers.IO) {
            lifecycleMutex.withLock {
                try {
                    if (started.get()) {
                        val port = checkNotNull(boundPort) {
                            "P2P local node is marked started without a bound TCP port"
                        }
                        if (currentAdvertisementConfig != desiredConfig) {
                            advertise(port = port, config = desiredConfig)
                            currentAdvertisementConfig = desiredConfig
                        }
                        return@withLock port
                    }

                    started.set(true)
                    // R7.4: the listen/advertised port is taken from the user-configured range at
                    // start time, so a settings change is honored by the next presence start while
                    // an already-bound presence keeps its port.
                    val port = tcpServer.start(portRange = runtimeParameters.current().listenPortRange)
                    advertise(port = port, config = desiredConfig)
                    boundPort = port
                    currentAdvertisementConfig = desiredConfig
                    port
                } catch (t: Throwable) {
                    boundPort = null
                    currentAdvertisementConfig = null
                    started.set(false)
                    cleanupAfterStartFailure(t)
                    throw t
                }
            }
        }
    }

    private fun cleanupAfterStartFailure(cause: Throwable) {
        try {
            advertiser.stopAdvertising()
        } catch (cleanupError: Throwable) {
            cause.addSuppressed(cleanupError)
        }
        try {
            tcpServer.stop()
        } catch (cleanupError: Throwable) {
            cause.addSuppressed(cleanupError)
        }
    }

    private suspend fun advertise(
        port: Int,
        config: P2PLocalNodeAdvertisementConfig
    ) {
        val deviceId = identity.deviceId()
        val pubKeyFP = identity.pubKeyFingerprint()
        val baseAdvertisement = buildBaseAdvertisement(
            deviceId = deviceId,
            pubKeyFP = pubKeyFP,
            showDeviceName = config.showDeviceName
        )

        advertiser.startAdvertising(
            port = port,
            advertisement = baseAdvertisement.copy(
                capabilities = P2PLocalNodeAdvertisementPolicy.capabilityTxt(config.verifiedCapabilities),
                // Use the suite CSV captured in the config so the rewritten TXT matches the set the
                // config comparison keyed on; serviceName (from uniqueId/deviceId) and pubKeyFP are
                // taken from the stable identity and therefore remain unchanged across the rewrite.
                cryptoSuites = config.cryptoSuitesCsv
            ),
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE
        )
    }

    private fun buildBaseAdvertisement(
        deviceId: String,
        pubKeyFP: String,
        showDeviceName: Boolean
    ): BonjourAdvertiserDataSource.Advertisement {
        return BonjourAdvertiserDataSource.Advertisement(
            deviceId = deviceId,
            pubKeyFP = pubKeyFP,
            uniqueId = deviceId,
            name = identity.publishedDeviceName(showDeviceName),
            platform = "android",
            version = PROTOCOL_VERSION,
            osVersion = AndroidPlatformMetadata.versionString(Build.VERSION.RELEASE, Build.VERSION.SDK_INT),
            model = if (showDeviceName) Build.MODEL else null,
            supportsSoa = true
        )
    }

    fun stop() {
        if (!started.compareAndSet(true, false)) return
        boundPort = null
        currentAdvertisementConfig = null
        advertiser.stopAdvertising()
        tcpServer.stop()
    }
}

internal data class P2PLocalNodeAdvertisementConfig(
    val showDeviceName: Boolean,
    val verifiedCapabilities: Set<DeviceCapability>,
    val cryptoSuitesCsv: String?
)

internal object P2PLocalNodeAdvertisementPolicy {
    fun config(
        showDeviceName: Boolean,
        verifiedCapabilities: Set<DeviceCapability>,
        cryptoSuitesCsv: String?
    ): P2PLocalNodeAdvertisementConfig =
        P2PLocalNodeAdvertisementConfig(
            showDeviceName = showDeviceName,
            verifiedCapabilities = verifiedCapabilities.toSet(),
            cryptoSuitesCsv = cryptoSuitesCsv
        )

    fun capabilityTxt(verifiedCapabilities: Set<DeviceCapability>): String? =
        verifiedCapabilities
            .takeIf { it.isNotEmpty() }
            ?.let(AppleBonjourInterop::appleCompatibleCapabilities)

    /**
     * Normalizes the identity-derived crypto-suite CSV for the `cryptoSuites`/`suites` TXT field.
     * Returns null only when the identity reports no negotiable suites (so the advertiser omits the
     * field rather than writing a blank value); otherwise returns the trimmed non-empty CSV. Because
     * the local identity always materializes at least the ML-KEM-768 KEM key, this is non-empty on
     * every real advertising registration, satisfying R3.2.
     */
    fun cryptoSuitesTxt(discoveryCryptoSuitesCsv: String): String? =
        discoveryCryptoSuitesCsv.trim().takeIf { it.isNotEmpty() }
}
