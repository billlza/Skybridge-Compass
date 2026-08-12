package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.p2p.BootstrapAssistedHandshake
import com.skybridge.compass.shared.p2p.BootstrapControlChannel
import com.skybridge.compass.shared.p2p.BootstrapDerivedKeyMaterial
import com.skybridge.compass.shared.p2p.BootstrapHandshakeException
import com.skybridge.compass.shared.p2p.BootstrapHandshakeState
import com.skybridge.compass.shared.p2p.BootstrapRekeyCause
import com.skybridge.compass.shared.p2p.DefaultBootstrapAssistedHandshake
import com.skybridge.compass.shared.p2p.DowngradePolicy
import com.skybridge.compass.shared.p2p.HandshakeFailureCategory
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
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 18: 引导通道在强制 PQC 密钥更新成功前不承载业务流量**
 *
 * **Validates: Requirements 4.2**
 *
 * 任务 9.10 的属性测试，驱动的是**生产实现** [DefaultBootstrapAssistedHandshake]
 * （`shared/src/main/kotlin/com/skybridge/compass/shared/p2p/BootstrapAssistedHandshake.kt`），
 * 不在测试内重写任何状态机逻辑。与既有示例测试 `BootstrapAssistedHandshakeTest` 互补：
 * 示例测试固定若干已知路径（happy path、rekey 超时、KEM 取不到），本文件在随机生成的
 * **策略 × 本地密钥持有情况 × 通道行为 × rekey 结果**空间上验证同一条 R4.2 不变式。
 *
 * ### 被验证的不变式（R4.2）
 * 「在该 PQC 密钥更新成功前，不在该通道上承载业务流量，且不呈现会话为已建立。」
 * 形式化为两条同时成立的断言：
 *
 * 1. **时序半部**：在整个 `bootstrapPeerKemKeys` 生命周期中，
 *    [BootstrapAssistedHandshake.canCarryBusinessTraffic] 与
 *    [BootstrapAssistedHandshake.isSessionEstablished] 在**任何**非
 *    [BootstrapHandshakeState.ESTABLISHED] 的状态下都必须为 false——包括
 *    [BootstrapHandshakeState.KEM_RETRIEVED] 与 [BootstrapHandshakeState.REKEYING_PQC]
 *    这两个「KEM 已到手但强制 rekey 尚未成功」的关键中间态。该半部由 `onStateChange`
 *    观察者在**每一次**状态迁移时刻当场断言，而不是只看终态。
 * 2. **终态半部**：仅当强制 PQC 密钥更新成功时才允许 ESTABLISHED / 承载业务流量；
 *    rekey 失败或超时时必须为 FAILED、不承载业务流量，且按 R4.12 擦除该次尝试派生的
 *    密钥材料（[BootstrapDerivedKeyMaterial] 恰好擦除一次）。
 *
 * ### 属性定义域
 * 本属性覆盖 [DowngradePolicy] 的四种 posture 与「本地是否已持有对端 KEM 公钥」的组合。
 * 注意生产语义：本地**已**持有 KEM 公钥时无需引导，直接 ESTABLISHED（不开经典通道）——
 * 这条捷径不违反 R4.2，因为 R4.2 的前提是「本地不持有对端 KEM 公钥」，故该分支单独计数
 * （`shortCircuitCases`）并按「从未进入 RETRIEVING_KEM」来断言。
 *
 * 非空真保证：每个测试在 `checkAll` 结束后断言各分支计数均 > 0 并打印计数值，避免属性
 * 以空真（vacuous truth）方式通过。
 */
