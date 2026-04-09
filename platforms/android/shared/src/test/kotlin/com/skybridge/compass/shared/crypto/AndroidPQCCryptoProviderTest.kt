package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.byte
import io.kotest.property.arbitrary.byteArray
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.map
import io.kotest.property.checkAll
import kotlinx.coroutines.runBlocking

/**
 * Property-based tests for AndroidPQCCryptoProvider.
 * 
 * These tests verify ML-KEM-768 and ML-DSA-65 operations.
 * Tests are skipped if the native library is not available.
 */
class AndroidPQCCryptoProviderTest : FunSpec({
    
    val isPQCAvailable = try {
        AndroidPQCCryptoProvider.isAvailable()
    } catch (e: Exception) {
        false
    }
    
    /**
     * **Feature: android-pqc-crypto, Property 6: ML-KEM-768 encapsulation round-trip**
     * 
     * *For any* valid ML-KEM-768 key pair, encapsulating with the public key SHALL produce:
     * - A ciphertext of exactly 1088 bytes
     * - A shared secret of exactly 32 bytes
     * - Decapsulating the ciphertext with the corresponding private key SHALL produce the same shared secret
     * 
     * **Validates: Requirements 4.2, 4.3**
     */
    test("Property 6: ML-KEM-768 encapsulation round-trip").config(enabled = isPQCAvailable) {
        val provider = AndroidPQCCryptoProvider(CryptoSuite.ML_KEM_768_ML_DSA_65)
        
        // Generate multiple key pairs and test encapsulation/decapsulation
        repeat(100) {
            runBlocking {
                // Generate key pair
                val keyPair = provider.generateKeyPair(KeyUsage.KEY_EXCHANGE)
                
                // Verify key sizes
                keyPair.publicKey.bytes.size shouldBe AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE
                keyPair.privateKey.bytes.size shouldBe AndroidPQCCryptoProvider.MLKEM768_SECRET_KEY_SIZE
                
                // Test HPKE seal/open round-trip (which uses ML-KEM-768 internally)
                val plaintext = ByteArray(32) { it.toByte() }
                val info = "test-info".toByteArray()
                
                val sealedBox = provider.hpkeSeal(plaintext, keyPair.publicKey.bytes, info)
                
                // Verify ciphertext size (encapsulated key should be 1088 bytes)
                sealedBox.encapsulatedKey.size shouldBe AndroidPQCCryptoProvider.MLKEM768_CIPHERTEXT_SIZE
                
                // Decrypt and verify round-trip
                val decrypted = provider.hpkeOpen(sealedBox, keyPair.privateKey.bytes, info)
                decrypted.contentEquals(plaintext) shouldBe true
            }
        }
    }
    
    /**
     * **Feature: android-pqc-crypto, Property 7: ML-DSA-65 signature round-trip**
     * 
     * *For any* message and valid ML-DSA-65 key pair, signing the message SHALL produce:
     * - A signature of approximately 3309 bytes (within FIPS 204 bounds)
     * - Verifying the signature with the corresponding public key (1952 bytes) SHALL return true
     * - Verifying with any other public key SHALL return false
     * 
     * **Validates: Requirements 4.4, 4.5**
     */
    test("Property 7: ML-DSA-65 signature round-trip").config(enabled = isPQCAvailable) {
        val provider = AndroidPQCCryptoProvider(CryptoSuite.ML_KEM_768_ML_DSA_65)
        val messageArb = Arb.byteArray(Arb.int(1..1024), Arb.byte())
        
        checkAll(100, messageArb) { message ->
            runBlocking {
                // Generate signing key pair
                val keyPair = provider.generateKeyPair(KeyUsage.SIGNING)
                
                // Verify key sizes
                keyPair.publicKey.bytes.size shouldBe AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE
                keyPair.privateKey.bytes.size shouldBe AndroidPQCCryptoProvider.MLDSA65_SECRET_KEY_SIZE
                
                // Sign message
                val signature = provider.sign(message, keyPair.privateKey.bytes)
                
                // Signature should be approximately 3309 bytes (may vary slightly)
                (signature.size in 3200..3400) shouldBe true
                
                // Verify with correct public key should succeed
                val isValid = provider.verify(message, signature, keyPair.publicKey.bytes)
                isValid shouldBe true
                
                // Generate another key pair
                val otherKeyPair = provider.generateKeyPair(KeyUsage.SIGNING)
                
                // Verify with wrong public key should fail
                val isInvalid = provider.verify(message, signature, otherKeyPair.publicKey.bytes)
                isInvalid shouldBe false
            }
        }
    }
    
    /**
     * Test that provider correctly reports availability.
     */
    test("isAvailable returns consistent result") {
        val result1 = try { AndroidPQCCryptoProvider.isAvailable() } catch (e: Exception) { false }
        val result2 = try { AndroidPQCCryptoProvider.isAvailable() } catch (e: Exception) { false }
        result1 shouldBe result2
    }
    
    /**
     * Test that provider has correct tier and name.
     */
    test("Provider has correct metadata").config(enabled = isPQCAvailable) {
        val provider = AndroidPQCCryptoProvider(CryptoSuite.ML_KEM_768_ML_DSA_65)
        provider.providerName shouldBe "liboqs-android"
        provider.tier shouldBe CryptoTier.LIBOQS_PQC
        provider.activeSuite shouldBe CryptoSuite.ML_KEM_768_ML_DSA_65
    }
})
