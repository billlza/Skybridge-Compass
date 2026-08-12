package com.skybridge.compass.core.data

import kotlinx.coroutines.flow.Flow

/**
 * 配对批准的单一读取面（design §7、R7.5）。
 *
 * 与 [RuntimeNetworkParameters] 并列：运行时消费方不直接读取
 * `security_settings` 的 `auto_trust_known_devices`，一律经由本接口，
 * 使「界面可改的值」与「运行时真正生效的值」保持同一来源。
 *
 * 持久化字段位于 **app** 模块的 `SecuritySettingsStore`，实现也在 app 模块；core 只声明读取面。
 */
interface RuntimePairingApprovalParameters {
    /** 已配对设备是否免交互批准（`auto_trust_known_devices`，默认 false）。 */
    val autoTrustKnownDevices: Boolean
}

/**
 * [RuntimePairingApprovalParameters] 的取值入口。
 *
 * [current] 每次调用都重新读取持久化值，因此**新到达的配对请求**按最新设置判定，
 * 而已进入等待显式批准态的请求仍沿用其判定时读到的快照（R7.5）。
 */
interface RuntimePairingApprovalParametersSource {

    /** 读取当前生效值，供一次新的配对判定使用。 */
    suspend fun current(): RuntimePairingApprovalParameters

    /** 观察取值变化，供需要随设置变化重新决策的长驻消费方使用。 */
    fun observe(): Flow<RuntimePairingApprovalParameters>
}

/** 不可变取值快照。一次配对判定取一份，之后不再变化。 */
data class RuntimePairingApprovalParametersSnapshot(
    override val autoTrustKnownDevices: Boolean
) : RuntimePairingApprovalParameters
