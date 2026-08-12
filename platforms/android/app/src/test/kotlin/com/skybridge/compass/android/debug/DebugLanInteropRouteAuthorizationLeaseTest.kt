package com.skybridge.compass.android.debug

import android.content.ContextWrapper
import com.skybridge.compass.android.account.AccountBusinessIdentityProvider
import com.skybridge.compass.android.remote.mac.MacRemoteControlClient
import com.skybridge.compass.android.remote.mac.MacRemoteControlLogSink
import com.skybridge.compass.android.remote.mac.MacRemoteControlTrustContext
import com.skybridge.compass.android.remote.mac.MacRemoteControlTrustMode
import com.skybridge.compass.core.p2p.FormalLanBonjourEndpoint
import com.skybridge.compass.core.p2p.FormalLanPeerSnapshot
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.PeerKemKeyStore
import com.skybridge.compass.core.p2p.PeerKemPublicKeySource
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PXWingKem
import com.skybridge.compass.shared.productsession.ProductRouteBindingProtocol
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DebugLanInteropRouteAuthorizationLeaseTest {
    @Test
    fun lifecycleRevocationBeforeSecondPreDialGatePreventsSocketConnect() {
        assertRevocationPreventsDial { lease, _ -> lease.revoke() }
    }

    @Test
    fun changedDiscoverySnapshotBeforeSecondPreDialGatePreventsSocketConnect() {
        assertRevocationPreventsDial { lease, original ->
            lease.retainIfAnyObserved(
                listOf(snapshot(revision = original.discoveryRevision + 1))
            )
        }
    }

    @Test
    fun exactSnapshotBindingRejectsEveryRouteIdentityAndProvenanceChange() {
        val baseline = snapshot(revision = 17)
        val changedSnapshots = listOf(
            snapshot(revision = 17, remoteHost = "192.168.1.21"),
            snapshot(revision = 17, deviceId = "id:other-mac"),
            snapshot(revision = 17, fingerprint = OTHER_PIN),
            snapshot(revision = 17, remoteInstance = "Other._skybridge-rd._tcp.local"),
            snapshot(revision = 17, routeProvenance = "DIRECT_SERVICE")
        )
        changedSnapshots.forEach { changed ->
            val lease = DebugLanInteropRouteAuthorizationLease(RUN_REF)
            lease.bindAttempt(1L, baseline)
            assertFalse(lease.retainIfAnyObserved(listOf(changed)))
            assertFalse(lease.isCurrent())
        }
    }

    @Test
    fun unboundLostDoubleBindAndTerminalLifecycleAreFailClosed() {
        val lease = DebugLanInteropRouteAuthorizationLease(RUN_REF)
        val baseline = snapshot(revision = 17)
        assertFalse(lease.isCurrent())
        lease.bindAttempt(1L, baseline)
        assertTrue(lease.isCurrent())
        assertThrows(IllegalStateException::class.java) {
            lease.bindAttempt(2L, baseline)
        }
        assertFalse(lease.retainIfAnyObserved(emptyList()))
        assertFalse(lease.isCurrent())

        val terminalLease = DebugLanInteropRouteAuthorizationLease(RUN_REF)
        terminalLease.bindAttempt(1L, baseline)
        terminalLease.revoke()
        assertFalse(terminalLease.isCurrent())
    }

    private fun assertRevocationPreventsDial(
        revokeBeforeDial: (DebugLanInteropRouteAuthorizationLease, FormalLanPeerSnapshot) -> Unit
    ) {
        val snapshot = snapshot(revision = 17)
        val lease = DebugLanInteropRouteAuthorizationLease(RUN_REF)
        lease.bindAttempt(attempt = 1L, peer = snapshot)
        val connectorCalls = AtomicInteger(0)
        val context = ContextWrapper(null)
        val client = MacRemoteControlClient(
            appContext = context,
            accountBusinessIdentityProvider = AccountBusinessIdentityProvider { null },
            localIdentityOverride = LocalP2PIdentity(
                context,
                LocalP2PIdentity.StorageMode.ISOLATED_PLAINTEXT_TEST
            ),
            trustContextOverride = MacRemoteControlTrustContext(
                peerKemPublicKeys = PeerKemPublicKeySource {
                    PeerKemKeyStore.PeerKemPublicKeys(
                        xWingPublicKey = ByteArray(P2PXWingKem.XWING_PUBLIC_KEY_SIZE)
                    )
                },
                peerSigningFingerprints = ReadOnlyTrustStore(PIN),
                fallbackCooldowns = P2PHandshakeWire.InMemoryFallbackCooldownStore(),
                mode = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY
            ),
            formalRouteAuthorizationLease = lease,
            socketConnector = { _, _, _ -> connectorCalls.incrementAndGet() },
            localXWingAvailability = { true },
            beforeFormalDialRecheck = { revokeBeforeDial(lease, snapshot) },
            logSink = SilentLogSink
        )
        client.connect(
            target = MacRemoteControlClient.ConnectionTarget(
                host = snapshot.remoteDesktop.hostAddress,
                port = snapshot.remoteDesktop.port,
                displayName = snapshot.displayName,
                deviceIdHint = snapshot.deviceId,
                advertisedFingerprint = snapshot.advertisedProtocolFingerprint,
                advertisedFingerprintTrustSource =
                    MacRemoteControlClient.FingerprintTrustSource.TRUSTED_CONFIGURATION
            ),
            enableHandshake = true,
            securityConfig = MacRemoteControlClient.SecurityConfig.formalLanAcceptance()
        )

        runBlocking {
            withTimeout(5_000) {
                client.state.first { it is MacRemoteControlClient.State.Failed }
            }
        }
        assertEquals(0, connectorCalls.get())
        client.disconnect()
    }

    private fun snapshot(
        revision: Long,
        remoteHost: String = "192.168.1.20",
        deviceId: String = DEVICE_ID,
        fingerprint: String = PIN,
        remoteInstance: String = "Mac._skybridge-rd._tcp.local",
        routeProvenance: String = "SERVICE_INDEX"
    ): FormalLanPeerSnapshot = FormalLanPeerSnapshot(
        displayName = "Mac",
        handshake = endpoint(
            serviceType = ProductRouteBindingProtocol.CONTROL_SERVICE_TYPE,
            instanceName = "Mac._skybridge._tcp.local",
            hostAddress = "192.168.1.19",
            port = 44_000,
            revision = revision,
            deviceId = deviceId,
            fingerprint = fingerprint,
            routeProvenance = routeProvenance
        ),
        remoteDesktop = endpoint(
            serviceType = ProductRouteBindingProtocol.REMOTE_DESKTOP_SERVICE_TYPE,
            instanceName = remoteInstance,
            hostAddress = remoteHost,
            port = 5_901,
            revision = revision,
            deviceId = deviceId,
            fingerprint = fingerprint,
            routeProvenance = routeProvenance
        )
    )

    private fun endpoint(
        serviceType: String,
        instanceName: String,
        hostAddress: String,
        port: Int,
        revision: Long,
        deviceId: String,
        fingerprint: String,
        routeProvenance: String
    ): FormalLanBonjourEndpoint = FormalLanBonjourEndpoint(
        serviceType = serviceType,
        instanceName = instanceName,
        hostAddress = hostAddress,
        port = port,
        routeProvenance = routeProvenance,
        advertisedDeviceId = deviceId,
        advertisedProtocolFingerprint = fingerprint,
        discoveryRevision = revision
    )

    private class ReadOnlyTrustStore(
        private val fingerprint: String
    ) : P2PHandshakeWire.TrustStore {
        override fun loadPeerSigningFingerprint(peerId: String): String = fingerprint

        override fun savePeerSigningFingerprint(
            peerId: String,
            peerSigningFingerprint: String
        ) = error("debug route lease test trust store is read-only")
    }

    private object SilentLogSink : MacRemoteControlLogSink {
        override fun debug(message: String) = Unit
        override fun info(message: String) = Unit
        override fun warn(message: String) = Unit
        override fun error(message: String) = Unit
    }

    private companion object {
        const val DEVICE_ID = "id:mac-debug-1"
        const val PIN =
            "aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22"
        const val OTHER_PIN =
            "bb11bb22bb11bb22bb11bb22bb11bb22bb11bb22bb11bb22bb11bb22bb11bb22"
        const val RUN_REF =
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
}
