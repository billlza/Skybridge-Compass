package com.skybridge.compass.core.filetransfer

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MacLanFileTransferClientTest {
    @Test
    fun fileChunkJsonUsesSwiftDataBase64String() {
        val json = MacLanFileTransferProtocol.json.encodeToString(
            MacLanFileTransferProtocol.FileChunk(index = 0, data = byteArrayOf(1, 2, 3), size = 3)
        )

        assertTrue(json.contains(""""data":"AQID""""))
    }

    @Test
    fun sendFileWritesMetadataChunksCompleteAndValidatesReceipt() {
        val payload = "android to apple lan file".encodeToByteArray()
        val observed = withFakeServer { server ->
            val client = MacLanFileTransferClient(loopbackSocketFactory(server))

            runBlocking {
                client.sendFile(
                    MacLanFileTransferClient.SendRequest(
                        host = "192.168.1.44",
                        port = 44010,
                        fileName = "android.txt",
                        fileSize = payload.size.toLong(),
                        openInputStream = { ByteArrayInputStream(payload) },
                        senderDeviceName = "Pixel"
                    )
                )
            }
        }

        assertEquals("android.txt", observed.metadata.fileName)
        assertEquals(payload.size.toLong(), observed.metadata.fileSize)
        assertEquals("Pixel", observed.metadata.senderDeviceName)
        assertEquals("android", observed.metadata.senderPlatform)
        assertEquals(payload.decodeToString(), observed.payload.decodeToString())
        assertEquals(listOf(0), observed.chunkIndexes)
    }

    @Test
    fun receiverHashMismatchFailsClosed() {
        val payload = "bad receipt".encodeToByteArray()
        val server = ServerSocket(0)
        val executor = Executors.newSingleThreadExecutor()
        val receiverReady = CountDownLatch(1)
        val future = executor.submit {
            server.use { srv ->
                receiverReady.countDown()
                srv.accept().use { socket ->
                    val metadata = readMetadata(socket)
                    readChunksAndComplete(socket)
                    val receipt = MacLanFileTransferProtocol.FileTransferReceipt(
                        transferId = metadata.transferId,
                        success = true,
                        receivedBytes = metadata.fileSize,
                        fileHash = "0".repeat(64)
                    )
                    writeReceipt(socket, receipt)
                }
            }
        }
        val client = MacLanFileTransferClient(loopbackSocketFactory(server))

        try {
            // Do not start the client until the dedicated receiver thread has entered its accept
            // path. Without this barrier, a heavily loaded parallel test run could let the
            // client's real 30-second receipt timeout expire before the fixture was scheduled.
            assertTrue(
                "receiver fixture did not start within 30 seconds",
                receiverReady.await(30, TimeUnit.SECONDS)
            )
            val failure = runCatching {
                runBlocking {
                    client.sendFile(
                        MacLanFileTransferClient.SendRequest(
                            host = "192.168.1.44",
                            port = 44010,
                            fileName = "android.txt",
                            fileSize = payload.size.toLong(),
                            openInputStream = { ByteArrayInputStream(payload) }
                        )
                    )
                }
            }

            future.get(5, TimeUnit.SECONDS)
            assertTrue(failure.exceptionOrNull() is MacLanFileTransferClient.LanFileTransferException)
            assertTrue(failure.exceptionOrNull()?.message?.contains("sha256 mismatch") == true)
        } finally {
            executor.shutdownNow()
            runCatching { server.close() }
        }
    }

    private fun withFakeServer(
        send: (ServerSocket) -> MacLanFileTransferClient.SendResult
    ): ObservedTransfer {
        val server = ServerSocket(0)
        val executor = Executors.newSingleThreadExecutor()
        val receiverReady = CountDownLatch(1)
        val future = executor.submit<ObservedTransfer> {
            server.use { srv ->
                receiverReady.countDown()
                srv.accept().use { socket ->
                    val metadata = readMetadata(socket)
                    val chunks = readChunksAndComplete(socket)
                    val payload = chunks.flatMap { it.data.toList() }.toByteArray()
                    writeReceipt(
                        socket,
                        MacLanFileTransferProtocol.FileTransferReceipt(
                            transferId = metadata.transferId,
                            success = true,
                            receivedBytes = payload.size.toLong(),
                            fileHash = sha256Hex(payload)
                        )
                    )
                    ObservedTransfer(
                        metadata = metadata,
                        payload = payload,
                        chunkIndexes = chunks.map { it.index }
                    )
                }
            }
        }
        try {
            assertTrue(
                "receiver fixture did not start within 30 seconds",
                receiverReady.await(30, TimeUnit.SECONDS)
            )
            send(server)
            return future.get(5, TimeUnit.SECONDS)
        } finally {
            executor.shutdownNow()
            runCatching { server.close() }
        }
    }

    private fun loopbackSocketFactory(server: ServerSocket) =
        MacLanFileTransferClient.SocketFactory { _, _, _, readTimeoutMillis ->
            Socket("127.0.0.1", server.localPort).apply {
                soTimeout = readTimeoutMillis
                tcpNoDelay = true
            }
        }

    private fun readMetadata(socket: Socket): MacLanFileTransferProtocol.FileMetadata {
        val payload = readFrame(socket, MacLanFileTransferProtocol.MessageType.METADATA)
        return MacLanFileTransferProtocol.json.decodeFromString(
            MacLanFileTransferProtocol.FileMetadata.serializer(),
            payload.decodeToString()
        )
    }

    private fun readChunksAndComplete(socket: Socket): List<MacLanFileTransferProtocol.FileChunk> {
        val chunks = mutableListOf<MacLanFileTransferProtocol.FileChunk>()
        while (true) {
            val header = ByteArray(8)
            assertTrue(MacLanFileTransferProtocol.readExactly(socket.getInputStream(), header))
            val (type, length) = MacLanFileTransferProtocol.readHeader(header)
            if (type == MacLanFileTransferProtocol.MessageType.COMPLETE) {
                assertEquals(0, length)
                return chunks
            }
            assertEquals(MacLanFileTransferProtocol.MessageType.CHUNK, type)
            val payload = ByteArray(length)
            assertTrue(MacLanFileTransferProtocol.readExactly(socket.getInputStream(), payload))
            chunks += MacLanFileTransferProtocol.json.decodeFromString(
                MacLanFileTransferProtocol.FileChunk.serializer(),
                payload.decodeToString()
            )
        }
    }

    private fun readFrame(socket: Socket, expectedType: MacLanFileTransferProtocol.MessageType): ByteArray {
        val header = ByteArray(8)
        assertTrue(MacLanFileTransferProtocol.readExactly(socket.getInputStream(), header))
        val (type, length) = MacLanFileTransferProtocol.readHeader(header)
        assertEquals(expectedType, type)
        val payload = ByteArray(length)
        assertTrue(MacLanFileTransferProtocol.readExactly(socket.getInputStream(), payload))
        return payload
    }

    private fun writeReceipt(
        socket: Socket,
        receipt: MacLanFileTransferProtocol.FileTransferReceipt
    ) {
        val payload = MacLanFileTransferProtocol.json.encodeToString(receipt).encodeToByteArray()
        MacLanFileTransferProtocol.writeAll(
            socket.getOutputStream(),
            MacLanFileTransferProtocol.writeHeader(
                MacLanFileTransferProtocol.MessageType.RECEIPT,
                payload.size
            ) + payload
        )
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }

    data class ObservedTransfer(
        val metadata: MacLanFileTransferProtocol.FileMetadata,
        val payload: ByteArray,
        val chunkIndexes: List<Int>
    )
}
