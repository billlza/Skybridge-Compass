package com.skybridge.compass.android.security

import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.p2p.capabilityAwareHandshakePolicyOverride
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem

fun SecuritySettings.toHandshakePolicyOverride(): P2PHandshakePolicyOverride {
    if (!pqcEnabled) {
        throw IllegalArgumentException("PQC cannot be disabled for this product line")
    }

    val normalizedTier = when (pqcMinimumTier) {
        P2PQPeriaptKem.MINIMUM_TIER_RAW, "nativePQC", "liboqsPQC", "classic" -> pqcMinimumTier
        else -> throw IllegalArgumentException("unsupported PQC minimum tier: $pqcMinimumTier")
    }
    val requirePqc = enforcePqcHandshake
    val effectiveMinimumTier =
        if (requirePqc && normalizedTier == "classic") "liboqsPQC" else normalizedTier
    val effectiveAllowClassicFallback =
        if (effectiveMinimumTier == P2PQPeriaptKem.MINIMUM_TIER_RAW) false else allowClassicFallbackForCompatibility

    return capabilityAwareHandshakePolicyOverride(
        requirePqc = requirePqc,
        allowClassicFallback = effectiveAllowClassicFallback,
        minimumTierRaw = effectiveMinimumTier,
        requireSecureEnclavePoP = requireSecureEnclavePoP
    )
}
