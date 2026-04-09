package com.skybridge.compass.shared.crypto.providers

import com.skybridge.compass.shared.crypto.CryptoOperationException
import com.skybridge.compass.shared.crypto.CryptoProvider
import com.skybridge.compass.shared.crypto.CryptoTier
import com.skybridge.compass.shared.crypto.KeyUsage
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.HPKESealedBox
import com.skybridge.compass.shared.crypto.models.KeyMaterial
import com.skybridge.compass.shared.crypto.models.KeyPair
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Classic cryptography provider using standard Java crypto (ECDH, ECDSA).
 * 
 * Supports:
 * - P-256 ECDH for key exchange
 * - ECDSA with SHA-256 for signing
 * - X25519 key exchange (via BouncyCastle if available, otherwise P-256 fallback)
 * 
 * This provider serves as the fallback when PQC providers are unavailable.
 */
class ClassicCryptoProvider(
    override val activeSuite: CryptoSuite = CryptoSuite.P256_ECDSA
) : CryptoProvider {
    
    override val providerName: String = "classic-ec"
    override val tier: CryptoTier = CryptoTier.CLASSIC
    
    private val secureRandom = SecureRandom()
    
    init {
        require(!activeSuite.isPQC) {
            "ClassicCryptoProvider does not support PQC suites: ${activeSuite.rawValue}"
        }
    }

    /**
     * Performs HPKE seal operation using ECDH + AES-GCM.
     * 
     * 1. Generate ephemeral key pair
     * 2. Perform ECDH with recipient's public key
     * 3. Derive encryption key using HKDF
     * 4. Encrypt plaintext with AES-GCM
     */
    override suspend fun hpkeSeal(
        plaintext: ByteArray,
        recipientPublicKey: ByteArray,
        info: ByteArray
    ): HPKESealedBox {
        try {
            // Generate ephemeral key pair for ECDH
            val ephemeralKeyPair = generateECKeyPair()
            val ephemeralPublic = ephemeralKeyPair.public as ECPublicKey
            val ephemeralPrivate = ephemeralKeyPair.private as ECPrivateKey
            
            // Decode recipient's public key
            val keyFactory = KeyFactory.getInstance("EC")
            val recipientKey = keyFactory.generatePublic(
                X509EncodedKeySpec(recipientPublicKey)
            ) as ECPublicKey
            
            // Perform ECDH
            val keyAgreement = KeyAgreement.getInstance("ECDH")
            keyAgreement.init(ephemeralPrivate)
            keyAgreement.doPhase(recipientKey, true)
            val sharedSecret = keyAgreement.generateSecret()
            
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
            
            // Split ciphertext and tag (AES-GCM appends 16-byte tag)
            val ciphertext = ciphertextWithTag.sliceArray(0 until ciphertextWithTag.size - 16)
            val tag = ciphertextWithTag.sliceArray(ciphertextWithTag.size - 16 until ciphertextWithTag.size)
            
            // Encode ephemeral public key
            val encapsulatedKey = ephemeralPublic.encoded
            
            return HPKESealedBox(encapsulatedKey, nonce, ciphertext, tag)
        } catch (e: Exception) {
            throw CryptoOperationException("hpkeSeal", "Failed to seal: ${e.message}", e)
        }
    }
    
    /**
     * Performs HPKE open operation using ECDH + AES-GCM.
     */
    override suspend fun hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: ByteArray,
        info: ByteArray
    ): ByteArray {
        try {
            // Decode private key
            val keyFactory = KeyFactory.getInstance("EC")
            val ecPrivateKey = keyFactory.generatePrivate(
                PKCS8EncodedKeySpec(privateKey)
            ) as ECPrivateKey
            
            // Decode ephemeral public key from encapsulated key
            val ephemeralPublic = keyFactory.generatePublic(
                X509EncodedKeySpec(sealedBox.encapsulatedKey)
            ) as ECPublicKey
            
            // Perform ECDH
            val keyAgreement = KeyAgreement.getInstance("ECDH")
            keyAgreement.init(ecPrivateKey)
            keyAgreement.doPhase(ephemeralPublic, true)
            val sharedSecret = keyAgreement.generateSecret()
            
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
            
            // Combine ciphertext and tag for decryption
            val ciphertextWithTag = sealedBox.ciphertext + sealedBox.tag
            
            return cipher.doFinal(ciphertextWithTag)
        } catch (e: Exception) {
            throw CryptoOperationException("hpkeOpen", "Failed to open: ${e.message}", e)
        }
    }

    /**
     * Creates an ECDSA signature over the provided data.
     */
    override suspend fun sign(data: ByteArray, privateKey: ByteArray): ByteArray {
        try {
            val keyFactory = KeyFactory.getInstance("EC")
            val ecPrivateKey = keyFactory.generatePrivate(
                PKCS8EncodedKeySpec(privateKey)
            ) as ECPrivateKey
            
            val signature = Signature.getInstance("SHA256withECDSA")
            signature.initSign(ecPrivateKey)
            signature.update(data)
            
            return signature.sign()
        } catch (e: Exception) {
            throw CryptoOperationException("sign", "Failed to sign: ${e.message}", e)
        }
    }
    
    /**
     * Verifies an ECDSA signature.
     */
    override suspend fun verify(
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean {
        try {
            val keyFactory = KeyFactory.getInstance("EC")
            val ecPublicKey = keyFactory.generatePublic(
                X509EncodedKeySpec(publicKey)
            ) as ECPublicKey
            
            val sig = Signature.getInstance("SHA256withECDSA")
            sig.initVerify(ecPublicKey)
            sig.update(data)
            
            return sig.verify(signature)
        } catch (e: Exception) {
            throw CryptoOperationException("verify", "Failed to verify: ${e.message}", e)
        }
    }
    
    /**
     * Generates a new EC key pair for the specified usage.
     */
    override suspend fun generateKeyPair(usage: KeyUsage): KeyPair {
        try {
            val javaKeyPair = generateECKeyPair()
            
            val publicKeyBytes = javaKeyPair.public.encoded
            val privateKeyBytes = javaKeyPair.private.encoded
            
            return KeyPair(
                publicKey = KeyMaterial(activeSuite, usage, publicKeyBytes),
                privateKey = KeyMaterial(activeSuite, usage, privateKeyBytes)
            )
        } catch (e: Exception) {
            throw CryptoOperationException("generateKeyPair", "Failed to generate key pair: ${e.message}", e)
        }
    }
    
    /**
     * Generates an EC key pair using P-256 curve.
     */
    private fun generateECKeyPair(): java.security.KeyPair {
        val keyPairGenerator = KeyPairGenerator.getInstance("EC")
        keyPairGenerator.initialize(ECGenParameterSpec("secp256r1"), secureRandom)
        return keyPairGenerator.generateKeyPair()
    }
    
    /**
     * HKDF-Extract: Extract a pseudorandom key from input keying material.
     */
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
    
    /**
     * HKDF-Expand: Expand a pseudorandom key to desired length.
     */
    private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        
        val hashLen = 32 // SHA-256 output length
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
    
    companion object {
        /**
         * Checks if this provider is available on the current platform.
         * Classic EC crypto is always available via standard Java crypto.
         */
        fun isAvailable(): Boolean = true
    }
}
