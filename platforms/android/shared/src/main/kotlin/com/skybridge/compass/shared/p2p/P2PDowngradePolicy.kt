package com.skybridge.compass.shared.p2p

import java.time.Instant
import java.time.format.DateTimeFormatter
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Auditable-downgrade policy layer (Kotlin port).
 *
 * This is the Android/Kotlin port of the canonical Rust policy in the Pro release
 * (`rust/crates/skybridge-core/src/policy.rs`), which itself ports the Swift policy
 * that governs whether a crypto-suite downgrade (PQC -> Classic fallback) is
 * permitted, rate-limits it per peer, and emits a structured, replayable audit
 * record.
 *
 * It replaces the prior Android state where a fallback was only a bare
 * `usedClassicFallback: Boolean` plus a 300 s cooldown with no reason taxonomy and
 * no auditable event. The discovery design doc requires "Every fallback triggers an
 * auditable security event" (`CrossPlatformDiscoveryDesign.md` §4.3) and lists the
 * exact downgrade-resistance mitigations (§7.3: timeout never triggers fallback;
 * per-peer 5-minute cooldown; signature-algorithm confusion is rejected); the PQC
 * doc requires recording downgrade events for telemetry (`Android_PQC_Implementation.md`
 * §6.3).
 *
 * ## Downgrade-resistance invariants (paper terminology)
 * - **Local-only / pre-send**: a downgrade is decided locally before a Classic
 *   `MessageA` is sent; the wire peer cannot *induce* a downgrade.
 * - **Rate-limited**: at most one fallback per peer per [FALLBACK_COOLDOWN_MILLIS]
 *   (300 s), tracked via the shared [P2PHandshakeWire.FallbackCooldownStore].
 * - **Reason-gated**: only [FallbackReason.PQC_PROVIDER_UNAVAILABLE] and
 *   [FallbackReason.SUITE_NEGOTIATION_FAILED] are fallback-eligible. Every
 *   network-derived or authentication failure (timeout, signature/key-confirmation,
 *   replay, identity, suite-signature mismatch) is *structurally* ineligible, so a
 *   packet-dropping attacker cannot force a downgrade.
 * - **Auditable**: an authorized downgrade produces a [DowngradeEvent] that is
 *   serializable (kotlinx.serialization) and therefore replayable / verifiable after
 *   the fact.
 */

/** Per-peer cooldown enforced between two authorized Classic fallbacks (300 s). */
const val FALLBACK_COOLDOWN_MILLIS: Long = 300_000L

/**
 * The downgrade posture for a handshake.
 *
 * Mirrors `policy.rs::DowngradePolicy`. `STRICT_PQC_*` has two realizations,
 * matching the Swift `HandshakePolicy` distinction between a hard "no classic path
 * at all" stance and the bootstrap-assisted recovery flow.
 */
@Serializable
enum class DowngradePolicy {
    /** Strict PQC, compliance realization: classic fallback is *never* allowed. */
    @SerialName("strict_pqc_compliance")
    STRICT_PQC_COMPLIANCE,

    /**
     * Strict PQC, bootstrap-assisted realization: a one-time classic *control*
     * channel is allowed for paired KEM-key recovery, then mandatory PQC rekey.
     */
    @SerialName("strict_pqc_bootstrap_assisted")
    STRICT_PQC_BOOTSTRAP_ASSISTED,

    /** Prefer PQC, allow eligible + rate-limited classic business-traffic fallback. */
    @SerialName("prefer_pqc")
    PREFER_PQC,

    /** Default posture: no mandatory initial PQC attempt; same fallback gating. */
    @SerialName("default")
    DEFAULT;

    /** Whether this policy mandates that the *first* handshake attempt is PQC. */
    fun requiresPqc(): Boolean = this == STRICT_PQC_COMPLIANCE ||
        this == STRICT_PQC_BOOTSTRAP_ASSISTED ||
        this == PREFER_PQC

    /**
     * Whether this policy permits a Classic fallback to carry *business traffic*.
     *
     * Both strict realizations deny this: compliance has no classic path at all, and
     * bootstrap-assisted only permits a classic *control* channel for KEM-key
     * recovery (see [allowsBootstrapControlChannel]), never business traffic without
     * a subsequent PQC rekey.
     */
    fun allowsClassicBusinessFallback(): Boolean = this == PREFER_PQC || this == DEFAULT

    /**
     * Whether this policy permits a one-time classic *control* channel solely to
     * recover a paired peer's KEM public key (bootstrap-assisted only).
     */
    fun allowsBootstrapControlChannel(): Boolean = this == STRICT_PQC_BOOTSTRAP_ASSISTED

