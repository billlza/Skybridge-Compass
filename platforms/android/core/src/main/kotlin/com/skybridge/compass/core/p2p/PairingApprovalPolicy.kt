package com.skybridge.compass.core.p2p

/**
 * 一次配对批准判定的输入快照（design §7、R7.5）。
 *
 * 只包含判定所需的事实，且在一次判定内不可变，因此 [PairingApprovalPolicy.decide] 是纯函数：
 * 相同输入永远得到相同输出，不读取任何持久化状态、时钟或全局变量。
 *
 * @param isKnownDevice 该设备是否**已配对/已知**（已存在受信任记录或已固定公钥）。
 *   仅此字段为 `true` 时才存在免交互批准的可能。
 * @param hasTrustConflict 是否检测到信任冲突（身份冲突、隔离、吊销、信任库损坏等）。
 */
data class PairingRequest(
    val peerId: String,
    val declaredDeviceId: String,
    val isKnownDevice: Boolean,
    val hasTrustConflict: Boolean = false
)

/** 配对批准判定结果（R7.5 的两种终态）。 */
enum class PairingDecision {
    /** 免交互批准：不弹出任何提示，直接建立信任。 */
    APPROVE_WITHOUT_INTERACTION,

    /** 进入等待用户显式批准态：由既有 `SecurityPromptStore` 提示流程决定最终结果。 */
    AWAIT_EXPLICIT_USER_APPROVAL
}

interface PairingApprovalPolicy {
    /** autoTrustKnownDevices = true 时已配对设备免交互批准，false 时进入等待显式批准态。 */
    fun decide(request: PairingRequest, autoTrustKnownDevices: Boolean): PairingDecision
}

/**
 * [PairingApprovalPolicy] 的唯一生产实现：把 `auto_trust_known_devices` 变成真实运行时行为。
 *
 * 判定表（R7.5）：
 *
 * | autoTrustKnownDevices | isKnownDevice | 结果 |
 * |---|---|---|
 * | true  | true  | [PairingDecision.APPROVE_WITHOUT_INTERACTION] |
 * | true  | false | [PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL] |
 * | false | true  | [PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL] |
 * | false | false | [PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL] |
 *
 * **安全边界**：开关只为**已配对**设备去掉交互，绝不为未知设备降低门槛。未知设备的拒绝写成
 * 函数首个前置守卫（而非控制流的副产物），且整个函数只有一处返回
 * [PairingDecision.APPROVE_WITHOUT_INTERACTION]，该返回点被守卫支配，因此
 * `isKnownDevice == false` 在结构上不可能到达免交互批准。
 */
object AutoTrustPairingApprovalPolicy : PairingApprovalPolicy {

    override fun decide(request: PairingRequest, autoTrustKnownDevices: Boolean): PairingDecision {
        // 守卫 1（安全边界，不可失效开放）：未知/未配对设备永不免交互批准，与开关取值无关。
        if (!request.isKnownDevice) return PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL

        // 守卫 2：存在信任冲突的设备即使已知也必须由用户显式处置。
        if (request.hasTrustConflict) return PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL

        // 守卫 3：开关关闭时，已配对设备也进入等待显式批准态。
        if (!autoTrustKnownDevices) return PairingDecision.AWAIT_EXPLICIT_USER_APPROVAL

        // 唯一的免交互批准返回点：被上面三个守卫支配。
        return PairingDecision.APPROVE_WITHOUT_INTERACTION
    }
}
