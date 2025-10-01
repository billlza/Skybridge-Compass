package com.yunqiao.sinan.manager

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.drawable.Drawable
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.*

/**
 * 权限状态枚举
 */
enum class PermissionStatus {
    UNKNOWN,
    GRANTED,
    DENIED,
    PARTIALLY_GRANTED
}

/**
 * 天气管理器 - 集成真实天气API和智能壁纸切换
 */
data class WeatherInfo(
    val temperature: Float = 0f,
    val humidity: Int = 0,
    val pressure: Float = 0f,
    val windSpeed: Float = 0f,
    val windDirection: Int = 0,
    val visibility: Float = 0f,
    val uvIndex: Int = 0,
    val condition: String = "Unknown",
    val conditionCode: Int = 0,
    val cityName: String = "Unknown",
    val country: String = "Unknown",
    val localTime: String = "",
    val sunrise: String = "",
    val sunset: String = "",
    val forecast: List<ForecastDay> = emptyList(),
    val airQuality: AirQuality? = null
)

data class ForecastDay(
    val date: String,
    val maxTemp: Float,
    val minTemp: Float,
    val condition: String,
    val conditionCode: Int,
    val chanceOfRain: Int,
    val humidity: Int,
    val windSpeed: Float
)

data class AirQuality(
    val co: Float,           // 一氧化碳
    val no2: Float,          // 二氧化氮
    val o3: Float,           // 臭氧
    val so2: Float,          // 二氧化硫
    val pm2_5: Float,        // PM2.5
    val pm10: Float,         // PM10
    val aqi: Int,            // 空气质量指数
    val quality: String      // 空气质量等级
)

data class LocationInfo(
    val latitude: Double = 0.0,
    val longitude: Double = 0.0,
    val city: String = "Unknown",
    val country: String = "Unknown",
    val accuracy: Float = 0f
)

class WeatherManager(private val context: Context) {
    
    // 使用免费的OpenWeatherMap API服务
    private fun getWeatherApiKey(): String {
        val sharedPrefs = context.getSharedPreferences("weather_settings", Context.MODE_PRIVATE)
        val apiKey = sharedPrefs.getString("weather_api_key", "") ?: ""
        return if (apiKey.isNotEmpty()) apiKey else "demo_api_key"
    }
    
    // 支持多种免费天气API
    private val openWeatherMapBaseUrl = "https://api.openweathermap.org/data/2.5"
    private val weatherApiBaseUrl = "https://api.weatherapi.com/v1"
    
    private val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    
    private val _weatherInfo = MutableStateFlow(WeatherInfo())
    val weatherInfo: StateFlow<WeatherInfo> = _weatherInfo.asStateFlow()
    
    private val _locationInfo = MutableStateFlow(LocationInfo())
    val locationInfo: StateFlow<LocationInfo> = _locationInfo.asStateFlow()
    
    private val _isUpdating = MutableStateFlow(false)
    val isUpdating: StateFlow<Boolean> = _isUpdating.asStateFlow()
    
    private val _weatherEnabled = MutableStateFlow(true)
    val weatherEnabled: StateFlow<Boolean> = _weatherEnabled.asStateFlow()
    
    private var updateJob: Job? = null
    private var locationListener: LocationListener? = null
    private var isInitialized = false
    
    // 权限状态验证
    private val _permissionStatus = MutableStateFlow(PermissionStatus.UNKNOWN)
    val permissionStatus: StateFlow<PermissionStatus> = _permissionStatus.asStateFlow()
    
    // 壁纸资源映射
    private val weatherWallpapers = mapOf(
        "sunny" to listOf("sunny_day_1", "sunny_day_2", "sunny_day_3"),
        "cloudy" to listOf("cloudy_1", "cloudy_2", "cloudy_3"),
        "rainy" to listOf("rainy_1", "rainy_2", "rainy_3"),
        "snow" to listOf("snow_1", "snow_2", "snow_3"),
        "storm" to listOf("storm_1", "storm_2"),
        "fog" to listOf("fog_1", "fog_2"),
        "night" to listOf("night_1", "night_2", "night_3"),
        "sunset" to listOf("sunset_1", "sunset_2"),
        "sunrise" to listOf("sunrise_1", "sunrise_2")
    )
    
    // 移除init块中的自动启动，改为手动初始化
    init {
        // 仅进行基础状态初始化，不启动服务
        checkPermissionStatus()
    }
    
