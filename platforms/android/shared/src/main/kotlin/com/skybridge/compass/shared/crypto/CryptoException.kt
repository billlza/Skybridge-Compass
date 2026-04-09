package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.CryptoSuite

/**
 * Base exception class for all cryptographic operations.
 * 
 * This sealed class hierarchy provides type-safe error handling
 * for different failure scenarios in the crypto module.
 */
sealed class CryptoException(
    message: String,
    cause: Throwable? = null
) : Exception(message, cause)

/**
 * Thrown when a required crypto provider is not available.
 * 
 * @param provider The name of the unavailable provider
 */
class CryptoProviderUnavailableException(
    val provider: String,
    message: String = "Crypto provider $provider is not available"
) : CryptoException(message)

/**
 * Thrown when crypto suite negotiation fails.
 * 
 * @param localSuites The suites supported by the local peer
 * @param remoteSuites The suites supported by the remote peer
 */
class CryptoNegotiationException(
    val localSuites: List<CryptoSuite>,
    val remoteSuites: List<CryptoSuite>,
    message: String = "No common crypto suite found"
) : CryptoException(message)

/**
 * Thrown when parsing an HPKESealedBox fails.
 * 
 * @param reason Description of why parsing failed
 */
class HPKEParseException(
    val reason: String,
    message: String = "Failed to parse HPKESealedBox: $reason"
) : CryptoException(message)

/**
 * Thrown when a handshake operation fails.
 * 
 * @param phase The handshake phase where failure occurred
 */
class HandshakeException(
    val phase: String,
    message: String,
    cause: Throwable? = null
) : CryptoException(message, cause)

/**
 * Thrown when key storage operations fail.
 * 
 * @param alias The key alias involved in the failure
 */
class KeyStorageException(
    val alias: String,
    message: String,
    cause: Throwable? = null
) : CryptoException(message, cause)

/**
 * Thrown when a cryptographic operation fails.
 * 
 * @param operation The operation that failed (e.g., "encrypt", "decrypt", "sign")
 */
class CryptoOperationException(
    val operation: String,
    message: String,
    cause: Throwable? = null
) : CryptoException(message, cause)

/**
 * Thrown when key material is invalid or corrupted.
 * 
 * @param keyType The type of key that was invalid
 * @param expectedSize Expected size in bytes (if applicable)
 * @param actualSize Actual size in bytes (if applicable)
 */
class InvalidKeyException(
    val keyType: String,
    val expectedSize: Int? = null,
    val actualSize: Int? = null,
    message: String = buildInvalidKeyMessage(keyType, expectedSize, actualSize)
) : CryptoException(message)

private fun buildInvalidKeyMessage(
    keyType: String,
    expectedSize: Int?,
    actualSize: Int?
): String {
    return if (expectedSize != null && actualSize != null) {
        "Invalid $keyType key: expected $expectedSize bytes, got $actualSize bytes"
    } else {
        "Invalid $keyType key"
    }
}
