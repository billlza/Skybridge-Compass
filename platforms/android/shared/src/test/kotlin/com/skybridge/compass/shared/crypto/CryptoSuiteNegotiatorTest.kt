package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.CryptoSuite
import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.list
import io.kotest.property.checkAll

class CryptoSuiteNegotiatorTest : FunSpec({
    
    val allSuites = listOf(
        CryptoSuite.ML_KEM_768_ML_DSA_65,
        CryptoSuite.X_WING_ML_DSA,
        CryptoSuite.X25519_ED25519,
        CryptoSuite.P256_ECDSA
    )
    
    fun createSuiteListArb(suites: List<CryptoSuite>, minSize: Int = 1, maxSize: Int = 4): Arb<List<CryptoSuite>> {
        return Arb.list(Arb.element(suites), minSize..maxSize)
    }

    /**
     * **Feature: android-pqc-crypto, Property 13: Suite negotiation selects highest priority common suite**
     * **Validates: Requirements 8.1**
     */
    test("Property 13: Suite negotiation selects highest priority common suite") {
        val suiteListArb = createSuiteListArb(allSuites)
        
        checkAll(100, suiteListArb, suiteListArb) { rawLocal, rawRemote ->
            val localSuites = rawLocal.distinct()
            val remoteSuites = rawRemote.distinct()
            if (localSuites.isEmpty() || remoteSuites.isEmpty()) return@checkAll
            val commonSuites = localSuites.filter { it in remoteSuites }
            if (commonSuites.isNotEmpty()) {
                val result = CryptoSuiteNegotiator.negotiate(localSuites, remoteSuites)
                (result in localSuites) shouldBe true
                (result in remoteSuites) shouldBe true
                val expectedSuite = localSuites.first { it in remoteSuites }
                result shouldBe expectedSuite
            }
        }
    }

    /**
     * **Feature: android-pqc-crypto, Property 14: Suite negotiation fails on disjoint suites**
     * **Validates: Requirements 8.2**
     */
    test("Property 14: Suite negotiation fails on disjoint suites") {
        val pqcSuites = listOf(CryptoSuite.ML_KEM_768_ML_DSA_65, CryptoSuite.X_WING_ML_DSA)
        val classicSuites = listOf(CryptoSuite.X25519_ED25519, CryptoSuite.P256_ECDSA)
        val pqcListArb = createSuiteListArb(pqcSuites, 1, 2)
        val classicListArb = createSuiteListArb(classicSuites, 1, 2)
        
        checkAll(100, pqcListArb, classicListArb) { rawLocal, rawRemote ->
            val localSuites = rawLocal.distinct()
            val remoteSuites = rawRemote.distinct()
            if (localSuites.isEmpty() || remoteSuites.isEmpty()) return@checkAll
            val commonSuites = localSuites.filter { it in remoteSuites }
            commonSuites.isEmpty() shouldBe true
            val exception = shouldThrow<CryptoNegotiationException> {
                CryptoSuiteNegotiator.negotiate(localSuites, remoteSuites)
            }
            exception.localSuites shouldBe localSuites
            exception.remoteSuites shouldBe remoteSuites
        }
    }

    test("Order of remote suites does not affect negotiation result") {
        val suiteListArb = createSuiteListArb(allSuites, 2, 4)
        checkAll(100, suiteListArb) { rawSuites ->
            val suites = rawSuites.distinct()
            if (suites.size < 2) return@checkAll
            val result1 = CryptoSuiteNegotiator.negotiate(suites, suites)
            val result2 = CryptoSuiteNegotiator.negotiate(suites, suites.reversed())
            result1 shouldBe result2
            result1 shouldBe suites.first()
        }
    }

    test("canNegotiate is consistent with negotiate") {
        val suiteListArb = createSuiteListArb(allSuites)
        checkAll(100, suiteListArb, suiteListArb) { rawLocal, rawRemote ->
            val localSuites = rawLocal.distinct()
            val remoteSuites = rawRemote.distinct()
            if (localSuites.isEmpty() || remoteSuites.isEmpty()) return@checkAll
            val canNegotiate = CryptoSuiteNegotiator.canNegotiate(localSuites, remoteSuites)
            if (canNegotiate) {
                val result = CryptoSuiteNegotiator.negotiate(localSuites, remoteSuites)
                (result in localSuites) shouldBe true
                (result in remoteSuites) shouldBe true
            } else {
                shouldThrow<CryptoNegotiationException> {
                    CryptoSuiteNegotiator.negotiate(localSuites, remoteSuites)
                }
            }
        }
    }
})
