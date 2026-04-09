package com.skybridge.compass.shared.crypto.models

/**
 * Session keys derived from hybrid key exchange.
 * 
 * Contains separate 32-byte keys for different communication channels:
 * - Control channel: signaling and control messages
 * - Video channel: screen mirroring data
 * - File channel: file transfer data
 * 
 * Each key is derived using HKDF with domain separation to ensure
 * cryptographic independence between channels.
 * 
 * @property controlKey 32-byte key for control channel (AES-256-GCM)
 * @property videoKey 32-byte key for video channel (AES-256-GCM)
 * @property fileKey 32-byte key for file transfer channel (AES-256-GCM)
 */
data class SessionKeys(
    val controlKey: ByteArray,
    val videoKey: ByteArray,
    val fileKey: ByteArray
) {
    init {
        require(controlKey.size == KEY_SIZE) {
            "controlKey must be $KEY_SIZE bytes, got ${controlKey.size}"
        }
        require(videoKey.size == KEY_SIZE) {
            "videoKey must be $KEY_SIZE bytes, got ${videoKey.size}"
        }
        require(fileKey.size == KEY_SIZE) {
            "fileKey must be $KEY_SIZE bytes, got ${fileKey.size}"
        }
    }
    
    /**
     * Checks if all three keys are distinct (no key reuse).
     */
    fun areKeysDistinct(): Boolean {
        return !controlKey.contentEquals(videoKey) &&
               !controlKey.contentEquals(fileKey) &&
               !videoKey.contentEquals(fileKey)
    }
    
    /**
     * Securely clears all keys from memory.
     * Call this when the session is terminated.
     */
    fun clear() {
        controlKey.fill(0)
        videoKey.fill(0)
        fileKey.fill(0)
    }
    
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SessionKeys) return false
        
        return controlKey.contentEquals(other.controlKey) &&
               videoKey.contentEquals(other.videoKey) &&
               fileKey.contentEquals(other.fileKey)
    }
    
    override fun hashCode(): Int {
        var result = controlKey.contentHashCode()
        result = 31 * result + videoKey.contentHashCode()
        result = 31 * result + fileKey.contentHashCode()
        return result
    }
    
    companion object {
        /** Expected key size in bytes (256 bits for AES-256) */
        const val KEY_SIZE = 32
    }
}
