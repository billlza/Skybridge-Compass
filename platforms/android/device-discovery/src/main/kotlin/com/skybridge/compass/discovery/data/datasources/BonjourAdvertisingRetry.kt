package com.skybridge.compass.discovery.data.datasources

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Terminal / transitional status of the Bonjour (NSD) advertising registration, surfaced to the UI
 * as a leaf-level fact (R3.13). Browsing runs on an independent path and is unaffected by any of
 * these advertise-side transitions.
 */
sealed interface BonjourAdvertisingStatus {
    /** No advertising registration has been attempted yet (or it was stopped). */
    data object Idle : BonjourAdvertisingStatus

    /** A registration attempt is in flight (first attempt, before any retry backoff). */
    data class Registering(val serviceType: String) : BonjourAdvertisingStatus

    /**
     * A prior attempt failed and the next retry is scheduled after [backoffMs].
     * [attempt] is the 1-based index of the retry about to run (1, 2, or 3).
     */
    data class Retrying(
        val serviceType: String,
        val attempt: Int,
        val backoffMs: Long
    ) : BonjourAdvertisingStatus

    /** Registration succeeded; the service is advertised under [serviceName]. */
    data class Active(val serviceType: String, val serviceName: String) : BonjourAdvertisingStatus

    /**
     * Registration failed terminally after exhausting all retries. [reason] is human-readable text
     * intended for display in the discovery UI. Browsing continues to run regardless of this state.
     */
    data class Failed(val serviceType: String, val reason: String) : BonjourAdvertisingStatus
}

/**
 * Pure, Android-free retry orchestration for Bonjour advertising registration (R3.13).
 *
 * A registration attempt that does not return a success callback within the registration timeout is
 * retried at most [MAX_RETRIES] times with a 1s / 2s / 4s backoff between attempts. The clock/delay
 * is injected (see [execute]'s `delayMs`) so unit tests can drive the backoff without waiting.
 */
internal object BonjourAdvertisingRetryPolicy {

    /** Maximum number of retries after the initial attempt (initial + 3 retries = 4 total attempts). */
    const val MAX_RETRIES = 3

    /** Backoff before retry #1, #2, #3 respectively, in milliseconds. */
    val BACKOFF_DELAYS_MS: List<Long> = listOf(1_000L, 2_000L, 4_000L)

    /**
     * Runs [attempt] up to `1 + MAX_RETRIES` times. Before each retry (i.e. every attempt after the
     * first) it invokes [onRetryScheduled] with the 1-based retry index and the backoff, then
     * suspends for that backoff via [delayMs]. Returns the first successful result; if every attempt
     * fails, rethrows the last non-cancellation failure. Structured cancellation is never swallowed.
     */
    suspend fun <T> execute(
        attempt: suspend (attemptIndex: Int) -> T,
        delayMs: suspend (Long) -> Unit = { delay(it) },
        onRetryScheduled: (retryIndex: Int, backoffMs: Long) -> Unit = { _, _ -> }
    ): T {
        var lastError: Throwable? = null
        val totalAttempts = MAX_RETRIES + 1
        for (attemptIndex in 0 until totalAttempts) {
            if (attemptIndex > 0) {
                val backoff = BACKOFF_DELAYS_MS[attemptIndex - 1]
                onRetryScheduled(attemptIndex, backoff)
                delayMs(backoff)
            }
            try {
                return attempt(attemptIndex)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                lastError = error
            }
        }
        throw lastError
            ?: IllegalStateException("Bonjour advertising registration failed with no captured error")
    }
}

/**
 * Drives a single logical advertising registration through [BonjourAdvertisingRetryPolicy] while
 * publishing the resulting status transitions to [status].
 *
 * This type owns no Android state — [registerOnce] is supplied by the caller and performs the actual
 * NSD registration (with its own per-attempt timeout). Keeping the retry/backoff and status logic
 * here makes it unit-testable without spinning up a real NsdManager.
 */
internal class BonjourAdvertisingRegistrar(
    private val status: MutableStateFlow<BonjourAdvertisingStatus>,
    private val delayMs: suspend (Long) -> Unit = { delay(it) }
) {
    /**
     * Registers [serviceType] via [registerOnce], retrying per [BonjourAdvertisingRetryPolicy].
     *
     * On success the status becomes [BonjourAdvertisingStatus.Active] and the registered service
     * name is returned. If every attempt fails the status becomes [BonjourAdvertisingStatus.Failed]
     * with a reason text and the last failure is rethrown so the caller can release resources; the
     * failed status remains observable by the UI. Cancellation is propagated without marking failure.
     */
    suspend fun register(
        serviceType: String,
        registerOnce: suspend () -> String
    ): String {
        status.value = BonjourAdvertisingStatus.Registering(serviceType)
        return try {
            val serviceName = BonjourAdvertisingRetryPolicy.execute(
                attempt = { registerOnce() },
                delayMs = delayMs,
                onRetryScheduled = { retryIndex, backoffMs ->
                    status.value = BonjourAdvertisingStatus.Retrying(
                        serviceType = serviceType,
                        attempt = retryIndex,
                        backoffMs = backoffMs
                    )
                }
            )
            status.value = BonjourAdvertisingStatus.Active(serviceType, serviceName)
            serviceName
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Throwable) {
            status.value = BonjourAdvertisingStatus.Failed(
                serviceType = serviceType,
                reason = failureReason(serviceType, error)
            )
            throw error
        }
    }

    private fun failureReason(serviceType: String, error: Throwable): String {
        val detail = error.message?.trim().takeUnless { it.isNullOrEmpty() }
            ?: error::class.java.simpleName
        return "Bonjour advertising registration for $serviceType failed after " +
            "${BonjourAdvertisingRetryPolicy.MAX_RETRIES} retries: $detail"
    }
}
