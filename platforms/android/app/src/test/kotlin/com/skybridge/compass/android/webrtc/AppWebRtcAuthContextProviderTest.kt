package com.skybridge.compass.android.webrtc

import com.skybridge.compass.auth.AuthSessionSnapshot
import java.util.Base64
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AppWebRtcAuthContextProviderTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun usesActiveRepositorySnapshotWithoutRequiringPersistedSession() {
        val accessToken = token("""{"sub":"user-1","app_metadata":{"tenant_id":"tenant-1"}}""")
        val provider = AppWebRtcAuthContextProvider(
            sessionSnapshotProvider = {
                AuthSessionSnapshot(
                    authority = "https://project.supabase.co",
                    accessToken = accessToken,
                    subject = "user-1",
                    expiresAtEpochMs = 100_000L
                )
            },
            json = json,
            clockMs = { 1_000L }
        )

        val context = provider.current()

        assertEquals(accessToken, context?.bearerToken)
        assertEquals("tenant-1", context?.tenantId)
    }

    @Test
    fun rejectsSnapshotInsideExpirySkewWindow() {
        val provider = AppWebRtcAuthContextProvider(
            sessionSnapshotProvider = {
                AuthSessionSnapshot(
                    authority = "https://project.supabase.co",
                    accessToken = token("""{"sub":"user-1"}"""),
                    subject = "user-1",
                    expiresAtEpochMs = 30_999L
                )
            },
            json = json,
            clockMs = { 1_000L }
        )

        assertNull(provider.current())
    }

    private fun token(payload: String): String {
        val encodedPayload = Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(payload.toByteArray(Charsets.UTF_8))
        return "eyJhbGciOiJub25lIn0.$encodedPayload.signature"
    }
}
