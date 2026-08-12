package com.skybridge.compass.audit

import java.nio.file.Path
import java.nio.file.Paths
import java.util.Locale

/**
 * 边界守卫（Cross-Platform Parity Audit，任务 4.2 / R11.1、R11.9、R11.10、R11.12）。
 *
 * 该类是**审计工具代码**，位于 `test` 源集，不随生产应用打包（遵守 G3：仅 Kotlin；
 * 不改动 Apple 源码树）。它承担两项职责：
 *
 * 1. **路径守卫**：把候选路径规范化后，拒绝任何不以工作区根为前缀的路径（R11.1），
 *    并拒绝任何属于 macOS / iOS 源码树的文件（R11.10 的判定基础）。
 * 2. **提示词守卫**：在启动只读审查任务前扫描提示词中的凭据类模式（私钥、令牌、
 *    密钥库、口令、本地凭据配置）与越范围路径（R11.9）；命中时按"至多重发 2 次，
 *    仍命中则停止该范围并报告"的语义返回决策（R11.12）。
 *
 * 设计要点：
 * - 纯逻辑、无 I/O、无 Android 依赖，可作为普通 JVM 单元测试运行。
 * - 路径规范化基于 [java.nio.file.Path.normalize]，逻辑地消解 `.` 与 `..` 段，
 *   即使目标文件不存在也可判定，从而在写入**之前**拦截越界路径。
 */
class BoundaryGuard(workspaceRoot: String) {

    /** 规范化后的工作区根绝对路径，作为所有路径判定的前缀基准。 */
    private val root: Path = Paths.get(workspaceRoot).toAbsolutePath().normalize()

    // region 路径守卫（R11.1 / R11.10）

    /**
     * 规范化候选路径并判定其是否被允许写入 / 解析。
     *
     * 判定顺序：
     * 1. 规范化后必须以工作区根为前缀，否则 [PathRejectionReason.OUTSIDE_WORKSPACE_ROOT]。
     * 2. 不得属于 macOS / iOS 源码树，否则 [PathRejectionReason.APPLE_SOURCE_TREE]。
     *
     * @param candidate 绝对或相对路径；相对路径按工作区根解析。
     */
    fun checkPath(candidate: String): PathGuardResult {
        val normalized: Path = if (Paths.get(candidate).isAbsolute) {
            Paths.get(candidate).normalize()
        } else {
            root.resolve(candidate).normalize()
        }

        if (!normalized.startsWith(root)) {
            return PathGuardResult(
                allowed = false,
                normalizedPath = normalized.toString(),
                reason = PathRejectionReason.OUTSIDE_WORKSPACE_ROOT,
            )
        }

        if (isAppleSourceTreePath(normalized.toString())) {
            return PathGuardResult(
                allowed = false,
                normalizedPath = normalized.toString(),
                reason = PathRejectionReason.APPLE_SOURCE_TREE,
            )
        }

        return PathGuardResult(
            allowed = true,
            normalizedPath = normalized.toString(),
            reason = null,
        )
    }

    /**
     * 从一批待写入 / 待提交路径中筛出属于 macOS / iOS 源码树或越界的路径（R11.10）。
     * 返回被拦截的路径集合；调用方据此放弃写入、还原文件并报告被拦截数量与 Gap_Item 编号。
     */
    fun interceptForbidden(paths: Iterable<String>): List<PathGuardResult> =
        paths.map(::checkPath).filter { !it.allowed }

    private fun isAppleSourceTreePath(path: String): Boolean {
        val lower = path.lowercase(Locale.ROOT)
        // Apple 源码树标志：Swift / Objective-C 源文件、Xcode 工程与工作区、构建配置。
        if (APPLE_FILE_SUFFIXES.any { lower.endsWith(it) }) return true
        if (APPLE_DIR_MARKERS.any { lower.contains(it) }) return true
        return false
    }

    // endregion

    // region 提示词守卫（R11.9 / R11.12）

    /**
     * 扫描单个提示词，返回凭据类模式与越范围路径的命中项。
     *
     * @param scopeAllowedPathPrefixes 当前范围允许出现的仓库相对路径前缀集合；
     *   提示词中出现的、不落在任一前缀下的模块路径记为越范围命中（R11.9）。
     */
    fun scanPrompt(
        prompt: String,
        scopeAllowedPathPrefixes: Set<String> = emptySet(),
    ): PromptScanResult {
        val findings = mutableListOf<PromptFinding>()

        for ((category, regex) in CREDENTIAL_PATTERNS) {
            regex.findAll(prompt).forEach { match ->
                findings += PromptFinding(category, redact(match.value))
            }
        }

        if (scopeAllowedPathPrefixes.isNotEmpty()) {
            MODULE_PATH_PATTERN.findAll(prompt).forEach { match ->
                val token = match.value.trimStart('/')
                val inScope = scopeAllowedPathPrefixes.any { prefix ->
                    val p = prefix.trimStart('/').trimEnd('/')
                    token == p || token.startsWith("$p/")
                }
                if (!inScope) {
                    findings += PromptFinding(PromptFindingCategory.OUT_OF_SCOPE_PATH, token)
                }
            }
        }

        return PromptScanResult(clean = findings.isEmpty(), findings = findings)
    }

