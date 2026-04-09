package com.skybridge.compass.android.data

import com.skybridge.compass.android.api.DashboardApi
import com.skybridge.compass.android.api.DashboardMetrics
import kotlinx.coroutines.delay
import javax.inject.Inject

class DashboardRepository @Inject constructor(
    private val api: DashboardApi
) {
    suspend fun fetchDashboardMetrics(): Result<DashboardMetrics> {
        return try {
            val data = api.getMetrics()
            Result.success(data)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchWithRetry(maxRetries: Int = 2, backoffMs: Long = 800): Result<DashboardMetrics> {
        var attempt = 0
        var lastError: Exception? = null
        while (attempt <= maxRetries) {
            val result = fetchDashboardMetrics()
            if (result.isSuccess) return result
            lastError = result.exceptionOrNull() as? Exception
            attempt++
            delay(backoffMs * attempt)
        }
        return Result.failure(lastError ?: RuntimeException("Unknown error"))
    }
}