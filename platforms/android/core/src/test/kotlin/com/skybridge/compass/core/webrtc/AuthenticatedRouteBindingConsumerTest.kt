package com.skybridge.compass.core.webrtc

import com.skybridge.compass.core.p2p.AppMessage
import com.skybridge.compass.core.p2p.SwiftDateSeconds
import com.skybridge.compass.shared.productsession.InMemoryProductSessionAuthorityStore
import com.skybridge.compass.shared.productsession.ProductRouteKind
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AuthenticatedRouteBindingConsumerTest {
    @Test
    fun consumeWritesRemoteMacAuthorityUsingSwiftDateSeconds() {
        val store = InMemoryProductSessionAuthorityStore()
        val consumer = AuthenticatedRouteBindingConsumer(store)
        val context = context(nowEpochMillis = SwiftDateSeconds.toUnixEpochMillis(50.0))
        store.claimSession(context.sessionOwner)

        consumer.consume(
            payload = payload(),
            context = context
        )

        val session = store.sessions.value.single()
        assertEquals("mac-device", session.remoteDeviceId)
        assertEquals(REMOTE_FINGERPRINT, session.remotePublicKeyFingerprint)
        assertEquals(SwiftDateSeconds.toUnixEpochMillis(72.0), session.expiresAtEpochMillis)
        val binding = session.authenticatedRouteBindings.single()
        assertEquals(ProductRouteKind.REMOTE_DESKTOP, binding.kind)
        assertEquals("_skybridge-rd._tcp", binding.serviceType)
        assertEquals("Desk Mac._skybridge-rd._tcp.local", binding.instanceName)
        assertEquals("desk-mac.local", binding.hostName)
        assertEquals("1111111111111111", binding.sessionHashHex)
        assertEquals("2222222222222222", binding.transcriptPrefixHex)
    }

    @Test
    fun legacyDedicatedServiceLabelIsAcceptedAndStoredCanonically() {
        val store = InMemoryProductSessionAuthorityStore()
        val consumer = AuthenticatedRouteBindingConsumer(store)
        val context = context(nowEpochMillis = SwiftDateSeconds.toUnixEpochMillis(50.0))
        store.claimSession(context.sessionOwner)

        consumer.consume(
            payload = payload(
                serviceType = "_skybridge-remote._tcp",
                instanceName = "Desk Mac._skybridge-remote._tcp.local"
            ),
            context = context
        )

        val binding = store.sessions.value.single().authenticatedRouteBindings.single()
        assertEquals("_skybridge-rd._tcp", binding.serviceType)
        assertEquals("Desk Mac._skybridge-rd._tcp.local", binding.instanceName)
    }

    @Test
    fun serviceAndInstanceMismatchIsRejectedWithoutStoreWrite() {
        val store = InMemoryProductSessionAuthorityStore()
        val consumer = AuthenticatedRouteBindingConsumer(store)

        val error = runCatching {
            consumer.consume(
                payload = payload(instanceName = "Desk Mac._skybridge-xfer._tcp.local"),
                context = context(nowEpochMillis = SwiftDateSeconds.toUnixEpochMillis(50.0))
            )
        }.exceptionOrNull()

        assertEquals("route-binding instanceName does not match serviceType", error?.message)
        assertTrue(store.sessions.value.isEmpty())
    }

    @Test
    fun receiverDeviceMismatchIsRejectedWithoutStoreWrite() {
        val store = InMemoryProductSessionAuthorityStore()
        val consumer = AuthenticatedRouteBindingConsumer(store)

        val error = runCatching {
            consumer.consume(
                payload = payload(remoteDeviceId = "other-android-device"),
                context = context(nowEpochMillis = SwiftDateSeconds.toUnixEpochMillis(50.0))
            )
        }.exceptionOrNull()

        assertEquals("route-binding receiver device mismatch", error?.message)
        assertTrue(store.sessions.value.isEmpty())
    }

    @Test
    fun authorityFingerprintMismatchIsRejectedWithoutStoreWrite() {
        val store = InMemoryProductSessionAuthorityStore()
        val consumer = AuthenticatedRouteBindingConsumer(store)

        val error = runCatching {
            consumer.consume(
                payload = payload(routeAuthorityFingerprint = OTHER_FINGERPRINT),
                context = context(nowEpochMillis = SwiftDateSeconds.toUnixEpochMillis(50.0))
            )
        }.exceptionOrNull()

        assertEquals("route-binding authority fingerprint mismatch", error?.message)
        assertTrue(store.sessions.value.isEmpty())
    }

    @Test
    fun sessionHashMismatchIsRejectedWithoutStoreWrite() {
        val store = InMemoryProductSessionAuthorityStore()
        val consumer = AuthenticatedRouteBindingConsumer(store)

        val error = runCatching {
            consumer.consume(
                payload = payload(sessionHashHex = "9999999999999999"),
                context = context(nowEpochMillis = SwiftDateSeconds.toUnixEpochMillis(50.0))
            )
        }.exceptionOrNull()

        assertEquals("route-binding session hash mismatch", error?.message)
        assertTrue(store.sessions.value.isEmpty())
    }

    @Test
    fun expiredBindingIsRejectedWithoutStoreWrite() {
        val store = InMemoryProductSessionAuthorityStore()
        val consumer = AuthenticatedRouteBindingConsumer(store)

        val error = runCatching {
            consumer.consume(
                payload = payload(expiresAt = 72.0),
                context = context(nowEpochMillis = SwiftDateSeconds.toUnixEpochMillis(72.0))
            )
        }.exceptionOrNull()

        assertEquals("route-binding is expired", error?.message)
        assertTrue(store.sessions.value.isEmpty())
    }

    @Test
    fun staleOwnerIsRejectedWithoutReplacingCurrentAuthority() {
        val store = InMemoryProductSessionAuthorityStore()
        val consumer = AuthenticatedRouteBindingConsumer(store)
        val staleContext = context(
            nowEpochMillis = SwiftDateSeconds.toUnixEpochMillis(50.0),
            generation = 1
        )
        val replacementOwner = ProductSessionOwner.create("session-1", generation = 2)
        store.claimSession(staleContext.sessionOwner)
        store.claimSession(replacementOwner)

        val error = runCatching {
            consumer.consume(payload = payload(), context = staleContext)
        }.exceptionOrNull()

        assertEquals("route-binding session owner is stale", error?.message)
        assertTrue(store.sessions.value.isEmpty())
    }

    private fun payload(
        localDeviceId: String = "mac-device",
        remoteDeviceId: String = "android-device",
        routeAuthorityFingerprint: String = REMOTE_FINGERPRINT,
        receiverFingerprint: String = LOCAL_FINGERPRINT,
        sessionHashHex: String = "1111111111111111",
        transcriptPrefixHex: String = "2222222222222222",
        expiresAt: Double = 72.0,
        serviceType: String = "_skybridge-rd._tcp",
        instanceName: String = "Desk Mac._skybridge-rd._tcp.local"
    ) = AppMessage.AuthenticatedRouteBindingPayload(
        version = 1,
        kind = "remoteDesktop",
        serviceType = serviceType,
        instanceName = instanceName,
        hostName = "desk-mac.local",
        port = 5901,
        endpointProvenance = "resolved-dns-sd-endpoint",
        localDeviceId = localDeviceId,
        remoteDeviceId = remoteDeviceId,
        routeAuthorityProtocolPublicKeyFingerprint = routeAuthorityFingerprint,
        remoteProtocolPublicKeyFingerprint = receiverFingerprint,
        sessionHashHex = sessionHashHex,
        transcriptPrefixHex = transcriptPrefixHex,
        sentAt = 42.0,
        expiresAt = expiresAt,
        nonce = ByteArray(16) { (it + 1).toByte() }
    )

    private fun context(
        nowEpochMillis: Long,
        generation: Long = 1
    ) = AuthenticatedRouteBindingValidationContext(
        sessionOwner = ProductSessionOwner.create("session-1", generation),
        localDeviceId = "android-device",
        localProtocolPublicKeyFingerprint = LOCAL_FINGERPRINT,
        expectedRemoteDeviceId = "mac-device",
        expectedRemotePublicKeyFingerprint = REMOTE_FINGERPRINT,
        sessionHashHex = "1111111111111111",
        transcriptPrefixHex = "2222222222222222",
        nowEpochMillis = nowEpochMillis
    )

    private companion object {
        const val LOCAL_FINGERPRINT =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        const val REMOTE_FINGERPRINT =
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        const val OTHER_FINGERPRINT =
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
}
