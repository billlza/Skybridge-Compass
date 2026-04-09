package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.SessionKeys
import com.skybridge.compass.shared.crypto.protocol.DeviceCapabilities
import com.skybridge.compass.shared.crypto.protocol.HandshakeV2ClientHello
import com.skybridge.compass.shared.crypto.protocol.HandshakeV2ServerHello
import com.skybridge.compass.shared.crypto.protocol.KeyShare
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import javax.crypto.KeyAgreement

/**
 * Interface for transport layer used during handshake.
 * 
 * Implementations should handle the actual network communication.
 */
interface Transport {
    /**
     * Sends data to the remote peer.
     * 
     * @param data The data to send
     * @throws HandshakeException if sending fails
     */
    suspend fun send(data: ByteArray)
    
    /**
     * Receives data from the remote peer.
     * 
     * @return The received data
     * @throws HandshakeException if receiving fails or times out
     */
    suspend fun receive(): ByteArray
}

/**
 * Result of a successful handshake.
 * 
 * @property sessionKeys The derived session keys for encrypted communication
 * @property selectedSuite The negotiated crypto suite
 * @property transcriptHash Hash of the handshake transcript for verification
 */
data class HandshakeResult(
    val sessionKeys: SessionKeys,
    val selectedSuite: CryptoSuite,
    val transcriptHash: ByteArray
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HandshakeResult) return false
        return sessionKeys == other.sessionKeys &&
               selectedSuite == other.selectedSuite &&
               transcriptHash.contentEquals(other.transcriptHash)
    }
    
    override fun hashCode(): Int {
        var result = sessionKeys.hashCode()
        result = 31 * result + selectedSuite.hashCode()
        result = 31 * result + transcriptHash.contentHashCode()
        return result
    }
}


/**
 * Manages the SkyBridge V2 handshake protocol.
 *
 * Coordinates the exchange of ClientHello and ServerHello messages,
 * performs key exchange (both classic ECDH and PQC KEM), and derives
 * session keys using hybrid key derivation.
 *
 * PQC Support (ML-KEM-768 + ML-DSA-65):
 * - Client generates ML-KEM keypair and includes public key in extensions
 * - Server encapsulates shared secret using client's ML-KEM public key
 * - Both parties sign their messages using ML-DSA for authentication
 *
 * @param providerFactory Factory for creating crypto providers
 * @param telemetry Optional telemetry service for logging events
 */
