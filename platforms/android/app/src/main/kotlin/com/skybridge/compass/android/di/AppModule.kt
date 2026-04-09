package com.skybridge.compass.android.di

import android.content.Context
import androidx.room.Room
import com.skybridge.compass.core.data.database.AppDatabase
import com.skybridge.compass.android.permissions.PermissionManager
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * 应用级别的依赖注入模块
 * 
 * 提供应用范围内的单例依赖，如数据库、权限管理器等
 */
@Module
@InstallIn(SingletonComponent::class)
object AppModule {
    
    /**
     * 提供应用数据库实例
     */
    @Provides
    @Singleton
    fun provideAppDatabase(
        @ApplicationContext context: Context
    ): AppDatabase {
        return Room.databaseBuilder(
            context,
            AppDatabase::class.java,
            "skybridge_database"
        )
        .fallbackToDestructiveMigration(true)
        .build()
    }
    
}