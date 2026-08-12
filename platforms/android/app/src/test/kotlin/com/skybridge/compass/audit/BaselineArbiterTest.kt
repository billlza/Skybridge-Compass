package com.skybridge.compass.audit

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.time.LocalDate

/**
 * [BaselineArbiter] / [StandardBaselines] 单元测试（任务 5.8 / R2.8、R2.9、R2.10）。
 *
 * 使用 JUnit Jupiter（与 `:app` 模块 `useJUnitPlatform()` 一致），位于 `test` 源集，
 * 不随生产应用打包。与 [BaselineArbiterPropertyTest] 互补：本文件把 `audit-report.md`
 * §3.1–§3.3 登记的**真实 B1..B6 场景**钉成具体用例，覆盖：
 *  - 基线索引登记项与报告表格一致（六份、层级划分、日期）
 *  - 代码证据优先，不进入文档裁决顺序（§3.2 第 1 级）
 *  - 不可定位证据不足以判定，退回文档裁决顺序（R2.3）
 *  - 层级优先与次级文档历史内容标记（§3.2 第 2 级 / §3.3，R2.8）
 *  - ADR 互冲取新（§3.2 第 3 级，R2.9）
 *  - B1/B3 同日期主题区分（§3.2 第 4 级，R2.9）
 *  - 同日期主题不可辨 ⇒ 待 Apple 侧决策 + 未核实推测（§3.2 第 5 级，R2.9）
 *  - 文档缺失时的置信度降级（R2.10）
 */
class BaselineArbiterTest {

    // 只把以 "live/" 起始的路径视为可定位（与 PBT 同约定）。
    private val locator = SourceLocator { ref -> ref.file.startsWith("live/") }
    private val arbiter = BaselineArbiter(locator)

    private val b1 = StandardBaselines.B1_PEER_FAMILY_PROTOCOL_LANES
    private val b2 = StandardBaselines.B2_ANDROID_P2P_QPERIAPT_STACK
    private val b3 = StandardBaselines.B3_ANDROID_UI_GLASS_PARITY
    private val b4 = StandardBaselines.B4_CROSS_PLATFORM_DISCOVERY_DESIGN
    private val b5 = StandardBaselines.B5_ANDROID_PQC_IMPLEMENTATION
    private val b6 = StandardBaselines.B6_ANDROID_DEVELOPMENT_SPECIFICATION

    private fun subject(id: String) = ContestedSubject(SubjectKind.BEHAVIOR, id)

    private fun side(doc: BaselineDoc, conclusion: String) = BaselineSide(doc, conclusion)

    // region 文档基线索引登记（R2.7 / §3.1）

    @Test fun `基线索引登记六份文档，三份优先级 ADR 与三份次级文档`() {
        assertEquals(6, StandardBaselines.all.size)
        assertEquals(listOf("B1", "B2", "B3", "B4", "B5", "B6"), StandardBaselines.all.map { it.id })
        assertEquals(listOf("B1", "B2", "B3"), StandardBaselines.priorityAdrs.map { it.id })
        assertEquals(listOf("B4", "B5", "B6"), StandardBaselines.secondaryDocs.map { it.id })
        assertTrue(StandardBaselines.all.all { it.present }, "本轮六份文档全部存在且可读（§3.1）")
    }

    @Test fun `登记日期与报告表格一致，B2 取更新日期参与取新比较`() {
        assertEquals(LocalDate.of(2026, 7, 23), b1.effectiveDate)
        assertEquals(LocalDate.of(2026, 7, 23), b3.effectiveDate)
        // B2：2026-07-01（更新 2026-07-05）→ 取新比较用 07-05，仍早于 07-23。
        assertEquals(LocalDate.of(2026, 7, 1), b2.date)
        assertEquals(LocalDate.of(2026, 7, 5), b2.effectiveDate)
        assertTrue(b2.effectiveDate!! < b1.effectiveDate!!)
        // B4 / B6 无 ISO 日期。
        assertNull(b4.date)
        assertNull(b6.date)
        assertEquals(LocalDate.of(2025, 12, 16), b5.date)
    }

    @Test fun `B1 与 B3 同日期且治理主题互不重叠（§3_2 第 4 级的前提）`() {
        assertEquals(b1.effectiveDate, b3.effectiveDate)
        assertTrue(b1.topics.intersect(b3.topics).isEmpty(), "B1 与 B3 主题不重叠 ⇒ 主题归属可区分")
    }

