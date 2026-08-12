package com.skybridge.compass.audit

import java.util.Locale

/**
 * 范围切分与并行只读审查任务调度（Cross-Platform Parity Audit，任务 4.3 / R2.1、R2.11）。
 *
 * 该文件是**审计工具代码**，位于 `:app` 模块的 `test` 源集（与 [BoundaryGuard] 同包），
 * 不随生产应用打包（遵守 G3：仅 Kotlin；不改动 Apple 源码树）。它承担四项职责：
 *
 * 1. **范围切分（R2.1）**：把仓库切成 S1 发现与连接 / S2 文件传输 / S3 远程桌面与输入 /
 *    S4 设置与构建四个只读审计范围；**任意两个范围的模块与目录集合交集为空**，并在构造
 *    [ParityAuditScheduler] 时强制校验（[requirePairwiseDisjoint]）。
 * 2. **归属判定（[AuditScope.contains]）**：把仓库相对路径规范化后判定其归属于哪个范围。
 * 3. **越范围检测**：审查任务返回的结论若引用了其指派范围之外的路径，视为无效返回（R2.11）。
 * 4. **补发与停止（R2.11）**：越范围或未返回的审查任务，以同一范围**至多补发替换两次**；
 *    补发后有效返回的审查任务仍少于四个时，停止审计并报告实际有效数量与未覆盖范围。
 *
 * 设计说明（与 design.md §"范围切分"的对齐与偏差）：
 * - design 的范围表把 S4 描述为"全部 gradle.kts 与 gradle 目录"，而 S1–S3 描述为整模块。
 *   直接照搬会使各模块的 build.gradle.kts 同时落入其所属模块范围与 S4，交集非空，
 *   违反 R2.1"交集为空"这一硬约束。为满足该硬约束（且本任务明确要求"enforce and test"），
 *   本实现把各模块的源码目录（module/src）归入其所属特性范围，把构建脚本
 *   （根与各模块 build.gradle.kts、settings.gradle.kts、gradle 目录）归入 S4。
 *   该切分与设计意图一致（构建健康归 S4，模块代码归特性范围），且可被机器校验为不相交。
 * - 运行时限制（R2.6）：当前运行时不暴露审查任务的模型选择与推理档位控制接口，故本调度器
 *   以抽象的 [AuditWorkerDispatcher] 表示一次只读审查任务派发，真实模型选择不可控；调度逻辑
 *   （切分、越范围检测、补发、停止）与模型无关，可独立单测。
 */
