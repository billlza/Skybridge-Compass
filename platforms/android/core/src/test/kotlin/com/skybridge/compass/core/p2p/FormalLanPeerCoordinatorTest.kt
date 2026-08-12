package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.p2p.P2PXWingKem
import com.skybridge.compass.shared.productsession.ProductRouteBindingProtocol
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FormalLanPeerCoordinatorTest {
    @Test
    fun missingFormalKemRefreshesThenAuthorizesXWingOnly() = runTest {
        val authority = activeAuthority()
        val authorityPort = FakeAuthorityPort(authority)
        val skr = FakeSkrPort {
            authorityPort.keys = PeerKemKeyStore.PeerKemPublicKeys(
                xWingPublicKey = ByteArray(P2PXWingKem.XWING_PUBLIC_KEY_SIZE) { 0x41 }
            )
        }
        val coordinator = coordinator(authorityPort, skr)
        val peer = peerSnapshot()

        val ready = coordinator.authorizeRemoteConnect(peer) { peer }

        assertEquals(1, skr.calls)
        assertEquals(peer.endpointDigest, ready.peer.endpointDigest)
        assertEquals(FINGERPRINT, ready.pinnedProtocolFingerprint)
    }

    @Test
    fun mlKemOnlyRefreshIsDurableButCannotAuthorizeFormalDial() = runTest {
        val authorityPort = FakeAuthorityPort(activeAuthority())
        val skr = FakeSkrPort {
            authorityPort.keys = PeerKemKeyStore.PeerKemPublicKeys(
                mlKem768PublicKey = ByteArray(1_184) { 0x42 }
            )
        }
        val peer = peerSnapshot()

        val error = captureFormalFailure {
            coordinator(authorityPort, skr).authorizeRemoteConnect(peer) { peer }
        }

        assertEquals(FormalLanPeerFailureReason.X_WING_REQUIRED, error.reason)
        assertEquals(1, skr.calls)
        assertTrue(authorityPort.keys.mlKem768PublicKey != null)
        assertTrue(authorityPort.keys.xWingPublicKey == null)
    }

    @Test
    fun changedRouteBeforeRefreshDoesNotCallSkr() = runTest {
        val authorityPort = FakeAuthorityPort(activeAuthority())
        val skr = FakeSkrPort()
        val expected = peerSnapshot(revision = 7)
        val changed = peerSnapshot(revision = 8)

        val error = captureFormalFailure {
            coordinator(authorityPort, skr).authorizeRemoteConnect(expected) { changed }
        }

        assertEquals(FormalLanPeerFailureReason.DISCOVERY_ROUTE_CHANGED, error.reason)
        assertEquals(0, skr.calls)
    }

    @Test
    fun changedRouteAfterRefreshFailsBeforeAuthorization() = runTest {
        val authorityPort = FakeAuthorityPort(activeAuthority())
        val expected = peerSnapshot(revision = 7)
        var current = expected
        val skr = FakeSkrPort {
            authorityPort.keys = xWingKeys()
            current = peerSnapshot(revision = 8)
        }

        val error = captureFormalFailure {
            coordinator(authorityPort, skr).authorizeRemoteConnect(expected) { current }
        }

        assertEquals(FormalLanPeerFailureReason.DISCOVERY_ROUTE_CHANGED, error.reason)
        assertEquals(1, skr.calls)
    }

    @Test
    fun authorityMutationAfterRefreshFailsClosed() = runTest {
        val authorityPort = FakeAuthorityPort(activeAuthority())
        val peer = peerSnapshot()
        val skr = FakeSkrPort {
            authorityPort.keys = xWingKeys()
            authorityPort.lookup = FormalLanAuthorityLookup.ActiveVerified(
                activeAuthority(fingerprint = OTHER_FINGERPRINT)
            )
        }

        val error = captureFormalFailure {
            coordinator(authorityPort, skr).authorizeRemoteConnect(peer) { peer }
        }

        assertEquals(FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH, error.reason)
    }

    @Test
    fun inactiveCanonicalAuthorityBlocksBeforeSkr() = runTest {
        val authorityPort = FakeAuthorityPort(activeAuthority()).apply {
            lookup = FormalLanAuthorityLookup.InactiveBlocked
        }
        val skr = FakeSkrPort()
        val peer = peerSnapshot()

        val error = captureFormalFailure {
            coordinator(authorityPort, skr).authorizeRemoteConnect(peer) { peer }
        }

        assertEquals(FormalLanPeerFailureReason.CANONICAL_AUTHORITY_BLOCKED, error.reason)
        assertEquals(0, skr.calls)
    }

    @Test
    fun existingFormalXWingSkipsRefresh() = runTest {
        val authorityPort = FakeAuthorityPort(activeAuthority()).apply { keys = xWingKeys() }
        val skr = FakeSkrPort()
        val peer = peerSnapshot()

        coordinator(authorityPort, skr).authorizeRemoteConnect(peer) { peer }

        assertEquals(0, skr.calls)
    }

    @Test
    fun existingProductSessionRouteRequiresDurableExactPinAndXWingWithoutNetworkRefresh() = runTest {
        val authorityPort = FakeAuthorityPort(activeAuthority()).apply { keys = xWingKeys() }
        val skr = FakeSkrPort()

        val authorized = coordinator(authorityPort, skr)
            .authorizeDurableProductSessionRoute(DEVICE_ID, FINGERPRINT)

        assertEquals(FINGERPRINT, authorized.pinnedProtocolFingerprint)
        assertEquals(listOf(DEVICE_ID), authorized.authorityDeviceIds)
        assertEquals(0, skr.calls)

        authorityPort.keys = PeerKemKeyStore.PeerKemPublicKeys(
            mlKem768PublicKey = ByteArray(1_184)
        )
        assertEquals(
            FormalLanPeerFailureReason.X_WING_REQUIRED,
            captureFormalFailure {
                coordinator(authorityPort, skr)
                    .authorizeDurableProductSessionRoute(DEVICE_ID, FINGERPRINT)
            }.reason
        )
        assertEquals(0, skr.calls)
    }

    @Test
    fun existingProductSessionRouteFailsClosedForNonDurableOrChangedAuthority() = runTest {
        val authorityPort = FakeAuthorityPort(activeAuthority()).apply { keys = xWingKeys() }
        val coordinator = coordinator(authorityPort, FakeSkrPort())

        authorityPort.lookup = FormalLanAuthorityLookup.Absent
        assertEquals(
            FormalLanPeerFailureReason.ACTIVE_AUTHENTICATED_PIN_REQUIRED,
            captureFormalFailure {
                coordinator.authorizeDurableProductSessionRoute(DEVICE_ID, FINGERPRINT)
            }.reason
        )
        authorityPort.lookup = FormalLanAuthorityLookup.ActiveNeedsExplicitPairing(FINGERPRINT)
        assertEquals(
            FormalLanPeerFailureReason.ACTIVE_AUTHENTICATED_PIN_REQUIRED,
            captureFormalFailure {
                coordinator.authorizeDurableProductSessionRoute(DEVICE_ID, FINGERPRINT)
            }.reason
        )
        authorityPort.lookup = FormalLanAuthorityLookup.InactiveBlocked
        assertEquals(
            FormalLanPeerFailureReason.CANONICAL_AUTHORITY_BLOCKED,
            captureFormalFailure {
                coordinator.authorizeDurableProductSessionRoute(DEVICE_ID, FINGERPRINT)
            }.reason
        )
        authorityPort.lookup = FormalLanAuthorityLookup.ActiveVerified(activeAuthority())
        assertEquals(
            FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH,
            captureFormalFailure {
                coordinator.authorizeDurableProductSessionRoute(DEVICE_ID, OTHER_FINGERPRINT)
            }.reason
        )
        assertEquals(
            FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH,
            captureFormalFailure {
                coordinator.authorizeDurableProductSessionRoute("id:unknown", FINGERPRINT)
            }.reason
        )
        authorityPort.lookupError = TrustedPeerStoreCorruptionException("test corruption")
        assertEquals(
            FormalLanPeerFailureReason.TRUST_STORE_CORRUPTED,
            captureFormalFailure {
                coordinator.authorizeDurableProductSessionRoute(DEVICE_ID, FINGERPRINT)
            }.reason
        )
    }

    @Test
    fun signedCanonicalResponderIdMayUseOriginalBonjourAliasAsDiscoveryKey() = runTest {
        val alias = "bonjour:mac@local."
        val canonical = "id:mac-1"
        val authorityPort = FakeAuthorityPort(activeAuthority()).apply {
            lookup = FormalLanAuthorityLookup.Absent
        }
        val expected = peerSnapshot(deviceId = alias)
        val result = pairingResult(deviceId = canonical, aliases = listOf(alias))
        val pib = object : FormalLanPibPort {
            override suspend fun request(snapshot: FormalLanPeerSnapshot) = result
            override suspend fun confirm(
                snapshot: FormalLanPeerSnapshot,
                result: PibPairingClient.PairingResult
            ): TrustedPeerRecord = error("confirm must not be called")
        }

        val candidate = coordinator(authorityPort, FakeSkrPort(), pib)
            .requestPairing(expected) { expected }

        assertEquals(alias, candidate.discoveryPeerKey)
        assertEquals(canonical, candidate.macDeviceId)
    }

    @Test
    fun finalAckPersistenceFailurePreservesReceiptAndNeverRunsSkr() = runTest {
        listOf(true, false).forEach { rollbackConfirmed ->
            val authorityPort = FakeAuthorityPort(activeAuthority())
            val skr = FakeSkrPort()
            val pib = FailingPersistencePibPort(rollbackConfirmed)
            val peer = peerSnapshot()

            val error = captureFormalFailure {
                coordinator(authorityPort, skr, pib)
                    .confirmPairingAndRefresh(candidate(peer)) { peer }
            }

            assertEquals(FormalLanPeerFailureReason.LOCAL_TRUST_PERSISTENCE_FAILED, error.reason)
            assertTrue(error.pibFinalAckVerified)
            assertEquals(rollbackConfirmed, error.localTrustRollbackConfirmed)
            assertFalse(error.durablePibReceiptObtained)
            assertEquals(0, skr.calls)
        }
    }

    @Test
    fun routeChangeBeforeFinalAckHasNoDurableAuthorityReceipt() = runTest {
        val authorityPort = FakeAuthorityPort(activeAuthority())
        val pib = FakePibPort(authorityPort)
        val peer = peerSnapshot()
        val candidate = candidate(peer)

        val error = captureFormalFailure {
            coordinator(authorityPort, FakeSkrPort(), pib)
                .confirmPairingAndRefresh(candidate) { peerSnapshot(revision = 2) }
        }

        assertFalse(error.durablePibReceiptObtained)
        assertEquals(0, pib.confirmCalls)
    }

    @Test
    fun routeChangeAfterDurableFinalAckReturnsReceiptAndRetryOnlyRunsSkr() = runTest {
        val authorityPort = FakeAuthorityPort(activeAuthority())
        val pib = FakePibPort(authorityPort)
        val skr = FakeSkrPort { authorityPort.keys = xWingKeys() }
        val peer = peerSnapshot()
        var reads = 0

        val error = captureFormalFailure {
            coordinator(authorityPort, skr, pib).confirmPairingAndRefresh(candidate(peer)) {
                if (reads++ == 0) peer else peerSnapshot(revision = 2)
            }
        }

        assertTrue(error.durablePibReceiptObtained)
        assertEquals(1, pib.confirmCalls)
        assertEquals(0, skr.calls)

        coordinator(authorityPort, skr, pib).refreshAndAuthorize(peer) { peer }
        assertEquals(1, pib.confirmCalls)
        assertEquals(1, skr.calls)
    }

    private fun coordinator(
        authorityPort: FakeAuthorityPort,
        skr: FakeSkrPort,
        pib: FormalLanPibPort = NeverPibPort
    ) = FormalLanPeerCoordinator(authorityPort, pib, skr)

    private suspend fun captureFormalFailure(
        block: suspend () -> Unit
    ): FormalLanPeerException = try {
        block()
        error("expected FormalLanPeerException")
    } catch (error: FormalLanPeerException) {
        error
    }

    private fun peerSnapshot(
        revision: Long = 1,
        deviceId: String = DEVICE_ID
    ): FormalLanPeerSnapshot =
        FormalLanPeerSnapshot(
            displayName = "Mac",
            handshake = endpoint(
                serviceType = ProductRouteBindingProtocol.CONTROL_SERVICE_TYPE,
                instanceName = "Mac._skybridge._tcp.local",
                host = "192.168.1.10",
                port = 44_000,
                revision = revision,
                deviceId = deviceId
            ),
            remoteDesktop = endpoint(
                serviceType = ProductRouteBindingProtocol.REMOTE_DESKTOP_SERVICE_TYPE,
                instanceName = "Mac._skybridge-rd._tcp.local",
                host = "192.168.1.10",
                port = 5_901,
                revision = revision,
                deviceId = deviceId
            )
        )

    private fun endpoint(
        serviceType: String,
        instanceName: String,
        host: String,
        port: Int,
        revision: Long,
        deviceId: String = DEVICE_ID
    ) = FormalLanBonjourEndpoint(
        serviceType = serviceType,
        instanceName = instanceName,
        hostAddress = host,
        port = port,
        routeProvenance = "SERVICE_INDEX",
        advertisedDeviceId = deviceId,
        advertisedProtocolFingerprint = FINGERPRINT,
        discoveryRevision = revision
    )

    private fun activeAuthority(fingerprint: String = FINGERPRINT) =
        FormalLanAuthoritySnapshot(
            deviceId = DEVICE_ID,
            currentDeviceId = DEVICE_ID,
            knownDeviceIds = listOf(DEVICE_ID),
            protocolSigningAlgorithm = "Ed25519",
            protocolPublicKeyFingerprint = fingerprint
        )

    private fun xWingKeys() = PeerKemKeyStore.PeerKemPublicKeys(
        xWingPublicKey = ByteArray(P2PXWingKem.XWING_PUBLIC_KEY_SIZE) { 0x55 }
    )

    private fun candidate(peer: FormalLanPeerSnapshot): FormalLanPairingCandidate =
        FormalLanPairingCandidate(
            macName = "Mac",
            macDeviceId = DEVICE_ID,
            discoveryPeerKey = peer.deviceId,
            sasCode = "123456",
            macFingerprint = FINGERPRINT,
            macSigningAlgorithm = "Ed25519",
            expectedSnapshot = peer,
            transcript = pairingResult()
        )

    private fun pairingResult(
        deviceId: String = DEVICE_ID,
        aliases: List<String> = listOf(deviceId)
    ) = PibPairingClient.PairingResult(
        sasCode = "123456",
        macFingerprint = FINGERPRINT,
        macSigningAlgorithm = "Ed25519",
        macDeviceId = deviceId,
        macDeviceName = "Mac",
        macAliases = aliases,
        transactionId = "transaction-1",
        requestNonce = ByteArray(24),
        requestHashHex = "1".repeat(64),
        candidateHashHex = "2".repeat(64),
        sasTranscriptHashHex = "3".repeat(64),
        requesterDeviceId = "android-1",
        requesterProtocolSigningAlgorithm = "ML-DSA-65",
        requesterProtocolIdentityFingerprint = "4".repeat(64),
        requesterSignature = byteArrayOf(1),
        requestCanonicalPreimage = byteArrayOf(2),
        macProtocolIdentityPublicKey = ByteArray(32),
        candidateExpiresAtReferenceSeconds = 1_000_000_000.0
    )

    private class FakeAuthorityPort(authority: FormalLanAuthoritySnapshot) : FormalLanAuthorityPort {
        var lookup: FormalLanAuthorityLookup =
            FormalLanAuthorityLookup.ActiveVerified(authority)
        var keys = PeerKemKeyStore.PeerKemPublicKeys()
        var lookupError: RuntimeException? = null

        override fun lookupAuthority(deviceId: String): FormalLanAuthorityLookup =
            lookupError?.let { throw it } ?: lookup
        override fun readFormalKem(deviceId: String): PeerKemKeyStore.PeerKemPublicKeys = keys
    }

    private class FailingPersistencePibPort(
        private val rollbackConfirmed: Boolean
    ) : FormalLanPibPort {
        override suspend fun request(snapshot: FormalLanPeerSnapshot) = pairingResultStatic()

        override suspend fun confirm(
            snapshot: FormalLanPeerSnapshot,
            result: PibPairingClient.PairingResult
        ): TrustedPeerRecord = throw PibPairingClient.PairingError.TrustPersistence(
            message = "test persistence failure",
            finalAckVerified = true,
            rollbackConfirmed = rollbackConfirmed
        )
    }

    private class FakeSkrPort(
        private val afterRefresh: () -> Unit = {}
    ) : FormalLanSkrPort {
        var calls = 0

        override suspend fun refresh(
            snapshot: FormalLanPeerSnapshot,
            pinnedProtocolFingerprint: String
        ): SignedLanKemRefreshClient.RefreshResult {
            calls += 1
            afterRefresh()
            return SignedLanKemRefreshClient.RefreshResult(
                deviceId = DEVICE_ID,
                aliases = listOf(DEVICE_ID),
                keyId = "key-1",
                generation = 1,
                expiresAtMillis = Long.MAX_VALUE,
                signedSuiteWireIds = emptyList(),
                payloadHashHex = "5".repeat(64)
            )
        }
    }

    private class FakePibPort(
        private val authorityPort: FakeAuthorityPort
    ) : FormalLanPibPort {
        var confirmCalls = 0
        override suspend fun request(snapshot: FormalLanPeerSnapshot) = pairingResultStatic()

        override suspend fun confirm(
            snapshot: FormalLanPeerSnapshot,
            result: PibPairingClient.PairingResult
        ): TrustedPeerRecord {
            confirmCalls += 1
            val authority = activeAuthorityStatic()
            authorityPort.lookup = FormalLanAuthorityLookup.ActiveVerified(authority)
            return TrustedPeerRecord(
                deviceId = DEVICE_ID,
                protocolSigningAlgorithm = authority.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint = authority.protocolPublicKeyFingerprint,
                currentDeviceId = DEVICE_ID,
                knownDeviceIds = listOf(DEVICE_ID),
                lifecycleState = TrustedPeerLifecycleState.ACTIVE,
                verificationOrigin = TrustedPeerVerificationOrigin.AUTHENTICATED_PRODUCT_V1
            )
        }
    }

    private object NeverPibPort : FormalLanPibPort {
        override suspend fun request(snapshot: FormalLanPeerSnapshot): PibPairingClient.PairingResult =
            error("PIB must not be called")

        override suspend fun confirm(
            snapshot: FormalLanPeerSnapshot,
            result: PibPairingClient.PairingResult
        ): TrustedPeerRecord = error("PIB must not be called")
    }

    private companion object {
        const val DEVICE_ID = "mac-1"
        const val FINGERPRINT =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        const val OTHER_FINGERPRINT =
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

        fun activeAuthorityStatic() = FormalLanAuthoritySnapshot(
            deviceId = DEVICE_ID,
            currentDeviceId = DEVICE_ID,
            knownDeviceIds = listOf(DEVICE_ID),
            protocolSigningAlgorithm = "Ed25519",
            protocolPublicKeyFingerprint = FINGERPRINT
        )

        fun pairingResultStatic() = PibPairingClient.PairingResult(
            sasCode = "123456",
            macFingerprint = FINGERPRINT,
            macSigningAlgorithm = "Ed25519",
            macDeviceId = DEVICE_ID,
            macDeviceName = "Mac",
            macAliases = listOf(DEVICE_ID),
            transactionId = "transaction-1",
            requestNonce = ByteArray(24),
            requestHashHex = "1".repeat(64),
            candidateHashHex = "2".repeat(64),
            sasTranscriptHashHex = "3".repeat(64),
            requesterDeviceId = "android-1",
            requesterProtocolSigningAlgorithm = "ML-DSA-65",
            requesterProtocolIdentityFingerprint = "4".repeat(64),
            requesterSignature = byteArrayOf(1),
            requestCanonicalPreimage = byteArrayOf(2),
            macProtocolIdentityPublicKey = ByteArray(32),
            candidateExpiresAtReferenceSeconds = 1_000_000_000.0
        )
    }
}
