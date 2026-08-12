package com.skybridge.compass.audit

/**
 * 一个只读审计范围（Cross-Platform Parity Audit，任务 4.3 / R2.1）。
 *
 * 范围以**仓库根相对路径前缀**表达：[includedPrefixes] 给出被纳入的目录/文件前缀，
 * [excludedPrefixes] 从中挖去更深层的子树（用于表达"shared 的 p2p 但不含 filetransfer"
 * 这类切分）。归属判定见 [contains]。
 *
 * 相等 / 交集判定不依赖前缀书写顺序，且以规范化后的路径段边界为准（`a/b` 是 `a/bc` 的
 * 前缀但不覆盖它——见 [pathStartsWith]）。
 */
data class AuditScope(
    /** 范围标识（S1..S4）。 */
    val id: String,
    /** 人类可读的范围名称。 */
    val displayName: String,
    /** 被纳入的仓库相对路径前缀集合。 */
    val includedPrefixes: List<String>,
    /** 从 [includedPrefixes] 中挖去的更深层子树前缀集合。 */
    val excludedPrefixes: List<String> = emptyList(),
) {
    private val includes: List<String> = includedPrefixes.map(::normalizePath).filter { it.isNotEmpty() }
    private val excludes: List<String> = excludedPrefixes.map(::normalizePath).filter { it.isNotEmpty() }

    init {
        require(id.isNotBlank()) { "scope id must not be blank" }
        require(includes.isNotEmpty()) { "scope $id must include at least one prefix" }
    }

    /**
     * 判定 [path]（仓库相对路径）是否归属本范围：
     * 命中任一 [includedPrefixes] 且不命中任何 [excludedPrefixes]。
     */
    fun contains(path: String): Boolean {
        val p = normalizePath(path)
        if (p.isEmpty()) return false
        if (excludes.any { pathStartsWith(p, it) }) return false
        return includes.any { pathStartsWith(p, it) }
    }

    /**
     * 判定本范围与 [other] 是否存在交集（即存在某条路径同时归属两者）。
     *
     * 不枚举无限路径空间，而是基于前缀的结构关系做有限判定：对每一对 (a ∈ includes,
     * b ∈ other.includes)，若二者存在前缀包含关系，则较深者所在子树是二者共同的候选交集区；
     * 只要该区未被**任一方**的某个 exclude 完整覆盖，就存在既在该区内、又避开所有 exclude 的
     * 路径，从而两范围相交。
     */
    fun overlaps(other: AuditScope): Boolean {
        for (a in includes) {
            for (b in other.includes) {
                val deeper = commonRegion(a, b) ?: continue
                val coveredByThis = excludes.any { covers(it, deeper) }
                val coveredByOther = other.excludes.any { covers(it, deeper) }
                if (!coveredByThis && !coveredByOther) return true
            }
        }
        return false
    }

    companion object {
        /**
         * 规范化路径：去首尾空白、反斜杠转正斜杠、去 `./` 前缀、折叠多重斜杠、去首尾斜杠。
         */
        fun normalizePath(raw: String): String {
            var s = raw.trim().replace('\\', '/')
            while (s.startsWith("./")) s = s.substring(2)
            s = s.replace(Regex("/+"), "/")
            return s.trim('/')
        }

        /**
         * 路径段边界感知的前缀判定：[path] 是否等于 [prefix] 或位于 [prefix] 子树下。
         * `a/b`.startsWith(`a/b`) = true；`a/bc`.startsWith(`a/b`) = false。
         */
        fun pathStartsWith(path: String, prefix: String): Boolean =
            path == prefix || path.startsWith("$prefix/")

        /**
         * 两前缀若存在包含关系，返回较深（更具体）的那个作为共同候选区；否则返回 null。
         */
        private fun commonRegion(a: String, b: String): String? = when {
            a == b -> a
            pathStartsWith(b, a) -> b // b 在 a 子树下，较深者为 b
            pathStartsWith(a, b) -> a // a 在 b 子树下，较深者为 a
            else -> null
        }

        /**
         * [exclude] 是否**完整覆盖** [region]：当 exclude 等于 region 或 region 位于 exclude
         * 子树下时成立（此时 region 内所有路径都被挖去，不再是交集）。
         * 若 exclude 只是 region 的更深子树，则不能完整覆盖 region（region 内仍有路径避开 exclude）。
         */
        private fun covers(exclude: String, region: String): Boolean = pathStartsWith(region, exclude)
    }
}

/**
 * 一次只读审查任务的原始返回。
 */
sealed interface AuditWorkerReturn {
    /** 审查任务未返回任何结论（R2.11 的"未返回"分支）。 */
    data object NoResult : AuditWorkerReturn

    /** 审查任务产出结论，引用了 [producedPaths] 中的仓库路径作为证据。 */
    data class Produced(val producedPaths: List<String>) : AuditWorkerReturn
}

/**
 * 经越范围检测后的审查任务结果。[valid] 为真当且仅当审查任务有返回且无越范围路径。
 */
data class AuditWorkerResult(
    val scopeId: String,
    val producedPaths: List<String>,
    /** 落在指派范围之外的路径；非空即视为无效（越范围）返回（R2.11）。 */
    val outOfScopePaths: List<String>,
) {
    val valid: Boolean get() = outOfScopePaths.isEmpty()
}

