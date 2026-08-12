package com.skybridge.compass.discovery.data.interop

import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice

/**
 * Reason an otherwise-discovered peer must not be presented as a connectable device.
 *
 * These map 1:1 to the illegal-entry filtering rules in R3.6 and R3.14 and are surfaced to the UI
 * as a leaf-node explanation next to a disabled connect entry (no screen/route/container changes).
 */
enum class PeerNotConnectableReason {
    /** No actionable resolved DNS-SD service endpoint exists (R3.6). */
    PORT_INFORMATION_MISSING,

    /** Identity fingerprint TXT field is absent or blank (R3.14). */
    IDENTITY_FINGERPRINT_MISSING,

    /** Identity fingerprint encoding exceeds 255 bytes (R3.14). */
    IDENTITY_FINGERPRINT_TOO_LONG,

    /** Identity fingerprint does not match the agreed 64-char lowercase-hex format (R3.14). */
    IDENTITY_FINGERPRINT_MALFORMED
}

/**
 * Result of classifying a single discovered peer for connectability.
 *
 * [isConnectable] is `true` only when no [reasons] apply. Classification is a pure per-device
 * function, so an illegal peer never affects the classification of any other peer in the list.
 */
data class PeerConnectability(
    val isConnectable: Boolean,
    val reasons: List<PeerNotConnectableReason>
) {
    /** The single reason to surface to the user, in priority order, or null when connectable. */
    val primaryReason: PeerNotConnectableReason?
        get() = reasons.firstOrNull()
}

/**
 * Pure, data/domain-layer classifier that decides whether a discovered Apple/SkyBridge peer may be
 * presented as connectable.
 *
 * Keeping this logic out of the UI lets the connect entry be enabled/disabled and its reason text
 * rendered as a leaf node inside the existing device row, without any screen restructuring (G2).
 */
object DiscoveredPeerConnectability {

    /**
     * Classify [device] against the illegal-entry filtering rules:
     *  - R3.6: no actionable resolved SRV or indexed DNS-SD route → not connectable, port reason.
     *  - R3.14: identity fingerprint missing / >255 bytes / malformed → not connectable, fp reason.
     *
     * Fingerprint validity is evaluated first so the surfaced [PeerConnectability.primaryReason]
     * names the identity problem before the port problem when both apply.
     */
    fun classify(device: DiscoveredDevice): PeerConnectability {
        val reasons = mutableListOf<PeerNotConnectableReason>()

        fingerprintReason(device)?.let { reasons += it }
        if (!AppleBonjourPeerRoutes.from(device).hasAnyRoute) {
            reasons += PeerNotConnectableReason.PORT_INFORMATION_MISSING
        }

        return PeerConnectability(
            isConnectable = reasons.isEmpty(),
            reasons = reasons.toList()
        )
    }

    private fun fingerprintReason(device: DiscoveredDevice): PeerNotConnectableReason? {
        val raw = AppleBonjourInterop.resolveTxtValue(
            device.connectionInfo.txtRecords,
            *AppleBonjourInterop.PUB_KEY_FINGERPRINT_TXT_KEYS.toTypedArray()
        )
        if (raw.isNullOrBlank()) return PeerNotConnectableReason.IDENTITY_FINGERPRINT_MISSING
        if (raw.toByteArray(Charsets.UTF_8).size > AppleBonjourInterop.MAX_PUB_KEY_FINGERPRINT_BYTES) {
            return PeerNotConnectableReason.IDENTITY_FINGERPRINT_TOO_LONG
        }
        if (AppleBonjourInterop.normalizedPubKeyFingerprint(raw) == null) {
            return PeerNotConnectableReason.IDENTITY_FINGERPRINT_MALFORMED
        }
        return null
    }

}
