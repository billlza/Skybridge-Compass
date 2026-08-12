package com.skybridge.compass.shared.audit

import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * Evidence_Record 结构与采集/标注规则（任务 5.3，_Requirements: 10.3、10.4、10.5、10.6_）。
 *
 * 这是**审计工具代码**，位于 `shared` 模块的 test 源集，不随生产应用打包
 * （与 [AuditReportWriter] 同一 audit 工具包，见 design §"Audit_Report 产物布局"）。
 *
 * 一条 [EvidenceRecord] 记录一次互操作验证。其字段结构取自 design
 * §"Data Models — Evidence_Record（R10.3/R10.4）"，含十项核心字段：
 *
 *  1. [id]              报告内唯一且不复用编号
 *  2. [gapItemIds]      关联的 Gap_Item 编号
 *  3. [completedAtUtc]  验证完成时刻（UTC，精度到秒）
 *  4. [initiator]       发起端（平台 + OS/API 级别）
 *  5. [responder]       响应端（平台 + OS/API 级别）
 *  6. [transport]       传输方式
 *  7. [negotiatedSuite] 协商出的密码套件
 *  8. [turnRelayed]     是否经由 TURN 中继
 *  9. [deviceClass]     设备类别（真机 / 模拟器）
 * 10. [flags]           证据标注（EMULATOR / CONNECTIVITY_ONLY / INCOMPLETE 的子集）
 *
 * 采集与标注规则（在 [create] 工厂与 [validate] 中强制）：
 *  - **R10.4 不完整证据**：任一字段无法采集时以 [Collected.NotCollected] 记为「未采集」+ 原因，
 *    禁止留空、禁止填推测值；含任一「未采集」字段的记录必带 [EvidenceFlag.INCOMPLETE]。
 *  - **R10.5 模拟器证据**：设备类别为模拟器时必带 [EvidenceFlag.EMULATOR]，并通过
 *    [emulatorCoverage] 记录未覆盖的真机行为，至少给出「本地网络发现」与「硬件编解码」两项
 *    是否被覆盖的结论。
 *  - **R10.6 连通性证据**：使用本地兼容信令服务的证据必带 [EvidenceFlag.CONNECTIVITY_ONLY]，
 *    并通过 [connectivityOnly] 记录其不可用于判定生产信令认证、鉴权与证书校验。
 */
