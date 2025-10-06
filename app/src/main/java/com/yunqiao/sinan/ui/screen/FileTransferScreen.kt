package com.yunqiao.sinan.ui.screen

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Cable
import androidx.compose.material.icons.filled.Cast
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.HighQuality
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.LocalMovies
import androidx.compose.material.icons.filled.Loop
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Nfc
import androidx.compose.material.icons.filled.TextSnippet
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yunqiao.sinan.manager.BridgeAccountEndpoint
import com.yunqiao.sinan.manager.BridgeDevice
import com.yunqiao.sinan.manager.BridgeLinkQuality
import com.yunqiao.sinan.manager.BridgeTransport
import com.yunqiao.sinan.manager.BridgeTransportHint
import com.yunqiao.sinan.manager.HybridFileTransferManager
import com.yunqiao.sinan.manager.TransferMediaCapability
import com.yunqiao.sinan.operationshub.manager.FileTransferTask
import com.yunqiao.sinan.operationshub.manager.TransferCategory
import com.yunqiao.sinan.ui.component.MetricChip
import com.yunqiao.sinan.ui.component.TransportBadge
import com.yunqiao.sinan.ui.theme.GlassColors
import kotlinx.coroutines.launch
import java.util.Locale

@Composable
fun FileTransferScreen(
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val transferManager = remember { HybridFileTransferManager(context) }
    val statistics by transferManager.statistics.collectAsStateWithLifecycle()
    val activeTasks by transferManager.activeTasks.collectAsStateWithLifecycle()
    val completedTasks by transferManager.completedTasks.collectAsStateWithLifecycle()
    val failedTasks by transferManager.failedTasks.collectAsStateWithLifecycle()
    val transport by transferManager.transport.collectAsStateWithLifecycle()
    val nearbyDevices by transferManager.proximityDevices.collectAsStateWithLifecycle()
    val remoteAccounts by transferManager.remoteAccounts.collectAsStateWithLifecycle()
    val isProximity by transferManager.proximityState.collectAsStateWithLifecycle()
    val linkQuality by transferManager.linkQuality.collectAsStateWithLifecycle()
    val mediaCapabilities by transferManager.mediaCapabilities.collectAsStateWithLifecycle()
    val coroutineScope = rememberCoroutineScope()
    var manualAccount by rememberSaveable { mutableStateOf("") }
    var pendingTransfer by remember { mutableStateOf<PendingTransfer?>(null) }

    val documentLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        val request = pendingTransfer
        if (uri != null && request != null) {
            try {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: SecurityException) {
            }
            coroutineScope.launch {
                val result = transferManager.startSmartTransfer(
                    sourceUri = uri,
                    targetDeviceId = request.device?.deviceId,
                    remoteAccount = request.accountId,
                    categoryHint = request.category
                )
                result.exceptionOrNull()?.let { error ->
                    Toast.makeText(
                        context,
                        error.message ?: "传输启动失败",
                        Toast.LENGTH_LONG
                    ).show()
                }
            }
        } else if (uri == null && request != null) {
            Toast.makeText(context, "未选择任何文件", Toast.LENGTH_SHORT).show()
        }
        pendingTransfer = null
    }

    fun launchTransferPicker(request: PendingTransfer, category: TransferCategory?) {
        val normalized = request.copy(category = category ?: request.category)
        pendingTransfer = normalized
        documentLauncher.launch(mimeTypesForCategory(normalized.category))
    }

    DisposableEffect(transferManager) {
        onDispose { transferManager.release() }
    }

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .background(color = Color.Transparent, shape = RoundedCornerShape(16.dp))
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            TransferOverviewCard(
                statistics = statistics,
                transport = transport,
                isProximity = isProximity,
                linkQuality = linkQuality,
                categoryDistribution = statistics.categoryDistribution
            )
        }

        if (mediaCapabilities.isNotEmpty()) {
            item {
                MediaCapabilitySection(
                    capabilities = mediaCapabilities,
                    onStart = { category ->
                        val proximityTarget = nearbyDevices.firstOrNull()
                        val remoteTarget = remoteAccounts.firstOrNull()?.accountId
                        if (proximityTarget == null && remoteTarget == null) {
                            Toast.makeText(context, "暂无可用的传输目标", Toast.LENGTH_SHORT).show()
                        } else {
                            val request = PendingTransfer(
                                device = proximityTarget,
                                accountId = if (proximityTarget == null) remoteTarget else null,
                                category = category
                            )
                            launchTransferPicker(request, category)
                        }
                    }
                )
            }
        }

        if (nearbyDevices.isNotEmpty()) {
            item {
                SectionTitle(text = "附近设备极速互传")
            }
            items(nearbyDevices) { device ->
                ProximityTransferCard(
                    device = device,
                    onTransfer = {
                        launchTransferPicker(PendingTransfer(device = device), null)
                    }
                )
            }
        }

        if (remoteAccounts.isNotEmpty()) {
            item {
                SectionTitle(text = "云桥账号中继")
            }
            items(remoteAccounts) { account ->
                RemoteTransferCard(
                    account = account,
                    onTransfer = {
                        launchTransferPicker(PendingTransfer(accountId = account.accountId), null)
                    }
                )
            }
        }

        item {
            ManualRelayCard(
                account = manualAccount,
                onAccountChange = { manualAccount = it },
                onConnect = {
                    if (manualAccount.isNotBlank()) {
                        coroutineScope.launch { transferManager.ensureAccount(manualAccount) }
                        launchTransferPicker(PendingTransfer(accountId = manualAccount), null)
                    }
                }
            )
        }

        if (activeTasks.isNotEmpty()) {
            item {
                SectionTitle(text = "活跃传输")
            }
            items(activeTasks) { task ->
                ActiveTransferItem(
                    task = task,
                    onCancel = {
                        coroutineScope.launch {
                            transferManager.cancelTransfer(task.taskId)
                        }
                    }
                )
            }
        }

        if (completedTasks.isNotEmpty() || failedTasks.isNotEmpty()) {
            item {
                SectionTitle(text = "历史记录")
            }
            items(completedTasks.take(3)) { task ->
                HistoryTransferItem(task = task, highlightColor = Color(0xFF4CAF50))
            }
            items(failedTasks.take(3)) { task ->
                HistoryTransferItem(task = task, highlightColor = Color(0xFFE53935))
            }
        }
    }
}

