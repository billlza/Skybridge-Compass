package com.yunqiao.sinan.weather

import android.content.Context
import android.content.SharedPreferences
import android.graphics.drawable.Drawable
import androidx.core.content.ContextCompat
import com.yunqiao.sinan.manager.WeatherInfo
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.*

/**
 * 天气壁纸管理器
 * 负责根据天气条件自动切换壁纸
 */
class WeatherWallpaperManager(private val context: Context) {
    
    private val prefs: SharedPreferences = context.getSharedPreferences(
        "weather_wallpaper_settings", Context.MODE_PRIVATE
    )
    
    private val _currentWallpaper = MutableStateFlow("")
    val currentWallpaper: StateFlow<String> = _currentWallpaper.asStateFlow()
    
    private val _wallpaperEnabled = MutableStateFlow(true)
    val wallpaperEnabled: StateFlow<Boolean> = _wallpaperEnabled.asStateFlow()
    
    // 壁纸资源映射 - 支持不同时间和天气的组合
    private val weatherWallpapers = mapOf(
        // 晴天壁纸
        "sunny_day" to listOf(
            "sunny_day_1", "sunny_day_2", "sunny_day_3", "sunny_day_4"
        ),
        "sunny_morning" to listOf(
            "sunny_morning_1", "sunny_morning_2"
        ),
        "sunny_afternoon" to listOf(
            "sunny_afternoon_1", "sunny_afternoon_2"
        ),
        
        // 多云天气
        "cloudy_day" to listOf(
            "cloudy_day_1", "cloudy_day_2", "cloudy_day_3"
        ),
        "cloudy_morning" to listOf(
            "cloudy_morning_1", "cloudy_morning_2"
        ),
        
        // 雨天壁纸
        "rainy_day" to listOf(
            "rainy_day_1", "rainy_day_2", "rainy_day_3"
        ),
        "rainy_night" to listOf(
            "rainy_night_1", "rainy_night_2"
        ),
        "storm" to listOf(
            "storm_1", "storm_2", "thunderstorm_1"
        ),
        
        // 雪天壁纸
        "snow_day" to listOf(
            "snow_day_1", "snow_day_2", "snow_day_3"
        ),
        "snow_night" to listOf(
            "snow_night_1", "snow_night_2"
        ),
        
        // 雾天壁纸
        "fog_morning" to listOf(
            "fog_morning_1", "fog_morning_2"
        ),
        "fog_day" to listOf(
            "fog_day_1", "fog_day_2"
        ),
        
        // 夜间壁纸
        "clear_night" to listOf(
            "clear_night_1", "clear_night_2", "clear_night_3", "starry_night_1"
        ),
        "cloudy_night" to listOf(
            "cloudy_night_1", "cloudy_night_2"
        ),
        
        // 日出日落
        "sunrise" to listOf(
            "sunrise_1", "sunrise_2", "sunrise_3"
        ),
        "sunset" to listOf(
            "sunset_1", "sunset_2", "sunset_3", "sunset_4"
        ),
        
        // 默认壁纸
        "default" to listOf(
            "default_gradient_1", "default_gradient_2", "default_space_1"
        )
    )
    
    // 备用壁纸（当指定壁纸不存在时使用）
    private val fallbackWallpapers = listOf(
        "android.R.drawable.wallpaper_background_primary",
        "android.R.drawable.wallpaper_background_secondary"
    )
    
    init {
        loadSettings()
    }
    
    /**
     * 根据天气信息更新壁纸
     */
    fun updateWallpaperForWeather(weatherInfo: WeatherInfo) {
        if (!_wallpaperEnabled.value) return
        
        val wallpaperCategory = determineWallpaperCategory(weatherInfo)
        val wallpaperName = selectWallpaperFromCategory(wallpaperCategory)
        
        applyWallpaper(wallpaperName)
    }
    
