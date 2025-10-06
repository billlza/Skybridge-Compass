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
        icon = Icons.Default.Home,
        isSelected = true
    ),
    NavigationItem(
        route = "device_discovery",
        title = "附近设备",
        icon = Icons.Default.DeviceHub
    ),
    NavigationItem(
        route = "file_transfer",
        title = "文件传输",
        icon = Icons.Default.CloudUpload
    ),
    NavigationItem(
        route = "remote_desktop",
        title = "远程桌面",
        icon = Icons.Default.Computer
    ),
    NavigationItem(
        route = "ai_assistant",
        title = "AI助手",
        icon = Icons.Default.Psychology
    ),
    NavigationItem(
        route = "user_settings",
        title = "系统设置",
        icon = Icons.Default.Settings
    )
)
