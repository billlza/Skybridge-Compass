package com.skybridge.compass.auth

import io.github.jan.supabase.auth.user.UserSession
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

class SupabaseAuthSessionContractException(message: String) : IllegalStateException(message)

internal object SupabaseAuthSessionContract {
    private const val MAX_TOKEN_BYTES = 64 * 1024
    private const val MAX_ACCESS_TOKEN_LIFETIME_SECONDS = 31_536_000L
    private const val EXPIRY_CLOCK_TOLERANCE_MS = 60_000L

    fun parse(response: JsonObject, action: String): UserSession {
        val accessToken = requiredString(response, "access_token", action)
        val refreshToken = requiredString(response, "refresh_token", action)
        val tokenType = requiredString(response, "token_type", action)
        val expiresIn = (response["expires_in"] as? JsonPrimitive)?.longOrNull
            ?: throw SupabaseAuthSessionContractException(
                "$action failed: server returned missing or malformed expires_in"
            )
        val session = UserSession(
            accessToken = accessToken,
            refreshToken = refreshToken,
            expiresIn = expiresIn,
            tokenType = tokenType,
            user = null
        )
        validate(session, action)
        return session
    }

    fun validate(session: UserSession, action: String) {
        requireBoundedToken(session.accessToken, "access_token", action)
        requireBoundedToken(session.refreshToken, "refresh_token", action)
        if (!session.tokenType.equals("bearer", ignoreCase = true)) {
            throw SupabaseAuthSessionContractException(
                "$action failed: server returned unsupported token_type"
            )
        }
        if (session.expiresIn !in 1..MAX_ACCESS_TOKEN_LIFETIME_SECONDS) {
            throw SupabaseAuthSessionContractException(
                "$action failed: server returned out-of-range expires_in"
            )
        }
        val nowMs = System.currentTimeMillis()
        val maximumExpiryMs = try {
            Math.addExact(
                nowMs,
                Math.addExact(
                    Math.multiplyExact(MAX_ACCESS_TOKEN_LIFETIME_SECONDS, 1_000L),
                    EXPIRY_CLOCK_TOLERANCE_MS
                )
            )
        } catch (error: ArithmeticException) {
            throw SupabaseAuthSessionContractException("$action failed: session expiry overflow")
        }
        val expiresAtMs = session.expiresAt.toEpochMilliseconds()
        if (expiresAtMs <= nowMs || expiresAtMs > maximumExpiryMs) {
            throw SupabaseAuthSessionContractException(
                "$action failed: server returned invalid absolute expiry"
            )
        }
    }

    fun requirePendingVerificationUser(response: JsonObject, action: String) {
        val user = response["user"] as? JsonObject
            ?: throw SupabaseAuthSessionContractException(
                "$action failed: server returned neither a session nor a user"
            )
        requiredString(user, "id", action)
    }

    private fun requiredString(response: JsonObject, field: String, action: String): String {
        val primitive = response[field] as? JsonPrimitive
        val value = primitive
            ?.takeIf { it.isString }
            ?.contentOrNull
            ?.takeIf { it.isNotBlank() && it == it.trim() }
        return value ?: throw SupabaseAuthSessionContractException(
            "$action failed: server returned missing or malformed $field"
        )
    }

    private fun requireBoundedToken(value: String, field: String, action: String) {
        if (value.isBlank() || value.toByteArray(Charsets.UTF_8).size > MAX_TOKEN_BYTES) {
            throw SupabaseAuthSessionContractException(
                "$action failed: server returned invalid $field"
            )
        }
    }
}
