package com.skybridge.compass.audit

/**
 * 冲突检测与证据裁决（Cross-Platform Parity Audit，任务 5.7 / R2.4、R2.5）。
 *
 * 该文件是**审计工具代码**，位于 `:app` 模块的 `test` 源集，不随生产应用打包（遵守 G3）。
 *
 * ## 与 design.md 契约的对应与偏差（如实记录）
 *
 * design.md 给出的契约是 `fun reconcile(results: List<AuditWorkerResult>): ReconciliationOutcome`
 * （注释：「冲突以双方 文件:行 证据裁决，写入冲突记录（R2.4）」）。落地实现的
 * [AuditWorkerResult]（见 [AuditScope]）只承载 `scopeId` / `producedPaths` / `outOfScopePaths`，
 * **不承载判定内容**——它是任务 4.3 的越范围检测结果类型，没有 design 草案里的 `gapItems` 字段。
 * 因此本实现把裁决的输入面显式建模为 [AuditJudgment] 列表（一个审查任务对一个争议对象的一条判定），
 * 主入口为 [reconcile]，并提供 [reconcileResults] 以 `(AuditWorkerResult, 判定列表)` 配对的形式
 * 贴合 design 的调用形态。未擅自修改 [AuditWorkerResult]，以免破坏任务 4.3 的既有测试。
 *
 * ## 冲突判定（R2.4 前半：条数）
 *
 * 按 [ContestedSubject] 分组。同一 subject 上出现**两个及以上不同 [AuditJudgment.stance]** 即为
 * 一次互不相容判定，产出**恰好一条** [ConflictRecord]；同一 subject 上全部判定 stance 相同
 * （无论有多少个审查任务、多少条证据）则**不产出任何条目**——即 R2.4「不存在冲突时不写入冲突条目」。
 * 故 `records.size` 恒等于「存在互不相容判定的 subject 个数」。
 *
 * ## 证据裁决（R2.4 后半：唯一判定）
 *
 * 只认在当前工作副本**可定位**的 `文件:行` 证据（[SourceLocator]，与 R2.3 同一口径：不可定位的
 * 证据不能确立已核实结论，因此**不可定位的证据不得取胜**）。裁决规则是一个**全序**比较器，
 * 逐级比较、前一级可分则不再看后一级：
 *
 *  1. **持可定位证据者优先**。仅一方持有 ⇒ 该方胜，依据记 [AdjudicationBasis.SOLE_LOCATABLE_EVIDENCE]。
 *  2. **可定位证据条数多者优先**（多方均持可定位证据时）。
 *  3. **可定位证据的最小 `文件:行` 文本字典序在前者优先**（确定性，不依赖输入顺序）。
 *  4. **`scopeIds` 字典序在前者优先**。
 *  5. **`stance` 字典序在前者优先**（stance 在同一 subject 内两两不同，故该级必定可分，比较器为全序）。
 *
 * 第 2–5 级生效时依据记 [AdjudicationBasis.LOCATABLE_EVIDENCE_TIE_BREAK]。
 *
 * **无一方持可定位证据时**：R2.4 仍要求「作出唯一判定」，故按同一比较器的第 3–5 级兜底选出唯一一方，
 * 依据记 [AdjudicationBasis.NO_LOCATABLE_EVIDENCE_TIE_BREAK]，采纳证据文本写
 * [ConflictRecord.NO_LOCATABLE_EVIDENCE]，且 [ConflictRecord.verdictBackedByLocatableEvidence]
 * 为 false —— 该裁决**不作为修复决策依据**（R2.3 原则的延续）。
 */
