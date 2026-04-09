@file:Suppress("DEPRECATION")

package com.skybridge.compass.core.webrtc

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Mirrors the app-layer Supabase session persistence format so core WebRTC
 * flows can reuse the authenticated user session without depending on app code.
 */
class CurrentPathAuthSessionStore(
    context: Context,
    private val json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false }
) {
    private val appContext = context.applicationContext

    private val prefs: SharedPreferences by lazy {
        try {
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            EncryptedSharedPreferences.create(
                appContext,
                ENCRYPTED_PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (err: Exception) {
            Log.w(TAG, "Failed to open encrypted auth session prefs, falling back", err)
            appContext.getSharedPreferences(FALLBACK_PREFS_NAME, Context.MODE_PRIVATE)
        }
    }

    @Serializable
    private data class StoredSession(
        val accessToken: String,
        val refreshToken: String,
        val expiresAtMs: Long,
        val tokenType: String
    )

    fun loadUserAuthContext(): SignalServerClient.UserAuthContext? {
        val overrideToken = System.getProperty("skybridge.smoke.bearerToken")
            ?.trim()
            .orEmpty()
        val overrideTenantId = System.getProperty("skybridge.smoke.tenantId")
            ?.trim()
            .orEmpty()
        if (overrideToken.isNotEmpty() && overrideTenantId.isNotEmpty()) {
            return SignalServerClient.UserAuthContext(
                bearerToken = overrideToken,
                tenantId = overrideTenantId
            )
        }

        val raw = prefs.getString(KEY_SESSION_JSON, null) ?: return null
        val stored = runCatching {
            json.decodeFromString(StoredSession.serializer(), raw)
        }.getOrNull() ?: return null

        val accessToken = stored.accessToken.trim()
        if (accessToken.isEmpty()) {
            return null
        }

        if (stored.expiresAtMs > 0L && stored.expiresAtMs <= System.currentTimeMillis() + 30_000L) {
            return null
        }

        val tenantId = deriveTenantIdentifier(accessToken)
        if (tenantId.isEmpty()) {
            return null
        }

        return SignalServerClient.UserAuthContext(
            bearerToken = accessToken,
            tenantId = tenantId
        )
    }

    companion object {
        private const val TAG = "CurrentPathAuthStore"
        private const val ENCRYPTED_PREFS_NAME = "sb_supabase_session_encrypted"
        private const val FALLBACK_PREFS_NAME = "sb_supabase_session"
        private const val KEY_SESSION_JSON = "session_json"

        fun deriveTenantIdentifier(accessToken: String): String {
            val payload = decodeJwtPayload(accessToken) ?: return ""
            val appMetadata = payload["app_metadata"]?.jsonObject
            val userMetadata = payload["user_metadata"]?.jsonObject
            val candidates = listOf(
                appMetadata.stringOrNull("tenant_id"),
                appMetadata.stringOrNull("tenantId"),
                appMetadata.stringOrNull("org_id"),
                appMetadata.stringOrNull("workspace_id"),
                userMetadata.stringOrNull("tenant_id"),
                userMetadata.stringOrNull("tenantId"),
                userMetadata.stringOrNull("org_id"),
                userMetadata.stringOrNull("workspace_id"),
                payload.stringOrNull("tenant_id"),
                payload.stringOrNull("tenantId"),
                payload.stringOrNull("sub")
            )
            return candidates.firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()
        }

        private fun decodeJwtPayload(accessToken: String): JsonObject? {
            val payload = accessToken.split('.').getOrNull(1) ?: return null
            var normalized = payload.replace('-', '+').replace('_', '/')
            val remainder = normalized.length % 4
            if (remainder != 0) {
                normalized += "=".repeat(4 - remainder)
            }
            return runCatching {
                val bytes = android.util.Base64.decode(normalized, android.util.Base64.DEFAULT)
                jsonFromString(bytes.decodeToString()).jsonObject
            }.getOrNull()
        }

        private fun jsonFromString(raw: String) = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
        }.parseToJsonElement(raw)

        private fun JsonObject?.stringOrNull(key: String): String? =
            this?.get(key)?.jsonPrimitive?.contentOrNull
    }
}

private fun JsonObject.stringOrNull(key: String): String? =
    this[key]?.jsonPrimitive?.contentOrNull
