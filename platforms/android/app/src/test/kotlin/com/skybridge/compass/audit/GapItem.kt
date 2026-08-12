package com.skybridge.compass.audit

/**
 * Gap_Item 数据模型与置信度标注（Cross-Platform Parity Audit，任务 4.4 / R2.2、R2.3）。
 *
 * 该文件是**审计工具代码**，位于 `:app` 模块的 `test` 源集（与 [BoundaryGuard]、
 * [ParityAuditScheduler] 同包），不随生产应用打包（遵守 G3：仅 Kotlin；不改动 Apple 源码树）。
 *
 * 一条 [GapItem] 记录 R2.2 要求的五项内容：
 *  1. 在 Audit_Report 内**唯一且不复用**的编号 [id]（由 [GapItemMerger] 归并时统一分配，
 *     见该类的 [GapIdAllocator]）。
 *  2. 取自"缺失 / 半接线 / 假接线 / 缺陷"四值集合之一的 [category]。
 *  3. 至少一条以仓库根为起点的 `文件:行` 证据 [evidence]（可为空——此时按 R2.3 只能标注为
 *     [Confidence.UNVERIFIED_SPECULATION]）。
 *  4. 受影响的 [subsystem] 与 [userVisibleImpact]（用户可见行为）。
 *  5. 一条可由他人独立执行并得出通过/不通过结果的 [verdictCondition]。
 *
 * 置信度（R2.3）：[confidence] **不由构造方自由指定**，而是由 [GapItemMerger] 依据
 * "证据中是否存在至少一条在当前工作副本可定位的 `文件:行`"派生（见 [SourceLocator]）。
 * 满足者标 [Confidence.VERIFIED_BY_REPO_EVIDENCE]；否则一律 [Confidence.UNVERIFIED_SPECULATION]，
 * 且**不进入修复决策**（见 [GapMergeResult.fixEligible]）。
 */
data class GapItem(
    /** Audit_Report 内唯一且不复用的编号（由归并分配，形如 `GAP-0001`）。 */
    val id: String,
    /** 类别：缺失 / 半接线 / 假接线 / 缺陷。 */
    val category: GapCategory,
    /** 至少一条 `文件:行` 证据；允许为空，但空则只能标注为未核实推测（R2.3）。 */
    val evidence: List<SourceRef>,
    /** 受影响的子系统（如 Discovery_Subsystem / Settings_Subsystem）。 */
    val subsystem: String,
    /** 用户可见行为（缺口对用户造成的可观察影响）。 */
    val userVisibleImpact: String,
    /** 可由他人独立执行并得出通过/不通过结果的判定条件。 */
    val verdictCondition: String,
    /** 置信度标注（由归并派生，不由构造方指定语义）。 */
    val confidence: Confidence,
    /** 产出该条目的审计范围标识（S1..S4），用于溯源。 */
    val scopeId: String,
    /** 文档基线小节引用，或"无对应基线条目"；本任务不强制，缺省 null。 */
    val baselineRef: String? = null,
) {
    init {
        require(id.isNotBlank()) { "gap id must not be blank" }
        require(subsystem.isNotBlank()) { "gap $id: subsystem must not be blank" }
        require(userVisibleImpact.isNotBlank()) { "gap $id: userVisibleImpact must not be blank" }
        require(verdictCondition.isNotBlank()) { "gap $id: verdictCondition must not be blank" }
        require(scopeId.isNotBlank()) { "gap $id: scopeId must not be blank" }
        // R2.3 不变式：证据为空时必须是"未核实推测"。
        if (evidence.isEmpty()) {
            require(confidence == Confidence.UNVERIFIED_SPECULATION) {
                "gap $id has no file:line evidence and therefore must be UNVERIFIED_SPECULATION (R2.3)"
            }
        }
    }

    /** R2.3：仅"已用仓库证据核实"的条目可进入修复决策。 */
    val isFixEligible: Boolean get() = confidence == Confidence.VERIFIED_BY_REPO_EVIDENCE
}

/** Gap_Item 四值类别集合（R2.2）。 */
enum class GapCategory(val label: String) {
    /** 缺失：功能完全不存在。 */
    MISSING("缺失"),

    /** 半接线：实现存在且可编译，但从 UI 或启动路径不可达。 */
    HALF_WIRING("半接线"),

    /** 假接线：有用户可见控件或公开 API，但其值/调用不影响任何运行时行为。 */
    FAKE_WIRING("假接线"),

    /** 缺陷：行为存在但与基线不一致。 */
    DEFECT("缺陷"),
}

/** 置信度标注（R2.3）。 */
enum class Confidence(val label: String) {
    /** 已用仓库证据核实：附至少一条在当前工作副本可定位的 `文件:行`。 */
    VERIFIED_BY_REPO_EVIDENCE("已用仓库证据核实"),

    /** 未核实推测：无可定位的 `文件:行` 证据；不进入修复决策。 */
    UNVERIFIED_SPECULATION("未核实推测"),
}

/**
 * 以仓库根为起点的 `文件:行` 证据引用（R2.2）。
 *
 * [file] 为仓库相对路径，[line] 为 1 起的行号。[toString] 输出规范的 `文件:行` 文本，
 * [parse] 从该文本还原。
 */
data class SourceRef(
    val file: String,
    val line: Int,
) {
    init {
        require(file.isNotBlank()) { "source ref file must not be blank" }
        require(line >= 1) { "source ref line must be >= 1, was $line" }
    }

    /** 规范的 `文件:行` 文本，如 `device-discovery/src/main/kotlin/Nsd.kt:95`。 */
    override fun toString(): String = "$file:$line"

    companion object {
        /**
         * 从 `文件:行` 文本解析（行号取最后一个冒号后的整数，以兼容 Windows 盘符等含冒号路径）。
         * 解析失败返回 null。
         */
        fun parse(raw: String): SourceRef? {
            val trimmed = raw.trim()
            val idx = trimmed.lastIndexOf(':')
            if (idx <= 0 || idx == trimmed.length - 1) return null
            val file = trimmed.substring(0, idx)
            val line = trimmed.substring(idx + 1).toIntOrNull() ?: return null
            if (file.isBlank() || line < 1) return null
            return SourceRef(file, line)
        }
    }
}

/**
 * 判定一条 `文件:行` 证据是否在当前仓库工作副本中可定位（R2.3 的置信度前提）。
 *
 * 抽象为函数接口，便于单测注入确定性的可定位集合，也可在真实运行中以文件系统探测实现
 * （文件存在且行号不超过文件行数）。
 */
fun interface SourceLocator {
    /** [ref] 是否可在当前工作副本中定位到。 */
    fun isLocatable(ref: SourceRef): Boolean
}
