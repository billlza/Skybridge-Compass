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
        val password: String,
        val ttl: Int,
        val uris: List<String>? = null,
        val expiresAt: Long? = null,
        val mode: String? = null
    )

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val httpClient = HttpClient(Android) {
        install(ContentNegotiation) { json(this@TURNCredentialService.json) }
    }

    private val cachedByAdmissionToken = linkedMapOf<String, TurnCredentials>()

    suspend fun getCredentials(
        turnAdmissionToken: String? = null,
        deviceId: String? = null
    ): TurnCredentials {
        val tokenKey = turnAdmissionToken?.trim().orEmpty()
        if (tokenKey.isNotEmpty()) {
            cachedByAdmissionToken[tokenKey]?.takeIf { it.isValid() }?.let { return it }
        }

        val fresh = if (tokenKey.isNotEmpty()) {
            runCatching { fetchFromServer(tokenKey, deviceId) }
                .getOrElse { fallbackCredentials() }
        } else {
            fallbackCredentials()
        }

        if (tokenKey.isNotEmpty()) {
            cachedByAdmissionToken[tokenKey] = fresh
        }
        return fresh
    }

    private suspend fun fetchFromServer(
        turnAdmissionToken: String,
        deviceId: String?
    ): TurnCredentials {
        val url = SkyBridgeServerConfig.turnCredentialEndpoint()
        val response = httpClient.get(url) {
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
                "turn credential request failed (${response.status.value}): $payload"
            )
        }
        val resp = json.decodeFromString<ServerResponse>(payload)

        val expiresAt = resp.expiresAt
            ?.takeIf { it > 0L }
            ?.let { raw ->
                if (raw >= 1_000_000_000_000L) raw else raw * 1000L
            }
            ?: (System.currentTimeMillis() + resp.ttl.toLong() * 1000L)
        return TurnCredentials(
            username = resp.username,
            password = resp.password,
            ttl = resp.ttl,
            uris = preferredTurnUris(
                serverUris = resp.uris.orEmpty(),
                fallbackUris = SkyBridgeServerConfig.turnURLs
            ),
            expiresAtMillis = expiresAt
        )
    }

    private fun fallbackCredentials(): TurnCredentials =
        TurnCredentials(
            username = "",
            password = "",
            ttl = 3600,
            uris = emptyList(),
            expiresAtMillis = System.currentTimeMillis() + 3600_000L
        )

    private fun preferredTurnUris(
        serverUris: List<String>,
        fallbackUris: List<String>
    ): List<String> {
        val effective = normalizeTurnUris(serverUris).ifEmpty {
            normalizeTurnUris(fallbackUris)
        }
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
