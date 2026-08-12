package com.skybridge.compass.filetransfer.webrtc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ReceiveResourceCleanupTest {
    @Test
    fun closeFailureIsTypedAndPreservesPartialBySkippingDelete() {
        var deleteCalled = false

        val report = ReceiveResourceCleanup.execute(
            transferId = "transfer-close-failure",
            closePartialFile = { throw IllegalStateException("close failed") },
            deletePartialFile = { deleteCalled = true },
        )

        assertFalse(report.isSuccessful)
        assertEquals(listOf("close_partial_file"), report.failedStages)
        assertEquals(
            ReceiveCleanupCheckpointDisposition.RETAIN_FOR_RECOVERY,
            report.checkpointDisposition,
        )
        assertTrue(report.failures.single().cause is IllegalStateException)
        assertFalse(deleteCalled, "an open partial must remain at its checkpoint path")
    }

    @Test
    fun deleteFailureIsTypedAfterSuccessfulClose() {
        val operations = mutableListOf<String>()

        val report = ReceiveResourceCleanup.execute(
            transferId = "transfer-delete-failure",
            closePartialFile = { operations += "close" },
            deletePartialFile = {
                operations += "delete"
                throw IllegalStateException("delete failed")
            },
        )

        assertFalse(report.isSuccessful)
        assertEquals(listOf("close", "delete"), operations)
        assertEquals(listOf("delete_partial_file"), report.failedStages)
        assertEquals(
            ReceiveCleanupCheckpointDisposition.RETAIN_FOR_RECOVERY,
            report.checkpointDisposition,
        )
    }

    @Test
    fun successfulCleanupReportsNoFailure() {
        val report = ReceiveResourceCleanup.execute(
            transferId = "transfer-success",
            closePartialFile = {},
            deletePartialFile = {},
        )

        assertTrue(report.isSuccessful)
        assertTrue(report.failedStages.isEmpty())
        assertEquals(ReceiveCleanupCheckpointDisposition.DELETE, report.checkpointDisposition)
    }
}
