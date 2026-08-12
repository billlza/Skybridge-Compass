package com.skybridge.compass.android.data

import io.github.jan.supabase.auth.user.UserSession
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Instant

class SupabaseSessionEnvelopeCodecTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun roundTripsSessionForMatchingAuthorityWithoutPersistingUserPayload() {
        val session = UserSession(
            accessToken = "access-token",
            refreshToken = "refresh-token",
            expiresIn = 3_600L,
            tokenType = "bearer",
            user = null,
            expiresAt = Instant.fromEpochMilliseconds(3_601_000L)
        )

        val encoded = SupabaseSessionEnvelopeCodec.encode(
            json = json,
            session = session,
            authority = "https://project.supabase.co/"
        )
        val restored = SupabaseSessionEnvelopeCodec.decode(
            json = json,
            raw = encoded,
            expectedAuthority = "https://project.supabase.co",
            nowMs = 2_000L
        )

        assertEquals("access-token", restored.accessToken)
        assertEquals("refresh-token", restored.refreshToken)
        assertEquals(3_599L, restored.expiresIn)
        assertEquals("bearer", restored.tokenType)
        assertNull(restored.user)
        assertEquals(Instant.fromEpochMilliseconds(3_601_000L), restored.expiresAt)
        assertTrue(encoded.contains("\"schemaVersion\":3"))
        assertTrue(encoded.contains("\"authority\":\"https://project.supabase.co\""))
    }

    @Test
    fun rejectsLegacyEnvelopeWithoutAuthorityBinding() {
        val legacy =
            """{"schemaVersion":1,"accessToken":"a","refreshToken":"r","expiresAtMs":3601000,"tokenType":"bearer"}"""

        assertThrows<SupabaseSessionAuthorityMismatchException> {
            SupabaseSessionEnvelopeCodec.decode(
                json = json,
                raw = legacy,
                expectedAuthority = "https://project.supabase.co",
                nowMs = 1_000L
            )
        }
    }

    @Test
    fun rejectsEnvelopeFromDifferentSupabaseAuthority() {
        val encoded = SupabaseSessionEnvelopeCodec.encode(
            json = json,
            session = UserSession(
                accessToken = "a",
                refreshToken = "r",
                expiresIn = 60L,
                tokenType = "bearer",
                user = null,
                expiresAt = Instant.fromEpochMilliseconds(61_000L)
            ),
            authority = "https://first.supabase.co"
        )

        assertThrows<SupabaseSessionAuthorityMismatchException> {
            SupabaseSessionEnvelopeCodec.decode(
                json = json,
                raw = encoded,
                expectedAuthority = "https://second.supabase.co",
                nowMs = 1_000L
            )
        }
    }

    @Test
    fun rejectsBlankRefreshTokenBeforePersistence() {
        assertThrows<IllegalArgumentException> {
            SupabaseSessionEnvelopeCodec.encode(
                json = json,
                session = UserSession(
                    accessToken = "a",
                    refreshToken = "",
                    expiresIn = 60L,
                    tokenType = "bearer",
                    user = null,
                    expiresAt = Instant.fromEpochMilliseconds(61_000L)
                ),
                authority = "https://project.supabase.co"
            )
        }
    }

    @Test
    fun delayedPersistencePreservesAbsoluteExpiry() {
        val absoluteExpiry = Instant.fromEpochMilliseconds(3_601_000L)
        val session = UserSession(
            accessToken = "access-token",
            refreshToken = "refresh-token",
            expiresIn = 3_600L,
            tokenType = "bearer",
            user = null,
            expiresAt = absoluteExpiry
        )

        val encoded = SupabaseSessionEnvelopeCodec.encode(
            json = json,
            session = session,
            authority = "https://project.supabase.co"
        )
        val restored = SupabaseSessionEnvelopeCodec.decode(
            json = json,
            raw = encoded,
            expectedAuthority = "https://project.supabase.co",
            nowMs = 1_801_000L
        )
        val reencoded = SupabaseSessionEnvelopeCodec.encode(
            json = json,
            session = restored,
            authority = "https://project.supabase.co"
        )
        val restoredAgain = SupabaseSessionEnvelopeCodec.decode(
            json = json,
            raw = reencoded,
            expectedAuthority = "https://project.supabase.co",
            nowMs = 2_001_000L
        )

        assertEquals(absoluteExpiry, restored.expiresAt)
        assertEquals(absoluteExpiry, restoredAgain.expiresAt)
        assertEquals(1_600L, restoredAgain.expiresIn)
    }

    @Test
    fun rejectsMalformedStoredAuthorityAsCorruption() {
        val malformed =
            """{"schemaVersion":3,"authority":"   ","accessToken":"a","refreshToken":"r","expiresAtMs":61000,"tokenType":"bearer"}"""

        assertThrows<SupabaseSessionStoreCorruptionException> {
            SupabaseSessionEnvelopeCodec.decode(
                json = json,
                raw = malformed,
                expectedAuthority = "https://project.supabase.co",
                nowMs = 1_000L
            )
        }
    }

    private inline fun <reified T : Throwable> assertThrows(block: () -> Unit): T {
        return try {
            block()
            throw AssertionError("Expected ${T::class.java.simpleName}")
        } catch (error: Throwable) {
            if (error is T) error else throw error
        }
    }
}
