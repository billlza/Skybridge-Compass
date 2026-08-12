package com.skybridge.compass.core.webrtc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.concurrent.atomic.AtomicInteger

class ExactOwnerWebRtcFramedSenderTest {
    @Test
    fun secondChunkRejectionClosesExactOwnerAndRejectsNextSend() {
        val owner = Any()
        var currentOwner: Any? = owner
        val chunkAttempts = AtomicInteger(0)
        var closedOwner: Any? = null
        val sender = ExactOwnerWebRtcFramedSender<Any>(
            runIfCurrentOwner = { candidate, operation ->
                if (currentOwner === candidate) {
                    operation()
                    true
                } else {
                    false
                }
            },
            sendChunk = { _, _ -> chunkAttempts.incrementAndGet() == 1 },
            terminatePartiallyWrittenOwner = { candidate, _ ->
                if (currentOwner === candidate) {
                    closedOwner = candidate
                    currentOwner = null
                }
            },
        )
        val twoChunkPayload = ByteArray(WebRtcDataChannelFraming.MAXIMUM_CHUNK_BYTES)

        assertFalse(sender.send(owner, twoChunkPayload))
        assertTrue(closedOwner === owner, "the exact partially-written owner must be closed")
        assertFalse(sender.send(owner, byteArrayOf(1)), "a closed owner must reject the next send")
        assertEquals(2, chunkAttempts.get(), "the next send must not reach the native sender")
    }

    @Test
    fun firstChunkRejectionDoesNotCloseAlignedOwner() {
        val owner = Any()
        var closeCount = 0
        val sender = ExactOwnerWebRtcFramedSender<Any>(
            runIfCurrentOwner = { _, operation ->
                operation()
                true
            },
            sendChunk = { _, _ -> false },
            terminatePartiallyWrittenOwner = { _, _ -> closeCount += 1 },
        )

        assertFalse(sender.send(owner, byteArrayOf(1)))
        assertEquals(0, closeCount)
    }
}
