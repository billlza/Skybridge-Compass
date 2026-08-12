package com.skybridge.compass.auth

import io.github.jan.supabase.auth.user.UserSession
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

class SupabaseAuthSessionContractTest {
    private val json = Json

    @Test
    fun parsesCompleteSessionWithoutInventingCredentialFields() {
        val session = SupabaseAuthSessionContract.parse(
            response = objectFrom(
                """{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"bearer"}"""
            ),
            action = "test login"
        )

        assertEquals("access", session.accessToken)
        assertEquals("refresh", session.refreshToken)
        assertEquals(3_600L, session.expiresIn)
        assertEquals("bearer", session.tokenType)
    }

    @Test
    fun rejectsMissingRefreshTokenInsteadOfInstallingNonRefreshableSession() {
        assertContractFailure("refresh_token") {
            SupabaseAuthSessionContract.parse(
                response = objectFrom(
                    """{"access_token":"access","expires_in":3600,"token_type":"bearer"}"""
                ),
                action = "test login"
            )
        }
    }

    @Test
    fun rejectsMissingOrMalformedExpiryInsteadOfDefaultingLifetime() {
        listOf(
            """{"access_token":"access","refresh_token":"refresh","token_type":"bearer"}""",
            """{"access_token":"access","refresh_token":"refresh","expires_in":"later","token_type":"bearer"}"""
        ).forEach { raw ->
            assertContractFailure("expires_in") {
                SupabaseAuthSessionContract.parse(objectFrom(raw), "test login")
            }
        }
    }

    @Test
    fun validationIsIdenticalForRememberedAndMemoryOnlyCommitPolicies() {
        listOf(false, true).forEach { rememberLogin ->
            val invalid = UserSession(
                accessToken = "access",
                refreshToken = "",
                expiresIn = 3_600L,
                tokenType = "bearer",
                user = null
            )
            assertContractFailure("refresh_token (remember=$rememberLogin)") {
                SupabaseAuthSessionContract.validate(
                    invalid,
                    "test login remember=$rememberLogin"
                )
            }
        }
    }

    @Test
    fun pendingEmailVerificationRequiresConcreteUserIdentity() {
        SupabaseAuthSessionContract.requirePendingVerificationUser(
            objectFrom("""{"user":{"id":"user-1"}}"""),
            "test registration"
        )

        listOf("{}", """{"user":{}}""").forEach { raw ->
            assertContractFailure("server returned") {
                SupabaseAuthSessionContract.requirePendingVerificationUser(
                    objectFrom(raw),
                    "test registration"
                )
            }
        }
    }

    private fun objectFrom(raw: String) = json.parseToJsonElement(raw).jsonObject

    private fun assertContractFailure(
        expectedMessageToken: String,
        block: () -> Unit
    ) {
        try {
            block()
            throw AssertionError("Expected SupabaseAuthSessionContractException")
        } catch (error: SupabaseAuthSessionContractException) {
            check(error.message?.contains(expectedMessageToken.substringBefore(" (")) == true) {
                "Unexpected error message: ${error.message}"
            }
        }
    }
}
