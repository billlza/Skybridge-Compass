package com.skybridge.compass.android.di

import android.content.Context
import com.skybridge.compass.BuildConfig
import com.skybridge.compass.android.security.PinProvider
import com.skybridge.compass.android.security.PinProviderImpl
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Singleton
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.plugins.HttpTimeout
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.runBlocking
import java.util.concurrent.TimeUnit

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides
    @Singleton
    fun providePinProvider(
        @ApplicationContext context: Context,
        json: Json
    ): PinProvider =
        PinProviderImpl(
            json = json,
            allowUnverifiedPinsInDebug = BuildConfig.DEBUG,
            publicKeyPem = readRawResourceText(context, "pins_public_key")
        )

    /**
     * 提供OkHttp客户端
     */
    @Provides
    @Singleton
    fun provideOkHttpClient(
        @ApplicationContext context: Context,
        pinProvider: PinProvider
    ): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
        
        // Add certificate pinning if available
        runBlocking {
            pinProvider.buildCertificatePinner(context)?.let { pinner ->
                builder.certificatePinner(pinner)
            }
        }
        
        // Add logging in debug builds
        if (BuildConfig.DEBUG) {
            val loggingInterceptor = HttpLoggingInterceptor().apply {
                level = HttpLoggingInterceptor.Level.BODY
            }
            builder.addInterceptor(loggingInterceptor)
        }
        
        return builder.build()
    }

    /**
     * 提供Ktor HTTP客户端
     */
    @Provides
    @Singleton
    fun provideKtorClient(
        okHttpClient: OkHttpClient,
        json: Json
    ): HttpClient = HttpClient(OkHttp) {
        engine {
            preconfigured = okHttpClient
        }
        install(ContentNegotiation) {
            json(json)
        }
        install(HttpTimeout) {
            requestTimeoutMillis = 20_000
            connectTimeoutMillis = 10_000
            socketTimeoutMillis = 20_000
        }
    }
    
    /**
     * 提供JSON序列化器
     */
    @Provides
    @Singleton
    fun provideJson(): Json {
        return Json {
            ignoreUnknownKeys = true
            isLenient = true
            prettyPrint = BuildConfig.DEBUG
        }
    }

    private fun readRawResourceText(context: Context, name: String): String? {
        return try {
            val resId = context.resources.getIdentifier(name, "raw", context.packageName)
            if (resId == 0) return null
            context.resources.openRawResource(resId).bufferedReader().use { it.readText().trim() }
        } catch (_: Exception) {
            null
        }
    }
}
