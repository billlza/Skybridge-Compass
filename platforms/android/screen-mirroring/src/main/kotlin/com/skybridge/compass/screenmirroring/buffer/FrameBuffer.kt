package com.skybridge.compass.screenmirroring.buffer

import com.skybridge.compass.core.utils.Logger
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * 帧缓冲配置
 */
data class FrameBufferConfig(
    val maxBufferSize: Int = 30,           // 最大缓冲帧数
    val maxRetryCount: Int = 3,            // 最大重试次数
    val retryDelayMs: Long = 100,          // 重试延迟（毫秒）
    val dropOldFramesOnOverflow: Boolean = true, // 溢出时丢弃旧帧
    val prioritizeKeyFrames: Boolean = true // 优先保留关键帧
)

/**
 * 缓冲帧数据
 */
data class BufferedFrame(
    val frameId: Long,
    val data: ByteArray,
    val isKeyFrame: Boolean,
    val timestamp: Long,
    val retryCount: Int = 0,
    val priority: Int = 0 // 0=普通, 1=高优先级（关键帧）
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as BufferedFrame
        return frameId == other.frameId
    }
    
    override fun hashCode(): Int = frameId.hashCode()
}

/**
 * 缓冲状态
 */
data class BufferStatus(
    val bufferedFrames: Int,
    val droppedFrames: Long,
    val retriedFrames: Long,
    val failedFrames: Long,
    val bufferUtilization: Float // 0.0 - 1.0
)

/**
 * 帧缓冲器
 * 用于在网络拥塞时缓冲帧，并支持重试机制
 */
class FrameBuffer(
    private val config: FrameBufferConfig = FrameBufferConfig()
) {
    companion object {
        private const val TAG = "FrameBuffer"
    }
    
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // 帧缓冲队列
    private val frameQueue = ConcurrentLinkedQueue<BufferedFrame>()
    
    // 待重试队列
    private val retryQueue = Channel<BufferedFrame>(Channel.UNLIMITED)
    
    // 统计信息
    private val droppedFrameCount = AtomicLong(0)
    private val retriedFrameCount = AtomicLong(0)
    private val failedFrameCount = AtomicLong(0)
    private val frameIdCounter = AtomicLong(0)
    
    // 状态流
    private val _bufferStatus = MutableStateFlow(BufferStatus(0, 0, 0, 0, 0f))
    val bufferStatus: StateFlow<BufferStatus> = _bufferStatus.asStateFlow()
    
    // 发送回调
    private var sendCallback: (suspend (BufferedFrame) -> Boolean)? = null
    
    // 是否正在运行
    private var isRunning = false
    private var processingJob: Job? = null
    
    /**
     * 启动缓冲器
     * @param onSend 发送帧的回调函数，返回 true 表示发送成功
     */
    fun start(onSend: suspend (BufferedFrame) -> Boolean) {
        if (isRunning) return
        
        Logger.screenMirroring("启动帧缓冲器")
        sendCallback = onSend
        isRunning = true
        
        // 启动处理协程
        processingJob = scope.launch {
            processFrames()
        }
        
        // 启动重试处理协程
        scope.launch {
            processRetryQueue()
        }
    }
    
    /**
     * 停止缓冲器
     */
    fun stop() {
        Logger.screenMirroring("停止帧缓冲器")
        isRunning = false
        processingJob?.cancel()
        frameQueue.clear()
        retryQueue.close()
    }
    
    /**
     * 添加帧到缓冲区
     */
    fun enqueue(data: ByteArray, isKeyFrame: Boolean): Long {
        val frameId = frameIdCounter.incrementAndGet()
        
        val frame = BufferedFrame(
            frameId = frameId,
            data = data,
            isKeyFrame = isKeyFrame,
            timestamp = System.currentTimeMillis(),
            priority = if (isKeyFrame) 1 else 0
        )
        
        // 检查缓冲区是否已满
        if (frameQueue.size >= config.maxBufferSize) {
            handleBufferOverflow()
        }
        
        frameQueue.offer(frame)
        updateStatus()
        
        return frameId
    }
    
    /**
     * 处理缓冲区溢出
     */
    private fun handleBufferOverflow() {
        if (!config.dropOldFramesOnOverflow) {
            // 不丢弃，等待空间
            return
        }
        
        if (config.prioritizeKeyFrames) {
            // 优先丢弃非关键帧
            val iterator = frameQueue.iterator()
            while (iterator.hasNext() && frameQueue.size >= config.maxBufferSize) {
                val frame = iterator.next()
                if (!frame.isKeyFrame) {
                    iterator.remove()
                    droppedFrameCount.incrementAndGet()
                    Logger.screenMirroring("丢弃非关键帧: ${frame.frameId}")
                }
            }
        }
        
        // 如果还是满的，丢弃最旧的帧
        while (frameQueue.size >= config.maxBufferSize) {
            val dropped = frameQueue.poll()
            if (dropped != null) {
                droppedFrameCount.incrementAndGet()
                Logger.screenMirroring("丢弃旧帧: ${dropped.frameId}")
            }
        }
        
        updateStatus()
    }
    
    /**
     * 处理帧队列
     */
    private suspend fun processFrames() {
        while (isRunning) {
            val frame = frameQueue.poll()
            
            if (frame != null) {
                val success = trySendFrame(frame)
                
                if (!success && frame.retryCount < config.maxRetryCount) {
                    // 发送失败，加入重试队列
                    val retryFrame = frame.copy(retryCount = frame.retryCount + 1)
                    retryQueue.send(retryFrame)
                    retriedFrameCount.incrementAndGet()
                } else if (!success) {
                    // 超过重试次数，标记为失败
                    failedFrameCount.incrementAndGet()
                    Logger.screenMirroring("帧发送失败（超过重试次数）: ${frame.frameId}")
                }
                
                updateStatus()
            } else {
                // 队列为空，短暂等待
                delay(5)
            }
        }
    }
    
    /**
     * 处理重试队列
     */
    private suspend fun processRetryQueue() {
        for (frame in retryQueue) {
            if (!isRunning) break
            
            // 等待重试延迟
            delay(config.retryDelayMs * frame.retryCount)
            
            val success = trySendFrame(frame)
            
            if (!success && frame.retryCount < config.maxRetryCount) {
                // 继续重试
                val retryFrame = frame.copy(retryCount = frame.retryCount + 1)
                retryQueue.send(retryFrame)
            } else if (!success) {
                failedFrameCount.incrementAndGet()
                Logger.screenMirroring("帧重试失败: ${frame.frameId}")
            }
            
            updateStatus()
        }
    }
    
    /**
     * 尝试发送帧
     */
    private suspend fun trySendFrame(frame: BufferedFrame): Boolean {
        return try {
            sendCallback?.invoke(frame) ?: false
        } catch (e: Exception) {
            Logger.screenMirroring("发送帧异常: ${e.message}")
            false
        }
    }
    
    /**
     * 更新状态
     */
    private fun updateStatus() {
        _bufferStatus.value = BufferStatus(
            bufferedFrames = frameQueue.size,
            droppedFrames = droppedFrameCount.get(),
            retriedFrames = retriedFrameCount.get(),
            failedFrames = failedFrameCount.get(),
            bufferUtilization = frameQueue.size.toFloat() / config.maxBufferSize
        )
    }
    
    /**
     * 清空缓冲区
     */
    fun clear() {
        val clearedCount = frameQueue.size
        frameQueue.clear()
        droppedFrameCount.addAndGet(clearedCount.toLong())
        updateStatus()
        Logger.screenMirroring("清空缓冲区，丢弃 $clearedCount 帧")
    }
    
    /**
     * 获取当前缓冲帧数
     */
    fun getBufferedCount(): Int = frameQueue.size
    
    /**
     * 检查缓冲区是否为空
     */
    fun isEmpty(): Boolean = frameQueue.isEmpty()
    
    /**
     * 检查缓冲区是否已满
     */
    fun isFull(): Boolean = frameQueue.size >= config.maxBufferSize
}

