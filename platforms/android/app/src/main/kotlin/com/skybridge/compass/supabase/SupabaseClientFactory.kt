package com.skybridge.compass.supabase

import com.skybridge.compass.android.data.SupabaseConfig
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.realtime.Realtime
import io.github.jan.supabase.storage.Storage
class SupabaseClientFactory {
    fun create(config: SupabaseConfig): SupabaseClient {
        return createSupabaseClient(config.url, config.anonKey) {
            install(Auth) {
                alwaysAutoRefresh = true
            }
            install(Postgrest)
            install(Storage)
            install(Realtime)
        }
    }
}

