package com.skybridge.compass.filetransfer.webrtc.resume

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Compile-ready skeleton for a resumable transfer state machine.
 *
 * This will be incrementally wired into UI/notifications later; for now, WebRtcFileTransferController
 * can emit coarse progress while this models transitions more explicitly.
 */
class ResumableTransferStateMachine(
    initial: TransferState = TransferState.Idle
) {
    sealed class TransferState {
        data object Idle : TransferState()

        data class Sending(val transferId: String) : TransferState()
        data class WaitingForAcks(val transferId: String) : TransferState()
        data class Completed(val transferId: String) : TransferState()

        data class Receiving(val transferId: String) : TransferState()
        data class WaitingForMissingChunks(val transferId: String, val missingCount: Int) : TransferState()

        data class Failed(val transferId: String?, val reason: String) : TransferState()
        data class Cancelled(val transferId: String) : TransferState()
    }

    private val _state = MutableStateFlow(initial)
    val state: StateFlow<TransferState> = _state.asStateFlow()

    fun transition(next: TransferState) {
        _state.value = next
    }
}