data class EvidenceRecord(
    // —— 十项核心字段（R10.3）——
    val id: String,
    val gapItemIds: List<String>,
    val completedAtUtc: Collected<Instant>,
    val initiator: EndpointDescriptor,
    val responder: EndpointDescriptor,
    val transport: Collected<TransportKind>,
    val negotiatedSuite: Collected<String>,
    val turnRelayed: Collected<Boolean>,
    val deviceClass: DeviceClass,
    val flags: Set<EvidenceFlag>,
    // —— 标注支撑字段（R10.5 / R10.6）——
    /** 模拟器证据时必填：未覆盖真机行为的结论（R10.5）。 */
    val emulatorCoverage: EmulatorCoverage? = null,
    /** 连通性证据时必填：本地兼容信令服务的适用范围说明（R10.6）。 */
    val connectivityOnly: ConnectivityOnlyNote? = null,
) {
    /** 全部可能「未采集」的采集态字段，供不完整判定统一遍历（含端点内的 OS/API 字段）。 */
    private fun collectedFields(): List<Collected<*>> = listOf(
        completedAtUtc,
        transport,
        negotiatedSuite,
        turnRelayed,
        initiator.osVersion,
        initiator.apiLevel,
        responder.osVersion,
        responder.apiLevel,
    )

    /** 是否存在任一「未采集」字段（R10.4）。 */
    fun hasUncollectedField(): Boolean = collectedFields().any { it is Collected.NotCollected }

    /**
     * 校验采集/标注规则是否被满足。返回 [EvidenceValidation.Valid] 或含逐条违规说明的
     * [EvidenceValidation.Invalid]。[create] 工厂产出的记录恒通过校验。
     */
    fun validate(): EvidenceValidation {
        val violations = mutableListOf<String>()

        if (id.isBlank()) violations += "id 不得为空"

        // R10.4：任一「未采集」字段 ⇒ 必带 INCOMPLETE。
        if (hasUncollectedField() && EvidenceFlag.INCOMPLETE !in flags) {
            violations += "存在「未采集」字段但缺少 INCOMPLETE 标注（R10.4）"
        }
        // 反向：标了 INCOMPLETE 但无任何未采集字段属于错误标注。
        if (EvidenceFlag.INCOMPLETE in flags && !hasUncollectedField()) {
            violations += "标注 INCOMPLETE 但不存在任何「未采集」字段（R10.4）"
        }

        // R10.5：模拟器证据 ⇒ 必带 EMULATOR 且必须记录两项真机覆盖结论。
        if (deviceClass == DeviceClass.EMULATOR) {
            if (EvidenceFlag.EMULATOR !in flags) {
                violations += "设备类别为模拟器但缺少 EMULATOR 标注（R10.5）"
            }
            if (emulatorCoverage == null) {
                violations += "模拟器证据必须记录未覆盖真机行为结论（R10.5）"
            }
        }
        // EMULATOR 标注必须与真机覆盖结论并存。
        if (EvidenceFlag.EMULATOR in flags && emulatorCoverage == null) {
            violations += "标注 EMULATOR 但缺少 emulatorCoverage（R10.5）"
        }

        // R10.6：连通性证据 ⇒ 必带 CONNECTIVITY_ONLY 且必须记录适用范围说明。
        if (connectivityOnly != null && EvidenceFlag.CONNECTIVITY_ONLY !in flags) {
            violations += "存在连通性证据说明但缺少 CONNECTIVITY_ONLY 标注（R10.6）"
        }
        if (EvidenceFlag.CONNECTIVITY_ONLY in flags && connectivityOnly == null) {
            violations += "标注 CONNECTIVITY_ONLY 但缺少 connectivityOnly 说明（R10.6）"
        }

        return if (violations.isEmpty()) EvidenceValidation.Valid
        else EvidenceValidation.Invalid(violations)
    }

    companion object {
        /**
         * 构造一条 [EvidenceRecord] 并**自动派生**标注（flags），确保采集/标注规则一致：
         *  - 任一采集态字段为「未采集」⇒ 追加 [EvidenceFlag.INCOMPLETE]（R10.4）。
         *  - [deviceClass] 为模拟器 ⇒ 追加 [EvidenceFlag.EMULATOR]（R10.5）。
         *  - 传入 [connectivityOnly] ⇒ 追加 [EvidenceFlag.CONNECTIVITY_ONLY]（R10.6）。
         *
         * [completedAtUtc] 若为具体值则截断到秒（R10.3「精度到秒」）。
         *
         * 若 [deviceClass] 为模拟器却未提供 [emulatorCoverage]，直接抛出，避免产出违规记录。
         */
        fun create(
            id: String,
            gapItemIds: List<String>,
            completedAtUtc: Collected<Instant>,
            initiator: EndpointDescriptor,
            responder: EndpointDescriptor,
            transport: Collected<TransportKind>,
            negotiatedSuite: Collected<String>,
            turnRelayed: Collected<Boolean>,
            deviceClass: DeviceClass,
            emulatorCoverage: EmulatorCoverage? = null,
            connectivityOnly: ConnectivityOnlyNote? = null,
        ): EvidenceRecord {
            require(id.isNotBlank()) { "id 不得为空" }
            require(deviceClass != DeviceClass.EMULATOR || emulatorCoverage != null) {
                "模拟器证据必须提供 emulatorCoverage（R10.5）"
            }

            val secondPrecision = when (completedAtUtc) {
                is Collected.Value -> Collected.Value(completedAtUtc.value.truncatedTo(ChronoUnit.SECONDS))
                is Collected.NotCollected -> completedAtUtc
            }

            val derivedFlags = buildSet {
                val record = EvidenceRecord(
                    id = id,
                    gapItemIds = gapItemIds,
                    completedAtUtc = secondPrecision,
                    initiator = initiator,
                    responder = responder,
                    transport = transport,
                    negotiatedSuite = negotiatedSuite,
                    turnRelayed = turnRelayed,
                    deviceClass = deviceClass,
                    flags = emptySet(),
                    emulatorCoverage = emulatorCoverage,
                    connectivityOnly = connectivityOnly,
                )
                if (record.hasUncollectedField()) add(EvidenceFlag.INCOMPLETE)
                if (deviceClass == DeviceClass.EMULATOR) add(EvidenceFlag.EMULATOR)
                if (connectivityOnly != null) add(EvidenceFlag.CONNECTIVITY_ONLY)
            }

            return EvidenceRecord(
                id = id,
                gapItemIds = gapItemIds,
                completedAtUtc = secondPrecision,
                initiator = initiator,
                responder = responder,
                transport = transport,
                negotiatedSuite = negotiatedSuite,
                turnRelayed = turnRelayed,
                deviceClass = deviceClass,
                flags = derivedFlags,
                emulatorCoverage = emulatorCoverage,
                connectivityOnly = connectivityOnly,
            )
        }
    }
}

