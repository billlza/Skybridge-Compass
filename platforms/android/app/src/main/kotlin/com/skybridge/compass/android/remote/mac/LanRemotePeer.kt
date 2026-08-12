package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.core.p2p.FormalLanBonjourEndpoint
import com.skybridge.compass.core.p2p.FormalLanPeerSnapshot
import com.skybridge.compass.discovery.data.interop.AppleBonjourPeerEndpoint
import com.skybridge.compass.discovery.data.interop.AppleBonjourPeerRoutes
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import java.util.Locale

/** Immutable same-revision handshake + Remote Desktop route selected from unified Bonjour. */
data class LanRemotePeer(
    val id: String,
    val name: String,
    val deviceType: DeviceType,
    val remoteDesktopEndpoint: FormalLanBonjourEndpoint,
    val formalSnapshot: FormalLanPeerSnapshot?
) {
    val handshakeEndpoint: FormalLanBonjourEndpoint? get() = formalSnapshot?.handshake
    val discoveryRevision: Long get() = remoteDesktopEndpoint.discoveryRevision
    val endpointDigest: String? get() = formalSnapshot?.endpointDigest
    val host: String get() = remoteDesktopEndpoint.hostAddress
    val port: Int get() = remoteDesktopEndpoint.port
    val identityHint: MacRemotePeerIdentityHint = MacRemotePeerIdentityHint(
        deviceId = remoteDesktopEndpoint.advertisedDeviceId,
        advertisedFingerprint = remoteDesktopEndpoint.advertisedProtocolFingerprint
    )

    fun sameSecuritySnapshot(other: LanRemotePeer): Boolean =
        remoteDesktopEndpoint == other.remoteDesktopEndpoint &&
            when {
                formalSnapshot == null -> other.formalSnapshot == null
                other.formalSnapshot == null -> false
                else -> formalSnapshot.sameSecuritySnapshot(other.formalSnapshot)
            }

    companion object {
        fun fromDiscoveredDevice(device: DiscoveredDevice): LanRemotePeer? {
            val routes = AppleBonjourPeerRoutes.from(device)
            val remote = routes.remoteDesktop ?: return null
            val formalRemote = remote.toFormalEndpoint() ?: return null
            val displayName = device.name.trim().ifEmpty { formalRemote.advertisedDeviceId }
            val snapshot = routes.handshake
                ?.toFormalEndpoint()
                ?.let { formalHandshake ->
                    try {
                        FormalLanPeerSnapshot(
                            displayName = displayName,
                            handshake = formalHandshake,
                            remoteDesktop = formalRemote
                        )
                    } catch (_: IllegalArgumentException) {
                        null
                    }
                }
            return LanRemotePeer(
                id = formalRemote.advertisedDeviceId,
                name = displayName,
                deviceType = device.type,
                remoteDesktopEndpoint = formalRemote,
                formalSnapshot = snapshot
            )
        }

        private fun AppleBonjourPeerEndpoint.toFormalEndpoint(): FormalLanBonjourEndpoint? {
            val normalizedInstance = instanceName?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val normalizedDeviceId = advertisedDeviceId
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: return null
            val normalizedFingerprint = advertisedFingerprint
                ?.trim()
                ?.lowercase(Locale.ROOT)
                ?.takeIf { HEX_SHA256.matches(it) }
                ?: return null
            val revision = discoveryRevision?.takeIf { it > 0L } ?: return null
            return try {
                FormalLanBonjourEndpoint(
                    serviceType = serviceType.trim().lowercase(Locale.ROOT).removeSuffix("."),
                    instanceName = normalizedInstance,
                    hostAddress = host.trim(),
                    port = port,
                    routeProvenance = provenance.name,
                    advertisedDeviceId = normalizedDeviceId,
                    advertisedProtocolFingerprint = normalizedFingerprint,
                    discoveryRevision = revision
                )
            } catch (_: IllegalArgumentException) {
                null
            }
        }

        private val HEX_SHA256 = Regex("^[0-9a-f]{64}$")
    }
}
