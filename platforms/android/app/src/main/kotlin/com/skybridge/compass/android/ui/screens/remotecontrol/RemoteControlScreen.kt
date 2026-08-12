package com.skybridge.compass.android.ui.screens.remotecontrol

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavController
import androidx.navigation.compose.rememberNavController
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.data.DeveloperSettingsStore
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.discovery.DiscoveryPeerLaunchTarget
import com.skybridge.compass.android.remote.mac.MacRemoteControlClient
import com.skybridge.compass.android.remote.mac.LanRemotePeer
import com.skybridge.compass.android.remote.mac.MouseEventType
import com.skybridge.compass.android.remote.mac.RemoteInputMessages
import com.skybridge.compass.android.remote.mac.RemoteKeyIntent
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.IOSGlassCard
import com.skybridge.compass.android.ui.components.IOSGlassRow
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.components.CupertinoSegmentedControl
import com.skybridge.compass.android.ui.navigation.Screen
import com.skybridge.compass.android.ui.theme.IOSParityTokens
import com.skybridge.compass.android.ui.theme.SkyBridgeCompassTheme
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import com.skybridge.compass.core.webrtc.RemoteRenderAdmissionPolicy
import com.skybridge.compass.core.webrtc.RemoteViewerStatus
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSelectedRoute
import kotlinx.coroutines.launch

@Composable
private fun t(zh: String, en: String, ja: String): String = localizedText(zh, en, ja)

/**
 * Interop with SkyBridge Compass Pro (macOS) RemoteControlServer:
 * - Bonjour: _skybridge-rd._tcp
 * - TCP: 5901
 * - Framing: u32 length (big-endian) + JSON(RemoteMessage)
 * - Screen: supports JPEG plus Annex-B H.264 / HEVC.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemoteControlScreen(
    navController: NavController,
    initialLanTarget: DiscoveryPeerLaunchTarget? = null,
    launchTargetError: String? = null
) {
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
    if (launchTargetError != null) {
        FeatureDisabledPanel(
            title = t("所选设备不可用", "Selected peer unavailable", "選択したピアは利用できません"),
            message = launchTargetError
        )
        return
    }
    if (initialLanTarget != null && !initialLanTarget.isRemoteDesktop) {
        FeatureDisabledPanel(
            title = t("所选设备不可用", "Selected peer unavailable", "選択したピアは利用できません"),
            message = t(
                "发现页传入的端点不是远程桌面服务。",
                "The selected discovery endpoint is not a Remote Desktop service.",
                "選択した検出エンドポイントはリモートデスクトップサービスではありません。"
            )
        )
        return
    }
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

        // iOS-parity entry rows: pairing (step ④) + stream settings (step ③) presented as
        // grouped glass rows, mirroring the iOS toolbar "slider.horizontal.3" stream-settings
        // affordance and the trust-pairing flow. Navigation targets are unchanged.
        RemoteEntryRow(
            icon = Icons.Filled.Link,
            accent = IOSParityTokens.ColorTokens.CyanAccent,
            title = t("配对 Mac（建立信任）", "Pair with Mac", "Mac とペアリング"),
            subtitle = t(
                "首次远控前与 Mac 建立 SAS 信任",
                "Establish SAS trust before first remote control",
                "初回リモート操作前に Mac と SAS 信頼を確立"
            ),
            onClick = {
                // PIB-1 SAS pairing entry: a Mac rejects inbound control with `untrustedPeer`
                // until a TrustRecord exists. This flow establishes that trust once.
                navController.navigate(Screen.PibPairing.route) {
                    launchSingleTop = true
                }
            }
        )

        Spacer(Modifier.height(8.dp))

        RemoteEntryRow(
            icon = Icons.Filled.Tune,
            accent = IOSParityTokens.ColorTokens.PurpleAccent,
            title = t("画面流设置", "Stream Settings", "ストリーム設定"),
            subtitle = t(
                "分辨率、帧率、编码与低延迟",
                "Resolution, frame rate, codec and low latency",
                "解像度・フレームレート・コーデック・低遅延"
            ),
            onClick = {
                navController.navigate(Screen.RemoteDesktopStreamSettings.route) {
                    launchSingleTop = true
                }
            }
        )

        Spacer(Modifier.height(16.dp))

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
                Mode.LAN -> LanRemoteControlContent(initialTarget = initialLanTarget)
                Mode.WEBRTC -> WebRtcRemoteControlContent()
            }
        }
    }
}

/**
 * iOS-parity grouped glass entry row used for the "Pair with Mac" (step ④) and "Stream Settings"
 * (step ③) shortcuts. Reuses 5a's [IOSGlassRow] + cyan accent language with a leading icon tile,
 * title/subtitle, and a trailing chevron — matching the dashboard device-row treatment.
 */
