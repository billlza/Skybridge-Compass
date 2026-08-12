@file:Suppress("DEPRECATION")

package com.skybridge.compass.android.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import io.github.jan.supabase.auth.user.UserSession
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlin.time.Instant

/**
 * Persist Supabase auth session so users don't need to login again after app restart.
 *
 * Best practice:
 * - DO NOT store password.
 * - Store refresh token (and access token) encrypted, backed by Android Keystore.
 */
@Singleton
class SupabaseSessionStore internal constructor(
    context: Context,
    private val json: Json
) {
    @Inject
    constructor(
        @ApplicationContext context: Context
    ) : this(context, DEFAULT_JSON)

    private val appContext = context.applicationContext

    @Suppress("DEPRECATION")
    private val prefs: SharedPreferences by lazy {
        encryptedSessionPreferences()
    }

    private fun encryptedSessionPreferences(): SharedPreferences {
        return try {
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
            throw IllegalStateException("Encrypted Supabase session storage is unavailable", e)
        }
    }

    fun save(session: UserSession?, authority: String) {
        if (session == null) return
        val encoded = SupabaseSessionEnvelopeCodec.encode(
            json = json,
            session = session,
            authority = authority
        )
        val committed = prefs.edit()
            .putString(KEY_SESSION_JSON, encoded)
            .commit()
        check(committed) {
            "Failed to persist Supabase session"
        }
    }

    fun clear() {
        val committed = prefs.edit()
            .remove(KEY_SESSION_JSON)
            .commit()
        check(committed) {
            "Failed to clear Supabase session"
        }
    }

    fun hasStoredSession(): Boolean = prefs.contains(KEY_SESSION_JSON)

    fun load(expectedAuthority: String): UserSession? {
        val raw = prefs.getString(KEY_SESSION_JSON, null) ?: return null
        return SupabaseSessionEnvelopeCodec.decode(
            json = json,
            raw = raw,
            expectedAuthority = expectedAuthority,
            nowMs = System.currentTimeMillis()
        )
    }

    companion object {
        private const val ENCRYPTED_PREFS_NAME = "sb_supabase_session_encrypted"
        private const val KEY_SESSION_JSON = "session_json"
        private val DEFAULT_JSON = Json { ignoreUnknownKeys = true; explicitNulls = false }
    }
}

@Serializable
internal class StoredSupabaseSession(
    val schemaVersion: Int = 1,
    val authority: String? = null,
    val accessToken: String,
    val refreshToken: String,
    val expiresAtMs: Long,
    val tokenType: String
) {
    override fun toString(): String =
        "StoredSupabaseSession(schemaVersion=$schemaVersion, authority=$authority, tokens=[REDACTED])"
}

internal object SupabaseSessionEnvelopeCodec {
    const val CURRENT_SCHEMA_VERSION = 3
    private const val MAX_ENCODED_BYTES = 256 * 1024

    fun encode(
        json: Json,
        session: UserSession,
        authority: String
    ): String {
        val normalizedAuthority = normalizedAuthority(authority)
        require(session.accessToken.isNotBlank()) { "Supabase access token is empty" }
        require(session.refreshToken.isNotBlank()) { "Supabase refresh token is empty" }
        require(session.tokenType.isNotBlank()) { "Supabase token type is empty" }
        val expiresAtMs = session.expiresAt.toEpochMilliseconds()
        require(expiresAtMs >= 0L) { "Supabase session expiry is invalid" }
        return json.encodeToString(
            StoredSupabaseSession(
                schemaVersion = CURRENT_SCHEMA_VERSION,
                authority = normalizedAuthority,
                accessToken = session.accessToken,
                refreshToken = session.refreshToken,
                expiresAtMs = expiresAtMs,
                tokenType = session.tokenType
            )
        )
    }

    fun decode(
        json: Json,
        raw: String,
        expectedAuthority: String,
        nowMs: Long
    ): UserSession {
        if (raw.toByteArray(Charsets.UTF_8).size > MAX_ENCODED_BYTES) {
            throw SupabaseSessionStoreCorruptionException(
                "Stored Supabase session exceeds the size limit",
                IllegalArgumentException("session envelope too large")
            )
        }
        val stored = try {
            json.decodeFromString(StoredSupabaseSession.serializer(), raw)
        } catch (e: SerializationException) {
            throw SupabaseSessionStoreCorruptionException("Stored Supabase session JSON is invalid", e)
        } catch (e: IllegalArgumentException) {
            throw SupabaseSessionStoreCorruptionException("Stored Supabase session fields are invalid", e)
        }
        val normalizedExpectedAuthority = normalizedAuthority(expectedAuthority)
        if (stored.schemaVersion != CURRENT_SCHEMA_VERSION) {
            throw SupabaseSessionAuthorityMismatchException(
                "Stored Supabase session belongs to a different or legacy authority"
            )
        }
        val normalizedStoredAuthority = try {
            stored.authority?.let(::normalizedAuthority)
        } catch (error: IllegalArgumentException) {
            throw SupabaseSessionStoreCorruptionException(
                "Stored Supabase session authority is invalid",
                error
            )
        }
        if (normalizedStoredAuthority != normalizedExpectedAuthority) {
            throw SupabaseSessionAuthorityMismatchException(
                "Stored Supabase session belongs to a different or legacy authority"
            )
        }
        if (
            stored.accessToken.isBlank() ||
            stored.refreshToken.isBlank() ||
            stored.tokenType.isBlank() ||
            stored.expiresAtMs < 0
        ) {
            throw SupabaseSessionStoreCorruptionException(
                "Stored Supabase session fields are invalid",
                IllegalArgumentException("invalid session envelope")
            )
        }
        val expiresInSec = ((stored.expiresAtMs - nowMs) / 1000L).coerceAtLeast(0L)
        return UserSession(
            accessToken = stored.accessToken,
            refreshToken = stored.refreshToken,
            expiresIn = expiresInSec,
            tokenType = stored.tokenType,
            user = null,
            expiresAt = Instant.fromEpochMilliseconds(stored.expiresAtMs)
        )
    }

    private fun normalizedAuthority(raw: String): String {
        val normalized = raw.trim().trimEnd('/')
        require(normalized.isNotEmpty()) { "Supabase session authority is empty" }
        return normalized
    }
}

class SupabaseSessionStoreCorruptionException(
    message: String,
    cause: Throwable
) : IllegalStateException(message, cause)

class SupabaseSessionAuthorityMismatchException(
    message: String
) : IllegalStateException(message)