@Composable
private fun TransferOverviewCard(
    statistics: com.yunqiao.sinan.operationshub.model.FileTransferStatistics,
    transport: BridgeTransport,
    isProximity: Boolean,
    linkQuality: BridgeLinkQuality,
    categoryDistribution: Map<TransferCategory, Int>
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(18.dp)
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text(
                text = "文件传输",
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                text = if (isProximity) "近距优先：自动建立免外网高速通道" else "智能路由：云桥中继与局域网自适应",
                fontSize = 13.sp,
                color = Color.White.copy(alpha = 0.72f)
            )

            Spacer(modifier = Modifier.height(18.dp))

            Row(
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                OverviewMetric(title = "活跃任务", value = statistics.activeTasks.toString(), icon = Icons.Default.Loop)
                OverviewMetric(title = "平均速度", value = "${"%.1f".format(statistics.averageSpeed)} MB/s", icon = Icons.Default.Speed)
                OverviewMetric(title = "累计数据", value = "${statistics.totalDataTransferred} MB", icon = Icons.Default.Storage)
            }

            Spacer(modifier = Modifier.height(18.dp))

            TransportBadge(transport = transport)

            Spacer(modifier = Modifier.height(14.dp))

            CategoryDistributionRow(distribution = categoryDistribution)

            Spacer(modifier = Modifier.height(14.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                MetricChip(
                    label = "吞吐",
                    value = String.format(Locale.getDefault(), "%.0f Mbps", linkQuality.throughputMbps),
                    icon = Icons.Default.Speed
                )
                MetricChip(
                    label = "延迟",
                    value = "${linkQuality.latencyMs} ms",
                    icon = Icons.Default.Timer
                )
                val accessLabel = when (linkQuality.hint) {
                    BridgeTransportHint.UltraWideband -> "液态直连"
                    BridgeTransportHint.Bluetooth -> "蓝牙"
                    BridgeTransportHint.Nfc -> "NFC"
                    BridgeTransportHint.AirPlay -> "AirPlay"
                    BridgeTransportHint.WifiDirect -> if (linkQuality.isDirect) "热点直连" else "Wi-Fi"
                    BridgeTransportHint.Lan -> "局域网"
                    BridgeTransportHint.Cloud -> "云桥"
                    BridgeTransportHint.UniversalBridge -> "通用桥接"
                }
                val accessIcon = when (linkQuality.hint) {
                    BridgeTransportHint.UltraWideband -> Icons.Default.WifiTethering
                    BridgeTransportHint.Bluetooth -> Icons.Default.Bluetooth
                    BridgeTransportHint.Nfc -> Icons.Default.Nfc
                    BridgeTransportHint.AirPlay -> Icons.Default.Cast
                    BridgeTransportHint.WifiDirect -> Icons.Default.WifiTethering
                    BridgeTransportHint.Lan -> Icons.Default.Cable
                    BridgeTransportHint.Cloud -> Icons.Default.Cloud
                    BridgeTransportHint.UniversalBridge -> Icons.Default.HighQuality
                }
                MetricChip(
                    label = "链路",
                    value = accessLabel,
                    icon = accessIcon
                )
                if (linkQuality.supportsLossless) {
                    MetricChip(
                        label = "画质",
                        value = "近无损",
                        icon = Icons.Default.HighQuality
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MediaCapabilitySection(
    capabilities: List<TransferMediaCapability>,
    onStart: (TransferCategory) -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(18.dp)
    ) {
        Column(modifier = Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(text = "媒体极速通道", fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                items(capabilities) { capability ->
                    MediaCapabilityCard(capability = capability, onStart = { onStart(capability.category) })
                }
            }
        }
    }
}

private data class PendingTransfer(
    val device: BridgeDevice? = null,
    val accountId: String? = null,
    val category: TransferCategory? = null
)

@Composable
private fun MediaCapabilityCard(capability: TransferMediaCapability, onStart: () -> Unit) {
    Card(
        colors = CardDefaults.cardColors(containerColor = GlassColors.background.copy(alpha = 0.9f)),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(modifier = Modifier.width(220.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(imageVector = categoryIcon(capability.category), contentDescription = null, tint = Color.White)
                Text(text = capability.label, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White)
            }
            Text(text = capability.description, fontSize = 12.sp, color = Color.White.copy(alpha = 0.72f))
            Text(text = "格式：${capability.preferredExtensions.joinToString(" / ")}", fontSize = 11.sp, color = Color.White.copy(alpha = 0.7f))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                capability.recommendedTransports.forEach { hint ->
                    AssistChip(
                        onClick = {},
                        label = { Text(text = transportHintLabel(hint), fontSize = 10.sp) },
                        colors = AssistChipDefaults.assistChipColors(
                            containerColor = Color.White.copy(alpha = 0.14f),
                            labelColor = Color.White
                        )
                    )
                }
            }
            Text(text = "建议大小：${capability.maxSizeMb} MB", fontSize = 11.sp, color = Color.White.copy(alpha = 0.8f))
            Button(onClick = onStart, modifier = Modifier.fillMaxWidth()) {
                Text(text = "一键传输")
            }
        }
    }
}

private fun mimeTypesForCategory(category: TransferCategory?): Array<String> {
    return when (category) {
        TransferCategory.IMAGE -> arrayOf("image/*")
        TransferCategory.VIDEO -> arrayOf("video/*")
        TransferCategory.AUDIO -> arrayOf("audio/*")
        TransferCategory.DOCUMENT -> arrayOf(
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )
        TransferCategory.APPLICATION -> arrayOf("application/vnd.android.package-archive", "application/octet-stream")
        TransferCategory.ARCHIVE -> arrayOf(
            "application/zip",
            "application/x-7z-compressed",
            "application/x-rar-compressed",
            "application/gzip"
        )
        TransferCategory.OTHER, null -> arrayOf("*/*")
    }
}

@Composable
private fun CategoryDistributionRow(distribution: Map<TransferCategory, Int>) {
    if (distribution.isEmpty()) return
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(distribution.toList()) { (category, count) ->
            AssistChip(
                onClick = {},
                leadingIcon = {
                    Icon(imageVector = categoryIcon(category), contentDescription = null, tint = Color.White)
                },
                label = { Text(text = "${categoryLabel(category)} ${count}", fontSize = 11.sp) },
                colors = AssistChipDefaults.assistChipColors(
                    containerColor = Color.White.copy(alpha = 0.12f),
                    labelColor = Color.White
                )
            )
        }
    }
}

private fun categoryIcon(category: TransferCategory): ImageVector {
    return when (category) {
        TransferCategory.IMAGE -> Icons.Default.Image
        TransferCategory.VIDEO -> Icons.Default.LocalMovies
        TransferCategory.AUDIO -> Icons.Default.LibraryMusic
        TransferCategory.ARCHIVE -> Icons.Default.Archive
        TransferCategory.APPLICATION -> Icons.Default.Apps
        TransferCategory.DOCUMENT -> Icons.Default.TextSnippet
        TransferCategory.OTHER -> Icons.Default.FileUpload
    }
}

private fun categoryLabel(category: TransferCategory): String {
    return when (category) {
        TransferCategory.IMAGE -> "照片"
        TransferCategory.VIDEO -> "视频"
        TransferCategory.AUDIO -> "音频"
        TransferCategory.ARCHIVE -> "压缩"
        TransferCategory.APPLICATION -> "应用"
        TransferCategory.DOCUMENT -> "文档"
        TransferCategory.OTHER -> "通用"
    }
}

private fun endpointLabel(endpoint: Uri): String {
    val scheme = endpoint.scheme?.lowercase(Locale.getDefault()) ?: return endpoint.toString()
    val host = endpoint.host ?: endpoint.schemeSpecificPart
    val port = if (endpoint.port > 0) ":${endpoint.port}" else ""
    return when (scheme) {
        "direct", "ultra" -> "直连 $host$port"
        "lan" -> "局域网 $host$port"
        "relay" -> "云桥 ${endpoint.host ?: "中继"}$port"
        "bt" -> "蓝牙 ${endpoint.host ?: endpoint.schemeSpecificPart}"
        "nfc" -> "NFC ${endpoint.host ?: endpoint.schemeSpecificPart}"
        "airplay" -> "AirPlay ${endpoint.host ?: "终端"}$port"
        "peripheral" -> "外设 ${endpoint.host ?: "终端"}$port"
        else -> endpoint.toString()
    }
}

private fun transportHintLabel(hint: BridgeTransportHint): String {
    return when (hint) {
        BridgeTransportHint.UltraWideband -> "超宽带"
        BridgeTransportHint.Bluetooth -> "蓝牙"
        BridgeTransportHint.Nfc -> "NFC"
        BridgeTransportHint.AirPlay -> "AirPlay"
        BridgeTransportHint.WifiDirect -> "Wi-Fi 直连"
        BridgeTransportHint.Lan -> "局域网"
        BridgeTransportHint.Cloud -> "云桥"
        BridgeTransportHint.UniversalBridge -> "通用桥接"
    }
}

@Composable
private fun OverviewMetric(title: String, value: String, icon: ImageVector) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Surface(
            shape = CircleShape,
            color = Color.White.copy(alpha = 0.1f)
        ) {
            Box(modifier = Modifier.size(44.dp), contentAlignment = Alignment.Center) {
                Icon(imageVector = icon, contentDescription = null, tint = Color.White)
            }
        }
        Spacer(modifier = Modifier.height(6.dp))
        Text(text = value, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color.White)
        Text(text = title, fontSize = 12.sp, color = Color.White.copy(alpha = 0.7f))
    }
}

