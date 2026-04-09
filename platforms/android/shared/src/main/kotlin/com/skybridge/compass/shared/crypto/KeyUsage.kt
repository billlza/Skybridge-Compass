package com.skybridge.compass.shared.crypto

/**
 * Defines the intended usage of a cryptographic key pair.
 */
enum class KeyUsage {
    /**
     * Key pair used for key exchange (KEM).
     * Examples: ML-KEM-768, X25519, P-256 ECDH
     */
    KEY_EXCHANGE,
    
    /**
     * Key pair used for digital signatures.
     * Examples: ML-DSA-65, Ed25519, ECDSA
     */
    SIGNING
}
