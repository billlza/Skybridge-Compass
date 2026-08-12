package com.skybridge.compass.shared.audit

import java.security.MessageDigest

/**
 * 脱敏映射与写入门控（任务 5.4，_Requirements: 10.9、10.10_）。
 *
 * 这是**审计工具代码**，位于 `shared` 模块的 test 源集，不随生产应用打包
 * （与 [AuditReportWriter] 同址，故可在写入前对内容做门控）。
 *
 * 覆盖两条验收标准：
 *  - R10.9：Audit_Report 不输出连接码 / 设备标识 / 协议指纹明文；需指代时使用
 *    **不可由报告内容反推出原值**的**稳定占位标记**；同一原值映射到同一标记、
 *    不同原值不共用标记（即映射为**单射**）。
 *  - R10.10：写入前检测到明文即**阻止该次写入**、以占位标记**替换后再写**，
 *    并记录发生替换的**条目编号**与**被替换字段名**。
 */

/** 敏感值类别。每类有独立的标记前缀，保证跨类别不会共用标记。 */
enum class SensitiveKind(val markerPrefix: String) {
    /** 连接码。 */
    CONNECTION_CODE("CC"),

    /** 设备标识。 */
    DEVICE_IDENTIFIER("DEV"),

    /** 协议指纹。 */
    PROTOCOL_FINGERPRINT("FP"),
}

/** 一个待扫描的敏感值：其明文、类别与所属字段名（用于替换记录）。 */
data class SensitiveValue(
    val value: String,
    val kind: SensitiveKind,
    val fieldName: String,
)

/** 一条脱敏替换记录：发生替换的条目编号、被替换字段名、替换后的占位标记（R10.10）。 */
data class RedactionRecord(
    val entryId: String,
    val fieldName: String,
    val marker: String,
)

/**
 * 单射稳定的占位标记映射（R10.9）。
 *
 * - **稳定**：同一原值在同一映射实例内始终返回同一标记（结果被缓存）。
 * - **单射**：不同原值不共用标记——标记以 SHA-256 摘要为基础，跨类别用前缀区分；
 *   同类别内若出现摘要前缀碰撞（密码学上可忽略），确定性地延长摘要直至唯一。
 * - **不可反推**：标记只含单向哈希摘要，不含原值任何子串；仅凭标记与报告内容
 *   无法还原原值。
 */
class RedactionMap(
    /** 标记中摘要的初始十六进制字符数（96 bit 起，碰撞概率可忽略）。 */
    private val digestChars: Int = DEFAULT_DIGEST_CHARS,
) {
    init {
        require(digestChars in 8..FULL_SHA256_HEX_CHARS) {
            "digestChars 须在 [8, $FULL_SHA256_HEX_CHARS] 内，实际 $digestChars"
        }
    }

    private data class Key(val kind: SensitiveKind, val value: String)

    private val markerByValue = LinkedHashMap<Key, String>()
    private val valueByMarker = HashMap<String, String>()

    /** 返回 [value]（属于 [kind]）的稳定占位标记；同值同标记、异值不共用。 */
    fun markerFor(value: String, kind: SensitiveKind): String {
        val key = Key(kind, value)
        markerByValue[key]?.let { return it }

        val fullDigest = sha256Hex("${kind.name}\u0000$value")
        var length = digestChars
        var salt = 0
        while (true) {
            val digest = digestFor(fullDigest, length, salt, kind, value)
            val marker = "\u27E6REDACTED:${kind.markerPrefix}:$digest\u27E7"
            val existing = valueByMarker[marker]
            if (existing == null || existing == value) {
                markerByValue[key] = marker
                valueByMarker[marker] = value
                return marker
            }
            // 与不同原值发生标记碰撞：确定性地延长摘要；超出全长则加盐重哈希。
            if (length < FULL_SHA256_HEX_CHARS) {
                length = minOf(length + 8, FULL_SHA256_HEX_CHARS)
            } else {
                salt += 1
            }
        }
    }

    private fun digestFor(
        fullDigest: String,
        length: Int,
        salt: Int,
        kind: SensitiveKind,
        value: String,
    ): String = if (salt == 0) {
        fullDigest.take(length)
    } else {
        sha256Hex("$salt\u0000${kind.name}\u0000$value").take(length)
    }

    companion object {
        const val DEFAULT_DIGEST_CHARS: Int = 24
        const val FULL_SHA256_HEX_CHARS: Int = 64

        private val HEX = "0123456789abcdef".toCharArray()

        internal fun sha256Hex(input: String): String {
            val bytes = MessageDigest.getInstance("SHA-256")
                .digest(input.toByteArray(Charsets.UTF_8))
            val out = CharArray(bytes.size * 2)
            for (i in bytes.indices) {
                val b = bytes[i].toInt() and 0xFF
                out[i * 2] = HEX[b ushr 4]
                out[i * 2 + 1] = HEX[b and 0x0F]
            }
            return String(out)
        }
    }
}

