package com.skybridge.compass.android.discovery

import com.skybridge.compass.discovery.data.interop.AppleBonjourEndpointProvenance
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscoveryPeerLaunchTargetTest {
    @Test
    fun fromActionPreservesTypedFileTransferEndpointAndIdentityHint() {
        val device = discoveredDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::1",
            port = 44000,
            txtRecords = mapOf(
                "deviceId" to "ios-peer",
                "pubKeyFP" to VALID_FINGERPRINT.uppercase()
            ),
            extra = mapOf(
                "serviceAddress:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "192.168.1.44",
                "servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010"
            )
        )
        val action = DiscoveryPeerActionProjection.actionsFor(
            device,
            com.skybridge.compass.android.data.DeveloperSettings()
        ).single { it.kind == DiscoveryPeerActionKind.FileTransfer }

        val target = DiscoveryPeerLaunchTarget.from(device, action)

        assertEquals("ios-peer-id", target.peerId)
        assertEquals("Ziang iPhone", target.peerName)
        assertEquals(DeviceType.IOS, target.peerType)
        assertEquals(AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE, target.serviceType)
        assertEquals("192.168.1.44", target.host)
        assertEquals(44010, target.port)
        assertEquals(AppleBonjourEndpointProvenance.SERVICE_INDEX, target.routeProvenance)
        assertTrue(target.requiresAuthenticatedClassicFileTransferSession)
        assertEquals("ios-peer", target.deviceIdHint)
        assertEquals(VALID_FINGERPRINT, target.advertisedFingerprint)
    }

    @Test
    fun routeRoundTripsIpv6RemoteDesktopTarget() {
        val target = DiscoveryPeerLaunchTarget(
            peerId = "mac-peer",
            peerName = "Mac Studio",
            peerType = DeviceType.MACOS,
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            host = "fe80::abcd",
            port = 5901,
            routeProvenance = AppleBonjourEndpointProvenance.DIRECT_SERVICE,
            deviceIdHint = "mac-device",
            advertisedFingerprint = VALID_FINGERPRINT
        )

        val route = DiscoveryLaunchTargetRoute.routeFor("remote_control", target)
        val parsed = DiscoveryLaunchTargetRoute.parseQuery(route).getOrThrow()

        assertEquals(target, parsed)
        assertFalse(parsed?.requiresAuthenticatedClassicFileTransferSession ?: true)
    }

    @Test
    fun authenticatedProductFileTransferRouteDoesNotRequireClassicSession() {
        val target = DiscoveryPeerLaunchTarget(
            peerId = "mac-peer",
            peerName = "Mac Studio",
            peerType = DeviceType.MACOS,
            serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            host = "192.168.1.44",
            port = 44010,
            routeProvenance = AppleBonjourEndpointProvenance.SERVICE_INDEX,
            deviceIdHint = "mac-device",
            advertisedFingerprint = VALID_FINGERPRINT,
            authenticatedProductRoute = true
        )

        val route = DiscoveryLaunchTargetRoute.routeFor("file_transfer", target)
        val parsed = DiscoveryLaunchTargetRoute.parseQuery(route).getOrThrow()

        assertEquals(target, parsed)
        assertFalse(parsed?.requiresAuthenticatedClassicFileTransferSession ?: true)
    }

    @Test
    fun parseRejectsUnsupportedServiceAndLoopbackHost() {
        val unsupported = DiscoveryLaunchTargetRoute.parse(
            mapOf(
                DiscoveryLaunchTargetRoute.PEER_ID to "peer",
                DiscoveryLaunchTargetRoute.PEER_NAME to "Peer",
                DiscoveryLaunchTargetRoute.PEER_TYPE to DeviceType.IOS.name,
                DiscoveryLaunchTargetRoute.SERVICE_TYPE to "_http._tcp",
                DiscoveryLaunchTargetRoute.HOST to "192.168.1.5",
                DiscoveryLaunchTargetRoute.PORT to "8080",
                DiscoveryLaunchTargetRoute.ROUTE_PROVENANCE to AppleBonjourEndpointProvenance.DIRECT_SERVICE.name
            )
        )
        assertTrue(unsupported.isFailure)

        val loopback = DiscoveryLaunchTargetRoute.parse(
            mapOf(
                DiscoveryLaunchTargetRoute.PEER_ID to "peer",
                DiscoveryLaunchTargetRoute.PEER_NAME to "Peer",
                DiscoveryLaunchTargetRoute.PEER_TYPE to DeviceType.IOS.name,
                DiscoveryLaunchTargetRoute.SERVICE_TYPE to AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
                DiscoveryLaunchTargetRoute.HOST to "127.0.0.1",
                DiscoveryLaunchTargetRoute.PORT to "8080",
                DiscoveryLaunchTargetRoute.ROUTE_PROVENANCE to AppleBonjourEndpointProvenance.DIRECT_SERVICE.name
            )
        )
        assertTrue(loopback.isFailure)
    }

    @Test
    fun parseWithoutArgumentsReturnsNullTarget() {
        assertEquals(null, DiscoveryLaunchTargetRoute.parse(emptyMap()).getOrThrow())
    }

    private fun discoveredDevice(
        serviceType: String?,
        address: String,
        port: Int,
        txtRecords: Map<String, String> = emptyMap(),
        extra: Map<String, String> = emptyMap()
    ) = DiscoveredDevice(
        id = "ios-peer-id",
        name = "Ziang iPhone",
        type = DeviceType.IOS,
        capabilities = setOf(DeviceCapability.FILE_TRANSFER),
        connectionInfo = ConnectionInfo(
            protocol = DiscoveryProtocol.BONJOUR,
            address = address,
            port = port,
            serviceType = serviceType,
            txtRecords = txtRecords,
            extra = extra
        ),
        signalStrength = 100,
        lastSeen = 1_000
    )

    private companion object {
        const val VALID_FINGERPRINT =
            "aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22"
    }
}
