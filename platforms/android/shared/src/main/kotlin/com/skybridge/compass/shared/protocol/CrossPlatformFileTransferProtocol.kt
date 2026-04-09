package com.skybridge.compass.shared.protocol

import com.skybridge.compass.shared.crypto.CrossPlatformKeyDerivation
import com.skybridge.compass.shared.crypto.HandshakeManager
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.zip.Deflater
import java.util.zip.Inflater
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 跨平台文件传输协议
 * 
 * 确保 Android 与 iOS/macOS 之间文件传输的完全兼容性
 * 
 * 协议格式（与 iOS/macOS FileTransferEngine 兼容）:
 * - Magic: "SBFT" (4 bytes)
 * - Version: UInt16 (2 bytes, little-endian)
 * - MessageType: UInt8 (1 byte)
 * - Flags: UInt8 (1 byte)
 * - PayloadLength: UInt32 (4 bytes, little-endian)
 * - Payload: [PayloadLength] bytes
 */
object CrossPlatformFileTransferProtocol {
    
    // 魔数标识
    private val MAGIC = byteArrayOf(0x53, 0x42, 0x46, 0x54) // "SBFT"
    
    // 协议版本
    const val PROTOCOL_VERSION: UShort = 0x0001u
    
    // 消息类型（与 iOS/macOS 保持一致）
    object MessageType {
        const val METADATA: UByte = 0x01u      // 文件元数据
        const val CHUNK: UByte = 0x02u         // 数据块
        const val COMPLETE: UByte = 0x03u      // 传输完成
        const val ACK: UByte = 0x04u           // 确认
        const val RESUME_REQ: UByte = 0x05u    // 断点续传请求
        const val RESUME_ACK: UByte = 0x06u    // 断点续传确认
        const val ERROR: UByte = 0x07u         // 错误
        const val CANCEL: UByte = 0x08u        // 取消
    }
    
    // 标志位
    object Flags {
        const val COMPRESSED: UByte = 0x01u    // 数据已压缩
        const val ENCRYPTED: UByte = 0x02u     // 数据已加密
        const val HAS_CHECKSUM: UByte = 0x04u  // 包含校验和
        const val HAS_SIGNATURE: UByte = 0x08u // 包含签名
        const val LAST_CHUNK: UByte = 0x10u    // 最后一个数据块
    }
    
    /**
     * 文件传输元数据
     * 与 iOS/macOS FileTransferMetadata 结构兼容
     */
    data class FileTransferMetadata(
        val transferId: String,
        val fileName: String,
        val fileSize: Long,
        val checksum: String,
        val merkleRoot: String? = null,
        val hashAlgorithm: String = "SHA256",
        val compressionEnabled: Boolean = false,
        val encryptionEnabled: Boolean = false,
        val chunkSize: Int = 1024 * 1024, // 1MB default
        val fileSignature: ByteArray? = null,
        val signatureAlgorithm: String? = null,
        val signerPeerId: String? = null,
        val timestamp: Long = System.currentTimeMillis()
    )
    
