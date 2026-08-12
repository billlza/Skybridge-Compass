package com.skybridge.compass.core.webrtc

import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem

internal object CurrentPathProtocolAuthority {
    fun bindingFor(
        deviceId: String,
        policy: P2PHandshakePolicyOverride,
        signingKeys: LocalP2PIdentity.ProtocolSigningKeys
    ): ProtocolIdentityBinding {
        return when (protocolSigningAlgorithmFor(policy.minimumTierRaw)) {
            ProtocolSigningAlgorithm.ED25519 -> ProtocolIdentityBinding(
                deviceId = deviceId,
                protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
                protocolPublicKeyBytes = signingKeys.ed25519PublicRaw32
            )

            ProtocolSigningAlgorithm.ML_DSA_65 -> {
                val publicKey = requireNotNull(signingKeys.mlDsa65PublicKeyRaw) {
                    "ML-DSA-65 public key unavailable for current-path PQC authority"
                }
                ProtocolIdentityBinding(
                    deviceId = deviceId,
                    protocolSigningAlgorithm = ProtocolSigningAlgorithm.ML_DSA_65,
                    protocolPublicKeyBytes = publicKey
                )
            }
        }
    }

    internal fun protocolSigningAlgorithmFor(minimumTierRaw: String): ProtocolSigningAlgorithm =
        when (minimumTierRaw.trim()) {
            "classic" -> ProtocolSigningAlgorithm.ED25519
            P2PQPeriaptKem.MINIMUM_TIER_RAW,
            "nativePQC",
            "liboqsPQC" -> ProtocolSigningAlgorithm.ML_DSA_65
            else -> throw IllegalArgumentException(
                "Unsupported current-path handshake minimum tier: $minimumTierRaw"
            )
        }
}
