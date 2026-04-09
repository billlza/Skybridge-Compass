package com.skybridge.compass.shared.crypto

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * AES-256-GCM in CryptoKit "combined" format:
 * combined = nonce(12) || ciphertext || tag(16)
 */
object AesGcmCombined {
    private const val NONCE_LEN = 12
    private const val TAG_BITS = 128
    private val rng = SecureRandom()

    fun seal(key32: ByteArray, plaintext: ByteArray, aad: ByteArray? = null): ByteArray {
        require(key32.size == 32) { "AES-256 key must be 32 bytes" }
        val nonce = ByteArray(NONCE_LEN).also { rng.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key32, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        if (aad != null) cipher.updateAAD(aad)
        val ctAndTag = cipher.doFinal(plaintext)
        return nonce + ctAndTag
    }

    fun open(key32: ByteArray, combined: ByteArray, aad: ByteArray? = null): ByteArray {
        require(key32.size == 32) { "AES-256 key must be 32 bytes" }
        require(combined.size >= NONCE_LEN + 16) { "combined too short" }
        val nonce = combined.copyOfRange(0, NONCE_LEN)
        val ctAndTag = combined.copyOfRange(NONCE_LEN, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key32, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        if (aad != null) cipher.updateAAD(aad)
        return cipher.doFinal(ctAndTag)
    }
}


