package com.skybridge.compass.shared.crypto.protocol

import com.skybridge.compass.shared.crypto.HandshakeException
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom

/**
 * Handshake V2 ServerHello message.
 * 
 * Sent by the server in response to ClientHello.
 * 
 * Wire format:
 * ```
 * magic(4B: "SBV2") || version(2B) || selectedSuite(2B) ||
 * randomLen(1B) || random || keyShareLen(2B) || keyShare ||
 * pqcEncLen(2B) || pqcEnc || transcriptHashLen(1B) || transcriptHash ||
 * extensionsLen(2B) || extensions
 * ```
 * 
 * @property protocolVersion Protocol version (0x0002 for V2)
 * @property selectedSuite The selected crypto suite
 * @property serverRandom 32-byte random value for key derivation
 * @property serverKeyShare Server's classic key share for ECDH
 * @property pqcEncapsulated PQC encapsulated key (ML-KEM ciphertext)
 * @property transcriptHash SHA-256 hash of handshake transcript
 * @property extensions Optional extension data
 */
data class HandshakeV2ServerHello(
    val protocolVersion: UShort = PROTOCOL_VERSION,
    val selectedSuite: CryptoSuite,
    val serverRandom: ByteArray = SecureRandom().generateSeed(32),
    val serverKeyShare: KeyShare,
    val pqcEncapsulated: ByteArray,
    val transcriptHash: ByteArray,
    val extensions: Map<String, ByteArray> = emptyMap()
) {
    init {
        require(serverRandom.size == 32) { "serverRandom must be 32 bytes" }
        require(transcriptHash.size == 32) { "transcriptHash must be 32 bytes (SHA-256)" }
    }
    
    /**
     * Serializes this ServerHello to wire format.
     */
    fun serialize(): ByteArray {
        val keyShareBytes = serverKeyShare.serialize()
        val extensionsBytes = serializeExtensions()
        
        val size = 4 + 2 + 2 +
                   1 + serverRandom.size +
                   2 + keyShareBytes.size +
                   2 + pqcEncapsulated.size +
                   1 + transcriptHash.size +
                   2 + extensionsBytes.size
        
        return ByteBuffer.allocate(size).apply {
            order(ByteOrder.LITTLE_ENDIAN)  // IEEE paper: little-endian wire format
            
            // Magic "SBV2"
            putInt(MAGIC)
            
            // Protocol version
            putShort(protocolVersion.toShort())
            
            // Selected suite
            putShort(selectedSuite.wireId.toShort())
            
            // Server random
            put(serverRandom.size.toByte())
            put(serverRandom)
            
            // Key share
            putShort(keyShareBytes.size.toShort())
            put(keyShareBytes)
            
            // PQC encapsulated key
            putShort(pqcEncapsulated.size.toShort())
            put(pqcEncapsulated)
            
            // Transcript hash
            put(transcriptHash.size.toByte())
            put(transcriptHash)
            
            // Extensions
            putShort(extensionsBytes.size.toShort())
            put(extensionsBytes)
        }.array()
    }
    
    private fun serializeExtensions(): ByteArray {
        if (extensions.isEmpty()) return ByteArray(0)
        
        val buffer = ByteBuffer.allocate(4096).order(ByteOrder.LITTLE_ENDIAN)
        extensions.forEach { (key, value) ->
            val keyBytes = key.toByteArray(Charsets.UTF_8)
            buffer.putShort(keyBytes.size.toShort())
            buffer.put(keyBytes)
            buffer.putShort(value.size.toShort())
            buffer.put(value)
        }
        
        val result = ByteArray(buffer.position())
        buffer.flip()
        buffer.get(result)
        return result
    }
    
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HandshakeV2ServerHello) return false
        
        return protocolVersion == other.protocolVersion &&
               selectedSuite == other.selectedSuite &&
               serverRandom.contentEquals(other.serverRandom) &&
               serverKeyShare == other.serverKeyShare &&
               pqcEncapsulated.contentEquals(other.pqcEncapsulated) &&
               transcriptHash.contentEquals(other.transcriptHash)
    }
    
    override fun hashCode(): Int {
        var result = protocolVersion.hashCode()
        result = 31 * result + selectedSuite.hashCode()
        result = 31 * result + serverRandom.contentHashCode()
        result = 31 * result + serverKeyShare.hashCode()
        result = 31 * result + pqcEncapsulated.contentHashCode()
        result = 31 * result + transcriptHash.contentHashCode()
        return result
    }
    
    companion object {
        /** Magic bytes: "SBV2" */
        const val MAGIC = 0x53425632
        
        /** Protocol version 2 */
        const val PROTOCOL_VERSION: UShort = 0x0002u
        
        /**
         * Parses a ServerHello from wire format.
         * 
         * @param data The wire format bytes
         * @return Parsed ServerHello
         * @throws HandshakeException if parsing fails
         */
        fun parse(data: ByteArray): HandshakeV2ServerHello {
            if (data.size < 12) {
                throw HandshakeException("ServerHello", "Data too short: ${data.size}")
            }
            
            val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
            
            // Validate magic
            val magic = buffer.int
            if (magic != MAGIC) {
                throw HandshakeException(
                    "ServerHello",
                    "Invalid magic: expected 0x${MAGIC.toString(16)}, got 0x${magic.toString(16)}"
                )
            }
            
            // Protocol version
            val version = buffer.short.toUShort()
            if (version != PROTOCOL_VERSION) {
                throw HandshakeException(
                    "ServerHello",
                    "Unsupported protocol version: $version"
                )
            }
            
            // Selected suite
            val suiteWireId = buffer.short.toUShort()
            val selectedSuite = CryptoSuite.fromWireId(suiteWireId)
                ?: throw HandshakeException("ServerHello", "Unknown suite: $suiteWireId")
            
            // Server random
            val randomLen = buffer.get().toInt() and 0xFF
            if (randomLen != 32) {
                throw HandshakeException("ServerHello", "Invalid random length: $randomLen")
            }
            val serverRandom = ByteArray(randomLen)
            buffer.get(serverRandom)
            
            // Key share
            val keyShareLen = buffer.short.toInt() and 0xFFFF
            val keyShareBytes = ByteArray(keyShareLen)
            buffer.get(keyShareBytes)
            val (keyShare, _) = KeyShare.parse(keyShareBytes)
            
            // PQC encapsulated key
            val pqcEncLen = buffer.short.toInt() and 0xFFFF
            val pqcEncapsulated = ByteArray(pqcEncLen)
            buffer.get(pqcEncapsulated)
            
            // Transcript hash
            val hashLen = buffer.get().toInt() and 0xFF
            if (hashLen != 32) {
                throw HandshakeException("ServerHello", "Invalid hash length: $hashLen")
            }
            val transcriptHash = ByteArray(hashLen)
            buffer.get(transcriptHash)
            
            // Extensions (optional)
            val extensions = mutableMapOf<String, ByteArray>()
            if (buffer.remaining() >= 2) {
                val extLen = buffer.short.toInt() and 0xFFFF
                if (extLen > 0 && buffer.remaining() >= extLen) {
                    val extEndPos = buffer.position() + extLen
                    while (buffer.position() < extEndPos && buffer.remaining() >= 4) {
                        // Parse key
                        val keyLen = buffer.short.toInt() and 0xFFFF
                        if (buffer.remaining() < keyLen) break
                        val keyBytes = ByteArray(keyLen)
                        buffer.get(keyBytes)
                        val key = String(keyBytes, Charsets.UTF_8)

                        // Parse value
                        if (buffer.remaining() < 2) break
                        val valueLen = buffer.short.toInt() and 0xFFFF
                        if (buffer.remaining() < valueLen) break
                        val value = ByteArray(valueLen)
                        buffer.get(value)

                        extensions[key] = value
                    }
                }
            }
            
            return HandshakeV2ServerHello(
                protocolVersion = version,
                selectedSuite = selectedSuite,
                serverRandom = serverRandom,
                serverKeyShare = keyShare,
                pqcEncapsulated = pqcEncapsulated,
                transcriptHash = transcriptHash,
                extensions = extensions
            )
        }
    }
}
