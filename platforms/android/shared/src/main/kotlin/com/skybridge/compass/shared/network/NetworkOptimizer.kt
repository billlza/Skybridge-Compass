package com.skybridge.compass.shared.network

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Network optimizer for improving transfer performance and error handling
 */
@Singleton
class NetworkOptimizer @Inject constructor() {

    private val connectionMetrics = ConcurrentHashMap<String, ConnectionMetrics>()
    private val adaptiveSettings = ConcurrentHashMap<String, AdaptiveNetworkSettings>()
    private val retryStrategies = ConcurrentHashMap<String, RetryStrategy>()

    /**
     * Optimize network settings based on connection quality
     */
    suspend fun optimizeConnection(
        connectionId: String,
        currentLatency: Long,
        bandwidth: Long,
        packetLoss: Float
    ): NetworkOptimizationResult {
        val metrics = updateConnectionMetrics(connectionId, currentLatency, bandwidth, packetLoss)
        val settings = calculateOptimalSettings(metrics)
        
        adaptiveSettings[connectionId] = settings
        
        return NetworkOptimizationResult(
            recommendedChunkSize = settings.chunkSize,
            recommendedConcurrency = settings.concurrentConnections,
            recommendedTimeout = settings.timeout,
            enableCompression = settings.enableCompression,
            enableEncryption = settings.enableEncryption,
            bufferSize = settings.bufferSize,
            keepAliveInterval = settings.keepAliveInterval
        )
    }

    /**
     * Get adaptive retry strategy based on error patterns
     */
    fun getRetryStrategy(connectionId: String, errorType: NetworkErrorType): RetryStrategy {
        return retryStrategies.getOrPut(connectionId) {
            createAdaptiveRetryStrategy(errorType)
        }.also { strategy ->
            // Update strategy based on recent error patterns
            strategy.updateForError(errorType)
        }
    }

    /**
     * Monitor connection quality continuously
     */
    fun monitorConnectionQuality(connectionId: String): Flow<ConnectionQuality> = flow {
        while (currentCoroutineContext().isActive) {
            val metrics = connectionMetrics[connectionId]
            if (metrics != null) {
                val quality = calculateConnectionQuality(metrics)
                emit(quality)
            }
            delay(1000) // Monitor every second
        }
    }.flowOn(Dispatchers.IO)

    /**
     * Optimize transfer based on file characteristics
     */
    fun optimizeForFileType(
        fileSize: Long,
        mimeType: String,
        connectionQuality: ConnectionQuality
    ): FileTransferOptimization {
        val isCompressible = isFileCompressible(mimeType)
        val optimalChunkSize = calculateOptimalChunkSize(fileSize, connectionQuality)
        val concurrency = calculateOptimalConcurrency(fileSize, connectionQuality)
        
        return FileTransferOptimization(
            chunkSize = optimalChunkSize,
            concurrentTransfers = concurrency,
            enableCompression = isCompressible && connectionQuality != ConnectionQuality.POOR,
            enableEncryption = true, // Always encrypt for security
            priorityLevel = calculatePriority(fileSize, mimeType),
            estimatedDuration = estimateTransferDuration(fileSize, connectionQuality)
        )
    }

    /**
     * Handle network errors with adaptive strategies
     */
    suspend fun handleNetworkError(
        connectionId: String,
        error: NetworkError,
        attempt: Int
    ): ErrorHandlingResult {
        val strategy = getRetryStrategy(connectionId, error.type)
        
        return when {
            attempt >= strategy.maxRetries -> {
                ErrorHandlingResult.GiveUp(
                    reason = "Max retries exceeded",
                    suggestion = "Check network connection and try again"
                )
            }
            
            error.type == NetworkErrorType.TIMEOUT -> {
                val newTimeout = strategy.calculateBackoffDelay(attempt)
                ErrorHandlingResult.Retry(
                    delayMs = newTimeout,
                    adjustedSettings = adaptiveSettings[connectionId]?.copy(
                        timeout = newTimeout * 2
                    )
                )
            }
            
            error.type == NetworkErrorType.CONNECTION_LOST -> {
                ErrorHandlingResult.Reconnect(
                    delayMs = strategy.calculateBackoffDelay(attempt),
                    useAlternativeEndpoint = attempt > 2
                )
            }
            
            error.type == NetworkErrorType.BANDWIDTH_LIMITED -> {
                val currentSettings = adaptiveSettings[connectionId]
                ErrorHandlingResult.Retry(
                    delayMs = 1000,
                    adjustedSettings = currentSettings?.copy(
                        chunkSize = currentSettings.chunkSize / 2,
                        concurrentConnections = maxOf(1, currentSettings.concurrentConnections / 2)
                    )
                )
            }
            
            else -> {
                ErrorHandlingResult.Retry(
                    delayMs = strategy.calculateBackoffDelay(attempt)
                )
            }
        }
    }

