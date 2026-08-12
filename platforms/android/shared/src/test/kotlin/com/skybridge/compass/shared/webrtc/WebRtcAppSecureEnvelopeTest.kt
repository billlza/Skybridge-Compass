package com.skybridge.compass.shared.webrtc

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * JUnit 5 (Jupiter) tests for the SBWC application-secure envelope.
 *
 * IMPORTANT: the shared module runs `useJUnitPlatform()` (Jupiter engine ONLY). These tests use
 * `org.junit.jupiter.api.*` so the engine actually executes them. The legacy `org.junit.Test`
 * (JUnit 4) tests in this module compile but are NOT run, since no junit-vintage-engine is on the
 * runtime classpath — that is why this file is written for Jupiter.
 *
 * Validates byte-for-byte interop with the macOS canon
 *   Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCAppSecureEnvelope.swift
 */
class WebRtcAppSecureEnvelopeTest {

    // Deterministic 32-byte keys / transcript so the KATs are reproducible.
    private val sendKey = ByteArray(32) { it.toByte() }            // 0x00..0x1f
    private val recvKey = ByteArray(32) { (it + 100).toByte() }    // distinct
    private val transcriptHash = ByteArray(32) { it.toByte() }     // 0x00..0x1f

    private val initiatorRole = WebRtcAppSecureEnvelope.Role.INITIATOR
    private val responderRole = WebRtcAppSecureEnvelope.Role.RESPONDER

    /**
     * The Mac derives sessionId from transcriptHash (SessionKeys is created with sessionId=nil,
     * falling back to deterministicSessionId). KAT computed independently from the Swift formula:
     *   "hs-" + first16Bytes(SHA256("SkyBridge-SessionId-v1|" + transcriptHash)).hex
     */
    private val sessionId = WebRtcAppSecureEnvelope.deterministicSessionId(transcriptHash)

    @Test
    fun sessionIdDerivationMatchesSwiftFormula() {
        // KAT for transcriptHash = 0x00..0x1f, reproducing SessionKeys.deterministicSessionId.
        assertEquals("hs-8269a6bb6b69f0a4c744d41d11c48ed3", sessionId)
    }

    @Test
    fun sessionHashAndTranscriptPrefixMatchSwiftFormula() {
        // Seal a frame and read the header fields back to confirm the on-wire sessionHash and
        // transcriptPrefix match the KATs computed from the Swift first-8-byte big-endian fold.
        val frame = WebRtcAppSecureEnvelope.seal(
            plaintext = "x".toByteArray(),
            sendKey = sendKey,
            role = initiatorRole,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL,
            counter = 1L
        )
        val sessionHash = readU64BE(frame, 8)
        val transcriptPrefix = readU64BE(frame, 16)
        assertEquals(4514973782079501206L, sessionHash, "sessionHash KAT mismatch")
        assertEquals(3713746137790658733L, transcriptPrefix, "transcriptPrefix KAT mismatch")
    }

    @Test
    fun headerByteLayoutMatchesCanon() {
        val plaintext = "hello-sbwc".toByteArray()
        val frame = WebRtcAppSecureEnvelope.seal(
            plaintext = plaintext,
            sendKey = sendKey,
            role = initiatorRole,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER,
            counter = 7L
        )

        // 52-byte header + ciphertext(=plaintext.size for GCM) + 16-byte tag.
        assertEquals(52 + plaintext.size + 16, frame.size)

        // magic 0x53425743 "SBWC" big-endian at offset 0
        assertEquals(0x53, frame[0].toInt() and 0xFF)
        assertEquals(0x42, frame[1].toInt() and 0xFF)
        assertEquals(0x57, frame[2].toInt() and 0xFF)
        assertEquals(0x43, frame[3].toInt() and 0xFF)
        assertEquals(1, frame[4].toInt() and 0xFF)               // version
        assertEquals(52, frame[5].toInt() and 0xFF)              // headerLength
        assertEquals(2, frame[6].toInt() and 0xFF)               // packetType = FILE_TRANSFER
        assertEquals(1, frame[7].toInt() and 0xFF)               // direction = initiator->responder
        assertEquals(0L, readU32BE(frame, 24))                   // epoch
        assertEquals(7L, readU64BE(frame, 28))                   // counter
        assertEquals(plaintext.size.toLong(), readU32BE(frame, 36)) // payloadLength
    }

