package com.skybridge.compass.core.network

import com.skybridge.compass.core.data.RuntimeNetworkParameters
import com.skybridge.compass.core.data.RuntimeNetworkParametersSource
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * 会话意外断开后的重连退避策略（R4.7、design §4）。
 *
 * - [maxAttempts] 取自单一读取面 [RuntimeNetworkParameters.maxReconnectAttempts]
 *   （其背后是 `NetworkSettingsStore` 的持久化值），取值范围 0..10，默认 3（与 R7.4 同一来源）。
 * - [delayFor] 给出第 `attempt` 次尝试（1 起）的退避间隔：基准为
 *   `min(2^(attempt-1) 秒, 30 秒)`（即 1s/2s/4s/8s… 指数退避、30s 上限），
 *   附加不超过基准 20% 的抖动。
 */
interface ReconnectPolicy {
    val maxAttempts: Int

    fun delayFor(attempt: Int): Duration
}

/**
 * 默认退避实现。抖动来源可注入（[jitterFraction]），以便测试确定化——
 * 默认使用 [kotlin.random.Random] 产生 `[0, 0.2]` 区间的抖动比例。
 */
class DefaultReconnectPolicy(
    override val maxAttempts: Int,
    private val jitterFraction: () -> Double = { kotlin.random.Random.nextDouble(0.0, MAX_JITTER_FRACTION) }
) : ReconnectPolicy {

    init {
        require(maxAttempts in MIN_ATTEMPTS..MAX_ATTEMPTS) {
            "maxAttempts must be within $MIN_ATTEMPTS..$MAX_ATTEMPTS, was $maxAttempts"
        }
    }

    override fun delayFor(attempt: Int): Duration {
        require(attempt >= 1) { "attempt must be >= 1, was $attempt" }
        val base = baseDelaySecondsFor(attempt)
        val fraction = jitterFraction().coerceIn(0.0, MAX_JITTER_FRACTION)
        val jittered = base * (1.0 + fraction)
        return jittered.seconds
    }

    private fun baseDelaySecondsFor(attempt: Int): Double {
        // 2^(attempt-1)：attempt=1→1s, 2→2s, 3→4s, 4→8s, …；封顶 30s。
        // 大指数下先钳制指数上限，避免 Double 溢出。
        val exponent = (attempt - 1).coerceAtMost(CAP_EXPONENT)
        val raw = Math.pow(2.0, exponent.toDouble())
        return raw.coerceAtMost(CAP_SECONDS)
    }

    companion object {
        const val MIN_ATTEMPTS = 0
        const val MAX_ATTEMPTS = 10
        const val CAP_SECONDS = 30.0
        const val MAX_JITTER_FRACTION = 0.20

        /** 2^6 = 64s 已超过 30s 上限，超过该指数一律封顶，无需再幂运算。 */
        private const val CAP_EXPONENT = 6

        /**
         * 从 [RuntimeNetworkParameters.maxReconnectAttempts] 构造策略（R4.7 / R7.4 同一来源）。
         * 越界值钳制到 0..10 兜底。
         */
        fun fromMaxReconnectAttempts(
            maxReconnectAttempts: Int,
            jitterFraction: () -> Double = { kotlin.random.Random.nextDouble(0.0, MAX_JITTER_FRACTION) }
        ): DefaultReconnectPolicy =
            DefaultReconnectPolicy(
                maxAttempts = maxReconnectAttempts.coerceIn(MIN_ATTEMPTS, MAX_ATTEMPTS),
                jitterFraction = jitterFraction
            )

        /**
         * 从单一读取面 [RuntimeNetworkParameters] 构造策略。运行时消费方应走这条路径，
         * 不要自行读取持久化字段。
         */
        fun from(
            parameters: RuntimeNetworkParameters,
            jitterFraction: () -> Double = { kotlin.random.Random.nextDouble(0.0, MAX_JITTER_FRACTION) }
        ): DefaultReconnectPolicy =
            fromMaxReconnectAttempts(
                maxReconnectAttempts = parameters.maxReconnectAttempts,
                jitterFraction = jitterFraction
            )
    }
}

/**
 * 为**每一次新会话**构造一个 [ReconnectPolicy]（R7.4）。
 *
 * 每次 [forNewSession] 都重新经 [RuntimeNetworkParametersSource] 取值，所以设置改动后新建立的会话
 * 按新的 `maxAttempts` 运行；已经在重连中的会话仍持有它建立时拿到的策略实例，不受影响。
 */
@Singleton
class RuntimeReconnectPolicyFactory @Inject constructor(
    private val runtimeParameters: RuntimeNetworkParametersSource
) {
    suspend fun forNewSession(): ReconnectPolicy =
        DefaultReconnectPolicy.from(runtimeParameters.current())
}
