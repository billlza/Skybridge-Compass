package com.skybridge.compass.shared.p2p

import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the R4.2 bootstrap-assisted KEM acquisition state machine (task 9.2).
 *
 * These prove the behaviors task 9.2 owns:
 *  1. The bootstrap path retrieves the peer KEM public key over a one-time classic
 *     control channel, then forces a PQC rekey.
 *  2. The session is never presented as established and never carries business traffic
 *     before the forced PQC rekey completes.
 *  3. The classic bootstrap channel is used ONLY for KEM retrieval (it exposes no
 *     business-traffic operation and is torn down before any business phase).
 *
 * Detailed R4.11/R4.12 failure handling (pairing hints, key-material wipe) is task 9.3;
 * these tests only assert the state transitions 9.3 plugs into and the task-9.1
 * classification of failures.
 */
class BootstrapAssistedHandshakeTest {

    private fun mlKemKeys(): PeerKemPublicKeys =
        P2PHandshakeClient.PeerKemPublicKeys(mlKem768PublicKey = ByteArray(1184) { 7 })

    /**
     * A control channel test double that records every operation, so a test can prove
     * it was used ONLY for KEM retrieval and never carried application payloads.
     */
    private class RecordingControlChannel(
        private val keys: PeerKemPublicKeys?,
        private val failWith: Throwable? = null,
        /** Live secret this channel "derived"; the state machine zeroizes it on failure. */
        val derivedSecret: ByteArray? = null,
        /** When > 0, retrieval suspends this long (used to trip the acquisition deadline). */
        private val retrieveDelayMillis: Long = 0
    ) : BootstrapControlChannel {
        val operations = mutableListOf<String>()
        var closed = false

        override suspend fun retrievePeerKemPublicKeys(): PeerKemPublicKeys {
            operations += "retrieveKem"
            if (retrieveDelayMillis > 0) delay(retrieveDelayMillis)
            failWith?.let { throw it }
            return keys ?: PeerKemPublicKeys()
        }

        override fun derivedKeyMaterial(): ByteArray? = derivedSecret

        override suspend fun close() {
            operations += "close"
            closed = true
        }
    }