    /**
     * 数据块包
     * 与 iOS/macOS FileChunkPacket 结构兼容
     */
    data class FileChunkPacket(
        val transferId: String,
        val chunkIndex: Int,
        val totalChunks: Int,
        val data: ByteArray,
        val aeadNonce: ByteArray? = null,
        val aeadTag: ByteArray? = null,
        val isCompressed: Boolean = false,
        val isEncrypted: Boolean = false,
        val checksum: String,
        val timestamp: Long = System.currentTimeMillis()
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is FileChunkPacket) return false
            return transferId == other.transferId && chunkIndex == other.chunkIndex
        }
        
        override fun hashCode(): Int {
            return 31 * transferId.hashCode() + chunkIndex
        }
    }
    
    /**
     * 序列化文件元数据
     * 使用 JSON 格式（与 iOS/macOS 兼容）
     */
    fun serializeMetadata(metadata: FileTransferMetadata): ByteArray {
        val json = buildString {
            append("{")
            append("\"transferId\":\"${metadata.transferId}\",")
            append("\"fileName\":\"${escapeJson(metadata.fileName)}\",")
            append("\"fileSize\":${metadata.fileSize},")
            append("\"checksum\":\"${metadata.checksum}\",")
            metadata.merkleRoot?.let { append("\"merkleRoot\":\"$it\",") }
            append("\"hashAlgorithm\":\"${metadata.hashAlgorithm}\",")
            append("\"compressionEnabled\":${metadata.compressionEnabled},")
            append("\"encryptionEnabled\":${metadata.encryptionEnabled},")
            append("\"chunkSize\":${metadata.chunkSize},")
            metadata.fileSignature?.let { 
                append("\"fileSignature\":\"${bytesToBase64(it)}\",")
            }
            metadata.signatureAlgorithm?.let { append("\"signatureAlgorithm\":\"$it\",") }
            metadata.signerPeerId?.let { append("\"signerPeerId\":\"$it\",") }
            append("\"timestamp\":${metadata.timestamp}")
            append("}")
        }
        return json.toByteArray(Charsets.UTF_8)
    }
    
    /**
     * 反序列化文件元数据
     */
    fun deserializeMetadata(data: ByteArray): FileTransferMetadata {
        val json = String(data, Charsets.UTF_8)
        // 简单的 JSON 解析（实际项目中应使用 kotlinx.serialization）
        val transferId = extractJsonString(json, "transferId") ?: ""
        val fileName = extractJsonString(json, "fileName") ?: ""
        val fileSize = extractJsonLong(json, "fileSize") ?: 0L
        val checksum = extractJsonString(json, "checksum") ?: ""
        val merkleRoot = extractJsonString(json, "merkleRoot")
        val hashAlgorithm = extractJsonString(json, "hashAlgorithm") ?: "SHA256"
        val compressionEnabled = extractJsonBoolean(json, "compressionEnabled") ?: false
        val encryptionEnabled = extractJsonBoolean(json, "encryptionEnabled") ?: false
        val chunkSize = extractJsonInt(json, "chunkSize") ?: 1024 * 1024
        val fileSignatureBase64 = extractJsonString(json, "fileSignature")
        val signatureAlgorithm = extractJsonString(json, "signatureAlgorithm")
        val signerPeerId = extractJsonString(json, "signerPeerId")
        val timestamp = extractJsonLong(json, "timestamp") ?: System.currentTimeMillis()
        
        return FileTransferMetadata(
            transferId = transferId,
            fileName = fileName,
            fileSize = fileSize,
            checksum = checksum,
            merkleRoot = merkleRoot,
            hashAlgorithm = hashAlgorithm,
            compressionEnabled = compressionEnabled,
            encryptionEnabled = encryptionEnabled,
            chunkSize = chunkSize,
            fileSignature = fileSignatureBase64?.let { base64ToBytes(it) },
            signatureAlgorithm = signatureAlgorithm,
            signerPeerId = signerPeerId,
            timestamp = timestamp
        )
    }
    
    /**
     * 序列化数据块头部
     * 格式: transferId(36) + chunkIndex(4) + totalChunks(4) + dataLength(8) + 
     *       checksum(64) + flags(1) + timestamp(8) = 125 bytes
     */
    fun serializeChunkHeader(packet: FileChunkPacket): ByteArray {
        val buffer = ByteBuffer.allocate(125)
        buffer.order(ByteOrder.BIG_ENDIAN)
        
        // transferId (36 bytes, padded)
        val transferIdBytes = packet.transferId.toByteArray(Charsets.UTF_8)
        val paddedTransferId = ByteArray(36)
        System.arraycopy(transferIdBytes, 0, paddedTransferId, 0, 
            minOf(transferIdBytes.size, 36))
        buffer.put(paddedTransferId)
        
        // chunkIndex (4 bytes)
        buffer.putInt(packet.chunkIndex)
        
        // totalChunks (4 bytes)
        buffer.putInt(packet.totalChunks)
        
        // dataLength (8 bytes)
        buffer.putLong(packet.data.size.toLong())
        
        // checksum (64 bytes, padded with spaces)
        val checksumBytes = packet.checksum.toByteArray(Charsets.UTF_8)
        val paddedChecksum = ByteArray(64) { 0x20 } // space padding
        System.arraycopy(checksumBytes, 0, paddedChecksum, 0, 
            minOf(checksumBytes.size, 64))
        buffer.put(paddedChecksum)
        
        // flags (1 byte)
        var flags: UByte = 0u
        if (packet.isCompressed) flags = flags or Flags.COMPRESSED
        if (packet.isEncrypted) flags = flags or Flags.ENCRYPTED
        if (packet.chunkIndex == packet.totalChunks - 1) flags = flags or Flags.LAST_CHUNK
        buffer.put(flags.toByte())
        
        // timestamp (8 bytes)
        buffer.putDouble(packet.timestamp / 1000.0) // Convert to seconds
        
        return buffer.array()
    }
    
    /**
     * 反序列化数据块头部
     */
    fun deserializeChunkHeader(headerData: ByteArray): ChunkHeaderInfo {
        require(headerData.size >= 125) { "Header too short: ${headerData.size}" }
        
        val buffer = ByteBuffer.wrap(headerData)
        buffer.order(ByteOrder.BIG_ENDIAN)
        
        val transferIdBytes = ByteArray(36)
        buffer.get(transferIdBytes)
        val transferId = String(transferIdBytes, Charsets.UTF_8).trim('\u0000')
        
        val chunkIndex = buffer.int
        val totalChunks = buffer.int
        val dataLength = buffer.long
        
        val checksumBytes = ByteArray(64)
        buffer.get(checksumBytes)
        val checksum = String(checksumBytes, Charsets.UTF_8).trim()
        
        val flags = buffer.get().toUByte()
        val isCompressed = (flags and Flags.COMPRESSED) != 0.toUByte()
        val isEncrypted = (flags and Flags.ENCRYPTED) != 0.toUByte()
        val isLastChunk = (flags and Flags.LAST_CHUNK) != 0.toUByte()
        
        val timestampSeconds = buffer.double
        val timestamp = (timestampSeconds * 1000).toLong()
        
        return ChunkHeaderInfo(
            transferId = transferId,
            chunkIndex = chunkIndex,
            totalChunks = totalChunks,
            dataLength = dataLength,
            checksum = checksum,
            isCompressed = isCompressed,
            isEncrypted = isEncrypted,
            isLastChunk = isLastChunk,
            timestamp = timestamp
        )
    }
    
    data class ChunkHeaderInfo(
        val transferId: String,
        val chunkIndex: Int,
        val totalChunks: Int,
        val dataLength: Long,
        val checksum: String,
        val isCompressed: Boolean,
        val isEncrypted: Boolean,
        val isLastChunk: Boolean,
        val timestamp: Long
    )
    
    /**
     * 构建协议消息
     */
    fun buildMessage(
        messageType: UByte,
        payload: ByteArray,
        flags: UByte = 0u
    ): ByteArray {
        val buffer = ByteBuffer.allocate(12 + payload.size)
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        
        // Magic (4 bytes)
        buffer.put(MAGIC)
        
        // Version (2 bytes)
        buffer.putShort(PROTOCOL_VERSION.toShort())
        
        // MessageType (1 byte)
        buffer.put(messageType.toByte())
        
        // Flags (1 byte)
        buffer.put(flags.toByte())
        
        // PayloadLength (4 bytes)
        buffer.putInt(payload.size)
        
        // Payload
        buffer.put(payload)
        
        return buffer.array()
    }
    
    /**
     * 解析协议消息
     */
    fun parseMessage(data: ByteArray): ParsedMessage {
        require(data.size >= 12) { "Message too short: ${data.size}" }
        
        val buffer = ByteBuffer.wrap(data)
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        
        // Verify magic
        val magic = ByteArray(4)
        buffer.get(magic)
        require(magic.contentEquals(MAGIC)) { "Invalid magic: ${magic.contentToString()}" }
        
        val version = buffer.short.toUShort()
        val messageType = buffer.get().toUByte()
        val flags = buffer.get().toUByte()
        val payloadLength = buffer.int
        
        require(data.size >= 12 + payloadLength) { 
            "Incomplete message: expected ${12 + payloadLength}, got ${data.size}" 
        }
        
        val payload = ByteArray(payloadLength)
        buffer.get(payload)
        
        return ParsedMessage(version, messageType, flags, payload)
    }
    
    data class ParsedMessage(
        val version: UShort,
        val messageType: UByte,
        val flags: UByte,
        val payload: ByteArray
    )
    
    /**
     * 计算 SHA-256 校验和
     */
    fun calculateChecksum(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(data)
        return hash.joinToString("") { "%02x".format(it) }
    }
    
    /**
     * 计算 Merkle 根
     * 与 iOS/macOS computeMerkleRoot 兼容
     */
    fun computeMerkleRoot(chunks: List<ByteArray>): String {
        if (chunks.isEmpty()) {
            val digest = MessageDigest.getInstance("SHA-256")
            return digest.digest(ByteArray(0)).joinToString("") { "%02x".format(it) }
        }
        
        var leafHashes = chunks.map { chunk ->
            val digest = MessageDigest.getInstance("SHA-256")
            digest.digest(chunk)
        }
        
        while (leafHashes.size > 1) {
            val nextLevel = mutableListOf<ByteArray>()
            var i = 0
            while (i < leafHashes.size) {
                val left = leafHashes[i]
                val right = if (i + 1 < leafHashes.size) leafHashes[i + 1] else left
                
                val digest = MessageDigest.getInstance("SHA-256")
                digest.update(left)
                digest.update(right)
                nextLevel.add(digest.digest())
                
                i += 2
            }
            leafHashes = nextLevel
        }
        
        return leafHashes[0].joinToString("") { "%02x".format(it) }
    }
    
    /**
     * 压缩数据
     * 使用 DEFLATE（兼容 iOS/macOS 的 LZFSE，但更通用）
     */
    fun compressData(data: ByteArray): ByteArray {
        if (data.isEmpty()) return data
        
        val deflater = Deflater(Deflater.BEST_SPEED)
        deflater.setInput(data)
        deflater.finish()
        
        val outputStream = ByteArrayOutputStream(data.size)
        val buffer = ByteArray(1024)
        
        while (!deflater.finished()) {
            val count = deflater.deflate(buffer)
            outputStream.write(buffer, 0, count)
        }
        
        deflater.end()
        
        val compressed = outputStream.toByteArray()
        
        // 如果压缩后更大，返回原始数据
        return if (compressed.size >= data.size) data else compressed
    }
    
    /**
     * 解压数据
     */
    fun decompressData(data: ByteArray): ByteArray {
        if (data.isEmpty()) return data
        
        val inflater = Inflater()
        inflater.setInput(data)
        
        val outputStream = ByteArrayOutputStream(data.size * 2)
        val buffer = ByteArray(1024)
        
        try {
            while (!inflater.finished()) {
                val count = inflater.inflate(buffer)
                if (count == 0) break
                outputStream.write(buffer, 0, count)
            }
        } catch (e: Exception) {
            // 解压失败，可能数据未压缩，返回原始数据
            return data
        } finally {
            inflater.end()
        }
        
        return outputStream.toByteArray()
    }
    
    /**
     * AES-GCM 加密
     * 与 iOS/macOS EnhancedPostQuantumCrypto 兼容
     */
    fun encryptAesGcm(
        data: ByteArray,
        key: ByteArray
    ): EncryptedChunk {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val nonce = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
        val gcmSpec = GCMParameterSpec(128, nonce)
        val secretKey = SecretKeySpec(key, "AES")
        
        cipher.init(Cipher.ENCRYPT_MODE, secretKey, gcmSpec)
        val ciphertext = cipher.doFinal(data)
        
        // GCM 的 ciphertext 包含 tag (最后16字节)
        val actualCiphertext = ciphertext.copyOf(ciphertext.size - 16)
        val tag = ciphertext.copyOfRange(ciphertext.size - 16, ciphertext.size)
        
        return EncryptedChunk(
            ciphertext = actualCiphertext,
            nonce = nonce,
            tag = tag
        )
    }
    
    /**
     * AES-GCM 解密
     */
    fun decryptAesGcm(
        encrypted: EncryptedChunk,
        key: ByteArray
    ): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val gcmSpec = GCMParameterSpec(128, encrypted.nonce)
        val secretKey = SecretKeySpec(key, "AES")
        
        cipher.init(Cipher.DECRYPT_MODE, secretKey, gcmSpec)
        
        // 重新组合 ciphertext + tag
        val ciphertextWithTag = encrypted.ciphertext + encrypted.tag
        return cipher.doFinal(ciphertextWithTag)
    }
    
    data class EncryptedChunk(
        val ciphertext: ByteArray,
        val nonce: ByteArray,
        val tag: ByteArray
    )
    
    /**
     * 计算 HMAC-SHA256
     * 与 iOS/macOS computeFileHMACTag 兼容
     */
    fun computeHmacSha256(data: ByteArray, key: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        val secretKey = SecretKeySpec(key, "HmacSHA256")
        mac.init(secretKey)
        return mac.doFinal(data)
    }
    
    // ========== 辅助方法 ==========
    
    private fun escapeJson(s: String): String {
        return s.replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
    }
    
    private fun extractJsonString(json: String, key: String): String? {
        val pattern = "\"$key\"\\s*:\\s*\"([^\"]*)\""
        val regex = Regex(pattern)
        return regex.find(json)?.groupValues?.get(1)
    }
    
    private fun extractJsonLong(json: String, key: String): Long? {
        val pattern = "\"$key\"\\s*:\\s*(-?\\d+)"
        val regex = Regex(pattern)
        return regex.find(json)?.groupValues?.get(1)?.toLongOrNull()
    }
    
    private fun extractJsonInt(json: String, key: String): Int? {
        return extractJsonLong(json, key)?.toInt()
    }
    
    private fun extractJsonBoolean(json: String, key: String): Boolean? {
        val pattern = "\"$key\"\\s*:\\s*(true|false)"
        val regex = Regex(pattern)
        return regex.find(json)?.groupValues?.get(1)?.toBooleanStrictOrNull()
    }
    
    private fun bytesToBase64(bytes: ByteArray): String {
        return android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
    }
    
    private fun base64ToBytes(base64: String): ByteArray {
        return android.util.Base64.decode(base64, android.util.Base64.NO_WRAP)
    }
}

