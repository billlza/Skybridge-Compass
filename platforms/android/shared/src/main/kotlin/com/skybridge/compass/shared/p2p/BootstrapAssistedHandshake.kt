package com.skybridge.compass.shared.p2p

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/**
 * Bootstrap-assisted KEM public-key acquisition state machine (task 9.2).
 *
 * This is the Android/Kotlin realization of acceptance criterion **R4.2** and the
 * `design.md` §4 Connection_Subsystem "bootstrap-assisted" flow. It resolves the
 * first-contact handshake deadlock (Gap G-D03): `resolveSuitePlan`
 * (`P2PHandshakeClient.kt`) requires a known peer KEM public key, but the Bonjour TXT
 * record does not carry one, so an unpaired Apple peer on the LAN would otherwise
 * always fall to "no compatible suite".
 *
 * ### What R4.2 mandates
 * > WHERE 降级策略为 STRICT_PQC_BOOTSTRAP_ASSISTED，WHEN 本地不持有对端 KEM 公钥且用户
 * > 选择连接该 Apple 设备，THE Connection_Subsystem SHALL 建立一次性经典控制通道，仅用于
 * > 获取对端 KEM 公钥，并在获取成功后 10 秒内发起强制 PQC 密钥更新；在该 PQC 密钥更新成功前，
 * > THE Connection_Subsystem SHALL 不在该通道上承载业务流量，且不呈现会话为已建立。
 *
 * Concretely, when — and only when — the local side has **no** peer KEM public key
 * **and** the downgrade posture is [DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED]:
 *
 * 1. establish a **one-time classic control channel** used *solely* to retrieve the
 *    peer's KEM public key (never to carry business/application traffic),
 * 2. on retrieval success, **initiate a mandatory PQC rekey within 10 s**, and
 * 3. keep the session **not established** and carrying **no business traffic** until
 *    that rekey succeeds.
 *
 * ### Wire-protocol constraint (G5 / WP-02)
 * The KEM public key is retrieved over the classic *control* channel; it is **not**
 * placed into the Bonjour TXT record. Putting KEM keys in TXT is a Wire_Protocol
 * change and is registered as pending Apple-side decision (see `gaps/wire-protocol-pending.md`,
 * task 7.10 / WP-02). This class therefore introduces no on-wire change.
 *
 * ### Task 9.3 refinements (R4.11 / R4.12)
 * On top of the task-9.2 happy path (retrieve → force rekey → establish) and its
 * FAILED transitions, task 9.3 adds:
 *  - **R4.11** — when the peer KEM public key is unobtainable (control channel open
 *    failed, retrieval failed or timed out within the acquisition deadline, or the
 *    bundle came back empty), the flow establishes **no** session, classifies the
 *    failure as [HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE], and
 *    surfaces an actionable [PairingHint] on the [BootstrapHandshakeException] so the
 *    UI can tell the user how to pair. No business traffic is ever carried over a
 *    classic suite.
 *  - **R4.12** — when the bootstrap control channel is established but the forced PQC
 *    rekey does not complete within 10 s (timeout) or fails, the flow terminates the
 *    channel (already closed before the rekey phase) **and wipes the key material
 *    derived during this attempt** (see [BootstrapDerivedKeyMaterial]), keeps the
 *    session unestablished, and classifies as
 *    [HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE] or
 *    [HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY] per the actual cause.
 * All failures remain classified through the task-9.1 [HandshakeFailure] taxonomy.
 */

/** A stable reference to the peer being bootstrapped. */
data class PeerRef(
    /** Stable peer identifier (device id / signaling id). Must be non-blank. */
    val peerId: String
) {
    init {
        require(peerId.isNotBlank()) { "peerId is required for bootstrap-assisted handshake" }
    }
}

/** Convenience alias for the shared peer-KEM-public-key bundle. */
typealias PeerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys

/** True iff at least one KEM public key is present in this bundle. */
internal fun PeerKemPublicKeys.hasAnyKemKey(): Boolean =
    qPeriaptPublicKey != null || xWingPublicKey != null || mlKem768PublicKey != null

