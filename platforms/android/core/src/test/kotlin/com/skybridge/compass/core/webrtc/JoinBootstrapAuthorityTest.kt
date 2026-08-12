package com.skybridge.compass.core.webrtc

import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class JoinBootstrapAuthorityTest {
    @Test
    fun parsesCompleteJoinAuthority() {
        val publicKey = ByteArray(32) { 0x11 }
        val fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm = ProtocolSigningAlgorithm.ED25519,
            publicKeyBytes = publicKey
        )

        val authority = JoinBootstrapAuthority.fromJoinEnvelope(
            WebRtcSignalingEnvelope(
                sessionId = "ABCDEFGH",
                from = "12345678-1234-1234-1234-1234567890ab",
                type = WebRtcSignalingEnvelope.MessageType.JOIN,
                payload = WebRtcSignalingEnvelope.Payload(
                    protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
                    protocolPublicKeyFingerprint = fingerprint,
                    protocolPublicKeyBytes = Base64.getEncoder().encodeToString(publicKey)
                ),
                sentAt = 1.0
            )
        )

        requireNotNull(authority)
        assertEquals("12345678-1234-1234-1234-1234567890ab", authority.deviceId)
        assertEquals(ProtocolSigningAlgorithm.ED25519, authority.protocolSigningAlgorithm)
        assertArrayEquals(publicKey, authority.protocolPublicKeyBytes)
        assertEquals(fingerprint, authority.protocolPublicKeyFingerprint)
    }

    @Test
    fun returnsNullWhenJoinCarriesNoAuthority() {
        val authority = JoinBootstrapAuthority.fromPayload(
            deviceId = "12345678-1234-1234-1234-1234567890ab",
            payload = WebRtcSignalingEnvelope.Payload()
        )

        assertNull(authority)
    }

    @Test
    fun rejectsPartialJoinAuthority() {
        assertThrows(IllegalArgumentException::class.java) {
            JoinBootstrapAuthority.fromPayload(
                deviceId = "12345678-1234-1234-1234-1234567890ab",
                payload = WebRtcSignalingEnvelope.Payload(
                    protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
                    protocolPublicKeyFingerprint = "aa".repeat(32)
                )
            )
        }
    }

    @Test
    fun rejectsJoinAuthorityFingerprintMismatch() {
        val publicKey = ByteArray(32) { 0x11 }
        val mismatchedFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm = ProtocolSigningAlgorithm.ED25519,
            publicKeyBytes = ByteArray(32) { 0x22 }
        )

        assertThrows(IllegalArgumentException::class.java) {
            JoinBootstrapAuthority.fromPayload(
                deviceId = "12345678-1234-1234-1234-1234567890ab",
                payload = WebRtcSignalingEnvelope.Payload(
                    protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
                    protocolPublicKeyFingerprint = mismatchedFingerprint,
                    protocolPublicKeyBytes = Base64.getEncoder().encodeToString(publicKey)
                )
            )
        }
    }

    @Test
    fun rejectsNonJoinEnvelope() {
        assertThrows(IllegalArgumentException::class.java) {
            JoinBootstrapAuthority.fromJoinEnvelope(
                WebRtcSignalingEnvelope(
                    sessionId = "ABCDEFGH",
                    from = "12345678-1234-1234-1234-1234567890ab",
                    type = WebRtcSignalingEnvelope.MessageType.OFFER,
                    payload = WebRtcSignalingEnvelope.Payload(),
                    sentAt = 1.0
                )
            )
        }
    }
}
