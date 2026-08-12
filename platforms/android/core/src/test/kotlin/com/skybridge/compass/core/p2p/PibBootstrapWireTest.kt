package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.p2p.P2PPibShortAuthString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Base64

class PibBootstrapWireTest {

    private val json = Json
    private val transactionId = "12345678-1234-5678-1234-567812345678"

    @Test
    fun encodeRequestUsesSwiftDefaultBase64DataFields() {
        val publicKey = byteArrayOf(1, 2, 3, 4)
        val signature = byteArrayOf(5, 6, 7, 8)
        val nonce = ByteArray(24) { (it + 9).toByte() }

        val encoded = PibBootstrapWire.encodeRequest(
            PibBootstrapWire.ProtocolIdentityBindingRequestPayload(
                transactionId = transactionId,
                requesterDeviceId = "android-device",
                targetDeviceId = "mac-device",
                requestedProtocolSigningAlgorithms = listOf("ML-DSA-65", "Ed25519"),
                requesterProtocolSigningAlgorithm = "ML-DSA-65",
                requesterProtocolIdentityPublicKey = publicKey,
                requesterProtocolIdentityFingerprint = "ab".repeat(32),
                requesterSignature = signature,
                nonce = nonce,
                sentAt = 1.25
            )
        )

        val request = json.parseToJsonElement(encoded.decodeToString())
            .jsonObject
            .getValue("protocolIdentityBindingRequest")
            .jsonObject

        assertEquals(P2PPibShortAuthString.REQUEST_VERSION, request.getValue("version").jsonPrimitive.content.toInt())
        assertEquals(transactionId, request.getValue("transactionId").jsonPrimitive.content)
        assertEquals(base64(publicKey), request.getValue("requesterProtocolIdentityPublicKey").jsonPrimitive.content)
        assertEquals(base64(signature), request.getValue("requesterSignature").jsonPrimitive.content)
        assertEquals(base64(nonce), request.getValue("nonce").jsonPrimitive.content)
        assertFalse(encoded.decodeToString().contains("\"nonce\":["))
    }

    @Test
    fun decodeSignedBindingAcceptsSwiftDefaultBase64DataFields() {
        val protocolKey = byteArrayOf(1, 1, 2, 3)
        val nonce = ByteArray(24) { it.toByte() }
        val signature = byteArrayOf(8, 7, 6, 5)
        val jsonText = """
            {
              "signedProtocolIdentityBinding": {
                "version": ${P2PPibShortAuthString.RESPONSE_VERSION},
                "transactionId": "$transactionId",
                "deviceId": "mac-device",
                "aliases": ["id:mac-device"],
                "protocolSigningAlgorithm": "ML-DSA-65",
                "protocolIdentityPublicKey": "${base64(protocolKey)}",
                "protocolIdentityFingerprint": "${"cd".repeat(32)}",
                "deviceName": "Mac \uD83D\uDE80",
                "sentAt": 1.0,
                "expiresAt": 2.0,
                "requestNonce": "${base64(nonce)}",
                "requestHashHex": "${"ef".repeat(32)}",
                "policyRequirePQC": true,
                "policyAllowClassicFallback": false,
                "routeScope": "lan",
                "signature": "${base64(signature)}"
              }
            }
        """.trimIndent()

        val decoded = PibBootstrapWire.decodeSignedBinding(jsonText.encodeToByteArray())

        assertArrayEquals(protocolKey, decoded.protocolIdentityPublicKey)
        assertArrayEquals(nonce, decoded.requestNonce)
        assertArrayEquals(signature, decoded.signature)
        assertEquals(transactionId, decoded.transactionId)
    }

