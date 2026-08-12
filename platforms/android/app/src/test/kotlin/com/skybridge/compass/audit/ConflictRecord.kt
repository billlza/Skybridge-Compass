package com.skybridge.compass.audit

/**
 * 冲突记录数据模型（Cross-Platform Parity Audit，任务 5.7 / R2.4、R2.5）。
 *
 * 该文件是**审计工具代码**，位于 `:app` 模块的 `test` 源集（与 [GapItem]、[AuditScope]、
 * [ParityAuditScheduler] 同包），不随生产应用打包（遵守 G3：仅 Kotlin；不改动 Apple 源码树）。
 *
 * 背景：任务 4.5 / 4.6 已把冲突记录作为**文档**产出（`audit-report.md` §4，本轮结论为"未发现
 * 互不相容判定，故不写入冲突条目"）。本文件把该文档规则落成可执行的纯 Kotlin 裁决单元，
 * 使 R2.4 的两个半部（**条数**与**证据裁决**）可被属性测试机器校验。
 *
 * R2.4 逐句到类型的映射：
 *  - 「两个审查任务对同一代码对象或同一行为给出互不相容的判定」→ 同一 [ContestedSubject] 上
 *    出现两个及以上不同 [AuditJudgment.stance] 的判定（见 [ConflictReconciler]）。
 *  - 「以双方引用的 `文件:行` 代码证据为准作出唯一判定」→ [ConflictRecord.adoptedSide] 唯一，
 *    裁决依据为各方证据的**可定位性**（[SourceLocator]，与 R2.3 同一口径）。
 *  - 「记录冲突双方的结论、采纳的证据与被否结论」→ [ConflictRecord.sides]（含全部各方结论）、
 *    [ConflictRecord.adoptedEvidence]、[ConflictRecord.rejectedConclusions]，三者均非空白。
 *  - 「不存在冲突时不写入冲突条目」→ 无分歧的 subject 不产出任何 [ConflictRecord]。
 */

/**
 * 争议对象：R2.4 中的「同一代码对象或同一行为」。
 *
 * [kind] 区分二者（代码对象 / 行为），[identifier] 是该对象或行为在审计内的稳定标识
 * （例如代码对象用 `文件` 或完全限定名，行为用行为描述键）。相等判定即"是否为同一争议对象"。
 */
data class ContestedSubject(
    val kind: SubjectKind,
    val identifier: String,
) {
    init {
        require(identifier.isNotBlank()) { "contested subject identifier must not be blank" }
    }

    override fun toString(): String = "${kind.label}:$identifier"
}

/** 争议对象的两类形态（R2.4：「同一代码对象或同一行为」）。 */
enum class SubjectKind(val label: String) {
    /** 代码对象：类、函数、声明点等。 */
    CODE_OBJECT("代码对象"),

    /** 行为：运行时可观察的行为判定。 */
    BEHAVIOR("行为"),
}

/**
 * 一个审查任务对某个 [ContestedSubject] 给出的判定。
 *
 * [stance] 是**归一化后的结论取值**：两条判定互不相容当且仅当二者 subject 相同而 stance 不同。
 * [conclusion] 是该结论的人类可读文本（写入报告的「冲突双方的结论」）。
 * [evidence] 是该方引用的 `文件:行` 证据（可为空——此时该方无证据可依，见 [ConflictReconciler]）。
 */
data class AuditJudgment(
    /** 产出该判定的审查任务范围标识（S1..S4）。 */
    val scopeId: String,
    val subject: ContestedSubject,
    /** 归一化结论取值；相同 subject 上取值不同即互不相容。 */
    val stance: String,
    /** 结论文本（非空白）。 */
    val conclusion: String,
    /** 该方引用的 `文件:行` 证据。 */
    val evidence: List<SourceRef> = emptyList(),
) {
    init {
        require(scopeId.isNotBlank()) { "judgment scopeId must not be blank" }
        require(stance.isNotBlank()) { "judgment stance must not be blank" }
        require(conclusion.isNotBlank()) { "judgment conclusion must not be blank" }
    }
}

/**
 * 冲突记录中的一方（同一 stance 可由多个审查任务共同持有）。
 *
 * [locatableEvidence] 是本方证据中在当前工作副本**可定位**的子集——R2.3 的原则是不可定位的
 * 证据不能确立"已核实"的结论，因此裁决只认这部分（见 [ConflictReconciler] 的裁决规则）。
 */