/**
 * 自适应帧缓冲器
 * 根据网络状况动态调整缓冲策略
 */
class AdaptiveFrameBuffer(
    initialConfig: FrameBufferConfig = FrameBufferConfig()
) {
    private var currentConfig = initialConfig
    private val frameBuffer = FrameBuffer(currentConfig)
    
    // 网络质量指标
    private var recentSuccessRate = 1.0f
    private var recentLatency = 0L
    
    /**
     * 根据网络状况调整配置
     */
    fun adaptToNetworkConditions(successRate: Float, latencyMs: Long) {
        recentSuccessRate = successRate
        recentLatency = latencyMs
        
        // 根据成功率调整重试次数
        val newRetryCount = when {
            successRate < 0.5f -> 5  // 网络很差，增加重试
            successRate < 0.8f -> 3  // 网络一般
            else -> 2               // 网络良好
        }
        
        // 根据延迟调整缓冲区大小
        val newBufferSize = when {
            latencyMs > 500 -> 60   // 高延迟，增大缓冲
            latencyMs > 200 -> 45
            latencyMs > 100 -> 30
            else -> 15              // 低延迟，减小缓冲
        }
        
        // 根据延迟调整重试延迟
        val newRetryDelay = when {
            latencyMs > 500 -> 200L
            latencyMs > 200 -> 150L
            else -> 100L
        }
        
        currentConfig = currentConfig.copy(
            maxRetryCount = newRetryCount,
            maxBufferSize = newBufferSize,
            retryDelayMs = newRetryDelay
        )
        
        Logger.screenMirroring("自适应调整: bufferSize=$newBufferSize, retryCount=$newRetryCount, retryDelay=$newRetryDelay")
    }
    
    fun getFrameBuffer(): FrameBuffer = frameBuffer
    fun getCurrentConfig(): FrameBufferConfig = currentConfig
}
