package com.skybridge.compass.shared.network

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Error recovery manager for handling network failures and automatic recovery
 */
@Singleton
class ErrorRecoveryManager @Inject constructor(
    private val networkOptimizer: NetworkOptimizer
) {

    private val activeRecoveries = ConcurrentHashMap<String, RecoverySession>()
    private val errorPatterns = ConcurrentHashMap<String, ErrorPattern>()
    private val circuitBreakers = ConcurrentHashMap<String, CircuitBreaker>()

    /**
     * Handle error with automatic recovery strategies
     */
    suspend fun handleError(
        sessionId: String,
        error: NetworkError,
        context: ErrorContext
    ): RecoveryResult {
        val pattern = updateErrorPattern(sessionId, error)
        val circuitBreaker = getOrCreateCircuitBreaker(sessionId)
        
        // Check if circuit breaker is open
        if (circuitBreaker.isOpen()) {
            return RecoveryResult.CircuitBreakerOpen(
                waitTimeMs = circuitBreaker.getWaitTime(),
                reason = "Too many consecutive failures"
            )
        }

        // Get existing recovery session or create new one
        val recoverySession = activeRecoveries.getOrPut(sessionId) {
            RecoverySession(
                sessionId = sessionId,
                startTime = System.currentTimeMillis(),
                attempts = AtomicInteger(0),
                strategy = determineRecoveryStrategy(error, pattern, context)
            )
        }

        val attemptNumber = recoverySession.attempts.incrementAndGet()
        
        return when (val strategy = recoverySession.strategy) {
            is RecoveryStrategy.ExponentialBackoff -> {
                handleExponentialBackoff(sessionId, error, strategy, attemptNumber, circuitBreaker)
            }
            
            is RecoveryStrategy.CircuitBreaker -> {
                handleCircuitBreakerRecovery(sessionId, error, strategy, circuitBreaker)
            }
            
            is RecoveryStrategy.Failover -> {
                handleFailoverRecovery(sessionId, error, strategy, context)
            }
            
            is RecoveryStrategy.AdaptiveRetry -> {
                handleAdaptiveRetry(sessionId, error, strategy, attemptNumber, context)
            }
            
            is RecoveryStrategy.GracefulDegradation -> {
                handleGracefulDegradation(sessionId, error, strategy, context)
            }
        }
    }

    /**
     * Monitor recovery progress
     */
    fun monitorRecovery(sessionId: String): Flow<RecoveryStatus> = flow {
        val recoverySession = activeRecoveries[sessionId]
        if (recoverySession == null) {
            emit(RecoveryStatus.NotActive)
            return@flow
        }

        while (activeRecoveries.containsKey(sessionId)) {
            val session = activeRecoveries[sessionId]!!
            val circuitBreaker = circuitBreakers[sessionId]
            
            emit(RecoveryStatus.Active(
                sessionId = sessionId,
                attempts = session.attempts.get(),
                strategy = session.strategy,
                elapsedTime = System.currentTimeMillis() - session.startTime,
                circuitBreakerState = circuitBreaker?.getState() ?: CircuitBreakerState.CLOSED,
                nextRetryTime = calculateNextRetryTime(session)
            ))
            
            delay(1000) // Update every second
        }
        
        emit(RecoveryStatus.Completed)
    }.flowOn(Dispatchers.IO)

    /**
     * Force recovery completion
     */
    fun completeRecovery(sessionId: String, success: Boolean) {
        activeRecoveries.remove(sessionId)
        
        val circuitBreaker = circuitBreakers[sessionId]
        if (success) {
            circuitBreaker?.recordSuccess()
        } else {
            circuitBreaker?.recordFailure()
        }
    }

    /**
     * Get recovery statistics
     */
    fun getRecoveryStatistics(sessionId: String): RecoveryStatistics? {
        val pattern = errorPatterns[sessionId] ?: return null
        val circuitBreaker = circuitBreakers[sessionId]
        
        return RecoveryStatistics(
            sessionId = sessionId,
            totalErrors = pattern.totalErrors,
            errorsByType = pattern.errorsByType.toMap(),
            averageRecoveryTime = pattern.averageRecoveryTime,
            successRate = pattern.successRate,
            circuitBreakerTrips = circuitBreaker?.getTripCount() ?: 0,
            lastErrorTime = pattern.lastErrorTime,
            recoveryTrend = calculateRecoveryTrend(pattern)
        )
    }

    /**
     * Reset error patterns and circuit breakers
     */
    fun resetRecoveryState(sessionId: String) {
        activeRecoveries.remove(sessionId)
        errorPatterns.remove(sessionId)
        circuitBreakers.remove(sessionId)
    }

    private suspend fun handleExponentialBackoff(
        sessionId: String,
        error: NetworkError,
        strategy: RecoveryStrategy.ExponentialBackoff,
        attemptNumber: Int,
        circuitBreaker: CircuitBreaker
    ): RecoveryResult {
        if (attemptNumber > strategy.maxRetries) {
            circuitBreaker.recordFailure()
            return RecoveryResult.MaxRetriesExceeded(
                totalAttempts = attemptNumber,
                suggestion = "Consider checking network connectivity or server status"
            )
        }

        val delayMs = calculateExponentialBackoff(
            baseDelayMs = strategy.baseDelayMs,
            attempt = attemptNumber,
            multiplier = strategy.multiplier,
            maxDelayMs = strategy.maxDelayMs,
            jitterFactor = strategy.jitterFactor
        )

        return RecoveryResult.RetryAfterDelay(
            delayMs = delayMs,
            attemptNumber = attemptNumber,
            adjustedSettings = networkOptimizer.optimizeConnection(
                connectionId = sessionId,
                currentLatency = 0L, // Will be measured
                bandwidth = 0L,     // Will be measured
                packetLoss = 0f     // Will be measured
            )
        )
    }

    private suspend fun handleCircuitBreakerRecovery(
        sessionId: String,
        error: NetworkError,
        strategy: RecoveryStrategy.CircuitBreaker,
        circuitBreaker: CircuitBreaker
    ): RecoveryResult {
        circuitBreaker.recordFailure()
        
        return if (circuitBreaker.isOpen()) {
            RecoveryResult.CircuitBreakerOpen(
                waitTimeMs = circuitBreaker.getWaitTime(),
                reason = "Circuit breaker opened due to consecutive failures"
            )
        } else {
            RecoveryResult.RetryAfterDelay(
                delayMs = strategy.retryDelayMs,
                attemptNumber = 1,
                adjustedSettings = null
            )
        }
    }

    private suspend fun handleFailoverRecovery(
        sessionId: String,
        error: NetworkError,
        strategy: RecoveryStrategy.Failover,
        context: ErrorContext
    ): RecoveryResult {
        val alternativeEndpoint = selectAlternativeEndpoint(
            currentEndpoint = context.endpoint,
            availableEndpoints = strategy.alternativeEndpoints
        )

        return if (alternativeEndpoint != null) {
            RecoveryResult.SwitchEndpoint(
                newEndpoint = alternativeEndpoint,
                reason = "Switching to alternative endpoint due to ${error.type}"
            )
        } else {
            RecoveryResult.NoAlternativesAvailable(
                reason = "All alternative endpoints exhausted"
            )
        }
    }

    private suspend fun handleAdaptiveRetry(
        sessionId: String,
        error: NetworkError,
        strategy: RecoveryStrategy.AdaptiveRetry,
        attemptNumber: Int,
        context: ErrorContext
    ): RecoveryResult {
        val pattern = errorPatterns[sessionId]
        val adaptiveDelay = calculateAdaptiveDelay(error, pattern, attemptNumber)
        
        // Adjust strategy based on error patterns
        val adjustedSettings = when {
            pattern?.isFrequentTimeout() == true -> {
                // Increase timeouts for frequent timeout errors
                networkOptimizer.optimizeConnection(sessionId, 0L, 0L, 0f).copy(
                    recommendedTimeout = strategy.baseTimeoutMs * 2
                )
            }
            
            pattern?.isFrequentConnectionLoss() == true -> {
                // Reduce concurrency for connection issues
                networkOptimizer.optimizeConnection(sessionId, 0L, 0L, 0f).copy(
                    recommendedConcurrency = 1
                )
            }
            
            else -> null
        }

        return RecoveryResult.RetryAfterDelay(
            delayMs = adaptiveDelay,
            attemptNumber = attemptNumber,
            adjustedSettings = adjustedSettings
        )
    }

    private suspend fun handleGracefulDegradation(
        sessionId: String,
        error: NetworkError,
        strategy: RecoveryStrategy.GracefulDegradation,
        context: ErrorContext
    ): RecoveryResult {
        val degradedMode = when (error.type) {
            NetworkErrorType.BANDWIDTH_LIMITED -> DegradedMode.ReducedQuality(
                compressionLevel = 0.8f,
                reducedConcurrency = true,
                lowerResolution = true
            )
            
            NetworkErrorType.TIMEOUT -> DegradedMode.OfflineMode(
                cacheData = true,
                queueOperations = true
            )
            
            NetworkErrorType.CONNECTION_LOST -> DegradedMode.LocalOnly(
                useLocalCache = true,
                disableRemoteFeatures = true
            )
            
            else -> DegradedMode.BasicFunctionality(
                disableNonEssentialFeatures = true
            )
        }

        return RecoveryResult.DegradeService(
            mode = degradedMode,
            reason = "Degrading service due to ${error.type}",
            estimatedRecoveryTime = strategy.estimatedRecoveryTimeMs
        )
    }

    private fun updateErrorPattern(sessionId: String, error: NetworkError): ErrorPattern {
        return errorPatterns.compute(sessionId) { _, existing ->
            val current = existing ?: ErrorPattern(sessionId)
            current.copy(
                totalErrors = current.totalErrors + 1,
                errorsByType = current.errorsByType.toMutableMap().apply {
                    this[error.type] = (this[error.type] ?: 0) + 1
                },
                lastErrorTime = error.timestamp,
                recentErrors = (current.recentErrors + error).takeLast(10)
            )
        }!!
    }

    private fun getOrCreateCircuitBreaker(sessionId: String): CircuitBreaker {
        return circuitBreakers.getOrPut(sessionId) {
            CircuitBreaker(
                failureThreshold = 5,
                recoveryTimeoutMs = 30000L,
                halfOpenMaxCalls = 3
            )
        }
    }

    private fun determineRecoveryStrategy(
        error: NetworkError,
        pattern: ErrorPattern,
        context: ErrorContext
    ): RecoveryStrategy {
        return when {
            // Use circuit breaker for frequent failures
            pattern.totalErrors > 10 && pattern.getRecentFailureRate() > 0.8f -> {
                RecoveryStrategy.CircuitBreaker(retryDelayMs = 5000L)
            }
            
            // Use failover for connection issues with alternatives available
            error.type == NetworkErrorType.CONNECTION_LOST && context.hasAlternatives -> {
                RecoveryStrategy.Failover(
                    alternativeEndpoints = context.alternativeEndpoints
                )
            }
            
            // Use adaptive retry for timeout patterns
            pattern.isFrequentTimeout() -> {
                RecoveryStrategy.AdaptiveRetry(
                    baseTimeoutMs = 10000L,
                    adaptationFactor = 1.5
                )
            }
            
            // Use graceful degradation for bandwidth issues
            error.type == NetworkErrorType.BANDWIDTH_LIMITED -> {
                RecoveryStrategy.GracefulDegradation(
                    estimatedRecoveryTimeMs = 60000L
                )
            }
            
            // Default to exponential backoff
            else -> {
                RecoveryStrategy.ExponentialBackoff(
                    baseDelayMs = 1000L,
                    multiplier = 2.0,
                    maxRetries = 5,
                    maxDelayMs = 30000L,
                    jitterFactor = 0.1
                )
            }
        }
    }

    private fun calculateExponentialBackoff(
        baseDelayMs: Long,
        attempt: Int,
        multiplier: Double,
        maxDelayMs: Long,
        jitterFactor: Double
    ): Long {
        val delay = (baseDelayMs * Math.pow(multiplier, (attempt - 1).toDouble())).toLong()
        val jitter = (delay * jitterFactor * Math.random()).toLong()
        return minOf(maxDelayMs, delay + jitter)
    }

    private fun calculateAdaptiveDelay(
        error: NetworkError,
        pattern: ErrorPattern?,
        attemptNumber: Int
    ): Long {
        val baseDelay = when (error.type) {
            NetworkErrorType.TIMEOUT -> 2000L
            NetworkErrorType.CONNECTION_LOST -> 5000L
            NetworkErrorType.BANDWIDTH_LIMITED -> 10000L
            else -> 1000L
        }

        val patternMultiplier = pattern?.let { p ->
            when {
                p.isFrequentTimeout() -> 2.0
                p.isFrequentConnectionLoss() -> 1.5
                else -> 1.0
            }
        } ?: 1.0

        return (baseDelay * patternMultiplier * attemptNumber).toLong()
    }

    private fun selectAlternativeEndpoint(
        currentEndpoint: String,
        availableEndpoints: List<String>
    ): String? {
        return availableEndpoints.firstOrNull { it != currentEndpoint }
    }

    private fun calculateNextRetryTime(session: RecoverySession): Long {
        // This is a simplified calculation - in practice, this would depend on the strategy
        return System.currentTimeMillis() + 5000L
    }

    private fun calculateRecoveryTrend(pattern: ErrorPattern): RecoveryTrend {
        val recentErrors = pattern.recentErrors.takeLast(5)
        if (recentErrors.size < 2) return RecoveryTrend.STABLE

        val timeSpan = recentErrors.last().timestamp - recentErrors.first().timestamp
        val errorRate = recentErrors.size.toDouble() / (timeSpan / 1000.0) // errors per second

        return when {
            errorRate > 0.1 -> RecoveryTrend.DETERIORATING
            errorRate < 0.01 -> RecoveryTrend.IMPROVING
            else -> RecoveryTrend.STABLE
        }
    }
}

