@file:Suppress("DEPRECATION")

package com.skybridge.compass.android.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Persist Supabase auth session so users don't need to login again after app restart.
 *
 * Best practice:
 * - DO NOT store password.
 * - Store refresh token (and access token) encrypted, backed by Android Keystore.
 */
class SupabaseSessionStore(
    context: Context,
    private val json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false }
) {
    private val appContext = context.applicationContext

    @Suppress("DEPRECATION")
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
        } catch (e: Exception) {
            Log.w(TAG, "Failed to create EncryptedSharedPreferences, falling back to regular SharedPreferences", e)
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

    fun save(session: UserSession?) {
        if (session == null) return
        // expiresIn is seconds
        val expiresAtMs = System.currentTimeMillis() + (session.expiresIn.coerceAtLeast(0) * 1000L)
        val stored = StoredSession(
            accessToken = session.accessToken,
            refreshToken = session.refreshToken,
            expiresAtMs = expiresAtMs,
            tokenType = session.tokenType
        )
        runCatching {
            prefs.edit().putString(KEY_SESSION_JSON, json.encodeToString(stored)).apply()
        }.onFailure { e ->
            Log.w(TAG, "Failed to persist session", e)
        }
    }

    fun clear() {
        runCatching { prefs.edit().remove(KEY_SESSION_JSON).apply() }
    }

    fun load(): UserSession? {
        val raw = prefs.getString(KEY_SESSION_JSON, null) ?: return null
        val stored = runCatching { json.decodeFromString(StoredSession.serializer(), raw) }.getOrNull() ?: return null
        val expiresInSec = ((stored.expiresAtMs - System.currentTimeMillis()) / 1000L).coerceAtLeast(0L)
        return UserSession(
            accessToken = stored.accessToken,
            refreshToken = stored.refreshToken,
            expiresIn = expiresInSec,
            tokenType = stored.tokenType,
            user = null
        )
    }

    companion object {
        private const val TAG = "SupabaseSessionStore"
        private const val ENCRYPTED_PREFS_NAME = "sb_supabase_session_encrypted"
        private const val FALLBACK_PREFS_NAME = "sb_supabase_session"
        private const val KEY_SESSION_JSON = "session_json"
    }
}


