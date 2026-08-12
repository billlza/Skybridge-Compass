package com.skybridge.compass.core.data

/**
 * 「先校验后写入」的纯函数校验面（design §7、R7.8）。
 *
 * 现状缺陷：`NetworkSettingsStore` 曾用 `coerceIn` 静默钳制用户输入，越界值被改写后仍以「已保存」
 * 呈现。R7.8 要求：空、非数值或越界一律**拒绝保存**、提示**含最小与最大值**、**保留原持久化值**。
 *
 * 因此本文件提供的入口一律返回 [NetworkSettingValidation]，而**不返回被钳制的值**：
 * - 只有 [NetworkSettingValidation.Accepted] 才允许继续写入 DataStore；
 * - [NetworkSettingValidation.Rejected] 携带字段、最小值与最大值，调用方据此生成提示文案，
 *   且**不得**触碰持久化层。
 *
 * 区间与 [RuntimeNetworkParametersPolicy] 完全一致（端口 1..65535 且结束 ≥ 起始；
 * 发现超时 250..120000ms；重连 0..10）。读取面的钳制（`RuntimeNetworkParametersPolicy.from`）
 * 与存储层的钳制（[NetworkSettingsStorageBackstop]）都只作为兜底，不承担校验职责。
 *
 * 全部入口都是**输入的纯函数**：不接触 `Context`、不接触 DataStore，可直接被单元测试与
 * 属性测试驱动。
 */

/** 参与范围校验的三项网络设置字段。 */
enum class NetworkSettingField {
    PORT_RANGE_START,
    PORT_RANGE_END,
    DISCOVERY_TIMEOUT_MS,
    MAX_RECONNECT_ATTEMPTS
}

/**
 * 拒绝保存的原因。每种原因都带 [min]/[max]，保证提示文案能满足 R7.8「提示含最小与最大值」。
 */
sealed interface NetworkSettingRejection {

    /** 被拒绝的字段。 */
    val settingField: NetworkSettingField

    /** 该字段允许的最小值（端口/重连为个数，发现超时为毫秒）。 */
    val min: Long

    /** 该字段允许的最大值。 */
    val max: Long

    /** 引发拒绝的原始输入（原样保留，便于回显与诊断）。 */
    val rawInput: String

    /**
     * 面向诊断/日志的英文说明，**必定同时包含** [min] 与 [max] 的十进制表示。
     * 界面侧可用 [min]/[max] 自行组织本地化文案，不必依赖此字符串。
     */
    val message: String

    /** 输入为空或仅空白。 */
    data class Empty(
        override val settingField: NetworkSettingField,
        override val min: Long,
        override val max: Long,
        override val rawInput: String
    ) : NetworkSettingRejection {
        override val message: String
            get() = "$settingField must not be empty; allowed range is $min to $max"
    }

    /** 输入不是整数（含非数字字符、只有符号等）。 */
    data class NotNumeric(
        override val settingField: NetworkSettingField,
        override val min: Long,
        override val max: Long,
        override val rawInput: String
    ) : NetworkSettingRejection {
        override val message: String
            get() = "$settingField must be an integer; allowed range is $min to $max (got \"$rawInput\")"
    }

    /** 输入是整数但落在允许区间之外（含超出 64 位表示的过大数值）。 */
    data class OutOfRange(
        override val settingField: NetworkSettingField,
        override val min: Long,
        override val max: Long,
        override val rawInput: String
    ) : NetworkSettingRejection {
        override val message: String
            get() = "$settingField must be between $min and $max (got \"$rawInput\")"
    }

    /** 端口两端各自合法，但结束端口小于起始端口。 */
    data class EndBeforeStart(
        val start: Int,
        val end: Int,
        override val min: Long,
        override val max: Long
    ) : NetworkSettingRejection {
        override val settingField: NetworkSettingField
            get() = NetworkSettingField.PORT_RANGE_END
        override val rawInput: String get() = end.toString()
        override val message: String
            get() = "port range end must be >= start ($start) and between $min and $max (got \"$end\")"
    }
}

/** 校验结果：接受并携带已解析值，或拒绝并携带原因。 */
sealed interface NetworkSettingValidation<out T> {

    data class Accepted<out T>(val value: T) : NetworkSettingValidation<T>

    data class Rejected(val reason: NetworkSettingRejection) : NetworkSettingValidation<Nothing>
}

/** 便捷取值：接受时返回值，拒绝时返回 `null`。 */
fun <T> NetworkSettingValidation<T>.acceptedValueOrNull(): T? =
    (this as? NetworkSettingValidation.Accepted<T>)?.value

/** 便捷取值：拒绝时返回原因，接受时返回 `null`。 */
fun <T> NetworkSettingValidation<T>.rejectionOrNull(): NetworkSettingRejection? =
    (this as? NetworkSettingValidation.Rejected)?.reason
