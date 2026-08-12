@file:OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)

package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.p2p.P2PPibShortAuthString
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.util.Base64

/**
 * Wire models + codec for the PIB-1 LAN bootstrap-control exchange, matching the macOS canon
 * `Sources/SkyBridgeCore/P2P/AppMessage.swift` cases:
 *   - `.protocolIdentityBindingRequest(ProtocolIdentityBindingRequestPayload)`
 *   - `.signedProtocolIdentityBinding(SignedProtocolIdentityBindingPayload)`
 *
 * CRITICAL interop facts (verified against the Pro-release source):
 *
 *  1. Transport is a plain-TCP framed channel to the Mac's `_skybridge._tcp` handshake socket
 *     (`P2PDiscoveryService.exchangeBootstrapControlMessage`, P2PDiscoveryService.swift:1347). Each
 *     frame is `UInt32 big-endian length || bytes` where `bytes` is the JSON of the externally-tagged
 *     `AppMessage` enum, e.g. `{"protocolIdentityBindingRequest": {...}}`.
 *
 *  2. The bootstrap frames are encoded with a BARE `JSONEncoder()` / `JSONDecoder()` (no custom
 *     date/data strategy — P2PDiscoveryService.swift:1360,1366). Swift's default Codable therefore
     *     encodes:
     *       - `Data`  ->  a base64 JSON string
     *       - `Date`  ->  a Double = secondsSinceReferenceDate (2001-01-01 00:00:00 UTC)
 *     This is DIFFERENT from the SBWC/WebRTC AppMessage path (which uses base64). [SwiftDataIntArray]
 *     and [SwiftReferenceDate] below reproduce the bare-encoder behavior.
 *
 *  3. The SAS + signatures are computed over the CANONICAL preimage (`key=value\n` encoding via
 *     [P2PPibCanonical]/`P2PPibShortAuthString`), NOT over this JSON. The JSON is transport only.
 */
object PibBootstrapWire {

    class DecodeException(message: String, cause: Throwable? = null) :
        IllegalArgumentException(message, cause)

    /** Swift Date reference epoch (2001-01-01 00:00:00 UTC) in Unix seconds. */
    const val SWIFT_REFERENCE_EPOCH_UNIX_SECONDS: Double = 978_307_200.0

    fun unixMillisToReferenceSeconds(unixMillis: Long): Double =
        (unixMillis.toDouble() / 1000.0) - SWIFT_REFERENCE_EPOCH_UNIX_SECONDS

    fun referenceSecondsToUnixMillis(referenceSeconds: Double): Long =
        ((referenceSeconds + SWIFT_REFERENCE_EPOCH_UNIX_SECONDS) * 1000.0).toLong()

    /** floor(unixSeconds * 1000), matching `AppMessage.millisecondsSinceEpoch` (AppMessage.swift:1276). */
    fun referenceSecondsToCanonicalMillis(referenceSeconds: Double): Long {
        require(referenceSeconds.isFinite()) { "PIB timestamp must be finite" }
        val unixSeconds = referenceSeconds + SWIFT_REFERENCE_EPOCH_UNIX_SECONDS
        val milliseconds = unixSeconds * 1000.0
        require(milliseconds.isFinite()) { "PIB timestamp is outside the canonical millisecond domain" }
        val flooredMilliseconds = kotlin.math.floor(milliseconds)
        val upperBoundExclusive = -Long.MIN_VALUE.toDouble()
        require(
            flooredMilliseconds >= Long.MIN_VALUE.toDouble() &&
                flooredMilliseconds < upperBoundExclusive
        ) { "PIB timestamp is outside the canonical Int64 millisecond domain" }
        return flooredMilliseconds.toLong()
    }

