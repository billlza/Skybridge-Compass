package com.skybridge.compass.audit

import io.kotest.assertions.throwables.shouldNotThrowAny
import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.bind
import io.kotest.property.arbitrary.choice
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.list
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 49: 审计范围两两互不相交且结论不越界**
 *
 * **Validates: Requirements 2.1**
 *
 * 审计工具代码的属性测试（任务 5.5）。位于 `:app` 的 `test` 源集，不随生产应用打包
 * （遵守 G3：仅 Kotlin；不改动 Apple 源码树）。与 [ParityAuditSchedulerTest] 的示例测试
 * **互补**：示例测试固定几个已知的边界用例（`shared/.../p2p/filetransfer` 归 S2、模块
 * `build.gradle.kts` 归 S4、`core/src/webrtc` 与 `core/src/webrtcx` 的段边界），本文件在
 * 随机生成的路径空间与随机构造的范围对上验证同一属性的两个半部：
 *
 * 1. **两两互不相交**：S1–S4 任意两个范围无交集，且任意仓库相对路径至多归属一个范围；
 *    [AuditScope.overlaps] 对称；相交的范围集合被 [ParityAuditScheduler] 构造拒绝，
 *    而以 `exclude` 挖去共同子树后的范围集合被接受。
 * 2. **结论不越界**：审查任务结论引用任一指派范围之外的路径即被判为无效返回（并触发
 *    R2.11 的补发 / 停止），仅引用范围内路径的结论被接受。
 *
 * 生成器均按 Kotest 默认种子驱动（失败时种子写入测试输出以便复现），且刻意让"接受"
 * 与"拒绝"两条分支都被真正走到——每个测试在 `checkAll` 结束后断言两条分支的计数均
 * 大于 0，避免属性以空真（vacuous truth）方式通过。
 */
