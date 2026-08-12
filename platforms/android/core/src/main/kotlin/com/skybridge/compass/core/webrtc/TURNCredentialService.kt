package com.skybridge.compass.core.webrtc

import io.ktor.client.HttpClient
import io.ktor.client.engine.android.Android
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

/**
 * Mirrors the current Apple TURN fetch flow:
 * - GET /api/turn/credentials with X-API-Key
 * - include X-SkyBridge-Turn-Admission when available
 * - include X-Device-Id for server-side auditing/routing
 * - cache leased credentials until shortly before expiry
 */
class TURNCredentialService {
    @Serializable
    data class TurnCredentials(
        val username: String,
        val password: String,
        val ttl: Int,
        val uris: List<String>,
        val expiresAtMillis: Long
    ) {
        fun isValid(bufferMillis: Long = 300_000L): Boolean =
            System.currentTimeMillis() + bufferMillis < expiresAtMillis
    }

    @Serializable
    private data class ServerResponse(
        val username: String,
        val password: String? = null,
        val credential: String? = null,
        val ttl: Int,
        val uris: List<String>? = null,
        val expiresAt: Long? = null,
        val mode: String? = null
    )

    private val httpClient = HttpClient(Android) {
        install(ContentNegotiation) { json(credentialJson) }
    }

    private data class CredentialCacheKey(
        val endpoint: String,
        val admissionToken: String
    )

    private val cachedByEndpointAndAdmissionToken = linkedMapOf<CredentialCacheKey, TurnCredentials>()

    suspend fun getCredentials(
        turnAdmissionToken: String? = null,
        deviceId: String? = null,
        signalingServerOrigin: String? = null
    ): TurnCredentials {
        val tokenKey = turnAdmissionToken?.trim().orEmpty()
        require(tokenKey.isNotEmpty()) { "turn credential admission token is required" }
        val endpoint = turnCredentialEndpoint(signalingServerOrigin)
        val cacheKey = CredentialCacheKey(endpoint, tokenKey)
        cachedByEndpointAndAdmissionToken[cacheKey]?.takeIf { it.isValid() }?.let { return it }

        val fresh = fetchFromServer(endpoint, tokenKey, deviceId)

        cachedByEndpointAndAdmissionToken[cacheKey] = fresh
        return fresh
    }

    private suspend fun fetchFromServer(
        endpoint: String,
        turnAdmissionToken: String,
        deviceId: String?
    ): TurnCredentials {
        val response = httpClient.get(endpoint) {
            header(HttpHeaders.Accept, "application/json")
            header(HttpHeaders.UserAgent, SignalServerClient.defaultUserAgent())
            header("X-API-Key", SkyBridgeServerConfig.clientApiKey)
            header("X-SkyBridge-Turn-Admission", turnAdmissionToken)
            deviceId?.trim()?.takeIf { it.isNotEmpty() }?.let {
                header("X-Device-Id", it)
            }
        }
        val payload = response.bodyAsText()
        if (!response.status.isSuccess()) {
            throw IllegalStateException(
                "turn credential request failed (${response.status.value})"
            )
        }
        return decodeServerCredentials(payload)
    }

    internal companion object {
        private val credentialJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

        internal fun decodeServerCredentials(
            payload: String,
            nowMillis: Long = System.currentTimeMillis()
        ): TurnCredentials {
            val resp = credentialJson.decodeFromString<ServerResponse>(payload)
            val username = requireCredentialField(resp.username, "username")
            val password = requireTurnCredential(resp.password, resp.credential)
            require(resp.ttl > 0) { "turn credential response ttl must be positive" }

            val uris = preferredTurnUris(serverUris = resp.uris.orEmpty())
            require(uris.isNotEmpty()) { "turn credential response did not include any TURN URI" }

            val expiresAt = resp.expiresAt
                ?.takeIf { it > 0L }
                ?.let { raw ->
                    if (raw >= 1_000_000_000_000L) raw else raw * 1000L
                }
                ?: (nowMillis + resp.ttl.toLong() * 1000L)
            require(expiresAt > nowMillis) { "turn credential response is already expired" }

            return TurnCredentials(
                username = username,
                password = password,
                ttl = resp.ttl,
                uris = uris,
                expiresAtMillis = expiresAt
            )
        }

        internal fun turnCredentialEndpoint(signalingServerOrigin: String?): String {
            val rawOrigin = signalingServerOrigin?.trim()?.takeIf { it.isNotEmpty() }
                ?: return SkyBridgeServerConfig.turnCredentialEndpoint()
            val canonicalOrigin = CurrentPathOriginPolicy.canonicalOrigin(rawOrigin)
            return "$canonicalOrigin/api/turn/credentials"
        }

        private fun requireTurnCredential(password: String?, credential: String?): String {
            val hasPassword = password != null
            val hasCredential = credential != null
            require(hasPassword || hasCredential) {
                "turn credential response missing password"
            }
            if (hasPassword && hasCredential) {
                val passwordValue = requireCredentialField(checkNotNull(password), "password")
                val credentialValue = requireCredentialField(checkNotNull(credential), "credential")
                require(passwordValue == credentialValue) {
                    "turn credential response password and credential fields disagree"
                }
                return passwordValue
            }
            return if (hasPassword) {
                requireCredentialField(checkNotNull(password), "password")
            } else {
                requireCredentialField(checkNotNull(credential), "credential")
            }
        }

        private fun requireCredentialField(value: String, fieldName: String): String {
            val trimmed = value.trim()
            require(trimmed.isNotEmpty()) { "turn credential response missing $fieldName" }
            require(trimmed == value) { "turn credential response $fieldName contains surrounding whitespace" }
            return value
        }

        private fun preferredTurnUris(serverUris: List<String>): List<String> {
            val effective = normalizeTurnUris(serverUris)
            return effective.sortedWith(
                compareBy<String> { turnPriority(it) }
                    .thenBy { effective.indexOf(it) }
            )
        }

        private fun normalizeTurnUris(uris: List<String>): List<String> {
            val seen = linkedSetOf<String>()
            return uris.mapNotNull { raw ->
                val normalized = raw.trim()
                if (normalized.isEmpty()) {
                    null
                } else {
                    val lower = normalized.lowercase()
                    if (!lower.startsWith("turn:") && !lower.startsWith("turns:")) {
                        null
                    } else if (!seen.add(lower)) {
                        null
                    } else {
                        normalized
                    }
                }
            }
        }

        private fun turnPriority(uri: String): Int {
            val lower = uri.lowercase()
            return when {
                lower.startsWith("turns:") -> 0
                "transport=tcp" in lower -> 1
                else -> 2
            }
        }
    }
}
