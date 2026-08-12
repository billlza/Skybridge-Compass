package com.skybridge.compass.shared.p2p

/**
 * Mutually-exclusive classification of a P2P handshake failure.
 *
 * This is the Android/Kotlin realization of the failure taxonomy mandated by
 * acceptance criterion **R4.4**, which requires that a failed handshake negotiation
 * report *exactly one* reason drawn from a fixed, mutually-exclusive enumeration:
 *
 * > 对端 KEM 公钥不可得、套件协商无交集、本地 PQC 能力不可用、签名验证失败、
 * > 密钥确认失败、重放检测、身份指纹不匹配、套件签名不匹配、超时、网络不可达。
 *
 * The taxonomy is expressed at two layers:
 *
 * 1. [HandshakeFailureCategory] — the ten flat, mutually-exclusive category tags.
 *    This is the enum named in the design (`design.md` §4 Connection_Subsystem).
 * 2. [HandshakeFailure] — a sealed type with exactly one variant per category. Each
 *    variant carries category-specific diagnostic context (never influencing which
 *    category it belongs to) and exposes its single [HandshakeFailure.category].
 *
 * Wiring the concrete throw-sites in [P2PHandshakeClient]/[P2PHandshakeServer] to this
 * type is done by tasks 9.3/9.4/9.5; this file provides only the type and the pure
 * [HandshakeFailureClassifier].
 *
 * ### Relationship to [FallbackReason]
 * [FallbackReason] partitions failures by *fallback eligibility* (may this failure
 * authorize a PQC→Classic downgrade?). This taxonomy partitions failures by
 * *user-facing reason*. They overlap but are not the same axis: e.g.
 * [FallbackReason.SUITE_NEGOTIATION_FAILED] is fallback-eligible, whereas its
 * user-facing category [HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY] is simply
 * "no common suite". Both remain single sources of truth on their own axis.
 */
sealed class HandshakeFailure(
    /** The single, mutually-exclusive category this failure belongs to. */
    val category: HandshakeFailureCategory
) {
    /** Stable, machine-readable diagnostic code (mirrors [category]'s code). */
    val diagnosticCode: String get() = category.diagnosticCode

    /**
     * R4.11 — the peer's KEM public key is neither in the local pairing record nor
     * recoverable via the one-time classic bootstrap control channel within 10 s.
     */
    data class PeerKemPublicKeyUnavailable(
        val detail: String? = null
    ) : HandshakeFailure(HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE)

    /**
     * R4.3 — the two peers' declared suite sets have an empty intersection, so no
     * mutually-supported crypto suite exists.
     */
    data class SuiteIntersectionEmpty(
        val detail: String? = null
    ) : HandshakeFailure(HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY)

    /**
     * R4.12 — the local device has no usable PQC capability/provider (e.g. the
     * mandatory PQC rekey on a bootstrap control channel could not complete because
     * the local PQC provider is unavailable).
     */
    data class LocalPqcUnavailable(
        val detail: String? = null
    ) : HandshakeFailure(HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE)

    /** The peer's signature over the handshake transcript failed to verify. */
    data class SignatureVerificationFailed(
        val detail: String? = null
    ) : HandshakeFailure(HandshakeFailureCategory.SIGNATURE_VERIFICATION_FAILED)

    /** Key confirmation (the FINISHED MAC) did not match. */
    data class KeyConfirmationFailed(
        val detail: String? = null
    ) : HandshakeFailure(HandshakeFailureCategory.KEY_CONFIRMATION_FAILED)

    /** Replay / anti-rollback detection tripped during the handshake. */
    data class ReplayDetected(
        val detail: String? = null
    ) : HandshakeFailure(HandshakeFailureCategory.REPLAY_DETECTED)

    /**
     * R4.13 — the peer's identity fingerprint did not match the locally enrolled
     * fingerprint for this device. The handshake MUST abort immediately with no
     * auto-reconnect and no suite downgrade.
     */
    data class IdentityFingerprintMismatch(
        val detail: String? = null
    ) : HandshakeFailure(HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH)

    /** The signed suite list did not match the negotiated suite. */
    data class SuiteSignatureMismatch(
        val detail: String? = null
    ) : HandshakeFailure(HandshakeFailureCategory.SUITE_SIGNATURE_MISMATCH)

    /** A handshake phase exceeded its deadline. MUST NOT trigger a downgrade. */
    data class Timeout(
        val detail: String? = null
    ) : HandshakeFailure(HandshakeFailureCategory.TIMEOUT)

    /** The transport reported the peer as unreachable. MUST NOT trigger a downgrade. */
    data class NetworkUnreachable(
        val detail: String? = null
    ) : HandshakeFailure(HandshakeFailureCategory.NETWORK_UNREACHABLE)
}

