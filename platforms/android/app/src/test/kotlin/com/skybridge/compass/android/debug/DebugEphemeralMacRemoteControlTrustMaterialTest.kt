package com.skybridge.compass.android.debug

import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PXWingKem
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DebugEphemeralMacRemoteControlTrustMaterialTest {
    @Test
    fun diagnosticKemSeed_isVisibleOnlyToOwningActivityContext() {
        val seededMaterial = DebugEphemeralMacRemoteControlTrustMaterial()
        val originalMlKem = ByteArray(AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE) {
            (it % 251).toByte()
        }
        val expectedMlKem = originalMlKem.copyOf()

        seededMaterial.seedPeerKemKeys(
            peerId = "MAC-DEVICE",
            mlKem768PublicKey = originalMlKem,
            xWingPublicKey = null
        )
        originalMlKem.fill(0)

        val firstRead = seededMaterial.clientTrustContext.peerKemPublicKeys.load("MAC-DEVICE")
        assertArrayEquals(expectedMlKem, checkNotNull(firstRead.mlKem768PublicKey))
        firstRead.mlKem768PublicKey?.fill(1)
        val secondRead = seededMaterial.clientTrustContext.peerKemPublicKeys.load("MAC-DEVICE")
        assertArrayEquals(expectedMlKem, checkNotNull(secondRead.mlKem768PublicKey))
        assertNull(
            seededMaterial.clientTrustContext.peerKemPublicKeys.load("mac-device").mlKem768PublicKey
        )

        val newClientMaterial = DebugEphemeralMacRemoteControlTrustMaterial()
        val unseededRead = newClientMaterial.clientTrustContext.peerKemPublicKeys.load("MAC-DEVICE")
        assertNull(unseededRead.mlKem768PublicKey)
        assertNull(unseededRead.xWingPublicKey)
        assertNull(unseededRead.qPeriaptPublicKey)
    }

    @Test
    fun diagnosticFingerprintAndFallbackState_doNotCrossClientContexts() {
        val first = DebugEphemeralMacRemoteControlTrustMaterial()
        first.clientTrustContext.peerSigningFingerprints.savePeerSigningFingerprint(
            peerId = "MAC-DEVICE",
            peerSigningFingerprint = "AABBCC"
        )
        first.clientTrustContext.fallbackCooldowns.saveLastClassicFallbackAtMillis(
            peerId = "MAC-DEVICE",
            unixTimeMillis = 1234L
        )

        assertEquals(
            "aabbcc",
            first.clientTrustContext.peerSigningFingerprints.loadPeerSigningFingerprint("MAC-DEVICE")
        )
        assertEquals(
            1234L,
            first.clientTrustContext.fallbackCooldowns.loadLastClassicFallbackAtMillis("MAC-DEVICE")
        )

        val replacement = DebugEphemeralMacRemoteControlTrustMaterial()
        assertNull(
            replacement.clientTrustContext.peerSigningFingerprints
                .loadPeerSigningFingerprint("mac-device")
        )
        assertNull(
            replacement.clientTrustContext.fallbackCooldowns
                .loadLastClassicFallbackAtMillis("mac-device")
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun invalidDiagnosticKemLength_isRejectedBeforeHandshake() {
        DebugEphemeralMacRemoteControlTrustMaterial().seedPeerKemKeys(
            peerId = "mac-device",
            mlKem768PublicKey = null,
            xWingPublicKey = ByteArray(P2PXWingKem.XWING_PUBLIC_KEY_SIZE - 1)
        )
    }
}
