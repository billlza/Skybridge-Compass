package com.skybridge.compass.auth

import com.skybridge.compass.android.data.SupabaseConfig
import com.skybridge.compass.shared.account.AccountStore
import com.skybridge.compass.shared.account.NebulaId
import com.skybridge.compass.supabase.SupabasePostgrestUrls
import io.ktor.client.HttpClient
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.isSuccess
import io.ktor.http.contentType
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class SupabaseProfileProjectionException(
    message: String,
    cause: Throwable? = null
) : RuntimeException(message, cause)

/**
 * Writes the canonical cross-platform account projection used by Android/macOS/iOS.
 */
@Singleton
class SupabaseProfileProjectionDataSource @Inject constructor(
    private val httpClient: HttpClient
) {
    suspend fun upsertUserProfile(
        config: SupabaseConfig,
        accessToken: String,
        profile: AccountStore.AccountProfile
    ) {
        if (accessToken.isBlank()) {
            throw SupabaseProfileProjectionException("user_profiles upsert requires an active access token")
        }

        val url = SupabasePostgrestUrls.table(
            baseUrl = config.url,
            table = "user_profiles",
            query = mapOf("on_conflict" to "id")
        )
        val payload = buildJsonObject {
            put("id", profile.id)
            profile.email?.let { put("email", JsonPrimitive(it)) }
            put("full_name", profile.displayName)
            persistentAvatarUrlOrNull(profile.avatarUrl)?.let { put("avatar_url", JsonPrimitive(it)) }
            NebulaId.parseOrNull(profile.nebulaId)?.value?.let {
                put("nebula_id", JsonPrimitive(it))
            }
        }.toString()

        val response = httpClient.post(url) {
            contentType(ContentType.Application.Json)
            headers {
                append(HttpHeaders.Authorization, "Bearer $accessToken")
                append("apikey", config.anonKey)
                append("Prefer", "resolution=merge-duplicates")
                append("Prefer", "return=minimal")
            }
            setBody(payload)
        }

        if (!response.status.isSuccess()) {
            throw SupabaseProfileProjectionException(
                "user_profiles upsert failed: HTTP ${response.status.value}"
            )
        }
    }

    private fun persistentAvatarUrlOrNull(rawUrl: String?): String? {
        val url = rawUrl?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return if (url.contains("/storage/v1/object/sign/", ignoreCase = true)) null else url
    }

}
