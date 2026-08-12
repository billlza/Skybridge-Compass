package com.skybridge.compass.remotecontrol.secure

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteControlSecureEnvelopeTest {
    private val sendKey = ByteArray(32) { it.toByte() }
    private val receiveKey = ByteArray(32) { (it + 100).toByte() }
    private val transcriptHash = ByteArray(32) { it.toByte() }
    private val sessionId = RemoteControlSecureEnvelope.deterministicSessionId(transcriptHash)

    @Test
    fun sessionIdDerivationMatchesAppleFormula() {
        assertEquals("hs-8269a6bb6b69f0a4c744d41d11c48ed3", sessionId)
    }

    @Test
    fun headerByteLayoutMatchesAppleRemoteControlEnvelope() {
        val plaintext = "stream-config".encodeToByteArray()
        val frame = RemoteControlSecureEnvelope.seal(
            plaintext = plaintext,
            sendKey = sendKey,
            role = RemoteControlSecureEnvelope.Role.INITIATOR,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = RemoteControlSecureEnvelope.PacketType.CONTROL,
            counter = 7L
        )

        assertEquals(52 + plaintext.size + 16, frame.size)
        assertEquals("53425243", hex(frame.copyOfRange(0, 4)))
        assertEquals(1, frame[4].toInt() and 0xFF)
        assertEquals(52, frame[5].toInt() and 0xFF)
        assertEquals(1, frame[6].toInt() and 0xFF)
        assertEquals(1, frame[7].toInt() and 0xFF)
        assertEquals("98e765c624babcaa", hex(frame.copyOfRange(8, 16)))
        assertEquals("258fd231329f120c", hex(frame.copyOfRange(16, 24)))
        assertEquals(0L, readU32BE(frame, 24))
        assertEquals(7L, readU64BE(frame, 28))
        assertEquals(plaintext.size.toLong(), readU32BE(frame, 36))
        assertEquals(12, frame.copyOfRange(40, 52).size)
    }

    @Test
    fun initiatorControlFrameRoundTripsForResponder() {
        val plaintext = "mouse-event".encodeToByteArray()
        val frame = RemoteControlSecureEnvelope.seal(
            plaintext = plaintext,
            sendKey = sendKey,
            role = RemoteControlSecureEnvelope.Role.INITIATOR,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = RemoteControlSecureEnvelope.PacketType.CONTROL,
            counter = 1L
        )

        val opened = RemoteControlSecureEnvelope.open(
            packet = frame,
            receiveKey = sendKey,
            role = RemoteControlSecureEnvelope.Role.RESPONDER,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            allowedPacketTypes = setOf(RemoteControlSecureEnvelope.PacketType.CONTROL)
        )

        assertArrayEquals(plaintext, opened.payload)
        assertEquals(RemoteControlSecureEnvelope.PacketType.CONTROL, opened.packetType)
        assertEquals(1, opened.direction)
        assertEquals(1L, opened.counter)
    }

    @Test
    fun responderScreenFrameRoundTripsForInitiator() {
        val plaintext = "{\"type\":\"screenData\"}".encodeToByteArray()
        val frame = RemoteControlSecureEnvelope.seal(
            plaintext = plaintext,
            sendKey = receiveKey,
            role = RemoteControlSecureEnvelope.Role.RESPONDER,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = RemoteControlSecureEnvelope.PacketType.SCREEN,
            counter = 3L
        )

        val opened = RemoteControlSecureEnvelope.open(
            packet = frame,
            receiveKey = receiveKey,
            role = RemoteControlSecureEnvelope.Role.INITIATOR,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            allowedPacketTypes = setOf(RemoteControlSecureEnvelope.PacketType.SCREEN)
        )

        assertArrayEquals(plaintext, opened.payload)
        assertEquals(RemoteControlSecureEnvelope.PacketType.SCREEN, opened.packetType)
        assertEquals(2, opened.direction)
        assertEquals(3L, opened.counter)
    }

    @Test
    fun directionMismatchIsRejected() {
        val frame = sealControl(counter = 1L)

        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.DirectionMismatch::class.java) {
            RemoteControlSecureEnvelope.open(
                packet = frame,
                receiveKey = sendKey,
                role = RemoteControlSecureEnvelope.Role.INITIATOR,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                allowedPacketTypes = setOf(RemoteControlSecureEnvelope.PacketType.CONTROL)
            )
        }
    }

    @Test
    fun packetTypeMismatchIsRejectedBeforePayloadDecode() {
        val frame = sealControl(counter = 1L)

        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.PacketTypeMismatch::class.java) {
            RemoteControlSecureEnvelope.open(
                packet = frame,
                receiveKey = sendKey,
                role = RemoteControlSecureEnvelope.Role.RESPONDER,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                allowedPacketTypes = setOf(RemoteControlSecureEnvelope.PacketType.SCREEN)
            )
        }
    }

    @Test
    fun sessionMismatchIsRejected() {
        val frame = sealControl(counter = 1L)

        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.SessionMismatch::class.java) {
            RemoteControlSecureEnvelope.open(
                packet = frame,
                receiveKey = sendKey,
                role = RemoteControlSecureEnvelope.Role.RESPONDER,
                sessionId = "$sessionId-wrong",
                transcriptHash = transcriptHash,
                allowedPacketTypes = setOf(RemoteControlSecureEnvelope.PacketType.CONTROL)
            )
        }
    }

    @Test
    fun transcriptMismatchIsRejected() {
        val frame = sealControl(counter = 1L)
        val wrongTranscript = transcriptHash.copyOf().also { it[31] = (it[31].toInt() xor 0x01).toByte() }

        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.TranscriptMismatch::class.java) {
            RemoteControlSecureEnvelope.open(
                packet = frame,
                receiveKey = sendKey,
                role = RemoteControlSecureEnvelope.Role.RESPONDER,
                sessionId = sessionId,
                transcriptHash = wrongTranscript,
                allowedPacketTypes = setOf(RemoteControlSecureEnvelope.PacketType.CONTROL)
            )
        }
    }

    @Test
    fun authenticatedHeaderTamperFailsOpen() {
        val frame = sealControl(counter = 2L)
        val tampered = frame.copyOf()
        tampered[35] = (tampered[35].toInt() xor 0x01).toByte()

        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.AuthenticationFailed::class.java) {
            RemoteControlSecureEnvelope.open(
                packet = tampered,
                receiveKey = sendKey,
                role = RemoteControlSecureEnvelope.Role.RESPONDER,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                allowedPacketTypes = setOf(RemoteControlSecureEnvelope.PacketType.CONTROL)
            )
        }
    }

    @Test
    fun malformedHeaderFieldsAreRejected() {
        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.Malformed::class.java) {
            RemoteControlSecureEnvelope.open(
                packet = ByteArray(20),
                receiveKey = sendKey,
                role = RemoteControlSecureEnvelope.Role.RESPONDER,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                allowedPacketTypes = setOf(RemoteControlSecureEnvelope.PacketType.CONTROL)
            )
        }

        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.UnsupportedMagic::class.java) {
            openBrokenHeader(offset = 0, value = 0)
        }
        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.UnsupportedVersion::class.java) {
            openBrokenHeader(offset = 4, value = 2)
        }
        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.Malformed::class.java) {
            openBrokenHeader(offset = 5, value = 51)
        }
        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.UnsupportedPacketType::class.java) {
            openBrokenHeader(offset = 6, value = 99)
        }

        val badLength = sealControl(counter = 1L)
        badLength[39] = (badLength[39].toInt() + 1).toByte()
        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.Malformed::class.java) {
            openControlAsResponder(badLength)
        }
    }

    @Test
    fun zeroCounterIsRejectedOnSeal() {
        assertThrows(RemoteControlSecureEnvelope.EnvelopeException.InvalidCounter::class.java) {
            RemoteControlSecureEnvelope.seal(
                plaintext = "x".encodeToByteArray(),
                sendKey = sendKey,
                role = RemoteControlSecureEnvelope.Role.INITIATOR,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                packetType = RemoteControlSecureEnvelope.PacketType.CONTROL,
                counter = 0L
            )
        }
    }

    @Test
    fun replayWindowRejectsDuplicateCounters() {
        val window = RemoteControlSecureEnvelope.ReplayWindow()
        val first = openControlAsResponder(sealControl(counter = 1L))
        val replay = openControlAsResponder(sealControl(counter = 1L))

        window.validateAndRecord(first)
        val error = assertThrows(RemoteControlSecureEnvelope.EnvelopeException.ReplayDetected::class.java) {
            window.validateAndRecord(replay)
        }
        assertEquals("duplicate-counter", error.reason)
    }

    @Test
    fun replayWindowKeepsIndependentPacketTypeScopes() {
        val window = RemoteControlSecureEnvelope.ReplayWindow()
        val control = openControlAsResponder(sealControl(counter = 1L))
        val screen = RemoteControlSecureEnvelope.open(
            packet = RemoteControlSecureEnvelope.seal(
                plaintext = "frame".encodeToByteArray(),
                sendKey = receiveKey,
                role = RemoteControlSecureEnvelope.Role.RESPONDER,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                packetType = RemoteControlSecureEnvelope.PacketType.SCREEN,
                counter = 1L
            ),
            receiveKey = receiveKey,
            role = RemoteControlSecureEnvelope.Role.INITIATOR,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            allowedPacketTypes = setOf(RemoteControlSecureEnvelope.PacketType.SCREEN)
        )

        window.validateAndRecord(control)
        window.validateAndRecord(screen)
        assertTrue(screen.counter == control.counter)
    }

    private fun sealControl(counter: Long): ByteArray =
        RemoteControlSecureEnvelope.seal(
            plaintext = "control".encodeToByteArray(),
            sendKey = sendKey,
            role = RemoteControlSecureEnvelope.Role.INITIATOR,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = RemoteControlSecureEnvelope.PacketType.CONTROL,
            counter = counter
        )

    private fun openControlAsResponder(frame: ByteArray): RemoteControlSecureEnvelope.Opened =
        RemoteControlSecureEnvelope.open(
            packet = frame,
            receiveKey = sendKey,
            role = RemoteControlSecureEnvelope.Role.RESPONDER,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            allowedPacketTypes = setOf(RemoteControlSecureEnvelope.PacketType.CONTROL)
        )

    private fun openBrokenHeader(offset: Int, value: Int) {
        val broken = sealControl(counter = 1L)
        broken[offset] = value.toByte()
        openControlAsResponder(broken)
    }

    private fun readU64BE(data: ByteArray, offset: Int): Long {
        var value = 0L
        for (i in 0 until 8) {
            value = (value shl 8) or (data[offset + i].toLong() and 0xFF)
        }
        return value
    }

    private fun readU32BE(data: ByteArray, offset: Int): Long {
        var value = 0L
        for (i in 0 until 4) {
            value = (value shl 8) or (data[offset + i].toLong() and 0xFF)
        }
        return value
    }

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
}
