package com.skybridge.compass.audit

import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.checkAll

/**
 * Property 50: Gap_Item 结构、编号唯一性与置信度标注（任务 5.6）。
 *
 * **Validates: Requirements 2.2, 2.3, 2.7, 10.1**
 *
 * 该文件是**审计工具的属性测试**，位于 `:app` 的 `test` 源集，不随生产应用打包（遵守 G3）。
 * 与既有的示例测试 [GapItemMergerTest]（JUnit Jupiter）互补：示例测试固定若干具体场景，
 * 本文件用 Kotest Property 在随机输入域上校验同一批不变式，每条属性不少于 100 次迭代。
 *
 * 属性 50 分三部分，本文件逐部分覆盖：
 *  1. **结构**（R2.2 / R2.7）：编号非空、类别取自四值集合、子系统 / 用户可见行为 / 判定条件非空、
 *     基线引用逐字透传；且 R2.3 构造期不变式成立（空证据 + 已核实 ⇒ 构造被拒）。
 *  2. **编号唯一**（R2.2）：跨范围（S1–S4）与跨多次 [GapItemMerger.merge] 调用，同一分配器
 *     发放的编号两两不同、绝不复用；同一逻辑缺口（同 [DedupKey]）合并为一条并只消耗一个编号，
 *     证据取并集。
 *  3. **置信度**（R2.3）：当且仅当证据中存在至少一条可定位的 `文件:行` 时标注
 *     [Confidence.VERIFIED_BY_REPO_EVIDENCE]，否则 [Confidence.UNVERIFIED_SPECULATION]；
 *     [GapMergeResult.fixEligible] / [GapMergeResult.speculative] 构成全覆盖且互斥的划分。
 *
 * **R10.1 建模范围说明（如实记录，不臆造字段）**：R10.1 要求「缺陷」类条目额外记录 ≤20 步复现步骤、
 * 前置条件、观察行为与期望行为。当前 Kotlin 侧的 [GapItem] **未建模** `repro` / `status` / `tests` /
 * `evidenceRecords` 四个字段（design.md 的数据模型草案含这些字段，落地实现只取了前八个字段），
 * 复现步骤目前仅以文档形式存在于 `gaps/gap-items.md`。因此本属性测试在 R10.1 方向上**只能**覆盖
 * 类型确实承载的部分：缺陷类条目同样受四值类别约束，并携带 R2.7 要求的基线引用（R10.1 中「期望行为
 * 须附基线小节引用或『无对应基线条目』」这一子句）。步数上限 ≤20 无法在此断言——类型中没有该字段。
 *
 * **R2.7 强制力说明（如实记录）**：[GapItem.baselineRef] 声明为 `String?` 且构造期**不做校验**
 * （对比 [GapItem.subsystem] 等字段有 `require(isNotBlank())`）。也就是说 R2.7 目前由报告层约定与
 * 生成侧保证，而非由类型强制。本文件断言真实成立的不变式——**归并逐字透传 `baselineRef`**，
 * 因而当草稿侧满足 R2.7（非空小节引用或 [NO_BASELINE_MARKER]）时，归并结果必然同样满足。
 */
