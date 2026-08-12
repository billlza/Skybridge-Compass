package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LanRemotePeerTest {
    @Test
    fun mergedSameRevisionServicesProduceExactDualFormalSnapshot() {
        val peer = LanRemotePeer.fromDiscoveredDevice(
            discoveredDevice(extra = dualRouteExtra())
        )

        assertNotNull(peer)
        requireNotNull(peer)
        assertNotNull(peer.formalSnapshot)
        assertEquals("mac-peer", peer.id)
        assertEquals(17L, peer.discoveryRevision)
        assertEquals("192.168.1.20", peer.host)
        assertEquals(5901, peer.port)
        assertEquals("192.168.1.19", peer.handshakeEndpoint?.hostAddress)
        assertEquals(VALID_FINGERPRINT, peer.identityHint.advertisedFingerprint)
        assertEquals(
            "d7952306c7230e8a9ddb847695cbea4771299e1a677d5c5a353c55439dc35249",
            peer.endpointDigest
        )
    }

    @Test
    fun remoteOnlyRouteRemainsAvailableOnlyForExistingProductSessionLane() {
        val peer = LanRemotePeer.fromDiscoveredDevice(
            discoveredDevice(
                serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                address = "192.168.1.20",
                port = 5901,
                extra = remoteRouteExtra(revision = 21)
            )
        )

        assertNotNull(peer)
        requireNotNull(peer)
        assertNull(peer.formalSnapshot)
        assertNull(peer.handshakeEndpoint)
        assertEquals(21L, peer.discoveryRevision)
    }

    @Test
    fun crossServiceFingerprintMismatchCannotProduceFormalBootstrapSnapshot() {
        val extra = dualRouteExtra() +
            ("serviceFingerprint:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to OTHER_FINGERPRINT)

        val peer = LanRemotePeer.fromDiscoveredDevice(discoveredDevice(extra = extra))

        assertNotNull(peer)
        requireNotNull(peer)
        assertNull(peer.formalSnapshot)
        assertEquals(OTHER_FINGERPRINT, peer.identityHint.advertisedFingerprint)
    }

    @Test
    fun indexedRemoteWithoutItsOwnResolvedAddressIsRejected() {
        val extra = dualRouteExtra() -
            "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}"

        assertNull(LanRemotePeer.fromDiscoveredDevice(discoveredDevice(extra = extra)))
    }

    @Test
    fun nonBonjourPeerIsRejected() {
        val device = discoveredDevice(
            protocol = DiscoveryProtocol.UDP_BROADCAST,
            serviceType = null,
            address = "192.168.1.22",
            port = 5901,
            extra = dualRouteExtra()
        )

        assertNull(LanRemotePeer.fromDiscoveredDevice(device))
    }

    @Test
    fun endpointDigestChangesWithEitherRouteRevisionOrIdentity() {
        val baseline = requireNotNull(
            LanRemotePeer.fromDiscoveredDevice(discoveredDevice(extra = dualRouteExtra()))
        )
        val changedRevision = requireNotNull(
            LanRemotePeer.fromDiscoveredDevice(
                discoveredDevice(extra = dualRouteExtra(revision = 18))
            )
        )
        val changedRemote = requireNotNull(
            LanRemotePeer.fromDiscoveredDevice(
                discoveredDevice(
                    extra = dualRouteExtra() +
                        ("serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to
                            "192.168.1.30")
                )
            )
        )

        assertTrue(baseline.endpointDigest != changedRevision.endpointDigest)
        assertTrue(baseline.endpointDigest != changedRemote.endpointDigest)
    }

    private fun dualRouteExtra(revision: Long = 17): Map<String, String> =
        endpointExtra(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            instance = "Mac._skybridge._tcp.local",
            address = "192.168.1.19",
            port = 44_000
        ) + endpointExtra(
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            instance = "Mac._skybridge-rd._tcp.local",
            address = "192.168.1.20",
            port = 5_901
        ) + ("serviceIndexRevision" to revision.toString())

    private fun remoteRouteExtra(revision: Long): Map<String, String> =
        endpointExtra(
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            instance = "Mac._skybridge-rd._tcp.local",
            address = "192.168.1.20",
            port = 5_901
        ) + ("serviceIndexRevision" to revision.toString())

    private fun endpointExtra(
        serviceType: String,
        instance: String,
        address: String,
        port: Int
    ) = mapOf(
        "servicePort:$serviceType" to port.toString(),
        "serviceInstance:$serviceType" to instance,
        "serviceAddress:$serviceType" to address,
        "serviceDeviceId:$serviceType" to "mac-peer",
        "serviceFingerprint:$serviceType" to VALID_FINGERPRINT
    )

    private fun discoveredDevice(
        protocol: DiscoveryProtocol = DiscoveryProtocol.BONJOUR,
        serviceType: String? = AppleBonjourInterop.MAIN_SERVICE_TYPE,
        address: String = "192.168.1.19",
        port: Int = 44_000,
        extra: Map<String, String>
    ) = DiscoveredDevice(
        id = "mac-peer",
        name = "Mac Studio",
        type = DeviceType.MACOS,
        capabilities = setOf(DeviceCapability.SCREEN_SHARING, DeviceCapability.REMOTE_CONTROL),
        connectionInfo = ConnectionInfo(
            protocol = protocol,
            address = address,
            port = port,
            serviceType = serviceType,
            txtRecords = emptyMap(),
            extra = extra
        ),
        signalStrength = 100,
        lastSeen = 1_000
    )

    private companion object {
        const val VALID_FINGERPRINT =
            "aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22"
        const val OTHER_FINGERPRINT =
            "bb11bb22bb11bb22bb11bb22bb11bb22bb11bb22bb11bb22bb11bb22bb11bb22"
    }
}
