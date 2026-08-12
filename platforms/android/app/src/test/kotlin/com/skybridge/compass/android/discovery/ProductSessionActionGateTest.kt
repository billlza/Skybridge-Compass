package com.skybridge.compass.android.discovery

import com.skybridge.compass.discovery.data.interop.AppleBonjourEndpointProvenance
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.core.p2p.FormalLanBonjourEndpoint
import com.skybridge.compass.core.p2p.FormalLanPeerSnapshot
import com.skybridge.compass.shared.productsession.AuthenticatedProductRouteBinding
import com.skybridge.compass.shared.productsession.InMemoryProductSessionAuthorityStore
import com.skybridge.compass.shared.productsession.ProductRouteBindingProtocol
import com.skybridge.compass.shared.productsession.ProductRouteKind
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProductSessionActionGateTest {
    @Test
    fun matchingAuthenticatedRouteAllowsFileTransferAtExecutionTime() {
        val gate = gateWithRoute(
            kind = ProductRouteKind.FILE_TRANSFER,
            instanceName = FILE_TRANSFER_INSTANCE,
            host = "192.168.1.30",
            port = 44010,
            expiresAtEpochMillis = NOW + 60_000
        )

        val decision = gate.checkFileTransfer(
            launchTarget(
                serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
                instanceName = FILE_TRANSFER_INSTANCE,
                host = "192.168.1.30",
                port = 44010
            ),
            nowEpochMillis = NOW
        )

        assertTrue(decision is ProductActionGateDecision.Allowed)
    }

    @Test
    fun executionGateRejectsMissingRouteInstanceName() {
        val gate = gateWithRoute(
            kind = ProductRouteKind.FILE_TRANSFER,
            instanceName = FILE_TRANSFER_INSTANCE,
            host = "192.168.1.30",
            port = 44010,
            expiresAtEpochMillis = NOW + 60_000
        )

        val decision = gate.checkFileTransfer(
            launchTarget(
                serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
                instanceName = null,
                host = "192.168.1.30",
                port = 44010
            ),
            nowEpochMillis = NOW
        )

        assertEquals(
            ProductActionGateDecision.Denied(ProductActionGateDenialReason.MissingRouteInstanceName),
            decision
        )
    }

    @Test
    fun executionGateRejectsExpiredAuthenticatedRouteBinding() {
        val gate = gateWithRoute(
            kind = ProductRouteKind.FILE_TRANSFER,
            instanceName = FILE_TRANSFER_INSTANCE,
            host = "192.168.1.30",
            port = 44010,
            expiresAtEpochMillis = NOW
        )

        val decision = gate.checkFileTransfer(
            launchTarget(
                serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
                instanceName = FILE_TRANSFER_INSTANCE,
                host = "192.168.1.30",
                port = 44010
            ),
            nowEpochMillis = NOW
        )

        assertEquals(
            ProductActionGateDecision.Denied(ProductActionGateDenialReason.AuthenticatedRouteBindingExpired),
            decision
        )
    }

    @Test
    fun executionGateDoesNotTreatSameHostPortAsSameRouteWhenInstanceNameDiffers() {
        val gate = gateWithRoute(
            kind = ProductRouteKind.REMOTE_DESKTOP,
            instanceName = REMOTE_DESKTOP_INSTANCE,
            host = "192.168.1.31",
            port = 5901,
            expiresAtEpochMillis = NOW + 60_000
        )

        val decision = gate.checkRemoteDesktop(
            launchTarget(
                serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                instanceName = "Other._skybridge-rd._tcp.local",
                host = "192.168.1.31",
                port = 5901
            ),
            nowEpochMillis = NOW
        )

        assertEquals(
            ProductActionGateDecision.Denied(ProductActionGateDenialReason.MissingAuthenticatedRouteBinding),
            decision
        )
    }

    @Test
    fun unifiedDecisionPreservesExistingAuthenticatedRemoteOnlySession() {
        val gate = gateWithRoute(
            kind = ProductRouteKind.REMOTE_DESKTOP,
            instanceName = REMOTE_DESKTOP_INSTANCE,
            host = "192.168.1.31",
            port = 5901,
            expiresAtEpochMillis = NOW + 60_000
        )

        val decision = gate.decideRemoteDesktop(
            target = actionTarget(
                serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                instanceName = REMOTE_DESKTOP_INSTANCE,
                host = "192.168.1.31",
                port = 5901
            ),
            formalPeer = null,
            nowEpochMillis = NOW
        )

        assertTrue(decision is ProductRemoteDesktopDecision.ExistingProductSession)
    }

    @Test
    fun unifiedDecisionRoutesMissingSessionToExactDualBootstrap() {
        val gate = ProductSessionActionGate(InMemoryProductSessionAuthorityStore())
        val formal = formalPeer()

        val decision = gate.decideRemoteDesktop(
            target = actionTarget(
                serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                instanceName = REMOTE_DESKTOP_INSTANCE,
                host = "192.168.1.31",
                port = 5901
            ),
            formalPeer = formal,
            nowEpochMillis = NOW
        )

        assertEquals(ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap, decision)
    }

    @Test
    fun unifiedDecisionRejectsRemoteRouteDifferentFromDualSnapshot() {
        val gate = ProductSessionActionGate(InMemoryProductSessionAuthorityStore())

        val decision = gate.decideRemoteDesktop(
            target = actionTarget(
                serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                instanceName = REMOTE_DESKTOP_INSTANCE,
                host = "192.168.1.99",
                port = 5901
            ),
            formalPeer = formalPeer(),
            nowEpochMillis = NOW
        )

        assertEquals(
            ProductRemoteDesktopDecision.Denied(
                ProductActionGateDenialReason.TrustedLanBootstrapUnavailable
            ),
            decision
        )
    }

    private fun gateWithRoute(
        kind: ProductRouteKind,
        instanceName: String,
        host: String,
        port: Int,
        expiresAtEpochMillis: Long
    ): ProductSessionActionGate {
        val store = InMemoryProductSessionAuthorityStore()
        val owner = ProductSessionOwner.create("session-1", generation = 1)
        store.claimSession(owner)
        store.upsertEstablishedRouteBinding(
            owner = owner,
            remoteDeviceId = "ios-device-1",
            remotePublicKeyFingerprint = VALID_FINGERPRINT,
            binding = AuthenticatedProductRouteBinding(
                kind = kind,
                serviceType = kind.serviceType,
                instanceName = instanceName,
                hostName = host,
                port = port,
                endpointProvenance = ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD,
                sessionHashHex = "1111111111111111",
                transcriptPrefixHex = "2222222222222222",
                expiresAtEpochMillis = expiresAtEpochMillis
            ),
            nowEpochMillis = NOW - 1
        )
        if (expiresAtEpochMillis <= NOW) {
            store.upsertEstablishedRouteBinding(
                owner = owner,
                remoteDeviceId = "ios-device-1",
                remotePublicKeyFingerprint = VALID_FINGERPRINT,
                binding = AuthenticatedProductRouteBinding(
                    kind = ProductRouteKind.REMOTE_DESKTOP,
                    serviceType = ProductRouteKind.REMOTE_DESKTOP.serviceType,
                    instanceName = REMOTE_DESKTOP_INSTANCE,
                    hostName = "192.168.1.31",
                    port = 5901,
                    endpointProvenance = ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD,
                    sessionHashHex = "1111111111111111",
                    transcriptPrefixHex = "2222222222222222",
                    expiresAtEpochMillis = NOW + 60_000
                ),
                nowEpochMillis = NOW - 1
            )
        }
        return ProductSessionActionGate(store)
    }

    private fun launchTarget(
        serviceType: String,
        instanceName: String?,
        host: String,
        port: Int
    ) = DiscoveryPeerLaunchTarget(
        peerId = "peer",
        peerName = "Peer",
        peerType = com.skybridge.compass.discovery.domain.entities.DeviceType.IOS,
        serviceType = serviceType,
        instanceName = instanceName,
        host = host,
        port = port,
        routeProvenance = AppleBonjourEndpointProvenance.SERVICE_INDEX,
        deviceIdHint = "ios-device-1",
        advertisedFingerprint = VALID_FINGERPRINT,
        authenticatedProductRoute = true
    )

    private fun actionTarget(
        serviceType: String,
        instanceName: String?,
        host: String,
        port: Int
    ) = ProductActionGateTarget(
        serviceType = serviceType,
        instanceName = instanceName,
        host = host,
        port = port,
        routeProvenance = AppleBonjourEndpointProvenance.SERVICE_INDEX,
        deviceIdHint = "ios-device-1",
        advertisedFingerprint = VALID_FINGERPRINT
    )

    private fun formalPeer() = FormalLanPeerSnapshot(
        displayName = "Peer",
        handshake = formalEndpoint(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            instanceName = "SkyBridge Peer._skybridge._tcp.local",
            host = "192.168.1.30",
            port = 44_000
        ),
        remoteDesktop = formalEndpoint(
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            instanceName = REMOTE_DESKTOP_INSTANCE,
            host = "192.168.1.31",
            port = 5_901
        )
    )

    private fun formalEndpoint(
        serviceType: String,
        instanceName: String,
        host: String,
        port: Int
    ) = FormalLanBonjourEndpoint(
        serviceType = serviceType,
        instanceName = instanceName,
        hostAddress = host,
        port = port,
        routeProvenance = AppleBonjourEndpointProvenance.SERVICE_INDEX.name,
        advertisedDeviceId = "ios-device-1",
        advertisedProtocolFingerprint = VALID_FINGERPRINT,
        discoveryRevision = 1
    )

    private companion object {
        const val NOW = 1_800_000_000_000
        const val FILE_TRANSFER_INSTANCE = "SkyBridge Peer._skybridge-transfer._tcp.local"
        const val REMOTE_DESKTOP_INSTANCE = "SkyBridge Peer._skybridge-rd._tcp.local"
        const val VALID_FINGERPRINT =
            "aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22"
    }
}
