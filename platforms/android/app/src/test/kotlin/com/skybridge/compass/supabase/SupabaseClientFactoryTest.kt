package com.skybridge.compass.supabase

import com.skybridge.compass.android.data.SupabaseConfig
import io.github.jan.supabase.auth.MemoryCodeVerifierCache
import io.github.jan.supabase.auth.MemorySessionManager
import io.github.jan.supabase.auth.auth
import io.ktor.client.engine.mock.MockEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Test

class SupabaseClientFactoryTest {
    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `created client uses the explicit engine and process-local auth store`() = runTest {
        val engine = MockEngine {
            error("network must not be reached while constructing a Supabase client")
        }
        val factory = SupabaseClientFactory(
            httpEngineFactory = SupabaseHttpEngineFactory { engine },
            // A local JVM test has no Android ProcessLifecycleOwner. Disable only that
            // platform adapter; Auth still initializes normally and all failures remain visible.
            enableAuthLifecycleCallbacks = false
        )
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val client = factory.create(
                SupabaseConfig(
                    url = "https://example.supabase.co",
                    anonKey = "test-anon-key"
                )
            )

            try {
                // Client construction starts Auth initialization asynchronously. Await the
                // documented boundary before inspecting or closing the plugin so its scope
                // cannot outlive Dispatchers.Main in this test.
                client.auth.awaitInitialization()
                assertSame(engine, client.config.networkConfig.httpEngine)
                assertInstanceOf(MemorySessionManager::class.java, client.auth.sessionManager)
                assertInstanceOf(MemoryCodeVerifierCache::class.java, client.auth.codeVerifierCache)
            } finally {
                client.close()
                advanceUntilIdle()
            }
        } finally {
            Dispatchers.resetMain()
        }
    }
}