    // endregion

    // region 第 1 级：代码证据优先（§3.2 / R2.4）

    @Test fun `可定位代码证据足以判定时由代码证据定案且不进入文档裁决顺序`() {
        val conflict = BaselineConflict(
            subject = subject("HPKE 密封盒线格式"),
            sides = listOf(
                side(b1, "B1：跨平台面以 Cross_Platform_Lane 契约编码"),
                side(b5, "B5：以 HPKE 自描述前缀编码"),
            ),
            contestedTopic = "wire-format",
            codeEvidence = CodeEvidenceCitation(
                refs = listOf(SourceRef("live/core/src/main/kotlin/P2PHPKESealedBox.kt", 53)),
                supportsBaselineId = "B5",
            ),
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.CODE_EVIDENCE, verdict.basis)
        // 「不进入文档裁决顺序」：只评估过第 1 级。
        assertEquals(listOf(BaselineAdjudicationBasis.CODE_EVIDENCE), verdict.evaluatedLevels)
        // 代码证据可以让次级文档胜过优先级 ADR——层级只在代码证据不足时才起作用。
        assertEquals("B5", verdict.winningBaseline?.id)
        assertEquals("B1", verdict.defeatedSides.single().doc.id)
        assertFalse(verdict.defeatedSides.single().markedHistorical, "被否方是 ADR，不标记历史内容")
        assertFalse(verdict.unverifiedConjecture)
        assertEquals(Confidence.VERIFIED_BY_REPO_EVIDENCE, verdict.confidence)
    }

    @Test fun `仅不可定位证据时不足以判定，退回文档裁决顺序（R2_3）`() {
        val conflict = BaselineConflict(
            subject = subject("Bonjour 服务类型集合"),
            sides = listOf(
                side(b1, "B1：单一跨平台契约下的服务类型"),
                side(b4, "B4：多服务类型并行广播"),
            ),
            contestedTopic = "service-type",
            codeEvidence = CodeEvidenceCitation(
                refs = listOf(SourceRef("gone/app/src/main/kotlin/Deleted.kt", 12)),
                supportsBaselineId = "B4",
            ),
        )

        val verdict = arbiter.arbitrate(conflict)

        // 不可定位证据不得取胜 ⇒ 走层级优先，B1 胜。
        assertEquals(BaselineAdjudicationBasis.TIER_PRIORITY, verdict.basis)
        assertEquals("B1", verdict.winningBaseline?.id)
        assertTrue(verdict.defeatedSides.single().markedHistorical)
    }

    // endregion

    // region 第 2 级：层级优先与历史内容标记（§3.2 / §3.3 / R2.8）

    @Test fun `B1 与 B4 冲突时 B1 胜且 B4 条目标记为历史内容`() {
        val conflict = BaselineConflict(
            subject = subject("跨平台 framing 是否唯一"),
            sides = listOf(
                side(b4, "B4：单一通用 framing/传输"),
                side(b1, "B1：按 lane 分族，不要求单一通用 framing"),
            ),
            contestedTopic = "discovery",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.TIER_PRIORITY, verdict.basis)
        assertEquals("B1", verdict.winningBaseline?.id)
        assertEquals(listOf("B4"), verdict.historicalBaselineIds)
        assertTrue(verdict.markedHistorical)
        assertTrue(verdict.defeatedConclusions.single().contains("单一通用 framing"))
        assertFalse(verdict.pendingAppleDecision)
        assertFalse(verdict.unverifiedConjecture)
    }

    @Test fun `B3 与 B6 的 2025 UI 示例冲突时 B3 胜且 B6 标记历史内容`() {
        val conflict = BaselineConflict(
            subject = subject("Compose 分组容器层级"),
            sides = listOf(
                side(b3, "B3：玻璃材质分组容器 + 语义色"),
                side(b6, "B6：2025 UI 示例的容器写法"),
            ),
            contestedTopic = "compose-ui",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.TIER_PRIORITY, verdict.basis)
        assertEquals("B3", verdict.winningBaseline?.id)
        assertEquals(listOf("B6"), verdict.historicalBaselineIds)
    }

