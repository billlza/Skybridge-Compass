package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.shared.p2p.P2PSoa

internal object MacRemoteControlSoaIdentity {

    fun messageAExtensions(
        localDeviceId: String,
        remoteDeviceId: String,
        attemptId: ByteArray
    ): ByteArray? {
        val localPeerId = peerIdBytes(localDeviceId) ?: return null
        val remotePeerId = peerIdBytes(remoteDeviceId) ?: return null
        return P2PSoa.SoaExtension(
            version = P2PSoa.VERSION,
            initiatorPeerId = localPeerId,
            targetPeerId = remotePeerId,
            attemptId = attemptId
        ).encodeTlv()
    }

    fun peerIdBytes(deviceId: String): ByteArray? =
        stableIdentifier(deviceId)
            ?.removePrefix("id:")
            ?.let(P2PSoa::canonicalPeerIdBytes)

    internal fun stableIdentifier(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val normalized = trimmed.lowercase()
        if (normalized.startsWith("host:") ||
            normalized.startsWith("peer:") ||
            normalized.startsWith("bonjour:") ||
            normalized.startsWith("recent:") ||
            normalized.contains("@")
        ) {
            return null
        }
        return if (normalized.startsWith("id:")) normalized else "id:$normalized"
    }
}
