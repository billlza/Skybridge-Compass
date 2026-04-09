package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.p2p.P2PIdentityPublicKeys
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CurrentPathSecurityTest {

    @Test
    fun fingerprint_matchesAppleCanonicalizationForEd25519() {
        val fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm = ProtocolSigningAlgorithm.ED25519,
            publicKeyBytes = ByteArray(32) { 0x11 }
        )

        assertEquals(
            "6d2b9f7fa7f28ec0553190b584e04b31b946d0767464c9028284bdb721e4d884",
            fingerprint
        )
    }

    @Test
    fun canonicalOrigin_normalizesSchemeHostAndDefaultPort() {
        assertEquals(
            "https://api.example.com",
            CurrentPathOriginPolicy.canonicalOrigin("https://API.EXAMPLE.com:443/")
        )
        assertEquals(
            "http://api.example.com:8443",
            CurrentPathOriginPolicy.canonicalOrigin("http://Api.Example.com:8443")
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun canonicalOrigin_rejectsUnexpectedPath() {
        CurrentPathOriginPolicy.canonicalOrigin("https://api.example.com/ws")
    }

    @Test
    fun protocolSigningAlgorithm_mapsHandshakeAlgorithms() {
        assertEquals(
            ProtocolSigningAlgorithm.ED25519,
            ProtocolSigningAlgorithm.fromIdentityAlgorithm(P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519)
        )
        assertEquals(
            ProtocolSigningAlgorithm.ML_DSA_65,
            ProtocolSigningAlgorithm.fromIdentityAlgorithm(P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65)
        )
        assertNull(
            ProtocolSigningAlgorithm.fromIdentityAlgorithm(P2PIdentityPublicKeys.ProtocolAlgorithm.P256_ECDSA_LEGACY)
        )
    }
}