    /**
     * Encode this posture's `requirePQC` flag into the legacy on-wire policy byte
     * (`0x01` when PQC required, `0x00` otherwise). Kept here so the handshake
     * codecs and the policy layer agree without changing the wire format.
     */
    fun wirePolicyByte(): Byte = if (requiresPqc()) 0x01 else 0x00

    companion object {
        val DEFAULT_POLICY = PREFER_PQC

        /** Derive a posture from the legacy [P2PHandshakePolicy] flags. */
        fun fromHandshakePolicy(policy: P2PHandshakePolicy): DowngradePolicy = when {
            policy.requirePqc && !policy.allowClassicFallback -> STRICT_PQC_COMPLIANCE
            policy.requirePqc && policy.allowClassicFallback -> PREFER_PQC
            else -> DEFAULT
        }
    }
}

/**
 * Why a handshake attempt failed, partitioned into the fallback taxonomy.
 *
 * Mirrors `policy.rs::FallbackReason`. The ALLOWED set is exactly
 * `{PQC_PROVIDER_UNAVAILABLE, SUITE_NEGOTIATION_FAILED}` (the Swift whitelist).
 * Everything else is BLOCKED. Network-derived failures (notably [TIMEOUT]) are
 * *structurally* ineligible so an attacker cannot force a downgrade by dropping or
 * delaying packets.
 */
@Serializable
enum class FallbackReason(val diagnosticCode: String) {
    // ---- ALLOWED (fallback-eligible) ----
    /** No PQC provider / no usable PQC suite is available locally. */
    @SerialName("pqc_provider_unavailable")
    PQC_PROVIDER_UNAVAILABLE("pqc_provider_unavailable"),

    /** PQC suite negotiation produced no mutually supported suite. */
    @SerialName("suite_negotiation_failed")
    SUITE_NEGOTIATION_FAILED("suite_negotiation_failed"),

    // ---- BLOCKED (never fallback-eligible) ----
    /** Network-derived timeout. MUST NOT trigger fallback (downgrade resistance). */
    @SerialName("timeout")
    TIMEOUT("timeout"),

    /** Peer signature failed to verify. */
    @SerialName("signature_verification_failed")
    SIGNATURE_VERIFICATION_FAILED("signature_verification_failed"),

    /** Replay / anti-rollback detection tripped. */
    @SerialName("replay_detected")
    REPLAY_DETECTED("replay_detected"),

    /** Key confirmation (FINISHED MAC) failed. */
    @SerialName("key_confirmation_failed")
    KEY_CONFIRMATION_FAILED("key_confirmation_failed"),

    /** Peer identity did not match the pinned/enrolled identity. */
    @SerialName("identity_mismatch")
    IDENTITY_MISMATCH("identity_mismatch"),

    /** The signed suite list did not match the negotiated suite. */
    @SerialName("suite_signature_mismatch")
    SUITE_SIGNATURE_MISMATCH("suite_signature_mismatch");

    /**
     * `true` only for the ALLOWED set. Returns `false` for *every* BLOCKED reason,
     * including all network-derived failures. This is the single structural gate
     * that makes timeout/auth failures fallback-ineligible.
     */
    fun isFallbackEligible(): Boolean =
        this == PQC_PROVIDER_UNAVAILABLE || this == SUITE_NEGOTIATION_FAILED
}

/**
 * A structured, replayable downgrade audit record.
 *
 * Mirrors `policy.rs::DowngradeEvent`. Emitted *only* when a downgrade is authorized.
 * It is serializable (kotlinx.serialization) so it can be persisted, shipped to an
 * audit log, and replayed/verified later. [transcriptAnchorHex] binds the record to
 * the in-progress handshake transcript (SHA-256 of `MessageA`).
 */
@Serializable
data class DowngradeEvent(
    /** Audit schema version for forward-compatible replay. */
    @SerialName("schema_version") val schemaVersion: Int = SCHEMA_VERSION,
    /** Stable identifier of the peer the downgrade targets. */
    val peer: String,
    /** Wire id of the suite being downgraded *from* (the PQC suite attempted). */
    @SerialName("from_suite") val fromSuite: Int,
    /** Wire id of the suite being downgraded *to* (the Classic suite). */
    @SerialName("to_suite") val toSuite: Int,
    /** The fallback-eligible reason that authorized the downgrade. */
    val reason: FallbackReason,
    /** Policy posture in effect when the downgrade was authorized. */
    val policy: DowngradePolicy,
    /** Cooldown window (seconds) enforced for this peer at authorization time. */
    @SerialName("cooldown_seconds") val cooldownSeconds: Long,
    /**
     * RFC-3339 wall-clock timestamp of the authorization (for human audit; the
     * rate-limit decision itself uses the cooldown store's clock, not this field).
     */
    @SerialName("timestamp_window") val timestampWindow: String,
    /** Hex-encoded transcript hash anchoring this record to a specific handshake. */
    @SerialName("transcript_anchor") val transcriptAnchorHex: String? = null,
    /**
     * Constant downgrade-resistance descriptor, mirroring the Swift/Rust audit
     * context.
     */
    @SerialName("downgrade_resistance") val downgradeResistance: String = DOWNGRADE_RESISTANCE
) {
    companion object {
        /** Current audit schema version. */
        const val SCHEMA_VERSION: Int = 1

        /** Canonical descriptor of the enforced downgrade-resistance properties. */
        const val DOWNGRADE_RESISTANCE: String = "policy_gate+no_timeout_fallback+rate_limited"
    }
}

