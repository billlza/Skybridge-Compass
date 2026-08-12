package com.skybridge.compass.android.data.cloud

import com.skybridge.compass.android.data.SupabaseConfig
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.supabase.SupabaseConfigLockedException
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.serialization.json.Json

@OptIn(ExperimentalCoroutinesApi::class)
class CloudUserSettingsSyncManagerTest {

    @Test
    fun authenticatedSyncKeepsPushCollectorAliveAfterPullFailure() = runTest {
        val auth = FakeAuthState()
        val remote = FakeRemoteStore(
            nextPullError = CloudUserSettingsSyncManager.CloudSettingsSyncException(
                stage = "pull",
                detail = "policy violation",
                retryable = false
            )
        )
        val local = FakeLocalStore()
        val manager = CloudUserSettingsSyncManager(
            authState = auth,
            remoteStore = remote,
            localStore = local,
            scope = this
        )

        try {
            manager.start()
            auth.authenticated.value = true
            advanceUntilIdle()

            val failed = manager.syncStatus.value
            assertTrue(failed is CloudUserSettingsSyncManager.SyncStatus.Failed)
            assertEquals("pull", (failed as CloudUserSettingsSyncManager.SyncStatus.Failed).stage)
            assertEquals(1, remote.pullAttempts)

            advanceTimeBy(CloudUserSettingsSyncManager.pullRetryDelayMillis(1))
            advanceUntilIdle()
            assertEquals(1, remote.pullAttempts)

            local.emit(CloudUserSettingsSyncManager.SettingsSnapshot())
            advanceTimeBy(901)
            advanceUntilIdle()

            assertEquals(1, remote.pushedSnapshots.size)
            assertEquals(CloudUserSettingsSyncManager.SyncStatus.Synced, manager.syncStatus.value)
        } finally {
            manager.stop()
            advanceUntilIdle()
        }
    }

    @Test
    fun transientPullFailureRetriesWithoutBlockingPushCollector() = runTest {
        val auth = FakeAuthState()
        val remote = FakeRemoteStore(
            nextPullError = CloudUserSettingsSyncManager.CloudSettingsSyncException("pull", "HTTP 500"),
            nextPullSnapshot = CloudUserSettingsSyncManager.SettingsSnapshot(schemaVersion = 3)
        )
        val local = FakeLocalStore()
        val manager = CloudUserSettingsSyncManager(
            authState = auth,
            remoteStore = remote,
            localStore = local,
            scope = this
        )

        try {
            manager.start()
            auth.authenticated.value = true
            advanceTimeBy(CloudUserSettingsSyncManager.pullRetryDelayMillis(1))
            advanceUntilIdle()

            assertEquals(2, remote.pullAttempts)
            assertEquals(1, local.appliedSnapshots.size)
            assertEquals(3, local.appliedSnapshots.single().schemaVersion)
            assertEquals(CloudUserSettingsSyncManager.SyncStatus.Synced, manager.syncStatus.value)

            local.emit(CloudUserSettingsSyncManager.SettingsSnapshot(schemaVersion = 4))
            advanceTimeBy(901)
            advanceUntilIdle()

            assertEquals(1, remote.pushedSnapshots.size)
        } finally {
            manager.stop()
            advanceUntilIdle()
        }
    }

    @Test
    fun pushFailureDoesNotTerminateFuturePushes() = runTest {
        val auth = FakeAuthState()
        val remote = FakeRemoteStore(nextPushError = RuntimeException("transient push failure"))
        val local = FakeLocalStore()
        val manager = CloudUserSettingsSyncManager(
            authState = auth,
            remoteStore = remote,
            localStore = local,
            scope = this
        )

        try {
            manager.start()
            auth.authenticated.value = true
            advanceUntilIdle()

            local.emit(CloudUserSettingsSyncManager.SettingsSnapshot())
            advanceTimeBy(901)
            advanceUntilIdle()
            val failed = manager.syncStatus.value
            assertTrue(failed is CloudUserSettingsSyncManager.SyncStatus.Failed)
            assertEquals("push", (failed as CloudUserSettingsSyncManager.SyncStatus.Failed).stage)

            local.emit(CloudUserSettingsSyncManager.SettingsSnapshot(schemaVersion = 3))
            advanceTimeBy(901)
            advanceUntilIdle()

            assertEquals(2, remote.pushAttempts)
            assertEquals(1, remote.pushedSnapshots.size)
            assertEquals(CloudUserSettingsSyncManager.SyncStatus.Synced, manager.syncStatus.value)
        } finally {
            manager.stop()
            advanceUntilIdle()
        }
    }

