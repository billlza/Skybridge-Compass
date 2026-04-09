package com.skybridge.compass.android.ui.screens.remotecontrol

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.unit.dp
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.i18n.localizedText
import com.skybridge.compass.android.remote.host.AndroidRemoteControlHostRuntime
import com.skybridge.compass.android.remote.host.AndroidRemoteControlHostService
import com.skybridge.compass.android.ui.components.LiquidGlassSurface

@Composable
private fun hostText(zh: String, en: String, ja: String): String = localizedText(zh, en, ja)

@Composable
fun AndroidRemoteHostContent(
    securitySettings: SecuritySettings,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val projectionManager = remember(context) {
        context.getSystemService(MediaProjectionManager::class.java)
    }
    val hostState by AndroidRemoteControlHostRuntime.state.collectAsState()

    val projectionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode != Activity.RESULT_OK) {
            return@rememberLauncherForActivityResult
        }
        val data = result.data ?: return@rememberLauncherForActivityResult
        AndroidRemoteControlHostService.start(context, result.resultCode, data)
    }

    Column(modifier = modifier.fillMaxSize()) {
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
                    tint = when (hostState) {
                        is AndroidRemoteControlHostRuntime.State.Running -> MaterialTheme.colorScheme.primary
                        is AndroidRemoteControlHostRuntime.State.Starting -> MaterialTheme.colorScheme.tertiary
                        is AndroidRemoteControlHostRuntime.State.Error -> MaterialTheme.colorScheme.error
                        AndroidRemoteControlHostRuntime.State.Stopped -> MaterialTheme.colorScheme.onSurfaceVariant
                    }
                )
                Spacer(modifier = Modifier.width(8.dp))
                Column(modifier = Modifier.weight(1f)) {
                    val title = when (val state = hostState) {
                        AndroidRemoteControlHostRuntime.State.Stopped ->
                            hostText("本机未共享", "This Android is not shared", "この Android は共有されていません")
                        is AndroidRemoteControlHostRuntime.State.Starting ->
                            hostText("共享准备中…", "Preparing host…", "共有準備中…")
                        is AndroidRemoteControlHostRuntime.State.Running ->
                            hostText("本机已共享", "This Android is being shared", "この Android は共有中です")
                        is AndroidRemoteControlHostRuntime.State.Error ->
                            hostText("共享失败", "Host failed", "共有に失敗しました")
                    }
                    Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    Text(
                        text = when (val state = hostState) {
                            AndroidRemoteControlHostRuntime.State.Stopped ->
                                hostText(
                                    "启动后会以 _skybridge-remote._tcp 对外广播",
                                    "Once started, this device advertises `_skybridge-remote._tcp`",
                                    "開始すると `_skybridge-remote._tcp` として公開されます"
                                )
                            is AndroidRemoteControlHostRuntime.State.Starting -> state.message
                            is AndroidRemoteControlHostRuntime.State.Running ->
                                hostText(
                                    "端口 ${state.port} · ${state.captureWidth}x${state.captureHeight} · 客户端 ${state.connectedClients}",
                                    "Port ${state.port} · ${state.captureWidth}x${state.captureHeight} · Clients ${state.connectedClients}",
                                    "ポート ${state.port} ・ ${state.captureWidth}x${state.captureHeight} ・ クライアント ${state.connectedClients}"
                                )
                            is AndroidRemoteControlHostRuntime.State.Error -> state.message
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        LiquidGlassSurface(
            modifier = Modifier.fillMaxWidth(),
            blurRadius = 0.dp,
            tintColor = Color.White.copy(alpha = 0.05f),
            tintAlpha = 0.05f,
            borderAlpha = 0.12f,
            highlightAlpha = 0.04f,
            edgeGlowAlpha = 0.03f
        ) {
            Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    text = hostText("共享当前 Android", "Share this Android", "この Android を共有"),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    text = hostText(
                        "这会启动真实的 LAN 远控服务：发送屏幕帧，并接收来自 macOS/iOS 的鼠标、文本输入、导航键与常用快捷键。",
                        "This starts the real LAN remote-control host: it streams screen frames and accepts mouse, text entry, navigation keys, and common shortcuts from macOS and iOS.",
                        "実際の LAN リモートホストを起動し、画面フレームを配信しつつ macOS / iOS からのマウス、文字入力、ナビゲーションキー、主要ショートカットを受け付けます。"
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = if (securitySettings.allowRemoteControl) {
                        when (val state = hostState) {
                            is AndroidRemoteControlHostRuntime.State.Running ->
                                if (state.inputEnabled) {
                                    hostText(
                                        "远程输入已启用。若未生效，请确认系统中已开启 SkyBridge 无障碍服务。",
                                        "Remote input is enabled. If input still does not work, confirm that the SkyBridge accessibility service is enabled in system settings.",
                                        "リモート入力は有効です。動作しない場合は、システム設定で SkyBridge のアクセシビリティサービスを有効にしてください。"
                                    )
                                } else {
                                    hostText(
                                        "当前仅可查看屏幕。请在系统无障碍设置中启用 SkyBridge，才能执行远程输入。",
                                        "This session is view-only right now. Enable the SkyBridge accessibility service in system settings to allow remote input.",
                                        "現在は画面表示のみです。リモート入力を有効にするには、システム設定で SkyBridge アクセシビリティサービスを有効にしてください。"
                                    )
                                }
                            else -> hostText(
                                "启动前建议先开启 SkyBridge 无障碍服务，这样远程输入会立即生效。",
                                "Enable the SkyBridge accessibility service first so remote input works immediately after the host starts.",
                                "先に SkyBridge アクセシビリティサービスを有効にしておくと、起動直後からリモート入力が使えます。"
                            )
                        }
                    } else {
                        hostText(
                            "当前访问控制禁止远程输入，因此只会共享画面，不接受鼠标或键盘事件。",
                            "Access control currently blocks remote input, so the host will share the screen only and ignore mouse/keyboard events.",
                            "アクセス制御でリモート入力が禁止されているため、画面共有のみ行い、マウス・キーボード入力は受け付けません。"
                        )
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(
                        enabled = hostState !is AndroidRemoteControlHostRuntime.State.Starting &&
                            projectionManager != null,
                        onClick = {
                            val manager = projectionManager ?: return@Button
                            projectionLauncher.launch(manager.createScreenCaptureIntent())
                        }
                    ) {
                        Text(hostText("开始共享", "Start Sharing", "共有を開始"))
                    }
                    OutlinedButton(
                        enabled = hostState is AndroidRemoteControlHostRuntime.State.Running ||
                            hostState is AndroidRemoteControlHostRuntime.State.Starting,
                        onClick = { AndroidRemoteControlHostService.stop(context) }
                    ) {
                        Icon(Icons.Default.Stop, contentDescription = null)
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(hostText("停止", "Stop", "停止"))
                    }
                    OutlinedButton(
                        onClick = {
                            context.startActivity(
                                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                            )
                        }
                    ) {
                        Icon(Icons.Default.Settings, contentDescription = null)
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(hostText("无障碍", "Accessibility", "アクセシビリティ"))
                    }
                }
            }
        }
    }
}
