package com.yunqiao.sinan.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.data.ConnectionStatus
import com.yunqiao.sinan.data.BatteryChargeStatus
import com.yunqiao.sinan.data.DeviceStatusManager
import com.yunqiao.sinan.data.formatTemperatureC
import com.yunqiao.sinan.data.formatUptime
import com.yunqiao.sinan.data.getThermalStatusText
import com.yunqiao.sinan.data.rememberDeviceStatusManager
import com.yunqiao.sinan.ui.theme.GlassColors
import kotlinx.coroutines.delay

/**
 * 主控制台页面
 */
@Composable
fun MainControlScreen(
    modifier: Modifier = Modifier,
    deviceStatusManager: DeviceStatusManager = rememberDeviceStatusManager(),
    onNavigate: (String) -> Unit = {}
) {
    val deviceStatus by deviceStatusManager.deviceStatus.collectAsState()
    
    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        item {
            // 欢迎标题
            Text(
                text = "主控制台",
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White,
                modifier = Modifier.padding(bottom = 8.dp)
            )
            
            Text(
                text = "设备管理与远程控制中心",
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.7f)
            )
        }
        
        item {
            // 系统状态概览
            SystemOverviewCard(
                deviceStatus = deviceStatus
            )
        }
        
        item {
            // 快速操作
            QuickActionsSection(onNavigate = onNavigate)
        }
        
        item {
            // 连接设备列表
            ConnectedDevicesSection(
                deviceCount = deviceStatus.connectedDevicesCount
            )
        }
        
        item {
            // 最近活动
            RecentActivitySection()
        }
    }
}

/**
 * 系统状态概览卡片
 */
@Composable
private fun SystemOverviewCard(deviceStatus: com.yunqiao.sinan.data.DeviceStatus) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = GlassColors.background
        ),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(20.dp)
        ) {
            Text(
                text = "系统状态概览",
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
                modifier = Modifier.padding(bottom = 16.dp)
            )
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                StatusMetric(
                    title = "CPU",
                    value = "${(deviceStatus.cpuUsage * 100).toInt()}%",
                    icon = Icons.Default.Computer,
                    color = when {
                        deviceStatus.cpuUsage < 0.5f -> Color(0xFF4CAF50)
                        deviceStatus.cpuUsage < 0.8f -> Color(0xFFFF9800)
                        else -> Color(0xFFF44336)
                    }
                )

                StatusMetric(
                    title = "GPU",
                    value = "${(deviceStatus.gpuUsage * 100).toInt()}%",
                    icon = Icons.Default.Speed,
                    color = when {
                        deviceStatus.gpuUsage < 0.5f -> Color(0xFF4CAF50)
                        deviceStatus.gpuUsage < 0.8f -> Color(0xFFFF9800)
                        else -> Color(0xFFF44336)
                    }
                )

                StatusMetric(
                    title = "内存",
                    value = "${(deviceStatus.memoryUsage * 100).toInt()}%",
                    icon = Icons.Default.DataUsage,
                    color = when {
                        deviceStatus.memoryUsage < 0.5f -> Color(0xFF4CAF50)
                        deviceStatus.memoryUsage < 0.8f -> Color(0xFFFF9800)
                        else -> Color(0xFFF44336)
                    }
                )

                val batteryColor = when {
                    (deviceStatus.batteryLevel ?: 0) > 50 -> Color(0xFF4CAF50)
                    (deviceStatus.batteryLevel ?: 0) > 20 -> Color(0xFFFF9800)
                    else -> Color(0xFFF44336)
                }
                StatusMetric(
                    title = "电池",
                    value = deviceStatus.batteryLevel?.let { "$it%" } ?: "--",
                    icon = if (deviceStatus.batteryStatus == BatteryChargeStatus.CHARGING) Icons.Default.BatteryChargingFull else Icons.Default.BatteryFull,
                    color = batteryColor
                )
            }

            Spacer(modifier = Modifier.height(16.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                StatusMetric(
                    title = "CPU温度",
                    value = formatTemperatureC(deviceStatus.cpuTemperatureC),
                    icon = Icons.Default.Thermostat,
                    color = Color(0xFF4FC3F7)
                )

                StatusMetric(
                    title = "GPU温度",
                    value = formatTemperatureC(deviceStatus.gpuTemperatureC),
                    icon = Icons.Default.Whatshot,
                    color = Color(0xFFFF7043)
                )

                StatusMetric(
                    title = "热状态",
                    value = getThermalStatusText(deviceStatus.thermalStatus),
                    icon = Icons.Default.Thermostat,
                    color = Color(0xFFFFA726)
                )

                StatusMetric(
                    title = "运行时间",
                    value = formatUptime(deviceStatus.uptime),
                    icon = Icons.Default.AccessTime,
                    color = Color(0xFF9C27B0)
                )
            }
        }
    }
}

