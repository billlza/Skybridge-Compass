package com.skybridge.compass.android.ui.screens.remotecontrol

import android.os.Build
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import androidx.navigation.compose.rememberNavController
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.data.DeveloperSettingsStore
import com.skybridge.compass.android.ui.components.CupertinoSegmentedControl
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.remote.mac.MacRemoteControlClient
import com.skybridge.compass.android.remote.mac.MacRemoteDiscovery
import com.skybridge.compass.android.remote.mac.identityHint
import com.skybridge.compass.android.remote.mac.MouseEventType
import com.skybridge.compass.android.remote.mac.RemoteMessage
import com.skybridge.compass.android.remote.mac.RemoteMouseEvent
import com.skybridge.compass.android.remote.mac.ScreenData
import com.skybridge.compass.android.security.toHandshakePolicyOverride
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.core.p2p.AppMessage
import com.skybridge.compass.core.p2p.AppMessageCodec
import com.skybridge.compass.core.p2p.SwiftDateSeconds
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import com.skybridge.compass.core.webrtc.AndroidCrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

@Composable
private fun t(zh: String, en: String, ja: String): String = localizedText(zh, en, ja)

/**
 * Interop with SkyBridge Compass Pro (macOS) RemoteControlServer:
 * - Bonjour: _skybridge-remote._tcp
 * - TCP: 5901
 * - Framing: u32 length (big-endian) + JSON(RemoteMessage)
 * - Screen: supports JPEG plus Annex-B H.264 / HEVC.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemoteControlScreen(navController: NavController) {
    val featureDisabledTitle = localizedText(
        "远程控制已在设置中关闭",
        "Remote control is disabled in Settings",
        "リモート操作は設定で無効になっています"
    )
    val featureDisabledMessage = localizedText(
        "请前往 设置 > 深度开发设置 重新启用。",
        "Go to Settings > Advanced Developer Settings to enable it again.",
        "設定 > 開発者向け詳細設定 で再度有効にしてください。"
    )
    val openSettingsLabel = localizedText("打开设置", "Open Settings", "設定を開く")
    val context = LocalContext.current
    val devSettings by DeveloperSettingsStore.observe(context).collectAsState(initial = DeveloperSettings())
    if (!devSettings.enableRemoteControl) {
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
    var mode by remember { mutableStateOf(Mode.LAN) }

    Column(modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = t("远程控制", "Remote Control", "リモート操作"),
            style = MaterialTheme.typography.headlineLarge,
            color = androidx.compose.ui.graphics.Color.White,
            fontWeight = FontWeight.Bold
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = t("连接后可进行屏幕查看与输入控制", "Connect to view the screen and control input", "接続すると画面表示と入力操作ができます"),
            style = MaterialTheme.typography.bodyMedium,
            color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.72f)
        )

        Spacer(Modifier.height(12.dp))

        CupertinoSegmentedControl(
            items = listOf(
                t("局域网（5901）", "LAN (5901)", "ローカルネットワーク (5901)"),
                t("跨网（WebRTC）", "Internet (WebRTC)", "インターネット (WebRTC)")
            ),
            selectedIndex = mode.ordinal,
            onSelect = { mode = if (it == 0) Mode.LAN else Mode.WEBRTC },
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(16.dp))

        Box(modifier = Modifier.fillMaxWidth().weight(1f, fill = true)) {
            when (mode) {
                Mode.LAN -> LanRemoteControlContent()
                Mode.WEBRTC -> WebRtcRemoteControlContent()
            }
        }
    }
}

private enum class Mode { LAN, WEBRTC }
private enum class LanMode { CONTROL, HOST }

@Composable
private fun LanRemoteControlContent() {
    val context = LocalContext.current
    val securitySettings by SecuritySettingsStore.observe(context)
        .collectAsState(initial = SecuritySettings())
    var lanMode by remember { mutableStateOf(LanMode.CONTROL) }

    if (!securitySettings.allowScreenMirroring) {
        FeatureDisabledPanel(
            title = t("屏幕镜像已关闭", "Screen mirroring is turned off", "画面ミラーリングはオフです"),
            message = t("请到 设置 → 访问控制 中开启“屏幕镜像”。", "Go to Settings → Access Control to enable Screen Mirroring.", "設定 → アクセス制御 で画面ミラーリングを有効にしてください。")
        )
        return
    }

    Column(modifier = Modifier.fillMaxSize()) {
        CupertinoSegmentedControl(
            items = listOf(
                t("控制其他设备", "Control Another Device", "他の端末を操作"),
                t("共享本机", "Share This Android", "この Android を共有")
            ),
            selectedIndex = lanMode.ordinal,
            onSelect = { lanMode = if (it == 0) LanMode.CONTROL else LanMode.HOST },
            modifier = Modifier.fillMaxWidth()
        )
        Spacer(modifier = Modifier.height(16.dp))
        when (lanMode) {
            LanMode.CONTROL -> LanRemoteClientContent(securitySettings = securitySettings)
            LanMode.HOST -> AndroidRemoteHostContent(
                securitySettings = securitySettings,
                modifier = Modifier.weight(1f, fill = true)
            )
        }
    }
}

@Composable
private fun LanRemoteClientContent(securitySettings: SecuritySettings) {
    val context = LocalContext.current
    val discovery = remember { MacRemoteDiscovery(context) }
    val client = remember { MacRemoteControlClient(context.applicationContext) }

    var services by remember { mutableStateOf<List<MacRemoteDiscovery.Service>>(emptyList()) }
    var selected by remember { mutableStateOf<MacRemoteDiscovery.Service?>(null) }

    val state by client.state.collectAsState()
    val frame by client.latestFrame.collectAsState()
    val securityState by client.securityState.collectAsState()

    DisposableEffect(client) {
        onDispose { client.disconnect() }
    }

    LaunchedEffect(Unit) {
        discovery.discover().collectLatest { list ->
            services = list
            if (selected == null) selected = list.firstOrNull()
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        LiquidGlassSurface(
            modifier = Modifier.fillMaxWidth(),
            blurRadius = 0.dp,
            tintColor = Color.White.copy(alpha = 0.05f),
            tintAlpha = 0.05f,
            borderAlpha = 0.12f,
            highlightAlpha = 0.04f,
            edgeGlowAlpha = 0.03f,
            contentPadding = PaddingValues(0.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.Computer,
                    contentDescription = null,
                    tint = when (state) {
                        is MacRemoteControlClient.State.Connected -> MaterialTheme.colorScheme.primary
                        is MacRemoteControlClient.State.Connecting -> MaterialTheme.colorScheme.tertiary
                        is MacRemoteControlClient.State.Failed -> MaterialTheme.colorScheme.error
                        is MacRemoteControlClient.State.Disconnected -> MaterialTheme.colorScheme.onSurfaceVariant
                    },
                    modifier = Modifier.size(32.dp)
                )

                Spacer(Modifier.width(16.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = when (state) {
                            is MacRemoteControlClient.State.Connected -> t("已连接（5901）", "Connected (5901)", "接続済み (5901)")
                            is MacRemoteControlClient.State.Connecting -> t("连接中…", "Connecting…", "接続中…")
                            is MacRemoteControlClient.State.Failed -> t("连接失败", "Connection Failed", "接続失敗")
                            is MacRemoteControlClient.State.Disconnected -> t("未连接", "Not Connected", "未接続")
                        },
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        text = selected?.let { "${it.name}  (${it.host}:${it.port})" }
                            ?: t("未发现 _skybridge-remote._tcp", "No _skybridge-remote._tcp service found", "_skybridge-remote._tcp が見つかりません"),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = lanSecuritySummary(securityState),
                        style = MaterialTheme.typography.bodySmall,
                        color = lanSecurityColor(securityState)
                    )
                }

                when (state) {
                    is MacRemoteControlClient.State.Connected,
                    is MacRemoteControlClient.State.Connecting -> {
                        OutlinedButton(onClick = { client.disconnect() }) {
                            Icon(Icons.Default.Stop, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(t("断开", "Disconnect", "切断"))
                        }
                    }
                    else -> {
                        Button(
                            enabled = selected != null,
                            onClick = {
                                val s = selected ?: return@Button
                                val hint = s.identityHint()
                                client.connect(
                                    MacRemoteControlClient.ConnectionTarget(
                                        host = s.host,
                                        port = s.port,
                                        displayName = s.name,
                                        deviceIdHint = hint.deviceId,
                                        advertisedFingerprint = hint.advertisedFingerprint
                                    ),
                                    securityConfig = MacRemoteControlClient.SecurityConfig(
                                        encryptionRequired = securitySettings.encryptionEnabled,
                                        allowPlaintextFallback = !securitySettings.encryptionEnabled,
                                        allowTrustOnFirstUse = true,
                                        handshakePolicyOverride = securitySettings.toHandshakePolicyOverride()
                                    )
                                )
                            }
                        ) { Text(t("连接", "Connect", "接続")) }
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        LiquidGlassSurface(
            modifier = Modifier.fillMaxWidth(),
            blurRadius = 0.dp,
            tintColor = Color.White.copy(alpha = 0.05f),
            tintAlpha = 0.05f,
            borderAlpha = 0.12f,
            highlightAlpha = 0.04f,
            edgeGlowAlpha = 0.03f
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = t("发现到的服务", "Discovered Services", "検出されたサービス"),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(onClick = { /* NSD continuous */ }) {
                        Icon(Icons.Default.Refresh, contentDescription = t("刷新", "Refresh", "更新"))
                    }
                }

                Spacer(Modifier.height(12.dp))

                if (services.isEmpty()) {
                    Text(
                        text = t(
                            "未发现服务。请确认 Mac 端已启动 RemoteControlServer（5901），且与你的 Android 在同一局域网。",
                            "No service found. Make sure RemoteControlServer (5901) is running on your Mac and both devices are on the same LAN.",
                            "サービスが見つかりません。Mac で RemoteControlServer (5901) が起動しており、Android と同じ LAN 上にあることを確認してください。"
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                } else {
                    LazyColumn(modifier = Modifier.heightIn(max = 220.dp)) {
                        items(services) { svc ->
                            ServiceRow(
                                label = "${svc.name}  (${svc.host}:${svc.port})",
                                selected = selected == svc,
                                onClick = { selected = svc }
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        RemoteScreenSurface(
            modifier = Modifier.fillMaxWidth().weight(1f, fill = true),
            frame = frame?.let { RemoteFrame(it.width, it.height, it.format, it.timestamp, it.imageBytes) },
            controlEnabled = securitySettings.allowRemoteControl && (
                !securitySettings.encryptionEnabled || client.hasSecureChannel()
            ),
            onPointerEvent = { x, y, phase ->
                if (!securitySettings.allowRemoteControl) return@RemoteScreenSurface
                if (securitySettings.encryptionEnabled && !client.hasSecureChannel()) return@RemoteScreenSurface
                when (phase) {
                    PointerPhase.Down -> client.sendLeftDown(x, y)
                    PointerPhase.Move -> client.sendMouseMove(x, y)
                    PointerPhase.Up -> client.sendLeftUp(x, y)
                }
            }
        )
    }
}

private enum class PointerPhase { Down, Move, Up }

internal data class RemoteFrame(
    val width: Int,
    val height: Int,
    val format: String?,
    val timestampSeconds: Double,
    val imageBytes: ByteArray
)

@Composable
private fun WebRtcRemoteControlContent() {
    val context = LocalContext.current
    val appContext = remember(context) { context.applicationContext }
    val scope = rememberCoroutineScope()
    val securitySettings by SecuritySettingsStore.observe(context)
        .collectAsState(initial = SecuritySettings())

    if (!securitySettings.allowScreenMirroring) {
        FeatureDisabledPanel(
            title = t("屏幕镜像已关闭", "Screen mirroring is turned off", "画面ミラーリングはオフです"),
            message = t("请到 设置 → 访问控制 中开启“屏幕镜像”。", "Go to Settings → Access Control to enable Screen Mirroring.", "設定 → アクセス制御 で画面ミラーリングを有効にしてください。")
        )
        return
    }

    val webrtcResult = remember(appContext) {
        runCatching {
            AndroidCrossNetworkWebRtcTransportAdapter(
                SkyBridgeWebRtcConnectionManager(appContext)
            )
        }
    }
    val webrtc = webrtcResult.getOrNull()
    if (webrtc == null) {
        FeatureDisabledPanel(
            title = t("跨网互通不可用", "Cross-network access unavailable", "クロスネットワーク接続は利用できません"),
            message = webrtcResult.exceptionOrNull()?.message ?: t("WebRTC 初始化失败", "WebRTC initialization failed", "WebRTC の初期化に失敗しました")
        )
        return
    }

    val webrtcState by webrtc.state.collectAsState()
    val signalingStatus by webrtc.signalingStatus.collectAsState()
    val json = remember { Json { ignoreUnknownKeys = true; explicitNulls = false } }
    val appMessageCodec = remember { AppMessageCodec() }
    val supportedStreamingFormats = remember { AndroidRemoteVideoFormats.supportedStreamingFormats() }
    var inputCode by remember { mutableStateOf("") }
    var frame by remember { mutableStateOf<RemoteFrame?>(null) }
    var plaintextStreamConfigurationSent by remember { mutableStateOf(false) }
    var encryptedStreamConfigurationSent by remember { mutableStateOf(false) }

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

    fun nowUnixSeconds(): Double = System.currentTimeMillis() / 1000.0

    fun sendStreamConfiguration() {
        val preferredCodec = AndroidRemoteVideoFormats.preferredStreamingCodec()
        val prefersCompressedVideo = preferredCodec != AndroidRemoteVideoFormats.JPEG
        val config = com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfiguration(
            preferredCodec = preferredCodec,
            supportedVideoFormats = supportedStreamingFormats,
            adaptiveResolutionEnabled = true,
            targetFrameRate = if (prefersCompressedVideo) 30 else 20,
            keyFrameInterval = 30,
            lowLatencyMode = prefersCompressedVideo,
            enableHardwareAcceleration = prefersCompressedVideo,
            enableAppleSiliconOptimization = false,
            clipboardSyncEnabled = false,
            damageTrackingEnabled = true,
            separateCursorChannelEnabled = false,
            interactionOverlayChannelEnabled = false,
            refreshStrategy = if (prefersCompressedVideo) "live" else "adaptive",
            lossRecoveryMode = if (prefersCompressedVideo) "keyframe" else "none",
            sentAt = nowUnixSeconds()
        )
        val configJson = json.encodeToString(
            com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfiguration.serializer(),
            config
        ).encodeToByteArray()
        val message = RemoteMessage(
            type = RemoteMessage.MessageType.STREAM_CONFIGURATION,
            payload = configJson
        )
        webrtc.send(json.encodeToString(RemoteMessage.serializer(), message).encodeToByteArray())
    }

    fun sendHeartbeat() {
        val heartbeat = AppMessage.Heartbeat(
            AppMessage.HeartbeatPayload(
                sentAt = SwiftDateSeconds.now(),
                platform = "android",
                osVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                remoteVideoFormats = supportedStreamingFormats
            )
        )
        webrtc.send(appMessageCodec.encode(heartbeat))
    }

    fun sendMouse(type: MouseEventType, x: Double, y: Double) {
        if (!securitySettings.allowRemoteControl) return
        if (!webrtc.hasSessionKeys()) return
        val evt = RemoteMouseEvent(type = type, x = x, y = y, timestamp = nowUnixSeconds())
        val evtJson = json.encodeToString(RemoteMouseEvent.serializer(), evt).encodeToByteArray()
        val msg = RemoteMessage(type = RemoteMessage.MessageType.MOUSE_EVENT, payload = evtJson)
        val msgJson = json.encodeToString(RemoteMessage.serializer(), msg).encodeToByteArray()
        webrtc.send(msgJson)
    }

    DisposableEffect(webrtc, json) {
        webrtc.onData = { bytes ->
            runCatching {
                val msg = json.decodeFromString(RemoteMessage.serializer(), bytes.decodeToString())
                if (msg.type != RemoteMessage.MessageType.SCREEN_DATA) return@runCatching
                val screen = json.decodeFromString(ScreenData.serializer(), msg.payload.decodeToString())
                if (screen.imageData.isEmpty()) return@runCatching
                val normalizedFormat = AndroidRemoteVideoFormats.normalizeIncomingFormat(
                    format = screen.format,
                    payload = screen.imageData
                ) ?: return@runCatching
                scope.launch {
                    frame = RemoteFrame(
                        width = screen.width,
                        height = screen.height,
                        format = normalizedFormat,
                        timestampSeconds = screen.timestamp,
                        imageBytes = screen.imageData
                    )
                }
            }
        }
        onDispose {
            webrtc.onData = null
            webrtc.release()
        }
    }

    LaunchedEffect(webrtcState) {
        frame = null
        plaintextStreamConfigurationSent = false
        encryptedStreamConfigurationSent = false
        if (webrtcState is SkyBridgeWebRtcConnectionManager.State.Connected) {
            if (!plaintextStreamConfigurationSent) {
                sendStreamConfiguration()
                plaintextStreamConfigurationSent = true
            }
            while (true) {
                if (webrtc.hasSessionKeys()) {
                    if (!encryptedStreamConfigurationSent) {
                        sendStreamConfiguration()
                        encryptedStreamConfigurationSent = true
                    }
                    sendHeartbeat()
                }
                delay(2_000)
            }
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        LiquidGlassSurface(
            modifier = Modifier.fillMaxWidth(),
            blurRadius = 0.dp,
            tintColor = Color.White.copy(alpha = 0.05f),
            tintAlpha = 0.05f,
            borderAlpha = 0.12f,
            highlightAlpha = 0.04f,
            edgeGlowAlpha = 0.03f,
            contentPadding = PaddingValues(0.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.Computer,
                    contentDescription = null,
                    tint = when (webrtcState) {
                        is SkyBridgeWebRtcConnectionManager.State.Connected -> MaterialTheme.colorScheme.primary
                        is SkyBridgeWebRtcConnectionManager.State.Connecting -> MaterialTheme.colorScheme.tertiary
                        is SkyBridgeWebRtcConnectionManager.State.Waiting -> MaterialTheme.colorScheme.tertiary
                        is SkyBridgeWebRtcConnectionManager.State.Failed -> MaterialTheme.colorScheme.error
                        is SkyBridgeWebRtcConnectionManager.State.Idle -> MaterialTheme.colorScheme.onSurfaceVariant
                    },
                    modifier = Modifier.size(32.dp)
                )

                Spacer(Modifier.width(16.dp))

                Column(modifier = Modifier.weight(1f)) {
                    val label = when (val st = webrtcState) {
                        is SkyBridgeWebRtcConnectionManager.State.Idle -> t("未连接", "Not Connected", "未接続")
                        is SkyBridgeWebRtcConnectionManager.State.Waiting -> t("等待加入（${st.code}）", "Waiting for peer (${st.code})", "参加待ち (${st.code})")
                        is SkyBridgeWebRtcConnectionManager.State.Connecting -> t("连接中…（${st.code}）", "Connecting… (${st.code})", "接続中… (${st.code})")
                        is SkyBridgeWebRtcConnectionManager.State.Connected -> t("已连接（${st.code}）", "Connected (${st.code})", "接続済み (${st.code})")
                        is SkyBridgeWebRtcConnectionManager.State.Failed -> t("连接失败", "Connection Failed", "接続失敗")
                    }
                    Text(label, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    Text(
                        text = if (webrtc.hasSessionKeys()) {
                            t("握手已建立（AES-GCM）", "Handshake established (AES-GCM)", "ハンドシェイク確立済み (AES-GCM)")
                        } else {
                            t("握手进行中…", "Handshake in progress…", "ハンドシェイク中…")
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = t(
                            "信令：${signalingStatus.lastEvent}",
                            "Signaling: ${signalingStatus.lastEvent}",
                            "シグナリング: ${signalingStatus.lastEvent}"
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                when (webrtcState) {
                    is SkyBridgeWebRtcConnectionManager.State.Connected,
                    is SkyBridgeWebRtcConnectionManager.State.Connecting,
                    is SkyBridgeWebRtcConnectionManager.State.Waiting -> {
                        OutlinedButton(onClick = { webrtc.disconnect() }) {
                            Icon(Icons.Default.Stop, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(t("断开", "Disconnect", "切断"))
                        }
                    }
                    else -> Unit
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        LiquidGlassSurface(
            modifier = Modifier.fillMaxWidth(),
            blurRadius = 0.dp,
            tintColor = Color.White.copy(alpha = 0.05f),
            tintAlpha = 0.05f,
            borderAlpha = 0.12f,
            highlightAlpha = 0.04f,
            edgeGlowAlpha = 0.03f
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(t("连接码", "Connection Code", "接続コード"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = inputCode,
                    onValueChange = { inputCode = it.uppercase() },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    placeholder = { Text(t("输入连接码（当前兼容 6-16 位）", "Enter connection code (supports 6-16 characters)", "接続コードを入力（現在は 6-16 文字に対応）")) }
                )
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(
                        onClick = {
                            scope.launch {
                                runCatching { webrtc.generateConnectionCode() }
                                    .onSuccess { code -> inputCode = code }
                            }
                        }
                    ) { Text(t("生成并等待", "Generate & Wait", "生成して待機")) }
                    OutlinedButton(
                        onClick = { webrtc.startAnswerer(inputCode) },
                        enabled = inputCode.uppercase().filter { it.isLetterOrDigit() }.length in 6..16
                    ) { Text(t("加入", "Join", "参加")) }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        RemoteScreenSurface(
            modifier = Modifier.fillMaxWidth().weight(1f, fill = true),
            frame = frame,
            controlEnabled = securitySettings.allowRemoteControl,
            onPointerEvent = { x, y, phase ->
                when (phase) {
                    PointerPhase.Down -> sendMouse(MouseEventType.LEFT_MOUSE_DOWN, x, y)
                    PointerPhase.Move -> sendMouse(MouseEventType.MOUSE_MOVED, x, y)
                    PointerPhase.Up -> sendMouse(MouseEventType.LEFT_MOUSE_UP, x, y)
                }
            }
        )
    }
}

@Composable
private fun RemoteScreenSurface(
    modifier: Modifier,
    frame: RemoteFrame?,
    controlEnabled: Boolean = true,
    onPointerEvent: (x: Double, y: Double, phase: PointerPhase) -> Unit
) {
    LiquidGlassSurface(
        modifier = modifier,
        blurRadius = 0.dp,
        tintColor = Color.White.copy(alpha = 0.05f),
        tintAlpha = 0.05f,
        borderAlpha = 0.12f,
        highlightAlpha = 0.04f,
        edgeGlowAlpha = 0.03f
    ) {
        if (frame == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    text = t(
                        "等待屏幕帧（支持 JPEG / H.264 / HEVC）",
                        "Waiting for screen frames (supports JPEG / H.264 / HEVC)",
                        "画面フレーム待機中（JPEG / H.264 / HEVC 対応）"
                    ),
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        } else {
            val f = frame
            val normalizedFormat = remember(f.format, f.imageBytes) {
                AndroidRemoteVideoFormats.normalizeIncomingFormat(
                    format = f.format,
                    payload = f.imageBytes
                )
            }
            if (normalizedFormat == null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        t("当前格式暂不支持", "This frame format is not supported yet", "このフレーム形式はまだサポートされていません"),
                        color = MaterialTheme.colorScheme.error
                    )
                }
            } else {
                var lastTouch by remember { mutableStateOf(Offset.Zero) }
                val gestureModifier = if (controlEnabled) {
                    Modifier.pointerInput(f.width, f.height) {
                        detectDragGestures(
                            onDragStart = { offset ->
                                lastTouch = offset
                                val (rx, ry) = mapToRemote(offset, f.width, f.height, size.width.toFloat(), size.height.toFloat())
                                onPointerEvent(rx, ry, PointerPhase.Down)
                            },
                            onDrag = { change, _ ->
                                lastTouch = change.position
                                val (rx, ry) = mapToRemote(change.position, f.width, f.height, size.width.toFloat(), size.height.toFloat())
                                onPointerEvent(rx, ry, PointerPhase.Move)
                            },
                            onDragEnd = {
                                val (rx, ry) = mapToRemote(lastTouch, f.width, f.height, size.width.toFloat(), size.height.toFloat())
                                onPointerEvent(rx, ry, PointerPhase.Up)
                            }
                        )
                    }
                } else {
                    Modifier
                }
                if (AndroidRemoteVideoFormats.isVideoFormat(normalizedFormat)) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .then(gestureModifier)
                    ) {
                        RemoteVideoSurface(
                            modifier = Modifier.fillMaxSize(),
                            frame = f,
                            normalizedFormat = normalizedFormat
                        )
                        if (!controlEnabled) {
                            Box(
                                modifier = Modifier.fillMaxSize(),
                                contentAlignment = Alignment.BottomCenter
                            ) {
                                Text(
                                    text = t("远程控制已关闭（仅查看）", "Remote control is off (view only)", "リモート操作はオフです（閲覧のみ）"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(12.dp)
                                )
                            }
                        }
                    }
                } else {
                    val bmp = remember(f.imageBytes, normalizedFormat) {
                        decodeRemoteStaticBitmap(f.imageBytes)
                    }
                    if (bmp == null) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Text(
                                t("图像解码失败", "Image decode failed", "画像のデコードに失敗しました"),
                                color = MaterialTheme.colorScheme.error
                            )
                        }
                    } else {
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .then(gestureModifier)
                        ) {
                            Image(
                                bitmap = bmp.asImageBitmap(),
                                contentDescription = t("远程屏幕", "Remote Screen", "リモート画面"),
                                modifier = Modifier.fillMaxSize()
                            )
                            if (!controlEnabled) {
                                Box(
                                    modifier = Modifier.fillMaxSize(),
                                    contentAlignment = Alignment.BottomCenter
                                ) {
                                    Text(
                                        text = t("远程控制已关闭（仅查看）", "Remote control is off (view only)", "リモート操作はオフです（閲覧のみ）"),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(12.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FeatureDisabledPanel(title: String, message: String) {
    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        blurRadius = 0.dp,
        tintColor = Color.White.copy(alpha = 0.05f),
        tintAlpha = 0.05f,
        borderAlpha = 0.12f,
        highlightAlpha = 0.04f,
        edgeGlowAlpha = 0.03f
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Text(message, style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.72f))
        }
    }
}

@Composable
private fun lanSecuritySummary(state: MacRemoteControlClient.SecurityState): String =
    when (state) {
        MacRemoteControlClient.SecurityState.Disconnected ->
            t("等待建立安全通道", "Waiting for secure channel", "セキュアチャネル待機中")

        is MacRemoteControlClient.SecurityState.Negotiating ->
            t("正在验证对端身份…", "Verifying peer identity…", "相手の識別情報を検証中…")

        is MacRemoteControlClient.SecurityState.Secure -> {
            when (state.trustState) {
                MacRemoteControlClient.TrustState.TRUSTED_EXISTING ->
                    t("已建立互信与加密会话", "Trusted encrypted session established", "信頼済み暗号化セッションを確立")

                MacRemoteControlClient.TrustState.TRUSTED_NEW ->
                    t("首次信任并已建立加密会话", "First-use trust saved and encrypted session established", "初回信頼を保存し暗号化セッションを確立")

                MacRemoteControlClient.TrustState.UNTRUSTED_EPHEMERAL ->
                    t("已建立加密会话（未持久信任）", "Encrypted session established (not pinned)", "暗号化セッションを確立（未固定）")
            }
        }

        is MacRemoteControlClient.SecurityState.Plaintext ->
            t("当前为明文兼容模式", "Running in plaintext compatibility mode", "現在は平文互換モードです")

        is MacRemoteControlClient.SecurityState.Failed ->
            t("安全协商失败", "Security negotiation failed", "セキュリティネゴシエーション失敗")
    }

@Composable
private fun lanSecurityColor(state: MacRemoteControlClient.SecurityState): Color =
    when (state) {
        MacRemoteControlClient.SecurityState.Disconnected -> MaterialTheme.colorScheme.onSurfaceVariant
        is MacRemoteControlClient.SecurityState.Negotiating -> MaterialTheme.colorScheme.tertiary
        is MacRemoteControlClient.SecurityState.Secure -> MaterialTheme.colorScheme.primary
        is MacRemoteControlClient.SecurityState.Plaintext -> MaterialTheme.colorScheme.error
        is MacRemoteControlClient.SecurityState.Failed -> MaterialTheme.colorScheme.error
    }

@Composable
private fun ServiceRow(label: String, selected: Boolean, onClick: () -> Unit) {
    val bg = if (selected) Color(0xFF0A84FF).copy(alpha = 0.16f) else Color.White.copy(alpha = 0.04f)
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = bg,
        shape = RoundedCornerShape(12.dp),
        onClick = onClick
    ) {
        Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, modifier = Modifier.weight(1f), color = Color.White)
            if (selected) {
                Text(localizedText("已选", "Selected", "選択済み"), color = Color(0xFF7CC0FF), style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

private fun mapToRemote(
    local: Offset,
    remoteW: Int,
    remoteH: Int,
    viewW: Float,
    viewH: Float
): Pair<Double, Double> {
    if (viewW <= 0f || viewH <= 0f) return 0.0 to 0.0
    val x = (local.x / viewW).coerceIn(0f, 1f) * remoteW
    val y = (local.y / viewH).coerceIn(0f, 1f) * remoteH
    return x.toDouble() to y.toDouble()
}

@Preview(showBackground = true)
@Composable
fun RemoteControlScreenPreview() {
    SkyBridgeCompassTheme {
        RemoteControlScreen(navController = rememberNavController())
    }
}
