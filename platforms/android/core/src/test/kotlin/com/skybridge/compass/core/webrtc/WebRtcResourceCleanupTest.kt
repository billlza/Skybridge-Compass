package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebRtcResourceCleanupTest {
    @Test
    fun cleanupAttemptsEveryStageAndAggregatesFailuresWithoutLosingStageIdentity() {
        val timeline = mutableListOf<String>()
        val report = WebRtcResourceCloseReport()

        report.attempt("dataChannel.close") {
            timeline += "dataChannel.close"
            throw IllegalStateException("first")
        }
        report.attempt("peerConnection.close") {
            timeline += "peerConnection.close"
        }
        report.attempt("factory.dispose") {
            timeline += "factory.dispose"
            throw IllegalArgumentException("last")
        }

        assertEquals(
            listOf("dataChannel.close", "peerConnection.close", "factory.dispose"),
            timeline
        )
        assertFalse(report.isSuccessful)
        assertEquals(listOf("dataChannel.close", "factory.dispose"), report.failures.map { it.stage })
        val aggregate = report.asException("session")
        assertEquals(2, aggregate.suppressed.size)
        assertTrue(aggregate.message.orEmpty().contains("dataChannel.close,factory.dispose"))
    }

    @Test
    fun successfulCleanupCannotBeMisrepresentedAsAnError() {
        val report = WebRtcResourceCloseReport()
        report.attempt("resource.close") { }

        assertTrue(report.isSuccessful)
        assertThrows(IllegalStateException::class.java) {
            report.asException("session")
        }
    }

    @Test
    fun nestedReportsKeepTheResourcePrefix() {
        val session = WebRtcResourceCloseReport().apply {
            attempt("peerConnection.dispose") { throw IllegalStateException("native") }
        }
        val connection = WebRtcResourceCloseReport().apply {
            merge("session", session)
        }

        assertEquals(listOf("session.peerConnection.dispose"), connection.failures.map { it.stage })
    }
}