/**
 * 状态指标组件
 */
@Composable
private fun StatusMetric(
    title: String,
    value: String,
    icon: ImageVector,
    color: Color
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            modifier = Modifier
                .size(48.dp)
                .background(
                    color = color.copy(alpha = 0.2f),
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(24.dp)
            )
        }
        
        Spacer(modifier = Modifier.height(8.dp))
        
        Text(
            text = value,
            fontSize = 16.sp,
            fontWeight = FontWeight.Bold,
            color = Color.White
        )
        
        Text(
            text = title,
            fontSize = 12.sp,
            color = Color.White.copy(alpha = 0.7f)
        )
    }
}

/**
 * 快速操作区域
 */
@Composable
private fun QuickActionsSection(onNavigate: (String) -> Unit = {}) {
    Column {
        Text(
            text = "快速操作",
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color.White,
            modifier = Modifier.padding(bottom = 12.dp)
        )
        
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            val actions = listOf(
                QuickAction(
                    title = "远程桌面",
                    icon = Icons.Default.Computer,
                    color = Color(0xFF2196F3)
                ) { onNavigate("remote_desktop") },
                QuickAction(
                    title = "文件传输",
                    icon = Icons.Default.Folder,
                    color = Color(0xFF4CAF50)
                ) { onNavigate("file_transfer") },
                QuickAction(
                    title = "设备管理",
                    icon = Icons.Default.Devices,
                    color = Color(0xFFFF9800)
                ) { onNavigate("device_discovery") },
                QuickAction(
                    title = "系统监控",
                    icon = Icons.Default.Analytics,
                    color = Color(0xFF9C27B0)
                ) { onNavigate("system_monitor") },
                QuickAction(
                    title = "网络测试",
                    icon = Icons.Default.NetworkCheck,
                    color = Color(0xFFF44336)
                ) { onNavigate("operations_hub_dashboard") }
            )
            items(actions) { action ->
                QuickActionCard(action = action)
            }
        }
    }
}

/**
 * 快速操作卡片
 */
@Composable
private fun QuickActionCard(action: QuickAction) {
    Card(
        modifier = Modifier
            .width(120.dp)
            .clickable { action.onClick() },
        colors = CardDefaults.cardColors(
            containerColor = GlassColors.background
        ),
        shape = RoundedCornerShape(12.dp)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .background(
                        color = action.color.copy(alpha = 0.2f),
                        shape = CircleShape
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = action.icon,
                    contentDescription = null,
                    tint = action.color,
                    modifier = Modifier.size(20.dp)
                )
            }
            
            Spacer(modifier = Modifier.height(8.dp))
            
            Text(
                text = action.title,
                fontSize = 12.sp,
                color = Color.White,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

/**
 * 连接设备区域
 */
@Composable
private fun ConnectedDevicesSection(deviceCount: Int) {
    Column {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "连接设备 ($deviceCount)",
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White
            )
            
            TextButton(
                onClick = { /* 查看全部 */ }
            ) {
                Text(
                    text = "查看全部",
                    color = Color(0xFF2196F3)
                )
            }
        }
        
        Spacer(modifier = Modifier.height(8.dp))
        
        repeat(minOf(deviceCount, 3)) { index ->
            DeviceItem(
                deviceName = when (index) {
                    0 -> "iPhone 15 Pro Max"
                    1 -> "MacBook Pro M3"
                    2 -> "iPad Air"
                    else -> "Unknown Device"
                },
                deviceType = when (index) {
                    0 -> "手机"
                    1 -> "电脑"
                    2 -> "平板"
                    else -> "未知"
                },
                isOnline = true
            )
            
            if (index < minOf(deviceCount, 3) - 1) {
                Spacer(modifier = Modifier.height(8.dp))
            }
        }
    }
}