/** The outcome of asking the policy to authorize a downgrade. */
sealed class DowngradeDecision {
    /** Downgrade authorized; carries the structured audit record to emit. */
    data class Allowed(val event: DowngradeEvent) : DowngradeDecision()

    /** Denied because the policy forbids any classic business fallback. */
    object DeniedByPolicy : DowngradeDecision()

    /** Denied because the failure reason is not fallback-eligible (BLOCKED set). */
    data class DeniedReasonIneligible(val reason: FallbackReason) : DowngradeDecision()

    /** Denied because the per-peer cooldown has not elapsed. */
    data class DeniedRateLimited(val remainingMillis: Long) : DowngradeDecision()

    /**
     * Denied because the user has not explicitly authorized this downgrade.
     *
     * R4.5 requires a downgrade to happen *only* when the established policy permits
     * it **and** the user has explicitly authorized it. This variant is the second
     * half of that conjunction: even a policy-eligible, non-rate-limited,
     * fallback-eligible reason is denied unless an explicit [UserDowngradeAuthorization]
     * grant is presented for this peer and suite transition.
     */
    object DeniedUserNotAuthorized : DowngradeDecision()

    /** Convenience: did the policy authorize the downgrade? */
    val isAllowed: Boolean get() = this is Allowed

    /** The audit record, if the downgrade was authorized. */
    fun eventOrNull(): DowngradeEvent? = (this as? Allowed)?.event
}

/**
 * An explicit user grant that authorizes a specific PQC→Classic downgrade.
 *
 * R4.5 mandates that a downgrade occur *only* when (a) the established policy permits
 * it (already enforced by [PolicyGate.authorizeDowngrade]) **and** (b) the user has
 * explicitly authorized it. This type models (b) as a first-class, non-defaultable
 * value so that "the user authorized a downgrade" can never be assumed implicitly:
 * a caller must construct a [Granted] with the exact peer and suite transition the
 * user consented to, or the downgrade is denied.
 *
 * The grant is intentionally *scoped* (peer + from/to suite): a consent captured for
 * one peer or one suite transition cannot silently authorize a different one.
 */
sealed interface UserDowngradeAuthorization {
    /** The user has NOT authorized any downgrade. This is the safe default. */
    data object NotAuthorized : UserDowngradeAuthorization

    /**
     * The user explicitly authorized downgrading [peer] from [fromSuiteWireId] to
     * [toSuiteWireId]. A grant only authorizes the exact transition it names.
     */
    data class Granted(
        val peer: String,
        val fromSuiteWireId: Int,
        val toSuiteWireId: Int
    ) : UserDowngradeAuthorization

    /** Does this authorization cover a downgrade of [peer] from [from] to [to]? */
    fun authorizes(peer: String, from: P2PCryptoSuite, to: P2PCryptoSuite): Boolean =
        this is Granted &&
            this.peer == peer &&
            this.fromSuiteWireId == from.wireId.toInt() &&
            this.toSuiteWireId == to.wireId.toInt()
}

/**
 * The first-class policy object that gates suite selection / classic fallback.
 *
 * Mirrors `policy.rs::PolicyGate`. It bundles a [DowngradePolicy] with a per-peer
 * rate limiter backed by the shared [P2PHandshakeWire.FallbackCooldownStore] (so the
 * 300 s/peer cooldown has a single source of truth across the handshake) and is the
 * single authority the handshake code consults before sending a downgraded (Classic)
 * `MessageA`.
 */
