package com.skybridge.compass.android.data

import android.content.Context
import com.skybridge.compass.core.data.RuntimePairingApprovalParameters
import com.skybridge.compass.core.data.RuntimePairingApprovalParametersSnapshot
import com.skybridge.compass.core.data.RuntimePairingApprovalParametersSource
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 生产实现：取值来自 app 模块的 [SecuritySettingsStore]（DataStore，键 `auto_trust_known_devices`）。
 *
 * 本类是全仓**唯一**允许把该持久化字段交给运行时配对判定的地方（R7.5）。
 */
@Singleton
class DataStoreRuntimePairingApprovalParametersSource @Inject constructor(
    @param:ApplicationContext private val appContext: Context
) : RuntimePairingApprovalParametersSource {

    override fun observe(): Flow<RuntimePairingApprovalParameters> =
        SecuritySettingsStore.observe(appContext).map {
            RuntimePairingApprovalParametersSnapshot(autoTrustKnownDevices = it.autoTrustKnownDevices)
        }

    /** 每次调用都取一次最新持久化值，保证下一个配对请求按新值判定（R7.5）。 */
    override suspend fun current(): RuntimePairingApprovalParameters =
        RuntimePairingApprovalParametersSnapshot(
            autoTrustKnownDevices = SecuritySettingsStore.observe(appContext).first().autoTrustKnownDevices
        )
}
