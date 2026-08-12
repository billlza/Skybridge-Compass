package com.skybridge.compass.remotecontrol.execution

import com.skybridge.compass.remotecontrol.model.InputEventStats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InputExecutionStatsReducerTest {

    @Test
    fun firstRecordedEventUsesProcessingTimeAsAverageLatency() {
        val updated = InputExecutionStatsReducer.record(
            stats = InputEventStats(),
            success = true,
            processingTime = 25L,
            now = 100L
        )

        assertEquals(1L, updated.totalEvents)
        assertEquals(1L, updated.successfulEvents)
        assertEquals(0L, updated.failedEvents)
        assertEquals(25.0, updated.averageLatency, 0.0)
        assertEquals(100L, updated.lastEventTime)
        assertTrue(updated.averageLatency.isFinite())
    }

    @Test
    fun subsequentEventsUpdateAverageAgainstPreviousTotal() {
        val initial = InputEventStats(
            totalEvents = 1L,
            successfulEvents = 1L,
            averageLatency = 25.0,
            lastEventTime = 100L
        )
        val updated = InputExecutionStatsReducer.record(
            stats = initial,
            success = false,
            processingTime = 75L,
            now = 200L
        )

        assertEquals(2L, updated.totalEvents)
        assertEquals(1L, updated.successfulEvents)
        assertEquals(1L, updated.failedEvents)
        assertEquals(50.0, updated.averageLatency, 0.0)
        assertEquals(200L, updated.lastEventTime)
    }
}
