package com.skybridge.compass.core.p2p

import android.content.SharedPreferences
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.Base64
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class PeerKemKeyStoreSignedRefreshTest {
    @Test
    fun firstTrustAlwaysDurablyCommitsObservedAuthorityBeforeKemForEveryAlias() {
        val trustedPrefs = ScriptedSharedPreferences()
        val trustedStore = TrustedPeerStore(trustedPrefs)
        val peerPrefs = ScriptedSharedPreferences()
        val peerStore = peerStore(peerPrefs, trustedStore)

        val result = AuthenticatedPairingPersistence(trustedStore, peerStore).persistApprovedAttempt(
            decision = PairingTrustDecision.TRUST_ALWAYS,
            declaredDeviceId = DEVICE_ID,
            aliasIds = listOf(DEVICE_ID, ALIAS_ID),
            observedProtocolFingerprint = PIN,
            deviceName = "Mac",
            protocolSigningAlgorithm = "Ed25519",
            kemPublicKeys = productKemKeys(),
            platform = "macOS",
            osVersion = "26.0"
        )

        assertEquals(AuthenticatedPairingPersistenceResult.TRUST_AND_KEM_DURABLE, result)
        val authority = trustedStore.findExactVerifiedAuthorityReadOnly(
            listOf(DEVICE_ID, ALIAS_ID),
            PIN
        )
        assertNotNull(authority)
        assertEquals(TrustedPeerLifecycleState.ACTIVE, authority?.lifecycleState)
        assertEquals(TrustedPeerVerificationOrigin.AUTHENTICATED_PRODUCT_V1, authority?.verificationOrigin)
        assertArrayEquals(X_WING_KEY, peerStore.loadVerifiedReadOnly(ALIAS_ID).xWingPublicKey)
    }

    @Test
    fun allowOnceWithoutPredatingExactAuthorityLeavesBothStoresUnchanged() {
        val trustedPrefs = ScriptedSharedPreferences()
        val trustedStore = TrustedPeerStore(trustedPrefs)
        val peerPrefs = ScriptedSharedPreferences()
        val peerStore = peerStore(peerPrefs, trustedStore)

        val result = AuthenticatedPairingPersistence(trustedStore, peerStore).persistApprovedAttempt(
            decision = PairingTrustDecision.ALLOW_ONCE,
            declaredDeviceId = DEVICE_ID,
            aliasIds = listOf(DEVICE_ID, ALIAS_ID),
            observedProtocolFingerprint = PIN,
            deviceName = "Mac",
            protocolSigningAlgorithm = "Ed25519",
            kemPublicKeys = productKemKeys(),
            platform = "macOS",
            osVersion = "26.0"
        )

        assertEquals(AuthenticatedPairingPersistenceResult.SESSION_ONLY, result)
        assertTrue(trustedStore.loadAll().isEmpty())
        assertTrue(peerPrefs.all.isEmpty())
    }

    @Test
    fun allowOnceWithPredatingExactAuthorityDurablyPersistsKemWithoutRewritingTrust() {
        val trustedPrefs = ScriptedSharedPreferences()
        val trustedStore = TrustedPeerStore(trustedPrefs)
        trustedStore.upsertVerifiedCurrentPathAuthority(
            deviceId = DEVICE_ID,
            protocolPublicKeyFingerprint = PIN,
            protocolSigningAlgorithm = "Ed25519",
            aliasIds = listOf(ALIAS_ID)
        )
        val trustedSnapshot = trustedPrefs.all.toMap()
        val peerPrefs = ScriptedSharedPreferences()
        val peerStore = peerStore(peerPrefs, trustedStore)

        val outcome = AuthenticatedPairingPersistence(
            trustedPeerStore = trustedStore,
            peerKemStore = peerStore
        ).persistApprovedAttemptWithOutcome(
            decision = PairingTrustDecision.ALLOW_ONCE,
            declaredDeviceId = DEVICE_ID,
            aliasIds = listOf(DEVICE_ID, ALIAS_ID),
            observedProtocolFingerprint = PIN,
            deviceName = "Mac",
            protocolSigningAlgorithm = "Ed25519",
            kemPublicKeys = productKemKeys(),
            platform = "macOS",
            osVersion = "26.0"
        )

        assertEquals(
            AuthenticatedPairingPersistenceResult.KEM_DURABLE_UNDER_EXISTING_TRUST,
            outcome.disposition
        )
        assertEquals(trustedSnapshot, trustedPrefs.all)
        assertArrayEquals(X_WING_KEY, peerStore.loadVerifiedReadOnly(DEVICE_ID).xWingPublicKey)
        assertArrayEquals(X_WING_KEY, peerStore.loadVerifiedReadOnly(ALIAS_ID).xWingPublicKey)
    }

    @Test
    fun sessionOnlyOutcomeNormalizesBindingAndDeepCopiesValidatedKemWithoutWrites() {
        val trustedPrefs = ScriptedSharedPreferences()
        val trustedStore = TrustedPeerStore(trustedPrefs)
        val peerPrefs = ScriptedSharedPreferences()
        val peerStore = peerStore(peerPrefs, trustedStore)
        val inputXWing = X_WING_KEY.copyOf()
        val inputMlKem = ML_KEM_KEY.copyOf()

        val outcome = AuthenticatedPairingPersistence(
            trustedPeerStore = trustedStore,
            peerKemStore = peerStore
        ).persistApprovedAttemptWithOutcome(
            decision = PairingTrustDecision.ALLOW_ONCE,
            declaredDeviceId = "  $DEVICE_ID  ",
            aliasIds = listOf(" $ALIAS_ID "),
            observedProtocolFingerprint = PIN.uppercase(),
            deviceName = "Mac",
            protocolSigningAlgorithm = "Ed25519",
            kemPublicKeys = listOf(
                AppMessage.KemPublicKeyInfo(
                    P2PCryptoSuite.X_WING.wireId.toInt(),
                    inputXWing
                ),
                AppMessage.KemPublicKeyInfo(
                    P2PCryptoSuite.MLKEM_768.wireId.toInt(),
                    inputMlKem
                )
            ),
            platform = "macOS",
            osVersion = "26.0"
        )
        inputXWing.fill(0)
        inputMlKem.fill(0)

        assertEquals(AuthenticatedPairingPersistenceResult.SESSION_ONLY, outcome.disposition)
        assertEquals(setOf(DEVICE_ID, ALIAS_ID), outcome.normalizedPeerIds)
        assertEquals(PIN, outcome.observedProtocolFingerprint)
        assertArrayEquals(X_WING_KEY, outcome.validatedKemPublicKeys.xWingPublicKey)
        assertArrayEquals(ML_KEM_KEY, outcome.validatedKemPublicKeys.mlKem768PublicKey)
        assertTrue(trustedPrefs.all.isEmpty())
        assertTrue(peerPrefs.all.isEmpty())
    }

    @Test
    fun kemFailureAfterTrustAlwaysReportsPartialStateAndRetainsApprovedTrust() {
        val trustedStore = TrustedPeerStore(ScriptedSharedPreferences())
        val peerPrefs = ScriptedSharedPreferences().also {
            it.enqueueCommitModes(CommitMode.RETURN_FALSE, CommitMode.APPLY)
        }
        val peerStore = peerStore(peerPrefs, trustedStore)

        val failure = assertThrows(AuthenticatedPairingPartialPersistenceException::class.java) {
            AuthenticatedPairingPersistence(trustedStore, peerStore).persistApprovedAttempt(
                decision = PairingTrustDecision.TRUST_ALWAYS,
                declaredDeviceId = DEVICE_ID,
                aliasIds = listOf(DEVICE_ID, ALIAS_ID),
                observedProtocolFingerprint = PIN,
                deviceName = "Mac",
                protocolSigningAlgorithm = "Ed25519",
                kemPublicKeys = productKemKeys(),
                platform = "macOS",
                osVersion = "26.0"
            )
        }

        assertTrue(failure.message.orEmpty().contains("trust is durable"))
        assertNotNull(trustedStore.findExactVerifiedAuthorityReadOnly(listOf(DEVICE_ID, ALIAS_ID), PIN))
        assertFalse(peerPrefs.contains("trust_origin_${DEVICE_ID.sha256Key()}"))
    }

    @Test
    fun explicitTrustAlwaysAuthorizesSameFingerprintAliasMigrationWithoutCrossOwnerMerge() {
        val trustedStore = TrustedPeerStore(ScriptedSharedPreferences())
        trustedStore.upsertVerifiedCurrentPathAuthority(
            deviceId = DEVICE_ID,
            protocolPublicKeyFingerprint = PIN,
            protocolSigningAlgorithm = "Ed25519"
        )
        val peerPrefs = ScriptedSharedPreferences()
        val peerStore = peerStore(peerPrefs, trustedStore)

        val result = AuthenticatedPairingPersistence(trustedStore, peerStore).persistApprovedAttempt(
            decision = PairingTrustDecision.TRUST_ALWAYS,
            declaredDeviceId = ALIAS_ID,
            aliasIds = listOf(DEVICE_ID, ALIAS_ID),
            observedProtocolFingerprint = PIN,
            deviceName = "Renamed Mac",
            protocolSigningAlgorithm = "Ed25519",
            kemPublicKeys = productKemKeys(),
            platform = "macOS",
            osVersion = "26.0"
        )

        assertEquals(AuthenticatedPairingPersistenceResult.TRUST_AND_KEM_DURABLE, result)
        assertNotNull(trustedStore.findExactVerifiedAuthorityReadOnly(listOf(DEVICE_ID, ALIAS_ID), PIN))
        assertArrayEquals(ML_KEM_KEY, peerStore.loadVerifiedReadOnly(DEVICE_ID).mlKem768PublicKey)
        assertArrayEquals(ML_KEM_KEY, peerStore.loadVerifiedReadOnly(ALIAS_ID).mlKem768PublicKey)
    }

    @Test
    fun emptyKemExchangeIsRejectedBeforeTrustAlwaysCanWriteAuthority() {
        val trustedStore = TrustedPeerStore(ScriptedSharedPreferences())
        val peerStore = peerStore(ScriptedSharedPreferences(), trustedStore)

        assertThrows(PeerKemKeyStorePersistenceException::class.java) {
            AuthenticatedPairingPersistence(trustedStore, peerStore).persistApprovedAttempt(
                decision = PairingTrustDecision.TRUST_ALWAYS,
                declaredDeviceId = DEVICE_ID,
                aliasIds = listOf(DEVICE_ID),
                observedProtocolFingerprint = PIN,
                deviceName = null,
                protocolSigningAlgorithm = null,
                kemPublicKeys = emptyList(),
                platform = "macOS",
                osVersion = "26.0"
            )
        }

        assertNull(trustedStore.findVerifiedRecordByKnownDeviceIdReadOnly(DEVICE_ID))
    }

    @Test
    fun attemptReplacementAndPersistenceAreLinearizedByOneGate() {
        val gate = AuthenticatedPairingAttemptGate()
        val attempt = checkNotNull(
            gate.establishIfActive(
                observedProtocolFingerprint = PIN,
                isActive = { true }
            )
        )
        val persistenceEntered = CountDownLatch(1)
        val releasePersistence = CountDownLatch(1)
        val clearCompleted = CountDownLatch(1)
        var persistenceResult: String? = null

        val persistenceThread = thread(start = true) {
            persistenceResult = gate.runIfCurrent(attempt) {
                persistenceEntered.countDown()
                check(releasePersistence.await(5, TimeUnit.SECONDS))
                "durable"
            }
        }
        assertTrue(persistenceEntered.await(5, TimeUnit.SECONDS))
        val replacementThread = thread(start = true) {
            gate.clear()
            clearCompleted.countDown()
        }

        assertFalse(
            "replacement must not complete in the middle of the exact persistence section",
            clearCompleted.await(200, TimeUnit.MILLISECONDS)
        )
        releasePersistence.countDown()
        persistenceThread.join(5_000)
        replacementThread.join(5_000)

        assertEquals("durable", persistenceResult)
        assertTrue(clearCompleted.await(1, TimeUnit.SECONDS))
        assertNull(gate.runIfCurrent(attempt) { "stale write" })
    }

    @Test
    fun durableSignedRefreshRoundTripsAndSameLengthKeyTamperingIsCorruption() {
        val fixture = fixture()
        fixture.store.saveSignedLanRefresh(listOf(DEVICE_ID), refresh())

        val loaded = fixture.store.loadVerifiedReadOnly(DEVICE_ID)
        assertArrayEquals(X_WING_KEY, loaded.xWingPublicKey)
        assertArrayEquals(ML_KEM_KEY, loaded.mlKem768PublicKey)

        val tampered = X_WING_KEY.copyOf().also { it[100] = (it[100].toInt() xor 1).toByte() }
        fixture.peerPrefs.edit()
            .putString("xwing_${DEVICE_ID.sha256Key()}", Base64.getEncoder().encodeToString(tampered))
            .commit()
        assertThrows(PeerKemKeyStoreCorruptionException::class.java) {
            fixture.store.loadVerifiedReadOnly(DEVICE_ID)
        }
    }

    @Test
    fun mlKemOnlySignedRefreshRoundTripsAndRemovesStaleXWingMaterial() {
        val fixture = fixture()
        fixture.store.saveSignedLanRefresh(listOf(DEVICE_ID), refresh(generation = 7))

        val mlKemOnly = listOf(
            AppMessage.KemPublicKeyInfo(P2PCryptoSuite.MLKEM_768.wireId.toInt(), ML_KEM_KEY)
        )
        fixture.store.saveSignedLanRefresh(
            listOf(DEVICE_ID),
            refresh(generation = 8, keys = mlKemOnly)
        )

        val loaded = fixture.store.loadVerifiedReadOnly(DEVICE_ID)
        assertNull(loaded.xWingPublicKey)
        assertArrayEquals(ML_KEM_KEY, loaded.mlKem768PublicKey)
        assertEquals(
            P2PCryptoSuite.MLKEM_768.wireId.toInt().toString(),
            fixture.peerPrefs.getString("skr_suite_wire_ids_${DEVICE_ID.sha256Key()}", null)
        )
    }

    @Test
    fun signedRefreshSuiteMetadataMustBeCanonicalNonEmptyAllowlistedSubset() {
        val invalidSuiteLists = listOf(
            emptyList(),
            listOf(0x0001, 0x0001),
            listOf(0x0101, 0x0001),
            listOf(0x7777)
        )
        invalidSuiteLists.forEach { suiteWireIds ->
            val fixture = fixture()
            val failure = assertThrows(PeerKemKeyStorePersistenceException::class.java) {
                fixture.store.saveSignedLanRefresh(
                    listOf(DEVICE_ID),
                    refresh().copy(signedSuiteWireIds = suiteWireIds)
                )
            }
            assertTrue(failure.message.orEmpty().contains("metadata is inconsistent"))
        }
    }

    @Test
    fun durableSignedRefreshRejectsNonCanonicalOrUnknownSuiteMetadata() {
        listOf("", "1,1", "257,1", "30583").forEach { persistedSuiteList ->
            val fixture = fixture()
            fixture.store.saveSignedLanRefresh(listOf(DEVICE_ID), refresh())
            fixture.peerPrefs.edit()
                .putString("skr_suite_wire_ids_${DEVICE_ID.sha256Key()}", persistedSuiteList)
                .commit()

            assertThrows(PeerKemKeyStoreCorruptionException::class.java) {
                fixture.store.loadVerifiedReadOnly(DEVICE_ID)
            }
        }
    }

    @Test
    fun signedRefreshSubsetMustExactlyMatchPersistedKeyMaterial() {
        val fixture = fixture()
        val mlKemOnly = listOf(
            AppMessage.KemPublicKeyInfo(P2PCryptoSuite.MLKEM_768.wireId.toInt(), ML_KEM_KEY)
        )

        val failure = assertThrows(PeerKemKeyStorePersistenceException::class.java) {
            fixture.store.saveSignedLanRefresh(
                listOf(DEVICE_ID),
                refresh(keys = mlKemOnly).copy(signedSuiteWireIds = listOf(0x0001))
            )
        }

        assertTrue(failure.message.orEmpty().contains("key material does not match suite metadata"))
    }

    @Test
    fun expiredRefreshRequiresNewMaterialButRetainsGenerationFloor() {
        val fixture = fixture(nowMillis = NOW)
        fixture.store.saveSignedLanRefresh(listOf(DEVICE_ID), refresh(generation = 7, expiresAt = NOW + 1))
        fixture.nowMillis = NOW + 1

        val stale = fixture.store.loadVerifiedReadOnly(DEVICE_ID)
        assertTrue(stale.xWingPublicKey == null && stale.mlKem768PublicKey == null)
        assertEquals(7L, fixture.store.maximumSignedRefreshGeneration(listOf(DEVICE_ID)))

        fixture.store.saveSignedLanRefresh(
            listOf(DEVICE_ID),
            refresh(
                generation = 7,
                expiresAt = NOW + 60_000,
                payloadHash = "c".repeat(64)
            )
        )
        assertArrayEquals(X_WING_KEY, fixture.store.loadVerifiedReadOnly(DEVICE_ID).xWingPublicKey)

        val failure = assertThrows(PeerKemKeyStorePersistenceException::class.java) {
            fixture.store.saveSignedLanRefresh(
                listOf(DEVICE_ID),
                refresh(generation = 6, expiresAt = NOW + 60_000)
            )
        }
        assertTrue(failure.message.orEmpty().contains("generation rollback"))
    }

    @Test
    fun commitFalseRestoresSnapshotAndReportsConfirmedRollback() {
        val fixture = fixture()
        fixture.peerPrefs.enqueueCommitModes(CommitMode.RETURN_FALSE, CommitMode.APPLY)

        val failure = assertThrows(PeerKemKeyStorePersistenceException::class.java) {
            fixture.store.saveSignedLanRefresh(listOf(DEVICE_ID), refresh())
        }

        assertTrue(failure.rollbackConfirmed)
        assertFalse(fixture.peerPrefs.contains("trust_origin_${DEVICE_ID.sha256Key()}"))
    }

    @Test
    fun commitTrueWithoutWriteIsDetectedByImmediateRereadAndRolledBack() {
        val fixture = fixture()
        fixture.peerPrefs.enqueueCommitModes(CommitMode.RETURN_TRUE_WITHOUT_WRITE, CommitMode.APPLY)

        val failure = assertThrows(PeerKemKeyStorePersistenceException::class.java) {
            fixture.store.saveSignedLanRefresh(listOf(DEVICE_ID), refresh())
        }

        assertTrue(failure.rollbackConfirmed)
        assertTrue(failure.message.orEmpty().contains("durable re-read mismatch"))
        assertFalse(fixture.peerPrefs.contains("trust_origin_${DEVICE_ID.sha256Key()}"))
    }

    @Test
    fun rollbackFailureIsExplicitAndNeverReportedAsDurableSuccess() {
        val fixture = fixture()
        fixture.peerPrefs.enqueueCommitModes(CommitMode.RETURN_FALSE, CommitMode.RETURN_FALSE)

        val failure = assertThrows(PeerKemKeyStorePersistenceException::class.java) {
            fixture.store.saveSignedLanRefresh(listOf(DEVICE_ID), refresh())
        }

        assertFalse(failure.rollbackConfirmed)
        assertTrue(failure.message.orEmpty().contains("confirm snapshot rollback"))
    }

    @Test
    fun formalReadRejectsInvalidBase64AndFingerprintMetadataMismatch() {
        val fixture = fixture()
        fixture.store.saveSignedLanRefresh(listOf(DEVICE_ID), refresh())
        val hash = DEVICE_ID.sha256Key()

        fixture.peerPrefs.edit().putString("xwing_$hash", "${Base64.getEncoder().encodeToString(X_WING_KEY)}!").commit()
        assertThrows(PeerKemKeyStoreCorruptionException::class.java) {
            fixture.store.loadVerifiedReadOnly(DEVICE_ID)
        }

        fixture.store.saveSignedLanRefresh(listOf(DEVICE_ID), refresh(generation = 8))
        fixture.peerPrefs.edit().putString("skr_signing_fingerprint_$hash", "d".repeat(64)).commit()
        assertThrows(PeerKemKeyStoreCorruptionException::class.java) {
            fixture.store.loadVerifiedReadOnly(DEVICE_ID)
        }
    }

    @Test
    fun authenticatedSessionOriginRequiresObservedAuthorityMatchingActivePin() {
        val fixture = fixture()
        fixture.store.saveForAliases(
            peerIds = listOf(DEVICE_ID),
            kemPublicKeys = listOf(AppMessage.KemPublicKeyInfo(0x0101, ML_KEM_KEY)),
            platform = "macOS",
            osVersion = "26.0",
            verifiedProtocolFingerprint = PIN.uppercase()
        )
        assertArrayEquals(ML_KEM_KEY, fixture.store.loadVerifiedReadOnly(DEVICE_ID).mlKem768PublicKey)

        assertThrows(PeerKemKeyStorePersistenceException::class.java) {
            fixture.store.saveForAliases(
                peerIds = listOf(DEVICE_ID),
                kemPublicKeys = listOf(AppMessage.KemPublicKeyInfo(0x0101, ML_KEM_KEY)),
                platform = "macOS",
                osVersion = "26.0",
                verifiedProtocolFingerprint = "d".repeat(64)
            )
        }
    }

    @Test
    fun sessionAndSignedRefreshMutationsAreLinearizedWithoutMixedProvenance() {
        repeat(20) {
            val fixture = fixture()
            val start = CountDownLatch(1)
            val failures = ConcurrentLinkedQueue<Throwable>()
            val sessionThread = thread(start = true) {
                start.await()
                runCatching {
                    fixture.store.saveForAliases(
                        peerIds = listOf(DEVICE_ID),
                        kemPublicKeys = listOf(AppMessage.KemPublicKeyInfo(0x0101, ML_KEM_KEY)),
                        platform = "macOS",
                        osVersion = "26.0",
                        verifiedProtocolFingerprint = PIN
                    )
                }.exceptionOrNull()?.let(failures::add)
            }
            val signedThread = thread(start = true) {
                start.await()
                runCatching {
                    fixture.store.saveSignedLanRefresh(listOf(DEVICE_ID), refresh())
                }.exceptionOrNull()?.let(failures::add)
            }
            start.countDown()
            sessionThread.join()
            signedThread.join()

            assertTrue(failures.toString(), failures.isEmpty())
            val hash = DEVICE_ID.sha256Key()
            when (fixture.peerPrefs.getString("trust_origin_$hash", null)) {
                PeerKemTrustOriginPolicy.AUTHENTICATED_PRODUCT_V1 -> {
                    assertEquals(PIN, fixture.peerPrefs.getString("session_protocol_fingerprint_$hash", null))
                    assertFalse(fixture.peerPrefs.contains("skr_generation_$hash"))
                    assertTrue(fixture.store.loadVerifiedReadOnly(DEVICE_ID).mlKem768PublicKey != null)
                }
                PeerKemTrustOriginPolicy.SIGNED_LAN_KEM_REFRESH -> {
                    assertFalse(fixture.peerPrefs.contains("session_protocol_fingerprint_$hash"))
                    assertTrue(fixture.peerPrefs.contains("skr_kem_public_key_hash_$hash"))
                    assertTrue(fixture.store.loadVerifiedReadOnly(DEVICE_ID).xWingPublicKey != null)
                }
                else -> throw AssertionError("persistent mutation did not commit a typed origin")
            }
        }
    }

    private fun fixture(nowMillis: Long = NOW): Fixture {
        val trustedPrefs = ScriptedSharedPreferences()
        val trustedStore = TrustedPeerStore(trustedPrefs)
        trustedStore.upsertVerifiedCurrentPathAuthority(
            deviceId = DEVICE_ID,
            protocolPublicKeyFingerprint = PIN,
            protocolSigningAlgorithm = "Ed25519"
        )
        val peerPrefs = ScriptedSharedPreferences()
        return Fixture(peerPrefs, trustedStore, nowMillis)
    }

    private fun peerStore(
        peerPrefs: SharedPreferences,
        trustedStore: TrustedPeerStore
    ): PeerKemKeyStore = PeerKemKeyStore(
        prefsProvider = { peerPrefs },
        trustedPeerStoreProvider = { trustedStore },
        currentTimeMillis = { NOW }
    )

    private fun productKemKeys(): List<AppMessage.KemPublicKeyInfo> = listOf(
        AppMessage.KemPublicKeyInfo(P2PCryptoSuite.X_WING.wireId.toInt(), X_WING_KEY),
        AppMessage.KemPublicKeyInfo(P2PCryptoSuite.MLKEM_768.wireId.toInt(), ML_KEM_KEY)
    )

    private fun refresh(
        generation: Long = 7,
        expiresAt: Long = NOW + 300_000,
        payloadHash: String = "b".repeat(64),
        keys: List<AppMessage.KemPublicKeyInfo> = listOf(
            AppMessage.KemPublicKeyInfo(P2PCryptoSuite.X_WING.wireId.toInt(), X_WING_KEY),
            AppMessage.KemPublicKeyInfo(P2PCryptoSuite.MLKEM_768.wireId.toInt(), ML_KEM_KEY)
        )
    ): VerifiedSignedLanKemRefresh {
        return VerifiedSignedLanKemRefresh(
            responseDeviceId = DEVICE_ID,
            aliases = emptyList(),
            protocolIdentityFingerprint = PIN,
            kemPublicKeys = keys,
            keyId = "skr-key-1",
            generation = generation,
            sentAtMillis = NOW,
            expiresAtMillis = expiresAt,
            payloadHashHex = payloadHash,
            kemPublicKeyHashHex = SkrCanonical.kemPublicKeyHashHex(
                keys.map { SkrBootstrapWire.KemPublicKeyInfo(it.suiteWireId, it.publicKey) }
            ),
            signedSuiteWireIds = keys.map(AppMessage.KemPublicKeyInfo::suiteWireId).sorted()
        )
    }

    private class Fixture(
        val peerPrefs: ScriptedSharedPreferences,
        trustedStore: TrustedPeerStore,
        initialNowMillis: Long
    ) {
        var nowMillis: Long = initialNowMillis
        val store = PeerKemKeyStore(
            prefsProvider = { peerPrefs },
            trustedPeerStoreProvider = { trustedStore },
            currentTimeMillis = { nowMillis }
        )
    }

    private fun String.sha256Key(): String = MessageDigest.getInstance("SHA-256")
        .digest(toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private companion object {
        const val DEVICE_ID = "id:mac-1"
        const val ALIAS_ID = "bonjour:mac@local."
        const val NOW = 1_700_000_000_000L
        val PIN = "ab".repeat(32)
        val X_WING_KEY = ByteArray(1_216) { 0x55 }
        val ML_KEM_KEY = ByteArray(1_184) { 0x66 }
    }
}

internal enum class CommitMode {
    APPLY,
    RETURN_FALSE,
    RETURN_TRUE_WITHOUT_WRITE
}

internal class ScriptedSharedPreferences : SharedPreferences {
    private val values = linkedMapOf<String, Any?>()
    private val commitModes = ArrayDeque<CommitMode>()
    var commitCount: Int = 0
        private set

    @Synchronized
    fun enqueueCommitModes(vararg modes: CommitMode) {
        commitModes.addAll(modes)
    }

    @Synchronized
    override fun getAll(): MutableMap<String, *> = LinkedHashMap(values)

    override fun getString(key: String?, defValue: String?): String? {
        val raw = rawValue(key) ?: return defValue
        if (raw !is String) throw ClassCastException("preference is not a string")
        return raw
    }
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? {
        val raw = rawValue(key) ?: return defValues
        if (raw !is Set<*> || raw.any { it !is String }) {
            throw ClassCastException("preference is not a string set")
        }
        return raw.filterIsInstance<String>().toMutableSet()
    }
    override fun getInt(key: String?, defValue: Int): Int =
        typed(key, defValue, Int::class.javaObjectType)
    override fun getLong(key: String?, defValue: Long): Long =
        typed(key, defValue, Long::class.javaObjectType)
    override fun getFloat(key: String?, defValue: Float): Float =
        typed(key, defValue, Float::class.javaObjectType)
    override fun getBoolean(key: String?, defValue: Boolean): Boolean =
        typed(key, defValue, Boolean::class.javaObjectType)

    @Synchronized
    private fun rawValue(key: String?): Any? = key?.let(values::get)

    private fun <T> typed(key: String?, defaultValue: T, type: Class<T>): T =
        rawValue(key)?.let(type::cast) ?: defaultValue

    @Synchronized
    override fun contains(key: String?): Boolean = key != null && key in values

    override fun edit(): SharedPreferences.Editor = Editor()
    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?
    ) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?
    ) = Unit

    private inner class Editor : SharedPreferences.Editor {
        private val pending = linkedMapOf<String, Any?>()
        private val removals = linkedSetOf<String>()
        private var clearRequested = false

        override fun putString(key: String?, value: String?): SharedPreferences.Editor = put(key, value)
        override fun putStringSet(key: String?, values: MutableSet<String>?): SharedPreferences.Editor =
            put(key, values?.toSet())
        override fun putInt(key: String?, value: Int): SharedPreferences.Editor = put(key, value)
        override fun putLong(key: String?, value: Long): SharedPreferences.Editor = put(key, value)
        override fun putFloat(key: String?, value: Float): SharedPreferences.Editor = put(key, value)
        override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor = put(key, value)

        private fun put(key: String?, value: Any?): SharedPreferences.Editor {
            if (key != null) {
                pending[key] = value
                removals.remove(key)
            }
            return this
        }

        override fun remove(key: String?): SharedPreferences.Editor {
            if (key != null) {
                removals.add(key)
                pending.remove(key)
            }
            return this
        }

        override fun clear(): SharedPreferences.Editor {
            clearRequested = true
            pending.clear()
            removals.clear()
            return this
        }

        override fun commit(): Boolean = synchronized(this@ScriptedSharedPreferences) {
            commitCount += 1
            when (commitModes.pollFirst() ?: CommitMode.APPLY) {
                CommitMode.RETURN_FALSE -> false
                CommitMode.RETURN_TRUE_WITHOUT_WRITE -> true
                CommitMode.APPLY -> {
                    if (clearRequested) values.clear()
                    removals.forEach(values::remove)
                    pending.forEach { (key, value) ->
                        if (value == null) values.remove(key) else values[key] = value
                    }
                    true
                }
            }
        }

        override fun apply() {
            commit()
        }
    }
}
