package com.skybridge.compass.auth

import java.util.Base64
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SupabaseJwtClaimsTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun extractsSubjectFromJwtPayload() {
        val jwt = token("""{"sub":"auth-user","email":"alice@example.com"}""")

        assertEquals("auth-user", SupabaseJwtClaims.subjectOrNull(json, jwt))
    }

    @Test
    fun extractsTenantIdentifierFromMetadataBeforeSubject() {
        val jwt = token(
            """
            {
              "sub":"auth-user",
              "app_metadata":{"tenant_id":"tenant-app"},
              "user_metadata":{"tenant_id":"tenant-user"}
            }
            """.trimIndent()
        )

        assertEquals("tenant-app", SupabaseJwtClaims.tenantIdentifierOrNull(json, jwt))
    }

    @Test
    fun fallsBackToSubjectWhenTenantMetadataIsMissing() {
        val jwt = token("""{"sub":"auth-user"}""")

        assertEquals("auth-user", SupabaseJwtClaims.tenantIdentifierOrNull(json, jwt))
    }

    @Test
    fun ignoresUserEditableTenantMetadata() {
        val jwt = token(
            """
            {
              "sub":"auth-user",
              "user_metadata":{
                "tenant_id":"attacker-selected-tenant",
                "workspace_id":"attacker-selected-workspace"
              }
            }
            """.trimIndent()
        )

        assertEquals("auth-user", SupabaseJwtClaims.tenantIdentifierOrNull(json, jwt))
    }

    @Test
    fun returnsNullForMalformedJwtOrMissingSubject() {
        assertNull(SupabaseJwtClaims.subjectOrNull(json, "not-a-jwt"))
        assertNull(SupabaseJwtClaims.subjectOrNull(json, token("""{"email":"alice@example.com"}""")))
        assertNull(SupabaseJwtClaims.subjectOrNull(json, token("""{"sub":"   "}""")))
        assertNull(SupabaseJwtClaims.tenantIdentifierOrNull(json, "not-a-jwt"))
    }

    private fun token(payload: String): String {
        val encodedPayload = Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(payload.toByteArray(Charsets.UTF_8))
        return "eyJhbGciOiJub25lIn0.$encodedPayload.signature"
    }
}
