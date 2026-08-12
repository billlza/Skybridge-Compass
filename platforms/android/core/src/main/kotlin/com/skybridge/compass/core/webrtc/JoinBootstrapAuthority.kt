package com.skybridge.compass.core.webrtc

import java.util.Base64

internal object JoinBootstrapAuthority {
    fun fromJoinEnvelope(env: WebRtcSignalingEnvelope): ProtocolIdentityBinding? {
        require(env.type == WebRtcSignalingEnvelope.MessageType.JOIN) {
            "JOIN bootstrap authority requires a join envelope"
        }
        val payload = env.payload ?: return null
        return fromPayload(deviceId = env.from, payload = payload)
    }

    fun fromPayload(
        deviceId: String,
        payload: WebRtcSignalingEnvelope.Payload
    ): ProtocolIdentityBinding? {
        val algorithm = payload.protocolSigningAlgorithm
        val fingerprint = payload.protocolPublicKeyFingerprint
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        val publicKeyBase64 = payload.protocolPublicKeyBytes
            ?.trim()
            ?.takeIf { it.isNotEmpty() }

        if (algorithm == null && fingerprint == null && publicKeyBase64 == null) {
            return null
        }
        require(algorithm != null && fingerprint != null && publicKeyBase64 != null) {
            "JOIN bootstrap authority is incomplete"
        }

        val publicKeyBytes = runCatching {
            Base64.getDecoder().decode(publicKeyBase64)
        }.getOrElse {
            throw IllegalArgumentException("JOIN bootstrap authority public key is not valid base64")
        }

        return ProtocolIdentityBinding(
            deviceId = deviceId,
            protocolSigningAlgorithm = algorithm,
            protocolPublicKeyBytes = publicKeyBytes,
            protocolPublicKeyFingerprint = fingerprint
        )
    }
}
