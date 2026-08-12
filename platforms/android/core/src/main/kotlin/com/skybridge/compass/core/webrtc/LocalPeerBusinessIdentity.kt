package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.account.NebulaId

/**
 * Peer-visible business identity metadata carried only inside authenticated
 * app-control messages after the WebRTC/P2P session keys are established.
 */
data class LocalPeerBusinessIdentity(
    val accountDisplayName: String? = null,
    val nebulaId: String? = null
) {
    fun normalizedOrNull(): LocalPeerBusinessIdentity? {
        val normalizedName = accountDisplayName?.trim()?.takeIf { it.isNotEmpty() }
        val normalizedNebulaId = NebulaId.parseOrNull(nebulaId)?.value ?: return null
        return LocalPeerBusinessIdentity(
            accountDisplayName = normalizedName,
            nebulaId = normalizedNebulaId
        )
    }
}
