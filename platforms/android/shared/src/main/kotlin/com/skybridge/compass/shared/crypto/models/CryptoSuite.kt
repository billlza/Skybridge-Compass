package com.skybridge.compass.shared.crypto.models

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Represents a cryptographic algorithm suite for secure communication.
 * 
 * Each suite defines a combination of:
 * - KEM (Key Encapsulation Mechanism) for key exchange
 * - Signature algorithm for authentication
 * 
 * Wire Protocol encoding uses a 2-byte wireId in big-endian format:
 * - High byte indicates algorithm family (0x00/0x01 = PQC, 0x10 = Classic)
 * - Low byte indicates specific variant
 * 
 * @property rawValue Human-readable name of the suite
 * @property wireId 2-byte identifier for wire protocol encoding
 */
data class CryptoSuite(
    val rawValue: String,
    val wireId: UShort
) {
    /**
     * Indicates whether this suite uses post-quantum cryptography.
     * 
     * PQC suites have wireId high byte of 0x00 or 0x01.
     * Classic suites have wireId high byte of 0x10.
     */
    val isPQC: Boolean
        get() {
            val highByte = (wireId.toInt() shr 8) and 0xFF
            return highByte == 0x00 || highByte == 0x01
        }
    
    /**
     * Returns the KEM algorithm name for this suite.
     */
    val kemAlgorithm: String
        get() = when (this) {
            X_WING_ML_DSA -> "X-Wing"
            ML_KEM_768_ML_DSA_65 -> "ML-KEM-768"
            X25519_ED25519 -> "X25519"
            P256_ECDSA -> "P-256"
            else -> "Unknown"
        }
    
    /**
     * Returns the signature algorithm name for this suite.
     */
    val signatureAlgorithm: String
        get() = when (this) {
            X_WING_ML_DSA -> "ML-DSA-65"
            ML_KEM_768_ML_DSA_65 -> "ML-DSA-65"
            X25519_ED25519 -> "Ed25519"
            P256_ECDSA -> "ECDSA"
            else -> "Unknown"
        }
    
    /**
     * Serializes this CryptoSuite to wire protocol format.
     *
     * @return 2-byte array containing wireId in little-endian format (per IEEE paper wire protocol spec)
     */
    fun serialize(): ByteArray {
        return ByteBuffer.allocate(2)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putShort(wireId.toShort())
            .array()
    }
    
    companion object {
        /**
         * X-Wing hybrid KEM + ML-DSA-65 signature.
         * Wire ID: 0x0001
         * 
         * Note: X-Wing is a hybrid of X25519 and ML-KEM-768.
         * Supported on iOS 26+ via Apple CryptoKit.
         */
        val X_WING_ML_DSA = CryptoSuite("X-Wing+ML-DSA-65", 0x0001u)
        
        /**
         * ML-KEM-768 (FIPS 203) + ML-DSA-65 (FIPS 204).
         * Wire ID: 0x0101
         * 
         * Primary PQC suite for Android-macOS interoperability.
         * Supported via liboqs on Android and CryptoKit on iOS 26+.
         */
        val ML_KEM_768_ML_DSA_65 = CryptoSuite("ML-KEM-768+ML-DSA-65", 0x0101u)
        
        /**
         * X25519 ECDH + Ed25519 signature.
         * Wire ID: 0x1001
         * 
         * Classic elliptic curve suite, widely supported.
         * Used as fallback when PQC is unavailable.
         */
        val X25519_ED25519 = CryptoSuite("X25519+Ed25519", 0x1001u)
        
        /**
         * P-256 ECDH + ECDSA signature.
         * Wire ID: 0x1002
         * 
         * NIST P-256 curve suite, maximum compatibility.
         * Used as ultimate fallback.
         */
        val P256_ECDSA = CryptoSuite("P-256+ECDSA", 0x1002u)
        
        /**
         * All known crypto suites in priority order (highest first).
         */
        val ALL_SUITES = listOf(
            ML_KEM_768_ML_DSA_65,
            X_WING_ML_DSA,
            X25519_ED25519,
            P256_ECDSA
        )
        
        /**
         * Creates a CryptoSuite from its wire protocol ID.
         * 
         * @param wireId The 2-byte wire protocol identifier
         * @return The corresponding CryptoSuite, or null if unknown
         */
        fun fromWireId(wireId: UShort): CryptoSuite? = when (wireId) {
            0x0001.toUShort() -> X_WING_ML_DSA
            0x0101.toUShort() -> ML_KEM_768_ML_DSA_65
            0x1001.toUShort() -> X25519_ED25519
            0x1002.toUShort() -> P256_ECDSA
            else -> null
        }
        
        /**
         * Parses a CryptoSuite from wire protocol bytes.
         * 
         * @param data Byte array containing at least 2 bytes
         * @param offset Starting offset in the array (default 0)
         * @return The parsed CryptoSuite, or null if unknown
         * @throws IllegalArgumentException if data is too short
         */
        fun parse(data: ByteArray, offset: Int = 0): CryptoSuite? {
            require(data.size >= offset + 2) {
                "Data too short: need at least ${offset + 2} bytes, got ${data.size}"
            }
            
            val wireId = ByteBuffer.wrap(data, offset, 2)
                .order(ByteOrder.LITTLE_ENDIAN)
                .short
                .toUShort()
            
            return fromWireId(wireId)
        }
    }
    
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CryptoSuite) return false
        return wireId == other.wireId
    }
    
    override fun hashCode(): Int = wireId.hashCode()
    
    override fun toString(): String = rawValue
}
