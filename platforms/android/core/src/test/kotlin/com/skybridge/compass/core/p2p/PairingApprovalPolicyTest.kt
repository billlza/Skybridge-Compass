package com.skybridge.compass.core.p2p

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * R7.5 判定表与安全边界。[AutoTrustPairingApprovalPolicy.decide] 是纯函数，直接逐项验证。
 */
class PairingApprovalPolicyTest {

    private fun request(isKnownDevice: Boolean, hasTrustConflict: Boolean = false) = PairingRequest(
        peerId = "peer-a",
        declaredDeviceId = "device-a",
        isKnownDevice = isKnownDevice,
        hasTrustConflict = hasTrustConflict
    )

    @Test
    fun autoTrustOnAndDeviceKnown_approvesWithoutInteraction() {
        assertEquals(
            PairingDecision.APPROVE_WITHOUT_INTERACTION,
            AutoTrustPairingApprovalPolicy.decide(
                request = request(isKnownDevice = true),
                autoTrustKnownDevices = true
            )
        )
    }

    @Test
    fun autoTrustOnAndDeviceUnknown_awaitsExplicitApproval() {
        assertEquals(
            PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL,
            AutoTrustPairingApprovalPolicy.decide(
                request = request(isKnownDevice = false),
                autoTrustKnownDevices = true
            )
        )
    }

    @Test
    fun autoTrustOffAndDeviceKnown_awaitsExplicitApproval() {
        assertEquals(
            PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL,
            AutoTrustPairingApprovalPolicy.decide(
                request = request(isKnownDevice = true),
                autoTrustKnownDevices = false
            )
        )
    }

    @Test
    fun autoTrustOffAndDeviceUnknown_awaitsExplicitApproval() {
        assertEquals(
            PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL,
            AutoTrustPairingApprovalPolicy.decide(
                request = request(isKnownDevice = false),
                autoTrustKnownDevices = false
            )
        )
    }

    /** 安全边界：未知设备在开关任意取值下都不得免交互批准。 */
    @Test
    fun unknownDeviceIsNeverAutoApproved() {
        listOf(true, false).forEach { flag ->
            listOf(true, false).forEach { conflict ->
                assertEquals(
                    "unknown device must never be auto-approved (flag=$flag, conflict=$conflict)",
                    PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL,
                    AutoTrustPairingApprovalPolicy.decide(
                        request = request(isKnownDevice = false, hasTrustConflict = conflict),
                        autoTrustKnownDevices = flag
                    )
                )
            }
        }
    }

    /** 已知设备但存在信任冲突时也必须由用户显式处置。 */
    @Test
    fun knownDeviceWithTrustConflictAwaitsExplicitApproval() {
        assertEquals(
            PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL,
            AutoTrustPairingApprovalPolicy.decide(
                request = request(isKnownDevice = true, hasTrustConflict = true),
                autoTrustKnownDevices = true
            )
        )
    }

    /** 纯函数：相同输入重复调用得到相同结果，不受调用次数/顺序影响。 */
    @Test
    fun decideIsPureForRepeatedCalls() {
        val req = request(isKnownDevice = true)
        val first = AutoTrustPairingApprovalPolicy.decide(req, autoTrustKnownDevices = true)
        AutoTrustPairingApprovalPolicy.decide(request(isKnownDevice = false), autoTrustKnownDevices = false)
        val second = AutoTrustPairingApprovalPolicy.decide(req, autoTrustKnownDevices = true)
        assertEquals(first, second)
    }
}
