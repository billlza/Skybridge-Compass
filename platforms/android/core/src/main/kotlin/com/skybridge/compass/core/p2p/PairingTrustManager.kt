package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.data.RuntimePairingApprovalParametersSource
import java.util.UUID

enum class PairingTrustConflict {
    IDENTITY_CONFLICT,
    DEVICE_ID_MIGRATION_REQUIRED,
    QUARANTINED_IDENTITY,
    REVOKED_IDENTITY,
    TRUST_STORE_CORRUPTED
}

data class PairingTrustRequest(
    val requestId: String = UUID.randomUUID().toString(),
    val peerId: String,
    val declaredDeviceId: String,
    val deviceName: String? = null,
    val platform: String? = null,
    val modelName: String? = null,
    val osVersion: String? = null,
    val chip: String? = null,
    val protocolPublicKeyFingerprint: String? = null,
    val conflict: PairingTrustConflict? = null
)

enum class PairingTrustDecision {
    TRUST_ALWAYS,
    ALLOW_ONCE,
    DECLINE
}

fun interface PairingTrustApprovalProvider {
    suspend fun requestDecision(request: PairingTrustRequest): PairingTrustDecision
}

object PairingTrustManager {
    @Volatile
    var approvalProvider: PairingTrustApprovalProvider? = null

    /**
     * `auto_trust_known_devices` 的运行时读取面（R7.5）。由 app 模块在进程启动时注册。
     *
     * 未注册时按**关闭**处理（与 `SecuritySettingsStore` 默认值一致），即一律等待用户显式批准，
     * 属失败关闭而非失败开放。
     */
    @Volatile
    var approvalParametersSource: RuntimePairingApprovalParametersSource? = null

    /** 判定策略。默认 [AutoTrustPairingApprovalPolicy]，仅测试可替换。 */
    @Volatile
    var approvalPolicy: PairingApprovalPolicy = AutoTrustPairingApprovalPolicy

    suspend fun requestDecision(request: PairingTrustRequest): PairingTrustDecision {
        val provider = approvalProvider
        if (provider == null) return PairingTrustDecision.DECLINE
        return provider.requestDecision(request)
    }

    /**
     * 已知/未知设备的统一批准入口：先按 [approvalPolicy] 判定是否可免交互批准，
     * 否则进入等待用户显式批准态（复用既有 [approvalProvider] 提示流程）。
     *
     * 每次调用都通过 [RuntimePairingApprovalParametersSource.current] 重新读取开关，
     * 因此设置改动对**下一个**配对请求生效；已在等待批准的请求不受影响——它的判定早已完成，
     * 其结果只能由用户操作或超时决定。
     */
    suspend fun requestDecision(
        request: PairingTrustRequest,
        isKnownDevice: Boolean
    ): PairingTrustDecision {
        val autoTrustKnownDevices = approvalParametersSource?.current()?.autoTrustKnownDevices ?: false
        val policyDecision = approvalPolicy.decide(
            request = PairingRequest(
                peerId = request.peerId,
                declaredDeviceId = request.declaredDeviceId,
                isKnownDevice = isKnownDevice,
                hasTrustConflict = request.conflict != null
            ),
            autoTrustKnownDevices = autoTrustKnownDevices
        )
        return when (policyDecision) {
            PairingDecision.APPROVE_WITHOUT_INTERACTION -> PairingTrustDecision.TRUST_ALWAYS
            PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL -> requestDecision(request)
        }
    }
}
