package com.skybridge.compass.core.webrtc

import com.skybridge.compass.core.p2p.AppMessage
import com.skybridge.compass.core.p2p.PeerKemPublicKeyValidation
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.QPeriaptPlatformPolicy
import java.util.Base64

internal data class JoinBootstrapKemAdmissionResult(
    val acceptedKeys: List<AppMessage.KemPublicKeyInfo>,
    val rejectedQPeriapt: Boolean
)

internal object JoinBootstrapKemAdmission {
    fun admit(
        keys: List<WebRtcSignalingEnvelope.Payload.BootstrapKemPublicKey>,
        platform: String?,
        osVersion: String?
    ): JoinBootstrapKemAdmissionResult {
        var rejectedQPeriapt = false
        val accepted = keys.mapNotNull { key ->
            require(key.publicKey.isNotBlank()) {
                "JOIN bootstrap KEM public key is blank for suite=${key.suiteWireId}"
            }
            if (key.suiteWireId == P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND.wireId.toInt() &&
                !QPeriaptPlatformPolicy.isAppPeerEligible(platform = platform, osVersion = osVersion)
            ) {
                rejectedQPeriapt = true
                null
            } else {
                val publicKey = decodePublicKey(key)
                PeerKemPublicKeyValidation.validateWirePublicKey(key.suiteWireId, publicKey)
                AppMessage.KemPublicKeyInfo(
                    suiteWireId = key.suiteWireId,
                    publicKey = publicKey
                )
            }
        }
        return JoinBootstrapKemAdmissionResult(
            acceptedKeys = accepted,
            rejectedQPeriapt = rejectedQPeriapt
        )
    }

    private fun decodePublicKey(key: WebRtcSignalingEnvelope.Payload.BootstrapKemPublicKey): ByteArray =
        try {
            Base64.getDecoder().decode(key.publicKey)
        } catch (e: IllegalArgumentException) {
            throw IllegalArgumentException(
                "JOIN bootstrap KEM public key is not valid base64 for suite=${key.suiteWireId}",
                e
            )
        }
}