/**
 * 设备项组件
 */
@Composable
private fun DeviceItem(
    deviceName: String,
    deviceType: String,
    isOnline: Boolean
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = GlassColors.background.copy(alpha = 0.6f)
        ),
        shape = RoundedCornerShape(8.dp)
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // 设备图标
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .background(
                        color = if (isOnline) Color(0xFF4CAF50).copy(alpha = 0.2f) 
                               else Color.Gray.copy(alpha = 0.2f),
                        shape = CircleShape
                    ),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = when (deviceType) {
                        "手机" -> Icons.Default.PhoneAndroid
                        "电脑" -> Icons.Default.Computer
                        "平板" -> Icons.Default.Tablet
                        else -> Icons.Default.DeviceUnknown
                    },
                    contentDescription = null,
                    tint = if (isOnline) Color(0xFF4CAF50) else Color.Gray,
                    modifier = Modifier.size(16.dp)
                )
            }
            
            Spacer(modifier = Modifier.width(12.dp))
            
            // 设备信息
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = deviceName,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = Color.White
                )
                
                Text(
                    text = deviceType,
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
            
            // 状态指示器
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .background(
                        color = if (isOnline) Color(0xFF4CAF50) else Color.Gray,
                        shape = CircleShape
                    )
            )
        }
    }
}

/**
 * 最近活动区域
 */
@Composable
private fun RecentActivitySection() {
    Column {
        Text(
            text = "最近活动",
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color.White,
            modifier = Modifier.padding(bottom = 12.dp)
        )
        
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = GlassColors.background.copy(alpha = 0.6f)
            ),
            shape = RoundedCornerShape(12.dp)
        ) {
            Column(
                modifier = Modifier.padding(16.dp)
            ) {
                recentActivities.forEach { activity ->
                    ActivityItem(activity = activity)
                    Spacer(modifier = Modifier.height(8.dp))
                }
            }
        }
    }
}

/**
 * 活动项组件
 */
@Composable
private fun ActivityItem(activity: RecentActivity) {
    Row(
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = activity.icon,
            contentDescription = null,
            tint = activity.color,
            modifier = Modifier.size(16.dp)
        )
        
        Spacer(modifier = Modifier.width(8.dp))
        
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = activity.title,
                fontSize = 13.sp,
                color = Color.White
            )
            
            Text(
                text = activity.time,
                fontSize = 11.sp,
                color = Color.White.copy(alpha = 0.5f)
            )
        }
    }
}

// 数据类和常量
data class QuickAction(
    val title: String,
    val icon: ImageVector,
    val color: Color,
    val onClick: () -> Unit
)

data class RecentActivity(
    val title: String,
    val time: String,
    val icon: ImageVector,
    val color: Color
)

private val quickActions = listOf(
    QuickAction(
        title = "远程桌面",
        icon = Icons.Default.Computer,
        color = Color(0xFF2196F3)
    ) { },
    QuickAction(
        title = "文件传输",
        icon = Icons.Default.Folder,
        color = Color(0xFF4CAF50)
    ) { },
    QuickAction(
        title = "设备管理",
        icon = Icons.Default.Devices,
        color = Color(0xFFFF9800)
    ) { },
    QuickAction(
        title = "系统监控",
        icon = Icons.Default.Analytics,
        color = Color(0xFF9C27B0)
    ) { },
    QuickAction(
        title = "网络测试",
        icon = Icons.Default.NetworkCheck,
        color = Color(0xFFF44336)
    ) { }
)

private val recentActivities = listOf(
    RecentActivity(
        title = "iPhone 15 Pro Max 连接成功",
        time = "2分钟前",
        icon = Icons.Default.PhoneAndroid,
        color = Color(0xFF4CAF50)
    ),
    RecentActivity(
        title = "文件传输完成：photo.jpg",
        time = "5分钟前",
        icon = Icons.Default.Download,
        color = Color(0xFF2196F3)
    ),
    RecentActivity(
        title = "MacBook Pro M3 断开连接",
        time = "10分钟前",
        icon = Icons.Default.Computer,
        color = Color(0xFFFF9800)
    )
)
