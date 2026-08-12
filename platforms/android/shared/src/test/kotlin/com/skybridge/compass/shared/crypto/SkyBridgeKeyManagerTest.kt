package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.KeyMaterial
import com.skybridge.compass.shared.crypto.models.KeyPair
import io.kotest.core.spec.style.FunSpec
import io.kotest.assertions.throwables.shouldThrow
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.byte
import io.kotest.property.arbitrary.byteArray
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.string
import io.kotest.property.checkAll
import java.security.KeyStore
import java.security.PublicKey
import java.security.cert.Certificate

/**
 * Property-based tests for SkyBridgeKeyManager.
 * 
 * Note: These tests require Android instrumentation to run properly
 * since they depend on Android Keystore and SharedPreferences.
 * The property tests here validate the logic that can be tested
 * in a JVM environment.
 */
class SkyBridgeKeyManagerTest : FunSpec({
    test("existing-only wrapping key lookup does not create a missing alias") {
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
        }
        val alias = "missing-pqc-wrapper"

        shouldThrow<KeyStorageException> {
            SkyBridgeKeyManager.requireExistingSecretKeyEntry(keyStore, alias)
        }
        keyStore.containsAlias(alias) shouldBe false
    }

    test("existing-only wrapping key lookup rejects a non-secret entry") {
        val alias = "wrong-pqc-wrapper-type"
        val entry = KeyStore.TrustedCertificateEntry(TestCertificate())

        shouldThrow<KeyStorageException> {
            SkyBridgeKeyManager.requireExistingSecretKeyEntry(
                alias = alias,
                aliasPresent = true,
                entry = entry
            )
        }
    }
    
    /**
     * **Feature: android-pqc-crypto, Property 12: PQC key storage round-trip**
     * 
     * *For any* valid PQC KeyPair, storing with storePQCKeyPair() and retrieving 
     * SHALL produce a KeyPair with identical public and private key bytes.
     * 
     * **Validates: Requirements 7.2**
     * 
     * Note: This test validates the KeyPair data model consistency.
     * Full round-trip testing requires Android instrumentation tests
     * since SkyBridgeKeyManager depends on Android Keystore.
     */
    test("Property 12: KeyPair data model preserves key bytes through construction") {
        val suiteArb = Arb.element(
            CryptoSuite.ML_KEM_768_ML_DSA_65,
            CryptoSuite.X_WING_ML_DSA
        )
        val usageArb = Arb.element(KeyUsage.KEY_EXCHANGE, KeyUsage.SIGNING)
        
        // Generate key bytes of realistic sizes for PQC keys
        val publicKeySizeArb = Arb.element(1184, 1952) // ML-KEM-768 or ML-DSA-65 public key sizes
        val privateKeySizeArb = Arb.element(2400, 4032) // ML-KEM-768 or ML-DSA-65 private key sizes
        
        checkAll(100, suiteArb, usageArb, publicKeySizeArb, privateKeySizeArb) { suite, usage, pubSize, privSize ->
            val publicKeyBytes = ByteArray(pubSize) { it.toByte() }
            val privateKeyBytes = ByteArray(privSize) { (it * 2).toByte() }
            
            val keyPair = KeyPair(
                publicKey = KeyMaterial(suite, usage, publicKeyBytes),
                privateKey = KeyMaterial(suite, usage, privateKeyBytes)
            )
            
            // Verify key pair preserves all data
            keyPair.publicKey.bytes.contentEquals(publicKeyBytes) shouldBe true
            keyPair.privateKey.bytes.contentEquals(privateKeyBytes) shouldBe true
            keyPair.suite shouldBe suite
            keyPair.usage shouldBe usage
        }
    }
    
    /**
     * Test that KeyPair equality works correctly for round-trip verification.
     */
    test("KeyPair equality is based on key bytes content") {
        val suiteArb = Arb.element(
            CryptoSuite.ML_KEM_768_ML_DSA_65,
            CryptoSuite.X25519_ED25519
        )
        val usageArb = Arb.element(KeyUsage.KEY_EXCHANGE, KeyUsage.SIGNING)
        val bytesArb = Arb.byteArray(Arb.int(32..64), Arb.byte())
        
        checkAll(100, suiteArb, usageArb, bytesArb, bytesArb) { suite, usage, pubBytes, privBytes ->
            val keyPair1 = KeyPair(
                publicKey = KeyMaterial(suite, usage, pubBytes.copyOf()),
                privateKey = KeyMaterial(suite, usage, privBytes.copyOf())
            )
            
            val keyPair2 = KeyPair(
                publicKey = KeyMaterial(suite, usage, pubBytes.copyOf()),
                privateKey = KeyMaterial(suite, usage, privBytes.copyOf())
            )
            
            // Two key pairs with same content should be equal
            keyPair1 shouldBe keyPair2
            keyPair1.hashCode() shouldBe keyPair2.hashCode()
        }
    }
    
    /**
     * Test that KeyMaterial clear() properly zeroes out key bytes.
     */
    test("KeyMaterial clear zeroes key bytes") {
        val bytesArb = Arb.byteArray(Arb.int(32..256), Arb.byte())
        
        checkAll(100, bytesArb) { originalBytes ->
            // Skip if all bytes are already zero
            if (originalBytes.all { it == 0.toByte() }) return@checkAll
            
            val keyMaterial = KeyMaterial(
                CryptoSuite.ML_KEM_768_ML_DSA_65,
                KeyUsage.KEY_EXCHANGE,
                originalBytes.copyOf()
            )
            
            // Verify bytes are not all zero before clear
            val hasNonZero = keyMaterial.bytes.any { it != 0.toByte() }
            hasNonZero shouldBe true
            
            // Clear the key material
            keyMaterial.clear()
            
            // Verify all bytes are now zero
            keyMaterial.bytes.all { it == 0.toByte() } shouldBe true
        }
    }
    
    /**
     * Test that KeyPair clear() properly zeroes both keys.
     */
    test("KeyPair clear zeroes both public and private key bytes") {
        val bytesArb = Arb.byteArray(Arb.int(32..64), Arb.byte())
        
        checkAll(100, bytesArb, bytesArb) { pubBytes, privBytes ->
            // Skip if all bytes are already zero
            if (pubBytes.all { it == 0.toByte() } && privBytes.all { it == 0.toByte() }) {
                return@checkAll
            }
            
            val keyPair = KeyPair(
                publicKey = KeyMaterial(
                    CryptoSuite.ML_KEM_768_ML_DSA_65,
                    KeyUsage.KEY_EXCHANGE,
                    pubBytes.copyOf()
                ),
                privateKey = KeyMaterial(
                    CryptoSuite.ML_KEM_768_ML_DSA_65,
                    KeyUsage.KEY_EXCHANGE,
                    privBytes.copyOf()
                )
            )
            
            // Clear the key pair
            keyPair.clear()
            
            // Verify all bytes are now zero
            keyPair.publicKey.bytes.all { it == 0.toByte() } shouldBe true
            keyPair.privateKey.bytes.all { it == 0.toByte() } shouldBe true
        }
    }
})

private class TestCertificate : Certificate("test") {
    override fun getEncoded(): ByteArray = byteArrayOf(0x01)
    override fun verify(key: PublicKey) = Unit
    override fun verify(key: PublicKey, sigProvider: String) = Unit
    override fun toString(): String = "TestCertificate"
    override fun getPublicKey(): PublicKey = object : PublicKey {
        override fun getAlgorithm(): String = "test"
        override fun getFormat(): String = "RAW"
        override fun getEncoded(): ByteArray = byteArrayOf(0x01)
    }
}
