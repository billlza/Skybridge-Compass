package com.skybridge.compass.discovery.data.services

import com.skybridge.compass.core.data.RuntimeNetworkParameters
import com.skybridge.compass.core.data.RuntimeNetworkParametersSnapshot
import com.skybridge.compass.core.data.RuntimeNetworkParametersSource
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds

/**
 * In-memory stand-in for the single read surface. Mutating [value] models the user changing a
 * setting: every subsequent [current] call observes the new value, which is exactly the R7.4
 * "next session uses the new value" contract.
 */
class FakeRuntimeNetworkParametersSource(
    listenPortRange: IntRange = 8080..8090,
    discoveryWindow: Duration = 30_000.milliseconds,
    maxReconnectAttempts: Int = 3
) : RuntimeNetworkParametersSource {

    private val state = MutableStateFlow<RuntimeNetworkParameters>(
        RuntimeNetworkParametersSnapshot(
            listenPortRange = listenPortRange,
            discoveryWindow = discoveryWindow,
            maxReconnectAttempts = maxReconnectAttempts
        )
    )

    /** Number of times a consumer re-read the surface; proves per-session reads. */
    var readCount: Int = 0
        private set

    var value: RuntimeNetworkParameters
        get() = state.value
        set(newValue) {
            state.value = newValue
        }

    override suspend fun current(): RuntimeNetworkParameters {
        readCount += 1
        return state.value
    }

    override fun observe(): Flow<RuntimeNetworkParameters> = state.asStateFlow()
}
