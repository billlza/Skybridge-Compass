package com.skybridge.compass.discovery.data.services

import android.os.Build
import android.util.Log
import com.skybridge.compass.core.filetransfer.MacLanFileTransferServer
import com.skybridge.compass.core.filetransfer.MacLanFileTransferProtocol
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.TcpControlServer
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import com.skybridge.compass.discovery.data.datasources.BonjourAdvertiserDataSource
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import kotlinx.coroutines.Dispatchers
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
    private val fileTransferServer: MacLanFileTransferServer
) {
    private companion object {
        private const val TAG = "P2PLocalNodeService"
        private const val PROTOCOL_VERSION = "1.0.0"
    }

    private val started = AtomicBoolean(false)

    suspend fun start(): Int {
        if (!started.compareAndSet(false, true)) {
            return -1
        }
        return withContext(Dispatchers.IO) {
            try {
                val deviceId = identity.deviceId()
                val pubKeyFP = identity.pubKeyFingerprint()

                val port = tcpServer.start(port = 0)
                val baseAdvertisement = buildBaseAdvertisement(
                    deviceId = deviceId,
                    pubKeyFP = pubKeyFP
                )

                advertiser.startAdvertising(
                    port = port,
                    advertisement = baseAdvertisement.copy(
                        capabilities = AppleBonjourInterop.appleCompatibleCapabilities(
                            setOf(
                                DeviceCapability.FILE_TRANSFER,
                                DeviceCapability.SCREEN_SHARING,
                                DeviceCapability.REMOTE_CONTROL
                            )
                        )
                    ),
                    serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE
                )

                val transferPort = runCatching {
                    fileTransferServer.start(MacLanFileTransferProtocol.DEFAULT_PORT)
                }.getOrElse { error ->
                    Log.w(TAG, "LAN file transfer listener unavailable: ${error.message}")
                    -1
                }

                if (transferPort > 0) {
                    runCatching {
                        advertiser.startAdvertising(
                            port = transferPort,
                            advertisement = baseAdvertisement.copy(
                                capabilities = AppleBonjourInterop.appleCompatibleCapabilities(
                                    setOf(DeviceCapability.FILE_TRANSFER)
                                )
                            ),
                            serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE
                        )
                    }.onFailure { error ->
                        Log.w(TAG, "LAN file transfer Bonjour advertising unavailable: ${error.message}")
                    }
                }

                port
            } catch (t: Throwable) {
                started.set(false)
                runCatching { advertiser.stopAdvertising() }
                runCatching { tcpServer.stop() }
                runCatching { fileTransferServer.stop() }
                throw t
            }
        }
    }

    private fun buildBaseAdvertisement(
        deviceId: String,
        pubKeyFP: String
    ): BonjourAdvertiserDataSource.Advertisement {
        return BonjourAdvertiserDataSource.Advertisement(
            deviceId = deviceId,
            pubKeyFP = pubKeyFP,
            uniqueId = deviceId,
            name = identity.deviceName(),
            platform = "android",
            version = PROTOCOL_VERSION,
            osVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            model = Build.MODEL,
            cryptoSuites = identity.discoveryCryptoSuitesCsv(),
            remoteVideoFormats = AndroidRemoteVideoFormats.supportedStreamingFormats().toSet(),
            supportsSoa = true
        )
    }

    fun stop() {
        if (!started.compareAndSet(true, false)) return
        runCatching { advertiser.stopAdvertising() }
        runCatching { tcpServer.stop() }
        runCatching { fileTransferServer.stop() }
    }
}
