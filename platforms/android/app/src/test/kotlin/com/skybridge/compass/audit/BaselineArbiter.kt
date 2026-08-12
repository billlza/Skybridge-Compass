package com.skybridge.compass.audit

import java.time.LocalDate

/**
 * 文档基线冲突裁决顺序（Cross-Platform Parity Audit，任务 5.8 / R2.8、R2.9、R2.10）。
 *
 * 该文件是**审计工具代码**，位于 `:app` 模块的 `test` 源集（与 [ConflictReconciler]、[GapItem]、
 * [AuditScope] 同包），不随生产应用打包（遵守 G3：仅 Kotlin；不改动 Apple 源码树）。
 *
 * `audit-report.md` §3.2 已把裁决顺序写成文档规则；本文件把该规则落成可执行的纯 Kotlin 裁决单元，
 * 使 R2.8 / R2.9 可被属性测试机器校验（Property 52）。**规则以 §3.2 为准，本实现逐级对应**：
 *
 *  1. **代码证据优先**（[BaselineAdjudicationBasis.CODE_EVIDENCE]）——文档基线之间存在冲突但仓库
 *     `文件:行` 代码证据足以判定时，以代码证据裁决（R2.4），**不进入文档裁决顺序**。
 *     「足以判定」的口径与 R2.3 / R2.4 一致：至少一条证据在当前工作副本**可定位**（[SourceLocator]）。
 *  2. **层级优先**（[BaselineAdjudicationBasis.TIER_PRIORITY]，R2.8）——代码证据不足时，
 *     [BaselineTier.PRIORITY_ADR]（B1、B2、B3）胜 [BaselineTier.SECONDARY]（B4、B5、B6）；
 *     被否的次级条目标记为**历史内容**（[DefeatedBaselineSide.markedHistorical]）。
 *  3. **互冲取新**（[BaselineAdjudicationBasis.NEWER_ADR]，R2.9）——同层级且日期不同时取**日期较新**者。
 *  4. **同日期主题区分**（[BaselineAdjudicationBasis.TOPIC_OWNERSHIP]，R2.9）——同日期时，
 *     若争议主题（[BaselineConflict.contestedTopic]）**恰好归属其中一方**，该方胜。
 *  5. **同日期且主题不可辨**（[BaselineAdjudicationBasis.PENDING_APPLE_DECISION]，R2.9 兜底）——
 *     前四级都不可分时**不选出胜者**，该条目标记为**待 Apple 侧决策**并标注为**未核实推测**。
 *
 * ## 确定性（全序）
 *
 * 裁决以「逐级取最优组」的过滤实现：每一级都用一个**最优键**筛掉非最优方，某级筛出唯一一方即
 * 由该级定案，[BaselineVerdict.basis] 记录**实际定案的那一级**。每级的最优组只由集合本身决定，
 * 与输入顺序无关，故裁决结果对各方的任意置换保持不变。[ARBITRATION_ORDER] 是与该过滤同序的
 * 比较器（末级以基线编号收尾，故为**全序**），[arbitrate] 在选出胜者时与它交叉一致：
 * `winner == candidates.minWith(ARBITRATION_ORDER)`（见 `BaselineArbiterPropertyTest`）。
 *
 * ## 与 R2.10 的衔接（缺失文档降级）
 *
 * 文档缺失/不可读（[BaselineDoc.present] 为 false）**不改变**上述裁决顺序——否则裁决结果会依赖
 * 工作副本的偶然状态。缺失只影响置信度：胜方文档缺失时该结论**仅依赖一份读不到的文档**，
 * 故 [BaselineVerdict.unverifiedConjecture] 置为 true（R2.10），并在
 * [BaselineVerdict.missingBaselineIds] 登记全部缺失文档编号。
 *
 * ## 有意的规则外推（如实记录）
 *
 * R2.9 的字面主体是「两份或以上 **ADR** 基线」。为使裁决在任何输入上都确定且不出现"任意挑一方"，
 * 第 3–5 级**同样适用于次级文档之间的冲突**：日期较新者胜；日期与主题都不可分时同样归入
 * [BaselineAdjudicationBasis.PENDING_APPLE_DECISION] 并标注未核实推测——即在真正无法判定时
 * **宁可挂起也不擅自定案**，与 R2.3「无可核实依据者不进入修复决策」同向。
 */