    /**
     * Optimize bandwidth usage based on network conditions
     */
    fun optimizeBandwidthUsage(
        connectionId: String,
        availableBandwidth: Long,
        activeTransfers: Int
    ): BandwidthOptimization {
        val metrics = connectionMetrics[connectionId]
        val baseAllocation = availableBandwidth / maxOf(1, activeTransfers)
        
        // Reserve bandwidth for other system operations
        val reservedBandwidth = (availableBandwidth * 0.1).toLong()
        val usableBandwidth = availableBandwidth - reservedBandwidth
        
        return BandwidthOptimization(
            maxBandwidthPerTransfer = baseAllocation,
            totalBandwidthLimit = usableBandwidth,
            adaptiveThrottling = metrics?.packetLoss ?: 0f > 0.05f,
            priorityWeights = calculatePriorityWeights(activeTransfers)
        )
    }

    private fun updateConnectionMetrics(
        connectionId: String,
        latency: Long,
        bandwidth: Long,
        packetLoss: Float
    ): ConnectionMetrics {
        return connectionMetrics.compute(connectionId) { _, existing ->
            val current = existing ?: ConnectionMetrics(connectionId)
            current.copy(
                averageLatency = (current.averageLatency * 0.8 + latency * 0.2).toLong(),
                peakBandwidth = maxOf(current.peakBandwidth, bandwidth),
                averageBandwidth = (current.averageBandwidth * 0.8 + bandwidth * 0.2).toLong(),
                packetLoss = (current.packetLoss * 0.8f + packetLoss * 0.2f),
                lastUpdated = System.currentTimeMillis(),
                sampleCount = current.sampleCount + 1
            )
        }!!
    }

    private fun calculateOptimalSettings(metrics: ConnectionMetrics): AdaptiveNetworkSettings {
        val quality = calculateConnectionQuality(metrics)
        
        return when (quality) {
            ConnectionQuality.EXCELLENT -> AdaptiveNetworkSettings(
                chunkSize = 64 * 1024, // 64KB
                concurrentConnections = 8,
                timeout = 5000L,
                enableCompression = true,
                enableEncryption = true,
                bufferSize = 128 * 1024,
                keepAliveInterval = 30000L
            )
            
            ConnectionQuality.GOOD -> AdaptiveNetworkSettings(
                chunkSize = 32 * 1024, // 32KB
                concurrentConnections = 4,
                timeout = 10000L,
                enableCompression = true,
                enableEncryption = true,
                bufferSize = 64 * 1024,
                keepAliveInterval = 45000L
            )
            
            ConnectionQuality.FAIR -> AdaptiveNetworkSettings(
                chunkSize = 16 * 1024, // 16KB
                concurrentConnections = 2,
                timeout = 15000L,
                enableCompression = false, // Reduce CPU overhead
                enableEncryption = true,
                bufferSize = 32 * 1024,
                keepAliveInterval = 60000L
            )
            
            ConnectionQuality.POOR -> AdaptiveNetworkSettings(
                chunkSize = 8 * 1024, // 8KB
                concurrentConnections = 1,
                timeout = 30000L,
                enableCompression = false,
                enableEncryption = true,
                bufferSize = 16 * 1024,
                keepAliveInterval = 90000L
            )
        }
    }

