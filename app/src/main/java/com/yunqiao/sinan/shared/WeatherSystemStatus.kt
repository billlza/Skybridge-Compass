package com.yunqiao.sinan.shared

import kotlinx.serialization.Serializable

/**
 * 天气系统状态数据类
 * 共享给所有天气相关模块使用
 */
@Serializable
data class WeatherSystemStatus(
    val isActive: Boolean = false,
    val currentMode: WeatherMode = WeatherMode.AUTO,
    val temperature: Float = 20.0f,
    val humidity: Float = 50.0f,
    val pressure: Float = 1013.25f,
    val visibility: Float = 10.0f,
    val timestamp: Long = System.currentTimeMillis()
)

enum class WeatherMode {
    AUTO,
    MANUAL,
    SIMULATION,
    DISABLED
}

/**
 * 天气效果配置
 */
@Serializable
data class WeatherEffectConfig(
    val enabled: Boolean = true,
    val intensity: Float = 1.0f,
    val duration: Long = 5000L,
    val transitionTime: Long = 1000L
)
