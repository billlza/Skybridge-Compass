package com.skybridge.compass.android.weather

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Drives the 30-minute auto-refresh that macOS runs off a `Timer`.
 *
 * The ticker is bound to the process lifecycle rather than a WorkManager job: weather only feeds
 * on-screen surfaces (the dashboard card and the animated background), so polling while the app is
 * backgrounded would burn battery for data nobody can see. Re-entering the foreground restarts the
 * loop, which refreshes immediately if the last observation has gone stale.
 */
@Singleton
class WeatherAutoRefreshScheduler @Inject constructor(
    private val weatherRepository: WeatherRepository
) : DefaultLifecycleObserver {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var tickerJob: Job? = null

    /** Must be called from the main thread (see [ProcessLifecycleOwner.get]). */
    fun start() {
        ProcessLifecycleOwner.get().lifecycle.addObserver(this)
    }

    override fun onStart(owner: LifecycleOwner) {
        tickerJob?.cancel()
        tickerJob = scope.launch {
            while (isActive) {
                weatherRepository.refreshIfStale()
                delay(STALENESS_CHECK_INTERVAL_MILLIS)
            }
        }
    }

    override fun onStop(owner: LifecycleOwner) {
        tickerJob?.cancel()
        tickerJob = null
    }

    private companion object {
        /**
         * Polling cadence, not the refresh cadence: `refreshIfStale` is a no-op until the
         * observation is older than [WeatherRepository.AUTO_REFRESH_INTERVAL_MILLIS].
         */
        const val STALENESS_CHECK_INTERVAL_MILLIS = 5 * 60 * 1000L
    }
}
