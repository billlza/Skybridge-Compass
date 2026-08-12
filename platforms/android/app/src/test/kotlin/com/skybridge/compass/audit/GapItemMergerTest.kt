package com.skybridge.compass.audit

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * GapItem / GapItemMerger 单元测试（任务 4.4 / R2.2、R2.3）。
 *
 * 使用 JUnit Jupiter（与 `:app` 模块 `useJUnitPlatform()` 一致），位于 `test` 源集，
 * 不随生产应用打包。覆盖：
 *  - 归并后编号跨范围唯一（R2.2）
 *  - 置信度由是否存在可定位 `文件:行` 证据派生（R2.3）
 *  - 无证据（或全部证据不可定位）的条目标注为未核实推测且被排除出修复决策集合（R2.3）
 *  - 同一分配器跨多次归并不复用编号（R2.2）
 *  - 去重合并证据、不为重复项各占编号
 *  - SourceRef 解析/格式化与 GapItem 结构不变式
 */
class GapItemMergerTest {

    // 只把这些路径视为"当前工作副本可定位"。
    private fun locatorFor(vararg locatable: String): SourceLocator {
        val set = locatable.toSet()
        return SourceLocator { ref -> ref.toString() in set }
    }

    private fun draft(
        category: GapCategory = GapCategory.HALF_WIRING,
        evidence: List<SourceRef> = emptyList(),
        subsystem: String = "Discovery_Subsystem",
        impact: String = "对端不出现在设备列表",
        verdict: String = "运行 X 后设备列表包含该对端",
        scopeId: String = "S1",
    ) = GapItemDraft(
        category = category,
        evidence = evidence,
        subsystem = subsystem,
        userVisibleImpact = impact,
        verdictCondition = verdict,
        scopeId = scopeId,
    )

    // region 编号唯一（R2.2）

    @Test
    fun mergeAssignsUniqueSequentialIdsAcrossScopes() {
        val merger = GapItemMerger(locator = locatorFor())
        val drafts = listOf(
            draft(scopeId = "S1", impact = "发现缺口", evidence = listOf(SourceRef("device-discovery/src/A.kt", 10))),
            draft(scopeId = "S2", impact = "传输缺口", evidence = listOf(SourceRef("file-transfer/src/B.kt", 20))),
            draft(scopeId = "S3", impact = "远桌缺口", evidence = listOf(SourceRef("remote-control/src/C.kt", 30))),
            draft(scopeId = "S4", impact = "设置缺口", evidence = listOf(SourceRef("app/src/D.kt", 40))),
        )

        val result = merger.merge(drafts)

        assertEquals(4, result.items.size)
        assertTrue(result.allIdsUnique, "ids must be unique across merged scopes (R2.2)")
        assertEquals(listOf("GAP-0001", "GAP-0002", "GAP-0003", "GAP-0004"), result.ids)
        // 溯源保留各自 scopeId。
        assertEquals(setOf("S1", "S2", "S3", "S4"), result.items.map { it.scopeId }.toSet())
    }

    @Test
    fun idsAreNotReusedAcrossMultipleMergesWithSameAllocator() {
        val allocator = GapIdAllocator()
        val merger = GapItemMerger(locator = locatorFor(), idAllocator = allocator)

        val first = merger.merge(listOf(draft(impact = "a"), draft(impact = "b")))
        val second = merger.merge(listOf(draft(impact = "c"), draft(impact = "d")))

        assertEquals(listOf("GAP-0001", "GAP-0002"), first.ids)
        assertEquals(listOf("GAP-0003", "GAP-0004"), second.ids)

        val all = first.ids + second.ids
        assertEquals(all.size, all.toSet().size, "ids must not be reused across merge calls (R2.2)")
        assertEquals(4, allocator.issued.size)
    }

    @Test
    fun allocatorNeverReusesAndTracksIssued() {
        val allocator = GapIdAllocator()
        val ids = (1..1000).map { allocator.next() }
        assertEquals(1000, ids.toSet().size, "allocator must never reuse an id")
        assertEquals("GAP-0001", ids.first())
        assertEquals("GAP-1000", ids.last())
        assertEquals(1000, allocator.issued.size)
    }

    // endregion

    // region 置信度派生（R2.3）

    @Test
    fun confidenceIsVerifiedWhenAtLeastOneEvidenceIsLocatable() {
        val locatable = SourceRef("device-discovery/src/Nsd.kt", 95)
        val merger = GapItemMerger(locator = locatorFor(locatable.toString()))

        val result = merger.merge(listOf(draft(evidence = listOf(locatable))))

        val item = result.items.single()
        assertEquals(Confidence.VERIFIED_BY_REPO_EVIDENCE, item.confidence)
        assertTrue(item.isFixEligible)
    }

    @Test
    fun confidenceIsVerifiedIfAnyOneOfSeveralEvidenceIsLocatable() {
        val stale = SourceRef("device-discovery/src/Deleted.kt", 5)
        val live = SourceRef("device-discovery/src/Live.kt", 12)
        // 只有 live 可定位。
        val merger = GapItemMerger(locator = locatorFor(live.toString()))

        val result = merger.merge(listOf(draft(evidence = listOf(stale, live))))

        assertEquals(Confidence.VERIFIED_BY_REPO_EVIDENCE, result.items.single().confidence)
    }