class HandshakeManager(
    private val providerFactory: CryptoProviderFactory = CryptoProviderFactory,
    private val telemetry: CryptoTelemetry? = null
) {

    companion object {
        private const val TAG = "HandshakeManager"

        // Extension keys for PQC data
        const val EXT_PQC_KEM_PUBLIC_KEY = "pqc_kem_pk"
        const val EXT_PQC_SIGNATURE = "pqc_sig"
        const val EXT_PQC_SIGNING_PUBLIC_KEY = "pqc_sig_pk"

        // Cross-platform extension keys
        const val EXT_PEER_PLATFORM = "peer_platform"
        const val EXT_PEER_API_LEVEL = "peer_api_level"
        const val EXT_SIGNATURE_ALGORITHM = "sig_alg"
        const val EXT_CLASSIC_SIGNATURE = "classic_sig"
        const val EXT_CLASSIC_SIGNING_PUBLIC_KEY = "classic_sig_pk"

        // Platform identifiers
        const val PLATFORM_ANDROID = "android"
        const val PLATFORM_IOS = "ios"
        const val PLATFORM_MACOS = "macos"

        // Signature algorithm identifiers
        const val SIG_ALG_ML_DSA_65 = "ML-DSA-65"
        const val SIG_ALG_ED25519 = "Ed25519"
        const val SIG_ALG_ECDSA_P256 = "ECDSA-P256"
    }

    // Lazily initialized PQC provider (only when PQC suite is negotiated)
    private val pqcProvider: AndroidPQCCryptoProvider? by lazy {
        if (AndroidPQCCryptoProvider.isAvailable()) {
            try {
                AndroidPQCCryptoProvider()
            } catch (e: Exception) {
                null
            }
        } else {
            null
        }
    }
    
    /**
     * Performs handshake as the client (initiator).
     *
     * Flow:
     * 1. Generate client random and classic key share
     * 2. Generate PQC KEM key pair (if PQC suites supported)
     * 3. Send ClientHello with supported suites and PQC public key
     * 4. Receive ServerHello with selected suite and key shares
     * 5. Perform classic ECDH key agreement
     * 6. Decrypt PQC encapsulated secret (if PQC suite selected)
     * 7. Verify server's ML-DSA signature on transcript
     * 8. Derive session keys using hybrid key derivation
     *
     * @param transport Transport layer for sending/receiving messages
     * @param localSuites List of supported crypto suites in priority order
     * @param deviceCaps Optional device capabilities to advertise
     * @param signingKeyPair Optional ML-DSA signing key pair for client authentication
     * @return HandshakeResult containing session keys and metadata
     * @throws HandshakeException if handshake fails
     *
     * _Requirements: 5.1, 5.2, 5.3, 6.1_
     */
    suspend fun performHandshakeAsClient(
        transport: Transport,
        localSuites: List<CryptoSuite> = providerFactory.getSupportedSuites(),
        deviceCaps: DeviceCapabilities = DeviceCapabilities(),
        signingKeyPair: com.skybridge.compass.shared.crypto.models.KeyPair? = null
    ): HandshakeResult {
        try {
            // 1. Generate client random
            val clientRandom = SecureRandom().generateSeed(32)

            // 2. Generate classic key pair for ECDH
            val (classicKeyPair, classicGroup) = generateClassicKeyPair()
            val clientKeyShare = KeyShare(classicGroup, classicKeyPair.public.encoded)

            // 3. Generate PQC KEM key pair if provider is available
            val pqcKemKeyPair = if (pqcProvider != null && localSuites.any { it.isPQC }) {
                pqcProvider!!.generateKeyPair(KeyUsage.KEY_EXCHANGE)
            } else null

            // 4. Build extensions with PQC public key and platform info
            val extensions = mutableMapOf<String, ByteArray>()
            if (pqcKemKeyPair != null) {
                extensions[EXT_PQC_KEM_PUBLIC_KEY] = pqcKemKeyPair.publicKey.bytes
            }
            // Add platform identification for cross-platform compatibility
            extensions[EXT_PEER_PLATFORM] = PLATFORM_ANDROID.toByteArray(Charsets.UTF_8)
            extensions[EXT_PEER_API_LEVEL] = PlatformCompat.apiLevel.toString().toByteArray(Charsets.UTF_8)

            // 5. Build and send ClientHello
            val clientHello = HandshakeV2ClientHello(
                supportedSuites = localSuites,
                deviceCaps = deviceCaps,
                clientRandom = clientRandom,
                clientKeyShare = clientKeyShare,
                extensions = extensions
            )

            val clientHelloBytes = clientHello.serialize()
            transport.send(clientHelloBytes)

            // 6. Receive ServerHello
            val serverHelloBytes = transport.receive()
            val serverHello = HandshakeV2ServerHello.parse(serverHelloBytes)

            // 7. Validate selected suite is one we support
            if (serverHello.selectedSuite !in localSuites) {
                throw HandshakeException(
                    "ClientHandshake",
                    "Server selected unsupported suite: ${serverHello.selectedSuite.rawValue}"
                )
            }

            // 8. Compute transcript hash (canonical: ServerHello with transcriptHash=0s and no extensions)
            val serverHelloForHashBytes = serverHello.copy(
                transcriptHash = ByteArray(32),
                extensions = emptyMap()
            ).serialize()
            val transcriptHash = computeTranscriptHash(clientHelloBytes, serverHelloForHashBytes)

            // Verify transcript hash matches server's announced hash
            if (!transcriptHash.contentEquals(serverHello.transcriptHash)) {
                throw HandshakeException(
                    "ClientHandshake",
                    "Transcript hash mismatch"
                )
            }

            // 9. Perform classic ECDH key agreement
            val classicSecret = performECDH(
                classicKeyPair.private as java.security.PrivateKey,
                serverHello.serverKeyShare.keyExchange,
                classicGroup
            )

            // 10. Decrypt PQC encapsulated secret (if PQC suite selected)
            val pqcSecret: ByteArray = if (serverHello.selectedSuite.isPQC &&
                serverHello.pqcEncapsulated.isNotEmpty() &&
                pqcKemKeyPair != null &&
                pqcProvider != null
            ) {
                try {
                    // Server encapsulated to our PQC public key, we decapsulate
                    pqcProvider!!.decapsulate(
                        serverHello.pqcEncapsulated,
                        pqcKemKeyPair.privateKey.bytes
                    )
                } catch (e: Exception) {
                    telemetry?.recordEvent("crypto_pqc_decapsulation_failed", mapOf(
                        "error" to (e.message ?: "Unknown")
                    ))
                    ByteArray(0)
                }
            } else {
                ByteArray(0)
            }

            // If PQC suite was negotiated, failing PQC derivation is a hard error (prevents downgrade).
            if (serverHello.selectedSuite.isPQC && pqcSecret.isEmpty()) {
                throw HandshakeException(
                    "ClientHandshake",
                    "PQC suite negotiated but PQC secret derivation failed"
                )
            }

            // 12. Verify server's signature (supports ML-DSA, Ed25519, ECDSA for Apple compatibility)
            verifyServerSignature(
                serverHello = serverHello,
                transcriptHash = transcriptHash,
                selectedSuite = serverHello.selectedSuite
            )

            // 13. Derive session keys using appropriate strategy based on peer platform
            val peerPlatform = serverHello.extensions[EXT_PEER_PLATFORM]?.toString(Charsets.UTF_8)
            val kdfStrategy = CrossPlatformKeyDerivation.selectStrategy(peerPlatform)
            
            val sessionKeys = when (kdfStrategy) {
                CrossPlatformKeyDerivation.KeyDerivationStrategy.APPLE_COMPATIBLE -> {
                    // Use Apple-compatible key derivation for iOS/macOS peers
                    CrossPlatformKeyDerivation.deriveSessionKeys(
                        classicSecret = classicSecret,
                        pqcSecret = pqcSecret,
                        clientRandom = clientRandom,
                        serverRandom = serverHello.serverRandom,
                        transcriptHash = transcriptHash
                    )
                }
                CrossPlatformKeyDerivation.KeyDerivationStrategy.NATIVE_ANDROID -> {
                    // Use native Android key derivation for Android peers
                    HybridKeyDerivation.deriveSessionKeys(
                        classicSecret = classicSecret,
                        pqcSecret = pqcSecret,
                        clientRandom = clientRandom,
                        serverRandom = serverHello.serverRandom,
                        transcriptHash = transcriptHash
                    )
                }
            }

            // Log telemetry
            val eventName = if (serverHello.selectedSuite.isPQC && pqcSecret.isNotEmpty()) {
                CryptoTelemetry.EVENT_PQC_HANDSHAKE_SUCCESS
            } else {
                CryptoTelemetry.EVENT_CLASSIC_HANDSHAKE_SUCCESS
            }
            telemetry?.recordEvent(eventName, mapOf(
                "suite" to serverHello.selectedSuite.rawValue,
                "is_client" to true,
                "pqc_secret_derived" to pqcSecret.isNotEmpty()
            ))

            return HandshakeResult(
                sessionKeys = sessionKeys,
                selectedSuite = serverHello.selectedSuite,
                transcriptHash = transcriptHash
            )

        } catch (e: HandshakeException) {
            telemetry?.recordEvent(CryptoTelemetry.EVENT_HANDSHAKE_FAILURE, mapOf(
                "is_client" to true,
                "error" to (e.message ?: "Unknown")
            ))
            throw e
        } catch (e: Exception) {
            telemetry?.recordEvent(CryptoTelemetry.EVENT_HANDSHAKE_FAILURE, mapOf(
                "is_client" to true,
                "error" to (e.message ?: "Unknown")
            ))
            throw HandshakeException(
                "ClientHandshake",
                "Handshake failed: ${e.message}",
                e
            )
        }
    }

    
    /**
     * Performs handshake as the server (responder).
     *
     * Flow:
     * 1. Receive ClientHello with client's supported suites and PQC public key
     * 2. Select best common suite
     * 3. Generate server random and classic key share
     * 4. Perform PQC encapsulation using client's ML-KEM public key (if PQC suite)
     * 5. Compute transcript hash
     * 6. Sign transcript with ML-DSA (if PQC suite and signing key provided)
     * 7. Send ServerHello with PQC ciphertext and signature
     * 8. Perform classic ECDH key agreement
     * 9. Derive session keys using hybrid key derivation
     *
     * @param transport Transport layer for sending/receiving messages
     * @param localSuites List of supported crypto suites in priority order
     * @param signingKeyPair Optional ML-DSA signing key pair for server authentication
     * @return HandshakeResult containing session keys and metadata
     * @throws HandshakeException if handshake fails
     *
     * _Requirements: 5.3, 6.1_
     */
    suspend fun performHandshakeAsServer(
        transport: Transport,
        localSuites: List<CryptoSuite> = providerFactory.getSupportedSuites(),
        signingKeyPair: com.skybridge.compass.shared.crypto.models.KeyPair? = null
    ): HandshakeResult {
        try {
            // 1. Receive ClientHello
            val clientHelloBytes = transport.receive()
            val clientHello = HandshakeV2ClientHello.parse(clientHelloBytes)

            // 2. Negotiate suite - select highest priority common suite
            val selectedSuite = CryptoSuiteNegotiator.negotiate(
                localSuites = localSuites,
                remoteSuites = clientHello.supportedSuites
            )

            // 3. Generate server random
            val serverRandom = SecureRandom().generateSeed(32)

            // 4. Generate classic key pair for ECDH (match client's group)
            val clientGroup = clientHello.clientKeyShare.group
            val (classicKeyPair, _) = generateClassicKeyPair(clientGroup)
            val serverKeyShare = KeyShare(clientGroup, classicKeyPair.public.encoded)

            // 5. Perform PQC encapsulation if PQC suite selected and client provided PQC public key
            val (pqcEncapsulated, pqcSecret) = if (selectedSuite.isPQC && pqcProvider != null) {
                // Extract client's PQC public key from extensions
                val clientPqcPublicKey = clientHello.extensions[EXT_PQC_KEM_PUBLIC_KEY]

                if (clientPqcPublicKey != null &&
                    clientPqcPublicKey.size == AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE
                ) {
                    try {
                        // Encapsulate to client's PQC public key
                        val (ciphertext, secret) = pqcProvider!!.encapsulate(clientPqcPublicKey)

                        telemetry?.recordEvent("crypto_pqc_encapsulation_success", mapOf(
                            "ciphertext_size" to ciphertext.size
                        ))
                        ciphertext to secret
                    } catch (e: Exception) {
                        // Log error but continue with classic-only
                        telemetry?.recordEvent("crypto_pqc_encapsulation_failed", mapOf(
                            "error" to (e.message ?: "Unknown")
                        ))
                        ByteArray(0) to ByteArray(0)
                    }
                } else {
                    // Client didn't provide PQC public key or it's invalid
                    telemetry?.recordEvent("crypto_pqc_client_key_missing")
                    ByteArray(0) to ByteArray(0)
                }
            } else {
                ByteArray(0) to ByteArray(0)
            }

            // If PQC suite was negotiated, failing PQC derivation is a hard error (prevents downgrade).
            if (selectedSuite.isPQC && pqcSecret.isEmpty()) {
                throw HandshakeException(
                    "ServerHandshake",
                    "PQC suite negotiated but PQC encapsulation failed"
                )
            }

            // 6. Build extensions with PQC signature and platform info
            val serverExtensions = mutableMapOf<String, ByteArray>()

            // Add platform identification for cross-platform compatibility
            serverExtensions[EXT_PEER_PLATFORM] = PLATFORM_ANDROID.toByteArray(Charsets.UTF_8)
            serverExtensions[EXT_PEER_API_LEVEL] = PlatformCompat.apiLevel.toString().toByteArray(Charsets.UTF_8)

            // Detect peer platform from client extensions
            val peerPlatform = clientHello.extensions[EXT_PEER_PLATFORM]?.toString(Charsets.UTF_8) ?: "unknown"
            val peerApiLevel = clientHello.extensions[EXT_PEER_API_LEVEL]?.toString(Charsets.UTF_8)?.toIntOrNull() ?: 0

            // 7. Build ServerHello (need transcript hash first)
            // Use the canonical hash input shape: zeroed transcriptHash and no extensions.
            val serverHelloForHash = HandshakeV2ServerHello(
                selectedSuite = selectedSuite,
                serverRandom = serverRandom,
                serverKeyShare = serverKeyShare,
                pqcEncapsulated = pqcEncapsulated,
                transcriptHash = ByteArray(32), // canonical zeroed field before hashing
                extensions = emptyMap()
            )

            // Compute final transcript hash
            val serverHelloBytesForHash = serverHelloForHash.serialize()
            val transcriptHash = computeTranscriptHash(clientHelloBytes, serverHelloBytesForHash)

            // 8. Sign transcript - use appropriate algorithm based on peer platform
            signServerResponse(
                serverExtensions = serverExtensions,
                transcriptHash = transcriptHash,
                selectedSuite = selectedSuite,
                signingKeyPair = signingKeyPair,
                peerPlatform = peerPlatform,
                peerApiLevel = peerApiLevel
            )

            // Create final ServerHello with correct transcript hash and extensions
            val serverHello = serverHelloForHash.copy(
                transcriptHash = transcriptHash,
                extensions = serverExtensions
            )
            val serverHelloBytes = serverHello.serialize()

            // 7. Send ServerHello
            transport.send(serverHelloBytes)

            // 8. Perform classic ECDH key agreement
            val classicSecret = performECDH(
                classicKeyPair.private as java.security.PrivateKey,
                clientHello.clientKeyShare.keyExchange,
                clientGroup
            )

            // 9. Derive session keys using appropriate strategy based on peer platform
            val kdfStrategy = CrossPlatformKeyDerivation.selectStrategy(peerPlatform)
            
            val sessionKeys = when (kdfStrategy) {
                CrossPlatformKeyDerivation.KeyDerivationStrategy.APPLE_COMPATIBLE -> {
                    // Use Apple-compatible key derivation for iOS/macOS peers
                    CrossPlatformKeyDerivation.deriveSessionKeys(
                        classicSecret = classicSecret,
                        pqcSecret = pqcSecret,
                        clientRandom = clientHello.clientRandom,
                        serverRandom = serverRandom,
                        transcriptHash = transcriptHash
                    )
                }
                CrossPlatformKeyDerivation.KeyDerivationStrategy.NATIVE_ANDROID -> {
                    // Use native Android key derivation for Android peers
                    HybridKeyDerivation.deriveSessionKeys(
                        classicSecret = classicSecret,
                        pqcSecret = pqcSecret,
                        clientRandom = clientHello.clientRandom,
                        serverRandom = serverRandom,
                        transcriptHash = transcriptHash
                    )
                }
            }

            // Log telemetry
            val eventName = if (selectedSuite.isPQC && pqcSecret.isNotEmpty()) {
                CryptoTelemetry.EVENT_PQC_HANDSHAKE_SUCCESS
            } else {
                CryptoTelemetry.EVENT_CLASSIC_HANDSHAKE_SUCCESS
            }
            telemetry?.recordEvent(eventName, mapOf(
                "suite" to selectedSuite.rawValue,
                "is_client" to false,
                "pqc_secret_derived" to pqcSecret.isNotEmpty()
            ))

            return HandshakeResult(
                sessionKeys = sessionKeys,
                selectedSuite = selectedSuite,
                transcriptHash = transcriptHash
            )

        } catch (e: CryptoNegotiationException) {
            telemetry?.recordEvent(CryptoTelemetry.EVENT_HANDSHAKE_FAILURE, mapOf(
                "is_client" to false,
                "error" to "No common suite"
            ))
            throw HandshakeException(
                "ServerHandshake",
                "Suite negotiation failed: ${e.message}",
                e
            )
        } catch (e: HandshakeException) {
            telemetry?.recordEvent(CryptoTelemetry.EVENT_HANDSHAKE_FAILURE, mapOf(
                "is_client" to false,
                "error" to (e.message ?: "Unknown")
            ))
            throw e
        } catch (e: Exception) {
            telemetry?.recordEvent(CryptoTelemetry.EVENT_HANDSHAKE_FAILURE, mapOf(
                "is_client" to false,
                "error" to (e.message ?: "Unknown")
            ))
            throw HandshakeException(
                "ServerHandshake",
                "Handshake failed: ${e.message}",
                e
            )
        }
    }

    
    /**
     * Generates a classic key pair for ECDH key exchange.
     * 
     * @param preferredGroup Optional preferred group (X25519 or P-256)
     * @return Pair of generated key pair and the group used
     */
    private fun generateClassicKeyPair(
        preferredGroup: UShort = KeyShare.GROUP_P256
    ): Pair<java.security.KeyPair, UShort> {
        // Use P-256 as it's more widely supported
        // X25519 would require additional library support
        val keyPairGenerator = KeyPairGenerator.getInstance("EC")
        keyPairGenerator.initialize(ECGenParameterSpec("secp256r1"))
        val keyPair = keyPairGenerator.generateKeyPair()
        
        return keyPair to KeyShare.GROUP_P256
    }
    
    /**
     * Performs ECDH key agreement.
     * 
     * @param privateKey Our private key
     * @param peerPublicKeyBytes Peer's public key bytes
     * @param group The named group (curve) being used
     * @return The shared secret
     */
    private fun performECDH(
        privateKey: java.security.PrivateKey,
        peerPublicKeyBytes: ByteArray,
        group: UShort
    ): ByteArray {
        // Decode peer's public key
        val keyFactory = java.security.KeyFactory.getInstance("EC")
        val peerPublicKey = keyFactory.generatePublic(
            java.security.spec.X509EncodedKeySpec(peerPublicKeyBytes)
        )
        
        // Perform key agreement
        val keyAgreement = KeyAgreement.getInstance("ECDH")
        keyAgreement.init(privateKey)
        keyAgreement.doPhase(peerPublicKey, true)
        
        return keyAgreement.generateSecret()
    }
    
    /**
     * Computes the transcript hash of handshake messages.
     *
     * @param clientHelloBytes Serialized ClientHello
     * @param serverHelloBytes Serialized ServerHello
     * @return SHA-256 hash of the transcript
     */
    private fun computeTranscriptHash(
        clientHelloBytes: ByteArray,
        serverHelloBytes: ByteArray
    ): ByteArray {
        return MessageDigest.getInstance("SHA-256").apply {
            update(clientHelloBytes)
            update(serverHelloBytes)
        }.digest()
    }

    // ========== Cross-Platform Signature Methods ==========

    /**
     * Verifies server signature with automatic algorithm detection.
     * Supports ML-DSA-65, Ed25519, and ECDSA P-256 for Apple CryptoKit compatibility.
     *
     * Algorithm selection priority:
     * 1. ML-DSA-65 (if PQC suite and both peers support it)
     * 2. Ed25519 (if Android 13+ and Apple peer)
     * 3. ECDSA P-256 (universal fallback)
     *
     * @param serverHello The received ServerHello message
     * @param transcriptHash The computed transcript hash
     * @param selectedSuite The negotiated crypto suite
     * @throws HandshakeException if signature verification fails
     */
    private suspend fun verifyServerSignature(
        serverHello: HandshakeV2ServerHello,
        transcriptHash: ByteArray,
        selectedSuite: CryptoSuite
    ) {
        // Get peer platform information
        val peerPlatform = serverHello.extensions[EXT_PEER_PLATFORM]?.toString(Charsets.UTF_8) ?: "unknown"
        val peerApiLevel = serverHello.extensions[EXT_PEER_API_LEVEL]?.toString(Charsets.UTF_8)?.toIntOrNull() ?: 0
        val signatureAlgorithm = serverHello.extensions[EXT_SIGNATURE_ALGORITHM]?.toString(Charsets.UTF_8)

        telemetry?.recordEvent("crypto_verify_start", mapOf(
            "peer_platform" to peerPlatform,
            "peer_api_level" to peerApiLevel,
            "signature_algorithm" to (signatureAlgorithm ?: "auto")
        ))

        // Try PQC signature first (if available)
        val pqcSignature = serverHello.extensions[EXT_PQC_SIGNATURE]
        val pqcSigningPublicKey = serverHello.extensions[EXT_PQC_SIGNING_PUBLIC_KEY]

        if (selectedSuite.isPQC && pqcSignature != null && pqcSigningPublicKey != null && pqcProvider != null) {
            try {
                // Use verifyWithFallback for cross-platform compatibility
                val isValid = pqcProvider!!.verifyWithFallback(
                    transcriptHash,
                    pqcSignature,
                    pqcSigningPublicKey
                )
                if (!isValid) {
                    throw HandshakeException(
                        "ClientHandshake",
                        "Server PQC signature verification failed"
                    )
                }
                telemetry?.recordEvent("crypto_pqc_signature_verified", mapOf(
                    "algorithm" to SIG_ALG_ML_DSA_65,
                    "public_key_size" to pqcSigningPublicKey.size
                ))
                return // PQC verification succeeded
            } catch (e: HandshakeException) {
                throw e
            } catch (e: Exception) {
                telemetry?.recordEvent("crypto_pqc_signature_verify_error", mapOf(
                    "error" to (e.message ?: "Unknown")
                ))
                // Fall through to try classic signature
            }
        }

        // Try classic signature (Ed25519 or ECDSA)
        val classicSignature = serverHello.extensions[EXT_CLASSIC_SIGNATURE]
        val classicSigningPublicKey = serverHello.extensions[EXT_CLASSIC_SIGNING_PUBLIC_KEY]

        if (classicSignature != null && classicSigningPublicKey != null) {
            try {
                val isValid = if (pqcProvider != null) {
                    // Use cross-platform verifier
                    pqcProvider!!.verifyWithFallback(
                        transcriptHash,
                        classicSignature,
                        classicSigningPublicKey
                    )
                } else {
                    // Direct verification based on key size
                    verifyClassicSignature(transcriptHash, classicSignature, classicSigningPublicKey)
                }

                if (!isValid) {
                    throw HandshakeException(
                        "ClientHandshake",
                        "Server classic signature verification failed"
                    )
                }

                val algorithm = when (classicSigningPublicKey.size) {
                    32 -> SIG_ALG_ED25519
                    else -> SIG_ALG_ECDSA_P256
                }
                telemetry?.recordEvent("crypto_classic_signature_verified", mapOf(
                    "algorithm" to algorithm,
                    "public_key_size" to classicSigningPublicKey.size
                ))
                return // Classic verification succeeded
            } catch (e: HandshakeException) {
                throw e
            } catch (e: Exception) {
                telemetry?.recordEvent("crypto_classic_signature_verify_error", mapOf(
                    "error" to (e.message ?: "Unknown")
                ))
            }
        }

        // No signature found - this is acceptable for some configurations
        telemetry?.recordEvent("crypto_signature_missing", mapOf(
            "peer_platform" to peerPlatform,
            "selected_suite" to selectedSuite.rawValue
        ))
    }

    /**
     * Signs the server response with appropriate algorithm for cross-platform compatibility.
     *
     * Signs with both PQC (ML-DSA-65) and classic (Ed25519/ECDSA) when peer may not support PQC.
     *
     * @param serverExtensions Mutable map to add signature extensions
     * @param transcriptHash The transcript hash to sign
     * @param selectedSuite The negotiated crypto suite
     * @param signingKeyPair Optional ML-DSA signing key pair
     * @param peerPlatform The peer's platform identifier
     * @param peerApiLevel The peer's API level (for Android)
     */
    private suspend fun signServerResponse(
        serverExtensions: MutableMap<String, ByteArray>,
        transcriptHash: ByteArray,
        selectedSuite: CryptoSuite,
        signingKeyPair: com.skybridge.compass.shared.crypto.models.KeyPair?,
        peerPlatform: String,
        peerApiLevel: Int
    ) {
        // Determine recommended signature mode based on peer capabilities
        val signatureMode = PlatformCompat.getRecommendedSignatureMode(peerPlatform, peerApiLevel)

        telemetry?.recordEvent("crypto_sign_start", mapOf(
            "peer_platform" to peerPlatform,
            "peer_api_level" to peerApiLevel,
            "signature_mode" to signatureMode.name
        ))

        // Sign with ML-DSA if PQC suite and signing key available
        if (selectedSuite.isPQC && signingKeyPair != null && pqcProvider != null) {
            try {
                val signature = pqcProvider!!.sign(transcriptHash, signingKeyPair.privateKey.bytes)
                serverExtensions[EXT_PQC_SIGNATURE] = signature
                serverExtensions[EXT_PQC_SIGNING_PUBLIC_KEY] = signingKeyPair.publicKey.bytes
                serverExtensions[EXT_SIGNATURE_ALGORITHM] = SIG_ALG_ML_DSA_65.toByteArray(Charsets.UTF_8)

                telemetry?.recordEvent("crypto_pqc_signature_generated", mapOf(
                    "signature_size" to signature.size
                ))
            } catch (e: Exception) {
                telemetry?.recordEvent("crypto_pqc_signature_failed", mapOf(
                    "error" to (e.message ?: "Unknown")
                ))
            }
        }

        // Also sign with classic algorithm for Apple compatibility if peer may not support PQC
        if (signatureMode != PlatformCompat.SignatureMode.PQC_ML_DSA ||
            peerPlatform in listOf(PLATFORM_IOS, PLATFORM_MACOS)
        ) {
            try {
                val (classicSig, classicPubKey) = generateClassicSignature(transcriptHash)
                if (classicSig != null && classicPubKey != null) {
                    serverExtensions[EXT_CLASSIC_SIGNATURE] = classicSig
                    serverExtensions[EXT_CLASSIC_SIGNING_PUBLIC_KEY] = classicPubKey

                    val algorithm = if (PlatformCompat.apiLevel >= 33) SIG_ALG_ED25519 else SIG_ALG_ECDSA_P256
                    serverExtensions[EXT_SIGNATURE_ALGORITHM] = algorithm.toByteArray(Charsets.UTF_8)

                    telemetry?.recordEvent("crypto_classic_signature_generated", mapOf(
                        "algorithm" to algorithm,
                        "signature_size" to classicSig.size
                    ))
                }
            } catch (e: Exception) {
                telemetry?.recordEvent("crypto_classic_signature_failed", mapOf(
                    "error" to (e.message ?: "Unknown")
                ))
            }
        }
    }

    /**
     * Generates a classic signature (Ed25519 or ECDSA P-256) for cross-platform compatibility.
     *
     * @param data Data to sign
     * @return Pair of (signature, public key) or (null, null) on failure
     */
    private fun generateClassicSignature(data: ByteArray): Pair<ByteArray?, ByteArray?> {
        return try {
            if (PlatformCompat.apiLevel >= 33) {
                // Use Ed25519 on Android 13+
                val (privateKey, rawPubKey) = com.skybridge.compass.shared.p2p.P2PHandshakeWire.generateEd25519IdentityKeyPair()

                val signature = Signature.getInstance("Ed25519")
                signature.initSign(privateKey)
                signature.update(data)
                val sig = signature.sign()

                sig to rawPubKey
            } else {
                // Use ECDSA P-256 on older Android versions
                val keyPairGenerator = KeyPairGenerator.getInstance("EC")
                keyPairGenerator.initialize(ECGenParameterSpec("secp256r1"))
                val keyPair = keyPairGenerator.generateKeyPair()

                val signature = Signature.getInstance("SHA256withECDSA")
                signature.initSign(keyPair.private)
                signature.update(data)
                val sig = signature.sign()

                // Get raw public key (65 bytes uncompressed)
                val ecPublicKey = keyPair.public as ECPublicKey
                val rawPubKey = getUncompressedPublicKey(ecPublicKey)

                // Convert DER signature to raw (r||s) format for Apple compatibility
                val rawSig = derToRawSignature(sig)

                rawSig to rawPubKey
            }
        } catch (e: Exception) {
            telemetry?.recordEvent("crypto_classic_keygen_failed", mapOf(
                "error" to (e.message ?: "Unknown")
            ))
            null to null
        }
    }

    /**
     * Verifies a classic signature (Ed25519 or ECDSA) based on public key format.
     *
     * @param data Original data
     * @param signature Signature to verify
     * @param publicKey Public key (format detected by size)
     * @return true if signature is valid
     */
    private fun verifyClassicSignature(
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean {
        return try {
            when {
                // Ed25519 public key (32 bytes)
                publicKey.size == 32 && PlatformCompat.apiLevel >= 33 -> {
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
                }
                // ECDSA P-256 public key (65 bytes uncompressed or 33 bytes compressed)
                publicKey.size in listOf(33, 65) -> {
                    val keyFactory = java.security.KeyFactory.getInstance("EC")
                    val keySpec = java.security.spec.X509EncodedKeySpec(
                        createX509PublicKeyBytes(publicKey)
                    )
                    val pubKey = keyFactory.generatePublic(keySpec)

                    val sig = Signature.getInstance("SHA256withECDSA")
                    sig.initVerify(pubKey)
                    sig.update(data)

                    // Convert raw signature to DER if needed
                    val derSig = if (signature.size == 64) {
                        rawToDerSignature(signature)
                    } else {
                        signature
                    }
                    sig.verify(derSig)
                }
                else -> false
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Gets uncompressed public key bytes (0x04 || x || y) from ECPublicKey.
     */
    private fun getUncompressedPublicKey(ecPublicKey: ECPublicKey): ByteArray {
        val point = ecPublicKey.w
        val x = point.affineX.toByteArray().let {
            if (it.size > 32) it.sliceArray(it.size - 32 until it.size)
            else if (it.size < 32) ByteArray(32 - it.size) + it
            else it
        }
        val y = point.affineY.toByteArray().let {
            if (it.size > 32) it.sliceArray(it.size - 32 until it.size)
            else if (it.size < 32) ByteArray(32 - it.size) + it
            else it
        }
        return byteArrayOf(0x04) + x + y
    }

    /**
     * Creates X.509 SubjectPublicKeyInfo bytes for P-256 public key.
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
     * Converts raw signature (r||s) to DER format.
     */
    private fun rawToDerSignature(raw: ByteArray): ByteArray {
        require(raw.size == 64) { "Raw signature must be 64 bytes (r||s)" }

        val r = raw.sliceArray(0 until 32)
        val s = raw.sliceArray(32 until 64)

        fun encodeInteger(bytes: ByteArray): ByteArray {
            var start = 0
            while (start < bytes.size - 1 && bytes[start] == 0.toByte()) {
                start++
            }
            val trimmed = bytes.sliceArray(start until bytes.size)
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
     * Converts DER signature to raw format (r||s).
     */
    private fun derToRawSignature(der: ByteArray): ByteArray {
        require(der[0] == 0x30.toByte()) { "Invalid DER signature" }

        var offset = 2 // Skip SEQUENCE tag and length

        // Read R
        require(der[offset] == 0x02.toByte()) { "Invalid DER signature: expected INTEGER" }
        offset++
        val rLen = der[offset].toInt() and 0xFF
        offset++
        val rBytes = der.sliceArray(offset until offset + rLen)
        offset += rLen

        // Read S
        require(der[offset] == 0x02.toByte()) { "Invalid DER signature: expected INTEGER" }
        offset++
        val sLen = der[offset].toInt() and 0xFF
        offset++
        val sBytes = der.sliceArray(offset until offset + sLen)

        // Normalize to 32 bytes each
        fun normalize(bytes: ByteArray): ByteArray {
            return when {
                bytes.size > 32 -> bytes.sliceArray(bytes.size - 32 until bytes.size)
                bytes.size < 32 -> ByteArray(32 - bytes.size) + bytes
                else -> bytes
            }
        }

        return normalize(rBytes) + normalize(sBytes)
    }
}