class BootstrapBusinessTrafficGatePropertyTest : FunSpec({

    /** 非空 KEM 公钥包（至少一把密钥），用于「本地已持有」与「引导取回成功」两种场景。 */
    fun kemKeys(seed: Int): P2PHandshakeClient.PeerKemPublicKeys =
        P2PHandshakeClient.PeerKemPublicKeys(
            xWingPublicKey = ByteArray(32) { (seed + it).toByte() },
            mlKem768PublicKey = ByteArray(32) { (seed + it + 1).toByte() }
        )

    /**
     * 一次性经典控制通道的测试替身。生产接口 [BootstrapControlChannel] **结构上**只提供
     * `retrievePeerKemPublicKeys` / `close`，没有任何发送业务数据的方法；这里额外记录
     * close/retrieve 次数，用于断言通道在 rekey 阶段前已被拆除、不会滞留承载业务流量。
     */
    class RecordingChannel(
        private val keys: P2PHandshakeClient.PeerKemPublicKeys,
        private val failRetrieval: Boolean,
        val channelSecret: ByteArray = ByteArray(32) { 0x5A }
    ) : BootstrapControlChannel {
        var closeCount = 0
            private set
        var retrieveCount = 0
            private set

        override suspend fun retrievePeerKemPublicKeys(): P2PHandshakeClient.PeerKemPublicKeys {
            retrieveCount++
            if (failRetrieval) error("retrieval failed")
            return keys
        }

        override fun derivedKeyMaterial(): ByteArray = channelSecret

        override suspend fun close() {
            closeCount++
        }
    }

    /** 一次引导尝试的输入组合。 */
    data class Case(
        val policy: DowngradePolicy,
        val hasLocalKeys: Boolean,
        val retrievalSucceeds: Boolean,
        val bundleNonEmpty: Boolean,
        val rekeySucceeds: Boolean,
        val rekeyCause: BootstrapRekeyCause,
        val seed: Int,
        val peer: PeerRef
    )

    /**
     * posture 生成器**刻意加权**偏向 [DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED]。
     * R4.2 的定义域正是该 posture，而四种 posture 里只有它会真正走完
     * 「开经典通道 → 取 KEM → 强制 rekey」全流程；均匀采样会让 3/4 的用例在第一道
     * posture 门就被拒，使真正要验证的中间态覆盖过稀（实测均匀采样下 500 次仅约 17 次
     * 走到 REKEYING_PQC）。其余三种 posture 仍保留采样，用于锁定「非 bootstrap posture
     * 一律不开经典通道」这一半部。
     */
    val policyArb: Arb<DowngradePolicy> = Arb.element(
        listOf(
            DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            DowngradePolicy.STRICT_PQC_COMPLIANCE,
            DowngradePolicy.PREFER_PQC,
            DowngradePolicy.DEFAULT
        )
    )
    val rekeyCauseArb: Arb<BootstrapRekeyCause> = Arb.element(BootstrapRekeyCause.entries.toList())

    val caseArb: Arb<Case> = arbitrary { rs ->
        Case(
            policy = policyArb.bind(),
            hasLocalKeys = Arb.boolean().bind(),
            retrievalSucceeds = Arb.boolean().bind(),
            bundleNonEmpty = Arb.boolean().bind(),
            rekeySucceeds = Arb.boolean().bind(),
            rekeyCause = rekeyCauseArb.bind(),
            seed = Arb.int(0..255).bind(),
            peer = PeerRef("peer-${Arb.int(1..100000).bind()}")
        )
    }

    test("Property 18: 强制 PQC 密钥更新成功前，任何状态都不承载业务流量、不呈现已建立") {
        // 分支计数器（非空真保证）。
        var establishedViaRekey = 0
        var failedRekey = 0
        var failedKemUnavailable = 0
        var shortCircuitCases = 0
        var deniedByPolicy = 0
        // 关键中间态是否真的被生成到（KEM 已到手但 rekey 未成功）。
        var sawKemRetrievedState = 0
        var sawRekeyingState = 0

        checkAll(500, caseArb) { case ->
            val channel = RecordingChannel(
                keys = if (case.bundleNonEmpty) {
                    kemKeys(case.seed)
                } else {
                    P2PHandshakeClient.PeerKemPublicKeys()
                },
                failRetrieval = !case.retrievalSucceeds
            )

            // 逐次状态迁移的当场断言容器。
            val observedStates = mutableListOf<BootstrapHandshakeState>()
            var violatedGate = false

            lateinit var flow: DefaultBootstrapAssistedHandshake
            flow = DefaultBootstrapAssistedHandshake(
                policy = case.policy,
                localPeerKemLookup = { if (case.hasLocalKeys) kemKeys(case.seed) else null },
                openControlChannel = { channel },
                forcePqcRekey = { _, _ ->
                    // rekey 进行中：此刻必须仍未承载业务流量、未呈现已建立（R4.2 的核心时刻）。
                    if (flow.canCarryBusinessTraffic || flow.isSessionEstablished) violatedGate = true
                    if (case.rekeySucceeds) {
                        PqcRekeyResult.Success
                    } else {
                        PqcRekeyResult.Failed(cause = case.rekeyCause, detail = "property-driven failure")
                    }
                },
                onStateChange = { state ->
                    observedStates += state
                    // **不变式 1（时序半部）**：非 ESTABLISHED 的任何状态都不得承载业务流量、
                    // 不得呈现为已建立。在每一次迁移当场求值。
                    val gateOpen = flow.canCarryBusinessTraffic || flow.isSessionEstablished
                    if (state != BootstrapHandshakeState.ESTABLISHED && gateOpen) violatedGate = true
                }
            )

            val result = flow.bootstrapPeerKemKeys(case.peer)

            // 时序不变式必须始终成立。
            violatedGate shouldBe false

            // 中间态计数（证明关键状态确实被走到，而非属性空转）。
            if (observedStates.contains(BootstrapHandshakeState.KEM_RETRIEVED)) sawKemRetrievedState++
            if (observedStates.contains(BootstrapHandshakeState.REKEYING_PQC)) sawRekeyingState++

            // **不变式 2（终态半部）**：按实际路径分类断言。
            //
            // 分支顺序刻意与生产实现的判定优先级一致：`bootstrapPeerKemKeys` 先查 posture
            // （`policy.allowsBootstrapControlChannel()`），**再**查本地是否已持有对端 KEM 公钥。
            // 因此在非 bootstrap-assisted posture 下，即便本地已持有密钥，该流程也返回
            // 「对端 KEM 公钥不可得」——这不违反 R4.2（依然 FAILED、依然不承载业务流量），
            // 只是该流程的定义域本就是「bootstrap-assisted posture + 本地无 KEM 公钥」，
            // 其余 posture 由常规 PQC 握手路径处理，不会走到这里。
            when {
                // 策略不允许开经典引导通道 → R4.11 分类为「对端 KEM 公钥不可得」，
                // 且从不打开通道、从不承载业务流量。
                !case.policy.allowsBootstrapControlChannel() -> {
                    deniedByPolicy++
                    result.isFailure shouldBe true
                    flow.state shouldBe BootstrapHandshakeState.FAILED
                    flow.canCarryBusinessTraffic shouldBe false
                    flow.isSessionEstablished shouldBe false
                    val ex = result.exceptionOrNull() as BootstrapHandshakeException
                    ex.failure.category shouldBe
                        HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE
                    // 策略禁止时一律不得打开经典通道（无论本地是否已持有密钥）。
                    channel.retrieveCount shouldBe 0
                    channel.closeCount shouldBe 0
                    observedStates.contains(BootstrapHandshakeState.OPENING_CONTROL_CHANNEL) shouldBe false
                    // R4.11：必须给出可执行的配对提示。
                    (ex.pairingHint != null) shouldBe true
                }

                // 本地已持有 KEM 公钥：无需引导（定义域说明见类文档），直接可用。
                case.hasLocalKeys -> {
                    shortCircuitCases++
                    result.isSuccess shouldBe true
                    flow.state shouldBe BootstrapHandshakeState.ESTABLISHED
                    // 从未进入引导取回阶段，也就从未存在「经典通道承载业务流量」的窗口。
                    observedStates.contains(BootstrapHandshakeState.RETRIEVING_KEM) shouldBe false
                    channel.retrieveCount shouldBe 0
                }

                // 引导取回失败或包为空 → R4.11「对端 KEM 公钥不可得」，绝不承载业务流量。
                !case.retrievalSucceeds || !case.bundleNonEmpty -> {
                    failedKemUnavailable++
                    result.isFailure shouldBe true
                    flow.state shouldBe BootstrapHandshakeState.FAILED
                    flow.canCarryBusinessTraffic shouldBe false
                    flow.isSessionEstablished shouldBe false
                    val ex = result.exceptionOrNull() as BootstrapHandshakeException
                    ex.failure.category shouldBe
                        HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE
                    // 一次性通道必须已被拆除，不得滞留。
                    (channel.closeCount >= 1) shouldBe true
                    // 从未进入 rekey 阶段（KEM 都没拿到）。
                    observedStates.contains(BootstrapHandshakeState.REKEYING_PQC) shouldBe false
                }

                // KEM 取回成功但强制 rekey 失败 → R4.12：FAILED、不承载业务流量。
                !case.rekeySucceeds -> {
                    failedRekey++
                    result.isFailure shouldBe true
                    flow.state shouldBe BootstrapHandshakeState.FAILED
                    flow.canCarryBusinessTraffic shouldBe false
                    flow.isSessionEstablished shouldBe false
                    // 经典通道在进入 rekey 前就已关闭，故失败时不存在可承载业务流量的通道。
                    (channel.closeCount >= 1) shouldBe true
                    // R4.12 的分类恰为两项之一，且与实际 cause 一致。
                    val ex = result.exceptionOrNull() as BootstrapHandshakeException
                    val expected = when (case.rekeyCause) {
                        BootstrapRekeyCause.LOCAL_PQC_UNAVAILABLE ->
                            HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE
                        BootstrapRekeyCause.SUITE_INTERSECTION_EMPTY ->
                            HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY
                    }
                    ex.failure.category shouldBe expected
                    // 关键：rekey 未成功前一定经过了「KEM 已到手」的中间态，而那时门必须是关的
                    // （已由 violatedGate 逐迁移断言覆盖）。
                    observedStates.contains(BootstrapHandshakeState.KEM_RETRIEVED) shouldBe true
                }

                // 唯一允许承载业务流量的路径：强制 PQC 密钥更新成功。
                else -> {
                    establishedViaRekey++
                    result.isSuccess shouldBe true
                    flow.state shouldBe BootstrapHandshakeState.ESTABLISHED
                    flow.canCarryBusinessTraffic shouldBe true
                    flow.isSessionEstablished shouldBe true
                    // 必须真的走过 KEM_RETRIEVED → REKEYING_PQC → ESTABLISHED 的顺序。
                    val kemIdx = observedStates.indexOf(BootstrapHandshakeState.KEM_RETRIEVED)
                    val rekeyIdx = observedStates.indexOf(BootstrapHandshakeState.REKEYING_PQC)
                    val estIdx = observedStates.indexOf(BootstrapHandshakeState.ESTABLISHED)
                    (kemIdx in 0 until rekeyIdx) shouldBe true
                    (rekeyIdx in 0 until estIdx) shouldBe true
                    // 一次性经典通道在建立前已拆除。
                    (channel.closeCount >= 1) shouldBe true
                }
            }
        }

        println(
            "Property 18 counters: establishedViaRekey=$establishedViaRekey, " +
                "failedRekey=$failedRekey, failedKemUnavailable=$failedKemUnavailable, " +
                "shortCircuit=$shortCircuitCases, deniedByPolicy=$deniedByPolicy, " +
                "sawKemRetrieved=$sawKemRetrievedState, sawRekeying=$sawRekeyingState"
        )

        // 非空真保证：每条有意义的分支都被真正生成到。
        (establishedViaRekey > 0) shouldBe true
        (failedRekey > 0) shouldBe true
        (failedKemUnavailable > 0) shouldBe true
        (shortCircuitCases > 0) shouldBe true
        (deniedByPolicy > 0) shouldBe true
        // 关键中间态（KEM 已到手但 rekey 未成功）确实被覆盖，属性非空转。
        (sawKemRetrievedState > 0) shouldBe true
        (sawRekeyingState > 0) shouldBe true
    }

    test("Property 18: rekey 未成功的每条终止路径都擦除该次尝试派生的密钥材料（R4.12）") {
        var wipedOnRekeyFailure = 0
        var notWipedOnSuccess = 0

        val wipeCaseArb: Arb<Triple<Boolean, BootstrapRekeyCause, Int>> = arbitrary {
            Triple(Arb.boolean().bind(), rekeyCauseArb.bind(), Arb.int(0..255).bind())
        }

        checkAll(300, wipeCaseArb) { (rekeySucceeds, rekeyCause, seed) ->
            val channelSecret = ByteArray(32) { (seed + it + 1).toByte() }
            // 生成器自检：秘密初始非全零，否则「已擦除」断言会空真通过。
            channelSecret.any { it != 0.toByte() } shouldBe true

            val channel = RecordingChannel(
                keys = kemKeys(seed),
                failRetrieval = false,
                channelSecret = channelSecret
            )

            var wipeCallbacks = 0
            val flow = DefaultBootstrapAssistedHandshake(
                policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
                localPeerKemLookup = { null },
                openControlChannel = { channel },
                forcePqcRekey = { _, _ ->
                    if (rekeySucceeds) {
                        PqcRekeyResult.Success
                    } else {
                        PqcRekeyResult.Failed(cause = rekeyCause, detail = "wipe-path")
                    }
                },
                onKeyMaterialWiped = { wipeCallbacks++ }
            )

            flow.bootstrapPeerKemKeys(PeerRef("peer-wipe-$seed"))

            if (rekeySucceeds) {
                notWipedOnSuccess++
                flow.state shouldBe BootstrapHandshakeState.ESTABLISHED
                // 成功路径不做失败擦除（引导通道秘密被已建立的 PQC 会话取代）。
                wipeCallbacks shouldBe 0
            } else {
                wipedOnRekeyFailure++
                flow.state shouldBe BootstrapHandshakeState.FAILED
                flow.canCarryBusinessTraffic shouldBe false
                // R4.12：恰好擦除一次（幂等，但对本次尝试只回调一次）。
                wipeCallbacks shouldBe 1
                // 通道派生的秘密确已就地置零。
                channelSecret.all { it == 0.toByte() } shouldBe true
            }
        }

        println(
            "Property 18 (wipe) counters: wipedOnRekeyFailure=$wipedOnRekeyFailure, " +
                "notWipedOnSuccess=$notWipedOnSuccess"
        )

        (wipedOnRekeyFailure > 0) shouldBe true
        (notWipedOnSuccess > 0) shouldBe true
    }
})
