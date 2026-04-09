package com.skybridge.compass.core.filetransfer

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.Deflater
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class MacLanFileTransferClient @Inject constructor(
    @ApplicationContext private val context: Context
) {
    companion object {
        private const val TAG = "MacLanFileTransferClient"
        private const val DEFAULT_CHUNK_BYTES = 512 * 1024
    }

    suspend fun sendFile(
        contentResolver: ContentResolver,
        uri: Uri,
        remoteHost: String,
        remotePort: Int = MacLanFileTransferProtocol.DEFAULT_PORT,
        enableCompression: Boolean = true,
        chunkBytes: Int = DEFAULT_CHUNK_BYTES
    ): Result<String> = withContext(Dispatchers.IO) {
        val transferId = UUID.randomUUID().toString()
        runCatching {
            val fileName = queryDisplayName(contentResolver, uri) ?: "android-file-$transferId"
            val fileSize = querySize(contentResolver, uri)

            val fileHash = sha256Hex(contentResolver.openInputStream(uri) ?: error("openInputStream failed"))

            val meta = MacLanFileTransferProtocol.FileMetadata(
                transferId = transferId,
                fileName = fileName,
                fileSize = fileSize,
                fileHash = fileHash,
                chunkSize = chunkBytes.coerceIn(64 * 1024, DEFAULT_CHUNK_BYTES),
                compression = if (enableCompression) "zlib" else null,
                senderDeviceId = null,
                senderDeviceName = android.os.Build.MODEL,
                senderPlatform = "android",
                senderOSVersion = "Android ${android.os.Build.VERSION.RELEASE} (API ${android.os.Build.VERSION.SDK_INT})",
                senderModelName = android.os.Build.MODEL
            )

            val socket = Socket()
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.connect(InetSocketAddress(remoteHost, remotePort), 10_000)

            val input = contentResolver.openInputStream(uri) ?: error("openInputStream failed")
            val out = socket.getOutputStream()
            val ins = socket.getInputStream()

            val metaJson = MacLanFileTransferProtocol.json.encodeToString(
                MacLanFileTransferProtocol.FileMetadata.serializer(),
                meta
            ).encodeToByteArray()
            val metaHeader = MacLanFileTransferProtocol.writeHeader(
                MacLanFileTransferProtocol.MessageType.METADATA,
                metaJson.size
            )
            MacLanFileTransferProtocol.writeAll(out, metaHeader + metaJson)

            val buf = ByteArray(meta.chunkSize)
            var idx = 0
            var sent: Long = 0
            input.use { stream ->
                while (true) {
                    val r = stream.read(buf)
                    if (r <= 0) break

                    val raw = buf.copyOf(r)
                    val payload = if (enableCompression) zlibCompress(raw) else raw

                    val chunk = MacLanFileTransferProtocol.FileChunk(
                        index = idx,
                        data = payload,
                        size = raw.size
                    )
                    val chunkJson = MacLanFileTransferProtocol.json.encodeToString(
                        MacLanFileTransferProtocol.FileChunk.serializer(),
                        chunk
                    ).encodeToByteArray()
                    val chunkHeader = MacLanFileTransferProtocol.writeHeader(
                        MacLanFileTransferProtocol.MessageType.CHUNK,
                        chunkJson.size
                    )
                    MacLanFileTransferProtocol.writeAll(out, chunkHeader + chunkJson)

                    sent += raw.size.toLong()
                    idx += 1
                }
            }

            val completeHeader = MacLanFileTransferProtocol.writeHeader(
                MacLanFileTransferProtocol.MessageType.COMPLETE,
                0
            )
            MacLanFileTransferProtocol.writeAll(out, completeHeader)

            // receipt
            val header = ByteArray(8)
            require(MacLanFileTransferProtocol.readExactly(ins, header)) { "connection closed" }
            val (t4, l4) = MacLanFileTransferProtocol.readHeader(header)
            require(t4 == MacLanFileTransferProtocol.MessageType.RECEIPT) { "expected receipt" }
            require(l4 in 1..MacLanFileTransferProtocol.MAX_MESSAGE_BYTES) { "invalid receipt length" }
            val receiptBytes = ByteArray(l4)
            require(MacLanFileTransferProtocol.readExactly(ins, receiptBytes)) { "connection closed" }
            val receipt = MacLanFileTransferProtocol.json.decodeFromString(
                MacLanFileTransferProtocol.FileTransferReceipt.serializer(),
                receiptBytes.decodeToString()
            )

            require(receipt.success) { receipt.error ?: "receiver rejected" }
            if (!receipt.fileHash.isNullOrBlank()) {
                require(receipt.fileHash.equals(fileHash, ignoreCase = true)) { "hash mismatch" }
            }
            Log.i(TAG, "Sent file ok transferId=$transferId bytes=$sent")
            socket.close()
            transferId
        }
    }

    private fun queryDisplayName(cr: ContentResolver, uri: Uri): String? {
        return runCatching {
            cr.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) c.getString(idx) else null
                } else null
            }
        }.getOrNull()
    }

    private fun querySize(cr: ContentResolver, uri: Uri): Long {
        return runCatching {
            cr.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(OpenableColumns.SIZE)
                    if (idx >= 0) c.getLong(idx) else -1L
                } else -1L
            } ?: -1L
        }.getOrElse { -1L }.let { if (it >= 0) it else 0L }
    }

    private fun sha256Hex(input: InputStream): String {
        val md = MessageDigest.getInstance("SHA-256")
        input.use { ins ->
            val buf = ByteArray(1024 * 1024)
            while (true) {
                val r = ins.read(buf)
                if (r <= 0) break
                md.update(buf, 0, r)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

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