class AuditScopePropertyTest : FunSpec({

    // region 生成器素材

    /** 仓库真实模块根与顶层目录。 */
    val moduleRoots = listOf(
        "app", "core", "device-discovery", "remote-control", "file-transfer",
        "shared", "baselineprofile", "scripts", "docs", "gradle",
    )

    /** 真实路径段素材，含刻意制造段边界歧义的 `webrtc` / `webrtcx` 与归属歧义的 `filetransfer`。 */
    val pathSegments = listOf(
        "src", "main", "test", "kotlin", "com", "skybridge", "compass", "android",
        "p2p", "filetransfer", "protocol", "webrtc", "webrtcx", "discovery",
        "remotecontrol", "settings", "ui", "screens", "data", "cloud",
        "build.gradle.kts", "Nsd.kt", "Wire.kt", "Host.kt",
    )

    /** 示例测试已标注的高风险归属用例，混入随机路径一并生成。 */
    val trickyPaths = listOf(
        "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/filetransfer/Chunk.kt",
        "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/HandshakeWire.kt",
        "shared/src/main/kotlin/com/skybridge/compass/shared/protocol/CrossPlatformFileTransferProtocol.kt",
        "device-discovery/build.gradle.kts",
        "file-transfer/build.gradle.kts",
        "app/build.gradle.kts",
        "settings.gradle.kts",
        "build.gradle.kts",
        "core/src/main/kotlin/com/skybridge/compass/core/webrtc/PeerConnection.kt",
        "core/src/main/kotlin/com/skybridge/compass/core/webrtcx/NotWebRtc.kt",
        "core/src/main/kotlin/com/skybridge/compass/core/filetransfer/Sender.kt",
        "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings/SettingsScreen.kt",
        "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/filetransfer/TransferScreen.kt",
        "scripts/check_android_packaged_placeholders.sh",
        "README.md",
        "gradle/libs.versions.toml",
    )

    val randomPathArb: Arb<String> = Arb.bind(
        Arb.element(moduleRoots),
        Arb.list(Arb.element(pathSegments), 0..6),
    ) { root, segs -> (listOf(root) + segs).joinToString("/") }

    /** 仓库相对路径生成器：随机路径 + 已知高风险用例。 */
    val pathArb: Arb<String> = Arb.choice(randomPathArb, Arb.element(trickyPaths))

    /** 构造任意范围用的前缀池，刻意包含互为子树、互为兄弟与仅字符串前缀重叠的组合。 */
    val prefixPool = listOf(
        "app/src",
        "app/src/main/kotlin",
        "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings",
        "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/filetransfer",
        "app/build.gradle.kts",
        "core/src",
        "core/src/main/kotlin/com/skybridge/compass/core/webrtc",
        "core/src/main/kotlin/com/skybridge/compass/core/webrtcx",
        "device-discovery/src",
        "file-transfer/src",
        "remote-control/src",
        "shared/src/main/kotlin/com/skybridge/compass/shared/p2p",
        "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/filetransfer",
        "gradle",
        "docs",
        "scripts",
    )

    val scopePrefixesArb: Arb<List<String>> = Arb.list(Arb.element(prefixPool), 1..3)

    /** 追加到范围前缀后的良性路径段（均不等于任何范围的 exclude 段，故不会误落进被挖去的子树）。 */
    val benignSegments = listOf("main", "kotlin", "impl", "util", "Alpha.kt", "Beta.kt", "Gamma.kt")
    val benignSegsArb: Arb<List<String>> = Arb.list(Arb.element(benignSegments), 0..3)

    /** 构造范围内路径：取该范围第 [pick] 个 include 前缀，追加良性路径段。 */
    fun inScopePath(scope: AuditScope, pick: Int, segs: List<String>): String {
        val prefixes = scope.includedPrefixes
        val prefix = prefixes[pick.mod(prefixes.size)]
        // 前缀本身即文件时不再追加路径段，保持路径形态真实。
        val isFile = prefix.endsWith(".kts") || prefix.endsWith(".kt") || prefix.endsWith(".sh")
        return if (isFile) prefix else (listOf(prefix) + segs).joinToString("/")
    }

    val neverReturns = AuditWorkerDispatcher { _, _ -> AuditWorkerReturn.NoResult }

    // endregion

    // region 第 1 半：两两互不相交

    test("Property 49 (disjoint): 标准范围两两不相交，且任意仓库路径至多归属一个范围") {
        // 范围集合层面的硬不变量（R2.1），与路径生成无关，先直接断言。
        ParityAuditScheduler.arePairwiseDisjoint(StandardAuditScopes.all) shouldBe true

        var ownedByOne = 0
        var ownedByNone = 0

        checkAll(300, pathArb) { path ->
            val owners = StandardAuditScopes.all.filter { it.contains(path) }
            // 核心断言：分区语义 —— 至多一个范围拥有该路径。
            (owners.size <= 1) shouldBe true

            // 归属判定与书写形态无关（等价路径必须得到相同归属）。
            val messy = "./" + path.replace("/", "//") + "/"
            val messyOwners = StandardAuditScopes.all.filter { it.contains(messy) }
            messyOwners.map { it.id } shouldBe owners.map { it.id }

            if (owners.size == 1) ownedByOne++ else ownedByNone++
        }

        // 非空真保证：既生成到了有归属的路径，也生成到了无归属的路径。
        (ownedByOne > 0) shouldBe true
        (ownedByNone > 0) shouldBe true
    }

    test("Property 49 (disjoint): overlaps 对称，且相交范围集合被调度器构造拒绝") {
        var overlapping = 0
        var disjoint = 0

        checkAll(300, scopePrefixesArb, scopePrefixesArb, pathArb) { prefixesA, prefixesB, path ->
            val a = AuditScope("A", "范围 A", includedPrefixes = prefixesA)
            val b = AuditScope("B", "范围 B", includedPrefixes = prefixesB)

            val ab = a.overlaps(b)
            // 相交关系必须对称。
            ab shouldBe b.overlaps(a)

            if (ab) {
                overlapping++
                // R2.1 硬约束：相交的范围集合不得构成合法调度。
                shouldThrow<IllegalArgumentException> {
                    ParityAuditScheduler(
                        scopes = listOf(a, b),
                        dispatcher = neverReturns,
                        minValidResults = 1,
                    )
                }
            } else {
                disjoint++
                shouldNotThrowAny {
                    ParityAuditScheduler(
                        scopes = listOf(a, b),
                        dispatcher = neverReturns,
                        minValidResults = 1,
                    )
                }
                // 不相交的范围不得共同拥有任何一条具体路径（与 overlaps 的结构判定交叉核对）。
                (a.contains(path) && b.contains(path)) shouldBe false
            }
        }

        (overlapping > 0) shouldBe true
        (disjoint > 0) shouldBe true
    }

    test("Property 49 (disjoint): exclude 挖去共同子树后范围不再相交且被接受") {
        // 取"父前缀 + 其真子树"这类必然相交的组合，验证 exclude 是消除相交的有效手段。
        val nestedPairs = listOf(
            "shared/src/main/kotlin/com/skybridge/compass/shared/p2p" to
                "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/filetransfer",
            "app/src" to "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings",
            "core/src" to "core/src/main/kotlin/com/skybridge/compass/core/webrtc",
        )

        var checked = 0

        checkAll(150, Arb.element(nestedPairs), benignSegsArb) { (parent, child), segs ->
            val carved = AuditScope(
                id = "A",
                displayName = "父范围（已挖去子树）",
                includedPrefixes = listOf(parent),
                excludedPrefixes = listOf(child),
            )
            val inner = AuditScope("B", "子树范围", includedPrefixes = listOf(child))

            // 未挖去时必然相交。
            AuditScope("A", "父范围", includedPrefixes = listOf(parent)).overlaps(inner) shouldBe true

            // 挖去后不相交（双向），且调度器接受。
            carved.overlaps(inner) shouldBe false
            inner.overlaps(carved) shouldBe false
            shouldNotThrowAny {
                ParityAuditScheduler(
                    scopes = listOf(carved, inner),
                    dispatcher = neverReturns,
                    minValidResults = 1,
                )
            }

            // 子树内的具体路径只归 inner，不归 carved。
            val childPath = (listOf(child) + segs).joinToString("/")
            carved.contains(childPath) shouldBe false
            inner.contains(childPath) shouldBe true
            checked++
        }

        (checked > 0) shouldBe true
    }

    // endregion

    // region 第 2 半：结论不越界

    test("Property 49 (no overreach): 引用范围外路径的审查任务结论被拒绝，仅引用范围内路径的被接受") {
        val scheduler = ParityAuditScheduler(
            dispatcher = AuditWorkerDispatcher { scope, _ ->
                AuditWorkerReturn.Produced(listOf(inScopePath(scope, 0, emptyList())))
            },
        )

        val inScopeSpecArb = Arb.list(
            Arb.bind(Arb.int(0..7), benignSegsArb) { pick, segs -> pick to segs },
            1..3,
        )
        val foreignSpecArb = Arb.list(
            Arb.bind(Arb.int(0..2), Arb.int(0..7), benignSegsArb) { other, pick, segs ->
                Triple(other, pick, segs)
            },
            0..2,
        )

        var acceptedCases = 0
        var rejectedCases = 0

        checkAll(300, Arb.element(StandardAuditScopes.all), inScopeSpecArb, foreignSpecArb) {
                dispatched, inScopeSpec, foreignSpec ->

            val inScopePaths = inScopeSpec.map { (pick, segs) -> inScopePath(dispatched, pick, segs) }

            // 越范围路径由**其他标准范围**的范围内路径构成：范围两两不相交（已由上面的属性
            // 独立验证），故这些路径必然落在 dispatched 之外——这是不依赖被测 contains() 的
            // 独立判据。
            val others = StandardAuditScopes.all.filter { it.id != dispatched.id }
            val foreignPaths = foreignSpec.map { (otherIdx, pick, segs) ->
                val owner = others[otherIdx.mod(others.size)]
                val path = inScopePath(owner, pick, segs)
                // 生成器自检：该路径确实归属它的所属范围。
                owner.contains(path) shouldBe true
                path
            }

            val conclusionPaths = (inScopePaths + foreignPaths).sorted()
            val result = scheduler.validate(dispatched, AuditWorkerReturn.Produced(conclusionPaths))
            // 结论已产出（非 NoResult），validate 必须给出判定而非 null。
            val checked = requireNotNull(result) { "produced conclusion must yield a result" }

            if (foreignPaths.isEmpty()) {
                acceptedCases++
                checked.valid shouldBe true
                checked.outOfScopePaths shouldBe emptyList()
            } else {
                rejectedCases++
                checked.valid shouldBe false
                // 被判越范围的恰好是外部路径集合，范围内路径不得被误判。
                checked.outOfScopePaths.toSet() shouldBe foreignPaths.toSet()
                inScopePaths.none { it in checked.outOfScopePaths } shouldBe true
            }

            // 同一结论经完整调度：越范围结论用满补发后停止并报告该范围未覆盖（R2.11）。
            val single = ParityAuditScheduler(
                scopes = listOf(dispatched),
                dispatcher = AuditWorkerDispatcher { _, _ -> AuditWorkerReturn.Produced(conclusionPaths) },
                minValidResults = 1,
            )
            val outcome = single.runParallel()
            if (foreignPaths.isEmpty()) {
                (outcome is ScheduleOutcome.Completed) shouldBe true
                outcome.traces.single().attempts.size shouldBe 1
            } else {
                (outcome is ScheduleOutcome.Stopped) shouldBe true
                val stopped = outcome as ScheduleOutcome.Stopped
                stopped.uncoveredScopeIds shouldBe listOf(dispatched.id)
                stopped.validCount shouldBe 0
                stopped.traces.single().replacementsUsed shouldBe ParityAuditScheduler.MAX_REPLACEMENTS
            }
        }

        (acceptedCases > 0) shouldBe true
        (rejectedCases > 0) shouldBe true
    }

    test("Property 49 (no overreach): 提示词守卫在启动前检出范围外路径 token") {
        val guard = BoundaryGuard(workspaceRoot = System.getProperty("user.dir") ?: ".")

        // 该属性的定义域：BoundaryGuard.scanPrompt 只做**前缀级**越范围判定（不支持 exclude
        // 挖除语义），且其 token 识别限于"已知模块根 + 至少一个路径段"。因此这里只把不落在
        // dispatched 任一 include 前缀下、且可被 token 模式识别的路径作为越范围判据；
        // exclude 敏感的归属用例（如 shared/.../p2p/filetransfer 对 S1）由上一个测试经
        // validate() 覆盖，不在此处重复判定。
        val tokenRoots = setOf(
            "app", "core", "device-discovery", "remote-control", "file-transfer",
            "shared", "baselineprofile", "scripts", "docs", "gradle",
        )

        fun isTokenMatchable(path: String): Boolean {
            val segs = path.split("/")
            return segs.size >= 2 && segs.first() in tokenRoots
        }

        val inScopeSpecArb = Arb.list(
            Arb.bind(Arb.int(0..7), benignSegsArb) { pick, segs -> pick to segs },
            1..2,
        )
        val foreignSpecArb = Arb.list(
            Arb.bind(Arb.int(0..2), Arb.int(0..7), benignSegsArb) { other, pick, segs ->
                Triple(other, pick, segs)
            },
            0..2,
        )

        var cleanCases = 0
        var flaggedCases = 0

        checkAll(200, Arb.element(StandardAuditScopes.all), inScopeSpecArb, foreignSpecArb) {
                dispatched, inScopeSpec, foreignSpec ->

            val allowedPrefixes = dispatched.includedPrefixes.toSet()
            fun underDispatched(path: String): Boolean = allowedPrefixes.any {
                AuditScope.pathStartsWith(
                    AuditScope.normalizePath(path),
                    AuditScope.normalizePath(it),
                )
            }

            val inScopePaths = inScopeSpec.map { (pick, segs) -> inScopePath(dispatched, pick, segs) }
            val others = StandardAuditScopes.all.filter { it.id != dispatched.id }
            val foreignPaths = foreignSpec
                .map { (otherIdx, pick, segs) ->
                    inScopePath(others[otherIdx.mod(others.size)], pick, segs)
                }
                .filter { !underDispatched(it) && isTokenMatchable(it) }

            val prompt = buildString {
                append("范围 ${dispatched.id} 审查任务结论：证据路径 ")
                append((inScopePaths + foreignPaths).joinToString(", "))
            }

            val scan = guard.scanPrompt(prompt, scopeAllowedPathPrefixes = allowedPrefixes)
            val flagged = scan.findings
                .filter { it.category == PromptFindingCategory.OUT_OF_SCOPE_PATH }
                .map { it.matchedSnippet }
                .toSet()

            if (foreignPaths.isEmpty()) {
                cleanCases++
                // 仅引用范围内路径：不得报出越范围命中。
                flagged shouldBe emptySet()
                scan.clean shouldBe true
            } else {
                flaggedCases++
                // 每条范围外路径都必须被检出（无漏报），且范围内路径不被误报。
                foreignPaths.all { it in flagged } shouldBe true
                inScopePaths.none { it in flagged } shouldBe true
                scan.clean shouldBe false
            }
        }

        (cleanCases > 0) shouldBe true
        (flaggedCases > 0) shouldBe true
    }

    // endregion
})
