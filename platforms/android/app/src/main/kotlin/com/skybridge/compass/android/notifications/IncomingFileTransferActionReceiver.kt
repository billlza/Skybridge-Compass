package com.skybridge.compass.android.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.skybridge.compass.android.securityprompts.SecurityPromptStore
import com.skybridge.compass.core.p2p.PairingTrustDecision

class IncomingFileTransferActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            SecurityPromptNotifier.ACTION_INBOUND_FILE_DECLINE -> {
                val transferId = intent.getStringExtra(SecurityPromptNotifier.EXTRA_TRANSFER_ID) ?: return
                SecurityPromptStore.resolveInbound(transferId, SecurityPromptStore.InboundFileTransferDecision.Decline)
                SecurityPromptNotifier.cancelInboundFilePrompt(context, transferId)
            }
            SecurityPromptNotifier.ACTION_PAIRING_TRUST_DECLINE -> {
                val requestId = intent.getStringExtra(SecurityPromptNotifier.EXTRA_PAIRING_REQUEST_ID) ?: return
                SecurityPromptStore.resolvePairing(requestId, PairingTrustDecision.DECLINE)
                SecurityPromptNotifier.cancelPairingTrustPrompt(context, requestId)
            }
        }
    }
}