    private fun calculateConnectionQuality(metrics: ConnectionMetrics): ConnectionQuality {
        val latencyScore = when {
            metrics.averageLatency < 50 -> 4
            metrics.averageLatency < 100 -> 3
            metrics.averageLatency < 200 -> 2
            else -> 1
        }
        
        val bandwidthScore = when {
            metrics.averageBandwidth > 10 * 1024 * 1024 -> 4 // > 10MB/s
            metrics.averageBandwidth > 5 * 1024 * 1024 -> 3  // > 5MB/s
            metrics.averageBandwidth > 1 * 1024 * 1024 -> 2  // > 1MB/s
            else -> 1
        }
        
        val packetLossScore = when {
            metrics.packetLoss < 0.01f -> 4 // < 1%
            metrics.packetLoss < 0.05f -> 3 // < 5%
            metrics.packetLoss < 0.1f -> 2  // < 10%
            else -> 1
        }
        
        val totalScore = (latencyScore + bandwidthScore + packetLossScore) / 3.0
        
        return when {
            totalScore >= 3.5 -> ConnectionQuality.EXCELLENT
            totalScore >= 2.5 -> ConnectionQuality.GOOD
            totalScore >= 1.5 -> ConnectionQuality.FAIR
            else -> ConnectionQuality.POOR
        }
    }

    private fun createAdaptiveRetryStrategy(errorType: NetworkErrorType): RetryStrategy {
        return when (errorType) {
            NetworkErrorType.TIMEOUT -> RetryStrategy(
                maxRetries = 5,
                baseDelayMs = 1000L,
                maxDelayMs = 30000L,
                backoffMultiplier = 2.0,
                jitterFactor = 0.1
            )
            
            NetworkErrorType.CONNECTION_LOST -> RetryStrategy(
                maxRetries = 10,
                baseDelayMs = 2000L,
                maxDelayMs = 60000L,
                backoffMultiplier = 1.5,
                jitterFactor = 0.2
            )
            
            NetworkErrorType.BANDWIDTH_LIMITED -> RetryStrategy(
                maxRetries = 3,
                baseDelayMs = 5000L,
                maxDelayMs = 30000L,
                backoffMultiplier = 1.0, // Linear backoff
                jitterFactor = 0.0
            )
            
            else -> RetryStrategy(
                maxRetries = 3,
                baseDelayMs = 1000L,
                maxDelayMs = 10000L,
                backoffMultiplier = 2.0,
                jitterFactor = 0.1
            )
        }
    }

    private fun isFileCompressible(mimeType: String): Boolean {
        return when {
            mimeType.startsWith("text/") -> true
            mimeType.startsWith("application/json") -> true
            mimeType.startsWith("application/xml") -> true
            mimeType.startsWith("application/javascript") -> true
            mimeType.contains("zip") -> false
            mimeType.contains("compressed") -> false
            mimeType.startsWith("image/") -> false
            mimeType.startsWith("video/") -> false
            mimeType.startsWith("audio/") -> false
            else -> true
        }
    }

    private fun calculateOptimalChunkSize(fileSize: Long, quality: ConnectionQuality): Int {
        val baseSize = when (quality) {
            ConnectionQuality.EXCELLENT -> 64 * 1024
            ConnectionQuality.GOOD -> 32 * 1024
            ConnectionQuality.FAIR -> 16 * 1024
            ConnectionQuality.POOR -> 8 * 1024
        }
        
        // Adjust based on file size
        return when {
            fileSize < 1024 * 1024 -> baseSize / 4 // Small files
            fileSize > 100 * 1024 * 1024 -> baseSize * 2 // Large files
            else -> baseSize
        }
    }

    private fun calculateOptimalConcurrency(fileSize: Long, quality: ConnectionQuality): Int {
        val baseConcurrency = when (quality) {
            ConnectionQuality.EXCELLENT -> 8
            ConnectionQuality.GOOD -> 4
            ConnectionQuality.FAIR -> 2
            ConnectionQuality.POOR -> 1
        }
        
        // Reduce concurrency for small files
        return if (fileSize < 10 * 1024 * 1024) {
            maxOf(1, baseConcurrency / 2)
        } else {
            baseConcurrency
        }
    }

    private fun calculatePriority(fileSize: Long, mimeType: String): TransferPriority {
        return when {
            mimeType.startsWith("image/") && fileSize < 1024 * 1024 -> TransferPriority.HIGH
            mimeType.startsWith("text/") -> TransferPriority.HIGH
            fileSize < 10 * 1024 * 1024 -> TransferPriority.NORMAL
            else -> TransferPriority.LOW
        }
    }

