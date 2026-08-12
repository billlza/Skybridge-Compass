package com.skybridge.compass.remotecontrol.admission

import com.skybridge.compass.core.utils.Logger
import com.skybridge.compass.remotecontrol.secure.RemoteControlSecureEnvelope.PacketType

/**
 * Why an inbound remote input event was refused execution (R6.8).
 *
 * Every value maps 1:1 onto a clause of the acceptance criteria so the recorded audit event carries a
 * discriminable reason rather than a free-form string.
 */
enum class RemoteInputRejectionReason {
    /** Injection is not running, or the local stop entry was triggered (R6.7 hard gate). */
    INJECTION_STOPPED,

    /** The event arrived from a peer that is not the authorized/trusted peer (R6.7). */
    PEER_NOT_AUTHORIZED,

    /** The session signature/envelope authentication for this event failed (R6.8). */
    SIGNATURE_INVALID,

    /**
     * The counter is not strictly greater than the highest counter already accepted for this
     * session lane — i.e. a replayed or reordered event (R6.8).
     */
    COUNTER_NOT_MONOTONIC,

    /** The counter runs further ahead of the highest accepted counter than the acceptance window (R6.8). */
    COUNTER_OUTSIDE_WINDOW,
}

/**
 * Outcome of the admission decision for a single inbound remote input event.
 */
sealed interface Admission {
    /** The event may be injected. [counter] becomes the new highest accepted counter for the lane. */
    data class Accept(val counter: Long) : Admission

    /** The event must be dropped without touching device input state, and audited. */
    data class Reject(val reason: RemoteInputRejectionReason) : Admission
}

/**
 * A single audit record emitted for every rejected inbound input event (R6.8).
 *
 * @param reason discriminable rejection cause.
 * @param counter the envelope counter carried by the refused event.
 * @param highestAcceptedCounter the lane's highest accepted counter at decision time.
 * @param peerId identifier of the peer the event arrived from.
 * @param packetType the envelope packet type lane the event belongs to.
 */
data class RemoteInputAuditEvent(
    val reason: RemoteInputRejectionReason,
    val counter: Long,
    val highestAcceptedCounter: Long,
    val peerId: String,
    val packetType: PacketType,
)

/**
 * Sink for input-admission audit events. Kept as a seam so the decision path stays testable without
 * a logging framework or Android runtime.
 */
fun interface RemoteInputAuditSink {
    fun record(event: RemoteInputAuditEvent)
}

/** Default sink: routes audit events onto the existing remote-control log tag. */
object LoggingRemoteInputAuditSink : RemoteInputAuditSink {
    override fun record(event: RemoteInputAuditEvent) {
        Logger.remoteControl(
            "remote input rejected reason=${event.reason} counter=${event.counter} " +
                "highestAccepted=${event.highestAcceptedCounter} peer=${event.peerId} " +
                "packetType=${event.packetType.raw}"
        )
    }
}

/**
 * Admission seam in front of remote input injection.
 *
 * Reuses the existing secure-envelope counter to enforce a strictly-monotonic sequence plus a
 * 256-event acceptance window, and records an audit event on every rejection (R6.8).
 *
 * The [peerId] and [signatureValid] parameters are explicit rather than implied by an ambient session:
 * R6.7 gates on the *authorized peer* and R6.8 gates on *session signature validity*, so both must be
 * part of the decision input for the gate to be able to reject on them.
 */
interface RemoteInputAdmission {
    fun admit(
        envelopeCounter: Long,
        packetType: PacketType,
        peerId: String,
        signatureValid: Boolean,
    ): Admission
}

/**
 * Admission gate in front of remote input injection (R6.7/R6.8).
 *
 * Reuses the *existing* SBRC secure-envelope counter that every remote-control frame already carries
 * (`RemoteControlSecureEnvelope.ParsedHeader.counter`) — no new wire field is introduced. The gate
 * only reads that counter, so it is wire-compatible with the Apple peer by construction.
 *
 * Admission requires all of:
 *  1. injection is active and the local stop entry has not been triggered;
 *  2. the event came from the currently authorized peer;
 *  3. the event's session signature verified (the caller passes the envelope-open result);
 *  4. the counter is **strictly greater** than the highest counter already accepted for the lane;
 *  5. the counter is **within 256 events** of that highest accepted counter.
 *
 * ### Window boundary (documented, and asserted in tests)
 * With `highest` the highest accepted counter and `delta = counter - highest`, the gate accepts
 * `1 <= delta <= 256` and rejects `delta <= 0` (non-monotonic) and `delta > 256` (outside window).
 * The boundary is therefore **inclusive at +256** and exclusive at +257, mirroring the sliding-window
 * distance test used by `RemoteControlSecureEnvelope.ReplayWindow` (`distance >= WINDOW_SIZE` fails).
 *
 * Lanes are kept per (peer, packetType) exactly like the envelope's replay scoping, so a CONTROL and a
 * SCREEN lane do not starve each other.
 *
 * Thread-safety: all mutating entry points are synchronized, and [stopAllInjection] flips the hard
 * gate synchronously so a local stop takes effect on the calling thread before it returns (R6.8's
 * companion requirement R6.7: all injection stops within 1 second of the trigger).
 */