class BaselineArbiter(
    /** `文件:行` 可定位性判定（与 R2.3 / R2.4 同一口径）。 */
    private val locator: SourceLocator,
) {

    /**
     * 对一次文档基线冲突作出裁决。
     *
     * @return [BaselineVerdict]：定案级别、胜方（第 5 级为 null）、被否方结论、历史内容与
     *   未核实推测标记。结果与 [BaselineConflict.sides] 的输入顺序无关。
     */
    fun arbitrate(conflict: BaselineConflict): BaselineVerdict {
        val candidates = conflict.sides.map { side ->
            BaselineCandidate(
                side = side,
                backedByCodeEvidence = conflict.isBackedByLocatableCodeEvidence(side, locator),
                ownsContestedTopic = conflict.ownsContestedTopic(side),
            )
        }

        val evaluated = mutableListOf<BaselineAdjudicationBasis>()
        var surviving = candidates

        for (level in CASCADE_LEVELS) {
            evaluated += level.basis
            surviving = level.bestGroup(surviving)
            if (surviving.size == 1) {
                return conflict.verdict(
                    winner = surviving.single(),
                    basis = level.basis,
                    evaluatedLevels = evaluated.toList(),
                )
            }
        }

        // 第 5 级兜底：前四级均不可分 ⇒ 不选出胜者，挂起待 Apple 侧决策并标注未核实推测（R2.9）。
        evaluated += BaselineAdjudicationBasis.PENDING_APPLE_DECISION
        return conflict.verdict(
            winner = null,
            basis = BaselineAdjudicationBasis.PENDING_APPLE_DECISION,
            evaluatedLevels = evaluated.toList(),
        )
    }

    /** 由 [conflict] 与定案结果组装裁决。 */
    private fun BaselineConflict.verdict(
        winner: BaselineCandidate?,
        basis: BaselineAdjudicationBasis,
        evaluatedLevels: List<BaselineAdjudicationBasis>,
    ): BaselineVerdict {
        val winningSide = winner?.side
        // 各集合按基线编号排序：使整个 [BaselineVerdict] 对 sides 的任意置换**逐字段相等**。
        val defeated = if (winningSide == null) {
            emptyList()
        } else {
            sides.filter { it !== winningSide }
                .sortedBy { it.doc.id }
                .map { side ->
                    DefeatedBaselineSide(
                        doc = side.doc,
                        conclusion = side.conclusion,
                        // R2.8：被否的次级文档（B4/B5/B6）条目一律标记为历史内容。
                        markedHistorical = side.doc.tier == BaselineTier.SECONDARY,
                    )
                }
        }
        val missing = sides.map { it.doc }.filterNot { it.present }.map { it.id }.sorted()
        return BaselineVerdict(
            subject = subject,
            contestedTopic = contestedTopic,
            basis = basis,
            winningBaseline = winningSide?.doc,
            winningConclusion = winningSide?.conclusion,
            defeatedSides = defeated,
            undecidedSides = if (winningSide == null) sides.sortedBy { it.doc.id } else emptyList(),
            evaluatedLevels = evaluatedLevels,
            missingBaselineIds = missing,
            // R2.9 兜底分支必为未核实推测；R2.10：胜方文档缺失时该结论仅依赖读不到的文档，同样降级。
            unverifiedConjecture = basis == BaselineAdjudicationBasis.PENDING_APPLE_DECISION ||
                (winningSide != null && !winningSide.doc.present),
        )
    }

    companion object {
        /**
         * 裁决级联的前四级。每级把候选集合收敛到该级的**最优组**；某级收敛到唯一一方即由该级定案。
         * 各级最优组只依赖集合本身，故与输入顺序无关。
         */
        private val CASCADE_LEVELS: List<CascadeLevel> = listOf(
            // 1. 代码证据优先（R2.4）：持可定位代码证据者胜，不进入文档裁决顺序。
            CascadeLevel(BaselineAdjudicationBasis.CODE_EVIDENCE) { group ->
                group.filter { it.backedByCodeEvidence }.ifEmpty { group }
            },
            // 2. 层级优先（R2.8）：优先级 ADR 胜次级文档。
            CascadeLevel(BaselineAdjudicationBasis.TIER_PRIORITY) { group ->
                group.filter { it.doc.tier == BaselineTier.PRIORITY_ADR }.ifEmpty { group }
            },
            // 3. 互冲取新（R2.9）：日期较新者胜（无 ISO 日期视为最旧）。
            CascadeLevel(BaselineAdjudicationBasis.NEWER_ADR) { group ->
                val newest = group.maxOf { it.comparableDate }
                group.filter { it.comparableDate == newest }
            },
            // 4. 同日期主题区分（R2.9）：争议主题恰好归属一方时该方胜。
            CascadeLevel(BaselineAdjudicationBasis.TOPIC_OWNERSHIP) { group ->
                group.filter { it.ownsContestedTopic }.ifEmpty { group }
            },
        )

        /**
         * 与 [CASCADE_LEVELS] 同序的**全序**比较器（胜者为最小元），末级以基线编号收尾保证可分。
         *
         * 仅用于交叉验证过滤级联的确定性：当级联选出胜者时，该胜者必为本比较器的最小元。
         * 级联**不**用末级编号定案——前四级不可分时按 R2.9 挂起，而不是按编号任意挑一方。
         */
        val ARBITRATION_ORDER: Comparator<BaselineCandidate> =
            // 1. 持可定位代码证据者优先。
            compareByDescending<BaselineCandidate> { it.backedByCodeEvidence }
                // 2. 优先级 ADR 优先。
                .thenByDescending { it.doc.tier == BaselineTier.PRIORITY_ADR }
                // 3. 日期较新者优先。
                .thenByDescending { it.comparableDate }
                // 4. 争议主题归属方优先。
                .thenByDescending { it.ownsContestedTopic }
                // 5. 基线编号字典序（必定可分 ⇒ 全序）。
                .thenBy { it.doc.id }
    }
}

