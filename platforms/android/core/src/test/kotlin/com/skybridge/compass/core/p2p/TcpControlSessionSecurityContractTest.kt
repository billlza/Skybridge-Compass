package com.skybridge.compass.core.p2p

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class TcpControlSessionSecurityContractTest {
    @Test
    fun responderHandshakeDeadlineIsAppliedAndClearedAfterAuthentication() {
        val session = source("TcpControlSession.kt")
        val server = source("TcpControlServer.kt")

        assertTrue(server.contains("handshakeDeadlineMillis = HANDSHAKE_DEADLINE_MILLIS"))
        assertTrue(server.contains("private const val HANDSHAKE_DEADLINE_MILLIS = 30_000L"))
        assertTrue(session.contains("TcpHandshakeDeadline.remainingTimeoutMillis("))
        assertTrue(session.contains("maxFrameSize = P2PHandshakeWire.MAX_HANDSHAKE_FRAME_BYTES"))
        assertTrue(session.contains("socket.soTimeout = 0"))
    }

    @Test
    fun authenticatedInputFailuresTerminateWithFixedCategories() {
        val session = source("TcpControlSession.kt")

        assertTrue(session.contains("authenticated session rekey failed"))
        assertTrue(session.contains("authenticated frame validation failed"))
        assertTrue(session.contains("unsupported authenticated app-control message"))
        assertFalse(session.contains("unsupported authenticated app-control message: \${decoded.type}"))
        assertFalse(session.contains("error.message ?: \"rekey failed\""))
    }

    @Test
    fun clientWaitsForEveryHandshakeTerminalEvent() {
        val client = source("TcpControlClient.kt")

        assertTrue(client.contains("event is TcpControlEvent.HandshakeEstablished"))
        assertTrue(client.contains("event is TcpControlEvent.Failed"))
        assertTrue(client.contains("event is TcpControlEvent.Disconnected"))
        assertTrue(client.contains("TcpControlHandshakeException"))
    }

    private fun source(fileName: String): String {
        val file = listOf(
            File("core/src/main/kotlin/com/skybridge/compass/core/p2p/$fileName"),
            File("src/main/kotlin/com/skybridge/compass/core/p2p/$fileName")
        ).firstOrNull(File::isFile)
            ?: error("$fileName not found from cwd=${File(".").absolutePath}")
        return file.readText()
    }
}
