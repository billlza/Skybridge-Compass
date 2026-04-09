package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.SessionKeys
import java.security.MessageDigest

/**
 * Cross-platform key derivation for iOS/macOS compatibility.
 *
 * This module provides key derivation functions that match the Apple
 * CryptoKit HybridCryptoService implementation, ensuring Android devices
 * can successfully establish encrypted sessions with iOS/macOS peers.
 *
 * Key differences from HybridKeyDerivation:
 * - Uses fixed salt "SkyBridgeHybridKDF" (matches Apple)
 * - Uses fixed info "hybrid-key-exchange" (matches Apple)
 * - Outputs 32-byte combined secret first, then derives channel keys
 *
 * Reference: SkyBridge Compass Pro release - Sources/SkyBridgeCore/Protocol/HybridCrypto.swift
 *
 * _Requirements: Cross-platform PQC handshake compatibility_
 */
object CrossPlatformKeyDerivation {

    private const val TAG = "CrossPlatformKDF"

    // Apple-compatible HKDF parameters (from HybridCrypto.swift)
    private val APPLE_KDF_SALT = "SkyBridgeHybridKDF".toByteArray(Charsets.UTF_8)
    private val APPLE_KDF_INFO = "hybrid-key-exchange".toByteArray(Charsets.UTF_8)

    // SkyBridge channel key derivation labels
    private val CONTROL_CHANNEL_INFO = "skybridge-control-v1".toByteArray(Charsets.UTF_8)
    private val VIDEO_CHANNEL_INFO = "skybridge-video-v1".toByteArray(Charsets.UTF_8)
    private val FILE_CHANNEL_INFO = "skybridge-file-v1".toByteArray(Charsets.UTF_8)

    // P2P session key derivation template (matches Apple P2PHandshakeManager)
    private const val P2P_SESSION_INFO_PREFIX = "session-"

    /**
     * Combines classic and PQC shared secrets using Apple-compatible HKDF.
     *
     * This matches `HybridCryptoService.combineSharedSecrets()` in Swift:
     * ```swift
     * let inputKey = SymmetricKey(data: combined)
     * let derivedKey = HKDF<SHA256>.deriveKey(
     *     inputKeyMaterial: inputKey,
     *     salt: Data("SkyBridgeHybridKDF".utf8),
     *     info: Data("hybrid-key-exchange".utf8),
     *     outputByteCount: 32
     * )
     * ```
     *
     * @param classicSecret Secret from classic ECDH (X25519 or P-256)
     * @param pqcSecret Secret from PQC KEM (ML-KEM-768), may be empty
     * @return 32-byte combined shared secret
     */
    fun combineSharedSecrets(
        classicSecret: ByteArray,
        pqcSecret: ByteArray
    ): ByteArray {
        // Combine: IKM = classicSecret || pqcSecret
        val ikm = classicSecret + pqcSecret

        // HKDF with Apple-compatible parameters
        val prk = HybridKeyDerivation.hkdfExtract(APPLE_KDF_SALT, ikm)
        return HybridKeyDerivation.hkdfExpand(prk, APPLE_KDF_INFO, 32)
    }

    /**
     * Derives session keys from a combined secret (Apple-compatible).
     *
     * This two-step process ensures compatibility:
     * 1. First combine secrets using Apple parameters
     * 2. Then derive channel keys using SkyBridge labels
     *
     * @param classicSecret Secret from classic ECDH
     * @param pqcSecret Secret from PQC KEM (may be empty)
     * @param clientRandom 32-byte client random
     * @param serverRandom 32-byte server random
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

        // Step 1: Combine secrets using Apple-compatible method
        val combinedSecret = combineSharedSecrets(classicSecret, pqcSecret)

        // Step 2: Derive channel keys using SkyBridge-specific derivation
        return deriveChannelKeys(
            combinedSecret = combinedSecret,
            clientRandom = clientRandom,
            serverRandom = serverRandom,
            transcriptHash = transcriptHash
        )
    }

    /**
     * Derives channel keys from a combined secret.
     *
     * @param combinedSecret 32-byte combined shared secret
     * @param clientRandom 32-byte client random
     * @param serverRandom 32-byte server random
     * @param transcriptHash SHA-256 hash of handshake transcript
     * @return SessionKeys containing control, video, and file channel keys
     */
    fun deriveChannelKeys(
        combinedSecret: ByteArray,
        clientRandom: ByteArray,
        serverRandom: ByteArray,
        transcriptHash: ByteArray
    ): SessionKeys {
        // Use random values for additional entropy
        val contextSalt = MessageDigest.getInstance("SHA-256").apply {
            update(clientRandom)
            update(serverRandom)
        }.digest()

        // Derive master secret with transcript binding
        val prk = HybridKeyDerivation.hkdfExtract(contextSalt, combinedSecret)
        val domainInfo = "SkyBridge-P2P-v2".toByteArray(Charsets.UTF_8) + transcriptHash
        val masterSecret = HybridKeyDerivation.hkdfExpand(prk, domainInfo, 48)

        // Derive channel-specific keys
        val controlKey = HybridKeyDerivation.hkdfExpand(masterSecret, CONTROL_CHANNEL_INFO, 32)
        val videoKey = HybridKeyDerivation.hkdfExpand(masterSecret, VIDEO_CHANNEL_INFO, 32)
        val fileKey = HybridKeyDerivation.hkdfExpand(masterSecret, FILE_CHANNEL_INFO, 32)

        return SessionKeys(controlKey, videoKey, fileKey)
    }

    /**
     * Derives a simple P2P session key (matches Apple P2PHandshakeManager).
     *
     * This is for the simpler handshake flow used by P2PHandshakeManager:
     * ```swift
     * security.deriveAndStoreSessionKey(sharedSecret: ss, deviceId: deviceId)
     * ```
     *
     * @param sharedSecret Raw shared secret from KEM (32 bytes)
     * @param deviceId Peer device identifier
     * @return 32-byte session key
     */
    fun deriveP2PSessionKey(
        sharedSecret: ByteArray,
        deviceId: String
    ): ByteArray {
        val info = (P2P_SESSION_INFO_PREFIX + deviceId).toByteArray(Charsets.UTF_8)
        val prk = HybridKeyDerivation.hkdfExtract(APPLE_KDF_SALT, sharedSecret)
        return HybridKeyDerivation.hkdfExpand(prk, info, 32)
    }

    /**
     * Determines which key derivation strategy to use based on peer platform.
     *
     * @param peerPlatform Platform identifier from handshake extensions
     * @return KeyDerivationStrategy to use
     */
    fun selectStrategy(peerPlatform: String?): KeyDerivationStrategy {
        return when (peerPlatform?.lowercase()) {
            "ios", "macos" -> KeyDerivationStrategy.APPLE_COMPATIBLE
            "android" -> KeyDerivationStrategy.NATIVE_ANDROID
            else -> KeyDerivationStrategy.APPLE_COMPATIBLE // Default to most compatible
        }
    }

    /**
     * Key derivation strategy selection.
     */
    enum class KeyDerivationStrategy {
        /**
         * Use Apple-compatible HKDF parameters.
         * - Salt: "SkyBridgeHybridKDF"
         * - Info: "hybrid-key-exchange"
         * For: iOS, macOS peers
         */
        APPLE_COMPATIBLE,

        /**
         * Use native Android/SkyBridge HKDF parameters.
         * - Salt: SHA-256(clientRandom || serverRandom)
         * - Info: "SkyBridge-P2P-v2" + transcriptHash
         * For: Android peers only
         */
        NATIVE_ANDROID
    }
}

