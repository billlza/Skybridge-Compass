package com.yunqiao.sinan.ui.component

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.yunqiao.sinan.data.*
import com.yunqiao.sinan.ui.theme.ModernGlassColors
import com.yunqiao.sinan.ui.theme.ModernShapes
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * 现代化设备状态栏组件，显示在线状态和设备数量
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceStatusBar(
    modifier: Modifier = Modifier,
    deviceStatusManager: DeviceStatusManager = rememberDeviceStatusManager()
) {
    val deviceStatus by deviceStatusManager.deviceStatus.collectAsState()
    val colorScheme = MaterialTheme.colorScheme
    val lifecycleOwner = LocalLifecycleOwner.current
    val coroutineScope = rememberCoroutineScope()
    
    // 使用DisposableEffect管理协程生命周期，避免内存泄漏
    DisposableEffect(deviceStatusManager, lifecycleOwner) {
        var updateJob: Job? = null
        var isComponentActive = true
        
        val lifecycleObserver = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    isComponentActive = true
                    // 启动定期更新协程
                    updateJob = coroutineScope.launch {
                        while (isActive && isComponentActive) {
                            try {
                                delay(5000) // 每5秒更新一次，添加限流机制
                                if (isActive && isComponentActive) {
                                    deviceStatusManager.updateSystemStatus()
                                }
                            } catch (e: Exception) {
                                // 处理异常，避免协程崩溃
                                println("设备状态更新异常: ${e.message}")
                                delay(10000) // 发生异常时延长延迟时间
                            }
                        }
                    }
                }
                Lifecycle.Event.ON_PAUSE -> {
                    isComponentActive = false
                    updateJob?.cancel()
                    updateJob = null
                }
                else -> { /* 其他生命周期事件 */ }
            }
        }
        
        lifecycleOwner.lifecycle.addObserver(lifecycleObserver)
        
        // 组件初始化时立即启动更新
        isComponentActive = true
        updateJob = coroutineScope.launch {
            while (isActive && isComponentActive) {
                try {
                    delay(5000)
                    if (isActive && isComponentActive) {
                        deviceStatusManager.updateSystemStatus()
                    }
                } catch (e: Exception) {
                    println("设备状态更新异常: ${e.message}")
                    delay(10000)
                }
            }
        }
        
        // 组件销毁时的清理工作
        onDispose {
            isComponentActive = false
            updateJob?.cancel()
            updateJob = null
            lifecycleOwner.lifecycle.removeObserver(lifecycleObserver)
        }
    }
    
    Surface(
        modifier = modifier,
        shape = ModernShapes.large,
        color = colorScheme.surfaceVariant.copy(alpha = 0.8f),
        tonalElevation = 4.dp
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // 主状态栏
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // 在线状态指示器
                ModernConnectionStatusIndicator(deviceStatus.connectionStatus)
                
                Spacer(modifier = Modifier.width(12.dp))
                
                // 设备基本信息
                Column {
                    Text(
                        text = getConnectionStatusText(deviceStatus.connectionStatus),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colorScheme.onSurfaceVariant,
                        fontWeight = FontWeight.Medium
                    )
                    
                    Row(
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = deviceStatus.deviceModel,
                            style = MaterialTheme.typography.bodySmall,
                            color = colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                        )
                        
                        Spacer(modifier = Modifier.width(8.dp))
                        
                        // 网络类型图标
                        ModernNetworkTypeIcon(deviceStatus.networkType)
                        
                        Spacer(modifier = Modifier.width(4.dp))
                        
                        Text(
                            text = getNetworkTypeText(deviceStatus.networkType),
                            style = MaterialTheme.typography.labelSmall,
                            color = colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                        )
                    }
                }
                
                Spacer(modifier = Modifier.weight(1f))
                
                // 系统状态信息
                Column(
                    horizontalAlignment = Alignment.End
                ) {
                    // 连接设备数量
                    Text(
                        text = "${deviceStatus.connectedDevicesCount}/${deviceStatus.totalDevicesCount} 设备",
                        style = MaterialTheme.typography.bodySmall,
                        color = colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        textAlign = TextAlign.End
                    )
                    
                    // IP地址
                    Text(
                        text = deviceStatus.ipAddress,
                        style = MaterialTheme.typography.labelSmall,
                        color = colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                        textAlign = TextAlign.End
                    )
                }
                
                // 电池状态（如果有）
                if (deviceStatus.batteryLevel != null) {
                    Spacer(modifier = Modifier.width(16.dp))
                    val batteryLevel = deviceStatus.batteryLevel!! 
                    ModernBatteryIndicator(batteryLevel)
                }
            }
            
            // 系统性能指标
            Surface(
                shape = ModernShapes.medium,
                color = colorScheme.surface.copy(alpha = 0.5f)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    // CPU使用率
                    ModernSystemMetric(
                        label = "CPU",
                        value = deviceStatus.cpuUsage,
                        icon = Icons.Default.Memory,
                        modifier = Modifier.weight(1f)
                    )
                    
                    Spacer(modifier = Modifier.width(16.dp))
                    
                    // 内存使用率
                    ModernSystemMetric(
                        label = "内存",
                        value = deviceStatus.memoryUsage,
                        icon = Icons.Default.Storage,
                        modifier = Modifier.weight(1f)
                    )
                    
                    Spacer(modifier = Modifier.width(16.dp))
                    
                    // 运行时间和最后更新时间
                    Column(
                        modifier = Modifier.weight(1f),
                        horizontalAlignment = Alignment.End
                    ) {
                        Text(
                            text = "运行时间: ${formatUptime(deviceStatus.uptime)}",
                            style = MaterialTheme.typography.labelSmall,
                            color = colorScheme.onSurface.copy(alpha = 0.7f)
                        )
                        Text(
                            text = "更新: ${formatLastUpdate(deviceStatus.lastUpdateTime)}",
                            style = MaterialTheme.typography.labelSmall,
                            color = colorScheme.onSurface.copy(alpha = 0.5f)
                        )
                    }
                }
            }
        }
    }
}

