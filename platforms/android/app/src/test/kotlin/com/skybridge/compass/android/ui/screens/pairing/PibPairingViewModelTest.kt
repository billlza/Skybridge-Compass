package com.skybridge.compass.android.ui.screens.pairing

import com.skybridge.compass.android.remote.mac.LanRemotePeer
import com.skybridge.compass.core.p2p.FormalLanPairingCandidate
import com.skybridge.compass.core.p2p.FormalLanPeerAction
import com.skybridge.compass.core.p2p.FormalLanPeerCoordinator
import com.skybridge.compass.core.p2p.FormalLanPeerException
import com.skybridge.compass.core.p2p.FormalLanPeerFailureReason
import com.skybridge.compass.core.p2p.FormalLanPeerInspection
import com.skybridge.compass.core.p2p.FormalLanReadyAuthorization
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PibPairingViewModelTest {
    @Test
    fun signedCanonicalIdMayDifferFromDiscoveryAliasThroughConfirmationAndRefresh() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val coordinator = mockk<FormalLanPeerCoordinator>()
            val identity = mockk<LocalP2PIdentity>()
            every { identity.deviceName() } returns "Android"
            val device = discoveredDevice(deviceId = DISCOVERY_ALIAS)
            val peer = requireNotNull(LanRemotePeer.fromDiscoveredDevice(device))
            val snapshot = requireNotNull(peer.formalSnapshot)
            val candidate = candidate(peerKey = DISCOVERY_ALIAS, canonicalDeviceId = CANONICAL_ID)
            coEvery { coordinator.inspect(any()) } returns
                FormalLanPeerInspection(FormalLanPeerAction.PAIR)
            coEvery { coordinator.requestPairing(any(), any()) } returns candidate
            coEvery { coordinator.confirmPairingAndRefresh(candidate, any()) } coAnswers {
                val currentPeer = arg<() -> com.skybridge.compass.core.p2p.FormalLanPeerSnapshot?>(1)
                assertTrue(snapshot.sameSecuritySnapshot(requireNotNull(currentPeer())))
                FormalLanReadyAuthorization(snapshot, listOf(DISCOVERY_ALIAS, CANONICAL_ID), PIN)
            }
            val viewModel = PibPairingViewModel(identity, coordinator)

            viewModel.updateDiscoveredDevices(listOf(device))
            advanceUntilIdle()
            viewModel.startOrRefresh(DISCOVERY_ALIAS)
            advanceUntilIdle()
            assertTrue(viewModel.state.value is PibPairingViewModel.PairingUiState.AwaitingConfirmation)
            viewModel.confirmSasMatches()
            advanceUntilIdle()

            val trusted = viewModel.state.value as PibPairingViewModel.PairingUiState.Trusted
            assertEquals(DISCOVERY_ALIAS, trusted.peer.id)
            coVerify(exactly = 1) { coordinator.requestPairing(any(), any()) }
            coVerify(exactly = 1) { coordinator.confirmPairingAndRefresh(candidate, any()) }
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun durablePibFailureRetriesOnlySignedRefreshWithoutRepeatingPib() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val coordinator = mockk<FormalLanPeerCoordinator>()
            val identity = mockk<LocalP2PIdentity>()
            every { identity.deviceName() } returns "Android"
            val device = discoveredDevice(deviceId = DISCOVERY_ALIAS)
            val peer = requireNotNull(LanRemotePeer.fromDiscoveredDevice(device))
            val snapshot = requireNotNull(peer.formalSnapshot)
            val durable = AtomicBoolean(false)
            val candidate = candidate(DISCOVERY_ALIAS, CANONICAL_ID)
            coEvery { coordinator.inspect(any()) } coAnswers {
                FormalLanPeerInspection(
                    if (durable.get()) FormalLanPeerAction.REFRESH_AND_CONNECT
                    else FormalLanPeerAction.PAIR
                )
            }
            coEvery { coordinator.requestPairing(any(), any()) } returns candidate
            coEvery { coordinator.confirmPairingAndRefresh(candidate, any()) } coAnswers {
                durable.set(true)
                throw FormalLanPeerException(
                    reason = FormalLanPeerFailureReason.REFRESH_FAILED,
                    durablePibReceiptObtained = true
                )
            }
            coEvery { coordinator.refreshAndAuthorize(any(), any()) } returns
                FormalLanReadyAuthorization(snapshot, listOf(DISCOVERY_ALIAS, CANONICAL_ID), PIN)
            val viewModel = PibPairingViewModel(identity, coordinator)

            viewModel.updateDiscoveredDevices(listOf(device))
            advanceUntilIdle()
            viewModel.startOrRefresh(DISCOVERY_ALIAS)
            advanceUntilIdle()
            viewModel.confirmSasMatches()
            advanceUntilIdle()
            val pending = viewModel.state.value as PibPairingViewModel.PairingUiState.RefreshPending
            assertEquals(DISCOVERY_ALIAS, pending.peerId)

            viewModel.retrySignedRefresh(pending.peerId)
            advanceUntilIdle()
            assertTrue(viewModel.state.value is PibPairingViewModel.PairingUiState.Trusted)
            coVerify(exactly = 1) { coordinator.requestPairing(any(), any()) }
            coVerify(exactly = 1) { coordinator.refreshAndAuthorize(any(), any()) }
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun routeReplacementAfterDurablePibAndSkrReportsReadyButRouteChanged() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val coordinator = mockk<FormalLanPeerCoordinator>()
            val identity = mockk<LocalP2PIdentity>()
            every { identity.deviceName() } returns "Android"
            val original = discoveredDevice(deviceId = DISCOVERY_ALIAS, revision = 17, remotePort = 5_901)
            val replacement = discoveredDevice(deviceId = DISCOVERY_ALIAS, revision = 18, remotePort = 5_902)
            val readyPeer = requireNotNull(
                LanRemotePeer.fromDiscoveredDevice(original)?.formalSnapshot
            )
            val candidate = candidate(DISCOVERY_ALIAS, CANONICAL_ID)
            coEvery { coordinator.inspect(any()) } returns
                FormalLanPeerInspection(FormalLanPeerAction.PAIR)
            coEvery { coordinator.requestPairing(any(), any()) } returns candidate
            lateinit var viewModel: PibPairingViewModel
            coEvery { coordinator.confirmPairingAndRefresh(candidate, any()) } coAnswers {
                viewModel.updateDiscoveredDevices(listOf(replacement))
                FormalLanReadyAuthorization(readyPeer, listOf(DISCOVERY_ALIAS, CANONICAL_ID), PIN)
            }
            viewModel = PibPairingViewModel(identity, coordinator)

            viewModel.updateDiscoveredDevices(listOf(original))
            advanceUntilIdle()
            viewModel.startOrRefresh(DISCOVERY_ALIAS)
            advanceUntilIdle()
            viewModel.confirmSasMatches()
            advanceUntilIdle()

            assertTrue(
                viewModel.state.value is PibPairingViewModel.PairingUiState.ReadyButRouteChanged
            )
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun verifiedFinalAckLocalPersistenceFailurePreservesRollbackCertainty() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            listOf(true, false).forEach { rollbackConfirmed ->
                val coordinator = mockk<FormalLanPeerCoordinator>()
                val identity = mockk<LocalP2PIdentity>()
                every { identity.deviceName() } returns "Android"
                val device = discoveredDevice(deviceId = DISCOVERY_ALIAS)
                val candidate = candidate(DISCOVERY_ALIAS, CANONICAL_ID)
                coEvery { coordinator.inspect(any()) } returns
                    FormalLanPeerInspection(FormalLanPeerAction.PAIR)
                coEvery { coordinator.requestPairing(any(), any()) } returns candidate
                coEvery { coordinator.confirmPairingAndRefresh(candidate, any()) } throws
                    FormalLanPeerException(
                        reason = FormalLanPeerFailureReason.LOCAL_TRUST_PERSISTENCE_FAILED,
                        pibFinalAckVerified = true,
                        localTrustRollbackConfirmed = rollbackConfirmed
                    )
                val viewModel = PibPairingViewModel(identity, coordinator)

                viewModel.updateDiscoveredDevices(listOf(device))
                advanceUntilIdle()
                viewModel.startOrRefresh(DISCOVERY_ALIAS)
                advanceUntilIdle()
                viewModel.confirmSasMatches()
                advanceUntilIdle()

                val recovery = viewModel.state.value as
                    PibPairingViewModel.PairingUiState.LocalTrustRecovery
                assertEquals(rollbackConfirmed, recovery.rollbackConfirmed)
                assertEquals(DISCOVERY_ALIAS, recovery.peerId)
                coVerify(exactly = 1) {
                    coordinator.confirmPairingAndRefresh(candidate, any())
                }
                coVerify(exactly = 0) { coordinator.refreshAndAuthorize(any(), any()) }
            }
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun repeatedConfirmIsSingleFlightAndRejectCancelsItsLateCompletion() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val coordinator = mockk<FormalLanPeerCoordinator>()
            val identity = mockk<LocalP2PIdentity>()
            every { identity.deviceName() } returns "Android"
            val device = discoveredDevice(deviceId = DISCOVERY_ALIAS)
            val readyPeer = requireNotNull(
                LanRemotePeer.fromDiscoveredDevice(device)?.formalSnapshot
            )
            val candidate = candidate(DISCOVERY_ALIAS, CANONICAL_ID)
            val confirmStarted = CompletableDeferred<Unit>()
            val releaseConfirm = CompletableDeferred<Unit>()
            coEvery { coordinator.inspect(any()) } returns
                FormalLanPeerInspection(FormalLanPeerAction.PAIR)
            coEvery { coordinator.requestPairing(any(), any()) } returns candidate
            coEvery { coordinator.confirmPairingAndRefresh(candidate, any()) } coAnswers {
                confirmStarted.complete(Unit)
                releaseConfirm.await()
                FormalLanReadyAuthorization(
                    readyPeer,
                    listOf(DISCOVERY_ALIAS, CANONICAL_ID),
                    PIN
                )
            }
            val viewModel = PibPairingViewModel(identity, coordinator)

            viewModel.updateDiscoveredDevices(listOf(device))
            advanceUntilIdle()
            viewModel.startOrRefresh(DISCOVERY_ALIAS)
            advanceUntilIdle()
            viewModel.confirmSasMatches()
            viewModel.confirmSasMatches()
            runCurrent()
            confirmStarted.await()
            coVerify(exactly = 1) { coordinator.confirmPairingAndRefresh(candidate, any()) }

            viewModel.rejectSas()
            releaseConfirm.complete(Unit)
            advanceUntilIdle()

            assertEquals(PibPairingViewModel.PairingUiState.Idle, viewModel.state.value)
            coVerify(exactly = 1) { coordinator.confirmPairingAndRefresh(candidate, any()) }
        } finally {
            Dispatchers.resetMain()
        }
    }

    private fun candidate(
        peerKey: String,
        canonicalDeviceId: String
    ): FormalLanPairingCandidate = mockk {
        every { macName } returns "Mac"
        every { macDeviceId } returns canonicalDeviceId
        every { discoveryPeerKey } returns peerKey
        every { sasCode } returns "123456"
        every { macFingerprint } returns PIN
        every { macSigningAlgorithm } returns "Ed25519"
    }

    private fun discoveredDevice(
        deviceId: String,
        revision: Long = 17,
        remotePort: Int = 5_901
    ): DiscoveredDevice {
        val mainType = AppleBonjourInterop.MAIN_SERVICE_TYPE
        val remoteType = AppleBonjourInterop.REMOTE_SERVICE_TYPE
        val extra = mapOf(
            "servicePort:$mainType" to "44000",
            "serviceInstance:$mainType" to "Mac._skybridge._tcp.local",
            "serviceAddress:$mainType" to "192.168.1.19",
            "serviceDeviceId:$mainType" to deviceId,
            "serviceFingerprint:$mainType" to PIN,
            "servicePort:$remoteType" to remotePort.toString(),
            "serviceInstance:$remoteType" to "Mac._skybridge-rd._tcp.local",
            "serviceAddress:$remoteType" to "192.168.1.20",
            "serviceDeviceId:$remoteType" to deviceId,
            "serviceFingerprint:$remoteType" to PIN,
            "serviceIndexRevision" to revision.toString()
        )
        return DiscoveredDevice(
            id = deviceId,
            name = "Mac",
            type = DeviceType.MACOS,
            capabilities = setOf(DeviceCapability.SCREEN_SHARING, DeviceCapability.REMOTE_CONTROL),
            connectionInfo = ConnectionInfo(
                protocol = DiscoveryProtocol.BONJOUR,
                address = "192.168.1.19",
                port = 44_000,
                serviceType = mainType,
                txtRecords = emptyMap(),
                extra = extra
            ),
            signalStrength = 100,
            lastSeen = 1_000
        )
    }

    private companion object {
        const val DISCOVERY_ALIAS = "bonjour:mac@local."
        const val CANONICAL_ID = "id:mac-1"
        const val PIN =
            "aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22"
    }
}
