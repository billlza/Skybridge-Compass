package com.skybridge.compass.auth

import com.skybridge.compass.android.data.SupabaseConfig
import com.skybridge.compass.shared.account.AccountStore
import com.skybridge.compass.shared.account.NebulaId
import com.skybridge.compass.supabase.SupabasePostgrestUrls
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.http.HttpHeaders
import io.ktor.http.isSuccess
import java.net.URI
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

class SupabaseProfileException(
    val kind: Kind,
    message: String,
    cause: Throwable? = null
) : RuntimeException(message, cause) {
    enum class Kind {
        Unauthenticated,
        HttpStatus,
        InvalidResponse,
        SessionUserMismatch
    }
}

/**
 * Reads the cross-platform account projection from Supabase.
 *
 * Source order intentionally mirrors the mac/iOS contract:
 * - user identity: `/auth/v1/user` using the active access token.
 * - avatar: `user_profiles.avatar_url` first, then auth metadata, then legacy `profiles.avatar_url`.
 * - Nebula ID: auth metadata / identities first, then `user_profiles.nebula_id`,
 *   then legacy `profiles.nebula_id`, then `users.nebula_id`.
 *
 * Missing optional legacy tables/rows are not treated as fatal. Auth failures, RLS failures, network
 * failures and invalid JSON remain explicit errors so the UI cannot mistake them for "no profile".
 */
