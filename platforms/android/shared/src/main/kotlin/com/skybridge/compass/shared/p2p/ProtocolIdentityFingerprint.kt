package com.skybridge.compass.shared.p2p

import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

object ProtocolIdentityFingerprint {
    const val ED25519_TAG: String = "Ed25519"
    const val ML_DSA_65_TAG: String = "ML-DSA-65"

    fun compute(identityPublicKeys: P2PIdentityPublicKeys.Keys): String {
        val tag = when (identityPublicKeys.protocolAlgorithm) {
            P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519 -> ED25519_TAG
            P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65 -> ML_DSA_65_TAG
            P2PIdentityPublicKeys.ProtocolAlgorithm.P256_ECDSA_LEGACY ->
                throw IllegalArgumentException("P-256 ECDSA legacy identity is not a pinnable protocol identity")
        }
        return compute(
            algorithmTag = tag,
            publicKeyBytes = identityPublicKeys.protocolPublicKey
        )
    }

    fun compute(algorithmTag: String, publicKeyBytes: ByteArray): String {
        validateKeyEncoding(algorithmTag, publicKeyBytes)
        val payload = ByteArrayOutputStream()
        val algorithmBytes = algorithmTag.encodeToByteArray()
        payload.write(littleEndianU16(algorithmBytes.size))
        payload.write(algorithmBytes)
        payload.write(littleEndianU32(publicKeyBytes.size))
        payload.write(publicKeyBytes)
        return sha256Hex(payload.toByteArray())
    }

    fun isValidFingerprint(raw: String): Boolean =
        raw.length == 64 && raw.all { it in '0'..'9' || it in 'a'..'f' }

    private fun validateKeyEncoding(algorithmTag: String, bytes: ByteArray) {
        when (algorithmTag) {
            ED25519_TAG ->
                require(bytes.size == 32) { "ed25519 public key must be 32 bytes" }

            ML_DSA_65_TAG ->
                require(bytes.size == AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE) {
                    "mlDSA65 public key must be ${AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE} bytes"
                }

            else -> throw IllegalArgumentException("unsupported protocol signing algorithm: $algorithmTag")
        }
    }

    private fun littleEndianU16(value: Int): ByteArray =
        byteArrayOf(
            (value and 0xFF).toByte(),
            ((value ushr 8) and 0xFF).toByte()
        )

    private fun littleEndianU32(value: Int): ByteArray =
        byteArrayOf(
            (value and 0xFF).toByte(),
            ((value ushr 8) and 0xFF).toByte(),
            ((value ushr 16) and 0xFF).toByte(),
            ((value ushr 24) and 0xFF).toByte()
        )

    private fun sha256Hex(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(data)
            .joinToString(separator = "") { "%02x".format(it) }
}
