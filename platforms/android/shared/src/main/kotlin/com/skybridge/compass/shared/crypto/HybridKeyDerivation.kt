package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.SessionKeys
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Hybrid key derivation using HKDF with domain separation.
 * 
 * Combines classic ECDH secret and PQC KEM secret to derive session keys.
 * Follows Google Chrome's approach for hybrid key exchange.
 * 
 * Key derivation flow:
 * 1. Combine classicSecret || pqcSecret as IKM
 * 2. Compute salt = SHA-256(clientRandom || serverRandom)
 * 3. Extract PRK using HKDF-Extract
 * 4. Expand to master secret with domain separator
 * 5. Derive channel-specific keys
 */
object HybridKeyDerivation {
    
    /** Domain separator for SkyBridge P2P v2 protocol */
    private val DOMAIN_SEPARATOR = "SkyBridge-P2P-v2".toByteArray(Charsets.UTF_8)
    
    /** Channel info labels for key derivation */
    private val CONTROL_CHANNEL_INFO = "skybridge-control-v1".toByteArray(Charsets.UTF_8)
    private val VIDEO_CHANNEL_INFO = "skybridge-video-v1".toByteArray(Charsets.UTF_8)
    private val FILE_CHANNEL_INFO = "skybridge-file-v1".toByteArray(Charsets.UTF_8)
    
    /** Master secret length (384 bits) */
    private const val MASTER_SECRET_LENGTH = 48
    
    /** Channel key length (256 bits for AES-256) */
    private const val CHANNEL_KEY_LENGTH = 32
    
    /**
     * Derives session keys from hybrid key exchange secrets.
     * 
     * @param classicSecret Secret from classic ECDH (X25519 or P-256)
     * @param pqcSecret Secret from PQC KEM (ML-KEM-768)
     * @param clientRandom 32-byte client random from handshake
     * @param serverRandom 32-byte server random from handshake
     * @param transcriptHash SHA-256 hash of handshake transcript
     * @return SessionKeys containing control, video, and file channel keys
     */
    fun deriveSessionKeys(
        classicSecret: ByteArray,
        pqcSecret: ByteArray,
        clientRandom: ByteArray,
        serverRandom: ByteArray,
        transcriptHash: ByteArray
    ): SessionKeys {
        require(clientRandom.size == 32) { "clientRandom must be 32 bytes" }
        require(serverRandom.size == 32) { "serverRandom must be 32 bytes" }
        require(transcriptHash.size == 32) { "transcriptHash must be 32 bytes" }
        
        // 1. Combine input key material
        val ikm = ByteBuffer.allocate(classicSecret.size + pqcSecret.size).apply {
            put(classicSecret)
            put(pqcSecret)
        }.array()
        
        // 2. Compute salt = SHA-256(clientRandom || serverRandom)
        val salt = MessageDigest.getInstance("SHA-256").apply {
            update(clientRandom)
            update(serverRandom)
        }.digest()
        
        // 3. HKDF-Extract: PRK = HMAC-SHA256(salt, IKM)
        val prk = hkdfExtract(salt, ikm)
        
        // 4. HKDF-Expand with domain separator and transcript hash
        val info = DOMAIN_SEPARATOR + transcriptHash
        val masterSecret = hkdfExpand(prk, info, MASTER_SECRET_LENGTH)
        
        // 5. Derive channel-specific keys
        val controlKey = deriveChannelKey(masterSecret, CONTROL_CHANNEL_INFO)
        val videoKey = deriveChannelKey(masterSecret, VIDEO_CHANNEL_INFO)
        val fileKey = deriveChannelKey(masterSecret, FILE_CHANNEL_INFO)
        
        return SessionKeys(controlKey, videoKey, fileKey)
    }
    
    /**
     * Derives session keys for classic-only mode (no PQC).
     * Uses empty byte array for pqcSecret.
     */
    fun deriveSessionKeysClassicOnly(
        classicSecret: ByteArray,
        clientRandom: ByteArray,
        serverRandom: ByteArray,
        transcriptHash: ByteArray
    ): SessionKeys {
        return deriveSessionKeys(
            classicSecret = classicSecret,
            pqcSecret = ByteArray(0),
            clientRandom = clientRandom,
            serverRandom = serverRandom,
            transcriptHash = transcriptHash
        )
    }
    
    /**
     * Derives a channel-specific key from master secret.
     */
    private fun deriveChannelKey(masterSecret: ByteArray, channelInfo: ByteArray): ByteArray {
        return hkdfExpand(masterSecret, channelInfo, CHANNEL_KEY_LENGTH)
    }
    
    /**
     * HKDF-Extract: PRK = HMAC-Hash(salt, IKM)
     * 
     * @param salt Optional salt value (can be zero-length)
     * @param ikm Input keying material
     * @return Pseudorandom key (PRK)
     */
    fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val effectiveSalt = if (salt.isEmpty()) ByteArray(32) else salt
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(effectiveSalt, "HmacSHA256"))
        return mac.doFinal(ikm)
    }
    
    /**
     * HKDF-Expand: OKM = HKDF-Expand(PRK, info, L)
     * 
     * @param prk Pseudorandom key from Extract
     * @param info Optional context and application specific information
     * @param length Length of output keying material in bytes
     * @return Output keying material (OKM)
     */
    fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length > 0) { "Length must be positive" }
        require(length <= 255 * 32) { "Length too large for HKDF-SHA256" }
        
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        
        val result = ByteArrayOutputStream()
        var t = ByteArray(0)
        var i = 1
        
        while (result.size() < length) {
            mac.reset()
            mac.update(t)
            mac.update(info)
            mac.update(i.toByte())
            t = mac.doFinal()
            result.write(t)
            i++
        }
        
        return result.toByteArray().copyOf(length)
    }
}
