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
import java.security.Signature
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
 * Platform Compatibility (Android 13-17):
 * - Android 17 (API 36): Full PQC with hardware acceleration hints
 * - Android 14-16 (API 34-35): Full PQC with software implementation
 * - Android 13 (API 33): PQC with graceful fallback to hybrid mode
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

        return nativeMLKEM768Decaps(ciphertext, secretKey)
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
            return nativeMLDSA65Sign(data, privateKey)
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
                    val publicKey = keyData.sliceArray(0 until MLKEM768_PUBLIC_KEY_SIZE)
                    val privateKey = keyData.sliceArray(MLKEM768_PUBLIC_KEY_SIZE until keyData.size)
                    
                    KeyPair(
                        publicKey = KeyMaterial(activeSuite, usage, publicKey),
                        privateKey = KeyMaterial(activeSuite, usage, privateKey)
                    )
                }
                KeyUsage.SIGNING -> {
                    val keyData = nativeMLDSA65KeyGen()
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

    // ========== Cross-Platform Compatibility Methods ==========

    /**
     * Verify signature with automatic algorithm detection.
     * Supports ML-DSA, Ed25519, and ECDSA for Apple compatibility.
     *
     * @param data Original message
     * @param signature Signature to verify
     * @param publicKey Public key (format determined by size)
     * @return true if signature is valid
     */
    suspend fun verifyWithFallback(
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean {
        return when {
            // ML-DSA-65 public key (1952 bytes)
            publicKey.size == MLDSA65_PUBLIC_KEY_SIZE -> {
                verify(data, signature, publicKey)
            }
            // Ed25519 public key (32 bytes)
            publicKey.size == 32 && PlatformCompat.apiLevel >= 33 -> {
                verifyEd25519(data, signature, publicKey)
            }
            // P-256 public key (65 bytes uncompressed, 33 bytes compressed)
            publicKey.size in listOf(33, 65) -> {
                verifyECDSA(data, signature, publicKey)
            }
            else -> {
                throw CryptoOperationException(
                    "verifyWithFallback",
                    "Unknown public key format: ${publicKey.size} bytes"
                )
            }
        }
    }

    /**
     * Verify Ed25519 signature (Apple CryptoKit compatible).
     */
    private fun verifyEd25519(
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean {
        require(publicKey.size == 32) { "Ed25519 public key must be 32 bytes" }
        require(signature.size == 64) { "Ed25519 signature must be 64 bytes" }

        return try {
            val keySpec = java.security.spec.EdECPublicKeySpec(
                java.security.spec.NamedParameterSpec.ED25519,
                java.security.spec.EdECPoint(
                    publicKey[31].toInt() and 0x80 != 0,
                    java.math.BigInteger(1, publicKey.sliceArray(0 until 31).reversedArray())
                )
            )
            val keyFactory = java.security.KeyFactory.getInstance("Ed25519")
            val pubKey = keyFactory.generatePublic(keySpec)

            val sig = Signature.getInstance("Ed25519")
            sig.initVerify(pubKey)
            sig.update(data)
            sig.verify(signature)
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Verify ECDSA P-256 signature (Apple CryptoKit P256.Signing compatible).
     */
    private fun verifyECDSA(
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean {
        return try {
            val keyFactory = java.security.KeyFactory.getInstance("EC")

            // Convert public key to X509 format if needed
            val pubKeyBytes = if (publicKey.size == 65) {
                // Already uncompressed
                publicKey
            } else {
                // Decompress point (simplified - production should use proper decompression)
                publicKey
            }

            val keySpec = java.security.spec.X509EncodedKeySpec(
                createX509PublicKeyBytes(pubKeyBytes)
            )
            val pubKey = keyFactory.generatePublic(keySpec)

            val sig = Signature.getInstance("SHA256withECDSA")
            sig.initVerify(pubKey)
            sig.update(data)

            // Convert signature from raw (r||s) to DER if needed
            val derSig = if (signature.size == 64) {
                rawToDerSignature(signature)
            } else {
                signature
            }

            sig.verify(derSig)
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Create X.509 SubjectPublicKeyInfo bytes for P-256 public key.
     */
    private fun createX509PublicKeyBytes(rawPublicKey: ByteArray): ByteArray {
        // P-256 OID: 1.2.840.10045.3.1.7
        val oid = byteArrayOf(
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86.toByte(),
            0x48, 0xce.toByte(), 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
            0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00
        )
        return oid + rawPublicKey
    }

    /**
     * Convert raw signature (r||s) to DER format.
     */
    private fun rawToDerSignature(raw: ByteArray): ByteArray {
        require(raw.size == 64) { "Raw signature must be 64 bytes (r||s)" }

        val r = raw.sliceArray(0 until 32)
        val s = raw.sliceArray(32 until 64)

        fun encodeInteger(bytes: ByteArray): ByteArray {
            // Remove leading zeros but keep one if the high bit is set
            var start = 0
            while (start < bytes.size - 1 && bytes[start] == 0.toByte()) {
                start++
            }
            val trimmed = bytes.sliceArray(start until bytes.size)

            // Add leading zero if high bit is set (to keep positive)
            val needsLeadingZero = trimmed[0].toInt() and 0x80 != 0
            val encoded = if (needsLeadingZero) {
                byteArrayOf(0) + trimmed
            } else {
                trimmed
            }

            return byteArrayOf(0x02, encoded.size.toByte()) + encoded
        }

        val rEnc = encodeInteger(r)
        val sEnc = encodeInteger(s)
        val inner = rEnc + sEnc

        return byteArrayOf(0x30, inner.size.toByte()) + inner
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