/** 裁决级联的一级：把候选集合收敛到该级最优组。 */
private class CascadeLevel(
    val basis: BaselineAdjudicationBasis,
    private val select: (List<BaselineCandidate>) -> List<BaselineCandidate>,
) {
    fun bestGroup(group: List<BaselineCandidate>): List<BaselineCandidate> = select(group)
}

/** 参与裁决的一方及其在各级判据上的取值（由 [BaselineArbiter] 计算，不由调用方指定）。 */
data class BaselineCandidate(
    val side: BaselineSide,
    /** 是否被**可定位**的 `文件:行` 代码证据支持（第 1 级判据）。 */
    val backedByCodeEvidence: Boolean,
    /** 争议主题是否归属本方文档（第 4 级判据）。 */
    val ownsContestedTopic: Boolean,
) {
    val doc: BaselineDoc get() = side.doc

    /** 用于「取新」比较的日期；无 ISO 日期的文档视为最旧。 */
    val comparableDate: LocalDate get() = doc.effectiveDate ?: LocalDate.MIN
}

/** 文档基线的裁决层级（`audit-report.md` §3.1 的「裁决层级」列，R2.8）。 */
enum class BaselineTier(val label: String) {
    /** 优先（ADR）：B1、B2、B3。 */
    PRIORITY_ADR("优先（ADR）"),

