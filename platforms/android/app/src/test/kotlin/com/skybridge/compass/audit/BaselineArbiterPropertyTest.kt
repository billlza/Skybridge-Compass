package com.skybridge.compass.audit

import io.kotest.common.ExperimentalKotest
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.PropTestConfig
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.checkAll
import java.time.LocalDate

/**
 * **Feature: cross-platform-parity-audit, Property 52: 文档基线冲突裁决顺序**
 *
 * **Validates: Requirements 2.8, 2.9**
 *
 * 审计工具代码的属性测试（任务 5.8）。位于 `:app` 的 `test` 源集，不随生产应用打包
 * （遵守 G3：仅 Kotlin；不改动 Apple 源码树）。与 [BaselineArbiterTest] 的示例测试**互补**：
 * 示例测试固定真实的 B1..B6 场景（含 R2.10 缺失降级），本文件在随机生成的冲突上校验同一批
 * 不变式，每条属性不少于 100 次迭代。
 *
 * 被测规则是 `audit-report.md` §3.2 的五级确定性级联，六条断言逐级对应：
 *
 *  1. **代码证据优先**——存在可定位 `文件:行` 代码证据时定案级别恒为
 *     [BaselineAdjudicationBasis.CODE_EVIDENCE]，且**从不进入文档裁决顺序**
 *     （[BaselineVerdict.evaluatedLevels] 只含该一级）。
 *  2. **层级优先（R2.8）**——无代码证据时 [BaselineTier.PRIORITY_ADR] 恒胜
 *     [BaselineTier.SECONDARY]，且被否的次级条目恒 `markedHistorical == true`。
 *  3. **互冲取新（R2.9）**——两份日期不同的 ADR 之间恒取日期较新者。
 *  4. **同日期主题区分（R2.9）**——B1/B3 同为 2026-07-23 且主题可区分时，主题归属方胜且
 *     `unverifiedConjecture == false`。
 *  5. **同日期主题不可辨（R2.9 兜底）**——恒为 [BaselineAdjudicationBasis.PENDING_APPLE_DECISION]
 *     且 `unverifiedConjecture == true`。
 *  6. **确定性 / 全序**——对同一冲突的各方任意置换后裁决，得到**逐字段相等**的
 *     [BaselineVerdict]；选出胜者时该胜者恒为 [BaselineArbiter.ARBITRATION_ORDER] 的最小元。
 *
 * **定义域约束（显式记录，非削弱生成器）**：
 * - 冲突各方的文档编号两两不同（[BaselineConflict] 的构造前置条件）——同一份文档不与自身冲突。
 * - 可定位性由注入的确定性 [SourceLocator] 判定（路径以 `live/` 起始即可定位），与
 *   [ConflictReconcilerPropertyTest] 同一约定，使反例可复现且「足以判定 / 不足以判定」两分支
 *   都被稳定覆盖；`gone/` 前缀的证据不可定位，据 R2.3 不足以判定，必须退回文档裁决顺序。
 * - 主题键取自各文档 [BaselineDoc.topics]，另含一个不属于任何文档的 `unknown-topic`，
 *   使「归属一方 / 归属双方 / 不归属任何一方」三种主题形态都可达。
 *
 * **随机种子**：由 `BASELINE_ARBITER_PBT_SEED` 环境变量指定，未指定时随机取值并**打印到测试输出**，
 * 失败可用同一种子复现；发现的反例应作为固定回归用例补入 [BaselineArbiterTest]。
 *
 * [ExperimentalKotest] opt-in 仅因 `PropTestConfig.iterations` 在 Kotest 6.2 标注为实验性——
 * 显式指定迭代次数是任务 5.8「不少于 100 次迭代」的要求，故在此 opt-in 而非改用默认迭代数。
 */
