package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import com.skybridge.compass.shared.p2p.P2PXWingKem
import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PeerKemKeyStoreRecordsTest {

    @Test
    fun formalAcceptanceRejectsLegacyOrUnknownKemTrustOrigin() {
        assertFalse(PeerKemTrustOriginPolicy.isFormalAcceptanceEligible(null))
        assertFalse(PeerKemTrustOriginPolicy.isFormalAcceptanceEligible("diagnostic"))
        assertTrue(
            PeerKemTrustOriginPolicy.isFormalAcceptanceEligible(
                PeerKemTrustOriginPolicy.AUTHENTICATED_PRODUCT_V1
            )
        )
    }

    @Test
    fun materializeValidatesEphemeralJoinKeysWithoutAStoredRecord() {
        val xWingKey = key(P2PXWingKem.XWING_PUBLIC_KEY_SIZE, 31)
        val materialized = PeerKemKeyStoreRecords.materialize(
            kemPublicKeys = listOf(
                AppMessage.KemPublicKeyInfo(
                    suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                    publicKey = xWingKey
                )
            ),
            platform = "Android",
            osVersion = "Android 16 (API 36)"
        )

        assertArrayEquals(xWingKey, checkNotNull(materialized.xWingPublicKey))
        assertNull(materialized.qPeriaptPublicKey)
        assertNull(materialized.mlKem768PublicKey)
    }

    @Test
    fun snapshotPersistsAndLoadsEligibleQPeriaptPeers() {
        listOf(
            "macOS" to "macOS 26.0",
            "iOS" to "iOS 26.1",
            "Android" to "Android 16 (API 36)"
        ).forEachIndexed { index, (platform, osVersion) ->
            val qKey = key(P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE, index + 1)
            val record = PeerKemKeyStoreRecords.snapshot(
                kemPublicKeys = listOf(
                    AppMessage.KemPublicKeyInfo(
                        suiteWireId = P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND.wireId.toInt(),
                        publicKey = qKey
                    )
                ),
                platform = platform,
                osVersion = osVersion,
                updatedAtMillis = 123L
            )

            val loaded = PeerKemKeyStoreRecords.load(record)

            assertFalse(loaded.clearQPeriapt)
            assertArrayEquals(qKey, checkNotNull(loaded.keys.qPeriaptPublicKey))
            assertTrue(record.qPeriaptAllowed)
            assertTrue(checkNotNull(record.qPeriaptPlatform).contains(osVersion))
        }
    }

    @Test
    fun snapshotRejectsUnsupportedQPeriaptPeerMetadata() {
        val qKey = key(P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE, 7)
        listOf(
            "macOS" to "macOS 25.9",
            "iOS" to "iOS 25.9",
            "Android" to "Android 15 (API 35)",
            "Android" to "Android 16 (API 35)",
            "Android" to "Android 15 (API 36)",
            "Windows" to "Windows 26",
            null to "26.0"
        ).forEach { (platform, osVersion) ->
            assertThrows(IllegalArgumentException::class.java) {
                PeerKemKeyStoreRecords.snapshot(
                    kemPublicKeys = listOf(
                        AppMessage.KemPublicKeyInfo(
                            suiteWireId = P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND.wireId.toInt(),
                            publicKey = qKey
                        )
                    ),
                    platform = platform,
                    osVersion = osVersion,
                    updatedAtMillis = 456L
                )
            }
        }
    }

    @Test
    fun loadIgnoresLegacyQPeriaptKeyWithoutAllowedMarker() {
        val qKey = key(P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE, 2)
        val loaded = PeerKemKeyStoreRecords.load(
            PeerKemKeyStoreRecord(
                qPeriaptPublicKeyBase64 = encode(qKey),
                qPeriaptAllowed = false,
                qPeriaptPlatform = null,
                xWingPublicKeyBase64 = null,
                mlKem768PublicKeyBase64 = null
            )
        )

        assertFalse(loaded.clearQPeriapt)
        assertNull(loaded.keys.qPeriaptPublicKey)
    }

    @Test
    fun loadClearsQPeriaptMarkerWhenStoredPlatformIsNoLongerEligible() {
        val qKey = key(P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE, 3)
        val loaded = PeerKemKeyStoreRecords.load(
            PeerKemKeyStoreRecord(
                qPeriaptPublicKeyBase64 = encode(qKey),
                qPeriaptAllowed = true,
                qPeriaptPlatform = "Android Android 15 (API 35)",
                xWingPublicKeyBase64 = null,
                mlKem768PublicKeyBase64 = null
            )
        )

        assertTrue(loaded.clearQPeriapt)
        assertNull(loaded.keys.qPeriaptPublicKey)
    }

    @Test
    fun loadFailsExplicitlyWhenAllowedQPeriaptKeyHasBadLength() {
        val badQKey = key(P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE - 1, 4)

        assertThrows(IllegalArgumentException::class.java) {
            PeerKemKeyStoreRecords.load(
                PeerKemKeyStoreRecord(
                    qPeriaptPublicKeyBase64 = encode(badQKey),
                    qPeriaptAllowed = true,
                    qPeriaptPlatform = "macOS macOS 26.0",
                    xWingPublicKeyBase64 = null,
                    mlKem768PublicKeyBase64 = null
                )
            )
        }
    }

    @Test
    fun snapshotTreatsIncomingKemListAsAuthoritativeSuiteSet() {
        val xWingKey = key(P2PXWingKem.XWING_PUBLIC_KEY_SIZE, 5)
        val first = PeerKemKeyStoreRecords.snapshot(
            kemPublicKeys = listOf(
                AppMessage.KemPublicKeyInfo(
                    suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                    publicKey = xWingKey
                )
            ),
            platform = "Android",
            osVersion = "Android 16 (API 36)",
            updatedAtMillis = 100L
        )
        val second = PeerKemKeyStoreRecords.snapshot(
            kemPublicKeys = listOf(
                AppMessage.KemPublicKeyInfo(
                    suiteWireId = P2PCryptoSuite.MLKEM_768.wireId.toInt(),
                    publicKey = key(AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE, 6)
                )
            ),
            platform = "Android",
            osVersion = "Android 16 (API 36)",
            updatedAtMillis = 101L
        )

        assertArrayEquals(xWingKey, checkNotNull(PeerKemKeyStoreRecords.load(first).keys.xWingPublicKey))
        assertNull(second.xWingPublicKeyBase64)
        assertNull(PeerKemKeyStoreRecords.load(second).keys.xWingPublicKey)
    }

    private fun key(length: Int, seed: Int): ByteArray =
        ByteArray(length) { index -> ((index + seed) and 0xFF).toByte() }

    private fun encode(value: ByteArray): String =
        Base64.getEncoder().encodeToString(value)
}