@Composable
private fun ProximityTransferCard(
    device: BridgeDevice,
    onTransfer: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(14.dp)
    ) {
        Column(modifier = Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(imageVector = Icons.Default.Send, contentDescription = null, tint = Color(0xFF00E5FF))
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = device.displayName,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = "信号 ${device.signalLevel}",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "地址 ${device.deviceAddress}",
                fontSize = 12.sp,
                color = Color.White.copy(alpha = 0.6f)
            )
            Spacer(modifier = Modifier.height(12.dp))
            Button(
                onClick = onTransfer,
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF00E5FF))
            ) {
                Icon(Icons.Default.FileUpload, contentDescription = null, tint = Color.Black)
                Spacer(modifier = Modifier.width(6.dp))
                Text(text = "开始直连传输", color = Color.Black)
            }
        }
    }
}

@Composable
private fun RemoteTransferCard(
    account: BridgeAccountEndpoint,
    onTransfer: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(14.dp)
    ) {
        Column(modifier = Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(imageVector = Icons.Default.Cloud, contentDescription = null, tint = Color(0xFF7E57C2))
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "账号 ${account.accountId}",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = "${account.throughputMbps.toInt()} Mbps",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "中继 ${account.relayId}",
                fontSize = 12.sp,
                color = Color.White.copy(alpha = 0.6f)
            )
            Spacer(modifier = Modifier.height(12.dp))
            Button(
                onClick = onTransfer,
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF7E57C2))
            ) {
                Icon(Icons.Default.CheckCircle, contentDescription = null)
                Spacer(modifier = Modifier.width(6.dp))
                Text(text = "通过云桥发送")
            }
        }
    }
}

