package com.skybridge.compass.core.p2p

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement

/** Bare Swift JSONEncoder compatibility for the externally-tagged SKR-1 AppMessage cases. */
internal object SkrBootstrapWire {
    class DecodeException(message: String, cause: Throwable? = null) : IllegalArgumentException(message, cause)
    private val json = Json {
        ignoreUnknownKeys = false
        explicitNulls = false
        encodeDefaults = true
    }

    @Serializable
    data class KemRefreshRequestPayload(
        val version: Int = SkrCanonical.CURRENT_VERSION,
        val requesterDeviceId: String,
        val targetDeviceId: String,
        val requesterProtocolIdentityFingerprint: String? = null,
        val targetProtocolIdentityFingerprint: String? = null,
        val requestedSuiteWireIds: List<Int>,
        val policyRequirePQC: Boolean = true,
        val policyAllowClassicFallback: Boolean = false,
        val policyHashHex: String,
        val routeScope: String = SkrCanonical.ROUTE_SCOPE_LAN,
        val bonjourEndpointDigest: String? = null,
        @Serializable(with = PibBootstrapWire.SwiftDataBase64NonNull::class)
        val nonce: ByteArray,
        @Serializable(with = PibBootstrapWire.SwiftReferenceDate::class)
        val sentAt: Double
    )

    @Serializable
    data class KemPublicKeyInfo(
        val suiteWireId: Int,
        @Serializable(with = PibBootstrapWire.SwiftDataBase64NonNull::class)
        val publicKey: ByteArray
    )

    @Serializable
    data class SignedKemRefreshPayload(
        val version: Int = SkrCanonical.CURRENT_VERSION,
        val deviceId: String,
        val aliases: List<String> = emptyList(),
        val protocolSigningAlgorithm: String,
        @Serializable(with = PibBootstrapWire.SwiftDataBase64NonNull::class)
        val protocolIdentityPublicKey: ByteArray,
        val protocolIdentityFingerprint: String,
        val kemPublicKeys: List<KemPublicKeyInfo>,
        val keyId: String,
        val generation: Long,
        @Serializable(with = PibBootstrapWire.SwiftReferenceDate::class)
        val sentAt: Double,
        @Serializable(with = PibBootstrapWire.SwiftReferenceDate::class)
        val expiresAt: Double,
        @Serializable(with = PibBootstrapWire.SwiftDataBase64NonNull::class)
        val requestNonce: ByteArray,
        val requestHashHex: String? = null,
        val policyRequirePQC: Boolean = true,
        val policyAllowClassicFallback: Boolean = false,
        val routeScope: String = SkrCanonical.ROUTE_SCOPE_LAN,
        val bonjourEndpointDigest: String? = null,
        @Serializable(with = PibBootstrapWire.SwiftDataBase64NonNull::class)
        val signature: ByteArray
    )

    @Serializable
    data class KemRefreshFailurePayload(
        val version: Int,
        val requesterDeviceId: String,
        val targetDeviceId: String,
        val stage: String,
        val reasonCode: String,
        val reason: String,
        val requestHashHex: String? = null,
        @Serializable(with = PibBootstrapWire.SwiftReferenceDate::class)
        val sentAt: Double
    )

    sealed interface Response {
        data class Signed(val payload: SignedKemRefreshPayload) : Response
        data class Failure(val payload: KemRefreshFailurePayload) : Response
    }

    fun encodeRequest(payload: KemRefreshRequestPayload): ByteArray {
        val envelope = JsonObject(
            mapOf(
                REQUEST_CASE to json.encodeToJsonElement(
                    KemRefreshRequestPayload.serializer(),
                    payload
                )
            )
        )
        return json.encodeToString(JsonObject.serializer(), envelope).encodeToByteArray()
    }

    fun decodeResponse(bytes: ByteArray): Response = try {
        decodeResponseStrict(bytes)
    } catch (e: DecodeException) {
        throw e
    } catch (e: Exception) {
        throw DecodeException("malformed SKR-1 response", e)
    }

    private fun decodeResponseStrict(bytes: ByteArray): Response {
        val text = StrictJsonWire.validatedUtf8(bytes)
        val element: JsonElement = json.parseToJsonElement(text)
        val envelopeCase = StrictJsonWire.requireSingleEnvelopeCase(
            element = element,
            allowedCases = setOf(SIGNED_RESPONSE_CASE, FAILURE_CASE)
        )
        return when (envelopeCase.name) {
            SIGNED_RESPONSE_CASE -> Response.Signed(
                json.decodeFromJsonElement(
                    SignedKemRefreshPayload.serializer(),
                    envelopeCase.payload
                )
            )
            FAILURE_CASE -> Response.Failure(
                json.decodeFromJsonElement(
                    KemRefreshFailurePayload.serializer(),
                    envelopeCase.payload
                )
            )
            else -> error("validated SKR-1 envelope case is unhandled")
        }
    }

    private const val REQUEST_CASE = "kemRefreshRequest"
    private const val SIGNED_RESPONSE_CASE = "signedKEMRefresh"
    private const val FAILURE_CASE = "kemRefreshFailure"

}
