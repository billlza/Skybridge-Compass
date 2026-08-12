package com.skybridge.compass.android.remote.mac

import android.content.ContextWrapper
import com.skybridge.compass.android.account.AccountBusinessIdentityProvider
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.p2p.PeerKemKeyStore
import com.skybridge.compass.core.p2p.PeerKemPublicKeySource
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PXWingKem
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MacRemoteFormalLanSecurityPolicyTest {
    @Test
    fun productionFailureReasonsNeverExposeUnderlyingIdentityMaterial() {
        val canary = "peer=id:mac-secret nonce=nonce-secret key=key-secret"
        listOf(
            MacRemoteControlTrustMode.PERSISTENT_PRODUCT,
            MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY
        ).forEach { mode ->
            val reason = MacRemoteFormalFailurePolicy.reason(
                mode = mode,
                reasonCode = "formal_trust_precheck_failed",
                error = IllegalStateException(canary),
                diagnosticReason = canary
            )
            assertFalse(reason.contains("mac-secret"))
            assertFalse(reason.contains("nonce-secret"))
            assertFalse(reason.contains("key-secret"))
            assertTrue(reason.contains("reasonCode=formal_trust_precheck_failed"))
            assertTrue(reason.contains("exception=IllegalStateException"))
        }

        assertEquals(
            canary,
            MacRemoteFormalFailurePolicy.reason(
                mode = MacRemoteControlTrustMode.EPHEMERAL_DIAGNOSTIC,
                reasonCode = "diagnostic_failure",
                error = IllegalStateException(canary),
                diagnosticReason = canary
            )
        )
    }

    @Test
    fun formalConfigurationRequiresHandshakeEncryptionNoTofuAndNativePqc() {
        val strict = MacRemoteControlClient.SecurityConfig.formalLanAcceptance()
        MacRemoteFormalLanSecurityPolicy.requireStrict(enableHandshake = true, config = strict)

        listOf(
            false to strict,
            true to strict.copy(encryptionRequired = false),
            true to strict.copy(allowPlaintextFallback = true),
            true to strict.copy(allowTrustOnFirstUse = true),
            true to strict.copy(handshakePolicyOverride = null),
            true to strict.copy(
                handshakePolicyOverride = P2PHandshakePolicyOverride(
                    requirePqc = false,
                    allowClassicFallback = false,
                    minimumTierRaw = "classic"
                )
            ),
            true to strict.copy(
                handshakePolicyOverride = P2PHandshakePolicyOverride(
                    requirePqc = true,
                    allowClassicFallback = true,
                    minimumTierRaw = "nativePQC"
                )
            ),
            true to strict.copy(
                handshakePolicyOverride = P2PHandshakePolicyOverride(
                    requirePqc = true,
                    allowClassicFallback = false,
                    minimumTierRaw = "liboqsPQC"
                )
            )
        ).forEach { (enableHandshake, config) ->
            assertThrows(IllegalArgumentException::class.java) {
                MacRemoteFormalLanSecurityPolicy.requireStrict(enableHandshake, config)
            }
        }
    }

    @Test
    fun formalKemPolicyRejectsMissingXWingAndNegotiatedMlKem() {
        val formal = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY
        assertThrows(IllegalArgumentException::class.java) {
            MacRemoteFormalKemPolicy.requireStartReady(
                mode = formal,
                localXWingAvailable = true,
                peerXWingPublicKey = null
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            MacRemoteFormalKemPolicy.requireStartReady(
                mode = formal,
                localXWingAvailable = false,
                peerXWingPublicKey = ByteArray(1_216)
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            MacRemoteFormalKemPolicy.requireNegotiatedSuite(formal, P2PCryptoSuite.MLKEM_768)
        }
        MacRemoteFormalKemPolicy.requireStartReady(formal, true, ByteArray(1_216))
        MacRemoteFormalKemPolicy.requireNegotiatedSuite(formal, P2PCryptoSuite.X_WING)
    }

    @Test
    fun formalRouteAuthorizationRequiresAnExplicitCurrentLease() {
        val formal = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY
        assertThrows(IllegalArgumentException::class.java) {
            MacRemoteFormalRouteAuthorizationPolicy.requireCurrent(formal, lease = null)
        }
        assertThrows(IllegalArgumentException::class.java) {
            MacRemoteFormalRouteAuthorizationPolicy.requireCurrent(
                formal,
                MacRemoteFormalRouteAuthorizationLease { false }
            )
        }
        MacRemoteFormalRouteAuthorizationPolicy.requireCurrent(
            formal,
            MacRemoteFormalRouteAuthorizationLease { true }
        )

        MacRemoteFormalRouteAuthorizationPolicy.requireCurrent(
            MacRemoteControlTrustMode.PERSISTENT_PRODUCT,
            lease = null
        )
    }

    @Test
    fun formalCommitRereadsAndRejectsRevokedOrChangedAuthority() {
        val pin = "a".repeat(64)
        val store = MutableTrustStore(pin)
        MacRemoteFormalTrustCommitPolicy.requireUnchangedAuthority(
            mode = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY,
            trustStore = store,
            peerId = "id:mac-1",
            observedFingerprint = pin
        )

        store.currentFingerprint = null
        assertThrows(IllegalStateException::class.java) {
            MacRemoteFormalTrustCommitPolicy.requireUnchangedAuthority(
                mode = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY,
                trustStore = store,
                peerId = "id:mac-1",
                observedFingerprint = pin
            )
        }
        store.currentFingerprint = "b".repeat(64)
        assertThrows(IllegalStateException::class.java) {
            MacRemoteFormalTrustCommitPolicy.requireUnchangedAuthority(
                mode = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY,
                trustStore = store,
                peerId = "id:mac-1",
                observedFingerprint = pin
            )
        }
    }

    @Test
    fun formalPreDialRequiresExactCurrentPinAndXWing() {
        val pin = "a".repeat(64)
        val trust = MutableTrustStore(pin)
        var keys = PeerKemKeyStore.PeerKemPublicKeys(xWingPublicKey = ByteArray(1_216))
        var kemLoads = 0
        val context = MacRemoteControlTrustContext(
            peerKemPublicKeys = PeerKemPublicKeySource {
                kemLoads += 1
                keys
            },
            peerSigningFingerprints = trust,
            fallbackCooldowns = P2PHandshakeWire.InMemoryFallbackCooldownStore(),
            mode = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY
        )
        val target = MacRemoteControlClient.ConnectionTarget(
            host = "192.168.1.20",
            port = 5_901,
            deviceIdHint = "id:mac-1",
            advertisedFingerprint = pin,
            advertisedFingerprintTrustSource =
                MacRemoteControlClient.FingerprintTrustSource.TRUSTED_CONFIGURATION
        )

        MacRemoteFormalPreDialPolicy.requireReady(
            mode = context.mode,
            target = target,
            trustContext = context,
            localXWingAvailable = true
        )
        assertTrue(kemLoads == 1)

        trust.currentFingerprint = null
        assertThrows(IllegalStateException::class.java) {
            MacRemoteFormalPreDialPolicy.requireReady(context.mode, target, context, true)
        }
        assertTrue("revoked pin must fail before loading KEM", kemLoads == 1)

        trust.currentFingerprint = "b".repeat(64)
        assertThrows(IllegalStateException::class.java) {
            MacRemoteFormalPreDialPolicy.requireReady(context.mode, target, context, true)
        }
        assertTrue("changed pin must fail before loading KEM", kemLoads == 1)

        trust.currentFingerprint = pin
        keys = PeerKemKeyStore.PeerKemPublicKeys(mlKem768PublicKey = ByteArray(1_184))
        assertThrows(IllegalArgumentException::class.java) {
            MacRemoteFormalPreDialPolicy.requireReady(context.mode, target, context, true)
        }
        assertTrue(kemLoads == 2)
    }

    @Test
    fun formalFailureReasonNeverIncludesRawPeerCanaryOrExceptionMessage() {
        val canary = "id:peer-canary-do-not-log"
        val reason = MacRemoteFormalFailurePolicy.reason(
            mode = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY,
            reasonCode = "formal_handshake_start_failed",
            error = IllegalStateException("malformed provenance for $canary"),
            diagnosticReason = "legacy failure for $canary"
        )

        assertTrue(reason.contains("reasonCode=formal_handshake_start_failed"))
        assertTrue(reason.contains("exception=IllegalStateException"))
        assertFalse(reason.contains(canary))
        assertFalse(reason.contains("malformed provenance"))
    }

    @Test
    fun persistentProductMalformedInboundControlDoesNotExposePayloadInStateOrLogs() {
        val canary = "peer=id:mac-secret nonce=nonce-secret key=key-secret"
        val malformedControl = "{\"type\":\"$canary\",\"payload\":".encodeToByteArray()
        val framedControl = ByteBuffer.allocate(Int.SIZE_BYTES + malformedControl.size)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(malformedControl.size)
            .put(malformedControl)
            .array()
        val socket = InMemorySocket(framedControl)
        val logs = RecordingLogSink()
        val testContext = ContextWrapper(null)
        val client = MacRemoteControlClient(
            appContext = testContext,
            accountBusinessIdentityProvider = AccountBusinessIdentityProvider { null },
            localIdentityOverride = LocalP2PIdentity(
                testContext,
                LocalP2PIdentity.StorageMode.ISOLATED_PLAINTEXT_TEST
            ),
            trustContextOverride = MacRemoteControlTrustContext(
                peerKemPublicKeys = PeerKemPublicKeySource {
                    PeerKemKeyStore.PeerKemPublicKeys()
                },
                peerSigningFingerprints = MutableTrustStore(null),
                fallbackCooldowns = P2PHandshakeWire.InMemoryFallbackCooldownStore(),
                mode = MacRemoteControlTrustMode.PERSISTENT_PRODUCT
            ),
            socketFactory = { socket },
            socketConnector = { _, _, _ -> },
            streamingFormatsProvider = { listOf("jpeg") },
            logSink = logs
        )

        client.connect(
            target = MacRemoteControlClient.ConnectionTarget(
                host = "192.168.1.20",
                port = 5_901
            ),
            enableHandshake = false,
            securityConfig = MacRemoteControlClient.SecurityConfig(
                encryptionRequired = false,
                allowPlaintextFallback = true,
                allowTrustOnFirstUse = false
            )
        )

        val failed = runBlocking {
            withTimeout(5_000) {
                client.state.first { it is MacRemoteControlClient.State.Failed }
            }
        } as MacRemoteControlClient.State.Failed
        assertTrue(failed.message.contains("reasonCode=inbound_frame_handling_failed"))
        assertFalse(failed.message.contains(canary))
        assertFalse(logs.messages.joinToString("\n").contains(canary))
        client.disconnect()
    }

    @Test
    fun preAcknowledgementDisconnectClosesBlockedTransportWithoutWaitingForWriteLock() {
        val socket = BlockingWriteSocket()
        val testContext = ContextWrapper(null)
        val client = MacRemoteControlClient(
            appContext = testContext,
            accountBusinessIdentityProvider = AccountBusinessIdentityProvider { null },
            localIdentityOverride = LocalP2PIdentity(
                testContext,
                LocalP2PIdentity.StorageMode.ISOLATED_PLAINTEXT_TEST
            ),
            trustContextOverride = MacRemoteControlTrustContext(
                peerKemPublicKeys = PeerKemPublicKeySource {
                    PeerKemKeyStore.PeerKemPublicKeys()
                },
                peerSigningFingerprints = MutableTrustStore(null),
                fallbackCooldowns = P2PHandshakeWire.InMemoryFallbackCooldownStore(),
                mode = MacRemoteControlTrustMode.PERSISTENT_PRODUCT
            ),
            socketFactory = { socket },
            socketConnector = { _, _, _ -> },
            streamingFormatsProvider = { listOf("jpeg") },
            logSink = RecordingLogSink()
        )

        client.connect(
            target = MacRemoteControlClient.ConnectionTarget(
                host = "192.168.1.20",
                port = 5_901
            ),
            enableHandshake = false,
            securityConfig = MacRemoteControlClient.SecurityConfig(
                encryptionRequired = false,
                allowPlaintextFallback = true,
                allowTrustOnFirstUse = false
            )
        )
        assertTrue(socket.output.writeEntered.await(5, TimeUnit.SECONDS))

        val disconnectReturned = CountDownLatch(1)
        val disconnectFailure = AtomicReference<Throwable?>()
        val disconnectThread = thread(name = "pre-ack-disconnect") {
            try {
                client.disconnect()
            } catch (error: Throwable) {
                disconnectFailure.set(error)
            } finally {
                disconnectReturned.countDown()
            }
        }
        try {
            assertTrue(
                "disconnect must socket-close without waiting for the blocked writer",
                disconnectReturned.await(2, TimeUnit.SECONDS)
            )
            assertEquals(null, disconnectFailure.get())
            assertTrue(socket.closed.await(2, TimeUnit.SECONDS))
            assertEquals(MacRemoteControlClient.State.Disconnected, client.state.value)
        } finally {
            socket.close()
            disconnectThread.join(5_000)
        }
    }

    @Test
    fun routeLeaseReplacementAfterSchedulingPreventsSocketConnectorInvocation() {
        val routeCurrent = AtomicBoolean(true)
        assertSecondPreDialChangeDoesNotConnect(
            routeCurrent = routeCurrent,
            mutateBeforeSecondPrecheck = { routeCurrent.set(false) }
        )
    }

    @Test
    fun pinRevocationAfterSchedulingPreventsSocketConnectorInvocation() {
        val routeCurrent = AtomicBoolean(true)
        assertSecondPreDialChangeDoesNotConnect(
            routeCurrent = routeCurrent,
            mutateBeforeSecondPrecheck = { trust -> trust.currentFingerprint = null }
        )
    }

    private fun assertSecondPreDialChangeDoesNotConnect(
        routeCurrent: AtomicBoolean,
        mutateBeforeSecondPrecheck: (MutableTrustStore) -> Unit
    ) {
        val pin = "a".repeat(64)
        val trust = MutableTrustStore(pin)
        val enteredSecondPrecheck = CountDownLatch(1)
        val releaseSecondPrecheck = CountDownLatch(1)
        val connectorCalls = AtomicInteger(0)
        val testContext = ContextWrapper(null)
        val client = MacRemoteControlClient(
            appContext = testContext,
            accountBusinessIdentityProvider = AccountBusinessIdentityProvider { null },
            localIdentityOverride = LocalP2PIdentity(
                testContext,
                LocalP2PIdentity.StorageMode.ISOLATED_PLAINTEXT_TEST
            ),
            trustContextOverride = MacRemoteControlTrustContext(
                peerKemPublicKeys = PeerKemPublicKeySource {
                    PeerKemKeyStore.PeerKemPublicKeys(
                        xWingPublicKey = ByteArray(P2PXWingKem.XWING_PUBLIC_KEY_SIZE)
                    )
                },
                peerSigningFingerprints = trust,
                fallbackCooldowns = P2PHandshakeWire.InMemoryFallbackCooldownStore(),
                mode = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY
            ),
            formalRouteAuthorizationLease = MacRemoteFormalRouteAuthorizationLease(
                routeCurrent::get
            ),
            socketConnector = { _, _, _ -> connectorCalls.incrementAndGet() },
            localXWingAvailability = { true },
            beforeFormalDialRecheck = {
                enteredSecondPrecheck.countDown()
                check(releaseSecondPrecheck.await(5, TimeUnit.SECONDS)) {
                    "timed out waiting to release formal pre-dial recheck"
                }
            },
            logSink = RecordingLogSink()
        )

        client.connect(
            target = MacRemoteControlClient.ConnectionTarget(
                host = "192.168.1.20",
                port = 5_901,
                deviceIdHint = "id:mac-1",
                advertisedFingerprint = pin,
                advertisedFingerprintTrustSource =
                    MacRemoteControlClient.FingerprintTrustSource.TRUSTED_CONFIGURATION
            ),
            enableHandshake = true,
            securityConfig = MacRemoteControlClient.SecurityConfig.formalLanAcceptance()
        )
        assertTrue(enteredSecondPrecheck.await(5, TimeUnit.SECONDS))
        mutateBeforeSecondPrecheck(trust)
        releaseSecondPrecheck.countDown()

        runBlocking {
            withTimeout(5_000) {
                client.state.first { it is MacRemoteControlClient.State.Failed }
            }
        }
        assertEquals(0, connectorCalls.get())
        client.disconnect()
    }

    private class InMemorySocket(inputBytes: ByteArray) : Socket() {
        private val input = ByteArrayInputStream(inputBytes)
        private val output = ByteArrayOutputStream()

        override fun getInputStream(): InputStream = input

        override fun getOutputStream(): OutputStream = output

        override fun setTcpNoDelay(on: Boolean) = Unit

        override fun setSoTimeout(timeout: Int) = Unit
    }

    private class BlockingWriteSocket : Socket() {
        val output = BlockingOutputStream()
        val closed = CountDownLatch(1)
        private val input = ByteArrayInputStream(ByteArray(0))

        override fun getInputStream(): InputStream = input

        override fun getOutputStream(): OutputStream = output

        override fun setTcpNoDelay(on: Boolean) = Unit

        override fun setSoTimeout(timeout: Int) = Unit

        override fun close() {
            output.close()
            closed.countDown()
        }
    }

    private class BlockingOutputStream : OutputStream() {
        val writeEntered = CountDownLatch(1)
        private val closed = CountDownLatch(1)

        override fun write(value: Int) {
            writeEntered.countDown()
            check(closed.await(10, TimeUnit.SECONDS)) {
                "blocking output was not closed"
            }
            throw IOException("closed")
        }

        override fun close() {
            closed.countDown()
        }
    }

    private class RecordingLogSink : MacRemoteControlLogSink {
        val messages = mutableListOf<String>()

        override fun debug(message: String) {
            messages += message
        }

        override fun info(message: String) {
            messages += message
        }

        override fun warn(message: String) {
            messages += message
        }

        override fun error(message: String) {
            messages += message
        }
    }

    private class MutableTrustStore(
        var currentFingerprint: String?
    ) : P2PHandshakeWire.TrustStore {
        override fun loadPeerSigningFingerprint(peerId: String): String? = currentFingerprint

        override fun savePeerSigningFingerprint(peerId: String, peerSigningFingerprint: String) {
            error("test formal store is read-only")
        }
    }
}
