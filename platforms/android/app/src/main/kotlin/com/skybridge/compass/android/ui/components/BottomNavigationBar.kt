package com.skybridge.compass.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavDestination
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavHostController
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.compose.ui.platform.LocalContext
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.data.DeveloperSettingsStore
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.ui.navigation.Screen

// ─────────────────────────────────────────────────────────────────────

private val BarShape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp)
private val SelectedPillShape = androidx.compose.foundation.shape.RoundedCornerShape(18.dp)
private val CyanAccent = Color(0xFF2AB8FF)

// iOS 26 Liquid Glass dark-mode tab bar colors (from screenshot analysis)
private val BarTint = Color(0xFF0D1117)
private val BarTintAlpha = 0.78f
private val SelectedPillColor = Color(0xFF0A0E16).copy(alpha = 0.92f)
private val UnselectedIconColor = Color(0xFFB0B8C4)
private val UnselectedLabelColor = Color(0xFFA0A8B4)

@Composable
fun BottomNavigationBar(navController: NavHostController) {
    val context = LocalContext.current
    val homeLabel = localizedText("首页", "Home", "ホーム")
    val devicesLabel = localizedText("设备", "Devices", "デバイス")
    val filesLabel = localizedText("文件", "Files", "ファイル")
    val remoteLabel = localizedText("远程", "Remote", "リモート")
    val settingsLabel = localizedText("设置", "Settings", "設定")
    val appSettings by AppSettingsStore.observe(context).collectAsState(initial = AppSettings())
    val devSettings by DeveloperSettingsStore.observe(context).collectAsState(initial = DeveloperSettings())
    val items = remember(devSettings, homeLabel, devicesLabel, filesLabel, remoteLabel, settingsLabel) {
        buildList {
            add(BottomNavItem(homeLabel, Icons.Filled.Home, Screen.Dashboard.route))
            add(BottomNavItem(devicesLabel, Icons.Filled.Devices, Screen.DeviceDiscovery.route))
            if (devSettings.enableFileTransfer) {
                add(BottomNavItem(filesLabel, Icons.Filled.Folder, Screen.FileTransfer.route))
            }
            if (devSettings.enableRemoteControl) {
                add(BottomNavItem(remoteLabel, Icons.Filled.Computer, Screen.RemoteControl.route))
            }
            add(BottomNavItem(settingsLabel, Icons.Filled.Settings, Screen.Settings.route))
        }
    }

    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = backStackEntry?.destination

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .clip(BarShape)
            // ① Dark glass tint (iOS liquid glass on dark bg is ~78% opaque dark)
            .background(BarTint.copy(alpha = BarTintAlpha))
            // ② Glass specular + depth
            .drawWithCache {
                val topSpecular = Brush.verticalGradient(
                    colorStops = arrayOf(
                        0.00f to Color.White.copy(alpha = 0.12f),
                        0.02f to Color.White.copy(alpha = 0.07f),
                        0.08f to Color.White.copy(alpha = 0.02f),
                        0.25f to Color.Transparent
                    )
                )
                val bottomDepth = Brush.verticalGradient(
                    colorStops = arrayOf(
                        0.85f to Color.Transparent,
                        1.00f to Color.Black.copy(alpha = 0.10f)
                    )
                )
                onDrawWithContent {
                    drawContent()
                    drawRect(topSpecular)
                    drawRect(bottomDepth)
                }
            }
            // ③ Subtle border — slightly brighter at top
            .border(
                width = 0.5.dp,
                brush = Brush.verticalGradient(
                    colorStops = arrayOf(
                        0.0f to Color.White.copy(alpha = 0.18f),
                        0.3f to Color.White.copy(alpha = 0.08f),
                        0.7f to Color.White.copy(alpha = 0.04f),
                        1.0f to Color.White.copy(alpha = 0.06f)
                    )
                ),
                shape = BarShape
            )
            .padding(horizontal = 6.dp, vertical = 4.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(60.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically
        ) {
            items.forEach { item ->
                val selected = currentDestination.isTopLevelSelected(item.route)
                BottomTabItem(item = item, selected = selected, onClick = {
                    if (!selected) {
                        navController.navigate(item.route) {
                            popUpTo(navController.graph.startDestinationId) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    }
                }, hapticsEnabled = appSettings.hapticFeedback)
            }
        }
    }
}

@Composable
private fun RowScope.BottomTabItem(
    item: BottomNavItem,
    selected: Boolean,
    onClick: () -> Unit,
    hapticsEnabled: Boolean
) {
    val haptics = LocalHapticFeedback.current
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()

    val pressAlpha by animateFloatAsState(
        targetValue = if (isPressed) 0.45f else 1.0f,
        animationSpec = tween(durationMillis = if (isPressed) 30 else 180),
        label = "pressAlpha"
    )

    val iconTint = if (selected) CyanAccent else UnselectedIconColor
    val labelColor = if (selected) CyanAccent else UnselectedLabelColor

    Column(
        modifier = Modifier
            .weight(1f)
            .then(
                if (selected) {
                    Modifier
                        .padding(horizontal = 2.dp, vertical = 2.dp)
                        .clip(SelectedPillShape)
                        .background(SelectedPillColor)
                } else {
                    Modifier.padding(horizontal = 2.dp, vertical = 2.dp)
                }
            )
            .alpha(pressAlpha)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = {
                    if (hapticsEnabled) {
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    }
                    onClick()
                }
            )
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Icon(
            imageVector = item.icon,
            contentDescription = item.label,
            tint = iconTint,
            modifier = Modifier.size(26.dp)
        )

        Text(
            text = item.label,
            fontSize = 11.sp,
            color = labelColor,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            lineHeight = 13.sp
        )
    }
}

private fun NavDestination?.isTopLevelSelected(route: String): Boolean {
    return this?.hierarchy?.any { it.route == route } == true
}

private data class BottomNavItem(
    val label: String,
    val icon: ImageVector,
    val route: String
)
