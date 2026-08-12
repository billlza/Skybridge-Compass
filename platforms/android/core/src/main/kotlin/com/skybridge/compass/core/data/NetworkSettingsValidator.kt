package com.skybridge.compass.core.data

/**
 * 三项网络设置的**纯函数**校验器（R7.8）。
 *
 * 两类入口：
 * - `validate*Input(raw: String)`：接收文本框**原始字符串**，因此能表达「空」与「非数值」
 *   这两种 `Int`/`Long` 参数无法表达的拒绝情形；
 * - `validate*(value)`：给已经持有数值的调用方（如云端设置同步）用的类型化路径。
 *
 * 校验器不接触 `Context`/DataStore，也**从不**返回被钳制的值：越界一律 [NetworkSettingValidation.Rejected]。
 * 区间取自 [RuntimeNetworkParametersPolicy]，与读取面保持单一来源。
 */
object NetworkSettingsValidator {

    /** 端口最小值，1。 */
    const val MIN_PORT: Int = RuntimeNetworkParametersPolicy.MIN_PORT

    /** 端口最大值，65535。 */
    const val MAX_PORT: Int = RuntimeNetworkParametersPolicy.MAX_PORT

    /** 发现超时最小值，250ms。 */
    const val MIN_DISCOVERY_TIMEOUT_MS: Long = 250L

    /** 发现超时最大值，120000ms。 */
    const val MAX_DISCOVERY_TIMEOUT_MS: Long = 120_000L

    /** 重连尝试最小值，0。 */
    const val MIN_RECONNECT_ATTEMPTS: Int = RuntimeNetworkParametersPolicy.MIN_RECONNECT_ATTEMPTS

    /** 重连尝试最大值，10。 */
    const val MAX_RECONNECT_ATTEMPTS: Int = RuntimeNetworkParametersPolicy.MAX_RECONNECT_ATTEMPTS

    // region 端口范围

    /**
     * 校验端口范围的两个文本框输入。
     *
     * 顺序：先起始端口（空/非数值/越界），再结束端口（空/非数值/越界），最后 `end >= start`。
     * 任一步失败即返回拒绝，调用方**不得**写入。
     */
    fun validatePortRangeInput(
        rawStart: String,
        rawEnd: String
    ): NetworkSettingValidation<IntRange> {
        val start = parseInt(
            raw = rawStart,
            settingField = NetworkSettingField.PORT_RANGE_START,
            min = MIN_PORT,
            max = MAX_PORT
        )
        if (start is NetworkSettingValidation.Rejected) return start
        val end = parseInt(
            raw = rawEnd,
            settingField = NetworkSettingField.PORT_RANGE_END,
            min = MIN_PORT,
            max = MAX_PORT
        )
        if (end is NetworkSettingValidation.Rejected) return end

        val startValue = (start as NetworkSettingValidation.Accepted<Int>).value
        val endValue = (end as NetworkSettingValidation.Accepted<Int>).value
        return validatePortRange(startValue, endValue)
    }

    /** 类型化路径：两端已是 `Int` 时校验区间与 `end >= start`。 */
    fun validatePortRange(start: Int, end: Int): NetworkSettingValidation<IntRange> {
        if (start < MIN_PORT || start > MAX_PORT) {
            return rejectOutOfRange(
                settingField = NetworkSettingField.PORT_RANGE_START,
                min = MIN_PORT.toLong(),
                max = MAX_PORT.toLong(),
                rawInput = start.toString()
            )
        }
        if (end < MIN_PORT || end > MAX_PORT) {
            return rejectOutOfRange(
                settingField = NetworkSettingField.PORT_RANGE_END,
                min = MIN_PORT.toLong(),
                max = MAX_PORT.toLong(),
                rawInput = end.toString()
            )
        }
        if (end < start) {
            return NetworkSettingValidation.Rejected(
                NetworkSettingRejection.EndBeforeStart(
                    start = start,
                    end = end,
                    min = MIN_PORT.toLong(),
                    max = MAX_PORT.toLong()
                )
            )
        }
        return NetworkSettingValidation.Accepted(start..end)
    }

    // endregion

    // region 发现超时

    /** 校验发现超时文本框输入，单位毫秒。 */
    fun validateDiscoveryTimeoutMsInput(raw: String): NetworkSettingValidation<Long> =
        parseLong(
            raw = raw,
            settingField = NetworkSettingField.DISCOVERY_TIMEOUT_MS,
            min = MIN_DISCOVERY_TIMEOUT_MS,
            max = MAX_DISCOVERY_TIMEOUT_MS
        )

    /** 类型化路径：已持有毫秒数值时校验区间。 */
    fun validateDiscoveryTimeoutMs(timeoutMs: Long): NetworkSettingValidation<Long> =
        if (timeoutMs < MIN_DISCOVERY_TIMEOUT_MS || timeoutMs > MAX_DISCOVERY_TIMEOUT_MS) {
            rejectOutOfRange(
                settingField = NetworkSettingField.DISCOVERY_TIMEOUT_MS,
                min = MIN_DISCOVERY_TIMEOUT_MS,
                max = MAX_DISCOVERY_TIMEOUT_MS,
                rawInput = timeoutMs.toString()
            )
        } else {
            NetworkSettingValidation.Accepted(timeoutMs)
        }

    // endregion

    // region 重连次数

    /** 校验重连次数文本框输入。 */
    fun validateMaxReconnectAttemptsInput(raw: String): NetworkSettingValidation<Int> =
        parseInt(
            raw = raw,
            settingField = NetworkSettingField.MAX_RECONNECT_ATTEMPTS,
            min = MIN_RECONNECT_ATTEMPTS,
            max = MAX_RECONNECT_ATTEMPTS
        )

