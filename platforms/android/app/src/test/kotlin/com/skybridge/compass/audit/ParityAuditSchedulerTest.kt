package com.skybridge.compass.audit

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * ParityAuditScheduler / AuditScope 单元测试（任务 4.3 / R2.1、R2.11）。
 *
 * 使用 JUnit Jupiter（与 `:app` 模块 `useJUnitPlatform()` 一致），位于 `test` 源集，
 * 不随生产应用打包。覆盖：
 *  - 四个标准范围两两不相交（R2.1）
 *  - contains() 正确归属路径
 *  - 越范围返回被判为无效（R2.11）
 *  - 至多补发替换两次（R2.11）
 *  - 有效结果 < 4 时停止并报告（R2.11）
 */
class ParityAuditSchedulerTest {

    // 便捷派发器：对给定范围恒定返回同一结果。
    private fun fixed(ret: AuditWorkerReturn) = AuditWorkerDispatcher { _, _ -> ret }

    // 一个满足全部四范围的、始终有效的派发器：为每个范围回引其自身一个范围内路径。
    private val alwaysValidDispatcher = AuditWorkerDispatcher { scope, _ ->
        AuditWorkerReturn.Produced(listOf(inScopePathFor(scope.id)))
    }

    private fun inScopePathFor(scopeId: String): String = when (scopeId) {
        "S1" -> "device-discovery/src/main/kotlin/Discovery.kt"
        "S2" -> "file-transfer/src/main/kotlin/Transfer.kt"
        "S3" -> "remote-control/src/main/kotlin/Host.kt"
        "S4" -> "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/Settings.kt"
        else -> error("unknown scope $scopeId")
    }

    // region 范围两两不相交（R2.1）

    @Test
    fun standardScopesArePairwiseDisjoint() {
        assertTrue(
            ParityAuditScheduler.arePairwiseDisjoint(StandardAuditScopes.all),
            "S1–S4 must be pairwise disjoint (R2.1)",
        )
    }

    @Test
    fun constructingWithOverlappingScopesThrows() {
        val a = AuditScope("A", "a", includedPrefixes = listOf("shared/src/p2p"))
        val b = AuditScope("B", "b", includedPrefixes = listOf("shared/src/p2p/filetransfer"))
        // b 完全落在 a 之内且 a 未挖去它 → 相交。
        assertThrows(IllegalArgumentException::class.java) {
            ParityAuditScheduler(scopes = listOf(a, b), dispatcher = alwaysValidDispatcher)
        }
    }

    @Test
    fun excludeMakesOtherwiseOverlappingScopesDisjoint() {
        val a = AuditScope(
            "A", "a",
            includedPrefixes = listOf("shared/src/p2p"),
            excludedPrefixes = listOf("shared/src/p2p/filetransfer"),
        )
        val b = AuditScope("B", "b", includedPrefixes = listOf("shared/src/p2p/filetransfer"))
        assertFalse(a.overlaps(b), "excluding the shared subtree should remove the overlap")
        assertFalse(b.overlaps(a), "overlap must be symmetric")
    }

    @Test
    fun siblingPrefixesDoNotOverlap() {
        val a = AuditScope("A", "a", includedPrefixes = listOf("app/src/ui/screens/settings"))
        val b = AuditScope("B", "b", includedPrefixes = listOf("app/src/ui/screens/filetransfer"))
        assertFalse(a.overlaps(b))
    }

    @Test
    fun prefixBoundaryIsSegmentAwareNotStringPrefix() {
        // `a/bc` 不应被判为 `a/b` 的子路径。
        val a = AuditScope("A", "a", includedPrefixes = listOf("core/src/webrtc"))
        val b = AuditScope("B", "b", includedPrefixes = listOf("core/src/webrtcx"))
        assertFalse(a.overlaps(b))
    }

    // endregion

    // region contains() 归属判定

    @Test
    fun containsAssignsPathsToCorrectScope() {
        val s1 = StandardAuditScopes.S1_DISCOVERY_CONNECTION
        val s2 = StandardAuditScopes.S2_FILE_TRANSFER
        val s3 = StandardAuditScopes.S3_REMOTE_DESKTOP_INPUT
        val s4 = StandardAuditScopes.S4_SETTINGS_BUILD

        assertTrue(s1.contains("device-discovery/src/main/kotlin/Nsd.kt"))
        assertTrue(s2.contains("file-transfer/src/main/kotlin/Wire.kt"))
        assertTrue(s3.contains("remote-control/src/main/kotlin/Input.kt"))
        assertTrue(s4.contains("app/build.gradle.kts"))

        // 每条路径只归属一个范围。
        val path = "file-transfer/src/main/kotlin/Wire.kt"
        val owners = StandardAuditScopes.all.filter { it.contains(path) }
        assertEquals(1, owners.size)
        assertEquals("S2", owners.single().id)
    }

