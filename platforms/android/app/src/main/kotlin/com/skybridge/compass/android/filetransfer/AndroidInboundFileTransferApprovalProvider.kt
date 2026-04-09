package com.skybridge.compass.android.filetransfer

import android.content.Context
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.notifications.SecurityPromptNotifier
import com.skybridge.compass.android.securityprompts.SecurityPromptStore
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.filetransfer.webrtc.InboundFileTransferApprovalProvider
import com.skybridge.compass.filetransfer.webrtc.InboundFileTransferApprovalRequest
import com.skybridge.compass.filetransfer.webrtc.InboundFileTransferDecision
import kotlinx.coroutines.flow.first

class AndroidInboundFileTransferApprovalProvider(
    private val appContext: Context
) : InboundFileTransferApprovalProvider {
    override suspend fun requestDecision(request: InboundFileTransferApprovalRequest): InboundFileTransferDecision {
        val settings = SecuritySettingsStore.observe(appContext).first()

        // If file transfer is disabled, hard-decline with no UI.
        if (!settings.allowFileTransfer) return InboundFileTransferDecision.Decline

        val senderId = request.senderDeviceId?.trim()?.takeIf { it.isNotBlank() }
        val trusted = senderId?.let { isTrustedPeer(it) } ?: false

        // Auto-accept only for trusted devices when enabled.
        if (settings.autoAcceptTrustedDevices && trusted) {
            return InboundFileTransferDecision.Accept(
                downloadsDisplayName = sanitizeDownloadsDisplayName(request.fileName ?: "skybridge-received"),
                overwriteExisting = false
            )
        }

        val prompt = SecurityPromptStore.InboundFileTransferPrompt(
            transferId = request.transferId,
            fileName = request.fileName ?: "skybridge-received",
            mimeType = request.mimeType,
            fileSizeBytes = request.fileSizeBytes,
            senderDeviceId = request.senderDeviceId,
            senderDeviceName = request.senderDeviceName
        )

        val deferred = SecurityPromptStore.requestInboundDecision(prompt)
        SecurityPromptNotifier.postInboundFilePrompt(appContext, prompt)

        return when (val decision = deferred.await()) {
            is SecurityPromptStore.InboundFileTransferDecision.Accept -> {
                InboundFileTransferDecision.Accept(
                    downloadsDisplayName = decision.downloadsDisplayName,
                    overwriteExisting = decision.overwriteExisting
                )
            }

            SecurityPromptStore.InboundFileTransferDecision.Decline -> InboundFileTransferDecision.Decline
        }
    }

    private fun isTrustedPeer(peerId: String): Boolean {
        return runCatching {
            val fp = LocalP2PIdentity(appContext).trustStore().loadPeerSigningFingerprint(peerId)
            !fp.isNullOrBlank()
        }.getOrDefault(false)
    }

    private fun sanitizeDownloadsDisplayName(raw: String): String {
        val cleaned = raw
            .replace('/', '_')
            .replace('\\', '_')
            .trim()
        return cleaned.ifBlank { "skybridge-received" }
    }
}

