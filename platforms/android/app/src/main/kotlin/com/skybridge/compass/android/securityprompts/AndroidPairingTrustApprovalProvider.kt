package com.skybridge.compass.android.securityprompts

import android.content.Context
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.notifications.SecurityPromptNotifier
import com.skybridge.compass.core.p2p.PairingTrustApprovalProvider
import com.skybridge.compass.core.p2p.PairingTrustDecision
import com.skybridge.compass.core.p2p.PairingTrustRequest
import kotlinx.coroutines.flow.first

class AndroidPairingTrustApprovalProvider(
    private val appContext: Context
) : PairingTrustApprovalProvider {
    override suspend fun requestDecision(request: PairingTrustRequest): PairingTrustDecision {
        val settings = SecuritySettingsStore.observe(appContext).first()
        if (request.conflict == null && !settings.requirePairing) {
            return PairingTrustDecision.TRUST_ALWAYS
        }

        val timeoutMs = settings.pairingTimeoutSec.coerceIn(5, 600) * 1000L
        val deferred = SecurityPromptStore.requestPairingDecision(
            prompt = request,
            timeoutMs = timeoutMs
        )
        SecurityPromptNotifier.postPairingTrustPrompt(appContext, request)
        return try {
            deferred.await()
        } finally {
            SecurityPromptNotifier.cancelPairingTrustPrompt(appContext, request.requestId)
        }
    }
}