/**
 * A zeroizing holder for the secret key material derived during a single bootstrap
 * attempt (task 9.3, acceptance criterion **R4.12**).
 *
 * > IF 第 2 条的一次性经典控制通道已建立但强制 PQC 密钥更新在 10 秒内未成功完成，THEN
 * > THE Connection_Subsystem SHALL 终止该通道、**清除该通道派生的全部密钥材料**、保持
 * > 会话为未建立状态 …
 *
 * The classic bootstrap control channel derives ephemeral secret material (a channel
 * secret, plus any intermediate secrets produced while forcing the PQC rekey). If the
 * attempt fails — most importantly if the forced PQC rekey does not complete within the
 * deadline — that material must not be left resident in memory. This holder gathers all
 * such secrets for the attempt and [wipe]s them in place.
 *
 * [wipe] is **idempotent**: it zeroizes every registered secret exactly once and then
 * marks the holder wiped; subsequent calls are no-ops. This lets every terminal failure
 * path call [wipe] defensively while the "wipe happens exactly once per attempt"
 * guarantee still holds (see [wipeCount]).
 */
class BootstrapDerivedKeyMaterial {
    private val secrets = mutableListOf<ByteArray>()

    /** Number of times this attempt's material was actually zeroized (0 or 1). */
    @Volatile
    var wipeCount: Int = 0
        private set

    /** True once the derived material has been zeroized. */
    val isWiped: Boolean get() = wipeCount > 0

    /**
     * Register a secret derived during this attempt so it will be zeroized by [wipe].
     * A defensive copy is **not** taken: the same underlying array is zeroized, so
     * callers that hold a reference will observe it cleared. Empty arrays are ignored.
     */
    fun register(secret: ByteArray?) {
        if (secret == null || secret.isEmpty()) return
        synchronized(secrets) {
            if (!isWiped) secrets += secret
        }
    }

    /**
     * Zeroize all registered secrets in place, exactly once. Safe to call from any
     * (including multiple) terminal path.
     */
    fun wipe() {
        synchronized(secrets) {
            if (isWiped) return
            for (secret in secrets) secret.fill(0)
            secrets.clear()
            wipeCount = 1
        }
    }
}

/**
 * The one-time classic *control* channel used **only** to retrieve the peer's KEM
 * public key.
 *
 * The interface is deliberately **narrow**: it exposes *no* send/business-traffic
 * method, so it is *structurally impossible* for a caller to carry application
 * payloads over it. This enforces the R4.2 invariant "引导通道仅用于获取对端 KEM 公钥"
 * at the type level rather than relying on discipline.
 */
interface BootstrapControlChannel {
    /**
     * Retrieve the peer's KEM public key(s) over the classic control channel.
     * This is the *only* data operation the bootstrap channel supports.
     */
    suspend fun retrievePeerKemPublicKeys(): PeerKemPublicKeys

    /**
     * The secret key material this channel derived for the current attempt (e.g. the
     * classic channel secret). Returned so the state machine can register it for
     * zeroization on a failed attempt (R4.12). Returns `null` when the channel derives
     * no reclaimable secret (the default). Implementations that hold ephemeral secrets
     * SHOULD return the *live* arrays so wiping clears the resident copy.
     */
    fun derivedKeyMaterial(): ByteArray? = null

    /** Tear the one-time control channel down. Called exactly once. */
    suspend fun close()
}

/** Outcome of the mandatory PQC rekey forced after KEM retrieval. */
sealed interface PqcRekeyResult {
    /** The forced PQC rekey completed successfully; the session may now be established. */
    data object Success : PqcRekeyResult

    /**
     * The forced PQC rekey failed. [cause] selects the R4.12 failure category via the
     * task-9.1 classifier. Detailed R4.12 handling (channel teardown, key-material
     * wipe) is task 9.3.
     */
    data class Failed(
        val cause: BootstrapRekeyCause,
        val detail: String? = null
    ) : PqcRekeyResult
}

/**
 * The observable lifecycle states of the bootstrap-assisted handshake.
 *
 * The session is presented as **established** — and may carry **business traffic** —
 * in exactly one state: [ESTABLISHED]. Every other state (including
 * [KEM_RETRIEVED] and [REKEYING_PQC]) is *pre-establishment*: no business traffic, no
 * "session established" presentation. This is the R4.2 gate.
 */
enum class BootstrapHandshakeState {
    /** Nothing started yet. */
    IDLE,

