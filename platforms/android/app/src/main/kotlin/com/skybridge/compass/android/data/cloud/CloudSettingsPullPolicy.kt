package com.skybridge.compass.android.data.cloud

import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.cloud.CloudUserSettingsSyncManager.NetworkSettingsDto
import com.skybridge.compass.android.data.cloud.CloudUserSettingsSyncManager.SecuritySettingsDto
import com.skybridge.compass.android.data.cloud.CloudUserSettingsSyncManager.SettingsSnapshot
import com.skybridge.compass.core.webrtc.SkyBridgeServerConfig
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import java.net.URI
import java.net.URISyntaxException

internal object CloudSettingsPullPolicy {

    class Violation(message: String) : IllegalArgumentException(message)

    fun validateIncomingSnapshot(
        snapshot: SettingsSnapshot,
        securityDefaults: SecuritySettings = SecuritySettings()
    ) {
        validateNetworkSecurity(snapshot.network)
        validateSecurityIsNotWeaker(
            security = snapshot.security,
            legacySchema = snapshot.schemaVersion < 2,
            defaults = securityDefaults
        )
    }

    private fun validateNetworkSecurity(network: NetworkSettingsDto) {
        requirePolicy(network.tlsStrictMode) {
            "cloud settings cannot disable TLS strict mode"
        }
        requirePolicy(network.handshakeEnabled) {
            "cloud settings cannot disable transport handshake"
        }
        requirePolicy(network.encryptionMode == "AES_GCM") {
            "cloud settings cannot change network encryption mode"
        }
        requireCloudWritableWebRtcSignalingUrl(network.webrtcSignalingUrl)
        network.stunServers.forEach { url ->
            requireIceUrl(url = url, allowedSchemes = setOf("stun"), label = "STUN")
        }
        network.turnServers.forEach { url ->
            requireIceUrl(url = url, allowedSchemes = setOf("turn", "turns"), label = "TURN")
        }
    }

    private fun validateSecurityIsNotWeaker(
        security: SecuritySettingsDto,
        legacySchema: Boolean,
        defaults: SecuritySettings
    ) {
        requirePolicy(security.encryptionEnabled) { "cloud settings cannot disable encryption" }
        requirePolicy(security.pqcEnabled) { "cloud settings cannot disable PQC" }
        if (!legacySchema) {
            requirePolicy(security.enforcePqcHandshake) {
                "cloud settings cannot disable enforced PQC handshake"
            }
            requirePolicy(!security.allowClassicFallbackForCompatibility) {
                "cloud settings cannot enable classic fallback"
            }
            requirePolicy(security.pqcMinimumTier != P2PQPeriaptKem.MINIMUM_TIER_RAW) {
                "cloud settings cannot enable Q-Periapt beta"
            }
            requirePolicy(minimumTierRank(security.pqcMinimumTier) >= minimumTierRank(defaults.pqcMinimumTier)) {
                "cloud settings cannot lower PQC minimum tier"
            }
        }
        requirePolicy(!security.allowRemoteControl || defaults.allowRemoteControl) {
            "cloud settings cannot enable remote control from the default security posture"
        }
        requirePolicy(security.remoteControlRequireConfirmation || !defaults.remoteControlRequireConfirmation) {
            "cloud settings cannot disable remote control confirmation"
        }
        requirePolicy(security.requirePairing || !defaults.requirePairing) {
            "cloud settings cannot disable pairing approval"
        }
        requirePolicy(!security.autoTrustKnownDevices || defaults.autoTrustKnownDevices) {
            "cloud settings cannot enable automatic device trust"
        }
        requirePolicy(!security.autoAcceptTrustedDevices || defaults.autoAcceptTrustedDevices) {
            "cloud settings cannot enable automatic trusted-device file acceptance"
        }
        requirePolicy(security.confirmOverwriteOnInbound || !defaults.confirmOverwriteOnInbound) {
            "cloud settings cannot disable inbound overwrite confirmation"
        }
    }

