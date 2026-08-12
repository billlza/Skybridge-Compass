package com.skybridge.compass.audit

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.choice
import io.kotest.property.arbitrary.constant
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 51: 冲突记录条数与证据裁决**
 *
 * **Validates: Requirements 2.4**
 *
 * 审计工具代码的属性测试（任务 5.7）。位于 `:app` 的 `test` 源集，不随生产应用打包
 * （遵守 G3：仅 Kotlin；不改动 Apple 源码树）。与 [ConflictReconcilerTest] 的示例测试**互补**：
 * 示例测试固定若干具体场景（无冲突、单方持证据、双方持证据、无方持证据、写入失败三次），
 * 本文件在随机生成的判定集合上校验同一批不变式，每条属性不少于 100 次迭代。
 *
 * 属性 51 有两个半部，本文件逐半覆盖：
 *
 * 1. **冲突记录条数**（R2.4「不存在冲突时不写入冲突条目」）：生成混合了"一致"与"互不相容"
 *    判定对的 subject 集合，断言冲突记录条数**恰好等于**存在互不相容判定的 subject 个数——
 *    全部判定一致时为 **0** 条。期望值取自**生成器构造时的真值**（每个 plan 自带 `conflicting`
 *    标记），而非由被测实现的分组逻辑反算，避免同义反复。
 * 2. **证据裁决**（R2.4「以双方引用的 `文件:行` 代码证据为准作出唯一判定」）：每条冲突恰好一个
 *    [ConflictRecord.adoptedSide]；**不可定位的证据不得取胜**（只要有一方持可定位证据，胜者必是
 *    持可定位证据的一方；仅一方持有时胜者就是该方）；两方均持 / 无方持时按类级 KDoc 记载的
 *    确定性次序裁决，并以"输入顺序置换后裁决结果不变"交叉验证其确定性；每条记录的三项强制内容
 *    （冲突双方结论、采纳证据、被否结论）均非空白。
 *
 * 另附 R2.5 的写入上界属性：写入接缝对单条记录**至多尝试三次**，用满仍失败即停止且不再尝试后续
 * 记录、**已成功写入的内容不回滚**、报告受影响的冲突编号。
 *
 * **定义域约束（显式记录，非削弱生成器）**：
 * - `stance` 是**归一化后的结论取值**：同一 subject 上取值不同即互不相容。生成器为每个 subject
 *   取 stance 池的去重子集，故"同一 subject 内 stance 两两不同"这一前提由构造保证——它同时是
 *   [ConflictReconciler.ADJUDICATION_ORDER] 成为全序（末级必可分）的前提。
 * - subject 标识按下标加后缀保证**跨 plan 唯一**，使"每个 plan 对应至多一条冲突记录"可被逐一核对；
 *   同一 subject 被多个审查任务重复判定的情形由每个 plan 内的多 holder 覆盖。
 * - 可定位性由注入的确定性 [SourceLocator] 判定（路径以 `live/` 起始即可定位），与 [GapItemPropertyTest]
 *   同一约定，使反例可复现且"可定位 / 不可定位"两分支都被稳定覆盖。
 */
