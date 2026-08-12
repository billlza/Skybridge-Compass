package com.skybridge.compass.android.remote.mac

internal data class MacRemotePeerTrustEvaluation(
    val trustState: MacRemoteControlClient.TrustState,
    val fingerprintToPersist: String?,
    val observedFingerprint: String?
)

internal object MacRemotePeerTrustPolicy {
    fun evaluate(
        peerId: String,
        observedFingerprint: String,
        advertisedFingerprint: String?,
        advertisedFingerprintTrustSource: MacRemoteControlClient.FingerprintTrustSource,
        pinnedFingerprint: String?,
        allowTrustOnFirstUse: Boolean
    ): MacRemotePeerTrustEvaluation {
        require(peerId.isNotBlank()) { "peerId is required for trust evaluation" }
        require(observedFingerprint.isNotBlank()) { "observed fingerprint is required" }

        val normalizedObserved = observedFingerprint.trim().lowercase()
        val normalizedAdvertised = advertisedFingerprint
            ?.trim()
            ?.lowercase()
            ?.takeIf { it.isNotEmpty() }
        val normalizedPinned = pinnedFingerprint
            ?.trim()
            ?.lowercase()
            ?.takeIf { it.isNotEmpty() }

        if (normalizedAdvertised != null && normalizedAdvertised != normalizedObserved) {
            error("advertised fingerprint mismatch")
        }

        return when {
            normalizedPinned != null && normalizedPinned == normalizedObserved ->
                MacRemotePeerTrustEvaluation(
                    trustState = MacRemoteControlClient.TrustState.TRUSTED_EXISTING,
                    fingerprintToPersist = null,
                    observedFingerprint = normalizedObserved
                )

            normalizedPinned != null -> error("peer identity mismatch")

            normalizedAdvertised != null &&
                advertisedFingerprintTrustSource == MacRemoteControlClient.FingerprintTrustSource.TRUSTED_CONFIGURATION ->
                MacRemotePeerTrustEvaluation(
                    trustState = MacRemoteControlClient.TrustState.TRUSTED_NEW,
                    fingerprintToPersist = normalizedObserved,
                    observedFingerprint = normalizedObserved
                )

            allowTrustOnFirstUse ->
                MacRemotePeerTrustEvaluation(
                    trustState = MacRemoteControlClient.TrustState.TRUSTED_NEW,
                    fingerprintToPersist = normalizedObserved,
                    observedFingerprint = normalizedObserved
                )

            else ->
                MacRemotePeerTrustEvaluation(
                    trustState = MacRemoteControlClient.TrustState.UNTRUSTED_EPHEMERAL,
                    fingerprintToPersist = null,
                    observedFingerprint = normalizedObserved
                )
        }
    }
}