/**
 * The ten mutually-exclusive handshake-failure categories from R4.4.
 *
 * The set is closed and disjoint: every classified handshake failure maps to exactly
 * one of these values, and no failure maps to two.
 */
enum class HandshakeFailureCategory(val diagnosticCode: String) {
    /** 对端 KEM 公钥不可得. */
    PEER_KEM_PUBLIC_KEY_UNAVAILABLE("peer_kem_public_key_unavailable"),

    /** 套件协商无交集. */
    SUITE_INTERSECTION_EMPTY("suite_intersection_empty"),

    /** 本地 PQC 能力不可用. */
    LOCAL_PQC_UNAVAILABLE("local_pqc_unavailable"),

    /** 签名验证失败. */
    SIGNATURE_VERIFICATION_FAILED("signature_verification_failed"),

    /** 密钥确认失败. */
    KEY_CONFIRMATION_FAILED("key_confirmation_failed"),

    /** 重放检测. */
    REPLAY_DETECTED("replay_detected"),

    /** 身份指纹不匹配. */
    IDENTITY_FINGERPRINT_MISMATCH("identity_fingerprint_mismatch"),

    /** 套件签名不匹配. */
    SUITE_SIGNATURE_MISMATCH("suite_signature_mismatch"),

    /** 超时. */
    TIMEOUT("timeout"),

    /** 网络不可达. */
    NETWORK_UNREACHABLE("network_unreachable")
}

/**
 * Typed exception raised at a handshake negotiation throw-site, carrying the single
 * mutually-exclusive [HandshakeFailure] classification (and thus its
 * [HandshakeFailureCategory]) that terminated the handshake.
 *
 * It extends [IllegalStateException] deliberately: the pre-existing no-match throw-sites
 * in [P2PHandshakeClient]/[P2PHandshakeServer] raised a raw `IllegalStateException`, and
 * callers (and the existing test-suite) catch/expect that type. Subclassing preserves
 * that contract byte-for-byte on the failure path while adding an explicit, machine-
 * readable classification — no existing behavior is weakened.
 *
 * Introduced by task 9.4 to make the empty-suite-intersection case explicitly
 * classified as [HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY] (R4.3 / R4.4).
 */
class HandshakeNegotiationException(
    /** The single, mutually-exclusive classification of this failure. */
    val failure: HandshakeFailure,
    message: String = failure.detailMessage()
) : IllegalStateException(message) {
    /** The mutually-exclusive category this failure belongs to. */
    val category: HandshakeFailureCategory get() = failure.category
}

private fun HandshakeFailure.detailMessage(): String {
    val detail = when (this) {
        is HandshakeFailure.PeerKemPublicKeyUnavailable -> detail
        is HandshakeFailure.SuiteIntersectionEmpty -> detail
        is HandshakeFailure.LocalPqcUnavailable -> detail
        is HandshakeFailure.SignatureVerificationFailed -> detail
        is HandshakeFailure.KeyConfirmationFailed -> detail
        is HandshakeFailure.ReplayDetected -> detail
        is HandshakeFailure.IdentityFingerprintMismatch -> detail
        is HandshakeFailure.SuiteSignatureMismatch -> detail
        is HandshakeFailure.Timeout -> detail
        is HandshakeFailure.NetworkUnreachable -> detail
    }
    return if (detail.isNullOrBlank()) diagnosticCode else "$diagnosticCode: $detail"
}

/**
 * A raw, observed handshake-failure condition, prior to classification.
 *
 * The condition space is deliberately *not* one-to-one with
 * [HandshakeFailureCategory]: [BootstrapRekeyFailed] models R4.12, where a failure of
 * the one-time classic bootstrap control channel's mandatory PQC rekey is not its own
 * category but is classified into either [HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE]
 * or [HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY] depending on the underlying
 * cause. This is what makes "every condition lands in exactly one category" a
 * non-trivial, testable property rather than an identity mapping.
 */
sealed interface HandshakeFailureCondition {
    /** The peer's KEM public key could not be obtained (R4.11). */
    data class PeerKemPublicKeyUnavailable(val detail: String? = null) : HandshakeFailureCondition

    /** The declared suite sets have an empty intersection (R4.3). */
    data class SuiteIntersectionEmpty(val detail: String? = null) : HandshakeFailureCondition

    /** No usable local PQC capability/provider (R4.12). */
    data class LocalPqcUnavailable(val detail: String? = null) : HandshakeFailureCondition

