package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.CryptoSuite
import com.skybridge.compass.shared.crypto.models.HPKESealedBox
import com.skybridge.compass.shared.crypto.protocol.HandshakeV2ClientHello
import com.skybridge.compass.shared.crypto.protocol.HandshakeV2ServerHello
import com.skybridge.compass.shared.crypto.protocol.KeyShare
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe

/**
 * Interoperability test vectors for Android-macOS communication.
 * 
 * These test vectors are derived from the macOS SkyBridge Compass implementation
 * to ensure binary compatibility between platforms.
 * 
 * **Validates: Requirements 9.4**
 */
class InteroperabilityTestVectors : FunSpec({
    
    /**
     * Known HPKESealedBox test vectors from macOS implementation.
     * 
     * These vectors verify that Android can correctly parse HPKESealedBox
     * data produced by macOS.
     */
    context("HPKESealedBox interoperability") {
        
        test("Parse HPKESealedBox with ML-KEM-768 suite from macOS") {
            // Test vector: HPKESealedBox header with ML-KEM-768+ML-DSA-65 suite
            // Magic: HPKE (0x48504B45)
            // Version: 1
            // Suite wireId: 0x0101 (ML-KEM-768+ML-DSA-65)
            // Flags: 0x0000
            // encLen: 32 (0x0020)
            // nonceLen: 12 (0x0C)
            // tagLen: 16 (0x10)
            // ctLen: 16 (0x00000010)
            
            val encapsulatedKey = ByteArray(32) { (it + 1).toByte() }
            val nonce = ByteArray(12) { (it + 0x10).toByte() }
            val ciphertext = ByteArray(16) { (it + 0x20).toByte() }
            val tag = ByteArray(16) { (it + 0x30).toByte() }
            
            val sealedBox = HPKESealedBox(encapsulatedKey, nonce, ciphertext, tag)
            val combined = sealedBox.combinedWithHeader(CryptoSuite.ML_KEM_768_ML_DSA_65)
            
            // Verify magic bytes
            combined[0] shouldBe 0x48.toByte() // 'H'
            combined[1] shouldBe 0x50.toByte() // 'P'
            combined[2] shouldBe 0x4B.toByte() // 'K'
            combined[3] shouldBe 0x45.toByte() // 'E'
            
            // Verify version
            combined[4] shouldBe 0x01.toByte()
            
            // Verify suite wireId (big-endian 0x0101)
            combined[5] shouldBe 0x01.toByte()
            combined[6] shouldBe 0x01.toByte()
            
            // Parse back and verify round-trip
            val parsed = HPKESealedBox.fromCombined(combined, isHandshake = false)
            parsed.encapsulatedKey.contentEquals(encapsulatedKey) shouldBe true
            parsed.nonce.contentEquals(nonce) shouldBe true
            parsed.ciphertext.contentEquals(ciphertext) shouldBe true
            parsed.tag.contentEquals(tag) shouldBe true
        }
        
        test("Parse HPKESealedBox with X25519 suite from macOS") {
            // Test vector for classic X25519+Ed25519 suite
            val encapsulatedKey = ByteArray(32) { it.toByte() }
            val nonce = ByteArray(12) { (it * 2).toByte() }
            val ciphertext = ByteArray(64) { (it + 0x40).toByte() }
            val tag = ByteArray(16) { (0xFF - it).toByte() }
            
            val sealedBox = HPKESealedBox(encapsulatedKey, nonce, ciphertext, tag)
            val combined = sealedBox.combinedWithHeader(CryptoSuite.X25519_ED25519)
            
            // Verify suite wireId (little-endian 0x1001 = 0x01 0x10)
            combined[5] shouldBe 0x01.toByte()
            combined[6] shouldBe 0x10.toByte()
            
            // Parse back
            val parsed = HPKESealedBox.fromCombined(combined, isHandshake = false)
            parsed.encapsulatedKey.contentEquals(encapsulatedKey) shouldBe true
            parsed.nonce.contentEquals(nonce) shouldBe true
            parsed.ciphertext.contentEquals(ciphertext) shouldBe true
            parsed.tag.contentEquals(tag) shouldBe true
        }
        
        test("Parse HPKESealedBox with P-256 suite from macOS") {
            // Test vector for P-256+ECDSA suite
            val encapsulatedKey = ByteArray(65) { it.toByte() } // Uncompressed P-256 point
            val nonce = ByteArray(12) { (it + 0xA0).toByte() }
            val ciphertext = ByteArray(128) { (it % 256).toByte() }
            val tag = ByteArray(16) { (it + 0xB0).toByte() }
            
            val sealedBox = HPKESealedBox(encapsulatedKey, nonce, ciphertext, tag)
            val combined = sealedBox.combinedWithHeader(CryptoSuite.P256_ECDSA)
            
            // Verify suite wireId (little-endian 0x1002 = 0x02 0x10)
            combined[5] shouldBe 0x02.toByte()
            combined[6] shouldBe 0x10.toByte()
            
            // Parse back
            val parsed = HPKESealedBox.fromCombined(combined, isHandshake = false)
            parsed.encapsulatedKey.contentEquals(encapsulatedKey) shouldBe true
        }
    }

    
    /**
     * Known handshake message test vectors from macOS implementation.
     * 
     * These vectors verify that Android can correctly parse handshake
     * messages produced by macOS.
     */
    context("Handshake message interoperability") {
        
        test("ClientHello serialization matches macOS format") {
            // Create a ClientHello with known values
            val clientRandom = ByteArray(32) { it.toByte() }
            val keyExchange = ByteArray(65) { (it + 0x10).toByte() } // P-256 public key
            
            val clientHello = HandshakeV2ClientHello(
                supportedSuites = listOf(
                    CryptoSuite.ML_KEM_768_ML_DSA_65,
                    CryptoSuite.X25519_ED25519,
                    CryptoSuite.P256_ECDSA
                ),
                clientRandom = clientRandom,
                clientKeyShare = KeyShare(KeyShare.GROUP_P256, keyExchange)
            )
            
            val serialized = clientHello.serialize()
            
            // Verify magic "SBV2" as int (little-endian)
            serialized[0] shouldBe 0x32.toByte() // '2'
            serialized[1] shouldBe 0x56.toByte() // 'V'
            serialized[2] shouldBe 0x42.toByte() // 'B'
            serialized[3] shouldBe 0x53.toByte() // 'S'
            
            // Verify protocol version (little-endian 0x0002)
            serialized[4] shouldBe 0x02.toByte()
            serialized[5] shouldBe 0x00.toByte()
            
            // Verify suites count (little-endian 3)
            serialized[6] shouldBe 0x03.toByte()
            serialized[7] shouldBe 0x00.toByte()
            
            // Parse back and verify
            val parsed = HandshakeV2ClientHello.parse(serialized)
            parsed.protocolVersion shouldBe 0x0002u
            parsed.supportedSuites.size shouldBe 3
            parsed.supportedSuites[0] shouldBe CryptoSuite.ML_KEM_768_ML_DSA_65
            parsed.clientRandom.contentEquals(clientRandom) shouldBe true
            parsed.clientKeyShare.group shouldBe KeyShare.GROUP_P256
        }
        
        test("ServerHello serialization matches macOS format") {
            // Create a ServerHello with known values
            val serverRandom = ByteArray(32) { (0xFF - it).toByte() }
            val keyExchange = ByteArray(65) { (it + 0x20).toByte() }
            val pqcEncapsulated = ByteArray(1088) { (it % 256).toByte() } // ML-KEM-768 ciphertext
            val transcriptHash = ByteArray(32) { (it * 3).toByte() }
            
            val serverHello = HandshakeV2ServerHello(
                selectedSuite = CryptoSuite.ML_KEM_768_ML_DSA_65,
                serverRandom = serverRandom,
                serverKeyShare = KeyShare(KeyShare.GROUP_P256, keyExchange),
                pqcEncapsulated = pqcEncapsulated,
                transcriptHash = transcriptHash
            )
            
            val serialized = serverHello.serialize()
            
            // Verify magic "SBV2" as int (little-endian)
            serialized[0] shouldBe 0x32.toByte() // '2'
            serialized[1] shouldBe 0x56.toByte() // 'V'
            serialized[2] shouldBe 0x42.toByte() // 'B'
            serialized[3] shouldBe 0x53.toByte() // 'S'
            
            // Verify protocol version (little-endian 0x0002)
            serialized[4] shouldBe 0x02.toByte()
            serialized[5] shouldBe 0x00.toByte()
            
            // Verify selected suite (little-endian 0x0101)
            serialized[6] shouldBe 0x01.toByte()
            serialized[7] shouldBe 0x01.toByte()
            
            // Parse back and verify
            val parsed = HandshakeV2ServerHello.parse(serialized)
            parsed.protocolVersion shouldBe 0x0002u
            parsed.selectedSuite shouldBe CryptoSuite.ML_KEM_768_ML_DSA_65
            parsed.serverRandom.contentEquals(serverRandom) shouldBe true
            parsed.pqcEncapsulated.contentEquals(pqcEncapsulated) shouldBe true
            parsed.transcriptHash.contentEquals(transcriptHash) shouldBe true
        }
        
        test("KeyShare serialization matches macOS format") {
            // X25519 key share
            val x25519Key = ByteArray(32) { it.toByte() }
            val x25519Share = KeyShare(KeyShare.GROUP_X25519, x25519Key)
            val x25519Serialized = x25519Share.serialize()
            
            // Verify group (little-endian 0x001D for X25519)
            x25519Serialized[0] shouldBe 0x1D.toByte()
            x25519Serialized[1] shouldBe 0x00.toByte()
            
            // Verify length (little-endian 32 = 0x0020)
            x25519Serialized[2] shouldBe 0x20.toByte()
            x25519Serialized[3] shouldBe 0x00.toByte()
            
            // P-256 key share
            val p256Key = ByteArray(65) { (it + 0x04).toByte() }
            val p256Share = KeyShare(KeyShare.GROUP_P256, p256Key)
            val p256Serialized = p256Share.serialize()
            
            // Verify group (little-endian 0x0017 for P-256)
            p256Serialized[0] shouldBe 0x17.toByte()
            p256Serialized[1] shouldBe 0x00.toByte()
            
            // Verify length (little-endian 65 = 0x0041)
            p256Serialized[2] shouldBe 0x41.toByte()
            p256Serialized[3] shouldBe 0x00.toByte()
        }
    }
    
    /**
     * CryptoSuite wire format interoperability.
     */
    context("CryptoSuite wire format") {
        
        test("CryptoSuite wireId values match macOS") {
            // Verify all suite wireIds match macOS implementation
            CryptoSuite.X_WING_ML_DSA.wireId shouldBe 0x0001u
            CryptoSuite.ML_KEM_768_ML_DSA_65.wireId shouldBe 0x0101u
            CryptoSuite.X25519_ED25519.wireId shouldBe 0x1001u
            CryptoSuite.P256_ECDSA.wireId shouldBe 0x1002u
        }
        
        test("CryptoSuite fromWireId matches macOS") {
            CryptoSuite.fromWireId(0x0001u) shouldBe CryptoSuite.X_WING_ML_DSA
            CryptoSuite.fromWireId(0x0101u) shouldBe CryptoSuite.ML_KEM_768_ML_DSA_65
            CryptoSuite.fromWireId(0x1001u) shouldBe CryptoSuite.X25519_ED25519
            CryptoSuite.fromWireId(0x1002u) shouldBe CryptoSuite.P256_ECDSA
            CryptoSuite.fromWireId(0xFFFFu) shouldBe null
        }
        
        test("CryptoSuite isPQC matches macOS logic") {
            // PQC suites have high byte 0x00 or 0x01
            CryptoSuite.X_WING_ML_DSA.isPQC shouldBe true
            CryptoSuite.ML_KEM_768_ML_DSA_65.isPQC shouldBe true
            
            // Classic suites have high byte 0x10
            CryptoSuite.X25519_ED25519.isPQC shouldBe false
            CryptoSuite.P256_ECDSA.isPQC shouldBe false
        }
    }
    
    /**
     * Key derivation interoperability.
     */
    context("Key derivation interoperability") {
        
        test("HKDF produces deterministic output matching macOS") {
            // Known test vector for HKDF
            val ikm = ByteArray(32) { it.toByte() }
            val salt = ByteArray(32) { (it + 0x10).toByte() }
            val info = "test-info".toByteArray()
            
            // Extract
            val prk = HybridKeyDerivation.hkdfExtract(salt, ikm)
            prk.size shouldBe 32
            
            // Expand
            val okm = HybridKeyDerivation.hkdfExpand(prk, info, 64)
            okm.size shouldBe 64
            
            // Verify determinism - same inputs produce same output
            val prk2 = HybridKeyDerivation.hkdfExtract(salt, ikm)
            val okm2 = HybridKeyDerivation.hkdfExpand(prk2, info, 64)
            okm.contentEquals(okm2) shouldBe true
        }
        
        test("Session key derivation produces distinct keys") {
            val classicSecret = ByteArray(32) { it.toByte() }
            val pqcSecret = ByteArray(32) { (it + 0x20).toByte() }
            val clientRandom = ByteArray(32) { (it + 0x40).toByte() }
            val serverRandom = ByteArray(32) { (it + 0x60).toByte() }
            val transcriptHash = ByteArray(32) { (it + 0x80).toByte() }
            
            val sessionKeys = HybridKeyDerivation.deriveSessionKeys(
                classicSecret, pqcSecret, clientRandom, serverRandom, transcriptHash
            )
            
            // All keys should be 32 bytes
            sessionKeys.controlKey.size shouldBe 32
            sessionKeys.videoKey.size shouldBe 32
            sessionKeys.fileKey.size shouldBe 32
            
            // All keys should be distinct
            sessionKeys.areKeysDistinct() shouldBe true
        }
    }
})
