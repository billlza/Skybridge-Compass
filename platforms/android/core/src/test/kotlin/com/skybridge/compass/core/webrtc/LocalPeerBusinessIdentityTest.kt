package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalPeerBusinessIdentityTest {

    @Test
    fun normalizedIdentityRequiresValidNebulaId() {
        assertNull(LocalPeerBusinessIdentity(accountDisplayName = "Bill", nebulaId = null).normalizedOrNull())
        assertNull(
            LocalPeerBusinessIdentity(
                accountDisplayName = "Bill",
                nebulaId = "NEBULA-2026-invalid"
            ).normalizedOrNull()
        )
    }

    @Test
    fun normalizedIdentityTrimsDisplayNameAndNebulaId() {
        val identity = LocalPeerBusinessIdentity(
            accountDisplayName = "  Bill  ",
            nebulaId = "  NEBULA-2026-ABCDEF123456  "
        ).normalizedOrNull()

        assertEquals("Bill", identity?.accountDisplayName)
        assertEquals("NEBULA-2026-ABCDEF123456", identity?.nebulaId)
    }
}