    /** 次（历史内容）：B4、B5、B6；被否条目标记为历史内容。 */
    SECONDARY("次（历史内容）"),
}

/**
 * 一份文档基线的登记项（`audit-report.md` §3.1，R2.7 / R2.10）。
 *
 * [date] 为文档自身的 ISO 日期，无 ISO 日期者为 null（B4、B6）；[updatedDate] 为文档内声明的
 * 更新日期（B2 的 2026-07-05）。[effectiveDate] 是「取新」比较实际使用的日期。
 * [present] 表达 R2.10 的存在性：false 表示该文档在仓库中不存在或无法读取。
 */
data class BaselineDoc(
    /** 登记编号（B1..B6）。 */
    val id: String,
    /** 仓库相对路径。 */
    val path: String,
    /** 文档 ISO 日期；无 ISO 日期者为 null。 */
    val date: LocalDate?,
    /** 文档内声明的更新日期（如有）。 */
    val updatedDate: LocalDate? = null,
    /** 日期的人类可读登记文本（与 §3.1 表格一致）。 */
    val dateLabel: String,
    val tier: BaselineTier,
    /** 治理主题范围（用于同日期 ADR 的主题区分，R2.9）。 */
    val topics: Set<String>,
    /** R2.10：该文档在仓库中是否存在且可读。 */
    val present: Boolean = true,
) {
    init {
        require(id.isNotBlank()) { "baseline id must not be blank" }
        require(path.isNotBlank()) { "baseline $id: path must not be blank" }
        require(dateLabel.isNotBlank()) { "baseline $id: dateLabel must not be blank" }
        require(updatedDate == null || date != null) {
            "baseline $id: updatedDate requires a base date"
        }
        require(updatedDate == null || !updatedDate.isBefore(date)) {
            "baseline $id: updatedDate must not precede date"
        }
    }

    /** 「取新」比较使用的日期：有更新日期取更新日期，否则取文档日期（无 ISO 日期为 null）。 */
    val effectiveDate: LocalDate? get() = updatedDate ?: date
}

/** 冲突中的一方：某份基线文档就争议对象给出的结论。 */
data class BaselineSide(
    val doc: BaselineDoc,
    /** 该文档就争议对象给出的结论文本（非空白）。 */
    val conclusion: String,
    /** 该结论所在的文档小节锚点（§3.4），便于独立复核；可缺省。 */
    val sectionAnchor: String? = null,
) {
    init {
        require(conclusion.isNotBlank()) { "baseline side ${doc.id}: conclusion must not be blank" }
    }
}

/**
 * 支持某一方的仓库代码证据（第 1 级判据，R2.4）。
 *
 * [refs] 为 `文件:行` 证据；[supportsBaselineId] 指明这些证据支持冲突中的哪一方。
 * 「足以判定」要求 [refs] 中至少一条在当前工作副本可定位——不可定位的证据不足以判定，
 * 裁决将退回文档裁决顺序（R2.3 原则）。
 */
data class CodeEvidenceCitation(
    val refs: List<SourceRef>,
    val supportsBaselineId: String,
) {
    init {
        require(refs.isNotEmpty()) { "code evidence citation must carry at least one file:line ref" }
        require(supportsBaselineId.isNotBlank()) { "code evidence must name the baseline it supports" }
    }
}

/**
 * 一次文档基线之间的冲突（R2.8 / R2.9）。
 *
 * [sides] 为持不同结论的各方（≥2，文档编号两两不同）。[contestedTopic] 是争议所属的主题键：
 * 为 null 或未落在任何一方 [BaselineDoc.topics] 内，即「主题归属无法区分」；恰好落在一方即可区分。
 * [codeEvidence] 为支持某一方的仓库代码证据（可为 null——即代码证据不足）。
 */