    @Test
    fun sharedP2pFileTransferSubtreeBelongsToS2NotS1() {
        val s1 = StandardAuditScopes.S1_DISCOVERY_CONNECTION
        val s2 = StandardAuditScopes.S2_FILE_TRANSFER
        val path = "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/filetransfer/Chunk.kt"

        assertFalse(s1.contains(path), "filetransfer subtree is excluded from S1")
        assertTrue(s2.contains(path), "filetransfer subtree belongs to S2")
    }

    @Test
    fun sharedP2pNonFileTransferBelongsToS1() {
        val s1 = StandardAuditScopes.S1_DISCOVERY_CONNECTION
        val path = "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/HandshakeWire.kt"
        assertTrue(s1.contains(path))
    }

    @Test
    fun moduleBuildScriptBelongsToS4NotFeatureScope() {
        val s1 = StandardAuditScopes.S1_DISCOVERY_CONNECTION
        val s4 = StandardAuditScopes.S4_SETTINGS_BUILD
        // device-discovery 的源码归 S1，但其构建脚本归 S4，二者不相交。
        assertFalse(s1.contains("device-discovery/build.gradle.kts"))
        assertTrue(s4.contains("device-discovery/build.gradle.kts"))
    }

    @Test
    fun unrelatedPathBelongsToNoScope() {
        val path = "README.md"
        assertTrue(StandardAuditScopes.all.none { it.contains(path) })
    }

    @Test
    fun containsNormalizesPathForm() {
        val s1 = StandardAuditScopes.S1_DISCOVERY_CONNECTION
        assertTrue(s1.contains("./device-discovery/src//main/kotlin/Nsd.kt"))
        assertTrue(s1.contains("device-discovery/src/main/kotlin/Nsd.kt/"))
    }

    // endregion

    // region 越范围检测（R2.11）

    @Test
    fun inScopeResultIsValid() {
        val scheduler = ParityAuditScheduler(dispatcher = alwaysValidDispatcher)
        val s1 = StandardAuditScopes.S1_DISCOVERY_CONNECTION
        val result = scheduler.validate(
            s1,
            AuditWorkerReturn.Produced(listOf("device-discovery/src/main/kotlin/A.kt")),
        )
        assertTrue(result != null && result.valid)
        assertTrue(result!!.outOfScopePaths.isEmpty())
    }

    @Test
    fun outOfScopeResultIsRejected() {
        val scheduler = ParityAuditScheduler(dispatcher = alwaysValidDispatcher)
        val s1 = StandardAuditScopes.S1_DISCOVERY_CONNECTION
        // S1 审查任务引用了 S2 的文件传输路径 → 越范围。
        val result = scheduler.validate(
            s1,
            AuditWorkerReturn.Produced(
                listOf(
                    "device-discovery/src/main/kotlin/A.kt",
                    "file-transfer/src/main/kotlin/B.kt",
                ),
            ),
        )
        assertTrue(result != null)
        assertFalse(result!!.valid, "result referencing out-of-scope path must be invalid")
        assertEquals(listOf("file-transfer/src/main/kotlin/B.kt"), result.outOfScopePaths)
    }

    @Test
    fun noResultValidatesToNull() {
        val scheduler = ParityAuditScheduler(dispatcher = alwaysValidDispatcher)
        val s1 = StandardAuditScopes.S1_DISCOVERY_CONNECTION
        assertEquals(null, scheduler.validate(s1, AuditWorkerReturn.NoResult))
    }

    // endregion

    // region 补发替换至多两次（R2.11）

    @Test
    fun replacementHappensAtMostTwiceThenScopeGivesUp() {
        // 该范围的审查任务始终越范围返回 → 应初次 + 2 次补发 = 3 次尝试后放弃。
        val dispatcher = AuditWorkerDispatcher { _, _ ->
            AuditWorkerReturn.Produced(listOf("README.md")) // 不属于任何范围 → 越范围
        }
        val scheduler = ParityAuditScheduler(
            scopes = listOf(StandardAuditScopes.S1_DISCOVERY_CONNECTION),
            dispatcher = dispatcher,
            minValidResults = 1,
        )
        val outcome = scheduler.runParallel()
        val trace = outcome.traces.single()

        assertEquals(3, trace.attempts.size, "initial + at most 2 replacements = 3 attempts")
        assertEquals(2, trace.replacementsUsed, "R2.11: at most two replacements")
        assertTrue(trace.attempts.all { it.outcome == AttemptOutcome.OUT_OF_SCOPE })
        assertInstanceOf(ScheduleOutcome.Stopped::class.java, outcome)
    }

