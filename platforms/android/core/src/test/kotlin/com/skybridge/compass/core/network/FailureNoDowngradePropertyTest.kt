package com.skybridge.compass.core.network

import com.skybridge.compass.shared.p2p.DowngradeDecision
import com.skybridge.compass.shared.p2p.DowngradePolicy
import com.skybridge.compass.shared.p2p.FallbackReason
import com.skybridge.compass.shared.p2p.HandshakeFailureCategory
import com.skybridge.compass.shared.p2p.HandshakeFailureResponse
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.PolicyGate
import com.skybridge.compass.shared.p2p.UserDowngradeAuthorization
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 21: 失败不触发降级、不切换未认证路径、不自动重连**
 *
 * **Validates: Requirements 4.5, 4.6, 4.13**
 *
 * 任务 9.13 的属性测试，驱动生产裁决面 [HandshakeFailureResponse]（`:shared`）与生产编排面
 * [ReconnectCoordinator]（`:core`），不在测试内重写任何裁决表。与既有示例测试
 * `HandshakeFailureResponseTest` / [ReconnectCoordinatorTest] 互补：示例测试固定若干已知
 * 类别，本文件在**十项失败分类全域**上验证三条恒定禁令，并把裁决与真实重连编排的
 * 可观测行为交叉核对。
 *
 * ### 被验证的不变式
 * 1. **R4.5 / R4.6 — 失败恒不降级**：对**任意** [HandshakeFailureCategory]，
 *    [HandshakeFailureResponse.permitsAutomaticSuiteDowngrade] 恒为 false。这是全域恒假命题，
 *    在十项类别上逐项验证（含随机重复采样，确认无隐藏状态导致的偶发 true）。
 * 2. **R4.5 — 失败恒不切换未认证路径**：对任意类别
 *    [HandshakeFailureResponse.permitsUnauthenticatedPathSwitch] 恒为 false。
 * 3. **R4.13 — 指纹不匹配恒不自动重连**：
 *    [HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH] 及其余认证完整性/协商终态类别
 *    的 [HandshakeFailureResponse.permitsAutomaticReconnect] 为 false，且经
 *    [ReconnectCoordinator.onHandshakeFailure] 编排时**实际发起的连接尝试数恒为 0**——
 *    这是「不自动重连」的行为级证据，而非仅裁决函数返回值。仅超时 / 网络不可达两项瞬时
 *    传输失败允许重连。
 * 4. **交叉核对**：即便策略 posture 允许经典业务回退、且失败原因在 [FallbackReason] 的
 *    ALLOWED 集内，只要没有用户显式授权，[PolicyGate.authorizeUserApprovedDowngrade] 仍拒绝；
 *    而任何 BLOCKED 原因即便带用户授权也被结构性拒绝（降级不因失败而发生）。
 *
 * 非空真保证：每个测试统计并断言各分支计数 > 0，并打印计数值。
 */
