package com.skybridge.compass.android.security

import android.content.Context
import android.util.Base64
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.flow.first
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.CertificatePinner
import java.security.KeyFactory
import java.security.PublicKey
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64 as JavaBase64

private val Context.pinRegistryDataStore by preferencesDataStore(name = "pin_registry")

/** Host pins model */
@Serializable
data class HostPins(
    val host: String,
    val pins: List<String>,
    @SerialName("expires") val expiresIso8601: String? = null
)

@Serializable
data class RemotePinPayload(
    val hosts: List<HostPins>,
    @SerialName("expires") val expiresIso8601: String? = null
)

@Serializable
data class SignedRemotePins(
    val payload: String,           // JSON string of RemotePinPayload
    val signatureBase64: String    // Signature over payload (application-specific)
)

interface PinProvider {
    suspend fun buildCertificatePinner(context: Context): CertificatePinner?
    suspend fun updateFromTrustedJson(context: Context, payloadJson: String): Result<Unit>
    suspend fun refreshFromUrl(context: Context, httpClient: HttpClient, url: String): Result<Unit>
}

class PinProviderImpl(
    private val json: Json,
    private val allowUnverifiedPinsInDebug: Boolean = false,
    private val publicKeyPem: String? = null
) : PinProvider {

    private val KEY_PINS_JSON = stringPreferencesKey("pins_json")

    override suspend fun buildCertificatePinner(context: Context): CertificatePinner? {
        val prefs = context.pinRegistryDataStore.data.first()
        val pinsJson = prefs[KEY_PINS_JSON] ?: return null
        val payload = parseAndValidateRemotePinPayload(json, pinsJson)
        if (payload.hosts.isEmpty()) return null
        val builder = CertificatePinner.Builder()
        payload.hosts.forEach { hostPins ->
            builder.add(hostPins.host, *validatedCertificatePins(hostPins).toTypedArray())
        }
        return builder.build()
    }

    override suspend fun updateFromTrustedJson(context: Context, payloadJson: String): Result<Unit> {
        // Externally verified payloads can be accepted after sanity parse
        return try {
            parseAndValidateRemotePinPayload(json, payloadJson)
            // Save new pins, keeping previous for rollback on failure
            val prev = context.pinRegistryDataStore.data.first()[KEY_PINS_JSON]
            try {
                context.pinRegistryDataStore.edit { it[KEY_PINS_JSON] = payloadJson }
                Result.success(Unit)
            } catch (e: Exception) {
                // Attempt rollback
                if (prev != null) {
                    runCatching { context.pinRegistryDataStore.edit { it[KEY_PINS_JSON] = prev } }
                }
                Result.failure(e)
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun refreshFromUrl(context: Context, httpClient: HttpClient, url: String): Result<Unit> {
        return try {
            val body = httpClient.get(url).bodyAsText()
            val signed = json.decodeFromString(SignedRemotePins.serializer(), body)
            val payload = signed.payload
            val signatureB64 = signed.signatureBase64
            val signatureOk = verifySignatureRsaSha256(payload, signatureB64)
            if (!signatureOk && !allowUnverifiedPinsInDebug) {
                return Result.failure(IllegalStateException("Remote pins signature invalid"))
            }
            // Accept payload (verified or dev-override)
            parseAndValidateRemotePinPayload(json, payload)
            val prev = context.pinRegistryDataStore.data.first()[KEY_PINS_JSON]
            try {
                context.pinRegistryDataStore.edit { it[KEY_PINS_JSON] = payload }
                Result.success(Unit)
            } catch (e: Exception) {
                // Attempt rollback
                if (prev != null) {
                    runCatching { context.pinRegistryDataStore.edit { it[KEY_PINS_JSON] = prev } }
                }
                Result.failure(e)
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun verifySignatureRsaSha256(payload: String, signatureB64: String): Boolean {
        return try {
            val pem = publicKeyPem ?: return false
            val publicKey = parseRsaPublicKeyFromPem(pem) ?: return false
            val sigBytes = Base64.decode(signatureB64, Base64.DEFAULT)
            val signature = Signature.getInstance("SHA256withRSA")
            signature.initVerify(publicKey)
            signature.update(payload.toByteArray())
            signature.verify(sigBytes)
        } catch (_: Exception) {
            false
        }
    }

    private fun parseRsaPublicKeyFromPem(pem: String): PublicKey? {
        return try {
            val cleaned = pem
                .replace("-----BEGIN PUBLIC KEY-----", "")
                .replace("-----END PUBLIC KEY-----", "")
                .replace("\n", "")
                .trim()
            val decoded = Base64.decode(cleaned, Base64.DEFAULT)
            val keySpec = X509EncodedKeySpec(decoded)
            val keyFactory = KeyFactory.getInstance("RSA")
            keyFactory.generatePublic(keySpec)
        } catch (_: Exception) {
            null
        }
    }
}

internal fun parseAndValidateRemotePinPayload(json: Json, payloadJson: String): RemotePinPayload {
    val payload = json.decodeFromString(RemotePinPayload.serializer(), payloadJson)
    payload.hosts.forEach(::validatedCertificatePins)
    return payload
}

internal fun validatedCertificatePins(hostPins: HostPins): List<String> {
    val host = hostPins.host.trim()
    require(host.isNotEmpty()) { "pin registry host is blank" }
    require(hostPins.pins.isNotEmpty()) { "pin registry host $host has no certificate pins" }
    return hostPins.pins.map { pin ->
        require(pin.startsWith("sha256/")) { "pin registry host $host has unsupported pin algorithm" }
        val digest = pin.removePrefix("sha256/")
        val decoded = runCatching { JavaBase64.getDecoder().decode(digest) }.getOrElse {
            throw IllegalArgumentException("pin registry host $host has invalid sha256 pin base64", it)
        }
        require(decoded.size == 32) { "pin registry host $host has sha256 pin length ${decoded.size}, expected 32" }
        pin
    }
}
