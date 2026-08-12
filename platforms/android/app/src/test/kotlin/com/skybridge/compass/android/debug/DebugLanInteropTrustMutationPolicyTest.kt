package com.skybridge.compass.android.debug

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DebugLanInteropTrustMutationPolicyTest {
    @Test
    fun formalRunWithoutMutation_isAcceptanceEligible() {
        val decision = DebugLanInteropTrustMutationPolicy.authorize(
            allowDiagnosticTrustInjection = false,
            allowTrustOnFirstUse = false,
            hasPeerKemInput = false,
            hasPrePairingRequest = false
        )

        assertFalse(decision.mutationRequested)
        assertTrue(decision.acceptanceEligible)
    }

    @Test(expected = IllegalArgumentException::class)
    fun peerKemInjectionWithoutDiagnosticIntent_isRejected() {
        DebugLanInteropTrustMutationPolicy.authorize(
            allowDiagnosticTrustInjection = false,
            allowTrustOnFirstUse = false,
            hasPeerKemInput = true,
            hasPrePairingRequest = false
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun automaticPairingWithoutDiagnosticIntent_isRejected() {
        DebugLanInteropTrustMutationPolicy.authorize(
            allowDiagnosticTrustInjection = false,
            allowTrustOnFirstUse = false,
            hasPeerKemInput = false,
            hasPrePairingRequest = true
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun automaticPairingWithDiagnosticIntent_isStillRejected() {
        DebugLanInteropTrustMutationPolicy.authorize(
            allowDiagnosticTrustInjection = true,
            allowTrustOnFirstUse = false,
            hasPeerKemInput = false,
            hasPrePairingRequest = true
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun trustOnFirstUseWithoutEphemeralDiagnosticContext_isRejected() {
        DebugLanInteropTrustMutationPolicy.authorize(
            allowDiagnosticTrustInjection = false,
            allowTrustOnFirstUse = true,
            hasPeerKemInput = false,
            hasPrePairingRequest = false
        )
    }

    @Test
    fun explicitDiagnosticMutation_isNeverAcceptanceEvidence() {
        val decision = DebugLanInteropTrustMutationPolicy.authorize(
            allowDiagnosticTrustInjection = true,
            allowTrustOnFirstUse = false,
            hasPeerKemInput = true,
            hasPrePairingRequest = false
        )

        assertTrue(decision.mutationRequested)
        assertFalse(decision.acceptanceEligible)
    }

    @Test
    fun existingProductTrustModeRequiresNoMutationAndAnIdentityLookupCandidate() {
        val decision = DebugLanInteropTrustMutationPolicy.authorize(
            allowDiagnosticTrustInjection = false,
            allowTrustOnFirstUse = false,
            hasPeerKemInput = false,
            hasPrePairingRequest = false,
            requireExistingProductTrust = true,
            hasExpectedDeviceId = true
        )

        assertFalse(decision.mutationRequested)
        assertTrue(decision.acceptanceEligible)
    }

    @Test(expected = IllegalArgumentException::class)
    fun existingProductTrustModeRejectsMissingLookupCandidate() {
        DebugLanInteropTrustMutationPolicy.authorize(
            allowDiagnosticTrustInjection = false,
            allowTrustOnFirstUse = false,
            hasPeerKemInput = false,
            hasPrePairingRequest = false,
            requireExistingProductTrust = true,
            hasExpectedDeviceId = false
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun existingProductTrustModeRejectsDiagnosticInjection() {
        DebugLanInteropTrustMutationPolicy.authorize(
            allowDiagnosticTrustInjection = true,
            allowTrustOnFirstUse = false,
            hasPeerKemInput = false,
            hasPrePairingRequest = false,
            requireExistingProductTrust = true,
            hasExpectedDeviceId = true
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun existingProductTrustModeRejectsTofu() {
        DebugLanInteropTrustMutationPolicy.authorize(
            allowDiagnosticTrustInjection = false,
            allowTrustOnFirstUse = true,
            hasPeerKemInput = false,
            hasPrePairingRequest = false,
            requireExistingProductTrust = true,
            hasExpectedDeviceId = true
        )
    }

    @Test
    fun runScopedStatusNameIsDeterministicAndNonceBound() {
        val nonceA = "A".repeat(32)
        val nonceB = "B".repeat(32)
        val runRefA = DebugLanInteropRunScope.runRef(nonceA)

        assertTrue(runRefA.matches(Regex("^[0-9a-f]{64}$")))
        assertEquals(
            "debug-lan-interop-smoke-status-$runRefA.log",
            DebugLanInteropRunScope.statusFileName(nonceA)
        )
        assertNotEquals(
            DebugLanInteropRunScope.statusFileName(nonceA),
            DebugLanInteropRunScope.statusFileName(nonceB)
        )
    }

    @Test
    fun stagedNonceMustBeCanonicalAndConstantTimeEqual() {
        val expected = "C".repeat(32)

        assertTrue(
            DebugLanInteropRunScope.matchesStagedNonce(
                expected,
                expected.toByteArray(Charsets.UTF_8)
            )
        )
        assertFalse(
            DebugLanInteropRunScope.matchesStagedNonce(
                "D".repeat(32),
                expected.toByteArray(Charsets.UTF_8)
            )
        )
        assertFalse(
            DebugLanInteropRunScope.matchesStagedNonce(
                "short",
                expected.toByteArray(Charsets.UTF_8)
            )
        )
    }
}
