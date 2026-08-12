package com.skybridge.compass.shared.p2p

import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ProtocolIdentityFingerprintTest {
    @Test
    fun ed25519FingerprintMatchesAppleCanonicalization() {
        val publicKey = ByteArray(32) { 0x11 }
        val identity = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = publicKey,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519
        )

        val fingerprint = ProtocolIdentityFingerprint.compute(identity)

        assertEquals(
            "6d2b9f7fa7f28ec0553190b584e04b31b946d0767464c9028284bdb721e4d884",
            fingerprint
        )
        assertEquals(fingerprint, P2PHandshakeWire.computePeerSigningFingerprint(identity))
        assertNotEquals(sha256Hex(identity.encode()), fingerprint)
    }

    @Test
    fun rejectsLegacyP256IdentityAsPinnableProtocolIdentity() {
        val identity = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = ByteArray(65) { 0x22 },
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.P256_ECDSA_LEGACY
        )

        assertThrows(IllegalArgumentException::class.java) {
            ProtocolIdentityFingerprint.compute(identity)
        }
    }

    @Test
    fun rejectsInvalidEd25519Length() {
        assertThrows(IllegalArgumentException::class.java) {
            ProtocolIdentityFingerprint.compute(
                algorithmTag = ProtocolIdentityFingerprint.ED25519_TAG,
                publicKeyBytes = ByteArray(31)
            )
        }
    }

    private fun sha256Hex(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(data)
            .joinToString(separator = "") { "%02x".format(it) }
}