class ConflictReconcilerPropertyTest : FunSpec({

    // region 生成器与确定性 SourceLocator

    /** 可定位的证据路径（注入的确定性 locator 只认这些）。 */
    val liveFiles = listOf(
        "live/shared/src/main/kotlin/CrossPlatformFileTransferProtocol.kt",
        "live/device-discovery/src/main/kotlin/AndroidLocalNodeBootstrap.kt",
        "live/core/src/main/kotlin/NetworkSettingsStore.kt",
        "live/remote-control/src/main/kotlin/InputExecutionManager.kt",
    )

    /** 不可定位（已删除 / 行号越界）的证据路径。 */
    val staleFiles = listOf(
        "gone/app/src/main/kotlin/Deleted.kt",
        "gone/core/src/main/kotlin/Vanished.kt",
        "gone/shared/src/main/kotlin/Removed.kt",
    )

    /** 注入的确定性可定位性判定：`live/` 前缀即视为在当前工作副本可定位。 */
    val locator = SourceLocator { ref -> ref.file.startsWith("live/") }

    val liveRefArb: Arb<SourceRef> =
        Arb.bind(Arb.element(liveFiles), Arb.int(1..200)) { f, l -> SourceRef(f, l) }
    val staleRefArb: Arb<SourceRef> =
        Arb.bind(Arb.element(staleFiles), Arb.int(1..200)) { f, l -> SourceRef(f, l) }

    /**
     * 证据生成器：四种形态各自可达——只含可定位、只含不可定位、空、混合。
     * 覆盖裁决的三个分支（仅一方持可定位 / 多方均持 / 无方持）。
     */
    val evidenceArb: Arb<List<SourceRef>> = Arb.choice(
        Arb.list(liveRefArb, 1..3),
        Arb.list(staleRefArb, 1..3),
        Arb.constant(emptyList()),
        arbitrary { Arb.list(liveRefArb, 1..2).bind() + Arb.list(staleRefArb, 1..2).bind() },
    )

    /** 归一化结论取值池：同 subject 上取值不同即互不相容。 */
    val stancePool = listOf("缺陷", "非缺陷", "接通", "移除")

    val conclusionDetails = listOf(
        "零调用方，判定为死代码",
        "自起点集合可达，判定为已接通",
        "控件值无运行时消费方",
        "存在运行时消费方，判定非假接线",
    )

    val subjectIdentifiers = listOf(
        "shared/.../CrossPlatformFileTransferProtocol.kt:29",
        "AndroidLocalNodeBootstrap.verifiedCapabilities",
        "NetworkSettingsStore.portRange 的运行时消费",
        "RemoteControlAccessibilityService 可绑定性",
    )

    val scopeIdPool = listOf("S1", "S2", "S3", "S4")

    val sidePlanArb: Arb<SidePlan> = arbitrary {
        val stance = Arb.element(stancePool).bind()
        SidePlan(
            stance = stance,
            conclusion = "$stance —— ${Arb.element(conclusionDetails).bind()}",
            holders = Arb.list(Arb.element(scopeIdPool), 1..2).bind().distinct(),
            evidence = evidenceArb.bind(),
        )
    }

    /**
     * 单个 subject 的判定计划。`sides` 按 stance 去重——去重后 size == 1 即"全体一致"（不产出
     * 冲突条目），size >= 2 即互不相容（恰产出一条冲突条目）。两种情形都能被稳定生成。
     */
    val planArb: Arb<SubjectPlan> = arbitrary {
        val kind = Arb.element(SubjectKind.entries).bind()
        val identifier = Arb.element(subjectIdentifiers).bind()
        val sides = Arb.list(sidePlanArb, 1..3).bind().distinctBy { it.stance }
        SubjectPlan(kind = kind, identifierBase = identifier, sides = sides)
    }

    /** 一批 subject 计划 + 判定列表的旋转偏移（用于验证裁决与输入顺序无关）。 */
    val scenarioArb: Arb<Scenario> = arbitrary {
        val plans = Arb.list(planArb, 1..3).bind()
        Scenario(
            plans = plans.mapIndexed { index, plan -> plan.withUniqueSubject(index) },
            rotation = Arb.int(0..5).bind(),
        )
    }

    // endregion

    // region 第 1 半：冲突记录条数（R2.4「不存在冲突时不写入冲突条目」）

    test("Property 51 (count): 冲突条数恰好等于互不相容 subject 数，全体一致时为 0 条") {
        var sawZeroConflict = 0
        var sawSingleConflict = 0
        var sawMultiConflict = 0
        var sawAgreeingSubjectAlongsideConflict = 0

        checkAll(300, scenarioArb) { scenario ->
            val outcome = ConflictReconciler(locator = locator).reconcile(scenario.judgments())

            // 期望值取自生成器构造时的真值，不由被测实现反算。
            val conflictingPlans = scenario.plans.filter { it.conflicting }
            val agreeingPlans = scenario.plans.filterNot { it.conflicting }

            outcome.records.size shouldBe conflictingPlans.size
            outcome.hasConflicts shouldBe conflictingPlans.isNotEmpty()

            // 每个互不相容 subject 恰对应一条记录；一致的 subject 一条都不写入。
            outcome.records.map { it.subject }.toSet() shouldBe conflictingPlans.map { it.subject }.toSet()
            outcome.records.map { it.subject } shouldBe outcome.records.map { it.subject }.distinct()
            agreeingPlans.none { plan -> outcome.records.any { it.subject == plan.subject } } shouldBe true
            outcome.agreedSubjects.toSet() shouldBe agreeingPlans.map { it.subject }.toSet()

            // 全体一致 ⇒ 零条目（R2.4 末句），即便判定条数与证据条数都不为零。
            if (conflictingPlans.isEmpty()) {
                outcome.records shouldBe emptyList()
                scenario.judgments().isNotEmpty() shouldBe true
                sawZeroConflict++
            }
            when (conflictingPlans.size) {
                0 -> Unit
                1 -> sawSingleConflict++
                else -> sawMultiConflict++
            }
            if (conflictingPlans.isNotEmpty() && agreeingPlans.isNotEmpty()) {
                sawAgreeingSubjectAlongsideConflict++
            }

            // 编号唯一。
            outcome.allIdsUnique shouldBe true
        }

        // 非退化性：全体一致（0 条）、单冲突、多冲突、以及"冲突与一致共存"都被真正生成过。
        (sawZeroConflict > 0) shouldBe true
        (sawSingleConflict > 0) shouldBe true
        (sawMultiConflict > 0) shouldBe true
        (sawAgreeingSubjectAlongsideConflict > 0) shouldBe true
    }

    test("Property 51 (count): 同一分配器跨多次裁决编号不复用") {
        var sawAccumulatedRecords = 0

        checkAll(150, Arb.list(scenarioArb, 1..3)) { scenarios ->
            val allocator = GapIdAllocator(prefix = ConflictReconciler.CONFLICT_ID_PREFIX)
            val reconciler = ConflictReconciler(locator = locator, idAllocator = allocator)

            val emitted = mutableListOf<String>()
            scenarios.forEach { scenario ->
                val outcome = reconciler.reconcile(scenario.judgments())
                outcome.records.size shouldBe scenario.plans.count { it.conflicting }
                emitted += outcome.ids
            }

            emitted.size shouldBe emitted.toSet().size
            allocator.issued shouldBe emitted.toSet()
            emitted.all { it.startsWith(ConflictReconciler.CONFLICT_ID_PREFIX) } shouldBe true
            if (emitted.isNotEmpty()) sawAccumulatedRecords++
        }

        (sawAccumulatedRecords > 0) shouldBe true
    }

    // endregion

    // region 第 2 半：证据裁决（R2.4「以双方引用的 文件:行 证据为准作出唯一判定」）

    test("Property 51 (adjudication): 唯一裁决，可定位证据取胜，三项强制内容非空白") {
        var sawSoleLocatable = 0
        var sawMultipleLocatable = 0
        var sawNoLocatable = 0
        var sawMoreThanTwoSides = 0

        checkAll(300, scenarioArb) { scenario ->
            val judgments = scenario.judgments()
            val outcome = ConflictReconciler(locator = locator).reconcile(judgments)

            // 置换输入顺序后重新裁决：用于交叉验证裁决的确定性（与输入顺序无关）。
            val permuted = ConflictReconciler(locator = locator).reconcile(judgments.reversed())
            val permutedVerdict = permuted.records.associate { it.subject to it.adoptedSide.stance }

            outcome.records.forEach { record ->
                val plan = scenario.plans.single { it.subject == record.subject }

                // 各方与计划一一对应，stance 两两不同。
                record.sides.size shouldBe plan.sides.size
                record.sides.map { it.stance }.toSet() shouldBe plan.sides.map { it.stance }.toSet()
                record.sides.map { it.stance }.distinct().size shouldBe record.sides.size
                (record.sides.size >= 2) shouldBe true
                if (record.sides.size > 2) sawMoreThanTwoSides++

                // 恰好一个采纳方（唯一判定）。
                record.sides.count { it === record.adoptedSide } shouldBe 1
                record.rejectedSides.size shouldBe record.sides.size - 1
                (record.adoptedSide.stance in record.rejectedSides.map { it.stance }) shouldBe false

                // 裁决只认可定位证据：不可定位的证据不得取胜。
                val sidesWithLocatable = record.sides.filter { it.hasLocatableEvidence }
                when (sidesWithLocatable.size) {
                    0 -> {
                        sawNoLocatable++
                        // 无方持可定位证据：仍作出唯一判定，但不由证据确立，故不作修复决策依据。
                        record.basis shouldBe AdjudicationBasis.NO_LOCATABLE_EVIDENCE_TIE_BREAK
                        record.adoptedEvidence shouldBe ConflictRecord.NO_LOCATABLE_EVIDENCE
                        record.verdictBackedByLocatableEvidence shouldBe false
                        record.adoptedSide.hasLocatableEvidence shouldBe false
                    }
                    1 -> {
                        sawSoleLocatable++
                        // 仅一方持可定位证据 ⇒ 该方胜（R2.4 主路径）。
                        record.basis shouldBe AdjudicationBasis.SOLE_LOCATABLE_EVIDENCE
                        record.adoptedSide.stance shouldBe sidesWithLocatable.single().stance
                        record.verdictBackedByLocatableEvidence shouldBe true
                    }
                    else -> {
                        sawMultipleLocatable++
                        // 多方均持可定位证据：胜者必在这些方之中，且按记载次序取可定位证据条数最多者。
                        record.basis shouldBe AdjudicationBasis.LOCATABLE_EVIDENCE_TIE_BREAK
                        record.adoptedSide.hasLocatableEvidence shouldBe true
                        record.adoptedSide.locatableEvidence.size shouldBe
                            sidesWithLocatable.maxOf { it.locatableEvidence.size }
                        record.verdictBackedByLocatableEvidence shouldBe true
                    }
                }

                // 采纳方的采纳证据文本必须逐条来自其可定位证据（不得引用不可定位证据）。
                if (record.adoptedSide.hasLocatableEvidence) {
                    record.adoptedEvidence shouldBe
                        record.adoptedSide.locatableEvidence.map(SourceRef::toString).sorted()
                            .joinToString(", ")
                    record.adoptedSide.locatableEvidence.all(locator::isLocatable) shouldBe true
                }

                // R2.4 三项强制内容均非空白：双方结论、采纳证据、被否结论。
                record.sides.all { it.conclusion.isNotBlank() } shouldBe true
                record.adoptedEvidence.isNotBlank() shouldBe true
                record.rejectedConclusions.isNotEmpty() shouldBe true
                record.rejectedConclusions.all { it.isNotBlank() } shouldBe true
                record.rejectedConclusions.size shouldBe record.sides.size - 1
                // 每条被否结论确实承载对应被否方的结论文本。
                record.rejectedSides.all { side ->
                    record.rejectedConclusions.any { it.contains(side.conclusion) }
                } shouldBe true

                // 各方证据集合与计划一致（可定位子集是引用集合的子集）。
                val planSide = plan.sides.single { it.stance == record.adoptedSide.stance }
                record.adoptedSide.citedEvidence.toSet() shouldBe planSide.evidence.toSet()
                record.adoptedSide.locatableEvidence.toSet() shouldBe
                    planSide.evidence.filter(locator::isLocatable).toSet()

                // 确定性：输入顺序置换后同一 subject 的采纳方不变。
                permutedVerdict[record.subject] shouldBe record.adoptedSide.stance
            }

            // 置换后条数不变。
            permuted.records.size shouldBe outcome.records.size
        }

        // 非退化性：裁决的三个分支与"多于两方"的冲突都被真正生成过。
        (sawSoleLocatable > 0) shouldBe true
        (sawMultipleLocatable > 0) shouldBe true
        (sawNoLocatable > 0) shouldBe true
        (sawMoreThanTwoSides > 0) shouldBe true
    }

    // endregion

    // region R2.5：冲突记录写入的重试上界与失败处置

    test("Property 51 (R2.5 write bound): 单条记录至多三次尝试，用满仍失败即停止且不回滚") {
        var sawStopped = 0
        var sawCompleted = 0
        var sawTransientRetryThenSuccess = 0

        // 只用"全体互不相容"的计划，保证有足够记录参与写入。
        val conflictingScenarioArb: Arb<Scenario> = arbitrary {
            val plans = Arb.list(planArb, 2..4).bind()
                .filter { it.sides.size >= 2 }
                .ifEmpty {
                    listOf(
                        SubjectPlan(
                            kind = SubjectKind.CODE_OBJECT,
                            identifierBase = subjectIdentifiers.first(),
                            sides = listOf(
                                SidePlan("缺陷", "缺陷 —— 零调用方", listOf("S1"), emptyList()),
                                SidePlan("非缺陷", "非缺陷 —— 有消费方", listOf("S2"), emptyList()),
                            ),
                        ),
                    )
                }
            Scenario(
                plans = plans.mapIndexed { index, plan -> plan.withUniqueSubject(index) },
                rotation = 0,
            )
        }

        checkAll(200, conflictingScenarioArb, Arb.int(0..4), Arb.int(0..4)) {
                scenario, failIndexSeed, failCount ->

            val records = ConflictReconciler(locator = locator)
                .reconcile(scenario.judgments())
                .records
            records.isNotEmpty() shouldBe true

            val failIndex = failIndexSeed.mod(records.size)
            val failedRecordId = records[failIndex].id

            // 确定性写入接缝：对第 failIndex 条记录的前 failCount 次尝试抛错，其余尝试成功。
            val attempts = mutableListOf<Pair<String, Int>>()
            val publisher = ConflictRecordPublisher(
                writer = { record, attempt ->
                    attempts += record.id to attempt
                    if (record.id == failedRecordId && attempt <= failCount) {
                        error("simulated atomic-replace failure for ${record.id} attempt $attempt")
                    }
                },
            )

            val outcome = publisher.publish(records)

            // 上界：任何记录的尝试次数都不超过 3（R2.5）。
            attempts.groupBy({ it.first }, { it.second }).forEach { (_, tries) ->
                (tries.max() <= ConflictRecordPublisher.MAX_WRITE_ATTEMPTS) shouldBe true
                tries shouldBe (1..tries.max()).toList()
            }
            outcome.attemptsPerRecord.values.all {
                it <= ConflictRecordPublisher.MAX_WRITE_ATTEMPTS
            } shouldBe true

            val expectedStop = failCount >= ConflictRecordPublisher.MAX_WRITE_ATTEMPTS

            if (expectedStop) {
                sawStopped++
                val stopped = outcome as PublishOutcome.Stopped
                stopped.shouldHalt shouldBe true
                stopped.failedId shouldBe failedRecordId
                stopped.attemptsUsed shouldBe ConflictRecordPublisher.MAX_WRITE_ATTEMPTS
                // 不回滚：失败点之前已成功写入的内容全部保留。
                stopped.writtenIds shouldBe records.take(failIndex).map { it.id }
                // 报告受影响的冲突编号：失败的那条 + 因停止而未写入的后续各条。
                stopped.affectedIds shouldBe records.drop(failIndex).map { it.id }
                stopped.reason.isNotBlank() shouldBe true
                // 停止后不再尝试写入后续记录。
                val attemptedIds = attempts.map { it.first }.toSet()
                records.drop(failIndex + 1).none { it.id in attemptedIds } shouldBe true
            } else {
                sawCompleted++
                val completed = outcome as PublishOutcome.Completed
                completed.shouldHalt shouldBe false
                completed.writtenIds shouldBe records.map { it.id }
                // 瞬时失败后成功：该记录消耗的尝试次数等于失败次数 + 1。
                completed.attemptsPerRecord[failedRecordId] shouldBe failCount + 1
                if (failCount in 1 until ConflictRecordPublisher.MAX_WRITE_ATTEMPTS) {
                    sawTransientRetryThenSuccess++
                }
            }
        }

        // 非退化性：停止、正常完成、以及"重试后成功"三种走向都被真正生成过。
        (sawStopped > 0) shouldBe true
        (sawCompleted > 0) shouldBe true
        (sawTransientRetryThenSuccess > 0) shouldBe true
    }

    // endregion
})

