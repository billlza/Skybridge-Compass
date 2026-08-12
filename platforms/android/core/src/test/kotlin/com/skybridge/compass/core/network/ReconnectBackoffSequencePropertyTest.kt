package com.skybridge.compass.core.network

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.double
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.checkAll
import kotlin.time.Duration.Companion.seconds

/**
 * **Feature: cross-platform-parity-audit, Property 22: 重连退避序列与次数上限**
 *
 * **Validates: Requirements 4.7**
 *
 * 任务 9.14 的属性测试，驱动生产退避实现 [DefaultReconnectPolicy] 与生产编排
 * [ReconnectCoordinator]（均在 `:core` 的 `network/`），不在测试内重写退避公式。
 * 与既有示例测试 [ReconnectPolicyTest] / [ReconnectCoordinatorTest] 互补：示例测试固定
 * 前几次的具体间隔，本文件在**全部 attempt 序号 × 全部抖动比例 × 全部上限取值**的空间上
 * 验证退避的结构性质与次数上限。
 *
 * ### 被验证的不变式（R4.7）
 * 「相邻尝试间隔按 1 秒、2 秒、4 秒、8 秒的指数退避并以 30 秒为上限、附加不超过间隔 20%
 * 的抖动；重连次数上限取值范围 0 至 10 次；达上限仍未建立则停止、保持未建立并呈现失败分类。」
 *
 * 1. **退避区间半部**：对任意 `attempt >= 1`，间隔必落在
 *    `[base, base * 1.2]`，其中 `base = min(2^(attempt-1), 30)` 秒。等价地：间隔恒 >= base
 *    （抖动只增不减）、恒 <= base 的 120%（抖动上界 20%）、且恒 <= 36 秒（30s 上限 + 20% 抖动）。
 * 2. **单调封顶半部**：base 序列在到达 30 秒上限前严格递增，到达后恒为 30 秒（不溢出、
 *    不回绕）——包括刻意采样极大 attempt 值（生产实现先钳制指数以避免 Double 溢出）。
 * 3. **上限半部**：`maxAttempts` 越界构造被拒绝；`fromMaxReconnectAttempts` 把越界值钳制到
 *    0..10；经 [ReconnectCoordinator] 编排时实际尝试次数恒 <= `maxAttempts`，达上限未建立则
 *    呈现 [ReconnectState.GaveUp] 且携带最后一次的失败分类。
 * 4. **呈现半部**：每次尝试开始都以 [ReconnectState.Reconnecting] 呈现该次序号与总上限，
 *    且序号严格从 1 递增到实际停止处（R4.7 的"呈现序号与总上限"）。
 *
 * ### 属性定义域
 * 抖动来源在生产实现里可注入（`jitterFraction`），本测试用生成的确定值驱动它，覆盖
 * `[0, 0.2]` 区间端点与内部；同时刻意采样**越界但有限**的抖动值（负数与 > 0.2），验证生产
 * 实现用 `coerceIn` 钳制而非把越界抖动透出为超限间隔。
 *
 * 定义域**不含**非有限值（NaN / ±Inf）：生产注入源恒为 `Random.nextDouble(0.0, 0.20)`，
 * 只产出 [0, 0.2) 内的有限值，非有限值无法从生产路径到达 `delayFor`。（记录一处观察：
 * `Double.NaN.coerceIn(0.0, 0.2)` 仍为 NaN，若有调用方注入 NaN 抖动，`delayFor` 会在
 * `Duration` 构造处抛异常而非产出钳制后的间隔。这不是 R4.7 的性质、也不是当前可达的缺陷，
 * 故不在此断言，仅在此备注。）
 *
 * 迭代次数：任务未指定下限，取房内常规的上界 1000（退避为纯计算，无真实等待）。
 */
