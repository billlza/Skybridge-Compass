package com.yunqiao.sinan.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.IntOffset
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yunqiao.sinan.manager.SystemMonitorManager
import com.yunqiao.sinan.ui.theme.GlassColors
import kotlin.math.roundToInt

@Composable
fun SystemMonitorScreen(
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val systemMonitor = remember { SystemMonitorManager(context) }
    val systemMetrics by systemMonitor.systemMetrics.collectAsStateWithLifecycle()
    
    // 屏幕配置和方向检测
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val isPortrait = configuration.orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT
    val screenWidthDp = configuration.screenWidthDp.dp
    
    // 动画状态
    val fadeAnimationSpec = remember {
        spring<Float>(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessLow
        )
    }
    
    val slideAnimationSpec = remember {
        spring<IntOffset>(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessLow
        )
    }
    
    // 启动监控
    LaunchedEffect(Unit) {
        systemMonitor.startMonitoring()
    }
    
    // 清理资源
    DisposableEffect(Unit) {
        onDispose {
            systemMonitor.stopMonitoring()
        }
    }
    
    BoxWithConstraints(
        modifier = modifier
            .fillMaxSize()
            .background(
                color = Color.Transparent,
                shape = RoundedCornerShape(16.dp)
            )
            .padding(if (isPortrait) 16.dp else 24.dp)
    ) {
        val availableWidth = maxWidth
        val contentPadding = if (isPortrait) 16.dp else 20.dp
        
        LazyColumn(
            verticalArrangement = Arrangement.spacedBy(if (isPortrait) 16.dp else 20.dp),
            contentPadding = PaddingValues(vertical = 8.dp)
        ) {
            item {
                // 系统概览卡片
                AnimatedVisibility(
                    visible = true,
                    enter = slideInVertically(
                        animationSpec = slideAnimationSpec,
                        initialOffsetY = { -it }
                    ) + fadeIn(animationSpec = fadeAnimationSpec)
                ) {
                    SystemOverviewCard(
                        systemMetrics = systemMetrics,
                        isPortrait = isPortrait,
                        availableWidth = availableWidth
                    )
                }
            }
            
            item {
                // 响应式监控卡片网格
                AnimatedVisibility(
                    visible = true,
                    enter = slideInVertically(
                        animationSpec = slideAnimationSpec,
                        initialOffsetY = { it }
                    ) + fadeIn(
                        animationSpec = tween(300, delayMillis = 100)
                    )
                ) {
                    ResponsiveMonitorCardsGrid(
                        systemMetrics = systemMetrics,
                        isPortrait = isPortrait,
                        availableWidth = availableWidth
                    )
                }
            }
            
            item {
                // 其他系统信息
                AnimatedVisibility(
                    visible = true,
                    enter = slideInVertically(
                        animationSpec = slideAnimationSpec,
                        initialOffsetY = { it }
                    ) + fadeIn(
                        animationSpec = tween(300, delayMillis = 200)
                    )
                ) {
                    SystemInfoGrid(
                        systemMetrics = systemMetrics,
                        isPortrait = isPortrait
                    )
                }
            }
            
            item {
                // 热管理状态
                AnimatedVisibility(
                    visible = true,
                    enter = slideInVertically(
                        animationSpec = slideAnimationSpec,
                        initialOffsetY = { it }
                    ) + fadeIn(
                        animationSpec = tween(300, delayMillis = 300)
                    )
                ) {
                    ThermalStatusCard(
                        thermalState = systemMetrics.thermalState,
                        isPortrait = isPortrait
                    )
                }
            }
        }
    }
}

