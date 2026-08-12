package com.skybridge.compass.filetransfer.webrtc

/**
 * App-provided approval flow for inbound file transfers.
 *
 * The file-transfer module cannot depend on the app module, so the app must
 * provide an implementation that can surface UI/notifications and return a decision.
 */
data class InboundFileTransferApprovalRequest(
    val transferId: String,
    val fileName: String?,
    val mimeType: String?,
    val fileSizeBytes: Long?,
    val authenticatedSenderDeviceId: String?,
    val senderDeviceId: String?,
    val senderDeviceName: String?
)

sealed interface InboundFileTransferDecision {
    data class Accept(
        val downloadsDisplayName: String,
        val overwriteExisting: Boolean
    ) : InboundFileTransferDecision

    data object Decline : InboundFileTransferDecision
}

fun interface InboundFileTransferApprovalProvider {
    suspend fun requestDecision(request: InboundFileTransferApprovalRequest): InboundFileTransferDecision
}