data class BaselineConflict(
    /** 争议对象（复用 R2.4 的 [ContestedSubject] 模型）。 */
    val subject: ContestedSubject,
    val sides: List<BaselineSide>,
    /** 争议所属主题键；null 表示主题归属无法区分。 */
    val contestedTopic: String? = null,
    /** 支持某一方的仓库代码证据；null 表示无代码证据。 */
    val codeEvidence: CodeEvidenceCitation? = null,
) {
    init {
        require(sides.size >= 2) { "baseline conflict on $subject must have at least two sides" }
        require(sides.map { it.doc.id }.distinct().size == sides.size) {
            "baseline conflict on $subject: sides must cite pairwise different baselines"
        }
        require(codeEvidence == null || sides.any { it.doc.id == codeEvidence.supportsBaselineId }) {
            "baseline conflict on $subject: code evidence must support one of the conflicting sides"
        }
    }

    /** 本方是否被**可定位**的代码证据支持（第 1 级判据）。 */
    internal fun isBackedByLocatableCodeEvidence(side: BaselineSide, locator: SourceLocator): Boolean {
        val citation = codeEvidence ?: return false
        if (citation.supportsBaselineId != side.doc.id) return false
        return citation.refs.any(locator::isLocatable)
    }

    /** 争议主题是否归属本方文档（第 4 级判据）。 */
    internal fun ownsContestedTopic(side: BaselineSide): Boolean {
        val topic = contestedTopic ?: return false
        return topic in side.doc.topics
    }

    /** 主题归属是否可区分：争议主题恰好归属其中一方（R2.9）。 */
    val topicOwnershipDistinguishable: Boolean
        get() = contestedTopic != null && sides.count { ownsContestedTopic(it) } == 1
}

/** 定案级别（`audit-report.md` §3.2 的五级裁决顺序）。 */
enum class BaselineAdjudicationBasis(val label: String) {
    /** 第 1 级：仓库 `文件:行` 代码证据足以判定，不进入文档裁决顺序（R2.4）。 */
    CODE_EVIDENCE("代码证据优先"),

    /** 第 2 级：优先级 ADR 胜次级文档；被否次级条目标记历史内容（R2.8）。 */
    TIER_PRIORITY("层级优先"),

    /** 第 3 级：日期较新者胜（R2.9）。 */
    NEWER_ADR("互冲取新"),

    /** 第 4 级：同日期时争议主题归属方胜（R2.9）。 */
    TOPIC_OWNERSHIP("同日期主题区分"),

    /** 第 5 级：同日期且主题不可辨 ⇒ 待 Apple 侧决策 + 未核实推测（R2.9 兜底）。 */
    PENDING_APPLE_DECISION("待 Apple 侧决策"),
}

/** 被否的一方（R2.8：属次级文档者标记为历史内容）。 */
data class DefeatedBaselineSide(
    val doc: BaselineDoc,
    /** 被否结论文本。 */
    val conclusion: String,
    /** R2.8：被否的次级文档（B4/B5/B6）条目标记为历史内容。 */
    val markedHistorical: Boolean,
)

/**
 * 一次基线冲突的裁决结果（R2.8 / R2.9 / R2.10）。
 *
 * [winningBaseline] 在第 5 级兜底分支为 null（此时 [undecidedSides] 承载全部待决方）。
 * [evaluatedLevels] 记录实际评估过的级别——代码证据定案时它**只含**
 * [BaselineAdjudicationBasis.CODE_EVIDENCE]，即「不进入文档裁决顺序」可被外部观测。
 */
