package com.skybridge.compass.audit

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * BoundaryGuard 单元测试（任务 4.2 / R11.1、R11.9、R11.10、R11.12）。
 *
 * 使用 JUnit Jupiter（与 `:app` 模块 `useJUnitPlatform()` 一致），位于 `test`
 * 源集，不随生产应用打包。
 */
class BoundaryGuardTest {

    private val workspaceRoot = "/workspace/skybridge-android"
    private val guard = BoundaryGuard(workspaceRoot)

    // region 路径守卫

    @Test
    fun pathInsideWorkspaceRootIsAllowed() {
        val result = guard.checkPath("app/src/main/kotlin/com/skybridge/Foo.kt")

        assertTrue(result.allowed, "workspace-relative path should be allowed")
        assertEquals(
            "$workspaceRoot/app/src/main/kotlin/com/skybridge/Foo.kt",
            result.normalizedPath,
        )
        assertEquals(null, result.reason)
    }

    @Test
    fun absolutePathInsideWorkspaceRootIsAllowed() {
        val result = guard.checkPath("$workspaceRoot/gradle/libs.versions.toml")

        assertTrue(result.allowed)
        assertEquals(null, result.reason)
    }

    @Test
    fun pathOutsideWorkspaceRootIsRejected() {
        val result = guard.checkPath("/etc/passwd")

        assertFalse(result.allowed, "path outside workspace root must be rejected")
        assertEquals(PathRejectionReason.OUTSIDE_WORKSPACE_ROOT, result.reason)
    }

    @Test
    fun traversalEscapingWorkspaceRootIsRejected() {
        // 逻辑规范化消解 `..`，逃逸到工作区根之外即被拒绝。
        val result = guard.checkPath("app/../../secrets/key.pem")

        assertFalse(result.allowed)
        assertEquals(PathRejectionReason.OUTSIDE_WORKSPACE_ROOT, result.reason)
    }

    @Test
    fun macosSourceTreePathIsRejected() {
        val result = guard.checkPath("$workspaceRoot/macos/SkyBridge/AppDelegate.swift")

        assertFalse(result.allowed, "macOS source tree path must be rejected")
        assertEquals(PathRejectionReason.APPLE_SOURCE_TREE, result.reason)
    }

    @Test
    fun iosSwiftFileIsRejected() {
        val result = guard.checkPath("$workspaceRoot/ios/Sources/PeerService.swift")

        assertFalse(result.allowed)
        assertEquals(PathRejectionReason.APPLE_SOURCE_TREE, result.reason)
    }

    @Test
    fun xcodeProjectFileIsRejected() {
        val result = guard.checkPath("$workspaceRoot/SkyBridge.xcodeproj/project.pbxproj")

        assertFalse(result.allowed)
        assertEquals(PathRejectionReason.APPLE_SOURCE_TREE, result.reason)
    }

    @Test
    fun interceptForbiddenReturnsOnlyRejectedPaths() {
        val batch = listOf(
            "app/src/main/kotlin/A.kt",              // allowed
            "$workspaceRoot/ios/B.swift",            // apple
            "/tmp/outside.txt",                      // outside
            "core/src/test/kotlin/C.kt",             // allowed
        )

        val intercepted = guard.interceptForbidden(batch)

        assertEquals(2, intercepted.size, "exactly two forbidden paths expected")
        assertTrue(intercepted.any { it.reason == PathRejectionReason.APPLE_SOURCE_TREE })
        assertTrue(intercepted.any { it.reason == PathRejectionReason.OUTSIDE_WORKSPACE_ROOT })
    }

    // endregion

    // region 提示词守卫

    @Test
    fun cleanPromptIsAllowed() {
        val prompt = "审计范围 S2 文件传输：请只读检查 file-transfer/src 与 " +
            "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/filetransfer 下的接线情况。"

        val scan = guard.scanPrompt(
            prompt,
            scopeAllowedPathPrefixes = setOf(
                "file-transfer",
                "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/filetransfer",
            ),
        )

        assertTrue(scan.clean, "clean prompt should pass with no findings")
        assertTrue(scan.findings.isEmpty())
    }