data class ConflictSide(
    /** 持有本方结论的审查任务范围标识（多个时按字典序以 `+` 连接，保证确定性）。 */
    val scopeIds: String,
    val stance: String,
    /** 本方结论文本（写入报告的「冲突双方的结论」之一），非空白。 */
    val conclusion: String,
    /** 本方引用的全部 `文件:行` 证据。 */
    val citedEvidence: List<SourceRef>,
    /** 本方证据中可定位的子集（裁决的实际依据）。 */
    val locatableEvidence: List<SourceRef>,
) {
    init {
        require(scopeIds.isNotBlank()) { "conflict side scopeIds must not be blank" }
        require(stance.isNotBlank()) { "conflict side stance must not be blank" }
        require(conclusion.isNotBlank()) { "conflict side conclusion must not be blank" }
        require(locatableEvidence.all { it in citedEvidence }) {
            "locatableEvidence must be a subset of citedEvidence"
        }
    }

    /** 本方是否有可定位的 `文件:行` 证据（R2.3 口径下能否确立已核实结论）。 */
    val hasLocatableEvidence: Boolean get() = locatableEvidence.isNotEmpty()
}

/**
 * 一条冲突记录（R2.4）。**每个互不相容的 subject 恰好产出一条**，且 [adoptedSide] 唯一。
 *
 * 三项强制内容（R2.4「记录冲突双方的结论、采纳的证据与被否结论」）：
 *  1. [sides] —— 冲突各方的结论（≥2 方，每方 [ConflictSide.conclusion] 非空白）；
 *  2. [adoptedEvidence] —— 采纳的证据文本（非空白；无任何一方持可定位证据时为显式说明文本，
 *     见 [NO_LOCATABLE_EVIDENCE]）；
 *  3. [rejectedConclusions] —— 被否结论（非空，每条非空白）。
 */
data class ConflictRecord(
    /** Audit_Report 内唯一且不复用的冲突编号（形如 `CONFLICT-0001`）。 */
    val id: String,
    val subject: ContestedSubject,
    /** 冲突各方（≥2）。 */
    val sides: List<ConflictSide>,
    /** 唯一裁决：被采纳的一方（必属于 [sides]）。 */
    val adoptedSide: ConflictSide,
    /** 采纳的证据文本（非空白）。 */
    val adoptedEvidence: String,
    /** 被否结论文本（非空，每条非空白）。 */
    val rejectedConclusions: List<String>,
    /** 裁决依据分类。 */
    val basis: AdjudicationBasis,
) {
    init {
        require(id.isNotBlank()) { "conflict id must not be blank" }
        require(sides.size >= 2) { "conflict $id must have at least two sides (R2.4)" }
        require(sides.map { it.stance }.distinct().size == sides.size) {
            "conflict $id: sides must hold pairwise different stances"
        }
        require(adoptedSide in sides) { "conflict $id: adopted side must be one of sides" }
        require(adoptedEvidence.isNotBlank()) { "conflict $id: adoptedEvidence must not be blank (R2.4)" }
        require(rejectedConclusions.isNotEmpty()) {
            "conflict $id: rejectedConclusions must not be empty (R2.4)"
        }
        require(rejectedConclusions.all { it.isNotBlank() }) {
            "conflict $id: every rejected conclusion must not be blank (R2.4)"
        }
        require(rejectedConclusions.size == sides.size - 1) {
            "conflict $id: rejected conclusions must cover exactly the non-adopted sides"
        }
    }

    /** 被否的各方（[sides] 去掉 [adoptedSide]）。 */
    val rejectedSides: List<ConflictSide> get() = sides.filter { it !== adoptedSide }

    /**
     * 本条裁决是否由可定位证据确立（R2.3 原则）。为 false 时该裁决不得作为修复决策依据。
     */
    val verdictBackedByLocatableEvidence: Boolean
        get() = basis != AdjudicationBasis.NO_LOCATABLE_EVIDENCE_TIE_BREAK

    companion object {
        /** 无任何一方持可定位证据时写入的显式采纳证据说明（R2.3：不可定位证据不能确立已核实结论）。 */
        const val NO_LOCATABLE_EVIDENCE: String =
            "无可定位 文件:行 证据；按确定性兜底规则裁决，该判定不作为修复决策依据"
    }
}

/** 裁决依据分类（对应 [ConflictReconciler] 的裁决规则各分支）。 */
enum class AdjudicationBasis(val label: String) {
    /** 仅一方持可定位证据 → 该方胜（R2.4 主路径）。 */
    SOLE_LOCATABLE_EVIDENCE("唯一持可定位证据方胜"),

    /** 多方均持可定位证据 → 按确定性次序裁决（可定位证据条数多者优先）。 */
    LOCATABLE_EVIDENCE_TIE_BREAK("多方均持可定位证据，按确定性次序裁决"),

    /** 无一方持可定位证据 → 确定性兜底，且裁决不作为修复决策依据（R2.3）。 */
    NO_LOCATABLE_EVIDENCE_TIE_BREAK("无方持可定位证据，确定性兜底且不作修复依据"),
}
