package com.skybridge.compass.android.securityprompts

import com.skybridge.compass.core.p2p.PairingTrustDecision
import com.skybridge.compass.core.p2p.PairingTrustRequest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal class SecurityPromptIdentityConflictException(
    promptKind: String,
    promptId: String
) : IllegalStateException(
    "A different $promptKind security prompt is already registered for id '$promptId'"
)

internal class SecurityPromptCapacityExceededException(
    promptKind: String,
    admissionKey: String
) : IllegalStateException(
    "Too many pending $promptKind security prompts for admission key '$admissionKey'"
)

/**
 * In-memory security prompt store for:
 * - inbound file transfer confirmation (Review/Decline -> in-app Accept/Decline)
 *
 * Note: these prompts only need to live while the app process is running.
 */
object SecurityPromptStore {
    const val INBOUND_DECISION_TIMEOUT_MS: Long = 60_000L
    const val PAIRING_DECISION_TIMEOUT_MS: Long = 60_000L
    internal const val MAX_PENDING_INBOUND_PROMPTS = 32
    internal const val MAX_PENDING_INBOUND_PROMPTS_PER_SENDER = 4
    internal const val MAX_PENDING_PAIRING_PROMPTS = 16
    internal const val MAX_PENDING_PAIRING_PROMPTS_PER_PEER = 2

    data class InboundFileTransferPrompt(
        val transferId: String,
        val fileName: String,
        val mimeType: String? = null,
        val fileSizeBytes: Long? = null,
        val senderDeviceId: String? = null,
        val senderDeviceName: String? = null,
        val createdAtMs: Long = System.currentTimeMillis()
    )

    sealed interface InboundFileTransferDecision {
        data class Accept(
            val downloadsDisplayName: String,
            val overwriteExisting: Boolean
        ) : InboundFileTransferDecision

        data object Decline : InboundFileTransferDecision
    }

    private data class InboundEntry(
        val prompt: InboundFileTransferPrompt,
        val decision: CompletableDeferred<InboundFileTransferDecision>,
        val timeoutJob: Job
    )