// Data classes for error recovery
data class RecoverySession(
    val sessionId: String,
    val startTime: Long,
    val attempts: AtomicInteger,
    val strategy: RecoveryStrategy
)

data class ErrorPattern(
    val sessionId: String,
    val totalErrors: Int = 0,
    val errorsByType: Map<NetworkErrorType, Int> = emptyMap(),
    val lastErrorTime: Long = 0L,
    val recentErrors: List<NetworkError> = emptyList(),
    val successCount: Int = 0,
    val averageRecoveryTime: Long = 0L
) {
    val successRate: Float
        get() = if (totalErrors + successCount == 0) 1.0f 
                else successCount.toFloat() / (totalErrors + successCount)

    fun getRecentFailureRate(): Float {
        val recentCount = recentErrors.size
        return if (recentCount == 0) 0f else recentCount / 10f // Out of last 10 operations
    }

    fun isFrequentTimeout(): Boolean {
        val timeoutCount = errorsByType[NetworkErrorType.TIMEOUT] ?: 0
        return timeoutCount > totalErrors * 0.5
    }

    fun isFrequentConnectionLoss(): Boolean {
        val connectionLossCount = errorsByType[NetworkErrorType.CONNECTION_LOST] ?: 0
        return connectionLossCount > totalErrors * 0.3
    }
}

