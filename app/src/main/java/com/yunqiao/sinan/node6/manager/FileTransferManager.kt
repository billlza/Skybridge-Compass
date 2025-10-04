package com.yunqiao.sinan.node6.manager

import android.content.Context
import com.yunqiao.sinan.node6.model.FileTransferStatistics
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import kotlin.random.Random

/**
 * 文件传输管理器
 */
class FileTransferManager(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    private val _transferStatistics = MutableStateFlow(FileTransferStatistics())
    val transferStatistics: StateFlow<FileTransferStatistics> = _transferStatistics.asStateFlow()
    
    private val activeTasks = ConcurrentHashMap<String, FileTransferTask>()
    private val completedTasks = mutableListOf<FileTransferTask>()
    private val failedTasks = mutableListOf<FileTransferTask>()
    
    private var totalDataTransferred = 0L
    private var isInitialized = false
    
    /**
     * 初始化文件传输服务
     */
    suspend fun initialize(): Boolean {
        return try {
            if (isInitialized) return true
            
            // 模拟初始化过程
            delay(500)
            
            // 模拟一些历史数据
            initializeMockData()
            
            // 开始监控传输任务
            startMonitoring()
            
            isInitialized = true
            true
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * 开始文件传输
     */
    suspend fun startTransfer(
        fileName: String,
        filePath: String,
        targetDevice: String,
        fileSize: Long = Random.nextLong(1024 * 1024, 1024 * 1024 * 100) // 1MB-100MB
    ): Result<String> {
        return try {
            val taskId = generateTaskId()
            val task = FileTransferTask(
                taskId = taskId,
                fileName = fileName,
                filePath = filePath,
                targetDevice = targetDevice,
                fileSize = fileSize,
                status = TransferStatus.QUEUED,
                startTime = System.currentTimeMillis()
            )
            
            activeTasks[taskId] = task
            updateStatistics()
            
            // 开始传输任务
            scope.launch {
                processTransferTask(taskId)
            }
            
            Result.success(taskId)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    /**
     * 取消文件传输
     */
    suspend fun cancelTransfer(taskId: String): Boolean {
        return try {
            activeTasks[taskId]?.let { task ->
                activeTasks[taskId] = task.copy(status = TransferStatus.CANCELLED)
                activeTasks.remove(taskId)
                updateStatistics()
                true
            } ?: false
        } catch (e: Exception) {
            false
        }
    }
    
    /**
     * 获取传输任务信息
     */
    fun getTransferTask(taskId: String): FileTransferTask? {
        return activeTasks[taskId]
    }
    
    /**
     * 获取所有活跃任务
     */
    fun getActiveTasks(): List<FileTransferTask> {
        return activeTasks.values.toList()
    }
    
    /**
     * 获取已完成任务
     */
    fun getCompletedTasks(): List<FileTransferTask> {
        return completedTasks.toList()
    }
    
    /**
     * 获取失败任务
     */
    fun getFailedTasks(): List<FileTransferTask> {
        return failedTasks.toList()
    }
    
    /**
     * 处理传输任务
     */
    private suspend fun processTransferTask(taskId: String) {
        val task = activeTasks[taskId] ?: return
        
        try {
            // 更新为传输中
            activeTasks[taskId] = task.copy(status = TransferStatus.TRANSFERRING)
            updateStatistics()
            
            // 模拟传输过程
            val totalChunks = 100
            var transferredBytes = 0L
            
            for (i in 1..totalChunks) {
                // 检查是否被取消
                val currentTask = activeTasks[taskId]
                if (currentTask?.status == TransferStatus.CANCELLED) {
                    return
                }
                
                // 模拟传输进度
                transferredBytes += task.fileSize / totalChunks
                val progress = (i.toFloat() / totalChunks) * 100
                
                activeTasks[taskId] = task.copy(
                    progress = progress,
                    transferredBytes = transferredBytes,
                    currentSpeed = Random.nextFloat() * 10f + 5f // 5-15 MB/s
                )
                updateStatistics()
                
                delay(50) // 模拟传输时间
            }
            
            // 传输完成
            val completedTask = task.copy(
                status = TransferStatus.COMPLETED,
                progress = 100f,
                transferredBytes = task.fileSize,
                endTime = System.currentTimeMillis()
            )
            
            activeTasks.remove(taskId)
            completedTasks.add(completedTask)
            totalDataTransferred += task.fileSize
            updateStatistics()
            
        } catch (e: Exception) {
            // 传输失败
            val failedTask = task.copy(
                status = TransferStatus.FAILED,
                errorMessage = e.message,
                endTime = System.currentTimeMillis()
            )
            
            activeTasks.remove(taskId)
            failedTasks.add(failedTask)
            updateStatistics()
        }
    }
    
    /**
     * 开始监控
     */
    private fun startMonitoring() {
        scope.launch {
            while (isInitialized) {
                updateStatistics()
                delay(1000)
            }
        }
    }
    
    /**
     * 更新统计信息
     */
    private fun updateStatistics() {
        val currentActiveTasks = activeTasks.values.filter { it.status == TransferStatus.TRANSFERRING }
        val averageSpeed = if (currentActiveTasks.isNotEmpty()) {
            currentActiveTasks.map { it.currentSpeed }.average().toFloat()
        } else {
            0f
        }
        
        val currentSpeed = if (currentActiveTasks.isNotEmpty()) {
            currentActiveTasks.maxOf { it.currentSpeed }
        } else {
            0f
        }
        
        _transferStatistics.value = FileTransferStatistics(
            activeTasks = activeTasks.size,
            completedTasks = completedTasks.size,
            failedTasks = failedTasks.size,
            currentSpeed = currentSpeed,
            averageSpeed = averageSpeed,
            totalDataTransferred = totalDataTransferred / (1024 * 1024), // 转换为MB
            queuedTasks = activeTasks.values.count { it.status == TransferStatus.QUEUED }
        )
    }
    
    /**
     * 初始化模拟数据
     */
    private fun initializeMockData() {
        // 模拟一些已完成的任务
        repeat(5) {
            completedTasks.add(
                FileTransferTask(
                    taskId = "completed_$it",
                    fileName = "file_$it.pdf",
                    filePath = "/documents/file_$it.pdf",
                    targetDevice = "Device_${('A'..'E').random()}",
                    fileSize = Random.nextLong(1024 * 1024, 1024 * 1024 * 50),
                    status = TransferStatus.COMPLETED,
                    progress = 100f,
                    startTime = System.currentTimeMillis() - Random.nextLong(3600000),
                    endTime = System.currentTimeMillis() - Random.nextLong(1800000)
                )
            )
        }
        
        // 模拟一些失败的任务
        repeat(2) {
            failedTasks.add(
                FileTransferTask(
                    taskId = "failed_$it",
                    fileName = "failed_file_$it.zip",
                    filePath = "/downloads/failed_file_$it.zip",
                    targetDevice = "Device_${('F'..'H').random()}",
                    fileSize = Random.nextLong(1024 * 1024, 1024 * 1024 * 30),
                    status = TransferStatus.FAILED,
                    errorMessage = "Network connection lost",
                    startTime = System.currentTimeMillis() - Random.nextLong(3600000),
                    endTime = System.currentTimeMillis() - Random.nextLong(1800000)
                )
            )
        }
        
        totalDataTransferred = completedTasks.sumOf { it.fileSize }
    }
    
    /**
     * 生成任务 ID
     */
    private fun generateTaskId(): String {
        return "task_${System.currentTimeMillis()}_${(1000..9999).random()}"
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        isInitialized = false
        activeTasks.clear()
        completedTasks.clear()
        failedTasks.clear()
        totalDataTransferred = 0L
    }
}

/**
 * 文件传输任务数据类
 */
data class FileTransferTask(
    val taskId: String,
    val fileName: String,
    val filePath: String,
    val targetDevice: String,
    val fileSize: Long,
    val status: TransferStatus,
    val progress: Float = 0f,
    val transferredBytes: Long = 0L,
    val currentSpeed: Float = 0f,
    val startTime: Long = 0L,
    val endTime: Long? = null,
    val errorMessage: String? = null
)

/**
 * 传输状态枚举
 */
enum class TransferStatus {
    QUEUED,
    TRANSFERRING,
    COMPLETED,
    FAILED,
    CANCELLED
}
