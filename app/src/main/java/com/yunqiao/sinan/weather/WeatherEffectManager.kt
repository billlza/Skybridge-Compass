package com.yunqiao.sinan.weather

import com.yunqiao.sinan.shared.WeatherSystemStatus
import com.yunqiao.sinan.shared.WeatherEffectConfig
import com.yunqiao.sinan.shared.WeatherMode
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/**
 * 天气效果管理器
 * 负责管理所有天气相关的视觉效果和数据处理
 */
class WeatherEffectManager {
    private val _weatherStatus = MutableStateFlow(WeatherSystemStatus())
    val weatherStatus: StateFlow<WeatherSystemStatus> = _weatherStatus.asStateFlow()
    
    private val _effectConfig = MutableStateFlow(WeatherEffectConfig())
    val effectConfig: StateFlow<WeatherEffectConfig> = _effectConfig.asStateFlow()
    
    private var managerScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    
    /**
     * 初始化天气系统
     */
    fun initialize() {
        println("WeatherEffectManager 初始化完成")
        updateWeatherStatus(WeatherSystemStatus(isActive = true))
    }
    
    /**
     * 更新天气状态
     */
    fun updateWeatherStatus(status: WeatherSystemStatus) {
        _weatherStatus.value = status
    }
    
    /**
     * 更新效果配置
     */
    fun updateEffectConfig(config: WeatherEffectConfig) {
        _effectConfig.value = config
    }
    
    /**
     * 设置天气模式
     */
    fun setWeatherMode(mode: WeatherMode) {
        val currentStatus = _weatherStatus.value
        _weatherStatus.value = currentStatus.copy(currentMode = mode)
    }
    
    /**
     * 获取当前天气数据
     */
    fun getCurrentWeatherData(): WeatherSystemStatus {
        return _weatherStatus.value
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        managerScope.cancel()
        managerScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    }
    
    companion object {
        @Volatile
        private var INSTANCE: WeatherEffectManager? = null
        
        fun getInstance(): WeatherEffectManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: WeatherEffectManager().also { INSTANCE = it }
            }
        }
    }
}
