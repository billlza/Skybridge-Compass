package com.skybridge.compass.core.data

import com.skybridge.compass.core.webrtc.SkyBridgeServerConfig
import java.net.URI
import java.net.URISyntaxException

object NetworkEndpointPolicy {
    fun normalizeWebRtcSignalingUrl(raw: String?): String {
        val value = raw?.trim().orEmpty().ifBlank { SkyBridgeServerConfig.signalingWebSocketURL }
        val uri = parseUri(value, "WebRTC signaling URL")
        val scheme = uri.scheme?.lowercase() ?: throw IllegalArgumentException("invalid WebRTC signaling URL")
        val host = uri.host?.lowercase() ?: throw IllegalArgumentException("invalid WebRTC signaling URL")
        require(uri.userInfo == null) { "WebRTC signaling URL must not include user info" }
        require(uri.rawFragment == null) { "WebRTC signaling URL must not include a fragment" }
        require(scheme == "wss" || (scheme == "ws" && isLoopbackHost(host))) {
            "WebRTC signaling URL must be wss or loopback ws"
        }
        return URI(
            scheme,
            uri.rawAuthority,
            uri.rawPath?.takeIf { it.isNotBlank() } ?: "/",
            uri.rawQuery,
            null
        ).toASCIIString()
    }

    fun normalizeStunServers(rawServers: List<String>?): List<String> =
        normalizeIceServers(
            rawServers = rawServers,
            defaults = SkyBridgeServerConfig.defaultStunServers,
            allowedSchemes = setOf("stun"),
            label = "STUN"
        )

    fun normalizeTurnServers(rawServers: List<String>?): List<String> =
        normalizeIceServers(
            rawServers = rawServers,
            defaults = SkyBridgeServerConfig.defaultTurnServers,
            allowedSchemes = setOf("turn", "turns"),
            label = "TURN"
        )

    fun resolveTurnUrlsForCredentials(
        configuredTurnServers: List<String>,
        credentialTurnUris: List<String>
    ): List<String> {
        val configured = normalizeTurnServers(configuredTurnServers)
        val defaults = normalizeTurnServers(SkyBridgeServerConfig.defaultTurnServers)
        val serverIssued = normalizeTurnServers(credentialTurnUris)
        return if (sameOrderedUrls(configured, defaults)) serverIssued else configured
    }

    private fun normalizeIceServers(
        rawServers: List<String>?,
        defaults: List<String>,
        allowedSchemes: Set<String>,
        label: String
    ): List<String> {
        val effective = rawServers
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?.takeIf { it.isNotEmpty() }
            ?: defaults
        val seen = linkedSetOf<String>()
        return effective.map { raw ->
            val uri = parseUri(raw, "$label URL")
            val scheme = uri.scheme?.lowercase() ?: throw IllegalArgumentException("invalid $label URL")
            require(scheme in allowedSchemes) { "$label URL has unsupported scheme" }
            require(!uri.schemeSpecificPart.isNullOrBlank()) { "invalid $label URL" }
            require(uri.userInfo == null) { "$label URL must not include user info" }
            require(uri.rawFragment == null) { "$label URL must not include a fragment" }
            raw
        }.filter { seen.add(it.lowercase()) }
            .also { require(it.isNotEmpty()) { "$label server list is empty" } }
    }

    private fun parseUri(raw: String, label: String): URI =
        try {
            URI(raw.trim())
        } catch (_: URISyntaxException) {
            throw IllegalArgumentException("invalid $label")
        } catch (_: IllegalArgumentException) {
            throw IllegalArgumentException("invalid $label")
        }

    private fun sameOrderedUrls(left: List<String>, right: List<String>): Boolean =
        left.map { it.lowercase() } == right.map { it.lowercase() }

    private fun isLoopbackHost(rawHost: String): Boolean {
        val host = rawHost.removeSurrounding("[", "]").lowercase()
        return host == "localhost" ||
            host == "10.0.2.2" ||
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
}
