package com.skybridge.compass.android.remote.mac

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MacRemotePeerIdentityHintTest {

    @Test
    fun identityHint_prefersDeviceIdAndNormalizesFingerprint() {
        val service = MacRemoteDiscovery.Service(
            name = "Mac",
            host = "192.168.1.10",
            port = 5901,
            txt = mapOf(
                "deviceId" to "mac-device-1",
                "pubKeyFP" to "AA11BB22AA11BB22AA11BB22AA11BB22AA11BB22AA11BB22AA11BB22AA11BB22"
            )
        )

        val hint = service.identityHint()

        assertEquals("mac-device-1", hint.deviceId)
        assertEquals("aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22", hint.advertisedFingerprint)
        assertTrue(hint.hasAdvertisedIdentityFields)
    }

    @Test
    fun identityHint_fallsBackToUuidAlias() {
        val service = MacRemoteDiscovery.Service(
            name = "Mac",
            host = "192.168.1.10",
            port = 5901,
            txt = mapOf(
                "uuid" to "uuid-peer",
                "uniqueId" to "ignored"
            )
        )

        val hint = service.identityHint()

        assertEquals("uuid-peer", hint.deviceId)
        assertNull(hint.advertisedFingerprint)
        assertFalse(hint.hasAdvertisedIdentityFields)
    }

    @Test
    fun identityHint_rejectsInvalidFingerprint() {
        val service = MacRemoteDiscovery.Service(
            name = "Mac",
            host = "192.168.1.10",
            port = 5901,
            txt = mapOf(
                "deviceId" to "mac-device-1",
                "pubKeyFP" to "AA11BB22"
            )
        )

        val hint = service.identityHint()

        assertEquals("mac-device-1", hint.deviceId)
        assertNull(hint.advertisedFingerprint)
        assertFalse(hint.hasAdvertisedIdentityFields)
    }
}
