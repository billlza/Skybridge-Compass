package com.skybridge.compass.shared.p2p

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.element
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 19: 协商套件属于双方声明集合的交集**
 *
 * **Validates: Requirements 4.3**
 *
 * 任务 9.11 的属性测试，驱动**生产协商实现** `P2PHandshakeClient.resolveSuitePlan`
 * （经同模块的 `resolveSuitePlanForTesting` 缝隙）。
 *
 * ### 为什么这个文件在 `:shared` 而不是 `:core`
 * `resolveSuitePlanForTesting` 与 `ResolvedSuitePlan` 都是 **`internal` to `:shared`**，
 * 从 `:core` 的测试源集**结构上不可达**（Kotlin `internal` = 模块可见）。真正的协商逻辑
 * `resolveSuitePlan` 本身是 `private`。要驱动生产入口而不是重写一份协商逻辑，本测试必须
 * 与它的示例测试 [SuiteIntersectionNegotiationTest] 同模块并列。其余六条属性（18、20–24）
 * 都在 `:core`。
 *
 * ### 被验证的不变式（R4.3）
 * 「协商出的密码套件同时属于两端各自声明的套件集合；交集为空则拒绝建立会话并把失败原因
 * 分类记为『套件协商无交集』。」拆成两个互补半部：
 *
 * 1. **成员性半部**：协商成功时，返回的 `selectedSuite` 必须落在**独立计算**的双方交集内。
 *    交集判据由生成器侧的输入直接推导（本端 runtime 能力 × 对端声明的 KEM 公钥），
 *    **不复用**被测代码的任何选择逻辑——否则就是用实现验证实现。
 * 2. **空交集半部**：交集为空（或交集非空但无成员通过策略约束）时，必须抛出
 *    [HandshakeNegotiationException] 且分类恰为
 *    [HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY]，绝不返回任何套件。
 *
 * 另外锁定**最高优先级选择**：协商结果必须是交集中策略允许的最高 rank 层级
 * （Q_PERIAPT > X_WING > PQC > CLASSIC），使属性不止于"落在交集里"这一弱断言。
 *
 * ### 属性定义域
 * - `qPeriaptExplicit`（`minimumTierRaw = qPeriapt`）时生产代码会先做
 *   `QPeriaptPlatformPolicy.requireLocalAndroidSupported(platformVersion)` 的平台门控，
 *   平台不满足会抛出与套件交集无关的异常。本测试固定使用受支持的平台串，把该门控排除在
 *   定义域外，专注验证交集语义本身。
 * - `allowClassicBootstrapForTrustedPeer = true` 是 R4.2 引导通道的专用旁路（返回 CLASSIC
 *   而不做交集判定），与 R4.3 的交集语义不是同一条规则，故固定为 false；该旁路由
 *   Property 18 与既有示例测试覆盖。
 *
 * 非空真保证：每个测试在 `checkAll` 结束后断言各分支计数均 > 0 并打印计数值。
 */
