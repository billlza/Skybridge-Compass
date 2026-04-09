package com.skybridge.compass.android.ui.screens.filetransfer

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import androidx.navigation.compose.rememberNavController
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.data.DeveloperSettingsStore
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.filetransfer.AndroidInboundFileTransferApprovalProvider
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.security.toHandshakePolicyOverride
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.core.webrtc.AndroidCrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import kotlinx.coroutines.launch
import java.util.UUID

@Composable
private fun t(zh: String, en: String, ja: String): String = localizedText(zh, en, ja)

@Composable
fun FileTransferScreen(navController: NavController) {
    val featureDisabledTitle = localizedText(
        "文件传输已在设置中关闭",
        "File transfer is disabled in Settings",
        "ファイル転送は設定で無効になっています"
    )
    val featureDisabledMessage = localizedText(
        "请前往 设置 > 深度开发设置 重新启用。",
        "Go to Settings > Advanced Developer Settings to enable it again.",
        "設定 > 開発者向け詳細設定 で再度有効にしてください。"
    )
    val openSettingsLabel = localizedText("打开设置", "Open Settings", "設定を開く")
    val context = LocalContext.current
    val appContext = remember(context) { context.applicationContext }
    val scope = rememberCoroutineScope()
    val devSettings by DeveloperSettingsStore.observe(context).collectAsState(initial = DeveloperSettings())

    if (!devSettings.enableFileTransfer) {
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
            Button(onClick = { navController.navigate(com.skybridge.compass.android.ui.navigation.Screen.Settings.route) { launchSingleTop = true } }) {
                Text(openSettingsLabel)
            }
        }
        return
    }

    val securitySettings by SecuritySettingsStore.observe(context)
        .collectAsState(initial = SecuritySettings())

    val webrtcResult = remember(appContext) {
        runCatching {
            AndroidCrossNetworkWebRtcTransportAdapter(
                SkyBridgeWebRtcConnectionManager(appContext)
            )
        }
    }
    val webrtc = webrtcResult.getOrNull()
    if (webrtc == null) {
        FileTransferInitError(
            message = webrtcResult.exceptionOrNull()?.message ?: t("WebRTC 初始化失败", "WebRTC initialization failed", "WebRTC の初期化に失敗しました")
        )
        return
    }

    val inboundApprovalProvider = remember(appContext) { AndroidInboundFileTransferApprovalProvider(appContext) }
    val transferControllerResult = remember(webrtc, inboundApprovalProvider, appContext) {
        runCatching {
            WebRtcFileTransferController(
                webrtc = webrtc,
                appContext = appContext,
                inboundApprovalProvider = inboundApprovalProvider,
                saveAcceptedInboundToDownloads = true
            )
        }
    }
    val transferController = transferControllerResult.getOrNull()
    if (transferController == null) {
        FileTransferInitError(
            message = transferControllerResult.exceptionOrNull()?.message ?: t("文件传输控制器初始化失败", "File transfer controller initialization failed", "ファイル転送コントローラーの初期化に失敗しました")
        )
        return
    }

    LaunchedEffect(
        securitySettings.pqcEnabled,
        securitySettings.enforcePqcHandshake,
        securitySettings.allowClassicFallbackForCompatibility,
        securitySettings.pqcMinimumTier,
        securitySettings.requireSecureEnclavePoP,
        webrtc
    ) {
        webrtc.setPqcEnabled(securitySettings.pqcEnabled)
        webrtc.setHandshakePolicyOverride(securitySettings.toHandshakePolicyOverride())
    }

    var codeInput by rememberSaveable { mutableStateOf("") }
    var statusMessage by rememberSaveable { mutableStateOf(resolveLocalizedText("等待建立连接", "Waiting for connection", "接続待機中")) }
    var generatedCode by rememberSaveable { mutableStateOf("") }
    val inboundLogs = remember { mutableStateListOf<String>() }

    val connState by webrtc.state.collectAsState()
    val signalingStatus by webrtc.signalingStatus.collectAsState()
    val progress by transferController.progress.collectAsState()
    val transferEnabled = securitySettings.allowFileTransfer
    val connected = connState is SkyBridgeWebRtcConnectionManager.State.Connected

    DisposableEffect(webrtc, transferController) {
        webrtc.onData = { bytes ->
            transferController.handleIncoming(bytes)
        }
        onDispose {
            webrtc.disconnect()
        }
    }

    LaunchedEffect(transferController) {
        transferController.receivedFiles.collect { file ->
            val label = file.localPath ?: file.fileName ?: file.transferId
            inboundLogs.add(0, resolveLocalizedText("已接收: $label", "Received: $label", "受信済み: $label"))
            statusMessage = resolveLocalizedText("接收完成: $label", "Receive complete: $label", "受信完了: $label")
        }
    }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        if (!transferEnabled) {
            statusMessage = resolveLocalizedText("文件传输已在设置中关闭", "File transfer is disabled in Settings", "ファイル転送は設定で無効になっています")
            return@rememberLauncherForActivityResult
        }
        if (!connected) {
            statusMessage = resolveLocalizedText("请先建立 WebRTC 连接", "Please establish a WebRTC connection first", "先に WebRTC 接続を確立してください")
            return@rememberLauncherForActivityResult
        }

        val resolver = context.contentResolver
        val fileName = queryDisplayName(context, uri) ?: "android-file-${System.currentTimeMillis()}"
        val mime = resolver.getType(uri)

        runCatching {
            resolver.takePersistableUriPermission(
                uri,
                android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        }

        scope.launch {
            val transferId = "android-${UUID.randomUUID()}"
            runCatching {
                transferController.sendFile(
                    contentResolver = resolver,
                    uri = uri,
                    transferId = transferId,
                    fileName = fileName,
                    mimeType = mime,
                    chunkSize = 128 * 1024
                )
            }.onSuccess {
                statusMessage = resolveLocalizedText("已发送: $fileName", "Sent: $fileName", "送信済み: $fileName")
            }.onFailure {
                statusMessage = resolveLocalizedText(
                    "发送失败: ${it.message ?: "未知错误"}",
                    "Send failed: ${it.message ?: "unknown"}",
                    "送信失敗: ${it.message ?: "不明"}"
                )
            }
        }
    }

    val pct = if (progress.totalBytes > 0) {
        (progress.sentBytes * 100 / progress.totalBytes).toInt().coerceIn(0, 100)
    } else {
        0
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        contentPadding = PaddingValues(top = 8.dp, bottom = 120.dp)
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = t("文件传输", "File Transfer", "ファイル転送"),
                    style = MaterialTheme.typography.headlineLarge,
                    color = Color.White,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f)
                )
                IconButton(onClick = { filePicker.launch(arrayOf("*/*")) }) {
                    Icon(
                        imageVector = Icons.Filled.Add,
                        contentDescription = t("选择文件", "Select File", "ファイルを選択"),
                        tint = Color(0xFF7CC0FF)
                    )
                }
            }
        }

        item {
            QuickSendSection(
                codeInput = codeInput,
                onCodeChange = { codeInput = it.uppercase() },
                connected = connected,
                transferEnabled = transferEnabled,
                generatedCode = generatedCode,
                onGenerateCode = {
                    scope.launch {
                        runCatching { webrtc.generateConnectionCode() }
                            .onSuccess { code ->
                                generatedCode = code
                                codeInput = code
                                statusMessage = resolveLocalizedText(
                                    "已创建连接码: $code，等待对端加入",
                                    "Connection code created: $code, waiting for peer",
                                    "接続コードを作成しました: $code、相手を待機中"
                                )
                            }
                            .onFailure { error ->
                                statusMessage = resolveLocalizedText(
                                    "生成连接码失败: ${error.message ?: "未知错误"}",
                                    "Failed to create connection code: ${error.message ?: "Unknown error"}",
                                    "接続コードの生成に失敗しました: ${error.message ?: "不明なエラー"}"
                                )
                            }
                    }
                },
                onConnectPeer = {
                    val code = codeInput.uppercase().filter { it.isLetterOrDigit() }
                    if (code.length !in 6..16) {
                        statusMessage = resolveLocalizedText(
                            "连接码无效，请输入 6-16 位字母数字",
                            "Invalid connection code. Enter 6-16 alphanumeric characters.",
                            "接続コードが無効です。6-16 文字の英数字を入力してください。"
                        )
                        return@QuickSendSection
                    }
                    webrtc.startAnswerer(code)
                    statusMessage = resolveLocalizedText("正在连接: $code", "Connecting: $code", "接続中: $code")
                },
                onSendFile = { filePicker.launch(arrayOf("*/*")) },
                onDisconnect = {
                    webrtc.disconnect()
                    statusMessage = resolveLocalizedText("连接已关闭", "Connection closed", "接続を閉じました")
                }
            )
        }

        item {
            TransferStatusSection(
                connStateText = renderState(connState),
                statusMessage = statusMessage,
                signalingStatusText = signalingStatus.lastEvent,
                generatedCode = generatedCode,
                progressBytesText = "${progress.sentBytes}/${progress.totalBytes} bytes ($pct%)",
                progressFraction = pct / 100f,
                eventText = progress.lastStatus
            )
        }

        item {
            Text(
                text = t("传输历史", "Transfer History", "転送履歴"),
                style = MaterialTheme.typography.titleMedium,
                color = Color.White,
                fontWeight = FontWeight.SemiBold
            )
        }

        if (inboundLogs.isEmpty()) {
            item {
                LiquidGlassSurface(
                    modifier = Modifier.fillMaxWidth(),
                    blurRadius = 0.dp,
                    tintColor = Color.White.copy(alpha = 0.05f),
                    tintAlpha = 0.05f,
                    borderAlpha = 0.12f,
                    highlightAlpha = 0.04f,
                    edgeGlowAlpha = 0.03f,
                    contentPadding = PaddingValues(20.dp)
                ) {
                    Text(
                        text = t("暂无接收记录", "No received files yet", "受信履歴はまだありません"),
                        style = MaterialTheme.typography.bodyMedium,
                        color = Color.White.copy(alpha = 0.66f)
                    )
                }
            }
        } else {
            items(inboundLogs) { item ->
                LiquidGlassSurface(
                    modifier = Modifier.fillMaxWidth(),
                    blurRadius = 0.dp,
                    tintColor = Color.White.copy(alpha = 0.05f),
                    tintAlpha = 0.05f,
                    borderAlpha = 0.12f,
                    highlightAlpha = 0.04f,
                    edgeGlowAlpha = 0.03f,
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(34.dp)
                                .background(Color(0xFF34C759).copy(alpha = 0.20f), CircleShape),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Filled.CloudDone,
                                contentDescription = null,
                                tint = Color(0xFF34C759),
                                modifier = Modifier.size(18.dp)
                            )
                        }
                        Spacer(modifier = Modifier.width(10.dp))
                        Text(
                            text = item,
                            style = MaterialTheme.typography.bodyMedium,
                            color = Color.White.copy(alpha = 0.86f)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun QuickSendSection(
    codeInput: String,
    onCodeChange: (String) -> Unit,
    connected: Boolean,
    transferEnabled: Boolean,
    generatedCode: String,
    onGenerateCode: () -> Unit,
    onConnectPeer: () -> Unit,
    onSendFile: () -> Unit,
    onDisconnect: () -> Unit
) {
    LiquidGlassSurface(
        blurRadius = 0.dp,
        tintColor = Color.White.copy(alpha = 0.05f),
        tintAlpha = 0.05f,
        borderAlpha = 0.12f,
        highlightAlpha = 0.04f,
        edgeGlowAlpha = 0.03f,
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(14.dp)
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .background(Color(0xFF0A84FF).copy(alpha = 0.22f), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Filled.Folder, contentDescription = null, tint = Color(0xFF7CC0FF))
                }
                Spacer(modifier = Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(t("快速发送", "Quick Send", "クイック送信"), style = MaterialTheme.typography.titleMedium, color = Color.White)
                    Text(
                        text = if (connected) {
                            t("连接已建立，可直接发送文件", "Connection established, you can send files now", "接続済みです。すぐにファイルを送信できます")
                        } else {
                            t("先建立连接码会话，再发送文件", "Create a connection-code session before sending files", "先に接続コードセッションを作成してからファイルを送信してください")
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.68f)
                    )
                }
                Text(
                    text = if (connected) t("已连接", "Connected", "接続済み") else t("未连接", "Not Connected", "未接続"),
                    style = MaterialTheme.typography.labelMedium,
                    color = if (connected) Color(0xFF34C759) else Color.White.copy(alpha = 0.72f),
                    modifier = Modifier
                        .background(
                            color = if (connected) Color(0xFF34C759).copy(alpha = 0.16f) else Color.White.copy(alpha = 0.08f),
                            shape = RoundedCornerShape(999.dp)
                        )
                        .padding(horizontal = 8.dp, vertical = 4.dp)
                )
            }

            OutlinedTextField(
                value = codeInput,
                onValueChange = onCodeChange,
                label = { Text(t("连接码（6-16位）", "Connection Code (6-16 chars)", "接続コード（6-16文字）")) },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                leadingIcon = {
                    Icon(Icons.Filled.Link, contentDescription = null)
                }
            )

            if (generatedCode.isNotBlank()) {
                Text(
                    text = t("当前连接码：$generatedCode", "Current code: $generatedCode", "現在のコード: $generatedCode"),
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.64f)
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedButton(
                    onClick = onGenerateCode,
                    enabled = transferEnabled,
                    modifier = Modifier.weight(1f)
                ) {
                    Text(t("生成连接码", "Generate Code", "接続コードを生成"))
                }
                OutlinedButton(
                    onClick = onConnectPeer,
                    enabled = transferEnabled,
                    modifier = Modifier.weight(1f)
                ) {
                    Text(t("连接对端", "Connect Peer", "相手に接続"))
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Button(
                    onClick = onSendFile,
                    enabled = transferEnabled && connected,
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Filled.CloudUpload, contentDescription = null)
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(t("发送文件", "Send File", "ファイル送信"))
                }
                OutlinedButton(
                    onClick = onDisconnect,
                    modifier = Modifier.weight(1f)
                ) {
                    Text(t("断开连接", "Disconnect", "接続を切断"))
                }
            }
        }
    }
}

