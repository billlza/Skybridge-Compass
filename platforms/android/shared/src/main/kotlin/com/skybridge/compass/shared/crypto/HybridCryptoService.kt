package com.skybridge.compass.shared.crypto

import android.content.Context
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.SessionKeys
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Represents an established secure session.
 * 
 * @property sessionId Unique identifier for this session
 * @property sessionKeys The derived session keys
 * @property selectedSuite The negotiated crypto suite
 * @property transcriptHash Hash of the handshake transcript
 * @property isClient Whether this peer was the client (initiator)
 */
data class SecureSession(
    val sessionId: String,
    val sessionKeys: SessionKeys,
    val selectedSuite: CryptoSuite,
    val transcriptHash: ByteArray,
    val isClient: Boolean
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SecureSession) return false
        return sessionId == other.sessionId &&
               sessionKeys == other.sessionKeys &&
               selectedSuite == other.selectedSuite &&
               transcriptHash.contentEquals(other.transcriptHash) &&
               isClient == other.isClient
    }
    
    override fun hashCode(): Int {
        var result = sessionId.hashCode()
        result = 31 * result + sessionKeys.hashCode()
        result = 31 * result + selectedSuite.hashCode()
        result = 31 * result + transcriptHash.contentHashCode()
        result = 31 * result + isClient.hashCode()
        return result
    }
}

/**
 * Enum representing the communication channel for encryption.
 */
enum class Channel {
    CONTROL,
    VIDEO,
    FILE
}


/**
 * High-level service for hybrid cryptographic operations.
 * 
 * Coordinates handshake, key derivation, and message encryption/decryption
 * using the appropriate crypto providers based on negotiated suite.
 * 
 * This service provides a simple API for establishing secure sessions
 * and encrypting/decrypting messages across different channels.
 * 
 * @param context Android application context (for key storage)
 * @param providerFactory Factory for creating crypto providers
 * @param handshakeManager Manager for handshake protocol
 * @param keyManager Manager for key storage
 * 
 * _Requirements: 1.1_
 */