/**
 * 采集态字段（R10.4）：要么是采集到的 [Value]，要么是记有原因的 [NotCollected]（「未采集」）。
 * 用类型系统禁止「留空」——无采集值时必须给出非空原因，也无法填入推测值而不被标注为未采集。
 */
sealed interface Collected<out T> {
    data class Value<T>(val value: T) : Collected<T>

    data class NotCollected(val reason: String) : Collected<Nothing> {
        init {
            require(reason.isNotBlank()) { "「未采集」必须附无法采集的原因，不得留空（R10.4）" }
        }
    }
}

/** 端点描述：平台 + OS 版本 + API 级别。OS/API 允许「未采集」。 */
data class EndpointDescriptor(
    val platform: String,
    val osVersion: Collected<String>,
    val apiLevel: Collected<Int>,
) {
    init {
        require(platform.isNotBlank()) { "platform 不得为空" }
    }
}

/** 设备类别（R10.3 / R10.5）。 */
enum class DeviceClass { REAL_DEVICE, EMULATOR }

/** 传输方式（design §"Data Models"）。 */
enum class TransportKind { LAN_TCP, WEBRTC_P2P, WEBRTC_TURN }

/** 证据标注（R10.4 / R10.5 / R10.6）。 */
enum class EvidenceFlag { EMULATOR, CONNECTIVITY_ONLY, INCOMPLETE }

/**
 * 模拟器证据的真机覆盖结论（R10.5）。至少给出「本地网络发现」与「硬件编解码」两项
 * 是否被覆盖的结论。
 */
data class EmulatorCoverage(
    val localNetworkDiscoveryCovered: Boolean,
    val hardwareCodecCovered: Boolean,
    /** 未覆盖真机行为的补充说明。 */
    val uncoveredBehaviorNotes: String,
) {
    init {
        require(uncoveredBehaviorNotes.isNotBlank()) {
            "模拟器证据须说明未覆盖的真机行为（R10.5）"
        }
    }
}

/**
 * 连通性证据说明（R10.6）：使用本地兼容信令服务时的适用范围限制。
 * 该证据不可用于判定生产信令认证、鉴权与证书校验行为。
 */
data class ConnectivityOnlyNote(
    val usedLocalCompatSignaling: Boolean = true,
    val note: String = "本证据仅证明连通性，不可用于判定生产信令认证、鉴权与证书校验行为。",
) {
    init {
        require(note.isNotBlank()) { "连通性证据说明不得为空（R10.6）" }
    }
}

/** [EvidenceRecord.validate] 的结果。 */
sealed interface EvidenceValidation {
    object Valid : EvidenceValidation
    data class Invalid(val violations: List<String>) : EvidenceValidation
}
