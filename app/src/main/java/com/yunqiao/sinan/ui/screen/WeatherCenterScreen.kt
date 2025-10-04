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
import com.yunqiao.sinan.shared.WeatherVisualState
import com.yunqiao.sinan.shared.WeatherRenderingInfo
import com.yunqiao.sinan.shared.WeatherRenderTier
import com.yunqiao.sinan.shared.WeatherEffectType
import com.yunqiao.sinan.ui.theme.GlassColors
import com.yunqiao.sinan.ui.component.WeatherDynamicBackground
import com.yunqiao.sinan.weather.WeatherEffectManager
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)

@Composable
fun WeatherCenterScreen(
    modifier: Modifier = Modifier
) {
    val weatherManager = remember { WeatherEffectManager.getInstance() }
    val weatherStatus by weatherManager.weatherStatus.collectAsState()
    val visualState by weatherManager.visualState.collectAsState()

    LaunchedEffect(Unit) {
        weatherManager.initialize()
    }

    WeatherDynamicBackground(
        visualState = visualState,
        modifier = modifier.fillMaxSize()
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            WeatherHeader(visualState = visualState, weatherStatus = weatherStatus)

            WeatherStatusCard(
                weatherStatus = weatherStatus,
                visualState = visualState,
                onModeChange = { mode ->
                    weatherManager.setWeatherMode(mode)
                }
            )

            WeatherDataCard(weatherStatus = weatherStatus, visualState = visualState)

            WeatherControlPanel(
                weatherStatus = weatherStatus,
                onStatusUpdate = { status ->
                    weatherManager.updateWeatherStatus(status)
                }
            )
        }
    }
}

@Composable
fun WeatherHeader(
    visualState: WeatherVisualState,
    weatherStatus: WeatherSystemStatus
) {
    val accent = Color(visualState.accentColor)

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = Icons.Default.Cloud,
            contentDescription = "天气中心",
            tint = accent,
            modifier = Modifier.size(36.dp)
        )

        Spacer(modifier = Modifier.width(16.dp))

        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text(
                text = "天气中心",
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )

            Text(
                text = buildString {
                    val city = visualState.cityName.ifBlank { weatherStatus.cityName.ifBlank { "定位中" } }
                    append(city)
                    if (visualState.country.isNotBlank()) {
                        append(" · ")
                        append(visualState.country)
                    }
                },
                fontSize = 15.sp,
                color = Color.White.copy(alpha = 0.8f)
            )

            Text(
                text = visualState.conditionLabel.ifBlank { "实时天气监控与控制" },
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
        }

        Spacer(modifier = Modifier.weight(1f))

        Column(
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            WeatherEffectBadge(visualState = visualState)

            Text(
                text = String.format(Locale.getDefault(), "%.1f°C", weatherStatus.temperature),
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold,
                color = accent
            )
        }
    }
}

@Composable
fun WeatherEffectBadge(
    visualState: WeatherVisualState
) {
    val accent = Color(visualState.accentColor)
    Surface(
        color = accent.copy(alpha = 0.18f),
        shape = RoundedCornerShape(999.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(
                imageVector = effectIconFor(visualState.effectType),
                contentDescription = "当前天气效果",
                tint = accent,
                modifier = Modifier.size(18.dp)
            )

            Text(
                text = visualState.effectLabel.ifBlank { "效果同步中" },
                color = Color.White,
                fontSize = 13.sp
            )
        }
    }
}

@Composable
private fun effectIconFor(effectType: WeatherEffectType) = when (effectType) {
    WeatherEffectType.CLEAR -> Icons.Default.WbSunny
    WeatherEffectType.CLOUDY -> Icons.Default.CloudQueue
    WeatherEffectType.RAIN -> Icons.Default.InvertColors
    WeatherEffectType.STORM -> Icons.Default.FlashOn
    WeatherEffectType.SNOW -> Icons.Default.AcUnit
    WeatherEffectType.FOG -> Icons.Default.BlurOn
}