    @Test
    fun confirmAndFinalAckUseSwiftCompatibleEnvelopeAndDataEncoding() {
        val requestNonce = ByteArray(24) { (it + 1).toByte() }
        val confirmationNonce = ByteArray(24) { (it + 31).toByte() }
        val requesterSignature = byteArrayOf(9, 8, 7, 6)
        val confirm = PibBootstrapWire.ProtocolIdentityBindingConfirmPayload(
            transactionId = transactionId,
            requesterDeviceId = "android-device",
            responderDeviceId = "mac-device",
            requesterProtocolIdentityFingerprint = "ab".repeat(32),
            responderProtocolIdentityFingerprint = "cd".repeat(32),
            requestNonce = requestNonce,
            requestHashHex = "de".repeat(32),
            candidateHashHex = "ef".repeat(32),
            sasTranscriptHashHex = "12".repeat(32),
            confirmationNonce = confirmationNonce,
            sentAt = 10.0,
            expiresAt = 20.0,
            requesterSignature = requesterSignature
        )

        val encodedConfirm = PibBootstrapWire.encodeConfirm(confirm)
        val confirmJson = json.parseToJsonElement(encodedConfirm.decodeToString())
            .jsonObject
            .getValue("protocolIdentityBindingConfirm")
            .jsonObject
        assertEquals(base64(requestNonce), confirmJson.getValue("requestNonce").jsonPrimitive.content)
        assertEquals(base64(confirmationNonce), confirmJson.getValue("confirmationNonce").jsonPrimitive.content)
        assertEquals(base64(requesterSignature), confirmJson.getValue("requesterSignature").jsonPrimitive.content)

        val responderSignature = byteArrayOf(1, 3, 5, 7)
        val finalAckJson = """
            {
              "signedProtocolIdentityBindingFinalAck": {
                "version": ${P2PPibShortAuthString.FINAL_ACK_VERSION},
                "transactionId": "$transactionId",
                "requesterDeviceId": "android-device",
                "responderDeviceId": "mac-device",
                "requesterProtocolIdentityFingerprint": "${"ab".repeat(32)}",
                "responderProtocolIdentityFingerprint": "${"cd".repeat(32)}",
                "requestNonce": "${base64(requestNonce)}",
                "confirmationNonce": "${base64(confirmationNonce)}",
                "requestHashHex": "${"de".repeat(32)}",
                "candidateHashHex": "${"ef".repeat(32)}",
                "confirmHashHex": "${"34".repeat(32)}",
                "sasTranscriptHashHex": "${"12".repeat(32)}",
                "accepted": true,
                "sentAt": 11.0,
                "expiresAt": 19.0,
                "policyRequirePQC": true,
                "policyAllowClassicFallback": false,
                "routeScope": "lan",
                "responderSignature": "${base64(responderSignature)}"
              }
            }
        """.trimIndent()

        val decodedFinalAck = PibBootstrapWire.decodeFinalAck(finalAckJson.encodeToByteArray())
        assertArrayEquals(requestNonce, decodedFinalAck.requestNonce)
        assertArrayEquals(confirmationNonce, decodedFinalAck.confirmationNonce)
        assertArrayEquals(responderSignature, decodedFinalAck.responderSignature)
    }

    @Test
    fun pibDecoderRejectsNonCanonicalExternallyTaggedJsonBeforePayloadDecode() {
        val malformedUtf8 = byteArrayOf(
            0x7b,
            0x22,
            0xc3.toByte(),
            0x28,
            0x22,
            0x3a,
            0x7b,
            0x7d,
            0x7d
        )
        assertThrows(PibBootstrapWire.DecodeException::class.java) {
            PibBootstrapWire.decodeSignedBinding(malformedUtf8)
        }

        listOf(
            """{"signedProtocolIdentityBinding":{},"extra":{}}""",
            """{"unknownCase":{}}""",
            """{"signedProtocolIdentityBinding":{"deviceId":"a","device\u0049d":"b"}}""",
            """{"signedProtocolIdentityBinding":{"nested":{"x":1,"x":2}}}""",
            """{"signedProtocolIdentityBinding":{}} true"""
        ).forEach { malformed ->
            assertThrows(PibBootstrapWire.DecodeException::class.java) {
                PibBootstrapWire.decodeSignedBinding(malformed.encodeToByteArray())
            }
        }

        val tooDeep = buildString {
            append("{\"signedProtocolIdentityBinding\":")
            repeat(65) { append('[') }
            append('0')
            repeat(65) { append(']') }
            append('}')
        }
        assertThrows(PibBootstrapWire.DecodeException::class.java) {
            PibBootstrapWire.decodeSignedBinding(tooDeep.encodeToByteArray())
        }
    }

    @Test
    fun canonicalMillisRejectsNonFiniteAndOutOfInt64DomainTimestamps() {
        listOf(
            Double.NaN,
            Double.POSITIVE_INFINITY,
            Double.NEGATIVE_INFINITY,
            Double.MAX_VALUE,
            (-Long.MIN_VALUE.toDouble() / 1_000.0) -
                PibBootstrapWire.SWIFT_REFERENCE_EPOCH_UNIX_SECONDS
        ).forEach { value ->
            assertThrows(IllegalArgumentException::class.java) {
                PibBootstrapWire.referenceSecondsToCanonicalMillis(value)
            }
        }
    }

    @Test
    fun canonicalMillisUsesFloorAndAcceptsTheInt64LowerBoundary() {
        val ordinary = PibBootstrapWire.unixMillisToReferenceSeconds(1_700_000_000_123)
        assertEquals(
            1_700_000_000_123,
            PibBootstrapWire.referenceSecondsToCanonicalMillis(ordinary)
        )

        val lowerBoundaryReferenceSeconds =
            (Long.MIN_VALUE.toDouble() / 1_000.0) -
                PibBootstrapWire.SWIFT_REFERENCE_EPOCH_UNIX_SECONDS
        assertEquals(
            Long.MIN_VALUE,
            PibBootstrapWire.referenceSecondsToCanonicalMillis(lowerBoundaryReferenceSeconds)
        )
    }

    private fun base64(bytes: ByteArray): String =
        Base64.getEncoder().encodeToString(bytes)
}