    /** Peer signature verification failed. */
    data class SignatureVerificationFailed(val detail: String? = null) : HandshakeFailureCondition

    /** Key confirmation (FINISHED MAC) failed. */
    data class KeyConfirmationFailed(val detail: String? = null) : HandshakeFailureCondition

    /** Replay / anti-rollback detection tripped. */
    data class ReplayDetected(val detail: String? = null) : HandshakeFailureCondition

    /** Peer identity fingerprint did not match the enrolled fingerprint (R4.13). */
    data class IdentityFingerprintMismatch(val detail: String? = null) : HandshakeFailureCondition

    /** The signed suite list did not match the negotiated suite. */
    data class SuiteSignatureMismatch(val detail: String? = null) : HandshakeFailureCondition

    /** A handshake phase exceeded its deadline. */
    data class Timeout(val detail: String? = null) : HandshakeFailureCondition

    /** The transport reported the peer as unreachable. */
    data class NetworkUnreachable(val detail: String? = null) : HandshakeFailureCondition

    /**
     * R4.12 — the bootstrap control channel was established but the mandatory PQC
     * rekey did not complete in time. Classified into exactly one of two categories
     * per [cause], never into a distinct "bootstrap" category.
     */
    data class BootstrapRekeyFailed(
        val cause: BootstrapRekeyCause,
        val detail: String? = null
    ) : HandshakeFailureCondition
}

/**
 * The underlying cause of a bootstrap-control-channel rekey failure, which selects
 * the R4.12 category the failure is classified into.
 */
enum class BootstrapRekeyCause {
    /** Local PQC provider/capability was unavailable → [HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE]. */
    LOCAL_PQC_UNAVAILABLE,

    /** No mutually-supported PQC suite for the rekey → [HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY]. */
    SUITE_INTERSECTION_EMPTY
}

/**
 * Pure classifier that maps an observed [HandshakeFailureCondition] to exactly one
 * [HandshakeFailure] (and thus exactly one [HandshakeFailureCategory]).
 *
 * The mapping is:
 * - **total**: every [HandshakeFailureCondition] is classified (the exhaustive `when`
 *   is compiler-checked), and
 * - **deterministic**: the same condition always yields the same single category.
 *
 * It has no side effects, performs no I/O, and does not consult any policy state, so
 * it is safe to call from any handshake throw-site.
 */
object HandshakeFailureClassifier {

    /** Classify [condition] into exactly one [HandshakeFailure]. */
    fun classify(condition: HandshakeFailureCondition): HandshakeFailure = when (condition) {
        is HandshakeFailureCondition.PeerKemPublicKeyUnavailable ->
            HandshakeFailure.PeerKemPublicKeyUnavailable(condition.detail)

        is HandshakeFailureCondition.SuiteIntersectionEmpty ->
            HandshakeFailure.SuiteIntersectionEmpty(condition.detail)

        is HandshakeFailureCondition.LocalPqcUnavailable ->
            HandshakeFailure.LocalPqcUnavailable(condition.detail)

        is HandshakeFailureCondition.SignatureVerificationFailed ->
            HandshakeFailure.SignatureVerificationFailed(condition.detail)

        is HandshakeFailureCondition.KeyConfirmationFailed ->
            HandshakeFailure.KeyConfirmationFailed(condition.detail)

        is HandshakeFailureCondition.ReplayDetected ->
            HandshakeFailure.ReplayDetected(condition.detail)

        is HandshakeFailureCondition.IdentityFingerprintMismatch ->
            HandshakeFailure.IdentityFingerprintMismatch(condition.detail)

        is HandshakeFailureCondition.SuiteSignatureMismatch ->
            HandshakeFailure.SuiteSignatureMismatch(condition.detail)

        is HandshakeFailureCondition.Timeout ->
            HandshakeFailure.Timeout(condition.detail)

        is HandshakeFailureCondition.NetworkUnreachable ->
            HandshakeFailure.NetworkUnreachable(condition.detail)

        // R4.12: bootstrap rekey failure is not its own category; it resolves into
        // exactly one of two categories based on the underlying cause.
        is HandshakeFailureCondition.BootstrapRekeyFailed -> when (condition.cause) {
            BootstrapRekeyCause.LOCAL_PQC_UNAVAILABLE ->
                HandshakeFailure.LocalPqcUnavailable(condition.detail)
            BootstrapRekeyCause.SUITE_INTERSECTION_EMPTY ->
                HandshakeFailure.SuiteIntersectionEmpty(condition.detail)
        }
    }
}