@Singleton
class SupabaseProfileDataSource @Inject constructor(
    private val httpClient: HttpClient,
    private val json: Json
) {
    suspend fun fetchCurrentProfile(
        config: SupabaseConfig,
        accessToken: String,
        sessionUserIdHint: String?
    ): AccountStore.AccountProfile {
        if (accessToken.isBlank()) {
            throw SupabaseProfileException(
                kind = SupabaseProfileException.Kind.Unauthenticated,
                message = "Supabase profile sync requires an active access token"
            )
        }

        val authUser = fetchAuthUser(config, accessToken)
        val userId = authUser.stringOrNull("id")
            ?: authUser.stringOrNull("sub")
            ?: throw SupabaseProfileException(
                kind = SupabaseProfileException.Kind.InvalidResponse,
                message = "Supabase /auth/v1/user response did not include a user id"
            )
        val trimmedHint = sessionUserIdHint?.trim()?.takeIf { it.isNotEmpty() }
        if (trimmedHint != null && trimmedHint != userId) {
            throw SupabaseProfileException(
                kind = SupabaseProfileException.Kind.SessionUserMismatch,
                message = "Supabase session user does not match /auth/v1/user"
            )
        }

        val authMetadata = authUser.objectOrNull("user_metadata")
        val identityData = preferredIdentityData(authUser)
        val canonicalProfile = fetchOptionalFirstRow(
            config = config,
            accessToken = accessToken,
            table = "user_profiles",
            select = "email,full_name,nebula_id,custom_user_id,avatar_url",
            eqColumn = "id",
            eqValue = userId,
            allowMissingRelation = true,
            allowMissingColumns = false
        )
        val legacyProfile = fetchOptionalFirstRow(
            config = config,
            accessToken = accessToken,
            table = "profiles",
            select = "username,display_name,full_name,phone_number,nebula_id,avatar_url",
            eqColumn = "id",
            eqValue = userId,
            allowMissingRelation = true,
            allowMissingColumns = true
        ) ?: fetchOptionalFirstRow(
            config = config,
            accessToken = accessToken,
            table = "profiles",
            select = "username,display_name,full_name,phone_number,nebula_id,avatar_url",
            eqColumn = "user_id",
            eqValue = userId,
            allowMissingRelation = true,
            allowMissingColumns = true
        )

        val canonicalCustomUserId = canonicalProfile?.stringOrNull("custom_user_id")
        val displayName = canonicalProfile?.stringOrNull("full_name")
            ?: canonicalCustomUserId?.takeUnless { normalizedNebulaId(it) != null }
            ?: authMetadata?.firstNonBlank("display_name", "full_name", "name", "preferred_username")
            ?: identityData?.firstNonBlank("display_name", "full_name", "name", "preferred_username")
            ?: legacyProfile?.firstNonBlank("display_name", "full_name", "username")
            ?: authUser.stringOrNull("email")
            ?: authUser.stringOrNull("phone")
            ?: userId

        val metadataAvatar = authMetadata?.firstNonBlank("avatar_url", "avatarUrl", "avatar", "picture")
            ?: identityData?.firstNonBlank("avatar_url", "avatarUrl", "avatar", "picture", "image_url")
        val avatarUrl = normalizeRemoteAssetUrl(
            canonicalProfile?.stringOrNull("avatar_url")
                ?: metadataAvatar
                ?: legacyProfile?.stringOrNull("avatar_url"),
            config.url
        )

        val authNebulaId = authMetadata?.firstNonBlank("nebula_id", "nebulaId")
            ?: identityData?.firstNonBlank("nebula_id", "nebulaId")
        val canonicalNebulaId = canonicalProfile?.firstNonBlank("nebula_id", "nebulaId")
        val legacyNebulaId = legacyProfile?.firstNonBlank("nebula_id", "nebulaId")
        val nebulaId = normalizedNebulaId(authNebulaId)
            ?: normalizedNebulaId(canonicalNebulaId)
            ?: normalizedNebulaId(legacyNebulaId)
            ?: normalizedNebulaId(fetchNebulaIdFromUsersTable(config, accessToken, userId))
            ?: normalizedNebulaId(canonicalCustomUserId)

        return AccountStore.AccountProfile(
            id = userId,
            displayName = displayName,
            email = authUser.stringOrNull("email") ?: canonicalProfile?.stringOrNull("email"),
            phone = authUser.stringOrNull("phone") ?: legacyProfile?.stringOrNull("phone_number"),
            avatarUrl = avatarUrl,
            nebulaId = nebulaId
        )
    }

    private suspend fun fetchAuthUser(
        config: SupabaseConfig,
        accessToken: String
    ): JsonObject {
        val url = "${config.url.trimEnd('/')}/auth/v1/user"
        val response = httpClient.get(url) {
            headers {
                append(HttpHeaders.Authorization, "Bearer $accessToken")
                append("apikey", config.anonKey)
            }
        }
        val bodyText: String = response.body()
        if (!response.status.isSuccess()) {
            throw SupabaseProfileException(
                kind = SupabaseProfileException.Kind.HttpStatus,
                message = "Supabase /auth/v1/user failed with HTTP ${response.status.value}"
            )
        }
        return parseJsonObject(bodyText, "Supabase /auth/v1/user")
    }

    private suspend fun fetchOptionalFirstRow(
        config: SupabaseConfig,
        accessToken: String,
        table: String,
        select: String,
        eqColumn: String,
        eqValue: String,
        allowMissingRelation: Boolean,
        allowMissingColumns: Boolean
    ): JsonObject? {
        val url = SupabasePostgrestUrls.table(
            baseUrl = config.url,
            table = table,
            query = mapOf(
                eqColumn to "eq.$eqValue",
                "select" to select,
                "limit" to "1"
            )
        )
        val response = httpClient.get(url) {
            headers {
                append(HttpHeaders.Authorization, "Bearer $accessToken")
                append("apikey", config.anonKey)
                append(HttpHeaders.Accept, "application/json")
            }
        }
        val bodyText: String = response.body()
        if (!response.status.isSuccess()) {
            if (allowMissingRelation && isPostgrestMissingRelation(response.status.value, bodyText)) {
                return null
            }
            if (allowMissingColumns && isPostgrestMissingColumn(bodyText)) {
                return null
            }
            throw SupabaseProfileException(
                kind = SupabaseProfileException.Kind.HttpStatus,
                message = "Supabase profile query failed for $table with HTTP ${response.status.value}"
            )
        }
        val rows = runCatching { json.parseToJsonElement(bodyText).jsonArray }.getOrElse { error ->
            throw SupabaseProfileException(
                kind = SupabaseProfileException.Kind.InvalidResponse,
                message = "Supabase profile query returned invalid JSON for $table",
                cause = error
            )
        }
        return rows.firstOrNull()?.let { row ->
            row as? JsonObject ?: throw SupabaseProfileException(
                kind = SupabaseProfileException.Kind.InvalidResponse,
                message = "Supabase profile query returned a non-object row for $table"
            )
        }
    }

    private suspend fun fetchNebulaIdFromUsersTable(
        config: SupabaseConfig,
        accessToken: String,
        userId: String
    ): String? {
        return fetchOptionalFirstRow(
            config = config,
            accessToken = accessToken,
            table = "users",
            select = "nebula_id",
            eqColumn = "id",
            eqValue = userId,
            allowMissingRelation = true,
            allowMissingColumns = true
        )?.stringOrNull("nebula_id")
    }

    private fun preferredIdentityData(authUser: JsonObject): JsonObject? {
        val identities = authUser["identities"] as? JsonArray ?: return null
        return identities
            .mapNotNull { it as? JsonObject }
            .firstNotNullOfOrNull { identity ->
                val provider = identity.stringOrNull("provider")?.lowercase()
                val data = identity.objectOrNull("identity_data")
                if (data != null && (provider == "nebula" || provider == "oidc" || provider == "keycloak")) {
                    data
                } else {
                    null
                }
            }
    }

    private fun parseJsonObject(bodyText: String, source: String): JsonObject {
        return runCatching { json.parseToJsonElement(bodyText).jsonObject }.getOrElse { error ->
            throw SupabaseProfileException(
                kind = SupabaseProfileException.Kind.InvalidResponse,
                message = "$source returned invalid JSON",
                cause = error
            )
        }
    }

    private fun isPostgrestMissingRelation(statusCode: Int, bodyText: String): Boolean {
        if (statusCode == 404) return true
        return postgrestErrorCode(bodyText) == "PGRST205"
    }

    private fun isPostgrestMissingColumn(bodyText: String): Boolean {
        return when (postgrestErrorCode(bodyText)) {
            "PGRST204", "42703" -> true
            else -> false
        }
    }

    private fun postgrestErrorCode(bodyText: String): String? {
        return runCatching {
            json.parseToJsonElement(bodyText).jsonObject.stringOrNull("code")
        }.getOrNull()
    }

    private fun normalizeRemoteAssetUrl(raw: String?, baseUrl: String): String? {
        val value = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val base = baseUrl.trimEnd('/')
        val candidate = when {
            value.startsWith("https://", ignoreCase = true) -> value
            value.startsWith("/storage/v1/") -> base + value
            value.startsWith("storage/v1/") -> "$base/$value"
            value.startsWith("storage/") -> "$base/$value"
            else -> return null
        }
        return candidate.takeIf { isSafeHttpsAssetUrl(it) }
    }

    private fun isSafeHttpsAssetUrl(raw: String): Boolean {
        val uri = runCatching { URI(raw) }.getOrNull() ?: return false
        return uri.scheme.equals("https", ignoreCase = true) &&
            !uri.host.isNullOrBlank() &&
            uri.userInfo == null &&
            uri.rawFragment == null
    }

    private fun normalizedNebulaId(raw: String?): String? {
        return NebulaId.parseOrNull(raw)?.value
    }
}

private fun JsonObject.objectOrNull(key: String): JsonObject? = this[key] as? JsonObject

private fun JsonObject.stringOrNull(key: String): String? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    return primitive.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
}

private fun JsonObject.firstNonBlank(vararg keys: String): String? {
    return keys.firstNotNullOfOrNull { key -> stringOrNull(key) }
}
