package com.skybridge.compass.android.data

import org.junit.Assert.assertEquals
import org.junit.Test

class SupabaseProjectOriginTest {
    @Test
    fun canonicalizesExactHttpsOrigin() {
        assertEquals(
            "https://project.supabase.co",
            canonicalSupabaseProjectOrigin(" HTTPS://PROJECT.SUPABASE.CO:443/ ")
        )
        assertEquals(
            "https://supabase.internal.example:8443",
            canonicalSupabaseProjectOrigin("https://Supabase.Internal.Example:8443")
        )
    }

    @Test
    fun rejectsOriginsThatCanRedirectOrSplitAuthority() {
        listOf(
            "http://project.supabase.co",
            "https://project.supabase.co@evil.example",
            "https://project.supabase.co/auth/v1",
            "https://project.supabase.co?redirect=https://evil.example",
            "https://project.supabase.co#fragment",
            "https:project.supabase.co",
            "project.supabase.co",
            ""
        ).forEach { candidate ->
            assertThrows<IllegalArgumentException>(candidate) {
                canonicalSupabaseProjectOrigin(candidate)
            }
        }
    }

    private inline fun <reified T : Throwable> assertThrows(
        candidate: String,
        block: () -> Unit
    ): T {
        return try {
            block()
            throw AssertionError("Expected ${T::class.java.simpleName} for $candidate")
        } catch (error: Throwable) {
            if (error is T) error else throw error
        }
    }
}
