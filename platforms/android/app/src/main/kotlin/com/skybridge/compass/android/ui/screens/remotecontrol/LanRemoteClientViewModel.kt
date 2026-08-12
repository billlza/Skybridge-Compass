package com.skybridge.compass.android.ui.screens.remotecontrol

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsSource
import com.skybridge.compass.android.discovery.ProductSessionActionGate
import com.skybridge.compass.android.discovery.ProductActionGateDecision
import com.skybridge.compass.android.discovery.ProductActionGateTarget
import com.skybridge.compass.android.discovery.ProductRemoteDesktopDecision
import com.skybridge.compass.android.discovery.userMessage
import com.skybridge.compass.android.remote.mac.LanRemotePeer
import com.skybridge.compass.android.remote.mac.MacRemoteControlClient
import com.skybridge.compass.android.remote.mac.MacRemoteControlClientFactory
import com.skybridge.compass.android.remote.mac.MacRemoteFormalRouteAuthorizationLease
import com.skybridge.compass.android.remote.mac.RemoteKeyIntent
import com.skybridge.compass.android.remote.mac.RemoteKeyboardInputMapper
import com.skybridge.compass.core.p2p.FormalLanReadyAuthorization
import com.skybridge.compass.core.p2p.FormalLanPeerCoordinator
import com.skybridge.compass.core.p2p.FormalLanPeerException
import com.skybridge.compass.core.p2p.FormalLanPeerFailureReason
import com.skybridge.compass.core.webrtc.RemoteViewerStatus
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.usecases.StartDeviceDiscoveryUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject

