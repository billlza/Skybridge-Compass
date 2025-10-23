package com.yunqiao.sinan.ui.component

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.ui.theme.GlassColors
import com.yunqiao.sinan.weather.WeatherSummary
import kotlinx.coroutines.delay

/**
 * 主界面天气组件
 */
@Composable
fun MainWeatherWidget(
    weatherSummary: WeatherSummary,
    onWeatherClick: () -> Unit,
    modifier: Modifier = Modifier,
    isCompact: Boolean = false
) {
    val weatherIcon = getWeatherIcon(weatherSummary.condition)
    val weatherColor = getWeatherColor(weatherSummary.condition)
    
    Card(
        modifier = modifier
            .clickable { onWeatherClick() }
            .animateContentSize(),
        colors = CardDefaults.cardColors(
            containerColor = GlassColors.background
        ),
        shape = RoundedCornerShape(12.dp),
        elevation = CardDefaults.cardElevation(defaultElevation = 4.dp)
    ) {
        if (isCompact) {
            CompactWeatherDisplay(
                weatherSummary = weatherSummary,
                weatherIcon = weatherIcon,
                weatherColor = weatherColor
            )
        } else {
            ExpandedWeatherDisplay(
                weatherSummary = weatherSummary,
                weatherIcon = weatherIcon,
                weatherColor = weatherColor
            )
        }
    }
}

@Composable
private fun CompactWeatherDisplay(
    weatherSummary: WeatherSummary,
    weatherIcon: ImageVector,
    weatherColor: Color
) {
    Row(
        modifier = Modifier.padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // 天气图标
        Icon(
            imageVector = weatherIcon,
            contentDescription = "天气状态",
            tint = weatherColor,
            modifier = Modifier.size(24.dp)
        )
        
        // 温度
        Text(
            text = "${weatherSummary.temperature.toInt()}°",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = Color.White
        )
        
        // 更新状态指示器
        if (weatherSummary.isUpdating) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = GlassColors.highlight
            )
        }
        
        Spacer(modifier = Modifier.weight(1f))
        
        // 城市名称
        Text(
            text = weatherSummary.cityName,
            fontSize = 12.sp,
            color = Color.White.copy(alpha = 0.7f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun ExpandedWeatherDisplay(
    weatherSummary: WeatherSummary,
    weatherIcon: ImageVector,
    weatherColor: Color
) {
    Column(
        modifier = Modifier.padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // 头部：温度和天气状态
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Icon(
                    imageVector = weatherIcon,
                    contentDescription = "天气状态",
                    tint = weatherColor,
                    modifier = Modifier.size(32.dp)
                )
                
                Column {
                    Text(
                        text = "${weatherSummary.temperature.toInt()}°C",
                        fontSize = 24.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White
                    )
                    
                    Text(
                        text = weatherSummary.condition,
                        fontSize = 14.sp,
                        color = Color.White.copy(alpha = 0.8f)
                    )
                }
            }
            
            // 更新状态和城市
            Column(
                horizontalAlignment = Alignment.End
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    if (weatherSummary.isUpdating) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = GlassColors.highlight
                        )
                    }
                    
                    Text(
                        text = weatherSummary.cityName,
                        fontSize = 14.sp,
                        color = Color.White,
                        fontWeight = FontWeight.Medium
                    )
                }
                
                Text(
                    text = "点击查看详情",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.6f)
                )
            }
        }
        
        // 详细信息
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly
        ) {
            WeatherDetailItem(
                icon = Icons.Default.WaterDrop,
                label = "湿度",
                value = "${weatherSummary.humidity}%"
            )
            
            WeatherDetailItem(
                icon = Icons.Default.Air,
                label = "风速",
                value = "${weatherSummary.windSpeed.toInt()} km/h"
            )
            
            WeatherDetailItem(
                icon = Icons.Default.Eco,
                label = "空气",
                value = weatherSummary.airQuality
            )
        }
        
        // 最后更新时间
        if (weatherSummary.lastUpdate.isNotEmpty()) {
            Text(
                text = "更新时间: ${formatLastUpdate(weatherSummary.lastUpdate)}",
                fontSize = 10.sp,
                color = Color.White.copy(alpha = 0.5f),
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Composable
private fun WeatherDetailItem(
    icon: ImageVector,
    label: String,
    value: String
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = GlassColors.highlight,
            modifier = Modifier.size(18.dp)
        )
        
        Text(
            text = label,
            fontSize = 10.sp,
            color = Color.White.copy(alpha = 0.7f)
        )
        
        Text(
            text = value,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = Color.White
        )
    }
}

/**
 * 获取天气图标
 */
private fun getWeatherIcon(condition: String): ImageVector {
    return when {
        condition.contains("晴", ignoreCase = true) || 
        condition.contains("sunny", ignoreCase = true) -> Icons.Default.WbSunny
        
        condition.contains("多云", ignoreCase = true) || 
        condition.contains("cloudy", ignoreCase = true) -> Icons.Default.Cloud
        
        condition.contains("雨", ignoreCase = true) || 
        condition.contains("rain", ignoreCase = true) -> Icons.Default.Grain
        
        condition.contains("雪", ignoreCase = true) || 
        condition.contains("snow", ignoreCase = true) -> Icons.Default.AcUnit
        
        condition.contains("雷", ignoreCase = true) || 
        condition.contains("storm", ignoreCase = true) -> Icons.Default.Thunderstorm
        
        condition.contains("雾", ignoreCase = true) || 
        condition.contains("fog", ignoreCase = true) -> Icons.Default.Cloud
        
        else -> Icons.Default.Cloud
    }
}

/**
 * 获取天气颜色
 */
private fun getWeatherColor(condition: String): Color {
    return when {
        condition.contains("晴", ignoreCase = true) || 
        condition.contains("sunny", ignoreCase = true) -> Color(0xFFFFB74D)
        
        condition.contains("多云", ignoreCase = true) || 
        condition.contains("cloudy", ignoreCase = true) -> Color(0xFF90A4AE)
        
        condition.contains("雨", ignoreCase = true) || 
        condition.contains("rain", ignoreCase = true) -> Color(0xFF64B5F6)
        
        condition.contains("雪", ignoreCase = true) || 
        condition.contains("snow", ignoreCase = true) -> Color(0xFFE1F5FE)
        
        condition.contains("雷", ignoreCase = true) || 
        condition.contains("storm", ignoreCase = true) -> Color(0xFF7E57C2)
        
        condition.contains("雾", ignoreCase = true) || 
        condition.contains("fog", ignoreCase = true) -> Color(0xFFBDBDBD)
        
        else -> Color(0xFF90A4AE)
    }
}

/**
 * 格式化最后更新时间
 */
private fun formatLastUpdate(lastUpdate: String): String {
    return try {
        // 简单的时间格式化，显示时间部分
        if (lastUpdate.contains(" ")) {
            lastUpdate.split(" ").getOrNull(1) ?: lastUpdate
        } else {
            lastUpdate
        }
    } catch (e: Exception) {
        lastUpdate
    }
}

/**
 * 动画天气背景组件
 */
@Composable
fun AnimatedWeatherBackground(
    condition: String,
    modifier: Modifier = Modifier
) {
    val weatherColor = getWeatherColor(condition)
    
    var animationState by remember { mutableStateOf(0f) }
    
    LaunchedEffect(condition) {
        while (true) {
            animationState = if (animationState == 0f) 1f else 0f
            delay(3000) // 每3秒切换一次
        }
    }
    
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(
                        weatherColor.copy(alpha = 0.1f),
                        weatherColor.copy(alpha = 0.05f),
                        Color.Transparent
                    )
                )
            )
    )
}