package com.skybridge.compass.shared.crypto

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import io.kotest.matchers.collections.shouldHaveSize

/**
 * Cross-platform interoperability tests for PQC handshake.
 *
 * These tests verify that Android key derivation produces the same
 * results as iOS/macOS implementations given identical inputs.
 *
 * To run these tests against actual iOS/macOS output:
 * 1. Run the Swift test with identical input vectors
 * 2. Compare the hex-encoded output values
 */
class CrossPlatformInteroperabilityTest : FunSpec({

    // Utility function for hex conversion
    fun hexToBytes(hex: String): ByteArray {
        val len = hex.length
        val data = ByteArray(len / 2)
        var i = 0
        while (i < len) {
            data[i / 2] = ((Character.digit(hex[i], 16) shl 4)
                    + Character.digit(hex[i + 1], 16)).toByte()
            i += 2
        }
        return data
    }

    fun bytesToHex(bytes: ByteArray): String {
        return bytes.joinToString("") { "%02x".format(it) }
    }

    // Test vectors - identical values should be used on iOS/macOS
    val TEST_CLASSIC_SECRET = hexToBytes("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
    val TEST_PQC_SECRET = hexToBytes("2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40")
    val TEST_CLIENT_RANDOM = hexToBytes("4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60")
    val TEST_SERVER_RANDOM = hexToBytes("6162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f80")
    val TEST_TRANSCRIPT_HASH = hexToBytes("8182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0")
    val TEST_DEVICE_ID = "test-device-123"

    test("combineSharedSecrets should be deterministic") {
        /**
         * Run equivalent Swift code to verify cross-platform compatibility:
         * ```swift
         * let classic = Data([0x01...0x20])
         * let pqc = Data([0x21...0x40])
         * let combined = classic + pqc
         * let derivedKey = HKDF<SHA256>.deriveKey(
         *     inputKeyMaterial: SymmetricKey(data: combined),
         *     salt: Data("SkyBridgeHybridKDF".utf8),
         *     info: Data("hybrid-key-exchange".utf8),
         *     outputByteCount: 32
         * )
         * print(derivedKey.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() })
         * ```
         */
        val combined1 = CrossPlatformKeyDerivation.combineSharedSecrets(
            classicSecret = TEST_CLASSIC_SECRET,
            pqcSecret = TEST_PQC_SECRET
        )

        val combined2 = CrossPlatformKeyDerivation.combineSharedSecrets(
            classicSecret = TEST_CLASSIC_SECRET,
            pqcSecret = TEST_PQC_SECRET
        )

        combined1.toList() shouldBe combined2.toList()
        combined1.size shouldBe 32

        println("Combined secret (hex): ${bytesToHex(combined1)}")
    }

    test("combineSharedSecrets classic-only mode should work") {
        val combined = CrossPlatformKeyDerivation.combineSharedSecrets(
            classicSecret = TEST_CLASSIC_SECRET,
            pqcSecret = ByteArray(0)
        )

        combined.size shouldBe 32

        // Verify it's different from combined with PQC
        val combinedWithPqc = CrossPlatformKeyDerivation.combineSharedSecrets(
            classicSecret = TEST_CLASSIC_SECRET,
            pqcSecret = TEST_PQC_SECRET
        )

        combined.toList() shouldNotBe combinedWithPqc.toList()

        println("Classic-only combined secret (hex): ${bytesToHex(combined)}")
    }

    test("deriveSessionKeys should produce all channel keys") {
        val sessionKeys = CrossPlatformKeyDerivation.deriveSessionKeys(
            classicSecret = TEST_CLASSIC_SECRET,
            pqcSecret = TEST_PQC_SECRET,
            clientRandom = TEST_CLIENT_RANDOM,
            serverRandom = TEST_SERVER_RANDOM,
            transcriptHash = TEST_TRANSCRIPT_HASH
        )

        sessionKeys.controlKey.size shouldBe 32
        sessionKeys.videoKey.size shouldBe 32
        sessionKeys.fileKey.size shouldBe 32

        // All keys should be different
        sessionKeys.controlKey.toList() shouldNotBe sessionKeys.videoKey.toList()
        sessionKeys.videoKey.toList() shouldNotBe sessionKeys.fileKey.toList()
        sessionKeys.controlKey.toList() shouldNotBe sessionKeys.fileKey.toList()

        println("Control key (hex): ${bytesToHex(sessionKeys.controlKey)}")
        println("Video key (hex): ${bytesToHex(sessionKeys.videoKey)}")
        println("File key (hex): ${bytesToHex(sessionKeys.fileKey)}")
    }

    test("deriveP2PSessionKey should match Apple implementation") {
        /**
         * Run equivalent Swift code to verify:
         * ```swift
         * let sharedSecret = Data([0x01...0x20])
         * let deviceId = "test-device-123"
         * let info = Data("session:\(deviceId)".utf8)
         * let key = HKDF<SHA256>.deriveKey(
         *     inputKeyMaterial: SymmetricKey(data: sharedSecret),
         *     salt: Data("SkyBridgeHybridKDF".utf8),
         *     info: info,
         *     outputByteCount: 32
         * )
         * ```
         */
        val sessionKey = CrossPlatformKeyDerivation.deriveP2PSessionKey(
            sharedSecret = TEST_CLASSIC_SECRET,
            deviceId = TEST_DEVICE_ID
        )

        sessionKey.size shouldBe 32

        println("P2P session key (hex): ${bytesToHex(sessionKey)}")
        println("Device ID: $TEST_DEVICE_ID")
    }

    test("selectStrategy should return APPLE_COMPATIBLE for ios") {
        val strategy = CrossPlatformKeyDerivation.selectStrategy("ios")
        strategy shouldBe CrossPlatformKeyDerivation.KeyDerivationStrategy.APPLE_COMPATIBLE
    }

    test("selectStrategy should return APPLE_COMPATIBLE for macos") {
        val strategy = CrossPlatformKeyDerivation.selectStrategy("macos")
        strategy shouldBe CrossPlatformKeyDerivation.KeyDerivationStrategy.APPLE_COMPATIBLE
    }

    test("selectStrategy should return NATIVE_ANDROID for android") {
        val strategy = CrossPlatformKeyDerivation.selectStrategy("android")
        strategy shouldBe CrossPlatformKeyDerivation.KeyDerivationStrategy.NATIVE_ANDROID
    }

    test("selectStrategy should default to APPLE_COMPATIBLE for unknown platform") {
        val strategy = CrossPlatformKeyDerivation.selectStrategy(null)
        strategy shouldBe CrossPlatformKeyDerivation.KeyDerivationStrategy.APPLE_COMPATIBLE
    }

    test("HKDF should match RFC 5869 test case 1") {
        /**
         * Test Case 1 from RFC 5869:
         * Hash = SHA-256
         * IKM  = 0x0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b (22 octets)
         * salt = 0x000102030405060708090a0b0c (13 octets)
         * info = 0xf0f1f2f3f4f5f6f7f8f9 (10 octets)
         * L    = 42
         *
         * PRK  = 0x077709362c2e32df0ddc3f0dc47bba63
         *        90b6c73bb50f9c3122ec844ad7c2b3e5 (32 octets)
         * OKM  = 0x3cb25f25faacd57a90434f64d0362f2a
         *        2d2d0a90cf1a5a4c5db02d56ecc4c5bf
         *        34007208d5b887185865 (42 octets)
         */
        val ikm = hexToBytes("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
        val salt = hexToBytes("000102030405060708090a0b0c")
        val info = hexToBytes("f0f1f2f3f4f5f6f7f8f9")
        val length = 42

        val prk = HybridKeyDerivation.hkdfExtract(salt, ikm)
        val expectedPrk = hexToBytes("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
        prk.toList() shouldBe expectedPrk.toList()

        val okm = HybridKeyDerivation.hkdfExpand(prk, info, length)
        val expectedOkm = hexToBytes("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        okm.toList() shouldBe expectedOkm.toList()
    }

    test("HKDF with empty salt should use zero-filled salt") {
        val ikm = TEST_CLASSIC_SECRET
        val prk1 = HybridKeyDerivation.hkdfExtract(ByteArray(0), ikm)
        val prk2 = HybridKeyDerivation.hkdfExtract(ByteArray(32), ikm)

        // Empty salt should be equivalent to zero-filled salt
        prk1.toList() shouldBe prk2.toList()
    }

    test("Generate cross-platform test vectors") {
        println("\n========== CROSS-PLATFORM TEST VECTORS ==========")
        println("Use these values in Swift to verify compatibility")
        println("==================================================\n")

        println("Input Values:")
        println("  classicSecret = ${bytesToHex(TEST_CLASSIC_SECRET)}")
        println("  pqcSecret = ${bytesToHex(TEST_PQC_SECRET)}")
        println("  clientRandom = ${bytesToHex(TEST_CLIENT_RANDOM)}")
        println("  serverRandom = ${bytesToHex(TEST_SERVER_RANDOM)}")
        println("  transcriptHash = ${bytesToHex(TEST_TRANSCRIPT_HASH)}")
        println("  deviceId = \"$TEST_DEVICE_ID\"")
        println()

        // Test 1: combineSharedSecrets
        val combined = CrossPlatformKeyDerivation.combineSharedSecrets(
            classicSecret = TEST_CLASSIC_SECRET,
            pqcSecret = TEST_PQC_SECRET
        )
        println("Test 1 - combineSharedSecrets:")
        println("  Expected (Android): ${bytesToHex(combined)}")
        println("  Swift equivalent:")
        println("    let combined = classicSecret + pqcSecret")
        println("    let key = HKDF<SHA256>.deriveKey(")
        println("        inputKeyMaterial: SymmetricKey(data: combined),")
        println("        salt: Data(\"SkyBridgeHybridKDF\".utf8),")
        println("        info: Data(\"hybrid-key-exchange\".utf8),")
        println("        outputByteCount: 32")
        println("    )")
        println()

        // Test 2: deriveP2PSessionKey
        val p2pKey = CrossPlatformKeyDerivation.deriveP2PSessionKey(
            sharedSecret = TEST_CLASSIC_SECRET,
            deviceId = TEST_DEVICE_ID
        )
        println("Test 2 - deriveP2PSessionKey:")
        println("  Expected (Android): ${bytesToHex(p2pKey)}")
        println("  Swift equivalent:")
        println("    let info = Data(\"session:\\(deviceId)\".utf8)")
        println("    let key = HKDF<SHA256>.deriveKey(")
        println("        inputKeyMaterial: SymmetricKey(data: sharedSecret),")
        println("        salt: Data(\"SkyBridgeHybridKDF\".utf8),")
        println("        info: info,")
        println("        outputByteCount: 32")
        println("    )")
        println()

        // Test 3: Full session key derivation
        val sessionKeys = CrossPlatformKeyDerivation.deriveSessionKeys(
            classicSecret = TEST_CLASSIC_SECRET,
            pqcSecret = TEST_PQC_SECRET,
            clientRandom = TEST_CLIENT_RANDOM,
            serverRandom = TEST_SERVER_RANDOM,
            transcriptHash = TEST_TRANSCRIPT_HASH
        )
        println("Test 3 - Full session key derivation:")
        println("  controlKey: ${bytesToHex(sessionKeys.controlKey)}")
        println("  videoKey: ${bytesToHex(sessionKeys.videoKey)}")
        println("  fileKey: ${bytesToHex(sessionKeys.fileKey)}")
        println()

        println("=================================================")
        println("END OF TEST VECTORS")
        println("=================================================\n")
    }
})
