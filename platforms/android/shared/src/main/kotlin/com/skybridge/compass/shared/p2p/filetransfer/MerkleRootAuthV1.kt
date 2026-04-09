package com.skybridge.compass.shared.p2p.filetransfer

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Shared (cross-platform) preimage format for merkleRootSignature.
 *
 * IMPORTANT: Keep this stable (v1). Old clients ignore the signature fields.
 *
 * Format (binary):
 *  ascii "SkyBridge-MerkleRoot|v1|" ||
 *  u16le transferIdLen || transferId(utf8) ||
 *  u16le merkleRootLen || merkleRoot ||
 *  u16le fileShaLen || fileSha256 (or 0)
 */
object MerkleRootAuthV1 {
    private val PREFIX = "SkyBridge-MerkleRoot|v1|".encodeToByteArray()

    fun preimage(transferId: String, merkleRoot: ByteArray, fileSha256: ByteArray?): ByteArray {
        val tid = transferId.encodeToByteArray()
        val fileSha = fileSha256 ?: ByteArray(0)
        val bb = ByteBuffer.allocate(
            PREFIX.size +
                2 + tid.size +
                2 + merkleRoot.size +
                2 + fileSha.size
        ).order(ByteOrder.LITTLE_ENDIAN)
        bb.put(PREFIX)
        bb.putShort(tid.size.toShort())
        bb.put(tid)
        bb.putShort(merkleRoot.size.toShort())
        bb.put(merkleRoot)
        bb.putShort(fileSha.size.toShort())
        bb.put(fileSha)
        return bb.array()
    }
}


