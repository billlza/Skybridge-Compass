package com.skybridge.compass.remotecontrol.secure

import com.skybridge.compass.shared.p2p.P2PSessionIds
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * SBRC ("SkyBridge-RemoteControl") secure envelope for LAN remote-control frames.
 *
 * This is the Android mirror of Apple
 * `Sources/SkyBridgeCore/RemoteControl/RemoteControlSecureEnvelope.swift`.
 */
object RemoteControlSecureEnvelope {
    enum class PacketType(val raw: Int) {
        CONTROL(1),
        SCREEN(2),
        AUDIO(3);

        companion object {
            fun fromRaw(raw: Int): PacketType? = entries.firstOrNull { it.raw == raw }
        }
    }

    enum class Role { INITIATOR, RESPONDER }

    data class Opened(
        val packetType: PacketType,
        val direction: Int,
        val sessionHash: Long,
        val transcriptPrefix: Long,
        val epoch: Long,
        val counter: Long,
        val payload: ByteArray
    )

    sealed class EnvelopeException(message: String) : Exception(message) {
        class Malformed : EnvelopeException("malformed remote-control secure envelope")
        class UnsupportedMagic(val magic: Long) :
            EnvelopeException("unsupported remote-control secure envelope magic=$magic")
        class UnsupportedVersion(val version: Int) :
            EnvelopeException("unsupported remote-control secure envelope version=$version")
        class UnsupportedPacketType(val raw: Int) :
            EnvelopeException("unsupported remote-control secure envelope packetType=$raw")
        class PacketTypeMismatch(val expected: Set<PacketType>, val actual: PacketType) :
            EnvelopeException(
                "remote-control secure envelope packetType mismatch expected=" +
                    expected.map { it.raw }.sorted().joinToString(",") +
                    " actual=${actual.raw}"
            )
        class DirectionMismatch(val expected: Int, val actual: Int) :
            EnvelopeException("remote-control secure envelope direction mismatch expected=$expected actual=$actual")
        class SessionMismatch(val expected: Long, val actual: Long) :
            EnvelopeException("remote-control secure envelope session mismatch expected=$expected actual=$actual")
        class TranscriptMismatch(val expected: Long, val actual: Long) :
            EnvelopeException("remote-control secure envelope transcript mismatch expected=$expected actual=$actual")
        class EpochMismatch(val expected: Long, val actual: Long) :
            EnvelopeException("remote-control secure envelope epoch mismatch expected=$expected actual=$actual")
        class AuthenticationFailed(val packetType: PacketType, val counter: Long) :
            EnvelopeException(
                "remote-control secure envelope authentication failed packetType=${packetType.raw} counter=$counter"
            )
        class InvalidCounter(val counter: Long) :
            EnvelopeException("remote-control secure envelope invalid counter=$counter")
        class ReplayDetected(
            val packetType: PacketType,
            val counter: Long,
            val highestCounter: Long,
            val reason: String
        ) : EnvelopeException(
            "remote-control secure envelope replay detected packetType=${packetType.raw} " +
                "counter=$counter highestCounter=$highestCounter reason=$reason"
        )
    }

    private const val MAGIC: Long = 0x5342_5243L // "SBRC"
    private const val VERSION: Int = 1
    private const val HEADER_LENGTH: Int = 52
    private const val TAG_LENGTH: Int = 16
    private const val NONCE_LENGTH: Int = 12
    private const val EPOCH: Long = 0L
    private const val DIRECTION_INITIATOR_TO_RESPONDER: Int = 1
    private const val DIRECTION_RESPONDER_TO_INITIATOR: Int = 2
    private const val GCM_TAG_BITS: Int = 128

    const val OVERHEAD_BYTES: Int = HEADER_LENGTH + TAG_LENGTH

    private val rng = SecureRandom()

    fun deterministicSessionId(transcriptHash: ByteArray): String =
        P2PSessionIds.deterministicSessionId(transcriptHash)

