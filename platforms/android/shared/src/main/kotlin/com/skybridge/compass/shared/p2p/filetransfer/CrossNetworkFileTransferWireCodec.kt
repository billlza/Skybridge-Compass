package com.skybridge.compass.shared.p2p.filetransfer

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * Shipping JSON codec for the F1 WebRTC file-transfer envelope.
 *
 * Decoding remains compatible with historical peers: object-key order is insignificant and
 * unknown fields are ignored. Encoding is deliberately canonical so Apple and Android produce
 * the same bytes for the same typed message. Only object keys are sorted; array order is protocol
 * data and is therefore preserved.
 */
object CrossNetworkFileTransferWireCodec {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    fun encode(message: CrossNetworkFileTransferMessage): ByteArray {
        val element = json.encodeToJsonElement(
            CrossNetworkFileTransferMessage.serializer(),
            message,
        )
        return json.encodeToString(
            JsonElement.serializer(),
            canonicalize(element),
        ).encodeToByteArray()
    }

    fun decode(bytes: ByteArray): CrossNetworkFileTransferMessage =
        json.decodeFromString(
            CrossNetworkFileTransferMessage.serializer(),
            bytes.decodeToString(),
        )

    internal fun canonicalize(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(
            element.entries
                .sortedBy { it.key }
                .associateTo(linkedMapOf()) { (key, value) -> key to canonicalize(value) },
        )
        is JsonArray -> JsonArray(element.map(::canonicalize))
        else -> element
    }
}