    @Test fun `B2 与 B5 的 PQC 冲突时 B2 胜且 B5 标记历史内容`() {
        val conflict = BaselineConflict(
            subject = subject("PQC 降级策略"),
            sides = listOf(
                side(b5, "B5：允许降级到经典套件"),
                side(b2, "B2：失败不降级"),
            ),
            contestedTopic = "pqc",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.TIER_PRIORITY, verdict.basis)
        assertEquals("B2", verdict.winningBaseline?.id)
        assertEquals(listOf("B5"), verdict.historicalBaselineIds)
        assertTrue(verdict.defeatedConclusions.single().contains("允许降级"))
    }

    // endregion

    // region 第 3 级：ADR 互冲取新（§3.2 / R2.9）

    @Test fun `B1 与 B2 同为 ADR 时取日期较新的 B1`() {
        val conflict = BaselineConflict(
            subject = subject("跨平台契约归属"),
            sides = listOf(
                side(b2, "B2：协议与模块边界以本 ADR 为准"),
                side(b1, "B1：跨平台互操作以 Cross_Platform_Lane 为准"),
            ),
            // 主题 protocol 只属 B2——但第 3 级已可分，第 4 级不应被咨询。
            contestedTopic = "protocol",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.NEWER_ADR, verdict.basis)
        assertEquals("B1", verdict.winningBaseline?.id)
        assertFalse(
            BaselineAdjudicationBasis.TOPIC_OWNERSHIP in verdict.evaluatedLevels,
            "第 3 级已定案，不应进入第 4 级",
        )
        assertFalse(verdict.markedHistorical, "被否方 B2 是 ADR，不标记历史内容")
    }

    @Test fun `B4 与 B5 同为次级文档时取有 ISO 日期的 B5（无日期视为最旧）`() {
        val conflict = BaselineConflict(
            subject = subject("线格式编码"),
            sides = listOf(
                side(b4, "B4：固定长度前缀"),
                side(b5, "B5：自描述前缀"),
            ),
            contestedTopic = "wire-format",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.NEWER_ADR, verdict.basis)
        assertEquals("B5", verdict.winningBaseline?.id)
        // 两方同为次级 ⇒ 被否的 B4 仍标记历史内容（R2.8）。
        assertEquals(listOf("B4"), verdict.historicalBaselineIds)
    }

    // endregion

    // region 第 4 级：同日期主题区分（§3.2 / R2.9）

    @Test fun `B1 与 B3 同日期时协议类主题归 B1`() {
        val conflict = BaselineConflict(
            subject = subject("远程控制通道归属"),
            sides = listOf(
                side(b3, "B3：以 UI 对等为准"),
                side(b1, "B1：以 lane 协议归属为准"),
            ),
            contestedTopic = "remote-control",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.TOPIC_OWNERSHIP, verdict.basis)
        assertEquals("B1", verdict.winningBaseline?.id)
        assertFalse(verdict.unverifiedConjecture)
        assertFalse(verdict.pendingAppleDecision)
    }

    @Test fun `B1 与 B3 同日期时 Compose 视觉对等主题归 B3`() {
        val conflict = BaselineConflict(
            subject = subject("玻璃材质分组层级"),
            sides = listOf(
                side(b1, "B1：以协议归属为准"),
                side(b3, "B3：以 Compose 视觉对等为准"),
            ),
            contestedTopic = "visual-parity",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.TOPIC_OWNERSHIP, verdict.basis)
        assertEquals("B3", verdict.winningBaseline?.id)
        assertEquals(Confidence.VERIFIED_BY_REPO_EVIDENCE, verdict.confidence)
    }

    // endregion

    // region 第 5 级：同日期主题不可辨 ⇒ 待 Apple 侧决策 + 未核实推测（§3.2 / R2.9）