    /**
     * 确定壁纸类别
     */
    private fun determineWallpaperCategory(weatherInfo: WeatherInfo): String {
        val currentTime = Calendar.getInstance()
        val hour = currentTime.get(Calendar.HOUR_OF_DAY)
        val condition = weatherInfo.condition.lowercase()
        val conditionCode = weatherInfo.conditionCode
        
        // 时间段判断
        val timeOfDay = when {
            hour in 5..7 -> "morning"
            hour in 17..19 -> "evening"
            hour >= 20 || hour <= 5 -> "night"
            else -> "day"
        }
        
        // 特殊时间段
        if (hour in 5..7) {
            return if (isClearWeather(condition, conditionCode)) "sunrise" else "cloudy_morning"
        }
        
        if (hour in 17..19) {
            return if (isClearWeather(condition, conditionCode)) "sunset" else "cloudy_$timeOfDay"
        }
        
        // 根据天气条件和时间选择
        return when {
            // 晴天
            isSunnyWeather(condition, conditionCode) -> {
                when (timeOfDay) {
                    "morning" -> "sunny_morning"
                    "night" -> "clear_night"
                    else -> "sunny_day"
                }
            }
            
            // 多云
            isCloudyWeather(condition, conditionCode) -> {
                when (timeOfDay) {
                    "morning" -> "cloudy_morning"
                    "night" -> "cloudy_night"
                    else -> "cloudy_day"
                }
            }
            
            // 雨天
            isRainyWeather(condition, conditionCode) -> {
                when {
                    isStormyWeather(condition, conditionCode) -> "storm"
                    timeOfDay == "night" -> "rainy_night"
                    else -> "rainy_day"
                }
            }
            
            // 雪天
            isSnowyWeather(condition, conditionCode) -> {
                when (timeOfDay) {
                    "night" -> "snow_night"
                    else -> "snow_day"
                }
            }
            
            // 雾天
            isFoggyWeather(condition, conditionCode) -> {
                when (timeOfDay) {
                    "morning" -> "fog_morning"
                    else -> "fog_day"
                }
            }
            
            else -> "default"
        }
    }
    
    /**
     * 从类别中选择壁纸
     */
    private fun selectWallpaperFromCategory(category: String): String {
        val wallpaperList = weatherWallpapers[category] ?: weatherWallpapers["default"]!!
        
        // 随机选择，但避免连续选择相同壁纸
        val lastWallpaper = _currentWallpaper.value
        val availableWallpapers = if (wallpaperList.size > 1) {
            wallpaperList.filter { it != lastWallpaper }
        } else {
            wallpaperList
        }
        
        return availableWallpapers.random()
    }
    
    /**
     * 应用壁纸
     */
    private fun applyWallpaper(wallpaperName: String) {
        try {
            // 检查资源是否存在
            val resourceId = getWallpaperResourceId(wallpaperName)
            
            if (resourceId != 0) {
                _currentWallpaper.value = wallpaperName
                saveCurrentWallpaper(wallpaperName)
                
                // 这里可以发送广播通知UI更新壁纸
                notifyWallpaperChanged(wallpaperName, resourceId)
            } else {
                // 使用备用壁纸
                applyFallbackWallpaper()
            }
            
        } catch (e: Exception) {
            e.printStackTrace()
            applyFallbackWallpaper()
        }
    }
    
    /**
     * 获取壁纸资源ID
     */
    private fun getWallpaperResourceId(wallpaperName: String): Int {
        return try {
            context.resources.getIdentifier(
                wallpaperName, "drawable", context.packageName
            )
        } catch (e: Exception) {
            0
        }
    }
    
    /**
     * 应用备用壁纸
     */
    private fun applyFallbackWallpaper() {
        val fallbackWallpaper = fallbackWallpapers.getOrElse(0) { "default_gradient_1" }
        val resourceId = getWallpaperResourceId(fallbackWallpaper)
        
        if (resourceId != 0) {
            _currentWallpaper.value = fallbackWallpaper
            notifyWallpaperChanged(fallbackWallpaper, resourceId)
        }
    }
    
