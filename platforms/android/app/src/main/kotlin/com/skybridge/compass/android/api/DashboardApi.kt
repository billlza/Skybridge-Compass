package com.skybridge.compass.android.api

import com.skybridge.compass.BuildConfig
import com.skybridge.compass.android.i18n.resolveLocalizedText
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import kotlinx.serialization.Serializable
import javax.inject.Inject

@Serializable
data class DashboardMetrics(
    val connectedDevices: Int = 0,
    val activeSessions: Int = 0,
    val networkQuality: String = resolveLocalizedText("未知", "Unknown", "不明"),
    val dataTransferredMb: Int = 0,
    val transferProgress: Float = 0f,
    val latencyMs: Long = 0L
)

class DashboardApi @Inject constructor(
    private val client: HttpClient
) {
    private val baseUrl: String = BuildConfig.API_BASE_URL.trimEnd('/')

    suspend fun getMetrics(): DashboardMetrics {
        // 约定后端返回 DashboardMetrics 结构；路径可按需调整
        return client.get("$baseUrl/dashboard/metrics").body()
    }
}
