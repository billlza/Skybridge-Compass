package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop

data class MacRemotePeerIdentityHint(
    val deviceId: String?,
    val advertisedFingerprint: String?
) {
    val hasAdvertisedIdentityFields: Boolean
        get() = !deviceId.isNullOrBlank() && !advertisedFingerprint.isNullOrBlank()
}

fun MacRemoteDiscovery.Service.identityHint(): MacRemotePeerIdentityHint =
    macRemotePeerIdentityHint(txt)

fun macRemotePeerIdentityHint(txt: Map<String, String>): MacRemotePeerIdentityHint =
    MacRemotePeerIdentityHint(
        deviceId = AppleBonjourInterop.resolveTxtValue(txt, "deviceId", "uuid", "uniqueId")
            ?.trim()
            ?.takeIf { it.isNotEmpty() },
        advertisedFingerprint = AppleBonjourInterop.resolveTxtValue(txt, "pubKeyFP")
            ?.trim()
            ?.lowercase()
            ?.takeIf { HEX_SHA256_PATTERN.matches(it) }
    )

private val HEX_SHA256_PATTERN = Regex("^[0-9a-f]{64}$")
