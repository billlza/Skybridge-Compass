package com.skybridge.compass.discovery.domain.entities

/**
 * Protocol profiles used by the Android app to keep production defaults aligned
 * with the paths that are implemented and validated for cross-platform interop.
 */
object DiscoveryProtocolProfiles {
    /**
     * Primary Apple interop discovery path.
     *
     * Bonjour is the protocol currently exercised by the Android <-> iOS/macOS
     * LAN remote desktop path and is the only direct-connect path we treat as
     * production-ready by default.
     */
    val appleInteropDefaults: Set<DiscoveryProtocol> = setOf(DiscoveryProtocol.BONJOUR)

    /**
     * Discovery protocols that are allowed to offer a direct "Connect" action
     * in the current production app flow.
     */
    val directConnectProtocols: Set<DiscoveryProtocol> = appleInteropDefaults

    fun supportsDirectConnect(protocol: DiscoveryProtocol): Boolean =
        protocol in directConnectProtocols
}