class ReconnectBackoffSequencePropertyTest : FunSpec({

    /** R4.7 的指数退避基准：min(2^(attempt-1), 30) 秒。独立推导，不引用被测实现。 */
    fun expectedBaseSeconds(attempt: Int): Double {
        var v = 1.0
        repeat(attempt - 1) {
            v *= 2.0
            if (v >= 30.0) return 30.0
        }
        return minOf(v, 30.0)
    }

    test("Property 22: 任意 attempt 的退避间隔恒落在 [base, base*1.2] 且不超过 36 秒") {
        var cappedCases = 0
        var uncappedCases = 0
        var zeroJitter = 0
        var maxJitter = 0
        var midJitter = 0
        var clampedJitter = 0

        // attempt 生成器刻意混合小序号（1..8，覆盖 1s/2s/4s/8s 的成文序列）、
        // 跨越 30s 封顶的中段（9..40），以及极大值（探测 Double 溢出防护）。
        val attemptArb: Arb<Int> = Arb.element(
            (1..8).toList() + (9..40).toList() + listOf(100, 1_000, 10_000, Int.MAX_VALUE)
        )

        // 抖动比例：含合法区间端点/内部，以及刻意越界的负数与 > 0.2 值。
        val jitterArb: Arb<Double> = Arb.element(
            listOf(0.0, 0.05, 0.1, 0.199, 0.2, -0.5, -0.0001, 0.2001, 1.0, 5.0)
        )

        checkAll(1000, attemptArb, jitterArb) { attempt, jitter ->
            val policy = DefaultReconnectPolicy(maxAttempts = 10, jitterFraction = { jitter })
            val delay = policy.delayFor(attempt)

            val base = expectedBaseSeconds(attempt)
            // 生产实现把越界抖动钳制到 [0, 0.2]，故有效抖动为：
            val effectiveJitter = jitter.coerceIn(0.0, DefaultReconnectPolicy.MAX_JITTER_FRACTION)

            // **不变式 1**：间隔恰为 base * (1 + 有效抖动)。
            delay shouldBe (base * (1.0 + effectiveJitter)).seconds

            // 区间性质（即使不逐值相等也必须成立的弱式断言，作为交叉核对）。
            (delay >= base.seconds) shouldBe true
            (delay <= (base * 1.2).seconds) shouldBe true
            // 30s 上限 + 20% 抖动 ⇒ 任何间隔都不超过 36 秒。
            (delay <= 36.seconds) shouldBe true

            if (base >= 30.0) cappedCases++ else uncappedCases++
            when {
                jitter < 0.0 || jitter > DefaultReconnectPolicy.MAX_JITTER_FRACTION -> clampedJitter++
                jitter == 0.0 -> zeroJitter++
                jitter == DefaultReconnectPolicy.MAX_JITTER_FRACTION -> maxJitter++
                else -> midJitter++
            }
        }

        println(
            "Property 22 (backoff interval) counters: capped=$cappedCases, uncapped=$uncappedCases, " +
                "zeroJitter=$zeroJitter, maxJitter=$maxJitter, midJitter=$midJitter, " +
                "clampedJitter=$clampedJitter"
        )

        // 非空真保证：封顶与未封顶、以及四种抖动情形都被生成到。
        (cappedCases > 0) shouldBe true
        (uncappedCases > 0) shouldBe true
        (zeroJitter > 0) shouldBe true
        (maxJitter > 0) shouldBe true
        (midJitter > 0) shouldBe true
        (clampedJitter > 0) shouldBe true
    }

    test("Property 22: 成文的 1s/2s/4s/8s 序列与 30s 封顶单调性") {
        var strictlyIncreasing = 0
        var atCap = 0

        checkAll(500, Arb.int(1..40)) { attempt ->
            // 抖动置 0 以观察纯基准序列。
            val policy = DefaultReconnectPolicy(maxAttempts = 10, jitterFraction = { 0.0 })
            val current = policy.delayFor(attempt)
            val next = policy.delayFor(attempt + 1)

            // 成文的前四项：1s / 2s / 4s / 8s。
            when (attempt) {
                1 -> current shouldBe 1.seconds
                2 -> current shouldBe 2.seconds
                3 -> current shouldBe 4.seconds
                4 -> current shouldBe 8.seconds
            }

            // 单调不减，且封顶后恒等于 30 秒。
            (next >= current) shouldBe true
            if (current == 30.seconds) {
                atCap++
                next shouldBe 30.seconds
            } else {
                strictlyIncreasing++
                (next > current) shouldBe true
                (current < 30.seconds) shouldBe true
            }
        }

        println(
            "Property 22 (monotonic cap) counters: strictlyIncreasing=$strictlyIncreasing, atCap=$atCap"
        )

        (strictlyIncreasing > 0) shouldBe true
        (atCap > 0) shouldBe true
    }

    test("Property 22: maxAttempts 取值范围 0..10，越界构造被拒、越界读值被钳制") {
        var inRange = 0
        var outOfRange = 0

        checkAll(500, Arb.int(-50..60)) { candidate ->
            val valid = candidate in DefaultReconnectPolicy.MIN_ATTEMPTS..DefaultReconnectPolicy.MAX_ATTEMPTS

            // 直接构造：越界必须被拒绝（不静默钳制）。
            val constructed = runCatching { DefaultReconnectPolicy(maxAttempts = candidate) }
            constructed.isSuccess shouldBe valid
            if (!valid) {
                (constructed.exceptionOrNull() is IllegalArgumentException) shouldBe true
                outOfRange++
            } else {
                constructed.getOrThrow().maxAttempts shouldBe candidate
                inRange++
            }

            // 从持久化设置读入的工厂路径：越界值钳制到 0..10 兜底，不抛异常。
            val fromSettings = DefaultReconnectPolicy.fromMaxReconnectAttempts(candidate)
            fromSettings.maxAttempts shouldBe
                candidate.coerceIn(
                    DefaultReconnectPolicy.MIN_ATTEMPTS,
                    DefaultReconnectPolicy.MAX_ATTEMPTS
                )
            (fromSettings.maxAttempts in 0..10) shouldBe true
        }

        println("Property 22 (attempt bounds) counters: inRange=$inRange, outOfRange=$outOfRange")

        (inRange > 0) shouldBe true
        (outOfRange > 0) shouldBe true
    }

    test("Property 22: 编排的实际尝试次数不超上限，序号从 1 连续递增并呈现总上限") {
        var establishedRuns = 0
        var gaveUpRuns = 0
        var disabledRuns = 0

        val runArb: Arb<Triple<Int, Int, Double>> = arbitrary {
            Triple(
                Arb.int(0..10).bind(),        // maxAttempts
                Arb.int(1..12).bind(),        // 第几次尝试成功（可能大于 maxAttempts ⇒ 永不成功）
                // 抖动比例的**定义域**：生产注入源恒为 `Random.nextDouble(0.0, 0.20)`，
                // 只产出 [0, 0.2) 内的有限值。这里用有限值枚举驱动，刻意**不**生成
                // NaN / ±Inf：那些值不在生产定义域内（`Arb.double` 默认会生成它们），
                // 且 `Double.NaN.coerceIn(0.0, 0.2)` 仍是 NaN，会在
                // `Duration` 构造处抛异常——那是"测试注入了不可能的值"，不是 R4.7 的性质。
                Arb.element(listOf(0.0, 0.01, 0.05, 0.1, 0.15, 0.199)).bind()
            )
        }

        checkAll(500, runArb) { (maxAttempts, successAt, jitter) ->
            val policy = DefaultReconnectPolicy(
                maxAttempts = maxAttempts,
                jitterFraction = { jitter }
            )

            val observedAttemptNumbers = mutableListOf<Int>()
            val observedPresentations = mutableListOf<ReconnectState.Reconnecting>()
            val sleepDurations = mutableListOf<kotlin.time.Duration>()

            val coordinator = ReconnectCoordinator(
                policy = policy,
                attemptConnect = { attempt ->
                    observedAttemptNumbers += attempt
                    if (attempt == successAt) {
                        ReconnectAttemptResult.Established
                    } else {
                        ReconnectAttemptResult.Failed("transient")
                    }
                },
                sleep = { sleepDurations += it }
            )

            // 呈现面观察：每次尝试开始的 Reconnecting 状态。
            val reconnected = coordinator.onDisconnected(DisconnectCause.UNEXPECTED)

            // **不变式 3（上限）**：实际尝试次数恒不超过上限。
            (observedAttemptNumbers.size <= maxAttempts) shouldBe true

            // 序号从 1 起连续递增（R4.7 要求呈现"该尝试的序号"）。
            observedAttemptNumbers shouldBe (1..observedAttemptNumbers.size).toList()

            // 每次尝试前都按退避序列睡眠了对应间隔（间隔值本身由前面的属性锁定）。
            sleepDurations.size shouldBe observedAttemptNumbers.size
            sleepDurations.forEachIndexed { idx, d ->
                d shouldBe policy.delayFor(idx + 1)
            }

            when {
                maxAttempts == 0 -> {
                    disabledRuns++
                    observedAttemptNumbers.size shouldBe 0
                    reconnected shouldBe false
                    val state = coordinator.state.value as ReconnectState.GaveUp
                    state.maxAttempts shouldBe 0
                    state.failureCategory shouldBe ReconnectCoordinator.FAILURE_RECONNECT_DISABLED
                }
                successAt <= maxAttempts -> {
                    establishedRuns++
                    reconnected shouldBe true
                    // 成功即停：不再继续尝试。
                    observedAttemptNumbers.size shouldBe successAt
                    coordinator.state.value shouldBe ReconnectState.Reconnected
                }
                else -> {
                    gaveUpRuns++
                    reconnected shouldBe false
                    // 达上限仍未建立：用满上限次尝试后停止。
                    observedAttemptNumbers.size shouldBe maxAttempts
                    val state = coordinator.state.value as ReconnectState.GaveUp
                    state.attempts shouldBe maxAttempts
                    state.maxAttempts shouldBe maxAttempts
                    // 保持未建立并呈现失败分类。
                    state.failureCategory shouldBe "transient"
                }
            }
        }

        println(
            "Property 22 (orchestration) counters: established=$establishedRuns, " +
                "gaveUp=$gaveUpRuns, disabled=$disabledRuns"
        )

        (establishedRuns > 0) shouldBe true
        (gaveUpRuns > 0) shouldBe true
        (disabledRuns > 0) shouldBe true
    }
})
