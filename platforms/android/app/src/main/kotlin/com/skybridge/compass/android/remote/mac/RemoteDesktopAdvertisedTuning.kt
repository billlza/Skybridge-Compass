package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.android.data.RemoteDesktopQualityPreset

/**
 * Pure, side-effect-free derivation of the transport-tuning values the Android viewer advertises to
 * the host in [RemoteDesktopStreamConfiguration] (`refreshStrategy` / `jitterBufferFrames` /
 * `lossRecoveryMode`).
 *
 * Requirement 6.2 has two obligations that must BOTH hold:
 *
 *  1. **Enum convergence.** The advertised values may only be drawn from the defined enums:
 *       - `jitterBufferFrames` ∈ {1, 2, 3}
 *       - `lossRecoveryMode`   ∈ {`fast-retransmit`, `balanced`, `resilient`}
 *       - `refreshStrategy`    ∈ {`instant`, `aggressive`, `balanced`, `quality-biased`}
 *     The prior hardcoded values `refreshStrategy = "adaptive"` and `lossRecoveryMode = "none"`
 *     were NOT members of these enums, and `jitterBufferFrames` was omitted entirely.
 *
 *  2. **Honesty.** Each advertised value must match what the viewer's receive/render path ACTUALLY
 *     does. We must never advertise an aspirational capability the viewer does not implement.
 *
 * ## Assessment of the actual Android viewer behavior
 *
 * The viewer's receive/render path is `SurfaceBackedRemoteVideoDecoder`
 * (ui/screens/remotecontrol/RemoteVideoDecoder.kt). Its observable behavior:
 *   - It holds at most ONE `pendingFrame`; each newly submitted frame overwrites the previous one
 *     and is rendered immediately (`submit` -> `renderPendingFrameLocked`). There is no multi-frame
 *     reorder/jitter buffer, so the honest jitter depth is **1 frame**.
 *   - The `MediaCodec` is configured with `KEY_LOW_LATENCY = 1` and output buffers are released
 *     immediately (`releaseOutputBuffer(index, true)`), i.e. render-on-arrival with no queued depth.
 *   - There is NO retransmit / NACK / FEC path anywhere in the viewer. Lost frames are simply
 *     skipped, so the viewer performs no loss recovery.
 *   - Frames are decoded whole with no damage-region / partial-refresh handling, so there is no
 *     damage-aware refresh strategy on the viewer side.
 *
 * Because the viewer implements none of the richer buffering/retransmit behaviors that the higher
 * quality presets describe (those describe the HOST's outbound frame pump, not the Android viewer's
 * receive path), the honest advertised tuning is the most conservative enum member consistent with
 * "render immediately, single-frame depth, no retransmit":
 *   - `jitterBufferFrames = 1`
 *   - `lossRecoveryMode   = balanced`  (the neutral member; `fast-retransmit`/`resilient` would
 *      claim active retransmit/heavy recovery the viewer does not perform)
 *   - `refreshStrategy    = balanced`  (`instant`/`aggressive`/`quality-biased` would claim
 *      refresh behavior the viewer does not drive)
 *
 * The derivation is written to be preset-aware and clamped to [ViewerReceiveCapabilities] so that if
 * a future change gives the viewer a real multi-frame buffer or retransmit path, only the capability
 * descriptor needs to change and the advertised values will honestly rise to the preset's request
 * (bounded by what is actually implemented). This keeps advertisement and behavior in lockstep.
 *
 * G4 (no wire-protocol change): only the existing `RemoteDesktopStreamConfiguration` fields are used;
 * no new wire fields are introduced.
 */
object RemoteDesktopAdvertisedTuning {

    const val MIN_JITTER_BUFFER_FRAMES: Int = 1
    const val MAX_JITTER_BUFFER_FRAMES: Int = 3

    /** The only enum-valid loss-recovery modes (Requirement 6.2). */
    val VALID_LOSS_RECOVERY_MODES: Set<String> =
        setOf("fast-retransmit", "balanced", "resilient")

    /** The only enum-valid refresh strategies (Requirement 6.2). */
    val VALID_REFRESH_STRATEGIES: Set<String> =
        setOf("instant", "aggressive", "balanced", "quality-biased")

