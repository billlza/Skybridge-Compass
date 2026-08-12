package com.skybridge.compass.android.remote.mac

internal object MacRemotePeerIdentityPolicy {
    fun stablePeerIdForSecureConnection(
        target: MacRemoteControlClient.ConnectionTarget,
        enableHandshake: Boolean,
        securityConfig: MacRemoteControlClient.SecurityConfig
    ): String? {
        val stablePeerId = target.deviceIdHint
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        if (enableHandshake && securityConfig.encryptionRequired) {
            require(stablePeerId != null) {
                "stable peer deviceId is required for secure LAN remote control"
            }
        }
        return stablePeerId
    }
}
