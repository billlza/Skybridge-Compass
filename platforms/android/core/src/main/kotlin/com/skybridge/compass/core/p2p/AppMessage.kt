package com.skybridge.compass.core.p2p

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
import java.nio.charset.CharacterCodingException
import java.util.Base64
import kotlin.math.roundToLong

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
    data class AuthenticatedRouteBinding(val payload: AuthenticatedRouteBindingPayload) : AppMessage()
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
        val capabilities: List<String>? = null,
        val fileTransferPort: Int? = null,
        val remoteControlPort: Int? = null,
        val sentAt: Double,
        val accountDisplayName: String? = null,
        val nebulaId: String? = null
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
        val remoteVideoFormats: List<String>? = null,
        val capabilities: List<String>? = null,
        val fileTransferPort: Int? = null,
        val remoteControlPort: Int? = null,
        val accountDisplayName: String? = null,
        val nebulaId: String? = null
    )

    @Serializable
    data class PingPayload(val id: Long)

    @Serializable
    data class PongPayload(val id: Long)

    @Serializable
    data class AuthenticatedRouteBindingPayload(
        val version: Int = 1,
        val kind: String,
        val serviceType: String,
        val instanceName: String,
        val hostName: String,
        val port: Int,
        val endpointProvenance: String,
        val localDeviceId: String,
        val remoteDeviceId: String,
        val routeAuthorityProtocolPublicKeyFingerprint: String,
        val remoteProtocolPublicKeyFingerprint: String,
        val sessionHashHex: String,
        val transcriptPrefixHex: String,
        val sentAt: Double,
        val expiresAt: Double,
        @Serializable(with = Base64BytesSerializer::class)
        val nonce: ByteArray
    )
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

    fun toUnixEpochMillis(swiftSeconds: Double): Long {
        require(swiftSeconds.isFinite()) { "Swift date seconds must be finite" }
        val epochMillis = (swiftSeconds + SWIFT_REF_UNIX_SECONDS) * 1000.0
        require(epochMillis.isFinite() && epochMillis > 0.0) { "Swift date seconds are out of range" }
        return epochMillis.roundToLong()
    }
}

/**
 * Kotlinx serializer compatible with Swift Codable `Data` (base64 string).
 */
object Base64BytesSerializer : KSerializer<ByteArray> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("Base64Bytes", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: ByteArray) {
        encoder.encodeString(Base64.getEncoder().encodeToString(value))
    }

    override fun deserialize(decoder: Decoder): ByteArray {
        val s = decoder.decodeString()
        return try {
            Base64.getDecoder().decode(s)
        } catch (e: IllegalArgumentException) {
            throw SerializationException("Invalid base64", e)
        }
    }
}