@Composable
private fun ManualRelayCard(
    account: String,
    onAccountChange: (String) -> Unit,
    onConnect: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface.copy(alpha = 0.95f)),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(modifier = Modifier.padding(18.dp)) {
            Text(
                text = "自定义账号中转",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            Spacer(modifier = Modifier.height(10.dp))
            OutlinedTextField(
                value = account,
                onValueChange = onAccountChange,
                label = { Text("云桥账号") },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color.White.copy(alpha = 0.8f),
                    unfocusedBorderColor = Color.White.copy(alpha = 0.5f),
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    cursorColor = Color.White
                ),
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(modifier = Modifier.height(12.dp))
            Button(
                onClick = onConnect,
                enabled = account.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF00E5FF))
            ) {
                Icon(Icons.Default.Cloud, contentDescription = null, tint = Color.Black)
                Spacer(modifier = Modifier.width(6.dp))
                Text(text = "发起云桥传输", color = Color.Black)
            }
        }
    }
}

@Composable
private fun ActiveTransferItem(
    task: FileTransferTask,
    onCancel: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface),
        shape = RoundedCornerShape(14.dp)
    ) {
        Column(modifier = Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(imageVector = categoryIcon(task.category), contentDescription = null, tint = Color(0xFF00E5FF))
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = task.fileName,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = "${"%.1f".format(task.currentSpeed)} MB/s",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
            }
            Spacer(modifier = Modifier.height(8.dp))
            LinearProgressIndicator(
                progress = task.progress / 100f,
                color = Color(0xFF00E5FF)
            )
            Spacer(modifier = Modifier.height(8.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "${categoryLabel(task.category)} · 已传输 ${task.transferredBytes / (1024 * 1024)} MB",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.7f)
                )
                TextButton(onClick = onCancel) {
                    Text(text = "取消", color = Color.White)
                }
            }
        }
    }
}

@Composable
private fun HistoryTransferItem(task: FileTransferTask, highlightColor: Color) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = GlassColors.surface.copy(alpha = 0.9f)),
        shape = RoundedCornerShape(12.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Surface(shape = CircleShape, color = highlightColor.copy(alpha = 0.2f)) {
                Box(modifier = Modifier.size(40.dp), contentAlignment = Alignment.Center) {
                    Icon(imageVector = categoryIcon(task.category), contentDescription = null, tint = highlightColor)
                }
            }
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = task.fileName,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    text = "${categoryLabel(task.category)} · ${endpointLabel(task.endpoint)}",
                    fontSize = 12.sp,
                    color = Color.White.copy(alpha = 0.6f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Text(
                text = when (task.status) {
                    com.yunqiao.sinan.operationshub.manager.TransferStatus.COMPLETED -> "已完成"
                    com.yunqiao.sinan.operationshub.manager.TransferStatus.FAILED -> "失败"
                    else -> task.status.name
                },
                fontSize = 12.sp,
                color = highlightColor
            )
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text = text,
        fontSize = 16.sp,
        fontWeight = FontWeight.SemiBold,
        color = Color.White
    )
}