// region 生成器数据结构（构造时即携带"是否互不相容"的真值）

/** 一方的判定计划：同一 stance 可由多个审查任务（[holders]）共同持有。 */
internal data class SidePlan(
    val stance: String,
    val conclusion: String,
    val holders: List<String>,
    val evidence: List<SourceRef>,
)

/**
 * 单个 subject 的判定计划。[conflicting] 是**构造时的真值**：去重后的 stance 数 ≥ 2 即互不相容，
 * 期望的冲突条数直接由它统计，而非由被测实现反算。
 */
internal data class SubjectPlan(
    val kind: SubjectKind,
    val identifierBase: String,
    val sides: List<SidePlan>,
    val subjectSuffix: String = "",
) {
    val subject: ContestedSubject
        get() = ContestedSubject(kind, identifierBase + subjectSuffix)

    /** 互不相容当且仅当同一 subject 上存在两个及以上不同 stance。 */
    val conflicting: Boolean get() = sides.size >= 2

    /** 以下标后缀保证 subject 跨 plan 唯一，便于逐 plan 核对其对应的冲突记录。 */
    fun withUniqueSubject(index: Int): SubjectPlan = copy(subjectSuffix = "#$index")

    fun judgments(): List<AuditJudgment> = sides.flatMap { side ->
        side.holders.map { holder ->
            AuditJudgment(
                scopeId = holder,
                subject = subject,
                stance = side.stance,
                conclusion = side.conclusion,
                evidence = side.evidence,
            )
        }
    }
}

/** 一批 subject 计划；[rotation] 旋转判定列表以打散输入顺序（裁决须与顺序无关）。 */
internal data class Scenario(
    val plans: List<SubjectPlan>,
    val rotation: Int,
) {
    fun judgments(): List<AuditJudgment> {
        val flat = plans.flatMap { it.judgments() }
        if (flat.isEmpty()) return flat
        val shift = rotation.mod(flat.size)
        return flat.drop(shift) + flat.take(shift)
    }
}

// endregion
