package com.skybridge.compass.supabase

import com.skybridge.compass.android.data.SupabaseConfig
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.MemoryCodeVerifierCache
import io.github.jan.supabase.auth.MemorySessionManager
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.realtime.Realtime
import io.github.jan.supabase.storage.Storage
import io.ktor.client.engine.HttpClientEngine

internal fun interface SupabaseHttpEngineFactory {
    fun create(): HttpClientEngine
}

class SupabaseClientFactory internal constructor(
    private val httpEngineFactory: SupabaseHttpEngineFactory,
    private val enableAuthLifecycleCallbacks: Boolean
) {
    fun create(config: SupabaseConfig): SupabaseClient {
        return createSupabaseClient(config.url, config.anonKey) {
            httpEngine = httpEngineFactory.create()
            install(Auth) {
                alwaysAutoRefresh = true
                enableLifecycleCallbacks = enableAuthLifecycleCallbacks
                // AuthRepository owns durable session persistence through
                // SupabaseSessionStore (Android Keystore-backed encrypted storage).
                // Keep the SDK session manager process-local so the SDK cannot
                // create a second, independently persisted copy of refresh tokens.
                autoLoadFromStorage = false
                autoSaveToStorage = false
                sessionManager = MemorySessionManager()
                codeVerifierCache = MemoryCodeVerifierCache()
            }
            install(Postgrest)
            install(Storage)
            install(Realtime)
        }
    }
}
