package com.yunqiao.sinan.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.shared.WeatherMode
import com.yunqiao.sinan.shared.WeatherSystemStatus
import com.yunqiao.sinan.ui.theme.GlassColors
import com.yunqiao.sinan.weather.WeatherEffectManager

@OptIn(ExperimentalMaterial3Api::class)

@Composable
fun WeatherCenterScreen(
    modifier: Modifier = Modifier
) {
    val weatherManager = remember { WeatherEffectManager.getInstance() }
    val weatherStatus by weatherManager.weatherStatus.collectAsState()
    
    LaunchedEffect(Unit) {
        weatherManager.initialize()
    }
    
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(
                color = Color.Transparent,
                shape = RoundedCornerShape(16.dp)
            )
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp)
    ) {
        // 标题区域
        WeatherHeader()
        
        // 天气状态卡片
        WeatherStatusCard(
            weatherStatus = weatherStatus,
            onModeChange = { mode ->
                weatherManager.setWeatherMode(mode)
            }
        )
        
        // 天气数据卡片
        WeatherDataCard(weatherStatus = weatherStatus)
        
        // 天气控制面板
        WeatherControlPanel(
            weatherStatus = weatherStatus,
            onStatusUpdate = { status ->
                weatherManager.updateWeatherStatus(status)
            }
        )
    }
}

@Composable
fun WeatherHeader() {
    Row(
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = Icons.Default.Cloud,
            contentDescription = "天气中心",
            tint = Color.White,
            modifier = Modifier.size(32.dp)
        )
        
        Spacer(modifier = Modifier.width(16.dp))
        
        Column {
            Text(
                text = "天气中心",
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            
            Text(
                text = "实时天气监控与控制",
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
        }
    }
}

@Composable
fun WeatherStatusCard(
    weatherStatus: WeatherSystemStatus,
    onModeChange: (WeatherMode) -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = GlassColors.background
        ),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                text = "系统状态",
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White
            )
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = if (weatherStatus.isActive) Icons.Default.CheckCircle else Icons.Default.Cancel,
                        contentDescription = null,
                        tint = if (weatherStatus.isActive) Color.Green else Color.Red,
                        modifier = Modifier.size(20.dp)
                    )
                    
                    Spacer(modifier = Modifier.width(8.dp))
                    
                    Text(
                        text = if (weatherStatus.isActive) "系统激活" else "系统停止",
                        color = Color.White,
                        fontSize = 16.sp
                    )
                }
                
                // 天气模式选择
                WeatherModeSelector(
                    currentMode = weatherStatus.currentMode,
                    onModeChange = onModeChange
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WeatherModeSelector(
    currentMode: WeatherMode,
    onModeChange: (WeatherMode) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    
    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = !expanded }
    ) {
        OutlinedTextField(
            value = when (currentMode) {
                WeatherMode.AUTO -> "自动模式"
                WeatherMode.MANUAL -> "手动模式" 
                WeatherMode.SIMULATION -> "模拟模式"
                WeatherMode.DISABLED -> "已禁用"
            },
            onValueChange = {},
            readOnly = true,
            trailingIcon = {
                ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded)
            },
            modifier = Modifier.menuAnchor(),
            colors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = Color.White,
                unfocusedTextColor = Color.White,
                focusedBorderColor = GlassColors.highlight,
                unfocusedBorderColor = Color.White.copy(alpha = 0.3f)
            )
        )
        
        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false }
        ) {
            WeatherMode.values().forEach { mode ->
                DropdownMenuItem(
                    text = {
                        Text(
                            text = when (mode) {
                                WeatherMode.AUTO -> "自动模式"
                                WeatherMode.MANUAL -> "手动模式"
                                WeatherMode.SIMULATION -> "模拟模式"
                                WeatherMode.DISABLED -> "已禁用"
                            },
                            color = Color.White
                        )
                    },
                    onClick = {
                        onModeChange(mode)
                        expanded = false
                    }
                )
            }
        }
    }
}

@Composable
fun WeatherDataCard(
    weatherStatus: WeatherSystemStatus
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = GlassColors.background
        ),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                text = "实时数据",
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White
            )
            
            // 数据网格
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                WeatherDataItem(
                    icon = Icons.Default.Thermostat,
                    label = "温度",
                    value = "${weatherStatus.temperature}°C"
                )
                
                WeatherDataItem(
                    icon = Icons.Default.WaterDrop,
                    label = "湿度",
                    value = "${weatherStatus.humidity}%"
                )
                
                WeatherDataItem(
                    icon = Icons.Default.Compress,
                    label = "气压",
                    value = "${weatherStatus.pressure} hPa"
                )
                
                WeatherDataItem(
                    icon = Icons.Default.Visibility,
                    label = "能见度",
                    value = "${weatherStatus.visibility} km"
                )
            }
        }
    }
}

@Composable
fun WeatherDataItem(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    value: String
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = GlassColors.highlight,
            modifier = Modifier.size(24.dp)
        )
        
        Text(
            text = label,
            fontSize = 12.sp,
            color = Color.White.copy(alpha = 0.7f)
        )
        
        Text(
            text = value,
            fontSize = 16.sp,
            fontWeight = FontWeight.Medium,
            color = Color.White
        )
    }
}

@Composable
fun WeatherControlPanel(
    weatherStatus: WeatherSystemStatus,
    onStatusUpdate: (WeatherSystemStatus) -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = GlassColors.background
        ),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                text = "控制面板",
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White
            )
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Button(
                    onClick = {
                        onStatusUpdate(weatherStatus.copy(isActive = !weatherStatus.isActive))
                    },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (weatherStatus.isActive) Color.Red.copy(alpha = 0.8f) else Color.Green.copy(alpha = 0.8f)
                    )
                ) {
                    Icon(
                        imageVector = if (weatherStatus.isActive) Icons.Default.Stop else Icons.Default.PlayArrow,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    
                    Spacer(modifier = Modifier.width(8.dp))
                    
                    Text(
                        text = if (weatherStatus.isActive) "停止系统" else "启动系统",
                        color = Color.White
                    )
                }
                
                Button(
                    onClick = {
                        // 刷新天气数据
                        onStatusUpdate(
                            weatherStatus.copy(
                                timestamp = System.currentTimeMillis(),
                                temperature = (15..30).random().toFloat(),
                                humidity = (40..80).random().toFloat(),
                                pressure = (990..1030).random().toFloat(),
                                visibility = (5..15).random().toFloat()
                            )
                        )
                    },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = GlassColors.highlight
                    )
                ) {
                    Icon(
                        imageVector = Icons.Default.Refresh,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    
                    Spacer(modifier = Modifier.width(8.dp))
                    
                    Text(
                        text = "刷新数据",
                        color = Color.White
                    )
                }
            }
        }
    }
}