data class ErrorContext(
    val endpoint: String,
    val alternativeEndpoints: List<String> = emptyList(),
    val operationType: String,
    val priority: TransferPriority = TransferPriority.NORMAL,
    val userInitiated: Boolean = true
) {
    val hasAlternatives: Boolean
        get() = alternativeEndpoints.isNotEmpty()
}

sealed class RecoveryStrategy {
    data class ExponentialBackoff(
        val baseDelayMs: Long,
        val multiplier: Double,
        val maxRetries: Int,
        val maxDelayMs: Long,
        val jitterFactor: Double
    ) : RecoveryStrategy()

    data class CircuitBreaker(
        val retryDelayMs: Long
    ) : RecoveryStrategy()

    data class Failover(
        val alternativeEndpoints: List<String>
    ) : RecoveryStrategy()

    data class AdaptiveRetry(
        val baseTimeoutMs: Long,
        val adaptationFactor: Double
    ) : RecoveryStrategy()

    data class GracefulDegradation(
        val estimatedRecoveryTimeMs: Long
    ) : RecoveryStrategy()
}

sealed class RecoveryResult {
    data class RetryAfterDelay(
        val delayMs: Long,
        val attemptNumber: Int,
        val adjustedSettings: NetworkOptimizationResult?
    ) : RecoveryResult()