    /** Verifying that bootstrap applies (policy + no local KEM key). */
    CHECKING_PRECONDITIONS,

    /** Opening the one-time classic control channel. */
    OPENING_CONTROL_CHANNEL,

    /** Control channel open; retrieving the peer KEM public key (KEM-only). */
    RETRIEVING_KEM,

    /** Peer KEM public key retrieved; control channel torn down. NOT established. */
    KEM_RETRIEVED,

    /** Mandatory PQC rekey in progress. NOT established; no business traffic. */
    REKEYING_PQC,

    /** Forced PQC rekey succeeded. The one and only established/business-capable state. */
    ESTABLISHED,

    /** A failure occurred; carries a classified [HandshakeFailure]. NOT established. */
    FAILED
}

/**
 * Raised when the bootstrap-assisted handshake fails, carrying the classified failure.
 *
 * When the failure is "peer KEM public key unobtainable" (R4.11), [pairingHint] carries
 * the actionable, UI-renderable hint telling the user how to pair. It is `null` for
 * every other failure category (those are not remediable by pairing).
 */
class BootstrapHandshakeException(
    val failure: HandshakeFailure,
    /** Actionable pairing hint; non-null only for R4.11 (KEM key unobtainable). */
    val pairingHint: PairingHint? = null
) : Exception("bootstrap-assisted handshake failed: ${failure.diagnosticCode}")

/**
 * Bootstrap-assisted KEM public-key acquisition — the R4.2 flow.
 *
 * @return on success, the retrieved [PeerKemPublicKeys] (after the forced PQC rekey
 *   has completed and the session is [BootstrapHandshakeState.ESTABLISHED]); on
 *   failure, a [Result.failure] wrapping a [BootstrapHandshakeException] with a
 *   task-9.1 [HandshakeFailure] classification.
 */
interface BootstrapAssistedHandshake {
    /** Current observable state. */
    val state: BootstrapHandshakeState

    /**
     * True iff the session may be presented to the user as "established". Per R4.2,
     * this is `false` until the forced PQC rekey has succeeded.
     */
    val isSessionEstablished: Boolean

    /**
     * True iff the session may carry business/application traffic. Per R4.2, this is
     * `false` until the forced PQC rekey has succeeded.
     */
    val canCarryBusinessTraffic: Boolean

    /**
     * Establish a one-time classic control channel to retrieve [peer]'s KEM public
     * key, then force a PQC rekey within 10 s. See the class docs for the full R4.2
     * contract.
     */
    suspend fun bootstrapPeerKemKeys(peer: PeerRef): Result<PeerKemPublicKeys>
}

/**
 * Default, transport-agnostic implementation of the R4.2 bootstrap-assisted flow.
 *
 * All I/O is injected so the state machine is pure and fully testable without a real
 * network transport:
 *  - [policy] — the downgrade posture; bootstrap applies only under
 *    [DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED].
 *  - [localPeerKemLookup] — the local pairing record; bootstrap applies only when it
 *    yields no KEM key for the peer.
 *  - [openControlChannel] — opens the one-time classic control channel.
 *  - [forcePqcRekey] — performs the mandatory PQC rekey with the retrieved KEM key.
 *  - [clock] — millisecond clock for the 10 s rekey-completion deadline.
 *  - [onStateChange] — optional observer of state transitions (used by tests to prove
 *    the session is never presented as established before rekey).
 */
