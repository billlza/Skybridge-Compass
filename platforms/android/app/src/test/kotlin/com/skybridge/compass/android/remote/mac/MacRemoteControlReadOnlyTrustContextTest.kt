package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class MacRemoteControlReadOnlyTrustContextTest {
    @Test
    fun fallbackState_readsExistingStateButRejectsEveryMutation() {
        val persistent = P2PHandshakeWire.InMemoryFallbackCooldownStore().apply {
            saveLastClassicFallbackAtMillis("existing-peer", 1234L)
        }
        val readOnly = ReadOnlyFallbackCooldownStore(persistent)

        assertEquals(
            1234L,
            readOnly.loadLastClassicFallbackAtMillis("existing-peer")
        )
        assertNull(readOnly.loadLastClassicFallbackAtMillis("new-peer"))

        try {
            readOnly.saveLastClassicFallbackAtMillis("new-peer", 5678L)
            fail("read-only fallback context accepted a persistence mutation")
        } catch (expected: IllegalStateException) {
            assertEquals(
                "read-only LAN acceptance probe cannot persist fallback migration state",
                expected.message
            )
        }
        assertNull(persistent.loadLastClassicFallbackAtMillis("new-peer"))
    }
}
