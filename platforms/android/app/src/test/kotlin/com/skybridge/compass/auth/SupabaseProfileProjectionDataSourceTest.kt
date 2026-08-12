package com.skybridge.compass.auth

import com.skybridge.compass.android.data.SupabaseConfig
import com.skybridge.compass.shared.account.AccountStore
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpResponseData
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.Url
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlin.text.Charsets
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SupabaseProfileProjectionDataSourceTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val config = SupabaseConfig(
        url = "https://test.supabase.co",
        anonKey = "anon-key"
    )

    @Test
    fun upsertsCanonicalUserProfilesProjection() = runTest {
        var payloadText: String? = null
        val dataSource = SupabaseProfileProjectionDataSource(
            httpClient = HttpClient(
                MockEngine { request ->
                    assertEquals(HttpMethod.Post, request.method)
                    assertEquals("/rest/v1/user_profiles", request.url.encodedPath)
                    assertEquals("id", request.url.parameters["on_conflict"])
                    assertEquals("Bearer token", request.headers[HttpHeaders.Authorization])
                    assertEquals("anon-key", request.headers["apikey"])
                    assertEquals(
                        listOf("resolution=merge-duplicates", "return=minimal"),
                        request.headers.getAll("Prefer")
                    )
                    payloadText = request.bodyAsText()
                    respond(content = "", status = HttpStatusCode.Created, headers = jsonHeaders)
                }
            )
        )

        dataSource.upsertUserProfile(
            config = config,
            accessToken = "token",
            profile = AccountStore.AccountProfile(
                id = "auth-user",
                displayName = "Alice Profile",
                email = "alice@example.com",
                avatarUrl = "https://profile.example/avatar.png",
                nebulaId = "NEBULA-2026-ABCDEF123456"
            )
        )

        val payload = json.parseToJsonElement(requireNotNull(payloadText)).jsonObject
        assertEquals("auth-user", payload["id"]?.jsonPrimitive?.content)
        assertEquals("alice@example.com", payload["email"]?.jsonPrimitive?.content)
        assertEquals("Alice Profile", payload["full_name"]?.jsonPrimitive?.content)
        assertEquals("https://profile.example/avatar.png", payload["avatar_url"]?.jsonPrimitive?.content)
        assertEquals("NEBULA-2026-ABCDEF123456", payload["nebula_id"]?.jsonPrimitive?.content)
        assertFalse(payload.containsKey("custom_user_id"))
    }

    @Test
    fun omitsSignedAvatarAndInvalidNebulaIdFromPersistentProjection() = runTest {
        var payloadText: String? = null
        val dataSource = SupabaseProfileProjectionDataSource(
            httpClient = HttpClient(
                MockEngine { request ->
                    payloadText = request.bodyAsText()
                    respond(content = "", status = HttpStatusCode.NoContent, headers = jsonHeaders)
                }
            )
        )

        dataSource.upsertUserProfile(
            config = config,
            accessToken = "token",
            profile = AccountStore.AccountProfile(
                id = "auth-user",
                displayName = "Alice Profile",
                email = "alice@example.com",
                avatarUrl = "https://test.supabase.co/storage/v1/object/sign/avatars/auth-user.png?token=secret",
                nebulaId = "not-a-nebula-id"
            )
        )

        val payload = json.parseToJsonElement(requireNotNull(payloadText)).jsonObject
        assertFalse(payload.containsKey("avatar_url"))
        assertFalse(payload.containsKey("nebula_id"))
    }

    @Test
    fun throwsWhenCanonicalProjectionUpsertFails() = runTest {
        val dataSource = SupabaseProfileProjectionDataSource(
            httpClient = HttpClient(
                MockEngine {
                    respond(
                        content = """{"message":"permission denied"}""",
                        status = HttpStatusCode.Forbidden,
                        headers = jsonHeaders
                    )
                }
            )
        )

        val error = runCatching {
            dataSource.upsertUserProfile(
                config = config,
                accessToken = "token",
                profile = AccountStore.AccountProfile(
                    id = "auth-user",
                    displayName = "Alice Profile"
                )
            )
        }.exceptionOrNull()

        assertTrue(error is SupabaseProfileProjectionException)
        assertTrue(error?.message.orEmpty().contains("user_profiles"))
        assertTrue(error?.message.orEmpty().contains("403"))
    }

    private fun HttpRequestData.bodyAsText(): String {
        val content = body
        return when (content) {
            is TextContent -> content.text
            is OutgoingContent.ByteArrayContent -> content.bytes().toString(Charsets.UTF_8)
            else -> error("unexpected outgoing content type: ${content::class}")
        }
    }

    private companion object {
        val jsonHeaders = headersOf(HttpHeaders.ContentType, "application/json")
    }
}
