package com.skybridge.compass.filetransfer.webrtc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.Executors

class InboundTransferAdmissionTest {
    @Test
    fun admitsAtMostFourActiveTransfersAndReleaseIsExactOnce() {
        val admission = admission(maximumAggregateBytes = 1_000)
        val ids = List(5) { UUID.randomUUID().toString() }

        ids.take(4).forEach { assertNull(admission.tryAdmit(it, 100)) }
        assertEquals("inbound transfer count capacity exceeded", admission.tryAdmit(ids[4], 100))
        assertEquals(4 to 400L, admission.snapshot())

        admission.release(ids[0])
        admission.release(ids[0])
        assertEquals(3 to 300L, admission.snapshot(), "duplicate release must not underflow accounting")
        assertNull(admission.tryAdmit(ids[4], 100))
        assertEquals(4 to 400L, admission.snapshot())
    }

    @Test
    fun aggregateBoundaryIsSixteenGiBAndNeverOverflows() {
        val maximum = 16L * 1024 * 1024 * 1024
        val admission = admission(maximumAggregateBytes = maximum)
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        val rejected = UUID.randomUUID().toString()

        assertNull(admission.tryAdmit(first, maximum - 1))
        assertNull(admission.tryAdmit(second, 1))
        assertEquals("inbound aggregate byte capacity exceeded", admission.tryAdmit(rejected, 1))
        assertEquals(2 to maximum, admission.snapshot())

        admission.release(first)
        assertNull(admission.tryAdmit(rejected, maximum - 1))
        assertEquals(2 to maximum, admission.snapshot())
    }

    @Test
    fun durableAdmissionReservesAggregateAgainstUsableSpace() {
        var usableSpace = 100L
        val admission = InboundTransferAdmission(
            maximumActiveTransfers = 4,
            maximumAggregateBytes = 1_000,
            requireDiskCapacity = true,
            usableSpaceBytes = { usableSpace },
        )
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()

        assertNull(admission.tryAdmit(first, 60))
        assertEquals("inbound staging disk capacity exceeded", admission.tryAdmit(second, 41))
        assertNull(admission.tryAdmit(second, 40))
        usableSpace = 99
        assertEquals(
            "inbound staging disk capacity exceeded",
            admission.tryAdmit(UUID.randomUUID().toString(), 1),
        )
    }

    @Test
    fun concurrentAdmissionHasOneLinearizedFourTransferLimit() {
        val admission = admission(maximumAggregateBytes = 1_000)
        val pool = Executors.newFixedThreadPool(12)
        try {
            val barrier = CyclicBarrier(12)
            val results = pool.invokeAll(
                List(12) {
                    Callable {
                        barrier.await()
                        admission.tryAdmit(UUID.randomUUID().toString(), 1)
                    }
                },
            ).map { it.get() }

            assertEquals(4, results.count { it == null })
            assertTrue(results.filterNotNull().all { it == "inbound transfer count capacity exceeded" })
            assertEquals(4 to 4L, admission.snapshot())
        } finally {
            pool.shutdownNow()
        }
    }

    private fun admission(maximumAggregateBytes: Long) = InboundTransferAdmission(
        maximumActiveTransfers = 4,
        maximumAggregateBytes = maximumAggregateBytes,
        requireDiskCapacity = false,
        usableSpaceBytes = { error("in-memory admission must not query disk capacity") },
    )
}
