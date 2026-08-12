package com.skybridge.compass.audit

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * ConflictRecord / ConflictReconciler / ConflictRecordPublisher 单元测试（任务 5.7 / R2.4、R2.5）。
 *
 * 使用 JUnit Jupiter（与 `:app` 模块 `useJUnitPlatform()` 一致），位于 `test` 源集，
 * 不随生产应用打包。覆盖：
 *  - 无互不相容判定时零条冲突记录（R2.4）
 *  - 单方持可定位证据时该方胜（R2.4 主路径）
 *  - 双方均持可定位证据时按记录数多者胜（确定性次序 1/5）
 *  - 无方持可定位证据时确定性兜底且不作修复依据（R2.3 + R2.4）
 *  - 三项强制内容非空白（双方结论 / 采纳证据 / 被否结论）
 *  - 写入连续失败三次后停止且不回滚已写入内容（R2.5）
 *  - 瞬时失败后重试成功（R2.5 重试路径）
 *  - 全部成功时 writtenIds 等于全部编号（R2.5 正常路径）
 */
class ConflictReconcilerTest {

    // 只把以 "live/" 起始的路径视为可定位（与 PBT 同约定）。
    private val locator = SourceLocator { ref -> ref.file.startsWith("live/") }

    private fun liveRef(file: String, line: Int = 1) =
        SourceRef("live/$file", line)

    private fun staleRef(file: String, line: Int = 1) =
        SourceRef("gone/$file", line)

    private fun subject(id: String) =
        ContestedSubject(SubjectKind.CODE_OBJECT, id)

    private fun judgment(scopeId: String, subject: ContestedSubject, stance: String, conclusion: String, vararg evidence: SourceRef) =
        AuditJudgment(scopeId, subject, stance, conclusion, evidence.toList())

    // region 冲突记录条数（R2.4）

    @Test fun `无互不相容判定时零条冲突记录`() {
        val s = subject("Foo.kt:10")
        val judgments = listOf(
            judgment("S1", s, "缺陷", "S1 判定缺陷", liveRef("Foo.kt", 10)),
            judgment("S2", s, "缺陷", "S2 判定缺陷", staleRef("Foo.kt", 10)),
        )
        val outcome = ConflictReconciler(locator).reconcile(judgments)
        assertTrue(outcome.records.isEmpty(), "全体一致时不写入任何冲突条目")
        assertFalse(outcome.hasConflicts)
        assertEquals(listOf(s), outcome.agreedSubjects)
    }

    @Test fun `单一 subject 互不相容时恰产出一条记录`() {
        val s = subject("Bar.kt:42")
        val judgments = listOf(
            judgment("S1", s, "接通", "S1 判定接通"),
            judgment("S2", s, "移除", "S2 判定移除"),
        )
        val outcome = ConflictReconciler(locator).reconcile(judgments)
        assertEquals(1, outcome.records.size)
        assertTrue(outcome.hasConflicts)
        assertTrue(outcome.agreedSubjects.isEmpty())
        val record = outcome.records.single()
        assertEquals(s, record.subject)
        assertEquals(2, record.sides.size)
    }

    @Test fun `多 subject 混合一致与冲突时条数为冲突数`() {
        val s1 = subject("A.kt:1")
        val s2 = subject("B.kt:2")  // 一致
        val s3 = subject("C.kt:3")
        val judgments = listOf(
            judgment("S1", s1, "缺陷", "A 缺陷"),
            judgment("S2", s1, "非缺陷", "A 非缺陷"),
            judgment("S1", s2, "接通", "B 接通"),
            judgment("S2", s2, "接通", "B 接通（同）"),
            judgment("S3", s3, "移除", "C 移除"),
            judgment("S4", s3, "接通", "C 接通"),
        )
        val outcome = ConflictReconciler(locator).reconcile(judgments)
        assertEquals(2, outcome.records.size)
        assertEquals(listOf(s2), outcome.agreedSubjects)
    }

    // endregion

    // region 证据裁决（R2.4 第二半）