@HiltViewModel
class LanRemoteClientViewModel @Inject constructor(
    private val startDeviceDiscovery: StartDeviceDiscoveryUseCase,
    private val productActionGate: ProductSessionActionGate,
    private val formalLanCoordinator: FormalLanPeerCoordinator,
    private val remoteControlClientFactory: MacRemoteControlClientFactory,
    securitySettingsSource: SecuritySettingsSource
) : ViewModel() {

    private val _peers = MutableStateFlow<List<LanRemotePeer>>(emptyList())
    val peers: StateFlow<List<LanRemotePeer>> = _peers.asStateFlow()

    private val _discoveryError = MutableStateFlow<String?>(null)
    val discoveryError: StateFlow<String?> = _discoveryError.asStateFlow()

    private val _actionGateError = MutableStateFlow<String?>(null)
    val actionGateError: StateFlow<String?> = _actionGateError.asStateFlow()

    private val _preDialPeerId = MutableStateFlow<String?>(null)
    val preDialPeerId: StateFlow<String?> = _preDialPeerId.asStateFlow()
    private val _activePeerState = MutableStateFlow<LanRemotePeer?>(null)
    val activePeerState: StateFlow<LanRemotePeer?> = _activePeerState.asStateFlow()
    val securitySettings: StateFlow<SecuritySettings> = securitySettingsSource.observe()
        .stateIn(viewModelScope, SharingStarted.Eagerly, SecuritySettings())

    private val clientHolder = MutableStateFlow<MacRemoteControlClient?>(null)
    val remoteState: StateFlow<MacRemoteControlClient.State> = clientHolder
        .switchTo(MacRemoteControlClient.State.Disconnected) { it.state }
        .stateIn(viewModelScope, SharingStarted.Eagerly, MacRemoteControlClient.State.Disconnected)
    val latestFrame: StateFlow<MacRemoteControlClient.Frame?> = clientHolder
        .switchTo(null) { it.latestFrame }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)
    val securityState: StateFlow<MacRemoteControlClient.SecurityState> = clientHolder
        .switchTo(MacRemoteControlClient.SecurityState.Disconnected) { it.securityState }
        .stateIn(
            viewModelScope,
            SharingStarted.Eagerly,
            MacRemoteControlClient.SecurityState.Disconnected
        )
    val viewerStatus: StateFlow<RemoteViewerStatus> = clientHolder
        .switchTo(RemoteViewerStatus.Idle) { it.viewerStatus }
        .stateIn(viewModelScope, SharingStarted.Eagerly, RemoteViewerStatus.Idle)

    private val attemptLock = Any()
    private var attemptToken = 0L
    private var connectJob: Job? = null
    private var clientOwnerToken: Long? = null
    private var activeClient: MacRemoteControlClient? = null
    private var activePeer: LanRemotePeer? = null
    private var activeRouteAuthorizationLease: LanRemoteRouteAuthorizationLease? = null
    private var activeLeftPointerOwnerToken: Long? = null
    private var discoveryJob: Job? = null

    private sealed interface PreparedRemoteAuthorization {
        data class ExistingSession(
            val authorization: ProductActionGateDecision.Allowed,
            val pinnedProtocolFingerprint: String
        ) : PreparedRemoteAuthorization
        data class FormalBootstrap(
            val authorization: FormalLanReadyAuthorization
        ) : PreparedRemoteAuthorization
    }

    private class RemoteGateDeniedException(
        val messageForUser: String
    ) : Exception(messageForUser)

    private data class InvalidatedRemoteInputOwner(
        val job: Job?,
        val client: MacRemoteControlClient?
    ) {
        fun terminate() {
            job?.cancel()
            client?.disconnect()
        }
    }

    init {
        refresh()
    }

    fun refresh() {
        discoveryJob?.cancel()
        val staleOwner = synchronized(attemptLock) {
            publishPeersLocked(emptyList())
        }
        staleOwner?.terminate()
        cancelPreDialForDiscoveryRefresh()
        discoveryJob = viewModelScope.launch {
            _discoveryError.value = null
            val discoveryFlow = runCatching {
                startDeviceDiscovery(protocols = setOf(DiscoveryProtocol.BONJOUR))
            }.getOrElse { error ->
                synchronized(attemptLock) { publishPeersLocked(emptyList()) }
                    ?.terminate()
                _discoveryError.value = discoveryErrorMessage(error)
                return@launch
            }

            discoveryFlow
                .catch { error ->
                    synchronized(attemptLock) { publishPeersLocked(emptyList()) }
                        ?.terminate()
                    _discoveryError.value = discoveryErrorMessage(error)
                }
                .collect { devices ->
                    val currentPeers = devices
                        .mapNotNull(LanRemotePeer::fromDiscoveredDevice)
                        .groupBy { it.id }
                        .values
                        .mapNotNull { sameIdPeers -> sameIdPeers.singleOrNull() }
                    val invalidatedOwner = synchronized(attemptLock) {
                        publishPeersLocked(currentPeers)
                    }
                    invalidatedOwner?.terminate()
                }
        }
    }

    fun connect(peer: LanRemotePeer) {
        val token: Long
        val previousJob: Job?
        val previousClient: MacRemoteControlClient?
        synchronized(attemptLock) {
            val clientBusy = when (activeClient?.state?.value) {
                is MacRemoteControlClient.State.Connecting,
                is MacRemoteControlClient.State.Connected -> true
                else -> false
            }
            if (
                activePeer?.sameSecuritySnapshot(peer) == true &&
                (connectJob?.isActive == true || clientBusy)
            ) {
                return
            }
            check(attemptToken != Long.MAX_VALUE) { "LAN remote attempt token exhausted" }
            token = ++attemptToken
            previousJob = connectJob
            previousClient = activeClient
            activeRouteAuthorizationLease?.revoke()
            activeRouteAuthorizationLease = null
            connectJob = null
            activeClient = null
            clientOwnerToken = null
            activeLeftPointerOwnerToken = null
            activePeer = peer
            _activePeerState.value = peer
            clientHolder.value = null
            _actionGateError.value = null
            _preDialPeerId.value = peer.id
        }
        previousJob?.cancel()
        previousClient?.disconnect()

        val job = viewModelScope.launch {
            try {
                val prepared = when (val decision = remoteDecision(peer)) {
                    is ProductRemoteDesktopDecision.ExistingProductSession -> {
                        val durableAuthorization = peer.formalSnapshot?.let { formalPeer ->
                            formalLanCoordinator.authorizeRemoteConnect(
                                expectedPeer = formalPeer,
                                currentPeer = { currentPeerSnapshot(peer.id) }
                            ).pinnedProtocolFingerprint
                        } ?: formalLanCoordinator.authorizeDurableProductSessionRoute(
                            deviceId = peer.id,
                            advertisedProtocolFingerprint =
                            peer.remoteDesktopEndpoint.advertisedProtocolFingerprint
                        ).pinnedProtocolFingerprint
                        PreparedRemoteAuthorization.ExistingSession(
                            authorization = decision.authorization,
                            pinnedProtocolFingerprint = durableAuthorization
                        )
                    }
                    ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap -> {
                        val formal = peer.formalSnapshot
                            ?: throw RemoteGateDeniedException(
                                "The peer has no current formal LAN bootstrap route."
                            )
                        PreparedRemoteAuthorization.FormalBootstrap(
                            formalLanCoordinator.authorizeRemoteConnect(
                                expectedPeer = formal,
                                currentPeer = { currentPeerSnapshot(peer.id) }
                            )
                        )
                    }
                    is ProductRemoteDesktopDecision.Denied ->
                        throw RemoteGateDeniedException(decision.reason.userMessage())
                }
                val current = currentPeer(peer.id)
                    ?.takeIf { peer.sameSecuritySnapshot(it) }
                    ?: throw FormalLanPeerException(
                        FormalLanPeerFailureReason.DISCOVERY_ROUTE_CHANGED
                    )

                val routeTarget = current.toProductActionGateTarget()
                val routeAuthorizationLease = LanRemoteRouteAuthorizationLease {
                    val currentRoute = currentPeer(current.id)
                    currentRoute?.sameSecuritySnapshot(current) == true && when (prepared) {
                        is PreparedRemoteAuthorization.ExistingSession ->
                            productActionGate.isRemoteDesktopAuthorizationCurrent(
                                target = routeTarget,
                                expected = prepared.authorization
                            )
                        is PreparedRemoteAuthorization.FormalBootstrap -> true
                    }
                }
                val client = remoteControlClientFactory.createFormalLanAcceptance(
                    routeAuthorizationLease
                )
                var startFailure: Exception? = null
                val installedAndStarted = synchronized(attemptLock) {
                    val finalPeer = currentPeer(current.id)
                    val finalDecision = finalPeer?.let(::remoteDecision)
                    val authorizationStillCurrent = when (prepared) {
                        is PreparedRemoteAuthorization.ExistingSession ->
                            (finalDecision as? ProductRemoteDesktopDecision.ExistingProductSession)
                                ?.authorization == prepared.authorization
                        is PreparedRemoteAuthorization.FormalBootstrap ->
                            finalDecision == ProductRemoteDesktopDecision.RequiresTrustedLanBootstrap &&
                                finalPeer.formalSnapshot?.let {
                                    prepared.authorization.peer.sameSecuritySnapshot(it)
                                } == true
                    }
                    if (
                        attemptToken != token ||
                        activePeer?.sameSecuritySnapshot(current) != true ||
                        finalPeer?.sameSecuritySnapshot(current) != true ||
                        !authorizationStillCurrent
                    ) {
                        false
                    } else {
                        val ownedFinalPeer = requireNotNull(finalPeer)
                        activeClient = client
                        clientOwnerToken = token
                        activeRouteAuthorizationLease?.revoke()
                        activeRouteAuthorizationLease = routeAuthorizationLease
                        activePeer = current
                        _activePeerState.value = current
                        clientHolder.value = client
                        _preDialPeerId.value = null
                        try {
                            val pinnedFingerprint = when (prepared) {
                                is PreparedRemoteAuthorization.ExistingSession ->
                                    prepared.pinnedProtocolFingerprint
                                is PreparedRemoteAuthorization.FormalBootstrap ->
                                    prepared.authorization.pinnedProtocolFingerprint
                            }
                            client.connect(
                                target = MacRemoteControlClient.ConnectionTarget(
                                    host = ownedFinalPeer.remoteDesktopEndpoint.hostAddress,
                                    port = ownedFinalPeer.remoteDesktopEndpoint.port,
                                    displayName = ownedFinalPeer.name,
                                    deviceIdHint = ownedFinalPeer.id,
                                    advertisedFingerprint = pinnedFingerprint,
                                    advertisedFingerprintTrustSource =
                                        MacRemoteControlClient.FingerprintTrustSource.TRUSTED_CONFIGURATION
                                ),
                                enableHandshake = true,
                                securityConfig = MacRemoteControlClient.SecurityConfig
                                    .formalLanAcceptance()
                            )
                        } catch (error: Exception) {
                            startFailure = error
                        }
                        true
                    }
                }
                if (!installedAndStarted) {
                    routeAuthorizationLease.revoke()
                    client.disconnect()
                    return@launch
                }
                if (startFailure != null) {
                    failAttempt(token, "The formal LAN client could not be started.")
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: FormalLanPeerException) {
                failAttempt(token, formalFailureMessage(e.reason))
            } catch (e: RemoteGateDeniedException) {
                failAttempt(token, e.messageForUser)
            } catch (_: IllegalArgumentException) {
                failAttempt(token, "The resolved LAN route is no longer valid.")
            } catch (_: Exception) {
                failAttempt(token, "The formal LAN connection failed before dialing.")
            }
        }
        synchronized(attemptLock) {
            if (attemptToken == token && activePeer?.sameSecuritySnapshot(peer) == true) {
                connectJob = job
            } else {
                job.cancel()
            }
        }
    }

    fun disconnect() {
        val job: Job?
        val client: MacRemoteControlClient?
        synchronized(attemptLock) {
            check(attemptToken != Long.MAX_VALUE) { "LAN remote attempt token exhausted" }
            attemptToken += 1L
            job = connectJob
            client = activeClient
            // A normal user disconnect removes the UI owner immediately, but the client retains its
            // still-current route lease long enough to flush only already-pressed compensating Up
            // events before closing. Route replacement/failure paths revoke instead.
            activeRouteAuthorizationLease = null
            connectJob = null
            activeClient = null
            clientOwnerToken = null
            activeLeftPointerOwnerToken = null
            activePeer = null
            _activePeerState.value = null
            clientHolder.value = null
            _preDialPeerId.value = null
        }
        job?.cancel()
        client?.disconnect()
    }

    fun hasSecureChannel(): Boolean = synchronized(attemptLock) {
        currentOwnedClientLocked()?.hasSecureChannel() == true
    }

    fun onDecoderError(detail: String?) {
        runLinearizedLanRemoteOwnerAction(
            lock = attemptLock,
            ownedValue = ::currentOwnedClientLocked
        ) { it.onDecoderError(detail) }
    }

    fun sendMouseMove(x: Double, y: Double) {
        runAuthorizedInput { it.sendMouseMove(x, y) }
    }

    fun sendLeftDown(x: Double, y: Double) {
        runLinearizedLanRemoteOwnerAction(
            lock = attemptLock,
            ownedValue = ::currentAuthorizedInputClientLocked
        ) { client ->
            if (activeLeftPointerOwnerToken != attemptToken) {
                client.sendLeftDown(x, y)
                activeLeftPointerOwnerToken = attemptToken
            }
        }
    }

    fun sendLeftUp(x: Double, y: Double) {
        // A control-policy transition may cancel an already-started gesture. Permit only its Up
        // release while the exact owner, secure session, and route lease remain current.
        runLinearizedLanRemoteOwnerAction(
            lock = attemptLock,
            ownedValue = {
                currentRouteAuthorizedInputClientLocked()
                    ?.takeIf { activeLeftPointerOwnerToken == attemptToken }
            }
        ) { client ->
            client.sendLeftUp(x, y)
            activeLeftPointerOwnerToken = null
        }
    }

    fun sendScrollUp(x: Double, y: Double) {
        runAuthorizedInput { it.sendScrollUp(x, y) }
    }

    fun sendScrollDown(x: Double, y: Double) {
        runAuthorizedInput { it.sendScrollDown(x, y) }
    }

    internal fun sendKeyStroke(intent: RemoteKeyIntent) {
        val keyCode = RemoteKeyboardInputMapper.toMacVirtualKeyCode(intent)
        runAuthorizedInput { client -> client.sendKeyStroke(keyCode) }
    }

    override fun onCleared() {
        discoveryJob?.cancel()
        disconnect()
    }

    private fun currentPeer(peerId: String): LanRemotePeer? =
        _peers.value.singleOrNull { it.id == peerId }

    private fun currentPeerSnapshot(peerId: String) = currentPeer(peerId)?.formalSnapshot

    private fun cancelPreDialForDiscoveryRefresh() {
        val staleJob = synchronized(attemptLock) {
            if (_preDialPeerId.value == null || activeClient != null) return
            check(attemptToken != Long.MAX_VALUE) { "LAN remote attempt token exhausted" }
            attemptToken += 1L
            val job = connectJob
            activeRouteAuthorizationLease?.revoke()
            activeRouteAuthorizationLease = null
            connectJob = null
            activePeer = null
            _activePeerState.value = null
            _preDialPeerId.value = null
            job
        }
        staleJob?.cancel()
    }

    private fun remoteDecision(peer: LanRemotePeer): ProductRemoteDesktopDecision =
        productActionGate.decideRemoteDesktop(
            target = peer.toProductActionGateTarget(),
            formalPeer = peer.formalSnapshot
        )

    private fun LanRemotePeer.toProductActionGateTarget(): ProductActionGateTarget =
        ProductActionGateTarget(
            serviceType = remoteDesktopEndpoint.serviceType,
            instanceName = remoteDesktopEndpoint.instanceName,
            host = remoteDesktopEndpoint.hostAddress,
            port = remoteDesktopEndpoint.port,
            routeProvenance = com.skybridge.compass.discovery.data.interop
                .AppleBonjourEndpointProvenance.valueOf(remoteDesktopEndpoint.routeProvenance),
            deviceIdHint = remoteDesktopEndpoint.advertisedDeviceId,
            advertisedFingerprint = remoteDesktopEndpoint.advertisedProtocolFingerprint
        )

    private fun failAttempt(token: Long, message: String) {
        val client = synchronized(attemptLock) {
            if (attemptToken != token) return
            val owned = currentOwnedClientLocked()
            _preDialPeerId.value = null
            _actionGateError.value = message
            activePeer = null
            _activePeerState.value = null
            connectJob = null
            activeClient = null
            clientOwnerToken = null
            activeLeftPointerOwnerToken = null
            activeRouteAuthorizationLease?.revoke()
            activeRouteAuthorizationLease = null
            clientHolder.value = null
            owned
        }
        client?.disconnect()
    }

    private fun discoveryErrorMessage(error: Throwable): String =
        "Bonjour discovery failed (${error.javaClass.simpleName})."

    private fun formalFailureMessage(reason: FormalLanPeerFailureReason): String = when (reason) {
        FormalLanPeerFailureReason.DISCOVERY_ROUTE_CHANGED ->
            "The peer's Bonjour route changed before the secure connection started."
        FormalLanPeerFailureReason.ACTIVE_AUTHENTICATED_PIN_REQUIRED ->
            "Pair this peer with SAS before remote control."
        FormalLanPeerFailureReason.ADVERTISED_PIN_MISMATCH ->
            "The discovered identity no longer matches the approved peer."
        FormalLanPeerFailureReason.TRUST_STORE_CORRUPTED ->
            "The trusted-peer store is corrupted; remote control was blocked."
        FormalLanPeerFailureReason.KEM_PERSISTENCE_FAILED ->
            "Verified post-quantum key material could not be read durably."
        FormalLanPeerFailureReason.X_WING_REQUIRED ->
            "This formal LAN connection requires a verified X-Wing key."
        FormalLanPeerFailureReason.REFRESH_FAILED ->
            "Signed post-quantum key refresh failed."
        else -> "The formal LAN connection was blocked."
    }

    private fun currentOwnedClientLocked(): MacRemoteControlClient? =
        activeClient?.takeIf { clientOwnerToken == attemptToken }

    private fun currentAuthorizedInputClientLocked(): MacRemoteControlClient? =
        currentRouteAuthorizedInputClientLocked()?.takeIf {
            securitySettings.value.allowRemoteControl
        }

    private fun currentRouteAuthorizedInputClientLocked(): MacRemoteControlClient? =
        currentOwnedClientLocked()?.takeIf { client ->
            activeRouteAuthorizationLease?.isCurrent() == true && client.hasSecureChannel()
        }

    private fun publishPeersLocked(peers: List<LanRemotePeer>): InvalidatedRemoteInputOwner? {
        val ownedPeer = activePeer
        val routeChanged =
            ownedPeer != null &&
            peers.singleOrNull { it.id == ownedPeer.id }
                ?.sameSecuritySnapshot(ownedPeer) != true
        val invalidatedOwner = if (routeChanged) {
            check(attemptToken != Long.MAX_VALUE) { "LAN remote attempt token exhausted" }
            attemptToken += 1L
            val invalidated = InvalidatedRemoteInputOwner(
                job = connectJob,
                client = activeClient
            )
            activeRouteAuthorizationLease?.revoke()
            activeRouteAuthorizationLease = null
            connectJob = null
            activeClient = null
            clientOwnerToken = null
            activeLeftPointerOwnerToken = null
            activePeer = null
            _activePeerState.value = null
            clientHolder.value = null
            _preDialPeerId.value = null
            _actionGateError.value = formalFailureMessage(
                FormalLanPeerFailureReason.DISCOVERY_ROUTE_CHANGED
            )
            invalidated
        } else {
            null
        }
        _peers.value = peers
        return invalidatedOwner
    }

    private fun runAuthorizedInput(action: (MacRemoteControlClient) -> Unit) {
        runLinearizedLanRemoteOwnerAction(
            lock = attemptLock,
            ownedValue = ::currentAuthorizedInputClientLocked,
            action = action
        )
    }

    private fun <T> StateFlow<MacRemoteControlClient?>.switchTo(
        default: T,
        selector: (MacRemoteControlClient) -> Flow<T>
    ): Flow<T> = channelFlow {
        this@switchTo.collectLatest { client ->
            if (client == null) {
                send(default)
            } else {
                selector(client).collect { value -> send(value) }
            }
        }
    }
}

/** Runs a non-suspending owner action in the same critical section as owner replacement. */
internal fun <T> runLinearizedLanRemoteOwnerAction(
    lock: Any,
    ownedValue: () -> T?,
    action: (T) -> Unit
): Boolean = synchronized(lock) {
    val owned = ownedValue() ?: return@synchronized false
    action(owned)
    true
}

/** Lock-free revocation prevents client commit locks from calling back into the ViewModel lock. */
internal class LanRemoteRouteAuthorizationLease(
    private val externalAuthorizationCurrent: () -> Boolean
) : MacRemoteFormalRouteAuthorizationLease {
    private val current = AtomicBoolean(true)

    override fun isCurrent(): Boolean =
        current.get() && externalAuthorizationCurrent() && current.get()

    fun revoke() {
        current.set(false)
    }
}
