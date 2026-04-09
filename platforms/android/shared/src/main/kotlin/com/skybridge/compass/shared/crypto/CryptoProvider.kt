package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.HPKESealedBox
import com.skybridge.compass.shared.crypto.models.KeyPair

/**
 * Unified interface for cryptographic operations.
 * 
 * This interface abstracts different cryptographic implementations
 * (liboqs, BouncyCastle, Classic) through a consistent API, enabling
 * seamless interoperability with macOS SkyBridge Compass.
 * 
 * Implementations:
 * - AndroidPQCCryptoProvider: liboqs-based PQC (ML-KEM-768, ML-DSA-65)
 * - BouncyCastlePQCProvider: BouncyCastle PQC fallback
 * - ClassicCryptoProvider: EC-based classic crypto (X25519, P-256)
 */
interface CryptoProvider {
    
    /**
     * Human-readable name identifying this provider.
     * Examples: "liboqs-android", "bouncy-castle-pqc", "classic-ec"
     */
    val providerName: String
    
    /**
     * The tier/level of this provider's cryptographic capabilities.
     */
    val tier: CryptoTier
    
    /**
     * The currently active cryptographic suite for this provider.
     */
    val activeSuite: CryptoSuite
    
    /**
     * Performs HPKE seal operation (KEM + AEAD encryption).
     * 
     * @param plaintext The data to encrypt
     * @param recipientPublicKey The recipient's public key for KEM
     * @param info Additional context info for key derivation
     * @return HPKESealedBox containing encapsulated key and ciphertext
     * @throws CryptoException if encryption fails
     */
    suspend fun hpkeSeal(
        plaintext: ByteArray,
        recipientPublicKey: ByteArray,
        info: ByteArray
    ): HPKESealedBox
    
    /**
     * Performs HPKE open operation (KEM decapsulation + AEAD decryption).
     * 
     * @param sealedBox The HPKESealedBox to decrypt
     * @param privateKey The recipient's private key for KEM decapsulation
     * @param info Additional context info for key derivation (must match seal)
     * @return Decrypted plaintext
     * @throws CryptoException if decryption fails
     */
    suspend fun hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: ByteArray,
        info: ByteArray
    ): ByteArray
    
    /**
     * Creates a digital signature over the provided data.
     * 
     * @param data The data to sign
     * @param privateKey The signing private key
     * @return The signature bytes
     * @throws CryptoException if signing fails
     */
    suspend fun sign(data: ByteArray, privateKey: ByteArray): ByteArray
    
    /**
     * Verifies a digital signature.
     * 
     * @param data The original data that was signed
     * @param signature The signature to verify
     * @param publicKey The signer's public key
     * @return true if signature is valid, false otherwise
     * @throws CryptoException if verification process fails
     */
    suspend fun verify(
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean
    
    /**
     * Generates a new key pair for the specified usage.
     * 
     * @param usage The intended usage of the key pair (KEY_EXCHANGE or SIGNING)
     * @return A new KeyPair with public and private keys
     * @throws CryptoException if key generation fails
     */
    suspend fun generateKeyPair(usage: KeyUsage): KeyPair
    
    companion object {
        /**
         * Checks if this provider type is available on the current platform.
         * Implementations should check for required native libraries or dependencies.
         * 
         * @return true if the provider can be instantiated and used
         */
        fun isAvailable(): Boolean = false
    }
}