class ConflictReconciler(
    /** `文件:行` 可定位性判定（R2.3 / R2.4 的裁决依据）。 */
    private val locator: SourceLocator,
    /** 冲突编号分配器；跨多次 [reconcile] 复用同一实例可保证编号全局不复用。 */
    private val idAllocator: GapIdAllocator = GapIdAllocator(prefix = CONFLICT_ID_PREFIX),
) {

    /**
     * 检测互不相容判定并逐个裁决。
     *
     * 结果条目顺序稳定（按各 subject 在 [judgments] 中首次出现的顺序），编号按该顺序递增分配。
     * 无冲突时 [ReconciliationOutcome.records] 为空列表（R2.4）。
     */
    fun reconcile(judgments: List<AuditJudgment>): ReconciliationOutcome {
        // 按 subject 分组，保持首次出现顺序。
        val bySubject = LinkedHashMap<ContestedSubject, MutableList<AuditJudgment>>()
        for (j in judgments) {
            bySubject.getOrPut(j.subject) { mutableListOf() } += j
        }

        val records = mutableListOf<ConflictRecord>()
        val agreedSubjects = mutableListOf<ContestedSubject>()

        for ((subject, group) in bySubject) {
            val stances = group.map { it.stance }.distinct()
            if (stances.size < 2) {
                // 无互不相容判定 → 不写入冲突条目（R2.4）。
                agreedSubjects += subject
                continue
            }
            records += adjudicate(subject, group, stances)
        }

        return ReconciliationOutcome(
            records = records,
            agreedSubjects = agreedSubjects,
        )
    }

    /**
     * design 形态的便捷入口：以 `(审查任务结果, 该审查任务的判定列表)` 配对调用。
     *
     * 仅取**有效**（[AuditWorkerResult.valid]，即无越范围路径）审查任务的判定参与裁决——越范围
     * 返回在 R2.11 下已被视为无效，不应贡献结论。
     */
    fun reconcileResults(
        results: List<Pair<AuditWorkerResult, List<AuditJudgment>>>,
    ): ReconciliationOutcome = reconcile(
        results.filter { (result, _) -> result.valid }.flatMap { (_, judgments) -> judgments },
    )

    /** 对单个互不相容 subject 作出唯一裁决并生成一条记录。 */
    private fun adjudicate(
        subject: ContestedSubject,
        group: List<AuditJudgment>,
        stanceOrder: List<String>,
    ): ConflictRecord {
        // 同 stance 的多个审查任务合并为一方；scopeIds 按字典序连接以保证确定性。
        val sides = stanceOrder.map { stance ->
            val holders = group.filter { it.stance == stance }
            val citedEvidence = holders.flatMap { it.evidence }.distinct()
            ConflictSide(
                scopeIds = holders.map { it.scopeId }.distinct().sorted().joinToString("+"),
                stance = stance,
                conclusion = holders.first().conclusion,
                citedEvidence = citedEvidence,
                locatableEvidence = citedEvidence.filter(locator::isLocatable),
            )
        }

        // 全序比较器：胜者为最小元，故结果不依赖 sides 的输入顺序。
        val adopted = sides.minWith(ADJUDICATION_ORDER)
        val anyLocatable = sides.any { it.hasLocatableEvidence }
        val soleLocatable = sides.count { it.hasLocatableEvidence } == 1

        val basis = when {
            soleLocatable -> AdjudicationBasis.SOLE_LOCATABLE_EVIDENCE
            anyLocatable -> AdjudicationBasis.LOCATABLE_EVIDENCE_TIE_BREAK
            else -> AdjudicationBasis.NO_LOCATABLE_EVIDENCE_TIE_BREAK
        }

        val adoptedEvidence = if (adopted.hasLocatableEvidence) {
            adopted.locatableEvidence.map(SourceRef::toString).sorted().joinToString(", ")
        } else {
            ConflictRecord.NO_LOCATABLE_EVIDENCE
        }

        return ConflictRecord(
            id = idAllocator.next(),
            subject = subject,
            sides = sides,
            adoptedSide = adopted,
            adoptedEvidence = adoptedEvidence,
            rejectedConclusions = sides.filter { it !== adopted }.map { rejectedText(it) },
            basis = basis,
        )
    }

    /** 被否结论文本：含被否方标识、其结论与其引用证据，便于报告独立复核。 */
    private fun rejectedText(side: ConflictSide): String {
        val cited = if (side.citedEvidence.isEmpty()) {
            "无引用证据"
        } else {
            side.citedEvidence.map(SourceRef::toString).sorted().joinToString(", ")
        }
        return "[${side.scopeIds}] ${side.conclusion}（被否；其引用证据：$cited）"
    }

    companion object {
        /** 冲突编号前缀（形如 `CONFLICT-0001`）。 */
        const val CONFLICT_ID_PREFIX: String = "CONFLICT-"

        /**
         * 裁决全序（胜者为最小元）。各级含义见类级 KDoc 的「证据裁决」小节。
         *
         * 末级以 [ConflictSide.stance] 收尾：同一 subject 内 stance 两两不同，故该比较器在
         * 一条冲突的各方之间**必定可分**，裁决结果唯一且与输入顺序无关。
         */
        val ADJUDICATION_ORDER: Comparator<ConflictSide> =
            // 1. 持可定位证据者优先（true 先于 false）。
            compareByDescending<ConflictSide> { it.hasLocatableEvidence }
                // 2. 可定位证据条数多者优先。
                .thenByDescending { it.locatableEvidence.size }
                // 3. 可定位证据最小文本字典序在前者优先（无证据方取空串）。
                .thenBy { side ->
                    side.locatableEvidence.map(SourceRef::toString).minOrNull() ?: ""
                }
                // 4. scopeIds 字典序。
                .thenBy { it.scopeIds }
                // 5. stance 字典序（必定可分）。
                .thenBy { it.stance }
    }
}

/**
 * 裁决总结果（R2.4）。
 *
 * [records] 为全部冲突记录——**条数恒等于存在互不相容判定的 subject 个数**，无冲突时为空。
 * [agreedSubjects] 为判定一致（无分歧）因而**未写入任何条目**的 subject，仅用于审计核对。
 */
