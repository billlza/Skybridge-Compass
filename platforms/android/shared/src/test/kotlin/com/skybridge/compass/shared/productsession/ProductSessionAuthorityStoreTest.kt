package com.skybridge.compass.shared.productsession

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProductSessionAuthorityStoreTest {
    @Test
    fun upsertEstablishedRouteBindingStoresShortLivedRemoteAuthority() {
        val store = InMemoryProductSessionAuthorityStore()
        val owner = owner()
        store.claimSession(owner)

        store.upsertEstablishedRouteBinding(
            owner = owner,
            remoteDeviceId = "mac-device",
            remotePublicKeyFingerprint = FINGERPRINT_A,
            binding = binding(expiresAtEpochMillis = NOW + 60_000),
            nowEpochMillis = NOW
        )

        val session = store.sessions.value.single()
        assertEquals("session-1", session.sessionId)
        assertEquals("mac-device", session.remoteDeviceId)
        assertEquals(FINGERPRINT_A, session.remotePublicKeyFingerprint)
        assertEquals(ProductSessionState.ESTABLISHED, session.state)
        assertEquals(NOW + 60_000, session.expiresAtEpochMillis)
        assertEquals(1, session.authenticatedRouteBindings.size)
    }

    @Test
    fun upsertReplacesSameRouteAndBoundsBindings() {
        val store = InMemoryProductSessionAuthorityStore(maxBindingsPerSession = 1)
        val owner = owner()
        store.claimSession(owner)

        store.upsertEstablishedRouteBinding(
            owner = owner,
            remoteDeviceId = "mac-device",
            remotePublicKeyFingerprint = FINGERPRINT_A,
            binding = binding(port = 44010, expiresAtEpochMillis = NOW + 10_000),
            nowEpochMillis = NOW
        )
        store.upsertEstablishedRouteBinding(
            owner = owner,
            remoteDeviceId = "mac-device",
            remotePublicKeyFingerprint = FINGERPRINT_A,
            binding = binding(port = 5901, kind = ProductRouteKind.REMOTE_DESKTOP, expiresAtEpochMillis = NOW + 20_000),
            nowEpochMillis = NOW
        )

        val bindings = store.sessions.value.single().authenticatedRouteBindings
        assertEquals(1, bindings.size)
        assertEquals(ProductRouteKind.REMOTE_DESKTOP, bindings.single().kind)
    }

    @Test
    fun expiredBindingsAreRejectedAndCleared() {
        val store = InMemoryProductSessionAuthorityStore()
        val owner = owner()
        store.claimSession(owner)

        val error = runCatching {
            store.upsertEstablishedRouteBinding(
                owner = owner,
                remoteDeviceId = "mac-device",
                remotePublicKeyFingerprint = FINGERPRINT_A,
                binding = binding(expiresAtEpochMillis = NOW),
                nowEpochMillis = NOW
            )
        }.exceptionOrNull()
        assertEquals("route binding is expired", error?.message)

        store.upsertEstablishedRouteBinding(
            owner = owner,
            remoteDeviceId = "mac-device",
            remotePublicKeyFingerprint = FINGERPRINT_A,
            binding = binding(expiresAtEpochMillis = NOW + 1),
            nowEpochMillis = NOW
        )
        store.clearExpired(NOW + 1)

        assertTrue(store.sessions.value.isEmpty())
    }

    @Test
    fun secureFailureCleanupRemovesSession() {
        val store = InMemoryProductSessionAuthorityStore()
        val owner = owner()
        store.claimSession(owner)

        store.upsertEstablishedRouteBinding(
            owner = owner,
            remoteDeviceId = "mac-device",
            remotePublicKeyFingerprint = FINGERPRINT_A,
            binding = binding(expiresAtEpochMillis = NOW + 60_000),
            nowEpochMillis = NOW
        )
        assertEquals(ProductSessionMutationResult.APPLIED, store.clearSession(owner))

        assertTrue(store.sessions.value.isEmpty())
    }

    @Test
    fun staleOwnerCannotClearReplacementUsingTheSameSessionId() {
        val store = InMemoryProductSessionAuthorityStore()
        val firstOwner = owner(generation = 1)
        val replacementOwner = owner(generation = 2)

        assertEquals(ProductSessionOwnerClaimResult.CLAIMED, store.claimSession(firstOwner))
        store.upsertEstablishedRouteBinding(
            owner = firstOwner,
            remoteDeviceId = "first-mac",
            remotePublicKeyFingerprint = FINGERPRINT_A,
            binding = binding(expiresAtEpochMillis = NOW + 30_000),
            nowEpochMillis = NOW
        )
        assertEquals(
            ProductSessionOwnerClaimResult.REPLACED_EXISTING_OWNER,
            store.claimSession(replacementOwner)
        )
        store.upsertEstablishedRouteBinding(
            owner = replacementOwner,
            remoteDeviceId = "replacement-mac",
            remotePublicKeyFingerprint = FINGERPRINT_B,
            binding = binding(port = 44011, expiresAtEpochMillis = NOW + 60_000),
            nowEpochMillis = NOW
        )

        assertEquals(ProductSessionMutationResult.STALE_OWNER, store.clearSession(firstOwner))
        val authority = store.sessions.value.single()
        assertEquals(replacementOwner, authority.owner)
        assertEquals("replacement-mac", authority.remoteDeviceId)
        assertEquals(FINGERPRINT_B, authority.remotePublicKeyFingerprint)
    }

    @Test
    fun independentlyCreatedManagerOwnersWithSameGenerationRemainIsolated() {
        val store = InMemoryProductSessionAuthorityStore()
        val firstManagerOwner = owner(generation = 1)
        val secondManagerOwner = owner(generation = 1)

        assertEquals(ProductSessionOwnerClaimResult.CLAIMED, store.claimSession(firstManagerOwner))
        assertEquals(
            ProductSessionOwnerClaimResult.REPLACED_EXISTING_OWNER,
            store.claimSession(secondManagerOwner)
        )
        assertEquals(
            ProductSessionMutationResult.STALE_OWNER,
            store.upsertEstablishedRouteBinding(
                owner = firstManagerOwner,
                remoteDeviceId = "stale-mac",
                remotePublicKeyFingerprint = FINGERPRINT_A,
                binding = binding(expiresAtEpochMillis = NOW + 30_000),
                nowEpochMillis = NOW
            )
        )
        assertEquals(
            ProductSessionMutationResult.APPLIED,
            store.upsertEstablishedRouteBinding(
                owner = secondManagerOwner,
                remoteDeviceId = "current-mac",
                remotePublicKeyFingerprint = FINGERPRINT_B,
                binding = binding(expiresAtEpochMillis = NOW + 60_000),
                nowEpochMillis = NOW
            )
        )
        assertEquals(ProductSessionMutationResult.STALE_OWNER, store.markFailed(firstManagerOwner))

        val authority = store.sessions.value.single()
        assertEquals(secondManagerOwner, authority.owner)
        assertEquals(ProductSessionState.ESTABLISHED, authority.state)
    }

    @Test
    fun terminalMutationReleasesOwnerAndRejectsLateUpsert() {
        val store = InMemoryProductSessionAuthorityStore()
        val owner = owner()
        store.claimSession(owner)
        store.upsertEstablishedRouteBinding(
            owner = owner,
            remoteDeviceId = "mac-device",
            remotePublicKeyFingerprint = FINGERPRINT_A,
            binding = binding(expiresAtEpochMillis = NOW + 60_000),
            nowEpochMillis = NOW
        )

        assertEquals(ProductSessionMutationResult.APPLIED, store.markDisconnected(owner))
        assertEquals(ProductSessionState.DISCONNECTED, store.sessions.value.single().state)
        assertEquals(
            ProductSessionMutationResult.OWNER_NOT_ACTIVE,
            store.upsertEstablishedRouteBinding(
                owner = owner,
                remoteDeviceId = "mac-device",
                remotePublicKeyFingerprint = FINGERPRINT_A,
                binding = binding(expiresAtEpochMillis = NOW + 90_000),
                nowEpochMillis = NOW
            )
        )
    }

    @Test
    fun failedTerminalMutationClearsBindingsAndReleasesOwner() {
        val store = InMemoryProductSessionAuthorityStore()
        val owner = owner()
        store.claimSession(owner)
        store.upsertEstablishedRouteBinding(
            owner = owner,
            remoteDeviceId = "mac-device",
            remotePublicKeyFingerprint = FINGERPRINT_A,
            binding = binding(expiresAtEpochMillis = NOW + 60_000),
            nowEpochMillis = NOW
        )

        assertEquals(ProductSessionMutationResult.APPLIED, store.markFailed(owner))
        val failed = store.sessions.value.single()
        assertEquals(ProductSessionState.FAILED, failed.state)
        assertTrue(failed.authenticatedRouteBindings.isEmpty())
        assertEquals(
            ProductSessionMutationResult.OWNER_NOT_ACTIVE,
            store.upsertEstablishedRouteBinding(
                owner = owner,
                remoteDeviceId = "mac-device",
                remotePublicKeyFingerprint = FINGERPRINT_A,
                binding = binding(expiresAtEpochMillis = NOW + 90_000),
                nowEpochMillis = NOW
            )
        )
    }

    @Test
    fun activeOwnerCapacityFailsClosedWithoutEvictingExistingOwner() {
        val store = InMemoryProductSessionAuthorityStore(maxSessions = 1)
        val existingOwner = owner()
        val excessOwner = ProductSessionOwner.create("session-2", generation = 1)

        assertEquals(ProductSessionOwnerClaimResult.CLAIMED, store.claimSession(existingOwner))
        assertEquals(
            ProductSessionOwnerClaimResult.CAPACITY_REACHED,
            store.claimSession(excessOwner)
        )
        assertEquals(
            ProductSessionMutationResult.APPLIED,
            store.upsertEstablishedRouteBinding(
                owner = existingOwner,
                remoteDeviceId = "existing-mac",
                remotePublicKeyFingerprint = FINGERPRINT_A,
                binding = binding(expiresAtEpochMillis = NOW + 60_000),
                nowEpochMillis = NOW
            )
        )
        assertEquals(existingOwner, store.sessions.value.single().owner)
        assertEquals(
            ProductSessionMutationResult.OWNER_NOT_ACTIVE,
            store.clearSession(excessOwner)
        )
    }

    @Test
    fun clearingExpiredAuthorityRetainsLiveOwnerClaim() {
        val store = InMemoryProductSessionAuthorityStore()
        val owner = owner()
        store.claimSession(owner)
        store.upsertEstablishedRouteBinding(
            owner = owner,
            remoteDeviceId = "mac-device",
            remotePublicKeyFingerprint = FINGERPRINT_A,
            binding = binding(expiresAtEpochMillis = NOW + 1),
            nowEpochMillis = NOW
        )

        store.clearExpired(NOW + 1)
        assertTrue(store.sessions.value.isEmpty())
        assertEquals(
            ProductSessionMutationResult.APPLIED,
            store.upsertEstablishedRouteBinding(
                owner = owner,
                remoteDeviceId = "mac-device",
                remotePublicKeyFingerprint = FINGERPRINT_A,
                binding = binding(expiresAtEpochMillis = NOW + 60_000),
                nowEpochMillis = NOW + 1
            )
        )
    }

    private fun owner(generation: Long = 1): ProductSessionOwner =
        ProductSessionOwner.create(sessionId = "session-1", generation = generation)

    private fun binding(
        kind: ProductRouteKind = ProductRouteKind.FILE_TRANSFER,
        port: Int = 44010,
        expiresAtEpochMillis: Long
    ) = AuthenticatedProductRouteBinding(
        kind = kind,
        serviceType = kind.serviceType,
        instanceName = "Mac.${kind.serviceType}.local",
        hostName = "192.168.1.30",
        port = port,
        endpointProvenance = ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD,
        sessionHashHex = "1111111111111111",
        transcriptPrefixHex = "2222222222222222",
        expiresAtEpochMillis = expiresAtEpochMillis
    )

    private companion object {
        const val NOW = 1_800_000_000_000L
        const val FINGERPRINT_A =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        const val FINGERPRINT_B =
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
}
