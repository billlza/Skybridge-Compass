package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.p2p.P2PIdentityPublicKeys
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.io.ByteArrayOutputStream
import java.net.URI
import java.security.MessageDigest

@Serializable
enum class ProtocolSigningAlgorithm(val rawValue: String) {
    @SerialName("Ed25519")
    ED25519("Ed25519"),

    @SerialName("ML-DSA-65")
    ML_DSA_65("ML-DSA-65");

    companion object {
        fun fromIdentityAlgorithm(raw: P2PIdentityPublicKeys.ProtocolAlgorithm): ProtocolSigningAlgorithm? =
            when (raw) {
                P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519 -> ED25519
                P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65 -> ML_DSA_65
                P2PIdentityPublicKeys.ProtocolAlgorithm.P256_ECDSA_LEGACY -> null
            }
    }
}

@Serializable
data class ProtocolIdentityBinding(
    val deviceId: String,
    val protocolSigningAlgorithm: ProtocolSigningAlgorithm,
    val protocolPublicKeyBytes: ByteArray,
    val protocolPublicKeyFingerprint: String =
        computeFingerprint(protocolSigningAlgorithm, protocolPublicKeyBytes)
) {
    init {
        require(normalizedDeviceId(deviceId) == deviceId) { "invalid current-path deviceId" }
        validateKeyEncoding(protocolPublicKeyBytes, protocolSigningAlgorithm)
        require(isValidFingerprint(protocolPublicKeyFingerprint)) { "invalid authoritative fingerprint" }
    }

    companion object {
        private val allowedDeviceIdChars = Regex("^[A-Za-z0-9._:-]{16,128}$")

        fun normalizedDeviceId(raw: String): String {
            val candidate = raw.trim()
            require(allowedDeviceIdChars.matches(candidate)) { "invalid current-path deviceId" }
            return candidate
        }

        fun isValidFingerprint(raw: String): Boolean =
            raw.length == 64 && raw.all { it in '0'..'9' || it in 'a'..'f' }

        fun validateKeyEncoding(bytes: ByteArray, algorithm: ProtocolSigningAlgorithm) {
            when (algorithm) {
                ProtocolSigningAlgorithm.ED25519 ->
                    require(bytes.size == 32) { "ed25519 public key must be 32 bytes" }

                ProtocolSigningAlgorithm.ML_DSA_65 ->
                    require(bytes.isNotEmpty()) { "mlDSA65 public key must not be empty" }
            }
        }

        fun computeFingerprint(
            algorithm: ProtocolSigningAlgorithm,
            publicKeyBytes: ByteArray
        ): String {
            validateKeyEncoding(publicKeyBytes, algorithm)
            val payload = ByteArrayOutputStream()
            val algorithmBytes = algorithm.rawValue.encodeToByteArray()
            payload.write(littleEndianU16(algorithmBytes.size))
            payload.write(algorithmBytes)
            payload.write(littleEndianU32(publicKeyBytes.size))
            payload.write(publicKeyBytes)
            return sha256Hex(payload.toByteArray())
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
}

object CurrentPathOriginPolicy {
    fun canonicalOrigin(raw: String): String {
        val uri = runCatching { URI(raw.trim()) }
            .getOrElse { throw IllegalArgumentException("invalid signaling origin") }
        val scheme = uri.scheme?.lowercase() ?: throw IllegalArgumentException("invalid signaling origin")
        require(scheme == "https" || scheme == "http") { "invalid signaling origin" }
        val host = uri.host?.lowercase() ?: throw IllegalArgumentException("invalid signaling origin")
        require(uri.rawPath.isNullOrEmpty() || uri.rawPath == "/") { "invalid signaling origin" }
        require(uri.rawQuery == null && uri.rawFragment == null) { "invalid signaling origin" }
        val port = uri.port
        val includePort = when {
            port < 0 -> false
            scheme == "https" && port == 443 -> false
            scheme == "http" && port == 80 -> false
            else -> true
        }
        return if (includePort) {
            "$scheme://$host:$port"
        } else {
            "$scheme://$host"
        }
    }
}
