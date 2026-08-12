package com.skybridge.compass.android.ui.screens.settings

/**
 * 设置项持久化写入的结果模型（任务 15.8 / R7.11、R7.12）。
 *
 * ## 为什么需要这一层
 *
 * 改造前 `SettingsViewModel` 的每个 setter 都是裸 `viewModelScope.launch { Store.set(...) }`：
 * DataStore 写入抛出的 `IOException` 会作为未捕获异常逃逸出协程，既不会呈现「保存未生效」，
 * 也不会把显示值回滚——R7.12 的两项要求都落空。本文件提供的类型让写入结果成为**可观察状态**。
 *
 * ## R7.12 的「回滚」在两类控件上语义不同
 *
 * - **开关 / 单选等由持久化流驱动的控件**：显示值来自 `Store.observe(...)`，写入失败时 DataStore
 *   根本没有改变，流不会发射新值，因此显示值**天然停留在写入前的已持久化值**——回滚是结构性的，
 *   不需要额外代码。这也正是「不改变其他设置项的已持久化值」成立的原因：一次 `edit` 只触碰自己的键。
 * - **文本框**：它另有一份本地 `remember` 状态（用户正在编辑的文本），不由持久化流驱动。
 *   这类控件需要**显式**把本地状态丢弃、重新以已持久化值为准。
 *
 * 因此 [SettingSaveFailure] 携带 [controlId]，界面据此知道是哪一项失败、需要把哪个本地状态回滚。
 */

/** 一次写入尝试的结果。 */
sealed interface SettingSaveOutcome {

    /** 写入成功并已落盘；此后消费方的下一次读取即取得新值（R7.11）。 */
    data object Saved : SettingSaveOutcome

    /** 写入失败；持久化值未改变（R7.12）。 */
    data class Failed(val failure: SettingSaveFailure) : SettingSaveOutcome
}

/**
 * 一次写入失败的记录。
 *
 * @param controlId 失败控件的标识，与审计清单 `SettingsControlInventory` 的 `id` 同名，
 *   使「界面提示的是哪一项」与审计证据可以对齐。
 * @param cause 底层异常（通常是 DataStore 的 `IOException`），仅用于诊断，不直接展示给用户。
 */
data class SettingSaveFailure(
    val controlId: String,
    val cause: Throwable
) {
    /**
     * 面向诊断/日志的说明。用户可见文案由界面层本地化生成
     * （见 `settingSaveFailureMessage`），因此这里不做本地化。
     */
    val message: String
        get() = "failed to persist \"$controlId\": ${cause.message ?: cause::class.java.name}"
}