@Composable
private fun TransferStatusSection(
    connStateText: String,
    statusMessage: String,
    signalingStatusText: String,
    generatedCode: String,
    progressBytesText: String,
    progressFraction: Float,
    eventText: String?
) {
    LiquidGlassSurface(
        blurRadius = 0.dp,
        tintColor = Color.White.copy(alpha = 0.05f),
        tintAlpha = 0.05f,
        borderAlpha = 0.12f,
        highlightAlpha = 0.04f,
        edgeGlowAlpha = 0.03f,
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(14.dp)
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.Sync,
                    contentDescription = null,
                    tint = Color(0xFF7CC0FF),
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(t("连接状态", "Connection Status", "接続状態"), style = MaterialTheme.typography.titleMedium, color = Color.White)
            }

            Text(t("会话：$connStateText", "Session: $connStateText", "セッション: $connStateText"), color = Color.White.copy(alpha = 0.84f))
            Text(t("状态：$statusMessage", "Status: $statusMessage", "状態: $statusMessage"), color = Color.White.copy(alpha = 0.72f))
            Text(t("信令：$signalingStatusText", "Signaling: $signalingStatusText", "シグナリング: $signalingStatusText"), color = Color.White.copy(alpha = 0.68f))
            if (generatedCode.isNotBlank()) {
                Text(t("连接码：$generatedCode", "Code: $generatedCode", "コード: $generatedCode"), color = Color.White.copy(alpha = 0.68f))
            }
            Spacer(modifier = Modifier.height(2.dp))
            LinearProgressIndicator(
                progress = { progressFraction.coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(),
                color = Color(0xFF34C759),
                trackColor = Color.White.copy(alpha = 0.12f)
            )
            Text(t("进度：$progressBytesText", "Progress: $progressBytesText", "進捗: $progressBytesText"), color = Color.White.copy(alpha = 0.68f))
            eventText?.let {
                Text(t("事件：$it", "Event: $it", "イベント: $it"), color = Color.White.copy(alpha = 0.64f))
            }
        }
    }
}

