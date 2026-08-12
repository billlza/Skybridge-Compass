package com.skybridge.compass.core.filetransfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for byte-accurate, monotonic LAN transfer progress (Requirement 5, R5.9).
 *
 * Verifies: progress reflects confirmed bytes exactly (not an estimate); a sequence of
 * confirmed-byte updates yields a monotonically non-decreasing progress; a stale/lower update never
 * regresses the reported progress.
 */
class LanTransferProgressTest {

    @Test
    fun fractionAndPercentReflectConfirmedBytesExactly() {
        val progress = LanTransferProgress(confirmedBytes = 250L, totalBytes = 1000L)
        assertEquals(0.25f, progress.fraction, 0.0f)
        assertEquals(25, progress.percent)
    }

    @Test
    fun initialProgressIsZeroNotAPlaceholder() {
        val progress = LanTransferProgress.initial(totalBytes = 4096L)
        assertEquals(0L, progress.confirmedBytes)
        assertEquals(4096L, progress.totalBytes)
        assertEquals(0f, progress.fraction, 0.0f)
        assertEquals(0, progress.percent)
        assertFalse(progress.completed)
    }

    @Test
    fun zeroByteFileReportsZeroUntilCompleted() {
        val progress = LanTransferProgress.initial(totalBytes = 0L)
        assertEquals(0f, progress.fraction, 0.0f)
        assertEquals(0, progress.percent)

        val completed = LanTransferProgress(confirmedBytes = 0L, totalBytes = 0L, completed = true)
        assertEquals(1f, completed.fraction, 0.0f)
        assertEquals(100, completed.percent)
    }

    @Test
    fun percentIsExactAcrossByteBoundaries() {
        // Exactly-known byte points map to exact percents, never rounded-up estimates.
        assertEquals(0, LanTransferProgress(0L, 3L).percent)
        assertEquals(33, LanTransferProgress(1L, 3L).percent)
        assertEquals(66, LanTransferProgress(2L, 3L).percent)
        assertEquals(100, LanTransferProgress(3L, 3L).percent)
    }

    @Test
    fun trackerYieldsMonotonicNonDecreasingProgressForAscendingUpdates() {
        val tracker = MonotonicLanProgressTracker(totalBytes = 1000L)
        val updates = listOf(100L, 250L, 500L, 750L, 1000L)

        var previous = tracker.snapshot()
        for (bytes in updates) {
            val current = tracker.update(bytes)
            assertTrue(
                "confirmed bytes regressed: ${current.confirmedBytes} < ${previous.confirmedBytes}",
                current.confirmedBytes >= previous.confirmedBytes
            )
            assertTrue(current.fraction >= previous.fraction)
            assertEquals(bytes, current.confirmedBytes)
            previous = current
        }
        assertEquals(100, previous.percent)
    }

    @Test
    fun staleOrLowerUpdateNeverRegressesReportedProgress() {
        val tracker = MonotonicLanProgressTracker(totalBytes = 1000L)
        tracker.update(600L)

        // A stale/out-of-order lower value must not move progress backwards.
        val afterStale = tracker.update(300L)
        assertEquals(600L, afterStale.confirmedBytes)
        assertEquals(60, afterStale.percent)

        // Equal value is a no-op as well.
        val afterEqual = tracker.update(600L)
        assertEquals(600L, afterEqual.confirmedBytes)

        // A higher value still advances.
        val afterHigher = tracker.update(900L)
        assertEquals(900L, afterHigher.confirmedBytes)
    }

    @Test
    fun updatesAreClampedToTotalBytes() {
        val tracker = MonotonicLanProgressTracker(totalBytes = 500L)
        val over = tracker.update(10_000L)
        assertEquals(500L, over.confirmedBytes)
        assertEquals(100, over.percent)
    }

    @Test
    fun completePinsProgressToOneHundredPercent() {
        val tracker = MonotonicLanProgressTracker(totalBytes = 1000L)
        tracker.update(400L)
        val done = tracker.complete()
        assertTrue(done.completed)
        assertEquals(1000L, done.confirmedBytes)
        assertEquals(1f, done.fraction, 0.0f)
        assertEquals(100, done.percent)
    }

    @Test
    fun invalidSnapshotConstructionIsRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            LanTransferProgress(confirmedBytes = 10L, totalBytes = 5L)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LanTransferProgress(confirmedBytes = -1L, totalBytes = 5L)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LanTransferProgress(confirmedBytes = 0L, totalBytes = -5L)
        }
    }
}
