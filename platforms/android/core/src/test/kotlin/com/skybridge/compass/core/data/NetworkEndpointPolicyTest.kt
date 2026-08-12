package com.skybridge.compass.core.data

import com.skybridge.compass.core.webrtc.SkyBridgeServerConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class NetworkEndpointPolicyTest {

    @Test
    fun normalizeWebRtcSignalingUrl_acceptsSecureDefaultAndLoopbackPlaintextOnly() {
        assertEquals(
            SkyBridgeServerConfig.signalingWebSocketURL,
            NetworkEndpointPolicy.normalizeWebRtcSignalingUrl("  ${SkyBridgeServerConfig.signalingWebSocketURL}  ")
        )
        assertEquals(
            "ws://127.0.0.1:8080/ws",
            NetworkEndpointPolicy.normalizeWebRtcSignalingUrl("ws://127.0.0.1:8080/ws")
        )
        assertEquals(
            "ws://10.0.2.2:18443/ws",
            NetworkEndpointPolicy.normalizeWebRtcSignalingUrl("ws://10.0.2.2:18443/ws")
        )
    }

    @Test
    fun normalizeWebRtcSignalingUrl_rejectsRemotePlaintextAndSpoofedLoopback() {
        assertThrows(IllegalArgumentException::class.java) {
            NetworkEndpointPolicy.normalizeWebRtcSignalingUrl("ws://api.nebula-technologies.net/ws")
        }
        assertThrows(IllegalArgumentException::class.java) {
            NetworkEndpointPolicy.normalizeWebRtcSignalingUrl("ws://127.0.0.1.evil.com/ws")
        }
        assertThrows(IllegalArgumentException::class.java) {
            NetworkEndpointPolicy.normalizeWebRtcSignalingUrl("wss://user:pass@example.com/ws")
        }
        assertThrows(IllegalArgumentException::class.java) {
            NetworkEndpointPolicy.normalizeWebRtcSignalingUrl("wss://api.nebula-technologies.net/ws#fragment")
        }
    }

    @Test
    fun normalizeIceServers_enforcesStunAndTurnSchemes() {
        assertEquals(
            listOf("stun:relay.example.com:3478"),
            NetworkEndpointPolicy.normalizeStunServers(listOf(" stun:relay.example.com:3478 "))
        )
        assertEquals(
            listOf("turns:relay.example.com:5349?transport=tcp", "turn:relay.example.com:3478?transport=udp"),
            NetworkEndpointPolicy.normalizeTurnServers(
                listOf(
                    "turns:relay.example.com:5349?transport=tcp",
                    "turn:relay.example.com:3478?transport=udp"
                )
            )
        )

        assertThrows(IllegalArgumentException::class.java) {
            NetworkEndpointPolicy.normalizeStunServers(listOf("turn:relay.example.com:3478"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            NetworkEndpointPolicy.normalizeTurnServers(listOf("stun:relay.example.com:3478"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            NetworkEndpointPolicy.normalizeTurnServers(listOf("turn://user:pass@relay.example.com:3478"))
        }
    }

    @Test
    fun resolveTurnUrlsForCredentials_usesServerIssuedUrisUntilLocalOverrideIsExplicit() {
        val serverIssued = listOf("turns:server-issued.example.com:5349?transport=tcp")

        assertEquals(
            serverIssued,
            NetworkEndpointPolicy.resolveTurnUrlsForCredentials(
                configuredTurnServers = SkyBridgeServerConfig.defaultTurnServers,
                credentialTurnUris = serverIssued
            )
        )

        assertEquals(
            listOf("turn:lab-relay.example.com:3478?transport=udp"),
            NetworkEndpointPolicy.resolveTurnUrlsForCredentials(
                configuredTurnServers = listOf("turn:lab-relay.example.com:3478?transport=udp"),
                credentialTurnUris = serverIssued
            )
        )
    }
}
