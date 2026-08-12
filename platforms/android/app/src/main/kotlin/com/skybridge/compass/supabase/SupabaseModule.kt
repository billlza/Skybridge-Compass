package com.skybridge.compass.supabase

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import io.ktor.client.engine.okhttp.OkHttp
import okhttp3.OkHttpClient
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object SupabaseModule {

    @Provides
    @Singleton
    fun provideSupabaseClientFactory(okHttpClient: OkHttpClient): SupabaseClientFactory =
        SupabaseClientFactory(
            httpEngineFactory = SupabaseHttpEngineFactory {
                OkHttp.create {
                    preconfigured = okHttpClient
                }
            },
            enableAuthLifecycleCallbacks = true
        )
}