@Composable
fun WeatherStatusCard(
    weatherStatus: WeatherSystemStatus,
    visualState: WeatherVisualState,
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

            Divider(color = Color.White.copy(alpha = 0.08f))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            imageVector = Icons.Default.Place,
                            contentDescription = "城市",
                            tint = Color.White.copy(alpha = 0.8f),
                            modifier = Modifier.size(20.dp)
                        )

                        Spacer(modifier = Modifier.width(8.dp))

                        Text(
                            text = visualState.cityName.ifBlank { weatherStatus.cityName.ifBlank { "定位中" } },
                            color = Color.White,
                            fontSize = 16.sp
                        )
                    }

                    Row(
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            imageVector = Icons.Default.CloudQueue,
                            contentDescription = "天气状况",
                            tint = Color.White.copy(alpha = 0.8f),
                            modifier = Modifier.size(20.dp)
                        )

                        Spacer(modifier = Modifier.width(8.dp))

                        Text(
                            text = visualState.conditionLabel.ifBlank { weatherStatus.conditionLabel.ifBlank { "等待同步" } },
                            color = Color.White.copy(alpha = 0.9f),
                            fontSize = 15.sp
                        )
                    }
                }

                Column(
                    horizontalAlignment = Alignment.End,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Text(
                        text = "效果",
                        color = Color.White.copy(alpha = 0.6f),
                        fontSize = 13.sp
                    )

                    Text(
                        text = visualState.effectLabel.ifBlank { weatherStatus.effectLabel.ifBlank { "待触发" } },
                        color = Color(visualState.accentColor),
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold
                    )

                    Text(
                        text = "更新于 ${formatUpdatedAt(visualState.lastUpdated)}",
                        color = Color.White.copy(alpha = 0.5f),
                        fontSize = 12.sp
                    )
                }
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
    weatherStatus: WeatherSystemStatus,
    visualState: WeatherVisualState
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
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "实时数据",
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White
                )

                Surface(
                    color = Color(visualState.accentColor).copy(alpha = 0.18f),
                    shape = RoundedCornerShape(999.dp)
                ) {
                    Text(
                        text = visualState.effectLabel.ifBlank { weatherStatus.effectLabel.ifBlank { "动态同步" } },
                        color = Color(visualState.accentColor),
                        fontSize = 13.sp,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)
                    )
                }
            }

            Text(
                text = buildString {
                    append(visualState.cityName.ifBlank { weatherStatus.cityName.ifBlank { "未定位" } })
                    if (visualState.conditionLabel.isNotBlank()) {
                        append(" · ")
                        append(visualState.conditionLabel)
                    }
                },
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 14.sp
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

            Divider(color = Color.White.copy(alpha = 0.08f))

            WeatherRenderingCapabilityRow(renderingInfo = visualState.renderingInfo)
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
private fun WeatherRenderingCapabilityRow(renderingInfo: WeatherRenderingInfo) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(
            text = "渲染能力",
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color.White
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            RenderingCapabilityChip(
                icon = Icons.Default.HdrStrong,
                label = if (renderingInfo.hdrEnabled) "${renderingInfo.hdrColorSpace} HDR" else "SDR",
                value = String.format(Locale.getDefault(), "%.0f nits", renderingInfo.hdrTargetNits)
            )

            RenderingCapabilityChip(
                icon = Icons.Default.AutoAwesome,
                label = if (renderingInfo.rayTracingEnabled) renderingInfo.rayTracingPipeline else "光追关闭",
                value = if (renderingInfo.optimizationHint.isNotBlank()) renderingInfo.optimizationHint else "标准模式"
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            RenderingCapabilityChip(
                icon = Icons.Default.ElectricBolt,
                label = tierLabel(renderingInfo.deviceTier),
                value = if (renderingInfo.socVendor.isNotBlank()) renderingInfo.socVendor else "通用芯片"
            )

            RenderingCapabilityChip(
                icon = Icons.Default.Tune,
                label = "调校倍率",
                value = buildString {
                    append(String.format(Locale.getDefault(), "细节 %.2fx", renderingInfo.shadingBoost))
                    append(" · ")
                    append(String.format(Locale.getDefault(), "反射 %.2fx", renderingInfo.reflectionStrength))
                }
            )
        }
    }
}

@Composable
private fun RenderingCapabilityChip(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    value: String
) {
    Surface(
        color = Color.White.copy(alpha = 0.08f),
        shape = RoundedCornerShape(14.dp)
    ) {
        Column(
            modifier = Modifier
                .widthIn(min = 0.dp)
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = label,
                    tint = GlassColors.highlight,
                    modifier = Modifier.size(18.dp)
                )

                Text(
                    text = label,
                    fontSize = 13.sp,
                    color = Color.White.copy(alpha = 0.9f)
                )
            }

            Text(
                text = value,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = Color.White
            )
        }
    }
}

private fun tierLabel(tier: WeatherRenderTier): String {
    return when (tier) {
        WeatherRenderTier.STANDARD -> "标准模式"
        WeatherRenderTier.ADVANCED -> "增强模式"
        WeatherRenderTier.ELITE -> "旗舰模式"
    }
}

private fun formatUpdatedAt(timestamp: Long): String {
    if (timestamp <= 0L) return "等待同步"
    return try {
        val formatter = SimpleDateFormat("HH:mm", Locale.getDefault())
        formatter.format(Date(timestamp))
    } catch (_: Exception) {
        "刚刚"
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