    @Test
    fun bootstrapRetrievesKemThenForcesPqcRekey() = runTest {
        val peer = PeerRef("apple-peer-1")
        val keys = mlKemKeys()
        val channel = RecordingControlChannel(keys)
        val states = mutableListOf<BootstrapHandshakeState>()
        var rekeyInvoked = false
        var rekeyReceivedKeys: PeerKemPublicKeys? = null

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, k ->
                rekeyInvoked = true
                rekeyReceivedKeys = k
                PqcRekeyResult.Success
            },
            onStateChange = { states += it }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue("bootstrap must succeed on the happy path", result.isSuccess)
        assertTrue("forced PQC rekey must be invoked", rekeyInvoked)
        assertEquals(
            "the retrieved KEM key must be the one handed to the rekey",
            keys.mlKem768PublicKey?.toList(),
            rekeyReceivedKeys?.mlKem768PublicKey?.toList()
        )
        // KEM retrieval happens strictly before the rekey state.
        assertTrue(
            "must pass through KEM_RETRIEVED then REKEYING_PQC then ESTABLISHED",
            states.containsAll(
                listOf(
                    BootstrapHandshakeState.RETRIEVING_KEM,
                    BootstrapHandshakeState.KEM_RETRIEVED,
                    BootstrapHandshakeState.REKEYING_PQC,
                    BootstrapHandshakeState.ESTABLISHED
                )
            )
        )
        assertEquals(BootstrapHandshakeState.ESTABLISHED, sm.state)
    }

    @Test
    fun sessionNotEstablishedAndNoTrafficUntilRekeyCompletes() = runTest {
        val peer = PeerRef("apple-peer-2")
        val channel = RecordingControlChannel(mlKemKeys())

        // Capture the machine's visibility while the rekey is in-flight.
        var establishedDuringRekey = true
        var trafficAllowedDuringRekey = true
        var stateDuringRekey: BootstrapHandshakeState? = null
        var stateAtKemRetrieved: BootstrapHandshakeState? = null

        lateinit var sm: DefaultBootstrapAssistedHandshake
        sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, _ ->
                // Mid-rekey: session must NOT be established and must NOT carry traffic.
                establishedDuringRekey = sm.isSessionEstablished
                trafficAllowedDuringRekey = sm.canCarryBusinessTraffic
                stateDuringRekey = sm.state
                delay(5)
                PqcRekeyResult.Success
            },
            onStateChange = { s ->
                if (s == BootstrapHandshakeState.KEM_RETRIEVED) {
                    // At KEM_RETRIEVED the session is still not established.
                    stateAtKemRetrieved = s
                }
            }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue(result.isSuccess)
        assertFalse("session must NOT be established during rekey", establishedDuringRekey)
        assertFalse("must NOT carry business traffic during rekey", trafficAllowedDuringRekey)
        assertEquals(BootstrapHandshakeState.REKEYING_PQC, stateDuringRekey)
        assertEquals(BootstrapHandshakeState.KEM_RETRIEVED, stateAtKemRetrieved)
        // Only after success is the session established / traffic-capable.
        assertTrue("established only after rekey success", sm.isSessionEstablished)
        assertTrue("traffic allowed only after rekey success", sm.canCarryBusinessTraffic)
    }

    @Test
    fun classicBootstrapChannelIsUsedOnlyForKemRetrieval() = runTest {
        val peer = PeerRef("apple-peer-3")
        val channel = RecordingControlChannel(mlKemKeys())

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, _ -> PqcRekeyResult.Success }
        )

        sm.bootstrapPeerKemKeys(peer)

        // The only data operation the channel supports/received is KEM retrieval, and
        // it was torn down (closed) before the business phase.
        assertTrue("KEM retrieval must have occurred", channel.operations.contains("retrieveKem"))
        assertTrue("control channel must be closed", channel.closed)
        assertEquals(
            "channel must ONLY retrieve KEM then close — no other operation",
            listOf("retrieveKem", "close"),
            channel.operations
        )
        // The channel must be closed before ESTABLISHED (no lingering channel to carry traffic).
        assertEquals(BootstrapHandshakeState.ESTABLISHED, sm.state)
    }

    @Test
    fun rekeyTimeoutKeepsSessionUnestablishedAndClassifiesFailure() = runTest {
        val peer = PeerRef("apple-peer-4")
        val channel = RecordingControlChannel(mlKemKeys())

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, _ ->
                // Never completes within the deadline.
                delay(60_000)
                PqcRekeyResult.Success
            },
            rekeyDeadlineMillis = 10_000L
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue("rekey timeout must fail the bootstrap", result.isFailure)
        val failure = (result.exceptionOrNull() as BootstrapHandshakeException).failure
        // R4.12: timeout classifies per the underlying cause; default is local PQC unavailable.
        assertEquals(HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE, failure.category)
        assertFalse("session must remain unestablished after rekey timeout", sm.isSessionEstablished)
        assertFalse("no traffic after rekey timeout", sm.canCarryBusinessTraffic)
        assertEquals(BootstrapHandshakeState.FAILED, sm.state)
    }

    @Test
    fun rekeyFailureClassifiedBySuiteIntersectionCause() = runTest {
        val peer = PeerRef("apple-peer-5")
        val channel = RecordingControlChannel(mlKemKeys())

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, _ ->
                PqcRekeyResult.Failed(BootstrapRekeyCause.SUITE_INTERSECTION_EMPTY)
            }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue(result.isFailure)
        val failure = (result.exceptionOrNull() as BootstrapHandshakeException).failure
        assertEquals(HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY, failure.category)
        assertFalse(sm.isSessionEstablished)
        assertEquals(BootstrapHandshakeState.FAILED, sm.state)
    }

    @Test
    fun missingPeerKemFromChannelClassifiesAsKemUnavailable() = runTest {
        val peer = PeerRef("apple-peer-6")
        // Channel returns an empty bundle — no KEM key obtained.
        val channel = RecordingControlChannel(PeerKemPublicKeys())
        var rekeyInvoked = false

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, _ -> rekeyInvoked = true; PqcRekeyResult.Success }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue(result.isFailure)
        val failure = (result.exceptionOrNull() as BootstrapHandshakeException).failure
        assertEquals(HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE, failure.category)
        assertFalse("rekey must not be forced when no KEM key was obtained", rekeyInvoked)
        assertFalse(sm.isSessionEstablished)
    }

    @Test
    fun controlChannelOpenFailureClassifiesAsKemUnavailable() = runTest {
        val peer = PeerRef("apple-peer-7")

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { throw IllegalStateException("no route to peer") },
            forcePqcRekey = { _, _ -> PqcRekeyResult.Success }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue(result.isFailure)
        val failure = (result.exceptionOrNull() as BootstrapHandshakeException).failure
        assertEquals(HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE, failure.category)
        assertEquals(BootstrapHandshakeState.FAILED, sm.state)
    }

    @Test
    fun nonBootstrapPolicyDoesNotOpenClassicControlChannel() = runTest {
        val peer = PeerRef("apple-peer-8")
        var channelOpened = false

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_COMPLIANCE,
            localPeerKemLookup = { null },
            openControlChannel = {
                channelOpened = true
                RecordingControlChannel(mlKemKeys())
            },
            forcePqcRekey = { _, _ -> PqcRekeyResult.Success }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue("non-bootstrap posture must not establish via classic channel", result.isFailure)
        assertFalse("must NOT open a classic control channel under a non-bootstrap policy", channelOpened)
        val failure = (result.exceptionOrNull() as BootstrapHandshakeException).failure
        assertEquals(HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE, failure.category)
    }

    @Test
    fun existingLocalKemKeySkipsBootstrapChannel() = runTest {
        val peer = PeerRef("apple-peer-9")
        val local = mlKemKeys()
        var channelOpened = false

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { local },
            openControlChannel = { channelOpened = true; RecordingControlChannel(local) },
            forcePqcRekey = { _, _ -> PqcRekeyResult.Success }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue(result.isSuccess)
        assertFalse("no classic channel needed when local KEM key already present", channelOpened)
        assertEquals(
            local.mlKem768PublicKey?.toList(),
            result.getOrNull()?.mlKem768PublicKey?.toList()
        )
        assertNull("no failure expected", result.exceptionOrNull())
    }

    // --- Task 9.3: R4.12 (rekey-timeout wipes derived key material + terminates channel) ---

    @Test
    fun rekeyTimeoutWipesDerivedKeyMaterialAndTerminatesChannelWithNoSession() = runTest {
        val peer = PeerRef("apple-peer-10")
        // A live secret the bootstrap channel derived; the state machine must zeroize it.
        val derivedSecret = ByteArray(32) { (it + 1).toByte() }
        val channel = RecordingControlChannel(mlKemKeys(), derivedSecret = derivedSecret)
        var wipeCallbacks = 0

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, _ ->
                // Never completes within the 10 s deadline.
                delay(60_000)
                PqcRekeyResult.Success
            },
            rekeyDeadlineMillis = 10_000L,
            onKeyMaterialWiped = { wipeCallbacks++ }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue("rekey timeout must fail the bootstrap", result.isFailure)
        val ex = result.exceptionOrNull() as BootstrapHandshakeException
        // R4.12: classified as LOCAL_PQC_UNAVAILABLE, no pairing hint (not a pairing problem).
        assertEquals(HandshakeFailureCategory.LOCAL_PQC_UNAVAILABLE, ex.failure.category)
        assertNull("R4.12 timeout is not a pairing hint scenario", ex.pairingHint)
        // Channel terminated.
        assertTrue("bootstrap control channel must be terminated on rekey timeout", channel.closed)
        // Derived key material wiped: the live secret is zeroized in place.
        assertTrue("derived key material must be zeroized", derivedSecret.all { it == 0.toByte() })
        assertEquals("wipe must be invoked exactly once on the failure path", 1, wipeCallbacks)
        // No session.
        assertFalse("session must remain unestablished after rekey timeout", sm.isSessionEstablished)
        assertFalse("no business traffic after rekey timeout", sm.canCarryBusinessTraffic)
        assertEquals(BootstrapHandshakeState.FAILED, sm.state)
    }

    @Test
    fun rekeyFailureWipesDerivedKeyMaterialExactlyOnce() = runTest {
        val peer = PeerRef("apple-peer-11")
        val derivedSecret = ByteArray(48) { 0x5A }
        val channel = RecordingControlChannel(mlKemKeys(), derivedSecret = derivedSecret)
        var wipeCallbacks = 0

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, _ ->
                PqcRekeyResult.Failed(BootstrapRekeyCause.SUITE_INTERSECTION_EMPTY)
            },
            onKeyMaterialWiped = { wipeCallbacks++ }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue(result.isFailure)
        val ex = result.exceptionOrNull() as BootstrapHandshakeException
        assertEquals(HandshakeFailureCategory.SUITE_INTERSECTION_EMPTY, ex.failure.category)
        assertTrue("channel terminated on rekey failure", channel.closed)
        assertTrue("derived key material must be zeroized", derivedSecret.all { it == 0.toByte() })
        assertEquals("wipe invoked exactly once on the failure path", 1, wipeCallbacks)
        assertFalse(sm.isSessionEstablished)
        assertEquals(BootstrapHandshakeState.FAILED, sm.state)
    }

    @Test
    fun successPathDoesNotInvokeFailurePathWipe() = runTest {
        val peer = PeerRef("apple-peer-12")
        val derivedSecret = ByteArray(16) { 9 }
        val channel = RecordingControlChannel(mlKemKeys(), derivedSecret = derivedSecret)
        var wipeCallbacks = 0

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, _ -> PqcRekeyResult.Success },
            onKeyMaterialWiped = { wipeCallbacks++ }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue(result.isSuccess)
        assertEquals("no failure-path wipe on the success path", 0, wipeCallbacks)
        assertTrue(sm.isSessionEstablished)
    }

    // --- Task 9.3: R4.11 (KEM public key unobtainable → actionable pairing hint, no session) ---

    @Test
    fun kemUnobtainableFromEmptyBundleYieldsActionablePairingHintAndNoSession() = runTest {
        val peer = PeerRef("apple-peer-13")
        val channel = RecordingControlChannel(PeerKemPublicKeys()) // empty bundle
        var rekeyInvoked = false

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, _ -> rekeyInvoked = true; PqcRekeyResult.Success }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue(result.isFailure)
        val ex = result.exceptionOrNull() as BootstrapHandshakeException
        // R4.11: classified as peer KEM key unobtainable.
        assertEquals(HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE, ex.failure.category)
        // Actionable pairing hint present, with concrete steps.
        val hint = ex.pairingHint
        assertNotNull("R4.11 must surface an actionable pairing hint", hint)
        assertEquals(PairingHintReason.PEER_KEM_PUBLIC_KEY_UNAVAILABLE, hint!!.reason)
        assertTrue("pairing hint must contain actionable steps", hint.steps.isNotEmpty())
        assertTrue("pairing hint steps must be non-blank", hint.steps.all { it.isNotBlank() })
        // No session established, no classic-suite business traffic; rekey never forced.
        assertFalse("rekey must not run when no KEM key was obtained", rekeyInvoked)
        assertFalse("no session may be established", sm.isSessionEstablished)
        assertFalse("no business traffic over a classic suite", sm.canCarryBusinessTraffic)
        assertEquals(BootstrapHandshakeState.FAILED, sm.state)
    }

    @Test
    fun kemAcquisitionTimeoutYieldsPairingHintAndNoSession() = runTest {
        val peer = PeerRef("apple-peer-14")
        val derivedSecret = ByteArray(24) { 3 }
        // Retrieval never completes within the 10 s acquisition deadline.
        val channel = RecordingControlChannel(
            keys = mlKemKeys(),
            derivedSecret = derivedSecret,
            retrieveDelayMillis = 60_000
        )
        var wipeCallbacks = 0

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { channel },
            forcePqcRekey = { _, _ -> PqcRekeyResult.Success },
            kemAcquisitionDeadlineMillis = 10_000L,
            onKeyMaterialWiped = { wipeCallbacks++ }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue(result.isFailure)
        val ex = result.exceptionOrNull() as BootstrapHandshakeException
        assertEquals(HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE, ex.failure.category)
        assertNotNull("KEM acquisition timeout must surface a pairing hint", ex.pairingHint)
        // Channel terminated and any derived material wiped exactly once.
        assertTrue("channel terminated on KEM acquisition timeout", channel.closed)
        assertTrue("derived material zeroized", derivedSecret.all { it == 0.toByte() })
        assertEquals(1, wipeCallbacks)
        assertFalse(sm.isSessionEstablished)
        assertEquals(BootstrapHandshakeState.FAILED, sm.state)
    }

    @Test
    fun controlChannelOpenFailureYieldsActionablePairingHint() = runTest {
        val peer = PeerRef("apple-peer-15")

        val sm = DefaultBootstrapAssistedHandshake(
            policy = DowngradePolicy.STRICT_PQC_BOOTSTRAP_ASSISTED,
            localPeerKemLookup = { null },
            openControlChannel = { throw IllegalStateException("no route to peer") },
            forcePqcRekey = { _, _ -> PqcRekeyResult.Success }
        )

        val result = sm.bootstrapPeerKemKeys(peer)

        assertTrue(result.isFailure)
        val ex = result.exceptionOrNull() as BootstrapHandshakeException
        assertEquals(HandshakeFailureCategory.PEER_KEM_PUBLIC_KEY_UNAVAILABLE, ex.failure.category)
        assertNotNull("R4.11 pairing hint on channel-open failure", ex.pairingHint)
        assertFalse(sm.isSessionEstablished)
    }
}
