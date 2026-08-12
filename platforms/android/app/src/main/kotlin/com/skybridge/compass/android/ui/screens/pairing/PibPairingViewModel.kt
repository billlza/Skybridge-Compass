package com.skybridge.compass.android.ui.screens.pairing

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.android.remote.mac.LanRemotePeer
import com.skybridge.compass.core.p2p.FormalLanPairingCandidate
import com.skybridge.compass.core.p2p.FormalLanPeerAction
import com.skybridge.compass.core.p2p.FormalLanPeerCoordinator
import com.skybridge.compass.core.p2p.FormalLanPeerException
import com.skybridge.compass.core.p2p.FormalLanPeerFailureReason
import com.skybridge.compass.core.p2p.FormalLanPeerSnapshot
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Presentation orchestration for PIB SAS followed by durable signed LAN KEM refresh. */
@HiltViewModel
class PibPairingViewModel @Inject constructor(
    identity: LocalP2PIdentity,
    private val coordinator: FormalLanPeerCoordinator
) : ViewModel() {

    data class PairingPeerItem(
        val peer: LanRemotePeer,
        val action: FormalLanPeerAction,
        val enabled: Boolean
    )

    sealed interface PairingUiState {
        data object Idle : PairingUiState
        data class Exchanging(val macName: String) : PairingUiState
        data class Refreshing(val macName: String) : PairingUiState
        data class Completing(val macName: String) : PairingUiState
        data class AwaitingConfirmation(
            val macName: String,
            val macDeviceId: String,
            val sasCode: String,
            val macFingerprint: String,
            val macSigningAlgorithm: String
        ) : PairingUiState
        data class Trusted(
            val macName: String,
            val peer: LanRemotePeer,
            val connectNow: Boolean
        ) : PairingUiState
        data class RefreshPending(
            val macName: String,
            val peerId: String,
            val message: String
        ) : PairingUiState
        data class ReadyButRouteChanged(
            val macName: String,
            val message: String
        ) : PairingUiState
        data class LocalTrustRecovery(
            val macName: String,
            val peerId: String,
            val rollbackConfirmed: Boolean,
            val message: String
        ) : PairingUiState
        data class Failed(val message: String) : PairingUiState
    }

    private val _state = MutableStateFlow<PairingUiState>(PairingUiState.Idle)
    val state: StateFlow<PairingUiState> = _state.asStateFlow()
    private val _peerItems = MutableStateFlow<List<PairingPeerItem>>(emptyList())
    val peerItems: StateFlow<List<PairingPeerItem>> = _peerItems.asStateFlow()
    val localName: String = identity.deviceName()

    @Volatile
    private var peersById: Map<String, LanRemotePeer> = emptyMap()
    private var peerInspectionGeneration = 0L
    private var inspectionJob: Job? = null
    private var operationJob: Job? = null
    private var pairingCandidate: FormalLanPairingCandidate? = null

    fun updateDiscoveredDevices(devices: List<DiscoveredDevice>) {
        val peers = devices
            .asSequence()
            .filter { it.type == DeviceType.MACOS }
            .mapNotNull(LanRemotePeer::fromDiscoveredDevice)
            .filter { it.formalSnapshot != null }
            .groupBy { it.id }
            .values
            .mapNotNull { sameIdPeers -> sameIdPeers.singleOrNull() }
            .sortedBy { it.name.lowercase() }
        peersById = peers.associateBy { it.id }
        _peerItems.value = emptyList()
        inspectionJob?.cancel()
        check(peerInspectionGeneration != Long.MAX_VALUE) { "pairing peer inspection exhausted" }
        val generation = ++peerInspectionGeneration
        inspectionJob = viewModelScope.launch {
            val inspected = peers.map { peer ->
                val inspection = coordinator.inspect(requireNotNull(peer.formalSnapshot))
                PairingPeerItem(
                    peer = peer,
                    action = inspection.action,
                    enabled = inspection.action != FormalLanPeerAction.BLOCKED
                )
            }
            if (peerInspectionGeneration == generation) {
                _peerItems.value = inspected.filter { item ->
                    peersById[item.peer.id]?.sameSecuritySnapshot(item.peer) == true
                }
            }
        }
    }

    fun startOrRefresh(peerId: String) {
        if (operationJob?.isActive == true) return
        val peer = peersById[peerId] ?: return
        val expectedSnapshot = peer.formalSnapshot ?: return
        pairingCandidate = null
        operationJob = viewModelScope.launch {
            try {
                val inspection = coordinator.inspect(expectedSnapshot)
                when (inspection.action) {
                    FormalLanPeerAction.PAIR -> {
                        _state.value = PairingUiState.Exchanging(peer.name)
                        val candidate = coordinator.requestPairing(
                            expectedPeer = expectedSnapshot,
                            currentPeer = { currentSnapshot(peer.id) }
                        )
                        pairingCandidate = candidate
                        _state.value = PairingUiState.AwaitingConfirmation(
                            macName = candidate.macName,
                            macDeviceId = candidate.macDeviceId,
                            sasCode = candidate.sasCode,
                            macFingerprint = candidate.macFingerprint,
                            macSigningAlgorithm = candidate.macSigningAlgorithm
                        )
                    }
                    FormalLanPeerAction.REFRESH_AND_CONNECT -> {
                        _state.value = PairingUiState.Refreshing(peer.name)
                        val ready = coordinator.refreshAndAuthorize(
                            expectedPeer = expectedSnapshot,
                            currentPeer = { currentSnapshot(peer.id) }
                        )
                        publishReadyState(peer.id, peer.name, ready.peer)
                    }
                    FormalLanPeerAction.BLOCKED -> throw FormalLanPeerException(
                        inspection.failureReason
                            ?: FormalLanPeerFailureReason.ACTIVE_AUTHENTICATED_PIN_REQUIRED
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: FormalLanPeerException) {
                _state.value = PairingUiState.Failed(failureMessage(e.reason))
            } catch (_: Exception) {
                _state.value = PairingUiState.Failed("Pairing could not be completed.")
            }
        }
    }

    fun confirmSasMatches() {
        if (operationJob?.isActive == true) return
        val current = _state.value as? PairingUiState.AwaitingConfirmation ?: return
        val candidate = pairingCandidate ?: return
        _state.value = PairingUiState.Completing(current.macName)
        operationJob = viewModelScope.launch {
            try {
                val ready = coordinator.confirmPairingAndRefresh(
                    candidate = candidate,
                    currentPeer = { currentSnapshot(candidate.discoveryPeerKey) }
                )
                pairingCandidate = null
                publishReadyState(
                    discoveryPeerId = candidate.discoveryPeerKey,
                    fallbackName = current.macName,
                    readyPeer = ready.peer
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: FormalLanPeerException) {
                _state.value = when {
                    e.durablePibReceiptObtained -> PairingUiState.RefreshPending(
                        macName = current.macName,
                        peerId = candidate.discoveryPeerKey,
                        message = failureMessage(e.reason)
                    )
                    e.pibFinalAckVerified -> PairingUiState.LocalTrustRecovery(
                        macName = current.macName,
                        peerId = candidate.discoveryPeerKey,
                        rollbackConfirmed = e.localTrustRollbackConfirmed == true,
                        message = if (e.localTrustRollbackConfirmed == true) {
                            "The Mac accepted the PIB confirmation, but Android did not store " +
                                "the pin. Retry the complete SAS flow."
                        } else {
                            "The Mac accepted the PIB confirmation, but Android's local trust " +
                                "state is uncertain. Remote control remains blocked."
                        }
                    )
                    else -> PairingUiState.Failed(failureMessage(e.reason))
                }
            } catch (_: Exception) {
                _state.value = PairingUiState.Failed("Pairing could not be completed.")
            }
        }
    }

    fun rejectSas() {
        operationJob?.cancel()
        operationJob = null
        pairingCandidate = null
        _state.value = PairingUiState.Idle
    }

    fun retrySignedRefresh(peerId: String) {
        _state.value = PairingUiState.Idle
        startOrRefresh(peerId)
    }

    fun retryFullPairing(peerId: String) {
        pairingCandidate = null
        _state.value = PairingUiState.Idle
        startOrRefresh(peerId)
    }

    fun reset() {
        operationJob?.cancel()
        operationJob = null
        pairingCandidate = null
        _state.value = PairingUiState.Idle
    }

    private fun currentPeer(peerId: String): LanRemotePeer? = peersById[peerId]
    private fun currentSnapshot(peerId: String) = currentPeer(peerId)?.formalSnapshot

    private fun publishReadyState(
        discoveryPeerId: String,
        fallbackName: String,
        readyPeer: FormalLanPeerSnapshot
    ) {
        val current = currentPeer(discoveryPeerId)?.takeIf { peer ->
            peer.formalSnapshot?.let(readyPeer::sameSecuritySnapshot) == true
        }
        _state.value = if (current == null) {
            PairingUiState.ReadyButRouteChanged(
                macName = fallbackName,
                message = "Identity pairing and the signed X-Wing key are durable. " +
                    "The Mac's Bonjour route changed; rescan before connecting."
            )
        } else {
            PairingUiState.Trusted(
                macName = current.name,
                peer = current,
                connectNow = true
            )
        }
    }

    private fun failureMessage(reason: FormalLanPeerFailureReason): String = when (reason) {
        FormalLanPeerFailureReason.DISCOVERY_ROUTE_CHANGED ->
            "The Mac's Bonjour routes changed. Scan again before pairing."
        FormalLanPeerFailureReason.CANONICAL_AUTHORITY_BLOCKED ->
            "This Mac's existing trust record is revoked or requires reverification."
        FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH ->
            "The discovered Mac identity does not match the approved identity."
        FormalLanPeerFailureReason.TRUST_STORE_CORRUPTED ->
            "The trusted-peer store is corrupted; pairing was blocked."
        FormalLanPeerFailureReason.KEM_PERSISTENCE_FAILED ->
            "The signed post-quantum keys could not be saved durably."
        FormalLanPeerFailureReason.LOCAL_TRUST_PERSISTENCE_FAILED ->
            "The Mac accepted the confirmation, but local trust persistence failed."
        FormalLanPeerFailureReason.X_WING_REQUIRED ->
            "The Mac did not provide a verified X-Wing key required for this connection."
        FormalLanPeerFailureReason.REFRESH_FAILED ->
            "Signed post-quantum key refresh failed."
        else -> "Pairing could not be completed securely."
    }
}