class RemoteInputAdmissionGate(
    private val auditSink: RemoteInputAuditSink = LoggingRemoteInputAuditSink,
    private val acceptanceWindow: Long = ACCEPTANCE_WINDOW,
) : RemoteInputAdmission {

    private val lock = Any()

    /** Highest accepted counter per (peerId, packetType) lane. */
    private val highestAccepted = HashMap<Pair<String, PacketType>, Long>()

    private var authorizedPeerId: String? = null
    private var injectionActive: Boolean = false
    private var stopped: Boolean = false

    /**
     * Counter a lane starts from. Injection is often enabled *mid-session*, when the envelope counter
     * has already advanced well past 0; seeding the baseline with the counter observed at authorization
     * time keeps the very first admitted event inside the acceptance window instead of permanently
     * out-of-window (which would deadlock the lane).
     */
    private var baselineCounter: Long = 0L

    /** True while injection may run — the observable state of the hard gate. */
    val isInjectionAllowed: Boolean
        get() = synchronized(lock) { injectionActive && !stopped }

    /** The peer whose input is currently allowed to execute, if any. */
    val currentAuthorizedPeer: String?
        get() = synchronized(lock) { authorizedPeerId }

    /**
     * Open the gate for [peerId] after the user explicitly enabled injection for that authorized peer.
     * Clears any previous stop latch and resets the counter lanes for a fresh session.
     *
     * @param baselineCounter the envelope counter already observed on the session at the moment
     *   injection was authorized. Admission then requires the next event to land in
     *   `(baselineCounter, baselineCounter + 256]`. Defaults to 0 for a session starting from scratch.
     */
    fun startInjection(peerId: String, baselineCounter: Long = 0L) {
        synchronized(lock) {
            authorizedPeerId = peerId
            injectionActive = true
            stopped = false
            highestAccepted.clear()
            this.baselineCounter = baselineCounter.coerceAtLeast(0L)
        }
        Logger.remoteControl(
            "remote input admission opened for peer=$peerId baselineCounter=$baselineCounter"
        )
    }

    /**
     * Local stop entry (R6.7): closes the hard gate **synchronously** so every subsequent event is
     * dropped immediately, with no queue to drain. Idempotent.
     */
    fun stopAllInjection() {
        synchronized(lock) {
            injectionActive = false
            stopped = true
            authorizedPeerId = null
            highestAccepted.clear()
            baselineCounter = 0L
        }
        Logger.remoteControl("remote input admission closed by local stop entry")
    }

    /**
     * Decide whether an inbound input event may be injected, recording exactly one audit event on
     * every rejection.
     *
     * @param envelopeCounter the counter from the already-existing secure envelope header.
     * @param packetType the envelope packet type lane.
     * @param peerId the peer the event arrived from.
     * @param signatureValid whether envelope/session authentication succeeded for this event.
     */
    override fun admit(
        envelopeCounter: Long,
        packetType: PacketType,
        peerId: String,
        signatureValid: Boolean,
    ): Admission {
        val (admission, highestAtDecision) = synchronized(lock) {
            val lane = peerId to packetType
            val highest = highestAccepted[lane] ?: baselineCounter
            val decision = decide(
                highestAcceptedCounter = highest,
                incomingCounter = envelopeCounter,
                acceptanceWindow = acceptanceWindow,
                injectionAllowed = injectionActive && !stopped,
                peerAuthorized = authorizedPeerId != null && authorizedPeerId == peerId,
                signatureValid = signatureValid,
            )
            if (decision is Admission.Accept) {
                highestAccepted[lane] = decision.counter
            }
            decision to highest
        }

        if (admission is Admission.Reject) {
            auditSink.record(
                RemoteInputAuditEvent(
                    reason = admission.reason,
                    counter = envelopeCounter,
                    highestAcceptedCounter = highestAtDecision,
                    peerId = peerId,
                    packetType = packetType,
                )
            )
        }
        return admission
    }

    companion object {
        /** 256-event acceptance window mandated by R6.8. */
        const val ACCEPTANCE_WINDOW: Long = 256L

        /**
         * The pure admission decision: no state, no I/O, exhaustively unit-testable.
         *
         * Checks run in a fixed precedence so exactly one reason is reported per rejection:
         * stop gate → peer authorization → signature → monotonicity → acceptance window.
         */
        fun decide(
            highestAcceptedCounter: Long,
            incomingCounter: Long,
            acceptanceWindow: Long = ACCEPTANCE_WINDOW,
            injectionAllowed: Boolean,
            peerAuthorized: Boolean,
            signatureValid: Boolean,
        ): Admission = when {
            !injectionAllowed -> Admission.Reject(RemoteInputRejectionReason.INJECTION_STOPPED)
            !peerAuthorized -> Admission.Reject(RemoteInputRejectionReason.PEER_NOT_AUTHORIZED)
            !signatureValid -> Admission.Reject(RemoteInputRejectionReason.SIGNATURE_INVALID)
            incomingCounter <= highestAcceptedCounter ->
                Admission.Reject(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC)
            incomingCounter - highestAcceptedCounter > acceptanceWindow ->
                Admission.Reject(RemoteInputRejectionReason.COUNTER_OUTSIDE_WINDOW)
            else -> Admission.Accept(incomingCounter)
        }
    }
}
