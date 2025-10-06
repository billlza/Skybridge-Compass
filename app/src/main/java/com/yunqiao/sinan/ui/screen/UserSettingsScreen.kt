package com.yunqiao.sinan.ui.screen

import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.BatterySaver
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.RocketLaunch
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.data.getThermalStatusText
import com.yunqiao.sinan.manager.PerformanceProfile
import com.yunqiao.sinan.manager.PerformanceProfileController
import kotlin.math.roundToInt
import java.util.Locale
import kotlin.math.max

@Composable
fun UserSettingsScreen(
    modifier: Modifier = Modifier,
    performanceProfileController: PerformanceProfileController = rememberPerformanceProfileController()
) {
    val profile by performanceProfileController.profile.collectAsState()
    val targetDuration by performanceProfileController.targetDurationNanos.collectAsState()
    val thermalStatus by performanceProfileController.thermalStatus.collectAsState()
    val powerSaveActive by performanceProfileController.powerSaveActive.collectAsState()

    val scrollState = rememberScrollState()
    val context = LocalContext.current

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(scrollState)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = "系统设置",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold
            )
            Text(
                text = "为云桥司南调校性能模式、能效策略与系统联动选项",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                text = "性能模式",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold
            )

            PerformanceProfile.values().forEach { option ->
                PerformanceModeOption(
                    profile = option,
                    selected = profile == option,
                    onSelect = { performanceProfileController.setProfile(option) }
                )
            }
        }

        PerformanceTelemetryCard(
            targetDuration = targetDuration,
            thermalStatus = thermalStatus,
            powerSaveActive = powerSaveActive
        )

        ElevatedCard(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(18.dp),
            colors = CardDefaults.elevatedCardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f)
            )
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Text(
                    text = "系统快捷入口",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )

                SettingsActionRow(
                    label = "电池优化设置",
                    description = "查看或调整系统省电策略，保障后台链路稳定",
                    onClick = { launchSystemIntent(context, Settings.ACTION_BATTERY_SAVER_SETTINGS) }
                )

                SettingsActionRow(
                    label = "开发者图像调校",
                    description = "跳转到开发者选项，手动设定最高刷新率或禁用动画",
                    onClick = { launchSystemIntent(context, Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS) }
                )
            }
        }
    }
}

@Composable
private fun PerformanceModeOption(
    profile: PerformanceProfile,
    selected: Boolean,
    onSelect: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val descriptor = when (profile) {
        PerformanceProfile.POWER_SAVE -> ModeDescriptor(
            title = "省电模式",
            description = "降低刷新节奏并启用能效提示，适合低电量或旅途中使用",
            icon = Icons.Default.BatterySaver,
            tint = colorScheme.tertiary
        )
        PerformanceProfile.AUTOMATIC -> ModeDescriptor(
            title = "自动模式",
            description = "根据热状态与系统省电模式自适应画质与刷新率",
            icon = Icons.Default.AutoAwesome,
            tint = colorScheme.primary
        )
        PerformanceProfile.HIGH_PERFORMANCE -> ModeDescriptor(
            title = "高性能",
            description = "启用硬件级镜像与高帧传输，保持远程桌面无损体验",
            icon = Icons.Default.RocketLaunch,
            tint = colorScheme.secondary
        )
    }
    val (title, description, icon, tint) = descriptor

    val background = if (selected) colorScheme.primary.copy(alpha = 0.12f) else colorScheme.surface
    val contentColor = if (selected) colorScheme.primary else colorScheme.onSurfaceVariant

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .clickable(onClick = onSelect),
        color = background,
        tonalElevation = if (selected) 4.dp else 0.dp
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(28.dp)
            )

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = colorScheme.onSurface
                )
                Text(
                    text = description,
                    style = MaterialTheme.typography.bodySmall,
                    color = contentColor
                )
            }

            RadioButton(selected = selected, onClick = onSelect)
        }
    }
}

@Composable
private fun PerformanceTelemetryCard(
    targetDuration: Long?,
    thermalStatus: Int,
    powerSaveActive: Boolean
) {
    val colorScheme = MaterialTheme.colorScheme
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.elevatedCardColors(
            containerColor = colorScheme.surfaceVariant.copy(alpha = 0.4f)
        )
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                text = "实时性能状态",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold
            )

            InfoRow(
                label = "Hint 目标帧间隔",
                value = formatTargetDuration(targetDuration)
            )

            InfoRow(
                label = "系统省电模式",
                value = if (powerSaveActive) "已启用" else "未启用"
            )

            InfoRow(
                label = "当前热状态",
                value = getThermalStatusText(thermalStatus)
            )
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.primary,
            textAlign = TextAlign.End
        )
    }
}

@Composable
private fun SettingsActionRow(label: String, description: String, onClick: () -> Unit) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClick = onClick),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 1.dp
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Icon(
                imageVector = Icons.Default.OpenInNew,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = label,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium
                )
                Text(
                    text = description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            IconButton(onClick = onClick) {
                Icon(
                    imageVector = Icons.Default.Info,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary
                )
            }
        }
    }
}

private fun formatTargetDuration(target: Long?): String {
    return if (target == null) {
        "自动调节"
    } else {
        val millis = target / 1_000_000.0
        val fps = max((1_000_000_000.0 / target).roundToInt(), 1)
        String.format(Locale.getDefault(), "%.1f ms (%d FPS)", millis, fps)
    }
}

private fun launchSystemIntent(context: Context, action: String) {
    runCatching {
        val intent = Intent(action).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        context.startActivity(intent)
    }
}

private data class ModeDescriptor(
    val title: String,
    val description: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val tint: Color
)

@Composable
fun rememberPerformanceProfileController(): PerformanceProfileController {
    val context = LocalContext.current
    return remember { PerformanceProfileController(context) }
}
