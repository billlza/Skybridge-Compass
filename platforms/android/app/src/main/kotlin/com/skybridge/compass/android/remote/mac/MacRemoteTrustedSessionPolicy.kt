package com.skybridge.compass.android.remote.mac

internal object MacRemoteTrustedSessionPolicy {
    fun isTrustedRemoteControlSession(state: MacRemoteControlClient.SecurityState): Boolean =
        state is MacRemoteControlClient.SecurityState.Secure &&
            state.trustState != MacRemoteControlClient.TrustState.UNTRUSTED_EPHEMERAL

    fun requireTrustedRemoteControlTrust(
        peerId: String?,
        trustState: MacRemoteControlClient.TrustState
    ): MacRemoteControlClient.TrustState {
        require(trustState != MacRemoteControlClient.TrustState.UNTRUSTED_EPHEMERAL) {
            untrustedEphemeralReason(peerId)
        }
        return trustState
    }

    fun untrustedEphemeralReason(peerId: String?): String =
        "peer identity is not trusted for remote control: ${peerId ?: "unknown peer"}"
}
