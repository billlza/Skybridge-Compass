package com.skybridge.compass.shared.p2p.filetransfer

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/**
 * Wire-compatible JSON models for Pro release P2P file transfer (Swift Codable / JSONEncoder).
 *
 * Important compatibility points:
 * - Swift Data is encoded as base64 strings in JSON. We mirror that with [Base64ByteArraySerializer].
 * - Swift UUID is encoded as a string. We mirror that with [UuidAsStringSerializer].
 */

object Base64ByteArraySerializer : KSerializer<ByteArray> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("Base64ByteArray", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: ByteArray) {
        encoder.encodeString(Base64.getEncoder().encodeToString(value))
    }

    override fun deserialize(decoder: Decoder): ByteArray =
        Base64.getDecoder().decode(decoder.decodeString())
}

object UuidAsStringSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("UUID", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: UUID) {
        encoder.encodeString(value.toString())
    }

    override fun deserialize(decoder: Decoder): UUID =
        UUID.fromString(decoder.decodeString())
}

@Serializable
enum class P2PFileNodeType {
    file,
    directory,
    symlink
}

@Serializable
data class P2PFileNode(
    val nodeType: P2PFileNodeType,
    val name: String,
    val relativePath: String,
    val size: ULong,
    val mtimeMillis: Long,
    val permissions: Int, // Swift: UInt16 (e.g., 0o644)
    @Serializable(with = Base64ByteArraySerializer::class)
    val fileHash: ByteArray? = null,
    val children: List<P2PFileNode>? = null,
    val startChunkIndex: ULong? = null,
    val chunkCount: ULong? = null
)

@Serializable
data class P2PFileTransferMetadata(
    @Serializable(with = UuidAsStringSerializer::class)
    val transferId: UUID,
    val fileTree: P2PFileNode,
    val totalSize: ULong,
    val totalFileCount: Int,
    @Serializable(with = Base64ByteArraySerializer::class)
    val merkleRoot: ByteArray,
    @Serializable(with = Base64ByteArraySerializer::class)
    val merkleRootSignature: ByteArray,
    val chunkSize: Int,
    val totalChunks: ULong,
    val createdAtMillis: Long,
    val protocolVersion: Int
)

@Serializable
data class P2PFileChunk(
    @Serializable(with = UuidAsStringSerializer::class)
    val transferId: UUID,
    val chunkIndex: ULong,
    val filePath: String,
    val offset: ULong,
    @Serializable(with = Base64ByteArraySerializer::class)
    val data: ByteArray,
    @Serializable(with = Base64ByteArraySerializer::class)
    val chunkHash: ByteArray,
    val isLastChunk: Boolean
) {
    fun verifyHash(): Boolean {
        val computed = MessageDigest.getInstance("SHA-256").digest(data)
        return computed.contentEquals(chunkHash)
    }
}

@Serializable
enum class P2PChunkAckType {
    received,
    checksum_failed,
    retransmit_request
}

@Serializable
data class P2PFileChunkAck(
    @Serializable(with = UuidAsStringSerializer::class)
    val transferId: UUID,
    val acknowledgedChunks: List<ULong>,
    val ackType: P2PChunkAckType = P2PChunkAckType.received,
    val timestampMillis: Long
)


