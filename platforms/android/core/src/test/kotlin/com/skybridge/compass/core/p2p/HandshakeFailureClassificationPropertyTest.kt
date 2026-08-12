package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.network.ConnectionEstablishmentDeadline
import com.skybridge.compass.shared.p2p.BootstrapControlChannel
import com.skybridge.compass.shared.p2p.BootstrapHandshakeException
import com.skybridge.compass.shared.p2p.BootstrapHandshakeState
import com.skybridge.compass.shared.p2p.BootstrapRekeyCause
import com.skybridge.compass.shared.p2p.DefaultBootstrapAssistedHandshake
import com.skybridge.compass.shared.p2p.DowngradePolicy
import com.skybridge.compass.shared.p2p.HandshakeFailure
import com.skybridge.compass.shared.p2p.HandshakeFailureCategory
import com.skybridge.compass.shared.p2p.HandshakeFailureClassifier
import com.skybridge.compass.shared.p2p.HandshakeFailureCondition
import com.skybridge.compass.shared.p2p.HandshakeNegotiationException
import com.skybridge.compass.shared.p2p.P2PHandshakeClient
import com.skybridge.compass.shared.p2p.PeerRef
import com.skybridge.compass.shared.p2p.PqcRekeyResult
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.of
import io.kotest.property.arbitrary.string
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 20: 握手失败分类互斥且资源释放完整**
 *
 * **Validates: Requirements 4.4**
 *
 * 任务 9.12 的属性测试，驱动生产分类器 [HandshakeFailureClassifier]（`:shared` 的
 * `HandshakeFailure.kt`）与生产资源释放路径 [DefaultBootstrapAssistedHandshake]，
 * 不在测试内重写分类表。与既有示例测试 `HandshakeFailureTest` 互补：示例测试逐条固定
 * 「condition → category」的已知映射，本文件在随机生成的 condition 空间上验证
 * **互斥性**与**资源释放完整性**这两条结构性质。
 *
 * ### 被验证的不变式（R4.4）
 * 「从十项互斥枚举中**恰好选择一项**作为失败原因分类…且保持会话为未建立状态并**释放本次
 * 尝试已分配的连接资源**。」两个半部：
 *
 * 1. **分类互斥半部**：任意 [HandshakeFailureCondition] 经 [HandshakeFailureClassifier.classify]
 *    得到的 [HandshakeFailure] 恰好属于十项 [HandshakeFailureCategory] 之一；分类是
 *    **确定性**的（同一 condition 多次分类结果相同）、**全域**的（无 condition 落空），
 *    且十项类别的 `diagnosticCode` 两两不同（互斥的可观测证据）。
 *    关键非平凡点：[HandshakeFailureCondition.BootstrapRekeyFailed] **不是**自己的类别，
 *    它按 `cause` 收敛到 LOCAL_PQC_UNAVAILABLE 或 SUITE_INTERSECTION_EMPTY 之一——
 *    所以「每个 condition 恰好一个类别」是真命题而非恒等映射。
 * 2. **资源释放半部**：任意失败路径结束后，会话必须为未建立，且本次尝试分配的资源
 *    （一次性经典控制通道、派生密钥材料）必须已释放——通道 `close()` 已调用、
 *    密钥材料已置零。
 */