    data class SwitchEndpoint(
        val newEndpoint: String,
        val reason: String
    ) : RecoveryResult()

    data class DegradeService(
        val mode: DegradedMode,
        val reason: String,
        val estimatedRecoveryTime: Long
    ) : RecoveryResult()

    data class CircuitBreakerOpen(
        val waitTimeMs: Long,
        val reason: String
    ) : RecoveryResult()

    data class MaxRetriesExceeded(
        val totalAttempts: Int,
        val suggestion: String
    ) : RecoveryResult()

    data class NoAlternativesAvailable(
        val reason: String
    ) : RecoveryResult()
}

sealed class RecoveryStatus {
    object NotActive : RecoveryStatus()
    
    data class Active(
        val sessionId: String,
        val attempts: Int,
        val strategy: RecoveryStrategy,
        val elapsedTime: Long,
        val circuitBreakerState: CircuitBreakerState,
        val nextRetryTime: Long
    ) : RecoveryStatus()
    
    object Completed : RecoveryStatus()
}

sealed class DegradedMode {
    data class ReducedQuality(
        val compressionLevel: Float,
        val reducedConcurrency: Boolean,
        val lowerResolution: Boolean
    ) : DegradedMode()

    data class OfflineMode(
        val cacheData: Boolean,
        val queueOperations: Boolean
    ) : DegradedMode()