    @Test
    fun stopAndLogoutCancelAuthedSyncWithoutDuplicatingCollectors() = runTest {
        val auth = FakeAuthState()
        val remote = FakeRemoteStore()
        val local = FakeLocalStore()
        val manager = CloudUserSettingsSyncManager(
            authState = auth,
            remoteStore = remote,
            localStore = local,
            scope = this
        )

        try {
            manager.start()
            manager.start()
            auth.authenticated.value = true
            runCurrent()
            assertEquals(1, remote.pullAttempts)

            auth.authenticated.value = false
            advanceUntilIdle()
            local.emit(CloudUserSettingsSyncManager.SettingsSnapshot())
            advanceTimeBy(901)
            advanceUntilIdle()
            assertEquals(0, remote.pushAttempts)

            auth.authenticated.value = true
            advanceUntilIdle()
            assertEquals(2, remote.pullAttempts)

            manager.stop()
            local.emit(CloudUserSettingsSyncManager.SettingsSnapshot(schemaVersion = 4))
            advanceTimeBy(901)
            advanceUntilIdle()
            assertEquals(0, remote.pushAttempts)
        } finally {
            manager.stop()
            advanceUntilIdle()
        }
    }

    @Test
    fun logoutCancelsPendingPullRetry() = runTest {
        val auth = FakeAuthState()
        val remote = FakeRemoteStore(
            nextPullError = CloudUserSettingsSyncManager.CloudSettingsSyncException("pull", "HTTP 500")
        )
        val local = FakeLocalStore()
        val manager = CloudUserSettingsSyncManager(
            authState = auth,
            remoteStore = remote,
            localStore = local,
            scope = this
        )

        try {
            manager.start()
            auth.authenticated.value = true
            runCurrent()
            assertEquals(1, remote.pullAttempts)

            auth.authenticated.value = false
            runCurrent()
            advanceTimeBy(CloudUserSettingsSyncManager.pullRetryDelayMillis(1))
            advanceUntilIdle()

            assertEquals(1, remote.pullAttempts)
            assertTrue(local.appliedSnapshots.isEmpty())
            assertTrue(remote.pushedSnapshots.isEmpty())
        } finally {
            manager.stop()
            advanceUntilIdle()
        }
    }

    @Test
    fun remotePullEncodesUserFilterAndSendsAuthHeaders() = runTest {
        val remote = SupabaseCloudSettingsRemoteStore(
            configProvider = { testSupabaseConfig },
            authState = FakeAuthState(userId = "user&select=evil"),
            httpClient = HttpClient(
                MockEngine { request ->
                    assertEquals(HttpMethod.Get, request.method)
                    assertEquals("/rest/v1/user_settings", request.url.encodedPath)
                    assertEquals("eq.user&select=evil", request.url.parameters["user_id"])
                    assertEquals(
                        listOf("settings_json,updated_at,schema_version"),
                        request.url.parameters.getAll("select")
                    )
                    assertEquals("1", request.url.parameters["limit"])
                    assertEquals("Bearer token", request.headers[HttpHeaders.Authorization])
                    assertEquals("anon-key", request.headers["apikey"])
                    respond(
                        content = """[{"settings_json":{},"schema_version":3}]""",
                        status = HttpStatusCode.OK,
                        headers = jsonHeaders
                    )
                }
            ),
            json = testJson
        )

        val snapshot = remote.pull()

        assertEquals(3, snapshot?.schemaVersion)
    }

    @Test
    fun remotePushUsesStructuredConflictParameterAndPreferHeaders() = runTest {
        val remote = SupabaseCloudSettingsRemoteStore(
            configProvider = { testSupabaseConfig },
            authState = FakeAuthState(),
            httpClient = HttpClient(
                MockEngine { request ->
                    assertEquals(HttpMethod.Post, request.method)
                    assertEquals("/rest/v1/user_settings", request.url.encodedPath)
                    assertEquals("user_id", request.url.parameters["on_conflict"])
                    assertEquals("Bearer token", request.headers[HttpHeaders.Authorization])
                    assertEquals("anon-key", request.headers["apikey"])
                    assertEquals(
                        listOf("resolution=merge-duplicates", "return=minimal"),
                        request.headers.getAll("Prefer")
                    )
                    respond(content = "", status = HttpStatusCode.Created, headers = jsonHeaders)
                }
            ),
            json = testJson
        )

        remote.push(CloudUserSettingsSyncManager.SettingsSnapshot(schemaVersion = 4))
    }

