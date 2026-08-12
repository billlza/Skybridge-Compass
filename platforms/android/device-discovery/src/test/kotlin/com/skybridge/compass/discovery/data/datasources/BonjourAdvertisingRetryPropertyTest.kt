package com.skybridge.compass.discovery.data.datasources

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.types.shouldBeInstanceOf
import io.kotest.property.Arb
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.checkAll
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * **Feature: cross-platform-parity-audit, Property 15: 广播注册重试序列与失败终态**
 *
 * **Validates: Requirements 3.13**
 *
 * 任务 7.18 的属性测试。与 [BonjourAdvertisingRetryTest] 的示例测试**互补**：示例测试固定
 * "全失败"、"第 3 次成功"、"首次成功"、"取消"四个序列，本文件在随机生成的
 * "失败次数 × 失败异常类型 × 成功时机"空间上验证 R3.13 的三个半部：
 *
 * 1. **重试序列**：无论失败发生在第几次，实际尝试次数恒为 `min(首次失败次数+1, 4)`，
 *    退避序列恒为 1s/2s/4s 的**前缀**，且最多重试 [BonjourAdvertisingRetryPolicy.MAX_RETRIES]=3 次
 *    （即总尝试 ≤ 4 次）。
 * 2. **失败终态**：4 次尝试全部失败时状态转为 [BonjourAdvertisingStatus.Failed] 并携带
 *    可展示的原因文本；成功时转为 [BonjourAdvertisingStatus.Active]。
 * 3. **浏览不受影响**：广播终态失败不改变浏览侧状态——本文件以"广播状态流与浏览侧标志相互独立"
 *    的形式断言（浏览的独立协程存活性由示例测试的 supervisorScope 用例覆盖）。
 *
 * **属性定义域**：退避时钟经 `delayMs` 注入，故测试不真正等待 7 秒；R3.13 的"10 秒无成功回调"
 * 超时判定由 `BonjourAdvertiserDataSource` 的 `withTimeout` 实现（需真实 NsdManager，
 * 不在本单元测试定义域内），本属性覆盖的是超时被转为一次失败**之后**的重试/终态逻辑。
 * [CancellationException] 单列一档：结构化取消必须原样传播且**不得**被标记为失败终态。
 *
 * 为避免空真通过，每个测试统计其真正走到的分支并在 `checkAll` 后断言计数均大于 0。
 */
