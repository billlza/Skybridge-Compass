package com.skybridge.compass.android.ui.screens.settings

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.FilterCenterFocus
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.NavController
import com.skybridge.compass.android.data.RemoteDesktopCodec
import com.skybridge.compass.android.data.RemoteDesktopFrameRate
import com.skybridge.compass.android.data.RemoteDesktopQualityPreset
import com.skybridge.compass.android.data.RemoteDesktopResolution
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.GroupedGlassDivider
import com.skybridge.compass.android.ui.components.GroupedGlassRow
import com.skybridge.compass.android.ui.components.GroupedGlassSection

/**
 * Remote-desktop stream-configuration settings (Android parity with iOS `RemoteDesktopViewerSettings`).
 * Exposes the fields the macOS host actually honors: quality preset, resolution, frame rate, codec,
 * low-latency mode and hardware acceleration. All writes go through
 * [RemoteDesktopStreamSettingsViewModel] -> RemoteDesktopStreamSettingsStore, which
 * `RemoteControlViewModel.sendStreamConfiguration()` reads when pushing config to the Mac.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemoteDesktopStreamSettingsScreen(
    navController: NavController,
    viewModel: RemoteDesktopStreamSettingsViewModel = hiltViewModel()
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    val settings by viewModel.settings.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(t("画面流设置", "Stream Settings", "ストリーム設定")) },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, t("返回", "Back", "戻る"))
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                Text(
                    text = t(
                        "控制发送给被控端（Mac）的画面编码与质量策略。",
                        "Controls the screen encoding and quality strategy requested from the host (Mac).",
                        "ホスト (Mac) に要求する画面エンコードと品質方針を制御します。"
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            // Quality preset chips (mirrors iOS preset picker; templated presets apply a combo).
            item {
                GroupedGlassSection(title = t("画质模式", "Quality Preset", "画質モード")) {
                    Column(modifier = Modifier.padding(12.dp)) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            RemoteDesktopQualityPreset.entries.forEach { preset ->
                                FilterChip(
                                    selected = settings.qualityPreset == preset,
                                    onClick = { viewModel.setQualityPreset(preset) },
                                    label = { Text(preset.displayName) },
                                    colors = FilterChipDefaults.filterChipColors()
                                )
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = settings.qualityPreset.detail,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // Resolution selector.
            item {
                GroupedGlassSection(title = t("分辨率", "Resolution", "解像度")) {
                    Column {
                        RemoteDesktopResolution.entries.forEachIndexed { idx, resolution ->
                            OptionRow(
                                label = resolution.displayName,
                                selected = settings.resolution == resolution,
                                onClick = { viewModel.setResolution(resolution) }
                            )
                            if (idx != RemoteDesktopResolution.entries.lastIndex) GroupedGlassDivider()
                        }
                    }
                }
            }

            // Frame rate selector.
            item {
                GroupedGlassSection(title = t("帧率", "Frame Rate", "フレームレート")) {
                    Column {
                        RemoteDesktopFrameRate.entries.forEachIndexed { idx, frameRate ->
                            OptionRow(
                                label = frameRate.displayName,
                                selected = settings.frameRate == frameRate,
                                onClick = { viewModel.setFrameRate(frameRate) }
                            )
                            if (idx != RemoteDesktopFrameRate.entries.lastIndex) GroupedGlassDivider()
                        }
                    }
                }
            }

            // Codec selector.
            item {
                GroupedGlassSection(title = t("编码器", "Codec", "コーデック")) {
                    Column {
                        RemoteDesktopCodec.entries.forEachIndexed { idx, codec ->
                            OptionRow(
                                label = codec.displayName,
                                selected = settings.preferredCodec == codec,
                                onClick = { viewModel.setPreferredCodec(codec) }
                            )
                            if (idx != RemoteDesktopCodec.entries.lastIndex) GroupedGlassDivider()
                        }
                    }
                }
            }

            // Advanced toggles.
            item {
                GroupedGlassSection(title = t("高级", "Advanced", "詳細")) {
                    Column {
                        GroupedGlassRow(
                            title = t("低延迟模式", "Low-Latency Mode", "低遅延モード"),
                            subtitle = t(
                                "降低关键帧间隔，弱网与高刷下更跟手",
                                "Shorter key-frame interval, snappier on weak or high-refresh links",
                                "キーフレーム間隔を短縮し、弱回線や高リフレッシュでも追従"
                            ),
                            icon = Icons.Default.Speed,
                            trailing = {
                                Switch(
                                    checked = settings.lowLatencyMode,
                                    onCheckedChange = { viewModel.setLowLatencyMode(it) }
                                )
                            }
                        )
                        GroupedGlassDivider()
                        GroupedGlassRow(
                            title = t("硬件解码加速", "Hardware Acceleration", "ハードウェアアクセラレーション"),
                            subtitle = t(
                                "请求被控端优先走硬件编码管线",
                                "Ask the host to prefer its hardware encode pipeline",
                                "ホストにハードウェアエンコードを優先するよう要求します"
                            ),
                            icon = Icons.Default.Memory,
                            trailing = {
                                Switch(
                                    checked = settings.enableHardwareAcceleration,
                                    onCheckedChange = { viewModel.setEnableHardwareAcceleration(it) }
                                )
                            }
                        )
                    }
                }
            }

            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Default.FilterCenterFocus,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.height(16.dp)
                    )
                    Spacer(Modifier.height(0.dp))
                    Text(
                        text = t(
                            "  剪贴板同步在「访问控制」中开关。",
                            "  Clipboard sync is toggled in Access Control.",
                            "  クリップボード同期は「アクセス制御」で切り替えます。"
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun OptionRow(
    label: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .selectable(selected = selected, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        RadioButton(selected = selected, onClick = onClick)
        Spacer(Modifier.height(0.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
            modifier = Modifier.padding(start = 8.dp)
        )
    }
}