class PolicyGate(
    val policy: DowngradePolicy,
    private val cooldownStore: P2PHandshakeWire.FallbackCooldownStore =
        P2PHandshakeWire.InMemoryFallbackCooldownStore(),
    private val cooldownMillis: Long = FALLBACK_COOLDOWN_MILLIS,
    private val clock: () -> Long = { System.currentTimeMillis() }
) {
    /**
     * Decide whether a PQC -> Classic downgrade is authorized for [peer] given the
     * failure [reason], recording the fallback (and starting the cooldown) *only*
     * when it authorizes one.
     *
     * Ordering matters and mirrors the Rust gate:
     * 1. reason eligibility (structural — blocks timeout/auth failures),
     * 2. policy posture (strict modes deny business fallback),
     * 3. per-peer rate limit (cooldown),
     * and only then is the cooldown clock armed and a [DowngradeEvent] minted.
     */
    fun authorizeDowngrade(
        peer: String,
        fromSuite: P2PCryptoSuite,
        toSuite: P2PCryptoSuite,
        reason: FallbackReason,
        transcriptAnchor: ByteArray? = null
    ): DowngradeDecision {
        require(peer.isNotBlank()) { "peer is required for downgrade authorization" }

        // 1. Structural eligibility: BLOCKED reasons can never be downgraded.
        if (!reason.isFallbackEligible()) {
            return DowngradeDecision.DeniedReasonIneligible(reason)
        }

        // 2. Policy posture: strict modes forbid classic business fallback.
        if (!policy.allowsClassicBusinessFallback()) {
            return DowngradeDecision.DeniedByPolicy
        }

        // 3. Per-peer rate limit (shared cooldown store).
        val decision = P2PHandshakeWire.evaluateClassicFallbackCooldown(
            peerId = peer,
            fallbackCooldownStore = cooldownStore,
            nowUnixTimeMillis = clock(),
            cooldownMillis = cooldownMillis
        )
        if (!decision.allowed) {
            return DowngradeDecision.DeniedRateLimited(decision.remainingMillis)
        }

        // Authorized: arm the cooldown and mint the auditable record.
        P2PHandshakeWire.recordClassicFallback(
            peerId = peer,
            fallbackCooldownStore = cooldownStore,
            nowUnixTimeMillis = clock()
        )
        val event = DowngradeEvent(
            peer = peer,
            fromSuite = fromSuite.wireId.toInt(),
            toSuite = toSuite.wireId.toInt(),
            reason = reason,
            policy = policy,
            cooldownSeconds = cooldownMillis / 1000L,
            timestampWindow = DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(clock())),
            transcriptAnchorHex = transcriptAnchor?.let(::hexEncode)
        )
        return DowngradeDecision.Allowed(event)
    }

    /**
     * R4.5 authorization: authorize a PQC→Classic downgrade **only** when the
     * established policy permits it (all of [authorizeDowngrade]'s structural gates)
     * *and* the user has explicitly authorized this exact transition via
     * [userAuthorization].
     *
     * The user-consent gate is evaluated **first and independently** of the policy
     * gate, so it can never be bypassed by any policy posture, reason, or cooldown
     * state:
     * - if [userAuthorization] does not cover this `peer`/`fromSuite`→`toSuite`
     *   transition, the result is [DowngradeDecision.DeniedUserNotAuthorized] and the
     *   per-peer cooldown is **not** consumed and **no** [DowngradeEvent] is minted;
     * - only if the user authorized it do we delegate to [authorizeDowngrade], whose
     *   structural gates (reason eligibility, policy posture, rate limit) still apply.
     *
     * Consequently a downgrade is authorized (and an auditable [DowngradeEvent]
     * emitted) *iff* policy-eligibility **and** explicit user authorization both hold
     * — exactly R4.5's conjunction. BLOCKED reasons (timeout / signature / replay /
     * key-confirmation / identity / suite-signature) remain structurally ineligible
     * even with a user grant, because [authorizeDowngrade] rejects them before minting
     * any event.
     */
    fun authorizeUserApprovedDowngrade(
        peer: String,
        fromSuite: P2PCryptoSuite,
        toSuite: P2PCryptoSuite,
        reason: FallbackReason,
        userAuthorization: UserDowngradeAuthorization,
        transcriptAnchor: ByteArray? = null
    ): DowngradeDecision {
        require(peer.isNotBlank()) { "peer is required for downgrade authorization" }

        // R4.5 conjunction, half 2: explicit user authorization is mandatory and is
        // checked before any cooldown is consumed or event minted.
        if (!userAuthorization.authorizes(peer, fromSuite, toSuite)) {
            return DowngradeDecision.DeniedUserNotAuthorized
        }

        // R4.5 conjunction, half 1: the established policy must also permit it. All of
        // authorizeDowngrade's structural gates (reason eligibility incl. the BLOCKED
        // set, policy posture, per-peer rate limit) still apply.
        return authorizeDowngrade(
            peer = peer,
            fromSuite = fromSuite,
            toSuite = toSuite,
            reason = reason,
            transcriptAnchor = transcriptAnchor
        )
    }
}

private fun hexEncode(bytes: ByteArray): String {
    val sb = StringBuilder(bytes.size * 2)
    for (b in bytes) sb.append("%02x".format(b.toInt() and 0xFF))
    return sb.toString()
}