    /**
     * 在启动审查任务前对提示词执行守卫，实现 R11.12 的重发 / 停止语义：
     * - 提示词干净 → 允许启动。
     * - 命中 → 调用 [sanitize] 移除命中内容后重扫；至多重发 [MAX_RESENDS] 次。
     * - 达到重发上限仍命中 → 停止该范围并返回 [LaunchDecision.ScopeStopped] 供上报。
     *
     * @param sanitize 接收当前提示词与本轮命中项，返回移除命中内容后的新提示词。
     */
    fun guardAuditWorkerLaunch(
        scopeId: String,
        initialPrompt: String,
        scopeAllowedPathPrefixes: Set<String> = emptySet(),
        sanitize: (prompt: String, findings: List<PromptFinding>) -> String = { p, _ -> p },
    ): LaunchDecision {
        var prompt = initialPrompt
        var scan = scanPrompt(prompt, scopeAllowedPathPrefixes)
        if (scan.clean) {
            return LaunchDecision.Allowed(prompt = prompt, resendCount = 0)
        }

        var resends = 0
        while (resends < MAX_RESENDS) {
            prompt = sanitize(prompt, scan.findings)
            resends++
            scan = scanPrompt(prompt, scopeAllowedPathPrefixes)
            if (scan.clean) {
                return LaunchDecision.Allowed(prompt = prompt, resendCount = resends)
            }
        }

        return LaunchDecision.ScopeStopped(
            scopeId = scopeId,
            findings = scan.findings,
            attempts = resends + 1, // 初次 + 重发次数
        )
    }

    // endregion

    companion object {
        /** R11.12：至多重发 2 次后停止该范围。 */
        const val MAX_RESENDS: Int = 2

        private val APPLE_FILE_SUFFIXES = listOf(
            ".swift", ".m", ".mm", ".pbxproj", ".xcconfig",
            ".xcworkspacedata", ".xcscheme", ".entitlements",
        )

        private val APPLE_DIR_MARKERS = listOf(
            ".xcodeproj/", ".xcworkspace/", "/macos/", "/ios/", "/apple/",
        )

        /** 越范围路径检测：匹配已知模块根开头的仓库相对路径 token。 */
        private val MODULE_PATH_PATTERN = Regex(
            "\\b(?:app|core|device-discovery|remote-control|file-transfer|shared|baselineprofile|scripts|docs|gradle)(?:/[\\w.\\-]+)+",
        )

        private val CREDENTIAL_PATTERNS: List<Pair<PromptFindingCategory, Regex>> = listOf(
            PromptFindingCategory.PRIVATE_KEY to Regex(
                "-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----",
            ),
            PromptFindingCategory.KEYSTORE to Regex(
                "(?i)(?:\\b\\w[\\w.\\-]*\\.(?:jks|keystore|p12|bks|pfx)\\b|keystorepassword|keyalias\\s*[:=])",
            ),
            PromptFindingCategory.TOKEN to Regex(
                "(?i)(?:bearer\\s+[a-z0-9._\\-]+|ghp_[a-z0-9]{20,}|xox[baprs]-[a-z0-9\\-]+|akia[0-9a-z]{16}|eyj[a-z0-9_\\-]+\\.[a-z0-9_\\-]+\\.[a-z0-9_\\-]+|(?:access[_-]?token|api[_-]?key|auth[_-]?token|secret[_-]?key)\\s*[:=]\\s*\\S+)",
            ),
            PromptFindingCategory.PASSWORD to Regex(
                "(?i)(?:password|passwd|pwd)\\s*[:=]\\s*\\S+",
            ),
            PromptFindingCategory.LOCAL_CREDENTIAL_CONFIG to Regex(
                "(?i)(?:\\blocal\\.properties\\b|(?:^|\\s)\\.env(?:\\.\\w+)?\\b|supabase_anon_key|supabase_service_role_key|nebula_client_secret)",
            ),
        )

        private fun redact(raw: String): String {
            val trimmed = raw.trim()
            val head = trimmed.take(4)
            return "<redacted:${head}…:len=${trimmed.length}>"
        }
    }
}

/** 路径守卫判定结果。 */
data class PathGuardResult(
    val allowed: Boolean,
    val normalizedPath: String,
    val reason: PathRejectionReason?,
)

enum class PathRejectionReason {
    /** 规范化后不以工作区根为前缀（R11.1）。 */
    OUTSIDE_WORKSPACE_ROOT,

    /** 属于 macOS / iOS 源码树（R11.10）。 */
    APPLE_SOURCE_TREE,
}

/** 提示词扫描结果。 */
data class PromptScanResult(
    val clean: Boolean,
    val findings: List<PromptFinding>,
)

/** 单条提示词命中，[matchedSnippet] 已做脱敏，不回显明文凭据。 */
data class PromptFinding(
    val category: PromptFindingCategory,
    val matchedSnippet: String,
)

enum class PromptFindingCategory {
    PRIVATE_KEY,
    TOKEN,
    KEYSTORE,
    PASSWORD,
    LOCAL_CREDENTIAL_CONFIG,
    OUT_OF_SCOPE_PATH,
}

/** 审查任务启动守卫决策（R11.12）。 */
sealed interface LaunchDecision {
    /** 允许启动；[resendCount] 记录为达到干净状态而发生的重发次数（0 表示首次即干净）。 */
    data class Allowed(val prompt: String, val resendCount: Int) : LaunchDecision

    /** 达到重发上限仍命中，停止该范围并报告。 */
    data class ScopeStopped(
        val scopeId: String,
        val findings: List<PromptFinding>,
        val attempts: Int,
    ) : LaunchDecision
}