class SuiteIntersectionNegotiationPropertyTest : FunSpec({

    /** 与既有示例测试一致的受支持平台串（把 QPeriapt 平台门控排除在定义域外）。 */
    val supportedPlatform = "Android 17 (API 37)"

    /** 本端 runtime 能力与对端声明集合的一次组合。 */
    data class Case(
        val liboqsAvailable: Boolean,
        val xWingAvailable: Boolean,
        val qPeriaptAvailable: Boolean,
        val peerQPeriapt: Boolean,
        val peerXWing: Boolean,
        val peerMlKem: Boolean,
        val minimumTierRaw: String,
        val requirePqc: Boolean,
        val allowClassicFallback: Boolean
    )

    val minimumTierArb: Arb<String> = Arb.element(
        listOf(P2PQPeriaptKem.MINIMUM_TIER_RAW, "nativePQC", "liboqsPQC", "classic")
    )

    val caseArb: Arb<Case> = arbitrary {
        Case(
            liboqsAvailable = Arb.boolean().bind(),
            xWingAvailable = Arb.boolean().bind(),
            qPeriaptAvailable = Arb.boolean().bind(),
            peerQPeriapt = Arb.boolean().bind(),
            peerXWing = Arb.boolean().bind(),
            peerMlKem = Arb.boolean().bind(),
            minimumTierRaw = minimumTierArb.bind(),
            requirePqc = Arb.boolean().bind(),
            allowClassicFallback = Arb.boolean().bind()
        )
    }

    fun peerKeys(case: Case): P2PHandshakeClient.PeerKemPublicKeys =
        P2PHandshakeClient.PeerKemPublicKeys(
            qPeriaptPublicKey = if (case.peerQPeriapt) ByteArray(4) { 0x10 } else null,
            xWingPublicKey = if (case.peerXWing) ByteArray(4) { 0x11 } else null,
            mlKem768PublicKey = if (case.peerMlKem) ByteArray(4) { 0x12 } else null
        )

    fun policyOf(case: Case) = P2PHandshakePolicy(
        requirePqc = case.requirePqc,
        allowClassicFallback = case.allowClassicFallback,
        minimumTierRaw = case.minimumTierRaw,
        requireSecureEnclavePoP = false
    )

    /** 层级 rank，与生产 `SuiteTier.rank` 同序（CLASSIC 0 < PQC 1 < X_WING 2 < Q_PERIAPT 3）。 */
    val rankOf = mapOf("CLASSIC" to 0, "PQC" to 1, "X_WING" to 2, "Q_PERIAPT" to 3)

    /**
     * 复现「最低层级」这一**输入量**（不是抄选择逻辑）：
     * `parseMinimumTier` 把 `nativePQC` 读成 X_WING(2)、`liboqsPQC` 读成 PQC(1)；
     * 且当请求为 X_WING、本端有 liboqs、而（本端无 xWing 能力或对端只声明 ML-KEM）时，
     * 最低层级放宽到 PQC(1)。
     */
    fun effectiveMinRank(case: Case): Int {
        val requested = when (case.minimumTierRaw) {
            P2PQPeriaptKem.MINIMUM_TIER_RAW -> 3
            "nativePQC" -> 2
            "liboqsPQC" -> 1
            "classic" -> 0
            else -> error("unmapped minimum tier ${case.minimumTierRaw}")
        }
        val peerSupportsMlKemOnly = case.peerMlKem && !case.peerXWing
        val relaxes = requested == 2 &&
            case.liboqsAvailable &&
            (!case.xWingAvailable || peerSupportsMlKemOnly)
        return if (relaxes) 1 else requested
    }

    // region 独立的交集判据（不引用被测选择逻辑）

    /**
     * 本端声明集合：由 runtime 能力推导。CLASSIC 永远在本端声明集合内（双方总能说 x25519）。
     * 这是生成器侧的独立推导，与被测代码的 `tierMutuallySupported` 各自成立。
     */
    fun localDeclared(case: Case): Set<String> = buildSet {
        if (case.qPeriaptAvailable) add("Q_PERIAPT")
        if (case.xWingAvailable) add("X_WING")
        if (case.liboqsAvailable) add("PQC")
        add("CLASSIC")
    }

    /** 对端声明集合：由对端提供的 KEM 公钥推导；CLASSIC 同理恒在集合内。 */
    fun peerDeclared(case: Case): Set<String> = buildSet {
        if (case.peerQPeriapt) add("Q_PERIAPT")
        if (case.peerXWing) add("X_WING")
        if (case.peerMlKem) add("PQC")
        add("CLASSIC")
    }

    /**
     * 套件 → 层级名的映射（仅用于把被测返回值投影到层级空间做成员性判定）。
     *
     * [P2PCryptoSuite.MLKEM_768_FS_COMPAT] 与 [P2PCryptoSuite.P256] 刻意映射为 `error`：
     * 前者按 [P2PCryptoSuite.isNegotiable] 本就不可协商（仅兼容解析路径），后者不属于本端
     * 协商层级序。若协商竟返回这两者，属性应当**失败**而不是被静默归类——这也是一条断言。
     */
    fun tierNameOf(suite: P2PCryptoSuite): String = when (suite) {
        P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND -> "Q_PERIAPT"
        P2PCryptoSuite.X_WING -> "X_WING"
        P2PCryptoSuite.MLKEM_768 -> "PQC"
        P2PCryptoSuite.X25519 -> "CLASSIC"
        P2PCryptoSuite.MLKEM_768_FS_COMPAT ->
            error("negotiation returned a non-negotiable compatibility suite: $suite")
        P2PCryptoSuite.P256 ->
            error("negotiation returned a suite outside the local tier ordering: $suite")
    }

    // endregion

    test("Property 19: 协商成功时所选套件必落在双方声明集合的交集内") {
        var negotiated = 0
        var rejectedEmptyIntersection = 0
        // 各层级作为协商结果被真正选到的次数（证明不是只有 CLASSIC 一条路被走）。
        val selectedTierCounts = mutableMapOf<String, Int>()

        checkAll(1000, caseArb) { case ->
            val intersection = localDeclared(case) intersect peerDeclared(case)
            // 生成器自检：CLASSIC 恒在交集内，故交集永不为空——这正是生产注释所述的性质。
            intersection.contains("CLASSIC") shouldBe true

            val outcome = runCatching {
                P2PHandshakeClient.resolveSuitePlanForTesting(
                    platformVersion = supportedPlatform,
                    liboqsAvailable = case.liboqsAvailable,
                    xWingAvailable = case.xWingAvailable,
                    qPeriaptAvailable = case.qPeriaptAvailable,
                    peerKemPublicKeys = peerKeys(case),
                    policy = policyOf(case),
                    allowClassicBootstrapForTrustedPeer = false
                )
            }

            outcome.fold(
                onSuccess = { plan ->
                    negotiated++
                    val tier = tierNameOf(plan.selectedSuite)
                    selectedTierCounts[tier] = (selectedTierCounts[tier] ?: 0) + 1

                    // **不变式（成员性半部）**：所选套件必属于双方声明集合的交集。
                    intersection.contains(tier) shouldBe true

                    // 加强断言：所选层级必须是交集中**策略允许**的最高 rank。
                    // 策略允许性判据由 R4.3 的策略字段独立推导：
                    //  - 非 CLASSIC 层级须满足 rank >= 最低层级 rank；
                    //  - CLASSIC 额外要求 !requirePqc && allowClassicFallback。
                    val qPeriaptExplicit = case.minimumTierRaw == P2PQPeriaptKem.MINIMUM_TIER_RAW
                    val minRank = effectiveMinRank(case)

                    val candidateTiers =
                        if (qPeriaptExplicit) listOf("Q_PERIAPT") else listOf("X_WING", "PQC", "CLASSIC")
                    val permitted = candidateTiers.filter { it in intersection }.filter { t ->
                        val r = rankOf.getValue(t)
                        if (t == "CLASSIC") {
                            !case.requirePqc && case.allowClassicFallback && r >= minRank
                        } else {
                            r >= minRank
                        }
                    }
                    // 被选中的层级正是候选序（优先级序）里第一个通过策略的成员。
                    permitted.first() shouldBe tier

                    // usedClassicFallback 与"选中了 CLASSIC 且原本还有更高层级可选"一致。
                    if (tier == "CLASSIC" && candidateTiers.any { it != "CLASSIC" }) {
                        plan.usedClassicFallback shouldBe true
                    }
                },
                onFailure = { t ->
                    rejectedEmptyIntersection++
                    // **不变式（空交集半部）**：拒绝必须以 SUITE_INTERSECTION_EMPTY 分类呈现。
                    val ex = t as HandshakeNegotiationException
                    ex.category shouldBe HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY
                    // 契约保持：仍是 IllegalStateException 子类（不削弱既有调用方约定）。
                    // 用运行时可赋值性判定而非 `is`——后者在此处是编译期恒真的同义反复。
                    IllegalStateException::class.java.isAssignableFrom(ex.javaClass) shouldBe true
                }
            )
        }

        println(
            "Property 19 counters: negotiated=$negotiated, " +
                "rejectedEmptyIntersection=$rejectedEmptyIntersection, " +
                "selectedTiers=$selectedTierCounts"
        )

        // 非空真保证：协商成功与被拒两条分支都被走到。
        (negotiated > 0) shouldBe true
        (rejectedEmptyIntersection > 0) shouldBe true
        // 且协商结果不是恒定一个层级——至少覆盖到 CLASSIC 之外的层级。
        (selectedTierCounts.size > 1) shouldBe true
        (selectedTierCounts.keys.any { it != "CLASSIC" }) shouldBe true
    }

    test("Property 19: 对端未声明任一 PQC 层级且策略禁止经典回退时，恒以无交集分类拒绝") {
        // 该测试把定义域收窄到"交集实质为 {CLASSIC}"的子空间：对端不提供任何 PQC KEM 公钥。
        // 此时若策略要求 PQC 且不允许经典回退，交集里没有任何成员能通过策略 → 必须拒绝。
        var rejected = 0
        var acceptedClassic = 0

        val narrowedArb: Arb<Case> = arbitrary {
            Case(
                liboqsAvailable = Arb.boolean().bind(),
                xWingAvailable = Arb.boolean().bind(),
                qPeriaptAvailable = Arb.boolean().bind(),
                // 对端声明集合固定为 {CLASSIC}。
                peerQPeriapt = false,
                peerXWing = false,
                peerMlKem = false,
                minimumTierRaw = Arb.element(listOf("nativePQC", "liboqsPQC", "classic")).bind(),
                requirePqc = Arb.boolean().bind(),
                allowClassicFallback = Arb.boolean().bind()
            )
        }

        checkAll(500, narrowedArb) { case ->
            val intersection = localDeclared(case) intersect peerDeclared(case)
            // 生成器自检：交集确实收窄为 {CLASSIC}。
            intersection shouldBe setOf("CLASSIC")

            val outcome = runCatching {
                P2PHandshakeClient.resolveSuitePlanForTesting(
                    platformVersion = supportedPlatform,
                    liboqsAvailable = case.liboqsAvailable,
                    xWingAvailable = case.xWingAvailable,
                    qPeriaptAvailable = case.qPeriaptAvailable,
                    peerKemPublicKeys = peerKeys(case),
                    policy = policyOf(case),
                    allowClassicBootstrapForTrustedPeer = false
                )
            }

            // CLASSIC 是交集唯一成员，它获得策略许可需三条同时成立：不强制 PQC、允许经典
            // 回退，且最低层级已降到 CLASSIC(0)——最低层级高于 CLASSIC 时它同样被策略挡掉。
            val classicPermitted =
                !case.requirePqc && case.allowClassicFallback && effectiveMinRank(case) == 0
            if (classicPermitted) {
                acceptedClassic++
                // 交集里唯一成员 CLASSIC 获得策略许可 → 必须协商出经典套件。
                val plan = outcome.getOrThrow()
                plan.selectedSuite shouldBe P2PCryptoSuite.X25519
                tierNameOf(plan.selectedSuite) shouldBe "CLASSIC"
                intersection.contains(tierNameOf(plan.selectedSuite)) shouldBe true
            } else {
                rejected++
                // 交集非空但无成员通过策略 → R4.3 要求以「套件协商无交集」终止。
                val ex = outcome.exceptionOrNull() as HandshakeNegotiationException
                ex.category shouldBe HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY
            }
        }

        println(
            "Property 19 (classic-only intersection) counters: " +
                "rejected=$rejected, acceptedClassic=$acceptedClassic"
        )

        (rejected > 0) shouldBe true
        (acceptedClassic > 0) shouldBe true
    }
})
