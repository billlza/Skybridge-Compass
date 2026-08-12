package com.skybridge.compass.auth

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NebulaOAuthBaseUrlTest {
    @Test
    fun acceptsExactHttpsOrigin() {
        assertTrue(isValidNebulaOAuthBaseUrl("https://auth.nebula.example"))
        assertTrue(isValidNebulaOAuthBaseUrl("https://auth.nebula.example:8443/"))
    }

    @Test
    fun rejectsInsecureOrNonOriginOAuthAuthorities() {
        listOf(
            "http://auth.nebula.example",
            "https://user@auth.nebula.example",
            "https://auth.nebula.example/oauth",
            "https://auth.nebula.example?redirect=evil",
            "https://auth.nebula.example#fragment",
            "not-a-url"
        ).forEach { candidate ->
            assertFalse(candidate, isValidNebulaOAuthBaseUrl(candidate))
        }
    }
}
