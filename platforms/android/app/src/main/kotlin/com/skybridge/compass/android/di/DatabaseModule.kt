package com.skybridge.compass.android.di

import com.skybridge.compass.core.data.database.AppDatabase
import com.skybridge.compass.core.data.dao.DeviceDao
import com.skybridge.compass.core.data.dao.ConnectionDao
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * 数据库模块的依赖注入配置
 * 
 * 提供数据库DAO等数据访问相关依赖
 */
@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {
    
    /**
     * 提供设备DAO
     */
    @Provides
    fun provideDeviceDao(database: AppDatabase): DeviceDao {
        return database.deviceDao()
    }

    /**
     * 提供连接DAO
     */
    @Provides
    fun provideConnectionDao(database: AppDatabase): ConnectionDao {
        return database.connectionDao()
    }
}