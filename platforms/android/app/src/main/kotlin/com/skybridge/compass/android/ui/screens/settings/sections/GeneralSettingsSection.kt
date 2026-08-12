package com.skybridge.compass.android.ui.screens.settings.sections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryAlert
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.StayCurrentPortrait
import androidx.compose.material.icons.filled.Vibration
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.skybridge.compass.android.data.APP_LANGUAGE_EN
import com.skybridge.compass.android.data.APP_LANGUAGE_JA
import com.skybridge.compass.android.data.APP_LANGUAGE_SYSTEM
import com.skybridge.compass.android.data.APP_LANGUAGE_ZH
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.i18n.resolveLanguageLabel
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.GroupedGlassDivider
import com.skybridge.compass.android.ui.components.GroupedGlassRow
import com.skybridge.compass.android.ui.components.GroupedGlassSection
import com.skybridge.compass.android.ui.components.LiquidGlassSurface

/**
 * "常规 / General" grouped section — extracted verbatim from SettingsScreen.kt.
 * Every switch remains wired to the same [AppSettings] field and the same setter intent.
 */
@Composable
fun GeneralSettingsSection(
    appSettings: AppSettings,
    onDarkModeChange: (Boolean) -> Unit,
    onLanguageSelected: (String) -> Unit,
    onAutoConnectChange: (Boolean) -> Unit,
    onNotificationsChange: (Boolean) -> Unit,
    onUseDynamicColorChange: (Boolean) -> Unit,
    onHapticFeedbackChange: (Boolean) -> Unit,
    onKeepScreenOnChange: (Boolean) -> Unit,
    onBatteryOptimizationWarningChange: (Boolean) -> Unit,
    onRealTimeWeatherChange: (Boolean) -> Unit
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    GroupedGlassSection(title = t("常规", "General", "一般")) {
        GroupedGlassRow(
            title = t("深色模式", "Dark Mode", "ダークモード"),
            subtitle = t("使用深色主题界面", "Use the dark app appearance", "ダークテーマの外観を使う"),
            icon = Icons.Default.DarkMode
        ) {
            Switch(
                checked = appSettings.darkMode,
                onCheckedChange = onDarkModeChange
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("语言", "Language", "言語"),
            subtitle = t("选择应用显示语言；默认跟随系统", "Choose the app display language; default follows the system", "アプリの表示言語を選択します。既定ではシステムに従います"),
            icon = Icons.Default.Public
        ) {
            Text(
                text = resolveLanguageLabel(appSettings.appLanguage, "中文", "English", "日本語"),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 52.dp, end = 12.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            AppLanguageSelector(
                selectedLanguage = appSettings.appLanguage,
                onLanguageSelected = onLanguageSelected
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("自动连接", "Auto Connect", "自動接続"),
            subtitle = t(
                "发现页只有一个可连接设备时自动发起连接",
                "Auto-connect when exactly one reachable device is found on the discovery screen",
                "デバイス発見画面で接続可能な端末が1台だけ見つかったときに自動接続する"
            ),
            icon = Icons.Default.Bolt
        ) {
            Switch(
                checked = appSettings.autoConnect,
                onCheckedChange = onAutoConnectChange
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("通知", "Notifications", "通知"),
            subtitle = t("接收连接和状态通知", "Receive connection and status notifications", "接続状態の通知を受け取る"),
            icon = Icons.Default.Notifications
        ) {
            Switch(
                checked = appSettings.notificationsEnabled,
                onCheckedChange = onNotificationsChange
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("动态取色", "Dynamic Color", "ダイナミックカラー"),
            subtitle = t("跟随系统壁纸提取主题色", "Derive accent colors from the system wallpaper", "システム壁紙からアクセントカラーを取得する"),
            icon = Icons.Default.Palette
        ) {
            Switch(
                checked = appSettings.useDynamicColor,
                onCheckedChange = onUseDynamicColorChange
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("触觉反馈", "Haptic Feedback", "触覚フィードバック"),
            subtitle = t("切换标签和应用参数时使用轻触反馈", "Use light haptics when switching tabs and applying changes", "タブ切替や設定適用時に軽い触覚フィードバックを使う"),
            icon = Icons.Default.Vibration
        ) {
            Switch(
                checked = appSettings.hapticFeedback,
                onCheckedChange = onHapticFeedbackChange
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("保持屏幕常亮", "Keep Screen Awake", "画面を常時点灯"),
            subtitle = t("使用 SkyBridge Compass 时阻止屏幕自动熄灭", "Prevent the screen from turning off while using SkyBridge Compass", "SkyBridge Compass の使用中に画面が消灯しないようにする"),
            icon = Icons.Default.StayCurrentPortrait
        ) {
            Switch(
                checked = appSettings.keepScreenOn,
                onCheckedChange = onKeepScreenOnChange
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("实时天气", "Real-Time Weather", "リアルタイム天気"),
            subtitle = t(
                "在仪表板显示当前天气与空气质量，并驱动动态天气背景；开启后按需读取粗略位置",
                "Show live weather and air quality on the dashboard and drive the animated background; uses approximate location when on",
                "ダッシュボードに現在の天気と空気質を表示し、背景アニメーションに反映します。オンのときのみおおよその位置を利用します"
            ),
            icon = Icons.Default.WbSunny
        ) {
            Switch(
                checked = appSettings.realTimeWeatherEnabled,
                onCheckedChange = onRealTimeWeatherChange
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("电池优化提醒", "Battery Optimization Warning", "バッテリー最適化の警告"),
            subtitle = t("提示关闭系统电池优化，避免后台连接被系统中断", "Warn when Android battery optimization may interrupt background connections", "Android の電池最適化がバックグラウンド接続を中断する可能性がある場合に警告する"),
            icon = Icons.Default.BatteryAlert
        ) {
            Switch(
                checked = appSettings.showBatteryOptimizationWarning,
                onCheckedChange = onBatteryOptimizationWarningChange
            )
        }
    }
}

/** Was `private fun AppLanguageSelector` in SettingsScreen.kt. */
@Composable
private fun AppLanguageSelector(
    selectedLanguage: String,
    onLanguageSelected: (String) -> Unit
) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        LanguageOptionChip(
            label = resolveLanguageLabel(APP_LANGUAGE_SYSTEM, "系统", "System", "システム"),
            selected = selectedLanguage == APP_LANGUAGE_SYSTEM,
            onClick = { onLanguageSelected(APP_LANGUAGE_SYSTEM) },
            modifier = Modifier.weight(1f)
        )
        LanguageOptionChip(
            label = "中文",
            selected = selectedLanguage == APP_LANGUAGE_ZH,
            onClick = { onLanguageSelected(APP_LANGUAGE_ZH) },
            modifier = Modifier.weight(1f)
        )
        LanguageOptionChip(
            label = "EN",
            selected = selectedLanguage == APP_LANGUAGE_EN,
            onClick = { onLanguageSelected(APP_LANGUAGE_EN) },
            modifier = Modifier.weight(1f)
        )
        LanguageOptionChip(
            label = "日本語",
            selected = selectedLanguage == APP_LANGUAGE_JA,
            onClick = { onLanguageSelected(APP_LANGUAGE_JA) },
            modifier = Modifier.weight(1f)
        )
    }
}

/** Was `private fun LanguageOptionChip` in SettingsScreen.kt. */
@Composable
private fun LanguageOptionChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    LiquidGlassSurface(
        modifier = modifier,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(999.dp),
        blurRadius = 0.dp,
        tintColor = if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.20f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.10f),
        tintAlpha = if (selected) 0.20f else 0.10f,
        borderAlpha = if (selected) 0.20f else 0.10f,
        highlightAlpha = if (selected) 0.08f else 0.04f,
        edgeGlowAlpha = if (selected) 0.06f else 0.02f,
        shadowElevation = 0.dp,
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 10.dp, vertical = 6.dp),
        onClick = onClick
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
        )
    }
}
