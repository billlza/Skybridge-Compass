package com.skybridge.compass.android.ui.screens.remotecontrol

import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsSource
import com.skybridge.compass.android.discovery.ProductActionGateDecision
import com.skybridge.compass.android.discovery.ProductRemoteDesktopDecision
import com.skybridge.compass.android.discovery.ProductSessionActionGate
import com.skybridge.compass.android.remote.mac.LanRemotePeer
import com.skybridge.compass.android.remote.mac.MacRemoteControlClient
import com.skybridge.compass.android.remote.mac.MacRemoteControlClientFactory
import com.skybridge.compass.android.remote.mac.MacRemoteFormalRouteAuthorizationLease
import com.skybridge.compass.android.remote.mac.RemoteKeyIntent
import com.skybridge.compass.android.remote.mac.RemoteKeyboardInputMapper
import com.skybridge.compass.core.p2p.FormalLanDurableRouteAuthorization
import com.skybridge.compass.core.p2p.FormalLanPeerCoordinator
import com.skybridge.compass.core.p2p.FormalLanPeerException
import com.skybridge.compass.core.p2p.FormalLanPeerFailureReason
import com.skybridge.compass.core.p2p.FormalLanReadyAuthorization
import com.skybridge.compass.core.webrtc.RemoteViewerStatus
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.usecases.StartDeviceDiscoveryUseCase
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LanRemoteClientViewModelTest {
    @Test
    fun doubleTapUsesOneSkrAuthorizationAndOneFormalDial() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val fixture = Fixture(dualRoute = true)
            val peer = fixture.awaitPeer(this)
            every { fixture.actionGate.decideRemoteDesktop(any(), any(), any()) } returns
                ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap
            coEvery { fixture.coordinator.authorizeRemoteConnect(any(), any()) } returns
                FormalLanReadyAuthorization(
                    peer = requireNotNull(peer.formalSnapshot),
                    authorityDeviceIds = listOf(peer.id),
                    pinnedProtocolFingerprint = PIN
                )

            fixture.viewModel.connect(peer)
            fixture.viewModel.connect(peer)
            advanceUntilIdle()

            coVerify(exactly = 1) { fixture.coordinator.authorizeRemoteConnect(any(), any()) }
            verify(exactly = 1) { fixture.factory.createFormalLanAcceptance(any()) }
            verify(exactly = 0) { fixture.factory.create() }
            verify(exactly = 1) {
                fixture.client.connect(
                    any(),
                    true,
                    MacRemoteControlClient.SecurityConfig.formalLanAcceptance()
                )
            }
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun existingProductSessionRemoteOnlyStillRequiresDurableFormalMaterialAndFormalClient() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val fixture = Fixture(dualRoute = false)
            val peer = fixture.awaitPeer(this)
            val allowed = ProductActionGateDecision.Allowed(
                owner = ProductSessionOwner.create("session-1", generation = 3),
                sessionId = "session-1",
                remoteDeviceId = peer.id,
                remotePublicKeyFingerprint = PIN
            )
            every { fixture.actionGate.decideRemoteDesktop(any(), any(), any()) } returns
                ProductRemoteDesktopDecision.ExistingProductSession(allowed)
            coEvery {
                fixture.coordinator.authorizeDurableProductSessionRoute(peer.id, PIN)
            } returns FormalLanDurableRouteAuthorization(listOf(peer.id), PIN)

            fixture.viewModel.connect(peer)
            advanceUntilIdle()

            coVerify(exactly = 1) {
                fixture.coordinator.authorizeDurableProductSessionRoute(peer.id, PIN)
            }
            coVerify(exactly = 0) { fixture.coordinator.authorizeRemoteConnect(any(), any()) }
            verify(exactly = 1) { fixture.factory.createFormalLanAcceptance(any()) }
            verify(exactly = 0) { fixture.factory.create() }
            verify(exactly = 1) {
                fixture.client.connect(
                    any(),
                    true,
                    MacRemoteControlClient.SecurityConfig.formalLanAcceptance()
                )
            }
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun disablingRemoteControlBlocksNewInputButAllowsOneOwnedPointerRelease() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val fixture = Fixture(dualRoute = true)
            val peer = fixture.awaitPeer(this)
            every { fixture.actionGate.decideRemoteDesktop(any(), any(), any()) } returns
                ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap
            coEvery { fixture.coordinator.authorizeRemoteConnect(any(), any()) } returns
                FormalLanReadyAuthorization(
                    peer = requireNotNull(peer.formalSnapshot),
                    authorityDeviceIds = listOf(peer.id),
                    pinnedProtocolFingerprint = PIN
                )
            every { fixture.client.hasSecureChannel() } returns true
            fixture.viewModel.connect(peer)
            advanceUntilIdle()
            fixture.clientState.value = MacRemoteControlClient.State.Connected(mockk(relaxed = true))
            fixture.viewModel.sendLeftDown(1.0, 2.0)
            fixture.settings.value = SecuritySettings(allowRemoteControl = false)
            advanceUntilIdle()

            fixture.viewModel.onDecoderError("decoder-canary")
            fixture.viewModel.sendMouseMove(1.0, 2.0)
            fixture.viewModel.sendLeftDown(1.0, 2.0)
            fixture.viewModel.sendLeftUp(1.0, 2.0)
            fixture.viewModel.sendLeftUp(1.0, 2.0)
            fixture.viewModel.sendScrollUp(1.0, 2.0)
            fixture.viewModel.sendScrollDown(1.0, 2.0)
            fixture.viewModel.sendKeyStroke(RemoteKeyIntent.Named.ENTER)

            verify(exactly = 1) { fixture.client.onDecoderError("decoder-canary") }
            verify(exactly = 1) { fixture.client.sendLeftDown(1.0, 2.0) }
            verify(exactly = 1) { fixture.client.sendLeftUp(1.0, 2.0) }
            verify(exactly = 0) {
                fixture.client.sendMouseMove(any(), any())
                fixture.client.sendScrollUp(any(), any())
                fixture.client.sendScrollDown(any(), any())
                fixture.client.sendKeyStroke(ENTER_MAC_KEY_CODE)
            }
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun routeReplacementRevokesAndTerminatesTheInputOwnerBeforeFurtherInput() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val fixture = Fixture(dualRoute = true)
            val peer = fixture.awaitPeer(this)
            every { fixture.actionGate.decideRemoteDesktop(any(), any(), any()) } returns
                ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap
            coEvery { fixture.coordinator.authorizeRemoteConnect(any(), any()) } returns
                FormalLanReadyAuthorization(
                    peer = requireNotNull(peer.formalSnapshot),
                    authorityDeviceIds = listOf(peer.id),
                    pinnedProtocolFingerprint = PIN
                )
            every { fixture.client.hasSecureChannel() } returns true
            fixture.viewModel.connect(peer)
            advanceUntilIdle()
            fixture.clientState.value = MacRemoteControlClient.State.Connected(mockk(relaxed = true))
            fixture.viewModel.sendLeftDown(4.0, 5.0)

            fixture.publishDevice(dualRoute = true, remoteAddress = "192.168.1.21")
            advanceUntilIdle()

            assertEquals(null, fixture.viewModel.activePeerState.value)
            verify(exactly = 1) { fixture.client.disconnect() }
            fixture.viewModel.sendMouseMove(6.0, 7.0)
            fixture.viewModel.sendLeftUp(6.0, 7.0)
            fixture.viewModel.sendScrollUp(6.0, 7.0)
            fixture.viewModel.sendKeyStroke(RemoteKeyIntent.Named.ENTER)
            verify(exactly = 1) { fixture.client.sendLeftDown(4.0, 5.0) }
            verify(exactly = 0) {
                fixture.client.sendMouseMove(any(), any())
                fixture.client.sendLeftUp(any(), any())
                fixture.client.sendScrollUp(any(), any())
                fixture.client.sendKeyStroke(ENTER_MAC_KEY_CODE)
            }
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun normalDisconnectDrainLeaseStillRejectsAChangedDiscoverySnapshot() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val fixture = Fixture(dualRoute = true)
            val peer = fixture.awaitPeer(this)
            val lease = slot<MacRemoteFormalRouteAuthorizationLease>()
            every { fixture.actionGate.decideRemoteDesktop(any(), any(), any()) } returns
                ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap
            coEvery { fixture.coordinator.authorizeRemoteConnect(any(), any()) } returns
                FormalLanReadyAuthorization(
                    peer = requireNotNull(peer.formalSnapshot),
                    authorityDeviceIds = listOf(peer.id),
                    pinnedProtocolFingerprint = PIN
                )
            every { fixture.factory.createFormalLanAcceptance(capture(lease)) } returns fixture.client

            fixture.viewModel.connect(peer)
            advanceUntilIdle()
            assertTrue(lease.captured.isCurrent())
            fixture.viewModel.disconnect()

            fixture.publishDevice(dualRoute = true, remoteAddress = "192.168.1.21")
            advanceUntilIdle()

            assertFalse(lease.captured.isCurrent())
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun typedFormalAuthorizationFailuresNeverCreateOrDialAClient() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val reasons = listOf(
                FormalLanPeerFailureReason.ACTIVE_AUTHENTICATED_PIN_REQUIRED,
                FormalLanPeerFailureReason.CANONICAL_AUTHORITY_BLOCKED,
                FormalLanPeerFailureReason.TRUST_STORE_CORRUPTED,
                FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH,
                FormalLanPeerFailureReason.X_WING_REQUIRED
            )
            reasons.forEach { reason ->
                val fixture = Fixture(dualRoute = true)
                val peer = fixture.awaitPeer(this)
                every { fixture.actionGate.decideRemoteDesktop(any(), any(), any()) } returns
                    ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap
                coEvery { fixture.coordinator.authorizeRemoteConnect(any(), any()) } throws
                    FormalLanPeerException(reason)

                fixture.viewModel.connect(peer)
                advanceUntilIdle()

                coVerify(exactly = 1) {
                    fixture.coordinator.authorizeRemoteConnect(any(), any())
                }
                verify(exactly = 0) { fixture.factory.createFormalLanAcceptance(any()) }
                verify(exactly = 0) { fixture.factory.create() }
                verify(exactly = 0) { fixture.client.connect(any(), any(), any()) }
            }
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun discoveryReplacementWhileAuthorizationIsSuspendedCannotCreateOrDialAClient() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val fixture = Fixture(dualRoute = true)
            val peer = fixture.awaitPeer(this)
            val authorizationStarted = CompletableDeferred<Unit>()
            val releaseAuthorization = CompletableDeferred<Unit>()
            every { fixture.actionGate.decideRemoteDesktop(any(), any(), any()) } returns
                ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap
            coEvery { fixture.coordinator.authorizeRemoteConnect(any(), any()) } coAnswers {
                authorizationStarted.complete(Unit)
                releaseAuthorization.await()
                FormalLanReadyAuthorization(
                    peer = requireNotNull(peer.formalSnapshot),
                    authorityDeviceIds = listOf(peer.id),
                    pinnedProtocolFingerprint = PIN
                )
            }

            fixture.viewModel.connect(peer)
            runCurrent()
            authorizationStarted.await()
            fixture.publishDevice(dualRoute = true, remoteAddress = "192.168.1.21")
            runCurrent()
            releaseAuthorization.complete(Unit)
            advanceUntilIdle()

            verify(exactly = 0) { fixture.factory.createFormalLanAcceptance(any()) }
            verify(exactly = 0) { fixture.client.connect(any(), any(), any()) }
            assertEquals(null, fixture.viewModel.preDialPeerId.value)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun disconnectWhileAuthorizationIsSuspendedCancelsTheAttemptBeforeClientCreation() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val fixture = Fixture(dualRoute = true)
            val peer = fixture.awaitPeer(this)
            val authorizationStarted = CompletableDeferred<Unit>()
            val releaseAuthorization = CompletableDeferred<Unit>()
            every { fixture.actionGate.decideRemoteDesktop(any(), any(), any()) } returns
                ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap
            coEvery { fixture.coordinator.authorizeRemoteConnect(any(), any()) } coAnswers {
                authorizationStarted.complete(Unit)
                releaseAuthorization.await()
                FormalLanReadyAuthorization(
                    peer = requireNotNull(peer.formalSnapshot),
                    authorityDeviceIds = listOf(peer.id),
                    pinnedProtocolFingerprint = PIN
                )
            }

            fixture.viewModel.connect(peer)
            runCurrent()
            authorizationStarted.await()
            fixture.viewModel.disconnect()
            releaseAuthorization.complete(Unit)
            advanceUntilIdle()

            verify(exactly = 0) { fixture.factory.createFormalLanAcceptance(any()) }
            verify(exactly = 0) { fixture.client.connect(any(), any(), any()) }
            assertEquals(null, fixture.viewModel.activePeerState.value)
        } finally {
            Dispatchers.resetMain()
        }
    }

    private class Fixture(
        dualRoute: Boolean
    ) {
        val discovery = mockk<StartDeviceDiscoveryUseCase>()
        val actionGate = mockk<ProductSessionActionGate>()
        val coordinator = mockk<FormalLanPeerCoordinator>()
        val factory = mockk<MacRemoteControlClientFactory>()
        val client = mockk<MacRemoteControlClient>()
        val settings = MutableStateFlow(SecuritySettings(allowRemoteControl = true))
        val clientState = MutableStateFlow<MacRemoteControlClient.State>(
            MacRemoteControlClient.State.Disconnected
        )
        private val devices = MutableStateFlow(listOf(discoveredDevice(dualRoute)))
        val viewModel: LanRemoteClientViewModel

        init {
            coEvery { discovery.invoke(any(), any()) } returns devices
            val settingsSource = mockk<SecuritySettingsSource>()
            every { settingsSource.observe() } returns settings
            every { client.state } returns clientState
            every { client.latestFrame } returns MutableStateFlow(null)
            every { client.securityState } returns MutableStateFlow(
                MacRemoteControlClient.SecurityState.Disconnected
            )
            every { client.viewerStatus } returns MutableStateFlow(RemoteViewerStatus.Idle)
            every { client.disconnect() } just Runs
            every { client.onDecoderError(any()) } just Runs
            every { client.sendMouseMove(any(), any()) } just Runs
            every { client.sendLeftDown(any(), any()) } just Runs
            every { client.sendLeftUp(any(), any()) } just Runs
            every { client.sendScrollUp(any(), any()) } just Runs
            every { client.sendScrollDown(any(), any()) } just Runs
            every { client.sendKeyStroke(ENTER_MAC_KEY_CODE) } just Runs
            every { client.connect(any(), any(), any()) } answers {
                clientState.value = MacRemoteControlClient.State.Connecting(firstArg())
            }
            every { factory.createFormalLanAcceptance(any()) } returns client
            viewModel = LanRemoteClientViewModel(
                startDeviceDiscovery = discovery,
                productActionGate = actionGate,
                formalLanCoordinator = coordinator,
                remoteControlClientFactory = factory,
                securitySettingsSource = settingsSource
            )
        }

        suspend fun awaitPeer(scope: kotlinx.coroutines.test.TestScope): LanRemotePeer {
            scope.advanceUntilIdle()
            assertEquals(1, viewModel.peers.value.size)
            return viewModel.peers.value.single()
        }

        fun publishDevice(
            dualRoute: Boolean,
            remoteAddress: String = "192.168.1.20"
        ) {
            devices.value = listOf(discoveredDevice(dualRoute, remoteAddress))
        }
    }

    private companion object {
        const val DEVICE_ID = "id:mac-1"
        const val PIN =
            "aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22"
        val ENTER_MAC_KEY_CODE =
            RemoteKeyboardInputMapper.toMacVirtualKeyCode(RemoteKeyIntent.Named.ENTER)

        fun discoveredDevice(
            dualRoute: Boolean,
            remoteAddress: String = "192.168.1.20"
        ): DiscoveredDevice {
            val remoteType = AppleBonjourInterop.REMOTE_SERVICE_TYPE
            val mainType = AppleBonjourInterop.MAIN_SERVICE_TYPE
            val remote = mapOf(
                "servicePort:$remoteType" to "5901",
                "serviceInstance:$remoteType" to "Mac._skybridge-rd._tcp.local",
                "serviceAddress:$remoteType" to remoteAddress,
                "serviceDeviceId:$remoteType" to DEVICE_ID,
                "serviceFingerprint:$remoteType" to PIN,
                "serviceIndexRevision" to "17"
            )
            val extra = if (!dualRoute) remote else remote + mapOf(
                "servicePort:$mainType" to "44000",
                "serviceInstance:$mainType" to "Mac._skybridge._tcp.local",
                "serviceAddress:$mainType" to "192.168.1.19",
                "serviceDeviceId:$mainType" to DEVICE_ID,
                "serviceFingerprint:$mainType" to PIN
            )
            return DiscoveredDevice(
                id = DEVICE_ID,
                name = "Mac",
                type = DeviceType.MACOS,
                capabilities = setOf(DeviceCapability.SCREEN_SHARING, DeviceCapability.REMOTE_CONTROL),
                connectionInfo = ConnectionInfo(
                    protocol = DiscoveryProtocol.BONJOUR,
                    address = if (dualRoute) "192.168.1.19" else remoteAddress,
                    port = if (dualRoute) 44_000 else 5_901,
                    serviceType = if (dualRoute) mainType else remoteType,
                    txtRecords = emptyMap(),
                    extra = extra
                ),
                signalStrength = 100,
                lastSeen = 1_000
            )
        }
    }
}