    @Test
    fun itemWithNoEvidenceIsSpeculationAndExcludedFromFixDecisions() {
        val merger = GapItemMerger(locator = locatorFor())

        val result = merger.merge(listOf(draft(evidence = emptyList())))

        val item = result.items.single()
        assertEquals(Confidence.UNVERIFIED_SPECULATION, item.confidence)
        assertFalse(item.isFixEligible, "no-evidence item must not enter fix decisions (R2.3)")
        assertTrue(result.fixEligible.isEmpty())
        assertEquals(listOf(item), result.speculative)
    }

    @Test
    fun itemWhoseEvidenceIsNotLocatableIsSpeculation() {
        val stale = SourceRef("device-discovery/src/Deleted.kt", 5)
        // 声明了证据，但当前工作副本无法定位它。
        val merger = GapItemMerger(locator = locatorFor(/* nothing locatable */))

        val result = merger.merge(listOf(draft(evidence = listOf(stale))))

        val item = result.items.single()
        assertEquals(Confidence.UNVERIFIED_SPECULATION, item.confidence)
        assertFalse(item.isFixEligible)
    }

    @Test
    fun fixEligibleAndSpeculativePartitionCoversAllItems() {
        val live = SourceRef("app/src/Live.kt", 3)
        val merger = GapItemMerger(locator = locatorFor(live.toString()))

        val result = merger.merge(
            listOf(
                draft(impact = "verified", evidence = listOf(live)),
                draft(impact = "speculative", evidence = emptyList()),
                draft(impact = "stale", evidence = listOf(SourceRef("app/src/Gone.kt", 9))),
            ),
        )

        assertEquals(3, result.items.size)
        assertEquals(1, result.fixEligible.size)
        assertEquals(2, result.speculative.size)
        assertEquals(result.items.size, result.fixEligible.size + result.speculative.size)
    }

    // endregion

    // region 去重

    @Test
    fun duplicateGapsAreMergedAndDoNotEachConsumeAnId() {
        val e1 = SourceRef("device-discovery/src/A.kt", 10)
        val e2 = SourceRef("device-discovery/src/A.kt", 11)
        val merger = GapItemMerger(locator = locatorFor(e1.toString()))

        // 两条草稿描述同一缺口（同类别/子系统/影响/判定），但各带不同证据顺序。
        val d1 = draft(evidence = listOf(e1, e2))
        val d2 = draft(evidence = listOf(e2, e1))

        val result = merger.merge(listOf(d1, d2))

        assertEquals(1, result.items.size, "identical gaps must dedup to a single item")
        assertEquals("GAP-0001", result.items.single().id)
        // 证据合并且去重。
        assertEquals(setOf(e1, e2), result.items.single().evidence.toSet())
    }

    @Test
    fun differentEvidenceMakesDistinctGaps() {
        val merger = GapItemMerger(locator = locatorFor())
        val d1 = draft(evidence = listOf(SourceRef("a/A.kt", 1)))
        val d2 = draft(evidence = listOf(SourceRef("a/A.kt", 2)))

        val result = merger.merge(listOf(d1, d2))

        assertEquals(2, result.items.size)
        assertTrue(result.allIdsUnique)
    }

    // endregion

    // region SourceRef 与 GapItem 结构

    @Test
    fun sourceRefFormatsAndParsesRoundTrip() {
        val ref = SourceRef("device-discovery/src/main/kotlin/Nsd.kt", 95)
        assertEquals("device-discovery/src/main/kotlin/Nsd.kt:95", ref.toString())
        assertEquals(ref, SourceRef.parse(ref.toString()))
    }

    @Test
    fun sourceRefParseRejectsMalformedInput() {
        assertNull(SourceRef.parse("no-line-number"))
        assertNull(SourceRef.parse("file.kt:"))
        assertNull(SourceRef.parse(":10"))
        assertNull(SourceRef.parse("file.kt:notanumber"))
        assertNull(SourceRef.parse("file.kt:0"))
    }

    @Test
    fun categoryLabelsMatchTheFourValueSet() {
        assertEquals(
            setOf("缺失", "半接线", "假接线", "缺陷"),
            GapCategory.entries.map { it.label }.toSet(),
        )
    }

    @Test
    fun constructingVerifiedItemWithoutEvidenceIsRejected() {
        // R2.3 不变式：无证据不得标注为已核实。
        assertThrows(IllegalArgumentException::class.java) {
            GapItem(
                id = "GAP-0001",
                category = GapCategory.DEFECT,
                evidence = emptyList(),
                subsystem = "X",
                userVisibleImpact = "y",
                verdictCondition = "z",
                confidence = Confidence.VERIFIED_BY_REPO_EVIDENCE,
                scopeId = "S1",
            )
        }
    }

    @Test
    fun constructingItemWithBlankMandatoryFieldsIsRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            GapItem(
                id = "GAP-0001",
                category = GapCategory.DEFECT,
                evidence = listOf(SourceRef("a/A.kt", 1)),
                subsystem = "  ",
                userVisibleImpact = "y",
                verdictCondition = "z",
                confidence = Confidence.VERIFIED_BY_REPO_EVIDENCE,
                scopeId = "S1",
            )
        }
    }

    // endregion
}
