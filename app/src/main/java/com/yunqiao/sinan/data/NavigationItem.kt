package com.yunqiao.sinan.data

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * 导航项数据类
 */
data class NavigationItem(
    val route: String,
    val title: String,
    val icon: ImageVector,
    val isSelected: Boolean = false
)

/**
 * 主导航项列表 - 包含天气和AI功能
 */
val navigationItems = listOf(
    NavigationItem(
        route = "main_control",
        title = "主控制台",
        icon = Icons.Default.Home
    ),
    NavigationItem(
        route = "system_monitor",
        title = "系统监控",
        icon = Icons.Default.Monitor,
        isSelected = true  // 默认选中
    ),
    NavigationItem(
        route = "weather_center",
        title = "天气中心",
        icon = Icons.Default.Cloud
    ),
    NavigationItem(
        route = "weather_settings",
        title = "天气设置",
        icon = Icons.Default.CloudQueue
    ),
    NavigationItem(
        route = "ai_assistant",
        title = "AI助手",
        icon = Icons.Default.Psychology
    ),
    NavigationItem(
        route = "remote_desktop",
        title = "远程桌面",
        icon = Icons.Default.Computer
    ),
    NavigationItem(
        route = "file_transfer",
        title = "文件传输",
        icon = Icons.Default.CloudUpload
    ),
    NavigationItem(
        route = "device_discovery",
        title = "设备发现",
        icon = Icons.Default.DeviceHub
    ),
    NavigationItem(
        route = "node6_dashboard",
        title = "Node 6",
        icon = Icons.Default.Dashboard
    ),
    NavigationItem(
        route = "user_settings",
        title = "用户设置",
        icon = Icons.Default.Settings
    )
)