/**
 * 现代化连接状态指示器
 */
@Composable
private fun ModernConnectionStatusIndicator(status: ConnectionStatus) {
    val colorScheme = MaterialTheme.colorScheme
    val statusColor = when (status) {
        ConnectionStatus.ONLINE -> ModernGlassColors.successGradientStart
        ConnectionStatus.OFFLINE -> ModernGlassColors.errorGradientStart
        ConnectionStatus.CONNECTING -> ModernGlassColors.warningGradientStart
    }
    
    val animatedColor by animateColorAsState(
        targetValue = statusColor,
        animationSpec = tween(durationMillis = 300),
        label = "status_color"
    )
    
    Surface(
        modifier = Modifier.size(12.dp),
        shape = CircleShape,
        color = animatedColor
    ) {}
}

/**
 * 现代化网络类型图标
 */
@Composable
private fun ModernNetworkTypeIcon(networkType: NetworkType) {
    val colorScheme = MaterialTheme.colorScheme
    
    val icon = when (networkType) {
        NetworkType.WIFI -> Icons.Default.Wifi
        NetworkType.MOBILE -> Icons.Default.SignalCellular4Bar
        NetworkType.ETHERNET -> Icons.Default.Cable
        NetworkType.UNKNOWN -> Icons.Default.DeviceUnknown
    }
    
    Icon(
        imageVector = icon,
        contentDescription = null,
        modifier = Modifier.size(12.dp),
        tint = colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
    )
}

/**
 * 现代化电池指示器
 */
@Composable
private fun ModernBatteryIndicator(batteryLevel: Int) {
    val colorScheme = MaterialTheme.colorScheme
    
    val batteryColor = when {
        batteryLevel > 50 -> ModernGlassColors.successGradientStart
        batteryLevel > 20 -> ModernGlassColors.warningGradientStart
        else -> ModernGlassColors.errorGradientStart
    }
    
    Surface(
        shape = ModernShapes.small,
        color = colorScheme.surface
    ) {
        Row(
            modifier = Modifier.padding(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = when {
                    batteryLevel > 90 -> Icons.Default.BatteryFull
                    batteryLevel > 60 -> Icons.Default.Battery6Bar
                    batteryLevel > 30 -> Icons.Default.Battery3Bar
                    batteryLevel > 10 -> Icons.Default.Battery2Bar
                    else -> Icons.Default.Battery1Bar
                },
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = batteryColor
            )
            
            Spacer(modifier = Modifier.width(4.dp))
            
            Text(
                text = "$batteryLevel%",
                style = MaterialTheme.typography.labelMedium,
                color = batteryColor,
                fontWeight = FontWeight.Medium
            )
        }
    }
}

/**
 * 现代化系统性能指标组件
 */
@Composable
private fun ModernSystemMetric(
    label: String,
    value: Float,
    icon: ImageVector,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val percentage = (value * 100).toInt()
    
    val metricColor = when {
        value < 0.5f -> ModernGlassColors.successGradientStart
        value < 0.8f -> ModernGlassColors.warningGradientStart
        else -> ModernGlassColors.errorGradientStart
    }
    
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(12.dp),
                tint = colorScheme.onSurface.copy(alpha = 0.7f)
            )
            
            Spacer(modifier = Modifier.width(4.dp))
            
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                color = colorScheme.onSurface.copy(alpha = 0.7f)
            )
        }
        
        Spacer(modifier = Modifier.height(4.dp))
        
        LinearProgressIndicator(
            progress = { value },
            modifier = Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(ModernShapes.small),
            color = metricColor,
            trackColor = colorScheme.surfaceVariant.copy(alpha = 0.3f)
        )
        
        Spacer(modifier = Modifier.height(2.dp))
        
        Text(
            text = "$percentage%",
            style = MaterialTheme.typography.labelSmall,
            color = metricColor,
            fontWeight = FontWeight.Medium
        )
    }
}
