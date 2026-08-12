package com.skybridge.compass.filetransfer.webrtc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Unit tests for [DownloadsFilenameDeduper].
 *
 * Covers R5.11: an accepted inbound file must not silently overwrite an existing Downloads entry;
 * on collision a distinguishing incrementing suffix is appended while preserving the extension.
 */
class DownloadsFilenameDeduperTest {

    @Test
    fun `returns original name when it is free`() {
        val result = DownloadsFilenameDeduper.deduplicate(
            desiredName = "report.pdf",
            nameExists = { false }
        )
        assertEquals("report.pdf", result)
    }

    @Test
    fun `appends (1) suffix on single collision preserving extension`() {
        val taken = setOf("report.pdf")
        val result = DownloadsFilenameDeduper.deduplicate(
            desiredName = "report.pdf",
            nameExists = { it in taken }
        )
        assertEquals("report (1).pdf", result)
    }

    @Test
    fun `increments suffix across multiple consecutive collisions`() {
        val taken = setOf("report.pdf", "report (1).pdf", "report (2).pdf")
        val result = DownloadsFilenameDeduper.deduplicate(
            desiredName = "report.pdf",
            nameExists = { it in taken }
        )
        assertEquals("report (3).pdf", result)
    }

    @Test
    fun `handles names without an extension`() {
        val taken = setOf("README", "README (1)")
        val result = DownloadsFilenameDeduper.deduplicate(
            desiredName = "README",
            nameExists = { it in taken }
        )
        assertEquals("README (2)", result)
    }

    @Test
    fun `preserves multi-dot base name and only splits final extension`() {
        val taken = setOf("archive.tar.gz")
        val result = DownloadsFilenameDeduper.deduplicate(
            desiredName = "archive.tar.gz",
            nameExists = { it in taken }
        )
        assertEquals("archive.tar (1).gz", result)
    }

    @Test
    fun `treats dotfile as having no extension`() {
        // Leading dot -> dot index is 0 -> not a valid extension split.
        val taken = setOf(".gitignore")
        val result = DownloadsFilenameDeduper.deduplicate(
            desiredName = ".gitignore",
            nameExists = { it in taken }
        )
        assertEquals(".gitignore (1)", result)
    }

    @Test
    fun `treats trailing dot as having no extension`() {
        val taken = setOf("weird.")
        val result = DownloadsFilenameDeduper.deduplicate(
            desiredName = "weird.",
            nameExists = { it in taken }
        )
        assertEquals("weird. (1)", result)
    }

    @Test
    fun `does not overwrite - result is always a free name`() {
        val taken = setOf("data.bin", "data (1).bin", "data (2).bin", "data (3).bin")
        val result = DownloadsFilenameDeduper.deduplicate(
            desiredName = "data.bin",
            nameExists = { it in taken }
        )
        assertEquals("data (4).bin", result)
        assertTrue(result !in taken, "deduped name must not collide with an existing entry")
    }

    @Test
    fun `falls back to timestamp name when all numbered candidates collide`() {
        val result = DownloadsFilenameDeduper.deduplicate(
            desiredName = "report.pdf",
            // Every name is taken except the timestamped fallback.
            nameExists = { it != "report-12345.pdf" },
            timestampProvider = { 12345L }
        )
        assertEquals("report-12345.pdf", result)
    }

    @Test
    fun `timestamp fallback omits extension for extensionless names`() {
        val result = DownloadsFilenameDeduper.deduplicate(
            desiredName = "backup",
            nameExists = { it != "backup-999" },
            timestampProvider = { 999L }
        )
        assertEquals("backup-999", result)
    }
}
