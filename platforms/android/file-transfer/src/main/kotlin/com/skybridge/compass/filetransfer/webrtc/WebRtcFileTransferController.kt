package com.skybridge.compass.filetransfer.webrtc

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.skybridge.compass.core.webrtc.CrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.shared.crypto.MerkleSha256
import com.skybridge.compass.shared.p2p.filetransfer.MerkleRootAuthV1
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.filetransfer.webrtc.resume.InMemoryTransferCheckpointStore
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifest
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestEntry
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestStore
import com.skybridge.compass.filetransfer.webrtc.resume.AndroidBatchManifestStore
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpointStore
import com.skybridge.compass.filetransfer.webrtc.resume.TransferDirection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Minimal CrossNetwork (WebRTC DataChannel) file transfer controller compatible with Pro release
 * message shapes. This provides a real metadata->chunk->complete flow.
 *
 * Notes:
 * - Payload is JSON bytes. Chunk bytes are base64-encoded inside JSON (Swift Data Codable behavior).
 * - This is intentionally simple (no resume / no encryption); the goal is true wire interop first.
 */
class WebRtcFileTransferController(
    private val webrtc: CrossNetworkWebRtcTransportAdapter,
    private val json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false },
    private val checkpointStore: TransferCheckpointStore = InMemoryTransferCheckpointStore(),
    private val appContext: Context? = null,
    private val batchManifestStore: BatchManifestStore? = appContext?.let { AndroidBatchManifestStore(it.applicationContext, json) },
    private val inboundApprovalProvider: InboundFileTransferApprovalProvider? = null,
    private val saveAcceptedInboundToDownloads: Boolean = false
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    data class Progress(
        val transferId: String? = null,
        val sentBytes: Long = 0L,
        val totalBytes: Long = 0L,
        val lastStatus: String? = null
    )

    private val _progress = MutableStateFlow(Progress())
    val progress: StateFlow<Progress> = _progress.asStateFlow()

    private val rxBytes = AtomicLong(0L)

    data class ReceivedFile(
        val transferId: String,
        val fileName: String?,
        val mimeType: String?,
        val bytes: ByteArray? = null,
        val localPath: String? = null,
        val downloadsUri: String? = null,
        val downloadsDisplayName: String? = null
    )

    private val _receivedFiles = MutableSharedFlow<ReceivedFile>(extraBufferCapacity = 8)
    val receivedFiles: SharedFlow<ReceivedFile> = _receivedFiles

    private data class ReceiveContext(
        val transferId: String,
        val version: Int,
        val senderDeviceId: String?,
        val senderDeviceName: String?,
        val fileName: String?,
        val mimeType: String?,
        val totalBytes: Long?,
        val chunkSize: Int?,
        val totalChunks: Int?,
        var partialFile: File?,
        var raf: RandomAccessFile?,
        var receivedBytes: Long = 0L
    ) {
        val buffer = ByteArrayOutputStream()
        var nextExpectedChunkIndex: Int = 0
        val pendingChunks: MutableMap<Int, ByteArray> = HashMap()
        val receivedChunkIndices: MutableSet<Int> = HashSet()
        var completeReceived: Boolean = false
        var completeReceivedBytes: Long? = null
        var completeReceivedAtMs: Long = 0L
        var expectedFileSha256: ByteArray? = null
        var expectedMerkleRoot: ByteArray? = null
        var expectedMerkleSig: ByteArray? = null
        var expectedMerkleSigAlg: String? = null
        val chunkHashes: MutableMap<Int, ByteArray> = HashMap()

        @Volatile
        var approvalDecision: InboundFileTransferDecision? = null

        @Volatile
        var declined: Boolean = false

        @Volatile
        var approvalJob: Job? = null
    }

    private val receiveContexts = ConcurrentHashMap<String, ReceiveContext>()

    private data class SendContext(
        val transferId: String,
        val totalChunks: Int,
        val totalBytes: Long,
        val chunks: List<ByteArray>
    ) {
        val acked: BooleanArray = BooleanArray(totalChunks)
        val sendAttempts: IntArray = IntArray(totalChunks)
    }

    private val sendContexts = ConcurrentHashMap<String, SendContext>()

    private data class BatchRef(
        val batchId: String,
        val batchIndex: Int? = null,
        val batchTotal: Int? = null,
        val relativePath: String? = null
    )
    private val sendBatchByTransferId = ConcurrentHashMap<String, BatchRef>()

    private fun newTransferId(prefix: String): String = "$prefix-${UUID.randomUUID()}"

    suspend fun listPendingCheckpoints(): List<TransferCheckpoint> = checkpointStore.list()

    suspend fun listPendingBatches(): List<BatchManifest> =
        batchManifestStore?.list()?.filter { m ->
            m.entries.any { it.status == BatchManifestEntry.Status.PENDING || it.status == BatchManifestEntry.Status.IN_PROGRESS }
        } ?: emptyList()

    suspend fun deleteBatch(batchId: String) {
        withContext(Dispatchers.IO) {
            val store = batchManifestStore ?: return@withContext
            val current = store.load(batchId) ?: run {
                store.delete(batchId)
                return@withContext
            }
            // Best-effort cleanup: delete checkpoints for batch entries and forget local mapping.
            current.entries.forEach { e ->
                runCatching { checkpointStore.delete(e.transferId) }
                sendBatchByTransferId.remove(e.transferId)
            }
            store.delete(batchId)
        }
    }

    suspend fun deleteBatchEntry(batchId: String, transferId: String) {
        withContext(Dispatchers.IO) {
            val store = batchManifestStore ?: return@withContext
            val current = store.load(batchId) ?: return@withContext
            runCatching { checkpointStore.delete(transferId) }
            sendBatchByTransferId.remove(transferId)
            val updatedEntries = current.entries.map { e ->
                if (e.transferId == transferId) e.copy(status = BatchManifestEntry.Status.CANCELLED, updatedAtMs = System.currentTimeMillis())
                else e
            }
            store.save(current.copy(entries = updatedEntries, updatedAtMs = System.currentTimeMillis()))
        }
    }

    suspend fun resumeBatch(contentResolver: ContentResolver, batchId: String) {
        withContext(Dispatchers.IO) {
            val store = batchManifestStore ?: return@withContext
            val manifest = store.load(batchId) ?: return@withContext
            // Resume all SEND entries that still have checkpoints with sourceUri.
            for (e in manifest.entries) {
                val cp = checkpointStore.load(e.transferId) ?: continue
                if (cp.direction != TransferDirection.SEND) continue
                // Only attempt resume if we have enough info.
                if (cp.sourceUri.isNullOrBlank()) continue
                runCatching { resumeSend(contentResolver, e.transferId) }
            }
        }
    }

    suspend fun deleteCheckpoint(transferId: String) {
        withContext(Dispatchers.IO) {
            checkpointStore.delete(transferId)
        }
    }

    /**
     * Resume a previously started SEND transfer using persisted checkpoint.
     * Requires `sourceUri` to be present and readable (persistable permission recommended).
     *
     * This does NOT change the wire protocol.
     */
    suspend fun resumeSend(contentResolver: ContentResolver, transferId: String) {
        withContext(Dispatchers.IO) {
            val cp = checkpointStore.load(transferId) ?: return@withContext
            if (cp.direction != com.skybridge.compass.filetransfer.webrtc.resume.TransferDirection.SEND) return@withContext
            val uriStr = cp.sourceUri ?: return@withContext
            val chunkSize = cp.chunkSize ?: return@withContext
            val totalChunks = cp.totalChunks ?: return@withContext

            val uri = Uri.parse(uriStr)
            val mime = cp.mimeType ?: contentResolver.getType(uri) ?: "application/octet-stream"
            val acked = cp.ackedChunks.toSet()

            val meta = CrossNetworkFileTransferMessage(
                version = 1,
                op = CrossNetworkFileTransferOp.metadata,
                transferId = transferId,
                senderDeviceId = android.os.Build.MODEL,
                senderDeviceName = android.os.Build.MODEL,
                fileName = cp.fileName ?: "file",
                fileSize = cp.fileSize,
                chunkSize = chunkSize,
                totalChunks = totalChunks,
                mimeType = mime
            )
            webrtc.send(encode(meta))
            _progress.value = Progress(transferId, 0, cp.fileSize ?: 0L, "resume: sent metadata")

            val input = contentResolver.openInputStream(uri) ?: return@withContext
            input.use { stream ->
                val buf = ByteArray(chunkSize)
                var index = 0
                var sent = 0L
                val fileDigest = MessageDigest.getInstance("SHA-256")
                val chunkHashes = ArrayList<ByteArray>(totalChunks)
                while (true) {
                    val n = stream.read(buf)
                    if (n <= 0) break
                    val chunkBytes = if (n == buf.size) buf else buf.copyOfRange(0, n)
                    fileDigest.update(chunkBytes)
                    chunkHashes.add(sha256(chunkBytes))
                    if (!acked.contains(index)) {
                        sendChunk(transferId = transferId, index = index, chunkBytes = chunkBytes, receivedBytes = sent + n)
                    }
                    sent += n
                    index += 1
                }

                val fileSha256 = fileDigest.digest()
                val merkleRoot = MerkleSha256.root(chunkHashes)
                val merkleSig = webrtc.computeOutboundHmacSha256(
                    MerkleRootAuthV1.preimage(transferId = transferId, merkleRoot = merkleRoot, fileSha256 = fileSha256)
                )
                webrtc.send(
                    encode(
                        CrossNetworkFileTransferMessage(
                            version = 1,
                            op = CrossNetworkFileTransferOp.complete,
                            transferId = transferId,
                            receivedBytes = cp.fileSize,
                            fileSha256 = fileSha256,
                            merkleRoot = merkleRoot,
                            merkleRootSignature = merkleSig,
                            merkleRootSignatureAlg = if (merkleSig != null) "hmac-sha256-session-v1" else null
                        )
                    )
                )
            }

            startResendLoopIfNeeded(transferId)
            _progress.value = Progress(transferId, cp.fileSize ?: 0L, cp.fileSize ?: 0L, "resume: sent complete")
        }
    }

    fun sendTestMetadata() {
        val msg = CrossNetworkFileTransferMessage(
            version = 1,
            op = CrossNetworkFileTransferOp.metadata,
            transferId = "android-test-${System.currentTimeMillis()}",
            senderDeviceId = android.os.Build.MODEL,
            senderDeviceName = android.os.Build.MODEL,
            fileName = "hello.txt",
            fileSize = 5,
            chunkSize = 16 * 1024,
            totalChunks = 1,
            mimeType = "text/plain",
            message = "hello-from-android"
        )
        webrtc.send(encode(msg))
        _progress.value = Progress(transferId = msg.transferId, lastStatus = "sent metadata(test)")
    }

    /**
     * Send an in-memory "file" over the CrossNetwork protocol (metadata -> chunks -> complete).
     * Useful for interoperability testing before wiring document pickers/UI.
     */
    suspend fun sendBytesAsFile(
        transferId: String,
        fileName: String,
        mimeType: String = "application/octet-stream",
        bytes: ByteArray,
        chunkSize: Int = 16 * 1024,
        batchId: String? = null,
        batchIndex: Int? = null,
        batchTotal: Int? = null,
        relativePath: String? = null
    ) {
        withContext(Dispatchers.IO) {
            val totalBytes = bytes.size.toLong()
            val totalChunks = ((totalBytes + chunkSize - 1) / chunkSize).toInt()

            val chunks = ArrayList<ByteArray>(totalChunks)
            run {
                var off = 0
                while (off < bytes.size) {
                    val end = kotlin.math.min(off + chunkSize, bytes.size)
                    chunks.add(bytes.copyOfRange(off, end))
                    off = end
                }
            }
            val sendCtx = SendContext(
                transferId = transferId,
                totalChunks = totalChunks,
                totalBytes = totalBytes,
                chunks = chunks
            )
            sendContexts[transferId] = sendCtx
            if (batchId != null) {
                sendBatchByTransferId[transferId] = BatchRef(batchId, batchIndex, batchTotal, relativePath)
            }
            checkpointStore.save(
                TransferCheckpoint.newSend(
                    transferId = transferId,
                    sourceUri = null,
                    fileName = fileName,
                    mimeType = mimeType,
                    fileSize = totalBytes,
                    chunkSize = chunkSize,
                    totalChunks = totalChunks
                )
            )

            val meta = CrossNetworkFileTransferMessage(
                version = 1,
                op = CrossNetworkFileTransferOp.metadata,
                transferId = transferId,
                senderDeviceId = android.os.Build.MODEL,
                senderDeviceName = android.os.Build.MODEL,
                fileName = fileName,
                fileSize = totalBytes,
                chunkSize = chunkSize,
                totalChunks = totalChunks,
                mimeType = mimeType,
                batchId = batchId,
                batchIndex = batchIndex,
                batchTotal = batchTotal,
                relativePath = relativePath
            )
            webrtc.send(encode(meta))
            _progress.value = Progress(transferId, 0, totalBytes, "sent metadata")

            // send all chunks once
            val fileSha256 = sha256(bytes)
            val chunkHashes = chunks.map { sha256(it) }
            val merkleRoot = MerkleSha256.root(chunkHashes)
            val merkleSig = webrtc.computeOutboundHmacSha256(
                MerkleRootAuthV1.preimage(transferId = transferId, merkleRoot = merkleRoot, fileSha256 = fileSha256)
            )
            chunks.forEachIndexed { index, chunkBytes ->
                sendChunk(transferId = transferId, index = index, chunkBytes = chunkBytes)
                val sentSoFar = kotlin.math.min(((index + 1).toLong() * chunkSize.toLong()), totalBytes)
                _progress.value = Progress(transferId, sentSoFar, totalBytes, "sent chunk#${index + 1}")
            }

            webrtc.send(
                encode(
                    CrossNetworkFileTransferMessage(
                        version = 1,
                        op = CrossNetworkFileTransferOp.complete,
                        transferId = transferId,
                        receivedBytes = totalBytes,
                        fileSha256 = fileSha256,
                        merkleRoot = merkleRoot,
                        merkleRootSignature = merkleSig,
                        merkleRootSignatureAlg = if (merkleSig != null) "hmac-sha256-session-v1" else null,
                        batchId = batchId,
                        batchIndex = batchIndex,
                        batchTotal = batchTotal,
                        relativePath = relativePath
                    )
                )
            )
            _progress.value = Progress(transferId, totalBytes, totalBytes, "sent complete")

            startResendLoopIfNeeded(transferId)
        }
    }

    suspend fun sendFile(
        contentResolver: ContentResolver,
        uri: Uri,
        transferId: String,
        fileName: String,
        mimeType: String?,
        chunkSize: Int = 64 * 1024,
        batchId: String? = null,
        batchIndex: Int? = null,
        batchTotal: Int? = null,
        relativePath: String? = null
    ) {
        withContext(Dispatchers.IO) {
            val input = contentResolver.openInputStream(uri) ?: error("openInputStream failed")
            input.use { stream ->
                val totalBytes = contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
                val bufferedChunks = ArrayList<ByteArray>()
                val meta = CrossNetworkFileTransferMessage(
                    version = 1,
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = transferId,
                    senderDeviceId = android.os.Build.MODEL,
                    senderDeviceName = android.os.Build.MODEL,
                    fileName = fileName,
                    fileSize = if (totalBytes >= 0) totalBytes else null,
                    chunkSize = chunkSize,
                    totalChunks = if (totalBytes >= 0) ((totalBytes + chunkSize - 1) / chunkSize).toInt() else null,
                    mimeType = mimeType ?: "application/octet-stream",
                    batchId = batchId,
                    batchIndex = batchIndex,
                    batchTotal = batchTotal,
                    relativePath = relativePath
                )
                webrtc.send(encode(meta))
                _progress.value = Progress(transferId, 0, totalBytes.coerceAtLeast(0), "sent metadata")

                checkpointStore.save(
                    TransferCheckpoint.newSend(
                        transferId = transferId,
                        sourceUri = uri.toString(),
                        fileName = fileName,
                        mimeType = mimeType ?: "application/octet-stream",
                        fileSize = if (totalBytes >= 0) totalBytes else null,
                        chunkSize = chunkSize,
                        totalChunks = if (totalBytes >= 0) ((totalBytes + chunkSize - 1) / chunkSize).toInt() else null
                    )
                )

                if (batchId != null) {
                    sendBatchByTransferId[transferId] = BatchRef(batchId, batchIndex, batchTotal, relativePath)
                }

                val buf = ByteArray(chunkSize)
                var sent = 0L
                var index = 0
                val fileDigest = MessageDigest.getInstance("SHA-256")
                val chunkHashes = ArrayList<ByteArray>()
                while (true) {
                    val n = stream.read(buf)
                    if (n <= 0) break
                    val chunkBytes = if (n == buf.size) buf else buf.copyOfRange(0, n)
                    fileDigest.update(chunkBytes)
                    chunkHashes.add(sha256(chunkBytes))
                    bufferedChunks.add(chunkBytes)
                    sendChunk(transferId = transferId, index = index, chunkBytes = chunkBytes, receivedBytes = sent + n)
                    sent += n
                    index += 1
                    _progress.value = Progress(transferId, sent, totalBytes.coerceAtLeast(0), "sent chunk#$index")
                }

                if (totalBytes >= 0) {
                    sendContexts[transferId] = SendContext(
                        transferId = transferId,
                        totalChunks = bufferedChunks.size,
                        totalBytes = totalBytes,
                        chunks = bufferedChunks
                    )
                }

                val fileSha256 = fileDigest.digest()
                val merkleRoot = MerkleSha256.root(chunkHashes)
                val merkleSig = webrtc.computeOutboundHmacSha256(
                    MerkleRootAuthV1.preimage(transferId = transferId, merkleRoot = merkleRoot, fileSha256 = fileSha256)
                )
                val complete = CrossNetworkFileTransferMessage(
                    version = 1,
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = sent,
                    fileSha256 = fileSha256,
                    merkleRoot = merkleRoot,
                    merkleRootSignature = merkleSig,
                    merkleRootSignatureAlg = if (merkleSig != null) "hmac-sha256-session-v1" else null,
                    batchId = batchId,
                    batchIndex = batchIndex,
                    batchTotal = batchTotal,
                    relativePath = relativePath
                )
                webrtc.send(encode(complete))
                _progress.value = Progress(transferId, sent, totalBytes.coerceAtLeast(0), "sent complete")

                startResendLoopIfNeeded(transferId)
            }
        }
    }

    /**
     * Batch send helper (multiple files, optional directory semantics).
     * Emits one transfer per item, grouped by batchId.
     */
    suspend fun sendFilesBatch(
        contentResolver: ContentResolver,
        items: List<Pair<Uri, String>>, // (uri, relativePathOrName)
        batchId: String = "batch-${UUID.randomUUID()}",
        mimeTypeResolver: ((Uri) -> String?)? = null
    ) {
        withContext(Dispatchers.IO) {
            val total = items.size
            items.forEachIndexed { idx, (uri, rel) ->
                val name = rel.substringAfterLast('/').ifBlank { "file" }
                val mime = mimeTypeResolver?.invoke(uri) ?: contentResolver.getType(uri)
                val transferId = "ft-${UUID.randomUUID()}"
                sendFile(
                    contentResolver = contentResolver,
                    uri = uri,
                    transferId = transferId,
                    fileName = name,
                    mimeType = mime,
                    batchId = batchId,
                    batchIndex = idx,
                    batchTotal = total,
                    relativePath = rel
                )
            }
        }
    }

    fun handleIncoming(bytes: ByteArray) {
        rxBytes.addAndGet(bytes.size.toLong())
        val msg = runCatching {
            json.decodeFromString(CrossNetworkFileTransferMessage.serializer(), bytes.decodeToString())
        }.getOrNull() ?: return

        when (msg.op) {
            CrossNetworkFileTransferOp.metadata -> {
                // Idempotent: if already tracking, just ACK (supports resume).
                if (receiveContexts.containsKey(msg.transferId)) {
                    webrtc.send(
                        encode(
                            CrossNetworkFileTransferMessage(
                                version = msg.version,
                                op = CrossNetworkFileTransferOp.metadataAck,
                                transferId = msg.transferId,
                                receivedBytes = msg.fileSize
                            )
                        )
                    )
                    return
                }

                val existingCp = runCatching {
                    runBlocking(Dispatchers.IO) { checkpointStore.load(msg.transferId) }
                }.getOrNull()
                val existingPartial = existingCp?.partialPath?.let { p ->
                    runCatching {
                        val f = File(p)
                        if (f.exists()) f else null
                    }.getOrNull()
                }
                val preloadReceivedChunks = existingCp?.receivedChunks?.toSet().orEmpty()

                val partialDir = appContext?.let {
                    File(it.applicationContext.filesDir, "skybridge_inbound_partials").apply { mkdirs() }
                }
                val partialFile = existingPartial ?: partialDir?.let { File(it, "${msg.transferId}.partial") }
                val raf = partialFile?.let { RandomAccessFile(it, "rw") }

                val ctx = ReceiveContext(
                    transferId = msg.transferId,
                    version = msg.version,
                    senderDeviceId = msg.senderDeviceId,
                    senderDeviceName = msg.senderDeviceName,
                    fileName = msg.fileName,
                    mimeType = msg.mimeType,
                    totalBytes = msg.fileSize,
                    chunkSize = msg.chunkSize,
                    totalChunks = msg.totalChunks,
                    partialFile = partialFile,
                    raf = raf,
                    receivedBytes = partialFile?.let { runCatching { it.length() }.getOrNull() } ?: 0L
                )
                receiveContexts[msg.transferId] = ctx
                // preload received chunks if we have them (resume after restart)
                ctx.receivedChunkIndices.addAll(preloadReceivedChunks)

                // Batch manifest (best-effort, local persistence)
                val bid = msg.batchId
                if (bid != null) {
                    scope.launch {
                        val store = batchManifestStore ?: return@launch
                        val current = store.load(bid)
                        val existingEntries = current?.entries.orEmpty().associateBy { it.transferId }.toMutableMap()
                        existingEntries[msg.transferId] = BatchManifestEntry(
                            transferId = msg.transferId,
                            batchIndex = msg.batchIndex,
                            relativePath = msg.relativePath,
                            fileName = msg.fileName,
                            fileSize = msg.fileSize,
                            status = BatchManifestEntry.Status.IN_PROGRESS,
                            updatedAtMs = System.currentTimeMillis()
                        )
                        val merged = BatchManifest(
                            batchId = bid,
                            batchTotal = msg.batchTotal ?: current?.batchTotal,
                            entries = existingEntries.values.sortedWith(compareBy({ it.batchIndex ?: Int.MAX_VALUE }, { it.transferId })),
                            createdAtMs = current?.createdAtMs ?: System.currentTimeMillis(),
                            updatedAtMs = System.currentTimeMillis()
                        )
                        store.save(merged)
                    }
                }
                scope.launch {
                    checkpointStore.save(
                        TransferCheckpoint.newReceive(
                            transferId = msg.transferId,
                            partialPath = partialFile?.absolutePath,
                            fileName = msg.fileName,
                            mimeType = msg.mimeType,
                            fileSize = msg.fileSize,
                            chunkSize = msg.chunkSize,
                            totalChunks = msg.totalChunks
                        )
                    )
                }

                // Start approval flow (app-provided). Until approved, we will not emit a completed file.
                startInboundApprovalIfNeeded(ctx)

                // ack metadata (best-effort)
                webrtc.send(
                    encode(
                        CrossNetworkFileTransferMessage(
                            version = msg.version,
                            op = CrossNetworkFileTransferOp.metadataAck,
                            transferId = msg.transferId,
                            receivedBytes = msg.fileSize
                        )
                    )
                )
            }
            CrossNetworkFileTransferOp.chunk -> {
                val ctx = receiveContexts[msg.transferId]
                if (ctx?.declined == true) return
                val chunkData = msg.chunkData
                val chunkIndex = msg.chunkIndex
                val expectedHash = msg.chunkSha256
                val actualHash = if (chunkData != null) sha256(chunkData) else null
                val hashOk = if (chunkData != null && expectedHash != null && actualHash != null) {
                    actualHash.contentEquals(expectedHash)
                } else true

                if (ctx != null && chunkData != null && chunkIndex != null && hashOk) {
                    // track chunk hashes for Merkle verification (always compute, even if peer didn't send expectedHash)
                    actualHash?.let { ctx.chunkHashes[chunkIndex] = it }
                    // tolerate out-of-order + duplicates: buffer by index, then flush contiguous window
                    if (chunkIndex >= 0) {
                        ctx.pendingChunks.putIfAbsent(chunkIndex, chunkData)
                        ctx.receivedChunkIndices.add(chunkIndex)
                        while (true) {
                            val next = ctx.pendingChunks.remove(ctx.nextExpectedChunkIndex) ?: break
                            val cs = ctx.chunkSize ?: next.size
                            val offset = ctx.nextExpectedChunkIndex.toLong() * cs.toLong()
                            if (ctx.raf != null) {
                                try {
                                    ctx.raf?.seek(offset)
                                    ctx.raf?.write(next)
                                } catch (_: Exception) {
                                    // fallback to in-memory
                                    ctx.buffer.write(next)
                                }
                            } else {
                                ctx.buffer.write(next)
                            }
                            ctx.receivedBytes = maxOf(ctx.receivedBytes, offset + next.size.toLong())
                            ctx.nextExpectedChunkIndex += 1
                        }
                    }
                }

                if (ctx != null && chunkIndex != null) {
                    scope.launch {
                        val existing = checkpointStore.load(ctx.transferId)
                        if (existing != null) {
                            val merged = (existing.receivedChunks.toList() + listOf(chunkIndex)).distinct().sorted().toIntArray()
                            checkpointStore.save(existing.copy(receivedChunks = merged))
                        }
                    }
                }

                // If sender already signaled "complete" but we were missing chunks, finalize once complete.
                if (ctx != null && ctx.completeReceived) {
                    val totalChunks = ctx.totalChunks
                    if (totalChunks != null && totalChunks > 0 && ctx.receivedChunkIndices.size == totalChunks) {
                        maybeFinalizeIfReady(ctx)
                    }
                }

                // ack chunk (best-effort)
                if (hashOk) {
                    val idx = msg.chunkIndex
                    webrtc.send(
                        encode(
                            CrossNetworkFileTransferMessage(
                                version = msg.version,
                                op = CrossNetworkFileTransferOp.chunkAck,
                                transferId = msg.transferId,
                                chunkIndex = idx,
                                rawSize = msg.rawSize,
                                receivedBytes = msg.receivedBytes
                            )
                        )
                    )
                } else {
                    _progress.value = _progress.value.copy(lastStatus = "chunk hash mismatch (idx=$chunkIndex)")
                }
            }
            CrossNetworkFileTransferOp.complete -> {
                val ctx = receiveContexts[msg.transferId]
                if (ctx != null) {
                    ctx.completeReceived = true
                    ctx.completeReceivedBytes = msg.receivedBytes
                    ctx.completeReceivedAtMs = System.currentTimeMillis()
                    ctx.expectedFileSha256 = msg.fileSha256
                    ctx.expectedMerkleRoot = msg.merkleRoot
                    ctx.expectedMerkleSig = msg.merkleRootSignature
                    ctx.expectedMerkleSigAlg = msg.merkleRootSignatureAlg

                    val totalChunks = ctx.totalChunks
                    if (totalChunks != null && totalChunks > 0 && ctx.receivedChunkIndices.size != totalChunks) {
                        val missing = (0 until totalChunks).filterNot { ctx.receivedChunkIndices.contains(it) }
                        _progress.value = Progress(
                            transferId = ctx.transferId,
                            sentBytes = ctx.buffer.size().toLong(),
                            totalBytes = ctx.totalBytes ?: 0L,
                            lastStatus = "waiting missing chunks: ${missing.take(16)}${if (missing.size > 16) "..." else ""}"
                        )

                        // Optional NACK: ask sender to resend missing chunks (backward compatible).
                        webrtc.send(
                            encode(
                                CrossNetworkFileTransferMessage(
                                    version = msg.version,
                                    op = CrossNetworkFileTransferOp.chunkAck,
                                    transferId = msg.transferId,
                                    missingChunks = missing.take(512).toIntArray(),
                                    message = "missingChunks"
                                )
                            )
                        )

                        // Safety for iOS/mac interop: do NOT proactively send op=error here.
                        // We just keep receiving; if sender retries/resends, we'll finalize once complete.
                        scope.launch {
                            delay(10_000)
                            val still = receiveContexts[ctx.transferId]
                            if (still != null && still.completeReceived && still.completeReceivedAtMs == ctx.completeReceivedAtMs) {
                                val tc = still.totalChunks
                                val ok = (tc == null) || (still.receivedChunkIndices.size == tc)
                                if (!ok) {
                                    // Best-effort final NACK before we give up.
                                    val tcNonNull = tc // smart-cast: !ok implies tc != null
                                    if (tcNonNull > 0) {
                                        val missing2 = (0 until tcNonNull).filterNot { still.receivedChunkIndices.contains(it) }
                                        webrtc.send(
                                            encode(
                                                CrossNetworkFileTransferMessage(
                                                    version = msg.version,
                                                    op = CrossNetworkFileTransferOp.chunkAck,
                                                    transferId = msg.transferId,
                                                    missingChunks = missing2.take(512).toIntArray(),
                                                    message = "missingChunks(timeout)"
                                                )
                                            )
                                        )
                                    }
                                    receiveContexts.remove(still.transferId)
                                    _progress.value = Progress(
                                        transferId = still.transferId,
                                        sentBytes = still.buffer.size().toLong(),
                                        totalBytes = still.totalBytes ?: 0L,
                                        lastStatus = "receive timed out (missing chunks)"
                                    )
                                    checkpointStore.delete(still.transferId)
                                }
                            }
                        }
                        return
                    }

                    maybeFinalizeIfReady(ctx)
                }
            }
            CrossNetworkFileTransferOp.chunkAck -> {
                val transferId = msg.transferId
                val idx = msg.chunkIndex
                val missing = msg.missingChunks

                if (missing != null && missing.isNotEmpty()) {
                    val ctx = sendContexts[transferId]
                    if (ctx != null) {
                        missing.forEach { mi ->
                            if (mi in 0 until ctx.totalChunks) {
                                ctx.acked[mi] = false
                                if (ctx.sendAttempts[mi] < 6) {
                                    sendChunk(transferId, mi, ctx.chunks[mi])
                                }
                            }
                        }
                        // Re-send complete to prompt finalize (receiver enforces integrity if present).
                        sendCompleteFromContext(ctx)
                    }
                }
                if (idx != null && idx >= 0) {
                    sendContexts[transferId]?.let { ctx ->
                        if (idx < ctx.acked.size) {
                            ctx.acked[idx] = true
                        }
                    }
                    scope.launch {
                        val existing = checkpointStore.load(transferId)
                        if (existing != null) {
                            val merged = (existing.ackedChunks.toList() + listOf(idx)).distinct().sorted().toIntArray()
                            checkpointStore.save(existing.copy(ackedChunks = merged))
                        }
                    }
                }
            }
            CrossNetworkFileTransferOp.completeAck -> {
                // sender-side completion; stop tracking
                sendContexts.remove(msg.transferId)
                scope.launch { checkpointStore.delete(msg.transferId) }

                // If this transfer belongs to a batch, mark completed.
                val ref = sendBatchByTransferId.remove(msg.transferId)
                if (ref != null) {
                    scope.launch {
                        val store = batchManifestStore ?: return@launch
                        val current = store.load(ref.batchId) ?: return@launch
                        val updated = current.entries.map { e ->
                            if (e.transferId == msg.transferId) e.copy(status = BatchManifestEntry.Status.COMPLETED, updatedAtMs = System.currentTimeMillis())
                            else e
                        }
                        store.save(current.copy(entries = updated, updatedAtMs = System.currentTimeMillis()))
                    }
                }
            }
            CrossNetworkFileTransferOp.error -> {
                // reserved for future: resend-on-demand. For now, treat as status update.
                _progress.value = _progress.value.copy(lastStatus = "peer error: ${msg.message}")
            }
            else -> Unit
        }
    }

    private fun startInboundApprovalIfNeeded(ctx: ReceiveContext) {
        if (ctx.approvalDecision != null || ctx.approvalJob != null || ctx.declined) return

        val provider = inboundApprovalProvider
        if (provider == null) {
            // No approval provider: default-accept, but never overwrite. (Used by demo screens/tests.)
            val displayName = sanitizeDownloadsDisplayName(ctx.fileName ?: "skybridge-received-${ctx.transferId}")
            ctx.approvalDecision = InboundFileTransferDecision.Accept(
                downloadsDisplayName = displayName,
                overwriteExisting = false
            )
            maybeFinalizeIfReady(ctx)
            return
        }

        ctx.approvalJob = scope.launch {
            val decision = runCatching {
                provider.requestDecision(
                    InboundFileTransferApprovalRequest(
                        transferId = ctx.transferId,
                        fileName = ctx.fileName,
                        mimeType = ctx.mimeType,
                        fileSizeBytes = ctx.totalBytes,
                        senderDeviceId = ctx.senderDeviceId,
                        senderDeviceName = ctx.senderDeviceName
                    )
                )
            }.getOrElse {
                InboundFileTransferDecision.Decline
            }

            val current = receiveContexts[ctx.transferId] ?: return@launch
            current.approvalDecision = decision

            when (decision) {
                is InboundFileTransferDecision.Accept -> maybeFinalizeIfReady(current)
                InboundFileTransferDecision.Decline -> abortInboundReceive(current, reason = "declined")
            }
        }
    }

    private fun abortInboundReceive(ctx: ReceiveContext, reason: String) {
        ctx.declined = true
        val removed = receiveContexts.remove(ctx.transferId) ?: return
        runCatching { removed.approvalJob?.cancel() }
        runCatching { removed.raf?.close() }
        runCatching { removed.partialFile?.delete() }
        scope.launch { checkpointStore.delete(removed.transferId) }
        _progress.value = Progress(
            transferId = removed.transferId,
            sentBytes = removed.receivedBytes,
            totalBytes = removed.totalBytes ?: removed.receivedBytes,
            lastStatus = "inbound declined ($reason)"
        )
        // Best-effort notify peer.
        webrtc.send(
            encode(
                CrossNetworkFileTransferMessage(
                    version = removed.version,
                    op = CrossNetworkFileTransferOp.error,
                    transferId = removed.transferId,
                    message = "declined"
                )
            )
        )
    }

    private fun isReceiveComplete(ctx: ReceiveContext): Boolean {
        if (!ctx.completeReceived) return false
        val totalChunks = ctx.totalChunks
        return totalChunks == null || totalChunks <= 0 || ctx.receivedChunkIndices.size == totalChunks
    }

    private fun maybeFinalizeIfReady(ctx: ReceiveContext) {
        val decision = ctx.approvalDecision
        if (decision !is InboundFileTransferDecision.Accept) return
        if (!isReceiveComplete(ctx)) return
        finalizeReceive(ctx, decision, receivedBytesHint = ctx.completeReceivedBytes)
    }

    private data class DownloadsSaveResult(
        val uri: Uri,
        val displayName: String
    )

    private fun finalizeReceive(
        ctx: ReceiveContext,
        decision: InboundFileTransferDecision.Accept,
        receivedBytesHint: Long?
    ) {
        // Remove first so we don't emit twice if duplicates arrive.
        val removed = receiveContexts.remove(ctx.transferId) ?: return
        runCatching { removed.approvalJob?.cancel() }
        runCatching { removed.raf?.close() }
        val expectedSize = removed.totalBytes
        val actualSize = removed.partialFile?.let { runCatching { it.length() }.getOrNull() } ?: removed.buffer.size().toLong()
        val sizeOk = expectedSize == null || expectedSize == actualSize

        val expectedHash = removed.expectedFileSha256
        val actualHash = runCatching {
            if (removed.partialFile != null) {
                sha256File(removed.partialFile!!)
            } else {
                sha256(removed.buffer.toByteArray())
            }
        }.getOrNull()
        val hashOk = expectedHash == null || (actualHash != null && actualHash.contentEquals(expectedHash))

        if (!hashOk) {
            removed.partialFile?.delete()
            scope.launch { checkpointStore.delete(removed.transferId) }
            _progress.value = Progress(
                transferId = removed.transferId,
                sentBytes = actualSize,
                totalBytes = expectedSize ?: actualSize,
                lastStatus = "received complete (file sha256 mismatch)"
            )
            webrtc.send(
                encode(
                    CrossNetworkFileTransferMessage(
                        version = removed.version,
                        op = CrossNetworkFileTransferOp.error,
                        transferId = removed.transferId,
                        message = "file sha256 mismatch"
                    )
                )
            )
            return
        }

        // Merkle root verification (optional; enforce only if provided)
        val expectedMerkle = removed.expectedMerkleRoot
        if (expectedMerkle != null) {
            val totalChunks = removed.totalChunks
            val leaves = if (totalChunks != null && totalChunks > 0) {
                val out = ArrayList<ByteArray>(totalChunks)
                for (i in 0 until totalChunks) {
                    val h = removed.chunkHashes[i]
                    if (h == null) {
                        // Can't verify; treat as failure when merkleRoot was provided.
                        scope.launch { checkpointStore.delete(removed.transferId) }
                        _progress.value = Progress(
                            transferId = removed.transferId,
                            sentBytes = actualSize,
                            totalBytes = expectedSize ?: actualSize,
                            lastStatus = "received complete (missing chunk hashes for merkle)"
                        )
                        webrtc.send(
                            encode(
                                CrossNetworkFileTransferMessage(
                                    version = removed.version,
                                    op = CrossNetworkFileTransferOp.error,
                                    transferId = removed.transferId,
                                    message = "missing chunk hashes for merkle"
                                )
                            )
                        )
                        return
                    }
                    out.add(h)
                }
                out
            } else {
                null
            }

            val actualMerkle = leaves?.let { runCatching { MerkleSha256.root(it) }.getOrNull() }
            if (actualMerkle == null || !actualMerkle.contentEquals(expectedMerkle)) {
                removed.partialFile?.delete()
                scope.launch { checkpointStore.delete(removed.transferId) }
                _progress.value = Progress(
                    transferId = removed.transferId,
                    sentBytes = actualSize,
                    totalBytes = expectedSize ?: actualSize,
                    lastStatus = "received complete (merkle root mismatch)"
                )
                webrtc.send(
                    encode(
                        CrossNetworkFileTransferMessage(
                            version = removed.version,
                            op = CrossNetworkFileTransferOp.error,
                            transferId = removed.transferId,
                            message = "merkle root mismatch"
                        )
                    )
                )
                return
            }

            // Optional MAC verification (only if present and algorithm matches)
            val sig = removed.expectedMerkleSig
            val alg = removed.expectedMerkleSigAlg
            if (sig != null) {
                if (alg != "hmac-sha256-session-v1") {
                    removed.partialFile?.delete()
                    scope.launch { checkpointStore.delete(removed.transferId) }
                    _progress.value = Progress(
                        transferId = removed.transferId,
                        sentBytes = actualSize,
                        totalBytes = expectedSize ?: actualSize,
                        lastStatus = "received complete (unknown merkle sig alg)"
                    )
                    webrtc.send(
                        encode(
                            CrossNetworkFileTransferMessage(
                                version = removed.version,
                                op = CrossNetworkFileTransferOp.error,
                                transferId = removed.transferId,
                                message = "unknown merkle sig alg"
                            )
                        )
                    )
                    return
                }

                val preimage = MerkleRootAuthV1.preimage(
                    transferId = removed.transferId,
                    merkleRoot = expectedMerkle,
                    fileSha256 = removed.expectedFileSha256
                )
                val ok = webrtc.verifyInboundHmacSha256(preimage, sig)
                if (!ok) {
                    removed.partialFile?.delete()
                    scope.launch { checkpointStore.delete(removed.transferId) }
                    _progress.value = Progress(
                        transferId = removed.transferId,
                        sentBytes = actualSize,
                        totalBytes = expectedSize ?: actualSize,
                        lastStatus = "received complete (merkle signature mismatch)"
                    )
                    webrtc.send(
                        encode(
                            CrossNetworkFileTransferMessage(
                                version = removed.version,
                                op = CrossNetworkFileTransferOp.error,
                                transferId = removed.transferId,
                                message = "merkle signature mismatch"
                            )
                        )
                    )
                    return
                }
            }
        }

        var outLocalPath: String? = removed.partialFile?.absolutePath
        var outBytes: ByteArray? = if (removed.partialFile != null) null else removed.buffer.toByteArray()
        var downloadsUri: String? = null
        var downloadsDisplayName: String? = null

        if (saveAcceptedInboundToDownloads) {
            val ctx = appContext
            if (ctx != null) {
                val save = runCatching { saveInboundToDownloads(ctx, removed, decision) }.getOrNull()
                if (save != null) {
                    downloadsUri = save.uri.toString()
                    downloadsDisplayName = save.displayName
                    outLocalPath = null
                    outBytes = null
                    // Keep storage tidy: remove the private partial after successful commit to Downloads.
                    runCatching { removed.partialFile?.delete() }
                }
            }
        }

        _progress.value = Progress(
            transferId = removed.transferId,
            sentBytes = actualSize,
            totalBytes = expectedSize ?: actualSize,
            lastStatus = buildString {
                append(if (sizeOk) "received complete" else "received complete (size mismatch)")
                if (downloadsDisplayName != null) append(" → Downloads/$downloadsDisplayName")
            }
        )
        _receivedFiles.tryEmit(
            ReceivedFile(
                transferId = removed.transferId,
                fileName = downloadsDisplayName ?: removed.fileName,
                mimeType = removed.mimeType,
                bytes = outBytes,
                localPath = outLocalPath,
                downloadsUri = downloadsUri,
                downloadsDisplayName = downloadsDisplayName
            )
        )
        scope.launch { checkpointStore.delete(removed.transferId) }
        webrtc.send(
            encode(
                CrossNetworkFileTransferMessage(
                    version = removed.version,
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = removed.transferId,
                    receivedBytes = receivedBytesHint ?: expectedSize ?: actualSize
                )
            )
        )
    }

    private fun saveInboundToDownloads(
        context: Context,
        removed: ReceiveContext,
        decision: InboundFileTransferDecision.Accept
    ): DownloadsSaveResult {
        val resolver = context.contentResolver
        val desired = sanitizeDownloadsDisplayName(
            decision.downloadsDisplayName.ifBlank { removed.fileName ?: "skybridge-received" }
        )

        val targetName = if (!decision.overwriteExisting) {
            uniqueDownloadsDisplayName(context, desired)
        } else {
            // Best-effort: delete by name first (may fail due to scoped storage restrictions).
            runCatching {
                resolver.delete(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    "${MediaStore.MediaColumns.DISPLAY_NAME}=?",
                    arrayOf(desired)
                )
            }
            desired
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, targetName)
            put(MediaStore.MediaColumns.MIME_TYPE, removed.mimeType ?: "application/octet-stream")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("MediaStore insert failed")

        try {
            resolver.openOutputStream(uri, "wt")?.use { os ->
                val partial = removed.partialFile
                if (partial != null && partial.exists()) {
                    partial.inputStream().use { it.copyTo(os) }
                } else {
                    os.write(removed.buffer.toByteArray())
                }
                os.flush()
            } ?: error("openOutputStream failed")
        } catch (e: Exception) {
            // Best-effort cleanup so we don't leave a broken entry in Downloads.
            runCatching { resolver.delete(uri, null, null) }
            throw e
        } finally {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                runCatching {
                    val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                    resolver.update(uri, done, null, null)
                }
            }
        }

        return DownloadsSaveResult(uri = uri, displayName = targetName)
    }

    private fun sanitizeDownloadsDisplayName(raw: String): String {
        val cleaned = raw
            .replace('/', '_')
            .replace('\\', '_')
            .trim()
        return cleaned.ifBlank { "skybridge-received" }
    }

    private fun downloadsItemExists(context: Context, displayName: String): Boolean {
        val resolver = context.contentResolver
        val uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val selection = "${MediaStore.MediaColumns.DISPLAY_NAME}=?"
        val args = arrayOf(displayName)
        resolver.query(uri, projection, selection, args, null)?.use { cursor ->
            return cursor.moveToFirst()
        }
        return false
    }

    private fun uniqueDownloadsDisplayName(context: Context, desiredName: String): String {
        if (!downloadsItemExists(context, desiredName)) return desiredName

        val dot = desiredName.lastIndexOf('.')
        val hasExt = dot > 0 && dot < desiredName.lastIndex
        val base = if (hasExt) desiredName.substring(0, dot) else desiredName
        val ext = if (hasExt) desiredName.substring(dot + 1) else ""

        for (i in 1..999) {
            val candidate = if (hasExt) "$base ($i).$ext" else "$base ($i)"
            if (!downloadsItemExists(context, candidate)) return candidate
        }
        return "${base}-${System.currentTimeMillis()}${if (hasExt) ".$ext" else ""}"
    }

    private fun sendChunk(
        transferId: String,
        index: Int,
        chunkBytes: ByteArray,
        receivedBytes: Long? = null
    ) {
        val msg = CrossNetworkFileTransferMessage(
            version = 1,
            op = CrossNetworkFileTransferOp.chunk,
            transferId = transferId,
            chunkIndex = index,
            chunkData = chunkBytes,
            chunkSha256 = sha256(chunkBytes),
            rawSize = chunkBytes.size,
            receivedBytes = receivedBytes
        )
        webrtc.send(encode(msg))
        sendContexts[transferId]?.let { ctx ->
            if (index in 0 until ctx.totalChunks) {
                ctx.sendAttempts[index] += 1
            }
        }
    }

    private fun startResendLoopIfNeeded(transferId: String) {
        val ctx = sendContexts[transferId] ?: return
        // lightweight retry loop: only resend unacked chunks a few times
        scope.launch {
            val maxAttempts = 3
            val resendDelayMs = 1200L
            while (isActive) {
                delay(resendDelayMs)
                val stillTracked = sendContexts[transferId] ?: break
                var anyPending = false
                for (i in 0 until stillTracked.totalChunks) {
                    val acked = stillTracked.acked[i]
                    if (!acked) {
                        anyPending = true
                        if (stillTracked.sendAttempts[i] < maxAttempts) {
                            sendChunk(transferId, i, stillTracked.chunks[i])
                        }
                    }
                }
                if (!anyPending) {
                    // all acked: sender can remain idle until completeAck, but we stop retrying
                    break
                }
            }
        }
    }

    private fun sendCompleteFromContext(ctx: SendContext) {
        val fileDigest = MessageDigest.getInstance("SHA-256")
        ctx.chunks.forEach { fileDigest.update(it) }
        val fileSha256 = fileDigest.digest()

        val leaves = ctx.chunks.map { sha256(it) }
        val merkleRoot = runCatching { MerkleSha256.root(leaves) }.getOrNull()
        val merkleSig = if (merkleRoot != null) {
            webrtc.computeOutboundHmacSha256(
                MerkleRootAuthV1.preimage(transferId = ctx.transferId, merkleRoot = merkleRoot, fileSha256 = fileSha256)
            )
        } else null

        webrtc.send(
            encode(
                CrossNetworkFileTransferMessage(
                    version = 1,
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = ctx.transferId,
                    receivedBytes = ctx.totalBytes,
                    fileSha256 = fileSha256,
                    merkleRoot = merkleRoot,
                    merkleRootSignature = merkleSig,
                    merkleRootSignatureAlg = if (merkleSig != null) "hmac-sha256-session-v1" else null
                )
            )
        )
    }

    private fun sha256(data: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(data)

    private fun sha256File(file: File): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { ins ->
            val buf = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val n = ins.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest()
    }

    private fun encode(msg: CrossNetworkFileTransferMessage): ByteArray =
        json.encodeToString(CrossNetworkFileTransferMessage.serializer(), msg).encodeToByteArray()
}
