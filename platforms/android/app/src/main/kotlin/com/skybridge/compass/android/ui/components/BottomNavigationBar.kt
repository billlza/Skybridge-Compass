package com.skybridge.compass.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Settings
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavDestination
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavHostController
import androidx.navigation.compose.currentBackStackEntryAsState
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.data.AppSettingsStore
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.ui.navigation.NavigationSemantics
import com.skybridge.compass.android.ui.navigation.Screen

// ─────────────────────────────────────────────────────────────────────
// Geometry mirrors the Samsung Galaxy Store floating tab bar measured on this device
// (main_tablayout bounds [15,2816,1425,3026] @ 1440x3120, density 600 → 3.75 px/dp):
// 4dp side margins, 56dp tall, fully rounded capsule, 64x48dp selected item pill.

private val PillShape = RoundedCornerShape(percent = 50)
private val CyanAccent = Color(0xFF2AB8FF)

private val BarTint = Color(0xFF10151F)
private val BarTintAlpha = 0.82f
private val BarEdgeColor = Color.White.copy(alpha = 0.10f)
private val SelectedPillFill = Color.White.copy(alpha = 0.10f)
private val UnselectedIconColor = Color(0xFFA0A8B4)
private val UnselectedLabelColor = Color(0xFF888F9A)

@Composable
fun BottomNavigationBar(navController: NavHostController) {
    val context = LocalContext.current
    val homeLabel = localizedText("首页", "Home", "ホーム")
    val devicesLabel = localizedText("设备", "Devices", "デバイス")
    val filesLabel = localizedText("文件", "Files", "ファイル")
    val remoteLabel = localizedText("远程", "Remote", "リモート")
    val settingsLabel = localizedText("设置", "Settings", "設定")
    val appSettings by AppSettingsStore.observe(context).collectAsState(initial = AppSettings())
    // iOS parity: all 5 tabs (Home / Devices / Files / Remote / Settings) are visible
    // unconditionally. File transfer and remote control are shipping features now, so the
    // bottom-nav entries no longer hinge on the developer feature-flags. The flags still
    // exist in Settings and continue to gate the underlying behaviors, not tab visibility.
    val items = remember(homeLabel, devicesLabel, filesLabel, remoteLabel, settingsLabel) {
        listOf(
            BottomNavItem(homeLabel, Icons.Filled.Home, Icons.Outlined.Home, Screen.Dashboard.route),
            BottomNavItem(devicesLabel, Icons.Filled.Devices, Icons.Outlined.Devices, Screen.DeviceDiscovery.route),
            BottomNavItem(filesLabel, Icons.Filled.Folder, Icons.Outlined.Folder, Screen.FileTransfer.route),
            BottomNavItem(remoteLabel, Icons.Filled.Computer, Icons.Outlined.Computer, Screen.RemoteControl.route),
            BottomNavItem(settingsLabel, Icons.Filled.Settings, Icons.Outlined.Settings, Screen.Settings.route)
        )
    }

    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = backStackEntry?.destination

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(start = 4.dp, end = 4.dp, bottom = 10.dp)
            .height(56.dp)
            .shadow(12.dp, PillShape, clip = false)
            .clip(PillShape)
            .background(BarTint.copy(alpha = BarTintAlpha))
            .border(0.5.dp, BarEdgeColor, PillShape)
    ) {
        Row(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 8.dp),
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
        targetValue = if (isPressed) 0.50f else 1.0f,
        animationSpec = tween(durationMillis = if (isPressed) 30 else 180),
        label = "pressAlpha"
    )

    val iconTint = if (selected) CyanAccent else UnselectedIconColor
    val labelColor = if (selected) CyanAccent else UnselectedLabelColor

    Column(
        modifier = Modifier
            .weight(1f)
            .padding(horizontal = 4.dp)
            .height(48.dp)
            .clip(PillShape)
            .background(if (selected) SelectedPillFill else Color.Transparent)
            .alpha(pressAlpha)
            .testTag(NavigationSemantics.bottomTab(item.route))
            .selectable(
                selected = selected,
                interactionSource = interactionSource,
                indication = null,
                role = Role.Tab,
                onClick = {
                    if (hapticsEnabled) {
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    }
                    onClick()
                }
            ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            imageVector = if (selected) item.icon else item.outlinedIcon,
            contentDescription = item.label,
            tint = iconTint,
            modifier = Modifier.size(22.dp)
        )

        Spacer(modifier = Modifier.height(3.dp))

        Text(
            text = item.label,
            fontSize = 10.sp,
            color = labelColor,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            lineHeight = 11.sp
        )
    }
}

private fun NavDestination?.isTopLevelSelected(route: String): Boolean {
    return this?.hierarchy?.any { destination ->
        destination.route?.substringBefore('?') == route
    } == true
}

private data class BottomNavItem(
    val label: String,
    val icon: ImageVector,
    val outlinedIcon: ImageVector,
    val route: String
)
