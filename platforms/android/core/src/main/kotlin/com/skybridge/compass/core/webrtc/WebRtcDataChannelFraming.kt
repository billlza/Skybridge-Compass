package com.skybridge.compass.core.webrtc

import java.nio.ByteBuffer

/**
 * Canonical framing boundary for the WebRTC data channel.
 *
 * Data-channel messages are untrusted network input. Admission therefore happens before copying
 * a transport chunk, and a payload buffer is allocated only after its complete length prefix has
 * passed the frame-size contract. The decoder supports fragmented frames and multiple frames in a
 * chunk without an expanding aggregate buffer.
 */
internal object WebRtcDataChannelFraming {
    const val LENGTH_PREFIX_BYTES = 4
    const val MAXIMUM_FRAME_BYTES = 8_000_000
    const val MAXIMUM_CHUNK_BYTES = 16 * 1024

    fun copyAdmittedChunk(source: ByteBuffer): ByteArray {
        val length = source.remaining()
        if (length !in 1..MAXIMUM_CHUNK_BYTES) {
            throw WebRtcDataChannelProtocolException("invalid transport chunk length")
        }
        return ByteArray(length).also(source::get)
    }

    fun encode(payload: ByteArray): ByteArray {
        if (payload.size !in 1..MAXIMUM_FRAME_BYTES) {
            throw WebRtcDataChannelProtocolException("invalid outbound frame length")
        }
        val framed = ByteArray(LENGTH_PREFIX_BYTES + payload.size)
        framed[0] = (payload.size ushr 24).toByte()
        framed[1] = (payload.size ushr 16).toByte()
        framed[2] = (payload.size ushr 8).toByte()
        framed[3] = payload.size.toByte()
        System.arraycopy(payload, 0, framed, LENGTH_PREFIX_BYTES, payload.size)
        return framed
    }

    internal class Decoder(
        private val maximumFrameBytes: Int = MAXIMUM_FRAME_BYTES,
        private val maximumChunkBytes: Int = MAXIMUM_CHUNK_BYTES
    ) {
        private val header = ByteArray(LENGTH_PREFIX_BYTES)
        private var headerBytes = 0
        private var payload: ByteArray? = null
        private var payloadBytes = 0

        init {
            require(maximumFrameBytes > 0) { "maximum frame size must be positive" }
            require(maximumChunkBytes >= LENGTH_PREFIX_BYTES) {
                "maximum data-channel chunk must hold a length prefix"
            }
        }

        fun reset() {
            headerBytes = 0
            payload = null
            payloadBytes = 0
        }

        fun push(chunk: ByteArray): List<ByteArray> {
            if (chunk.size !in 1..maximumChunkBytes) {
                reset()
                throw WebRtcDataChannelProtocolException("invalid transport chunk length")
            }

            val frames = ArrayList<ByteArray>()
            var chunkOffset = 0
            while (chunkOffset < chunk.size) {
                if (payload == null) {
                    val headerCopyBytes = minOf(
                        LENGTH_PREFIX_BYTES - headerBytes,
                        chunk.size - chunkOffset
                    )
                    System.arraycopy(chunk, chunkOffset, header, headerBytes, headerCopyBytes)
                    headerBytes += headerCopyBytes
                    chunkOffset += headerCopyBytes
                    if (headerBytes < LENGTH_PREFIX_BYTES) continue

                    val length = decodeLength(header)
                    if (length !in 1..maximumFrameBytes) {
                        reset()
                        throw WebRtcDataChannelProtocolException("invalid inbound frame length")
                    }
                    payload = ByteArray(length)
                    payloadBytes = 0
                    headerBytes = 0
                }

                val currentPayload = checkNotNull(payload)
                val payloadCopyBytes = minOf(
                    currentPayload.size - payloadBytes,
                    chunk.size - chunkOffset
                )
                System.arraycopy(chunk, chunkOffset, currentPayload, payloadBytes, payloadCopyBytes)
                payloadBytes += payloadCopyBytes
                chunkOffset += payloadCopyBytes
                if (payloadBytes == currentPayload.size) {
                    frames += currentPayload
                    payload = null
                    payloadBytes = 0
                }
            }
            return frames
        }

        private fun decodeLength(bytes: ByteArray): Int {
            val decoded =
                ((bytes[0].toLong() and 0xFF) shl 24) or
                    ((bytes[1].toLong() and 0xFF) shl 16) or
                    ((bytes[2].toLong() and 0xFF) shl 8) or
                    (bytes[3].toLong() and 0xFF)
            return if (decoded <= Int.MAX_VALUE) decoded.toInt() else -1
        }
    }
}

internal class WebRtcDataChannelProtocolException(message: String) : IllegalArgumentException(message)