    @Test
    fun sealThenOpenRoundTrips() {
        val plaintext = "pairing-identity-exchange-payload".toByteArray()
        val frame = WebRtcAppSecureEnvelope.seal(
            plaintext = plaintext,
            sendKey = sendKey,
            role = initiatorRole,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL,
            counter = 1L
        )

        // The responder receives an initiator->responder frame and decrypts with its recvKey,
        // which equals the initiator's sendKey for that direction.
        val opened = WebRtcAppSecureEnvelope.open(
            packet = frame,
            recvKey = sendKey,
            role = responderRole,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            allowedPacketTypes = WebRtcAppSecureEnvelope.PacketType.entries.toSet()
        )
        assertArrayEquals(plaintext, opened.payload)
        assertEquals(WebRtcAppSecureEnvelope.PacketType.APP_CONTROL, opened.packetType)
        assertEquals(1, opened.direction)
        assertEquals(1L, opened.counter)
    }

    @Test
    fun tamperingAnyHeaderByteFailsOpen() {
        val plaintext = "mouse-event".toByteArray()
        val frame = WebRtcAppSecureEnvelope.seal(
            plaintext = plaintext,
            sendKey = sendKey,
            role = initiatorRole,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = WebRtcAppSecureEnvelope.PacketType.REMOTE_CONTROL,
            counter = 2L
        )

        // Flip the counter LSB (offset 35) from 0x02 -> 0x03: still a valid nonzero counter (so no
        // early field-mismatch / InvalidCounter throw), but it mutates the header bytes that are fed
        // verbatim as the AES-GCM AAD. The only thing that can reject it is the GCM tag failing to
        // authenticate the changed AAD, proving the full header is the AAD.
        val tampered = frame.copyOf()
        tampered[35] = (tampered[35].toInt() xor 0x01).toByte()

        assertThrows(WebRtcAppSecureEnvelope.EnvelopeException.AuthenticationFailed::class.java) {
            WebRtcAppSecureEnvelope.open(
                packet = tampered,
                recvKey = sendKey,
                role = responderRole,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                allowedPacketTypes = WebRtcAppSecureEnvelope.PacketType.entries.toSet()
            )
        }
    }

    @Test
    fun wrongRecvKeyFailsOpen() {
        val frame = WebRtcAppSecureEnvelope.seal(
            plaintext = "clipboard".toByteArray(),
            sendKey = sendKey,
            role = initiatorRole,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL,
            counter = 1L
        )
        assertThrows(WebRtcAppSecureEnvelope.EnvelopeException.AuthenticationFailed::class.java) {
            WebRtcAppSecureEnvelope.open(
                packet = frame,
                recvKey = recvKey, // wrong key
                role = responderRole,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                allowedPacketTypes = WebRtcAppSecureEnvelope.PacketType.entries.toSet()
            )
        }
    }

    @Test
    fun replayedCounterIsRejected() {
        val window = WebRtcAppSecureEnvelope.ReplayWindow()

        fun openSealed(counter: Long): WebRtcAppSecureEnvelope.Opened {
            val frame = WebRtcAppSecureEnvelope.seal(
                plaintext = "f".toByteArray(),
                sendKey = sendKey,
                role = initiatorRole,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                packetType = WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER,
                counter = counter
            )
            return WebRtcAppSecureEnvelope.open(
                packet = frame,
                recvKey = sendKey,
                role = responderRole,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                allowedPacketTypes = WebRtcAppSecureEnvelope.PacketType.entries.toSet()
            )
        }

        val first = openSealed(1L)
        window.validateAndRecord(first) // accepted

        val replay = openSealed(1L) // same counter again
        val ex = assertThrows(WebRtcAppSecureEnvelope.EnvelopeException.ReplayDetected::class.java) {
            window.validateAndRecord(replay)
        }
        assertEquals("duplicate-counter", ex.reason)

        // A higher counter still advances the window.
        window.validateAndRecord(openSealed(2L))
    }

