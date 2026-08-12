package com.skybridge.compass.core.p2p

import android.content.SharedPreferences
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Trust-persistence round-trip for the PIB-1 pairing flow.
 *
 * After the user confirms the SAS, [PibPairingClient.confirmPairing] atomically verifies the final
 * acknowledgement and calls [TrustedPeerStore.upsertVerifiedCurrentPathAuthority]. This verifies the record survives a save/load cycle
 * with the exact (deviceId, fingerprint, algorithm) tuple, and that a subsequent connect resolves the
 * trusted peer by device id (so re-pairing is skipped) — mirroring the macOS resolver gate.
 *
 * Uses an in-memory [SharedPreferences] fake; [TrustedPeerStore] only depends on SharedPreferences
 * (records are serialized with kotlinx JSON, no android.util.Base64), so this runs as a plain JVM
 * unit test under the core module's JUnit-4 runner.
 */
class TrustedPeerStoreRoundTripTest {

    private val macDeviceId = "mac-AABBCCDD-1122-3344"
    private val macFingerprint = "ab".repeat(32)   // 64-hex
    private val rotatedFingerprint = "cd".repeat(32)
    private val macAlgorithm = "ML-DSA-65"
    private val macName = "Bill's Mac"
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    @Test
    fun verifiedProductTrustCarriesFormalAcceptanceProvenance() {
        val prefs = InMemorySharedPreferences()
        val stored = TrustedPeerStore(prefs).upsertVerifiedCurrentPathAuthority(
            deviceId = macDeviceId,
            protocolPublicKeyFingerprint = macFingerprint
        )

        assertEquals(
            TrustedPeerVerificationOrigin.AUTHENTICATED_PRODUCT_V1,
            stored.verificationOrigin
        )
        assertEquals(
            macFingerprint,
            FormalAcceptancePrefsTrustStore(prefs).loadPeerSigningFingerprint(macDeviceId)
        )
    }

    @Test
    fun legacyTrustRemainsStoredButIsInvisibleToFormalAcceptance() {
        val prefs = InMemorySharedPreferences()
        writeRecords(
            prefs,
            listOf(
                TrustedPeerRecord(
                    deviceId = macDeviceId,
                    protocolPublicKeyFingerprint = macFingerprint
                )
            )
        )
        assertNull(
            FormalAcceptancePrefsTrustStore(prefs).loadPeerSigningFingerprint(macDeviceId)
        )
        assertEquals(1, TrustedPeerStore(prefs).loadAll().size)
    }

    @Test
    fun formalAcceptanceReadDoesNotRepairExistingCorruptionMarker() {
        val prefs = InMemorySharedPreferences()
        TrustedPeerStore(prefs).upsertVerifiedCurrentPathAuthority(
            deviceId = macDeviceId,
            protocolPublicKeyFingerprint = macFingerprint
        )
        prefs.edit()
            .putBoolean(TrustedPeerStore.KEY_CORRUPTED, true)
            .putString(TrustedPeerStore.KEY_CORRUPTION_DETAIL, "existing marker")
            .apply()

        expectCorruption {
            FormalAcceptancePrefsTrustStore(prefs).loadPeerSigningFingerprint(macDeviceId)
        }
        assertTrue(prefs.getBoolean(TrustedPeerStore.KEY_CORRUPTED, false))
        assertEquals(
            "existing marker",
            prefs.getString(TrustedPeerStore.KEY_CORRUPTION_DETAIL, null)
        )
        assertEquals(1, TrustedPeerStore(prefs).loadAll().size)
        assertFalse(
            "normal product read repairs the marker only after the formal read remained non-mutating",
            prefs.getBoolean(TrustedPeerStore.KEY_CORRUPTED, false)
        )
    }

    @Test
    fun formalAcceptanceReadDoesNotWriteAnewCorruptionMarker() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString(TrustedPeerStore.KEY_RECORDS_JSON, "{not-json")
            .apply()

