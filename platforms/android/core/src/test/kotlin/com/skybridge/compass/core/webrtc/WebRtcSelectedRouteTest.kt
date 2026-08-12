package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.productsession.ProductSessionOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebRtcSelectedRouteTest {
    @Test
    fun recognizedNonRelayPairIsDirect() {
        assertEquals(
            WebRtcSelectedRoute.DIRECT,
            WebRtcSelectedCandidatePairPolicy.classify(
                localCandidateSdp = candidate("host"),
                remoteCandidateSdp = candidate("srflx")
            )
        )
        assertEquals(
            WebRtcSelectedRoute.DIRECT,
            WebRtcSelectedCandidatePairPolicy.classify(
                localCandidateSdp = candidate("prflx"),
                remoteCandidateSdp = candidate("host")
            )
        )
    }

    @Test
    fun relayOnEitherSideIsConclusiveEvenWhenOtherCandidateIsMissing() {
        assertEquals(
            WebRtcSelectedRoute.RELAY,
            WebRtcSelectedCandidatePairPolicy.classify(
                localCandidateSdp = candidate("relay"),
                remoteCandidateSdp = null
            )
        )
        assertEquals(
            WebRtcSelectedRoute.RELAY,
            WebRtcSelectedCandidatePairPolicy.classify(
                localCandidateSdp = candidate("host"),
                remoteCandidateSdp = candidate("relay")
            )
        )
    }

    @Test
    fun missingMalformedOrUnknownCandidateTypeIsUnknown() {
        assertEquals(
            WebRtcSelectedRoute.UNKNOWN,
            WebRtcSelectedCandidatePairPolicy.classify(null, candidate("host"))
        )
        assertEquals(
            WebRtcSelectedRoute.UNKNOWN,
            WebRtcSelectedCandidatePairPolicy.classify("not-a-candidate", candidate("host"))
        )
        assertEquals(
            WebRtcSelectedRoute.UNKNOWN,
            WebRtcSelectedCandidatePairPolicy.classify(candidate("future"), candidate("host"))
        )
    }

    @Test
    fun replacementPublishesUnknownAndRejectsDelayedOldOwnerCommit() {
        val store = OwnerBoundWebRtcRouteStore()
        val firstOwner = ProductSessionOwner.create("session", generation = 1)
        val replacementOwner = ProductSessionOwner.create("session", generation = 2)

        store.bind(firstOwner)
        assertTrue(store.commit(firstOwner, WebRtcSelectedRoute.DIRECT))
        assertEquals(WebRtcSelectedRoute.DIRECT, store.current(firstOwner))

        store.bind(replacementOwner)
        assertEquals(WebRtcSelectedRoute.UNKNOWN, store.current(replacementOwner))
        assertNull(store.current(firstOwner))
        assertFalse(store.commit(firstOwner, WebRtcSelectedRoute.RELAY))
        assertEquals(WebRtcSelectedRoute.UNKNOWN, store.current(replacementOwner))

        assertTrue(store.commit(replacementOwner, WebRtcSelectedRoute.RELAY))
        assertEquals(WebRtcSelectedRoute.RELAY, store.current(replacementOwner))
    }

    @Test
    fun staleClearCannotEraseReplacementWitness() {
        val store = OwnerBoundWebRtcRouteStore()
        val firstOwner = ProductSessionOwner.create("session", generation = 1)
        val replacementOwner = ProductSessionOwner.create("session", generation = 2)

        store.bind(firstOwner)
        store.bind(replacementOwner)

        assertFalse(store.clearIfOwned(firstOwner))
        assertEquals(WebRtcSelectedRoute.UNKNOWN, store.current(replacementOwner))
        assertTrue(store.clearIfOwned(replacementOwner))
        assertNull(store.witness.value)
    }

    @Test
    fun directOnlyAdmissionRequiresExactOwnerAndDirectWitness() {
        val owner = ProductSessionOwner.create("session", generation = 1)
        val otherOwner = ProductSessionOwner.create("session", generation = 1)

        assertTrue(
            WebRtcDirectRouteAdmissionPolicy.allows(
                owner,
                WebRtcSelectedRouteWitness(owner, WebRtcSelectedRoute.DIRECT)
            )
        )
        assertFalse(
            WebRtcDirectRouteAdmissionPolicy.allows(
                owner,
                WebRtcSelectedRouteWitness(owner, WebRtcSelectedRoute.RELAY)
            )
        )
        assertFalse(
            WebRtcDirectRouteAdmissionPolicy.allows(
                owner,
                WebRtcSelectedRouteWitness(owner, WebRtcSelectedRoute.UNKNOWN)
            )
        )
        assertFalse(
            WebRtcDirectRouteAdmissionPolicy.allows(
                owner,
                WebRtcSelectedRouteWitness(otherOwner, WebRtcSelectedRoute.DIRECT)
            )
        )
        assertFalse(WebRtcDirectRouteAdmissionPolicy.allows(owner, null))
    }

    private fun candidate(type: String): String =
        "candidate:1 1 udp 2122260223 192.0.2.1 5000 typ $type generation 0"
}
