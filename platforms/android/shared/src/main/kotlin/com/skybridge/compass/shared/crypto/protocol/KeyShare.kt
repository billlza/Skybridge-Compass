package com.skybridge.compass.shared.crypto.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Represents a key share for key exchange during handshake.
 * 
 * Used in TLS-style key exchange where each party contributes
 * a public key share for the selected group (curve).
 * 
 * @property group The named group identifier (e.g., X25519, P-256)
 * @property keyExchange The public key bytes for this group
 */
data class KeyShare(
    val group: UShort,
    val keyExchange: ByteArray
) {
    /**
     * Returns the expected key size for this group.
     */
    val expectedKeySize: Int
        get() = when (group) {
            GROUP_X25519 -> 32
            GROUP_P256 -> 65  // Uncompressed point
            else -> -1
        }
    
    /**
     * Validates that the key exchange bytes match expected size.
     */
    fun isValid(): Boolean {
        val expected = expectedKeySize
        return expected < 0 || keyExchange.size == expected
    }
    
    /**
     * Serializes this KeyShare to wire format.
     *
     * Format: group(2B) || length(2B) || keyExchange (little-endian per IEEE paper)
     */
    fun serialize(): ByteArray {
        return ByteBuffer.allocate(4 + keyExchange.size)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putShort(group.toShort())
            .putShort(keyExchange.size.toShort())
            .put(keyExchange)
            .array()
    }
    
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is KeyShare) return false
        
        return group == other.group && keyExchange.contentEquals(other.keyExchange)
    }
    
    override fun hashCode(): Int {
        var result = group.hashCode()
        result = 31 * result + keyExchange.contentHashCode()
        return result
    }
    
    companion object {
        /** X25519 named group (RFC 8446) */
        const val GROUP_X25519: UShort = 0x001Du
        
        /** secp256r1 (P-256) named group (RFC 8446) */
        const val GROUP_P256: UShort = 0x0017u
        
        /**
         * Parses a KeyShare from wire format.
         * 
         * @param data The wire format bytes
         * @param offset Starting offset in the array
         * @return Pair of parsed KeyShare and bytes consumed
         */
        fun parse(data: ByteArray, offset: Int = 0): Pair<KeyShare, Int> {
            require(data.size >= offset + 4) {
                "Data too short for KeyShare header"
            }
            
            val buffer = ByteBuffer.wrap(data, offset, data.size - offset)
                .order(ByteOrder.LITTLE_ENDIAN)
            
            val group = buffer.short.toUShort()
            val length = buffer.short.toInt() and 0xFFFF
            
            require(data.size >= offset + 4 + length) {
                "Data too short for KeyShare key exchange"
            }
            
            val keyExchange = ByteArray(length)
            buffer.get(keyExchange)
            
            return KeyShare(group, keyExchange) to (4 + length)
        }
    }
}
