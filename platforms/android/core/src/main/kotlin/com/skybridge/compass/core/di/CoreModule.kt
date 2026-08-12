package com.skybridge.compass.core.di

import android.content.Context
import com.skybridge.compass.core.data.DataStoreRuntimeNetworkParametersSource
import com.skybridge.compass.core.data.RuntimeNetworkParametersSource
import com.skybridge.compass.core.services.HardwareMonitorService
import com.skybridge.compass.core.services.HardwareMonitorServiceImpl
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object CoreModule {
    
    @Provides
    @Singleton
    fun provideHardwareMonitorService(
        @ApplicationContext context: Context
    ): HardwareMonitorService {
        return HardwareMonitorServiceImpl(context)
    }
}

/**
 * 网络运行时参数的单一读取面绑定（R7.4）。运行时消费方注入
 * [RuntimeNetworkParametersSource]，而不是各自去读 `NetworkSettingsStore`。
 */
@Module
@InstallIn(SingletonComponent::class)
abstract class CoreRuntimeNetworkParametersModule {

    @Binds
    @Singleton
    abstract fun bindRuntimeNetworkParametersSource(
        impl: DataStoreRuntimeNetworkParametersSource
    ): RuntimeNetworkParametersSource
}
