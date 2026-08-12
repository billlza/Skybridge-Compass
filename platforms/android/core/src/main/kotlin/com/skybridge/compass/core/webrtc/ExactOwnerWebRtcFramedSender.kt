package com.skybridge.compass.core.webrtc

/**
 * Serializes framed writes for one exact product-session owner.
 *
 * A DataChannel is an ordered byte stream for this framing layer. Once any chunk of a frame has
 * been accepted, failure of a later chunk makes that stream unrecoverable: the receiver cannot
 * distinguish a future frame from the missing suffix. The exact owner is therefore terminalized
 * after partial progress. A rejection before the first accepted chunk leaves the stream aligned.
 */
internal class ExactOwnerWebRtcFramedSender<Owner>(
    private val runIfCurrentOwner: (Owner, () -> Unit) -> Boolean,
    private val sendChunk: (Owner, ByteArray) -> Boolean,
    private val terminatePartiallyWrittenOwner: (Owner, String) -> Unit,
) {
    private sealed interface SendOutcome {
        data object Sent : SendOutcome
        data class Rejected(
            val acceptedChunks: Int,
            val errorType: String? = null,
        ) : SendOutcome
    }

    private val sendLock = Any()

    fun send(owner: Owner, payload: ByteArray): Boolean {
        return synchronized(sendLock) {
            var outcome: SendOutcome? = null
            val current = runIfCurrentOwner(owner) {
                outcome = sendWhileCurrent(owner, payload)
            }
            if (!current) return@synchronized false
            when (val resolved = requireNotNull(outcome)) {
                SendOutcome.Sent -> true
                is SendOutcome.Rejected -> {
                    if (resolved.acceptedChunks > 0) {
                        val detail = buildString {
                            append("partial framed send rejected after ")
                            append(resolved.acceptedChunks)
                            append(" accepted chunk(s)")
                            resolved.errorType?.let { append(" ($it)") }
                        }
                        // Keep the sender serialization lock held through exact-owner
                        // terminalization so no waiting send can append bytes to the broken stream.
                        terminatePartiallyWrittenOwner(owner, detail)
                    }
                    false
                }
            }
        }
    }

    private fun sendWhileCurrent(owner: Owner, payload: ByteArray): SendOutcome {
        val framed = WebRtcDataChannelFraming.encode(payload)
        var offset = 0
        var acceptedChunks = 0
        while (offset < framed.size) {
            val end = minOf(offset + WebRtcDataChannelFraming.MAXIMUM_CHUNK_BYTES, framed.size)
            val chunk = framed.copyOfRange(offset, end)
            val accepted = try {
                sendChunk(owner, chunk)
            } catch (error: Exception) {
                return SendOutcome.Rejected(
                    acceptedChunks = acceptedChunks,
                    errorType = error.javaClass.simpleName,
                )
            }
            if (!accepted) {
                return SendOutcome.Rejected(acceptedChunks)
            }
            acceptedChunks += 1
            offset = end
        }
        return SendOutcome.Sent
    }
}
