package com.skybridge.compass.core.webrtc

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class TURNCredentialServiceTest {

    @Test
    fun getCredentials_rejectsMissingAdmissionToken() {
        assertThrows(IllegalArgumentException::class.java) {
            runBlocking {
                TURNCredentialService().getCredentials(turnAdmissionToken = null, deviceId = "android-test")
            }
        }
    }

    @Test
    fun decodeServerCredentials_acceptsCompleteLeaseAndPrioritizesTurnsTcp() {
        val nowMillis = 1_700_000_000_000L
        val credentials = TURNCredentialService.decodeServerCredentials(
            payload = """
                {
                  "username": "skybridge-user",
                  "password": "skybridge-pass",
                  "ttl": 600,
                  "uris": [
                    "turn:relay.example.com:3478?transport=udp",
                    "turns:relay.example.com:5349?transport=tcp",
                    "turn:relay.example.com:3478?transport=tcp",
                    "stun:relay.example.com:3478"
                  ],
                  "expiresAt": 1700000600
                }
            """.trimIndent(),
            nowMillis = nowMillis
        )

        assertEquals("skybridge-user", credentials.username)
        assertEquals("skybridge-pass", credentials.password)
        assertEquals(600, credentials.ttl)
        assertEquals(1_700_000_600_000L, credentials.expiresAtMillis)
        assertEquals(
            listOf(
                "turns:relay.example.com:5349?transport=tcp",
                "turn:relay.example.com:3478?transport=tcp",
                "turn:relay.example.com:3478?transport=udp"
            ),
            credentials.uris
        )
    }

    @Test
    fun decodeServerCredentials_acceptsCompatCredentialAlias() {
        val credentials = TURNCredentialService.decodeServerCredentials(
            payload = """
                {
                  "mode": "compat",
                  "username": "local",
                  "credential": "local-pass",
                  "ttl": 60,
                  "uris": ["turn:127.0.0.1:3478?transport=udp"]
                }
            """.trimIndent(),
            nowMillis = 1_700_000_000_000L
        )

        assertEquals("local", credentials.username)
        assertEquals("local-pass", credentials.password)
        assertEquals(60, credentials.ttl)
        assertEquals(listOf("turn:127.0.0.1:3478?transport=udp"), credentials.uris)
    }

    @Test
    fun decodeServerCredentials_rejectsConflictingPasswordAndCredentialAlias() {
        assertThrows(IllegalArgumentException::class.java) {
            TURNCredentialService.decodeServerCredentials(
                payload = """
                    {
                      "username": "skybridge-user",
                      "password": "skybridge-pass",
                      "credential": "other-pass",
                      "ttl": 600,
                      "uris": ["turn:relay.example.com:3478"]
                    }
                """.trimIndent(),
                nowMillis = 1_700_000_000_000L
            )
        }
    }

    @Test
    fun decodeServerCredentials_rejectsMissingCredentialFields() {
        assertThrows(IllegalArgumentException::class.java) {
            TURNCredentialService.decodeServerCredentials(
                payload = """{"username":"","password":"skybridge-pass","ttl":600,"uris":["turn:relay.example.com:3478"]}""",
                nowMillis = 1_700_000_000_000L
            )
        }

        assertThrows(IllegalArgumentException::class.java) {
            TURNCredentialService.decodeServerCredentials(
                payload = """{"username":"skybridge-user","password":" skybridge-pass ","ttl":600,"uris":["turn:relay.example.com:3478"]}""",
                nowMillis = 1_700_000_000_000L
            )
        }
    }

    @Test
    fun decodeServerCredentials_rejectsInvalidLeaseTimes() {
        assertThrows(IllegalArgumentException::class.java) {
            TURNCredentialService.decodeServerCredentials(
                payload = """{"username":"skybridge-user","password":"skybridge-pass","ttl":0,"uris":["turn:relay.example.com:3478"]}""",
                nowMillis = 1_700_000_000_000L
            )
        }

        assertThrows(IllegalArgumentException::class.java) {
            TURNCredentialService.decodeServerCredentials(
                payload = """{"username":"skybridge-user","password":"skybridge-pass","ttl":600,"uris":["turn:relay.example.com:3478"],"expiresAt":1699999999}""",
                nowMillis = 1_700_000_000_000L
            )
        }
    }

    @Test
    fun decodeServerCredentials_rejectsMissingTurnUris() {
        assertThrows(IllegalArgumentException::class.java) {
            TURNCredentialService.decodeServerCredentials(
                payload = """{"username":"skybridge-user","password":"skybridge-pass","ttl":600}""",
                nowMillis = 1_700_000_000_000L
            )
        }
    }

    @Test
    fun turnCredentialEndpoint_defaultsToConfiguredProductionEndpoint() {
        assertEquals(
            SkyBridgeServerConfig.turnCredentialEndpoint(),
            TURNCredentialService.turnCredentialEndpoint(signalingServerOrigin = null)
        )

        assertEquals(
            SkyBridgeServerConfig.turnCredentialEndpoint(),
            TURNCredentialService.turnCredentialEndpoint(signalingServerOrigin = " ")
        )
    }

    @Test
    fun turnCredentialEndpoint_usesCanonicalCurrentPathOrigin() {
        assertEquals(
            "http://127.0.0.1:18443/api/turn/credentials",
            TURNCredentialService.turnCredentialEndpoint(" http://127.0.0.1:18443 ")
        )
        assertEquals(
            "http://10.0.2.2:18443/api/turn/credentials",
            TURNCredentialService.turnCredentialEndpoint(" http://10.0.2.2:18443 ")
        )

        assertEquals(
            "https://api.example.com/api/turn/credentials",
            TURNCredentialService.turnCredentialEndpoint("https://API.EXAMPLE.COM:443/")
        )
    }

    @Test
    fun turnCredentialEndpoint_rejectsInvalidCurrentPathOrigin() {
        assertThrows(IllegalArgumentException::class.java) {
            TURNCredentialService.turnCredentialEndpoint("https://api.example.com/custom")
        }

        assertThrows(IllegalArgumentException::class.java) {
            TURNCredentialService.turnCredentialEndpoint("ws://127.0.0.1:18443/ws")
        }
    }
}