    data class LocalOnly(
        val useLocalCache: Boolean,
        val disableRemoteFeatures: Boolean
    ) : DegradedMode()

    data class BasicFunctionality(
        val disableNonEssentialFeatures: Boolean
    ) : DegradedMode()
}

data class RecoveryStatistics(
    val sessionId: String,
    val totalErrors: Int,
    val errorsByType: Map<NetworkErrorType, Int>,
    val averageRecoveryTime: Long,
    val successRate: Float,
    val circuitBreakerTrips: Int,
    val lastErrorTime: Long,
    val recoveryTrend: RecoveryTrend
)

enum class RecoveryTrend {
    IMPROVING,
    STABLE,
    DETERIORATING
}

// Circuit Breaker implementation
class CircuitBreaker(
    private val failureThreshold: Int,
    private val recoveryTimeoutMs: Long,
    private val halfOpenMaxCalls: Int
) {
    private var state = CircuitBreakerState.CLOSED
    private var failureCount = 0
    private var lastFailureTime = 0L
    private var halfOpenCalls = 0
    private var tripCount = 0

    fun recordSuccess() {
        when (state) {
            CircuitBreakerState.HALF_OPEN -> {
                state = CircuitBreakerState.CLOSED
                failureCount = 0
                halfOpenCalls = 0
            }
            CircuitBreakerState.CLOSED -> {
                failureCount = 0
            }
            CircuitBreakerState.OPEN -> {
                // Should not happen, but reset anyway
                state = CircuitBreakerState.CLOSED
                failureCount = 0
            }
        }
    }

    fun recordFailure() {
        failureCount++
        lastFailureTime = System.currentTimeMillis()

        when (state) {
            CircuitBreakerState.CLOSED -> {
                if (failureCount >= failureThreshold) {
                    state = CircuitBreakerState.OPEN
                    tripCount++
                }
            }
            CircuitBreakerState.HALF_OPEN -> {
                state = CircuitBreakerState.OPEN
                tripCount++
            }
            CircuitBreakerState.OPEN -> {
                // Already open, do nothing
            }
        }
    }

    fun isOpen(): Boolean {
        if (state == CircuitBreakerState.OPEN) {
            if (System.currentTimeMillis() - lastFailureTime >= recoveryTimeoutMs) {
                state = CircuitBreakerState.HALF_OPEN
                halfOpenCalls = 0
                return false
            }
            return true
        }
        
        if (state == CircuitBreakerState.HALF_OPEN) {
            return halfOpenCalls >= halfOpenMaxCalls
        }
        
        return false
    }

    fun getState(): CircuitBreakerState = state

    fun getWaitTime(): Long {
        return if (state == CircuitBreakerState.OPEN) {
            maxOf(0, recoveryTimeoutMs - (System.currentTimeMillis() - lastFailureTime))
        } else {
            0L
        }
    }

    fun getTripCount(): Int = tripCount
}

enum class CircuitBreakerState {
    CLOSED,
    OPEN,
    HALF_OPEN
}