@Composable
private fun RemoteEntryRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    accent: Color,
    title: String,
    subtitle: String,
    onClick: () -> Unit
) {
    IOSGlassRow(
        modifier = Modifier.fillMaxWidth(),
        accentColor = accent,
        onClick = onClick
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .background(accent.copy(alpha = 0.18f), androidx.compose.foundation.shape.CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier.size(18.dp)
                )
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.64f)
                )
            }
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.3f),
                modifier = Modifier.size(20.dp)
            )
        }
    }
}

private enum class Mode { LAN, WEBRTC }
@Composable
private fun LanRemoteControlContent(
    initialTarget: DiscoveryPeerLaunchTarget? = null,
    viewModel: LanRemoteClientViewModel = hiltViewModel()
) {
    val securitySettings by viewModel.securitySettings.collectAsStateWithLifecycle()

    if (!securitySettings.allowScreenMirroring) {
        FeatureDisabledPanel(
            title = t("屏幕镜像已关闭", "Screen mirroring is turned off", "画面ミラーリングはオフです"),
            message = t("请到 设置 → 访问控制 中开启“屏幕镜像”。", "Go to Settings → Access Control to enable Screen Mirroring.", "設定 → アクセス制御 で画面ミラーリングを有効にしてください。")
        )
        return
    }

    LanRemoteClientContent(
        securitySettings = securitySettings,
        initialTarget = initialTarget,
        viewModel = viewModel
    )
}

