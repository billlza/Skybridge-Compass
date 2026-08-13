package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExistingTrustPeerKemAdmissionStateTest {
    @Test
    fun admissionIsBoundToOneOpaqueKeyEpochAndClearIsFailClosed() {
        val state = ExistingTrustPeerKemAdmissionState()
        val firstEpoch = FakeSecureOperationOwner()
        val replacementEpoch = FakeSecureOperationOwner()

        assertFalse(state.isCurrent(firstEpoch))
        state.beginSend(firstEpoch)
        assertTrue(state.finishSend(firstEpoch, transportDelivered = true))
        state.install(firstEpoch)
        assertTrue(state.wasSentBy(firstEpoch))
        assertTrue(state.isSendConfirmed(firstEpoch))
        assertTrue(state.isCurrent(firstEpoch))
        assertFalse(state.isCurrent(replacementEpoch))

        state.clear()
        assertFalse(state.isCurrent(firstEpoch))
        assertFalse(state.isCurrent(replacementEpoch))
    }

    @Test
    fun replacementEpochInvalidatesThePriorEpochCapability() {
        val state = ExistingTrustPeerKemAdmissionState()
        val firstEpoch = FakeSecureOperationOwner()
        val replacementEpoch = FakeSecureOperationOwner()

        state.beginSend(firstEpoch)
        assertTrue(state.finishSend(firstEpoch, transportDelivered = true))
        state.install(firstEpoch)
        state.beginSend(replacementEpoch)
        assertTrue(state.finishSend(replacementEpoch, transportDelivered = true))
        state.install(replacementEpoch)

        assertFalse(state.isCurrent(firstEpoch))
        assertTrue(state.isCurrent(replacementEpoch))
    }

    @Test
    fun admissionWithoutAnExactEpochRequestIsRejected() {
        val state = ExistingTrustPeerKemAdmissionState()
        val unsolicitedOwner = FakeSecureOperationOwner()

        org.junit.Assert.assertThrows(IllegalStateException::class.java) {
            state.install(unsolicitedOwner)
        }
        assertFalse(state.isCurrent(unsolicitedOwner))
    }

    @Test
    fun reentrantResponseWinsOverFalseTransportReturn() {
        val state = ExistingTrustPeerKemAdmissionState()
        val owner = FakeSecureOperationOwner()

        state.beginSend(owner)
        state.install(owner)

        assertTrue(state.finishSend(owner, transportDelivered = false))
        assertTrue(state.isSendConfirmed(owner))
        assertTrue(state.isCurrent(owner))
    }

    @Test
    fun failedSendWithoutResponseRollsBackThePendingEpoch() {
        val state = ExistingTrustPeerKemAdmissionState()
        val owner = FakeSecureOperationOwner()

        state.beginSend(owner)

        assertFalse(state.finishSend(owner, transportDelivered = false))
        assertFalse(state.wasSentBy(owner))
        assertFalse(state.isCurrent(owner))
    }

    private class FakeSecureOperationOwner : WebRtcSecureOperationOwner
}
