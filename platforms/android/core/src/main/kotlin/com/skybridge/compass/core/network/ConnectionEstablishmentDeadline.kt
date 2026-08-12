package com.skybridge.compass.core.network

import com.skybridge.compass.shared.p2p.HandshakeFailureCategory
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * 单次连接建立的整体时限与会话建立呈现门（R4.1、design §4，任务 9.7）。
 *
 * design §4 规定的分段时限：
 * - 控制通道连接 ≤ 5s；
 * - ICE 候选收集 ≤ 10s；
 * - P2P 握手 ≤ 15s；
 * - **从用户选择到会话状态呈现为已建立的端到端整体时限 ≤ 30s**。
 *
 * 本组件承担两件事，二者均为纯逻辑、可注入时钟、可单元测试，且不改变任何屏幕结构（G2）：
 *
 * 1. **整体时限判定**：一次连接建立自 [start] 起，若在 [overallDeadline]（默认 30s）内
 *    未把会话呈现为已建立，则如实以「超时」失败——失败原因分类恒为
 *    [HandshakeFailureCategory.TIMEOUT]（R4.4 的十项互斥枚举之一），经既有 signaling-status
 *    叶节点呈现路径如实呈现，不隐瞒、不改分类。
 *
 * 2. **会话建立呈现门（R4.2 不变式）**：仅当**应用层会话密钥已建立**（P2P 握手 / PQC 密钥更新
 *    完成、`sessionKeys != null`）时，才允许把会话呈现为「已连接 / 已建立」；在此之前一律不得
 *    呈现为已建立——[canPresentEstablished] 是该不变式的唯一判定函数。
 *
 * 时钟通过 [now] 注入，测试无需真实等待即可推进到时限边界。
 */
class ConnectionEstablishmentDeadline(
    /** 整体建立时限，默认 30s（design §4 的端到端上限）。 */
    val overallDeadline: Duration = DEFAULT_OVERALL_DEADLINE,
    /** 单调时钟毫秒；默认 [System.nanoTime] 派生，测试可注入以确定化。 */
    private val now: () -> Long = { System.nanoTime() / 1_000_000L }
) {
    init {
        require(overallDeadline.isPositive()) {
            "overallDeadline must be positive, was $overallDeadline"
        }
    }

    @Volatile
    private var startedAtMs: Long? = null

    /** 记录一次连接建立的起点（用户选择设备的时刻）。重复调用以最新起点为准。 */
    fun start() {
        startedAtMs = now()
    }

    /** 清除起点，使 [hasExpired] 恒为 false，用于会话成功建立或被清理后停用时限。 */
    fun clear() {
        startedAtMs = null
    }

    /** 是否已启动整体时限计时。 */
    fun isArmed(): Boolean = startedAtMs != null

    /** 自起点起已流逝时长；未启动时为 [Duration.ZERO]。 */
    fun elapsed(): Duration {
        val started = startedAtMs ?: return Duration.ZERO
        return (now() - started).coerceAtLeast(0L).milliseconds
    }

    /** 距整体时限到期的剩余时长，钳制到不小于 0；未启动时为 [overallDeadline]。 */
    fun remaining(): Duration {
        val started = startedAtMs ?: return overallDeadline
        val elapsedMs = (now() - started).coerceAtLeast(0L)
        val remainingMs = overallDeadline.inWholeMilliseconds - elapsedMs
        return remainingMs.coerceAtLeast(0L).milliseconds
    }

    /**
     * 整体时限是否已到期。已启动且流逝时长 ≥ [overallDeadline] 时为 true。
     * 未启动（未 [start] 或已 [clear]）时恒为 false。
     */
    fun hasExpired(): Boolean {
        val started = startedAtMs ?: return false
        return (now() - started) >= overallDeadline.inWholeMilliseconds
    }

    /**
     * 会话建立呈现门（R4.2 不变式）：仅当应用层会话密钥已建立时才允许呈现为「已建立」。
     *
     * @param appLayerSessionKeysEstablished 应用层会话密钥是否已建立（`sessionKeys != null`）。
     *   在经典引导通道尚未完成强制 PQC 密钥更新前、或握手尚未派生会话密钥前，该值为 false。
     * @return true 当且仅当会话密钥已建立，此时方可把会话呈现为已连接 / 已建立。
     */
    fun canPresentEstablished(appLayerSessionKeysEstablished: Boolean): Boolean =
        appLayerSessionKeysEstablished

    /**
     * 在整体时限到期时，评估本次建立的终态。
     *
     * @param appLayerSessionKeysEstablished 到期时刻应用层会话密钥是否已建立。
     * @return [Outcome.Established] 当会话密钥已建立（时限内已如实呈现为已建立）；
     *   否则 [Outcome.TimedOut]（携带恒定的 [HandshakeFailureCategory.TIMEOUT] 分类，供如实呈现）。
     */
    fun evaluateOnDeadline(appLayerSessionKeysEstablished: Boolean): Outcome =
        if (canPresentEstablished(appLayerSessionKeysEstablished)) {
            Outcome.Established
        } else {
            Outcome.TimedOut(HandshakeFailureCategory.TIMEOUT)
        }

    /** 一次连接建立在整体时限点上的终态。 */
    sealed interface Outcome {
        /** 会话密钥已建立，已如实呈现为已建立。 */
        data object Established : Outcome

        /**
         * 整体时限到期仍未把会话呈现为已建立；[category] 恒为
         * [HandshakeFailureCategory.TIMEOUT]，作为如实呈现给用户的失败原因分类。
         */
        data class TimedOut(val category: HandshakeFailureCategory) : Outcome
    }

    companion object {
        /** design §4：控制通道连接上限 5s。 */
        val CONTROL_CHANNEL_DEADLINE: Duration = 5.seconds

        /** design §4：ICE 候选收集上限 10s。 */
        val ICE_GATHERING_DEADLINE: Duration = 10.seconds

        /** design §4：P2P 握手上限 15s。 */
        val HANDSHAKE_DEADLINE: Duration = 15.seconds

        /** design §4：从用户选择到会话呈现为已建立的端到端整体时限上限 30s。 */
        val DEFAULT_OVERALL_DEADLINE: Duration = 30.seconds

        /** 超时失败对外呈现的原因分类诊断码（如实呈现，不改分类）。 */
        val TIMEOUT_DIAGNOSTIC_CODE: String = HandshakeFailureCategory.TIMEOUT.diagnosticCode
    }
}
