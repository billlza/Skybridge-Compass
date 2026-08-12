package com.skybridge.compass.android.discovery

import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.discovery.data.interop.AppleBonjourEndpointProvenance
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.shared.productsession.AuthenticatedProductRouteBinding
import com.skybridge.compass.shared.productsession.ProductRouteBindingProtocol
import com.skybridge.compass.shared.productsession.ProductRouteKind
import com.skybridge.compass.shared.productsession.ProductSessionAuthority
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import com.skybridge.compass.shared.productsession.ProductSessionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscoveryPeerActionProjectionTest {
    @Test
    fun actionsForMergedAppleBonjourPeerKeepsProductRoutesButRequiresAuthenticatedProductSession() {
        val device = discoveredDevice(
            type = DeviceType.IOS,
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::1",
            port = 44000,
            capabilities = setOf(DeviceCapability.FILE_TRANSFER, DeviceCapability.SCREEN_SHARING),
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010",
                "serviceAddress:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "192.168.1.30",
                "serviceInstance:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to FILE_TRANSFER_INSTANCE,
                "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901",
                "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "192.168.1.31",
                "serviceInstance:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to REMOTE_DESKTOP_INSTANCE
            )
        )

        val actions = DiscoveryPeerActionProjection.actionsFor(device, DeveloperSettings())

        assertEquals(
            listOf(
                DiscoveryPeerActionKind.Handshake,
                DiscoveryPeerActionKind.FileTransfer,
                DiscoveryPeerActionKind.RemoteDesktop
            ),
            actions.map { it.kind }
        )
        val handshake = actions.single { it.kind == DiscoveryPeerActionKind.Handshake }
        val fileTransfer = actions.single { it.kind == DiscoveryPeerActionKind.FileTransfer }
        val remoteDesktop = actions.single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }

        assertTrue(handshake.enabled)
        assertFalse(fileTransfer.enabled)
        assertEquals(
            DiscoveryPeerActionDisabledReason.AuthenticatedProductSessionRequired,
            fileTransfer.disabledReason
        )
        assertEquals("192.168.1.30", fileTransfer.endpoint.host)
        assertFalse(remoteDesktop.enabled)
        assertEquals(
            DiscoveryPeerActionDisabledReason.AuthenticatedProductSessionRequired,
            remoteDesktop.disabledReason
        )
        assertEquals(5901, remoteDesktop.endpoint.port)
    }

    @Test
    fun matchingEstablishedProductSessionWithAuthenticatedRoutesEnablesFileTransferAndRemoteDesktopActions() {
        val device = discoveredDevice(
            type = DeviceType.IOS,
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::1",
            port = 44000,
            capabilities = setOf(DeviceCapability.FILE_TRANSFER, DeviceCapability.SCREEN_SHARING),
            txtRecords = mapOf(
                "deviceId" to "ios-device-1",
                "pubKeyFP" to VALID_FINGERPRINT
            ),
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010",
                "serviceAddress:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "192.168.1.30",
                "serviceInstance:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to FILE_TRANSFER_INSTANCE,
                "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901",
                "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "192.168.1.31",
                "serviceInstance:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to REMOTE_DESKTOP_INSTANCE
            )
        )

        val actions = DiscoveryPeerActionProjection.actionsFor(
            device = device,
            developerSettings = DeveloperSettings(),
            productSession = productSession(
                authenticatedRouteBindings = listOf(
                    routeBinding(
                        kind = DiscoveryPeerActionKind.FileTransfer,
                        serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
                        instanceName = FILE_TRANSFER_INSTANCE,
                        host = "192.168.1.30",
                        port = 44010,
                        provenance = AppleBonjourEndpointProvenance.SERVICE_INDEX
                    ),
                    routeBinding(
                        kind = DiscoveryPeerActionKind.RemoteDesktop,
                        serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                        instanceName = REMOTE_DESKTOP_INSTANCE,
                        host = "192.168.1.31",
                        port = 5901,
                        provenance = AppleBonjourEndpointProvenance.SERVICE_INDEX
                    )
                )
            ),
            nowEpochMillis = NOW
        )

        val fileTransfer = actions.single { it.kind == DiscoveryPeerActionKind.FileTransfer }
        val remoteDesktop = actions.single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }
        assertTrue(fileTransfer.enabled)
        assertNull(fileTransfer.disabledReason)
        assertTrue(remoteDesktop.enabled)
        assertNull(remoteDesktop.disabledReason)
    }

    @Test
    fun sharedProductSessionSnapshotEnablesOnlyMatchingResolvedBonjourRoutes() {
        val device = discoveredDevice(
            type = DeviceType.IOS,
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::1",
            port = 44000,
            capabilities = setOf(DeviceCapability.FILE_TRANSFER, DeviceCapability.SCREEN_SHARING),
            txtRecords = mapOf(
                "deviceId" to "ios-device-1",
                "pubKeyFP" to VALID_FINGERPRINT
            ),
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010",
                "serviceAddress:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "192.168.1.30",
                "serviceInstance:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to FILE_TRANSFER_INSTANCE,
                "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901",
                "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "192.168.1.31",
                "serviceInstance:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to REMOTE_DESKTOP_INSTANCE
            )
        )
        val productSession = DiscoveryPeerActionProjection.productSessionFor(
            device = device,
            productSessions = listOf(sharedProductSession()),
            nowEpochMillis = NOW
        )

        val actions = DiscoveryPeerActionProjection.actionsFor(
            device = device,
            developerSettings = DeveloperSettings(),
            productSession = productSession,
            nowEpochMillis = NOW
        )

        assertTrue(actions.single { it.kind == DiscoveryPeerActionKind.FileTransfer }.enabled)
        assertTrue(actions.single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }.enabled)
    }

    @Test
    fun sharedProductSessionSnapshotDoesNotCreateRoutesFromCapabilitiesOnly() {
        val device = discoveredDevice(
            type = DeviceType.IOS,
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::1",
            port = 44000,
            capabilities = setOf(DeviceCapability.FILE_TRANSFER, DeviceCapability.SCREEN_SHARING),
            txtRecords = mapOf(
                "deviceId" to "ios-device-1",
                "pubKeyFP" to VALID_FINGERPRINT
            )
        )
        val productSession = DiscoveryPeerActionProjection.productSessionFor(
            device = device,
            productSessions = listOf(sharedProductSession()),
            nowEpochMillis = NOW
        )

        val actions = DiscoveryPeerActionProjection.actionsFor(
            device = device,
            developerSettings = DeveloperSettings(),
            productSession = productSession,
            nowEpochMillis = NOW
        )

        assertEquals(listOf(DiscoveryPeerActionKind.Handshake), actions.map { it.kind })
    }

    @Test
    fun featureTogglesDisableRoutedActionsWithoutRemovingTheirRouteEvidence() {
        val device = discoveredDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::1",
            port = 44000,
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010",
                "serviceAddress:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "fe80::1",
                "serviceInstance:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to FILE_TRANSFER_INSTANCE,
                "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901",
                "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "fe80::1",
                "serviceInstance:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to REMOTE_DESKTOP_INSTANCE
            )
        )

        val actions = DiscoveryPeerActionProjection.actionsFor(
            device,
            DeveloperSettings(enableFileTransfer = false, enableRemoteControl = false)
        )

        val fileTransfer = actions.single { it.kind == DiscoveryPeerActionKind.FileTransfer }
        val remoteDesktop = actions.single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }
        assertFalse(fileTransfer.enabled)
        assertFalse(remoteDesktop.enabled)
        assertEquals(DiscoveryPeerActionDisabledReason.FeatureDisabled, fileTransfer.disabledReason)
        assertEquals(DiscoveryPeerActionDisabledReason.FeatureDisabled, remoteDesktop.disabledReason)
    }

    @Test
    fun productRoutesRejectMissingIdentityStaleSessionAndMismatchedSession() {
        val missingIdentity = discoveredDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::5",
            port = 44000,
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "44010",
                "serviceAddress:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to "fe80::5",
                "serviceInstance:${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}" to FILE_TRANSFER_INSTANCE
            )
        )
        val missingIdentityAction = DiscoveryPeerActionProjection.actionsFor(
            missingIdentity,
            DeveloperSettings(),
            productSession = productSession(),
            nowEpochMillis = NOW
        ).single { it.kind == DiscoveryPeerActionKind.FileTransfer }
        assertFalse(missingIdentityAction.enabled)
        assertEquals(
            DiscoveryPeerActionDisabledReason.MissingPeerIdentity,
            missingIdentityAction.disabledReason
        )

        val identified = discoveredDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::6",
            port = 44000,
            txtRecords = mapOf(
                "deviceId" to "ios-device-1",
                "pubKeyFP" to VALID_FINGERPRINT
            ),
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901",
                "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "fe80::6",
                "serviceInstance:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to REMOTE_DESKTOP_INSTANCE
            )
        )
        val missingRouteBinding = DiscoveryPeerActionProjection.actionsFor(
            identified,
            DeveloperSettings(),
            productSession = productSession(),
            nowEpochMillis = NOW
        ).single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }
        assertFalse(missingRouteBinding.enabled)
        assertEquals(
            DiscoveryPeerActionDisabledReason.MissingAuthenticatedRouteBinding,
            missingRouteBinding.disabledReason
        )

        val expired = DiscoveryPeerActionProjection.actionsFor(
            identified,
            DeveloperSettings(),
            productSession = productSession(expiresAtEpochMillis = NOW),
            nowEpochMillis = NOW
        ).single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }
        assertFalse(expired.enabled)
        assertEquals(DiscoveryPeerActionDisabledReason.ProductSessionExpired, expired.disabledReason)

        val negotiating = DiscoveryPeerActionProjection.actionsFor(
            identified,
            DeveloperSettings(),
            productSession = productSession(state = DiscoveryProductSessionState.Negotiating),
            nowEpochMillis = NOW
        ).single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }
        assertFalse(negotiating.enabled)
        assertEquals(
            DiscoveryPeerActionDisabledReason.ProductSessionNotEstablished,
            negotiating.disabledReason
        )

        val deviceMismatch = DiscoveryPeerActionProjection.actionsFor(
            identified,
            DeveloperSettings(),
            productSession = productSession(remoteDeviceId = "other-device"),
            nowEpochMillis = NOW
        ).single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }
        assertFalse(deviceMismatch.enabled)
        assertEquals(
            DiscoveryPeerActionDisabledReason.PeerDeviceIdMismatch,
            deviceMismatch.disabledReason
        )

        val fingerprintMismatch = DiscoveryPeerActionProjection.actionsFor(
            identified,
            DeveloperSettings(),
            productSession = productSession(remotePublicKeyFingerprint = OTHER_FINGERPRINT),
            nowEpochMillis = NOW
        ).single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }
        assertFalse(fingerprintMismatch.enabled)
        assertEquals(
            DiscoveryPeerActionDisabledReason.PeerFingerprintMismatch,
            fingerprintMismatch.disabledReason
        )

        val expiredRouteBinding = DiscoveryPeerActionProjection.actionsFor(
            identified,
            DeveloperSettings(),
            productSession = productSession(
                authenticatedRouteBindings = listOf(
                    routeBinding(
                        kind = DiscoveryPeerActionKind.RemoteDesktop,
                        serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                        instanceName = REMOTE_DESKTOP_INSTANCE,
                        host = "fe80::6",
                        port = 5901,
                        provenance = AppleBonjourEndpointProvenance.SERVICE_INDEX,
                        expiresAtEpochMillis = NOW
                    )
                )
            ),
            nowEpochMillis = NOW
        ).single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }
        assertFalse(expiredRouteBinding.enabled)
        assertEquals(
            DiscoveryPeerActionDisabledReason.AuthenticatedRouteBindingExpired,
            expiredRouteBinding.disabledReason
        )
    }

    @Test
    fun productRoutesRequireDnsSdInstanceNameToMatchAuthenticatedBinding() {
        val device = discoveredDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::6",
            port = 44000,
            txtRecords = mapOf(
                "deviceId" to "ios-device-1",
                "pubKeyFP" to VALID_FINGERPRINT
            ),
            extra = mapOf(
                "servicePort:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "5901",
                "serviceAddress:${AppleBonjourInterop.REMOTE_SERVICE_TYPE}" to "fe80::6"
            )
        )

        val action = DiscoveryPeerActionProjection.actionsFor(
            device = device,
            developerSettings = DeveloperSettings(),
            productSession = productSession(
                authenticatedRouteBindings = listOf(
                    routeBinding(
                        kind = DiscoveryPeerActionKind.RemoteDesktop,
                        serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
                        instanceName = REMOTE_DESKTOP_INSTANCE,
                        host = "fe80::6",
                        port = 5901,
                        provenance = AppleBonjourEndpointProvenance.SERVICE_INDEX
                    )
                )
            ),
            nowEpochMillis = NOW
        ).single { it.kind == DiscoveryPeerActionKind.RemoteDesktop }

        assertFalse(action.enabled)
        assertEquals(DiscoveryPeerActionDisabledReason.MissingRouteInstanceName, action.disabledReason)
    }

    @Test
    fun capabilityTokensWithoutServiceEndpointsDoNotCreateFileOrRemoteActions() {
        val device = discoveredDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::2",
            port = 44000,
            capabilities = setOf(DeviceCapability.FILE_TRANSFER, DeviceCapability.SCREEN_SHARING)
        )

        val actions = DiscoveryPeerActionProjection.actionsFor(device, DeveloperSettings())

        assertEquals(listOf(DiscoveryPeerActionKind.Handshake), actions.map { it.kind })
    }

    @Test
    fun androidPeerDoesNotExposeRemoteDesktopAction() {
        val device = discoveredDevice(
            type = DeviceType.ANDROID,
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            address = "192.168.1.60",
            port = 5901,
            capabilities = setOf(DeviceCapability.SCREEN_SHARING)
        )

        val actions = DiscoveryPeerActionProjection.actionsFor(device, DeveloperSettings())

        assertTrue(actions.none { it.kind == DiscoveryPeerActionKind.RemoteDesktop })
    }

    @Test
    fun connectedPeerKeepsHandshakeEvidenceButDisablesDuplicateHandshakeAction() {
        val device = discoveredDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::3",
            port = 44000,
            isConnected = true
        )

        val action = DiscoveryPeerActionProjection.actionsFor(device, DeveloperSettings()).single()

        assertEquals(DiscoveryPeerActionKind.Handshake, action.kind)
        assertFalse(action.enabled)
        assertEquals(DiscoveryPeerActionDisabledReason.AlreadyConnected, action.disabledReason)
    }

    @Test
    fun nonBonjourPeerHasNoAppleInteropActions() {
        val device = discoveredDevice(
            protocol = DiscoveryProtocol.UDP_BROADCAST,
            serviceType = null,
            address = "192.168.1.70",
            port = 8080
        )

        assertTrue(DiscoveryPeerActionProjection.actionsFor(device, DeveloperSettings()).isEmpty())
    }

    @Test
    fun routedActionsDoNotTreatTxtIdentityAsTrust() {
        val device = discoveredDevice(
            serviceType = AppleBonjourInterop.MAIN_SERVICE_TYPE,
            address = "fe80::4",
            port = 44000,
            txtRecords = mapOf(
                "deviceid" to "ios-peer",
                "pubkeyfp" to "aa11bb22"
            )
        )

        val handshake = DiscoveryPeerActionProjection.actionsFor(device, DeveloperSettings()).single()

        assertEquals(DiscoveryPeerActionKind.Handshake, handshake.kind)
        assertNull(handshake.disabledReason)
    }

    private fun discoveredDevice(
        protocol: DiscoveryProtocol = DiscoveryProtocol.BONJOUR,
        type: DeviceType = DeviceType.IOS,
        serviceType: String?,
        address: String,
        port: Int,
        capabilities: Set<DeviceCapability> = emptySet(),
        extra: Map<String, String> = emptyMap(),
        txtRecords: Map<String, String> = emptyMap(),
        isConnected: Boolean = false
    ) = DiscoveredDevice(
        id = "peer",
        name = "SkyBridge Peer",
        type = type,
        capabilities = capabilities,
        connectionInfo = ConnectionInfo(
            protocol = protocol,
            address = address,
            port = port,
            serviceType = serviceType,
            txtRecords = txtRecords,
            extra = extra
        ),
        signalStrength = 100,
        lastSeen = 1_000,
        isConnected = isConnected
    )

    private fun productSession(
        remoteDeviceId: String = "ios-device-1",
        remotePublicKeyFingerprint: String = VALID_FINGERPRINT,
        state: DiscoveryProductSessionState = DiscoveryProductSessionState.Established,
        expiresAtEpochMillis: Long? = NOW + 60_000,
        authenticatedRouteBindings: List<AuthenticatedDiscoveryProductRouteBinding> = emptyList()
    ) = EstablishedDiscoveryProductSession(
        sessionId = "session-1",
        remoteDeviceId = remoteDeviceId,
        remotePublicKeyFingerprint = remotePublicKeyFingerprint,
        state = state,
        expiresAtEpochMillis = expiresAtEpochMillis,
        authenticatedRouteBindings = authenticatedRouteBindings
    )

    private fun routeBinding(
        kind: DiscoveryPeerActionKind,
        serviceType: String,
        instanceName: String = "${kind.name}.${serviceType}.local",
        host: String,
        port: Int,
        provenance: AppleBonjourEndpointProvenance,
        expiresAtEpochMillis: Long? = NOW + 60_000
    ) = AuthenticatedDiscoveryProductRouteBinding(
        kind = kind,
        serviceType = serviceType,
        instanceName = instanceName,
        host = host,
        port = port,
        provenance = provenance,
        expiresAtEpochMillis = expiresAtEpochMillis
    )

    private fun sharedProductSession(
        remoteDeviceId: String = "ios-device-1",
        remotePublicKeyFingerprint: String = VALID_FINGERPRINT,
        expiresAtEpochMillis: Long = NOW + 60_000
    ) = ProductSessionAuthority(
        owner = ProductSessionOwner.create("session-1", generation = 1),
        sessionId = "session-1",
        remoteDeviceId = remoteDeviceId,
        remotePublicKeyFingerprint = remotePublicKeyFingerprint,
        state = ProductSessionState.ESTABLISHED,
        expiresAtEpochMillis = expiresAtEpochMillis,
        authenticatedRouteBindings = listOf(
            sharedRouteBinding(
                kind = ProductRouteKind.FILE_TRANSFER,
                host = "192.168.1.30",
                port = 44010,
                expiresAtEpochMillis = expiresAtEpochMillis
            ),
            sharedRouteBinding(
                kind = ProductRouteKind.REMOTE_DESKTOP,
                host = "192.168.1.31",
                port = 5901,
                expiresAtEpochMillis = expiresAtEpochMillis
            )
        )
    )

    private fun sharedRouteBinding(
        kind: ProductRouteKind,
        host: String,
        port: Int,
        expiresAtEpochMillis: Long
    ) = AuthenticatedProductRouteBinding(
        kind = kind,
        serviceType = kind.serviceType,
        instanceName = when (kind) {
            ProductRouteKind.FILE_TRANSFER -> FILE_TRANSFER_INSTANCE
            ProductRouteKind.REMOTE_DESKTOP -> REMOTE_DESKTOP_INSTANCE
        },
        hostName = host,
        port = port,
        endpointProvenance = ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD,
        sessionHashHex = "1111111111111111",
        transcriptPrefixHex = "2222222222222222",
        expiresAtEpochMillis = expiresAtEpochMillis
    )

    private companion object {
        const val NOW = 1_800_000_000_000
        const val FILE_TRANSFER_INSTANCE = "SkyBridge Peer._skybridge-transfer._tcp.local"
        const val REMOTE_DESKTOP_INSTANCE = "SkyBridge Peer._skybridge-remote._tcp.local"
        const val VALID_FINGERPRINT =
            "aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22"
        const val OTHER_FINGERPRINT =
            "bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11"
    }
}
