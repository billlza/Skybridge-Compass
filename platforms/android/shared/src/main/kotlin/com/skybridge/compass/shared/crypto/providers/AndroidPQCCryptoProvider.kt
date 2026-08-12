package com.skybridge.compass.shared.crypto.providers

import android.os.Build
import com.skybridge.compass.shared.crypto.CryptoOperationException
import com.skybridge.compass.shared.crypto.CryptoProvider
import com.skybridge.compass.shared.crypto.CryptoTier
import com.skybridge.compass.shared.crypto.KeyUsage
import com.skybridge.compass.shared.crypto.PlatformCompat
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.HPKESealedBox
import com.skybridge.compass.shared.crypto.models.KeyMaterial
import com.skybridge.compass.shared.crypto.models.KeyPair
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Post-Quantum Cryptography provider using liboqs native library.
 *
 * Supports:
 * - ML-KEM-768 (FIPS 203): Key Encapsulation Mechanism
 * - ML-DSA-65 (FIPS 204): Digital Signature Algorithm
 *
 * Platform Compatibility:
 * - Current SkyBridge Android product line requires Android 16 / API 36+.
 * - Android 17 / API 37+: PQC with hardware acceleration hints when StrongBox is available.
 * - Android 16 / API 36: PQC with software implementation.
 *
 * Cross-Platform:
 * - Compatible with macOS/iOS CryptoKit PQC implementation
 * - Supports hybrid signatures for non-PQC peers
 */
