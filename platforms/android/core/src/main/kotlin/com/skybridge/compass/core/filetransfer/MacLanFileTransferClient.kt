package com.skybridge.compass.core.filetransfer

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID

class MacLanFileTransferClient(
    private val socketFactory: SocketFactory = DefaultSocketFactory
) {
    fun interface SocketFactory {
        fun connect(host: String, port: Int, connectTimeoutMillis: Int, readTimeoutMillis: Int): Socket
    }

    data class SendRequest(
        val host: String,
        val port: Int,
        val fileName: String,
        val fileSize: Long,
        val openInputStream: () -> InputStream,
        val senderDeviceId: String? = null,
        val senderDeviceName: String? = null,
        val senderPlatform: String = "android",
        val senderOSVersion: String? = null,
        val senderModelName: String? = null,
        val chunkSize: Int = DEFAULT_CHUNK_BYTES,
        val connectTimeoutMillis: Int = DEFAULT_CONNECT_TIMEOUT_MS,
        val readTimeoutMillis: Int = DEFAULT_READ_TIMEOUT_MS,
        /**
         * Kotlin-side progress callback (NOT a wire-protocol field). Invoked with a byte-accurate,
         * monotonically non-decreasing [LanTransferProgress] after each chunk is written and once
         * the peer receipt is validated (100%). No placeholder or estimated values are emitted.
         */
        val onProgress: ((LanTransferProgress) -> Unit)? = null
    )

    data class SendResult(
        val transferId: String,
        val bytesSent: Long,
        val fileSha256: String
    )

    class LanFileTransferException(message: String, cause: Throwable? = null) :
        IllegalStateException(message, cause)

    suspend fun sendFile(request: SendRequest): SendResult = withContext(Dispatchers.IO) {
        validateRequest(request)
        val transferId = UUID.randomUUID().toString()
        val fileHash = request.openInputStream().use(::sha256Hex)

        socketFactory.connect(
            host = request.host.trim(),
            port = request.port,
            connectTimeoutMillis = request.connectTimeoutMillis,
            readTimeoutMillis = request.readTimeoutMillis
        ).use { socket ->
            val input = socket.getInputStream()
            val output = socket.getOutputStream()

            val metadata = MacLanFileTransferProtocol.FileMetadata(
                transferId = transferId,
                fileName = request.fileName.trim(),
                fileSize = request.fileSize,
                fileHash = fileHash,
                chunkSize = request.chunkSize,
                senderDeviceId = request.senderDeviceId?.trim()?.takeIf { it.isNotEmpty() },
                senderDeviceName = request.senderDeviceName?.trim()?.takeIf { it.isNotEmpty() },
                senderPlatform = request.senderPlatform.trim().ifBlank { "android" },
                senderOSVersion = request.senderOSVersion?.trim()?.takeIf { it.isNotEmpty() },
                senderModelName = request.senderModelName?.trim()?.takeIf { it.isNotEmpty() }
            )
            writeFrame(
                type = MacLanFileTransferProtocol.MessageType.METADATA,
                payload = MacLanFileTransferProtocol.json.encodeToString(metadata).encodeToByteArray(),
                output = output
            )

            val progressTracker = MonotonicLanProgressTracker(request.fileSize)
            request.onProgress?.invoke(progressTracker.snapshot())

            var sentBytes = 0L
            val buffer = ByteArray(request.chunkSize)
            request.openInputStream().use { stream ->
                var chunkIndex = 0
                while (sentBytes < request.fileSize) {
                    val expected = minOf(buffer.size.toLong(), request.fileSize - sentBytes).toInt()
                    val bytesRead = stream.readAtMost(buffer, expected)
                    if (bytesRead <= 0) {
                        throw LanFileTransferException("source stream ended before advertised file size")
                    }
                    val chunkBytes = buffer.copyOf(bytesRead)
                    val chunk = MacLanFileTransferProtocol.FileChunk(
                        index = chunkIndex,
                        data = chunkBytes,
                        size = bytesRead
                    )
                    writeFrame(
                        type = MacLanFileTransferProtocol.MessageType.CHUNK,
                        payload = MacLanFileTransferProtocol.json.encodeToString(chunk).encodeToByteArray(),
                        output = output
                    )
                    sentBytes += bytesRead
                    chunkIndex += 1
                    // Report progress by actually-written bytes; monotonic, never a placeholder.
                    request.onProgress?.invoke(progressTracker.update(sentBytes))
                }
            }

            writeFrame(
                type = MacLanFileTransferProtocol.MessageType.COMPLETE,
                payload = ByteArray(0),
                output = output
            )

            val receiptPayload = readFrame(
                input = input,
                expectedType = MacLanFileTransferProtocol.MessageType.RECEIPT
            )
            val receipt = MacLanFileTransferProtocol.json.decodeFromString(
                MacLanFileTransferProtocol.FileTransferReceipt.serializer(),
                receiptPayload.decodeToString()
            )
            validateReceipt(
                receipt = receipt,
                transferId = transferId,
                expectedBytes = request.fileSize,
                expectedHash = fileHash
            )

            // Peer receipt validated: the transfer is confirmed delivered, so progress is 100%.
            request.onProgress?.invoke(progressTracker.complete())

            SendResult(
                transferId = transferId,
                bytesSent = sentBytes,
                fileSha256 = fileHash
            )
        }
    }

    private fun validateRequest(request: SendRequest) {
        validateHost(request.host)
        require(request.port in 1..65535) { "LAN file transfer port is out of range" }
        require(request.fileName.trim().isNotEmpty()) { "LAN file transfer fileName is empty" }
        require(request.fileName.none { it == '/' || it == '\\' || it.code < 0x20 }) {
            "LAN file transfer fileName is unsafe"
        }
        require(request.fileSize >= 0) { "LAN file transfer fileSize is negative" }
        require(request.chunkSize in 1..DEFAULT_CHUNK_BYTES) {
            "LAN file transfer chunkSize is out of range"
        }
        require(request.connectTimeoutMillis in 1..60_000) {
            "LAN file transfer connect timeout is out of range"
        }
        require(request.readTimeoutMillis in 1..120_000) {
            "LAN file transfer read timeout is out of range"
        }
    }

    private fun validateReceipt(
        receipt: MacLanFileTransferProtocol.FileTransferReceipt,
        transferId: String,
        expectedBytes: Long,
        expectedHash: String
    ) {
        if (receipt.transferId != transferId) {
            throw LanFileTransferException("receiver receipt transfer id mismatch")
        }
        if (!receipt.success) {
            throw LanFileTransferException("receiver rejected LAN file transfer")
        }
        if (receipt.receivedBytes != expectedBytes) {
            throw LanFileTransferException("receiver byte count mismatch")
        }
        if (!receipt.fileHash.equals(expectedHash, ignoreCase = true)) {
            throw LanFileTransferException("receiver sha256 mismatch")
        }
    }

    private fun writeFrame(
        type: MacLanFileTransferProtocol.MessageType,
        payload: ByteArray,
        output: java.io.OutputStream
    ) {
        require(payload.size <= MacLanFileTransferProtocol.MAX_MESSAGE_BYTES) {
            "LAN file transfer frame is too large"
        }
        MacLanFileTransferProtocol.writeAll(
            output,
            MacLanFileTransferProtocol.writeHeader(type, payload.size) + payload
        )
    }

    private fun readFrame(
        input: InputStream,
        expectedType: MacLanFileTransferProtocol.MessageType
    ): ByteArray {
        val header = ByteArray(8)
        if (!MacLanFileTransferProtocol.readExactly(input, header)) {
            throw LanFileTransferException("receiver closed before receipt header")
        }
        val (type, length) = MacLanFileTransferProtocol.readHeader(header)
        if (type != expectedType) {
            throw LanFileTransferException("unexpected LAN file transfer receipt frame")
        }
        if (length !in 1..MacLanFileTransferProtocol.MAX_MESSAGE_BYTES) {
            throw LanFileTransferException("invalid LAN file transfer receipt length")
        }
        val payload = ByteArray(length)
        if (!MacLanFileTransferProtocol.readExactly(input, payload)) {
            throw LanFileTransferException("receiver closed before receipt payload")
        }
        return payload
    }

    private fun InputStream.readAtMost(buffer: ByteArray, maxBytes: Int): Int {
        var offset = 0
        while (offset < maxBytes) {
            val read = read(buffer, offset, maxBytes - offset)
            if (read < 0) break
            offset += read
            if (read == 0) break
        }
        return offset
    }

    private fun sha256Hex(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(1024 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun validateHost(rawHost: String) {
        val host = rawHost.trim()
        require(host.isNotEmpty()) { "LAN file transfer host is empty" }
        require(host.none { it.isWhitespace() || it.code < 0x20 }) {
            "LAN file transfer host is invalid"
        }
        val normalized = host.removeSurrounding("[", "]").lowercase()
        require(normalized != "localhost") { "LAN file transfer host must not be loopback" }
        require(normalized != "::" && normalized != "0:0:0:0:0:0:0:0") {
            "LAN file transfer host must not be wildcard"
        }
        require(normalized != "::1" && normalized != "0:0:0:0:0:0:0:1") {
            "LAN file transfer host must not be loopback"
        }
        if (normalized == "0.0.0.0") {
            throw IllegalArgumentException("LAN file transfer host must not be wildcard")
        }
        val ipv4Octets = normalized.split('.').takeIf { it.size == 4 }?.map { part ->
            if (part.isEmpty() || part.any { !it.isDigit() }) return@map null
            part.toIntOrNull()
        }
        if (ipv4Octets != null && ipv4Octets.all { it != null && it in 0..255 }) {
            require(ipv4Octets.first() != 127) { "LAN file transfer host must not be loopback" }
        }
    }

    private object DefaultSocketFactory : SocketFactory {
        override fun connect(
            host: String,
            port: Int,
            connectTimeoutMillis: Int,
            readTimeoutMillis: Int
        ): Socket {
            val socket = Socket()
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.soTimeout = readTimeoutMillis
            try {
                socket.connect(InetSocketAddress(host, port), connectTimeoutMillis)
                return socket
            } catch (t: Throwable) {
                runCatching { socket.close() }
                throw t
            }
        }
    }

    private companion object {
        private const val DEFAULT_CHUNK_BYTES = 512 * 1024
        private const val DEFAULT_CONNECT_TIMEOUT_MS = 5_000
        private const val DEFAULT_READ_TIMEOUT_MS = 30_000
    }
}
