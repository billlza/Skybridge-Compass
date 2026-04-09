package com.skybridge.compass.shared.crypto.models

import com.skybridge.compass.shared.crypto.HPKEParseException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * HPKE (Hybrid Public Key Encryption) sealed box.
 * 
 * Contains the result of an HPKE seal operation:
 * - Encapsulated key from KEM
 * - Nonce for AEAD
 * - Ciphertext (encrypted data)
 * - Authentication tag from AEAD
 * 
 * Wire format (self-describing, compatible with macOS):
 * ```
 * magic(4B: "HPKE") || version(1B) || suiteWireId(2B) || flags(2B) ||
 * encLen(2B) || nonceLen(1B) || tagLen(1B) || ctLen(4B) ||
 * enc || nonce || ct || tag
 * ```
 * 
 * @property encapsulatedKey KEM encapsulated key (e.g., 1088 bytes for ML-KEM-768)
 * @property nonce AEAD nonce (12 bytes for AES-GCM)
 * @property ciphertext Encrypted data
 * @property tag AEAD authentication tag (16 bytes for AES-GCM)
 */
data class HPKESealedBox(
    val encapsulatedKey: ByteArray,
    val nonce: ByteArray,
    val ciphertext: ByteArray,
    val tag: ByteArray
) {
    init {
        require(nonce.size == EXPECTED_NONCE_LEN) {
            "Nonce must be $EXPECTED_NONCE_LEN bytes, got ${nonce.size}"
        }
        require(tag.size == EXPECTED_TAG_LEN) {
            "Tag must be $EXPECTED_TAG_LEN bytes, got ${tag.size}"
        }
    }
    
    /**
     * Serializes this HPKESealedBox to wire format with self-describing header.
     * 
     * @param suite The CryptoSuite used for encryption
     * @param flags Optional flags (default 0)
     * @return Complete wire format bytes
     */
    fun combinedWithHeader(suite: CryptoSuite, flags: UShort = 0u): ByteArray {
        val totalSize = HEADER_SIZE + encapsulatedKey.size + nonce.size + 
                       ciphertext.size + tag.size
        
        return ByteBuffer.allocate(totalSize).apply {
            order(ByteOrder.LITTLE_ENDIAN)  // IEEE paper: little-endian wire format
            
            // Header
            put(MAGIC)                                    // 4 bytes: "HPKE"
            put(VERSION.toByte())                         // 1 byte: version
            putShort(suite.wireId.toShort())              // 2 bytes: suite wireId
            putShort(flags.toShort())                     // 2 bytes: flags
            putShort(encapsulatedKey.size.toShort())      // 2 bytes: encLen
            put(EXPECTED_NONCE_LEN.toByte())              // 1 byte: nonceLen
            put(EXPECTED_TAG_LEN.toByte())                // 1 byte: tagLen
            putInt(ciphertext.size)                       // 4 bytes: ctLen
            
            // Payload
            put(encapsulatedKey)
            put(nonce)
            put(ciphertext)
            put(tag)
        }.array()
    }
    
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HPKESealedBox) return false
        
        return encapsulatedKey.contentEquals(other.encapsulatedKey) &&
               nonce.contentEquals(other.nonce) &&
               ciphertext.contentEquals(other.ciphertext) &&
               tag.contentEquals(other.tag)
    }
    
    override fun hashCode(): Int {
        var result = encapsulatedKey.contentHashCode()
        result = 31 * result + nonce.contentHashCode()
        result = 31 * result + ciphertext.contentHashCode()
        result = 31 * result + tag.contentHashCode()
        return result
    }
    
    companion object {
        /** Magic bytes identifying HPKE format: "HPKE" */
        val MAGIC = byteArrayOf(0x48, 0x50, 0x4B, 0x45)
        
        /** Current wire format version */
        const val VERSION = 1
        
        /** Total header size in bytes */
        const val HEADER_SIZE = 17
        
        /** Maximum encapsulated key length (DoS protection) */
        const val MAX_ENC_LEN = 4096
        
        /** Expected nonce length for AES-GCM */
        const val EXPECTED_NONCE_LEN = 12
        
        /** Expected tag length for AES-GCM */
        const val EXPECTED_TAG_LEN = 16
        
        /** Maximum ciphertext length during handshake (64KB) */
        const val MAX_CT_LEN_HANDSHAKE = 64 * 1024
        
        /** Maximum ciphertext length post-authentication (256KB) */
        const val MAX_CT_LEN_POST_AUTH = 256 * 1024
        
        /**
         * Parses an HPKESealedBox from wire format.
         * 
         * @param combined The complete wire format bytes
         * @param isHandshake If true, applies stricter size limits (64KB vs 256KB)
         * @return Parsed HPKESealedBox
         * @throws HPKEParseException if parsing fails
         */
        fun fromCombined(combined: ByteArray, isHandshake: Boolean = true): HPKESealedBox {
            // 1. Check minimum length
            if (combined.size < HEADER_SIZE) {
                throw HPKEParseException("Data too short for header: ${combined.size} < $HEADER_SIZE")
            }
            
            // 2. Validate magic bytes
            val magic = combined.sliceArray(0 until 4)
            if (!magic.contentEquals(MAGIC)) {
                throw HPKEParseException("Invalid magic bytes: expected 'HPKE'")
            }
            
            // 3. Parse header
            val buffer = ByteBuffer.wrap(combined).order(ByteOrder.LITTLE_ENDIAN)
            buffer.position(4) // Skip magic
            
            val version = buffer.get().toInt() and 0xFF
            if (version != VERSION) {
                throw HPKEParseException("Unsupported version: $version (expected $VERSION)")
            }
            
            val suiteWireId = buffer.short.toInt() and 0xFFFF
            val flags = buffer.short.toInt() and 0xFFFF
            val encLen = buffer.short.toInt() and 0xFFFF
            val nonceLen = buffer.get().toInt() and 0xFF
            val tagLen = buffer.get().toInt() and 0xFF
            val ctLen = buffer.int
            
            // 4. Validate lengths (DoS protection)
            if (encLen > MAX_ENC_LEN) {
                throw HPKEParseException("encLen exceeds limit: $encLen > $MAX_ENC_LEN")
            }
            if (nonceLen != EXPECTED_NONCE_LEN) {
                throw HPKEParseException("Invalid nonce length: $nonceLen (expected $EXPECTED_NONCE_LEN)")
            }
            if (tagLen != EXPECTED_TAG_LEN) {
                throw HPKEParseException("Invalid tag length: $tagLen (expected $EXPECTED_TAG_LEN)")
            }
            
            val maxCtLen = if (isHandshake) MAX_CT_LEN_HANDSHAKE else MAX_CT_LEN_POST_AUTH
            if (ctLen < 0 || ctLen > maxCtLen) {
                throw HPKEParseException("ctLen exceeds limit: $ctLen > $maxCtLen")
            }
            
            // 5. Validate total length
            val expectedTotal = HEADER_SIZE + encLen + nonceLen + ctLen + tagLen
            if (combined.size != expectedTotal) {
                throw HPKEParseException(
                    "Length mismatch: expected $expectedTotal, got ${combined.size}"
                )
            }
            
            // 6. Extract components
            var offset = HEADER_SIZE
            
            val enc = combined.sliceArray(offset until offset + encLen)
            offset += encLen
            
            val nonce = combined.sliceArray(offset until offset + nonceLen)
            offset += nonceLen
            
            val ct = combined.sliceArray(offset until offset + ctLen)
            offset += ctLen
            
            val tag = combined.sliceArray(offset until offset + tagLen)
            
            return HPKESealedBox(enc, nonce, ct, tag)
        }
        
        /**
         * Extracts the CryptoSuite wireId from wire format without full parsing.
         * 
         * @param combined The wire format bytes
         * @return The suite wireId, or null if invalid
         */
        fun extractSuiteWireId(combined: ByteArray): UShort? {
            if (combined.size < 7) return null
            if (!combined.sliceArray(0 until 4).contentEquals(MAGIC)) return null
            
            val buffer = ByteBuffer.wrap(combined, 5, 2).order(ByteOrder.LITTLE_ENDIAN)
            return buffer.short.toUShort()
        }
    }
}