data class BaselineVerdict(
    val subject: ContestedSubject,
    val contestedTopic: String?,
    /** 实际定案的级别。 */
    val basis: BaselineAdjudicationBasis,
    /** 胜方文档；第 5 级兜底为 null。 */
    val winningBaseline: BaselineDoc?,
    /** 胜方结论；第 5 级兜底为 null。 */
    val winningConclusion: String?,
    /** 被否各方（含其结论与历史内容标记）。 */
    val defeatedSides: List<DefeatedBaselineSide>,
    /** 第 5 级兜底时的全部待决方；有胜者时为空。 */
    val undecidedSides: List<BaselineSide>,
    /** 实际评估过的级别（按评估顺序）。 */
    val evaluatedLevels: List<BaselineAdjudicationBasis>,
    /** R2.10：冲突各方中在仓库缺失或不可读的文档编号。 */
    val missingBaselineIds: List<String>,
    /** R2.9 兜底分支，或 R2.10 胜方文档缺失 ⇒ 标注「未核实推测」。 */
    val unverifiedConjecture: Boolean,
) {
    init {
        require((winningBaseline == null) == (basis == BaselineAdjudicationBasis.PENDING_APPLE_DECISION)) {
            "verdict on $subject: winner must be absent exactly in the PENDING_APPLE_DECISION branch"
        }
        require(evaluatedLevels.isNotEmpty()) { "verdict on $subject: evaluatedLevels must not be empty" }
        require(evaluatedLevels.last() == basis) {
            "verdict on $subject: the last evaluated level must be the deciding basis"
        }
        if (basis == BaselineAdjudicationBasis.PENDING_APPLE_DECISION) {
            require(unverifiedConjecture) {
                "verdict on $subject: PENDING_APPLE_DECISION must be marked UNVERIFIED (R2.9)"
            }
            require(undecidedSides.size >= 2) {
                "verdict on $subject: PENDING_APPLE_DECISION must carry the undecided sides"
            }
        }
    }

    /** R2.8：被否条目中是否存在被标记为历史内容者。 */
    val markedHistorical: Boolean get() = defeatedSides.any { it.markedHistorical }

    /** 被否结论文本（R2.4 的「被否结论」在文档裁决面的对应物）。 */
    val defeatedConclusions: List<String> get() = defeatedSides.map { it.conclusion }

    /** 被标记为历史内容的文档编号。 */
    val historicalBaselineIds: List<String>
        get() = defeatedSides.filter { it.markedHistorical }.map { it.doc.id }

    /** 是否需要挂起等待 Apple 侧决策（记入 `gaps/wire-protocol-pending.md`）。 */
    val pendingAppleDecision: Boolean
        get() = basis == BaselineAdjudicationBasis.PENDING_APPLE_DECISION

    /** 置信度标注（复用 R2.3 的 [Confidence] 取值）。 */
    val confidence: Confidence
        get() = if (unverifiedConjecture) {
            Confidence.UNVERIFIED_SPECULATION
        } else {
            Confidence.VERIFIED_BY_REPO_EVIDENCE
        }
}

/**
 * 六份文档基线的登记（`audit-report.md` §3.1，R2.7）。
 *
 * 日期、层级与治理主题范围逐项取自该表；[BaselineDoc.topics] 是主题范围的**键化**表示，
 * 供 R2.9 的「同日期主题区分」使用。
 */
object StandardBaselines {

    /** B1：跨平台互操作与 Apple 归属、单一跨平台契约、Cross_Platform_Lane。 */
    val B1_PEER_FAMILY_PROTOCOL_LANES = BaselineDoc(
        id = "B1",
        path = "docs/ADR-2026-07-23-PEER-FAMILY-PROTOCOL-LANES.md",
        date = LocalDate.of(2026, 7, 23),
        dateLabel = "2026-07-23",
        tier = BaselineTier.PRIORITY_ADR,
        topics = setOf(
            "discovery",
            "connection",
            "transfer",
            "remote-control",
            "cross-platform-lane",
            "apple-ownership",
        ),
    )

