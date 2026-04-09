package com.skybridge.compass.core.p2p

import android.util.Base64
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * App-level encrypted message sent over an established P2P session (after handshake).
 *
 * JSON shape must match Swift's synthesized Codable encoding (externally tagged enum):
 * `{"pairingIdentityExchange": {...}}`, `{"ping": {"id": 1}}`, etc.
 */
sealed class AppMessage {
    data class Clipboard(val payload: ClipboardPayload) : AppMessage()
    data class PairingIdentityExchange(val payload: PairingIdentityExchangePayload) : AppMessage()
    data class Heartbeat(val payload: HeartbeatPayload) : AppMessage()
    data class Ping(val payload: PingPayload) : AppMessage()
    data class Pong(val payload: PongPayload) : AppMessage()

    @Serializable
    data class ClipboardPayload(
        val mimeType: String,
        val dataBase64: String,
        val sentAt: Double
    )

    @Serializable
    data class KemPublicKeyInfo(
        val suiteWireId: Int,
        @Serializable(with = Base64BytesSerializer::class)
        val publicKey: ByteArray
    )

    @Serializable
    data class PairingIdentityExchangePayload(
        val deviceId: String,
        val kemPublicKeys: List<KemPublicKeyInfo>,
        val deviceName: String? = null,
        val modelName: String? = null,
        val platform: String? = null,
        val osVersion: String? = null,
        val chip: String? = null,
        val remoteVideoFormats: List<String>? = null,
        val sentAt: Double
    )

    @Serializable
    data class HeartbeatPayload(
        val sentAt: Double,
        val deviceId: String? = null,
        val deviceName: String? = null,
        val modelName: String? = null,
        val platform: String? = null,
        val osVersion: String? = null,
        val chip: String? = null,
        val remoteVideoFormats: List<String>? = null
    )

    @Serializable
    data class PingPayload(val id: Long)

    @Serializable
    data class PongPayload(val id: Long)
}

/**
 * Swift `Date` default JSONEncoder representation (`.deferredToDate`):
 * seconds since 2001-01-01 00:00:00 UTC.
 */
object SwiftDateSeconds {
    private const val SWIFT_REF_UNIX_SECONDS: Double = 978_307_200.0

    fun now(): Double {
        val unixSeconds = System.currentTimeMillis().toDouble() / 1000.0
        return unixSeconds - SWIFT_REF_UNIX_SECONDS
    }
}

/**
 * Kotlinx serializer compatible with Swift Codable `Data` (base64 string).
 */
object Base64BytesSerializer : KSerializer<ByteArray> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("Base64Bytes", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: ByteArray) {
        encoder.encodeString(Base64.encodeToString(value, Base64.NO_WRAP))
    }

    override fun deserialize(decoder: Decoder): ByteArray {
        val s = decoder.decodeString()
        return try {
            Base64.decode(s, Base64.DEFAULT)
        } catch (e: IllegalArgumentException) {
            throw SerializationException("Invalid base64", e)
        }
    }
}

class AppMessageCodec(
    private val json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false }
) {
    fun encode(message: AppMessage): ByteArray {
        val obj: JsonObject = when (message) {
            is AppMessage.Clipboard ->
                JsonObject(mapOf("clipboard" to json.encodeToJsonElement(AppMessage.ClipboardPayload.serializer(), message.payload)))
            is AppMessage.PairingIdentityExchange ->
                JsonObject(mapOf("pairingIdentityExchange" to json.encodeToJsonElement(AppMessage.PairingIdentityExchangePayload.serializer(), message.payload)))
            is AppMessage.Heartbeat ->
                JsonObject(mapOf("heartbeat" to json.encodeToJsonElement(AppMessage.HeartbeatPayload.serializer(), message.payload)))
            is AppMessage.Ping ->
                JsonObject(mapOf("ping" to json.encodeToJsonElement(AppMessage.PingPayload.serializer(), message.payload)))
            is AppMessage.Pong ->
                JsonObject(mapOf("pong" to json.encodeToJsonElement(AppMessage.PongPayload.serializer(), message.payload)))
        }
        return json.encodeToString(JsonObject.serializer(), obj).encodeToByteArray()
    }

    fun decode(bytes: ByteArray): AppMessage? {
        val text = runCatching { bytes.decodeToString() }.getOrNull() ?: return null
        val element: JsonElement = runCatching { json.parseToJsonElement(text) }.getOrNull() ?: return null
        val obj = runCatching { element.jsonObject }.getOrNull() ?: return null
        if (obj.isEmpty()) return null

        // Externally-tagged: single key object. If multiple keys exist, pick the first stable order.
        val (key, value) = obj.entries.first()
        return when (key) {
            "clipboard" -> {
                val payload = json.decodeFromJsonElement(AppMessage.ClipboardPayload.serializer(), value)
                AppMessage.Clipboard(payload)
            }
            "pairingIdentityExchange" -> {
                val payload = json.decodeFromJsonElement(AppMessage.PairingIdentityExchangePayload.serializer(), value)
                AppMessage.PairingIdentityExchange(payload)
            }
            "heartbeat" -> {
                val payload = json.decodeFromJsonElement(AppMessage.HeartbeatPayload.serializer(), value)
                AppMessage.Heartbeat(payload)
            }
            "ping" -> {
                val payload = json.decodeFromJsonElement(AppMessage.PingPayload.serializer(), value)
                AppMessage.Ping(payload)
            }
            "pong" -> {
                val payload = json.decodeFromJsonElement(AppMessage.PongPayload.serializer(), value)
                AppMessage.Pong(payload)
            }
            else -> null
        }
    }
}