class AppMessageCodec(
    private val json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false }
) {
    sealed class DecodeResult {
        data class Known(val message: AppMessage) : DecodeResult()
        data class UnknownType(val type: String) : DecodeResult()
    }

    class DecodeException(message: String, cause: Throwable? = null) : IllegalArgumentException(message, cause)

    fun encode(message: AppMessage): ByteArray {
        val obj: JsonObject = when (message) {
            is AppMessage.Clipboard ->
                JsonObject(mapOf("clipboard" to json.encodeToJsonElement(AppMessage.ClipboardPayload.serializer(), message.payload)))
            is AppMessage.PairingIdentityExchange ->
                JsonObject(mapOf("pairingIdentityExchange" to json.encodeToJsonElement(AppMessage.PairingIdentityExchangePayload.serializer(), message.payload)))
            is AppMessage.Heartbeat ->
                JsonObject(mapOf("heartbeat" to json.encodeToJsonElement(AppMessage.HeartbeatPayload.serializer(), message.payload)))
            is AppMessage.AuthenticatedRouteBinding -> {
                validateAuthenticatedRouteBindingPayload(message.payload)
                JsonObject(mapOf("authenticatedRouteBinding" to json.encodeToJsonElement(AppMessage.AuthenticatedRouteBindingPayload.serializer(), message.payload)))
            }
            is AppMessage.Ping ->
                JsonObject(mapOf("ping" to json.encodeToJsonElement(AppMessage.PingPayload.serializer(), message.payload)))
            is AppMessage.Pong ->
                JsonObject(mapOf("pong" to json.encodeToJsonElement(AppMessage.PongPayload.serializer(), message.payload)))
        }
        return json.encodeToString(JsonObject.serializer(), obj).encodeToByteArray()
    }

    fun decode(bytes: ByteArray): AppMessage? {
        return when (val result = runCatching { decodeAuthenticatedControl(bytes) }.getOrNull()) {
            is DecodeResult.Known -> result.message
            is DecodeResult.UnknownType,
            null -> null
        }
    }

    fun decodeAuthenticatedControl(bytes: ByteArray): DecodeResult {
        val text = try {
            bytes.decodeToString(throwOnInvalidSequence = true)
        } catch (e: CharacterCodingException) {
            throw DecodeException("Authenticated app-control payload is not valid UTF-8", e)
        }
        val element: JsonElement = try {
            json.parseToJsonElement(text)
        } catch (e: SerializationException) {
            throw DecodeException("Authenticated app-control payload is not valid JSON", e)
        }
        val obj = element as? JsonObject
            ?: throw DecodeException("Authenticated app-control payload must be a JSON object")
        if (obj.isEmpty()) {
            throw DecodeException("Authenticated app-control payload has no message type")
        }
        if (obj.size != 1) {
            throw DecodeException("Authenticated app-control payload must have exactly one message type")
        }

        // Externally-tagged: authenticated control messages must be a single-key object.
        val (key, value) = obj.entries.first()
        return try {
            when (key) {
                "clipboard" -> {
                    val payload = json.decodeFromJsonElement(AppMessage.ClipboardPayload.serializer(), value)
                    DecodeResult.Known(AppMessage.Clipboard(payload))
                }
                "pairingIdentityExchange" -> {
                    val payload = json.decodeFromJsonElement(AppMessage.PairingIdentityExchangePayload.serializer(), value)
                    DecodeResult.Known(AppMessage.PairingIdentityExchange(payload))
                }
                "heartbeat" -> {
                    val payload = json.decodeFromJsonElement(AppMessage.HeartbeatPayload.serializer(), value)
                    DecodeResult.Known(AppMessage.Heartbeat(payload))
                }
                "authenticatedRouteBinding" -> {
                    val payload = json.decodeFromJsonElement(AppMessage.AuthenticatedRouteBindingPayload.serializer(), value)
                    validateAuthenticatedRouteBindingPayload(payload)
                    DecodeResult.Known(AppMessage.AuthenticatedRouteBinding(payload))
                }
                "ping" -> {
                    val payload = json.decodeFromJsonElement(AppMessage.PingPayload.serializer(), value)
                    DecodeResult.Known(AppMessage.Ping(payload))
                }
                "pong" -> {
                    val payload = json.decodeFromJsonElement(AppMessage.PongPayload.serializer(), value)
                    DecodeResult.Known(AppMessage.Pong(payload))
                }
                else -> DecodeResult.UnknownType(key)
            }
        } catch (e: SerializationException) {
            throw DecodeException("Authenticated app-control payload for '$key' is malformed", e)
        }
    }

    private fun validateAuthenticatedRouteBindingPayload(payload: AppMessage.AuthenticatedRouteBindingPayload) {
        if (payload.version != 1) {
            throw DecodeException("authenticatedRouteBinding version is unsupported")
        }
        if (payload.kind != "fileTransfer" && payload.kind != "remoteDesktop") {
            throw DecodeException("authenticatedRouteBinding kind must be fileTransfer or remoteDesktop")
        }
        if (payload.endpointProvenance != "resolved-dns-sd-endpoint") {
            throw DecodeException("authenticatedRouteBinding endpointProvenance must be resolved-dns-sd-endpoint")
        }
        if (payload.serviceType.isBlank()) {
            throw DecodeException("authenticatedRouteBinding serviceType must not be empty")
        }
        if (payload.instanceName.isBlank()) {
            throw DecodeException("authenticatedRouteBinding instanceName must not be empty")
        }
        if (payload.hostName.isBlank()) {
            throw DecodeException("authenticatedRouteBinding hostName must not be empty")
        }
        if (payload.port !in 1..65535) {
            throw DecodeException("authenticatedRouteBinding port must be between 1 and 65535")
        }
        if (payload.localDeviceId.isBlank()) {
            throw DecodeException("authenticatedRouteBinding localDeviceId must not be empty")
        }
        if (payload.remoteDeviceId.isBlank()) {
            throw DecodeException("authenticatedRouteBinding remoteDeviceId must not be empty")
        }
        if (!isLowerHex(payload.routeAuthorityProtocolPublicKeyFingerprint, 64)) {
            throw DecodeException("authenticatedRouteBinding routeAuthorityProtocolPublicKeyFingerprint must be 64 lowercase hex characters")
        }
        if (!isLowerHex(payload.remoteProtocolPublicKeyFingerprint, 64)) {
            throw DecodeException("authenticatedRouteBinding remoteProtocolPublicKeyFingerprint must be 64 lowercase hex characters")
        }
        if (!isLowerHex(payload.sessionHashHex, 16)) {
            throw DecodeException("authenticatedRouteBinding sessionHashHex must be 16 lowercase hex characters")
        }
        if (!isLowerHex(payload.transcriptPrefixHex, 16)) {
            throw DecodeException("authenticatedRouteBinding transcriptPrefixHex must be 16 lowercase hex characters")
        }
        if (!payload.sentAt.isFinite() || !payload.expiresAt.isFinite() || payload.expiresAt <= payload.sentAt) {
            throw DecodeException("authenticatedRouteBinding expiresAt must be finite and later than sentAt")
        }
        if (payload.nonce.size < 16) {
            throw DecodeException("authenticatedRouteBinding nonce must be at least 16 bytes")
        }
    }

    private fun isLowerHex(value: String, expectedLength: Int): Boolean =
        value.length == expectedLength && value.all { it in '0'..'9' || it in 'a'..'f' }
}
