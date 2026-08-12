package com.skybridge.compass.supabase

import io.ktor.http.Url
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SupabasePostgrestUrlsTest {

    @Test
    fun tableEncodesPostgrestFilterValuesAsSingleParameters() {
        val url = SupabasePostgrestUrls.table(
            baseUrl = "https://test.supabase.co/",
            table = "user_settings",
            query = mapOf(
                "user_id" to "eq.user&select=evil",
                "select" to "settings_json,updated_at,schema_version",
                "limit" to "1"
            )
        )

        val parsed = Url(url)
        assertEquals("/rest/v1/user_settings", parsed.encodedPath)
        assertEquals("eq.user&select=evil", parsed.parameters["user_id"])
        assertEquals(listOf("settings_json,updated_at,schema_version"), parsed.parameters.getAll("select"))
        assertEquals("1", parsed.parameters["limit"])
    }

    @Test
    fun tableRejectsInvalidIdentifiersBeforeBuildingUrl() {
        assertThrows(IllegalArgumentException::class.java) {
            SupabasePostgrestUrls.table(
                baseUrl = "https://test.supabase.co",
                table = "../users",
                query = mapOf("id" to "eq.user")
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            SupabasePostgrestUrls.table(
                baseUrl = "https://test.supabase.co",
                table = "users",
                query = mapOf("id.or.true" to "eq.user")
            )
        }
    }
}
