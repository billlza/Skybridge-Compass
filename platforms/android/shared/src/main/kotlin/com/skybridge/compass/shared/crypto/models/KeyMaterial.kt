package com.skybridge.compass.shared.crypto.models

import com.skybridge.compass.shared.crypto.KeyUsage

/**
 * Represents cryptographic key material with associated metadata.
 * 
 * @property suite The CryptoSuite this key belongs to
 * @property usage The intended usage of this key (KEY_EXCHANGE or SIGNING)
 * @property bytes The raw key bytes
 */
data class KeyMaterial(
    val suite: CryptoSuite,
    val usage: KeyUsage,
    val bytes: ByteArray
) {
    /**
     * Returns the expected key size based on suite and usage.
     */
    val expectedSize: Int?
        get() = when {
            suite == CryptoSuite.ML_KEM_768_ML_DSA_65 && usage == KeyUsage.KEY_EXCHANGE -> 
                1184 // ML-KEM-768 public key
            suite == CryptoSuite.ML_KEM_768_ML_DSA_65 && usage == KeyUsage.SIGNING -> 
                1952 // ML-DSA-65 public key
            suite == CryptoSuite.X25519_ED25519 && usage == KeyUsage.KEY_EXCHANGE -> 
                32 // X25519 public key
            suite == CryptoSuite.X25519_ED25519 && usage == KeyUsage.SIGNING -> 
                32 // Ed25519 public key
            suite == CryptoSuite.P256_ECDSA -> 
                65 // P-256 uncompressed public key
            else -> null
        }
    
    /**
     * Validates that the key bytes match the expected size for this suite/usage.
     * 
     * @return true if size matches or no expected size is defined
     */
    fun isValidSize(): Boolean {
        val expected = expectedSize ?: return true
        return bytes.size == expected
    }
    
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is KeyMaterial) return false
        
        return suite == other.suite &&
               usage == other.usage &&
               bytes.contentEquals(other.bytes)
    }
    
    override fun hashCode(): Int {
        var result = suite.hashCode()
        result = 31 * result + usage.hashCode()
        result = 31 * result + bytes.contentHashCode()
        return result
    }
    
    /**
     * Securely clears the key bytes from memory.
     * Call this when the key is no longer needed.
     */
    fun clear() {
        bytes.fill(0)
    }
}