    @Test
    fun replacementStopsEarlyOnceValid() {
        // 初次越范围，第一次补发即有效 → 只用 1 次补发，不再继续。
        val dispatcher = AuditWorkerDispatcher { scope, attempt ->
            if (attempt == 0) {
                AuditWorkerReturn.Produced(listOf("README.md")) // 越范围
            } else {
                AuditWorkerReturn.Produced(listOf(inScopePathFor(scope.id)))
            }
        }
        val scheduler = ParityAuditScheduler(
            scopes = listOf(StandardAuditScopes.S1_DISCOVERY_CONNECTION),
            dispatcher = dispatcher,
            minValidResults = 1,
        )
        val trace = scheduler.runParallel().traces.single()

        assertEquals(2, trace.attempts.size, "should stop right after the first valid replacement")
        assertEquals(1, trace.replacementsUsed)
        assertEquals(AttemptOutcome.OUT_OF_SCOPE, trace.attempts[0].outcome)
        assertEquals(AttemptOutcome.VALID, trace.attempts[1].outcome)
    }

    @Test
    fun noResultAlsoTriggersReplacement() {
        val dispatcher = fixed(AuditWorkerReturn.NoResult)
        val scheduler = ParityAuditScheduler(
            scopes = listOf(StandardAuditScopes.S1_DISCOVERY_CONNECTION),
            dispatcher = dispatcher,
            minValidResults = 1,
        )
        val trace = scheduler.runParallel().traces.single()
        assertEquals(3, trace.attempts.size)
        assertTrue(trace.attempts.all { it.outcome == AttemptOutcome.NO_RESULT })
    }

    // endregion

    // region 有效结果 < 4 停止并报告（R2.11）

    @Test
    fun completesWhenAllFourScopesReturnValid() {
        val scheduler = ParityAuditScheduler(dispatcher = alwaysValidDispatcher)
        val outcome = scheduler.runParallel()

        val completed = assertInstanceOf(ScheduleOutcome.Completed::class.java, outcome)
        assertEquals(4, completed.results.size)
        assertEquals(setOf("S1", "S2", "S3", "S4"), completed.results.map { it.scopeId }.toSet())
    }

    @Test
    fun stopsAndReportsWhenFewerThanFourValid() {
        // S3 的审查任务始终越范围（引用 S4 路径）→ 只有 3 个有效 → 停止并报告。
        val dispatcher = AuditWorkerDispatcher { scope, _ ->
            if (scope.id == "S3") {
                AuditWorkerReturn.Produced(listOf("app/build.gradle.kts")) // 属于 S4，对 S3 越范围
            } else {
                AuditWorkerReturn.Produced(listOf(inScopePathFor(scope.id)))
            }
        }
        val scheduler = ParityAuditScheduler(dispatcher = dispatcher)
        val outcome = scheduler.runParallel()

        val stopped = assertInstanceOf(ScheduleOutcome.Stopped::class.java, outcome)
        assertEquals(3, stopped.validCount)
        assertEquals(4, stopped.requiredCount)
        assertEquals(listOf("S3"), stopped.uncoveredScopeIds)
        // S3 用满了初次 + 2 次补发。
        val s3Trace = stopped.traces.single { it.scopeId == "S3" }
        assertEquals(2, s3Trace.replacementsUsed)
    }

    @Test
    fun stopsAndReportsWhenAScopeNeverReturns() {
        val dispatcher = AuditWorkerDispatcher { scope, _ ->
            if (scope.id == "S2") AuditWorkerReturn.NoResult
            else AuditWorkerReturn.Produced(listOf(inScopePathFor(scope.id)))
        }
        val scheduler = ParityAuditScheduler(dispatcher = dispatcher)
        val outcome = scheduler.runParallel()

        val stopped = assertInstanceOf(ScheduleOutcome.Stopped::class.java, outcome)
        assertEquals(3, stopped.validCount)
        assertTrue(stopped.uncoveredScopeIds.contains("S2"))
    }

    // endregion
}