data class ReconciliationOutcome(
    val records: List<ConflictRecord>,
    val agreedSubjects: List<ContestedSubject>,
) {
    /** 全部冲突编号（应两两不同）。 */
    val ids: List<String> get() = records.map { it.id }

    /** 是否存在冲突条目。 */
    val hasConflicts: Boolean get() = records.isNotEmpty()

    /** 编号是否全部唯一（不复用）。 */
    val allIdsUnique: Boolean get() = ids.size == ids.toSet().size

    /** 由可定位证据确立的裁决（可作修复决策依据）。 */
    val evidenceBackedRecords: List<ConflictRecord>
        get() = records.filter { it.verdictBackedByLocatableEvidence }
}

// region R2.5 —— 冲突记录写入的重试上界与失败处置

/**
 * 冲突记录写入的注入式接缝（R2.5）。抛异常即视为该次写入尝试失败。
 *
 * 真实实现由任务 4.1 的 `AuditReportWriter`（临时文件 + 原子替换）承担；此处抽象为函数接口，
 * 便于以确定性的失败序列单测「至多三次尝试后停止」这一上界。
 */
fun interface ConflictRecordWriter {
    /**
     * 写入一条冲突记录。
     * @param attempt 1 为首次尝试，2..[ConflictRecordPublisher.MAX_WRITE_ATTEMPTS] 为重试序号。
     */
    fun write(record: ConflictRecord, attempt: Int)
}

/**
 * 冲突记录写入器（R2.5）：**每条记录至多尝试三次**；某条记录三次均失败即**停止**——不再尝试写入
 * 后续记录、不再启动新的审查任务与新增审计条目，**已成功写入的内容不做回滚**，并报告失败原因与
 * **受影响的冲突编号**（失败的那条 + 因停止而未写入的后续各条）。
 */
class ConflictRecordPublisher(
    private val writer: ConflictRecordWriter,
    /** 单条记录的最大写入尝试次数（R2.5 要求至多三次）。 */
    val maxAttempts: Int = MAX_WRITE_ATTEMPTS,
) {
    init {
        require(maxAttempts >= 1) { "maxAttempts must be >= 1, was $maxAttempts" }
    }

    /** 按顺序写入 [records]，遇某条记录用满尝试次数仍失败则停止（R2.5）。 */
    fun publish(records: List<ConflictRecord>): PublishOutcome {
        val written = mutableListOf<String>()
        val attemptsPerRecord = LinkedHashMap<String, Int>()

        records.forEachIndexed { index, record ->
            var lastFailure: Throwable? = null
            var attemptsUsed = 0

            for (attempt in 1..maxAttempts) {
                attemptsUsed = attempt
                try {
                    writer.write(record, attempt)
                    lastFailure = null
                    break
                } catch (failure: Throwable) {
                    lastFailure = failure
                }
            }
            attemptsPerRecord[record.id] = attemptsUsed

            if (lastFailure == null) {
                written += record.id
                return@forEachIndexed
            }

            // R2.5：用满尝试次数仍失败 → 停止，保留已写入内容不回滚，报告受影响冲突编号。
            return PublishOutcome.Stopped(
                writtenIds = written.toList(),
                failedId = record.id,
                affectedIds = records.drop(index).map { it.id },
                attemptsUsed = attemptsUsed,
                attemptsPerRecord = attemptsPerRecord,
                reason = lastFailure.message ?: lastFailure::class.simpleName.orEmpty(),
            )
        }

        return PublishOutcome.Completed(
            writtenIds = written.toList(),
            attemptsPerRecord = attemptsPerRecord,
        )
    }

    companion object {
        /** R2.5：至多三次写入尝试。 */
        const val MAX_WRITE_ATTEMPTS: Int = 3
    }
}

/** 冲突记录写入结果（R2.5）。 */
sealed interface PublishOutcome {
    /** 已成功写入的冲突编号（**任何情况下都不回滚**）。 */
    val writtenIds: List<String>

    /** 每条被尝试过的记录实际消耗的尝试次数。 */
    val attemptsPerRecord: Map<String, Int>

    /** 是否应停止启动新审查任务与新增审计条目（R2.5）。 */
    val shouldHalt: Boolean

    /** 全部记录写入成功。 */
    data class Completed(
        override val writtenIds: List<String>,
        override val attemptsPerRecord: Map<String, Int>,
    ) : PublishOutcome {
        override val shouldHalt: Boolean get() = false
    }

    /** 某条记录用满尝试次数仍失败：停止并报告（R2.5）。 */
    data class Stopped(
        override val writtenIds: List<String>,
        /** 写入失败的冲突编号。 */
        val failedId: String,
        /** 受影响的冲突编号：失败的那条 + 因停止而未写入的后续各条。 */
        val affectedIds: List<String>,
        /** 失败记录实际消耗的尝试次数（等于 [ConflictRecordPublisher.maxAttempts]）。 */
        val attemptsUsed: Int,
        override val attemptsPerRecord: Map<String, Int>,
        /** 失败原因（向用户报告）。 */
        val reason: String,
    ) : PublishOutcome {
        override val shouldHalt: Boolean get() = true
    }
}

// endregion
