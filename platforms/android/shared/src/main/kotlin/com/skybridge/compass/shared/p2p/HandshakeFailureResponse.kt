package com.skybridge.compass.shared.p2p

/**
 * The permitted response to a classified handshake failure, encoding the R4.5 / R4.6 /
 * R4.13 invariants as a pure, side-effect-free decision function.
 *
 * This is the single authority the connection layer consults after a handshake fails
 * to decide what it may and may not do next. It exists so the "failure never
 * downgrades, never switches to an unauthenticated path, and (for a fingerprint
 * mismatch) never auto-reconnects" rules are expressed once, in one testable place,
 * rather than re-derived at each throw-site.
 *
 * ### The invariants (design.md §4 Connection_Subsystem; ADR 2026-07-01 Decision 4/7)
 * - **R4.5 / R4.6 — failure never downgrades**: for *every* [HandshakeFailureCategory],
 *   [permitsAutomaticSuiteDowngrade] is `false`. A crypto-suite downgrade is decided
 *   *before* a handshake is attempted (the negotiation/planning phase in
 *   [P2PHandshakeClient.resolveSuitePlan]) and is gated by the reason-eligible,
 *   user-authorized [PolicyGate]; a *failure* of an in-progress handshake is never a
 *   downgrade trigger. This mirrors [FallbackReason]'s BLOCKED set, which makes every
 *   network-derived / authentication failure structurally fallback-ineligible.
 * - **R4.5 / R4.6 — failure never switches to an unauthenticated path**: for *every*
 *   category, [permitsUnauthenticatedPathSwitch] is `false`. Signaling admission,
 *   TURN admission, and current-path auth all fail closed (ADR Decision 4); there is
 *   no code path that answers "yes" here.
 * - **R4.13 — a fingerprint mismatch aborts immediately and never auto-reconnects**:
 *   [permitsAutomaticReconnect] is `false` for
 *   [HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH] (and for the other
 *   authentication-integrity categories, which retrying cannot fix). Only genuinely
 *   transient categories (timeout / network-unreachable) are reconnect-eligible, and
 *   even then the actual attempt count/backoff is owned by
 *   [com.skybridge.compass.core.network.ReconnectPolicy].
 */
object HandshakeFailureResponse {

    /**
     * Whether a *handshake failure* of [category] may trigger an automatic crypto-suite
     * downgrade.
     *
     * Always `false`. A downgrade is a pre-send, policy-gated, user-authorized decision
     * (see [PolicyGate.authorizeUserApprovedDowngrade]); no handshake failure — of any
     * category — authorizes one (R4.5 / R4.6, ADR Decision 7).
     */
    @Suppress("UNUSED_PARAMETER")
    fun permitsAutomaticSuiteDowngrade(category: HandshakeFailureCategory): Boolean = false

    /**
     * Whether a *handshake failure* of [category] may switch the connection to an
     * unauthenticated transport/path.
     *
     * Always `false`. Signaling/TURN/path-auth failures fail closed and never fall
     * back to an unauthenticated path (R4.5, ADR Decision 4).
     */
    @Suppress("UNUSED_PARAMETER")
    fun permitsUnauthenticatedPathSwitch(category: HandshakeFailureCategory): Boolean = false

    /**
     * Whether a *handshake failure* of [category] is eligible for an automatic
     * reconnect at all.
     *
     * `false` for every authentication-integrity failure — most importantly
     * [HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH] (R4.13: abort
     * immediately, do not auto-reconnect) — because reconnecting cannot resolve a
     * mismatch/verification/replay condition and would only repeat the failure.
     * `true` only for the transient transport categories, whose recovery is what the
     * reconnect backoff exists for (R4.7).
     */
    fun permitsAutomaticReconnect(category: HandshakeFailureCategory): Boolean = when (category) {
        // Transient transport conditions — genuinely recoverable, so reconnect-eligible.
        HandshakeFailureCategory.TIMEOUT,
        HandshakeFailureCategory.NETWORK_UNREACHABLE -> true

        // Authentication-integrity / negotiation-terminal conditions — reconnecting
        // repeats the same failure and (for the fingerprint mismatch) is explicitly
        // forbidden by R4.13. Never auto-reconnect.
        HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH,
        HandshakeFailureCategory.SIGNATURE_VERIFICATION_FAILED,
        HandshakeFailureCategory.KEY_CONFIRMATION_FAILED,
        HandshakeFailureCategory.REPLAY_DETECTED,
        HandshakeFailureCategory.SUITE_SIGNATURE_MISMATCH,
        HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY,
        HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE,
        HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE -> false
    }
}