class AndroidPQCCryptoProvider(
    override val activeSuite: CryptoSuite = CryptoSuite.ML_KEM_768_ML_DSA_65
) : CryptoProvider {

    override val providerName: String = "liboqs-android"
    override val tier: CryptoTier = CryptoTier.LIBOQS_PQC

    private val secureRandom = SecureRandom()

    /**
     * Platform information for optimization and telemetry.
     */
    val platformInfo: Map<String, Any> = PlatformCompat.getPlatformInfo()

    /**
     * Whether hardware acceleration is available (Android 17+).
     */
    val hasHardwareAcceleration: Boolean = PlatformCompat.isAndroid17OrHigher &&
            PlatformCompat.hasStrongBox

    init {
        require(activeSuite.isPQC) {
            "AndroidPQCCryptoProvider requires a PQC suite: ${activeSuite.rawValue}"
        }
        require(isAvailable()) {
            "liboqs native library is not available on this device (API ${Build.VERSION.SDK_INT})"
        }
    }
    
    // ========== Native method declarations ==========
    
    /**
     * Generate ML-KEM-768 key pair.
     * @return byte array containing [public_key(1184) || secret_key(2400)]
     */
    private external fun nativeMLKEM768KeyGen(): ByteArray
    
    /**
     * ML-KEM-768 encapsulation.
     * @param publicKey 1184-byte public key
     * @return byte array containing [ciphertext(1088) || shared_secret(32)]
     */
    private external fun nativeMLKEM768Encaps(publicKey: ByteArray): ByteArray
    
    /**
     * ML-KEM-768 decapsulation.
     * @param ciphertext 1088-byte ciphertext
     * @param secretKey 2400-byte secret key
     * @return 32-byte shared secret
     */
    private external fun nativeMLKEM768Decaps(ciphertext: ByteArray, secretKey: ByteArray): ByteArray

    /**
     * Generate ML-DSA-65 key pair.
     * @return byte array containing [public_key(1952) || secret_key(4032)]
     */
    private external fun nativeMLDSA65KeyGen(): ByteArray
    
    /**
     * ML-DSA-65 sign.
     * @param message Message to sign
     * @param secretKey 4032-byte secret key
     * @return Signature (~3309 bytes)
     */
    private external fun nativeMLDSA65Sign(message: ByteArray, secretKey: ByteArray): ByteArray
    
    /**
     * ML-DSA-65 verify.
     * @param message Original message
     * @param signature Signature to verify
     * @param publicKey 1952-byte public key
     * @return true if valid
     */
    private external fun nativeMLDSA65Verify(
        message: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean
    
    // ========== Direct KEM operations for handshake ==========

    /**
     * Performs ML-KEM-768 encapsulation (for server side).
     *
     * @param recipientPublicKey Client's ML-KEM-768 public key (1184 bytes)
     * @return Pair of (ciphertext, sharedSecret)
     */
    fun encapsulate(recipientPublicKey: ByteArray): Pair<ByteArray, ByteArray> {
        require(recipientPublicKey.size == MLKEM768_PUBLIC_KEY_SIZE) {
            "Invalid public key size: ${recipientPublicKey.size}, expected $MLKEM768_PUBLIC_KEY_SIZE"
        }

        val result = nativeMLKEM768Encaps(recipientPublicKey)
        require(result.size == MLKEM768_CIPHERTEXT_SIZE + MLKEM768_SHARED_SECRET_SIZE) {
            "Invalid ML-KEM encapsulation result size: ${result.size}"
        }

        val ciphertext = result.sliceArray(0 until MLKEM768_CIPHERTEXT_SIZE)
        val sharedSecret = result.sliceArray(MLKEM768_CIPHERTEXT_SIZE until result.size)

        return ciphertext to sharedSecret
    }

    /**
     * Performs ML-KEM-768 decapsulation (for client side).
     *
     * @param ciphertext ML-KEM-768 ciphertext (1088 bytes)
     * @param secretKey Client's ML-KEM-768 secret key (2400 bytes)
     * @return 32-byte shared secret
     */
    fun decapsulate(ciphertext: ByteArray, secretKey: ByteArray): ByteArray {
        require(ciphertext.size == MLKEM768_CIPHERTEXT_SIZE) {
            "Invalid ciphertext size: ${ciphertext.size}, expected $MLKEM768_CIPHERTEXT_SIZE"
        }
        require(secretKey.size == MLKEM768_SECRET_KEY_SIZE) {
            "Invalid secret key size: ${secretKey.size}, expected $MLKEM768_SECRET_KEY_SIZE"
        }

        val sharedSecret = nativeMLKEM768Decaps(ciphertext, secretKey)
        require(sharedSecret.size == MLKEM768_SHARED_SECRET_SIZE) {
            "Invalid ML-KEM decapsulation result size: ${sharedSecret.size}"
        }
        return sharedSecret
    }

    // ========== CryptoProvider implementation ==========
    
    /**
     * Performs HPKE seal using ML-KEM-768 + AES-GCM.
     */
    override suspend fun hpkeSeal(
        plaintext: ByteArray,
        recipientPublicKey: ByteArray,
        info: ByteArray
    ): HPKESealedBox {
        try {
            // Perform KEM encapsulation
            val encapsResult = nativeMLKEM768Encaps(recipientPublicKey)
            
            // Split result: [ciphertext(1088) || shared_secret(32)]
            val ciphertext = encapsResult.sliceArray(0 until MLKEM768_CIPHERTEXT_SIZE)
            val sharedSecret = encapsResult.sliceArray(MLKEM768_CIPHERTEXT_SIZE until encapsResult.size)
            
            // Derive encryption key using HKDF
            val encryptionKey = hkdfExpand(
                hkdfExtract(info, sharedSecret),
                "hpke-aes-gcm".toByteArray(),
                32
            )
            
            // Generate nonce
            val nonce = ByteArray(HPKESealedBox.EXPECTED_NONCE_LEN)
            secureRandom.nextBytes(nonce)
            
            // Encrypt with AES-GCM
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val secretKey = SecretKeySpec(encryptionKey, "AES")
            cipher.init(Cipher.ENCRYPT_MODE, secretKey, GCMParameterSpec(128, nonce))
            cipher.updateAAD(info)
            val ciphertextWithTag = cipher.doFinal(plaintext)
            
            // Split ciphertext and tag
            val ct = ciphertextWithTag.sliceArray(0 until ciphertextWithTag.size - 16)
            val tag = ciphertextWithTag.sliceArray(ciphertextWithTag.size - 16 until ciphertextWithTag.size)
            
            return HPKESealedBox(ciphertext, nonce, ct, tag)
        } catch (e: Exception) {
            throw CryptoOperationException("hpkeSeal", "Failed to seal: ${e.message}", e)
        }
    }
    
    /**
     * Performs HPKE open using ML-KEM-768 + AES-GCM.
     */
    override suspend fun hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: ByteArray,
        info: ByteArray
    ): ByteArray {
        try {
            // Perform KEM decapsulation
            val sharedSecret = nativeMLKEM768Decaps(sealedBox.encapsulatedKey, privateKey)
            
            // Derive decryption key using HKDF
            val decryptionKey = hkdfExpand(
                hkdfExtract(info, sharedSecret),
                "hpke-aes-gcm".toByteArray(),
                32
            )
            
            // Decrypt with AES-GCM
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val secretKey = SecretKeySpec(decryptionKey, "AES")
            cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(128, sealedBox.nonce))
            cipher.updateAAD(info)
            
            // Combine ciphertext and tag
            val ciphertextWithTag = sealedBox.ciphertext + sealedBox.tag
            
            return cipher.doFinal(ciphertextWithTag)
        } catch (e: Exception) {
            throw CryptoOperationException("hpkeOpen", "Failed to open: ${e.message}", e)
        }
    }

    /**
     * Signs data using ML-DSA-65.
     */
    override suspend fun sign(data: ByteArray, privateKey: ByteArray): ByteArray {
        try {
            val signature = nativeMLDSA65Sign(data, privateKey)
            require(signature.size == MLDSA65_SIGNATURE_SIZE) {
                "Invalid ML-DSA signature size: ${signature.size}"
            }
            return signature
        } catch (e: Exception) {
            throw CryptoOperationException("sign", "Failed to sign: ${e.message}", e)
        }
    }
    
    /**
     * Verifies an ML-DSA-65 signature.
     */
    override suspend fun verify(
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean {
        require(publicKey.size == MLDSA65_PUBLIC_KEY_SIZE) {
            "Invalid ML-DSA-65 public key size: ${publicKey.size}"
        }
        require(signature.size == MLDSA65_SIGNATURE_SIZE) {
            "Invalid ML-DSA-65 signature size: ${signature.size}"
        }
        try {
            return nativeMLDSA65Verify(data, signature, publicKey)
        } catch (e: Exception) {
            throw CryptoOperationException("verify", "Failed to verify: ${e.message}", e)
        }
    }
    
    /**
     * Generates a key pair for the specified usage.
     */
    override suspend fun generateKeyPair(usage: KeyUsage): KeyPair {
        try {
            return when (usage) {
                KeyUsage.KEY_EXCHANGE -> {
                    val keyData = nativeMLKEM768KeyGen()
                    require(keyData.size == MLKEM768_PUBLIC_KEY_SIZE + MLKEM768_SECRET_KEY_SIZE) {
                        "Invalid ML-KEM keypair result size: ${keyData.size}"
                    }
                    val publicKey = keyData.sliceArray(0 until MLKEM768_PUBLIC_KEY_SIZE)
                    val privateKey = keyData.sliceArray(MLKEM768_PUBLIC_KEY_SIZE until keyData.size)
                    
                    KeyPair(
                        publicKey = KeyMaterial(activeSuite, usage, publicKey),
                        privateKey = KeyMaterial(activeSuite, usage, privateKey)
                    )
                }
                KeyUsage.SIGNING -> {
                    val keyData = nativeMLDSA65KeyGen()
                    require(keyData.size == MLDSA65_PUBLIC_KEY_SIZE + MLDSA65_SECRET_KEY_SIZE) {
                        "Invalid ML-DSA keypair result size: ${keyData.size}"
                    }
                    val publicKey = keyData.sliceArray(0 until MLDSA65_PUBLIC_KEY_SIZE)
                    val privateKey = keyData.sliceArray(MLDSA65_PUBLIC_KEY_SIZE until keyData.size)
                    
                    KeyPair(
                        publicKey = KeyMaterial(activeSuite, usage, publicKey),
                        privateKey = KeyMaterial(activeSuite, usage, privateKey)
                    )
                }
            }
        } catch (e: Exception) {
            throw CryptoOperationException("generateKeyPair", "Failed to generate key pair: ${e.message}", e)
        }
    }
    
    // ========== HKDF helper functions ==========
    
    private fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        val saltKey = if (salt.isEmpty()) {
            SecretKeySpec(ByteArray(32), "HmacSHA256")
        } else {
            SecretKeySpec(salt, "HmacSHA256")
        }
        mac.init(saltKey)
        return mac.doFinal(ikm)
    }
    
    private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        
        val hashLen = 32
        val n = (length + hashLen - 1) / hashLen
        val result = ByteArray(n * hashLen)
        var t = ByteArray(0)
        
        for (i in 1..n) {
            mac.reset()
            mac.update(t)
            mac.update(info)
            mac.update(i.toByte())
            t = mac.doFinal()
            System.arraycopy(t, 0, result, (i - 1) * hashLen, hashLen)
        }
        
        return result.sliceArray(0 until length)
    }

    /**
     * Sign with fallback algorithm selection for cross-platform compatibility.
     *
     * @param data Data to sign
     * @param privateKey Private key
     * @param preferPQC Whether to prefer PQC (ML-DSA) if available
     * @return Signature bytes
     */
    suspend fun signWithFallback(
        data: ByteArray,
        privateKey: ByteArray,
        preferPQC: Boolean = true
    ): ByteArray {
        return when {
            // ML-DSA-65 private key
            preferPQC && privateKey.size == MLDSA65_SECRET_KEY_SIZE -> {
                sign(data, privateKey)
            }
            // Fall back to platform default
            else -> {
                throw CryptoOperationException(
                    "signWithFallback",
                    "Only ML-DSA signing supported in PQC provider"
                )
            }
        }
    }

    companion object {
        // ML-KEM-768 constants
        const val MLKEM768_PUBLIC_KEY_SIZE = 1184
        const val MLKEM768_SECRET_KEY_SIZE = 2400
        const val MLKEM768_CIPHERTEXT_SIZE = 1088
        const val MLKEM768_SHARED_SECRET_SIZE = 32
        
        // ML-DSA-65 constants
        const val MLDSA65_PUBLIC_KEY_SIZE = 1952
        const val MLDSA65_SECRET_KEY_SIZE = 4032
        const val MLDSA65_SIGNATURE_SIZE = 3309
        
        private var libraryLoaded = false
        private var libraryAvailable = false
        
        init {
            try {
                System.loadLibrary("skybridge_pqc")
                libraryLoaded = true
                libraryAvailable = nativeIsAvailable()
            } catch (e: UnsatisfiedLinkError) {
                libraryLoaded = false
                libraryAvailable = false
            }
        }
        
        /**
         * Check if liboqs native library is available.
         */
        @JvmStatic
        external fun nativeIsAvailable(): Boolean
        
        /**
         * Returns true if the PQC provider is available on this device.
         */
        @JvmStatic
        fun isAvailable(): Boolean = libraryLoaded && libraryAvailable
    }
}