class FailureNoDowngradePropertyTest : FunSpec({

    val allCategories = HandshakeFailureCategory.entries.toList()

    /** R4.13 与认证完整性/协商终态类别：不得自动重连。 */
    val terminalCategories = setOf(
        HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH,
        HandshakeFailureCategory.SIGNATURE_VERIFICATION_FAILED,
        HandshakeFailureCategory.KEY_CONFIRMATION_FAILED,
        HandshakeFailureCategory.REPLAY_DETECTED,
        HandshakeFailureCategory.SUITE_SIGNATURE_MISMATCH,
        HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY,
        HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE,
        HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE
    )

    /** 仅这两项瞬时传输失败是重连合格的。 */
    val transientCategories = setOf(
        HandshakeFailureCategory.TIMEOUT,
        HandshakeFailureCategory.NETWORK_UNREACHABLE
    )

    val categoryArb: Arb<HandshakeFailureCategory> = Arb.element(allCategories)

    test("Property 21: 任意失败分类都不得触发套件降级、不得切换未认证路径") {
        // 生成器自检：两个子集恰好划分十项类别（不重不漏），否则后续分支断言可能空真。
        (terminalCategories + transientCategories).size shouldBe 10
        terminalCategories.intersect(transientCategories) shouldBe emptySet()

        var terminalSeen = 0
        var transientSeen = 0
        val perCategory = mutableMapOf<HandshakeFailureCategory, Int>()

        checkAll(1000, categoryArb) { category ->
            // **不变式 1（R4.5/R4.6）**：失败恒不授权套件降级——全域恒假。
            HandshakeFailureResponse.permitsAutomaticSuiteDowngrade(category) shouldBe false
            // **不变式 2（R4.5）**：失败恒不切换未认证路径——全域恒假。
            HandshakeFailureResponse.permitsUnauthenticatedPathSwitch(category) shouldBe false

            // 幂等/无隐藏状态：重复询问同一类别结果不变。
            HandshakeFailureResponse.permitsAutomaticSuiteDowngrade(category) shouldBe false
            HandshakeFailureResponse.permitsUnauthenticatedPathSwitch(category) shouldBe false

            // **不变式 3（R4.13）**：重连合格性恰好按瞬时/终态划分。
            val reconnectAllowed = HandshakeFailureResponse.permitsAutomaticReconnect(category)
            if (category in terminalCategories) {
                terminalSeen++
                reconnectAllowed shouldBe false
            } else {
                transientSeen++
                reconnectAllowed shouldBe true
            }

            perCategory[category] = (perCategory[category] ?: 0) + 1
        }

        println(
            "Property 21 counters: terminalSeen=$terminalSeen, transientSeen=$transientSeen, " +
                "distinctCategories=${perCategory.size}"
        )

        (terminalSeen > 0) shouldBe true
        (transientSeen > 0) shouldBe true
        // 十项类别全部被采样到，恒假命题不是只在少数类别上被检验。
        perCategory.size shouldBe 10
        allCategories.all { (perCategory[it] ?: 0) > 0 } shouldBe true
    }

    test("Property 21: 终态失败经重连编排时实际发起的连接尝试数恒为 0（R4.13 行为级证据）") {
        var terminalCases = 0
        var transientCases = 0
        var transientEstablished = 0
        var transientGaveUp = 0

        val caseArb: Arb<Triple<HandshakeFailureCategory, Int, Boolean>> = arbitrary {
            Triple(
                categoryArb.bind(),
                Arb.int(0..10).bind(),      // maxAttempts（R4.7 允许的 0..10）
                Arb.boolean().bind()        // 瞬时失败时，某次尝试是否最终建立
            )
        }

        checkAll(400, caseArb) { (category, maxAttempts, eventuallyEstablishes) ->
            var attemptsMade = 0
            var slept = 0

            val coordinator = ReconnectCoordinator(
                policy = DefaultReconnectPolicy(
                    maxAttempts = maxAttempts,
                    // 抖动确定化，退避不引入真实等待。
                    jitterFraction = { 0.0 }
                ),
                attemptConnect = { attempt ->
                    attemptsMade++
                    if (eventuallyEstablishes && attempt == maxAttempts) {
                        ReconnectAttemptResult.Established
                    } else {
                        ReconnectAttemptResult.Failed(category.diagnosticCode)
                    }
                },
                // 注入空睡眠：退避序列本身由 Property 22 验证，这里只关心尝试次数。
                sleep = { slept++ }
            )

            val reconnected = coordinator.onHandshakeFailure(category)

            if (category in terminalCategories) {
                terminalCases++
                // **R4.13 的行为级证据**：终态失败一次连接尝试都不发起。
                attemptsMade shouldBe 0
                slept shouldBe 0
                reconnected shouldBe false
                // 呈现为已放弃，且尝试数为 0。
                val state = coordinator.state.value as ReconnectState.GaveUp
                state.attempts shouldBe 0
                state.failureCategory shouldBe ReconnectCoordinator.FAILURE_TERMINAL
            } else {
                transientCases++
                // 瞬时失败：允许按上限重连；上限为 0 时同样一次都不试。
                if (maxAttempts == 0) {
                    attemptsMade shouldBe 0
                    reconnected shouldBe false
                    val state = coordinator.state.value as ReconnectState.GaveUp
                    state.failureCategory shouldBe ReconnectCoordinator.FAILURE_RECONNECT_DISABLED
                } else {
                    (attemptsMade in 1..maxAttempts) shouldBe true
                    if (eventuallyEstablishes) {
                        transientEstablished++
                        reconnected shouldBe true
                        coordinator.state.value shouldBe ReconnectState.Reconnected
                    } else {
                        transientGaveUp++
                        reconnected shouldBe false
                        attemptsMade shouldBe maxAttempts
                        val state = coordinator.state.value as ReconnectState.GaveUp
                        state.attempts shouldBe maxAttempts
                        state.maxAttempts shouldBe maxAttempts
                        // 如实呈现最后一次尝试的失败分类。
                        state.failureCategory shouldBe category.diagnosticCode
                    }
                }
            }

            // 无论哪条路径，失败都不得授权降级或未认证路径切换。
            HandshakeFailureResponse.permitsAutomaticSuiteDowngrade(category) shouldBe false
            HandshakeFailureResponse.permitsUnauthenticatedPathSwitch(category) shouldBe false
        }

        println(
            "Property 21 (reconnect orchestration) counters: terminalCases=$terminalCases, " +
                "transientCases=$transientCases, transientEstablished=$transientEstablished, " +
                "transientGaveUp=$transientGaveUp"
        )

        (terminalCases > 0) shouldBe true
        (transientCases > 0) shouldBe true
        (transientEstablished > 0) shouldBe true
        (transientGaveUp > 0) shouldBe true
    }

    test("Property 21: 降级只在策略允许且用户显式授权时发生，失败原因本身从不授权降级") {
        var deniedUserNotAuthorized = 0
        var deniedReasonIneligible = 0
        var deniedByPolicy = 0
        var allowed = 0

        val suitePairs = listOf(
            P2PCryptoSuite.X_WING to P2PCryptoSuite.X25519,
            P2PCryptoSuite.MLKEM_768 to P2PCryptoSuite.X25519,
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND to P2PCryptoSuite.X25519
        )

        data class GateCase(
            val policy: DowngradePolicy,
            val reason: FallbackReason,
            val userAuthorizes: Boolean,
            val suites: Pair<P2PCryptoSuite, P2PCryptoSuite>,
            val peerIndex: Int
        )

        val gateArb: Arb<GateCase> = arbitrary {
            GateCase(
                policy = Arb.element(DowngradePolicy.entries.toList()).bind(),
                reason = Arb.element(FallbackReason.entries.toList()).bind(),
                userAuthorizes = Arb.boolean().bind(),
                suites = Arb.element(suitePairs).bind(),
                peerIndex = Arb.int(1..10_000).bind()
            )
        }

        checkAll(600, gateArb) { case ->
            val peer = "peer-${case.peerIndex}"
            val (from, to) = case.suites
            // 每个用例独立的 gate（各自独立的冷却存储），避免用例间相互影响。
            val gate = PolicyGate(policy = case.policy)

            val auth = if (case.userAuthorizes) {
                UserDowngradeAuthorization.Granted(
                    peer = peer,
                    fromSuiteWireId = from.wireId.toInt(),
                    toSuiteWireId = to.wireId.toInt()
                )
            } else {
                UserDowngradeAuthorization.NotAuthorized
            }

            val decision = gate.authorizeUserApprovedDowngrade(
                peer = peer,
                fromSuite = from,
                toSuite = to,
                reason = case.reason,
                userAuthorization = auth
            )

            // 判定顺序（生产实现）：用户授权 → 原因合格性 → posture → 速率限制。
            when {
                !case.userAuthorizes -> {
                    deniedUserNotAuthorized++
                    decision shouldBe DowngradeDecision.DeniedUserNotAuthorized
                    // 未授权时不得铸出任何审计事件。
                    (decision.eventOrNull() == null) shouldBe true
                }
                !case.reason.isFallbackEligible() -> {
                    deniedReasonIneligible++
                    // 结构性拒绝：BLOCKED 原因即便带用户授权也不得降级
                    // （含 TIMEOUT 等网络派生失败——这正是 R4.6 的抗降级要求）。
                    (decision is DowngradeDecision.DeniedReasonIneligible) shouldBe true
                    (decision.eventOrNull() == null) shouldBe true
                }
                !case.policy.allowsClassicBusinessFallback() -> {
                    deniedByPolicy++
                    decision shouldBe DowngradeDecision.DeniedByPolicy
                    (decision.eventOrNull() == null) shouldBe true
                }
                else -> {
                    allowed++
                    // 策略允许 + 原因合格 + 用户显式授权 → 授权，并铸出可审计事件。
                    decision.isAllowed shouldBe true
                    val event = requireNotNull(decision.eventOrNull())
                    event.peer shouldBe peer
                    event.fromSuite shouldBe from.wireId.toInt()
                    event.toSuite shouldBe to.wireId.toInt()
                    event.reason shouldBe case.reason
                    event.policy shouldBe case.policy
                }
            }

            // 关键交叉核对：无论上面的降级判定如何，**握手失败**这一侧恒不授权降级。
            // 十项失败分类与 FallbackReason 是两条不同的轴，前者恒假（R4.5/R4.6）。
            allCategories.all {
                !HandshakeFailureResponse.permitsAutomaticSuiteDowngrade(it) &&
                    !HandshakeFailureResponse.permitsUnauthenticatedPathSwitch(it)
            } shouldBe true
        }

        println(
            "Property 21 (downgrade gate) counters: deniedUserNotAuthorized=$deniedUserNotAuthorized, " +
                "deniedReasonIneligible=$deniedReasonIneligible, deniedByPolicy=$deniedByPolicy, " +
                "allowed=$allowed"
        )

        (deniedUserNotAuthorized > 0) shouldBe true
        (deniedReasonIneligible > 0) shouldBe true
        (deniedByPolicy > 0) shouldBe true
        (allowed > 0) shouldBe true
    }
})
