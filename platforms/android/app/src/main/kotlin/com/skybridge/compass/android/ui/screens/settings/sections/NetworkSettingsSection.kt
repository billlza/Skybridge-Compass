package com.skybridge.compass.android.ui.screens.settings.sections

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.unit.dp
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.GroupedGlassDivider
import com.skybridge.compass.android.ui.components.GroupedGlassRow
import com.skybridge.compass.android.ui.components.GroupedGlassSection
import com.skybridge.compass.android.ui.screens.settings.CompactInlineNumberField
import com.skybridge.compass.android.ui.screens.settings.InlineApplyButton
import com.skybridge.compass.android.ui.screens.settings.InlineSavedIndicator
import com.skybridge.compass.android.ui.screens.settings.SettingSaveFailure
import com.skybridge.compass.android.ui.screens.settings.networkSettingRejectionMessage
import com.skybridge.compass.android.ui.screens.settings.settingSaveFailureMessage
import com.skybridge.compass.core.data.NetworkSettingField
import com.skybridge.compass.core.data.NetworkSettingRejection
import com.skybridge.compass.core.data.NetworkSettings
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * "网络 / Network" grouped section — extracted verbatim from SettingsScreen.kt.
 *
 * Owns the same composable-local inline-editor state the original screen held:
 * `portStartInput`/`portEndInput`/`discoveryTimeoutSecInput`/`maxReconnectInput`, the
 * `networkAdvancedExpanded` toggle, the `*SavedAtMs` indicators, and the `LaunchedEffect(netSettings)`
 * that re-syncs the inputs whenever the persisted settings change. The apply buttons call back into
 * the ViewModel intents (which delegate to `NetworkSettingsStore.set...`) exactly as before, with the
 * identical haptic gate and the 1100ms "Saved" indicator window.
 */
