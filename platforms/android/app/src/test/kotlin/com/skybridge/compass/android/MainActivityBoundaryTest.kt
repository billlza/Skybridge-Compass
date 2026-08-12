package com.skybridge.compass.android

import com.skybridge.compass.android.ui.navigation.Screen
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MainActivityBoundaryTest {
    @Test
    fun debugNavigationAcceptsOnlyKnownStaticRoutes() {
        assertEquals(
            Screen.Settings.route,
            resolveDebugNavigationRoute(Screen.Settings.route)
        )
        assertNull(resolveDebugNavigationRoute("security/incoming_transfer_review/forged"))
        assertNull(resolveDebugNavigationRoute("settings/../remote_control"))
        assertNull(resolveDebugNavigationRoute(""))
    }

    @Test
    fun rememberLoginReadReturnsAnExplicitPreference() = runTest {
        assertEquals(
            true,
            readRememberLoginPreference({ true }) {
                throw AssertionError("unexpected preference read failure", it)
            }
        )
        assertEquals(
            false,
            readRememberLoginPreference({ false }) {
                throw AssertionError("unexpected preference read failure", it)
            }
        )
    }

    @Test
    fun rememberLoginReadFailureIsReportedAndDoesNotBecomeFalse() = runTest {
        var reported = false
        val result = readRememberLoginPreference(
            read = { throw IllegalStateException("corrupt preferences") },
            onFailure = { reported = true }
        )

        assertNull(result)
        assertTrue(reported)
    }

    @Test
    fun rememberLoginReadPreservesCoroutineCancellation() {
        var reported = false
        assertThrows(CancellationException::class.java) {
            runTest {
                readRememberLoginPreference(
                    read = { throw CancellationException("cancelled") },
                    onFailure = { reported = true }
                )
            }
        }
        assertFalse(reported)
    }
}
