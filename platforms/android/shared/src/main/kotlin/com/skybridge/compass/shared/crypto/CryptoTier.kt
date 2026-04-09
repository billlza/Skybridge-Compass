package com.skybridge.compass.shared.crypto

/**
 * Defines the tier/level of cryptographic provider implementation.
 * Higher tiers provide stronger security guarantees.
 */
enum class CryptoTier {
    /**
     * liboqs native implementation for post-quantum cryptography.
     * Provides ML-KEM-768 and ML-DSA-65 support.
     */
    LIBOQS_PQC,
    
    /**
     * BouncyCastle PQC implementation.
     * Fallback for PQC when liboqs is unavailable.
     */
    BOUNCY_CASTLE_PQC,
    
    /**
     * Classic cryptography using EC/RSA.
     * Provides X25519, P-256, Ed25519, ECDSA support.
     */
    CLASSIC
}
