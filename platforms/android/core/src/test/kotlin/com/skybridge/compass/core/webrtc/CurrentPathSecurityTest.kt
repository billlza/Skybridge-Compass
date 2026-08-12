package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.p2p.P2PIdentityPublicKeys
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
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
    fun protocolIdentityBindingRejectsMismatchedFingerprint() {
        val actualFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm = ProtocolSigningAlgorithm.ED25519,
            publicKeyBytes = ByteArray(32) { 0x11 }
        )
        val mismatchedFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm = ProtocolSigningAlgorithm.ED25519,
            publicKeyBytes = ByteArray(32) { 0x22 }
        )
        require(actualFingerprint != mismatchedFingerprint)

        assertThrows(IllegalArgumentException::class.java) {
            ProtocolIdentityBinding(
                deviceId = "12345678-1234-1234-1234-1234567890ab",
                protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
                protocolPublicKeyBytes = ByteArray(32) { 0x11 },
                protocolPublicKeyFingerprint = mismatchedFingerprint
            )
        }
    }

    @Test
    fun canonicalOrigin_normalizesSchemeHostAndDefaultPort() {
        assertEquals(
            "https://api.example.com",
            CurrentPathOriginPolicy.canonicalOrigin("https://API.EXAMPLE.com:443/")
        )
        assertEquals(
            "http://localhost:8080",
            CurrentPathOriginPolicy.canonicalOrigin("http://LOCALHOST:8080")
        )
        assertEquals(
            "http://127.0.0.1:8443",
            CurrentPathOriginPolicy.canonicalOrigin("http://127.0.0.1:8443")
        )
        assertEquals(
            "http://10.0.2.2:18443",
            CurrentPathOriginPolicy.canonicalOrigin("http://10.0.2.2:18443")
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun canonicalOrigin_rejectsUnexpectedPath() {
        CurrentPathOriginPolicy.canonicalOrigin("https://api.example.com/ws")
    }

    @Test(expected = IllegalArgumentException::class)
    fun canonicalOrigin_rejectsPublicHttpOrigin() {
        CurrentPathOriginPolicy.canonicalOrigin("http://api.example.com")
    }

    @Test(expected = IllegalArgumentException::class)
    fun canonicalOrigin_rejectsLoopbackPrefixSpoofing() {
        CurrentPathOriginPolicy.canonicalOrigin("http://127.evil.com")
    }

    @Test
    fun signalingEndpointTrustPolicy_allowsUserAuthOnlyForDefaultServiceEndpoint() {
        assertTrue(
            SignalingEndpointTrustPolicy.allowsUserAuthContext(
                SkyBridgeServerConfig.signalingWebSocketURL
            )
        )
        assertTrue(
            SignalingEndpointTrustPolicy.allowsUserAuthContext(
                "https://api.nebula-technologies.net/ws"
            )
        )

        assertFalse(
            SignalingEndpointTrustPolicy.allowsUserAuthContext(
                "wss://signal.example.com/ws"
            )
        )
        assertFalse(
            SignalingEndpointTrustPolicy.allowsUserAuthContext(
                "wss://api.nebula-technologies.net/alternate"
            )
        )
        assertFalse(
            SignalingEndpointTrustPolicy.allowsUserAuthContext(
                "wss://api.nebula-technologies.net/ws?tenant=other"
            )
        )
        assertFalse(
            SignalingEndpointTrustPolicy.allowsUserAuthContext(
                "ws://api.nebula-technologies.net/ws"
            )
        )

        assertTrue(
            SignalingEndpointTrustPolicy.allowsDiagnosticLoopbackAuthContext(
                "ws://127.0.0.1:18443/ws"
            )
        )
        assertTrue(
            SignalingEndpointTrustPolicy.allowsDiagnosticLoopbackAuthContext(
                "http://10.0.2.2:18443/ws"
            )
        )
        assertTrue(
            SignalingEndpointTrustPolicy.allowsDiagnosticLocalNetworkAuthContext(
                "ws://172.20.10.4:18443/ws"
            )
        )
        assertTrue(
            SignalingEndpointTrustPolicy.allowsDiagnosticLocalNetworkAuthContext(
                "http://192.168.1.20:18443/ws"
            )
        )
        assertFalse(
            SignalingEndpointTrustPolicy.allowsDiagnosticLoopbackAuthContext(
                "wss://api.nebula-technologies.net/ws"
            )
        )
        assertFalse(
            SignalingEndpointTrustPolicy.allowsDiagnosticLocalNetworkAuthContext(
                "wss://api.nebula-technologies.net/ws"
            )
        )
        assertFalse(
            SignalingEndpointTrustPolicy.allowsDiagnosticLoopbackAuthContext(
                "ws://192.168.1.20:18443/ws"
            )
        )
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
