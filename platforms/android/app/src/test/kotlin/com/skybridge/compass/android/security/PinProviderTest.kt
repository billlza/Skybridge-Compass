package com.skybridge.compass.android.security

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Base64

class PinProviderTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun acceptsValidSha256Pins() {
        val pin = "sha256/" + Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() })
        val payload = """{"hosts":[{"host":"api.example.test","pins":["$pin"]}]}"""

        val parsed = parseAndValidateRemotePinPayload(json, payload)

        assertEquals("api.example.test", parsed.hosts.single().host)
        assertEquals(listOf(pin), validatedCertificatePins(parsed.hosts.single()))
    }

    @Test
    fun rejectsMalformedStoredPinRegistryInsteadOfDisablingPinning() {
        assertThrows(IllegalArgumentException::class.java) {
            parseAndValidateRemotePinPayload(json, """{"hosts":[{"host":"api.example.test","pins":["sha256/not-base64"]}]}""")
        }
    }

    @Test
    fun rejectsHostEntriesWithoutUsablePins() {
        assertThrows(IllegalArgumentException::class.java) {
            parseAndValidateRemotePinPayload(json, """{"hosts":[{"host":"api.example.test","pins":[]}]}""")
        }
    }

    @Test
    fun rejectsBlankHosts() {
        val pin = "sha256/" + Base64.getEncoder().encodeToString(ByteArray(32) { 7 })
        assertThrows(IllegalArgumentException::class.java) {
            parseAndValidateRemotePinPayload(json, """{"hosts":[{"host":" ","pins":["$pin"]}]}""")
        }
    }
}
