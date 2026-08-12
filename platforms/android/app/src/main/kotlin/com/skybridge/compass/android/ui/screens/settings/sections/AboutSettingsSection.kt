package com.skybridge.compass.android.ui.screens.settings.sections

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import com.skybridge.compass.BuildConfig
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.GroupedGlassDivider
import com.skybridge.compass.android.ui.components.GroupedGlassRow
import com.skybridge.compass.android.ui.components.GroupedGlassSection
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.android.ui.screens.settings.Setting
import com.skybridge.compass.android.ui.theme.IOSParityTokens

/**
 * Builds the "关于 / About" item list — extracted verbatim from SettingsScreen.kt (the original
 * `aboutSettingItems`). The screen still renders these via `items(aboutSettingItems) { SettingCard(...) }`
 * so each entry navigates to the same route. Exposed as a builder (not a Composable) because the
 * original list is consumed by the LazyColumn's `items(...)` overload.
 */
@Composable
fun rememberAboutSettingItems(): List<Setting> {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    return listOf(
        Setting(
            title = t("版本信息", "Version Info", "バージョン情報"),
            description = t("查看应用版本和更新", "View app version and build details", "アプリのバージョンとビルド情報を確認する"),
            icon = Icons.Default.Info,
            value = BuildConfig.VERSION_NAME,
            route = Screen.VersionInfo.route
        ),
        Setting(
            title = t("帮助与支持", "Help & Support", "ヘルプとサポート"),
            description = t("获取使用帮助和技术支持", "Open documentation and support options", "利用ガイドとサポート窓口を開く"),
            icon = Icons.Default.Info,
            route = Screen.HelpSupport.route
        ),
        Setting(
            title = t("反馈建议", "Feedback", "フィードバック"),
            description = t("提交问题反馈和功能建议", "Send bug reports and feature ideas", "不具合報告や機能提案を送信する"),
            icon = Icons.AutoMirrored.Filled.Send,
            route = Screen.Feedback.route
        ),
        Setting(
            title = t("开源许可", "Open Source Licenses", "オープンソースライセンス"),
            description = t("查看开源组件许可信息", "Review open-source component licenses", "オープンソースコンポーネントのライセンスを確認する"),
            icon = Icons.Default.Info,
            route = Screen.OpenSourceLicenses.route
        )
    )
}

@Composable
fun AboutSettingsSectionGrouped(
    aboutSettingItems: List<Setting>,
    onNavigate: (String) -> Unit
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    GroupedGlassSection(title = t("关于", "About", "情報")) {
        aboutSettingItems.forEachIndexed { idx, setting ->
            GroupedGlassRow(
                title = setting.title,
                subtitle = setting.description,
                icon = setting.icon,
                onClick = { setting.route?.let { onNavigate(it) } }
            ) {
                if (setting.value != null) {
                    Text(
                        text = setting.value,
                        style = MaterialTheme.typography.bodySmall,
                        color = IOSParityTokens.ColorTokens.CyanAccent
                    )
                }
                Icon(
                    Icons.AutoMirrored.Filled.ArrowForward,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (idx != aboutSettingItems.lastIndex) {
                GroupedGlassDivider()
            }
        }
    }
}