@OptIn(ExperimentalKotest::class)
class BaselineArbiterPropertyTest : FunSpec({

    // region 随机种子（写入测试输出以便复现）

    val seed: Long = System.getenv("BASELINE_ARBITER_PBT_SEED")?.toLongOrNull()
        ?: java.util.Random().nextLong()

    beforeSpec {
        println("[Property 52] BaselineArbiter PBT effective seed = $seed")
        println("[Property 52] reproduce with: BASELINE_ARBITER_PBT_SEED=$seed ./gradlew :app:testDebugUnitTest --tests '*BaselineArbiterPropertyTest*'")
    }

    /** 每条属性至少 100 次迭代（任务 5.8 要求），并固定种子以便复现。 */
    val config = PropTestConfig(seed = seed, iterations = 200)

    // endregion

    // region 生成器与确定性 SourceLocator

    /** 注入的确定性可定位性判定：`live/` 前缀即视为在当前工作副本可定位。 */
    val locator = SourceLocator { ref -> ref.file.startsWith("live/") }
    val arbiter = BaselineArbiter(locator)

    val liveFiles = listOf(
        "live/shared/src/main/kotlin/CrossPlatformFileTransferProtocol.kt",
        "live/device-discovery/src/main/kotlin/AndroidLocalNodeBootstrap.kt",
        "live/core/src/main/kotlin/P2PHPKESealedBox.kt",
    )
    val staleFiles = listOf(
        "gone/app/src/main/kotlin/Deleted.kt",
        "gone/core/src/main/kotlin/Vanished.kt",
    )

    val liveRefArb: Arb<SourceRef> =
        Arb.bind(Arb.element(liveFiles), Arb.int(1..300)) { f, l -> SourceRef(f, l) }
    val staleRefArb: Arb<SourceRef> =
        Arb.bind(Arb.element(staleFiles), Arb.int(1..300)) { f, l -> SourceRef(f, l) }

    val conclusionDetails = listOf(
        "该面以自描述前缀编码",
        "该面以固定长度前缀编码",
        "服务类型为 _skybridge._tcp",
        "服务类型为 _skybridge-transfer._tcp",
        "降级策略为失败不降级",
    )

    val subjectIdentifiers = listOf(
        "HPKE 密封盒线格式",
        "Bonjour 服务类型集合",
        "握手协议版本协商",
        "Compose 分组容器层级",
    )

    fun subjectArb(): Arb<ContestedSubject> = arbitrary {
        ContestedSubject(
            kind = Arb.element(SubjectKind.entries).bind(),
            identifier = Arb.element(subjectIdentifiers).bind() + "#" + Arb.int(0..999).bind(),
        )
    }

    /** 由一份文档构造一方，结论文本随机但非空白。 */
    fun sideArb(doc: BaselineDoc): Arb<BaselineSide> = arbitrary {
        BaselineSide(
            doc = doc,
            conclusion = "${doc.id} 主张：${Arb.element(conclusionDetails).bind()}",
        )
    }

    /** 全部主题键 + 一个不属于任何文档的键（使「不归属任何一方」可达）。 */
    val allTopics: List<String> =
        StandardBaselines.all.flatMap { it.topics }.distinct() + "unknown-topic"

    /** 主题形态：具体主题键，或 null（主题归属无法区分的一种形态）。 */
    val topicChoices: List<String?> = allTopics + listOf(null)
    val topicArb: Arb<String?> = Arb.element(topicChoices)

    /** 任取两份**不同**文档构成的一对（编号两两不同是 [BaselineConflict] 的前置条件）。 */
    val docPairArb: Arb<Pair<BaselineDoc, BaselineDoc>> = arbitrary {
        val first = Arb.element(StandardBaselines.all).bind()
        val second = Arb.element(StandardBaselines.all.filter { it.id != first.id }).bind()
        first to second
    }

    /** 任意冲突：2..3 方、任意主题、代码证据可为「无 / 可定位 / 不可定位」。 */
    val conflictArb: Arb<BaselineConflict> = arbitrary {
        val docs = Arb.list(Arb.element(StandardBaselines.all), 2..3).bind()
            .distinctBy { it.id }
        // distinctBy 可能只剩一份 → 补一份不同编号的文档，保证 ≥2 方。
        val fixedDocs = if (docs.size >= 2) {
            docs
        } else {
            docs + StandardBaselines.all.first { it.id != docs.single().id }
        }
        val sides = fixedDocs.map { sideArb(it).bind() }
        val evidenceShape = Arb.int(0..2).bind()
        val citation = when (evidenceShape) {
            // 无代码证据 → 走文档裁决顺序。
            0 -> null
            // 可定位证据 → 足以判定（第 1 级定案）。
            1 -> CodeEvidenceCitation(
                refs = Arb.list(liveRefArb, 1..3).bind(),
                supportsBaselineId = Arb.element(sides.map { it.doc.id }).bind(),
            )
            // 仅不可定位证据 → 不足以判定，必须退回文档裁决顺序（R2.3）。
            else -> CodeEvidenceCitation(
                refs = Arb.list(staleRefArb, 1..2).bind(),
                supportsBaselineId = Arb.element(sides.map { it.doc.id }).bind(),
            )
        }
        BaselineConflict(
            subject = subjectArb().bind(),
            sides = sides,
            contestedTopic = topicArb.bind(),
            codeEvidence = citation,
        )
    }

    // endregion

    // region 断言 1：代码证据优先，且不进入文档裁决顺序

    test("Property 52 (1/6): 存在可定位代码证据时恒由代码证据定案且不进入文档裁决顺序") {
        var sawPriorityLoserBackedByCode = 0
        var sawStaleEvidenceFallThrough = 0

        checkAll(config, conflictArb) { conflict ->
            val verdict = arbiter.arbitrate(conflict)
            val citation = conflict.codeEvidence
            val locatable = citation != null && citation.refs.any(locator::isLocatable)

            if (locatable) {
                verdict.basis shouldBe BaselineAdjudicationBasis.CODE_EVIDENCE
                // 「不进入文档裁决顺序」：只评估过第 1 级。
                verdict.evaluatedLevels shouldBe listOf(BaselineAdjudicationBasis.CODE_EVIDENCE)
                verdict.winningBaseline?.id shouldBe citation.supportsBaselineId
                verdict.pendingAppleDecision shouldBe false
                // 代码证据定案时，即便胜方是次级文档，优先级 ADR 也会被否——记录该分支已被覆盖。
                if (verdict.winningBaseline?.tier == BaselineTier.SECONDARY &&
                    verdict.defeatedSides.any { it.doc.tier == BaselineTier.PRIORITY_ADR }
                ) {
                    sawPriorityLoserBackedByCode++
                }
            } else {
                // 无证据或仅不可定位证据（R2.3：不足以判定）⇒ 必须退回文档裁决顺序。
                (verdict.basis != BaselineAdjudicationBasis.CODE_EVIDENCE) shouldBe true
                verdict.evaluatedLevels.first() shouldBe BaselineAdjudicationBasis.CODE_EVIDENCE
                (verdict.evaluatedLevels.size >= 2) shouldBe true
                if (citation != null) sawStaleEvidenceFallThrough++
            }
        }

        // 非退化性：两个关键分支都被真正生成过。
        (sawPriorityLoserBackedByCode > 0) shouldBe true
        (sawStaleEvidenceFallThrough > 0) shouldBe true
    }

    // endregion

    // region 断言 2：层级优先（R2.8）+ 被否次级条目标记历史内容

    test("Property 52 (2/6): 无代码证据时优先级 ADR 恒胜次级文档，被否次级条目恒标记历史内容") {
        // 一方取优先级 ADR、另一方取次级文档，且不带代码证据。
        val mixedTierConflictArb: Arb<BaselineConflict> = arbitrary {
            val adr = Arb.element(StandardBaselines.priorityAdrs).bind()
            val secondary = Arb.element(StandardBaselines.secondaryDocs).bind()
            BaselineConflict(
                subject = subjectArb().bind(),
                sides = listOf(sideArb(adr).bind(), sideArb(secondary).bind()),
                contestedTopic = topicArb.bind(),
                codeEvidence = null,
            )
        }

        checkAll(config, mixedTierConflictArb) { conflict ->
            val verdict = arbiter.arbitrate(conflict)

            verdict.basis shouldBe BaselineAdjudicationBasis.TIER_PRIORITY
            verdict.winningBaseline?.tier shouldBe BaselineTier.PRIORITY_ADR
            // R2.8：被否的次级条目一律标记为历史内容。
            verdict.defeatedSides.size shouldBe 1
            verdict.defeatedSides.single().doc.tier shouldBe BaselineTier.SECONDARY
            verdict.defeatedSides.single().markedHistorical shouldBe true
            verdict.markedHistorical shouldBe true
            verdict.historicalBaselineIds shouldBe listOf(verdict.defeatedSides.single().doc.id)
            // 被否结论文本保留，供报告独立复核。
            verdict.defeatedConclusions.all { it.isNotBlank() } shouldBe true
            verdict.pendingAppleDecision shouldBe false
            verdict.unverifiedConjecture shouldBe false
        }
    }

    test("Property 52 (2/6 反向): 被否条目属 B4/B5/B6 时恒标记历史内容，属 ADR 时不标记") {
        checkAll(config, conflictArb) { conflict ->
            val verdict = arbiter.arbitrate(conflict)
            verdict.defeatedSides.forEach { defeated ->
                defeated.markedHistorical shouldBe (defeated.doc.tier == BaselineTier.SECONDARY)
                // 次级文档恰为报告 §3.3 登记的三份。
                if (defeated.markedHistorical) {
                    (defeated.doc.id in listOf("B4", "B5", "B6")) shouldBe true
                }
            }
        }
    }

    // endregion

    // region 断言 3：互冲取新（R2.9）

    test("Property 52 (3/6): 日期不同的两份 ADR 之间恒取日期较新者") {
        // 取两份日期不同的优先级 ADR（B1/B3 与 B2）。
        val differentDateAdrArb: Arb<BaselineConflict> = arbitrary {
            val newer = Arb.element(
                StandardBaselines.priorityAdrs.filter { it.id == "B1" || it.id == "B3" },
            ).bind()
            val older = StandardBaselines.B2_ANDROID_P2P_QPERIAPT_STACK
            BaselineConflict(
                subject = subjectArb().bind(),
                sides = listOf(sideArb(newer).bind(), sideArb(older).bind()),
                // 主题任意——第 3 级已可分，第 4 级不应被咨询。
                contestedTopic = topicArb.bind(),
                codeEvidence = null,
            )
        }

        checkAll(config, differentDateAdrArb) { conflict ->
            val verdict = arbiter.arbitrate(conflict)
            val expected = conflict.sides.maxBy { it.doc.effectiveDate ?: LocalDate.MIN }

            verdict.basis shouldBe BaselineAdjudicationBasis.NEWER_ADR
            verdict.winningBaseline?.id shouldBe expected.doc.id
            // 日期严格更新者胜。
            val winnerDate = verdict.winningBaseline?.effectiveDate
            val loserDate = verdict.defeatedSides.single().doc.effectiveDate
            (winnerDate!! > loserDate!!) shouldBe true
            // 第 3 级定案 ⇒ 未评估第 4 级。
            (BaselineAdjudicationBasis.TOPIC_OWNERSHIP in verdict.evaluatedLevels) shouldBe false
            verdict.unverifiedConjecture shouldBe false
        }
    }

    // endregion

    // region 断言 4：同日期主题区分（R2.9）

    test("Property 52 (4/6): B1 与 B3 同日期且主题可区分时主题归属方胜且非未核实推测") {
        val b1 = StandardBaselines.B1_PEER_FAMILY_PROTOCOL_LANES
        val b3 = StandardBaselines.B3_ANDROID_UI_GLASS_PARITY
        // B1 与 B3 的主题集合互不重叠，任取其中一个主题即「恰好归属一方」。
        val exclusiveTopics = (b1.topics + b3.topics).toList()

        val sameDateDistinguishableArb: Arb<BaselineConflict> = arbitrary {
            val topic = Arb.element(exclusiveTopics).bind()
            BaselineConflict(
                subject = subjectArb().bind(),
                sides = listOf(sideArb(b1).bind(), sideArb(b3).bind()),
                contestedTopic = topic,
                codeEvidence = null,
            )
        }

        checkAll(config, sameDateDistinguishableArb) { conflict ->
            val verdict = arbiter.arbitrate(conflict)
            val topic = conflict.contestedTopic!!
            val owner = if (topic in b1.topics) b1 else b3

            // 前提：两份 ADR 日期相同，主题归属可区分。
            (b1.effectiveDate == b3.effectiveDate) shouldBe true
            conflict.topicOwnershipDistinguishable shouldBe true

            verdict.basis shouldBe BaselineAdjudicationBasis.TOPIC_OWNERSHIP
            verdict.winningBaseline?.id shouldBe owner.id
            verdict.unverifiedConjecture shouldBe false
            verdict.pendingAppleDecision shouldBe false
            verdict.confidence shouldBe Confidence.VERIFIED_BY_REPO_EVIDENCE
            // 被否方是同为 ADR 的另一份 ⇒ 不标记历史内容。
            verdict.markedHistorical shouldBe false
        }
    }

    // endregion

    // region 断言 5：同日期且主题不可辨 ⇒ 待 Apple 侧决策 + 未核实推测（R2.9 兜底）

    test("Property 52 (5/6): 同日期 ADR 主题归属不可辨时恒为待 Apple 侧决策且标注未核实推测") {
        val b1 = StandardBaselines.B1_PEER_FAMILY_PROTOCOL_LANES
        val b3 = StandardBaselines.B3_ANDROID_UI_GLASS_PARITY

        // 三种「不可辨」形态：主题为 null、主题不属于任何一方、主题同属双方。
        // 前两种用真实 B1/B3；第三种需要主题重叠的同日期 ADR，故构造合成文档（真实 B1/B3 主题互斥）。
        val overlapTopic = "shared-contested-topic"
        val synthA = b1.copy(id = "BX", path = "docs/ADR-2026-07-23-SYNTHETIC-A.md", topics = setOf(overlapTopic))
        val synthB = b3.copy(id = "BY", path = "docs/ADR-2026-07-23-SYNTHETIC-B.md", topics = setOf(overlapTopic))

        val indistinguishableArb: Arb<BaselineConflict> = arbitrary {
            when (Arb.int(0..2).bind()) {
                0 -> BaselineConflict(
                    subject = subjectArb().bind(),
                    sides = listOf(sideArb(b1).bind(), sideArb(b3).bind()),
                    contestedTopic = null,
                    codeEvidence = null,
                )
                1 -> BaselineConflict(
                    subject = subjectArb().bind(),
                    sides = listOf(sideArb(b1).bind(), sideArb(b3).bind()),
                    contestedTopic = "unknown-topic",
                    codeEvidence = null,
                )
                else -> BaselineConflict(
                    subject = subjectArb().bind(),
                    sides = listOf(sideArb(synthA).bind(), sideArb(synthB).bind()),
                    contestedTopic = overlapTopic,
                    codeEvidence = null,
                )
            }
        }

        var sawNullTopic = 0
        var sawUnownedTopic = 0
        var sawDoublyOwnedTopic = 0

        checkAll(config, indistinguishableArb) { conflict ->
            val verdict = arbiter.arbitrate(conflict)

            // 前提：同日期、主题归属不可区分。
            conflict.sides.map { it.doc.effectiveDate }.distinct().size shouldBe 1
            conflict.topicOwnershipDistinguishable shouldBe false

            verdict.basis shouldBe BaselineAdjudicationBasis.PENDING_APPLE_DECISION
            verdict.unverifiedConjecture shouldBe true
            verdict.pendingAppleDecision shouldBe true
            verdict.confidence shouldBe Confidence.UNVERIFIED_SPECULATION
            // 兜底分支不选出胜者，全部待决方留档。
            verdict.winningBaseline shouldBe null
            verdict.winningConclusion shouldBe null
            verdict.defeatedSides shouldBe emptyList()
            verdict.undecidedSides.size shouldBe conflict.sides.size
            verdict.markedHistorical shouldBe false
            // 五级全部被评估过。
            verdict.evaluatedLevels shouldBe BaselineAdjudicationBasis.entries.toList()

            when {
                conflict.contestedTopic == null -> sawNullTopic++
                conflict.contestedTopic == "unknown-topic" -> sawUnownedTopic++
                else -> sawDoublyOwnedTopic++
            }
        }

        // 非退化性：三种「不可辨」形态都被真正生成过。
        (sawNullTopic > 0) shouldBe true
        (sawUnownedTopic > 0) shouldBe true
        (sawDoublyOwnedTopic > 0) shouldBe true
    }

    // endregion

    // region 断言 6：确定性 / 全序（置换不变）

    test("Property 52 (6/6): 各方任意置换后裁决结果逐字段相等，胜者恒为全序最小元") {
        checkAll(config, conflictArb, Arb.int(0..5)) { conflict, rotation ->
            val verdict = arbiter.arbitrate(conflict)

            // 置换 1：逆序。
            val reversed = arbiter.arbitrate(conflict.copy(sides = conflict.sides.reversed()))
            // 置换 2：旋转。
            val shift = rotation.mod(conflict.sides.size)
            val rotated = arbiter.arbitrate(
                conflict.copy(sides = conflict.sides.drop(shift) + conflict.sides.take(shift)),
            )

            // 逐字段相等（data class 相等即逐字段相等）。
            reversed shouldBe verdict
            rotated shouldBe verdict

            // 与 ARBITRATION_ORDER 交叉验证：选出胜者时该胜者为全序最小元。
            if (verdict.winningBaseline != null) {
                val candidates = conflict.sides.map { side ->
                    BaselineCandidate(
                        side = side,
                        backedByCodeEvidence = conflict.codeEvidence
                            ?.takeIf { it.supportsBaselineId == side.doc.id }
                            ?.refs?.any(locator::isLocatable) == true,
                        ownsContestedTopic = conflict.contestedTopic
                            ?.let { it in side.doc.topics } == true,
                    )
                }
                candidates.minWith(BaselineArbiter.ARBITRATION_ORDER).doc.id shouldBe
                    verdict.winningBaseline.id
            }

            // 幂等：同一输入重复裁决结果不变。
            arbiter.arbitrate(conflict) shouldBe verdict
        }
    }

    // endregion
})
