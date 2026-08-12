package com.skybridge.compass.core.webrtc

data class AuthenticatedPeerMetadata(
    val deviceId: String,
    val deviceName: String? = null,
    val accountDisplayName: String? = null,
    val nebulaId: String? = null,
    val platform: String? = null,
    val modelName: String? = null,
    val osVersion: String? = null,
    val chip: String? = null,
    val capabilities: List<String>? = null,
    val remoteVideoFormats: List<String>? = null
)