class HybridCryptoService(
    private val context: Context,
    private val providerFactory: CryptoProviderFactory = CryptoProviderFactory,
    private val handshakeManager: HandshakeManager = HandshakeManager(providerFactory),
    private val keyManager: SkyBridgeKeyManager = SkyBridgeKeyManager(context)
) {
    
    companion object {
        private const val TAG = "HybridCryptoService"
        
        /** AES-GCM parameters */
        private const val GCM_NONCE_LENGTH = 12
        private const val GCM_TAG_LENGTH = 128
        
        /** Algorithm for AES-GCM encryption */
        private const val AES_GCM_ALGORITHM = "AES/GCM/NoPadding"
    }
    
    private val secureRandom = SecureRandom()
    
    /** Currently active sessions, keyed by session ID */
    private val activeSessions = mutableMapOf<String, SecureSession>()

    
    /**
     * Establishes a secure session as the client (initiator).
     * 
     * Performs the V2 handshake protocol and derives session keys.
     * 
     * @param transport Transport layer for communication
     * @param preferredSuites Optional list of preferred suites (defaults to all supported)
     * @return The established secure session
     * @throws HandshakeException if handshake fails
     * 
     * _Requirements: 5.1, 6.1_
     */
    suspend fun establishSessionAsClient(
        transport: Transport,
        preferredSuites: List<CryptoSuite>? = null
    ): SecureSession {
        val suites = preferredSuites ?: providerFactory.getSupportedSuites()
        
        val result = handshakeManager.performHandshakeAsClient(
            transport = transport,
            localSuites = suites
        )
        
        val sessionId = generateSessionId()
        val session = SecureSession(
            sessionId = sessionId,
            sessionKeys = result.sessionKeys,
            selectedSuite = result.selectedSuite,
            transcriptHash = result.transcriptHash,
            isClient = true
        )
        
        activeSessions[sessionId] = session
        return session
    }
    
    /**
     * Establishes a secure session as the server (responder).
     * 
     * Waits for ClientHello, performs negotiation, and derives session keys.
     * 
     * @param transport Transport layer for communication
     * @param preferredSuites Optional list of preferred suites (defaults to all supported)
     * @return The established secure session
     * @throws HandshakeException if handshake fails
     * 
     * _Requirements: 5.3, 6.1_
     */
    suspend fun establishSessionAsServer(
        transport: Transport,
        preferredSuites: List<CryptoSuite>? = null
    ): SecureSession {
        val suites = preferredSuites ?: providerFactory.getSupportedSuites()
        
        val result = handshakeManager.performHandshakeAsServer(
            transport = transport,
            localSuites = suites
        )
        
        val sessionId = generateSessionId()
        val session = SecureSession(
            sessionId = sessionId,
            sessionKeys = result.sessionKeys,
            selectedSuite = result.selectedSuite,
            transcriptHash = result.transcriptHash,
            isClient = false
        )
        
        activeSessions[sessionId] = session
        return session
    }
    
    /**
     * Generates a unique session ID.
     */
    private fun generateSessionId(): String {
        val bytes = ByteArray(16)
        secureRandom.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
    
    /**
     * Gets an active session by ID.
     * 
     * @param sessionId The session ID
     * @return The session, or null if not found
     */
    fun getSession(sessionId: String): SecureSession? {
        return activeSessions[sessionId]
    }
    
    /**
     * Terminates a session and clears its keys.
     * 
     * @param sessionId The session ID to terminate
     */
    fun terminateSession(sessionId: String) {
        activeSessions.remove(sessionId)?.sessionKeys?.clear()
    }
    
    /**
     * Terminates all active sessions.
     */
    fun terminateAllSessions() {
        activeSessions.values.forEach { it.sessionKeys.clear() }
        activeSessions.clear()
    }

    
    /**
     * Encrypts a message using the session keys for the specified channel.
     * 
     * Uses AES-256-GCM with a random nonce. The output format is:
     * nonce(12B) || ciphertext || tag(16B)
     * 
     * @param session The secure session to use
     * @param plaintext The message to encrypt
     * @param channel The channel to use (determines which key is used)
     * @param associatedData Optional additional authenticated data (AAD)
     * @return The encrypted message (nonce + ciphertext + tag)
     * @throws CryptoOperationException if encryption fails
     * 
     * _Requirements: 1.1_
     */
    fun encryptMessage(
        session: SecureSession,
        plaintext: ByteArray,
        channel: Channel,
        associatedData: ByteArray? = null
    ): ByteArray {
        try {
            val key = getChannelKey(session.sessionKeys, channel)
            
            // Generate random nonce
            val nonce = ByteArray(GCM_NONCE_LENGTH)
            secureRandom.nextBytes(nonce)
            
            // Initialize cipher
            val cipher = Cipher.getInstance(AES_GCM_ALGORITHM)
            val keySpec = SecretKeySpec(key, "AES")
            val gcmSpec = GCMParameterSpec(GCM_TAG_LENGTH, nonce)
            cipher.init(Cipher.ENCRYPT_MODE, keySpec, gcmSpec)
            
            // Add AAD if provided
            if (associatedData != null) {
                cipher.updateAAD(associatedData)
            }
            
            // Encrypt
            val ciphertext = cipher.doFinal(plaintext)
            
            // Combine nonce + ciphertext (includes tag)
            return nonce + ciphertext
            
        } catch (e: Exception) {
            throw CryptoOperationException(
                operation = "encrypt",
                message = "Failed to encrypt message: ${e.message}",
                cause = e
            )
        }
    }
    
    /**
     * Decrypts a message using the session keys for the specified channel.
     * 
     * Expects input format: nonce(12B) || ciphertext || tag(16B)
     * 
     * @param session The secure session to use
     * @param ciphertext The encrypted message (nonce + ciphertext + tag)
     * @param channel The channel to use (determines which key is used)
     * @param associatedData Optional additional authenticated data (AAD)
     * @return The decrypted plaintext
     * @throws CryptoOperationException if decryption fails
     * 
     * _Requirements: 1.1_
     */
    fun decryptMessage(
        session: SecureSession,
        ciphertext: ByteArray,
        channel: Channel,
        associatedData: ByteArray? = null
    ): ByteArray {
        try {
            if (ciphertext.size < GCM_NONCE_LENGTH + GCM_TAG_LENGTH / 8) {
                throw CryptoOperationException(
                    operation = "decrypt",
                    message = "Ciphertext too short"
                )
            }
            
            val key = getChannelKey(session.sessionKeys, channel)
            
            // Extract nonce and encrypted data
            val nonce = ciphertext.copyOfRange(0, GCM_NONCE_LENGTH)
            val encryptedData = ciphertext.copyOfRange(GCM_NONCE_LENGTH, ciphertext.size)
            
            // Initialize cipher
            val cipher = Cipher.getInstance(AES_GCM_ALGORITHM)
            val keySpec = SecretKeySpec(key, "AES")
            val gcmSpec = GCMParameterSpec(GCM_TAG_LENGTH, nonce)
            cipher.init(Cipher.DECRYPT_MODE, keySpec, gcmSpec)
            
            // Add AAD if provided
            if (associatedData != null) {
                cipher.updateAAD(associatedData)
            }
            
            // Decrypt
            return cipher.doFinal(encryptedData)
            
        } catch (e: CryptoOperationException) {
            throw e
        } catch (e: Exception) {
            throw CryptoOperationException(
                operation = "decrypt",
                message = "Failed to decrypt message: ${e.message}",
                cause = e
            )
        }
    }
    
    /**
     * Gets the appropriate key for the specified channel.
     */
    private fun getChannelKey(sessionKeys: SessionKeys, channel: Channel): ByteArray {
        return when (channel) {
            Channel.CONTROL -> sessionKeys.controlKey
            Channel.VIDEO -> sessionKeys.videoKey
            Channel.FILE -> sessionKeys.fileKey
        }
    }
    
    /**
     * Encrypts a message for the control channel.
     * Convenience method for control messages.
     */
    fun encryptControlMessage(session: SecureSession, plaintext: ByteArray): ByteArray {
        return encryptMessage(session, plaintext, Channel.CONTROL)
    }
    
    /**
     * Decrypts a message from the control channel.
     * Convenience method for control messages.
     */
    fun decryptControlMessage(session: SecureSession, ciphertext: ByteArray): ByteArray {
        return decryptMessage(session, ciphertext, Channel.CONTROL)
    }
    
    /**
     * Encrypts data for the video channel.
     * Convenience method for video streaming.
     */
    fun encryptVideoData(session: SecureSession, data: ByteArray): ByteArray {
        return encryptMessage(session, data, Channel.VIDEO)
    }
    
    /**
     * Decrypts data from the video channel.
     * Convenience method for video streaming.
     */
    fun decryptVideoData(session: SecureSession, ciphertext: ByteArray): ByteArray {
        return decryptMessage(session, ciphertext, Channel.VIDEO)
    }
    
    /**
     * Encrypts data for the file transfer channel.
     * Convenience method for file transfers.
     */
    fun encryptFileData(session: SecureSession, data: ByteArray): ByteArray {
        return encryptMessage(session, data, Channel.FILE)
    }
    
    /**
     * Decrypts data from the file transfer channel.
     * Convenience method for file transfers.
     */
    fun decryptFileData(session: SecureSession, ciphertext: ByteArray): ByteArray {
        return decryptMessage(session, ciphertext, Channel.FILE)
    }
    
    /**
     * Returns the list of supported crypto suites on this device.
     */
    fun getSupportedSuites(): List<CryptoSuite> {
        return providerFactory.getSupportedSuites()
    }
    
    /**
     * Checks if PQC (Post-Quantum Cryptography) is available on this device.
     */
    fun isPQCAvailable(): Boolean {
        return providerFactory.isPQCAvailable()
    }
}