class DefaultBootstrapAssistedHandshake(
    private val policy: DowngradePolicy,
    private val localPeerKemLookup: (PeerRef) -> PeerKemPublicKeys?,
    private val openControlChannel: suspend (PeerRef) -> BootstrapControlChannel,
    private val forcePqcRekey: suspend (PeerRef, PeerKemPublicKeys) -> PqcRekeyResult,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val rekeyDeadlineMillis: Long = FORCED_REKEY_DEADLINE_MILLIS,
    private val kemAcquisitionDeadlineMillis: Long = KEM_ACQUISITION_DEADLINE_MILLIS,
    private val onStateChange: (BootstrapHandshakeState) -> Unit = {},
    /**
     * Invoked exactly once per attempt when this attempt's derived key material is
     * zeroized (R4.12). Used by tests to prove the wipe happened on the failure path
     * (and happened exactly once). Never invoked on the success path, where the
     * derived channel secret is superseded by the established PQC session and no
     * separate wipe is required.
     */
    private val onKeyMaterialWiped: () -> Unit = {}
) : BootstrapAssistedHandshake {

    @Volatile
    override var state: BootstrapHandshakeState = BootstrapHandshakeState.IDLE
        private set

    override val isSessionEstablished: Boolean
        get() = state == BootstrapHandshakeState.ESTABLISHED

    override val canCarryBusinessTraffic: Boolean
        get() = state == BootstrapHandshakeState.ESTABLISHED

    private fun transitionTo(next: BootstrapHandshakeState) {
        state = next
        onStateChange(next)
    }

    /**
     * Transition to [BootstrapHandshakeState.FAILED] and return a classified failure.
     *
     * If [material] is supplied, its derived key material is zeroized *before*
     * surfacing the failure (R4.12): terminating the attempt must never leave secret
     * material resident. The wipe is idempotent, and the [onKeyMaterialWiped] observer
     * fires exactly once for the attempt.
     *
     * [pairingHint] is attached only for the R4.11 "KEM key unobtainable" path.
     */
    private fun fail(
        failure: HandshakeFailure,
        material: BootstrapDerivedKeyMaterial? = null,
        pairingHint: PairingHint? = null
    ): Result<PeerKemPublicKeys> {
        if (material != null) {
            val wasWiped = material.isWiped
            material.wipe()
            if (!wasWiped && material.isWiped) onKeyMaterialWiped()
        }
        transitionTo(BootstrapHandshakeState.FAILED)
        return Result.failure(BootstrapHandshakeException(failure, pairingHint))
    }

    /** R4.11 helper: classify as "peer KEM public key unobtainable" + actionable hint. */
    private fun failKemUnavailable(
        detail: String,
        material: BootstrapDerivedKeyMaterial? = null
    ): Result<PeerKemPublicKeys> = fail(
        failure = HandshakeFailureClassifier.classify(
            HandshakeFailureCondition.PeerKemPublicKeyUnavailable(detail = detail)
        ),
        material = material,
        pairingHint = PairingHint.peerKemPublicKeyUnavailable()
    )

    override suspend fun bootstrapPeerKemKeys(peer: PeerRef): Result<PeerKemPublicKeys> {
        // 1. Preconditions: bootstrap applies only under the bootstrap-assisted posture
        //    and only when the local side has no peer KEM key.
        transitionTo(BootstrapHandshakeState.CHECKING_PRECONDITIONS)

        if (!policy.allowsBootstrapControlChannel()) {
            // Not the bootstrap-assisted posture: this flow must not open a classic
            // control channel. The peer KEM key is unobtainable via this flow → R4.11:
            // reject the session and surface an actionable pairing hint.
            return failKemUnavailable(
                detail = "bootstrap control channel not permitted by policy=$policy"
            )
        }

        val existingLocalKeys = localPeerKemLookup(peer)
        if (existingLocalKeys != null && existingLocalKeys.hasAnyKemKey()) {
            // Already have the peer KEM key locally: no bootstrap needed. The regular
            // PQC handshake path can proceed; report success without opening a classic
            // control channel.
            transitionTo(BootstrapHandshakeState.ESTABLISHED)
            return Result.success(existingLocalKeys)
        }

        // Holder for every secret this attempt derives, so we can zeroize it in place
        // on any terminal failure path (R4.12). The wipe is idempotent.
        val attemptMaterial = BootstrapDerivedKeyMaterial()

        // 2. Open the one-time classic control channel (KEM retrieval only).
        transitionTo(BootstrapHandshakeState.OPENING_CONTROL_CHANNEL)
        val channel = try {
            openControlChannel(peer)
        } catch (t: Throwable) {
            // Control channel could not be opened → peer KEM key unobtainable (R4.11):
            // no session, actionable pairing hint. Nothing was derived yet.
            return failKemUnavailable(
                detail = "bootstrap control channel open failed: ${t.message}",
                material = attemptMaterial
            )
        }

        // 3. Retrieve the peer KEM public key within the acquisition deadline, then tear
        //    the channel down. The channel is closed in all paths so it can never linger
        //    to carry business traffic. Register the channel-derived secret so it is
        //    wiped if the attempt fails.
        val retrievedKeys: PeerKemPublicKeys = try {
            transitionTo(BootstrapHandshakeState.RETRIEVING_KEM)
            attemptMaterial.register(channel.derivedKeyMaterial())
            withTimeout(kemAcquisitionDeadlineMillis) {
                channel.retrievePeerKemPublicKeys()
            }
        } catch (_: TimeoutCancellationException) {
            // R4.11: KEM public key not obtained within the deadline → no session,
            // actionable pairing hint, wipe any derived material.
            return failKemUnavailable(
                detail = "peer KEM not obtained within ${kemAcquisitionDeadlineMillis}ms",
                material = attemptMaterial
            )
        } catch (t: Throwable) {
            return failKemUnavailable(
                detail = "peer KEM retrieval failed: ${t.message}",
                material = attemptMaterial
            )
        } finally {
            // The one-time control channel exists only for KEM retrieval; close it
            // immediately, before any rekey/business phase.
            runCatching { channel.close() }
        }

        if (!retrievedKeys.hasAnyKemKey()) {
            // Empty bundle → peer KEM key unobtainable (R4.11).
            return failKemUnavailable(
                detail = "bootstrap channel returned no KEM public key",
                material = attemptMaterial
            )
        }

        transitionTo(BootstrapHandshakeState.KEM_RETRIEVED)

        // 4. Initiate the mandatory PQC rekey within 10 s of retrieval, and require it
        //    to complete within the deadline. Until it succeeds we remain
        //    pre-establishment (no business traffic, not "established").
        transitionTo(BootstrapHandshakeState.REKEYING_PQC)
        val rekeyResult: PqcRekeyResult = try {
            withTimeout(rekeyDeadlineMillis) {
                forcePqcRekey(peer, retrievedKeys)
            }
        } catch (_: TimeoutCancellationException) {
            // R4.12: bootstrap channel was up but the forced PQC rekey did not complete
            // within 10 s. The one-time control channel is already terminated (closed in
            // the finally above); now wipe the derived key material and keep the session
            // unestablished, classified as LOCAL_PQC_UNAVAILABLE.
            return fail(
                failure = HandshakeFailureClassifier.classify(
                    HandshakeFailureCondition.BootstrapRekeyFailed(
                        cause = BootstrapRekeyCause.LOCAL_PQC_UNAVAILABLE,
                        detail = "forced PQC rekey did not complete within ${rekeyDeadlineMillis}ms"
                    )
                ),
                material = attemptMaterial
            )
        } catch (t: Throwable) {
            return fail(
                failure = HandshakeFailureClassifier.classify(
                    HandshakeFailureCondition.BootstrapRekeyFailed(
                        cause = BootstrapRekeyCause.LOCAL_PQC_UNAVAILABLE,
                        detail = "forced PQC rekey threw: ${t.message}"
                    )
                ),
                material = attemptMaterial
            )
        }

        return when (rekeyResult) {
            is PqcRekeyResult.Success -> {
                // 5. Only now may the session be presented as established / carry traffic.
                //    The ephemeral bootstrap channel secret is superseded by the
                //    established PQC session; no separate failure-path wipe applies here.
                transitionTo(BootstrapHandshakeState.ESTABLISHED)
                Result.success(retrievedKeys)
            }

            // R4.12: rekey failed within the deadline → terminate (channel already
            // closed), wipe derived key material, classify per the underlying cause.
            is PqcRekeyResult.Failed -> fail(
                failure = HandshakeFailureClassifier.classify(
                    HandshakeFailureCondition.BootstrapRekeyFailed(
                        cause = rekeyResult.cause,
                        detail = rekeyResult.detail
                    )
                ),
                material = attemptMaterial
            )
        }
    }

    companion object {
        /** R4.2 / R4.12 forced-PQC-rekey completion deadline: 10 seconds. */
        const val FORCED_REKEY_DEADLINE_MILLIS: Long = 10_000L

        /** R4.11 peer-KEM-public-key acquisition deadline over the bootstrap channel: 10 seconds. */
        const val KEM_ACQUISITION_DEADLINE_MILLIS: Long = 10_000L
    }
}
