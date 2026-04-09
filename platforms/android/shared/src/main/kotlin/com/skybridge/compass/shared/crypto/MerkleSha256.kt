package com.skybridge.compass.shared.crypto

import java.security.MessageDigest

/**
 * Deterministic SHA-256 Merkle tree for chunk hashes.
 *
 * - Leaves are 32-byte SHA-256 digests (one per chunk, in chunkIndex order).
 * - Parent = SHA256(left || right)
 * - If the level has an odd node count, duplicate the last node.
 *
 * This is designed to be easy to implement cross-platform (Swift/Android).
 */
object MerkleSha256 {
    fun root(leaves: List<ByteArray>): ByteArray {
        require(leaves.isNotEmpty()) { "leaves must not be empty" }
        leaves.forEach { require(it.size == 32) { "leaf must be 32 bytes" } }

        var level = leaves.map { it.copyOf() }
        while (level.size > 1) {
            val next = ArrayList<ByteArray>((level.size + 1) / 2)
            var i = 0
            while (i < level.size) {
                val left = level[i]
                val right = if (i + 1 < level.size) level[i + 1] else left
                next.add(sha256(left + right))
                i += 2
            }
            level = next
        }
        return level[0]
    }

    private fun sha256(data: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(data)
}


