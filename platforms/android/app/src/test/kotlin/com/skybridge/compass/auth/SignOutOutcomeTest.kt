package com.skybridge.compass.auth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class SignOutOutcomeTest {
    @Test
    fun preservesRemoteFailureWhenClientCleanupAlsoFails() {
        val outcome = combineSignOutOutcomes(
            remoteOutcome = SignOutOutcome.LocalOnlyAfterRemoteFailure("timeout"),
            clientCleanupFailure = "IllegalStateException"
        )

        assertEquals(
            SignOutOutcome.LocalOnlyAfterRemoteAndClientCleanupFailure(
                remoteReason = "timeout",
                clientCleanupReason = "IllegalStateException"
            ),
            outcome
        )
    }

    @Test
    fun reportsClientCleanupFailureAfterSuccessfulRemoteRevocation() {
        val outcome = combineSignOutOutcomes(
            remoteOutcome = SignOutOutcome.RevokedRemotely,
            clientCleanupFailure = "IllegalStateException"
        )

        assertEquals(
            SignOutOutcome.LocalOnlyAfterClientCleanupFailure("IllegalStateException"),
            outcome
        )
    }

    @Test
    fun preservesRemoteOutcomeWhenClientCleanupSucceeds() {
        val remoteOutcome = SignOutOutcome.LocalOnlyAfterRemoteFailure("network")

        assertSame(remoteOutcome, combineSignOutOutcomes(remoteOutcome, null))
    }
}