@Composable
fun NetworkSettingsSection(
    netSettings: NetworkSettings,
    hapticFeedbackEnabled: Boolean,
    validationErrors: Map<NetworkSettingField, NetworkSettingRejection>,
    saveFailures: Map<String, SettingSaveFailure> = emptyMap(),
    onSetPortRange: (rawStart: String, rawEnd: String) -> Unit,
    onSetDiscoveryTimeoutSec: (rawSeconds: String) -> Unit,
    onSetMaxReconnectAttempts: (rawAttempts: String) -> Unit,
    onClearValidationError: (Array<NetworkSettingField>) -> Unit,
    onOpenWebRtcSettings: () -> Unit
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current

    var portStartInput by remember { mutableStateOf(netSettings.portRangeStart.toString()) }
    var portEndInput by remember { mutableStateOf(netSettings.portRangeEnd.toString()) }
    var discoveryTimeoutSecInput by remember { mutableStateOf((netSettings.discoveryTimeoutMs / 1000).toString()) }
    var maxReconnectInput by remember { mutableStateOf(netSettings.maxReconnectAttempts.toString()) }
    var networkAdvancedExpanded by rememberSaveable { mutableStateOf(false) }

    val portFields = remember {
        arrayOf(NetworkSettingField.PORT_RANGE_START, NetworkSettingField.PORT_RANGE_END)
    }
    val discoveryFields = remember { arrayOf(NetworkSettingField.DISCOVERY_TIMEOUT_MS) }
    val reconnectFields = remember { arrayOf(NetworkSettingField.MAX_RECONNECT_ATTEMPTS) }

    var portsSavedAtMs by remember { mutableLongStateOf(0L) }
    var discoverySavedAtMs by remember { mutableLongStateOf(0L) }
    var reconnectSavedAtMs by remember { mutableLongStateOf(0L) }

    LaunchedEffect(netSettings) {
        portStartInput = netSettings.portRangeStart.toString()
        portEndInput = netSettings.portRangeEnd.toString()
        discoveryTimeoutSecInput = (netSettings.discoveryTimeoutMs / 1000).toString()
        maxReconnectInput = netSettings.maxReconnectAttempts.toString()
    }

    // R7.12 的显示值回滚（文本框专属）。
    //
    // 开关/单选的显示值直接来自持久化流，写入失败时 DataStore 未改变、流不发射，显示值天然
    // 停留在写入前的值——回滚是结构性的。但文本框另有一份本地编辑状态，写入失败时上面那个
    // `LaunchedEffect(netSettings)` **不会**触发（netSettings 没变），用户刚输入的值会留在框里，
    // 与「已持久化值」不一致。因此这里在失败发生时显式把本地状态丢弃、重新以持久化值为准。
    LaunchedEffect(saveFailures) {
        if (saveFailures.keys.any { it.startsWith("network.") }) {
            portStartInput = netSettings.portRangeStart.toString()
            portEndInput = netSettings.portRangeEnd.toString()
            discoveryTimeoutSecInput = (netSettings.discoveryTimeoutMs / 1000).toString()
            maxReconnectInput = netSettings.maxReconnectAttempts.toString()
        }
    }

    GroupedGlassSection(title = t("网络", "Network", "ネットワーク")) {
        GroupedGlassRow(
            title = t("连接参数", "Connection Parameters", "接続パラメータ"),
            subtitle = t(
                "端口 ${netSettings.portRangeStart}-${netSettings.portRangeEnd} · 超时 ${netSettings.discoveryTimeoutMs / 1000}s · 重试 ${netSettings.maxReconnectAttempts}",
                "Ports ${netSettings.portRangeStart}-${netSettings.portRangeEnd} · Timeout ${netSettings.discoveryTimeoutMs / 1000}s · Retries ${netSettings.maxReconnectAttempts}",
                "ポート ${netSettings.portRangeStart}-${netSettings.portRangeEnd} ・ タイムアウト ${netSettings.discoveryTimeoutMs / 1000}s ・ 再試行 ${netSettings.maxReconnectAttempts}"
            ),
            icon = Icons.Default.Tune,
            onClick = { networkAdvancedExpanded = !networkAdvancedExpanded }
        ) {
            TextButton(onClick = { networkAdvancedExpanded = !networkAdvancedExpanded }) {
                Text(if (networkAdvancedExpanded) t("收起", "Collapse", "閉じる") else t("展开", "Expand", "展開"))
            }
        }

        AnimatedVisibility(visible = networkAdvancedExpanded) {
            Column {
                GroupedGlassDivider()

                GroupedGlassRow(
                    title = t("端口范围", "Port Range", "ポート範囲"),
                    subtitle = t(
                        "当前: ${netSettings.portRangeStart}-${netSettings.portRangeEnd}",
                        "Current: ${netSettings.portRangeStart}-${netSettings.portRangeEnd}",
                        "現在: ${netSettings.portRangeStart}-${netSettings.portRangeEnd}"
                    ),
                    icon = Icons.Default.Settings
                ) {
                    val portsDirty =
                        portStartInput != netSettings.portRangeStart.toString() ||
                            portEndInput != netSettings.portRangeEnd.toString()
                    // R7.8 的范围提示优先；若本次是「值合法但写入失败」，则给出 R7.12 的
                    // 「保存未生效」提示。两者复用同一个既有叶节点，不新增节点。
                    val portError = portFields
                        .firstNotNullOfOrNull { validationErrors[it] }
                        ?.let(::networkSettingRejectionMessage)
                        ?: saveFailures["network.port-range-start"]?.let(::settingSaveFailureMessage)

                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        CompactInlineNumberField(
                            value = portStartInput,
                            placeholder = t("起始", "Start", "開始"),
                            onValueChange = {
                                portsSavedAtMs = 0L
                                onClearValidationError(portFields)
                                portStartInput = it.filter { ch -> ch.isDigit() }.take(5)
                            }
                        )
                        Text("—", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        CompactInlineNumberField(
                            value = portEndInput,
                            placeholder = t("结束", "End", "終了"),
                            onValueChange = {
                                portsSavedAtMs = 0L
                                onClearValidationError(portFields)
                                portEndInput = it.filter { ch -> ch.isDigit() }.take(5)
                            }
                        )
                        InlineSavedIndicator(savedAtMs = portsSavedAtMs, errorMessage = portError)
                        InlineApplyButton(
                            enabled = portsDirty,
                            onClick = {
                                if (hapticFeedbackEnabled) {
                                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                }
                                // R7.8: 原始字符串交给校验面，空/非数值/越界一律拒绝且不写入。
                                onSetPortRange(portStartInput, portEndInput)
                                scope.launch {
                                    portsSavedAtMs = System.currentTimeMillis()
                                    delay(1100)
                                    portsSavedAtMs = 0L
                                }
                            }
                        )
                    }
                }

                GroupedGlassDivider()

                GroupedGlassRow(
                    title = t("发现超时", "Discovery Timeout", "探索タイムアウト"),
                    subtitle = t(
                        "当前: ${netSettings.discoveryTimeoutMs / 1000} 秒",
                        "Current: ${netSettings.discoveryTimeoutMs / 1000} sec",
                        "現在: ${netSettings.discoveryTimeoutMs / 1000} 秒"
                    ),
                    icon = Icons.Default.Timer
                ) {
                    val discoveryDirty =
                        discoveryTimeoutSecInput != (netSettings.discoveryTimeoutMs / 1000).toString()
                    val discoveryError = validationErrors[NetworkSettingField.DISCOVERY_TIMEOUT_MS]
                        ?.let(::networkSettingRejectionMessage)
                        ?: saveFailures["network.discovery-timeout"]?.let(::settingSaveFailureMessage)

                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        CompactInlineNumberField(
                            value = discoveryTimeoutSecInput,
                            placeholder = t("秒", "Sec", "秒"),
                            onValueChange = {
                                discoverySavedAtMs = 0L
                                onClearValidationError(discoveryFields)
                                discoveryTimeoutSecInput = it.filter { ch -> ch.isDigit() }.take(4)
                            }
                        )
                        InlineSavedIndicator(savedAtMs = discoverySavedAtMs, errorMessage = discoveryError)
                        InlineApplyButton(
                            enabled = discoveryDirty,
                            onClick = {
                                if (hapticFeedbackEnabled) {
                                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                }
                                // R7.8: 秒值原始字符串交给校验面换算并校验，拒绝时不写入。
                                onSetDiscoveryTimeoutSec(discoveryTimeoutSecInput)
                                scope.launch {
                                    discoverySavedAtMs = System.currentTimeMillis()
                                    delay(1100)
                                    discoverySavedAtMs = 0L
                                }
                            }
                        )
                    }
                }

                GroupedGlassDivider()

                GroupedGlassRow(
                    title = t("连接重试", "Reconnect Attempts", "再接続回数"),
                    subtitle = t(
                        "当前: ${netSettings.maxReconnectAttempts} 次",
                        "Current: ${netSettings.maxReconnectAttempts}",
                        "現在: ${netSettings.maxReconnectAttempts} 回"
                    ),
                    icon = Icons.Default.Refresh
                ) {
                    val reconnectDirty =
                        maxReconnectInput != netSettings.maxReconnectAttempts.toString()
                    val reconnectError = validationErrors[NetworkSettingField.MAX_RECONNECT_ATTEMPTS]
                        ?.let(::networkSettingRejectionMessage)
                        ?: saveFailures["network.max-reconnect-attempts"]?.let(::settingSaveFailureMessage)

                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        CompactInlineNumberField(
                            value = maxReconnectInput,
                            placeholder = t("次数", "Count", "回数"),
                            onValueChange = {
                                reconnectSavedAtMs = 0L
                                onClearValidationError(reconnectFields)
                                maxReconnectInput = it.filter { ch -> ch.isDigit() }.take(2)
                            }
                        )
                        InlineSavedIndicator(savedAtMs = reconnectSavedAtMs, errorMessage = reconnectError)
                        InlineApplyButton(
                            enabled = reconnectDirty,
                            onClick = {
                                if (hapticFeedbackEnabled) {
                                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                }
                                // R7.8: 原始字符串交给校验面，拒绝时保留原持久化值。
                                onSetMaxReconnectAttempts(maxReconnectInput)
                                scope.launch {
                                    reconnectSavedAtMs = System.currentTimeMillis()
                                    delay(1100)
                                    reconnectSavedAtMs = 0L
                                }
                            }
                        )
                    }
                }

                GroupedGlassDivider()
            }
        }

        GroupedGlassRow(
            title = t("跨网 WebRTC", "Cross-network WebRTC", "クロスネットワーク WebRTC"),
            subtitle = if (netSettings.webrtcEnabled) {
                t("已启用 · ${netSettings.webrtcSignalingUrl}", "Enabled · ${netSettings.webrtcSignalingUrl}", "有効 · ${netSettings.webrtcSignalingUrl}")
            } else {
                t("已关闭", "Disabled", "無効")
            },
            icon = Icons.Default.Public,
            onClick = onOpenWebRtcSettings
        ) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowForward,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
