package com.skybridge.compass.core.webrtc

data class WebRtcDiagnosticsConfig(
    val allowLoopbackOriginAlias: Boolean = false,
    val allowLocalNetworkCompatSignaling: Boolean = false,
    val keepAliveHeartbeat: Boolean = false,
    val ignoreClassicFallbackCooldown: Boolean = false,
    val immediateHandshake: Boolean = false,
    val forceRelayIce: Boolean = false,
    val existingTrustOnly: Boolean = false
)