class ParityAuditScheduler(
    /** 参与调度的审计范围集合，默认 [StandardAuditScopes.all]（S1–S4）。 */
    val scopes: List<AuditScope> = StandardAuditScopes.all,
    /** 一次只读审查任务派发的抽象执行器。 */
    private val dispatcher: AuditWorkerDispatcher,
    /** 视为审计有效所需的最少有效审查任务数（R2.11 要求 ≥ 4）。 */
    val minValidResults: Int = MIN_VALID_RESULTS,
    /** 单个范围至多补发替换次数（R2.11 要求至多两次）。 */
    val maxReplacements: Int = MAX_REPLACEMENTS,
) {
    init {
        require(scopes.isNotEmpty()) { "scopes must not be empty" }
        require(minValidResults >= 1) { "minValidResults must be >= 1, was $minValidResults" }
        require(maxReplacements >= 0) { "maxReplacements must be >= 0, was $maxReplacements" }
        val duplicateIds = scopes.groupingBy { it.id }.eachCount().filterValues { it > 1 }.keys
        require(duplicateIds.isEmpty()) { "duplicate scope ids: $duplicateIds" }
        requirePairwiseDisjoint(scopes)
    }

    /**
     * 校验一个审查任务原始返回是否落在其指派范围内，并计算越范围路径。
     *
     * @return 对应 [scope] 的 [AuditWorkerResult]；若审查任务未返回（[AuditWorkerReturn.NoResult]）则返回 null。
     */
    fun validate(scope: AuditScope, ret: AuditWorkerReturn): AuditWorkerResult? = when (ret) {
        AuditWorkerReturn.NoResult -> null
        is AuditWorkerReturn.Produced -> {
            val outOfScope = ret.producedPaths.filterNot { scope.contains(it) }
            AuditWorkerResult(
                scopeId = scope.id,
                producedPaths = ret.producedPaths,
                outOfScopePaths = outOfScope,
            )
        }
    }

    /**
     * 并行调度全部范围的只读审查任务，执行越范围检测、至多两次补发替换，并按"有效结果 < 4
     * 则停止并报告"的规则返回结果（R2.1、R2.11）。
     *
     * 各范围之间相互独立、无共享状态，逻辑上可并行派发；本实现以确定性的逐范围调度表达该
     * 并行语义（结果与派发顺序无关），便于复现与单测。
     */
    fun runParallel(): ScheduleOutcome {
        val perScope: List<ScopeDispatchTrace> = scopes.map { scope -> scheduleOne(scope) }

        val validResults = perScope.mapNotNull { it.finalResult?.takeIf(AuditWorkerResult::valid) }
        val coveredScopeIds = validResults.map { it.scopeId }.toSet()
        val uncoveredScopeIds = scopes.map { it.id }.filterNot { it in coveredScopeIds }

        return if (validResults.size < minValidResults) {
            // R2.11：补发后有效审查任务仍少于四个 → 停止审计并报告实际有效数量与未覆盖范围。
            ScheduleOutcome.Stopped(
                validResults = validResults,
                validCount = validResults.size,
                requiredCount = minValidResults,
                uncoveredScopeIds = uncoveredScopeIds,
                traces = perScope,
            )
        } else {
            ScheduleOutcome.Completed(
                results = validResults,
                traces = perScope,
            )
        }
    }

    /**
     * 对单个范围执行"初次派发 + 至多 [maxReplacements] 次补发替换"。
     * 一旦拿到落在范围内的有效返回即停止；否则记录全部尝试并返回最后一次结果（可能无效或缺失）。
     */
    private fun scheduleOne(scope: AuditScope): ScopeDispatchTrace {
        val attempts = mutableListOf<DispatchAttempt>()
        var finalResult: AuditWorkerResult? = null

        // attempt 索引 0 为初次派发，1..maxReplacements 为补发替换。
        for (attempt in 0..maxReplacements) {
            val ret = dispatcher.dispatch(scope, attempt)
            val result = validate(scope, ret)
            val outcome = when {
                result == null -> AttemptOutcome.NO_RESULT
                result.valid -> AttemptOutcome.VALID
                else -> AttemptOutcome.OUT_OF_SCOPE
            }
            attempts += DispatchAttempt(
                scopeId = scope.id,
                attempt = attempt,
                isReplacement = attempt > 0,
                outcome = outcome,
                outOfScopePaths = result?.outOfScopePaths ?: emptyList(),
            )
            finalResult = result
            if (outcome == AttemptOutcome.VALID) break
        }

        return ScopeDispatchTrace(
            scopeId = scope.id,
            attempts = attempts,
            replacementsUsed = attempts.count { it.isReplacement },
            finalResult = finalResult,
        )
    }

    companion object {
        /** R2.11：至少四个有效审查任务。 */
        const val MIN_VALID_RESULTS: Int = 4

        /** R2.11：单个范围至多补发替换两次。 */
        const val MAX_REPLACEMENTS: Int = 2

        /**
         * 校验范围集合两两不相交；发现相交即抛 [IllegalArgumentException]（R2.1 硬约束）。
         * 相交判定见 [AuditScope.overlaps]。
         */
        fun requirePairwiseDisjoint(scopes: List<AuditScope>) {
            for (i in scopes.indices) {
                for (j in i + 1 until scopes.size) {
                    val a = scopes[i]
                    val b = scopes[j]
                    require(!a.overlaps(b)) {
                        "audit scopes ${a.id} and ${b.id} overlap; scopes must be pairwise disjoint (R2.1)"
                    }
                }
            }
        }

        /** 便捷判定：范围集合是否两两不相交（不抛异常，供测试断言）。 */
        fun arePairwiseDisjoint(scopes: List<AuditScope>): Boolean {
            for (i in scopes.indices) {
                for (j in i + 1 until scopes.size) {
                    if (scopes[i].overlaps(scopes[j])) return false
                }
            }
            return true
        }
    }
}
