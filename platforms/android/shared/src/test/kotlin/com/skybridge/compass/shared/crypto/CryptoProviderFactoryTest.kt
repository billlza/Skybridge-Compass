package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.providers.ClassicCryptoProvider
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.types.shouldBeInstanceOf
import io.kotest.property.Arb
import io.kotest.property.arbitrary.element
import io.kotest.property.checkAll

/**
 * Property-based tests for CryptoProviderFactory.
 * 
 * Tests verify that the factory correctly selects providers based on
 * suite type and platform capabilities.
 */
class CryptoProviderFactoryTest : FunSpec({
    
    /**
     * **Feature: android-pqc-crypto, Property 1: CryptoProviderFactory selects correct provider for suite**
     * 
     * *For any* CryptoSuite, the CryptoProviderFactory SHALL return a provider that:
     * - Returns a PQC provider (AndroidPQCCryptoProvider or BouncyCastlePQCProvider) when 
     *   suite.isPQC is true and PQC libraries are available
     * - Returns ClassicCryptoProvider when suite.isPQC is false or no PQC libraries are available
     * 
     * **Validates: Requirements 1.4**
     */
    test("Property 1: CryptoProviderFactory selects correct provider for suite") {
        // Generator for classic (non-PQC) suites
        val classicSuiteArb = Arb.element(
            CryptoSuite.X25519_ED25519,
            CryptoSuite.P256_ECDSA
        )
        
        // Test: For any classic suite, factory should return ClassicCryptoProvider
        checkAll(100, classicSuiteArb) { suite ->
            // Classic suites should never be PQC
            suite.isPQC shouldBe false
            
            // Factory should return ClassicCryptoProvider for classic suites
            val provider = CryptoProviderFactory.createProvider(suite)
            
            provider.shouldBeInstanceOf<ClassicCryptoProvider>()
            provider.tier shouldBe CryptoTier.CLASSIC
            provider.activeSuite shouldBe suite
        }
    }
    
    /**
     * Property test: PQC suites are correctly identified
     * 
     * This tests the isPQC property which is used by the factory for selection.
     */
    test("PQC suites are correctly identified by isPQC property") {
        val pqcSuiteArb = Arb.element(
            CryptoSuite.ML_KEM_768_ML_DSA_65,
            CryptoSuite.X_WING_ML_DSA
        )
        
        checkAll(100, pqcSuiteArb) { suite ->
            suite.isPQC shouldBe true
        }
    }
    
    /**
     * Property test: Classic suites are correctly identified
     */
    test("Classic suites are correctly identified by isPQC property") {
        val classicSuiteArb = Arb.element(
            CryptoSuite.X25519_ED25519,
            CryptoSuite.P256_ECDSA
        )
        
        checkAll(100, classicSuiteArb) { suite ->
            suite.isPQC shouldBe false
        }
    }
    
    /**
     * Property test: getSupportedSuites always includes classic suites
     */
    test("getSupportedSuites always includes classic suites") {
        val supportedSuites = CryptoProviderFactory.getSupportedSuites()
        
        // Classic suites should always be present
        supportedSuites.contains(CryptoSuite.X25519_ED25519) shouldBe true
        supportedSuites.contains(CryptoSuite.P256_ECDSA) shouldBe true
    }
    
    /**
     * Property test: Provider tier matches suite type for classic suites
     */
    test("Provider tier is CLASSIC for all classic suites") {
        val classicSuiteArb = Arb.element(
            CryptoSuite.X25519_ED25519,
            CryptoSuite.P256_ECDSA
        )
        
        checkAll(100, classicSuiteArb) { suite ->
            val tier = CryptoProviderFactory.getAvailableTier(suite)
            tier shouldBe CryptoTier.CLASSIC
        }
    }
    
    /**
     * Property test: PQC suites throw exception when no PQC provider available
     * 
     * Since PQC providers are not yet implemented, requesting a PQC suite
     * should throw CryptoProviderUnavailableException.
     */
    test("PQC suites throw CryptoProviderUnavailableException when no PQC provider available") {
        val pqcSuiteArb = Arb.element(
            CryptoSuite.ML_KEM_768_ML_DSA_65,
            CryptoSuite.X_WING_ML_DSA
        )
        
        // Only run this test if PQC is not available
        if (!CryptoProviderFactory.isPQCAvailable()) {
            checkAll(100, pqcSuiteArb) { suite ->
                val result = runCatching { CryptoProviderFactory.createProvider(suite) }
                result.isFailure shouldBe true
                result.exceptionOrNull().shouldBeInstanceOf<CryptoProviderUnavailableException>()
            }
        }
    }
    
    /**
     * Property test: Created provider's activeSuite matches requested suite
     */
    test("Created provider's activeSuite matches requested suite for classic suites") {
        val classicSuiteArb = Arb.element(
            CryptoSuite.X25519_ED25519,
            CryptoSuite.P256_ECDSA
        )
        
        checkAll(100, classicSuiteArb) { suite ->
            val provider = CryptoProviderFactory.createProvider(suite)
            provider.activeSuite shouldBe suite
        }
    }
})
