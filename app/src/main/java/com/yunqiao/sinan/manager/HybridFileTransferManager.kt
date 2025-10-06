package com.yunqiao.sinan.manager

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.coerceAtLeast
import kotlin.math.roundToInt
import com.yunqiao.sinan.operationshub.manager.FileTransferManager
import com.yunqiao.sinan.operationshub.manager.FileTransferTask
import com.yunqiao.sinan.operationshub.manager.TransferCategory
import com.yunqiao.sinan.operationshub.model.FileTransferStatistics

data class TransferMediaCapability(
    val category: TransferCategory,
    val label: String,
    val description: String,
    val preferredExtensions: List<String>,
    val recommendedTransports: List<BridgeTransportHint>,
    val maxSizeMb: Int
)

class HybridFileTransferManager(context: Context) {

    private val appContext = context.applicationContext
    private val coordinator = BridgeConnectionCoordinator(appContext)
    private val nodeManager = FileTransferManager(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var latestLinkQuality = coordinator.linkQuality.value

    private val _activeTasks = MutableStateFlow<List<FileTransferTask>>(emptyList())
    val activeTasks: StateFlow<List<FileTransferTask>> = _activeTasks.asStateFlow()

    private val _completedTasks = MutableStateFlow<List<FileTransferTask>>(emptyList())
    val completedTasks: StateFlow<List<FileTransferTask>> = _completedTasks.asStateFlow()

    private val _failedTasks = MutableStateFlow<List<FileTransferTask>>(emptyList())
    val failedTasks: StateFlow<List<FileTransferTask>> = _failedTasks.asStateFlow()

    private val _mediaCapabilities = MutableStateFlow(buildMediaCapabilities(latestLinkQuality))
    val mediaCapabilities: StateFlow<List<TransferMediaCapability>> = _mediaCapabilities.asStateFlow()

    val statistics: StateFlow<FileTransferStatistics> = nodeManager.transferStatistics
    val transport: StateFlow<BridgeTransport> = coordinator.activeTransport
    val proximityDevices: StateFlow<List<BridgeDevice>> = coordinator.nearbyDevices
    val remoteAccounts: StateFlow<List<BridgeAccountEndpoint>> = coordinator.remoteAccounts
    val proximityState: StateFlow<Boolean> = coordinator.isInProximity
    val linkQuality: StateFlow<BridgeLinkQuality> = coordinator.linkQuality
    val compatibilityProfiles: StateFlow<Map<BridgeDevicePlatform, BridgeCompatibilityProfile>> =
        coordinator.compatibilityProfiles

    init {
        scope.launch {
            nodeManager.initialize()
            while (isActive) {
                _activeTasks.value = nodeManager.getActiveTasks()
                _completedTasks.value = nodeManager.getCompletedTasks()
                _failedTasks.value = nodeManager.getFailedTasks()
                delay(500)
            }
        }

        scope.launch {
            coordinator.linkQuality.collect { quality ->
                latestLinkQuality = quality
                nodeManager.updateNetworkProfile(quality.throughputMbps, quality.latencyMs)
                _mediaCapabilities.value = buildMediaCapabilities(quality)
            }
        }
    }

    suspend fun startProximityTransfer(
        targetDevice: BridgeDevice,
        sourceUri: Uri,
        categoryHint: TransferCategory? = null
    ): Result<String> {
        return startSmartTransfer(
            sourceUri = sourceUri,
            targetDeviceId = targetDevice.deviceId,
            remoteAccount = null,
            categoryHint = categoryHint
        )
    }

    suspend fun startRelayTransfer(
        accountId: String,
        sourceUri: Uri,
        categoryHint: TransferCategory? = null
    ): Result<String> {
        return startSmartTransfer(
            sourceUri = sourceUri,
            targetDeviceId = null,
            remoteAccount = accountId,
            categoryHint = categoryHint
        )
    }

    suspend fun startSmartTransfer(
        sourceUri: Uri,
        targetDeviceId: String?,
        remoteAccount: String?,
        categoryHint: TransferCategory? = null
    ): Result<String> {
        return try {
            val transport = coordinator.negotiateTransport(targetDeviceId, remoteAccount)
            val targetLabel = when (transport) {
                is BridgeTransport.DirectHotspot -> when (transport.medium) {
                    BridgeTransportHint.UltraWideband -> "ultra://${transport.groupOwnerAddress.hostAddress}:${transport.port}"
                    BridgeTransportHint.Bluetooth -> "bt://${transport.groupOwnerAddress.hostAddress}:${transport.port}"
                    BridgeTransportHint.Nfc -> "nfc://${transport.groupOwnerAddress.hostAddress}:${transport.port}"
                    else -> "direct://${transport.groupOwnerAddress.hostAddress}:${transport.port}"
                }
                is BridgeTransport.LocalLan -> "lan://${transport.ipAddress}:${transport.port}"
                is BridgeTransport.CloudRelay -> "relay://${transport.relayId}:${transport.negotiatedPort}"
                is BridgeTransport.Peripheral -> when (transport.medium) {
                    BridgeTransportHint.Bluetooth -> "bt://${transport.identifier}?channel=${transport.channel}"
                    BridgeTransportHint.Nfc -> "nfc://${transport.identifier}?channel=${transport.channel}"
                    BridgeTransportHint.AirPlay -> "airplay://${transport.identifier}:${transport.channel}"
                    else -> "peripheral://${transport.identifier}:${transport.channel}"
                }
            }
            val metadata = resolveFileMetadata(sourceUri)
            val category = categoryHint ?: inferCategory(metadata.displayName)
            nodeManager.startTransfer(
                sourceUri = sourceUri,
                fileName = metadata.displayName,
                targetDescriptor = targetLabel,
                category = category
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun cancelTransfer(taskId: String): Boolean {
        return nodeManager.cancelTransfer(taskId)
    }

    suspend fun ensureAccount(accountId: String): BridgeAccountEndpoint {
        return coordinator.forceAccountBridge(accountId)
    }

    fun release() {
        coordinator.release()
        nodeManager.cleanup()
        scope.cancel()
    }

    private fun buildMediaCapabilities(quality: BridgeLinkQuality): List<TransferMediaCapability> {
        val multiplier = when {
            quality.supportsLossless -> 2.2f
            quality.isDirect && quality.throughputMbps > 320f -> 1.8f
            quality.throughputMbps > 200f -> 1.5f
            quality.throughputMbps > 120f -> 1.2f
            else -> 1f
        }
        val imageMax = (96f * multiplier).roundToInt().coerceAtLeast(48)
        val videoMax = (960f * multiplier).roundToInt().coerceAtLeast(256)
        val audioMax = (220f * multiplier).roundToInt().coerceAtLeast(96)
        val docMax = (64f * multiplier).roundToInt().coerceAtLeast(32)
        val archiveMax = (512f * multiplier).roundToInt().coerceAtLeast(128)
        val appMax = (384f * multiplier).roundToInt().coerceAtLeast(96)
        return listOf(
            TransferMediaCapability(
                category = TransferCategory.IMAGE,
                label = "高清照片",
                description = "RAW/HEIC 原彩同步",
                preferredExtensions = listOf("JPG", "PNG", "HEIC", "RAW", "WEBP"),
                recommendedTransports = listOf(
                    BridgeTransportHint.UltraWideband,
                    BridgeTransportHint.AirPlay,
                    BridgeTransportHint.WifiDirect,
                    BridgeTransportHint.UniversalBridge
                ),
                maxSizeMb = imageMax
            ),
            TransferMediaCapability(
                category = TransferCategory.VIDEO,
                label = "专业视频",
                description = "最高 8K HDR 片段",
                preferredExtensions = listOf("MP4", "MOV", "MKV", "M4V", "WEBM"),
                recommendedTransports = listOf(
                    BridgeTransportHint.UltraWideband,
                    BridgeTransportHint.WifiDirect,
                    BridgeTransportHint.Lan,
                    BridgeTransportHint.UniversalBridge
                ),
                maxSizeMb = videoMax
            ),
            TransferMediaCapability(
                category = TransferCategory.AUDIO,
                label = "母带音频",
                description = "无损混音快速分发",
                preferredExtensions = listOf("FLAC", "WAV", "MP3", "AAC", "OGG"),
                recommendedTransports = listOf(
                    BridgeTransportHint.Bluetooth,
                    BridgeTransportHint.AirPlay,
                    BridgeTransportHint.WifiDirect,
                    BridgeTransportHint.UniversalBridge
                ),
                maxSizeMb = audioMax
            ),
            TransferMediaCapability(
                category = TransferCategory.DOCUMENT,
                label = "文档协作",
                description = "合同/方案安全直传",
                preferredExtensions = listOf("PDF", "DOCX", "PPTX", "XLSX"),
                recommendedTransports = listOf(
                    BridgeTransportHint.Lan,
                    BridgeTransportHint.Cloud,
                    BridgeTransportHint.WifiDirect,
                    BridgeTransportHint.UniversalBridge
                ),
                maxSizeMb = docMax
            ),
            TransferMediaCapability(
                category = TransferCategory.ARCHIVE,
                label = "压缩包",
                description = "项目资源批量同步",
                preferredExtensions = listOf("ZIP", "RAR", "7Z"),
                recommendedTransports = listOf(
                    BridgeTransportHint.Lan,
                    BridgeTransportHint.Cloud,
                    BridgeTransportHint.UltraWideband,
                    BridgeTransportHint.UniversalBridge
                ),
                maxSizeMb = archiveMax
            ),
            TransferMediaCapability(
                category = TransferCategory.APPLICATION,
                label = "安装包",
                description = "APK/AAB 免外网部署",
                preferredExtensions = listOf("APK", "AAB"),
                recommendedTransports = listOf(
                    BridgeTransportHint.Lan,
                    BridgeTransportHint.WifiDirect,
                    BridgeTransportHint.Cloud,
                    BridgeTransportHint.UniversalBridge
                ),
                maxSizeMb = appMax
            )
        )
    }

    private fun resolveFileMetadata(uri: Uri): FileMetadata {
        val resolver = appContext.contentResolver
        var displayName = "transfer-${System.currentTimeMillis()}"
        var size = 0L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (cursor.moveToFirst()) {
                    if (nameIndex >= 0) {
                        displayName = cursor.getString(nameIndex) ?: displayName
                    }
                    if (sizeIndex >= 0) {
                        size = cursor.getLong(sizeIndex)
                    }
                }
            }
        return FileMetadata(displayName = displayName, sizeBytes = size)
    }

    private fun inferCategory(displayName: String): TransferCategory {
        val lower = displayName.lowercase()
        return when {
            lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png") ||
                lower.endsWith(".gif") || lower.endsWith(".webp") || lower.endsWith(".heic") -> TransferCategory.IMAGE
            lower.endsWith(".mp4") || lower.endsWith(".mov") || lower.endsWith(".mkv") ||
                lower.endsWith(".avi") || lower.endsWith(".m4v") || lower.endsWith(".webm") -> TransferCategory.VIDEO
            lower.endsWith(".mp3") || lower.endsWith(".wav") || lower.endsWith(".flac") ||
                lower.endsWith(".aac") || lower.endsWith(".m4a") || lower.endsWith(".ogg") -> TransferCategory.AUDIO
            lower.endsWith(".zip") || lower.endsWith(".rar") || lower.endsWith(".7z") ||
                lower.endsWith(".tar") || lower.endsWith(".gz") -> TransferCategory.ARCHIVE
            lower.endsWith(".apk") || lower.endsWith(".aab") || lower.endsWith(".ipa") -> TransferCategory.APPLICATION
            lower.endsWith(".pdf") || lower.endsWith(".doc") || lower.endsWith(".docx") || lower.endsWith(".ppt") ||
                lower.endsWith(".pptx") || lower.endsWith(".xls") || lower.endsWith(".xlsx") -> TransferCategory.DOCUMENT
            else -> TransferCategory.OTHER
        }
    }
}

private data class FileMetadata(
    val displayName: String,
    val sizeBytes: Long
)
