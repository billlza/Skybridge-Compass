package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.shared.p2p.P2PSoa
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.security.MessageDigest

class MacRemoteControlSoaIdentityTest {

    @Test
    fun messageAExtensionsUseAppleRemoteControlStableIds() {
        val localDeviceId = "AABBCCDD-1111-2222-3333-444455556666"
        val remoteDeviceId = "FFEEDDCC-AAAA-BBBB-CCCC-111122223333"
        val attemptId = ByteArray(P2PSoa.ATTEMPT_ID_LEN) { it.toByte() }

        val raw = MacRemoteControlSoaIdentity.messageAExtensions(
            localDeviceId = localDeviceId,
            remoteDeviceId = remoteDeviceId,
            attemptId = attemptId
        )

        val soa = requireNotNull(P2PSoa.decodeFromExtensions(requireNotNull(raw)))
        assertArrayEquals(stablePeerHash(localDeviceId), soa.initiatorPeerId)
        assertArrayEquals(stablePeerHash(remoteDeviceId), soa.targetPeerId)
        assertArrayEquals(attemptId, soa.attemptId)
    }

    @Test
    fun stableIdentifierPreservesExistingIdPrefixAndLowercases() {
        assertEquals(
            "id:mac-device-1",
            MacRemoteControlSoaIdentity.stableIdentifier(" ID:Mac-Device-1 ")
        )
    }

    @Test
    fun stableIdentifierRejectsEndpointAliases() {
        assertNull(MacRemoteControlSoaIdentity.stableIdentifier(""))
        assertNull(MacRemoteControlSoaIdentity.stableIdentifier("host:10.0.2.2"))
        assertNull(MacRemoteControlSoaIdentity.stableIdentifier("peer:10.0.2.2"))
        assertNull(MacRemoteControlSoaIdentity.stableIdentifier("bonjour:skybridge"))
        assertNull(MacRemoteControlSoaIdentity.stableIdentifier("recent:mac"))
        assertNull(MacRemoteControlSoaIdentity.stableIdentifier("mac@example.local"))
    }

    private fun stablePeerHash(value: String): ByteArray =
        MessageDigest.getInstance("SHA-256")
            .digest(value.trim().lowercase().toByteArray(Charsets.UTF_8))
}