    /** B2：协议 / 安全 / 平台基线 / 模块边界 / P2P / WebRTC / Q-Periapt PQC 栈 / 依赖版本。 */
    val B2_ANDROID_P2P_QPERIAPT_STACK = BaselineDoc(
        id = "B2",
        path = "docs/ADR-2026-07-01-ANDROID-P2P-QPERIAPT-STACK.md",
        date = LocalDate.of(2026, 7, 1),
        updatedDate = LocalDate.of(2026, 7, 5),
        dateLabel = "2026-07-01（更新 2026-07-05）",
        tier = BaselineTier.PRIORITY_ADR,
        topics = setOf(
            "protocol",
            "security",
            "platform-baseline",
            "module-boundaries",
            "p2p",
            "webrtc",
            "pqc",
            "dependency-versions",
        ),
    )

    /** B3：Compose UI 架构与视觉对等（玻璃材质、分组层级、语义色、无障碍）。 */
    val B3_ANDROID_UI_GLASS_PARITY = BaselineDoc(
        id = "B3",
        path = "docs/ADR-2026-07-23-ANDROID-UI-GLASS-PARITY.md",
        date = LocalDate.of(2026, 7, 23),
        dateLabel = "2026-07-23",
        tier = BaselineTier.PRIORITY_ADR,
        topics = setOf(
            "compose-ui",
            "visual-parity",
            "glass-material",
            "grouping-hierarchy",
            "semantic-color",
            "accessibility",
        ),
    )

    /** B4：跨平台发现协议栈、服务类型、线协议格式、回退策略（无 ISO 日期）。 */
    val B4_CROSS_PLATFORM_DISCOVERY_DESIGN = BaselineDoc(
        id = "B4",
        path = "CrossPlatformDiscoveryDesign.md",
        date = null,
        dateLabel = "版本 1.0（无 ISO 日期，2025 时期设计稿）",
        tier = BaselineTier.SECONDARY,
        topics = setOf(
            "discovery",
            "service-type",
            "cipher-suites",
            "wire-format",
            "classic-fallback",
        ),
    )

    /** B5：Android PQC 实现指南、握手协议 V2、HPKE 自描述格式。 */
    val B5_ANDROID_PQC_IMPLEMENTATION = BaselineDoc(
        id = "B5",
        path = "Android_PQC_Implementation.md",
        date = LocalDate.of(2025, 12, 16),
        dateLabel = "2025-12-16（版本 1.0.0）",
        tier = BaselineTier.SECONDARY,
        topics = setOf(
            "pqc",
            "wire-format",
            "handshake-v2",
            "hpke-self-describing",
            "downgrade-policy",
        ),
    )

    /** B6：Android 技术栈、项目结构、UI/UX、构建配置（2025 规范，无 ISO 日期）。 */
    val B6_ANDROID_DEVELOPMENT_SPECIFICATION = BaselineDoc(
        id = "B6",
        path = "ANDROID_DEVELOPMENT_SPECIFICATION_2025.md",
        date = null,
        dateLabel = "2025 规范",
        tier = BaselineTier.SECONDARY,
        topics = setOf(
            "android-stack",
            "project-structure",
            "compose-ui",
            "security-spec",
            "build-config",
        ),
    )

    /** B1–B6 全集（Audit_Report 文档基线索引，R2.7）。 */
    val all: List<BaselineDoc> = listOf(
        B1_PEER_FAMILY_PROTOCOL_LANES,
        B2_ANDROID_P2P_QPERIAPT_STACK,
        B3_ANDROID_UI_GLASS_PARITY,
        B4_CROSS_PLATFORM_DISCOVERY_DESIGN,
        B5_ANDROID_PQC_IMPLEMENTATION,
        B6_ANDROID_DEVELOPMENT_SPECIFICATION,
    )

    /** 优先级 ADR（B1、B2、B3）。 */
    val priorityAdrs: List<BaselineDoc> = all.filter { it.tier == BaselineTier.PRIORITY_ADR }

    /** 次级文档（B4、B5、B6）。 */
    val secondaryDocs: List<BaselineDoc> = all.filter { it.tier == BaselineTier.SECONDARY }
}