    @Test fun `B1 与 B3 同日期且主题不属任何一方时挂起待 Apple 侧决策`() {
        val conflict = BaselineConflict(
            subject = subject("某未归属主题的争议"),
            sides = listOf(
                side(b1, "B1 结论"),
                side(b3, "B3 结论"),
            ),
            contestedTopic = "unknown-topic",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.PENDING_APPLE_DECISION, verdict.basis)
        assertTrue(verdict.pendingAppleDecision)
        assertTrue(verdict.unverifiedConjecture)
        assertEquals(Confidence.UNVERIFIED_SPECULATION, verdict.confidence)
        assertNull(verdict.winningBaseline)
        assertNull(verdict.winningConclusion)
        assertTrue(verdict.defeatedSides.isEmpty(), "兜底分支不选出胜者，故无被否方")
        assertEquals(listOf("B1", "B3"), verdict.undecidedSides.map { it.doc.id })
        assertEquals(BaselineAdjudicationBasis.entries.toList(), verdict.evaluatedLevels)
    }

    @Test fun `无争议主题的同日期 ADR 冲突同样挂起待 Apple 侧决策`() {
        val conflict = BaselineConflict(
            subject = subject("未指明主题的争议"),
            sides = listOf(side(b1, "B1 结论"), side(b3, "B3 结论")),
            contestedTopic = null,
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.PENDING_APPLE_DECISION, verdict.basis)
        assertTrue(verdict.unverifiedConjecture)
        assertFalse(verdict.markedHistorical)
    }

    // endregion

    // region R2.10：文档缺失时的置信度降级

    @Test fun `胜方文档缺失时结论降级为未核实推测（R2_10）`() {
        val missingB1 = b1.copy(present = false)
        val conflict = BaselineConflict(
            subject = subject("发现协议栈归属"),
            sides = listOf(
                side(missingB1, "B1：以 lane 协议归属为准"),
                side(b4, "B4：单一通用 framing"),
            ),
            contestedTopic = "discovery",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        // 缺失不改变裁决顺序：层级优先仍让 B1 胜。
        assertEquals(BaselineAdjudicationBasis.TIER_PRIORITY, verdict.basis)
        assertEquals("B1", verdict.winningBaseline?.id)
        // 但该结论仅依赖一份读不到的文档 ⇒ 降级为未核实推测（R2.10）。
        assertTrue(verdict.unverifiedConjecture)
        assertEquals(Confidence.UNVERIFIED_SPECULATION, verdict.confidence)
        assertEquals(listOf("B1"), verdict.missingBaselineIds)
        // 被否的次级条目仍标记历史内容。
        assertEquals(listOf("B4"), verdict.historicalBaselineIds)
    }

    @Test fun `仅被否方文档缺失时胜方结论不降级（R2_10）`() {
        val missingB4 = b4.copy(present = false)
        val conflict = BaselineConflict(
            subject = subject("发现协议栈归属"),
            sides = listOf(
                side(b1, "B1：以 lane 协议归属为准"),
                side(missingB4, "B4：单一通用 framing"),
            ),
            contestedTopic = "discovery",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(conflict)

        assertEquals(BaselineAdjudicationBasis.TIER_PRIORITY, verdict.basis)
        assertEquals("B1", verdict.winningBaseline?.id)
        assertFalse(verdict.unverifiedConjecture, "胜方文档可读 ⇒ 不降级")
        assertEquals(Confidence.VERIFIED_BY_REPO_EVIDENCE, verdict.confidence)
        assertEquals(listOf("B4"), verdict.missingBaselineIds)
    }

    // endregion

    // region 确定性（置换不变）

    @Test fun `三方冲突的裁决结果与输入顺序无关`() {
        val sides = listOf(
            side(b1, "B1 结论"),
            side(b4, "B4 结论"),
            side(b5, "B5 结论"),
        )
        val base = BaselineConflict(
            subject = subject("三方争议"),
            sides = sides,
            contestedTopic = "wire-format",
            codeEvidence = null,
        )

        val verdict = arbiter.arbitrate(base)
        assertEquals(BaselineAdjudicationBasis.TIER_PRIORITY, verdict.basis)
        assertEquals("B1", verdict.winningBaseline?.id)
        // 两份被否次级文档都标记历史内容。
        assertEquals(listOf("B4", "B5"), verdict.historicalBaselineIds)

        // 全部置换逐字段相等。
        listOf(
            listOf(sides[1], sides[0], sides[2]),
            listOf(sides[2], sides[1], sides[0]),
            listOf(sides[1], sides[2], sides[0]),
            sides.reversed(),
        ).forEach { permuted ->
            assertEquals(verdict, arbiter.arbitrate(base.copy(sides = permuted)))
        }
    }

    // endregion
}