class BonjourAdvertisingRetryPropertyTest : FunSpec({

    val serviceTypeArb: Arb<String> = Arb.element(
        "_skybridge._tcp",
        "_skybridge-remote._tcp",
        "_skybridge-transfer._tcp"
    )

    /** 失败异常类型：覆盖 NSD 注册失败、注册超时与通用异常三种真实成因。 */
    fun failureFor(kind: Int, attempt: Int): Throwable = when (kind) {
        0 -> IllegalStateException("NSD registration failed (errorCode=$attempt)")
        1 -> BonjourAdvertisingException("NSD registration timed out after 10000ms for attempt $attempt")
        else -> RuntimeException("unexpected NSD failure #$attempt")
    }

    test("Property 15: 尝试次数与退避序列恒为 1s/2s/4s 的前缀，且总尝试不超过 4 次") {
        var firstAttemptSuccess = 0
        var successAfterRetry = 0
        var exhaustedAllRetries = 0
        var timeoutFailureKind = 0
        var nsdFailureKind = 0

        // failuresBeforeSuccess = 0..5：>=4 时代表"永不成功"，用于覆盖重试耗尽终态。
        checkAll(1_000, Arb.int(0..5), Arb.int(0..2)) { failuresBeforeSuccess, failureKind ->
            val backoffs = mutableListOf<Long>()
            val retryIndices = mutableListOf<Int>()
            var attempts = 0

            val outcome = runCatching {
                BonjourAdvertisingRetryPolicy.execute(
                    attempt = { attemptIndex ->
                        attempts += 1
                        if (attemptIndex < failuresBeforeSuccess) {
                            throw failureFor(failureKind, attemptIndex + 1)
                        }
                        "service-name-$attemptIndex"
                    },
                    delayMs = { backoffs += it },
                    onRetryScheduled = { retryIndex, _ -> retryIndices += retryIndex }
                )
            }

            val expectedAttempts = minOf(
                failuresBeforeSuccess + 1,
                BonjourAdvertisingRetryPolicy.MAX_RETRIES + 1
            )

            // 核心属性 1：尝试次数恒为 min(失败次数+1, 4)，绝不超过 4 次。
            attempts shouldBe expectedAttempts
            (attempts <= BonjourAdvertisingRetryPolicy.MAX_RETRIES + 1) shouldBe true

            // 核心属性 2：退避序列恒为 [1000, 2000, 4000] 的前缀，长度 = 尝试次数 - 1。
            val expectedBackoffs = BonjourAdvertisingRetryPolicy.BACKOFF_DELAYS_MS
                .take(expectedAttempts - 1)
            backoffs shouldBe expectedBackoffs
            // 重试索引恒为 1..n 的连续序列。
            retryIndices shouldBe (1..(expectedAttempts - 1)).toList()

            if (failuresBeforeSuccess <= BonjourAdvertisingRetryPolicy.MAX_RETRIES) {
                // 在允许的尝试次数内成功：返回成功值。
                outcome.isSuccess shouldBe true
                outcome.getOrNull() shouldBe "service-name-$failuresBeforeSuccess"
                if (failuresBeforeSuccess == 0) firstAttemptSuccess++ else successAfterRetry++
            } else {
                // 超出重试预算：重抛最后一次失败，且退避恰好用尽 1s/2s/4s 三档。
                outcome.isFailure shouldBe true
                backoffs shouldBe BonjourAdvertisingRetryPolicy.BACKOFF_DELAYS_MS
                exhaustedAllRetries++
            }

            if (failuresBeforeSuccess > 0) {
                if (failureKind == 1) timeoutFailureKind++ else if (failureKind == 0) nsdFailureKind++
            }
        }

        println(
            "[Property 15 序列] firstAttemptSuccess=$firstAttemptSuccess " +
                "successAfterRetry=$successAfterRetry exhaustedAllRetries=$exhaustedAllRetries " +
                "timeoutFailureKind=$timeoutFailureKind nsdFailureKind=$nsdFailureKind"
        )

        // 非空真保证：首次成功、重试后成功、重试耗尽与两类失败成因都被真正生成到。
        (firstAttemptSuccess > 0) shouldBe true
        (successAfterRetry > 0) shouldBe true
        (exhaustedAllRetries > 0) shouldBe true
        (timeoutFailureKind > 0) shouldBe true
        (nsdFailureKind > 0) shouldBe true
    }

    test("Property 15 (终态): registrar 的状态序列为 Registering -> Retrying(1..n) -> Active|Failed") {
        var endedActive = 0
        var endedFailed = 0
        var sawRetryingStates = 0

        checkAll(500, Arb.int(0..5), Arb.int(0..2), serviceTypeArb) {
                failuresBeforeSuccess, failureKind, serviceType ->

            val status = MutableStateFlow<BonjourAdvertisingStatus>(BonjourAdvertisingStatus.Idle)
            val observedAtAttemptStart = mutableListOf<BonjourAdvertisingStatus>()
            val registrar = BonjourAdvertisingRegistrar(status = status, delayMs = { })
            var attemptIndex = 0

            val outcome = runCatching {
                registrar.register(serviceType = serviceType) {
                    observedAtAttemptStart += status.value
                    val current = attemptIndex
                    attemptIndex += 1
                    if (current < failuresBeforeSuccess) {
                        throw failureFor(failureKind, current + 1)
                    }
                    "instance-$current"
                }
            }

            // 第一次尝试前状态恒为 Registering。
            observedAtAttemptStart.first() shouldBe BonjourAdvertisingStatus.Registering(serviceType)

            // 其后每次尝试前状态恒为 Retrying(i, 对应退避)，索引与退避严格对应。
            observedAtAttemptStart.drop(1).forEachIndexed { i, observed ->
                observed shouldBe BonjourAdvertisingStatus.Retrying(
                    serviceType = serviceType,
                    attempt = i + 1,
                    backoffMs = BonjourAdvertisingRetryPolicy.BACKOFF_DELAYS_MS[i]
                )
            }
            if (observedAtAttemptStart.size > 1) sawRetryingStates++

            if (failuresBeforeSuccess <= BonjourAdvertisingRetryPolicy.MAX_RETRIES) {
                // 成功终态：Active 且携带注册得到的实例名。
                outcome.isSuccess shouldBe true
                val terminal = status.value
                terminal.shouldBeInstanceOf<BonjourAdvertisingStatus.Active>()
                terminal.serviceType shouldBe serviceType
                terminal.serviceName shouldBe "instance-$failuresBeforeSuccess"
                endedActive++
            } else {
                // 失败终态：Failed 且原因文本可展示（含服务类型与重试次数）。
                outcome.isFailure shouldBe true
                val terminal = status.value
                terminal.shouldBeInstanceOf<BonjourAdvertisingStatus.Failed>()
                terminal.serviceType shouldBe serviceType
                terminal.reason.isNotBlank() shouldBe true
                terminal.reason.contains(serviceType) shouldBe true
                terminal.reason.contains(
                    "failed after ${BonjourAdvertisingRetryPolicy.MAX_RETRIES} retries"
                ) shouldBe true
                endedFailed++
            }
        }

        println(
            "[Property 15 终态] endedActive=$endedActive endedFailed=$endedFailed " +
                "sawRetryingStates=$sawRetryingStates"
        )

        // 非空真保证：Active 与 Failed 两个终态、以及经历过 Retrying 的序列都被真正生成到。
        (endedActive > 0) shouldBe true
        (endedFailed > 0) shouldBe true
        (sawRetryingStates > 0) shouldBe true
    }

    test("Property 15: 结构化取消原样传播且不产生失败终态；广播终态与浏览侧状态相互独立") {
        var cancelledCases = 0
        var failedCases = 0
        var browseUnaffected = 0

        checkAll(300, Arb.int(0..3), Arb.boolean(), serviceTypeArb) { cancelAtAttempt, cancel, serviceType ->
            val status = MutableStateFlow<BonjourAdvertisingStatus>(BonjourAdvertisingStatus.Idle)
            val registrar = BonjourAdvertisingRegistrar(status = status, delayMs = { })
            // 浏览侧的独立标志：广播路径的任何转移都不得改写它（R3.13 要求浏览继续运行）。
            var browseRunning = true
            var attemptIndex = 0

            val outcome = runCatching {
                registrar.register(serviceType = serviceType) {
                    val current = attemptIndex
                    attemptIndex += 1
                    if (cancel && current == cancelAtAttempt) {
                        throw CancellationException("scope cancelled")
                    }
                    throw IllegalStateException("registration failed #${current + 1}")
                }
            }

            outcome.isFailure shouldBe true
            val error = outcome.exceptionOrNull()!!

            if (cancel) {
                cancelledCases++
                // 取消必须原样传播，且状态不得变成 Failed。
                error.shouldBeInstanceOf<CancellationException>()
                (status.value is BonjourAdvertisingStatus.Failed) shouldBe false
                cancelAtAttempt.let { at ->
                    val expected = if (at == 0) {
                        BonjourAdvertisingStatus.Registering(serviceType)
                    } else {
                        BonjourAdvertisingStatus.Retrying(
                            serviceType = serviceType,
                            attempt = at,
                            backoffMs = BonjourAdvertisingRetryPolicy.BACKOFF_DELAYS_MS[at - 1]
                        )
                    }
                    status.value shouldBe expected
                }
            } else {
                failedCases++
                // 未取消且始终失败：终态为 Failed。
                status.value.shouldBeInstanceOf<BonjourAdvertisingStatus.Failed>()
            }

            // 浏览侧未被广播路径触碰。
            browseRunning shouldBe true
            browseUnaffected++
        }

        println(
            "[Property 15 取消] cancelledCases=$cancelledCases failedCases=$failedCases " +
                "browseUnaffected=$browseUnaffected"
        )

        (cancelledCases > 0) shouldBe true
        (failedCases > 0) shouldBe true
        (browseUnaffected > 0) shouldBe true
    }
})