/** 抽象的只读审查任务派发器（真实模型选择在当前运行时不可控，见 R2.6）。 */
fun interface AuditWorkerDispatcher {
    /**
     * 为 [scope] 派发一次只读审查任务。
     * @param attempt 0 为初次派发，1.. 为补发替换的序号。
     */
    fun dispatch(scope: AuditScope, attempt: Int): AuditWorkerReturn
}

/** 单次派发尝试的结果分类。 */
enum class AttemptOutcome {
    /** 有返回且完全落在指派范围内。 */
    VALID,

    /** 有返回但引用了范围外路径（越范围，视为无效）。 */
    OUT_OF_SCOPE,

    /** 未返回任何结论。 */
    NO_RESULT,
}

/** 单次派发尝试记录。 */
data class DispatchAttempt(
    val scopeId: String,
    /** 0 为初次派发，1.. 为补发替换序号。 */
    val attempt: Int,
    val isReplacement: Boolean,
    val outcome: AttemptOutcome,
    val outOfScopePaths: List<String>,
)

/** 单个范围的完整派发轨迹（含初次与全部补发）。 */
data class ScopeDispatchTrace(
    val scopeId: String,
    val attempts: List<DispatchAttempt>,
    val replacementsUsed: Int,
    val finalResult: AuditWorkerResult?,
)

/** 调度总结果（R2.11）。 */
sealed interface ScheduleOutcome {
    val traces: List<ScopeDispatchTrace>

    /** 有效审查任务数 ≥ 阈值：审计正常完成。 */
    data class Completed(
        val results: List<AuditWorkerResult>,
        override val traces: List<ScopeDispatchTrace>,
    ) : ScheduleOutcome

    /** 补发后有效审查任务仍少于阈值：停止审计并报告（R2.11）。 */
    data class Stopped(
        val validResults: List<AuditWorkerResult>,
        val validCount: Int,
        val requiredCount: Int,
        val uncoveredScopeIds: List<String>,
        override val traces: List<ScopeDispatchTrace>,
    ) : ScheduleOutcome
}

/**
 * 四个标准审计范围（S1–S4），模块/目录集合两两交集为空（R2.1）。
 *
 * 切分依据 design.md §"范围切分"，并按本文件顶部说明把模块源码目录归入特性范围、
 * 把构建脚本与 gradle 基础设施归入 S4，以满足"交集为空"硬约束。
 */
object StandardAuditScopes {

    /** S1 发现与连接。 */
    val S1_DISCOVERY_CONNECTION = AuditScope(
        id = "S1",
        displayName = "发现与连接",
        includedPrefixes = listOf(
            "device-discovery/src",
            "shared/src/main/kotlin/com/skybridge/compass/shared/p2p",
            "core/src/main/kotlin/com/skybridge/compass/core/webrtc",
            "app/src/main/kotlin/com/skybridge/compass/android/discovery",
        ),
        // 文件传输相关的 p2p 子树归 S2，从 S1 挖去。
        excludedPrefixes = listOf(
            "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/filetransfer",
        ),
    )

    /** S2 文件传输。 */
    val S2_FILE_TRANSFER = AuditScope(
        id = "S2",
        displayName = "文件传输",
        includedPrefixes = listOf(
            "file-transfer/src",
            "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/filetransfer",
            "shared/src/main/kotlin/com/skybridge/compass/shared/protocol/CrossPlatformFileTransferProtocol.kt",
            "core/src/main/kotlin/com/skybridge/compass/core/filetransfer",
            "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/filetransfer",
        ),
    )

    /** S3 远程桌面与输入。 */
    val S3_REMOTE_DESKTOP_INPUT = AuditScope(
        id = "S3",
        displayName = "远程桌面与输入",
        includedPrefixes = listOf(
            "remote-control/src",
            "core/src/main/kotlin/com/skybridge/compass/core/remotecontrol",
            "app/src/main/kotlin/com/skybridge/compass/android/remote",
            "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/remotecontrol",
            "scripts/check_android_packaged_placeholders.sh",
        ),
    )

    /** S4 设置与构建。 */
    val S4_SETTINGS_BUILD = AuditScope(
        id = "S4",
        displayName = "设置与构建",
        includedPrefixes = listOf(
            "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/settings",
            "core/src/main/kotlin/com/skybridge/compass/core/data",
            "app/src/main/kotlin/com/skybridge/compass/android/data/cloud",
            // 构建基础设施与全部构建脚本归 S4（模块源码已归各特性范围，故不相交）。
            "gradle",
            "build.gradle.kts",
            "settings.gradle.kts",
            "app/build.gradle.kts",
            "core/build.gradle.kts",
            "device-discovery/build.gradle.kts",
            "remote-control/build.gradle.kts",
            "file-transfer/build.gradle.kts",
            "shared/build.gradle.kts",
            "baselineprofile/build.gradle.kts",
        ),
    )

    /** S1–S4 全集。 */
    val all: List<AuditScope> = listOf(
        S1_DISCOVERY_CONNECTION,
        S2_FILE_TRANSFER,
        S3_REMOTE_DESKTOP_INPUT,
        S4_SETTINGS_BUILD,
    )
}
