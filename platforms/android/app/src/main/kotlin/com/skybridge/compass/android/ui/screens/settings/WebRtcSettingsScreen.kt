package com.skybridge.compass.android.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Public
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.core.data.NetworkSettings
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WebRtcSettingsScreen(
    navController: NavController,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    val scope = rememberCoroutineScope()
    val settings by viewModel.networkSettings.collectAsState(initial = NetworkSettings())

    var signalingUrl by remember(settings.webrtcSignalingUrl) { mutableStateOf(settings.webrtcSignalingUrl) }
    var stunServersInput by remember(settings.stunServers) { mutableStateOf(settings.stunServers.joinToString(",")) }
    var turnServersInput by remember(settings.turnServers) { mutableStateOf(settings.turnServers.joinToString(",")) }
    var validationMessage by remember { mutableStateOf<String?>(null) }

    fun parseServers(input: String): List<String> =
        input
            .split(',', '\n', '\r', '\t', ' ')
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(t("跨网 WebRTC", "Cross-network WebRTC", "クロスネットワーク WebRTC")) },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = t("返回", "Back", "戻る"))
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Public, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(t("启用跨网连接", "Enable Cross-network Connection", "クロスネットワーク接続を有効化"), style = MaterialTheme.typography.titleMedium)
                            Text(
                                t(
                                    "通过信令 + ICE（STUN/TURN）建立 WebRTC DataChannel，用于跨网文件传输/远程桌面。",
                                    "Create a WebRTC DataChannel with signaling and ICE (STUN/TURN) for cross-network file transfer and remote desktop.",
                                    "シグナリングと ICE（STUN/TURN）で WebRTC DataChannel を確立し、クロスネットワークのファイル転送やリモートデスクトップに使います。"
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Switch(
                            checked = settings.webrtcEnabled,
                            onCheckedChange = { enabled ->
                                viewModel.setWebRtcEnabled(enabled)
                            }
                        )
                    }
                }
            }

            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(t("信令服务器", "Signaling Server", "シグナリングサーバー"), style = MaterialTheme.typography.titleMedium)
                    OutlinedTextField(
                        value = signalingUrl,
                        onValueChange = { signalingUrl = it },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        enabled = settings.webrtcEnabled,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        label = { Text("WebSocket URL") },
                        placeholder = { Text("wss://api.nebula-technologies.net/ws") }
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            enabled = settings.webrtcEnabled,
                            onClick = {
                                scope.launch {
                                    runCatching {
                                        viewModel.setWebRtcSignalingUrl(signalingUrl)
                                    }.onSuccess {
                                        validationMessage = null
                                    }.onFailure { error ->
                                        validationMessage = error.message ?: t("信令地址无效", "Invalid signaling URL", "シグナリング URL が無効です")
                                    }
                                }
                            }
                        ) { Text(t("应用", "Apply", "適用")) }
                    }
                    validationMessage?.let { message ->
                        Text(
                            text = message,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                }
            }

            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(t("ICE 服务器", "ICE Servers", "ICE サーバー"), style = MaterialTheme.typography.titleMedium)

                    OutlinedTextField(
                        value = stunServersInput,
                        onValueChange = { stunServersInput = it },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = settings.webrtcEnabled,
                        label = { Text(t("STUN（逗号分隔）", "STUN (comma separated)", "STUN（カンマ区切り）")) },
                        placeholder = { Text("stun:54.92.79.99:3478") }
                    )
                    OutlinedTextField(
                        value = turnServersInput,
                        onValueChange = { turnServersInput = it },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = settings.webrtcEnabled,
                        label = { Text(t("TURN（逗号分隔）", "TURN (comma separated)", "TURN（カンマ区切り）")) },
                        placeholder = { Text("turn:54.92.79.99:3478") }
                    )

                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            enabled = settings.webrtcEnabled,
                            onClick = {
                                scope.launch {
                                    runCatching {
                                        viewModel.setStunServers(parseServers(stunServersInput))
                                        viewModel.setTurnServers(parseServers(turnServersInput))
                                    }.onSuccess {
                                        validationMessage = null
                                    }.onFailure { error ->
                                        validationMessage = error.message ?: t("ICE 配置无效", "Invalid ICE configuration", "ICE 設定が無効です")
                                    }
                                }
                            }
                        ) { Text(t("保存 ICE", "Save ICE", "ICE を保存")) }
                    }
                    validationMessage?.let { message ->
                        Text(
                            text = message,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error
                        )
                    }

                    Spacer(Modifier.height(4.dp))
                    Text(
                        t(
                            "提示：默认 TURN 凭据会通过 /api/turn/credentials 动态获取；这里的 TURN URL 用于覆盖服务器地址。",
                            "Tip: TURN credentials are normally fetched dynamically from /api/turn/credentials; the TURN URL here only overrides the server address.",
                            "ヒント：TURN 資格情報は通常 /api/turn/credentials から動的に取得されます。ここでの TURN URL はサーバーアドレスの上書きのみを行います。"
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}