    /**
     * 通知壁纸变化
     */
    private fun notifyWallpaperChanged(wallpaperName: String, resourceId: Int) {
        // 保存到SharedPreferences供UI使用
        prefs.edit().apply {
            putString("current_wallpaper", wallpaperName)
            putInt("current_wallpaper_id", resourceId)
            putLong("wallpaper_changed_time", System.currentTimeMillis())
            apply()
        }
    }
    
    /**
     * 获取当前壁纸Drawable
     */
    fun getCurrentWallpaperDrawable(): Drawable? {
        val wallpaperName = _currentWallpaper.value
        if (wallpaperName.isEmpty()) return null
        
        val resourceId = getWallpaperResourceId(wallpaperName)
        return if (resourceId != 0) {
            ContextCompat.getDrawable(context, resourceId)
        } else {
            null
        }
    }
    
    /**
     * 启用/禁用壁纸功能
     */
    fun setWallpaperEnabled(enabled: Boolean) {
        _wallpaperEnabled.value = enabled
        prefs.edit().putBoolean("wallpaper_enabled", enabled).apply()
    }
    
    /**
     * 手动设置壁纸
     */
    fun setManualWallpaper(wallpaperName: String) {
        applyWallpaper(wallpaperName)
    }
    
    /**
     * 获取可用壁纸列表
     */
    fun getAvailableWallpapers(): Map<String, List<String>> {
        return weatherWallpapers.mapValues { (_, wallpapers) ->
            wallpapers.filter { getWallpaperResourceId(it) != 0 }
        }.filterValues { it.isNotEmpty() }
    }
    
    /**
     * 加载设置
     */
    private fun loadSettings() {
        _wallpaperEnabled.value = prefs.getBoolean("wallpaper_enabled", true)
        _currentWallpaper.value = prefs.getString("current_wallpaper", "") ?: ""
    }
    
    /**
     * 保存当前壁纸
     */
    private fun saveCurrentWallpaper(wallpaperName: String) {
        prefs.edit().putString("current_wallpaper", wallpaperName).apply()
    }
    
    // 天气条件判断辅助方法
    private fun isSunnyWeather(condition: String, code: Int): Boolean {
        return condition.contains("晴") || condition.contains("sunny") || 
               condition.contains("clear") || code == 1000
    }
    
    private fun isClearWeather(condition: String, code: Int): Boolean {
        return isSunnyWeather(condition, code)
    }
    
    private fun isCloudyWeather(condition: String, code: Int): Boolean {
        return condition.contains("多云") || condition.contains("cloudy") ||
               condition.contains("部分") || code in 1003..1009
    }
    
    private fun isRainyWeather(condition: String, code: Int): Boolean {
        return condition.contains("雨") || condition.contains("rain") ||
               condition.contains("drizzle") || code in 1063..1201
    }
    
    private fun isStormyWeather(condition: String, code: Int): Boolean {
        return condition.contains("雷") || condition.contains("storm") ||
               condition.contains("thunder") || code in 1273..1282
    }
    
    private fun isSnowyWeather(condition: String, code: Int): Boolean {
        return condition.contains("雪") || condition.contains("snow") ||
               condition.contains("blizzard") || code in 1204..1282
    }
    
    private fun isFoggyWeather(condition: String, code: Int): Boolean {
        return condition.contains("雾") || condition.contains("fog") ||
               condition.contains("mist") || code in listOf(1030, 1135, 1147)
    }
    
    companion object {
        @Volatile
        private var INSTANCE: WeatherWallpaperManager? = null
        
        fun getInstance(context: Context): WeatherWallpaperManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: WeatherWallpaperManager(context.applicationContext).also { INSTANCE = it }
            }
        }
    }
}