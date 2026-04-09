package com.skybridge.compass.shared.crypto.protocol

import com.skybridge.compass.shared.crypto.HandshakeException
import com.skybridge.compass.shared.crypto.models.CryptoSuite
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom

/**
 * Handshake V2 ClientHello message.
 * 
 * Sent by the client to initiate a secure session.
 * 
 * Wire format:
 * ```
 * magic(4B: "SBV2") || version(2B) || suitesCount(2B) || suites(2B each) ||
 * capsLen(2B) || caps || randomLen(1B) || random || keyShareLen(2B) || keyShare ||
 * extensionsLen(2B) || extensions
 * ```
 * 
 * @property protocolVersion Protocol version (0x0002 for V2)
 * @property supportedSuites List of supported crypto suites in priority order
 * @property deviceCaps Device capabilities
 * @property clientRandom 32-byte random value for key derivation
 * @property clientKeyShare Classic key share for ECDH
 * @property extensions Optional extension data
 */
data class HandshakeV2ClientHello(
    val protocolVersion: UShort = PROTOCOL_VERSION,
    val supportedSuites: List<CryptoSuite>,
    val deviceCaps: DeviceCapabilities = DeviceCapabilities(),
    val clientRandom: ByteArray = SecureRandom().generateSeed(32),
    val clientKeyShare: KeyShare,
    val extensions: Map<String, ByteArray> = emptyMap()
) {
    init {
        require(supportedSuites.isNotEmpty()) { "Must support at least one suite" }
        require(clientRandom.size == 32) { "clientRandom must be 32 bytes" }
    }
    
    /**
     * Serializes this ClientHello to wire format.
     */
    fun serialize(): ByteArray {
        val capsBytes = deviceCaps.serialize()
        val keyShareBytes = clientKeyShare.serialize()
        val extensionsBytes = serializeExtensions()
        
        val size = 4 + 2 + 2 + (supportedSuites.size * 2) + 
                   2 + capsBytes.size + 
                   1 + clientRandom.size + 
                   2 + keyShareBytes.size +
                   2 + extensionsBytes.size
        
        return ByteBuffer.allocate(size).apply {
            order(ByteOrder.LITTLE_ENDIAN)  // IEEE paper: little-endian wire format
            
            // Magic "SBV2"
            putInt(MAGIC)
            
            // Protocol version
            putShort(protocolVersion.toShort())
            
            // Supported suites
            putShort(supportedSuites.size.toShort())
            supportedSuites.forEach { suite ->
                putShort(suite.wireId.toShort())
            }
            
            // Device capabilities
            putShort(capsBytes.size.toShort())
            put(capsBytes)
            
            // Client random
            put(clientRandom.size.toByte())
            put(clientRandom)
            
            // Key share
            putShort(keyShareBytes.size.toShort())
            put(keyShareBytes)
            
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
        if (other !is HandshakeV2ClientHello) return false
        
        return protocolVersion == other.protocolVersion &&
               supportedSuites == other.supportedSuites &&
               deviceCaps == other.deviceCaps &&
               clientRandom.contentEquals(other.clientRandom) &&
               clientKeyShare == other.clientKeyShare
    }
    
    override fun hashCode(): Int {
        var result = protocolVersion.hashCode()
        result = 31 * result + supportedSuites.hashCode()
        result = 31 * result + deviceCaps.hashCode()
        result = 31 * result + clientRandom.contentHashCode()
        result = 31 * result + clientKeyShare.hashCode()
        return result
    }
    
    companion object {
        /** Magic bytes: "SBV2" */
        const val MAGIC = 0x53425632
        
        /** Protocol version 2 */
        const val PROTOCOL_VERSION: UShort = 0x0002u
        
        /**
         * Parses a ClientHello from wire format.
         * 
         * @param data The wire format bytes
         * @return Parsed ClientHello
         * @throws HandshakeException if parsing fails
         */
        fun parse(data: ByteArray): HandshakeV2ClientHello {
            if (data.size < 10) {
                throw HandshakeException("ClientHello", "Data too short: ${data.size}")
            }
            
            val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
            
            // Validate magic
            val magic = buffer.int
            if (magic != MAGIC) {
                throw HandshakeException(
                    "ClientHello",
                    "Invalid magic: expected 0x${MAGIC.toString(16)}, got 0x${magic.toString(16)}"
                )
            }
            
            // Protocol version
            val version = buffer.short.toUShort()
            if (version != PROTOCOL_VERSION) {
                throw HandshakeException(
                    "ClientHello",
                    "Unsupported protocol version: $version"
                )
            }
            
            // Supported suites
            val suitesCount = buffer.short.toInt() and 0xFFFF
            if (suitesCount == 0 || suitesCount > 16) {
                throw HandshakeException("ClientHello", "Invalid suites count: $suitesCount")
            }
            
            val suites = mutableListOf<CryptoSuite>()
            repeat(suitesCount) {
                val wireId = buffer.short.toUShort()
                CryptoSuite.fromWireId(wireId)?.let { suites.add(it) }
            }
            
            if (suites.isEmpty()) {
                throw HandshakeException("ClientHello", "No recognized suites")
            }
            
            // Device capabilities
            val capsLen = buffer.short.toInt() and 0xFFFF
            val capsBytes = ByteArray(capsLen)
            buffer.get(capsBytes)
            val caps = if (capsLen >= 4) {
                DeviceCapabilities.parse(capsBytes)
            } else {
                DeviceCapabilities()
            }
            
            // Client random
            val randomLen = buffer.get().toInt() and 0xFF
            if (randomLen != 32) {
                throw HandshakeException("ClientHello", "Invalid random length: $randomLen")
            }
            val clientRandom = ByteArray(randomLen)
            buffer.get(clientRandom)
            
            // Key share
            val keyShareLen = buffer.short.toInt() and 0xFFFF
            val keyShareBytes = ByteArray(keyShareLen)
            buffer.get(keyShareBytes)
            val (keyShare, _) = KeyShare.parse(keyShareBytes)
            
            // Extensions (optional)
            val extensions = mutableMapOf<String, ByteArray>()
            if (buffer.remaining() >= 2) {
                val extLen = buffer.short.toInt() and 0xFFFF
                if (extLen > 0 && buffer.remaining() >= extLen) {
                    val extEndPos = buffer.position() + extLen
                    while (buffer.position() < extEndPos && buffer.remaining() >= 4) {
                        // Parse key
                        val keyLen = buffer.short.toInt() and 0xFFFF
                        if (keyLen == 0 || buffer.remaining() < keyLen) break
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
            
            return HandshakeV2ClientHello(
                protocolVersion = version,
                supportedSuites = suites,
                deviceCaps = caps,
                clientRandom = clientRandom,
                clientKeyShare = keyShare,
                extensions = extensions
            )
        }
    }
}