    private data class PairingEntry(
        val prompt: PairingTrustRequest,
        val decision: CompletableDeferred<PairingTrustDecision>,
        val timeoutJob: Job
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val inboundLock = Any()
    private val pairingLock = Any()
    private val inboundById = LinkedHashMap<String, InboundEntry>()
    private val pairingById = LinkedHashMap<String, PairingEntry>()

    private val _inboundPrompts = MutableStateFlow<Map<String, InboundFileTransferPrompt>>(emptyMap())
    val inboundPrompts: StateFlow<Map<String, InboundFileTransferPrompt>> = _inboundPrompts.asStateFlow()
    private val _pairingPrompts = MutableStateFlow<Map<String, PairingTrustRequest>>(emptyMap())
    val pairingPrompts: StateFlow<Map<String, PairingTrustRequest>> = _pairingPrompts.asStateFlow()

    fun getInboundPrompt(transferId: String): InboundFileTransferPrompt? = synchronized(inboundLock) {
        inboundById[transferId]?.prompt
    }

    fun getPairingPrompt(requestId: String): PairingTrustRequest? = synchronized(pairingLock) {
        pairingById[requestId]?.prompt
    }

    fun requestInboundDecision(
        prompt: InboundFileTransferPrompt,
        timeoutMs: Long = INBOUND_DECISION_TIMEOUT_MS
    ): CompletableDeferred<InboundFileTransferDecision> {
        require(timeoutMs > 0) { "Inbound security prompt timeout must be positive" }

        synchronized(inboundLock) {
            val existing = inboundById[prompt.transferId]
            if (existing != null) {
                if (!existing.prompt.isSameRequestAs(prompt)) {
                    throw SecurityPromptIdentityConflictException("inbound file-transfer", prompt.transferId)
                }
                return existing.decision
            }
            val admissionKey = prompt.senderAdmissionKey()
            if (
                inboundById.size >= MAX_PENDING_INBOUND_PROMPTS ||
                inboundById.values.count { it.prompt.senderAdmissionKey() == admissionKey } >=
                MAX_PENDING_INBOUND_PROMPTS_PER_SENDER
            ) {
                throw SecurityPromptCapacityExceededException("inbound file-transfer", admissionKey)
            }

            val deferred = CompletableDeferred<InboundFileTransferDecision>()
            val timeoutJob = scope.launch(start = CoroutineStart.LAZY) {
                delay(timeoutMs)
                resolveInbound(prompt.transferId, InboundFileTransferDecision.Decline)
            }
            inboundById[prompt.transferId] = InboundEntry(
                prompt = prompt,
                decision = deferred,
                timeoutJob = timeoutJob
            )
            publishInboundSnapshotLocked()
            timeoutJob.start()
            return deferred
        }
    }

    fun resolveInbound(transferId: String, decision: InboundFileTransferDecision) {
        val entry = synchronized(inboundLock) {
            inboundById.remove(transferId)?.also { publishInboundSnapshotLocked() }
        } ?: return
        entry.timeoutJob.cancel()
        entry.decision.complete(decision)
    }

    fun requestPairingDecision(
        prompt: PairingTrustRequest,
        timeoutMs: Long = PAIRING_DECISION_TIMEOUT_MS
    ): CompletableDeferred<PairingTrustDecision> {
        require(timeoutMs > 0) { "Pairing security prompt timeout must be positive" }

        synchronized(pairingLock) {
            val existing = pairingById[prompt.requestId]
            if (existing != null) {
                if (existing.prompt != prompt) {
                    throw SecurityPromptIdentityConflictException("pairing", prompt.requestId)
                }
                return existing.decision
            }
            val admissionKey = prompt.peerId.trim().ifEmpty { UNKNOWN_ADMISSION_KEY }
            if (
                pairingById.size >= MAX_PENDING_PAIRING_PROMPTS ||
                pairingById.values.count {
                    it.prompt.peerId.trim().ifEmpty { UNKNOWN_ADMISSION_KEY } == admissionKey
                } >= MAX_PENDING_PAIRING_PROMPTS_PER_PEER
            ) {
                throw SecurityPromptCapacityExceededException("pairing", admissionKey)
            }

            val deferred = CompletableDeferred<PairingTrustDecision>()
            val timeoutJob = scope.launch(start = CoroutineStart.LAZY) {
                delay(timeoutMs)
                resolvePairing(prompt.requestId, PairingTrustDecision.DECLINE)
            }
            pairingById[prompt.requestId] = PairingEntry(
                prompt = prompt,
                decision = deferred,
                timeoutJob = timeoutJob
            )
            publishPairingSnapshotLocked()
            timeoutJob.start()
            return deferred
        }
    }

    fun resolvePairing(requestId: String, decision: PairingTrustDecision) {
        val entry = synchronized(pairingLock) {
            pairingById.remove(requestId)?.also { publishPairingSnapshotLocked() }
        } ?: return
        entry.timeoutJob.cancel()
        entry.decision.complete(decision)
    }

    private fun publishInboundSnapshotLocked() {
        _inboundPrompts.value = inboundById.mapValuesTo(LinkedHashMap()) { it.value.prompt }
    }

    private fun publishPairingSnapshotLocked() {
        _pairingPrompts.value = pairingById.mapValuesTo(LinkedHashMap()) { it.value.prompt }
    }

    private fun InboundFileTransferPrompt.isSameRequestAs(other: InboundFileTransferPrompt): Boolean =
        transferId == other.transferId &&
            fileName == other.fileName &&
            mimeType == other.mimeType &&
            fileSizeBytes == other.fileSizeBytes &&
            senderDeviceId == other.senderDeviceId &&
            senderDeviceName == other.senderDeviceName

    private fun InboundFileTransferPrompt.senderAdmissionKey(): String =
        senderDeviceId?.trim()?.takeIf { it.isNotEmpty() } ?: UNKNOWN_ADMISSION_KEY

    private const val UNKNOWN_ADMISSION_KEY = "unknown-peer"
}
