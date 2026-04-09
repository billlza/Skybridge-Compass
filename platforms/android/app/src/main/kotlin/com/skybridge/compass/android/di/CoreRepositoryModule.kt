package com.skybridge.compass.android.di

import com.skybridge.compass.core.repository.ConnectionRepository
import com.skybridge.compass.core.repository.ConnectionRepositoryImpl
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * 核心仓库的依赖注入绑定
 */
@Module
@InstallIn(SingletonComponent::class)
abstract class CoreRepositoryModule {

    @Binds
    @Singleton
    abstract fun bindConnectionRepository(
        impl: ConnectionRepositoryImpl
    ): ConnectionRepository
}