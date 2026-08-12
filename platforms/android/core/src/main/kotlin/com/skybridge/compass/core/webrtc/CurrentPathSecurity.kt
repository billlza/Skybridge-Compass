package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.p2p.P2PIdentityPublicKeys
import com.skybridge.compass.shared.p2p.ProtocolIdentityFingerprint
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.net.URI

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
        require(
            protocolPublicKeyFingerprint.equals(
                computeFingerprint(protocolSigningAlgorithm, protocolPublicKeyBytes),
                ignoreCase = true
            )
        ) { "authoritative fingerprint does not match protocol public key" }
    }

    companion object {
        private val allowedDeviceIdChars = Regex("^[A-Za-z0-9._:-]{16,128}$")

        fun normalizedDeviceId(raw: String): String {
            val candidate = raw.trim()
            require(allowedDeviceIdChars.matches(candidate)) { "invalid current-path deviceId" }
            return candidate
        }

        fun isValidFingerprint(raw: String): Boolean =
            ProtocolIdentityFingerprint.isValidFingerprint(raw)

        fun validateKeyEncoding(bytes: ByteArray, algorithm: ProtocolSigningAlgorithm) {
            when (algorithm) {
                ProtocolSigningAlgorithm.ED25519 ->
                    require(bytes.size == 32) { "ed25519 public key must be 32 bytes" }

                ProtocolSigningAlgorithm.ML_DSA_65 ->
                    require(bytes.size == AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE) {
                        "mlDSA65 public key must be ${AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE} bytes"
                    }
            }
        }

        fun computeFingerprint(
            algorithm: ProtocolSigningAlgorithm,
            publicKeyBytes: ByteArray
        ): String {
            validateKeyEncoding(publicKeyBytes, algorithm)
            return ProtocolIdentityFingerprint.compute(algorithm.rawValue, publicKeyBytes)
        }
    }
}

object CurrentPathOriginPolicy {
    fun canonicalOrigin(raw: String): String {
        val uri = runCatching { URI(raw.trim()) }
            .getOrElse { throw IllegalArgumentException("invalid signaling origin") }
        val scheme = uri.scheme?.lowercase() ?: throw IllegalArgumentException("invalid signaling origin")
        require(scheme == "https" || scheme == "http") { "invalid signaling origin" }
        val host = uri.host?.lowercase() ?: throw IllegalArgumentException("invalid signaling origin")
        require(scheme == "https" || isLoopbackHost(host)) { "http signaling origin is only allowed for loopback" }
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

    private fun isLoopbackHost(host: String): Boolean =
        host == "localhost" ||
            host == "10.0.2.2" ||
            host == "::1" ||
            host == "0:0:0:0:0:0:0:1" ||
            isIpv4LoopbackLiteral(host)

    private fun isIpv4LoopbackLiteral(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) return false
        val octets = parts.map { part ->
            if (part.isEmpty()) return false
            part.toIntOrNull() ?: return false
        }
        return octets[0] == 127 && octets.all { it in 0..255 }
    }
}

object SignalingEndpointTrustPolicy {
    fun allowsUserAuthContext(rawEndpoint: String): Boolean {
        val endpoint = runCatching { URI(rawEndpoint.trim()) }.getOrNull() ?: return false
        val trusted = URI(SkyBridgeServerConfig.signalingWebSocketURL)
        return endpoint.scheme?.lowercase() in setOf("wss", "https") &&
            endpoint.host?.lowercase() == trusted.host?.lowercase() &&
            normalizedPort(endpoint) == normalizedPort(trusted) &&
            normalizedPath(endpoint) == normalizedPath(trusted) &&
            endpoint.rawQuery == null &&
            endpoint.rawFragment == null
    }

    fun allowsDiagnosticLoopbackAuthContext(rawEndpoint: String): Boolean {
        val endpoint = runCatching { URI(rawEndpoint.trim()) }.getOrNull() ?: return false
        return endpoint.scheme?.lowercase() in setOf("ws", "http") &&
            isLoopbackHost(endpoint.host?.lowercase().orEmpty()) &&
            endpoint.rawQuery == null &&
            endpoint.rawFragment == null
    }

    fun allowsDiagnosticLocalNetworkAuthContext(rawEndpoint: String): Boolean {
        val endpoint = runCatching { URI(rawEndpoint.trim()) }.getOrNull() ?: return false
        return endpoint.scheme?.lowercase() in setOf("ws", "http") &&
            isDiagnosticLocalNetworkHost(endpoint.host?.lowercase().orEmpty()) &&
            endpoint.rawQuery == null &&
            endpoint.rawFragment == null
    }

    internal fun isDiagnosticLocalNetworkHost(host: String): Boolean =
        isLoopbackHost(host) || isPrivateIpv4Host(host)

    private fun normalizedPort(uri: URI): Int =
        when {
            uri.port >= 0 -> uri.port
            uri.scheme.equals("https", ignoreCase = true) || uri.scheme.equals("wss", ignoreCase = true) -> 443
            uri.scheme.equals("http", ignoreCase = true) || uri.scheme.equals("ws", ignoreCase = true) -> 80
            else -> -1
        }

    private fun normalizedPath(uri: URI): String =
        uri.rawPath?.takeIf { it.isNotBlank() } ?: "/"

    private fun isLoopbackHost(host: String): Boolean =
        host == "localhost" ||
            host == "10.0.2.2" ||
            host == "::1" ||
            host == "0:0:0:0:0:0:0:1" ||
            isIpv4LoopbackLiteral(host)

    private fun isIpv4LoopbackLiteral(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) return false
        val octets = parts.map { part ->
            if (part.isEmpty()) return false
            part.toIntOrNull() ?: return false
        }
        return octets[0] == 127 && octets.all { it in 0..255 }
    }

    private fun isPrivateIpv4Host(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) return false
        val octets = parts.map { part ->
            if (part.isEmpty()) return false
            part.toIntOrNull() ?: return false
        }
        return when {
            octets.any { it !in 0..255 } -> false
            octets[0] == 10 -> true
            octets[0] == 172 && octets[1] in 16..31 -> true
            octets[0] == 192 && octets[1] == 168 -> true
            octets[0] == 169 && octets[1] == 254 -> true
            else -> false
        }
    }
}
