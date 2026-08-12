package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class WebRtcSecureOperationOwnerTest {
    @Test
    fun sameProductSessionRekeyRejectsOldSecureOwner() {
        val state = WebRtcSecureOperationOwnerState()
        val productOwner = ProductSessionOwner.create("session", generation = 1)
        val firstKeys = keys(seed = 1)
        val firstSecureOwner = state.replace(productOwner, firstKeys)

        assertTrue(state.isCurrent(firstSecureOwner, productOwner, firstKeys))
        assertSame(firstSecureOwner, state.owner.value)

        val rekeyedKeys = keys(seed = 17)
        val rekeyedSecureOwner = state.replace(productOwner, rekeyedKeys)

        assertFalse(state.isCurrent(firstSecureOwner, productOwner, rekeyedKeys))
        assertTrue(state.isCurrent(rekeyedSecureOwner, productOwner, rekeyedKeys))
        assertSame(rekeyedSecureOwner, state.owner.value)
        assertNull(state.current(productOwner, firstKeys))
        assertNotNull(state.current(productOwner, rekeyedKeys))
    }

    @Test
    fun externalMarkerCannotAuthorizeRealManagerState() {
        val state = WebRtcSecureOperationOwnerState()
        val productOwner = ProductSessionOwner.create("session", generation = 1)
        val keys = keys(seed = 3)
        state.replace(productOwner, keys)
        val externalMarker = object : WebRtcSecureOperationOwner {}

        assertFalse(state.isCurrent(externalMarker, productOwner, keys))
    }

    @Test
    fun keyContentMutationInvalidatesSnapshotAndClearRevokesCurrentOwner() {
        val state = WebRtcSecureOperationOwnerState()
        val productOwner = ProductSessionOwner.create("session", generation = 1)
        val keys = keys(seed = 5)
        val secureOwner = state.replace(productOwner, keys)

        keys.transcriptHash[0] = (keys.transcriptHash[0].toInt() xor 0x01).toByte()
        assertFalse(state.isCurrent(secureOwner, productOwner, keys))

        val replacement = state.replace(productOwner, keys)
        assertTrue(state.isCurrent(replacement, productOwner, keys))
        state.clear()
        assertFalse(state.isCurrent(replacement, productOwner, keys))
        assertNull(state.owner.value)
    }

    private fun keys(seed: Int): P2PHandshakeWire.DerivedSessionKeys =
        P2PHandshakeWire.DerivedSessionKeys(
            sendKey = ByteArray(32) { index -> (seed + index).toByte() },
            receiveKey = ByteArray(32) { index -> (seed + 64 + index).toByte() },
            transcriptHash = ByteArray(32) { index -> (seed + 128 + index).toByte() }
        )
}
