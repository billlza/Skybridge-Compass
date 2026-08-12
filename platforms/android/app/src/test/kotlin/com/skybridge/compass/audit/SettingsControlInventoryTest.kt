package com.skybridge.compass.audit

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * [SettingsControlInventory] 的结构不变式与核对断言（任务 15.1 / R7.1）。
 *
 * JUnit Jupiter（任务 2.1 已为 `:app` 接入 JUnit Platform）。
 *
 * **本文件不实现 Property 41**（设置控件清单不变式属性测试属任务 15.10）；这里只做清单自身的
 * 结构完备性与文档记载数字的一致性核对，使清单被机器校验、不会与文档悄悄漂移。
 */
class SettingsControlInventoryTest {

    @Test
    @DisplayName("控件 id 在全清单内唯一")
    fun controlIdsAreUnique() {
        val ids = SettingsControlInventory.all.map { it.id }
        assertEquals(ids.size, ids.toSet().size, "duplicate control ids: ${duplicates(ids)}")
    }

    @Test
    @DisplayName("(store, key) 组合唯一 —— 一个键恰好一条记录（计数规则 R-3）")
    fun storeKeyPairsAreUnique() {
        val pairs = SettingsControlInventory.all.map { it.store to it.key }
        assertEquals(pairs.size, pairs.toSet().size, "duplicate (store,key) pairs: ${duplicates(pairs)}")
    }

    @Test
    @DisplayName("每条记录都绑定六存储之一的一个非空键（计数规则 R-2）")
    fun everyControlIsBoundToAStoreKey() {
        SettingsControlInventory.all.forEach { record ->
            assertTrue(record.key.isNotBlank(), "${record.id} has a blank store key")
            assertTrue(
                record.store in SettingsStoreId.entries,
                "${record.id} is not bound to one of the six stores",
            )
        }
    }

    @Test
    @DisplayName("每个分区内 orderInSection 从 1 起连续且无重复、无空洞")
    fun orderInSectionIsContiguousPerSection() {
        SettingsControlInventory.bySection().forEach { (section, records) ->
            if (records.isEmpty()) return@forEach
            val orders = records.map { it.orderInSection }
            assertEquals(
                (1..records.size).toList(),
                orders,
                "section $section has gaps or duplicates in orderInSection: $orders",
            )
        }
    }

    @Test
    @DisplayName("清单只使用已声明的分区标识，且每个已声明分区都非空")
    fun sectionIdsMatchDeclaredSections() {
        val used = SettingsControlInventory.all.map { it.sectionId }.toSet()
        val declared = SettingsSections.order.toSet()
        assertEquals(emptySet<String>(), used - declared, "controls reference undeclared sections")
        assertEquals(emptySet<String>(), declared - used, "declared sections carry no controls")
    }

    @Test
    @DisplayName("分区求和等于清单总数 —— 无控件在分组时丢失")
    fun sectionPartitionCoversEveryControl() {
        val partitioned = SettingsControlInventory.bySection().values.sumOf { it.size }
        assertEquals(SettingsControlInventory.TOTAL_CONTROLS, partitioned)
    }

    @Test
    @DisplayName("已持久化控件数与有运行时消费方控件数等于文档记载值")
    fun documentedCountsMatchTheInventory() {
        // 与 settings-control-inventory.md §3 记载的数字一致；改动清单必须同步改文档。
        // 实时天气设置纳入清单后：44 项有运行时消费方，仅 encryption.algorithm 无消费方（只读事实呈现）。
        assertEquals(45, SettingsControlInventory.TOTAL_CONTROLS, "总控件数")
        assertEquals(45, SettingsControlInventory.persistedCount, "已持久化控件数")
        assertEquals(44, SettingsControlInventory.withRuntimeConsumerCount, "有运行时消费方的控件数")
        assertEquals(1, SettingsControlInventory.zeroConsumerControls.size, "零消费方控件数")
    }

    @Test
    @DisplayName("已持久化数 = 总数；有消费方数 + 零消费方数 = 总数")
    fun countsArePartitions() {
        val total = SettingsControlInventory.TOTAL_CONTROLS
        assertEquals(total, SettingsControlInventory.persistedCount)
        assertEquals(
            total,
            SettingsControlInventory.withRuntimeConsumerCount +
                SettingsControlInventory.zeroConsumerControls.size,
        )
    }

    @Test
    @DisplayName("清单总数与 R7.1/R7.13 记载的 77 不符 —— 该差异必须以冲突记录呈现，不得抹平")
    fun inventoryTotalDivergesFromTheDocumentedSeventySeven() {
        assertFalse(
            SettingsControlInventory.TOTAL_CONTROLS == 77,
            "如果这条断言失败，说明清单已达 77：请同步更新 settings-control-inventory.md 并撤销冲突记录",
        )
    }

