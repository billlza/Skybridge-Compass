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

        val timeoutMs = pairingDecisionTimeoutMs(settings.pairingTimeoutSec)
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

/**
 * `pairing_timeout_sec` 的运行时消费判定（R7.2）。
 *
 * 持久化的秒值决定配对提示在无人操作时多久自动判为 [PairingTrustDecision.DECLINE]——即
 * 传给 [SecurityPromptStore.requestPairingDecision] 的 `timeoutMs`。若不传，该函数的调用方会
 * 落到 `SecurityPromptStore.PAIRING_DECISION_TIMEOUT_MS` 的 60s 硬编码默认值，
 * 持久化值就不会改变任何行为。
 *
 * 取值范围与 `SecuritySettingsStore` 的写入/读取钳制一致（5..600 秒），越界值兜底钳制。
 */
internal fun pairingDecisionTimeoutMs(pairingTimeoutSec: Int): Long =
    pairingTimeoutSec.coerceIn(
        PAIRING_TIMEOUT_SEC_MIN,
        PAIRING_TIMEOUT_SEC_MAX
    ) * 1000L

/** 与 `SecuritySettingsStore.setPairingTimeoutSec` 的钳制下界一致。 */
internal const val PAIRING_TIMEOUT_SEC_MIN = 5

/** 与 `SecuritySettingsStore.setPairingTimeoutSec` 的钳制上界一致。 */
internal const val PAIRING_TIMEOUT_SEC_MAX = 600
