package com.skybridge.compass.audit

/**
 * Gap_Item 归并、编号唯一分配与置信度派生（Cross-Platform Parity Audit，任务 4.4 / R2.2、R2.3）。
 *
 * 该文件是**审计工具代码**，位于 `test` 源集，不随生产应用打包（遵守 G3）。
 *
 * 职责：
 * 1. **跨范围归并**：把四个只读审查任务（S1–S4）产出的 [GapItemDraft] 合并为一份全量 Gap_Item 表。
 * 2. **编号唯一且不复用（R2.2）**：由 [GapIdAllocator] 分配形如 `GAP-0001` 的编号；同一
 *    分配器实例在其生命周期内绝不复用任何已发放编号，即使跨多次 [merge] 调用亦然。
 * 3. **去重**：同一逻辑缺口（同 [DedupKey]）只保留一条，合并其证据；重复项不各占一个编号。
 * 4. **置信度派生（R2.3）**：每条条目的置信度由"其证据中是否存在至少一条在当前工作副本
 *    可定位的 `文件:行`"决定——满足则 [Confidence.VERIFIED_BY_REPO_EVIDENCE]，否则
 *    [Confidence.UNVERIFIED_SPECULATION]。未核实推测项不进入修复决策
 *    （见 [GapMergeResult.fixEligible] / [GapMergeResult.speculative]）。
 *
 * 说明：置信度只认"可定位"的证据。一条草稿即便声明了 `文件:行`，若该证据在当前工作副本
 * 无法定位（如已被删除或行号越界），则该证据不计入核实前提；若某草稿的全部证据都不可定位，
 * 则其等效于"无证据"，标注为未核实推测。
 */
class GapItemMerger(
    /** `文件:行` 可定位性判定（R2.3 前提）。 */
    private val locator: SourceLocator,
    /** 编号分配器；默认新建一个从 1 起的分配器。跨多次 merge 复用同一实例可保证全局不复用。 */
    private val idAllocator: GapIdAllocator = GapIdAllocator(),
) {

    /**
     * 归并一批草稿：去重 → 分配唯一编号 → 派生置信度。
     *
     * 结果中的条目顺序稳定（按去重后首次出现顺序），编号按该顺序递增分配。
     */
    fun merge(drafts: List<GapItemDraft>): GapMergeResult {
        // 去重：同 DedupKey 的草稿合并证据（保序去重），保留首条的描述性字段。
        val order = mutableListOf<DedupKey>()
        val grouped = LinkedHashMap<DedupKey, MutableList<GapItemDraft>>()
        for (d in drafts) {
            val key = d.dedupKey()
            if (key !in grouped) order += key
            grouped.getOrPut(key) { mutableListOf() } += d
        }

        val items = order.map { key ->
            val group = grouped.getValue(key)
            val head = group.first()
            val mergedEvidence = group
                .flatMap { it.evidence }
                .distinct()
            val confidence = deriveConfidence(mergedEvidence)
            GapItem(
                id = idAllocator.next(),
                category = head.category,
                evidence = mergedEvidence,
                subsystem = head.subsystem,
                userVisibleImpact = head.userVisibleImpact,
                verdictCondition = head.verdictCondition,
                confidence = confidence,
                scopeId = head.scopeId,
                baselineRef = head.baselineRef,
            )
        }

        return GapMergeResult(items)
    }

    /**
     * 派生置信度（R2.3）：证据中存在至少一条可定位的 `文件:行` → 已用仓库证据核实；
     * 否则未核实推测。
     */
    private fun deriveConfidence(evidence: List<SourceRef>): Confidence =
        if (evidence.any(locator::isLocatable)) {
            Confidence.VERIFIED_BY_REPO_EVIDENCE
        } else {
            Confidence.UNVERIFIED_SPECULATION
        }
}

/**
 * 单调递增、绝不复用的 Gap_Item 编号分配器（R2.2）。
 *
 * 线程内确定性：每次 [next] 返回 `GAP-####`（至少 4 位零填充），内部计数器只增不减，
 * 已发放编号记入 [issued] 供审计断言"不复用"。同一实例跨多次归并调用持续递增。
 */
class GapIdAllocator(
    private val prefix: String = "GAP-",
    startAt: Int = 1,
) {
    private var counter: Int = startAt
    private val issuedIds = LinkedHashSet<String>()

    /** 已发放的全部编号（发放顺序）。 */
    val issued: Set<String> get() = issuedIds

    /** 分配下一个未使用编号；保证与此前发放的任何编号都不相同。 */
    fun next(): String {
        val id = prefix + counter.toString().padStart(MIN_DIGITS, '0')
        check(issuedIds.add(id)) { "gap id $id reused — allocator invariant violated (R2.2)" }
        counter++
        return id
    }

    companion object {
        private const val MIN_DIGITS = 4
    }
}

/**
 * 审查任务产出的 Gap_Item 草稿：不含编号与置信度——二者分别由归并分配与派生（R2.2、R2.3）。
 */
data class GapItemDraft(
    val category: GapCategory,
    val evidence: List<SourceRef>,
    val subsystem: String,
    val userVisibleImpact: String,
    val verdictCondition: String,
    val scopeId: String,
    val baselineRef: String? = null,
) {
    /**
     * 去重键：同一逻辑缺口的判定依据。以（类别 + 子系统 + 用户可见行为 + 判定条件 +
     * 证据集合）为准；证据集合用**无序集合**比较，从而与书写顺序无关。
     */
    fun dedupKey(): DedupKey = DedupKey(
        category = category,
        subsystem = subsystem.trim(),
        userVisibleImpact = userVisibleImpact.trim(),
        verdictCondition = verdictCondition.trim(),
        evidence = evidence.toSet(),
    )
}

/** Gap_Item 去重键（值语义，证据以无序集合参与相等判定）。 */
data class DedupKey(
    val category: GapCategory,
    val subsystem: String,
    val userVisibleImpact: String,
    val verdictCondition: String,
    val evidence: Set<SourceRef>,
)

/**
 * 归并结果。[items] 为全量 Gap_Item 表；[fixEligible] 与 [speculative] 按置信度分区，
 * 后者不进入修复决策（R2.3）。
 */
data class GapMergeResult(
    val items: List<GapItem>,
) {
    /** 全部已发放编号（应两两不同）。 */
    val ids: List<String> get() = items.map { it.id }

    /** 进入修复决策的条目：已用仓库证据核实（R2.3）。 */
    val fixEligible: List<GapItem> get() = items.filter { it.isFixEligible }

    /** 不进入修复决策的条目：未核实推测（R2.3）。 */
    val speculative: List<GapItem> get() = items.filterNot { it.isFixEligible }

    /** 编号是否全部唯一（不复用）。 */
    val allIdsUnique: Boolean get() = ids.size == ids.toSet().size
}
