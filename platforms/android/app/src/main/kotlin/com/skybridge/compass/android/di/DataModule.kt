package com.skybridge.compass.android.di

import com.skybridge.compass.android.api.DashboardApi
import com.skybridge.compass.android.data.DashboardRepository
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import io.ktor.client.HttpClient
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object DataModule {

    @Provides
    @Singleton
    fun provideDashboardApi(client: HttpClient): DashboardApi {
        return DashboardApi(client)
    }

    @Provides
    @Singleton
    fun provideDashboardRepository(api: DashboardApi): DashboardRepository {
        return DashboardRepository(api)
    }
}