/** [RedactingAuditReportWriter.write] 的结果：底层写入结果 + 脱敏详情。 */
data class RedactedWriteResult(
    /** 底层 [AuditReportWriter] 的写入结果（针对已脱敏内容）。 */
    val writeResult: AuditWriteResult,
    /** 实际写入磁盘的（已脱敏）内容。 */
    val writtenContent: String,
    /** 本次写入发生的替换记录；为空表示未检测到明文。 */
    val replacements: List<RedactionRecord>,
    /** 是否检测到明文并因此阻止了原文写入。 */
    val redacted: Boolean,
)

/**
 * 写入门控（R10.10）：在委托 [AuditReportWriter] 之前扫描待写入内容中的敏感值明文，
 * 命中即阻止原文写入、以 [RedactionMap] 的占位标记替换后再写，并登记替换记录。
 *
 * 与 [AuditReportWriter] 组合而非继承——门面本身仍只负责原子写入，脱敏在其之前完成。
 */
class RedactingAuditReportWriter(
    private val writer: AuditReportWriter,
    /** 占位映射；默认新建一个（同一 Audit_Report 复用同一实例以保证同值同标记）。 */
    private val redactionMap: RedactionMap = RedactionMap(),
) {
    private val replacementLog = mutableListOf<RedactionRecord>()

    /** 迄今为止累计的脱敏替换记录（R10.10 的登记内容）。 */
    fun redactionLog(): List<RedactionRecord> = replacementLog.toList()

    /**
     * 脱敏并写入 [relativePath]。
     *
     * @param relativePath 相对报告根目录的目标路径。
     * @param entryId 本次写入对应的条目编号（如 Gap_Item 编号），发生替换时登记。
     * @param content 待写入内容（可能含敏感值明文）。
     * @param sensitiveValues 已知敏感值集合（连接码 / 设备标识 / 协议指纹及其字段名）。
     */
    fun write(
        relativePath: String,
        entryId: String,
        content: String,
        sensitiveValues: List<SensitiveValue>,
    ): RedactedWriteResult {
        var sanitized = content
        val replaced = mutableListOf<RedactionRecord>()

        // 先替换较长的明文，避免较短明文是较长明文子串时产生错位替换。
        val candidates = sensitiveValues
            .filter { it.value.isNotEmpty() }
            .sortedByDescending { it.value.length }

        for (sv in candidates) {
            if (sanitized.contains(sv.value)) {
                val marker = redactionMap.markerFor(sv.value, sv.kind)
                sanitized = sanitized.replace(sv.value, marker)
                replaced += RedactionRecord(entryId, sv.fieldName, marker)
            }
        }

        val result = writer.write(relativePath, sanitized, listOf(entryId))
        if (replaced.isNotEmpty()) {
            replacementLog += replaced
        }
        return RedactedWriteResult(
            writeResult = result,
            writtenContent = sanitized,
            replacements = replaced,
            redacted = replaced.isNotEmpty(),
        )
    }

    /** 把脱敏替换记录渲染为 audit-report.md §5 的表格行（条目编号 | 被替换字段名 | 占位标记）。 */
    fun redactionLogMarkdown(): String {
        if (replacementLog.isEmpty()) return "| _（暂无）_ | | |"
        return replacementLog.joinToString("\n") { r ->
            "| ${r.entryId} | ${r.fieldName} | ${r.marker} |"
        }
    }
}