    @Test
    @DisplayName("77-vs-实测 冲突经既有 ConflictReconciler 产出恰好一条记录，且由可定位证据裁决给清单方")
    fun inventoryConflictIsAdjudicatedToTheInventorySide() {
        // 只有清单方持证据；此处以「清单方证据可定位、需求方无证据」的口径注入。
        val locatable = SettingsInventoryConflict.inventoryJudgment.evidence.toSet()
        val outcome = SettingsInventoryConflict.reconcile { it in locatable }

        assertEquals(1, outcome.records.size, "恰好一条冲突记录")
        val record = outcome.records.single()
        assertEquals("count=45", record.adoptedSide.stance)
        assertEquals(AdjudicationBasis.SOLE_LOCATABLE_EVIDENCE, record.basis)
        assertTrue(record.verdictBackedByLocatableEvidence, "裁决须由可定位证据支撑")
        assertEquals(1, record.rejectedConclusions.size)
        assertTrue(
            record.rejectedConclusions.single().contains("77"),
            "被否结论须保留 77 这一原始记载",
        )
    }

    @Test
    @DisplayName("零消费方控件复核后仅剩只读事实呈现的 encryption.algorithm（R7.2 / 任务 15.4）")
    fun zeroConsumerControlsAreTheExpectedSet() {
        assertEquals(
            listOf("encryption.algorithm"),
            SettingsControlInventory.zeroConsumerControls.map { it.id }.sorted(),
        )
    }

    @Test
    @DisplayName("R7.2 验收：不存在「可操作但零消费方」的控件")
    fun noInteractiveControlLacksARuntimeConsumer() {
        assertEquals(
            emptyList<String>(),
            SettingsControlInventory.interactiveZeroConsumerControls.map { it.id },
            "每个交互式控件都必须有至少一处运行时消费方，否则应改为只读事实呈现",
        )
    }

    @Test
    @DisplayName("唯一的零消费方控件必须是只读事实呈现 —— 不得是可操作空控件")
    fun theOnlyZeroConsumerControlIsPresentedAsAReadOnlyFact() {
        val record = SettingsControlInventory.zeroConsumerControls.single()
        assertEquals(Presentation.READ_ONLY_FACT, record.presentation)
    }

    @Test
    @DisplayName("15.1 登记的 7 项零消费方中，6 项复核后已确认有可定位消费方")
    fun theSixReReviewedControlsNowCarryLocatableConsumers() {
        val reReviewed = listOf(
            "general.notifications",
            "general.keep-screen-on",
            "network.max-reconnect-attempts",
            "device-auth.auto-trust-known-devices",
            "device-auth.pairing-timeout-sec",
            "access-control.allow-clipboard-sync",
        )

        reReviewed.forEach { id ->
            val record = SettingsControlInventory.all.single { it.id == id }
            assertTrue(record.hasRuntimeConsumer, "$id 应已登记运行时消费方")
            record.consumers.forEach { consumer ->
                assertTrue(
                    SourceRef.parse(consumer) != null,
                    "$id 的消费方引用须为可定位的 文件:行 —— $consumer",
                )
            }
        }
    }

    @Test
    @DisplayName("R7.6 目标只读事实呈现项恰为数据加密子屏三项")
    fun readOnlyFactControlsAreTheEncryptionScreenRows() {
        assertEquals(
            listOf("encryption.algorithm", "encryption.post-quantum", "encryption.transport-encryption"),
            SettingsControlInventory.readOnlyFactControls.map { it.id }.sorted(),
        )
    }

    @Test
    @DisplayName("FeatureFlags 内存镜像读取点为 0 —— R7.10 清零依据")
    fun featureFlagsMirrorHasNoReadSites() {
        assertEquals(0, FeatureFlagsDeadState.readSiteCount)
        assertEquals(3, FeatureFlagsDeadState.declarations.size)
        assertEquals(3, FeatureFlagsDeadState.writeSites.size)
    }

    @Test
    @DisplayName("R7.10 已清零：3 个内存镜像变量与其写入点已移除，真实功能门仍是三个持久化键")
    fun featureFlagsMirrorHasBeenCleared() {
        assertTrue(FeatureFlagsDeadState.cleared, "任务 15.4 应已移除内存镜像")
        assertEquals(
            3,
            FeatureFlagsDeadState.inMemoryOnlyMirrorCount,
            "全仓实际找到的纯内存镜像变量数为 3，不是任务标题的 15",
        )
        assertEquals(
            listOf("enable_screen_mirroring", "enable_remote_control", "enable_file_transfer"),
            FeatureFlagsDeadState.remainingGateKeys,
            "清零后真实生效的仍是 DeveloperSettingsStore 的三个键",
        )
    }

    @Test
    @DisplayName("清零后 developer 分区三条记录仍各自保留运行时消费方")
    fun developerGateKeysKeepTheirConsumers() {
        FeatureFlagsDeadState.remainingGateKeys.forEach { key ->
            val record = SettingsControlInventory.all.single { it.key == key }
            assertTrue(
                record.hasRuntimeConsumer,
                "$key 的消费方不得随内存镜像一并消失",
            )
        }
    }

    private fun <T> duplicates(values: List<T>): List<T> =
        values.groupBy { it }.filterValues { it.size > 1 }.keys.toList()
}