class HandshakeFailureClassificationPropertyTest : FunSpec({

    /** 十项互斥类别（R4.4 的枚举全集），直接取自生产枚举而非在测试里另写一份。 */
    val allCategories = HandshakeFailureCategory.entries.toList()

    val detailArb: Arb<String?> = Arb.of(
        null,
        "",
        "   ",
        "peer closed the stream",
        "deadline exceeded at phase=2",
        "非 ASCII 诊断细节"
    )

    /** 覆盖全部 11 种 condition 变体（含按 cause 分岔的 BootstrapRekeyFailed）。 */
    val conditionArb: Arb<HandshakeFailureCondition> = arbitrary {
        val detail = detailArb.bind()
        when (Arb.int(0..10).bind()) {
            0 -> HandshakeFailureCondition.PeerKemPublicKeyUnavailable(detail)
            1 -> HandshakeFailureCondition.SuiteIntersectionEmpty(detail)
            2 -> HandshakeFailureCondition.LocalPqcUnavailable(detail)
            3 -> HandshakeFailureCondition.SignatureVerificationFailed(detail)
            4 -> HandshakeFailureCondition.KeyConfirmationFailed(detail)
            5 -> HandshakeFailureCondition.ReplayDetected(detail)
            6 -> HandshakeFailureCondition.IdentityFingerprintMismatch(detail)
            7 -> HandshakeFailureCondition.SuiteSignatureMismatch(detail)
            8 -> HandshakeFailureCondition.Timeout(detail)
            9 -> HandshakeFailureCondition.NetworkUnreachable(detail)
            else -> HandshakeFailureCondition.BootstrapRekeyFailed(
                cause = Arb.element(BootstrapRekeyCause.entries.toList()).bind(),
                detail = detail
            )
        }
    }

    test("Property 20: 每个失败条件恰好归入十项互斥分类之一，且分类确定") {
        // 类别层面的硬不变量，与生成无关，先直接锁定。
        allCategories.size shouldBe 10
        allCategories.map { it.diagnosticCode }.toSet().size shouldBe 10

        var bootstrapConditions = 0
        var directConditions = 0
        // 每个类别被命中的次数，用于证明分类不是坍缩到少数几项。
        val categoryHits = mutableMapOf<HandshakeFailureCategory, Int>()

        checkAll(1000, conditionArb) { condition ->
            val failure = HandshakeFailureClassifier.classify(condition)

            // **恰好一项**：分类结果的 category 必在十项枚举内。
            allCategories.contains(failure.category) shouldBe true
            // 互斥的可观测证据：该 category 恰好匹配十项中的一项（不多不少）。
            allCategories.count { it == failure.category } shouldBe 1
            // diagnosticCode 与 category 一致，且在十项里唯一。
            failure.diagnosticCode shouldBe failure.category.diagnosticCode
            allCategories.count { it.diagnosticCode == failure.diagnosticCode } shouldBe 1

            // **确定性**：重复分类同一 condition 必得同一 category 与同一 failure 类型。
            val again = HandshakeFailureClassifier.classify(condition)
            again.category shouldBe failure.category
            (again::class == failure::class) shouldBe true

            categoryHits[failure.category] = (categoryHits[failure.category] ?: 0) + 1

            // 非恒等映射的关键分岔：BootstrapRekeyFailed 收敛到两项之一，不自成一类。
            if (condition is HandshakeFailureCondition.BootstrapRekeyFailed) {
                bootstrapConditions++
                val expected = when (condition.cause) {
                    BootstrapRekeyCause.LOCAL_PQC_UNAVAILABLE ->
                        HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE
                    BootstrapRekeyCause.SUITE_INTERSECTION_EMPTY ->
                        HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY
                }
                failure.category shouldBe expected
            } else {
                directConditions++
            }

            // 携带的诊断细节不得改变分类归属（细节只进消息，不进判定）。
            val withOtherDetail = HandshakeFailureClassifier.classify(
                when (condition) {
                    is HandshakeFailureCondition.PeerKemPublicKeyUnavailable ->
                        HandshakeFailureCondition.PeerKemPublicKeyUnavailable("altered")
                    is HandshakeFailureCondition.SuiteIntersectionEmpty ->
                        HandshakeFailureCondition.SuiteIntersectionEmpty("altered")
                    is HandshakeFailureCondition.LocalPqcUnavailable ->
                        HandshakeFailureCondition.LocalPqcUnavailable("altered")
                    is HandshakeFailureCondition.SignatureVerificationFailed ->
                        HandshakeFailureCondition.SignatureVerificationFailed("altered")
                    is HandshakeFailureCondition.KeyConfirmationFailed ->
                        HandshakeFailureCondition.KeyConfirmationFailed("altered")
                    is HandshakeFailureCondition.ReplayDetected ->
                        HandshakeFailureCondition.ReplayDetected("altered")
                    is HandshakeFailureCondition.IdentityFingerprintMismatch ->
                        HandshakeFailureCondition.IdentityFingerprintMismatch("altered")
                    is HandshakeFailureCondition.SuiteSignatureMismatch ->
                        HandshakeFailureCondition.SuiteSignatureMismatch("altered")
                    is HandshakeFailureCondition.Timeout ->
                        HandshakeFailureCondition.Timeout("altered")
                    is HandshakeFailureCondition.NetworkUnreachable ->
                        HandshakeFailureCondition.NetworkUnreachable("altered")
                    is HandshakeFailureCondition.BootstrapRekeyFailed ->
                        HandshakeFailureCondition.BootstrapRekeyFailed(condition.cause, "altered")
                }
            )
            withOtherDetail.category shouldBe failure.category

            // 经异常载体传递后分类不变（throw-site 到呈现面的保真）。
            val ex = HandshakeNegotiationException(failure)
            ex.category shouldBe failure.category
            ex.failure.category shouldBe failure.category
            // 契约保持：仍是 IllegalStateException 子类，既有调用方的 catch 不被削弱。
            // 用运行时可赋值性判定而非 `is`——后者在此处是编译期恒真的同义反复。
            IllegalStateException::class.java.isAssignableFrom(ex.javaClass) shouldBe true
        }

        println(
            "Property 20 counters: bootstrapConditions=$bootstrapConditions, " +
                "directConditions=$directConditions, distinctCategoriesHit=${categoryHits.size}, " +
                "hits=$categoryHits"
        )

        // 非空真保证：两类 condition 都被生成到，且十项类别全部被命中。
        (bootstrapConditions > 0) shouldBe true
        (directConditions > 0) shouldBe true
        categoryHits.size shouldBe 10
        allCategories.all { (categoryHits[it] ?: 0) > 0 } shouldBe true
    }

    test("Property 20: 建立时限看门狗只产出 TIMEOUT 一项分类，且呈现门与密钥状态一致") {
        var timedOut = 0
        var completed = 0
        var expiredCases = 0
        var notExpiredCases = 0

        val deadlineArb: Arb<Pair<Boolean, Long>> = arbitrary {
            // 会话密钥是否已建立 × 到期时刻的流逝毫秒（跨越 30s 边界两侧）。
            Arb.boolean().bind() to Arb.int(0..60_000).bind().toLong()
        }

        checkAll(300, deadlineArb) { (keysEstablished, elapsedMillis) ->
            // 注入确定化时钟，无需真实等待即可推进到时限边界两侧。
            var clock = 0L
            val deadline = ConnectionEstablishmentDeadline(now = { clock })
            deadline.start()
            clock = elapsedMillis

            val outcome = deadline.evaluateOnDeadline(keysEstablished)

            // 呈现门（R4.2 不变式）：能否呈现为已建立完全由会话密钥状态决定，与时钟无关。
            deadline.canPresentEstablished(keysEstablished) shouldBe keysEstablished

            if (deadline.hasExpired()) expiredCases++ else notExpiredCases++

            when (outcome) {
                is ConnectionEstablishmentDeadline.Outcome.Established -> {
                    completed++
                    keysEstablished shouldBe true
                }
                is ConnectionEstablishmentDeadline.Outcome.TimedOut -> {
                    timedOut++
                    keysEstablished shouldBe false
                    // 看门狗只会产出十项里的 TIMEOUT 一项，绝不产出其它分类。
                    outcome.category shouldBe HandshakeFailureCategory.TIMEOUT
                    allCategories.count { it == outcome.category } shouldBe 1
                    outcome.category.diagnosticCode shouldBe
                        ConnectionEstablishmentDeadline.TIMEOUT_DIAGNOSTIC_CODE
                }
            }
        }

        println(
            "Property 20 (deadline) counters: timedOut=$timedOut, completed=$completed, " +
                "expired=$expiredCases, notExpired=$notExpiredCases"
        )

        (timedOut > 0) shouldBe true
        (completed > 0) shouldBe true
        // 时限边界两侧都被生成到。
        (expiredCases > 0) shouldBe true
        (notExpiredCases > 0) shouldBe true
    }

    test("Property 20: 任意失败路径都保持会话未建立并释放本次尝试的连接资源") {
        var kemFailures = 0
        var rekeyFailures = 0
        var successes = 0

        /** 记录资源生命周期的一次性经典控制通道替身。 */
        class TrackedChannel(
            private val returnKeys: Boolean,
            private val failRetrieval: Boolean,
            val secret: ByteArray
        ) : BootstrapControlChannel {
            var closed = 0
                private set

            override suspend fun retrievePeerKemPublicKeys(): P2PHandshakeClient.PeerKemPublicKeys {
                if (failRetrieval) error("retrieval failed")
                return if (returnKeys) {
                    P2PHandshakeClient.PeerKemPublicKeys(mlKem768PublicKey = ByteArray(32) { 0x7 })
                } else {
                    P2PHandshakeClient.PeerKemPublicKeys()
                }
            }

            override fun derivedKeyMaterial(): ByteArray = secret

            override suspend fun close() {
                closed++
            }
        }

        val pathArb: Arb<Triple<Boolean, Boolean, Boolean>> = arbitrary {
            Triple(Arb.boolean().bind(), Arb.boolean().bind(), Arb.boolean().bind())
        }

        checkAll(400, pathArb) { (retrievalSucceeds, bundleNonEmpty, rekeySucceeds) ->
            val secret = ByteArray(32) { (it + 3).toByte() }
            secret.any { it != 0.toByte() } shouldBe true

            val channel = TrackedChannel(
                returnKeys = bundleNonEmpty,
                failRetrieval = !retrievalSucceeds,
                secret = secret
            )

            val flow = DefaultBootstrapAssistedHandshake(
                policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
                localPeerKemLookup = { null },
                openControlChannel = { channel },
                forcePqcRekey = { _, _ ->
                    if (rekeySucceeds) {
                        PqcRekeyResult.Success
                    } else {
                        PqcRekeyResult.Failed(BootstrapRekeyCause.LOCAL_PQC_UNAVAILABLE, "resource-release")
                    }
                }
            )

            val result = flow.bootstrapPeerKemKeys(PeerRef("peer-res"))

            // 一次性经典控制通道在所有路径上都必须被关闭（不滞留连接资源）。
            (channel.closed >= 1) shouldBe true

            if (result.isFailure) {
                // **资源释放半部**：失败必须保持会话未建立。
                flow.state shouldBe BootstrapHandshakeState.FAILED
                flow.isSessionEstablished shouldBe false
                flow.canCarryBusinessTraffic shouldBe false
                // 且本次尝试派生的密钥材料已置零。
                secret.all { it == 0.toByte() } shouldBe true

                // 失败分类必属十项之一。
                val ex = result.exceptionOrNull() as BootstrapHandshakeException
                allCategories.contains(ex.failure.category) shouldBe true

                if (!retrievalSucceeds || !bundleNonEmpty) {
                    kemFailures++
                    ex.failure.category shouldBe
                        HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE
                } else {
                    rekeyFailures++
                    ex.failure.category shouldBe HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE
                }
            } else {
                successes++
                flow.state shouldBe BootstrapHandshakeState.ESTABLISHED
            }
        }

        println(
            "Property 20 (resource release) counters: kemFailures=$kemFailures, " +
                "rekeyFailures=$rekeyFailures, successes=$successes"
        )

        (kemFailures > 0) shouldBe true
        (rekeyFailures > 0) shouldBe true
        (successes > 0) shouldBe true
    }
})
