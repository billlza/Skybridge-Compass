package com.skybridge.compass.shared.p2p

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the R4.4 handshake-failure taxonomy.
 *
 * These prove the two properties task 9.1 is responsible for:
 *  1. Every failure condition classifies into **exactly one** category.
 *  2. The categories are **disjoint** — no two distinct conditions collapse into an
 *     ambiguous/shared classification, and the enum/sealed-type shapes stay aligned.
 *
 * Wiring the concrete throw-sites to this type is tasks 9.3/9.4/9.5 and is out of
 * scope here.
 */
class HandshakeFailureTest {

    /** The exact ten categories mandated by R4.4, in the design's order. */
    private val expectedCategories = listOf(
        HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE,
        HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY,
        HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE,
        HandshakeFailureCategory.SIGNATURE_VERIFICATION_FAILED,
        HandshakeFailureCategory.KEY_CONFIRMATION_FAILED,
        HandshakeFailureCategory.REPLAY_DETECTED,
        HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH,
        HandshakeFailureCategory.SUITE_SIGNATURE_MISMATCH,
        HandshakeFailureCategory.TIMEOUT,
        HandshakeFailureCategory.NETWORK_UNREACHABLE
    )

    // ---- Category set: closed, complete, disjoint ----

    @Test
    fun categorySetIsExactlyTheTenR44Categories() {
        assertEquals(
            "R4.4 mandates exactly ten mutually-exclusive categories",
            10,
            HandshakeFailureCategory.entries.size
        )
        assertEquals(
            "category set must match the R4.4 enumeration",
            expectedCategories.toSet(),
            HandshakeFailureCategory.entries.toSet()
        )
    }

    @Test
    fun diagnosticCodesAreUniquePerCategory() {
        val codes = HandshakeFailureCategory.entries.map { it.diagnosticCode }
        assertEquals(
            "each category must have a distinct diagnostic code (disjointness)",
            codes.size,
            codes.toSet().size
        )
        assertTrue("diagnostic codes must be non-blank", codes.all { it.isNotBlank() })
    }

    // ---- Classifier: each condition lands in exactly one category ----

    @Test
    fun directConditionsMapToTheirMatchingCategory() {
        val cases: List<Pair<HandshakeFailureCondition, HandshakeFailureCategory>> = listOf(
            HandshakeFailureCondition.PeerKemPublicKeyUnavailable() to
                HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE,
            HandshakeFailureCondition.SuiteIntersectionEmpty() to
                HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY,
            HandshakeFailureCondition.LocalPqcUnavailable() to
                HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE,
            HandshakeFailureCondition.SignatureVerificationFailed() to
                HandshakeFailureCategory.SIGNATURE_VERIFICATION_FAILED,
            HandshakeFailureCondition.KeyConfirmationFailed() to
                HandshakeFailureCategory.KEY_CONFIRMATION_FAILED,
            HandshakeFailureCondition.ReplayDetected() to
                HandshakeFailureCategory.REPLAY_DETECTED,
            HandshakeFailureCondition.IdentityFingerprintMismatch() to
                HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH,
            HandshakeFailureCondition.SuiteSignatureMismatch() to
                HandshakeFailureCategory.SUITE_SIGNATURE_MISMATCH,
            HandshakeFailureCondition.Timeout() to
                HandshakeFailureCategory.TIMEOUT,
            HandshakeFailureCondition.NetworkUnreachable() to
                HandshakeFailureCategory.NETWORK_UNREACHABLE
        )

        for ((condition, expected) in cases) {
            val failure = HandshakeFailureClassifier.classify(condition)
            assertEquals(
                "condition ${condition::class.simpleName} must classify to $expected",
                expected,
                failure.category
            )
        }
    }

    @Test
    fun everyDirectConditionCoversAllTenCategoriesExactlyOnce() {
        val directConditions: List<HandshakeFailureCondition> = listOf(
            HandshakeFailureCondition.PeerKemPublicKeyUnavailable(),
            HandshakeFailureCondition.SuiteIntersectionEmpty(),
            HandshakeFailureCondition.LocalPqcUnavailable(),
            HandshakeFailureCondition.SignatureVerificationFailed(),
            HandshakeFailureCondition.KeyConfirmationFailed(),
            HandshakeFailureCondition.ReplayDetected(),
            HandshakeFailureCondition.IdentityFingerprintMismatch(),
            HandshakeFailureCondition.SuiteSignatureMismatch(),
            HandshakeFailureCondition.Timeout(),
            HandshakeFailureCondition.NetworkUnreachable()
        )
        val producedCategories = directConditions.map { HandshakeFailureClassifier.classify(it).category }
        assertEquals(
            "the direct conditions must cover all ten categories exactly once (bijective)",
            expectedCategories.toSet(),
            producedCategories.toSet()
        )
        assertEquals(
            "no two direct conditions may collapse to the same category",
            producedCategories.size,
            producedCategories.toSet().size
        )
    }

    // ---- R4.12: bootstrap rekey failure resolves to exactly one of two categories ----

    @Test
    fun bootstrapRekeyLocalPqcCauseClassifiesAsLocalPqcUnavailable() {
        val failure = HandshakeFailureClassifier.classify(
            HandshakeFailureCondition.BootstrapRekeyFailed(
                cause = BootstrapRekeyCause.LOCAL_PQC_UNAVAILABLE
            )
        )
        assertEquals(HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE, failure.category)
        assertTrue(failure is HandshakeFailure.LocalPqcUnavailable)
    }

    @Test
    fun bootstrapRekeySuiteCauseClassifiesAsSuiteIntersectionEmpty() {
        val failure = HandshakeFailureClassifier.classify(
            HandshakeFailureCondition.BootstrapRekeyFailed(
                cause = BootstrapRekeyCause.SUITE_INTERSECTION_EMPTY
            )
        )
        assertEquals(HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY, failure.category)
        assertTrue(failure is HandshakeFailure.SuiteIntersectionEmpty)
    }

    @Test
    fun bootstrapRekeyNeverIntroducesAnEleventhCategory() {
        for (cause in BootstrapRekeyCause.entries) {
            val failure = HandshakeFailureClassifier.classify(
                HandshakeFailureCondition.BootstrapRekeyFailed(cause = cause)
            )
            assertTrue(
                "bootstrap rekey must land in an existing R4.4 category",
                failure.category in expectedCategories
            )
        }
    }

    // ---- Classification is deterministic and detail-independent ----

    @Test
    fun classificationIsDeterministicAndIndependentOfDetail() {
        val a = HandshakeFailureClassifier.classify(
            HandshakeFailureCondition.Timeout(detail = "phase=handshake")
        )
        val b = HandshakeFailureClassifier.classify(
            HandshakeFailureCondition.Timeout(detail = "phase=ice")
        )
        assertEquals(
            "detail text must not change the classified category",
            a.category,
            b.category
        )
        assertEquals(HandshakeFailureCategory.TIMEOUT, a.category)
    }

    @Test
    fun failureDiagnosticCodeMirrorsCategory() {
        val failure = HandshakeFailureClassifier.classify(
            HandshakeFailureCondition.ReplayDetected()
        )
        assertNotNull(failure.diagnosticCode)
        assertEquals(failure.category.diagnosticCode, failure.diagnosticCode)
    }
}