    private val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
    }

    // --- AppMessage payloads ------------------------------------------------------------------

    @Serializable
    data class ProtocolIdentityBindingRequestPayload(
        val version: Int = P2PPibShortAuthString.REQUEST_VERSION,
        val transactionId: String,
        val requesterDeviceId: String,
        val targetDeviceId: String,
        val requestedProtocolSigningAlgorithms: List<String>,
        val requesterProtocolSigningAlgorithm: String? = null,
        @Serializable(with = SwiftDataBase64::class)
        val requesterProtocolIdentityPublicKey: ByteArray? = null,
        val requesterProtocolIdentityFingerprint: String? = null,
        @Serializable(with = SwiftDataBase64::class)
        val requesterSignature: ByteArray? = null,
        val policyRequirePQC: Boolean = true,
        val policyAllowClassicFallback: Boolean = false,
        val routeScope: String = "lan",
        val bonjourEndpointDigest: String? = null,
        @Serializable(with = SwiftDataBase64NonNull::class)
        val nonce: ByteArray,
        @Serializable(with = SwiftReferenceDate::class)
        val sentAt: Double
    )

    @Serializable
    data class SignedProtocolIdentityBindingPayload(
        val version: Int = P2PPibShortAuthString.RESPONSE_VERSION,
        val transactionId: String,
        val deviceId: String,
        val aliases: List<String> = emptyList(),
        val protocolSigningAlgorithm: String,
        @Serializable(with = SwiftDataBase64NonNull::class)
        val protocolIdentityPublicKey: ByteArray,
        val protocolIdentityFingerprint: String,
        val deviceName: String? = null,
        @Serializable(with = SwiftReferenceDate::class)
        val sentAt: Double,
        @Serializable(with = SwiftReferenceDate::class)
        val expiresAt: Double,
        @Serializable(with = SwiftDataBase64NonNull::class)
        val requestNonce: ByteArray,
        val requestHashHex: String? = null,
        val policyRequirePQC: Boolean = true,
        val policyAllowClassicFallback: Boolean = false,
        val routeScope: String = "lan",
        val bonjourEndpointDigest: String? = null,
        @Serializable(with = SwiftDataBase64NonNull::class)
        val signature: ByteArray
    )

    @Serializable
    data class ProtocolIdentityBindingConfirmPayload(
        val version: Int = P2PPibShortAuthString.CONFIRM_VERSION,
        val transactionId: String,
        val requesterDeviceId: String,
        val responderDeviceId: String,
        val requesterProtocolIdentityFingerprint: String,
        val responderProtocolIdentityFingerprint: String,
        @Serializable(with = SwiftDataBase64NonNull::class)
        val requestNonce: ByteArray,
        val requestHashHex: String,
        val candidateHashHex: String,
        val sasTranscriptHashHex: String,
        @Serializable(with = SwiftDataBase64NonNull::class)
        val confirmationNonce: ByteArray,
        @Serializable(with = SwiftReferenceDate::class)
        val sentAt: Double,
        @Serializable(with = SwiftReferenceDate::class)
        val expiresAt: Double,
        val policyRequirePQC: Boolean = true,
        val policyAllowClassicFallback: Boolean = false,
        val routeScope: String = "lan",
        @Serializable(with = SwiftDataBase64NonNull::class)
        val requesterSignature: ByteArray
    )

    @Serializable
    data class SignedProtocolIdentityBindingFinalAckPayload(
        val version: Int = P2PPibShortAuthString.FINAL_ACK_VERSION,
        val transactionId: String,
        val requesterDeviceId: String,
        val responderDeviceId: String,
        val requesterProtocolIdentityFingerprint: String,
        val responderProtocolIdentityFingerprint: String,
        @Serializable(with = SwiftDataBase64NonNull::class)
        val requestNonce: ByteArray,
        @Serializable(with = SwiftDataBase64NonNull::class)
        val confirmationNonce: ByteArray,
        val requestHashHex: String,
        val candidateHashHex: String,
        val confirmHashHex: String,
        val sasTranscriptHashHex: String,
        val accepted: Boolean,
        @Serializable(with = SwiftReferenceDate::class)
        val sentAt: Double,
        @Serializable(with = SwiftReferenceDate::class)
        val expiresAt: Double,
        val policyRequirePQC: Boolean = true,
        val policyAllowClassicFallback: Boolean = false,
        val routeScope: String = "lan",
        @Serializable(with = SwiftDataBase64NonNull::class)
        val responderSignature: ByteArray
    )

    // --- Encode / decode the externally-tagged AppMessage envelope ----------------------------

    fun encodeRequest(payload: ProtocolIdentityBindingRequestPayload): ByteArray {
        val obj = JsonObject(
            mapOf(
                "protocolIdentityBindingRequest" to json.encodeToJsonElement(
                    ProtocolIdentityBindingRequestPayload.serializer(), payload
                )
            )
        )
        return json.encodeToString(JsonObject.serializer(), obj).encodeToByteArray()
    }

    fun encodeConfirm(payload: ProtocolIdentityBindingConfirmPayload): ByteArray {
        val obj = JsonObject(
            mapOf(
                "protocolIdentityBindingConfirm" to json.encodeToJsonElement(
                    ProtocolIdentityBindingConfirmPayload.serializer(), payload
                )
            )
        )
        return json.encodeToString(JsonObject.serializer(), obj).encodeToByteArray()
    }

    fun decodeSignedBinding(bytes: ByteArray): SignedProtocolIdentityBindingPayload =
        decodeSingleCase(
            bytes = bytes,
            caseName = "signedProtocolIdentityBinding",
            serializer = SignedProtocolIdentityBindingPayload.serializer()
        )

    fun decodeFinalAck(bytes: ByteArray): SignedProtocolIdentityBindingFinalAckPayload =
        decodeSingleCase(
            bytes = bytes,
            caseName = "signedProtocolIdentityBindingFinalAck",
            serializer = SignedProtocolIdentityBindingFinalAckPayload.serializer()
        )

    private fun <T> decodeSingleCase(
        bytes: ByteArray,
        caseName: String,
        serializer: KSerializer<T>
    ): T = try {
        val text = StrictJsonWire.validatedUtf8(bytes)
        val element: JsonElement = json.parseToJsonElement(text)
        val envelopeCase = StrictJsonWire.requireSingleEnvelopeCase(
            element = element,
            allowedCases = setOf(caseName)
        )
        json.decodeFromJsonElement(serializer, envelopeCase.payload)
    } catch (error: DecodeException) {
        throw error
    } catch (error: Exception) {
        throw DecodeException("malformed PIB-1 message", error)
    }

    // --- Swift-bare-JSONEncoder compatible serializers ---------------------------------------

    /** Encodes `Data?` as Swift's default JSONEncoder does: a base64 JSON string. */
    object SwiftDataBase64 : KSerializer<ByteArray?> {
        private val delegate = String.serializer()
        override val descriptor: SerialDescriptor = delegate.descriptor
        override fun serialize(encoder: Encoder, value: ByteArray?) {
            delegate.serialize(encoder, Base64.getEncoder().encodeToString(value ?: ByteArray(0)))
        }
        override fun deserialize(decoder: Decoder): ByteArray {
            return Base64.getDecoder().decode(delegate.deserialize(decoder))
        }
    }

    object SwiftDataBase64NonNull : KSerializer<ByteArray> {
        private val delegate = String.serializer()
        override val descriptor: SerialDescriptor = delegate.descriptor
        override fun serialize(encoder: Encoder, value: ByteArray) {
            delegate.serialize(encoder, Base64.getEncoder().encodeToString(value))
        }
        override fun deserialize(decoder: Decoder): ByteArray {
            return Base64.getDecoder().decode(delegate.deserialize(decoder))
        }
    }

    /** Encodes a Swift `Date` as a raw Double (secondsSinceReferenceDate). */
    object SwiftReferenceDate : KSerializer<Double> {
        override val descriptor: SerialDescriptor = Double.serializer().descriptor
        override fun serialize(encoder: Encoder, value: Double) = encoder.encodeDouble(value)
        override fun deserialize(decoder: Decoder): Double = decoder.decodeDouble()
    }
}