class GapItemPropertyTest : FunSpec({

    // region 生成器与确定性 SourceLocator

    /** R2.7 / R10.1 的显式标记文本。 */
    val noBaselineMarker = "无对应基线条目"

    /** 可定位的证据路径前缀（注入的确定性 locator 只认这些）。 */
    val liveFiles = listOf(
        "live/app/src/main/kotlin/Settings.kt",
        "live/device-discovery/src/main/kotlin/Bonjour.kt",
        "live/shared/src/main/kotlin/P2PHandshake.kt",
        "live/file-transfer/src/main/kotlin/Wire.kt",
    )

    /** 不可定位（已删除 / 行号越界）的证据路径前缀。 */
    val staleFiles = listOf(
        "gone/app/src/main/kotlin/Deleted.kt",
        "gone/remote-control/src/main/kotlin/Removed.kt",
        "gone/core/src/main/kotlin/Vanished.kt",
    )

    /**
     * 注入的确定性可定位性判定：路径以 `live/` 起始即视为在当前工作副本可定位。
     * 确定性使反例可复现，也让"可定位 / 不可定位"两个分支都能被生成器稳定覆盖。
     */
    val locator = SourceLocator { ref -> ref.file.startsWith("live/") }

    val liveRefArb: Arb<SourceRef> =
        Arb.bind(Arb.element(liveFiles), Arb.int(1..500)) { f, l -> SourceRef(f, l) }
    val staleRefArb: Arb<SourceRef> =
        Arb.bind(Arb.element(staleFiles), Arb.int(1..500)) { f, l -> SourceRef(f, l) }

    val subsystems = listOf(
        "Discovery_Subsystem",
        "Connection_Subsystem",
        "FileTransfer_Subsystem",
        "RemoteDesktop_Subsystem",
        "Settings_Subsystem",
    )
    val impacts = listOf(
        "对端不出现在设备列表",
        "传输进度恒为占位值",
        "取消入口不可用",
        "Android 无法作为被控端",
        "设置项不改变运行时行为",
    )
    val verdicts = listOf(
        "运行 :app:testDebugUnitTest 后该断言通过",
        "Apple 端设备列表 5 秒内出现该条目",
        "触发取消后 3 秒内呈现已取消",
        "修改端口范围后新会话监听端口落在该范围内",
    )
    val scopeIds = listOf("S1", "S2", "S3", "S4")

    /** R2.7 合规的基线引用：具体小节引用，或显式的"无对应基线条目"标记。 */
    val baselineRefs = listOf(
        "Android_PQC_Implementation.md §2.1",
        "CrossPlatformDiscoveryDesign.md §2.2",
        "ADR-2026-07-23 §决策 3",
        "ANDROID_DEVELOPMENT_SPECIFICATION_2025.md §4.1",
        noBaselineMarker,
    )

    /** 证据列表生成器：混合可定位与不可定位条目（含空列表），覆盖 R2.3 的两个分支。 */
    val evidenceArb: Arb<List<SourceRef>> = arbitrary {
        val live = Arb.list(liveRefArb, 0..3).bind()
        val stale = Arb.list(staleRefArb, 0..3).bind()
        // 交错拼接，避免"可定位项恒在首位"这类位置性偏置。
        (live zip stale).flatMap { (a, b) -> listOf(a, b) } +
            live.drop(minOf(live.size, stale.size)) +
            stale.drop(minOf(live.size, stale.size))
    }

    /** 全部证据均不可定位（含空列表）——等价于"无证据"的 R2.3 分支。 */
    val allStaleEvidenceArb: Arb<List<SourceRef>> = Arb.list(staleRefArb, 0..4)

    fun draftArbWith(evidence: Arb<List<SourceRef>>): Arb<GapItemDraft> = arbitrary {
        GapItemDraft(
            category = Arb.element(GapCategory.entries).bind(),
            evidence = evidence.bind(),
            subsystem = Arb.element(subsystems).bind(),
            userVisibleImpact = Arb.element(impacts).bind(),
            verdictCondition = Arb.element(verdicts).bind(),
            scopeId = Arb.element(scopeIds).bind(),
            baselineRef = Arb.element(baselineRefs).bind(),
        )
    }

    val draftArb = draftArbWith(evidenceArb)

    /**
     * 一批草稿 + 注入的重复项：`dupCount` 条从头部复制并把证据顺序反转。
     * 证据以无序集合参与 [DedupKey] 相等判定，因此这些副本必然与原条目同键，
     * 从而稳定覆盖"发生去重"与"未发生去重"两种结果。
     */
    val batchArb: Arb<List<GapItemDraft>> = arbitrary {
        val base = Arb.list(draftArb, 1..5).bind()
        val dupCount = Arb.int(0..3).bind()
        base + base.take(dupCount).map { it.copy(evidence = it.evidence.reversed()) }
    }

    // endregion

    // region 1. 结构（R2.2、R2.7、R10.1 中类型确实承载的部分）

    test("Property 50 (structure): 归并结果逐条满足 Gap_Item 结构约束且基线引用逐字透传") {
        val sawEachCategory = mutableSetOf<GapCategory>()
        var sawMarkerBaseline = false
        var sawSectionBaseline = false

        checkAll(200, batchArb) { drafts ->
            val result = GapItemMerger(locator = locator).merge(drafts)

            result.items.forEach { item ->
                // 编号非空。
                item.id.isNotBlank() shouldBe true
                // 类别取自四值集合。
                (item.category in GapCategory.entries) shouldBe true
                (item.category.label in setOf("缺失", "半接线", "假接线", "缺陷")) shouldBe true
                // 描述性字段非空。
                item.subsystem.isNotBlank() shouldBe true
                item.userVisibleImpact.isNotBlank() shouldBe true
                item.verdictCondition.isNotBlank() shouldBe true
                item.scopeId.isNotBlank() shouldBe true
                // R2.3 构造期不变式的运行时体现：空证据必为未核实推测。
                if (item.evidence.isEmpty()) {
                    item.confidence shouldBe Confidence.UNVERIFIED_SPECULATION
                }
                // R2.7 / R10.1：基线引用为非空小节引用或显式标记（草稿侧合规 ⇒ 归并结果合规）。
                (item.baselineRef != null) shouldBe true
                val ref = item.baselineRef.orEmpty()
                ref.isNotBlank() shouldBe true
                (ref == noBaselineMarker || ref in baselineRefs) shouldBe true

                sawEachCategory += item.category
                if (ref == noBaselineMarker) sawMarkerBaseline = true else sawSectionBaseline = true
            }

            // 逐字透传：每条结果的 baselineRef / scopeId 等于其去重组首条草稿的取值。
            val byKey = drafts.groupBy { it.dedupKey() }
            result.items.forEach { item ->
                val head = byKey.getValue(item.dedupKeyOf()).first()
                item.baselineRef shouldBe head.baselineRef
                item.scopeId shouldBe head.scopeId
                item.category shouldBe head.category
                item.userVisibleImpact shouldBe head.userVisibleImpact
                item.verdictCondition shouldBe head.verdictCondition
            }
        }

        // 非退化性：四类类别与两种基线引用形态都被真正生成过。
        sawEachCategory shouldBe GapCategory.entries.toSet()
        sawMarkerBaseline shouldBe true
        sawSectionBaseline shouldBe true
    }

    test("Property 50 (structure): 空证据 + 已核实的 Gap_Item 构造必被拒绝（R2.3 不变式）") {
        checkAll(
            100,
            Arb.element(GapCategory.entries),
            Arb.element(subsystems),
            Arb.element(impacts),
            Arb.element(verdicts),
            Arb.element(scopeIds),
        ) { category, subsystem, impact, verdict, scopeId ->
            shouldThrow<IllegalArgumentException> {
                GapItem(
                    id = "GAP-0001",
                    category = category,
                    evidence = emptyList(),
                    subsystem = subsystem,
                    userVisibleImpact = impact,
                    verdictCondition = verdict,
                    confidence = Confidence.VERIFIED_BY_REPO_EVIDENCE,
                    scopeId = scopeId,
                )
            }
            // 同字段配空证据 + 未核实推测则可构造，说明拒绝的原因确是置信度而非其他字段。
            GapItem(
                id = "GAP-0001",
                category = category,
                evidence = emptyList(),
                subsystem = subsystem,
                userVisibleImpact = impact,
                verdictCondition = verdict,
                confidence = Confidence.UNVERIFIED_SPECULATION,
                scopeId = scopeId,
            ).isFixEligible shouldBe false
        }
    }

    // endregion

    // region 2. 编号唯一与去重（R2.2）

    test("Property 50 (id uniqueness): 跨范围与跨多次归并调用编号两两不同且绝不复用") {
        var sawDedupCollapse = false
        var sawNoCollapse = false
        var sawMultipleScopes = false

        checkAll(150, Arb.list(batchArb, 1..4)) { batches ->
            val allocator = GapIdAllocator()
            val merger = GapItemMerger(locator = locator, idAllocator = allocator)

            val emittedIds = mutableListOf<String>()
            batches.forEach { batch ->
                val result = merger.merge(batch)

                // 去重：结果条数等于该批次内不同 DedupKey 的个数。
                val distinctKeys = batch.map { it.dedupKey() }.distinct()
                result.items.size shouldBe distinctKeys.size
                if (distinctKeys.size < batch.size) sawDedupCollapse = true else sawNoCollapse = true

                // 去重项证据取并集，且重复项不各占一个编号。
                distinctKeys.forEach { key ->
                    val group = batch.filter { it.dedupKey() == key }
                    val item = result.items.single { it.dedupKeyOf() == key }
                    item.evidence.toSet() shouldBe group.flatMap { it.evidence }.toSet()
                    item.evidence.size shouldBe item.evidence.distinct().size
                }

                result.allIdsUnique shouldBe true
                emittedIds += result.ids
            }

            // 跨范围 + 跨调用：全程发放的编号两两不同（绝不复用）。
            emittedIds.size shouldBe emittedIds.toSet().size
            allocator.issued.size shouldBe emittedIds.size
            allocator.issued shouldBe emittedIds.toSet()

            if (batches.flatten().map { it.scopeId }.distinct().size > 1) sawMultipleScopes = true
        }

        // 非退化性：去重发生与不发生两种结果、以及跨范围批次都被真正生成过。
        sawDedupCollapse shouldBe true
        sawNoCollapse shouldBe true
        sawMultipleScopes shouldBe true
    }

    // endregion

    // region 3. 置信度与修复决策划分（R2.3）

    test("Property 50 (confidence): 置信度当且仅当存在可定位证据时为已核实，且修复决策划分全覆盖互斥") {
        var sawVerified = false
        var sawSpeculative = false

        checkAll(200, batchArb) { drafts ->
            val result = GapItemMerger(locator = locator).merge(drafts)

            result.items.forEach { item ->
                val hasLocatable = item.evidence.any(locator::isLocatable)
                item.confidence shouldBe if (hasLocatable) {
                    Confidence.VERIFIED_BY_REPO_EVIDENCE
                } else {
                    Confidence.UNVERIFIED_SPECULATION
                }
                item.isFixEligible shouldBe hasLocatable
                if (hasLocatable) sawVerified = true else sawSpeculative = true
            }

            // 划分全覆盖且互斥。
            result.fixEligible.size + result.speculative.size shouldBe result.items.size
            result.fixEligible.map { it.id }.intersect(result.speculative.map { it.id }.toSet())
                .isEmpty() shouldBe true
            result.fixEligible.all { it.confidence == Confidence.VERIFIED_BY_REPO_EVIDENCE } shouldBe true
            result.speculative.all { it.confidence == Confidence.UNVERIFIED_SPECULATION } shouldBe true
            (result.fixEligible + result.speculative).map { it.id }.toSet() shouldBe result.ids.toSet()
        }

        sawVerified shouldBe true
        sawSpeculative shouldBe true
    }

    test("Property 50 (confidence): 全部证据不可定位等价于无证据，一律未核实推测且不进入修复决策") {
        var sawNonEmptyStaleEvidence = false

        checkAll(150, Arb.list(draftArbWith(allStaleEvidenceArb), 1..5)) { drafts ->
            val result = GapItemMerger(locator = locator).merge(drafts)

            result.items.forEach { item ->
                item.confidence shouldBe Confidence.UNVERIFIED_SPECULATION
                item.isFixEligible shouldBe false
                if (item.evidence.isNotEmpty()) sawNonEmptyStaleEvidence = true
            }
            result.fixEligible.isEmpty() shouldBe true
            result.speculative.size shouldBe result.items.size
        }

        // 非退化性：确实生成过"声明了证据但全部不可定位"的条目（不只是空证据）。
        sawNonEmptyStaleEvidence shouldBe true
    }

    // endregion
})

/** 由已归并条目反推其去重键（字段与 [GapItemDraft.dedupKey] 一致）。 */
private fun GapItem.dedupKeyOf(): DedupKey = DedupKey(
    category = category,
    subsystem = subsystem.trim(),
    userVisibleImpact = userVisibleImpact.trim(),
    verdictCondition = verdictCondition.trim(),
    evidence = evidence.toSet(),
)