@Composable
private fun ResponsiveMonitorCardsGrid(
    systemMetrics: com.yunqiao.sinan.manager.SystemMetrics,
    isPortrait: Boolean,
    availableWidth: androidx.compose.ui.unit.Dp
) {
    val cardData = remember(systemMetrics) {
        listOf(
            CardData.CPU(systemMetrics.cpuUsage, systemMetrics.cpuTemperature),
            CardData.Memory(systemMetrics.memoryUsage, systemMetrics.memoryUsed, systemMetrics.memoryAvailable),
            CardData.Battery(systemMetrics.batteryLevel, systemMetrics.batteryTemperature),
            CardData.Network(systemMetrics.networkType, systemMetrics.networkSpeed)
        )
    }
    
    if (isPortrait) {
        // 竖屏模式：垂直堆叠布局
        Column(
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            cardData.forEach { data ->
                AnimatedVisibility(
                    visible = true,
                    enter = slideInHorizontally(
                        animationSpec = spring(
                            dampingRatio = Spring.DampingRatioMediumBouncy,
                            stiffness = Spring.StiffnessLow
                        ),
                        initialOffsetX = { -it }
                    ) + fadeIn()
                ) {
                    when (data) {
                        is CardData.CPU -> CPUMonitorCard(
                            cpuUsage = data.usage,
                            cpuTemperature = data.temperature,
                            modifier = Modifier.fillMaxWidth(),
                            isPortrait = isPortrait
                        )
                        is CardData.Memory -> MemoryMonitorCard(
                            memoryUsage = data.usage,
                            memoryUsed = data.used,
                            memoryAvailable = data.available,
                            modifier = Modifier.fillMaxWidth(),
                            isPortrait = isPortrait
                        )
                        is CardData.Battery -> BatteryStatusCard(
                            batteryLevel = data.level,
                            batteryTemperature = data.temperature,
                            modifier = Modifier.fillMaxWidth(),
                            isPortrait = isPortrait
                        )
                        is CardData.Network -> NetworkStatusCard(
                            networkType = data.type,
                            networkSpeed = data.speed,
                            modifier = Modifier.fillMaxWidth(),
                            isPortrait = isPortrait
                        )
                    }
                }
            }
        }
    } else {
        // 横屏模式：网格布局
        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            items(cardData) { data ->
                AnimatedVisibility(
                    visible = true,
                    enter = scaleIn(
                        animationSpec = spring(
                            dampingRatio = Spring.DampingRatioMediumBouncy,
                            stiffness = Spring.StiffnessLow
                        )
                    ) + fadeIn()
                ) {
                    when (data) {
                        is CardData.CPU -> CPUMonitorCard(
                            cpuUsage = data.usage,
                            cpuTemperature = data.temperature,
                            modifier = Modifier.fillMaxWidth(),
                            isPortrait = isPortrait
                        )
                        is CardData.Memory -> MemoryMonitorCard(
                            memoryUsage = data.usage,
                            memoryUsed = data.used,
                            memoryAvailable = data.available,
                            modifier = Modifier.fillMaxWidth(),
                            isPortrait = isPortrait
                        )
                        is CardData.Battery -> BatteryStatusCard(
                            batteryLevel = data.level,
                            batteryTemperature = data.temperature,
                            modifier = Modifier.fillMaxWidth(),
                            isPortrait = isPortrait
                        )
                        is CardData.Network -> NetworkStatusCard(
                            networkType = data.type,
                            networkSpeed = data.speed,
                            modifier = Modifier.fillMaxWidth(),
                            isPortrait = isPortrait
                        )
                    }
                }
            }
        }
    }
}

// 数据类来封装不同类型的卡片数据
private sealed class CardData {
    data class CPU(val usage: Float, val temperature: Float) : CardData()
    data class Memory(val usage: Float, val used: Long, val available: Long) : CardData()
    data class Battery(val level: Int, val temperature: Float) : CardData()
    data class Network(val type: String, val speed: Float) : CardData()
}

