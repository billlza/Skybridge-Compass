package com.skybridge.compass.core.webrtc

import com.skybridge.compass.core.p2p.AuthenticatedPairingPersistenceOutcome
import com.skybridge.compass.core.p2p.AuthenticatedPairingPersistenceResult
import com.skybridge.compass.core.p2p.PeerKemKeyStore
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class AuthenticatedSessionPeerKemStoreTest {
    @Test
    fun exactOwnerAliasAndFingerprintReturnDeepCopiedSessionMaterial() {
        val owner = WebRtcSessionOwnerGate().begin(SESSION_ID).owner
        val inputXWing = X_WING_KEY.copyOf()
        val inputMlKem = ML_KEM_KEY.copyOf()
        val store = AuthenticatedSessionPeerKemStore()
        store.install(owner, sessionOnlyOutcome(inputXWing, inputMlKem))
        inputXWing.fill(0)
        inputMlKem.fill(0)

        val first = store.lookup(owner, " $ALIAS_ID ", PIN.uppercase())
            as AuthenticatedSessionPeerKemLookup.Match
        assertArrayEquals(X_WING_KEY, first.keys.xWingPublicKey)
        assertArrayEquals(ML_KEM_KEY, first.keys.mlKem768PublicKey)
        first.keys.xWingPublicKey?.fill(0)

        val second = store.lookup(owner, DEVICE_ID, PIN)
            as AuthenticatedSessionPeerKemLookup.Match
        assertArrayEquals(X_WING_KEY, second.keys.xWingPublicKey)
    }

    @Test
    fun wrongOwnerAliasOrFingerprintRejectsWithoutPersistentFallback() {
        val gate = WebRtcSessionOwnerGate()
        val owner = gate.begin(SESSION_ID).owner
        val store = AuthenticatedSessionPeerKemStore()
        store.install(owner, sessionOnlyOutcome())
        val sameIdReplacement = gate.begin(SESSION_ID).owner
        val rejectedLookups = listOf(
            store.lookup(sameIdReplacement, DEVICE_ID, PIN),
            store.lookup(owner, "id:different-peer", PIN),
            store.lookup(owner, DEVICE_ID, "cd".repeat(32))
        )
        var persistentLoads = 0

        rejectedLookups.forEach { lookup ->
            assertEquals(AuthenticatedSessionPeerKemLookup.RejectedBinding, lookup)
            assertThrows(AuthenticatedSessionPeerKemBindingException::class.java) {
                resolveAuthenticatedSessionPeerKemForRekey(lookup) {
                    persistentLoads += 1
                    persistentKeys()
                }
            }
        }

        assertEquals(0, persistentLoads)
    }

    @Test
    fun matchingSessionMaterialNeverLoadsPersistentKeysAndAbsentSlotLoadsExactlyOnce() {
        val owner = WebRtcSessionOwnerGate().begin(SESSION_ID).owner
        val store = AuthenticatedSessionPeerKemStore()
        store.install(owner, sessionOnlyOutcome())
        var persistentLoads = 0

        val resolvedSessionKeys = resolveAuthenticatedSessionPeerKemForRekey(
            lookup = store.lookup(owner, DEVICE_ID, PIN),
            persistentLoader = {
                persistentLoads += 1
                persistentKeys()
            }
        )
        assertEquals(0, persistentLoads)
        assertArrayEquals(X_WING_KEY, resolvedSessionKeys.xWingPublicKey)

        val absentStore = AuthenticatedSessionPeerKemStore()
        val resolvedPersistentKeys = resolveAuthenticatedSessionPeerKemForRekey(
            lookup = absentStore.lookup(owner, DEVICE_ID, PIN),
            persistentLoader = {
                persistentLoads += 1
                persistentKeys()
            }
        )
        assertEquals(1, persistentLoads)
        assertArrayEquals(PERSISTENT_X_WING_KEY, resolvedPersistentKeys.xWingPublicKey)
    }

    @Test
    fun sameOwnerInstallIsIdempotentButChangedBindingOrMaterialIsRejected() {
        val owner = WebRtcSessionOwnerGate().begin(SESSION_ID).owner
        val store = AuthenticatedSessionPeerKemStore()
        store.install(owner, sessionOnlyOutcome())
        store.install(owner, sessionOnlyOutcome())

        assertThrows(AuthenticatedSessionPeerKemBindingException::class.java) {
            store.install(
                owner,
                sessionOnlyOutcome(
                    xWing = X_WING_KEY.copyOf().also { key -> key[0] = 0x22 },
                    mlKem = ML_KEM_KEY
                )
            )
        }
        assertThrows(AuthenticatedSessionPeerKemBindingException::class.java) {
            store.install(
                owner,
                sessionOnlyOutcome(peerIds = setOf(DEVICE_ID))
            )
        }

        val retained = store.lookup(owner, ALIAS_ID, PIN)
            as AuthenticatedSessionPeerKemLookup.Match
        assertArrayEquals(X_WING_KEY, retained.keys.xWingPublicKey)
    }

    @Test
    fun onlyExactOwnerCanClearSessionMaterial() {
        val gate = WebRtcSessionOwnerGate()
        val owner = gate.begin(SESSION_ID).owner
        val store = AuthenticatedSessionPeerKemStore()
        store.install(owner, sessionOnlyOutcome())
        val unrelatedOwner = ProductSessionOwner.create(SESSION_ID, 1L)

        assertFalse(
            store.applyLifecycleEvent(
                unrelatedOwner,
                AuthenticatedSessionPeerKemLifecycleEvent.SESSION_FAILED
            )
        )
        assertTrue(store.lookup(owner, DEVICE_ID, PIN) is AuthenticatedSessionPeerKemLookup.Match)
        assertTrue(
            store.applyLifecycleEvent(
                owner,
                AuthenticatedSessionPeerKemLifecycleEvent.SESSION_DISCONNECTED
            )
        )
        assertEquals(
            AuthenticatedSessionPeerKemLookup.Absent,
            store.lookup(owner, DEVICE_ID, PIN)
        )
    }

    @Test
    fun everyTerminalAndRekeyOutcomeClearsExactOwnerSessionMaterial() {
        val terminalEvents = listOf(
            AuthenticatedSessionPeerKemLifecycleEvent.DURABLE_MATERIAL_COMMITTED,
            AuthenticatedSessionPeerKemLifecycleEvent.SESSION_DISCONNECTED,
            AuthenticatedSessionPeerKemLifecycleEvent.SESSION_FAILED,
            AuthenticatedSessionPeerKemLifecycleEvent.REKEY_SUCCEEDED,
            AuthenticatedSessionPeerKemLifecycleEvent.REKEY_FAILED
        )

        terminalEvents.forEach { event ->
            val owner = WebRtcSessionOwnerGate().begin("$SESSION_ID-$event").owner
            val store = AuthenticatedSessionPeerKemStore()
            store.install(owner, sessionOnlyOutcome())

            assertTrue("event=$event", store.applyLifecycleEvent(owner, event))
            assertEquals(
                "event=$event",
                AuthenticatedSessionPeerKemLookup.Absent,
                store.lookup(owner, DEVICE_ID, PIN)
            )
        }
    }

    @Test
    fun ownerReplacementCannotInterleaveWithInstallAndClearsOldSlotBeforePublication() {
        val gate = WebRtcSessionOwnerGate()
        val owner = gate.begin(SESSION_ID).owner
        val store = AuthenticatedSessionPeerKemStore()
        val installEntered = CountDownLatch(1)
        val releaseInstall = CountDownLatch(1)
        val replacementCompleted = CountDownLatch(1)
        val replacementOwner = AtomicReference<ProductSessionOwner>()

        val installThread = thread(start = true, name = "session-kem-install") {
            check(
                gate.runIfCurrent(owner) {
                    store.install(owner, sessionOnlyOutcome())
                    installEntered.countDown()
                    check(releaseInstall.await(5, TimeUnit.SECONDS))
                }
            )
        }
        assertTrue(installEntered.await(5, TimeUnit.SECONDS))
        val replacementThread = thread(start = true, name = "session-kem-replacement") {
            val replacement = gate.begin(SESSION_ID).owner
            check(
                gate.runIfCurrent(replacement) {
                    store.applyLifecycleEvent(
                        replacement,
                        AuthenticatedSessionPeerKemLifecycleEvent.OWNER_STARTED
                    )
                }
            )
            replacementOwner.set(replacement)
            replacementCompleted.countDown()
        }

        assertFalse(replacementCompleted.await(200, TimeUnit.MILLISECONDS))
        releaseInstall.countDown()
        installThread.join(5_000)
        replacementThread.join(5_000)

        assertTrue(replacementCompleted.await(1, TimeUnit.SECONDS))
        val replacement = checkNotNull(replacementOwner.get())
        assertEquals(
            AuthenticatedSessionPeerKemLookup.Absent,
            store.lookup(replacement, DEVICE_ID, PIN)
        )
    }

    private fun sessionOnlyOutcome(
        xWing: ByteArray = X_WING_KEY,
        mlKem: ByteArray = ML_KEM_KEY,
        peerIds: Set<String> = setOf(DEVICE_ID, ALIAS_ID)
    ): AuthenticatedPairingPersistenceOutcome = AuthenticatedPairingPersistenceOutcome(
        disposition = AuthenticatedPairingPersistenceResult.SESSION_ONLY,
        validatedKemPublicKeys = PeerKemKeyStore.PeerKemPublicKeys(
            xWingPublicKey = xWing,
            mlKem768PublicKey = mlKem
        ),
        normalizedPeerIds = peerIds,
        observedProtocolFingerprint = PIN
    )

    private fun persistentKeys(): PeerKemKeyStore.PeerKemPublicKeys =
        PeerKemKeyStore.PeerKemPublicKeys(xWingPublicKey = PERSISTENT_X_WING_KEY.copyOf())

    private companion object {
        const val SESSION_ID = "session-1"
        const val DEVICE_ID = "id:mac-1"
        const val ALIAS_ID = "bonjour:mac@local."
        val PIN = "ab".repeat(32)
        val X_WING_KEY = ByteArray(1_216) { 0x55 }
        val ML_KEM_KEY = ByteArray(1_184) { 0x66 }
        val PERSISTENT_X_WING_KEY = ByteArray(1_216) { 0x33 }
    }
}
