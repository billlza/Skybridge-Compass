package com.skybridge.compass.core.p2p

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class SkrBootstrapWireTest {
    @Test
    fun requestEncodeAndSwiftShapedResponseDecodePreserveWireSemantics() {
        val request = SkrBootstrapWire.KemRefreshRequestPayload(
            requesterDeviceId = "id:android-1",
            targetDeviceId = "id:mac-1",
            requesterProtocolIdentityFingerprint = "a".repeat(64),
            targetProtocolIdentityFingerprint = "b".repeat(64),
            requestedSuiteWireIds = listOf(0x0101, 0x0001),
            policyHashHex = SkrCanonical.policyHashHex(),
            bonjourEndpointDigest = "c".repeat(64),
            nonce = ByteArray(24) { it.toByte() },
            sentAt = 721_692_800.125
        )
        val requestEnvelope = Json.parseToJsonElement(
            SkrBootstrapWire.encodeRequest(request).decodeToString()
        ).jsonObject
        val requestPayload = requestEnvelope.getValue("kemRefreshRequest").jsonObject
        assertEquals("AAECAwQFBgcICQoLDA0ODxAREhMUFRYX", requestPayload.getValue("nonce").jsonPrimitive.content)
        assertEquals(721_692_800.125, requestPayload.getValue("sentAt").jsonPrimitive.content.toDouble(), 0.0)
        assertEquals(listOf(257, 1), requestPayload.getValue("requestedSuiteWireIds").jsonArray.map { it.jsonPrimitive.content.toInt() })

        val decoded = SkrBootstrapWire.decodeResponse(validSwiftResponseJson().encodeToByteArray())
        val signed = (decoded as SkrBootstrapWire.Response.Signed).payload
        assertEquals(Long.MAX_VALUE, signed.generation)
        assertEquals(721_692_800.25, signed.sentAt, 0.0)
        assertEquals(listOf(0x0101, 0x0001), signed.kemPublicKeys.map { it.suiteWireId })
        assertArrayEquals(ByteArray(32) { 0x11 }, signed.protocolIdentityPublicKey)
        assertArrayEquals(ByteArray(24) { it.toByte() }, signed.requestNonce)
    }

    @Test
    fun rejectsInvalidUtf8() {
        assertThrows(IllegalArgumentException::class.java) {
            SkrBootstrapWire.decodeResponse(byteArrayOf(0xc3.toByte(), 0x28))
        }
    }

    @Test
    fun rejectsMultipleEnvelopeCases() {
        assertThrows(IllegalArgumentException::class.java) {
            SkrBootstrapWire.decodeResponse(
                """{"signedKEMRefresh":{},"kemRefreshFailure":{}}""".encodeToByteArray()
            )
        }
    }

    @Test
    fun rejectsDuplicateObjectKeysIncludingEscapedEquivalent() {
        assertThrows(IllegalArgumentException::class.java) {
            SkrBootstrapWire.decodeResponse(
                """{"kemRefreshFailure":{},"kemRefresh\u0046ailure":{}}""".encodeToByteArray()
            )
        }
    }

    @Test
    fun duplicateScannerRejectsNestedAndEscapedSlashEquivalentKeys() {
        listOf(
            """{"outer":{"key":1,"\u006bey":2}}""",
            """{"a/b":1,"a\/b":2}"""
        ).forEach { json ->
            assertThrows(IllegalArgumentException::class.java) {
                StrictJsonWire.validatedUtf8(json.encodeToByteArray())
            }
        }
    }

    @Test
    fun duplicateScannerAcceptsLegalEscapesAndSurrogatePairAndRejectsTrailingContent() {
        StrictJsonWire.validatedUtf8(
            """{"quote\"key":"\uD83D\uDE03","slash":"a\/b"}""".encodeToByteArray()
        )
        val failure = assertThrows(IllegalArgumentException::class.java) {
            StrictJsonWire.validatedUtf8("{} false".encodeToByteArray())
        }
        assertTrue(failure.message.orEmpty().contains("trailing"))
    }

    @Test
    fun duplicateScannerEnforcesExplicitContainerDepthLimit() {
        StrictJsonWire.validatedUtf8(
            ("[".repeat(64) + "0" + "]".repeat(64)).encodeToByteArray()
        )
        val failure = assertThrows(IllegalArgumentException::class.java) {
            StrictJsonWire.validatedUtf8(
                ("[".repeat(65) + "0" + "]".repeat(65)).encodeToByteArray()
            )
        }
        assertTrue(failure.message.orEmpty().contains("nesting depth"))
    }

    @Test
    fun rejectsInvalidBase64() {
        val json = """
            {"signedKEMRefresh":{
              "version":1,
              "deviceId":"mac-1",
              "aliases":[],
              "protocolSigningAlgorithm":"Ed25519",
              "protocolIdentityPublicKey":"not base64!",
              "protocolIdentityFingerprint":"${"a".repeat(64)}",
              "kemPublicKeys":[],
              "keyId":"key-1",
              "generation":1,
              "sentAt":1.0,
              "expiresAt":2.0,
              "requestNonce":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYX",
              "requestHashHex":"${"b".repeat(64)}",
              "policyRequirePQC":true,
              "policyAllowClassicFallback":false,
              "routeScope":"lan",
              "signature":"AA=="
            }}
        """.trimIndent()
        assertThrows(IllegalArgumentException::class.java) {
            SkrBootstrapWire.decodeResponse(json.encodeToByteArray())
        }
    }

    @Test
    fun rejectsGenerationAboveSignedLongWithoutWrapping() {
        val overflow = validSwiftResponseJson().replace(
            "\"generation\":${Long.MAX_VALUE}",
            "\"generation\":9223372036854775808"
        )
        assertThrows(SkrBootstrapWire.DecodeException::class.java) {
            SkrBootstrapWire.decodeResponse(overflow.encodeToByteArray())
        }
    }

    private fun validSwiftResponseJson(): String = """
        {"signedKEMRefresh":{
          "version":1,
          "deviceId":"id:mac-1",
          "aliases":["id:mac-1","bonjour:mac@local."],
          "protocolSigningAlgorithm":"Ed25519",
          "protocolIdentityPublicKey":"ERERERERERERERERERERERERERERERERERERERERERE=",
          "protocolIdentityFingerprint":"6d2b9f7fa7f28ec0553190b584e04b31b946d0767464c9028284bdb721e4d884",
          "kemPublicKeys":[
            {"suiteWireId":257,"publicKey":"${java.util.Base64.getEncoder().encodeToString(ByteArray(1_184) { 0x66 })}"},
            {"suiteWireId":1,"publicKey":"${java.util.Base64.getEncoder().encodeToString(ByteArray(1_216) { 0x55 })}"}
          ],
          "keyId":"skr-key-1",
          "generation":${Long.MAX_VALUE},
          "sentAt":721692800.25,
          "expiresAt":721693100.25,
          "requestNonce":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYX",
          "requestHashHex":"ef160c364bf085b77e1d14799283550343cf8844767951d819a87d04f8660428",
          "policyRequirePQC":true,
          "policyAllowClassicFallback":false,
          "routeScope":"lan",
          "bonjourEndpointDigest":"${"c".repeat(64)}",
          "signature":"${java.util.Base64.getEncoder().encodeToString(ByteArray(64) { 0x77 })}"
        }}
    """.trimIndent()
}
