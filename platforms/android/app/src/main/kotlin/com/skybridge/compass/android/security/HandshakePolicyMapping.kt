package com.skybridge.compass.android.security

import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.p2p.capabilityAwareHandshakePolicyOverride

fun SecuritySettings.toHandshakePolicyOverride(): P2PHandshakePolicyOverride {
    if (!pqcEnabled) {
        return capabilityAwareHandshakePolicyOverride(
            requirePqc = false,
            allowClassicFallback = true,
            minimumTierRaw = "classic",
            requireSecureEnclavePoP = requireSecureEnclavePoP
        )
    }

    val normalizedTier = when (pqcMinimumTier) {
        "nativePQC", "liboqsPQC", "classic" -> pqcMinimumTier
        else -> "liboqsPQC"
    }
    val requirePqc = enforcePqcHandshake
    val effectiveMinimumTier =
        if (requirePqc && normalizedTier == "classic") "liboqsPQC" else normalizedTier

    return capabilityAwareHandshakePolicyOverride(
        requirePqc = requirePqc,
        allowClassicFallback = allowClassicFallbackForCompatibility,
        minimumTierRaw = effectiveMinimumTier,
        requireSecureEnclavePoP = requireSecureEnclavePoP
    )
}