@Composable
private fun SystemOverviewCard(
    systemMetrics: com.yunqiao.sinan.manager.SystemMetrics,
    isPortrait: Boolean,
    availableWidth: androidx.compose.ui.unit.Dp
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = GlassColors.surface
        ),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(if (isPortrait) 16.dp else 20.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "系统概览",
                    fontSize = if (isPortrait) 18.sp else 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                Icon(
                    imageVector = Icons.Default.Computer,
                    contentDescription = null,
                    tint = Color(0xFF00E5FF),
                    modifier = Modifier.size(if (isPortrait) 20.dp else 24.dp)
                )
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // 响应式系统指标卡片布局
            val metrics = remember(systemMetrics) {
                listOf(
                    MetricData("CPU", "${systemMetrics.cpuUsage.roundToInt()}%", Icons.Default.Memory, systemMetrics.cpuUsage > 80f),
                    MetricData("内存", "${systemMetrics.memoryUsage.roundToInt()}%", Icons.Default.Storage, systemMetrics.memoryUsage > 80f),
                    MetricData("电池", "${systemMetrics.batteryLevel}%", Icons.Default.BatteryStd, systemMetrics.batteryLevel < 20),
                    MetricData("存储", "${systemMetrics.storageUsage.roundToInt()}%", Icons.Default.Folder, systemMetrics.storageUsage > 90f),
                    MetricData("网络", systemMetrics.networkType, Icons.Default.Wifi, systemMetrics.networkType == "No Connection")
                )
            }
            
            if (isPortrait) {
                // 竖屏模式：使用网格布局
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.height(180.dp)
                ) {
                    items(metrics) { metric ->
                        AnimatedVisibility(
                            visible = true,
                            enter = scaleIn(
                                animationSpec = spring(
                                    dampingRatio = Spring.DampingRatioMediumBouncy,
                                    stiffness = Spring.StiffnessLow
                                )
                            ) + fadeIn()
                        ) {
                            MetricCard(metric, isPortrait = true)
                        }
                    }
                }
            } else {
                // 横屏模式：使用水平滚动
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(metrics) { metric ->
                        AnimatedVisibility(
                            visible = true,
                            enter = slideInHorizontally(
                                animationSpec = spring(
                                    dampingRatio = Spring.DampingRatioMediumBouncy,
                                    stiffness = Spring.StiffnessLow
                                ),
                                initialOffsetX = { it }
                            ) + fadeIn()
                        ) {
                            MetricCard(metric, isPortrait = false)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CPUMonitorCard(
    cpuUsage: Float,
    cpuTemperature: Float,
    modifier: Modifier = Modifier,
    isPortrait: Boolean = true
) {
    Card(
        modifier = modifier,
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(if (isPortrait) 16.dp else 12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "CPU状态",
                    fontSize = if (isPortrait) 16.sp else 14.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                Icon(
                    imageVector = Icons.Default.Memory,
                    contentDescription = null,
                    tint = Color(0xFF00E5FF),
                    modifier = Modifier.size(if (isPortrait) 20.dp else 18.dp)
                )
            }
            
            Spacer(modifier = Modifier.height(if (isPortrait) 12.dp else 8.dp))
            
            // CPU使用率
            Text(
                text = "使用率",
                fontSize = if (isPortrait) 12.sp else 10.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
            
            AnimatedContent(
                targetState = cpuUsage,
                transitionSpec = {
                    slideInVertically { height -> height } + fadeIn() togetherWith
                            slideOutVertically { height -> -height } + fadeOut()
                },
                label = "cpu_usage_animation"
            ) { usage ->
                Text(
                    text = "${usage.roundToInt()}%",
                    fontSize = if (isPortrait) 24.sp else 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (usage > 80f) Color.Red else Color(0xFF00E5FF)
                )
            }
            
            Spacer(modifier = Modifier.height(if (isPortrait) 8.dp else 6.dp))
            
            // CPU温度
            if (cpuTemperature > 0f) {
                Text(
                    text = "温度",
                    fontSize = if (isPortrait) 12.sp else 10.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
                AnimatedContent(
                    targetState = cpuTemperature,
                    transitionSpec = {
                        slideInVertically { height -> height } + fadeIn() togetherWith
                                slideOutVertically { height -> -height } + fadeOut()
                    },
                    label = "cpu_temp_animation"
                ) { temp ->
                    Text(
                        text = "${temp.roundToInt()}°C",
                        fontSize = if (isPortrait) 18.sp else 16.sp,
                        fontWeight = FontWeight.Medium,
                        color = if (temp > 70f) Color.Red else Color.White
                    )
                }
            }
        }
    }
}

@Composable
private fun MemoryMonitorCard(
    memoryUsage: Float,
    memoryUsed: Long,
    memoryAvailable: Long,
    modifier: Modifier = Modifier,
    isPortrait: Boolean = true
) {
    Card(
        modifier = modifier,
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(if (isPortrait) 16.dp else 12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "内存状态",
                    fontSize = if (isPortrait) 16.sp else 14.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                Icon(
                    imageVector = Icons.Default.Storage,
                    contentDescription = null,
                    tint = Color(0xFF4CAF50),
                    modifier = Modifier.size(if (isPortrait) 20.dp else 18.dp)
                )
            }
            
            Spacer(modifier = Modifier.height(if (isPortrait) 12.dp else 8.dp))
            
            // 内存使用率
            Text(
                text = "使用率",
                fontSize = if (isPortrait) 12.sp else 10.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
            
            AnimatedContent(
                targetState = memoryUsage,
                transitionSpec = {
                    slideInVertically { height -> height } + fadeIn() togetherWith
                            slideOutVertically { height -> -height } + fadeOut()
                },
                label = "memory_usage_animation"
            ) { usage ->
                Text(
                    text = "${usage.roundToInt()}%",
                    fontSize = if (isPortrait) 24.sp else 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (usage > 80f) Color.Red else Color(0xFF4CAF50)
                )
            }
            
            Spacer(modifier = Modifier.height(if (isPortrait) 8.dp else 6.dp))
            
            // 内存详情
            AnimatedContent(
                targetState = Pair(memoryUsed, memoryAvailable),
                transitionSpec = {
                    slideInVertically { height -> height } + fadeIn() togetherWith
                            slideOutVertically { height -> -height } + fadeOut()
                },
                label = "memory_details_animation"
            ) { (used, available) ->
                Column {
                    Text(
                        text = "已用: ${formatBytes(used)}",
                        fontSize = if (isPortrait) 12.sp else 10.sp,
                        color = Color.White.copy(alpha = 0.7f)
                    )
                    Text(
                        text = "可用: ${formatBytes(available)}",
                        fontSize = if (isPortrait) 12.sp else 10.sp,
                        color = Color.White.copy(alpha = 0.7f)
                    )
                }
            }
        }
    }
}

@Composable
private fun BatteryStatusCard(
    batteryLevel: Int,
    batteryTemperature: Float,
    modifier: Modifier = Modifier,
    isPortrait: Boolean = true
) {
    Card(
        modifier = modifier,
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(if (isPortrait) 16.dp else 12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "电池状态",
                    fontSize = if (isPortrait) 16.sp else 14.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                AnimatedContent(
                    targetState = batteryLevel,
                    transitionSpec = {
                        scaleIn() + fadeIn() togetherWith scaleOut() + fadeOut()
                    },
                    label = "battery_icon_animation"
                ) { level ->
                    Icon(
                        imageVector = when {
                            level > 75 -> Icons.Default.BatteryFull
                            level > 50 -> Icons.Default.Battery6Bar
                            level > 25 -> Icons.Default.Battery3Bar
                            else -> Icons.Default.Battery1Bar
                        },
                        contentDescription = null,
                        tint = when {
                            level > 50 -> Color(0xFF4CAF50)
                            level > 20 -> Color(0xFFFFC107)
                            else -> Color.Red
                        },
                        modifier = Modifier.size(if (isPortrait) 20.dp else 18.dp)
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(if (isPortrait) 12.dp else 8.dp))
            
            // 电池电量
            Text(
                text = "电量",
                fontSize = if (isPortrait) 12.sp else 10.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
            
            AnimatedContent(
                targetState = batteryLevel,
                transitionSpec = {
                    slideInVertically { height -> height } + fadeIn() togetherWith
                            slideOutVertically { height -> -height } + fadeOut()
                },
                label = "battery_level_animation"
            ) { level ->
                Text(
                    text = "$level%",
                    fontSize = if (isPortrait) 24.sp else 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = when {
                        level > 50 -> Color(0xFF4CAF50)
                        level > 20 -> Color(0xFFFFC107)
                        else -> Color.Red
                    }
                )
            }
            
            Spacer(modifier = Modifier.height(if (isPortrait) 8.dp else 6.dp))
            
            // 电池温度
            if (batteryTemperature > 0f) {
                AnimatedContent(
                    targetState = batteryTemperature,
                    transitionSpec = {
                        slideInVertically { height -> height } + fadeIn() togetherWith
                                slideOutVertically { height -> -height } + fadeOut()
                    },
                    label = "battery_temp_animation"
                ) { temp ->
                    Text(
                        text = "温度: ${temp.roundToInt()}°C",
                        fontSize = if (isPortrait) 12.sp else 10.sp,
                        color = Color.White.copy(alpha = 0.7f)
                    )
                }
            }
        }
    }
}

@Composable
private fun NetworkStatusCard(
    networkType: String,
    networkSpeed: Float,
    modifier: Modifier = Modifier,
    isPortrait: Boolean = true
) {
    Card(
        modifier = modifier,
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(if (isPortrait) 16.dp else 12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "网络状态",
                    fontSize = if (isPortrait) 16.sp else 14.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                AnimatedContent(
                    targetState = networkType,
                    transitionSpec = {
                        scaleIn() + fadeIn() togetherWith scaleOut() + fadeOut()
                    },
                    label = "network_icon_animation"
                ) { type ->
                    Icon(
                        imageVector = when (type) {
                            "WiFi" -> Icons.Default.Wifi
                            "Cellular" -> Icons.Default.SignalCellularAlt
                            else -> Icons.Default.SignalWifiOff
                        },
                        contentDescription = null,
                        tint = if (type == "No Connection") Color.Red else Color(0xFF2196F3),
                        modifier = Modifier.size(if (isPortrait) 20.dp else 18.dp)
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(if (isPortrait) 12.dp else 8.dp))
            
            // 网络类型
            Text(
                text = "类型",
                fontSize = if (isPortrait) 12.sp else 10.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
            
            AnimatedContent(
                targetState = networkType,
                transitionSpec = {
                    slideInVertically { height -> height } + fadeIn() togetherWith
                            slideOutVertically { height -> -height } + fadeOut()
                },
                label = "network_type_animation"
            ) { type ->
                Text(
                    text = type,
                    fontSize = if (isPortrait) 18.sp else 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (type == "No Connection") Color.Red else Color(0xFF2196F3)
                )
            }
            
            Spacer(modifier = Modifier.height(if (isPortrait) 8.dp else 6.dp))
            
            // 网络速度（如果有的话）
            if (networkSpeed > 0f) {
                AnimatedContent(
                    targetState = networkSpeed,
                    transitionSpec = {
                        slideInVertically { height -> height } + fadeIn() togetherWith
                                slideOutVertically { height -> -height } + fadeOut()
                    },
                    label = "network_speed_animation"
                ) { speed ->
                    Text(
                        text = "信号强度: ${speed.roundToInt()}",
                        fontSize = if (isPortrait) 12.sp else 10.sp,
                        color = Color.White.copy(alpha = 0.7f)
                    )
                }
            }
        }
    }
}

@Composable
private fun SystemInfoGrid(
    systemMetrics: com.yunqiao.sinan.manager.SystemMetrics,
    isPortrait: Boolean = true
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(if (isPortrait) 16.dp else 20.dp)
        ) {
            Text(
                text = "系统信息",
                fontSize = if (isPortrait) 16.sp else 18.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            
            Spacer(modifier = Modifier.height(if (isPortrait) 12.dp else 16.dp))
            
            val systemInfoItems = remember(systemMetrics) {
                listOf(
                    "蓝牙状态" to systemMetrics.bluetoothStatus,
                    "定位服务" to systemMetrics.locationStatus,
                    "GPU" to systemMetrics.gpuInfo,
                    "存储使用" to "${systemMetrics.storageUsage.roundToInt()}%"
                )
            }
            
            if (isPortrait) {
                // 竖屏模式：垂直布局
                Column(
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    systemInfoItems.forEach { (label, value) ->
                        AnimatedVisibility(
                            visible = true,
                            enter = slideInHorizontally(
                                animationSpec = spring(
                                    dampingRatio = Spring.DampingRatioMediumBouncy,
                                    stiffness = Spring.StiffnessLow
                                ),
                                initialOffsetX = { -it }
                            ) + fadeIn()
                        ) {
                            SystemInfoItem(label, value, isPortrait)
                        }
                    }
                }
            } else {
                // 横屏模式：网格布局
                LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    items(systemInfoItems) { (label, value) ->
                        AnimatedVisibility(
                            visible = true,
                            enter = scaleIn(
                                animationSpec = spring(
                                    dampingRatio = Spring.DampingRatioMediumBouncy,
                                    stiffness = Spring.StiffnessLow
                                )
                            ) + fadeIn()
                        ) {
                            SystemInfoItem(label, value, isPortrait)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ThermalStatusCard(
    thermalState: String,
    isPortrait: Boolean = true
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = when (thermalState) {
                "Normal" -> GlassColors.surface
                "Light Throttling", "Moderate Throttling" -> Color(0x33FFC107)
                else -> Color(0x33F44336)
            }
        ),
        shape = RoundedCornerShape(16.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(if (isPortrait) 16.dp else 20.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text(
                    text = "热管理状态",
                    fontSize = if (isPortrait) 16.sp else 18.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                
                AnimatedContent(
                    targetState = thermalState,
                    transitionSpec = {
                        slideInHorizontally { width -> width } + fadeIn() togetherWith
                                slideOutHorizontally { width -> -width } + fadeOut()
                    },
                    label = "thermal_state_animation"
                ) { state ->
                    Text(
                        text = state,
                        fontSize = if (isPortrait) 14.sp else 16.sp,
                        color = when (state) {
                            "Normal" -> Color(0xFF4CAF50)
                            "Light Throttling", "Moderate Throttling" -> Color(0xFFFFC107)
                            else -> Color.Red
                        }
                    )
                }
            }
            
            AnimatedContent(
                targetState = thermalState,
                transitionSpec = {
                    scaleIn() + fadeIn() togetherWith scaleOut() + fadeOut()
                },
                label = "thermal_icon_animation"
            ) { state ->
                Icon(
                    imageVector = Icons.Default.Thermostat,
                    contentDescription = null,
                    tint = when (state) {
                        "Normal" -> Color(0xFF4CAF50)
                        "Light Throttling", "Moderate Throttling" -> Color(0xFFFFC107)
                        else -> Color.Red
                    },
                    modifier = Modifier.size(if (isPortrait) 24.dp else 28.dp)
                )
            }
        }
    }
}

@Composable
private fun SystemInfoItem(
    label: String, 
    value: String, 
    isPortrait: Boolean = true
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            text = label,
            fontSize = if (isPortrait) 14.sp else 12.sp,
            color = Color.White.copy(alpha = 0.7f)
        )
        AnimatedContent(
            targetState = value,
            transitionSpec = {
                slideInHorizontally { width -> width } + fadeIn() togetherWith
                        slideOutHorizontally { width -> -width } + fadeOut()
            },
            label = "system_info_value_animation"
        ) { currentValue ->
            Text(
                text = currentValue,
                fontSize = if (isPortrait) 14.sp else 12.sp,
                color = Color.White,
                fontWeight = FontWeight.Medium
            )
        }
    }
}

@Composable
private fun MetricCard(
    metric: MetricData, 
    isPortrait: Boolean = true
) {
    val cardSize = if (isPortrait) 70.dp else 80.dp
    val iconSize = if (isPortrait) 18.dp else 20.dp
    val valueFontSize = if (isPortrait) 10.sp else 12.sp
    val labelFontSize = if (isPortrait) 8.sp else 10.sp
    
    Card(
        modifier = Modifier
            .size(cardSize),
        colors = CardDefaults.cardColors(
            containerColor = if (metric.isWarning) Color(0x33F44336) else Color(0x33000000)
        ),
        shape = RoundedCornerShape(12.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            AnimatedContent(
                targetState = metric.icon to metric.isWarning,
                transitionSpec = {
                    scaleIn() + fadeIn() togetherWith scaleOut() + fadeOut()
                },
                label = "metric_icon_animation"
            ) { (icon, warning) ->
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = if (warning) Color.Red else Color(0xFF00E5FF),
                    modifier = Modifier.size(iconSize)
                )
            }
            
            Spacer(modifier = Modifier.height(2.dp))
            
            AnimatedContent(
                targetState = metric.value to metric.isWarning,
                transitionSpec = {
                    slideInVertically { height -> height } + fadeIn() togetherWith
                            slideOutVertically { height -> -height } + fadeOut()
                },
                label = "metric_value_animation"
            ) { (value, warning) ->
                Text(
                    text = value,
                    fontSize = valueFontSize,
                    fontWeight = FontWeight.Bold,
                    color = if (warning) Color.Red else Color.White
                )
            }
            
            Text(
                text = metric.label,
                fontSize = labelFontSize,
                color = Color.White.copy(alpha = 0.7f)
            )
        }
    }
}

private data class MetricData(
    val label: String,
    val value: String,
    val icon: ImageVector,
    val isWarning: Boolean = false
)

private fun formatBytes(bytes: Long): String {
    if (bytes == 0L) return "0 B"
    val units = arrayOf("B", "KB", "MB", "GB", "TB")
    val base = 1024.0
    val logValue = (kotlin.math.ln(bytes.toDouble()) / kotlin.math.ln(base)).toInt()
    val unitIndex = minOf(logValue, units.size - 1)
    val value = bytes / Math.pow(base, unitIndex.toDouble())
    return "%.1f %s".format(value, units[unitIndex])
}