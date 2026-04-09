package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop

data class MacRemotePeerIdentityHint(
    val deviceId: String?,
    val advertisedFingerprint: String?
)

fun MacRemoteDiscovery.Service.identityHint(): MacRemotePeerIdentityHint =
    MacRemotePeerIdentityHint(
        deviceId = AppleBonjourInterop.resolveTxtValue(txt, "deviceId", "uuid", "uniqueId"),
        advertisedFingerprint = AppleBonjourInterop.resolveTxtValue(txt, "pubKeyFP")
            ?.trim()
            ?.lowercase()
            ?.takeIf { it.isNotEmpty() }
    )
