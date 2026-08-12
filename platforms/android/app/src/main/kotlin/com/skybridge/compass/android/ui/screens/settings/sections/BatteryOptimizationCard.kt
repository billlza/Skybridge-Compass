package com.skybridge.compass.android.ui.screens.settings.sections

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.LiquidGlassSurface

/**
 * The conditional battery-optimization warning card — extracted verbatim from SettingsScreen.kt.
 * Rendered only when `shouldShowBatteryOptimizationCard` is true (gating decision stays in the
 * screen so this composable has no behavior beyond the card itself).
 */
@Composable
fun BatteryOptimizationCard() {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val context = LocalContext.current

    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        blurRadius = 0.dp,
        tintColor = MaterialTheme.colorScheme.error.copy(alpha = 0.08f),
        tintAlpha = 0.08f,
        borderAlpha = 0.14f,
        highlightAlpha = 0.02f,
        edgeGlowAlpha = 0.02f,
        contentPadding = PaddingValues(16.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = t("建议关闭电池优化", "Battery optimization should be disabled", "バッテリー最適化を無効にすることを推奨"),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold
            )
            Text(
                text = t("否则后台发现、文件传输和远控连接可能被系统暂停。", "Otherwise device discovery, file transfer, and remote-control sessions may be paused in the background.", "無効にしない場合、バックグラウンドでのデバイス検出、ファイル転送、リモート接続が停止されることがあります。"),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            TextButton(
                onClick = {
                    val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    runCatching { context.startActivity(intent) }
                }
            ) {
                Text(t("打开系统电池设置", "Open Battery Settings", "バッテリー設定を開く"))
            }
        }
    }
}
