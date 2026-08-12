package com.skybridge.compass.core.filetransfer

import android.content.Context
import android.os.Environment
import android.util.Log
import com.skybridge.compass.core.data.RuntimeNetworkParametersSource
import com.skybridge.compass.core.network.ListenPortAllocator
import com.skybridge.compass.core.network.ListenPortRangeExhaustedException
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.DataFormatException
import java.util.zip.Deflater
import java.util.zip.Inflater
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class MacLanFileTransferServer @Inject constructor(
    @ApplicationContext private val context: Context,
    private val runtimeParameters: RuntimeNetworkParametersSource
) {
    companion object {
        private const val TAG = "MacLanFileTransferServer"
        private const val DEFAULT_CHUNK_BYTES = 512 * 1024
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val started = AtomicBoolean(false)

    @Volatile private var serverSocket: ServerSocket? = null

    /**
     * Start the LAN transfer listener on a port from the user-configured listen range
     * (`RuntimeNetworkParameters.listenPortRange`), replacing
     * [MacLanFileTransferProtocol.DEFAULT_PORT] as the port source (R7.4, design §7).
     *
     * The range is read here, at start time, so the next listener honors a changed setting while an
     * already-listening server keeps its bound port.
     */
    suspend fun start(): Int = start(portRange = runtimeParameters.current().listenPortRange)

    /**
     * Start on a specific configured range. Ports are tried in ascending order; when every port in
     * the range is occupied this throws [ListenPortRangeExhaustedException] rather than silently
     * falling back to a hardcoded default port.
     *
     * @return bound port, always inside [portRange]
     */
    fun start(portRange: IntRange): Int {
        if (!started.compareAndSet(false, true)) {
            return serverSocket?.localPort ?: portRange.first
        }
        val server = try {
            ListenPortAllocator.bindWithin(portRange) { candidate ->
                ServerSocket(candidate)
            }.also { serverSocket = it }
        } catch (t: Throwable) {
            started.set(false)
            serverSocket = null
            throw t
        }
        Log.i(TAG, "Listening on ${server.localPort}")
        scope.launch {
            try {
                while (!server.isClosed) {
                    val socket = runCatching { server.accept() }.getOrNull() ?: break
                    scope.launch { handle(socket) }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "Server stopped: ${t.message}")
            } finally {
                started.set(false)
                runCatching { serverSocket?.close() }
                serverSocket = null
            }
        }
        return server.localPort
    }

    fun stop() {
        if (!started.compareAndSet(true, false)) return
        runCatching { serverSocket?.close() }
        serverSocket = null
    }

    private suspend fun handle(socket: Socket) {
        socket.tcpNoDelay = true
        socket.keepAlive = true

        val input = socket.getInputStream()
        val output = socket.getOutputStream()

        try {
            val header = ByteArray(8)
            if (!MacLanFileTransferProtocol.readExactly(input, header)) return
            val (type, len) = MacLanFileTransferProtocol.readHeader(header)
            require(type == MacLanFileTransferProtocol.MessageType.METADATA) { "expected metadata" }
            require(len in 1..MacLanFileTransferProtocol.MAX_MESSAGE_BYTES) { "invalid metadata length" }

            val metaBytes = ByteArray(len)
            if (!MacLanFileTransferProtocol.readExactly(input, metaBytes)) return
            val meta = MacLanFileTransferProtocol.json.decodeFromString(
                MacLanFileTransferProtocol.FileMetadata.serializer(),
                metaBytes.decodeToString()
            )

            val base = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: context.filesDir
            val dir = File(base, "SkyBridge")
            runCatching { dir.mkdirs() }

            val target = uniqueFile(File(dir, sanitizeFilename(meta.fileName)))
            val fos = FileOutputStream(target)

            var received: Long = 0
            while (received < meta.fileSize) {
                if (!MacLanFileTransferProtocol.readExactly(input, header)) throw IllegalStateException("connection closed")
                val (t2, l2) = MacLanFileTransferProtocol.readHeader(header)
                require(t2 == MacLanFileTransferProtocol.MessageType.CHUNK) { "expected chunk" }
                require(l2 in 1..MacLanFileTransferProtocol.MAX_MESSAGE_BYTES) { "invalid chunk length" }

                val chunkBytes = ByteArray(l2)
                if (!MacLanFileTransferProtocol.readExactly(input, chunkBytes)) throw IllegalStateException("connection closed")
                val chunk = MacLanFileTransferProtocol.json.decodeFromString(
                    MacLanFileTransferProtocol.FileChunk.serializer(),
                    chunkBytes.decodeToString()
                )

                val raw = if (meta.compression == "zlib") {
                    zlibDecompress(chunk.data)
                } else {
                    chunk.data
                }

                require(raw.size == chunk.size) { "chunk size mismatch" }
                require(raw.size in 0..DEFAULT_CHUNK_BYTES) { "chunk too large" }

                fos.write(raw)
                received += raw.size.toLong()
            }

            fos.flush()
            fos.close()

            // complete marker
            if (!MacLanFileTransferProtocol.readExactly(input, header)) throw IllegalStateException("connection closed")
            val (t3, l3) = MacLanFileTransferProtocol.readHeader(header)
            require(t3 == MacLanFileTransferProtocol.MessageType.COMPLETE && l3 == 0) { "expected complete" }

            val receivedHash = sha256Hex(target)
            val ok = meta.fileHash.equals(receivedHash, ignoreCase = true)

            val receipt = MacLanFileTransferProtocol.FileTransferReceipt(
                transferId = meta.transferId,
                success = ok,
                receivedBytes = received,
                fileHash = receivedHash,
                error = if (ok) null else "integrity_check_failed"
            )

            val receiptJson = MacLanFileTransferProtocol.json.encodeToString(
                MacLanFileTransferProtocol.FileTransferReceipt.serializer(),
                receipt
            ).encodeToByteArray()
            val receiptHeader = MacLanFileTransferProtocol.writeHeader(
                MacLanFileTransferProtocol.MessageType.RECEIPT,
                receiptJson.size
            )
            MacLanFileTransferProtocol.writeAll(output, receiptHeader + receiptJson)
        } catch (t: Throwable) {
            Log.w(TAG, "transfer failed: ${t.message}")
            runCatching {
                val receipt = MacLanFileTransferProtocol.FileTransferReceipt(
                    transferId = "",
                    success = false,
                    receivedBytes = 0,
                    fileHash = null,
                    error = t.message ?: "failed"
                )
                val receiptJson = MacLanFileTransferProtocol.json.encodeToString(
                    MacLanFileTransferProtocol.FileTransferReceipt.serializer(),
                    receipt
                ).encodeToByteArray()
                val header = MacLanFileTransferProtocol.writeHeader(
                    MacLanFileTransferProtocol.MessageType.RECEIPT,
                    receiptJson.size
                )
                MacLanFileTransferProtocol.writeAll(output, header + receiptJson)
            }
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun sanitizeFilename(raw: String): String {
        val trimmed = raw.trim().ifBlank { "file" }
        return trimmed.replace(Regex("[\\\\/:*?\"<>|]"), "_")
    }

    private fun uniqueFile(file: File): File {
        if (!file.exists()) return file
        val parent = file.parentFile ?: return file
        val stem = file.nameWithoutExtension
        val ext = file.extension.let { if (it.isBlank()) "" else ".$it" }
        for (i in 1..9_999) {
            val cand = File(parent, "$stem ($i)$ext")
            if (!cand.exists()) return cand
        }
        return File(parent, "$stem-${System.currentTimeMillis()}$ext")
    }

    private fun sha256Hex(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { ins ->
            val buf = ByteArray(1024 * 1024)
            while (true) {
                val r = ins.read(buf)
                if (r <= 0) break
                md.update(buf, 0, r)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun zlibDecompress(data: ByteArray): ByteArray {
        val inflater = Inflater(false)
        inflater.setInput(data)
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        try {
            while (!inflater.finished()) {
                val n = inflater.inflate(buf)
                if (n == 0) {
                    if (inflater.needsInput()) break
                } else {
                    out.write(buf, 0, n)
                }
            }
        } catch (e: DataFormatException) {
            throw IllegalStateException("zlib decompress failed", e)
        } finally {
            inflater.end()
        }
        return out.toByteArray()
    }

    @Suppress("unused")
    private fun zlibCompress(data: ByteArray): ByteArray {
        val deflater = Deflater(Deflater.BEST_SPEED, false)
        deflater.setInput(data)
        deflater.finish()
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        try {
            while (!deflater.finished()) {
                val n = deflater.deflate(buf)
                if (n <= 0) break
                out.write(buf, 0, n)
            }
        } finally {
            deflater.end()
        }
        return out.toByteArray()
    }
}
