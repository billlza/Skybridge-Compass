package com.skybridge.compass.shared.audit

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AuditReportWriterTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private fun root(): Path = tempFolder.root.toPath()

    @Test
    fun writesContentOnFirstAttempt() {
        val writer = AuditReportWriter(root())

        val result = writer.write("audit-report.md", "hello", listOf("G-001"))

        assertTrue(result is AuditWriteResult.Success)
        result as AuditWriteResult.Success
        assertEquals(1, result.attempts)
        assertEquals("hello", Files.readString(root().resolve("audit-report.md")))
    }

    @Test
    fun createsNestedDirectories() {
        val writer = AuditReportWriter(root())

        val result = writer.write("gaps/gap-items.md", "table")

        assertTrue(result is AuditWriteResult.Success)
        assertTrue(Files.exists(root().resolve("gaps/gap-items.md")))
        assertEquals("table", Files.readString(root().resolve("gaps/gap-items.md")))
    }

    @Test
    fun overwritesExistingFileAtomically() {
        val writer = AuditReportWriter(root())
        writer.write("evidence/evidence-records.md", "v1")

        val result = writer.write("evidence/evidence-records.md", "v2")

        assertTrue(result is AuditWriteResult.Success)
        assertEquals("v2", Files.readString(root().resolve("evidence/evidence-records.md")))
        // 无临时文件残留
        val leftovers = Files.list(root().resolve("evidence")).use { stream ->
            stream.filter { it.fileName.toString().endsWith(".tmp") }.count()
        }
        assertEquals(0L, leftovers)
    }

    @Test
    fun retriesUpToThreeTimesThenReportsFailure() {
        var calls = 0
        val alwaysFailingReplace: (Path, Path) -> Unit = { _, _ ->
            calls++
            throw IOException("replace boom")
        }
        val writer = AuditReportWriter(root(), atomicReplace = alwaysFailingReplace)

        val result = writer.write("audit-report.md", "content", listOf("C-001", "C-002"))

        assertTrue(result is AuditWriteResult.Failure)
        result as AuditWriteResult.Failure
        assertEquals(3, result.attempts)
        assertEquals(3, calls)
        assertEquals(listOf("C-001", "C-002"), result.affectedIds)
        assertTrue(result.reason.contains("replace boom"))
        // 未成功写入的目标文件不存在
        assertFalse(Files.exists(root().resolve("audit-report.md")))
    }

    @Test
    fun succeedsOnLastAllowedAttempt() {
        var calls = 0
        val flakyReplace: (Path, Path) -> Unit = { source, target ->
            calls++
            if (calls < 3) throw IOException("transient")
            Files.move(source, target, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        }
        val writer = AuditReportWriter(root(), atomicReplace = flakyReplace)

        val result = writer.write("audit-report.md", "eventually")

        assertTrue(result is AuditWriteResult.Success)
        result as AuditWriteResult.Success
        assertEquals(3, result.attempts)
        assertEquals("eventually", Files.readString(root().resolve("audit-report.md")))
    }

    @Test
    fun leavesNoTempFilesAfterRepeatedFailure() {
        val writer = AuditReportWriter(root(), atomicReplace = { _, _ -> throw IOException("nope") })

        writer.write("gaps/fake-wiring.md", "x")

        val gapsDir = root().resolve("gaps")
        val tmpCount = Files.list(gapsDir).use { stream ->
            stream.filter { it.fileName.toString().endsWith(".tmp") }.count()
        }
        assertEquals(0L, tmpCount)
    }

    @Test
    fun rejectsPathTraversalOutsideRoot() {
        val writer = AuditReportWriter(root())

        val result = writer.write("../escape.md", "leak", listOf("G-009"))

        assertTrue(result is AuditWriteResult.Failure)
        result as AuditWriteResult.Failure
        assertEquals(0, result.attempts)
        assertEquals(listOf("G-009"), result.affectedIds)
        assertFalse(Files.exists(root().resolveSibling("escape.md")))
    }

    @Test
    fun previouslyWrittenFilesAreNotRolledBackOnLaterFailure() {
        // 先成功写入一个文件
        val okWriter = AuditReportWriter(root())
        okWriter.write("audit-report.md", "kept")

        // 另一个 writer 对不同文件写入失败三次
        val failingWriter = AuditReportWriter(root(), atomicReplace = { _, _ -> throw IOException("fail") })
        val result = failingWriter.write("gaps/gap-items.md", "lost")

        assertTrue(result is AuditWriteResult.Failure)
        // 已成功写入内容不回滚
        assertEquals("kept", Files.readString(root().resolve("audit-report.md")))
    }

    @Test
    fun rejectsInvalidMaxAttempts() {
        var threw = false
        try {
            AuditReportWriter(root(), maxAttempts = 0)
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        assertTrue(threw)
    }
}
