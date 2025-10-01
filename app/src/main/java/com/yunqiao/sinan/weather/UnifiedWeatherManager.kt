package com.yunqiao.sinan.weather

import android.content.Context
import android.content.SharedPreferences
import com.yunqiao.sinan.manager.WeatherManager
import com.yunqiao.sinan.manager.WeatherInfo
import com.yunqiao.sinan.manager.LocationInfo
import com.yunqiao.sinan.shared.WeatherSystemStatus
import com.yunqiao.sinan.shared.WeatherEffectConfig
import com.yunqiao.sinan.shared.WeatherMode
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/**
 * 统一天气管理器
 * 整合WeatherManager和WeatherEffectManager的功能
 */
class UnifiedWeatherManager private constructor(
    private val context: Context
) {
    // 核心管理器
    private val weatherManager = WeatherManager(context)
    private val weatherEffectManager = WeatherEffectManager.getInstance()
    private val wallpaperManager = WeatherWallpaperManager.getInstance(context)
    
    // SharedPreferences用于配置存储
    private val prefs: SharedPreferences = context.getSharedPreferences(
        "unified_weather_settings", Context.MODE_PRIVATE
    )
    
    // 配置状态
    private val _weatherConfig = MutableStateFlow(loadWeatherConfig())
    val weatherConfig: StateFlow<WeatherConfig> = _weatherConfig.asStateFlow()
    
    // 合并的天气状态
    private val _unifiedWeatherState = MutableStateFlow(UnifiedWeatherState())
    val unifiedWeatherState: StateFlow<UnifiedWeatherState> = _unifiedWeatherState.asStateFlow()
    
    private val _isInitialized = MutableStateFlow(false)
    val isInitialized: StateFlow<Boolean> = _isInitialized.asStateFlow()
    
    private val managerScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    
    init {
        // 初始化天气系统
        initialize()
    }
    
    /**
     * 初始化统一天气管理器
     */
    private fun initialize() {
        managerScope.launch {
            try {
                // 先初始化WeatherManager - 关键修复
                weatherManager.initializeWithPermissions()
                
                // 初始化效果管理器
                weatherEffectManager.initialize()
                
                // 安全地监听天气数据变化
                launch {
                    try {
                        weatherManager.weatherInfo.collect { weatherInfo ->
                            updateUnifiedState(weatherInfo = weatherInfo)
                            
                            // 如果启用了壁纸功能，更新壁纸
                            if (_weatherConfig.value.wallpaperEnabled) {
                                wallpaperManager.updateWallpaperForWeather(weatherInfo)
                            }
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }
                
                // 安全地监听位置信息变化
                launch {
                    try {
                        weatherManager.locationInfo.collect { locationInfo ->
                            updateUnifiedState(locationInfo = locationInfo)
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }
                
                // 安全地监听更新状态
                launch {
                    try {
                        weatherManager.isUpdating.collect { isUpdating ->
                            updateUnifiedState(isUpdating = isUpdating)
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }
                
                // 安全地监听系统状态变化
                launch {
                    try {
                        weatherEffectManager.weatherStatus.collect { systemStatus ->
                            updateUnifiedState(systemStatus = systemStatus)
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }
                
                _isInitialized.value = true
                
                // 如果启用了天气功能，开始更新
                if (_weatherConfig.value.enabled) {
                    startWeatherUpdates()
                }
                
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
    
    /**
     * 更新统一状态
     */
    private fun updateUnifiedState(
        weatherInfo: WeatherInfo? = null,
        locationInfo: LocationInfo? = null,
        isUpdating: Boolean? = null,
        systemStatus: WeatherSystemStatus? = null
    ) {
        val currentState = _unifiedWeatherState.value
        
        _unifiedWeatherState.value = currentState.copy(
            weatherInfo = weatherInfo ?: currentState.weatherInfo,
            locationInfo = locationInfo ?: currentState.locationInfo,
            isUpdating = isUpdating ?: currentState.isUpdating,
            systemStatus = systemStatus ?: currentState.systemStatus,
            lastUpdateTime = System.currentTimeMillis()
        )
    }
    
    /**
     * 启动天气更新
     */
    fun startWeatherUpdates() {
        val config = _weatherConfig.value
        // 确保 WeatherManager 已初始化
        weatherManager.initializeWithPermissions()
        weatherManager.setWeatherEnabled(true)
        weatherManager.startWeatherUpdates(config.updateIntervalMinutes)
    }
    
    /**
     * 停止天气更新
     */
    fun stopWeatherUpdates() {
        weatherManager.setWeatherEnabled(false)
        weatherManager.stopWeatherUpdates()
    }
    
    /**
     * 设置天气模式
     */
    fun setWeatherMode(mode: WeatherMode) {
        weatherEffectManager.setWeatherMode(mode)
        updateConfig { it.copy(weatherMode = mode) }
    }
    
    /**
     * 设置API密钥
     */
    fun setApiKey(apiKey: String) {
        weatherManager.setWeatherApiKey(apiKey)
        updateConfig { it.copy(apiKey = apiKey) }
    }
    
    /**
     * 设置更新间隔
     */
    fun setUpdateInterval(intervalMinutes: Long) {
        updateConfig { it.copy(updateIntervalMinutes = intervalMinutes) }
        if (_weatherConfig.value.enabled) {
            restartWeatherUpdates()
        }
    }
    
    /**
     * 启用/禁用天气功能
     */
    fun setWeatherEnabled(enabled: Boolean) {
        updateConfig { it.copy(enabled = enabled) }
        if (enabled) {
            startWeatherUpdates()
        } else {
            stopWeatherUpdates()
        }
    }
    
    /**
     * 启用/禁用壁纸切换
     */
    fun setWallpaperEnabled(enabled: Boolean) {
        updateConfig { it.copy(wallpaperEnabled = enabled) }
        wallpaperManager.setWallpaperEnabled(enabled)
    }
    
    /**
     * 获取当前壁纸
     */
    fun getCurrentWallpaper() = wallpaperManager.currentWallpaper
    
    /**
     * 手动设置壁纸
     */
    fun setManualWallpaper(wallpaperName: String) {
        wallpaperManager.setManualWallpaper(wallpaperName)
    }
    
    /**
     * 获取可用壁纸列表
     */
    fun getAvailableWallpapers() = wallpaperManager.getAvailableWallpapers()
    
    /**
     * 手动刷新天气
     */
    suspend fun refreshWeather() {
        weatherManager.refreshWeather()
    }
    
    /**
     * 获取天气概要（用于主界面显示）
     */
    fun getWeatherSummary(): WeatherSummary {
        val state = _unifiedWeatherState.value
        val weatherInfo = state.weatherInfo
        
        return WeatherSummary(
            temperature = weatherInfo.temperature,
            condition = weatherInfo.condition,
            cityName = weatherInfo.cityName,
            humidity = weatherInfo.humidity,
            windSpeed = weatherInfo.windSpeed,
            isUpdating = state.isUpdating,
            lastUpdate = weatherInfo.localTime,
            airQuality = weatherInfo.airQuality?.quality ?: "未知"
        )
    }
    
    /**
     * 重启天气更新
     */
    private fun restartWeatherUpdates() {
        stopWeatherUpdates()
        startWeatherUpdates()
    }
    
    /**
     * 更新配置
     */
    private fun updateConfig(update: (WeatherConfig) -> WeatherConfig) {
        val newConfig = update(_weatherConfig.value)
        _weatherConfig.value = newConfig
        saveWeatherConfig(newConfig)
    }
    
    /**
     * 加载天气配置
     */
    private fun loadWeatherConfig(): WeatherConfig {
        return WeatherConfig(
            enabled = prefs.getBoolean("weather_enabled", true),
            apiKey = prefs.getString("weather_api_key", "") ?: "",
            updateIntervalMinutes = prefs.getLong("update_interval", 30),
            wallpaperEnabled = prefs.getBoolean("wallpaper_enabled", true),
            weatherMode = WeatherMode.valueOf(
                prefs.getString("weather_mode", WeatherMode.AUTO.name) ?: WeatherMode.AUTO.name
            ),
            showInMainScreen = prefs.getBoolean("show_in_main", true),
            notificationsEnabled = prefs.getBoolean("notifications_enabled", false)
        )
    }
    
    /**
     * 保存天气配置
     */
    private fun saveWeatherConfig(config: WeatherConfig) {
        prefs.edit().apply {
            putBoolean("weather_enabled", config.enabled)
            putString("weather_api_key", config.apiKey)
            putLong("update_interval", config.updateIntervalMinutes)
            putBoolean("wallpaper_enabled", config.wallpaperEnabled)
            putString("weather_mode", config.weatherMode.name)
            putBoolean("show_in_main", config.showInMainScreen)
            putBoolean("notifications_enabled", config.notificationsEnabled)
            apply()
        }
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        managerScope.cancel()
        weatherManager.stopWeatherUpdates()
        weatherEffectManager.cleanup()
        // wallpaperManager不需要特殊清理
    }
    
    companion object {
        @Volatile
        private var INSTANCE: UnifiedWeatherManager? = null
        
        fun getInstance(context: Context): UnifiedWeatherManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: UnifiedWeatherManager(context.applicationContext).also { INSTANCE = it }
            }
        }
    }
}

/**
 * 天气配置数据类
 */
data class WeatherConfig(
    val enabled: Boolean = true,
    val apiKey: String = "",
    val updateIntervalMinutes: Long = 30,
    val wallpaperEnabled: Boolean = true,
    val weatherMode: WeatherMode = WeatherMode.AUTO,
    val showInMainScreen: Boolean = true,
    val notificationsEnabled: Boolean = false
)

/**
 * 统一天气状态
 */
data class UnifiedWeatherState(
    val weatherInfo: WeatherInfo = WeatherInfo(),
    val locationInfo: LocationInfo = LocationInfo(),
    val systemStatus: WeatherSystemStatus = WeatherSystemStatus(),
    val isUpdating: Boolean = false,
    val lastUpdateTime: Long = 0L
)

/**
 * 天气概要（用于主界面显示）
 */
data class WeatherSummary(
    val temperature: Float = 0f,
    val condition: String = "未知",
    val cityName: String = "未知",
    val humidity: Int = 0,
    val windSpeed: Float = 0f,
    val isUpdating: Boolean = false,
    val lastUpdate: String = "",
    val airQuality: String = "未知"
)