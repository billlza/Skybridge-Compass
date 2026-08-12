package com.skybridge.compass.shared.p2p

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit coverage for the R4.5 / R4.6 / R4.13 handshake-failure response invariants:
 * no failure downgrades, no failure switches to an unauthenticated path, and a
 * fingerprint mismatch (plus the other authentication-integrity categories) never
 * auto-reconnects.
 */
class HandshakeFailureResponseTest {

    @Test
    fun noFailureCategoryEverPermitsAutomaticSuiteDowngrade() {
        // R4.5 / R4.6: a failure of ANY category must not trigger a suite downgrade.
        for (category in HandshakeFailureCategory.entries) {
            assertFalse(
                "$category must never trigger an automatic suite downgrade",
                HandshakeFailureResponse.permitsAutomaticSuiteDowngrade(category)
            )
        }
    }

    @Test
    fun noFailureCategoryEverPermitsUnauthenticatedPathSwitch() {
        // R4.5: a failure of ANY category must not switch to an unauthenticated path.
        for (category in HandshakeFailureCategory.entries) {
            assertFalse(
                "$category must never switch to an unauthenticated path",
                HandshakeFailureResponse.permitsUnauthenticatedPathSwitch(category)
            )
        }
    }

    @Test
    fun fingerprintMismatchNeverPermitsAutomaticReconnect() {
        // R4.13: identity fingerprint mismatch aborts immediately, no auto-reconnect.
        assertFalse(
            HandshakeFailureResponse.permitsAutomaticReconnect(
                HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH
            )
        )
    }

    @Test
    fun authenticationIntegrityFailuresNeverPermitAutomaticReconnect() {
        val terminal = listOf(
            HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH,
            HandshakeFailureCategory.SIGNATURE_VERIFICATION_FAILED,
            HandshakeFailureCategory.KEY_CONFIRMATION_FAILED,
            HandshakeFailureCategory.REPLAY_DETECTED,
            HandshakeFailureCategory.SUITE_SIGNATURE_MISMATCH,
            HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY,
            HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE,
            HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE
        )
        for (category in terminal) {
            assertFalse(
                "$category must not be reconnect-eligible",
                HandshakeFailureResponse.permitsAutomaticReconnect(category)
            )
        }
    }

    @Test
    fun onlyTransientTransportFailuresPermitAutomaticReconnect() {
        // Timeout / network-unreachable are the only recoverable categories (R4.7).
        assertTrue(
            HandshakeFailureResponse.permitsAutomaticReconnect(HandshakeFailureCategory.TIMEOUT)
        )
        assertTrue(
            HandshakeFailureResponse.permitsAutomaticReconnect(
                HandshakeFailureCategory.NETWORK_UNREACHABLE
            )
        )
    }
}
