package com.skybridge.compass.core.filetransfer

/**
 * Byte-accurate LAN (`_skybridge-xfer._tcp`) transfer progress.
 *
 * This value is derived only from actually-confirmed bytes (bytes written to / acknowledged by the
 * peer) and the known total size. It never carries a placeholder or estimated value. The associated
 * [fraction] / [percent] are pure functions of [confirmedBytes] and [totalBytes], so the value is
 * fully testable without any socket or Android dependency.
 *
 * Monotonicity (progress is non-decreasing) is enforced by [MonotonicLanProgressTracker]; this type
 * is an immutable snapshot.
 */
data class LanTransferProgress(
    val confirmedBytes: Long,
    val totalBytes: Long,
    val completed: Boolean = false
) {
    init {
        require(totalBytes >= 0) { "totalBytes must be non-negative" }
        require(confirmedBytes >= 0) { "confirmedBytes must be non-negative" }
        require(confirmedBytes <= totalBytes) { "confirmedBytes ($confirmedBytes) must not exceed totalBytes ($totalBytes)" }
    }

    /** Exact fraction in [0f, 1f] computed from confirmed bytes; never an estimate. */
    val fraction: Float
        get() = when {
            completed -> 1f
            totalBytes == 0L -> 0f
            else -> (confirmedBytes.toDouble() / totalBytes.toDouble()).toFloat().coerceIn(0f, 1f)
        }

    /** Integer percent in [0, 100] computed from confirmed bytes; never an estimate. */
    val percent: Int
        get() = when {
            completed -> 100
            totalBytes == 0L -> 0
            else -> ((confirmedBytes * 100L) / totalBytes).toInt().coerceIn(0, 100)
        }

    companion object {
        /** Initial state before any byte is confirmed. */
        fun initial(totalBytes: Long): LanTransferProgress = LanTransferProgress(0L, totalBytes)
    }
}

/**
 * Maintains a monotonically non-decreasing view of confirmed bytes for a single LAN transfer.
 *
 * A stale or lower confirmed-byte update never regresses the reported progress: [update] only moves
 * the reported value forward. [complete] pins progress to 100% once the peer receipt is validated.
 *
 * All state transitions are pure with respect to the inputs and are safe to call from a single
 * transfer coroutine; access is synchronized so the snapshot can also be read from another thread.
 */
class MonotonicLanProgressTracker(private val totalBytes: Long) {
    init {
        require(totalBytes >= 0) { "totalBytes must be non-negative" }
    }

    private var confirmed: Long = 0L
    private var completed: Boolean = false

    /**
     * Records a new confirmed-byte count. Values are clamped to `[0, totalBytes]` and only applied
     * when strictly greater than the current confirmed count, guaranteeing non-regression.
     */
    @Synchronized
    fun update(confirmedBytes: Long): LanTransferProgress {
        val clamped = confirmedBytes.coerceIn(0L, totalBytes)
        if (clamped > confirmed) {
            confirmed = clamped
        }
        return snapshot()
    }

    /** Marks the transfer as fully confirmed (peer receipt validated); pins progress to 100%. */
    @Synchronized
    fun complete(): LanTransferProgress {
        confirmed = totalBytes
        completed = true
        return snapshot()
    }

    @Synchronized
    fun snapshot(): LanTransferProgress = LanTransferProgress(confirmed, totalBytes, completed)
}