    private fun estimateTransferDuration(fileSize: Long, quality: ConnectionQuality): Long {
        val estimatedSpeed = when (quality) {
            ConnectionQuality.EXCELLENT -> 10 * 1024 * 1024L // 10MB/s
            ConnectionQuality.GOOD -> 5 * 1024 * 1024L       // 5MB/s
            ConnectionQuality.FAIR -> 1 * 1024 * 1024L       // 1MB/s
            ConnectionQuality.POOR -> 256 * 1024L            // 256KB/s
        }
        
        return (fileSize / estimatedSpeed) * 1000 // Convert to milliseconds
    }

    private fun calculatePriorityWeights(activeTransfers: Int): Map<TransferPriority, Float> {
        return when (activeTransfers) {
            1 -> mapOf(
                TransferPriority.HIGH to 1.0f,
                TransferPriority.NORMAL to 1.0f,
                TransferPriority.LOW to 1.0f
            )
            
            in 2..4 -> mapOf(
                TransferPriority.HIGH to 0.6f,
                TransferPriority.NORMAL to 0.3f,
                TransferPriority.LOW to 0.1f
            )
            
            else -> mapOf(
                TransferPriority.HIGH to 0.7f,
                TransferPriority.NORMAL to 0.2f,
                TransferPriority.LOW to 0.1f
            )
        }
    }
}

// Data classes for network optimization
data class ConnectionMetrics(
    val connectionId: String,
    val averageLatency: Long = 0L,
    val peakBandwidth: Long = 0L,
    val averageBandwidth: Long = 0L,
    val packetLoss: Float = 0f,
    val lastUpdated: Long = System.currentTimeMillis(),
    val sampleCount: Int = 0
)

data class AdaptiveNetworkSettings(
    val chunkSize: Int,
    val concurrentConnections: Int,
    val timeout: Long,
    val enableCompression: Boolean,
    val enableEncryption: Boolean,
    val bufferSize: Int,
    val keepAliveInterval: Long
)

data class RetryStrategy(
    val maxRetries: Int,
    val baseDelayMs: Long,
    val maxDelayMs: Long,
    val backoffMultiplier: Double,
    val jitterFactor: Double,
    private val errorHistory: MutableList<NetworkErrorType> = mutableListOf()
) {
    fun calculateBackoffDelay(attempt: Int): Long {
        val delay = (baseDelayMs * Math.pow(backoffMultiplier, attempt.toDouble())).toLong()
        val jitter = (delay * jitterFactor * Math.random()).toLong()
        return minOf(maxDelayMs, delay + jitter)
    }
    
    fun updateForError(errorType: NetworkErrorType) {
        errorHistory.add(errorType)
        if (errorHistory.size > 10) {
            errorHistory.removeAt(0)
        }
    }
}

data class NetworkOptimizationResult(
    val recommendedChunkSize: Int,
    val recommendedConcurrency: Int,
    val recommendedTimeout: Long,
    val enableCompression: Boolean,
    val enableEncryption: Boolean,
    val bufferSize: Int,
    val keepAliveInterval: Long
)

data class FileTransferOptimization(
    val chunkSize: Int,
    val concurrentTransfers: Int,
    val enableCompression: Boolean,
    val enableEncryption: Boolean,
    val priorityLevel: TransferPriority,
    val estimatedDuration: Long
)

data class BandwidthOptimization(
    val maxBandwidthPerTransfer: Long,
    val totalBandwidthLimit: Long,
    val adaptiveThrottling: Boolean,
    val priorityWeights: Map<TransferPriority, Float>
)

sealed class ErrorHandlingResult {
    data class Retry(
        val delayMs: Long,
        val adjustedSettings: AdaptiveNetworkSettings? = null
    ) : ErrorHandlingResult()
    
    data class Reconnect(
        val delayMs: Long,
        val useAlternativeEndpoint: Boolean = false
    ) : ErrorHandlingResult()
    
    data class GiveUp(
        val reason: String,
        val suggestion: String
    ) : ErrorHandlingResult()
}

data class NetworkError(
    val type: NetworkErrorType,
    val message: String,
    val cause: Throwable? = null,
    val timestamp: Long = System.currentTimeMillis()
)

enum class NetworkErrorType {
    TIMEOUT,
    CONNECTION_LOST,
    BANDWIDTH_LIMITED,
    AUTHENTICATION_FAILED,
    PROTOCOL_ERROR,
    UNKNOWN
}

enum class ConnectionQuality {
    EXCELLENT,
    GOOD,
    FAIR,
    POOR
}

enum class TransferPriority {
    HIGH,
    NORMAL,
    LOW
}