    /**
     * 权限状态检查
     */
    private fun checkPermissionStatus() {
        val locationPermission = ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        
        val coarseLocationPermission = ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        
        _permissionStatus.value = when {
            locationPermission && coarseLocationPermission -> PermissionStatus.GRANTED
            locationPermission || coarseLocationPermission -> PermissionStatus.PARTIALLY_GRANTED
            else -> PermissionStatus.DENIED
        }
    }
    
    /**
     * 安全初始化 - 在权限验证后调用
     */
    fun initializeWithPermissions(): Boolean {
        if (isInitialized) return true
        
        checkPermissionStatus()
        
        return when (_permissionStatus.value) {
            PermissionStatus.GRANTED, PermissionStatus.PARTIALLY_GRANTED -> {
                if (_weatherEnabled.value) {
                    startWeatherUpdates()
                }
                isInitialized = true
                true
            }
            else -> {
                // 权限不足时使用模拟数据
                CoroutineScope(Dispatchers.IO).launch {
                    updateWithMockData()
                }
                isInitialized = true
                false
            }
        }
    }
    
    /**
     * 重新检查权限并初始化
     */
    fun recheckPermissionsAndInitialize(): Boolean {
        isInitialized = false
        return initializeWithPermissions()
    }
    
    /**
     * 启动天气更新
     */
    fun startWeatherUpdates(intervalMinutes: Long = 30) {
        if (updateJob?.isActive == true) return
        
        updateJob = CoroutineScope(Dispatchers.IO).launch {
            while (_weatherEnabled.value) {
                try {
                    updateLocation()
                    delay(5000) // 等待位置更新
                    
                    val location = _locationInfo.value
                    if (location.latitude != 0.0 && location.longitude != 0.0) {
                        updateWeatherData(location.latitude, location.longitude)
                        
                        // 更新壁纸
                        updateWeatherWallpaper()
                    }
                    
                    delay(intervalMinutes * 60 * 1000) // 间隔更新
                } catch (e: Exception) {
                    e.printStackTrace()
                    delay(60000) // 出错时1分钟后重试
                }
            }
        }
    }
    
    /**
     * 停止天气更新
     */
    fun stopWeatherUpdates() {
        updateJob?.cancel()
        stopLocationUpdates()
    }
    
    /**
     * 启用/禁用天气功能
     */
    fun setWeatherEnabled(enabled: Boolean) {
        _weatherEnabled.value = enabled
        if (enabled) {
            startWeatherUpdates()
        } else {
            stopWeatherUpdates()
        }
    }
    
