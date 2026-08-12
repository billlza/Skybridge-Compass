package com.skybridge.compass.shared.audit

import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption

/**
 * Audit_Report 写入门面（任务 4.1，_Requirements: 1.13、2.5、11.8_）。
 *
 * 这是**审计工具代码**，位于 `shared` 模块的 test 源集，不随生产应用打包（design §"Audit_Report 产物布局"）。
 *
 * 写入策略：
 *  - "临时文件 + 原子替换"：先把内容写入同目录下的临时文件，再以原子移动替换目标文件，避免半写状态。
 *  - 失败最多重试 3 次（共 3 次尝试）。
 *  - 三次失败后停止：调用方据此停止启动新审查任务与相关代码修改；已成功写入的内容**不回滚**；
 *    通过 [AuditWriteResult.Failure] 向调用方（进而向用户）报告失败原因与受影响编号。
 *
 * 该门面不做内容脱敏——脱敏由上层（任务 5.4，R10.9/R10.10）在构造 [content] 前完成。
 */
class AuditReportWriter(
    /** Audit_Report 根目录，全部写入路径必须落在其内。 */
    private val reportRoot: Path,
    /** 最多尝试次数（首次 + 重试），默认 3。 */
    private val maxAttempts: Int = DEFAULT_MAX_ATTEMPTS,
    /** 原子替换执行器，便于测试注入失败。默认使用文件系统原子移动。 */
    private val atomicReplace: (source: Path, target: Path) -> Unit = ::defaultAtomicReplace,
) {
    init {
        require(maxAttempts >= 1) { "maxAttempts must be >= 1, was $maxAttempts" }
    }

    /**
     * 原子写入 [relativePath] 指定的报告文件。
     *
     * @param relativePath 相对 [reportRoot] 的目标路径（如 `gaps/gap-items.md`）。
     * @param content 完整文件内容（UTF-8）。
     * @param affectedIds 本次写入涉及的编号（Gap_Item / 冲突编号等），失败时回报给用户。
     * @return [AuditWriteResult.Success] 或含失败原因与受影响编号的 [AuditWriteResult.Failure]。
     */
    fun write(
        relativePath: String,
        content: String,
        affectedIds: List<String> = emptyList(),
    ): AuditWriteResult {
        val target = resolveWithinRoot(relativePath)
            ?: return AuditWriteResult.Failure(
                relativePath = relativePath,
                reason = "目标路径越出 Audit_Report 根目录：$relativePath",
                affectedIds = affectedIds,
                attempts = 0,
            )

        var lastError: String? = null
        for (attempt in 1..maxAttempts) {
            try {
                Files.createDirectories(target.parent)
                val tempFile = Files.createTempFile(
                    target.parent,
                    ".${target.fileName}.",
                    ".tmp",
                )
                try {
                    Files.write(tempFile, content.toByteArray(Charsets.UTF_8))
                    atomicReplace(tempFile, target)
                    return AuditWriteResult.Success(
                        relativePath = relativePath,
                        attempts = attempt,
                    )
                } catch (t: Throwable) {
                    // 临时文件在替换失败时清理，避免残留（不影响已成功写入的目标文件）。
                    runCatching { Files.deleteIfExists(tempFile) }
                    throw t
                }
            } catch (e: IOException) {
                lastError = e.message ?: e.javaClass.simpleName
            } catch (e: SecurityException) {
                lastError = e.message ?: e.javaClass.simpleName
            }
        }

        return AuditWriteResult.Failure(
            relativePath = relativePath,
            reason = "写入在 $maxAttempts 次尝试后仍失败：${lastError ?: "未知原因"}",
            affectedIds = affectedIds,
            attempts = maxAttempts,
        )
    }

    /**
     * 将 [relativePath] 规范化后校验其落在 [reportRoot] 之内；越界返回 null。
     * 防止 `../` 等路径穿越写到 Audit_Report 之外（与 BoundaryGuard 一致的最小防护）。
     */
    private fun resolveWithinRoot(relativePath: String): Path? {
        val normalizedRoot = reportRoot.toAbsolutePath().normalize()
        val candidate = normalizedRoot.resolve(relativePath).normalize()
        return if (candidate.startsWith(normalizedRoot)) candidate else null
    }

    companion object {
        const val DEFAULT_MAX_ATTEMPTS: Int = 3

        private fun defaultAtomicReplace(source: Path, target: Path) {
            try {
                Files.move(
                    source,
                    target,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                // 某些文件系统不支持原子移动时退化为 REPLACE_EXISTING，仍优于半写状态。
                Files.move(source, target, StandardCopyOption.REPLACE_EXISTING)
            }
        }
    }
}

/** 写入结果。成功携带尝试次数；失败携带原因与受影响编号（R1.13 / R2.5 / R11.8）。 */
sealed interface AuditWriteResult {
    val relativePath: String
    val attempts: Int

    data class Success(
        override val relativePath: String,
        override val attempts: Int,
    ) : AuditWriteResult

    data class Failure(
        override val relativePath: String,
        val reason: String,
        val affectedIds: List<String>,
        override val attempts: Int,
    ) : AuditWriteResult
}