    @Test fun `仅一方持可定位证据时该方胜`() {
        val s = subject("Nsd.kt:95")
        val judgments = listOf(
            judgment("S1", s, "缺陷", "S1 缺陷", liveRef("Nsd.kt", 95)),  // 可定位
            judgment("S2", s, "非缺陷", "S2 非缺陷", staleRef("Nsd.kt", 95)),  // 不可定位
        )
        val outcome = ConflictReconciler(locator).reconcile(judgments)
        val record = outcome.records.single()
        assertEquals("缺陷", record.adoptedSide.stance)
        assertEquals(AdjudicationBasis.SOLE_LOCATABLE_EVIDENCE, record.basis)
        assertTrue(record.verdictBackedByLocatableEvidence)
    }

    @Test fun `双方均持可定位证据时按条数多者胜`() {
        val s = subject("Bootstrap.kt:200")
        val judgments = listOf(
            judgment("S1", s, "缺陷", "S1 缺陷",
                liveRef("Bootstrap.kt", 200), liveRef("Bootstrap.kt", 201)),  // 2条
            judgment("S2", s, "非缺陷", "S2 非缺陷",
                liveRef("Bootstrap.kt", 202)),  // 1条
        )
        val outcome = ConflictReconciler(locator).reconcile(judgments)
        val record = outcome.records.single()
        assertEquals("缺陷", record.adoptedSide.stance)
        assertEquals(AdjudicationBasis.LOCATABLE_EVIDENCE_TIE_BREAK, record.basis)
        assertTrue(record.verdictBackedByLocatableEvidence)
    }

    @Test fun `无方持可定位证据时确定性兜底且不作修复依据`() {
        val s = subject("Deleted.kt:5")
        val judgments = listOf(
            judgment("S1", s, "接通", "S1 接通", staleRef("Deleted.kt", 5)),
            judgment("S2", s, "移除", "S2 移除", staleRef("Deleted.kt", 6)),
        )
        val outcome = ConflictReconciler(locator).reconcile(judgments)
        val record = outcome.records.single()
        assertEquals(AdjudicationBasis.NO_LOCATABLE_EVIDENCE_TIE_BREAK, record.basis)
        assertEquals(ConflictRecord.NO_LOCATABLE_EVIDENCE, record.adoptedEvidence)
        assertFalse(record.verdictBackedByLocatableEvidence)
        // 裁决结果唯一（确定性）。
        val again = ConflictReconciler(locator).reconcile(judgments.reversed())
        assertEquals(record.adoptedSide.stance, again.records.single().adoptedSide.stance)
    }

    @Test fun `三项强制内容均非空白`() {
        val s = subject("Input.kt:33")
        val judgments = listOf(
            judgment("S1", s, "接通", "接通结论", liveRef("Input.kt", 33)),
            judgment("S2", s, "移除", "移除结论"),
        )
        val record = ConflictReconciler(locator).reconcile(judgments).records.single()
        assertTrue(record.sides.all { it.conclusion.isNotBlank() }, "双方结论非空白")
        assertTrue(record.adoptedEvidence.isNotBlank(), "采纳证据非空白")
        assertTrue(record.rejectedConclusions.isNotEmpty(), "被否结论非空")
        assertTrue(record.rejectedConclusions.all { it.isNotBlank() }, "被否结论每条非空白")
    }

    // endregion

    // region 写入上界与失败处置（R2.5）

    @Test fun `全部成功时 writtenIds 等于全部编号`() {
        val records = makeRecords(3)
        val publisher = ConflictRecordPublisher(writer = { _, _ -> /* 成功 */ })
        val outcome = publisher.publish(records) as PublishOutcome.Completed
        assertFalse(outcome.shouldHalt)
        assertEquals(records.map { it.id }, outcome.writtenIds)
        outcome.attemptsPerRecord.values.forEach { assertEquals(1, it) }
    }