    @Test
    fun promptWithPrivateKeyIsBlocked() {
        val prompt = "使用以下密钥连接：-----BEGIN RSA PRIVATE KEY-----\nMIIEvAIBADANBg...\n"

        val scan = guard.scanPrompt(prompt)

        assertFalse(scan.clean, "prompt containing a private key must be blocked")
        assertTrue(scan.findings.any { it.category == PromptFindingCategory.PRIVATE_KEY })
        // 命中片段已脱敏，不回显完整明文。
        assertTrue(scan.findings.all { !it.matchedSnippet.contains("MIIEvAIBAD") })
    }

    @Test
    fun promptWithTokenIsBlocked() {
        val prompt = "调用 API 时使用 access_token=abc123def456 完成鉴权。"

        val scan = guard.scanPrompt(prompt)

        assertFalse(scan.clean)
        assertTrue(scan.findings.any { it.category == PromptFindingCategory.TOKEN })
    }

    @Test
    fun promptWithPasswordIsBlocked() {
        val scan = guard.scanPrompt("keystore password: super-secret-pass")

        assertFalse(scan.clean)
        assertTrue(
            scan.findings.any {
                it.category == PromptFindingCategory.PASSWORD ||
                    it.category == PromptFindingCategory.KEYSTORE
            },
        )
    }

    @Test
    fun promptWithLocalCredentialConfigIsBlocked() {
        val scan = guard.scanPrompt("请读取 local.properties 与 SUPABASE_ANON_KEY 配置项。")

        assertFalse(scan.clean)
        assertTrue(scan.findings.any { it.category == PromptFindingCategory.LOCAL_CREDENTIAL_CONFIG })
    }

    @Test
    fun promptWithOutOfScopePathIsFlagged() {
        // 范围仅允许 file-transfer，提示词却引用 remote-control 路径 → 越范围。
        val prompt = "请检查 file-transfer/src/main/A.kt 以及 remote-control/src/main/B.kt。"

        val scan = guard.scanPrompt(prompt, scopeAllowedPathPrefixes = setOf("file-transfer"))

        assertFalse(scan.clean)
        val outOfScope = scan.findings.filter { it.category == PromptFindingCategory.OUT_OF_SCOPE_PATH }
        assertEquals(1, outOfScope.size)
        assertTrue(outOfScope.single().matchedSnippet.startsWith("remote-control/"))
    }

    // endregion

    // region 审查任务启动守卫（重发 / 停止语义 R11.12）

    @Test
    fun launchAllowedWhenPromptIsCleanFromStart() {
        val decision = guard.guardAuditWorkerLaunch(
            scopeId = "S1",
            initialPrompt = "只读审计 device-discovery 模块的发现广播接线。",
            scopeAllowedPathPrefixes = setOf("device-discovery"),
        )

        val allowed = assertInstanceOf(LaunchDecision.Allowed::class.java, decision)
        assertEquals(0, allowed.resendCount)
    }

    @Test
    fun launchAllowedAfterSanitizingWithinResendLimit() {
        val dirty = "审计 core 模块；顺带用 access_token=leak123 调用接口。"
        var sanitized = false

        val decision = guard.guardAuditWorkerLaunch(
            scopeId = "S1",
            initialPrompt = dirty,
            scopeAllowedPathPrefixes = setOf("core"),
            sanitize = { _, _ ->
                sanitized = true
                "审计 core 模块的接线情况。" // 移除凭据后干净
            },
        )

        assertTrue(sanitized, "sanitize should be invoked to remove the credential")
        val allowed = assertInstanceOf(LaunchDecision.Allowed::class.java, decision)
        assertEquals(1, allowed.resendCount)
    }

    @Test
    fun scopeStoppedWhenCredentialPersistsBeyondTwoResends() {
        // sanitize 无效（始终返回含凭据的提示词）→ 至多重发 2 次后停止该范围。
        val dirty = "token: bearer abcdef....."

        val decision = guard.guardAuditWorkerLaunch(
            scopeId = "S3",
            initialPrompt = dirty,
            sanitize = { p, _ -> p }, // 故意不清理
        )

        val stopped = assertInstanceOf(LaunchDecision.ScopeStopped::class.java, decision)
        assertEquals("S3", stopped.scopeId)
        // 初次 + 2 次重发 = 3 次尝试。
        assertEquals(BoundaryGuard.MAX_RESENDS + 1, stopped.attempts)
        assertTrue(stopped.findings.isNotEmpty())
    }

    // endregion
}
