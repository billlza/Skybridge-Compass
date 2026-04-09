package com.skybridge.compass.android.di

import com.skybridge.compass.core.network.NetworkClient
import com.skybridge.compass.core.network.NetworkClientImpl
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * 核心网络客户端绑定模块
 */
@Module
@InstallIn(SingletonComponent::class)
abstract class CoreNetworkModule {
    @Binds
    @Singleton
    abstract fun bindNetworkClient(impl: NetworkClientImpl): NetworkClient
}