    @Test
    fun remoteStoreReportsConfigTokenAndUserFailuresAsNonRetryable() = runTest {
        val configError = runCatching {
            SupabaseCloudSettingsRemoteStore(
                configProvider = { throw SupabaseConfigLockedException() },
                authState = FakeAuthState(),
                httpClient = HttpClient(MockEngine { error("network should not be reached") }),
                json = testJson
            ).pull()
        }.exceptionOrNull()
        assertTrue(configError is CloudUserSettingsSyncManager.CloudSettingsSyncException)
        assertEquals(false, (configError as CloudUserSettingsSyncManager.CloudSettingsSyncException).retryable)
        assertTrue(configError.message.orEmpty().contains("Supabase config unavailable"))

        val tokenError = runCatching {
            SupabaseCloudSettingsRemoteStore(
                configProvider = { testSupabaseConfig },
                authState = FakeAuthState(accessToken = null),
                httpClient = HttpClient(MockEngine { error("network should not be reached") }),
                json = testJson
            ).pull()
        }.exceptionOrNull()
        assertTrue(tokenError is CloudUserSettingsSyncManager.CloudSettingsSyncException)
        assertEquals(false, (tokenError as CloudUserSettingsSyncManager.CloudSettingsSyncException).retryable)
        assertTrue(tokenError.message.orEmpty().contains("missing Supabase access token"))

        val userError = runCatching {
            SupabaseCloudSettingsRemoteStore(
                configProvider = { testSupabaseConfig },
                authState = FakeAuthState(userId = null),
                httpClient = HttpClient(MockEngine { error("network should not be reached") }),
                json = testJson
            ).pull()
        }.exceptionOrNull()
        assertTrue(userError is CloudUserSettingsSyncManager.CloudSettingsSyncException)
        assertEquals(false, (userError as CloudUserSettingsSyncManager.CloudSettingsSyncException).retryable)
        assertTrue(userError.message.orEmpty().contains("missing authenticated user id"))
    }

    private class FakeAuthState(
        private val accessToken: String? = "token",
        private val userId: String? = "user-id"
    ) : CloudSettingsAuthState {
        override val authenticated = MutableStateFlow(false)
        override fun currentAccessTokenOrNull(): String? = accessToken
        override fun currentUserIdOrNull(): String? = userId
    }

    private class FakeRemoteStore(
        private var nextPullError: Throwable? = null,
        private var nextPullSnapshot: CloudUserSettingsSyncManager.SettingsSnapshot? = null,
        private var nextPushError: Throwable? = null
    ) : CloudSettingsRemoteStore {
        var pullAttempts: Int = 0
            private set
        var pushAttempts: Int = 0
            private set
        val pushedSnapshots = mutableListOf<CloudUserSettingsSyncManager.SettingsSnapshot>()

        override suspend fun pull(): CloudUserSettingsSyncManager.SettingsSnapshot? {
            pullAttempts += 1
            nextPullError?.let { error ->
                nextPullError = null
                throw error
            }
            return nextPullSnapshot.also { nextPullSnapshot = null }
        }

        override suspend fun push(snapshot: CloudUserSettingsSyncManager.SettingsSnapshot) {
            pushAttempts += 1
            nextPushError?.let { error ->
                nextPushError = null
                throw error
            }
            pushedSnapshots += snapshot
        }
    }

    private class FakeLocalStore : CloudSettingsLocalStore {
        private val snapshots = MutableSharedFlow<CloudUserSettingsSyncManager.SettingsSnapshot>(
            extraBufferCapacity = 8
        )

        override fun snapshots(): Flow<CloudUserSettingsSyncManager.SettingsSnapshot> = snapshots
        val appliedSnapshots = mutableListOf<CloudUserSettingsSyncManager.SettingsSnapshot>()

        suspend fun emit(snapshot: CloudUserSettingsSyncManager.SettingsSnapshot) {
            snapshots.emit(snapshot)
        }

        override suspend fun applySnapshotIfDefaults(
            snapshot: CloudUserSettingsSyncManager.SettingsSnapshot,
            securityDefaults: SecuritySettings
        ) {
            appliedSnapshots += snapshot
        }
    }

    private companion object {
        val testJson = Json { ignoreUnknownKeys = true }
        val testSupabaseConfig = SupabaseConfig(
            url = "https://test.supabase.co",
            anonKey = "anon-key"
        )
        val jsonHeaders = headersOf(HttpHeaders.ContentType, "application/json")
    }
}
