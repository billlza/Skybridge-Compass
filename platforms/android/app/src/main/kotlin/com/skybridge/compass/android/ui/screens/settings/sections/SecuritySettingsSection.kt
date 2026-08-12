package com.skybridge.compass.android.ui.screens.settings.sections

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.GroupedGlassDivider
import com.skybridge.compass.android.ui.components.GroupedGlassRow
import com.skybridge.compass.android.ui.components.GroupedGlassSection
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.android.ui.screens.settings.Setting

/**
 * "安全 / Security" grouped section — extracted verbatim from SettingsScreen.kt.
 * Each row navigates to the same dedicated security sub-screen route as before; the destinations
 * (Device Authentication / Encryption / Access Control / Privacy) own the real security toggles.
 */
@Composable
fun SecuritySettingsSection(
    onNavigate: (route: String) -> Unit
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    val securitySettingItems = listOf(
        Setting(
            title = t("设备认证", "Device Authentication", "デバイス認証"),
            description = t("要求设备配对认证", "Require device pairing authentication", "デバイスのペアリング認証を必須にする"),
            icon = Icons.Default.Lock,
            route = Screen.DeviceAuthentication.route
        ),
        Setting(
            title = t("数据加密", "Encryption", "データ暗号化"),
            description = t("传输数据加密设置", "Manage transport encryption settings", "通信データの暗号化設定を管理する"),
            icon = Icons.Default.Lock,
            route = Screen.EncryptionSettings.route
        ),
        Setting(
            title = t("访问控制", "Access Control", "アクセス制御"),
            description = t("管理设备访问权限", "Manage device access permissions", "デバイスのアクセス権限を管理する"),
            icon = Icons.Default.Settings,
            route = Screen.AccessControl.route
        ),
        Setting(
            title = t("隐私设置", "Privacy", "プライバシー"),
            description = t("控制数据收集和使用", "Control data collection and usage", "データ収集と利用を制御する"),
            icon = Icons.Default.Lock,
            route = Screen.PrivacySettings.route
        ),
        Setting(
            title = t("画面流设置", "Stream Settings", "ストリーム設定"),
            description = t("远程桌面分辨率/帧率/编码/延迟", "Remote desktop resolution, frame rate, codec, latency", "リモートデスクトップの解像度・フレームレート・コーデック・遅延"),
            icon = Icons.Default.Tune,
            route = Screen.RemoteDesktopStreamSettings.route
        )
    )

    GroupedGlassSection(title = t("安全", "Security", "セキュリティ")) {
        securitySettingItems.forEachIndexed { idx, setting ->
            GroupedGlassRow(
                title = setting.title,
                subtitle = setting.description,
                icon = setting.icon,
                onClick = {
                    setting.route?.let { onNavigate(it) }
                }
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (idx != securitySettingItems.lastIndex) {
                GroupedGlassDivider()
            }
        }
    }
}
