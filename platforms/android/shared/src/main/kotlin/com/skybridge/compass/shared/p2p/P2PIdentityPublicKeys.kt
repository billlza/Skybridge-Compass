package com.skybridge.compass.shared.p2p

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Pro release IdentityPublicKeys encoding:
 * protocolAlgorithm(1B) || protocolPublicKeyLen(2B LE) || protocolPublicKey ||
 * hasSecureEnclaveKey(1B) || [secureEnclavePublicKeyLen(2B LE) || secureEnclavePublicKey]
 */
object P2PIdentityPublicKeys {

    enum class ProtocolAlgorithm(val wireByte: Byte) {
        ED25519(0x01),
        ML_DSA_65(0x02),
        P256_ECDSA_LEGACY(0x03);

        companion object {
            fun fromWire(b: Byte): ProtocolAlgorithm? = entries.firstOrNull { it.wireByte == b }
        }
    }

    data class Keys(
        val protocolPublicKey: ByteArray,
        val protocolAlgorithm: ProtocolAlgorithm,
        val secureEnclavePublicKey: ByteArray? = null
    ) {
        fun encode(): ByteArray {
            val se = secureEnclavePublicKey
            val capacity = 1 + 2 + protocolPublicKey.size + 1 + (if (se != null) (2 + se.size) else 0)
            val bb = ByteBuffer.allocate(capacity).order(ByteOrder.LITTLE_ENDIAN)
            bb.put(protocolAlgorithm.wireByte)
            bb.putShort(protocolPublicKey.size.toShort())
            bb.put(protocolPublicKey)
            if (se != null) {
                bb.put(0x01)
                bb.putShort(se.size.toShort())
                bb.put(se)
            } else {
                bb.put(0x00)
            }
            return bb.array()
        }
    }

    fun decode(data: ByteArray): Keys {
        require(data.size >= 4) { "IdentityPublicKeys too short" }
        val bb = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val algByte = bb.get()
        val alg = requireNotNull(ProtocolAlgorithm.fromWire(algByte)) { "Unknown signature algorithm: $algByte" }
        val keyLen = bb.short.toInt() and 0xFFFF
        require(keyLen >= 0 && bb.remaining() >= keyLen) { "Protocol public key truncated" }
        val protocolKey = ByteArray(keyLen)
        bb.get(protocolKey)
        var seKey: ByteArray? = null
        if (bb.hasRemaining()) {
            val hasSe = bb.get().toInt() and 0xFF
            if (hasSe == 0x01) {
                require(bb.remaining() >= 2) { "SE key length truncated" }
                val seLen = bb.short.toInt() and 0xFFFF
                require(bb.remaining() >= seLen) { "SE public key truncated" }
                seKey = ByteArray(seLen)
                bb.get(seKey)
            }
        }
        return Keys(protocolPublicKey = protocolKey, protocolAlgorithm = alg, secureEnclavePublicKey = seKey)
    }
}


