package com.skybridge.compass.shared.p2p

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Pro release IdentityPublicKeys encoding:
 * protocolAlgorithm(1B) || protocolPublicKeyLen(2B LE) || protocolPublicKey ||
 * hasSecureEnclaveKey(1B) || [secureEnclavePublicKeyLen(2B LE) || secureEnclavePublicKey]
 */
object P2PIdentityPublicKeys {

    private const val UINT16_MAX = 0xFFFF

    enum class ProtocolAlgorithm(
        val wireByte: Byte,
        internal val publicKeyLength: Int
    ) {
        ED25519(0x01, 32),
        ML_DSA_65(0x02, 1_952),
        P256_ECDSA_LEGACY(0x03, 65);

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
            requireUInt16Length(protocolPublicKey, "Protocol public key")
            validateProtocolPublicKeyLength(protocolAlgorithm, protocolPublicKey.size)
            val se = secureEnclavePublicKey
            if (se != null) {
                requireUInt16Length(se, "Secure Enclave public key")
            }
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
        validateProtocolPublicKeyLength(alg, keyLen)
        require(bb.remaining() >= keyLen + 1) { "Protocol public key or SE key presence marker truncated" }
        val protocolKey = ByteArray(keyLen)
        bb.get(protocolKey)
        val hasSe = bb.get().toInt() and 0xFF
        val seKey = when (hasSe) {
            0x00 -> null
            0x01 -> {
                require(bb.remaining() >= 2) { "SE key length truncated" }
                val seLen = bb.short.toInt() and 0xFFFF
                require(bb.remaining() >= seLen) { "SE public key truncated" }
                ByteArray(seLen).also { bb.get(it) }
            }
            else -> throw IllegalArgumentException("Invalid SE key presence marker: $hasSe")
        }
        require(!bb.hasRemaining()) { "IdentityPublicKeys trailing bytes" }
        return Keys(protocolPublicKey = protocolKey, protocolAlgorithm = alg, secureEnclavePublicKey = seKey)
    }

    private fun validateProtocolPublicKeyLength(algorithm: ProtocolAlgorithm, actualLength: Int) {
        require(actualLength == algorithm.publicKeyLength) {
            "Invalid ${algorithm.name} public key length: $actualLength; expected ${algorithm.publicKeyLength}"
        }
    }

    private fun requireUInt16Length(bytes: ByteArray, fieldName: String) {
        require(bytes.size <= UINT16_MAX) { "$fieldName too large: ${bytes.size}" }
    }
}
