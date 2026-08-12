package com.skybridge.compass.core.network

import com.skybridge.compass.shared.p2p.HandshakeFailureCategory
import com.skybridge.compass.shared.p2p.HandshakeFailureResponse
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.time.Duration

/**
 * 会话意外断开的原因（决定是否触发重连）。
 *
 * - [UNEXPECTED]：网络中断等意外断开，触发按 [ReconnectPolicy] 的退避重连（R4.7）。
 * - [INTENTIONAL]：用户主动断开等有意断开，不触发任何重连（与 R4.9 主动断开清理一致）。
 * - [TERMINAL]：安全终态失败（如身份指纹不匹配），立即中止且**不得**自动重连（R4.13）。
 */
enum class DisconnectCause {
    UNEXPECTED,
    INTENTIONAL,
    TERMINAL
}

/**
 * 重连三态，如实呈现给 UI（design §4 / R4.7）。所有状态均为叶节点状态，
 * 不改变任何屏幕结构（G2）。
 */
sealed interface ReconnectState {
    /** 尚未发生需要重连的断开。 */
    data object Idle : ReconnectState

    /**
     * 正在进行第 [attempt] 次重连（1 起），总上限为 [maxAttempts]。
     * UI 须在每次尝试开始后 1 秒内呈现该序号与总上限（R4.7）。
     */
    data class Reconnecting(val attempt: Int, val maxAttempts: Int) : ReconnectState

    /** 重连成功，会话已重新建立；状态在成功后被重置，可再次响应后续断开。 */
    data object Reconnected : ReconnectState

    /**
     * 达到重连次数上限仍未建立，已停止重连、会话保持未建立；
     * [failureCategory] 为最后一次尝试的失败原因分类（R4.7）。
     */
    data class GaveUp(val attempts: Int, val maxAttempts: Int, val failureCategory: String) :
        ReconnectState
}

/**
 * 单次重连尝试的结果。
 */
sealed interface ReconnectAttemptResult {
    /** 会话成功建立。 */
    data object Established : ReconnectAttemptResult

    /** 本次尝试失败，[failureCategory] 为失败原因分类。 */
    data class Failed(val failureCategory: String) : ReconnectAttemptResult
}

/**
 * 会话意外断开后的重连编排（R4.7、design §4）。
 *
 * 职责：
 * - 意外断开后按 [policy] 的退避序列发起至多 `maxAttempts` 次重连尝试；
 * - 每次尝试开始即把序号与总上限以 [ReconnectState.Reconnecting] 呈现；
 * - 成功则呈现 [ReconnectState.Reconnected] 并重置为可再次响应后续断开；
 * - 达上限仍未建立则呈现 [ReconnectState.GaveUp] 并停止；
 * - 主动/有意断开（[DisconnectCause.INTENTIONAL]）不触发任何重连。
 *
 * 退避与时钟均可注入（[sleep]）以便测试无需真实等待。
 */
class ReconnectCoordinator(
    private val policy: ReconnectPolicy,
    /** 发起一次连接尝试并返回结果；实现方负责单次建立超时（沿用 R4.1 的 30s，见 9.7）。 */
    private val attemptConnect: suspend (attempt: Int) -> ReconnectAttemptResult,
    /** 退避睡眠，默认 [delay]；测试可注入以跳过真实等待。 */
    private val sleep: suspend (Duration) -> Unit = { delay(it) }
) {

    private val _state = MutableStateFlow<ReconnectState>(ReconnectState.Idle)
    val state: StateFlow<ReconnectState> = _state.asStateFlow()

    /**
     * 处理一次会话断开。
     *
     * @return 若最终重连成功返回 true；有意断开或达上限仍未建立返回 false。
     */
    suspend fun onDisconnected(cause: DisconnectCause): Boolean {
        when (cause) {
            DisconnectCause.INTENTIONAL -> {
                // 主动断开：不重连，回到空闲。
                _state.value = ReconnectState.Idle
                return false
            }
            DisconnectCause.TERMINAL -> {
                // 安全终态失败（R4.13 指纹不匹配等）：立即停止，不发起任何重连尝试。
                _state.value = ReconnectState.GaveUp(
                    attempts = 0,
                    maxAttempts = policy.maxAttempts,
                    failureCategory = FAILURE_TERMINAL
                )
                return false
            }
            DisconnectCause.UNEXPECTED -> return reconnectLoop()
        }
    }

    /**
     * 处理一次**握手失败**并决定是否重连（R4.5 / R4.6 / R4.13）。
     *
     * 由 [HandshakeFailureResponse.permitsAutomaticReconnect] 单一裁决：
     * - 身份指纹不匹配及其余认证完整性/协商终态失败 → 视为 [DisconnectCause.TERMINAL]，
     *   自动重连尝试数恒为 0（R4.13 明确要求指纹不匹配不自动重连）；
     * - 仅超时、网络不可达等瞬时传输失败 → 走 [DisconnectCause.UNEXPECTED] 的退避重连（R4.7）。
     *
     * 该方法不触发任何套件降级、不切换未认证路径——这些由 [HandshakeFailureResponse] 恒定拒绝。
     *
     * @return 若最终重连成功返回 true；终态失败或达上限仍未建立返回 false。
     */
    suspend fun onHandshakeFailure(category: HandshakeFailureCategory): Boolean {
        val cause = if (HandshakeFailureResponse.permitsAutomaticReconnect(category)) {
            DisconnectCause.UNEXPECTED
        } else {
            DisconnectCause.TERMINAL
        }
        return onDisconnected(cause)
    }

    private suspend fun reconnectLoop(): Boolean {
        val max = policy.maxAttempts
        if (max <= 0) {
            _state.value = ReconnectState.GaveUp(
                attempts = 0,
                maxAttempts = max,
                failureCategory = FAILURE_RECONNECT_DISABLED
            )
            return false
        }

        var lastFailure = FAILURE_UNKNOWN
        for (attempt in 1..max) {
            // 退避：第 1 次尝试也遵循 delayFor(1)=~1s（意外断开后的首个退避）。
            sleep(policy.delayFor(attempt))
            // 尝试开始即呈现序号与总上限（R4.7）。
            _state.value = ReconnectState.Reconnecting(attempt = attempt, maxAttempts = max)
            when (val result = attemptConnect(attempt)) {
                is ReconnectAttemptResult.Established -> {
                    // 如实呈现重连成功；尝试计数随下次断开的新一轮循环自然重置。
                    _state.value = ReconnectState.Reconnected
                    return true
                }
                is ReconnectAttemptResult.Failed -> {
                    lastFailure = result.failureCategory
                }
            }
        }

        _state.value = ReconnectState.GaveUp(
            attempts = max,
            maxAttempts = max,
            failureCategory = lastFailure
        )
        return false
    }

    companion object {
        const val FAILURE_UNKNOWN = "UNKNOWN"
        const val FAILURE_RECONNECT_DISABLED = "RECONNECT_DISABLED"

        /** 安全终态失败（R4.13 指纹不匹配等）导致不重连时的失败分类标识。 */
        const val FAILURE_TERMINAL = "TERMINAL_NO_RECONNECT"
    }
}
