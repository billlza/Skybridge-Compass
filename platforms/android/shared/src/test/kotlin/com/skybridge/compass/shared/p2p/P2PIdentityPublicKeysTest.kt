package com.skybridge.compass.shared.p2p

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class P2PIdentityPublicKeysTest {

    @Test
    fun allSupportedAlgorithmsRoundTripWithExactProductionKeyLengths() {
        val fixtures = listOf(
            P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519 to ByteArray(32) { it.toByte() },
            P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65 to ByteArray(1_952) { (it * 3).toByte() },
            P2PIdentityPublicKeys.ProtocolAlgorithm.P256_ECDSA_LEGACY to
                ByteArray(65) { (it + 7).toByte() }
        )

        fixtures.forEach { (algorithm, publicKey) ->
            val expected = P2PIdentityPublicKeys.Keys(
                protocolPublicKey = publicKey,
                protocolAlgorithm = algorithm
            )
            val decoded = P2PIdentityPublicKeys.decode(expected.encode())

            assertEquals(algorithm, decoded.protocolAlgorithm)
            assertArrayEquals(publicKey, decoded.protocolPublicKey)
            assertNull(decoded.secureEnclavePublicKey)
        }
    }

    @Test
    fun secureEnclavePublicKeyRoundTripsWithMandatoryPresenceMarker() {
        val secureEnclaveKey = ByteArray(65) { (0xA0 + it).toByte() }
        val expected = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = ByteArray(32) { (0x40 + it).toByte() },
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = secureEnclaveKey
        )

        val decoded = P2PIdentityPublicKeys.decode(expected.encode())

        assertArrayEquals(expected.protocolPublicKey, decoded.protocolPublicKey)
        assertArrayEquals(secureEnclaveKey, decoded.secureEnclavePublicKey)
        assertArrayEquals(expected.encode(), decoded.encode())
    }

    @Test
    fun emptyButPresentSecureEnclaveKeyRetainsMarkerOneOnRoundTrip() {
        val expected = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = ByteArray(32),
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = ByteArray(0)
        )
        val encoded = expected.encode()

        val decoded = P2PIdentityPublicKeys.decode(encoded)

        assertArrayEquals(ByteArray(0), decoded.secureEnclavePublicKey)
        assertArrayEquals(encoded, decoded.encode())
    }

    @Test
    fun encoderRejectsEveryAlgorithmWithWrongProtocolKeyLength() {
        val invalid = listOf(
            P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519 to 31,
            P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519 to 33,
            P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65 to 1_951,
            P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65 to 1_953,
            P2PIdentityPublicKeys.ProtocolAlgorithm.P256_ECDSA_LEGACY to 64,
            P2PIdentityPublicKeys.ProtocolAlgorithm.P256_ECDSA_LEGACY to 66
        )

        invalid.forEach { (algorithm, keyLength) ->
            assertThrows(IllegalArgumentException::class.java) {
                P2PIdentityPublicKeys.Keys(
                    protocolPublicKey = ByteArray(keyLength),
                    protocolAlgorithm = algorithm
                ).encode()
            }
        }
    }

    @Test
    fun encoderRejectsLengthsThatCannotBeRepresentedAsUInt16() {
        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.Keys(
                protocolPublicKey = ByteArray(65_536),
                protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519
            ).encode()
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.Keys(
                protocolPublicKey = ByteArray(32),
                protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
                secureEnclavePublicKey = ByteArray(65_536)
            ).encode()
        }
    }

    @Test
    fun decoderRejectsWrongAlgorithmSpecificLengthBeforeReadingKeyBytes() {
        val encoded = identityWire(
            algorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            declaredProtocolKeyLength = 31,
            protocolKey = ByteArray(31),
            suffix = byteArrayOf(0x00)
        )

        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.decode(encoded)
        }
    }

    @Test
    fun decoderRejectsUnknownAlgorithm() {
        val encoded = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = ByteArray(32),
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519
        ).encode().also { it[0] = 0x7F }

        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.decode(encoded)
        }
    }

    @Test
    fun decoderRequiresPresenceMarkerAndRejectsInvalidMarker() {
        val withoutMarker = identityWire(
            algorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            declaredProtocolKeyLength = 32,
            protocolKey = ByteArray(32),
            suffix = ByteArray(0)
        )
        val invalidMarker = withoutMarker + byteArrayOf(0x02)

        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.decode(withoutMarker)
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.decode(invalidMarker)
        }
    }

    @Test
    fun decoderRejectsDeclaredExactKeyWhoseBytesOrMarkerAreTruncated() {
        val keyAndMarkerTruncated = identityWire(
            algorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            declaredProtocolKeyLength = 32,
            protocolKey = ByteArray(31),
            suffix = byteArrayOf(0x00)
        )
        val markerTruncated = identityWire(
            algorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            declaredProtocolKeyLength = 32,
            protocolKey = ByteArray(32),
            suffix = ByteArray(0)
        )

        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.decode(keyAndMarkerTruncated)
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.decode(markerTruncated)
        }
    }

    @Test
    fun decoderRejectsTrailingBytesForAbsentAndPresentSecureEnclaveKey() {
        val base = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = ByteArray(32),
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519
        ).encode()
        val withSecureEnclave = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = ByteArray(32),
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = byteArrayOf(0x11)
        ).encode()

        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.decode(base + byteArrayOf(0x7F))
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.decode(withSecureEnclave + byteArrayOf(0x7F))
        }
    }

    @Test
    fun decoderRejectsTruncatedSecureEnclaveLengthAndValue() {
        val prefix = identityWire(
            algorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            declaredProtocolKeyLength = 32,
            protocolKey = ByteArray(32),
            suffix = byteArrayOf(0x01)
        )
        val truncatedLength = prefix + byteArrayOf(0x02)
        val truncatedValue = prefix + byteArrayOf(0x02, 0x00, 0x55)

        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.decode(truncatedLength)
        }
        assertThrows(IllegalArgumentException::class.java) {
            P2PIdentityPublicKeys.decode(truncatedValue)
        }
    }

    private fun identityWire(
        algorithm: P2PIdentityPublicKeys.ProtocolAlgorithm,
        declaredProtocolKeyLength: Int,
        protocolKey: ByteArray,
        suffix: ByteArray
    ): ByteArray = ByteBuffer.allocate(3 + protocolKey.size + suffix.size)
        .order(ByteOrder.LITTLE_ENDIAN)
        .put(algorithm.wireByte)
        .putShort(declaredProtocolKeyLength.toShort())
        .put(protocolKey)
        .put(suffix)
        .array()
}