    @Test
    fun directionMismatchIsRejected() {
        // initiator->responder frame, but the receiver also claims to be the initiator: the Mac
        // (and this port) reject on direction before touching the ciphertext.
        val frame = WebRtcAppSecureEnvelope.seal(
            plaintext = "x".toByteArray(),
            sendKey = sendKey,
            role = initiatorRole,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL,
            counter = 1L
        )
        assertThrows(WebRtcAppSecureEnvelope.EnvelopeException.DirectionMismatch::class.java) {
            WebRtcAppSecureEnvelope.open(
                packet = frame,
                recvKey = sendKey,
                role = initiatorRole, // wrong: would expect responder->initiator
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                allowedPacketTypes = WebRtcAppSecureEnvelope.PacketType.entries.toSet()
            )
        }
    }

    @Test
    fun packetTypeNotAllowedIsRejected() {
        val frame = WebRtcAppSecureEnvelope.seal(
            plaintext = "x".toByteArray(),
            sendKey = sendKey,
            role = initiatorRole,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = WebRtcAppSecureEnvelope.PacketType.REMOTE_DESKTOP,
            counter = 1L
        )
        assertThrows(WebRtcAppSecureEnvelope.EnvelopeException.PacketTypeMismatch::class.java) {
            WebRtcAppSecureEnvelope.open(
                packet = frame,
                recvKey = sendKey,
                role = responderRole,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                allowedPacketTypes = setOf(WebRtcAppSecureEnvelope.PacketType.APP_CONTROL)
            )
        }
    }

    @Test
    fun zeroCounterIsRejectedOnSeal() {
        assertThrows(WebRtcAppSecureEnvelope.EnvelopeException.InvalidCounter::class.java) {
            WebRtcAppSecureEnvelope.seal(
                plaintext = "x".toByteArray(),
                sendKey = sendKey,
                role = initiatorRole,
                sessionId = sessionId,
                transcriptHash = transcriptHash,
                packetType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL,
                counter = 0L
            )
        }
    }

    @Test
    fun differentNonceEachSeal() {
        val a = WebRtcAppSecureEnvelope.seal(
            "x".toByteArray(), sendKey, initiatorRole, sessionId, transcriptHash,
            WebRtcAppSecureEnvelope.PacketType.APP_CONTROL, 1L
        )
        val b = WebRtcAppSecureEnvelope.seal(
            "x".toByteArray(), sendKey, initiatorRole, sessionId, transcriptHash,
            WebRtcAppSecureEnvelope.PacketType.APP_CONTROL, 2L
        )
        val nonceA = a.copyOfRange(40, 52)
        val nonceB = b.copyOfRange(40, 52)
        assertEquals(12, nonceA.size)
        assertNotEquals(nonceA.toList(), nonceB.toList())
    }

    @Test
    fun unsupportedMagicIsRejected() {
        val frame = WebRtcAppSecureEnvelope.seal(
            "x".toByteArray(), sendKey, initiatorRole, sessionId, transcriptHash,
            WebRtcAppSecureEnvelope.PacketType.APP_CONTROL, 1L
        )
        val broken = frame.copyOf()
        broken[0] = 0x00
        val ex = assertThrows(WebRtcAppSecureEnvelope.EnvelopeException.UnsupportedMagic::class.java) {
            WebRtcAppSecureEnvelope.open(
                broken, sendKey, responderRole, sessionId, transcriptHash,
                WebRtcAppSecureEnvelope.PacketType.entries.toSet()
            )
        }
        assertTrue(ex.magic != 0x53425743L)
    }

    private fun readU64BE(data: ByteArray, offset: Int): Long {
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (data[offset + i].toLong() and 0xFF)
        return v
    }

    private fun readU32BE(data: ByteArray, offset: Int): Long {
        var v = 0L
        for (i in 0 until 4) v = (v shl 8) or (data[offset + i].toLong() and 0xFF)
        return v
    }
}