    /** 类型化路径：已持有次数时校验区间。 */
    fun validateMaxReconnectAttempts(attempts: Int): NetworkSettingValidation<Int> =
        if (attempts < MIN_RECONNECT_ATTEMPTS || attempts > MAX_RECONNECT_ATTEMPTS) {
            rejectOutOfRange(
                settingField = NetworkSettingField.MAX_RECONNECT_ATTEMPTS,
                min = MIN_RECONNECT_ATTEMPTS.toLong(),
                max = MAX_RECONNECT_ATTEMPTS.toLong(),
                rawInput = attempts.toString()
            )
        } else {
            NetworkSettingValidation.Accepted(attempts)
        }

    // endregion

    // region 解析

    private fun parseInt(
        raw: String,
        settingField: NetworkSettingField,
        min: Int,
        max: Int
    ): NetworkSettingValidation<Int> {
        val parsed = parseLong(raw, settingField, min.toLong(), max.toLong())
        return when (parsed) {
            is NetworkSettingValidation.Rejected -> parsed
            is NetworkSettingValidation.Accepted -> NetworkSettingValidation.Accepted(parsed.value.toInt())
        }
    }

    /**
     * 统一解析：空 → [NetworkSettingRejection.Empty]；非整数 → [NetworkSettingRejection.NotNumeric]；
     * 超出区间（含超过 `Long` 表示范围的纯数字串）→ [NetworkSettingRejection.OutOfRange]。
     */
    private fun parseLong(
        raw: String,
        settingField: NetworkSettingField,
        min: Long,
        max: Long
    ): NetworkSettingValidation<Long> {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) {
            return NetworkSettingValidation.Rejected(
                NetworkSettingRejection.Empty(settingField, min, max, raw)
            )
        }
        // 形状先判：可选单个 ASCII 正负号 + 至少一位 ASCII 数字。
        // 不能只依赖 toLongOrNull：它会接受全角数字等非 ASCII 数字（如 "１２３"），
        // 那类输入应归为「非数值」而不是被静默当成 123。
        if (!isAsciiDecimalInteger(trimmed)) {
            return NetworkSettingValidation.Rejected(
                NetworkSettingRejection.NotNumeric(settingField, min, max, raw)
            )
        }
        // 形状合法但超出 Long 表示范围：属于越界，而非非数值。
        val value = trimmed.toLongOrNull()
            ?: return rejectOutOfRange(settingField, min, max, raw)
        return if (value < min || value > max) {
            rejectOutOfRange(settingField, min, max, raw)
        } else {
            NetworkSettingValidation.Accepted(value)
        }
    }

    private fun isAsciiDecimalInteger(value: String): Boolean {
        val body = if (value.first() == '+' || value.first() == '-') value.substring(1) else value
        return body.isNotEmpty() && body.all { it in '0'..'9' }
    }

    private fun rejectOutOfRange(
        settingField: NetworkSettingField,
        min: Long,
        max: Long,
        rawInput: String
    ): NetworkSettingValidation.Rejected = NetworkSettingValidation.Rejected(
        NetworkSettingRejection.OutOfRange(settingField, min, max, rawInput)
    )

    // endregion
}

/**
 * 存储层兜底钳制（design §7「钳制只作为存储层兜底」）。
 *
 * 为什么保留钳制仍然安全：
 * - 经过 [NetworkSettingsValidator] 的调用方，其值必定已在区间内，钳制是恒等映射，
 *   因此**永远观察不到静默改写**；
 * - 绕过校验的调用方（旧代码、云端同步的历史快照）无法把越界值写进存储，运行时不会拿到
 *   非法端口/窗口/次数；
 * - 与 [RuntimeNetworkParametersPolicy] 的读取面钳制方向一致，形成写入面与读取面双兜底。
 */
internal object NetworkSettingsStorageBackstop {

    fun clampPortStart(start: Int): Int =
        start.coerceIn(NetworkSettingsValidator.MIN_PORT, NetworkSettingsValidator.MAX_PORT)

    fun clampPortEnd(start: Int, end: Int): Int =
        end.coerceIn(clampPortStart(start), NetworkSettingsValidator.MAX_PORT)

    fun clampDiscoveryTimeoutMs(timeoutMs: Long): Long = timeoutMs.coerceIn(
        NetworkSettingsValidator.MIN_DISCOVERY_TIMEOUT_MS,
        NetworkSettingsValidator.MAX_DISCOVERY_TIMEOUT_MS
    )

    fun clampReconnectAttempts(attempts: Int): Int = attempts.coerceIn(
        NetworkSettingsValidator.MIN_RECONNECT_ATTEMPTS,
        NetworkSettingsValidator.MAX_RECONNECT_ATTEMPTS
    )
}

/**
 * 唯一写入闸门：把「校验 → 写入」串成一条不可绕过的路径（R7.8）。
 *
 * [NetworkSettingsStore] 的三项数值写入**全部**经由本函数，且写入动作只存在于 [write] 闭包里。
 * 因此不变量可直接由此处证明：[validation] 为 [NetworkSettingValidation.Rejected] 时 [write]
 * 根本不会被调用，持久化层不被触碰——既保留原值，也不影响任何其他键。
 *
 * @return 原样返回 [validation]，供调用方据此生成提示。
 */
internal suspend fun <T> writeIfAccepted(
    validation: NetworkSettingValidation<T>,
    write: suspend (T) -> Unit
): NetworkSettingValidation<T> {
    val accepted = validation.acceptedValueOrNull() ?: return validation
    write(accepted)
    return validation
}