    fun seal(
        plaintext: ByteArray,
        sendKey: ByteArray,
        role: Role,
        sessionId: String,
        transcriptHash: ByteArray,
        packetType: PacketType,
        counter: Long
    ): ByteArray {
        require(sendKey.size == 32) { "AES-256 key must be 32 bytes" }
        if (counter <= 0L) throw EnvelopeException.InvalidCounter(counter)
        if (plaintext.size.toLong() > 0xFFFF_FFFFL) throw EnvelopeException.Malformed()

        val nonce = ByteArray(NONCE_LENGTH).also { rng.nextBytes(it) }
        val header = ByteArray(HEADER_LENGTH)
        putUInt32(header, 0, MAGIC)
        header[4] = VERSION.toByte()
        header[5] = HEADER_LENGTH.toByte()
        header[6] = packetType.raw.toByte()
        header[7] = sendDirection(role).toByte()
        putUInt64(header, 8, sessionIdHash(sessionId))
        putUInt64(header, 16, transcriptPrefix(transcriptHash))
        putUInt32(header, 24, EPOCH)
        putUInt64(header, 28, counter)
        putUInt32(header, 36, plaintext.size.toLong())
        System.arraycopy(nonce, 0, header, 40, NONCE_LENGTH)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(sendKey, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(header)
        val ciphertextAndTag = cipher.doFinal(plaintext)

        return header + ciphertextAndTag
    }

    fun open(
        packet: ByteArray,
        receiveKey: ByteArray,
        role: Role,
        sessionId: String,
        transcriptHash: ByteArray,
        allowedPacketTypes: Set<PacketType>
    ): Opened {
        require(receiveKey.size == 32) { "AES-256 key must be 32 bytes" }
        val parsed = parseHeader(packet)

        if (!allowedPacketTypes.contains(parsed.packetType)) {
            throw EnvelopeException.PacketTypeMismatch(allowedPacketTypes, parsed.packetType)
        }
        val expectedDirection = receiveDirection(role)
        if (parsed.direction != expectedDirection) {
            throw EnvelopeException.DirectionMismatch(expectedDirection, parsed.direction)
        }
        val expectedSessionHash = sessionIdHash(sessionId)
        if (parsed.sessionHash != expectedSessionHash) {
            throw EnvelopeException.SessionMismatch(expectedSessionHash, parsed.sessionHash)
        }
        val expectedTranscriptPrefix = transcriptPrefix(transcriptHash)
        if (parsed.transcriptPrefix != expectedTranscriptPrefix) {
            throw EnvelopeException.TranscriptMismatch(expectedTranscriptPrefix, parsed.transcriptPrefix)
        }
        if (parsed.epoch != EPOCH) {
            throw EnvelopeException.EpochMismatch(EPOCH, parsed.epoch)
        }
        if (parsed.counter <= 0L) {
            throw EnvelopeException.InvalidCounter(parsed.counter)
        }

        val ciphertextStart = HEADER_LENGTH
        val ciphertextEnd = ciphertextStart + parsed.payloadLength
        val nonce = packet.copyOfRange(40, 52)
        val ciphertextAndTag = packet.copyOfRange(ciphertextStart, ciphertextEnd + TAG_LENGTH)
        val payload = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(receiveKey, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
            cipher.updateAAD(packet.copyOfRange(0, HEADER_LENGTH))
            cipher.doFinal(ciphertextAndTag)
        } catch (t: Throwable) {
            throw EnvelopeException.AuthenticationFailed(parsed.packetType, parsed.counter)
        }

        return Opened(
            packetType = parsed.packetType,
            direction = parsed.direction,
            sessionHash = parsed.sessionHash,
            transcriptPrefix = parsed.transcriptPrefix,
            epoch = parsed.epoch,
            counter = parsed.counter,
            payload = payload
        )
    }

    private data class ParsedHeader(
        val packetType: PacketType,
        val direction: Int,
        val sessionHash: Long,
        val transcriptPrefix: Long,
        val epoch: Long,
        val counter: Long,
        val payloadLength: Int
    )

    private fun parseHeader(packet: ByteArray): ParsedHeader {
        if (packet.size < HEADER_LENGTH + TAG_LENGTH) throw EnvelopeException.Malformed()

        val magic = readUInt32(packet, 0)
        if (magic != MAGIC) throw EnvelopeException.UnsupportedMagic(magic)

        val version = packet[4].toInt() and 0xFF
        if (version != VERSION) throw EnvelopeException.UnsupportedVersion(version)

        val encodedHeaderLength = packet[5].toInt() and 0xFF
        if (encodedHeaderLength != HEADER_LENGTH) throw EnvelopeException.Malformed()

        val packetTypeRaw = packet[6].toInt() and 0xFF
        val packetType = PacketType.fromRaw(packetTypeRaw)
            ?: throw EnvelopeException.UnsupportedPacketType(packetTypeRaw)

        val payloadLength = readUInt32(packet, 36)
        if (packet.size.toLong() != HEADER_LENGTH.toLong() + payloadLength + TAG_LENGTH.toLong()) {
            throw EnvelopeException.Malformed()
        }

        return ParsedHeader(
            packetType = packetType,
            direction = packet[7].toInt() and 0xFF,
            sessionHash = readUInt64(packet, 8),
            transcriptPrefix = readUInt64(packet, 16),
            epoch = readUInt32(packet, 24),
            counter = readUInt64(packet, 28),
            payloadLength = payloadLength.toInt()
        )
    }

    class ReplayWindow {
        private data class Scope(
            val packetType: PacketType,
            val direction: Int,
            val sessionHash: Long,
            val transcriptPrefix: Long,
            val epoch: Long
        )

        private class Lane {
            var highestCounter: Long = 0L
            val recordedCounters: MutableSet<Long> = HashSet()
        }

        private val lanes = HashMap<Scope, Lane>()

        fun validateAndRecord(opened: Opened) {
            if (opened.counter <= 0L) throw EnvelopeException.InvalidCounter(opened.counter)

            val scope = Scope(
                packetType = opened.packetType,
                direction = opened.direction,
                sessionHash = opened.sessionHash,
                transcriptPrefix = opened.transcriptPrefix,
                epoch = opened.epoch
            )
            val lane = lanes.getOrPut(scope) { Lane() }
            val highest = lane.highestCounter

            if (opened.counter > highest) {
                lane.highestCounter = opened.counter
                lane.recordedCounters.add(opened.counter)
                prune(lane)
                return
            }

            val distance = highest - opened.counter
            if (distance >= WINDOW_SIZE) {
                throw EnvelopeException.ReplayDetected(
                    opened.packetType,
                    opened.counter,
                    highest,
                    "counter-outside-window"
                )
            }
            if (lane.recordedCounters.contains(opened.counter)) {
                throw EnvelopeException.ReplayDetected(
                    opened.packetType,
                    opened.counter,
                    highest,
                    "duplicate-counter"
                )
            }
            lane.recordedCounters.add(opened.counter)
        }

        private fun prune(lane: Lane) {
            val minimumCounterToKeep = if (lane.highestCounter > WINDOW_SIZE) {
                lane.highestCounter - WINDOW_SIZE + 1
            } else {
                1L
            }
            lane.recordedCounters.removeAll { it < minimumCounterToKeep }
        }

        private companion object {
            private const val WINDOW_SIZE: Long = 1024L
        }
    }

    private fun sendDirection(role: Role): Int =
        if (role == Role.INITIATOR) DIRECTION_INITIATOR_TO_RESPONDER else DIRECTION_RESPONDER_TO_INITIATOR

    private fun receiveDirection(role: Role): Int =
        if (role == Role.INITIATOR) DIRECTION_RESPONDER_TO_INITIATOR else DIRECTION_INITIATOR_TO_RESPONDER

    private fun sessionIdHash(sessionId: String): Long {
        val input = "SkyBridge-RemoteControl-Session-v1|".toByteArray(Charsets.UTF_8) +
            sessionId.toByteArray(Charsets.UTF_8)
        return firstUInt64(sha256(input))
    }

    private fun transcriptPrefix(transcriptHash: ByteArray): Long {
        val input = "SkyBridge-RemoteControl-Transcript-v1|".toByteArray(Charsets.UTF_8) + transcriptHash
        return firstUInt64(sha256(input))
    }

    private fun firstUInt64(digest: ByteArray): Long {
        var value = 0L
        for (i in 0 until 8) {
            value = (value shl 8) or (digest[i].toLong() and 0xFF)
        }
        return value
    }

    private fun sha256(data: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(data)

    private fun putUInt32(out: ByteArray, offset: Int, value: Long) {
        out[offset] = ((value ushr 24) and 0xFF).toByte()
        out[offset + 1] = ((value ushr 16) and 0xFF).toByte()
        out[offset + 2] = ((value ushr 8) and 0xFF).toByte()
        out[offset + 3] = (value and 0xFF).toByte()
    }

    private fun putUInt64(out: ByteArray, offset: Int, value: Long) {
        var shift = 56
        var index = 0
        while (shift >= 0) {
            out[offset + index] = ((value ushr shift) and 0xFF).toByte()
            shift -= 8
            index += 1
        }
    }

    private fun readUInt32(data: ByteArray, offset: Int): Long {
        return ((data[offset].toLong() and 0xFF) shl 24) or
            ((data[offset + 1].toLong() and 0xFF) shl 16) or
            ((data[offset + 2].toLong() and 0xFF) shl 8) or
            (data[offset + 3].toLong() and 0xFF)
    }

    private fun readUInt64(data: ByteArray, offset: Int): Long {
        var value = 0L
        for (i in 0 until 8) {
            value = (value shl 8) or (data[offset + i].toLong() and 0xFF)
        }
        return value
    }
}
