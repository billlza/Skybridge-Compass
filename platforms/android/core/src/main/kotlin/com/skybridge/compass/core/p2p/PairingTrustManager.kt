package com.skybridge.compass.core.p2p

import java.util.UUID

enum class PairingTrustConflict {
    IDENTITY_CONFLICT,
    DEVICE_ID_MIGRATION_REQUIRED,
    QUARANTINED_IDENTITY,
    REVOKED_IDENTITY
}

data class PairingTrustRequest(
    val requestId: String = UUID.randomUUID().toString(),
    val peerId: String,
    val declaredDeviceId: String,
    val deviceName: String? = null,
    val platform: String? = null,
    val modelName: String? = null,
    val osVersion: String? = null,
    val chip: String? = null,
    val protocolPublicKeyFingerprint: String? = null,
    val conflict: PairingTrustConflict? = null
)

enum class PairingTrustDecision {
    TRUST_ALWAYS,
    ALLOW_ONCE,
    DECLINE
}

fun interface PairingTrustApprovalProvider {
    suspend fun requestDecision(request: PairingTrustRequest): PairingTrustDecision
}

object PairingTrustManager {
    @Volatile
    var approvalProvider: PairingTrustApprovalProvider? = null

    suspend fun requestDecision(request: PairingTrustRequest): PairingTrustDecision {
        val provider = approvalProvider
        if (provider == null) {
            return if (request.conflict == null) {
                PairingTrustDecision.TRUST_ALWAYS
            } else {
                PairingTrustDecision.DECLINE
            }
        }
        return provider.requestDecision(request)
    }
}
