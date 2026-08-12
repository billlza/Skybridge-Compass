package com.skybridge.compass.android.di

import com.skybridge.compass.android.data.DataStoreRuntimePairingApprovalParametersSource
import com.skybridge.compass.core.data.RuntimePairingApprovalParametersSource
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * 配对批准运行时参数的单一读取面绑定（R7.5）。运行时消费方注入
 * [RuntimePairingApprovalParametersSource]，而不是各自去读 `SecuritySettingsStore`。
 */
@Module
@InstallIn(SingletonComponent::class)
abstract class PairingApprovalModule {

    @Binds
    @Singleton
    abstract fun bindRuntimePairingApprovalParametersSource(
        impl: DataStoreRuntimePairingApprovalParametersSource
    ): RuntimePairingApprovalParametersSource
}