        expectCorruption {
            FormalAcceptancePrefsTrustStore(prefs).loadPeerSigningFingerprint(macDeviceId)
        }
        assertFalse(prefs.contains(TrustedPeerStore.KEY_CORRUPTED))
        assertFalse(prefs.contains(TrustedPeerStore.KEY_CORRUPTION_DETAIL))
    }

    @Test
    fun exactExistingAdmissionIsAtomicReadOnlyAndPreservesCorruptionMarker() {
        val prefs = InMemorySharedPreferences()
        val store = TrustedPeerStore(prefs)
        store.upsertVerifiedCurrentPathAuthority(
            deviceId = macDeviceId,
            protocolPublicKeyFingerprint = macFingerprint
        )
        prefs.edit()
            .putBoolean(TrustedPeerStore.KEY_CORRUPTED, true)
            .putString(TrustedPeerStore.KEY_CORRUPTION_DETAIL, "existing marker")
            .apply()
        val before = prefs.all.toMap()

        val admission = store.evaluateExactExistingAuthorityReadOnly(
            deviceIds = listOf(macDeviceId),
            protocolPublicKeyFingerprint = macFingerprint
        )

        assertNull(admission.exactAuthority)
        assertEquals(PairingTrustConflict.TRUST_STORE_CORRUPTED, admission.conflict)
        assertEquals(before, prefs.all)
    }

    @Test
    fun exactExistingAdmissionDoesNotCreateCorruptionMarkerForMalformedRecords() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString(TrustedPeerStore.KEY_RECORDS_JSON, "{not-json")
            .apply()
        val before = prefs.all.toMap()

        val admission = TrustedPeerStore(prefs).evaluateExactExistingAuthorityReadOnly(
            deviceIds = listOf(macDeviceId),
            protocolPublicKeyFingerprint = macFingerprint
        )

        assertNull(admission.exactAuthority)
        assertEquals(PairingTrustConflict.TRUST_STORE_CORRUPTED, admission.conflict)
        assertEquals(before, prefs.all)
        assertFalse(prefs.contains(TrustedPeerStore.KEY_CORRUPTED))
    }

    @Test
    fun exactExistingAdmissionReturnsOneProductAuthorityWithoutMutation() {
        val prefs = InMemorySharedPreferences()
        val store = TrustedPeerStore(prefs)
        store.upsertVerifiedCurrentPathAuthority(
            deviceId = macDeviceId,
            protocolPublicKeyFingerprint = macFingerprint
        )
        val before = prefs.all.toMap()

        val admission = store.evaluateExactExistingAuthorityReadOnly(
            deviceIds = listOf(macDeviceId),
            protocolPublicKeyFingerprint = macFingerprint
        )

        assertNotNull(admission.exactAuthority)
        assertNull(admission.conflict)
        assertEquals(before, prefs.all)
    }

    @Test
    fun readOnlyIncludingInactivePreservesExistingCorruptionMarkerWithValidJson() {
        val prefs = InMemorySharedPreferences()
        writeRecords(
            prefs,
            listOf(
                TrustedPeerRecord(
                    deviceId = macDeviceId,
                    protocolPublicKeyFingerprint = macFingerprint,
                    verificationOrigin = TrustedPeerVerificationOrigin.AUTHENTICATED_PRODUCT_V1
                )
            )
        )
        prefs.edit()
            .putBoolean(TrustedPeerStore.KEY_CORRUPTED, true)
            .putString(TrustedPeerStore.KEY_CORRUPTION_DETAIL, "existing marker")
            .apply()

        expectCorruption {
            TrustedPeerStore(prefs)
                .findRecordByKnownDeviceIdIncludingInactiveReadOnly(macDeviceId)
        }

        assertTrue(prefs.getBoolean(TrustedPeerStore.KEY_CORRUPTED, false))
        assertEquals("existing marker", prefs.getString(TrustedPeerStore.KEY_CORRUPTION_DETAIL, null))
    }

    @Test
    fun formalReadOnlyLookupsRejectCorruptionBeforeValidatingCallerDeviceId() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putBoolean(TrustedPeerStore.KEY_CORRUPTED, true)
            .putString(TrustedPeerStore.KEY_CORRUPTION_DETAIL, "existing marker")
            .apply()
        val store = TrustedPeerStore(prefs)

        listOf("invalid=device", "x".repeat(TrustedPeerDeviceIdValidation.MAX_LENGTH + 1))
            .forEach { invalidDeviceId ->
                expectCorruption {
                    store.findRecordByKnownDeviceIdIncludingInactiveReadOnly(invalidDeviceId)
                }
                expectCorruption {
                    store.findVerifiedRecordByKnownDeviceIdReadOnly(invalidDeviceId)
                }
            }

        assertTrue(prefs.getBoolean(TrustedPeerStore.KEY_CORRUPTED, false))
        assertEquals("existing marker", prefs.getString(TrustedPeerStore.KEY_CORRUPTION_DETAIL, null))
    }

    @Test
    fun readOnlyIncludingInactiveInvalidJsonDoesNotWriteIntegrityMarkers() {
        val prefs = InMemorySharedPreferences()
        prefs.edit().putString(TrustedPeerStore.KEY_RECORDS_JSON, "{not-json").apply()

        expectCorruption {
            TrustedPeerStore(prefs)
                .findRecordByKnownDeviceIdIncludingInactiveReadOnly(macDeviceId)
        }

        assertFalse(prefs.contains(TrustedPeerStore.KEY_CORRUPTED))
        assertFalse(prefs.contains(TrustedPeerStore.KEY_CORRUPTION_DETAIL))
    }

    @Test
    fun readOnlyIncludingInactiveReturnsBlockedAndUnverifiedCanonicalRecordsWithoutMutation() {
        val states = listOf(
            TrustedPeerLifecycleState.REVERIFICATION_REQUIRED,
            TrustedPeerLifecycleState.QUARANTINED,
            TrustedPeerLifecycleState.REVOKED
        )
        states.forEach { state ->
            val prefs = InMemorySharedPreferences()
            val record = TrustedPeerRecord(
                deviceId = macDeviceId,
                protocolPublicKeyFingerprint = macFingerprint,
                lifecycleState = state
            )
            writeRecords(prefs, listOf(record))
            val before = prefs.all.toMap()

            assertEquals(
                record,
                TrustedPeerStore(prefs)
                    .findRecordByKnownDeviceIdIncludingInactiveReadOnly(macDeviceId)
            )
            assertEquals(before, prefs.all.toMap())
        }
    }

    @Test
    fun pibFinalAckExplicitApprovalMigratesSignedCanonicalIdAndBonjourAlias() {
        val prefs = InMemorySharedPreferences()
        val bonjourAlias = "bonjour:mac@local."
        val canonicalId = "id:mac-1"
        writeRecords(
            prefs,
            listOf(
                TrustedPeerRecord(
                    deviceId = bonjourAlias,
                    currentDeviceId = bonjourAlias,
                    knownDeviceIds = listOf(bonjourAlias),
                    protocolPublicKeyFingerprint = macFingerprint
                )
            )
        )

        val stored = PibPairingClient.persistVerifiedFinalAckAuthority(
            trustedPeerStore = TrustedPeerStore(prefs),
            deviceId = canonicalId,
            protocolPublicKeyFingerprint = macFingerprint,
            name = macName,
            protocolSigningAlgorithm = macAlgorithm,
            aliasIds = listOf(bonjourAlias)
        )

        assertTrue(canonicalId in stored.knownDeviceIds)
        assertTrue(bonjourAlias in stored.knownDeviceIds)
        assertEquals(TrustedPeerVerificationOrigin.AUTHENTICATED_PRODUCT_V1, stored.verificationOrigin)
        assertEquals(
            stored,
            TrustedPeerStore(prefs).findByKnownDeviceId(canonicalId)
        )
    }

    @Test
    fun pibFinalAckExplicitApprovalRejectsCrossOwnerAliasWithoutMutation() {
        val prefs = InMemorySharedPreferences()
        val store = TrustedPeerStore(prefs)
        val firstId = "id:mac-1"
        val secondId = "id:mac-2"
        store.upsertVerifiedCurrentPathAuthority(firstId, macFingerprint)
        store.upsertVerifiedCurrentPathAuthority(secondId, rotatedFingerprint)
        val before = prefs.all.toMap()

        val failure = expectPibPersistenceFailure {
            PibPairingClient.persistVerifiedFinalAckAuthority(
                trustedPeerStore = store,
                deviceId = secondId,
                protocolPublicKeyFingerprint = rotatedFingerprint,
                name = null,
                protocolSigningAlgorithm = macAlgorithm,
                aliasIds = listOf(firstId)
            )
        }

        assertTrue(failure.finalAckVerified)
        assertTrue(failure.rollbackConfirmed)
        assertEquals(before, prefs.all.toMap())
    }

    @Test
    fun pibFinalAckPersistenceReportsConfirmedRollbackAndUncertainRollback() {
        val commitFalsePrefs = InMemorySharedPreferences(commitSucceeds = false)
        val confirmed = expectPibPersistenceFailure {
            PibPairingClient.persistVerifiedFinalAckAuthority(
                trustedPeerStore = TrustedPeerStore(commitFalsePrefs),
                deviceId = macDeviceId,
                protocolPublicKeyFingerprint = macFingerprint,
                name = macName,
                protocolSigningAlgorithm = macAlgorithm,
                aliasIds = emptyList()
            )
        }
        assertTrue(confirmed.finalAckVerified)
        assertTrue(confirmed.rollbackConfirmed)

        val uncertainPrefs = InMemorySharedPreferences()
        val uncertainStore = TrustedPeerStore(uncertainPrefs)
        uncertainStore.upsertVerifiedCurrentPathAuthority(macDeviceId, macFingerprint)
        uncertainPrefs.enqueueCommitModes(
            CommitMode.THROW_AFTER_WRITE,
            CommitMode.RETURN_TRUE_WITHOUT_WRITE
        )
        val uncertain = expectPibPersistenceFailure {
            PibPairingClient.persistVerifiedFinalAckAuthority(
                trustedPeerStore = uncertainStore,
                deviceId = "id:mac-uncertain",
                protocolPublicKeyFingerprint = rotatedFingerprint,
                name = macName,
                protocolSigningAlgorithm = macAlgorithm,
                aliasIds = emptyList()
            )
        }
        assertTrue(uncertain.finalAckVerified)
        assertFalse(uncertain.rollbackConfirmed)
    }

    @Test
    fun pibFinalAckRecordsReadFailureReportsUncertainTypedPersistenceWithoutWriting() {
        val prefs = InMemorySharedPreferences(
            recordsReadObserver = {
                throw IllegalStateException("scripted records read failure")
            }
        )

        val failure = expectPibPersistenceFailure {
            PibPairingClient.persistVerifiedFinalAckAuthority(
                trustedPeerStore = TrustedPeerStore(prefs),
                deviceId = macDeviceId,
                protocolPublicKeyFingerprint = macFingerprint,
                name = macName,
                protocolSigningAlgorithm = macAlgorithm,
                aliasIds = emptyList()
            )
        }

        assertTrue(failure.finalAckVerified)
        assertFalse(failure.rollbackConfirmed)
        assertTrue(prefs.all.isEmpty())
    }

    @Test
    fun pibFinalAckSnapshotReadFailureReportsUncertainTypedPersistenceWithoutWriting() {
        val recordReads = AtomicInteger()
        val prefs = InMemorySharedPreferences(
            recordsReadObserver = {
                if (recordReads.incrementAndGet() == 2) {
                    throw IllegalStateException("scripted snapshot read failure")
                }
            }
        )

        val failure = expectPibPersistenceFailure {
            PibPairingClient.persistVerifiedFinalAckAuthority(
                trustedPeerStore = TrustedPeerStore(prefs),
                deviceId = macDeviceId,
                protocolPublicKeyFingerprint = macFingerprint,
                name = macName,
                protocolSigningAlgorithm = macAlgorithm,
                aliasIds = emptyList()
            )
        }

        assertTrue(failure.finalAckVerified)
        assertFalse(failure.rollbackConfirmed)
        assertTrue(prefs.all.isEmpty())
    }

    @Test
    fun pibFinalAckTrustReadPreservesCancellationIdentity() {
        val cancellation = CancellationException("scripted trust read cancellation")
        val prefs = InMemorySharedPreferences(
            recordsReadObserver = { throw cancellation }
        )

        try {
            PibPairingClient.persistVerifiedFinalAckAuthority(
                trustedPeerStore = TrustedPeerStore(prefs),
                deviceId = macDeviceId,
                protocolPublicKeyFingerprint = macFingerprint,
                name = macName,
                protocolSigningAlgorithm = macAlgorithm,
                aliasIds = emptyList()
            )
            fail("expected trust read cancellation")
        } catch (actual: CancellationException) {
            assertTrue(actual === cancellation)
        }
        assertTrue(prefs.all.isEmpty())
    }

    @Test
    fun formalAcceptanceTrustStoreRejectsWrites() {
        val prefs = InMemorySharedPreferences()
        val store = FormalAcceptancePrefsTrustStore(prefs)

        try {
            store.savePeerSigningFingerprint(macDeviceId, macFingerprint)
            fail("formal acceptance trust store accepted a write")
        } catch (expected: IllegalStateException) {
            assertEquals("formal acceptance trust store is read-only", expected.message)
        }
        assertTrue(TrustedPeerStore(prefs).loadAll().isEmpty())
    }

    @Test
    fun unverifiedAuthorityDoesNotGainFormalAcceptanceProvenance() {
        val prefs = InMemorySharedPreferences()
        val stored = checkNotNull(
            TrustedPeerStore(prefs).upsertCurrentPathAuthority(
                deviceId = macDeviceId,
                protocolPublicKeyFingerprint = macFingerprint
            )
        )

        assertNull(stored.verificationOrigin)
        assertNull(
            FormalAcceptancePrefsTrustStore(prefs).loadPeerSigningFingerprint(macDeviceId)
        )
    }

    @Test
    fun pib1TrustPersistsAndResolvesByDeviceId() {
        val prefs = InMemorySharedPreferences()

        // First store writes a fresh record.
        val store1 = TrustedPeerStore(prefs)
        val saved = store1.upsertCurrentPathAuthority(
            deviceId = macDeviceId,
            protocolPublicKeyFingerprint = macFingerprint,
            name = macName,
            protocolSigningAlgorithm = macAlgorithm,
            aliasIds = listOf("mac-alias-1")
        )
        assertNotNull("upsert should return the stored record", saved)
        assertEquals(macDeviceId, saved!!.deviceId)
        assertEquals(macFingerprint, saved.protocolPublicKeyFingerprint)
        assertEquals(macAlgorithm, saved.protocolSigningAlgorithm)

        // A SECOND store instance reads the same backing prefs — proves it round-tripped through JSON.
        val store2 = TrustedPeerStore(prefs)
        val all = store2.loadAll()
        assertEquals(1, all.size)
        assertEquals(macFingerprint, all.first().protocolPublicKeyFingerprint)

        // The inbound resolver gate is deviceId-based: a later connect must find the trusted peer.
        val resolved = store2.findByKnownDeviceId(macDeviceId)
        assertNotNull("Mac must resolve as trusted after pairing", resolved)
        assertEquals(macDeviceId, resolved!!.currentDeviceId)

        // Alias resolution also works (knownDeviceIds includes the alias).
        assertNotNull(store2.findByKnownDeviceId("mac-alias-1"))

        // Current-path fingerprint lookup matches the pinned fingerprint.
        assertNotNull(store2.currentPathTrustRecord(macFingerprint))
    }

    @Test
    fun reUpsertSameMacIsIdempotent() {
        val prefs = InMemorySharedPreferences()
        val store = TrustedPeerStore(prefs)
        store.upsertCurrentPathAuthority(macDeviceId, macFingerprint, macName, macAlgorithm)
        store.upsertCurrentPathAuthority(macDeviceId, macFingerprint, macName, macAlgorithm)
        assertEquals("re-pairing the same Mac must not duplicate records", 1, store.loadAll().size)
    }

    @Test
    fun verifiedAuthorityPersistsFreshRecord() {
        val store = TrustedPeerStore(InMemorySharedPreferences())

        val record = store.upsertVerifiedCurrentPathAuthority(
            deviceId = macDeviceId,
            protocolPublicKeyFingerprint = macFingerprint,
            name = macName,
            protocolSigningAlgorithm = macAlgorithm,
            aliasIds = listOf("mac-alias-1")
        )

        assertEquals(macDeviceId, record.currentDeviceId)
        assertEquals(macFingerprint, record.protocolPublicKeyFingerprint)
        assertNotNull(store.findByKnownDeviceId(macDeviceId))
        assertNotNull(store.findByKnownDeviceId("mac-alias-1"))
    }

    @Test
    fun verifiedAuthorityRejectsSameDeviceDifferentFingerprint() {
        val store = TrustedPeerStore(InMemorySharedPreferences())
        store.upsertCurrentPathAuthority(macDeviceId, macFingerprint, macName, macAlgorithm)

        val error = expectPersistenceFailure {
            store.upsertVerifiedCurrentPathAuthority(
                deviceId = macDeviceId,
                protocolPublicKeyFingerprint = rotatedFingerprint,
                name = macName,
                protocolSigningAlgorithm = macAlgorithm
            )
        }

        assertEquals(PairingTrustConflict.IDENTITY_CONFLICT, error.conflict)
        assertEquals(macFingerprint, store.findByKnownDeviceId(macDeviceId)?.protocolPublicKeyFingerprint)
    }

    @Test
    fun verifiedAuthorityRejectsFingerprintAlreadyPinnedToAnotherDevice() {
        val store = TrustedPeerStore(InMemorySharedPreferences())
        store.upsertCurrentPathAuthority(macDeviceId, macFingerprint, macName, macAlgorithm)

        val error = expectPersistenceFailure {
            store.upsertVerifiedCurrentPathAuthority(
                deviceId = "mac-new-device-id",
                protocolPublicKeyFingerprint = macFingerprint,
                name = macName,
                protocolSigningAlgorithm = macAlgorithm
            )
        }

        assertEquals(PairingTrustConflict.DEVICE_ID_MIGRATION_REQUIRED, error.conflict)
        assertNull(store.findByKnownDeviceId("mac-new-device-id"))
    }

    @Test
    fun invalidFingerprintIsRejected() {
        val store = TrustedPeerStore(InMemorySharedPreferences())
        assertNull(store.upsertCurrentPathAuthority(macDeviceId, "not-hex", macName, macAlgorithm))
        assertTrue(store.loadAll().isEmpty())
    }

    @Test
    fun corruptStoreIsExplicitWhenLoadedDirectly() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString(TrustedPeerStore.KEY_RECORDS_JSON, "{not-json")
            .apply()

        val store = TrustedPeerStore(prefs)

        try {
            store.loadAll()
            fail("corrupt trust store must not be reported as an empty healthy store")
        } catch (_: TrustedPeerStoreCorruptionException) {
            val status = store.integrityStatus()
            assertEquals(TrustedPeerStoreIntegrityState.CORRUPTED, status.state)
            assertTrue(status.detail?.isNotBlank() == true)
        }
    }

    @Test
    fun trustLookupsFailClosedWhenStoreIsCorrupt() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString(TrustedPeerStore.KEY_RECORDS_JSON, "{not-json")
            .apply()

        val store = TrustedPeerStore(prefs)

        expectCorruption { store.findByKnownDeviceId(macDeviceId) }
        expectCorruption { store.currentPathTrustRecord(macFingerprint) }
        assertEquals(
            PairingTrustConflict.TRUST_STORE_CORRUPTED,
            store.evaluateCurrentPathBinding(macDeviceId, macFingerprint)
        )
        assertEquals(TrustedPeerStoreIntegrityState.CORRUPTED, store.integrityStatus().state)
    }

    @Test
    fun upsertDoesNotOverwriteCorruptStore() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString(TrustedPeerStore.KEY_RECORDS_JSON, "{not-json")
            .apply()

        val store = TrustedPeerStore(prefs)

        expectCorruption {
            store.upsertCurrentPathAuthority(macDeviceId, macFingerprint, macName, macAlgorithm)
        }
        assertEquals("{not-json", prefs.getString(TrustedPeerStore.KEY_RECORDS_JSON, null))
        assertEquals(TrustedPeerStoreIntegrityState.CORRUPTED, store.integrityStatus().state)
    }

    @Test
    fun sameDeviceWithDifferentFingerprintReportsIdentityConflict() {
        val store = TrustedPeerStore(InMemorySharedPreferences())
        store.upsertCurrentPathAuthority(macDeviceId, macFingerprint, macName, macAlgorithm)

        assertEquals(
            PairingTrustConflict.IDENTITY_CONFLICT,
            store.evaluateCurrentPathBinding(macDeviceId, rotatedFingerprint)
        )
    }

    @Test
    fun sameFingerprintWithDifferentDeviceIdRequiresMigration() {
        val store = TrustedPeerStore(InMemorySharedPreferences())
        store.upsertCurrentPathAuthority(macDeviceId, macFingerprint, macName, macAlgorithm)

        assertEquals(
            PairingTrustConflict.DEVICE_ID_MIGRATION_REQUIRED,
            store.evaluateCurrentPathBinding("mac-new-device-id", macFingerprint)
        )
    }

    @Test
    fun nonActiveRecordsAreNotTrustedAndBlockCurrentPathBinding() {
        val blockedStates = listOf(
            TrustedPeerLifecycleState.REVERIFICATION_REQUIRED to PairingTrustConflict.QUARANTINED_IDENTITY,
            TrustedPeerLifecycleState.QUARANTINED to PairingTrustConflict.QUARANTINED_IDENTITY,
            TrustedPeerLifecycleState.REVOKED to PairingTrustConflict.REVOKED_IDENTITY
        )

        blockedStates.forEach { (state, expectedConflict) ->
            val prefs = InMemorySharedPreferences()
            writeRecords(
                prefs,
                listOf(
                    TrustedPeerRecord(
                        deviceId = macDeviceId,
                        name = macName,
                        protocolSigningAlgorithm = macAlgorithm,
                        protocolPublicKeyFingerprint = macFingerprint,
                        lifecycleState = state
                    )
                )
            )
            val store = TrustedPeerStore(prefs)

            assertNull("Non-active $state record must not resolve as trusted", store.findByKnownDeviceId(macDeviceId))
            assertNull("Non-active $state record must not resolve by fingerprint", store.currentPathTrustRecord(macFingerprint))
            assertEquals(expectedConflict, store.evaluateCurrentPathBinding(macDeviceId, macFingerprint))
            assertEquals(expectedConflict, store.evaluateCurrentPathBinding(macDeviceId, rotatedFingerprint))
            val beforeUpsert = prefs.getString(TrustedPeerStore.KEY_RECORDS_JSON, null)
            val observedBlockedRecord = store.upsertCurrentPathAuthority(macDeviceId, macFingerprint)
            assertEquals(
                "Upsert must not reactivate $state",
                state,
                observedBlockedRecord?.lifecycleState
            )
            assertEquals("Blocked upsert must not rewrite persistence", beforeUpsert, prefs.getString(TrustedPeerStore.KEY_RECORDS_JSON, null))
        }
    }

    @Test
    fun nonActiveCanonicalRecordBlocksLegacyPinFallback() {
        val prefs = InMemorySharedPreferences()
        writeRecords(
            prefs,
            listOf(
                TrustedPeerRecord(
                    deviceId = macDeviceId,
                    name = macName,
                    protocolSigningAlgorithm = macAlgorithm,
                    protocolPublicKeyFingerprint = macFingerprint,
                    lifecycleState = TrustedPeerLifecycleState.REVOKED
                )
            )
        )
        // Simulate a pre-canonical legacy pin left behind by an older Android build.
        prefs.edit()
            .putString("trust_fp_${macDeviceId.sha256Key()}", macFingerprint)
            .apply()

        assertNull(
            "a revoked canonical identity must not be resurrected by a legacy pin",
            PrefsTrustStore(prefs).loadPeerSigningFingerprint(macDeviceId)
        )
    }

    @Test
    fun legacyPinIsIgnoredWhenCanonicalStoreIsCorrupt() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString("trust_fp_${macDeviceId.sha256Key()}", macFingerprint)
            .putString(TrustedPeerStore.KEY_RECORDS_JSON, "{not-json")
            .apply()

        expectCorruption {
            PrefsTrustStore(prefs).loadPeerSigningFingerprint(macDeviceId)
        }
    }

    @Test
    fun legacyPinIsNotWrittenWhenCanonicalStoreIsCorrupt() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString(TrustedPeerStore.KEY_RECORDS_JSON, "{not-json")
            .apply()

        expectCorruption {
            PrefsTrustStore(prefs).savePeerSigningFingerprint(macDeviceId, macFingerprint)
        }
        assertFalse(prefs.contains("trust_fp_${macDeviceId.sha256Key()}"))
    }

    @Test
    fun legacyTrustAdapterRejectsUnapprovedDeviceIdMigration() {
        val prefs = InMemorySharedPreferences()
        val originalDeviceId = "mac-original-device"
        val replacementDeviceId = "mac-replacement-device"
        TrustedPeerStore(prefs).upsertVerifiedCurrentPathAuthority(
            deviceId = originalDeviceId,
            protocolPublicKeyFingerprint = macFingerprint
        )

        val failure = expectPersistenceFailure {
            PrefsTrustStore(prefs).savePeerSigningFingerprint(
                peerId = replacementDeviceId,
                peerSigningFingerprint = macFingerprint
            )
        }

        assertEquals(PairingTrustConflict.DEVICE_ID_MIGRATION_REQUIRED, failure.conflict)
        val stored = TrustedPeerStore(prefs).loadAll().single()
        assertEquals(originalDeviceId, stored.currentDeviceId)
        assertFalse(stored.knownDeviceIds.contains(replacementDeviceId))
        assertFalse(prefs.contains("trust_fp_${replacementDeviceId.sha256Key()}"))
    }

    @Test
    fun duplicateFingerprintRecordsAreRejectedAsCorrupt() {
        val prefs = InMemorySharedPreferences()
        writeRecords(
            prefs,
            listOf(
                TrustedPeerRecord(
                    deviceId = macDeviceId,
                    protocolPublicKeyFingerprint = macFingerprint
                ),
                TrustedPeerRecord(
                    deviceId = "mac-second-device-0001",
                    protocolPublicKeyFingerprint = macFingerprint
                )
            )
        )

        expectCorruption { TrustedPeerStore(prefs).loadAll() }
        assertEquals(TrustedPeerStoreIntegrityState.CORRUPTED, TrustedPeerStore(prefs).integrityStatus().state)
    }

    @Test
    fun duplicateAliasAcrossRecordsIsRejectedAsCorrupt() {
        val prefs = InMemorySharedPreferences()
        val sharedAlias = "mac-shared-alias-0001"
        writeRecords(
            prefs,
            listOf(
                TrustedPeerRecord(
                    deviceId = macDeviceId,
                    protocolPublicKeyFingerprint = macFingerprint,
                    knownDeviceIds = listOf(macDeviceId, sharedAlias)
                ),
                TrustedPeerRecord(
                    deviceId = "mac-second-device-0001",
                    protocolPublicKeyFingerprint = rotatedFingerprint,
                    knownDeviceIds = listOf("mac-second-device-0001", sharedAlias)
                )
            )
        )

        expectCorruption { TrustedPeerStore(prefs).loadAll() }
    }

    @Test
    fun verifiedUpsertRejectsAliasOwnedByAnotherPeerWithoutChangingSnapshot() {
        val prefs = InMemorySharedPreferences()
        val firstDeviceId = "mac-first-device-0001"
        val secondDeviceId = "mac-second-device-0001"
        val store = TrustedPeerStore(prefs)
        store.upsertVerifiedCurrentPathAuthority(
            deviceId = firstDeviceId,
            protocolPublicKeyFingerprint = macFingerprint
        )
        store.upsertVerifiedCurrentPathAuthority(
            deviceId = secondDeviceId,
            protocolPublicKeyFingerprint = rotatedFingerprint
        )
        val before = prefs.getString(TrustedPeerStore.KEY_RECORDS_JSON, null)

        val failure = expectPersistenceFailure {
            store.upsertVerifiedCurrentPathAuthority(
                deviceId = secondDeviceId,
                protocolPublicKeyFingerprint = rotatedFingerprint,
                aliasIds = listOf(firstDeviceId)
            )
        }

        assertEquals(PairingTrustConflict.IDENTITY_CONFLICT, failure.conflict)
        assertEquals(before, prefs.getString(TrustedPeerStore.KEY_RECORDS_JSON, null))
        assertEquals(2, store.loadAll().size)
    }

    @Test
    fun commitTrueWithoutWriteIsRejectedAndSnapshotRollbackIsConfirmedByReread() {
        val prefs = InMemorySharedPreferences()
        prefs.enqueueCommitModes(CommitMode.RETURN_TRUE_WITHOUT_WRITE, CommitMode.APPLY_TRUE)

        val failure = expectPersistenceFailure {
            TrustedPeerStore(prefs).upsertVerifiedCurrentPathAuthority(
                deviceId = macDeviceId,
                protocolPublicKeyFingerprint = macFingerprint
            )
        }

        assertTrue(failure.rollbackConfirmed)
        assertFalse(prefs.contains(TrustedPeerStore.KEY_RECORDS_JSON))
    }

    @Test
    fun wrongDurableValueIsRejectedAndExactPreviousSnapshotIsRestored() {
        val prefs = InMemorySharedPreferences()
        val store = TrustedPeerStore(prefs)
        store.upsertVerifiedCurrentPathAuthority(
            deviceId = macDeviceId,
            protocolPublicKeyFingerprint = macFingerprint
        )
        val before = prefs.getString(TrustedPeerStore.KEY_RECORDS_JSON, null)
        prefs.enqueueCommitModes(CommitMode.RETURN_TRUE_WITH_WRONG_RECORDS, CommitMode.APPLY_TRUE)

        val failure = expectPersistenceFailure {
            store.upsertVerifiedCurrentPathAuthority(
                deviceId = "mac-second-device-0001",
                protocolPublicKeyFingerprint = rotatedFingerprint
            )
        }

        assertTrue(failure.rollbackConfirmed)
        assertEquals(before, prefs.getString(TrustedPeerStore.KEY_RECORDS_JSON, null))
        assertEquals(listOf(macDeviceId), store.loadAll().map(TrustedPeerRecord::deviceId))
    }

    @Test
    fun commitThrowAfterWriteRollsBackButRollbackTrueWithoutWriteIsNotTrusted() {
        val prefs = InMemorySharedPreferences()
        val store = TrustedPeerStore(prefs)
        store.upsertVerifiedCurrentPathAuthority(
            deviceId = macDeviceId,
            protocolPublicKeyFingerprint = macFingerprint
        )
        val before = prefs.getString(TrustedPeerStore.KEY_RECORDS_JSON, null)
        prefs.enqueueCommitModes(
            CommitMode.THROW_AFTER_WRITE,
            CommitMode.RETURN_TRUE_WITHOUT_WRITE
        )

        val failure = expectPersistenceFailure {
            store.upsertVerifiedCurrentPathAuthority(
                deviceId = "mac-second-device-0001",
                protocolPublicKeyFingerprint = rotatedFingerprint
            )
        }

        assertFalse(failure.rollbackConfirmed)
        assertFalse(before == prefs.getString(TrustedPeerStore.KEY_RECORDS_JSON, null))
    }

    @Test
    fun corruptionMarkerCommitTrueWithoutWriteIsRejectedAndSnapshotIsRestored() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString(TrustedPeerStore.KEY_RECORDS_JSON, "{not-json")
            .apply()
        prefs.enqueueCommitModes(CommitMode.RETURN_TRUE_WITHOUT_WRITE, CommitMode.APPLY_TRUE)

        val failure = try {
            TrustedPeerStore(prefs).loadAll()
            fail("corrupt store unexpectedly loaded")
            error("unreachable")
        } catch (error: TrustedPeerStoreCorruptionException) {
            error
        }

        assertTrue(failure.message.orEmpty().contains("integrity marker persistence failed"))
        assertFalse(prefs.contains(TrustedPeerStore.KEY_CORRUPTED))
        assertFalse(prefs.contains(TrustedPeerStore.KEY_CORRUPTION_DETAIL))
        assertEquals("{not-json", prefs.getString(TrustedPeerStore.KEY_RECORDS_JSON, null))
    }

    @Test
    fun healthyMarkerClearCommitTrueWithoutWriteDoesNotClaimAHealthyStore() {
        val prefs = InMemorySharedPreferences()
        writeRecords(
            prefs,
            listOf(
                TrustedPeerRecord(
                    deviceId = macDeviceId,
                    protocolPublicKeyFingerprint = macFingerprint
                )
            )
        )
        prefs.edit()
            .putBoolean(TrustedPeerStore.KEY_CORRUPTED, true)
            .putString(TrustedPeerStore.KEY_CORRUPTION_DETAIL, "prior marker")
            .apply()
        prefs.enqueueCommitModes(CommitMode.RETURN_TRUE_WITHOUT_WRITE, CommitMode.APPLY_TRUE)

        val failure = expectPersistenceFailure { TrustedPeerStore(prefs).loadAll() }

        assertTrue(failure.rollbackConfirmed)
        assertTrue(prefs.getBoolean(TrustedPeerStore.KEY_CORRUPTED, false))
        assertEquals("prior marker", prefs.getString(TrustedPeerStore.KEY_CORRUPTION_DETAIL, null))
    }

    @Test
    fun verifiedUpsertReportsCommitFailureWithoutPublishingTrust() {
        val prefs = InMemorySharedPreferences(commitSucceeds = false)

        val error = expectPersistenceFailure {
            TrustedPeerStore(prefs).upsertVerifiedCurrentPathAuthority(
                deviceId = macDeviceId,
                protocolPublicKeyFingerprint = macFingerprint
            )
        }

        assertTrue(error.message?.contains("commit trusted-peer records") == true)
        assertTrue(error.rollbackConfirmed)
        assertFalse(prefs.contains(TrustedPeerStore.KEY_RECORDS_JSON))
    }

    @Test
    fun verifiedUpsertsFromDifferentStoreInstancesAreSerialized() {
        val firstReadEntered = CountDownLatch(1)
        val releaseFirstRead = CountDownLatch(1)
        val secondReadEntered = CountDownLatch(1)
        val recordReads = AtomicInteger(0)
        val failures = ConcurrentLinkedQueue<Throwable>()
        val prefs = InMemorySharedPreferences(
            recordsReadObserver = {
                when (recordReads.incrementAndGet()) {
                    1 -> {
                        firstReadEntered.countDown()
                        check(releaseFirstRead.await(5, TimeUnit.SECONDS)) {
                            "timed out waiting to release first trust-store read"
                        }
                    }
                    2 -> secondReadEntered.countDown()
                }
            }
        )

        val first = thread(name = "trust-upsert-1") {
            runCatching {
                TrustedPeerStore(prefs).upsertVerifiedCurrentPathAuthority(
                    deviceId = macDeviceId,
                    protocolPublicKeyFingerprint = macFingerprint
                )
            }.exceptionOrNull()?.let(failures::add)
        }
        assertTrue(firstReadEntered.await(5, TimeUnit.SECONDS))
        val second = thread(name = "trust-upsert-2") {
            runCatching {
                TrustedPeerStore(prefs).upsertVerifiedCurrentPathAuthority(
                    deviceId = "mac-second-device-0001",
                    protocolPublicKeyFingerprint = rotatedFingerprint
                )
            }.exceptionOrNull()?.let(failures::add)
        }

        assertFalse(
            "second store instance entered the load-modify-save transaction concurrently",
            secondReadEntered.await(200, TimeUnit.MILLISECONDS)
        )
        releaseFirstRead.countDown()
        first.join(5_000)
        second.join(5_000)

        assertFalse(first.isAlive)
        assertFalse(second.isAlive)
        assertTrue(failures.toString(), failures.isEmpty())
        assertEquals(2, TrustedPeerStore(prefs).loadAll().size)
    }

    private fun writeRecords(prefs: SharedPreferences, records: List<TrustedPeerRecord>) {
        prefs.edit()
            .putString(TrustedPeerStore.KEY_RECORDS_JSON, json.encodeToString(records))
            .apply()
    }

    private fun expectCorruption(block: () -> Unit) {
        try {
            block()
            fail("expected TrustedPeerStoreCorruptionException")
        } catch (_: TrustedPeerStoreCorruptionException) {
            // expected
        }
    }

    private fun expectPersistenceFailure(block: () -> Unit): TrustedPeerStorePersistenceException =
        try {
            block()
            fail("expected TrustedPeerStorePersistenceException")
            error("unreachable")
        } catch (e: TrustedPeerStorePersistenceException) {
            e
        }

    private fun expectPibPersistenceFailure(
        block: () -> Unit
    ): PibPairingClient.PairingError.TrustPersistence = try {
        block()
        fail("expected PIB trust persistence failure")
        error("unreachable")
    } catch (error: PibPairingClient.PairingError.TrustPersistence) {
        error
    }

    private fun String.sha256Key(): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    // --- Minimal in-memory SharedPreferences (only the methods TrustedPeerStore uses) -------------

    private enum class CommitMode {
        APPLY_TRUE,
        RETURN_TRUE_WITHOUT_WRITE,
        RETURN_TRUE_WITH_WRONG_RECORDS,
        THROW_AFTER_WRITE
    }

    private class InMemorySharedPreferences(
        private val commitSucceeds: Boolean = true,
        private val recordsReadObserver: (() -> Unit)? = null
    ) : SharedPreferences {
        private val map = HashMap<String, Any?>()
        private val mapLock = Any()
        private val commitModes = ArrayDeque<CommitMode>()

        fun enqueueCommitModes(vararg modes: CommitMode) = synchronized(mapLock) {
            commitModes.addAll(modes)
        }

        override fun getString(key: String?, defValue: String?): String? {
            if (key == TrustedPeerStore.KEY_RECORDS_JSON) recordsReadObserver?.invoke()
            return synchronized(mapLock) { (map[key] as? String) ?: defValue }
        }

        override fun edit(): SharedPreferences.Editor = Editor()

        override fun getAll(): MutableMap<String, *> = synchronized(mapLock) { map.toMutableMap() }
        override fun getStringSet(key: String?, defValues: MutableSet<String>?) = defValues
        override fun getInt(key: String?, defValue: Int) = synchronized(mapLock) { (map[key] as? Int) ?: defValue }
        override fun getLong(key: String?, defValue: Long) = synchronized(mapLock) { (map[key] as? Long) ?: defValue }
        override fun getFloat(key: String?, defValue: Float) = synchronized(mapLock) { (map[key] as? Float) ?: defValue }
        override fun getBoolean(key: String?, defValue: Boolean) = synchronized(mapLock) { (map[key] as? Boolean) ?: defValue }
        override fun contains(key: String?) = synchronized(mapLock) { map.containsKey(key) }
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}

        private inner class Editor : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removals = HashSet<String>()
            override fun putString(key: String?, value: String?): SharedPreferences.Editor {
                if (key != null) pending[key] = value
                return this
            }
            override fun putStringSet(key: String?, values: MutableSet<String>?) = this
            override fun putInt(key: String?, value: Int): SharedPreferences.Editor { if (key != null) pending[key] = value; return this }
            override fun putLong(key: String?, value: Long): SharedPreferences.Editor { if (key != null) pending[key] = value; return this }
            override fun putFloat(key: String?, value: Float): SharedPreferences.Editor { if (key != null) pending[key] = value; return this }
            override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor { if (key != null) pending[key] = value; return this }
            override fun remove(key: String?): SharedPreferences.Editor { if (key != null) removals.add(key); return this }
            override fun clear(): SharedPreferences.Editor {
                pending.clear()
                synchronized(mapLock) { removals.addAll(map.keys) }
                return this
            }
            override fun commit(): Boolean {
                val mode = synchronized(mapLock) { commitModes.pollFirst() }
                return when (mode) {
                    CommitMode.APPLY_TRUE -> {
                        applyPending()
                        true
                    }
                    CommitMode.RETURN_TRUE_WITHOUT_WRITE -> true
                    CommitMode.RETURN_TRUE_WITH_WRONG_RECORDS -> {
                        applyPending(recordsOverride = "[]")
                        true
                    }
                    CommitMode.THROW_AFTER_WRITE -> {
                        applyPending()
                        throw IllegalStateException("scripted commit failure after write")
                    }
                    null -> {
                        applyPending()
                        commitSucceeds
                    }
                }
            }
            override fun apply() {
                applyPending()
            }

            private fun applyPending(recordsOverride: String? = null) {
                synchronized(mapLock) {
                    removals.forEach { map.remove(it) }
                    map.putAll(pending)
                    if (recordsOverride != null && TrustedPeerStore.KEY_RECORDS_JSON in pending) {
                        map[TrustedPeerStore.KEY_RECORDS_JSON] = recordsOverride
                    }
                }
            }
        }
    }
}
