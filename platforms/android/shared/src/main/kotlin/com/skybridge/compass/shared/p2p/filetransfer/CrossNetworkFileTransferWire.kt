package com.skybridge.compass.shared.p2p.filetransfer

import kotlinx.serialization.Serializable

/**
 * Wire-compatible model for Pro release CrossNetworkFileTransferMessage (WebRTC DataChannel).
 *
 * Swift Codable notes:
 * - Optional fields are omitted when null.
 * - Data fields are base64 strings in JSON.
 */
@Serializable
enum class CrossNetworkFileTransferOp {
    metadata,
    metadataAck,
    chunk,
    chunkAck,
    complete,
    completeAck,
    cancel,
    error
}

@Serializable
data class CrossNetworkFileTransferMessage(
    val version: Int = 1,
    val op: CrossNetworkFileTransferOp,
    val transferId: String,

    val senderDeviceId: String? = null,
    val senderDeviceName: String? = null,

    val fileName: String? = null,
    val fileSize: Long? = null,
    val chunkSize: Int? = null,
    val totalChunks: Int? = null,
    val mimeType: String? = null,

    /**
     * Optional capabilities negotiated at application layer.
     * Backward compatible: older clients ignore unknown fields; if absent, treat as no extra features.
     */
    val encryption: String? = null, // e.g. "aes-gcm-256-v1" (future)

    val chunkIndex: Int? = null,
    @Serializable(with = Base64ByteArraySerializer::class)
    val chunkData: ByteArray? = null,
    @Serializable(with = Base64ByteArraySerializer::class)
    val nonce: ByteArray? = null, // for encrypted chunks (future)
    @Serializable(with = Base64ByteArraySerializer::class)
    val chunkSha256: ByteArray? = null, // integrity for chunkData (plaintext or ciphertext, per encryption)
    val rawSize: Int? = null,
    val receivedBytes: Long? = null,

    @Serializable(with = Base64ByteArraySerializer::class)
    val fileSha256: ByteArray? = null, // optional full file digest (future)

    // Merkle root integrity (optional, backward compatible)
    @Serializable(with = Base64ByteArraySerializer::class)
    val merkleRoot: ByteArray? = null, // SHA-256 Merkle root over per-chunk SHA-256 leaves
    @Serializable(with = Base64ByteArraySerializer::class)
    val merkleRootSignature: ByteArray? = null, // optional HMAC/Signature over merkleRoot (see merkleRootSignatureAlg)
    val merkleRootSignatureAlg: String? = null, // e.g. "hmac-sha256-session-v1"

    // Missing chunks request/response (optional, backward compatible)
    // Sent by receiver after .complete when chunks are missing; sender may resend those chunk indices.
    val missingChunks: IntArray? = null,

    // Batch transfer (optional, backward compatible)
    val batchId: String? = null,
    val batchIndex: Int? = null,
    val batchTotal: Int? = null,
    val relativePath: String? = null,

    val message: String? = null
)