    @Test fun `瞬时失败后重试成功则 Completed 且记录正确尝试次数`() {
        val records = makeRecords(2)
        var callCount = 0
        val publisher = ConflictRecordPublisher(writer = { record, _ ->
            callCount++
            if (record.id == records[0].id && callCount == 1) error("one-shot failure")
        })
        val outcome = publisher.publish(records) as PublishOutcome.Completed
        assertFalse(outcome.shouldHalt)
        assertEquals(records.map { it.id }, outcome.writtenIds)
        assertEquals(2, outcome.attemptsPerRecord[records[0].id])
        assertEquals(1, outcome.attemptsPerRecord[records[1].id])
    }

    @Test fun `连续失败三次后停止不回滚且报告受影响编号`() {
        val records = makeRecords(4)
        // 首条始终失败，其余成功。
        val publisher = ConflictRecordPublisher(writer = { record, _ ->
            if (record.id == records[0].id) error("persistent failure")
        })
        val outcome = publisher.publish(records) as PublishOutcome.Stopped
        assertTrue(outcome.shouldHalt)
        assertEquals(emptyList<String>(), outcome.writtenIds)        // 失败点之前无已写记录
        assertEquals(records[0].id, outcome.failedId)
        assertEquals(records.map { it.id }, outcome.affectedIds)
        assertEquals(ConflictRecordPublisher.MAX_WRITE_ATTEMPTS, outcome.attemptsUsed)
        assertTrue(outcome.reason.isNotBlank())
    }

    @Test fun `中间记录失败后之前已写记录保留且之后记录不被尝试`() {
        val records = makeRecords(4)
        // records[2] 始终失败。
        val attempted = mutableListOf<String>()
        val publisher = ConflictRecordPublisher(writer = { record, _ ->
            attempted += record.id
            if (record.id == records[2].id) error("midway failure")
        })
        val outcome = publisher.publish(records) as PublishOutcome.Stopped
        assertTrue(outcome.shouldHalt)
        // 失败点之前的两条已成功写入，不回滚。
        assertEquals(records.take(2).map { it.id }, outcome.writtenIds)
        assertEquals(records[2].id, outcome.failedId)
        // records[3] 从未被尝试。
        assertFalse(attempted.contains(records[3].id), "停止后不再尝试后续记录")
        assertEquals(records.drop(2).map { it.id }, outcome.affectedIds)
    }

    @Test fun `单条记录尝试次数不超过 maxAttempts`() {
        val records = makeRecords(1)
        val calls = mutableListOf<Int>()
        val publisher = ConflictRecordPublisher(writer = { _, attempt ->
            calls += attempt
            error("always fails")
        })
        val outcome = publisher.publish(records) as PublishOutcome.Stopped
        assertEquals(ConflictRecordPublisher.MAX_WRITE_ATTEMPTS, calls.size)
        assertEquals((1..ConflictRecordPublisher.MAX_WRITE_ATTEMPTS).toList(), calls)
        assertEquals(ConflictRecordPublisher.MAX_WRITE_ATTEMPTS, outcome.attemptsUsed)
    }

    // endregion

    // region 辅助

    /** 生成 [n] 条合法冲突记录（最小内容，无需真实裁决）。 */
    private fun makeRecords(n: Int): List<ConflictRecord> {
        val allocator = GapIdAllocator(prefix = ConflictReconciler.CONFLICT_ID_PREFIX)
        return (1..n).map { i ->
            val sideA = ConflictSide("S1", "接通", "接通 $i", emptyList(), emptyList())
            val sideB = ConflictSide("S2", "移除", "移除 $i", emptyList(), emptyList())
            ConflictRecord(
                id = allocator.next(),
                subject = subject("Obj$i"),
                sides = listOf(sideA, sideB),
                adoptedSide = sideA,
                adoptedEvidence = ConflictRecord.NO_LOCATABLE_EVIDENCE,
                rejectedConclusions = listOf("[S2] 移除 $i（被否；其引用证据：无引用证据）"),
                basis = AdjudicationBasis.NO_LOCATABLE_EVIDENCE_TIE_BREAK,
            )
        }
    }

    // endregion
}
