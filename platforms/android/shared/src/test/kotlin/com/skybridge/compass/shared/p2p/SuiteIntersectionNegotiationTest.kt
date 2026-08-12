package com.skybridge.compass.shared.p2p

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Task 9.4 — 套件协商交集校验 (suite negotiation intersection).
 *
 * Verifies that suite negotiation is an explicit set intersection of the two sides'
 * declared suite sets:
 *  - an empty intersection is classified as
 *    [HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY] ("no common suite") and the
 *    handshake terminates;
 *  - a non-empty intersection selects the highest-priority *policy-permitted* suite
 *    (Q_PERIAPT > X_WING > PQC > CLASSIC);
 *  - min-tier / requirePqc / allowClassicFallback constraints are still honored exactly
 *    as before.
 *
 * Validates: Requirements 4.3, 4.4
 */
class SuiteIntersectionNegotiationTest {

    private fun policy(
        minimumTierRaw: String,
        requirePqc: Boolean,
        allowClassicFallback: Boolean
    ) = P2PHandshakePolicy(
        requirePqc = requirePqc,
        allowClassicFallback = allowClassicFallback,
        minimumTierRaw = minimumTierRaw,
        requireSecureEnclavePoP = false
    )

    @Test
    fun emptyIntersectionIsClassifiedAndTerminates() {
        // Q_PERIAPT explicitly requested, but the local runtime has no Q_PERIAPT support:
        // the intersection of declared suites is empty → "no common suite".
        val ex = assertThrows(HandshakeNegotiationException::class.java) {
            P2PHandshakeClient.resolveSuitePlanForTesting(
                platformVersion = "Android 17 (API 37)",
                liboqsAvailable = true,
                xWingAvailable = true,
                qPeriaptAvailable = false,
                peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                    qPeriaptPublicKey = ByteArray(1) { 0x10 },
                    xWingPublicKey = ByteArray(1) { 0x11 },
                    mlKem768PublicKey = ByteArray(1) { 0x12 }
                ),
                policy = policy(
                    minimumTierRaw = P2PQPeriaptKem.MINIMUM_TIER_RAW,
                    requirePqc = true,
                    allowClassicFallback = false
                )
            )
        }
        assertEquals(HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY, ex.category)
        // Terminating exception is still an IllegalStateException (unchanged contract).
        assertTrue(ex is IllegalStateException)
    }

    @Test
    fun nonEmptyIntersectionSelectsHighestPrioritySuite() {
        // Intersection = {X_WING, PQC, CLASSIC}; highest-priority allowed is X_WING.
        val plan = P2PHandshakeClient.resolveSuitePlanForTesting(
            platformVersion = "Android 17 (API 37)",
            liboqsAvailable = true,
            xWingAvailable = true,
            peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                xWingPublicKey = ByteArray(1) { 0x21 },
                mlKem768PublicKey = ByteArray(1) { 0x22 }
            ),
            policy = policy(
                minimumTierRaw = "classic",
                requirePqc = false,
                allowClassicFallback = true
            )
        )
        assertEquals(P2PCryptoSuite.X_WING, plan.selectedSuite)
    }

    @Test
    fun minimumTierConstraintSkipsClassicWithinIntersection() {
        // Intersection = {PQC, CLASSIC} (peer offers ML-KEM only). Minimum tier PQC and
        // requirePqc forbid CLASSIC, so PQC is selected rather than the classic member.
        val plan = P2PHandshakeClient.resolveSuitePlanForTesting(
            platformVersion = "Android 17 (API 37)",
            liboqsAvailable = true,
            xWingAvailable = true,
            peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                mlKem768PublicKey = ByteArray(1) { 0x33 }
            ),
            policy = policy(
                minimumTierRaw = "liboqsPQC",
                requirePqc = true,
                allowClassicFallback = false
            )
        )
        assertEquals(P2PCryptoSuite.MLKEM_768, plan.selectedSuite)
    }

    @Test
    fun requirePqcWithoutClassicFallbackRejectsClassicOnlyIntersection() {
        // Peer offers no PQC key shares → intersection = {CLASSIC} only. requirePqc with
        // no classic fallback leaves no policy-permitted member → "no common suite".
        val ex = assertThrows(HandshakeNegotiationException::class.java) {
            P2PHandshakeClient.resolveSuitePlanForTesting(
                platformVersion = "Android 17 (API 37)",
                liboqsAvailable = true,
                xWingAvailable = true,
                peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(),
                policy = policy(
                    minimumTierRaw = "nativePQC",
                    requirePqc = true,
                    allowClassicFallback = false
                )
            )
        }
        assertEquals(HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY, ex.category)
    }

    @Test
    fun classicFallbackAllowedSelectsClassicWithinIntersection() {
        // Intersection = {CLASSIC} and policy permits classic fallback → CLASSIC selected.
        val plan = P2PHandshakeClient.resolveSuitePlanForTesting(
            platformVersion = "Android 17 (API 37)",
            liboqsAvailable = true,
            xWingAvailable = false,
            peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(),
            policy = policy(
                minimumTierRaw = "classic",
                requirePqc = false,
                allowClassicFallback = true
            )
        )
        assertEquals(P2PCryptoSuite.X25519, plan.selectedSuite)
        assertTrue(plan.usedClassicFallback)
    }
}
