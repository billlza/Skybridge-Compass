package com.skybridge.compass.shared.p2p.filetransfer

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class CrossNetworkFileTransferWireCodecTest {
    private val transferId = "01234567-89AB-CDEF-0123-456789ABCDEF"

    @Test
    fun encodingIsDeterministicAndMatchesAppleCanonicalJson() {
        val message = CrossNetworkFileTransferMessage(
            op = CrossNetworkFileTransferOp.error,
            transferId = transferId,
            message = "path/segment",
        )
        val expected =
            "{\"message\":\"path/segment\",\"op\":\"error\",\"transferId\":\"$transferId\",\"version\":1}"
                .encodeToByteArray()

        repeat(64) {
            assertArrayEquals(expected, CrossNetworkFileTransferWireCodec.encode(message))
        }
    }

    @Test
    fun decodingAcceptsHistoricalKeyOrderAndEscapedSlashes() {
        val historical =
            "{\"version\":1,\"transferId\":\"$transferId\",\"op\":\"error\",\"message\":\"path\\/segment\"}"
                .encodeToByteArray()

        val decoded = CrossNetworkFileTransferWireCodec.decode(historical)

        assertEquals(CrossNetworkFileTransferOp.error, decoded.op)
        assertEquals(transferId, decoded.transferId)
        assertEquals("path/segment", decoded.message)
    }

    @Test
    fun canonicalizationRecursivelySortsObjectsButPreservesArrayOrder() {
        val input = JsonObject(
            linkedMapOf(
                "z" to JsonPrimitive(0),
                "a" to JsonArray(
                    listOf(
                        JsonObject(linkedMapOf("y" to JsonPrimitive(2), "x" to JsonPrimitive(1))),
                        JsonPrimitive(3),
                    ),
                ),
            ),
        )

        val canonical = CrossNetworkFileTransferWireCodec.canonicalize(input)

        assertEquals(listOf("a", "z"), (canonical as JsonObject).keys.toList())
        val array = canonical.getValue("a") as JsonArray
        assertEquals(listOf("x", "y"), (array[0] as JsonObject).keys.toList())
        assertEquals(JsonPrimitive(3), array[1])
    }
}