    /** Most conservative honest members used when the viewer does not implement the behavior. */
    const val CONSERVATIVE_LOSS_RECOVERY_MODE: String = "balanced"
    const val CONSERVATIVE_REFRESH_STRATEGY: String = "balanced"

    /**
     * Describes what the viewer's receive/render path actually implements. Advertised values are
     * clamped to this so we never advertise more than we do.
     */
    data class ViewerReceiveCapabilities(
        /** Deepest multi-frame jitter buffer the viewer actually maintains (>= 1). */
        val maxImplementedJitterBufferFrames: Int,
        /** True only if the viewer actually performs retransmit / loss recovery. */
        val implementsLossRecovery: Boolean,
        /** True only if the viewer actually drives a damage-aware / non-balanced refresh strategy. */
        val implementsDamageAwareRefresh: Boolean
    )

    /**
     * The current Android viewer (`SurfaceBackedRemoteVideoDecoder`): single-frame depth, no
     * retransmit, no damage-aware refresh. See class doc for the evidence behind these values.
     */
    val CURRENT_VIEWER_CAPABILITIES: ViewerReceiveCapabilities =
        ViewerReceiveCapabilities(
            maxImplementedJitterBufferFrames = 1,
            implementsLossRecovery = false,
            implementsDamageAwareRefresh = false
        )

    /** The enum-valid, honesty-clamped tuning advertised on the wire. */
    data class AdvertisedTransportTuning(
        val jitterBufferFrames: Int,
        val lossRecoveryMode: String,
        val refreshStrategy: String
    )

    /**
     * Derive the advertised tuning for [preset] clamped to what [capabilities] actually implements.
     *
     * The result is guaranteed to satisfy Requirement 6.2:
     *  - `jitterBufferFrames` ∈ {1,2,3},
     *  - `lossRecoveryMode` ∈ [VALID_LOSS_RECOVERY_MODES],
     *  - `refreshStrategy` ∈ [VALID_REFRESH_STRATEGIES],
     *  - and every value is bounded by the corresponding capability so it matches actual behavior.
     */
    fun derive(
        preset: RemoteDesktopQualityPreset,
        capabilities: ViewerReceiveCapabilities = CURRENT_VIEWER_CAPABILITIES
    ): AdvertisedTransportTuning {
        val implementedDepth =
            capabilities.maxImplementedJitterBufferFrames
                .coerceIn(MIN_JITTER_BUFFER_FRAMES, MAX_JITTER_BUFFER_FRAMES)

        // Never advertise a deeper buffer than we actually keep; also clamp the (already enum-valid)
        // preset value into {1,2,3} defensively.
        val jitter =
            preset.jitterBufferFrames
                .coerceIn(MIN_JITTER_BUFFER_FRAMES, MAX_JITTER_BUFFER_FRAMES)
                .coerceAtMost(implementedDepth)

        val loss =
            if (capabilities.implementsLossRecovery &&
                preset.lossRecoveryMode in VALID_LOSS_RECOVERY_MODES
            ) {
                preset.lossRecoveryMode
            } else {
                CONSERVATIVE_LOSS_RECOVERY_MODE
            }

        val refresh =
            if (capabilities.implementsDamageAwareRefresh &&
                preset.refreshStrategy in VALID_REFRESH_STRATEGIES
            ) {
                preset.refreshStrategy
            } else {
                CONSERVATIVE_REFRESH_STRATEGY
            }

        return AdvertisedTransportTuning(
            jitterBufferFrames = jitter,
            lossRecoveryMode = loss,
            refreshStrategy = refresh
        )
    }

    /**
     * Convenience for the send path: derive the honest tuning for the current viewer. With the
     * current viewer this is always `(jitterBufferFrames=1, lossRecoveryMode=balanced,
     * refreshStrategy=balanced)` regardless of [preset], because the viewer does not implement the
     * richer behaviors the higher presets describe.
     */
    fun deriveForCurrentViewer(
        preset: RemoteDesktopQualityPreset = RemoteDesktopQualityPreset.AUTOMATIC
    ): AdvertisedTransportTuning = derive(preset, CURRENT_VIEWER_CAPABILITIES)
}
