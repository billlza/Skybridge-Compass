package com.skybridge.compass.android.ui.screens.screenmirroring

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavController
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.data.DeveloperSettingsStore
import com.skybridge.compass.android.ui.screens.remotecontrol.RemoteControlScreen
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.android.i18n.localizedText

/**
 * 当前 Android 端将“屏幕镜像”统一走远程桌面通道，
 * 直接复用已接入 macOS/iOS 互通协议的 RemoteControlScreen。
 */
@Composable
fun ScreenMirroringScreen(navController: NavController) {
    val featureDisabledTitle = localizedText(
        "屏幕镜像已在设置中关闭",
        "Screen mirroring is disabled in Settings",
        "画面ミラーリングは設定で無効になっています"
    )
    val featureDisabledMessage = localizedText(
        "请前往 设置 > 深度开发设置 重新启用。",
        "Go to Settings > Advanced Developer Settings to enable it again.",
        "設定 > 開発者向け詳細設定 で再度有効にしてください。"
    )
    val openSettingsLabel = localizedText("打开设置", "Open Settings", "設定を開く")
    val context = LocalContext.current
    val devSettings by DeveloperSettingsStore.observe(context).collectAsState(initial = DeveloperSettings())
    if (!devSettings.enableScreenMirroring) {
        Column(
            modifier = Modifier.fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text(featureDisabledTitle, style = MaterialTheme.typography.titleLarge)
            Text(
                featureDisabledMessage,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 8.dp, bottom = 16.dp)
            )
            Button(onClick = { navController.navigate(Screen.Settings.route) { launchSingleTop = true } }) {
                Text(openSettingsLabel)
            }
        }
        return
    }
    RemoteControlScreen(navController = navController)
}
