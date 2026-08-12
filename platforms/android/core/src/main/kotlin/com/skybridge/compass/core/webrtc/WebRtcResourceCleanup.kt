package com.skybridge.compass.core.webrtc

/** Best-effort native resource cleanup with an explicit, composable failure report. */
internal class WebRtcResourceCloseReport {
    data class Failure(val stage: String, val error: Throwable)

    private val mutableFailures = mutableListOf<Failure>()
    val failures: List<Failure> get() = mutableFailures.toList()
    val isSuccessful: Boolean get() = mutableFailures.isEmpty()

    fun attempt(stage: String, action: () -> Unit) {
        try {
            action()
        } catch (error: Exception) {
            mutableFailures += Failure(stage, error)
        }
    }

    suspend fun attemptSuspending(stage: String, action: suspend () -> Unit) {
        try {
            action()
        } catch (error: Exception) {
            mutableFailures += Failure(stage, error)
        }
    }

    fun merge(prefix: String, other: WebRtcResourceCloseReport) {
        other.failures.forEach { failure ->
            mutableFailures += Failure("$prefix.${failure.stage}", failure.error)
        }
    }

    fun asException(context: String): WebRtcResourceCleanupException {
        check(!isSuccessful) { "successful cleanup has no exception" }
        return WebRtcResourceCleanupException(
            context = context,
            stages = failures.map(Failure::stage)
        ).also { aggregate ->
            failures.forEach { aggregate.addSuppressed(it.error) }
        }
    }
}

internal class WebRtcResourceCleanupException(
    context: String,
    stages: List<String>
) : IllegalStateException("$context cleanup failed at ${stages.joinToString(separator = ",")}")
