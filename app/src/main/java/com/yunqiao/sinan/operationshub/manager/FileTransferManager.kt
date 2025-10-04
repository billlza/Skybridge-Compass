package com.yunqiao.sinan.operationshub.manager

import android.content.Context
import android.net.Uri
import android.os.SystemClock
import android.provider.OpenableColumns
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.min
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.yunqiao.sinan.operationshub.model.FileTransferStatistics

/**
 * 文件传输管理器
 * 使用真实的内容解析与Socket传输实现，替换所有模拟数据。
 */
class FileTransferManager(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _transferStatistics = MutableStateFlow(FileTransferStatistics())
    val transferStatistics: StateFlow<FileTransferStatistics> = _transferStatistics.asStateFlow()

    private val activeTasks = ConcurrentHashMap<String, FileTransferTask>()
    private val completedTasks = CopyOnWriteArrayList<FileTransferTask>()
    private val failedTasks = CopyOnWriteArrayList<FileTransferTask>()
    private val cancellationFlags = ConcurrentHashMap<String, Boolean>()

    private val totalDataTransferredBytes = AtomicLong(0L)

    @Volatile
    private var preferredChunkSizeBytes = DEFAULT_CHUNK_BYTES
    @Volatile
    private var preferredDelayMs = DEFAULT_CHUNK_DELAY_MS
    @Volatile
    private var isInitialized = false

    suspend fun initialize(): Boolean {
        return withContext(Dispatchers.IO) {
            if (isInitialized) {
                return@withContext true
            }
            startMonitoring()
            isInitialized = true
            true
        }
    }

    fun updateNetworkProfile(throughputMbps: Float, latencyMs: Int) {
        val chunk = when {
            throughputMbps > 480f -> 2L * 1024L * 1024L
            throughputMbps > 240f -> 1L * 1024L * 1024L
            throughputMbps > 120f -> 768L * 1024L
            throughputMbps > 60f -> 512L * 1024L
            else -> 256L * 1024L
        }
        val delayMs = when {
            latencyMs < 25 -> 12L
            latencyMs < 60 -> 24L
            latencyMs < 90 -> 36L
            else -> 48L
        }
        preferredChunkSizeBytes = chunk.coerceAtLeast(MIN_CHUNK_BYTES)
        preferredDelayMs = delayMs
    }

    suspend fun startTransfer(
        sourceUri: Uri,
        fileName: String,
        targetDescriptor: String,
        category: TransferCategory = inferCategory(fileName)
    ): Result<String> {
        return withContext(Dispatchers.IO) {
            try {
                val fileSize = resolveFileSize(sourceUri)
                if (fileSize <= 0L) {
                    throw IllegalStateException("无法获取文件大小")
                }
                val taskId = generateTaskId()
                val task = FileTransferTask(
                    taskId = taskId,
                    fileName = fileName,
                    sourceUri = sourceUri,
                    endpoint = Uri.parse(targetDescriptor),
                    targetDescriptor = targetDescriptor,
                    fileSize = fileSize,
                    category = category,
                    status = TransferStatus.QUEUED,
                    startTime = System.currentTimeMillis()
                )
                activeTasks[taskId] = task
                updateStatistics()
                scope.launch { processTransferTask(taskId) }
                Result.success(taskId)
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    suspend fun cancelTransfer(taskId: String): Boolean {
        return withContext(Dispatchers.IO) {
            val task = activeTasks[taskId] ?: return@withContext false
            cancellationFlags[taskId] = true
            activeTasks[taskId] = task.copy(status = TransferStatus.CANCELLED)
            updateStatistics()
            true
        }
    }

    fun getTransferTask(taskId: String): FileTransferTask? = activeTasks[taskId]

    fun getActiveTasks(): List<FileTransferTask> = activeTasks.values.toList()

    fun getCompletedTasks(): List<FileTransferTask> = completedTasks.toList()

    fun getFailedTasks(): List<FileTransferTask> = failedTasks.toList()

    fun cleanup() {
        isInitialized = false
        cancellationFlags.clear()
        activeTasks.clear()
        completedTasks.clear()
        failedTasks.clear()
        totalDataTransferredBytes.set(0L)
        _transferStatistics.value = FileTransferStatistics()
    }

    private suspend fun processTransferTask(taskId: String) {
        val initialTask = activeTasks[taskId] ?: return
        val updatedTask = initialTask.copy(status = TransferStatus.TRANSFERRING)
        activeTasks[taskId] = updatedTask
        updateStatistics()

        var socket: Socket? = null
        var input: BufferedInputStream? = null
        var output: BufferedOutputStream? = null

        try {
            val endpointUri = updatedTask.endpoint
            val host = endpointUri.host ?: throw IllegalStateException("无效的目标地址")
            val port = if (endpointUri.port != -1) endpointUri.port else DEFAULT_PORT
            socket = Socket()
            socket.connect(InetSocketAddress(host, port), SOCKET_CONNECT_TIMEOUT_MS)
            socket.tcpNoDelay = true

            output = BufferedOutputStream(socket.getOutputStream())
            val dataOutput = DataOutputStream(output)
            dataOutput.writeUTF(updatedTask.fileName)
            dataOutput.writeLong(updatedTask.fileSize)
            dataOutput.writeUTF(updatedTask.category.name)
            dataOutput.flush()

            val resolver = context.contentResolver
            input = BufferedInputStream(
                resolver.openInputStream(updatedTask.sourceUri)
                    ?: throw IllegalStateException("无法打开文件流")
            )

            val buffer = ByteArray(min(preferredChunkSizeBytes, MAX_CHUNK_BYTES).toInt())
            var transferredBytes = 0L
            var bytesSinceLastSample = 0L
            var lastSampleTimestamp = SystemClock.elapsedRealtime()

            while (scope.isActive) {
                if (cancellationFlags.remove(taskId) == true) {
                    throw CancellationException("任务被用户取消")
                }
                val read = input.read(buffer)
                if (read == -1) {
                    break
                }
                output.write(buffer, 0, read)
                output.flush()
                transferredBytes += read
                bytesSinceLastSample += read

                val progress = if (updatedTask.fileSize > 0) {
                    (transferredBytes.toFloat() / updatedTask.fileSize.toFloat()) * 100f
                } else {
                    100f
                }

                val now = SystemClock.elapsedRealtime()
                val elapsed = now - lastSampleTimestamp
                val speedMbps = if (elapsed > 0) {
                    (bytesSinceLastSample * 8f) / elapsed / 1000f
                } else {
                    0f
                }

                if (elapsed >= SPEED_SAMPLE_WINDOW_MS) {
                    val current = activeTasks[taskId]
                    if (current != null) {
                        activeTasks[taskId] = current.copy(
                            progress = progress,
                            transferredBytes = transferredBytes,
                            currentSpeed = speedMbps / 8f
                        )
                    }
                    updateStatistics()
                    lastSampleTimestamp = now
                    bytesSinceLastSample = 0L
                } else {
                    activeTasks[taskId] = activeTasks[taskId]?.copy(
                        progress = progress,
                        transferredBytes = transferredBytes
                    ) ?: updatedTask.copy(
                        progress = progress,
                        transferredBytes = transferredBytes
                    )
                }

                if (preferredDelayMs > 0) {
                    delay(preferredDelayMs)
                }
            }

            val completedTask = (activeTasks.remove(taskId) ?: updatedTask).copy(
                status = TransferStatus.COMPLETED,
                progress = 100f,
                transferredBytes = transferredBytes,
                currentSpeed = 0f,
                endTime = System.currentTimeMillis()
            )
            completedTasks += completedTask
            totalDataTransferredBytes.addAndGet(transferredBytes)
            updateStatistics()
        } catch (cancellation: CancellationException) {
            activeTasks.remove(taskId)
            val cancelledTask = updatedTask.copy(
                status = TransferStatus.CANCELLED,
                endTime = System.currentTimeMillis(),
                errorMessage = cancellation.message
            )
            failedTasks += cancelledTask
            updateStatistics()
        } catch (e: Exception) {
            val failedTask = (activeTasks.remove(taskId) ?: updatedTask).copy(
                status = TransferStatus.FAILED,
                endTime = System.currentTimeMillis(),
                errorMessage = e.message
            )
            failedTasks += failedTask
            updateStatistics()
        } finally {
            try {
                output?.flush()
            } catch (_: Exception) {
            }
            try {
                input?.close()
            } catch (_: Exception) {
            }
            try {
                socket?.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun resolveFileSize(uri: Uri): Long {
        val resolver = context.contentResolver
        resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (index >= 0 && cursor.moveToFirst()) {
                val size = cursor.getLong(index)
                if (size > 0) return size
            }
        }
        resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
            if (descriptor.statSize > 0) {
                return descriptor.statSize
            }
        }
        return 0L
    }

    private fun startMonitoring() {
        scope.launch {
            while (isActive) {
                updateStatistics()
                delay(1000)
            }
        }
    }

    private fun updateStatistics() {
        val currentActiveTasks = activeTasks.values.toList()
        val speeds = currentActiveTasks.map { it.currentSpeed }
        val currentSpeed = speeds.maxOrNull() ?: 0f
        val averageSpeed = if (speeds.isNotEmpty()) speeds.average().toFloat() else 0f

        val distribution = mutableMapOf<TransferCategory, Int>()
        (currentActiveTasks + completedTasks + failedTasks).forEach { task ->
            distribution[task.category] = (distribution[task.category] ?: 0) + 1
        }

        val queued = currentActiveTasks.count { it.status == TransferStatus.QUEUED }
        val completed = completedTasks.size
        val failed = failedTasks.size
        val active = currentActiveTasks.size

        _transferStatistics.value = FileTransferStatistics(
            activeTasks = active,
            completedTasks = completed,
            failedTasks = failed,
            currentSpeed = currentSpeed,
            averageSpeed = averageSpeed,
            totalDataTransferred = totalDataTransferredBytes.get() / (1024 * 1024),
            queuedTasks = queued,
            categoryDistribution = distribution.toMap()
        )
    }

    private fun inferCategory(fileName: String): TransferCategory {
        val lower = fileName.lowercase()
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

    private fun generateTaskId(): String {
        return "task_${System.currentTimeMillis()}_${(1000..9999).random()}"
    }

    companion object {
        private const val DEFAULT_CHUNK_BYTES = 512L * 1024L
        private const val MIN_CHUNK_BYTES = 128L * 1024L
        private const val MAX_CHUNK_BYTES = 4L * 1024L * 1024L
        private const val DEFAULT_CHUNK_DELAY_MS = 24L
        private const val SOCKET_CONNECT_TIMEOUT_MS = 8000
        private const val DEFAULT_PORT = 9000
        private const val SPEED_SAMPLE_WINDOW_MS = 400L
    }
}

/**
 * 文件传输任务数据类
 */
data class FileTransferTask(
    val taskId: String,
    val fileName: String,
    val sourceUri: Uri,
    val endpoint: Uri,
    val targetDescriptor: String,
    val fileSize: Long,
    val category: TransferCategory = TransferCategory.DOCUMENT,
    val status: TransferStatus,
    val progress: Float = 0f,
    val transferredBytes: Long = 0L,
    val currentSpeed: Float = 0f,
    val startTime: Long = 0L,
    val endTime: Long? = null,
    val errorMessage: String? = null
)

enum class TransferCategory {
    DOCUMENT,
    IMAGE,
    VIDEO,
    AUDIO,
    ARCHIVE,
    APPLICATION,
    OTHER
}

enum class TransferStatus {
    QUEUED,
    TRANSFERRING,
    COMPLETED,
    FAILED,
    CANCELLED
}