private fun renderState(state: SkyBridgeWebRtcConnectionManager.State): String {
    return when (state) {
        is SkyBridgeWebRtcConnectionManager.State.Idle -> resolveLocalizedText("空闲", "Idle", "待機")
        is SkyBridgeWebRtcConnectionManager.State.Waiting -> resolveLocalizedText(
            "等待对端 (${state.code})",
            "Waiting for peer (${state.code})",
            "相手待ち (${state.code})"
        )
        is SkyBridgeWebRtcConnectionManager.State.Connecting -> resolveLocalizedText(
            "连接中 (${state.code})",
            "Connecting (${state.code})",
            "接続中 (${state.code})"
        )
        is SkyBridgeWebRtcConnectionManager.State.Connected -> resolveLocalizedText(
            "已连接 (${state.code})",
            "Connected (${state.code})",
            "接続済み (${state.code})"
        )
        is SkyBridgeWebRtcConnectionManager.State.Failed -> resolveLocalizedText(
            "失败: ${state.message}",
            "Failed: ${state.message}",
            "失敗: ${state.message}"
        )
    }
}

private fun queryDisplayName(context: Context, uri: Uri): String? {
    return context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
        val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        if (idx >= 0 && cursor.moveToFirst()) {
            cursor.getString(idx)
        } else {
            null
        }
    }
}

@Preview(showBackground = true)
@Composable
fun FileTransferScreenPreview() {
    SkyBridgeCompassTheme {
        FileTransferScreen(navController = rememberNavController())
    }
}

@Composable
private fun FileTransferInitError(message: String) {
    val title = localizedText("文件传输初始化失败", "File Transfer Initialization Failed", "ファイル転送の初期化に失敗しました")
    val subtitle = localizedText("请返回后重试，或检查网络/权限配置。", "Go back and try again, or check network and permission settings.", "戻って再試行するか、ネットワークと権限設定を確認してください。")
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.Center
    ) {
        LiquidGlassSurface(
            blurRadius = 12.dp,
            tintColor = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.35f),
            borderWidth = 1.dp,
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onErrorContainer
                )
                Text(
                    text = message,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onErrorContainer.copy(alpha = 0.82f)
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onErrorContainer.copy(alpha = 0.72f)
                )
            }
        }
    }
}