    private fun requireCloudWritableWebRtcSignalingUrl(raw: String) {
        val uri = parseUri(raw, "WebRTC signaling URL")
        val scheme = uri.scheme?.lowercase()
            ?: reject("invalid WebRTC signaling URL")
        val host = uri.host?.lowercase()
            ?: reject("invalid WebRTC signaling URL")
        requirePolicy(scheme == "wss" || scheme == "https" || (scheme == "ws" && isLoopbackHost(host))) {
            "cloud WebRTC signaling URL must be secure or loopback"
        }
        requirePolicy(isLoopbackHost(host) || matchesDefaultSignalingEndpoint(uri)) {
            "cloud WebRTC signaling URL must be the default service endpoint or loopback"
        }
    }

    private fun requireIceUrl(url: String, allowedSchemes: Set<String>, label: String) {
        val trimmed = url.trim()
        requirePolicy(trimmed.isNotEmpty()) { "cloud $label settings contain blank URL" }
        val uri = parseUri(trimmed, "$label URL")
        val scheme = uri.scheme?.lowercase()
            ?: reject("cloud $label settings contain invalid URL")
        requirePolicy(scheme in allowedSchemes) {
            "cloud $label settings contain unsupported URL scheme"
        }
        requirePolicy(!uri.schemeSpecificPart.isNullOrBlank()) {
            "cloud $label settings contain invalid URL"
        }
    }

    private fun parseUri(raw: String, label: String): URI =
        try {
            URI(raw.trim())
        } catch (_: URISyntaxException) {
            reject("invalid $label")
        } catch (_: IllegalArgumentException) {
            reject("invalid $label")
        }

    private fun isLoopbackHost(rawHost: String): Boolean {
        val host = rawHost.removeSurrounding("[", "]").lowercase()
        return host == "localhost" ||
            host == "::1" ||
            host == "0:0:0:0:0:0:0:1" ||
            isIpv4LoopbackLiteral(host)
    }

    private fun isIpv4LoopbackLiteral(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) return false
        val octets = parts.map { part ->
            if (part.isEmpty()) return false
            part.toIntOrNull() ?: return false
        }
        return octets[0] == 127 && octets.all { it in 0..255 }
    }

    private fun minimumTierRank(raw: String): Int =
        when (raw.trim()) {
            "classic" -> 0
            "liboqsPQC" -> 1
            "nativePQC" -> 2
            P2PQPeriaptKem.MINIMUM_TIER_RAW -> 3
            else -> reject("cloud settings contain unsupported PQC minimum tier")
        }

    private fun matchesDefaultSignalingEndpoint(uri: URI): Boolean {
        val defaults = parseUri(SkyBridgeServerConfig.signalingWebSocketURL, "default WebRTC signaling URL")
        return uri.scheme?.lowercase() == defaults.scheme?.lowercase() &&
            uri.host?.lowercase() == defaults.host?.lowercase() &&
            normalizedPort(uri) == normalizedPort(defaults) &&
            normalizedPath(uri) == normalizedPath(defaults) &&
            uri.rawQuery == null &&
            uri.rawFragment == null
    }

    private fun normalizedPort(uri: URI): Int =
        when {
            uri.port >= 0 -> uri.port
            uri.scheme.equals("https", ignoreCase = true) || uri.scheme.equals("wss", ignoreCase = true) -> 443
            uri.scheme.equals("http", ignoreCase = true) || uri.scheme.equals("ws", ignoreCase = true) -> 80
            else -> -1
        }

    private fun normalizedPath(uri: URI): String =
        uri.rawPath?.takeIf { it.isNotBlank() } ?: "/"

    private inline fun requirePolicy(value: Boolean, message: () -> String) {
        if (!value) reject(message())
    }

    private fun reject(message: String): Nothing {
        throw Violation(message)
    }
}
