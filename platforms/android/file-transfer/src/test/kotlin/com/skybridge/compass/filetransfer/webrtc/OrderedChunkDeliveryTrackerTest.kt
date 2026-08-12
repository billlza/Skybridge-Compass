package com.skybridge.compass.filetransfer.webrtc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Unit tests for the pure ordered-send / delivery-confirmation bookkeeping (Requirements 5.1, 5.10).
 */
class OrderedChunkDeliveryTrackerTest {

    @Test
    fun sendOrder_isStrictlyAscendingByIndex() {
        val tracker = OrderedChunkDeliveryTracker(totalChunks = 5)
        assertEquals(listOf(0, 1, 2, 3, 4), tracker.sendOrder().toList())
    }

    @Test
    fun chunkIsNotDelivered_untilItsAckArrives() {
        val tracker = OrderedChunkDeliveryTracker(totalChunks = 3)

        // Before any ack, nothing is delivered.
        assertFalse(tracker.isChunkDelivered(0))
        assertFalse(tracker.isChunkDelivered(1))
        assertFalse(tracker.isChunkDelivered(2))
        assertEquals(0, tracker.deliveredCount())

        // Sending (attempting) a chunk does NOT make it delivered.
        tracker.recordSendAttempt(1)
        assertFalse(tracker.isChunkDelivered(1))

        // Only its ack marks it delivered.
        tracker.markDelivered(1)
        assertTrue(tracker.isChunkDelivered(1))
        assertFalse(tracker.isChunkDelivered(0))
        assertEquals(1, tracker.deliveredCount())
    }

    @Test
    fun resendCandidates_areOnlyUnackedChunksUnderAttemptCeiling_inAscendingOrder() {
        val tracker = OrderedChunkDeliveryTracker(totalChunks = 4)

        // Chunk 1 is acked -> must never be a resend candidate.
        tracker.markDelivered(1)

        // Chunk 0 exhausted its attempts (>= ceiling) -> excluded.
        repeat(3) { tracker.recordSendAttempt(0) }
        // Chunk 2 has one attempt (< ceiling) -> included.
        tracker.recordSendAttempt(2)
        // Chunk 3 untouched -> included.

        val candidates = tracker.resendCandidates(maxAttempts = 3)
        assertEquals(listOf(2, 3), candidates)
        // Acked chunk excluded even though its attempts are below the ceiling.
        assertFalse(candidates.contains(1))
    }

    @Test
    fun nack_flipsChunkBackToUndelivered_soItIsResentAgain() {
        val tracker = OrderedChunkDeliveryTracker(totalChunks = 2)
        tracker.markDelivered(0)
        assertTrue(tracker.isChunkDelivered(0))

        // Peer reports chunk 0 missing (NACK).
        tracker.markUndelivered(0)
        assertFalse(tracker.isChunkDelivered(0))
        assertTrue(tracker.resendCandidates(maxAttempts = 3).contains(0))
    }

    @Test
    fun isAllDelivered_trueOnlyWhenEveryChunkIsAcked() {
        val tracker = OrderedChunkDeliveryTracker(totalChunks = 3)
        assertFalse(tracker.isAllDelivered())

        tracker.markDelivered(0)
        tracker.markDelivered(2)
        assertFalse(tracker.isAllDelivered())
        assertEquals(listOf(1), tracker.unackedChunks())

        tracker.markDelivered(1)
        assertTrue(tracker.isAllDelivered())
        assertTrue(tracker.unackedChunks().isEmpty())
    }

    @Test
    fun outOfRangeIndices_areIgnored_withoutThrowing() {
        val tracker = OrderedChunkDeliveryTracker(totalChunks = 2)
        assertFalse(tracker.markDelivered(-1))
        assertFalse(tracker.markDelivered(2))
        assertFalse(tracker.markUndelivered(99))
        assertFalse(tracker.isChunkDelivered(5))
        tracker.recordSendAttempt(2) // no-op, no throw
        assertEquals(0, tracker.attemptsFor(2))
        assertFalse(tracker.isAllDelivered())
    }

    @Test
    fun emptyTransfer_isAllDeliveredVacuously() {
        val tracker = OrderedChunkDeliveryTracker(totalChunks = 0)
        assertTrue(tracker.isAllDelivered())
        assertTrue(tracker.sendOrder().toList().isEmpty())
        assertTrue(tracker.resendCandidates(maxAttempts = 3).isEmpty())
    }
}
