package com.skybridge.compass.shared.audit

import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * 任务 5.4 单元测试（_Requirements: 10.9、10.10_）。
 * 覆盖：单射稳定映射、明文检测阻止后替换、替换记录登记条目编号与字段名、标记不可反推原值。
 */
class AuditRedactorTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private fun root(): Path = tempFolder.root.toPath()

    private fun redactingWriter(map: RedactionMap = RedactionMap()): RedactingAuditReportWriter =
        RedactingAuditReportWriter(AuditReportWriter(root()), map)

    // R10.9：同值同标记（稳定）。
    @Test
    fun sameValueMapsToSameMarker() {
        val map = RedactionMap()

        val a = map.markerFor("ABC-123-XYZ", SensitiveKind.CONNECTION_CODE)
        val b = map.markerFor("ABC-123-XYZ", SensitiveKind.CONNECTION_CODE)

        assertEquals(a, b)
    }

    // R10.9：异值不共用标记（单射）。
    @Test
    fun differentValuesMapToDifferentMarkers() {
        val map = RedactionMap()

        val a = map.markerFor("device-aaaa", SensitiveKind.DEVICE_IDENTIFIER)
        val b = map.markerFor("device-bbbb", SensitiveKind.DEVICE_IDENTIFIER)

        assertNotEquals(a, b)
    }

    // R10.9：同一原值在不同类别下也不共用标记（前缀区分）。
    @Test
    fun sameValueDifferentKindsDoNotShareMarker() {
        val map = RedactionMap()
        val shared = "0011223344"

        val asCode = map.markerFor(shared, SensitiveKind.CONNECTION_CODE)
        val asDevice = map.markerFor(shared, SensitiveKind.DEVICE_IDENTIFIER)

        assertNotEquals(asCode, asDevice)
    }

    // R10.9：映射在较大集合上仍为单射（无标记碰撞）。
    @Test
    fun mappingIsInjectiveAcrossManyValues() {
        val map = RedactionMap()
        val markers = HashSet<String>()
        val count = 500
        for (i in 0 until count) {
            val marker = map.markerFor("fingerprint-$i", SensitiveKind.PROTOCOL_FINGERPRINT)
            markers.add(marker)
        }
        assertEquals(count, markers.size)
    }

    // R10.10：写入前检测到明文即阻止原文写入、以占位标记替换后再写。
    @Test
    fun plaintextIsDetectedBlockedAndReplacedBeforeWrite() {
        val writer = redactingWriter()
        val code = "SKY-CONNECT-7788"
        val content = "Gap G-042 复现：观察到连接码 $code 被明文记录。"

        val result = writer.write(
            relativePath = "gaps/gap-items.md",
            entryId = "G-042",
            content = content,
            sensitiveValues = listOf(
                SensitiveValue(code, SensitiveKind.CONNECTION_CODE, "connectionCode"),
            ),
        )

        assertTrue(result.redacted)
        assertTrue(result.writeResult is AuditWriteResult.Success)
        // 磁盘内容不含明文，含占位标记。
        val onDisk = Files.readString(root().resolve("gaps/gap-items.md"))
        assertFalse(onDisk.contains(code))
        assertTrue(onDisk.contains(result.replacements.single().marker))
    }

    // R10.10：无明文时不发生替换，原文照写。
    @Test
    fun cleanContentIsWrittenWithoutRedaction() {
        val writer = redactingWriter()
        val content = "Gap G-100：无敏感值，正常写入。"

        val result = writer.write(
            relativePath = "gaps/gap-items.md",
            entryId = "G-100",
            content = content,
            sensitiveValues = listOf(
                SensitiveValue("UNUSED-CODE", SensitiveKind.CONNECTION_CODE, "connectionCode"),
            ),
        )

        assertFalse(result.redacted)
        assertTrue(result.replacements.isEmpty())
        assertEquals(content, Files.readString(root().resolve("gaps/gap-items.md")))
    }

    // R10.10：替换记录登记条目编号与被替换字段名。
    @Test
    fun replacementLogRecordsEntryIdAndFieldName() {
        val writer = redactingWriter()
        val device = "AA:BB:CC:DD:EE:FF"
        val fingerprint = "sha256:deadbeefcafef00d"
        val content = "设备 $device 的协议指纹为 $fingerprint。"

        val result = writer.write(
            relativePath = "evidence/evidence-records.md",
            entryId = "E-007",
            content = content,
            sensitiveValues = listOf(
                SensitiveValue(device, SensitiveKind.DEVICE_IDENTIFIER, "deviceId"),
                SensitiveValue(fingerprint, SensitiveKind.PROTOCOL_FINGERPRINT, "protocolFingerprint"),
            ),
        )

        assertEquals(2, result.replacements.size)
        val byField = result.replacements.associateBy { it.fieldName }
        assertTrue(byField.containsKey("deviceId"))
        assertTrue(byField.containsKey("protocolFingerprint"))
        result.replacements.forEach { assertEquals("E-007", it.entryId) }

        // 累计日志与 markdown 渲染均含条目编号与字段名。
        val log = writer.redactionLog()
        assertEquals(2, log.size)
        val md = writer.redactionLogMarkdown()
        assertTrue(md.contains("E-007"))
        assertTrue(md.contains("deviceId"))
        assertTrue(md.contains("protocolFingerprint"))
    }

    // R10.9：标记不可由报告内容反推出原值——标记不含原值任何非平凡子串，
    // 且不同实例对同一原值产生相同标记（稳定），但标记本身仅为单向摘要。
    @Test
    fun markerIsNotReversibleToOriginal() {
        val map = RedactionMap()
        val secret = "ULTRA-SECRET-CODE-42"
        val marker = map.markerFor(secret, SensitiveKind.CONNECTION_CODE)

        // 标记不含原值。
        assertFalse(marker.contains(secret))
        // 标记不含原值的任何长度 >= 4 的连续子串（排除偶然出现的短片段）。
        val minSub = 4
        for (start in 0..(secret.length - minSub)) {
            for (end in (start + minSub)..secret.length) {
                val sub = secret.substring(start, end)
                assertFalse(
                    "标记不应包含原值子串 '$sub'",
                    marker.contains(sub),
                )
            }
        }
    }

    // R10.9：占位标记的稳定性由映射实例保证——多次调用得到同一标记，
    // 且用同一原值集合重放时映射一致（同值同标记）。
    @Test
    fun markerIsStableWithinMapInstance() {
        val map = RedactionMap()
        val values = listOf("v-one", "v-two", "v-three")
        val first = values.map { map.markerFor(it, SensitiveKind.DEVICE_IDENTIFIER) }
        val second = values.map { map.markerFor(it, SensitiveKind.DEVICE_IDENTIFIER) }
        assertEquals(first, second)
    }

    // R10.10：同一 RedactingAuditReportWriter 跨多次写入，累计替换日志且同值复用同一标记。
    @Test
    fun repeatedWritesShareStableMarkerAndAccumulateLog() {
        val writer = redactingWriter()
        val code = "REUSE-CODE-9"

        val r1 = writer.write(
            "gaps/gap-items.md", "G-1", "第一次出现 $code。",
            listOf(SensitiveValue(code, SensitiveKind.CONNECTION_CODE, "connectionCode")),
        )
        val r2 = writer.write(
            "gaps/half-wiring.md", "G-2", "第二次出现 $code。",
            listOf(SensitiveValue(code, SensitiveKind.CONNECTION_CODE, "connectionCode")),
        )

        assertEquals(r1.replacements.single().marker, r2.replacements.single().marker)
        assertEquals(2, writer.redactionLog().size)
    }
}
