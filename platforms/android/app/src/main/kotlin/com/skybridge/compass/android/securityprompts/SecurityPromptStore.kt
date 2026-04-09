package com.skybridge.compass.android.securityprompts

import com.skybridge.compass.core.p2p.PairingTrustDecision
import com.skybridge.compass.core.p2p.PairingTrustRequest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap

/**
 * In-memory security prompt store for:
 * - inbound file transfer confirmation (Review/Decline -> in-app Accept/Decline)
 *
 * Note: these prompts only need to live while the app process is running.
 */
object SecurityPromptStore {
    const val INBOUND_DECISION_TIMEOUT_MS: Long = 60_000L
    const val PAIRING_DECISION_TIMEOUT_MS: Long = 60_000L

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
    private val inboundById = ConcurrentHashMap<String, InboundEntry>()
    private val pairingById = ConcurrentHashMap<String, PairingEntry>()

    private val _inboundPrompts = MutableStateFlow<Map<String, InboundFileTransferPrompt>>(emptyMap())
    val inboundPrompts: StateFlow<Map<String, InboundFileTransferPrompt>> = _inboundPrompts.asStateFlow()
    private val _pairingPrompts = MutableStateFlow<Map<String, PairingTrustRequest>>(emptyMap())
    val pairingPrompts: StateFlow<Map<String, PairingTrustRequest>> = _pairingPrompts.asStateFlow()

    fun getInboundPrompt(transferId: String): InboundFileTransferPrompt? =
        inboundById[transferId]?.prompt

    fun getPairingPrompt(requestId: String): PairingTrustRequest? =
        pairingById[requestId]?.prompt

    fun requestInboundDecision(
        prompt: InboundFileTransferPrompt,
        timeoutMs: Long = INBOUND_DECISION_TIMEOUT_MS
    ): CompletableDeferred<InboundFileTransferDecision> {
        val existing = inboundById[prompt.transferId]
        if (existing != null) return existing.decision

        val deferred = CompletableDeferred<InboundFileTransferDecision>()
        val timeoutJob = scope.launch {
            delay(timeoutMs)
            resolveInbound(prompt.transferId, InboundFileTransferDecision.Decline)
        }
        inboundById[prompt.transferId] = InboundEntry(prompt = prompt, decision = deferred, timeoutJob = timeoutJob)
        _inboundPrompts.value = inboundById.mapValues { it.value.prompt }
        return deferred
    }

    fun resolveInbound(transferId: String, decision: InboundFileTransferDecision) {
        val entry = inboundById.remove(transferId) ?: return
        entry.timeoutJob.cancel()
        entry.decision.complete(decision)
        _inboundPrompts.value = inboundById.mapValues { it.value.prompt }
    }

    fun requestPairingDecision(
        prompt: PairingTrustRequest,
        timeoutMs: Long = PAIRING_DECISION_TIMEOUT_MS
    ): CompletableDeferred<PairingTrustDecision> {
        val existing = pairingById[prompt.requestId]
        if (existing != null) return existing.decision

        val deferred = CompletableDeferred<PairingTrustDecision>()
        val timeoutJob = scope.launch {
            delay(timeoutMs)
            resolvePairing(prompt.requestId, PairingTrustDecision.DECLINE)
        }
        pairingById[prompt.requestId] = PairingEntry(prompt = prompt, decision = deferred, timeoutJob = timeoutJob)
        _pairingPrompts.value = pairingById.mapValues { it.value.prompt }
        return deferred
    }

    fun resolvePairing(requestId: String, decision: PairingTrustDecision) {
        val entry = pairingById.remove(requestId) ?: return
        entry.timeoutJob.cancel()
        entry.decision.complete(decision)
        _pairingPrompts.value = pairingById.mapValues { it.value.prompt }
    }
}
