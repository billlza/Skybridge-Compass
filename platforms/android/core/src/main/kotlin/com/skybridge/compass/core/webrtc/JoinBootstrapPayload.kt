package com.skybridge.compass.core.webrtc

import com.skybridge.compass.core.p2p.AppMessage
import com.skybridge.compass.core.p2p.PeerKemPublicKeyValidation
import java.util.Base64

internal object JoinBootstrapPayload {
    fun fromPairingIdentity(
        payload: AppMessage.PairingIdentityExchangePayload,
        authority: ProtocolIdentityBinding? = null
    ): WebRtcSignalingEnvelope.Payload? {
        if (payload.kemPublicKeys.isEmpty()) return null
        return WebRtcSignalingEnvelope.Payload(
            protocolSigningAlgorithm = authority?.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint = authority?.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes = authority?.protocolPublicKeyBytes?.let {
                Base64.getEncoder().encodeToString(it)
            },
            kemPublicKeys = payload.kemPublicKeys.map { key ->
                require(key.publicKey.isNotEmpty()) {
                    "JOIN bootstrap KEM public key is empty for suite=${key.suiteWireId}"
                }
                PeerKemPublicKeyValidation.validateWirePublicKey(key.suiteWireId, key.publicKey)
                WebRtcSignalingEnvelope.Payload.BootstrapKemPublicKey(
                    suiteWireId = key.suiteWireId,
                    publicKey = Base64.getEncoder().encodeToString(key.publicKey)
                )
            },
            platform = payload.platform,
            osVersion = payload.osVersion
        )
    }
}