@Composable
private fun LanRemoteClientContent(
    securitySettings: SecuritySettings,
    initialTarget: DiscoveryPeerLaunchTarget? = null,
    viewModel: LanRemoteClientViewModel = hiltViewModel()
) {
    val services by viewModel.peers.collectAsStateWithLifecycle()
    val discoveryError by viewModel.discoveryError.collectAsStateWithLifecycle()
    val actionGateError by viewModel.actionGateError.collectAsStateWithLifecycle()
    val preDialPeerId by viewModel.preDialPeerId.collectAsStateWithLifecycle()
    val activePeer by viewModel.activePeerState.collectAsStateWithLifecycle()
    var selected by remember(initialTarget?.peerId) { mutableStateOf<LanRemotePeer?>(null) }
    var initialConnectAttempted by remember(initialTarget) { mutableStateOf(false) }

    val state by viewModel.remoteState.collectAsStateWithLifecycle()
    val frame by viewModel.latestFrame.collectAsStateWithLifecycle()
    val securityState by viewModel.securityState.collectAsStateWithLifecycle()
    val viewerStatus by viewModel.viewerStatus.collectAsStateWithLifecycle()
    val connectionOwnsPeer = preDialPeerId != null ||
        state is MacRemoteControlClient.State.Connecting ||
        state is MacRemoteControlClient.State.Connected
    val displayedPeer = activePeer.takeIf { connectionOwnsPeer } ?: selected

    DisposableEffect(viewModel) {
        onDispose { viewModel.disconnect() }
    }

    LaunchedEffect(services, initialTarget) {
        selected = selected?.let { current ->
            services.firstOrNull { it.id == current.id }
        } ?: initialTarget?.let { target ->
            services.singleOrNull { it.matchesInitialTarget(target) }
        } ?: services.firstOrNull()
    }

    LaunchedEffect(services, initialTarget, initialConnectAttempted) {
        if (initialConnectAttempted) return@LaunchedEffect
        val target = initialTarget ?: return@LaunchedEffect
        val exactPeer = services.singleOrNull { it.matchesInitialTarget(target) }
            ?: return@LaunchedEffect
        initialConnectAttempted = true
        selected = exactPeer
        viewModel.connect(exactPeer)
    }

    Column(modifier = Modifier.fillMaxSize()) {
        IOSGlassCard(modifier = Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.Computer,
                    contentDescription = null,
                    tint = when (state) {
                        is MacRemoteControlClient.State.Connected -> IOSParityTokens.ColorTokens.CyanAccent
                        is MacRemoteControlClient.State.Connecting -> IOSParityTokens.ColorTokens.WarningOrange
                        is MacRemoteControlClient.State.Failed -> IOSParityTokens.ColorTokens.ErrorRed
                        is MacRemoteControlClient.State.Disconnected -> Color.White.copy(alpha = 0.6f)
                    },
                    modifier = Modifier.size(32.dp)
                )

                Spacer(Modifier.width(16.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = when (state) {
                            is MacRemoteControlClient.State.Connected -> displayedPeer?.let { peer ->
                                t("已连接（${peer.port}）", "Connected (${peer.port})", "接続済み (${peer.port})")
                            } ?: t("已连接", "Connected", "接続済み")
                            is MacRemoteControlClient.State.Connecting -> t("连接中…", "Connecting…", "接続中…")
                            is MacRemoteControlClient.State.Failed -> t("连接失败", "Connection Failed", "接続失敗")
                            is MacRemoteControlClient.State.Disconnected -> t("未连接", "Not Connected", "未接続")
                        },
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        text = displayedPeer?.let { "${it.name}  (${it.host}:${it.port})" }
                            ?: t("未发现 _skybridge-rd._tcp", "No _skybridge-rd._tcp service found", "_skybridge-rd._tcp が見つかりません"),
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
                        OutlinedButton(onClick = viewModel::disconnect) {
                            Icon(Icons.Default.Stop, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(t("断开", "Disconnect", "切断"))
                        }
                    }
                    else -> {
                        Button(
                            enabled = selected != null && preDialPeerId == null,
                            onClick = {
                                val s = selected ?: return@Button
                                viewModel.connect(s)
                            }
                        ) {
                            Text(
                                if (preDialPeerId != null) {
                                    t("验证中…", "Authorizing…", "認証中…")
                                } else {
                                    t("连接", "Connect", "接続")
                                }
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        IOSGlassCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = t("统一发现到的远程桌面服务", "Remote Desktop Services from Unified Discovery", "統合検出のリモートデスクトップサービス"),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(onClick = { viewModel.refresh() }) {
                        Icon(
                            Icons.Default.Refresh,
                            contentDescription = t("刷新", "Refresh", "更新"),
                            tint = IOSParityTokens.ColorTokens.CyanAccent
                        )
                    }
                }

                Spacer(Modifier.height(12.dp))

                if (discoveryError != null || actionGateError != null) {
                    Text(
                        text = discoveryError ?: actionGateError.orEmpty(),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error
                    )
                } else if (services.isEmpty()) {
                    Text(
                        text = t(
                            "统一 Bonjour 发现中没有可连接的 _skybridge-rd._tcp。请确认 macOS/iOS 端已发布远程桌面服务，且与你的 Android 在同一局域网。",
                            "Unified Bonjour discovery has no connectable _skybridge-rd._tcp peer. Make sure macOS/iOS is advertising Remote Desktop and both devices are on the same LAN.",
                            "統合 Bonjour 検出で接続可能な _skybridge-rd._tcp が見つかりません。macOS / iOS 側がリモートデスクトップを公開し、Android と同じ LAN 上にあることを確認してください。"
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
                                onClick = {
                                    if (!connectionOwnsPeer) selected = svc
                                }
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
            controlEnabled = securitySettings.allowRemoteControl && viewModel.hasSecureChannel(),
            viewerStatus = viewerStatus,
            onDecoderError = viewModel::onDecoderError,
            onPointerEvent = { x, y, phase ->
                when (phase) {
                    PointerPhase.Down -> viewModel.sendLeftDown(x, y)
                    PointerPhase.Move -> viewModel.sendMouseMove(x, y)
                    PointerPhase.Up -> viewModel.sendLeftUp(x, y)
                }
            },
            onScroll = { up, x, y ->
                if (up) viewModel.sendScrollUp(x, y) else viewModel.sendScrollDown(x, y)
            },
            onKey = viewModel::sendKeyStroke
        )
    }
}

private fun LanRemotePeer.matchesInitialTarget(target: DiscoveryPeerLaunchTarget): Boolean =
    id == (target.deviceIdHint ?: target.peerId) &&
        remoteDesktopEndpoint.serviceType == target.serviceType &&
        remoteDesktopEndpoint.instanceName == target.instanceName &&
        remoteDesktopEndpoint.hostAddress == target.host &&
        remoteDesktopEndpoint.port == target.port &&
        remoteDesktopEndpoint.routeProvenance == target.routeProvenance.name &&
        remoteDesktopEndpoint.advertisedProtocolFingerprint == target.advertisedFingerprint

internal data class RemoteFrame(
    val width: Int,
    val height: Int,
    val format: String?,
    val timestampSeconds: Double,
    val imageBytes: ByteArray
)

@Composable
private fun WebRtcRemoteControlContent(
    viewModel: RemoteControlViewModel = hiltViewModel()
) {
    val scope = rememberCoroutineScope()
    val securitySettings by viewModel.securitySettings.collectAsStateWithLifecycle()

    if (!securitySettings.allowScreenMirroring) {
        FeatureDisabledPanel(
            title = t("屏幕镜像已关闭", "Screen mirroring is turned off", "画面ミラーリングはオフです"),
            message = t("请到 设置 → 访问控制 中开启“屏幕镜像”。", "Go to Settings → Access Control to enable Screen Mirroring.", "設定 → アクセス制御 で画面ミラーリングを有効にしてください。")
        )
        return
    }

    val stateFlow = viewModel.webrtcState
    val signalingFlow = viewModel.signalingStatus
    if (stateFlow == null || signalingFlow == null) {
        FeatureDisabledPanel(
            title = t("跨网互通不可用", "Cross-network access unavailable", "クロスネットワーク接続は利用できません"),
            message = viewModel.initErrorMessage ?: t("WebRTC 初始化失败", "WebRTC initialization failed", "WebRTC の初期化に失敗しました")
        )
        return
    }

    val webrtcState by stateFlow.collectAsStateWithLifecycle()
    val signalingStatus by signalingFlow.collectAsStateWithLifecycle()
    val frame by viewModel.frame.collectAsStateWithLifecycle()
    val viewerStatus by viewModel.viewerStatus.collectAsStateWithLifecycle()
    val streamConfigurationReady by viewModel.streamConfigurationReady.collectAsStateWithLifecycle()
    val routeWitness by requireNotNull(viewModel.webrtc)
        .selectedRouteWitness
        .collectAsStateWithLifecycle()
    var inputCode by remember { mutableStateOf("") }
    val remoteControlReady = streamConfigurationReady && viewModel.hasSessionKeys()

    Column(modifier = Modifier.fillMaxSize()) {
        IOSGlassCard(modifier = Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.Computer,
                    contentDescription = null,
                    tint = when (webrtcState) {
                        is SkyBridgeWebRtcConnectionManager.State.Established -> IOSParityTokens.ColorTokens.CyanAccent
                        is SkyBridgeWebRtcConnectionManager.State.Connected -> IOSParityTokens.ColorTokens.WarningOrange
                        is SkyBridgeWebRtcConnectionManager.State.Connecting -> IOSParityTokens.ColorTokens.WarningOrange
                        is SkyBridgeWebRtcConnectionManager.State.Waiting -> IOSParityTokens.ColorTokens.WarningOrange
                        is SkyBridgeWebRtcConnectionManager.State.Failed -> IOSParityTokens.ColorTokens.ErrorRed
                        is SkyBridgeWebRtcConnectionManager.State.Idle -> Color.White.copy(alpha = 0.6f)
                    },
                    modifier = Modifier.size(32.dp)
                )

                Spacer(Modifier.width(16.dp))

                Column(modifier = Modifier.weight(1f)) {
                    val label = when (val st = webrtcState) {
                        is SkyBridgeWebRtcConnectionManager.State.Idle -> t("未连接", "Not Connected", "未接続")
                        is SkyBridgeWebRtcConnectionManager.State.Waiting -> t("等待加入（${st.code}）", "Waiting for peer (${st.code})", "参加待ち (${st.code})")
                        is SkyBridgeWebRtcConnectionManager.State.Connecting -> t("连接中…（${st.code}）", "Connecting… (${st.code})", "接続中… (${st.code})")
                        is SkyBridgeWebRtcConnectionManager.State.Connected -> t("通道已就绪，握手中…（${st.code}）", "Channel open, handshaking… (${st.code})", "チャネル確立、ハンドシェイク中… (${st.code})")
                        is SkyBridgeWebRtcConnectionManager.State.Established -> t("已连接（${st.code}）", "Connected (${st.code})", "接続済み (${st.code})")
                        is SkyBridgeWebRtcConnectionManager.State.Failed -> t("连接失败", "Connection Failed", "接続失敗")
                    }
                    Text(label, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    Text(
                        text = if (remoteControlReady) {
                            t("安全流配置已确认", "Secure stream configuration acknowledged", "セキュアストリーム設定を確認済み")
                        } else {
                            t("等待安全握手与精确流配置确认…", "Awaiting secure handshake and exact stream acknowledgement…", "セキュアハンドシェイクと正確なストリーム確認を待機中…")
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    if (remoteControlReady) {
                        Text(
                            text = when {
                                viewModel.hasDirectRoute() -> t(
                                    "路由：已验证直连 P2P（所选候选对未使用中继）",
                                    "Route: verified direct P2P (selected pair is not relayed)",
                                    "ルート：直接 P2P を確認済み（選択ペアはリレーなし）"
                                )
                                routeWitness?.route == WebRtcSelectedRoute.RELAY -> t(
                                    "路由：TURN 中继（不属于直连 P2P 证据）",
                                    "Route: TURN relay (not direct P2P evidence)",
                                    "ルート：TURN リレー（直接 P2P の証拠ではありません）"
                                )
                                else -> t(
                                    "路由：未知（不计为直连 P2P 证据）",
                                    "Route: unknown (not counted as direct P2P evidence)",
                                    "ルート：不明（直接 P2P の証拠として扱いません）"
                                )
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
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
                    is SkyBridgeWebRtcConnectionManager.State.Established,
                    is SkyBridgeWebRtcConnectionManager.State.Connected,
                    is SkyBridgeWebRtcConnectionManager.State.Connecting,
                    is SkyBridgeWebRtcConnectionManager.State.Waiting -> {
                        OutlinedButton(onClick = { viewModel.disconnect() }) {
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

        IOSGlassCard(modifier = Modifier.fillMaxWidth()) {
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
                                runCatching { viewModel.generateConnectionCode() }
                                    .onSuccess { code -> inputCode = code }
                            }
                        }
                    ) { Text(t("生成并等待", "Generate & Wait", "生成して待機")) }
                    OutlinedButton(
                        onClick = { viewModel.startAnswerer(inputCode) },
                        enabled = inputCode.uppercase().filter { it.isLetterOrDigit() }.length in 6..16
                    ) { Text(t("加入", "Join", "参加")) }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        RemoteScreenSurface(
            modifier = Modifier.fillMaxWidth().weight(1f, fill = true),
            frame = frame,
            controlEnabled = securitySettings.allowRemoteControl && remoteControlReady,
            viewerStatus = viewerStatus,
            onDecoderError = { detail -> viewModel.onDecoderError(detail) },
            onPointerEvent = { x, y, phase ->
                when (phase) {
                    PointerPhase.Down -> viewModel.sendMouse(MouseEventType.LEFT_MOUSE_DOWN, x, y)
                    PointerPhase.Move -> viewModel.sendMouse(MouseEventType.MOUSE_MOVED, x, y)
                    PointerPhase.Up -> viewModel.sendMouse(MouseEventType.LEFT_MOUSE_UP, x, y)
                }
            },
            onScroll = { up, x, y ->
                val direction = if (up) {
                    RemoteInputMessages.ScrollDirection.UP
                } else {
                    RemoteInputMessages.ScrollDirection.DOWN
                }
                viewModel.sendScroll(direction, x, y)
            },
            onKey = viewModel::sendKeyStroke
        )
    }
}

@Composable
private fun RemoteScreenSurface(
    modifier: Modifier,
    frame: RemoteFrame?,
    controlEnabled: Boolean = true,
    viewerStatus: RemoteViewerStatus = RemoteViewerStatus.Idle,
    onDecoderError: (String?) -> Unit = {},
    onPointerEvent: (x: Double, y: Double, phase: PointerPhase) -> Unit,
    // R6.3 keyboard + scroll send affordances. Both are gated by [controlEnabled] here (the UI
    // affordance is only shown/active when control is enabled) AND defensively inside the
    // ViewModel/client send methods, so view-only mode (R6.4) discards them at both layers.
    onScroll: (up: Boolean, x: Double, y: Double) -> Unit = { _, _, _ -> },
    onKey: (RemoteKeyIntent) -> Unit = {}
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
        // R6.1/R6.11: when the viewer refused a stream (over-limit) or hit an unsupported codec /
        // decoder failure, present the reason instead of the (now-cleared) frame.
        val overLimitOrError = viewerStatus as? RemoteViewerStatus.OverLimit
            ?: (viewerStatus as? RemoteViewerStatus.DecoderError)
        // R6.13: while interrupted / reconnecting the last frame is RETAINED and we overlay a notice;
        // only fall through to a placeholder when there is genuinely no frame to keep.
        val interruptedNotice = when (viewerStatus) {
            RemoteViewerStatus.Interrupted, RemoteViewerStatus.Reconnecting -> frame != null
            else -> false
        }
        if (overLimitOrError != null && frame == null) {
            Box(Modifier.fillMaxSize().padding(16.dp), contentAlignment = Alignment.Center) {
                Text(
                    text = remoteViewerStatusMessage(viewerStatus),
                    color = MaterialTheme.colorScheme.error
                )
            }
        } else if (frame == null) {
            // R6.13/R6.9: after the session ends (last frame cleared to placeholder) show the ended
            // notice; otherwise the ordinary waiting-for-frames placeholder.
            val placeholder = if (viewerStatus == RemoteViewerStatus.SessionEnded) {
                t(
                    "会话已结束，画面已清除",
                    "Session ended — picture cleared",
                    "セッションが終了しました。映像をクリアしました"
                )
            } else {
                t(
                    "等待屏幕帧（支持 JPEG / H.264 / HEVC）",
                    "Waiting for screen frames (supports JPEG / H.264 / HEVC)",
                    "画面フレーム待機中（JPEG / H.264 / HEVC 対応）"
                )
            }
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    text = placeholder,
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
                val pointerContentMode =
                    if (AndroidRemoteVideoFormats.isVideoFormat(normalizedFormat)) {
                        RemotePointerContentMode.FILL_BOUNDS
                    } else {
                        RemotePointerContentMode.FIT_INSIDE
                    }
                val gestureModifier = if (controlEnabled) {
                    Modifier.pointerInput(f.width, f.height, pointerContentMode) {
                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = true)
                            val gesture = RemotePointerGestureStateMachine { coordinate, phase ->
                                onPointerEvent(coordinate.x, coordinate.y, phase)
                            }
                            fun map(offset: Offset): RemotePointerCoordinate? =
                                RemotePointerCoordinateMapper.map(
                                    localX = offset.x.toDouble(),
                                    localY = offset.y.toDouble(),
                                    remoteWidth = f.width,
                                    remoteHeight = f.height,
                                    viewWidth = size.width.toDouble(),
                                    viewHeight = size.height.toDouble(),
                                    contentMode = pointerContentMode
                                )

                            val accepted = gesture.begin(map(down.position))
                            if (accepted) down.consume()
                            try {
                                while (true) {
                                    val pointerEvent = awaitPointerEvent()
                                    if (
                                        gesture.cancelIfMultiplePointers(
                                            pointerEvent.changes.count { it.pressed }
                                        )
                                    ) {
                                        pointerEvent.changes.forEach { it.consume() }
                                        break
                                    }
                                    val change = pointerEvent.changes.firstOrNull { it.id == down.id }
                                    if (change == null) {
                                        gesture.cancel()
                                        break
                                    }
                                    val coordinate = map(change.position)
                                    if (!change.pressed) {
                                        gesture.end(coordinate)
                                        if (accepted) change.consume()
                                        break
                                    }
                                    if (change.positionChanged()) {
                                        gesture.move(coordinate)
                                        if (accepted) change.consume()
                                    }
                                }
                            } finally {
                                gesture.cancel()
                            }
                        }
                    }
                } else {
                    Modifier
                }
                if (AndroidRemoteVideoFormats.isVideoFormat(normalizedFormat)) {
                    Box(
                        modifier = Modifier.fillMaxSize()
                    ) {
                        RemoteVideoSurface(
                            modifier = Modifier
                                .fillMaxSize()
                                .then(gestureModifier),
                            frame = f,
                            normalizedFormat = normalizedFormat,
                            onDecoderError = onDecoderError
                        )
                        if (interruptedNotice) {
                            RemoteInterruptedOverlay(viewerStatus)
                        }
                        if (controlEnabled) {
                            RemoteInputControlsOverlay(
                                frameWidth = f.width,
                                frameHeight = f.height,
                                onScroll = onScroll,
                                onKey = onKey
                            )
                        } else {
                            RemoteViewOnlyIndicator()
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
                            modifier = Modifier.fillMaxSize()
                        ) {
                            Image(
                                bitmap = bmp.asImageBitmap(),
                                contentDescription = t("远程屏幕", "Remote Screen", "リモート画面"),
                                modifier = Modifier
                                    .fillMaxSize()
                                    .then(gestureModifier)
                            )
                            if (interruptedNotice) {
                                RemoteInterruptedOverlay(viewerStatus)
                            }
                            if (controlEnabled) {
                                RemoteInputControlsOverlay(
                                    frameWidth = f.width,
                                    frameHeight = f.height,
                                    onScroll = onScroll,
                                    onKey = onKey
                                )
                            } else {
                                RemoteViewOnlyIndicator()
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * R6.13 interrupted/reconnecting overlay — a leaf node placed on top of the RETAINED last frame.
 * Shows a localized "picture interrupted" / "reconnecting" notice at the top of the surface without
 * clearing the frame beneath it.
 */
@Composable
private fun BoxScope.RemoteInterruptedOverlay(status: RemoteViewerStatus) {
    val notice = when (status) {
        RemoteViewerStatus.Reconnecting -> t(
            "画面已中断，正在重连…（保留最近一帧）",
            "Picture interrupted — reconnecting… (last frame retained)",
            "映像が中断しました。再接続中…（直近のフレームを保持）"
        )
        else -> t(
            "画面已中断，正在等待新帧…（保留最近一帧）",
            "Picture interrupted — waiting for frames… (last frame retained)",
            "映像が中断しました。フレーム待機中…（直近のフレームを保持）"
        )
    }
    Box(
        modifier = Modifier
            .align(Alignment.TopCenter)
            .padding(12.dp)
            .background(
                Color.Black.copy(alpha = 0.55f),
                RoundedCornerShape(10.dp)
            )
            .padding(horizontal = 12.dp, vertical = 8.dp)
    ) {
        Text(
            text = notice,
            style = MaterialTheme.typography.bodySmall,
            color = IOSParityTokens.ColorTokens.WarningOrange
        )
    }
}

/**
 * R6.4 "view only" indicator — leaf node shown at the bottom of the remote-screen surface whenever
 * remote control is NOT enabled. While this is visible the surface sends no pointer/keyboard/scroll
 * events (the gesture modifier is disabled and the input-controls overlay is not composed).
 */
@Composable
private fun BoxScope.RemoteViewOnlyIndicator() {
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

/**
 * R6.3 keyboard + scroll input affordances — a leaf overlay on the remote-screen surface, only
 * composed when remote control is enabled (`controlEnabled`). Scroll up/down buttons map to
 * SCROLL_UP / SCROLL_DOWN (expressed as mouse events on the wire, no new fields). Keyboard buttons
 * emit typed Android hardware-key intents; free-form text is deliberately not represented as a
 * keyCode because the current wire carries macOS virtual keys rather than Unicode text.
 * All coordinates are the remote-screen center so the host applies the scroll at a stable anchor.
 */
@Composable
private fun BoxScope.RemoteInputControlsOverlay(
    frameWidth: Int,
    frameHeight: Int,
    onScroll: (up: Boolean, x: Double, y: Double) -> Unit,
    onKey: (RemoteKeyIntent) -> Unit
) {
    val centerX = frameWidth / 2.0
    val centerY = frameHeight / 2.0
    val namedKeys = listOf(
        RemoteKeyIntent.Named.TAB to "Tab",
        RemoteKeyIntent.Named.ENTER to "Enter",
        RemoteKeyIntent.Named.ARROW_LEFT to "←",
        RemoteKeyIntent.Named.ARROW_UP to "↑",
        RemoteKeyIntent.Named.ARROW_DOWN to "↓",
        RemoteKeyIntent.Named.ARROW_RIGHT to "→",
        RemoteKeyIntent.Named.BACKSPACE to "⌫",
        RemoteKeyIntent.Named.SPACE to t("空格", "Space", "スペース")
    )

    Row(
        modifier = Modifier
            .align(Alignment.BottomCenter)
            .padding(12.dp)
            .background(
                Color.Black.copy(alpha = 0.45f),
                RoundedCornerShape(IOSParityTokens.ShapeTokens.CompactCornerRadius)
            )
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        OutlinedButton(
            onClick = { onScroll(true, centerX, centerY) },
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
        ) { Text(t("上滚", "Scroll ↑", "上スクロール")) }
        OutlinedButton(
            onClick = { onScroll(false, centerX, centerY) },
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
        ) { Text(t("下滚", "Scroll ↓", "下スクロール")) }
        namedKeys.forEach { (key, label) ->
            OutlinedButton(
                onClick = { onKey(key) },
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
            ) { Text(label) }
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

/**
 * Localized, user-facing reason for a refused / errored viewer status (R6.1, R6.11). Presented on the
 * remote-screen surface instead of silently dropping the frame.
 */
@Composable
private fun remoteViewerStatusMessage(status: RemoteViewerStatus): String =
    when (status) {
        is RemoteViewerStatus.OverLimit -> when (status.reason) {
            RemoteRenderAdmissionPolicy.RejectionReason.RESOLUTION_OVER_LIMIT -> t(
                "分辨率超限（${status.width}×${status.height}），最高支持 1920×1080，已停止渲染",
                "Resolution over limit (${status.width}×${status.height}); max supported is 1920×1080. Rendering stopped.",
                "解像度が上限を超えています（${status.width}×${status.height}）。最大 1920×1080 まで対応。レンダリングを停止しました。"
            )
            RemoteRenderAdmissionPolicy.RejectionReason.FRAME_RATE_OVER_LIMIT -> t(
                "帧率超限（${status.frameRate} fps），最高支持 60 fps，已停止渲染",
                "Frame rate over limit (${status.frameRate} fps); max supported is 60 fps. Rendering stopped.",
                "フレームレートが上限を超えています（${status.frameRate} fps）。最大 60 fps まで対応。レンダリングを停止しました。"
            )
        }
        is RemoteViewerStatus.DecoderError -> when (status.cause) {
            RemoteViewerStatus.DecoderError.Cause.UNSUPPORTED_CODEC -> t(
                "编解码格式不受支持，已停止渲染并释放解码资源",
                "Codec is not supported. Rendering stopped and decode resources released.",
                "コーデックがサポートされていません。レンダリングを停止し、デコードリソースを解放しました。"
            )
            RemoteViewerStatus.DecoderError.Cause.DECODER_FAILURE -> t(
                "解码器初始化失败，已停止渲染并释放解码资源",
                "Decoder initialization failed. Rendering stopped and decode resources released.",
                "デコーダの初期化に失敗しました。レンダリングを停止し、デコードリソースを解放しました。"
            )
        }
        RemoteViewerStatus.Interrupted -> t(
            "画面已中断，正在等待新帧…",
            "Picture interrupted — waiting for frames…",
            "映像が中断しました。フレーム待機中…"
        )
        RemoteViewerStatus.Reconnecting -> t(
            "画面已中断，正在重连…",
            "Picture interrupted — reconnecting…",
            "映像が中断しました。再接続中…"
        )
        RemoteViewerStatus.SessionEnded -> t(
            "会话已结束，画面已清除",
            "Session ended — picture cleared",
            "セッションが終了しました。映像をクリアしました"
        )
        RemoteViewerStatus.Idle, RemoteViewerStatus.Rendering -> ""
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
                    t("对端身份未受信，已拒绝远控", "Peer identity is not trusted; remote control rejected", "相手の識別情報が信頼されていないため拒否")
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
        MacRemoteControlClient.SecurityState.Disconnected -> Color.White.copy(alpha = 0.6f)
        is MacRemoteControlClient.SecurityState.Negotiating -> IOSParityTokens.ColorTokens.WarningOrange
        is MacRemoteControlClient.SecurityState.Secure ->
            if (state.trustState == MacRemoteControlClient.TrustState.UNTRUSTED_EPHEMERAL) {
                IOSParityTokens.ColorTokens.ErrorRed
            } else {
                IOSParityTokens.ColorTokens.SuccessGreen
            }
        is MacRemoteControlClient.SecurityState.Plaintext -> IOSParityTokens.ColorTokens.ErrorRed
        is MacRemoteControlClient.SecurityState.Failed -> IOSParityTokens.ColorTokens.ErrorRed
    }

@Composable
private fun ServiceRow(label: String, selected: Boolean, onClick: () -> Unit) {
    val bg = if (selected) IOSParityTokens.ColorTokens.CyanAccent.copy(alpha = 0.16f) else Color.White.copy(alpha = 0.04f)
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = bg,
        shape = RoundedCornerShape(12.dp),
        onClick = onClick
    ) {
        Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, modifier = Modifier.weight(1f), color = Color.White)
            if (selected) {
                Text(localizedText("已选", "Selected", "選択済み"), color = IOSParityTokens.ColorTokens.CyanAccent, style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
fun RemoteControlScreenPreview() {
    SkyBridgeCompassTheme {
        RemoteControlScreen(navController = rememberNavController())
    }
}
