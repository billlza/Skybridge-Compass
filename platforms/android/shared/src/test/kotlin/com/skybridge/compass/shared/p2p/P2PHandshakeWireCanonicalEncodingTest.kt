package com.skybridge.compass.shared.p2p

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class P2PHandshakeWireCanonicalEncodingTest {

    @Test
    fun typedMessageAEncoderMatchesFreshAppleProductionGolden() {
        val encoded = P2PHandshakeWire.encodeMessageA(appleMessageA())

        assertArrayEquals(MESSAGE_A_GOLDEN.hexToBytes(), encoded)
        assertArrayEquals(encoded, P2PHandshakeWire.encodeMessageA(P2PHandshakeWire.decodeMessageA(encoded)))
    }

    @Test
    fun typedMessageBEncoderMatchesFreshAppleProductionGolden() {
        val encoded = P2PHandshakeWire.encodeMessageB(appleMessageB())

        assertArrayEquals(MESSAGE_B_GOLDEN.hexToBytes(), encoded)
        assertArrayEquals(encoded, P2PHandshakeWire.encodeMessageB(P2PHandshakeWire.decodeMessageB(encoded)))
    }

    @Test
    fun messageBTranscriptExcludesSignaturesButIncludesUnsignedWire() {
        val message = appleMessageB()
        val originalWire = P2PHandshakeWire.encodeMessageB(message)
        val changedSignatureWire = P2PHandshakeWire.encodeMessageB(
            message.copy(signature = message.signature.copyOf().also { it[0] = (it[0].toInt() xor 0x01).toByte() })
        )
        val changedUnsignedWire = P2PHandshakeWire.encodeMessageB(
            message.copy(serverNonce = message.serverNonce.copyOf().also { it[0] = (it[0].toInt() xor 0x01).toByte() })
        )

        assertArrayEquals(
            P2PHandshakeWire.transcriptHashBFromWire(originalWire),
            P2PHandshakeWire.transcriptHashBFromWire(changedSignatureWire)
        )
        assertFalse(
            P2PHandshakeWire.transcriptHashBFromWire(originalWire)
                .contentEquals(P2PHandshakeWire.transcriptHashBFromWire(changedUnsignedWire))
        )
    }

    @Test
    fun decodersRejectTrailingBytesAndMessageBPayloadSuiteMismatch() {
        val messageAWire = MESSAGE_A_GOLDEN.hexToBytes()
        val messageBWire = MESSAGE_B_GOLDEN.hexToBytes()

        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.decodeMessageA(messageAWire + byteArrayOf(0x00))
        }

        val nonCanonicalFlags = messageBWire.copyOf()
        val nonCanonicalHpkeOffset = indexOf(nonCanonicalFlags, byteArrayOf(0x48, 0x50, 0x4B, 0x45))
        nonCanonicalFlags[nonCanonicalHpkeOffset + 7] = 0x01
        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.decodeMessageB(nonCanonicalFlags)
        }
    }

    @Test
    fun messageAOfferShapeValidatorRejectsTypedAndRawAliases() {
        val valid = twoSuiteMessageA()

        val typedInvalid = listOf(
            valid.copy(
                supportedSuites = listOf(
                    P2PCryptoSuiteId.Known(P2PCryptoSuite.X25519),
                    P2PCryptoSuiteId.Known(P2PCryptoSuite.X25519)
                )
            ),
            valid.copy(
                keyShares = listOf(
                    P2PHandshakeWire.KeyShare(P2PCryptoSuite.X25519, ByteArray(32)),
                    P2PHandshakeWire.KeyShare(P2PCryptoSuite.X25519, ByteArray(32))
                )
            ),
            appleMessageA().copy(
                keyShares = listOf(
                    P2PHandshakeWire.KeyShare(P2PCryptoSuiteId.Unknown(0x4242u), ByteArray(32))
                )
            ),
            valid.copy(keyShares = valid.keyShares.reversed())
        )
        typedInvalid.forEach { message ->
            assertThrows(IllegalArgumentException::class.java) {
                P2PHandshakeWire.encodeMessageA(message)
            }
        }

        val canonical = P2PHandshakeWire.encodeMessageA(valid)
        val duplicateSupported = canonical.copyOf().also {
            it[5] = it[3]
            it[6] = it[4]
        }
        val duplicateKeyShare = canonical.copyOf().also {
            it[45] = it[9]
            it[46] = it[10]
        }
        val notOffered = MESSAGE_A_GOLDEN.hexToBytes().also {
            it[7] = 0x42
            it[8] = 0x42
        }
        val outOfOrder = canonical.copyOf().also {
            val firstLow = it[3]
            val firstHigh = it[4]
            it[3] = it[5]
            it[4] = it[6]
            it[5] = firstLow
            it[6] = firstHigh
        }
        listOf(duplicateSupported, duplicateKeyShare, notOffered, outOfOrder).forEach { wire ->
            assertThrows(IllegalArgumentException::class.java) {
                P2PHandshakeWire.decodeMessageA(wire)
            }
        }
    }

    @Test
    fun messageAEncoderPreservesSupportedSuiteAndKeyShareOrder() {
        val expected = twoSuiteMessageA()
        val decoded = P2PHandshakeWire.decodeMessageA(P2PHandshakeWire.encodeMessageA(expected))

        assertEquals(expected.supportedSuites.map { it.wireId }, decoded.supportedSuites.map { it.wireId })
        assertEquals(expected.keyShares.map { it.suiteId.wireId }, decoded.keyShares.map { it.suiteId.wireId })
    }

    @Test
    fun responderShareValidatorCoversEveryKnownSuiteOnEncodeAndDecode() {
        val messageBWire = MESSAGE_B_GOLDEN.hexToBytes()
        val expectedLengths = mapOf(
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND to 0,
            P2PCryptoSuite.X_WING to 0,
            P2PCryptoSuite.MLKEM_768 to 0,
            P2PCryptoSuite.MLKEM_768_FS_COMPAT to 32,
            P2PCryptoSuite.X25519 to 32,
            P2PCryptoSuite.P256 to 65
        )

        expectedLengths.forEach { (suite, expectedLength) ->
            val validMessage = messageBForSuite(suite, expectedLength)
            val validWire = P2PHandshakeWire.encodeMessageB(validMessage)
            assertEquals(expectedLength, P2PHandshakeWire.decodeMessageB(validWire).responderShare.size)

            val invalidLength = if (expectedLength == 0) 1 else expectedLength - 1
            assertThrows(IllegalArgumentException::class.java) {
                P2PHandshakeWire.encodeMessageB(messageBForSuite(suite, invalidLength))
            }
            assertThrows(IllegalArgumentException::class.java) {
                P2PHandshakeWire.decodeMessageB(replaceResponderShare(validWire, ByteArray(invalidLength)))
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.decodeMessageB(messageBWire + byteArrayOf(0x00))
        }

        val mismatchedPayloadSuite = messageBWire.copyOf()
        val hpkeOffset = indexOf(mismatchedPayloadSuite, byteArrayOf(0x48, 0x50, 0x4B, 0x45))
        assertTrue(hpkeOffset >= 0)
        mismatchedPayloadSuite[hpkeOffset + 5] = 0x01
        mismatchedPayloadSuite[hpkeOffset + 6] = 0x01
        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.decodeMessageB(mismatchedPayloadSuite)
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.encodeMessageB(
                appleMessageB().copy(
                    encryptedPayload = appleMessageB().encryptedPayload.copy(suiteWireId = 0x0101u)
                )
            )
        }
    }

    @Test
    fun messageAAndBEnforceSixteenKiBOnUnpaddedPayload() {
        val atCapA = messageAtEncodedSize(appleMessageA(), 16 * 1_024)
        val atCapB = messageAtEncodedSize(appleMessageB(), 16 * 1_024)

        val encodedA = P2PHandshakeWire.encodeMessageA(atCapA)
        val encodedB = P2PHandshakeWire.encodeMessageB(atCapB)
        assertEquals(16 * 1_024, encodedA.size)
        assertEquals(16 * 1_024, encodedB.size)
        P2PHandshakeWire.decodeMessageA(encodedA)
        P2PHandshakeWire.decodeMessageB(encodedB)
        P2PHandshakeWire.decodeMessageA(HandshakePaddingP1.wrap(encodedA))
        P2PHandshakeWire.decodeMessageB(HandshakePaddingP1.wrap(encodedB))

        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.encodeMessageA(atCapA.copy(signature = atCapA.signature + byteArrayOf(0x00)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.encodeMessageB(atCapB.copy(signature = atCapB.signature + byteArrayOf(0x00)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.decodeMessageA(encodedA + byteArrayOf(0x00))
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PHandshakeWire.decodeMessageB(encodedB + byteArrayOf(0x00))
        }
    }

    @Test
    fun serverUsesTypedMessageBWireBeforeTranscriptAndTransportPadding() {
        val classicPolicy = P2PHandshakePolicy(
            requirePqc = false,
            allowClassicFallback = true,
            minimumTierRaw = "classic",
            requireSecureEnclavePoP = false
        )
        val client = P2PHandshakeClient(platformVersion = "Android 16 (API 36)")
        val (clientState, messageAToSend) = client.start(
            P2PHandshakeClient.StartOptions(handshakePolicy = classicPolicy)
        )
        val response = P2PHandshakeServer().respond(
            messageAToSend,
            P2PHandshakeServer.RespondOptions(
                platformVersion = "Android 16 (API 36)",
                handshakePolicy = classicPolicy
            )
        )

        val unpadded = HandshakePaddingP1.unwrapIfNeeded(response.messageBToSend)
        val decoded = P2PHandshakeWire.decodeMessageB(unpadded)

        assertArrayEquals(unpadded, P2PHandshakeWire.encodeMessageB(decoded))
        assertArrayEquals(response.state.transcriptHashB32, P2PHandshakeWire.transcriptHashBFromWire(unpadded))
        assertArrayEquals(unpadded, HandshakePaddingP1.unwrapIfNeeded(HandshakePaddingP1.wrap(unpadded)))
        assertTrue(
            P2PHandshakeWire.verifyMessageBSignature(
                messageB = decoded,
                transcriptHashA32 = P2PHandshakeWire.transcriptHashAFromWire(clientState.messageAWithoutPadding),
                rawMessageBWithoutPadding = unpadded
            )
        )
    }

    private fun appleMessageA(): P2PHandshakeWire.MessageA = P2PHandshakeWire.MessageA(
        supportedSuites = listOf(P2PCryptoSuiteId.Known(P2PCryptoSuite.X25519)),
        keyShares = listOf(
            P2PHandshakeWire.KeyShare(
                suite = P2PCryptoSuite.X25519,
                shareBytes = increasingBytes(0x40, 32)
            )
        ),
        clientNonce = increasingBytes(0x00, 32),
        capabilities = appleCapabilities(),
        policy = applePolicy(),
        identityPublicKeys = appleIdentity(),
        signature = increasingBytes(0xA0, 64)
    )

    private fun appleMessageB(): P2PHandshakeWire.MessageB = P2PHandshakeWire.MessageB(
        selectedSuite = P2PCryptoSuiteId.Known(P2PCryptoSuite.X25519),
        responderShare = increasingBytes(0x60, 32),
        serverNonce = increasingBytes(0x20, 32),
        encryptedPayload = P2PHPKESealedBox(
            version = 1,
            suiteWireId = P2PCryptoSuite.X25519.wireId,
            encapsulatedKey = increasingBytes(0x10, 32),
            nonce = increasingBytes(0x30, 12),
            ciphertext = increasingBytes(0x40, 16),
            tag = increasingBytes(0x50, 16)
        ),
        identityPublicKeys = appleIdentity(),
        signature = increasingBytes(0xA0, 64)
    )

    private fun twoSuiteMessageA(): P2PHandshakeWire.MessageA = appleMessageA().copy(
        supportedSuites = listOf(
            P2PCryptoSuiteId.Known(P2PCryptoSuite.X25519),
            P2PCryptoSuiteId.Known(P2PCryptoSuite.P256)
        ),
        keyShares = listOf(
            P2PHandshakeWire.KeyShare(P2PCryptoSuite.X25519, increasingBytes(0x40, 32)),
            P2PHandshakeWire.KeyShare(P2PCryptoSuite.P256, increasingBytes(0x60, 65))
        )
    )

    private fun messageBForSuite(suite: P2PCryptoSuite, responderShareLength: Int): P2PHandshakeWire.MessageB =
        appleMessageB().let { message ->
            message.copy(
                selectedSuite = P2PCryptoSuiteId.Known(suite),
                responderShare = ByteArray(responderShareLength),
                encryptedPayload = message.encryptedPayload.copy(suiteWireId = suite.wireId)
            )
        }

    private fun messageAtEncodedSize(
        message: P2PHandshakeWire.MessageA,
        targetSize: Int
    ): P2PHandshakeWire.MessageA {
        val withoutSignatureBytes = P2PHandshakeWire.encodeMessageA(message.copy(signature = ByteArray(0))).size
        return message.copy(signature = ByteArray(targetSize - withoutSignatureBytes))
    }

    private fun messageAtEncodedSize(
        message: P2PHandshakeWire.MessageB,
        targetSize: Int
    ): P2PHandshakeWire.MessageB {
        val withoutSignatureBytes = P2PHandshakeWire.encodeMessageB(message.copy(signature = ByteArray(0))).size
        return message.copy(signature = ByteArray(targetSize - withoutSignatureBytes))
    }

    private fun appleCapabilities(): P2PCryptoCapabilities = P2PCryptoCapabilities(
        supportedKEM = listOf("X25519"),
        supportedSignature = listOf("Ed25519"),
        supportedAuthProfiles = listOf("classic"),
        supportedAEAD = listOf("AES-256-GCM"),
        pqcAvailable = false,
        platformVersion = "macOS-26.0",
        providerTypeRaw = "CryptoKit-Classic"
    )

    private fun applePolicy(): P2PHandshakePolicy = P2PHandshakePolicy(
        requirePqc = false,
        allowClassicFallback = true,
        minimumTierRaw = "classic",
        requireSecureEnclavePoP = false
    )

    private fun appleIdentity(): P2PIdentityPublicKeys.Keys = P2PIdentityPublicKeys.Keys(
        protocolPublicKey = increasingBytes(0x80, 32),
        protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519
    )

    private fun increasingBytes(start: Int, count: Int): ByteArray =
        ByteArray(count) { (start + it).toByte() }

    private fun String.hexToBytes(): ByteArray {
        require(length % 2 == 0)
        return ByteArray(length / 2) { index ->
            substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
        for (index in 0..haystack.size - needle.size) {
            if (needle.indices.all { offset -> haystack[index + offset] == needle[offset] }) {
                return index
            }
        }
        return -1
    }

    private fun replaceResponderShare(wire: ByteArray, replacement: ByteArray): ByteArray {
        val originalLength = (wire[3].toInt() and 0xFF) or ((wire[4].toInt() and 0xFF) shl 8)
        return ByteArray(wire.size - originalLength + replacement.size).also { result ->
            wire.copyInto(result, destinationOffset = 0, startIndex = 0, endIndex = 3)
            result[3] = (replacement.size and 0xFF).toByte()
            result[4] = ((replacement.size ushr 8) and 0xFF).toByte()
            replacement.copyInto(result, destinationOffset = 5)
            wire.copyInto(
                result,
                destinationOffset = 5 + replacement.size,
                startIndex = 5 + originalLength
            )
        }
    }

    private companion object {
        const val MESSAGE_A_GOLDEN =
            "0101000110010001102000404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f" +
                "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f63000100000006000000" +
                "5832353531390100000007000000456432353531390100000007000000636c6173736963010000000b000000" +
                "4145532d3235362d47434d000a0000006d61634f532d32362e301100000043727970746f4b69742d436c6173" +
                "7369630e00000107000000636c6173736963002400012000808182838485868788898a8b8c8d8e8f90919293" +
                "9495969798999a9b9c9d9e9f004000a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9ba" +
                "bbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf0000"

        const val MESSAGE_B_GOLDEN =
            "0101102000606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f20212223242526" +
                "2728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f5d0048504b45010110000020000c1010000000" +
                "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b" +
                "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f240001200080818283848586" +
                "8788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f004000a0a1a2a3a4a5a6a7a8a9aaabacadae" +
                "afb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8" +
                "d9dadbdcdddedf0000"
    }
}
