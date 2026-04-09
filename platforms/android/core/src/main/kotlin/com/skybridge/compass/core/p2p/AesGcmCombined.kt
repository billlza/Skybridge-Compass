package com.skybridge.compass.core.p2p

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * AES-256-GCM "combined" format used by Pro release for app payloads:
 * nonce(12) || ciphertext || tag(16), with empty AAD.
 */
object AesGcmCombined {
    private val secureRandom = SecureRandom()

    fun encrypt(key32: ByteArray, plaintext: ByteArray): ByteArray {
        require(key32.size == 32) { "AES-256 key must be 32 bytes" }
        val nonce = ByteArray(12).also { secureRandom.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key32, "AES"), GCMParameterSpec(128, nonce))
        val ctAndTag = cipher.doFinal(plaintext)
        val out = ByteArray(nonce.size + ctAndTag.size)
        System.arraycopy(nonce, 0, out, 0, nonce.size)
        System.arraycopy(ctAndTag, 0, out, nonce.size, ctAndTag.size)
        return out
    }

    fun decrypt(key32: ByteArray, combined: ByteArray): ByteArray {
        require(key32.size == 32) { "AES-256 key must be 32 bytes" }
        require(combined.size >= 12 + 16) { "ciphertext too short" }
        val nonce = combined.copyOfRange(0, 12)
        val body = combined.copyOfRange(12, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key32, "AES"), GCMParameterSpec(128, nonce))
        return cipher.doFinal(body)
    }
}

