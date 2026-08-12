package com.skybridge.compass.core.filetransfer

import com.skybridge.compass.shared.p2p.filetransfer.Base64ByteArraySerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Pro-release compatible LAN file transfer protocol used by macOS/iOS FileTransferManager:
 * - Service: _skybridge-xfer._tcp (default port 8080)
 * - Frame: 8B header (u32 type BE + u32 len BE) + JSON payload (Swift JSONEncoder/Codable)
 * - MessageType: metadata=1, chunk=2, complete=3, receipt=4
 *
 * Compatibility notes:
 * - Swift Data in JSON is base64 strings; kotlinx.serialization encodes ByteArray as base64 in JSON too.
 * - compression: "zlib" (optional). When present, FileChunk.data is compressed bytes and FileChunk.size is the
 *   original (uncompressed) byte length.
 */
object MacLanFileTransferProtocol {
    const val DEFAULT_PORT: Int = 8080
    const val MAX_MESSAGE_BYTES: Int = 2_000_000

    @Serializable
    data class FileMetadata(
        val transferId: String,
        val fileName: String,
        val fileSize: Long,
        val fileHash: String,
        val chunkSize: Int,
        val compression: String? = null,
        val senderDeviceId: String? = null,
        val senderDeviceName: String? = null,
        val senderPlatform: String? = null,
        val senderOSVersion: String? = null,
        val senderModelName: String? = null,
        val senderChip: String? = null
    )

    @Serializable
    data class FileChunk(
        val index: Int,
        @Serializable(with = Base64ByteArraySerializer::class)
        val data: ByteArray,
        val size: Int
    )

    @Serializable
    data class FileTransferReceipt(
        val transferId: String,
        val success: Boolean,
        val receivedBytes: Long,
        val fileHash: String? = null,
        val error: String? = null
    )

    enum class MessageType(val raw: Int) {
        METADATA(1),
        CHUNK(2),
        COMPLETE(3),
        RECEIPT(4);
    }

    val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    fun writeHeader(type: MessageType, length: Int): ByteArray {
        val buf = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN)
        buf.putInt(type.raw)
        buf.putInt(length)
        return buf.array()
    }

    fun readHeader(bytes8: ByteArray): Pair<MessageType, Int> {
        require(bytes8.size == 8) { "header must be 8 bytes" }
        val bb = ByteBuffer.wrap(bytes8).order(ByteOrder.BIG_ENDIAN)
        val type = bb.int
        val len = bb.int
        val mt = MessageType.values().firstOrNull { it.raw == type } ?: error("unknown message type $type")
        return mt to len
    }

    fun readExactly(input: InputStream, out: ByteArray): Boolean {
        var off = 0
        while (off < out.size) {
            val r = input.read(out, off, out.size - off)
            if (r < 0) return false
            off += r
        }
        return true
    }

    fun writeAll(output: OutputStream, bytes: ByteArray) {
        output.write(bytes)
        output.flush()
    }
}