    /**
     * 更新位置信息
     */
    private suspend fun updateLocation() = withContext(Dispatchers.Main) {
        if (!hasLocationPermission()) {
            return@withContext
        }
        
        try {
            val isGpsEnabled = locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)
            val isNetworkEnabled = locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            
            if (!isGpsEnabled && !isNetworkEnabled) {
                return@withContext
            }
            
            locationListener = object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    CoroutineScope(Dispatchers.IO).launch {
                        val cityInfo = getCityFromCoordinates(location.latitude, location.longitude)
                        
                        _locationInfo.value = LocationInfo(
                            latitude = location.latitude,
                            longitude = location.longitude,
                            city = cityInfo.first,
                            country = cityInfo.second,
                            accuracy = location.accuracy
                        )
                    }
                    
                    // 获取到位置后停止监听
                    stopLocationUpdates()
                }
                
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {}
            }
            
            val provider = when {
                isGpsEnabled -> LocationManager.GPS_PROVIDER
                isNetworkEnabled -> LocationManager.NETWORK_PROVIDER
                else -> return@withContext
            }
            
            if (ActivityCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_FINE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                locationManager.requestLocationUpdates(
                    provider,
                    10000L, // 10秒
                    100f,   // 100米
                    locationListener!!
                )
                
                // 尝试获取最后已知位置
                val lastKnownLocation = locationManager.getLastKnownLocation(provider)
                lastKnownLocation?.let { location ->
                    locationListener?.onLocationChanged(location)
                }
            }
            
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 停止位置更新
     */
    private fun stopLocationUpdates() {
        locationListener?.let { listener ->
            if (ActivityCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_FINE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                locationManager.removeUpdates(listener)
            }
        }
        locationListener = null
    }
    
    /**
     * 通过坐标获取城市信息
     */
    private suspend fun getCityFromCoordinates(lat: Double, lon: Double): Pair<String, String> = withContext(Dispatchers.IO) {
        try {
            val apiKey = getWeatherApiKey()
            
            if (apiKey == "demo_api_key" || apiKey.isEmpty()) {
                return@withContext Pair("演示城市", "中国")
            }
            
            // 尝试使用OpenWeatherMap的反向地理编码（免费）
            if (apiKey.length == 32) {
                val url = "$openWeatherMapBaseUrl/weather?lat=$lat&lon=$lon&appid=$apiKey"
                val connection = URL(url).openConnection() as HttpURLConnection
                connection.requestMethod = "GET"
                connection.connectTimeout = 10000
                connection.readTimeout = 10000
                
                val response = connection.inputStream.bufferedReader().readText()
                val jsonObject = JSONObject(response)
                
                val city = jsonObject.optString("name", "Unknown")
                val country = jsonObject.optJSONObject("sys")?.optString("country", "Unknown") ?: "Unknown"
                
                return@withContext Pair(city, country)
            } else {
                // 使用WeatherAPI的搜索功能
                val url = "$weatherApiBaseUrl/search.json?key=$apiKey&q=$lat,$lon"
                val connection = URL(url).openConnection() as HttpURLConnection
                connection.requestMethod = "GET"
                connection.connectTimeout = 10000
                connection.readTimeout = 10000
                
                val response = connection.inputStream.bufferedReader().readText()
                val jsonArray = org.json.JSONArray(response)
                
                if (jsonArray.length() > 0) {
                    val location = jsonArray.getJSONObject(0)
                    val city = location.getString("name")
                    val country = location.getString("country")
                    return@withContext Pair(city, country)
                }
            }
            
        } catch (e: Exception) {
            e.printStackTrace()
        }
        
        return@withContext Pair("Unknown", "Unknown")
    }
    
    /**
     * 更新天气数据
     */
    private suspend fun updateWeatherData(lat: Double, lon: Double) = withContext(Dispatchers.IO) {
        val apiKey = getWeatherApiKey()
        
        if (apiKey == "demo_api_key" || apiKey.isEmpty()) {
            // 使用模拟数据进行演示
            updateWithMockData()
            return@withContext
        }
        
        _isUpdating.value = true
        
        try {
            // 尝试使用OpenWeatherMap API（更常用的免费API）
            if (apiKey.length == 32) { // OpenWeatherMap API key length
                updateWithOpenWeatherMap(lat, lon, apiKey)
            } else {
                // 使用WeatherAPI
                updateWithWeatherAPI(lat, lon, apiKey)
            }
            
        } catch (e: Exception) {
            e.printStackTrace()
            // 发生错误时使用模拟数据
            updateWithMockData()
        } finally {
            _isUpdating.value = false
        }
    }
    
    /**
     * 使用OpenWeatherMap API获取天气数据
     */
    private suspend fun updateWithOpenWeatherMap(lat: Double, lon: Double, apiKey: String) {
        try {
            // 获取当前天气
            val currentWeatherUrl = "$openWeatherMapBaseUrl/weather?lat=$lat&lon=$lon&appid=$apiKey&units=metric&lang=zh_cn"
            val currentWeatherData = fetchWeatherData(currentWeatherUrl)
            
            // 获取5天天气预报
            val forecastUrl = "$openWeatherMapBaseUrl/forecast?lat=$lat&lon=$lon&appid=$apiKey&units=metric&lang=zh_cn"
            val forecastData = fetchWeatherData(forecastUrl)
            
            // 解析OpenWeatherMap数据
            val weatherInfo = parseOpenWeatherMapData(currentWeatherData, forecastData)
            _weatherInfo.value = weatherInfo
            
        } catch (e: Exception) {
            e.printStackTrace()
            throw e
        }
    }
    
    /**
     * 使用WeatherAPI获取天气数据
     */
    private suspend fun updateWithWeatherAPI(lat: Double, lon: Double, apiKey: String) {
        try {
            // 获取当前天气
            val currentWeatherUrl = "$weatherApiBaseUrl/current.json?key=$apiKey&q=$lat,$lon&aqi=yes"
            val currentWeatherData = fetchWeatherData(currentWeatherUrl)
            
            // 获取天气预报
            val forecastUrl = "$weatherApiBaseUrl/forecast.json?key=$apiKey&q=$lat,$lon&days=7&aqi=yes"
            val forecastData = fetchWeatherData(forecastUrl)
            
            // 解析天气数据
            val weatherInfo = parseWeatherData(currentWeatherData, forecastData)
            _weatherInfo.value = weatherInfo
            
        } catch (e: Exception) {
            e.printStackTrace()
            throw e
        }
    }
    
    /**
     * 解析OpenWeatherMap数据
     */
    private fun parseOpenWeatherMapData(currentData: JSONObject, forecastData: JSONObject): WeatherInfo {
        try {
            val main = currentData.getJSONObject("main")
            val weather = currentData.getJSONArray("weather").getJSONObject(0)
            val wind = currentData.optJSONObject("wind")
            val sys = currentData.optJSONObject("sys")
            
            // 解析预报数据
            val forecast = mutableListOf<ForecastDay>()
            if (forecastData.has("list")) {
                val forecastList = forecastData.getJSONArray("list")
                val dailyForecasts = mutableMapOf<String, MutableList<JSONObject>>()
                
                // 按日期分组
                for (i in 0 until forecastList.length()) {
                    val item = forecastList.getJSONObject(i)
                    val dateTime = item.getString("dt_txt")
                    val date = dateTime.split(" ")[0]
                    
                    if (!dailyForecasts.containsKey(date)) {
                        dailyForecasts[date] = mutableListOf()
                    }
                    dailyForecasts[date]?.add(item)
                }
                
                // 处理每日预报
                dailyForecasts.entries.take(5).forEach { (date, dayData) ->
                    val maxTemp = dayData.maxOf { it.getJSONObject("main").getDouble("temp_max") }.toFloat()
                    val minTemp = dayData.minOf { it.getJSONObject("main").getDouble("temp_min") }.toFloat()
                    val avgHumidity = dayData.map { it.getJSONObject("main").getInt("humidity") }.average().toInt()
                    
                    // 取中午时段的天气状态
                    val midDayWeather = dayData.find { 
                        it.getString("dt_txt").contains("12:00:00") 
                    } ?: dayData.first()
                    
                    val weatherInfo = midDayWeather.getJSONArray("weather").getJSONObject(0)
                    val windInfo = midDayWeather.optJSONObject("wind")
                    
                    forecast.add(
                        ForecastDay(
                            date = date,
                            maxTemp = maxTemp,
                            minTemp = minTemp,
                            condition = weatherInfo.getString("description"),
                            conditionCode = weatherInfo.getInt("id"),
                            chanceOfRain = 0, // OpenWeatherMap免费版本不提供降雨概率
                            humidity = avgHumidity,
                            windSpeed = windInfo?.optDouble("speed", 0.0)?.toFloat()?.times(3.6f) ?: 0f // m/s转为km/h
                        )
                    )
                }
            }
            
            return WeatherInfo(
                temperature = main.getDouble("temp").toFloat(),
                humidity = main.getInt("humidity"),
                pressure = main.getDouble("pressure").toFloat(),
                windSpeed = wind?.optDouble("speed", 0.0)?.toFloat()?.times(3.6f) ?: 0f, // m/s转为km/h
                windDirection = wind?.optInt("deg", 0) ?: 0,
                visibility = currentData.optDouble("visibility", 10000.0).toFloat() / 1000f, // 米转为公里
                uvIndex = 0, // 免费版本不提供UV指数
                condition = weather.getString("description"),
                conditionCode = weather.getInt("id"),
                cityName = currentData.getString("name"),
                country = sys?.optString("country", "Unknown") ?: "Unknown",
                localTime = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date()),
                sunrise = formatUnixTime(sys?.optLong("sunrise", 0) ?: 0),
                sunset = formatUnixTime(sys?.optLong("sunset", 0) ?: 0),
                forecast = forecast,
                airQuality = null // 免费版本不提供空气质量数据
            )
            
        } catch (e: Exception) {
            e.printStackTrace()
            return WeatherInfo()
        }
    }
    
    /**
     * 格式化Unix时间戳为时间字符串
     */
    private fun formatUnixTime(timestamp: Long): String {
        return if (timestamp > 0) {
            SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(timestamp * 1000))
        } else {
            ""
        }
    }
    
    /**
     * 获取天气数据
     */
    private suspend fun fetchWeatherData(url: String): JSONObject = withContext(Dispatchers.IO) {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connectTimeout = 15000
        connection.readTimeout = 15000
        connection.setRequestProperty("User-Agent", "YunQiaoSiNan/1.0")
        
        val response = connection.inputStream.bufferedReader().readText()
        JSONObject(response)
    }
    
    /**
     * 解析天气数据
     */
    private fun parseWeatherData(currentData: JSONObject, forecastData: JSONObject): WeatherInfo {
        try {
            val location = currentData.getJSONObject("location")
            val current = currentData.getJSONObject("current")
            val condition = current.getJSONObject("condition")
            
            // 解析空气质量
            val airQualityData = if (current.has("air_quality")) {
                val aq = current.getJSONObject("air_quality")
                AirQuality(
                    co = aq.optDouble("co", 0.0).toFloat(),
                    no2 = aq.optDouble("no2", 0.0).toFloat(),
                    o3 = aq.optDouble("o3", 0.0).toFloat(),
                    so2 = aq.optDouble("so2", 0.0).toFloat(),
                    pm2_5 = aq.optDouble("pm2_5", 0.0).toFloat(),
                    pm10 = aq.optDouble("pm10", 0.0).toFloat(),
                    aqi = aq.optInt("us-epa-index", 0),
                    quality = getAirQualityLevel(aq.optInt("us-epa-index", 0))
                )
            } else null
            
            // 解析预报数据
            val forecast = mutableListOf<ForecastDay>()
            if (forecastData.has("forecast")) {
                val forecastDays = forecastData.getJSONObject("forecast").getJSONArray("forecastday")
                for (i in 0 until forecastDays.length()) {
                    val day = forecastDays.getJSONObject(i)
                    val dayData = day.getJSONObject("day")
                    val dayCondition = dayData.getJSONObject("condition")
                    
                    forecast.add(
                        ForecastDay(
                            date = day.getString("date"),
                            maxTemp = dayData.getDouble("maxtemp_c").toFloat(),
                            minTemp = dayData.getDouble("mintemp_c").toFloat(),
                            condition = dayCondition.getString("text"),
                            conditionCode = dayCondition.getInt("code"),
                            chanceOfRain = dayData.optInt("daily_chance_of_rain", 0),
                            humidity = dayData.optInt("avghumidity", 0),
                            windSpeed = dayData.optDouble("maxwind_kph", 0.0).toFloat()
                        )
                    )
                }
            }
            
            // 解析日出日落时间
            val astronomy = if (forecastData.has("forecast") && 
                             forecastData.getJSONObject("forecast").getJSONArray("forecastday").length() > 0) {
                forecastData.getJSONObject("forecast")
                    .getJSONArray("forecastday")
                    .getJSONObject(0)
                    .getJSONObject("astro")
            } else null
            
            return WeatherInfo(
                temperature = current.getDouble("temp_c").toFloat(),
                humidity = current.getInt("humidity"),
                pressure = current.getDouble("pressure_mb").toFloat(),
                windSpeed = current.getDouble("wind_kph").toFloat(),
                windDirection = current.getInt("wind_degree"),
                visibility = current.getDouble("vis_km").toFloat(),
                uvIndex = current.optInt("uv", 0),
                condition = condition.getString("text"),
                conditionCode = condition.getInt("code"),
                cityName = location.getString("name"),
                country = location.getString("country"),
                localTime = location.getString("localtime"),
                sunrise = astronomy?.optString("sunrise", "") ?: "",
                sunset = astronomy?.optString("sunset", "") ?: "",
                forecast = forecast,
                airQuality = airQualityData
            )
            
        } catch (e: Exception) {
            e.printStackTrace()
            return WeatherInfo()
        }
    }
    
    /**
     * 使用模拟数据（用于演示）
     */
    private fun updateWithMockData() {
        val mockWeather = WeatherInfo(
            temperature = 22.5f,
            humidity = 65,
            pressure = 1013.2f,
            windSpeed = 12.5f,
            windDirection = 180,
            visibility = 10.0f,
            uvIndex = 5,
            condition = "部分多云",
            conditionCode = 1003,
            cityName = "北京",
            country = "中国",
            localTime = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date()),
            sunrise = "06:30",
            sunset = "18:45",
            forecast = listOf(
                ForecastDay("2025-09-23", 25f, 18f, "晴天", 1000, 10, 60, 8f),
                ForecastDay("2025-09-24", 23f, 16f, "多云", 1003, 30, 70, 12f),
                ForecastDay("2025-09-25", 20f, 14f, "小雨", 1183, 80, 85, 15f)
            ),
            airQuality = AirQuality(
                co = 0.3f, no2 = 25f, o3 = 45f, so2 = 8f,
                pm2_5 = 12f, pm10 = 18f, aqi = 2, quality = "良好"
            )
        )
        
        _weatherInfo.value = mockWeather
    }
    
    /**
     * 更新天气壁纸
     */
    private fun updateWeatherWallpaper() {
        try {
            val weather = _weatherInfo.value
            val wallpaperCategory = determineWallpaperCategory(weather)
            val wallpaperList = weatherWallpapers[wallpaperCategory] ?: return
            
            // 随机选择壁纸
            val randomWallpaper = wallpaperList.random()
            
            // 应用壁纸
            applyWallpaper(randomWallpaper)
            
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 确定壁纸类别
     */
    private fun determineWallpaperCategory(weather: WeatherInfo): String {
        val currentTime = Calendar.getInstance()
        val hour = currentTime.get(Calendar.HOUR_OF_DAY)
        
        return when {
            // 夜间 (22:00 - 06:00)
            hour >= 22 || hour <= 6 -> "night"
            
            // 日出时间 (06:00 - 08:00)
            hour in 6..8 -> "sunrise"
            
            // 日落时间 (17:00 - 19:00)
            hour in 17..19 -> "sunset"
            
            // 根据天气条件选择
            else -> when (weather.conditionCode) {
                1000 -> "sunny"           // 晴天
                1003, 1006, 1009 -> "cloudy"  // 多云
                in 1063..1201 -> "rainy"      // 雨天
                in 1204..1282 -> "snow"       // 雪天
                in 1273..1282 -> "storm"      // 雷暴
                1030, 1135, 1147 -> "fog"     // 雾天
                else -> "cloudy"
            }
        }
    }
    
    /**
     * 应用壁纸
     */
    private fun applyWallpaper(wallpaperName: String) {
        try {
            // 获取壁纸资源ID
            val resourceId = context.resources.getIdentifier(
                wallpaperName, "drawable", context.packageName
            )
            
            if (resourceId != 0) {
                // 这里可以通过回调或事件通知UI更新壁纸
                // 例如：发送广播或更新SharedPreferences
                val sharedPrefs = context.getSharedPreferences("weather_settings", Context.MODE_PRIVATE)
                sharedPrefs.edit().putString("current_wallpaper", wallpaperName).apply()
            }
            
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    /**
     * 获取空气质量等级
     */
    private fun getAirQualityLevel(aqi: Int): String {
        return when (aqi) {
            1 -> "优秀"
            2 -> "良好"
            3 -> "中等"
            4 -> "不健康(敏感人群)"
            5 -> "不健康"
            6 -> "危险"
            else -> "未知"
        }
    }
    
    /**
     * 检查位置权限
     */
    private fun hasLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED
    }
    
    /**
     * 手动刷新天气
     */
    suspend fun refreshWeather() {
        if (_isUpdating.value) return
        
        val location = _locationInfo.value
        if (location.latitude != 0.0 && location.longitude != 0.0) {
            updateWeatherData(location.latitude, location.longitude)
            updateWeatherWallpaper()
        } else {
            updateLocation()
        }
    }
    
    /**
     * 设置天气API密钥
     */
    fun setWeatherApiKey(apiKey: String) {
        // 这里应该安全地存储API密钥
        val sharedPrefs = context.getSharedPreferences("weather_settings", Context.MODE_PRIVATE)
        sharedPrefs.edit().putString("weather_api_key", apiKey).apply()
    }
    
    /**
     * 获取天气API密钥
     */

    
    /**
     * 获取天气概要
     */
    fun getWeatherSummary(): Map<String, Any> {
        val weather = _weatherInfo.value
        val location = _locationInfo.value
        
        return mapOf(
            "temperature" to weather.temperature,
            "condition" to weather.condition,
            "humidity" to weather.humidity,
            "windSpeed" to weather.windSpeed,
            "city" to weather.cityName,
            "country" to weather.country,
            "uvIndex" to weather.uvIndex,
            "airQuality" to (weather.airQuality?.quality ?: "未知"),
            "isUpdating" to _isUpdating.value,
            "lastUpdate" to weather.localTime,
            "weatherEnabled" to _weatherEnabled.value
        )
    }
}