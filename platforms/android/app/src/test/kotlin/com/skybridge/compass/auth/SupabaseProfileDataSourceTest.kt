package com.skybridge.compass.auth

import com.skybridge.compass.android.data.SupabaseConfig
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpResponseData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.Url
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SupabaseProfileDataSourceTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val config = SupabaseConfig(
        url = "https://test.supabase.co",
        anonKey = "anon-key"
    )

    @Test
    fun fetchesCanonicalProfileUsingAccessTokenWithoutSdkUserHint() = runTest {
        val paths = mutableListOf<String>()
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                paths += path
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "alice@example.com",
                          "phone": "+15550001000",
                          "user_metadata": {
                            "display_name": "Alice Metadata",
                            "avatar_url": "https://metadata.example/avatar.png",
                            "nebula_id": "NEBULA-2026-ABCDEF123456"
                          },
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> ok(
                        """
                        [
                          {
                            "email": "alice@example.com",
                            "full_name": "Alice Profile",
                            "custom_user_id": "alice",
                            "avatar_url": "https://profile.example/avatar.png"
                          }
                        ]
                        """.trimIndent()
                    )
                    "/rest/v1/profiles" -> ok("[]")
                    "/rest/v1/users" -> ok("[]")
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = null)

        assertEquals("auth-user", profile.id)
        assertEquals("Alice Profile", profile.displayName)
        assertEquals("alice@example.com", profile.email)
        assertEquals("+15550001000", profile.phone)
        assertEquals("https://profile.example/avatar.png", profile.avatarUrl)
        assertEquals("NEBULA-2026-ABCDEF123456", profile.nebulaId)
        assertTrue(paths.contains("/auth/v1/user"))
    }

    @Test
    fun doesNotUseSupabaseUuidAsNebulaIdWhenRemoteNebulaIdIsMissing() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "7f7f7f7f-0000-4000-8000-000000000000",
                          "email": "missing-nebula@example.com",
                          "user_metadata": {},
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> ok("[]")
                    "/rest/v1/profiles" -> ok("[]")
                    "/rest/v1/users" -> ok("[]")
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = null)

        assertEquals("7f7f7f7f-0000-4000-8000-000000000000", profile.id)
        assertEquals("missing-nebula@example.com", profile.displayName)
        assertNull(profile.nebulaId)
    }

    @Test
    fun usesUserProfilesCustomUserIdOnlyAsLegacyNebulaIdFallback() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "custom-nebula@example.com",
                          "user_metadata": {},
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> ok(
                        """
                        [
                          {
                            "email": "custom-nebula@example.com",
                            "custom_user_id": "NEBULA-2026-ABCDEF654321",
                            "avatar_url": "storage/v1/object/public/avatars/auth-user.png"
                          }
                        ]
                        """.trimIndent()
                    )
                    "/rest/v1/profiles" -> ok("[]")
                    "/rest/v1/users" -> ok("[]")
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = "auth-user")

        assertEquals("custom-nebula@example.com", profile.displayName)
        assertEquals("NEBULA-2026-ABCDEF654321", profile.nebulaId)
        assertEquals(
            "https://test.supabase.co/storage/v1/object/public/avatars/auth-user.png",
            profile.avatarUrl
        )
    }

    @Test
    fun postgrestFiltersEncodeAuthUserIdAsSingleQueryParameter() = runTest {
        val injectedUserId = "auth-user&select=evil"
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "$injectedUserId",
                          "email": "encoded@example.com",
                          "user_metadata": {
                            "nebula_id": "NEBULA-2026-ENCODED12345"
                          },
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> {
                        assertSingleFilterQuery(
                            path = path,
                            query = query,
                            column = "id",
                            value = "eq.$injectedUserId",
                            expectedSelect = "email,full_name,nebula_id,custom_user_id,avatar_url"
                        )
                        ok("[]")
                    }
                    "/rest/v1/profiles" -> {
                        val column = legacyProfileFilterColumn(path, query)
                        assertSingleFilterQuery(
                            path = path,
                            query = query,
                            column = column,
                            value = "eq.$injectedUserId",
                            expectedSelect = "username,display_name,full_name,phone_number,nebula_id,avatar_url"
                        )
                        ok("[]")
                    }
                    "/rest/v1/users" -> ok("[]")
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = null)

        assertEquals(injectedUserId, profile.id)
        assertEquals("NEBULA-2026-ENCODED12345", profile.nebulaId)
    }

    @Test
    fun prefersCanonicalUserProfilesNebulaIdOverCustomUserIdFallback() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "projected-nebula@example.com",
                          "user_metadata": {},
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> {
                        assertSingleFilterQuery(
                            path = path,
                            query = query,
                            column = "id",
                            value = "eq.auth-user",
                            expectedSelect = "email,full_name,nebula_id,custom_user_id,avatar_url"
                        )
                        ok(
                            """
                            [
                              {
                                "email": "projected-nebula@example.com",
                                "full_name": "Projected Profile",
                                "nebula_id": "NEBULA-2026-PROFILE12345",
                                "custom_user_id": "NEBULA-2026-CUSTOM123456"
                              }
                            ]
                            """.trimIndent()
                        )
                    }
                    "/rest/v1/profiles" -> ok("[]")
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = "auth-user")

        assertEquals("Projected Profile", profile.displayName)
        assertEquals("NEBULA-2026-PROFILE12345", profile.nebulaId)
    }

    @Test
    fun dropsUnsafeAvatarUrlsBeforeTheyReachUi() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "unsafe-avatar@example.com",
                          "user_metadata": {
                            "avatar_url": "http://metadata.example/avatar.png",
                            "nebula_id": "NEBULA-2026-ABCDEF123456"
                          },
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> ok("[]")
                    "/rest/v1/profiles" -> ok("[]")
                    "/rest/v1/users" -> ok("[]")
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = "auth-user")

        assertNull(profile.avatarUrl)
    }

    @Test
    fun ignoresProviderSubjectFieldsAsNebulaId() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "oidc@example.com",
                          "user_metadata": {},
                          "identities": [
                            {
                              "provider": "oidc",
                              "identity_data": {
                                "id": "provider-subject",
                                "sub": "7f7f7f7f-0000-4000-8000-000000000000"
                              }
                            }
                          ]
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> ok("[]")
                    "/rest/v1/profiles" -> ok("[]")
                    "/rest/v1/users" -> ok("[]")
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = null)

        assertNull(profile.nebulaId)
    }

    @Test
    fun rejectsMalformedNebulaIdValues() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "bad-nebula@example.com",
                          "user_metadata": {
                            "nebula_id": "not-a-nebula-id"
                          },
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> ok("[]")
                    "/rest/v1/profiles" -> ok("[]")
                    "/rest/v1/users" -> ok("[]")
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = null)

        assertNull(profile.nebulaId)
    }

    @Test
    fun ignoresMissingLegacyUsersTableWhenNebulaIdIsUnavailable() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "missing-users-table@example.com",
                          "user_metadata": {},
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> ok(
                        """
                        [
                          {
                            "email": "missing-users-table@example.com",
                            "full_name": "Projection Without Nebula"
                          }
                        ]
                        """.trimIndent()
                    )
                    "/rest/v1/profiles" -> ok("[]")
                    "/rest/v1/users" -> respond(
                        content = """{"code":"PGRST205","message":"Could not find the table public.users"}""",
                        status = HttpStatusCode.NotFound,
                        headers = jsonHeaders
                    )
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = "auth-user")

        assertEquals("Projection Without Nebula", profile.displayName)
        assertNull(profile.nebulaId)
    }

    @Test
    fun ignoresLegacyProfilesMissingColumnWhenCanonicalProjectionIsPresent() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "canonical@example.com",
                          "user_metadata": {},
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> ok(
                        """
                        [
                          {
                            "email": "canonical@example.com",
                            "full_name": "Canonical Profile",
                            "nebula_id": "NEBULA-2026-CANONICAL123"
                          }
                        ]
                        """.trimIndent()
                    )
                    "/rest/v1/profiles" -> respond(
                        content = """{"code":"42703","message":"column profiles.avatar_url does not exist"}""",
                        status = HttpStatusCode.BadRequest,
                        headers = jsonHeaders
                    )
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = "auth-user")

        assertEquals("Canonical Profile", profile.displayName)
        assertEquals("NEBULA-2026-CANONICAL123", profile.nebulaId)
    }

    @Test
    fun throwsWhenCanonicalProfileProjectionIsForbidden() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "alice@example.com",
                          "user_metadata": {},
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> respond(
                        content = """{"message":"permission denied"}""",
                        status = HttpStatusCode.Forbidden,
                        headers = jsonHeaders
                    )
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val error = runCatching {
            dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = null)
        }.exceptionOrNull()

        assertTrue(error is SupabaseProfileException)
        assertEquals(SupabaseProfileException.Kind.HttpStatus, (error as SupabaseProfileException).kind)
        assertTrue(error.message.orEmpty().contains("user_profiles"))
    }

    @Test
    fun throwsWhenCanonicalProjectionSchemaIsMissingARequiredColumn() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "alice@example.com",
                          "user_metadata": {},
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> respond(
                        content = """{"code":"42703","message":"column user_profiles.nebula_id does not exist"}""",
                        status = HttpStatusCode.BadRequest,
                        headers = jsonHeaders
                    )
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val error = runCatching {
            dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = null)
        }.exceptionOrNull()

        assertTrue(error is SupabaseProfileException)
        assertEquals(SupabaseProfileException.Kind.HttpStatus, (error as SupabaseProfileException).kind)
        assertTrue(error.message.orEmpty().contains("user_profiles"))
    }

    @Test
    fun usesLegacyProfilesWhenCanonicalProjectionHasNoRow() = runTest {
        val dataSource = SupabaseProfileDataSource(
            httpClient = mockClient { path, query ->
                when (path) {
                    "/auth/v1/user" -> ok(
                        """
                        {
                          "id": "auth-user",
                          "email": "legacy@example.com",
                          "user_metadata": {},
                          "identities": []
                        }
                        """.trimIndent()
                    )
                    "/rest/v1/user_profiles" -> ok("[]")
                    "/rest/v1/profiles" -> if (query.contains("id=eq.auth-user")) {
                        ok(
                            """
                            [
                              {
                                "display_name": "Legacy Profile",
                                "phone_number": "+15550009999",
                                "avatar_url": "/storage/v1/object/public/avatars/auth-user.jpg",
                                "nebula_id": "NEBULA-2026-ZYXWVU987654"
                              }
                            ]
                            """.trimIndent()
                        )
                    } else {
                        ok("[]")
                    }
                    else -> unexpected(path, query)
                }
            },
            json = json
        )

        val profile = dataSource.fetchCurrentProfile(config, "token", sessionUserIdHint = "auth-user")

        assertEquals("Legacy Profile", profile.displayName)
        assertEquals("+15550009999", profile.phone)
        assertEquals(
            "https://test.supabase.co/storage/v1/object/public/avatars/auth-user.jpg",
            profile.avatarUrl
        )
        assertEquals("NEBULA-2026-ZYXWVU987654", profile.nebulaId)
    }

    private fun mockClient(
        handler: suspend MockRequestHandleScope.(path: String, query: String) -> HttpResponseData
    ): HttpClient {
        return HttpClient(
            MockEngine { request ->
                assertEquals("Bearer token", request.headers[HttpHeaders.Authorization])
                assertEquals("anon-key", request.headers["apikey"])
                handler(request.url.encodedPath, request.url.encodedQuery)
            }
        )
    }

    private fun MockRequestHandleScope.ok(content: String) = respond(
        content = content,
        status = HttpStatusCode.OK,
        headers = jsonHeaders
    )

    private fun MockRequestHandleScope.unexpected(path: String, query: String) = respond(
        content = """{"message":"unexpected request: $path?$query"}""",
        status = HttpStatusCode.InternalServerError,
        headers = jsonHeaders
    )

    private fun assertSingleFilterQuery(
        path: String,
        query: String,
        column: String,
        value: String,
        expectedSelect: String
    ) {
        val parameters = Url("https://test.supabase.co$path?$query").parameters
        assertEquals(value, parameters[column])
        assertEquals(listOf(expectedSelect), parameters.getAll("select"))
        assertEquals("1", parameters["limit"])
    }

    private fun legacyProfileFilterColumn(path: String, query: String): String {
        val parameters = Url("https://test.supabase.co$path?$query").parameters
        return when {
            parameters["id"] != null -> "id"
            parameters["user_id"] != null -> "user_id"
            else -> error("expected id or user_id profile filter")
        }
    }

    private companion object {
        val jsonHeaders = headersOf(HttpHeaders.ContentType, "application/json")
    }
}
