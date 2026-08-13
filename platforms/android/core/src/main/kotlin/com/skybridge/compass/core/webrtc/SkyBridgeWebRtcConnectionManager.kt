package com.skybridge.compass.core.webrtc

import android.content.Context
import android.os.Build
import android.util.Base64
import com.skybridge.compass.core.data.NetworkEndpointPolicy
import com.skybridge.compass.core.data.NetworkSettings
import com.skybridge.compass.core.data.NetworkSettingsStore
import com.skybridge.compass.core.network.ConnectionEstablishmentDeadline
import com.skybridge.compass.core.p2p.AppMessage
import com.skybridge.compass.core.p2p.AppMessageCodec
import com.skybridge.compass.core.p2p.AuthenticatedPairingBindingNormalization
import com.skybridge.compass.core.p2p.AuthenticatedPairingPartialPersistenceException
import com.skybridge.compass.core.p2p.AuthenticatedPairingPersistence
import com.skybridge.compass.core.p2p.AuthenticatedPairingPersistenceOutcome
import com.skybridge.compass.core.p2p.AuthenticatedPairingPersistenceResult
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.p2p.PairingTrustDecision
import com.skybridge.compass.core.p2p.PairingTrustConflict
import com.skybridge.compass.core.p2p.PairingTrustManager
import com.skybridge.compass.core.p2p.PairingTrustRequest
import com.skybridge.compass.core.p2p.PeerKemKeyStore
import com.skybridge.compass.core.p2p.PeerKemKeyStoreCorruptionException
import com.skybridge.compass.core.p2p.PeerKemKeyStorePersistenceException
import com.skybridge.compass.core.p2p.PeerKemKeyStoreRecords
import com.skybridge.compass.core.p2p.PeerKemPublicKeyValidation
import com.skybridge.compass.core.p2p.SwiftDateSeconds
import com.skybridge.compass.core.p2p.TrustedPeerStoreCorruptionException
import com.skybridge.compass.core.p2p.TrustedPeerStorePersistenceException
import com.skybridge.compass.core.p2p.forTrustedClassicBootstrap
import com.skybridge.compass.core.p2p.isMissingPqcMaterial
import com.skybridge.compass.core.p2p.isPeerPinned
import com.skybridge.compass.core.p2p.toWirePolicy
import com.skybridge.compass.shared.account.NebulaId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import com.skybridge.compass.shared.p2p.HandshakePaddingP1
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PHandshakeClient
import com.skybridge.compass.shared.p2p.P2PHandshakeServer
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PIdentityPublicKeys
import com.skybridge.compass.shared.p2p.P2PProtocolSigningKeys
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import com.skybridge.compass.shared.p2p.QPeriaptPlatformPolicy
import com.skybridge.compass.shared.p2p.TrafficPaddingP2
import com.skybridge.compass.shared.platform.AndroidPlatformMetadata
import com.skybridge.compass.shared.productsession.ProductSessionAuthorityStore
import com.skybridge.compass.shared.productsession.ProductSessionMutationResult
import com.skybridge.compass.shared.productsession.ProductSessionOwner
import com.skybridge.compass.shared.productsession.ProductSessionOwnerClaimResult
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import android.util.Log

internal sealed interface AuthenticatedSessionPeerKemLookup {
    data object Absent : AuthenticatedSessionPeerKemLookup
    data object RejectedBinding : AuthenticatedSessionPeerKemLookup
    data class Match(
        val keys: PeerKemKeyStore.PeerKemPublicKeys
    ) : AuthenticatedSessionPeerKemLookup
}

internal class AuthenticatedSessionPeerKemBindingException : IllegalStateException(
    "authenticated session KEM material does not match the exact session binding"
)

/**
 * One exact-key-epoch admission marker for the read-only formal lane.
 *
 * The marker is installed only after the remote pairing exchange matches the existing authority
 * and KEM records and the local reply is sent through the same secure-operation capability.
 * Reference identity is intentional: wire messages carry no local generation identifier, so an
 * admission from an earlier key epoch must never authorize a replacement epoch.
 */
internal class ExistingTrustPeerKemAdmissionState {
    private val lock = Any()
    private var sentOwner: WebRtcSecureOperationOwner? = null
    private var sendConfirmed = false
    private var admittedOwner: WebRtcSecureOperationOwner? = null

    fun beginSend(owner: WebRtcSecureOperationOwner) = synchronized(lock) {
        sentOwner = owner
        sendConfirmed = false
        admittedOwner = null
    }

    /**
     * Finish the exact send. A re-entrant peer response is stronger delivery evidence than a
     * false transport return, so an admission that won while the send was in flight is retained.
     */
    fun finishSend(owner: WebRtcSecureOperationOwner, transportDelivered: Boolean): Boolean =
        synchronized(lock) {
            if (sentOwner !== owner) return@synchronized false
            if (transportDelivered) {
                sendConfirmed = true
                return@synchronized true
            }
            if (admittedOwner === owner) {
                sendConfirmed = true
                return@synchronized true
            }
            sentOwner = null
            sendConfirmed = false
            false
        }

    fun isSendConfirmed(owner: WebRtcSecureOperationOwner): Boolean = synchronized(lock) {
        sentOwner === owner && sendConfirmed
    }

    fun wasSentBy(owner: WebRtcSecureOperationOwner): Boolean = synchronized(lock) {
        sentOwner === owner
    }

    fun install(owner: WebRtcSecureOperationOwner) = synchronized(lock) {
        check(sentOwner === owner) {
            "peer-KEM admission requires one exchange sent by the exact key epoch"
        }
        admittedOwner = owner
    }

    fun isCurrent(owner: WebRtcSecureOperationOwner): Boolean = synchronized(lock) {
        admittedOwner === owner
    }

    fun clear() = synchronized(lock) {
        sentOwner = null
        sendConfirmed = false
        admittedOwner = null
    }
}

internal enum class AuthenticatedSessionPeerKemLifecycleEvent {
    OWNER_STARTED,
    DURABLE_MATERIAL_COMMITTED,
    SESSION_DISCONNECTED,
    SESSION_FAILED,
    REKEY_SUCCEEDED,
    REKEY_FAILED
}

/**
 * One manager-local KEM slot for ALLOW_ONCE. The caller must perform every operation while holding
 * the exact [WebRtcSessionOwnerGate] owner. Material in this slot is never merged with persistent
 * or pre-authentication JOIN keys.
 */
internal class AuthenticatedSessionPeerKemStore {
    private data class Binding(
        val owner: ProductSessionOwner,
        val peerIds: Set<String>,
        val protocolFingerprint: String,
        val keys: PeerKemKeyStore.PeerKemPublicKeys
    )

    private val lock = Any()
    private var binding: Binding? = null

    fun install(
        owner: ProductSessionOwner,
        outcome: AuthenticatedPairingPersistenceOutcome
    ) {
        if (outcome.disposition != AuthenticatedPairingPersistenceResult.SESSION_ONLY) {
            throw AuthenticatedSessionPeerKemBindingException()
        }
        val peerIds = outcome.normalizedPeerIds.map { peerId ->
            AuthenticatedPairingBindingNormalization.peerId(peerId)
                ?: throw AuthenticatedSessionPeerKemBindingException()
        }.toSet()
        if (peerIds.isEmpty() || peerIds != outcome.normalizedPeerIds) {
            throw AuthenticatedSessionPeerKemBindingException()
        }
        val protocolFingerprint = AuthenticatedPairingBindingNormalization.protocolFingerprint(
            outcome.observedProtocolFingerprint
        )
        if (protocolFingerprint == null ||
            protocolFingerprint != outcome.observedProtocolFingerprint
        ) {
            throw AuthenticatedSessionPeerKemBindingException()
        }
        val candidate = Binding(
            owner = owner,
            peerIds = peerIds,
            protocolFingerprint = protocolFingerprint,
            keys = validateAndCopy(outcome.validatedKemPublicKeys)
        )
        synchronized(lock) {
            val current = binding
            if (current == null) {
                binding = candidate
            } else if (!current.hasSameBindingAndMaterial(candidate)) {
                throw AuthenticatedSessionPeerKemBindingException()
            }
        }
    }

    fun lookup(
        owner: ProductSessionOwner,
        peerId: String?,
        observedProtocolFingerprint: String?
    ): AuthenticatedSessionPeerKemLookup = synchronized(lock) {
        val current = binding ?: return@synchronized AuthenticatedSessionPeerKemLookup.Absent
        val normalizedPeerId = peerId?.let(AuthenticatedPairingBindingNormalization::peerId)
        val normalizedFingerprint = observedProtocolFingerprint?.let(
            AuthenticatedPairingBindingNormalization::protocolFingerprint
        )
        if (current.owner != owner ||
            normalizedPeerId == null ||
            normalizedPeerId !in current.peerIds ||
            normalizedFingerprint == null ||
            normalizedFingerprint != current.protocolFingerprint
        ) {
            AuthenticatedSessionPeerKemLookup.RejectedBinding
        } else {
            AuthenticatedSessionPeerKemLookup.Match(current.keys.deepCopyPeerKem())
        }
    }

    fun applyLifecycleEvent(
        owner: ProductSessionOwner,
        event: AuthenticatedSessionPeerKemLifecycleEvent
    ): Boolean = synchronized(lock) {
        when (event) {
            AuthenticatedSessionPeerKemLifecycleEvent.OWNER_STARTED -> {
                val current = binding
                if (current == null || current.owner == owner) {
                    false
                } else {
                    binding = null
                    true
                }
            }
            AuthenticatedSessionPeerKemLifecycleEvent.DURABLE_MATERIAL_COMMITTED,
            AuthenticatedSessionPeerKemLifecycleEvent.SESSION_DISCONNECTED,
            AuthenticatedSessionPeerKemLifecycleEvent.SESSION_FAILED,
            AuthenticatedSessionPeerKemLifecycleEvent.REKEY_SUCCEEDED,
            AuthenticatedSessionPeerKemLifecycleEvent.REKEY_FAILED -> {
                if (binding?.owner != owner) {
                    false
                } else {
                    binding = null
                    true
                }
            }
        }
    }

    private fun validateAndCopy(
        keys: PeerKemKeyStore.PeerKemPublicKeys
    ): PeerKemKeyStore.PeerKemPublicKeys {
        try {
            keys.qPeriaptPublicKey?.let { key ->
                PeerKemPublicKeyValidation.validatePublicKey(
                    P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND,
                    key
                )
            }
            keys.xWingPublicKey?.let { key ->
                PeerKemPublicKeyValidation.validatePublicKey(P2PCryptoSuite.X_WING, key)
            }
            keys.mlKem768PublicKey?.let { key ->
                PeerKemPublicKeyValidation.validatePublicKey(P2PCryptoSuite.MLKEM_768, key)
            }
        } catch (_: IllegalArgumentException) {
            throw AuthenticatedSessionPeerKemBindingException()
        }
        if (keys.qPeriaptPublicKey == null &&
            keys.xWingPublicKey == null &&
            keys.mlKem768PublicKey == null
        ) {
            throw AuthenticatedSessionPeerKemBindingException()
        }
        return keys.deepCopyPeerKem()
    }

    private fun Binding.hasSameBindingAndMaterial(other: Binding): Boolean =
        owner == other.owner &&
            peerIds == other.peerIds &&
            protocolFingerprint == other.protocolFingerprint &&
            keys.hasSamePeerKemMaterial(other.keys)
}

internal fun resolveAuthenticatedSessionPeerKemForRekey(
    lookup: AuthenticatedSessionPeerKemLookup,
    persistentLoader: () -> PeerKemKeyStore.PeerKemPublicKeys
): PeerKemKeyStore.PeerKemPublicKeys = when (lookup) {
    AuthenticatedSessionPeerKemLookup.Absent -> persistentLoader()
    AuthenticatedSessionPeerKemLookup.RejectedBinding ->
        throw AuthenticatedSessionPeerKemBindingException()
    is AuthenticatedSessionPeerKemLookup.Match -> lookup.keys.deepCopyPeerKem()
}

private fun PeerKemKeyStore.PeerKemPublicKeys.deepCopyPeerKem() =
    PeerKemKeyStore.PeerKemPublicKeys(
        qPeriaptPublicKey = qPeriaptPublicKey?.copyOf(),
        xWingPublicKey = xWingPublicKey?.copyOf(),
        mlKem768PublicKey = mlKem768PublicKey?.copyOf()
    )

private fun PeerKemKeyStore.PeerKemPublicKeys.hasSamePeerKemMaterial(
    other: PeerKemKeyStore.PeerKemPublicKeys
): Boolean =
    qPeriaptPublicKey.contentEqualsNullable(other.qPeriaptPublicKey) &&
        xWingPublicKey.contentEqualsNullable(other.xWingPublicKey) &&
        mlKem768PublicKey.contentEqualsNullable(other.mlKem768PublicKey)

private fun ByteArray?.contentEqualsNullable(other: ByteArray?): Boolean = when {
    this == null -> other == null
    other == null -> false
    else -> contentEquals(other)
}

/**
 * Minimal connection manager aligning with Pro release CrossNetworkConnectionManager for code-based WebRTC:
 * - sessionId == server-issued connection code
 * - signaling via WebSocketSignalingClient (join/offer/answer/iceCandidate)
 * - DataChannel label "skybridge"
 */
class SkyBridgeWebRtcConnectionManager(
    private val appContext: Context,
    private val networkSettingsOverrideProvider: (suspend () -> NetworkSettings?)? = null,
    private val localIdentityProvider: (() -> LocalP2PIdentity)? = null,
    private val peerKemStoreProvider: (() -> PeerKemKeyStore)? = null,
    private val userAuthContextProvider: (suspend () -> SignalServerClient.UserAuthContext?)? = null,
    private val localBusinessIdentityProvider: (() -> LocalPeerBusinessIdentity?)? = null,
    private val productSessionAuthorityStore: ProductSessionAuthorityStore? = null,
    private val diagnosticsConfig: WebRtcDiagnosticsConfig = WebRtcDiagnosticsConfig(),
    /**
     * 单次连接建立的整体时限门（R4.1 / design §4，任务 9.7）。默认 30s 端到端上限；
     * 时钟可注入，测试可用确定化时钟推进到时限边界而无需真实等待。
     */
    private val establishmentDeadline: ConnectionEstablishmentDeadline =
        ConnectionEstablishmentDeadline()
) {
    sealed class State {
        data object Idle : State()
        data class Waiting(val code: String) : State() {
            override fun toString(): String = "Waiting(code=${redactCode(code)})"
        }

        data class Connecting(val code: String) : State() {
            override fun toString(): String = "Connecting(code=${redactCode(code)})"
        }

        /**
         * The WebRTC DataChannel is open (transport ready), but the secure P2P
         * handshake has NOT yet completed. Inbound application frames are still
         * decrypt-gated in this state. Do NOT treat this as "ready to transfer/control".
         */
        data class Connected(val code: String) : State() {
            override fun toString(): String = "Connected(code=${redactCode(code)})"
        }

        /**
         * The secure P2P handshake has completed and session keys are established.
         * This is the canonical "ready" state: readiness == handshakeComplete.
         * User-facing feature gates (file transfer, remote control entry) MUST
         * require this state, not [Connected].
         */
        data class Established(val code: String) : State() {
            override fun toString(): String = "Established(code=${redactCode(code)})"
        }

        data class Failed(val code: String?, val message: String) : State() {
            override fun toString(): String = "Failed(code=${redactCode(code)}, message=$message)"
        }

        private companion object {
            fun redactCode(code: String?): String {
                val value = code?.trim().orEmpty()
                if (value.isEmpty()) return "null"
                return "<redacted:${value.length}>"
            }
        }
    }

    data class SignalingStatus(
        val sessionId: String? = null,
        val websocketUrl: String = SkyBridgeServerConfig.signalingWebSocketURL,
        val shard: String? = null,
        val peerSignalingId: String? = null,
        val lastEvent: String = "idle"
    )

    private data class CurrentPathRemoteAuthority(
        val deviceId: String,
        val protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val protocolPublicKeyFingerprint: String,
        val deviceName: String? = null
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var signalingUrl: String = SkyBridgeServerConfig.signalingWebSocketURL
    private var signalingShard: String? = null
    private var signalingHeaders: Map<String, String> = emptyMap()
    private var signaling: WebSocketSignalingClient = WebSocketSignalingClient(wsUrlString = signalingUrl)
    private var signalingOwner: ProductSessionOwner? = null
    private val turnService = TURNCredentialService()
    private val lifecycleMutex = Mutex()
    private val pairingIdentityExchangeMutex = Mutex()
    private val sessionOwnerGate = WebRtcSessionOwnerGate()
    private val authenticatedSessionPeerKemStore = AuthenticatedSessionPeerKemStore()
    private val selectedRouteStore = OwnerBoundWebRtcRouteStore()
    private val secureOperationOwnerState = WebRtcSecureOperationOwnerState()
    private val existingTrustPeerKemAdmissionState = ExistingTrustPeerKemAdmissionState()

    private var session: WebRtcSession? = null
    private val localIdentity: LocalP2PIdentity by lazy {
        localIdentityProvider?.invoke() ?: LocalP2PIdentity(appContext)
    }
    private val peerKemStore: PeerKemKeyStore by lazy {
        peerKemStoreProvider?.invoke() ?: PeerKemKeyStore(appContext)
    }
    private val appMessageCodec: AppMessageCodec = AppMessageCodec()
    private val routeBindingConsumer: AuthenticatedRouteBindingConsumer? =
        productSessionAuthorityStore?.let(::AuthenticatedRouteBindingConsumer)

    private var localId: String = defaultDeviceId()
    private var currentSessionId: String? = null
    private var remoteSignalingId: String? = null
    private var remoteDeviceId: String? = null
    private val webrtcSignalingAuthTokenBySessionId = linkedMapOf<String, String>()
    private val currentPathExpectedRemoteAuthorityBySessionId = linkedMapOf<String, CurrentPathRemoteAuthority>()
    private val currentPathSignalingOriginBySessionId = linkedMapOf<String, String>()
    private val currentPathTurnAdmissionTokenBySessionId = linkedMapOf<String, String>()

    /** Pre-authentication JOIN material scoped to the exact in-memory session owner. */
    private data class PendingJoinBootstrapKem(
        val owner: ProductSessionOwner,
        val peerIds: Set<String>,
        val keys: PeerKemKeyStore.PeerKemPublicKeys
    )

    private var pendingJoinBootstrapKem: PendingJoinBootstrapKem? = null

    @Volatile
    private var pqcEnabled: Boolean = true
    @Volatile
    private var handshakePolicyOverride: P2PHandshakePolicyOverride? = null

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()
    val secureOperationOwner: StateFlow<WebRtcSecureOperationOwner?> =
        secureOperationOwnerState.owner

    var onData: ((ByteArray) -> Unit)? = null
    var onPacketData: ((ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null
    var onOwnedData: ((ProductSessionOwner, ByteArray) -> Unit)? = null
    var onOwnedPacketData: ((ProductSessionOwner, ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null
    var onSecurePacketData: ((WebRtcSecureOperationOwner, ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null

    val selectedRouteWitness: StateFlow<WebRtcSelectedRouteWitness?> = selectedRouteStore.witness

    private val _dataChannelConfigStatus =
        MutableStateFlow<WebRtcSession.DataChannelConfigStatus>(WebRtcSession.DataChannelConfigStatus.Unknown)
    val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> = _dataChannelConfigStatus.asStateFlow()
    private val _signalingStatus = MutableStateFlow(
        SignalingStatus(
            websocketUrl = signalingUrl,
            shard = signalingShard,
            lastEvent = "boot"
        )
    )
    val signalingStatus: StateFlow<SignalingStatus> = _signalingStatus.asStateFlow()
    private val _authenticatedPeerMetadata = MutableStateFlow<AuthenticatedPeerMetadata?>(null)
    val authenticatedPeerMetadata: StateFlow<AuthenticatedPeerMetadata?> =
        _authenticatedPeerMetadata.asStateFlow()

    // WebRTC app-layer crypto (derived from P2P v1 handshake over DataChannel)
    private var sessionKeys: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys? = null
    private var negotiatedSuite: P2PCryptoSuite? = null

    // SBWC application-secure envelope state (matches macOS WebRTCAppSecureEnvelope).
    // The outbound counter is monotonic per send-direction and must start at 1 (0 is rejected).
    // It resets whenever the session keys change (initial handshake or rekey) so it tracks the
    // per-(packetType,direction,sessionHash,transcriptPrefix,epoch) replay lanes the peer keeps.
    private var webrtcSecureEnvelopeSendCounter: Long = 0L
    private var webrtcSecureEnvelopeReplayWindow: WebRtcAppSecureEnvelope.ReplayWindow =
        WebRtcAppSecureEnvelope.ReplayWindow()
    // SBWC sessionId is the deterministic id the Mac derives from the transcript hash; cached so
    // sealing app payloads doesn't re-hash on every send.
    private var webrtcSecureEnvelopeSessionId: String? = null

    /**
     * Reset the SBWC envelope counters/replay window/sessionId cache. Called whenever the
     * session keys change (initial handshake or rekey) or the session is torn down, so the
     * outbound counter restarts at 1 and stale replay lanes are dropped — mirroring the Mac's
     * resetWebRTCSecureEnvelopeStateIfNeeded behavior keyed on the session keys.
     */
    private fun resetSecureEnvelopeState() {
        webrtcSecureEnvelopeSendCounter = 0L
        webrtcSecureEnvelopeReplayWindow = WebRtcAppSecureEnvelope.ReplayWindow()
        webrtcSecureEnvelopeSessionId = null
    }

    // Inbound app payloads may carry any SBWC packet type the Mac emits (app-control PIB/clipboard/
    // heartbeat/stream-config, file transfer, remote control, remote-desktop frames + audio).
    private val INBOUND_ALLOWED_PACKET_TYPES: Set<WebRtcAppSecureEnvelope.PacketType> =
        WebRtcAppSecureEnvelope.PacketType.entries.toSet()

    private var initiatorHandshake: Pair<P2PHandshakeClient.InitiatorState, P2PHandshakeClient>? = null
    private var initiatorHandshakePhase: HandshakePhase? = null
    private var initiatorPendingMessageB: ByteArray? = null
    private var initiatorPendingResponderFinished: ByteArray? = null

    private var responderHandshake: Pair<P2PHandshakeServer.ResponderState, P2PHandshakeServer>? = null
    private var responderHandshakePhase: HandshakePhase? = null
    private var responderNegotiatedSuite: com.skybridge.compass.shared.p2p.P2PCryptoSuite? = null
    private var observedHandshakeAuthority: ObservedHandshakeAuthority? = null

    private var pairingExchangeSent: Boolean = false
    private var rekeyInProgress: Boolean = false
    private var rekeyAttempted: Boolean = false
    private var appHeartbeatTask: Job? = null
    private var lastSentPairingExchangeFingerprint: String? = null

    /**
     * 整体连接建立时限的看门狗协程（任务 9.7 / R4.1）。自 [armEstablishmentDeadline] 起计时，
     * 若在 [establishmentDeadline] 的整体上限内会话未被呈现为已建立（应用层会话密钥未建立），
     * 则如实以「超时」失败并经既有 signaling-status 叶节点呈现。会话成功建立、失败或被清理时取消。
     */
    private var establishmentDeadlineTask: Job? = null

    private val inboundFrames = WebRtcDataChannelFraming.Decoder()
    private val framedSender = ExactOwnerWebRtcFramedSender<ProductSessionOwner>(
        runIfCurrentOwner = ::runIfCurrentSession,
        sendChunk = { _, chunk -> session?.send(chunk) == true },
        terminatePartiallyWrittenOwner = ::terminatePartiallyWrittenFramedTransport,
    )

    private enum class HandshakePhase { INITIAL, REKEY }

    private data class ObservedHandshakeAuthority(
        val owner: ProductSessionOwner,
        val protocolFingerprint: String
    )

    private data class PairingPersistenceAttemptSnapshot(
        val observedAuthority: ObservedHandshakeAuthority,
        val priorPeerId: String?,
        val remoteSignalingId: String?,
        val expectedAuthority: CurrentPathRemoteAuthority?
    )

    init {
        bindSignalingCallbacks(owner = null)
        signaling.connect()
    }

    fun setPqcEnabled(enabled: Boolean) {
        pqcEnabled = enabled
    }

    fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?) {
        handshakePolicyOverride = policy
    }

    fun setLocalDeviceId(id: String) {
        localId = id
    }

    private fun runIfCurrentSession(owner: ProductSessionOwner, action: () -> Unit): Boolean =
        sessionOwnerGate.runIfCurrent(owner) {
            check(currentSessionId == owner.sessionId) {
                "WebRTC current session id diverged from its exact owner"
            }
            action()
        }

    private fun requireCurrentSession(owner: ProductSessionOwner) {
        if (!sessionOwnerGate.isCurrent(owner) || currentSessionId != owner.sessionId) {
            throw StaleWebRtcSessionOwnerException()
        }
    }

    private fun <T> withCurrentSecureOperationOwner(
        capability: WebRtcSecureOperationOwner,
        defaultValue: T,
        action: (
            ProductSessionOwner,
            com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys
        ) -> T
    ): T {
        val owner = sessionOwnerGate.current() ?: return defaultValue
        var result = defaultValue
        sessionOwnerGate.runIfCurrent(owner) {
            val keys = sessionKeys
            if (
                currentSessionId == owner.sessionId &&
                _state.value is State.Established &&
                keys != null &&
                secureOperationOwnerState.isCurrent(capability, owner, keys)
            ) {
                result = action(owner, keys)
            }
        }
        return result
    }

    private fun logRejectedAuthorityMutation(
        operation: String,
        owner: ProductSessionOwner,
        result: ProductSessionMutationResult
    ) {
        if (result == ProductSessionMutationResult.APPLIED) return
        Log.w(
            "SB-WEBRTC",
            "$operation rejected session=${redactLogIdentifier(owner.sessionId)} generation=${owner.generation} result=$result"
        )
    }

    private fun publishSessionPreparationFailure(sessionId: String, error: Throwable) {
        val safeMessage = sanitizeErrorMessage(error, "session preparation failed")
        sessionOwnerGate.runIfNoCurrent {
            _state.value = State.Failed(sessionId, safeMessage)
            updateSignalingStatus(
                sessionId = sessionId,
                peerSignalingId = null,
                lastEvent = "failed: $safeMessage"
            )
        }
    }

    suspend fun generateConnectionCode(): String {
        val net = loadNetworkSettings()
        require(net.webrtcEnabled) { "WebRTC disabled in settings" }
        updateSignalingStatus(sessionId = null, lastEvent = "register-code start")

        val localBinding = currentPathLocalBinding()
        val lease = signalServerClient(net.webrtcSignalingUrl).registerConnectionCode(
            binding = localBinding,
            localIdentity = localIdentity,
            deviceName = localIdentity.deviceName(),
            validDurationSeconds = 600
        )
        validateCurrentPathOrigin(lease.signalingServerOrigin, net.webrtcSignalingUrl)
        updateSignalingStatus(sessionId = lease.sessionId, lastEvent = "register-code ok")

        val sessionId = requireNotNull(normalizeCode(lease.sessionId)) {
            "Invalid connection code lease"
        }

        val owner = try {
            prepareForSessionStart(sessionId)
        } catch (error: Throwable) {
            publishSessionPreparationFailure(sessionId, error)
            throw error
        }
        if (!runIfCurrentSession(owner) {
                webrtcSignalingAuthTokenBySessionId[sessionId] = lease.initiatorToken
                currentPathSignalingOriginBySessionId[sessionId] = lease.signalingServerOrigin
                currentPathTurnAdmissionTokenBySessionId[sessionId] = lease.turnAdmissionToken
                currentPathExpectedRemoteAuthorityBySessionId.remove(sessionId)
            }
        ) {
            throw StaleWebRtcSessionOwnerException()
        }

        runCatching {
            startOffererSession(owner, net)
        }.onFailure {
            val safeMessage = sanitizeErrorMessage(it, "generateConnectionCode failed")
            if (it !is StaleWebRtcSessionOwnerException) {
                failCurrentSession(owner, safeMessage, signalingEventPrefix = "failed")
            }
            throw it
        }

        return lease.code
    }

    fun startOfferer(code: String) {
        val sessionId = normalizeCode(code)
        if (sessionId == null) {
            _state.value = State.Failed(null, "Invalid connection code")
            updateSignalingStatus(sessionId = null, lastEvent = "invalid connection code")
            return
        }
        scope.launch {
            val owner = runCatching { prepareForSessionStart(sessionId) }
                .getOrElse { error ->
                    publishSessionPreparationFailure(sessionId, error)
                    return@launch
                }
            runCatching {
                val token = webrtcSignalingAuthTokenBySessionId[sessionId]
                require(!token.isNullOrBlank()) { "Connection code must be server-issued" }
                val net = loadNetworkSettings()
                requireCurrentSession(owner)
                require(net.webrtcEnabled) { "WebRTC disabled in settings" }
                startOffererSession(owner, net)
            }.onFailure {
                val safeMessage = sanitizeErrorMessage(it, "startOfferer failed")
                Log.e("SB-WEBRTC", "startOfferer failure message=$safeMessage")
                if (it !is StaleWebRtcSessionOwnerException) {
                    failCurrentSession(owner, safeMessage, signalingEventPrefix = "failed")
                }
            }
        }
    }

    fun startAnswerer(code: String) {
        val sessionId = normalizeCode(code)
        if (sessionId == null) {
            _state.value = State.Failed(null, "Invalid connection code")
            updateSignalingStatus(sessionId = null, lastEvent = "invalid connection code")
            return
        }
        scope.launch {
            val owner = runCatching { prepareForSessionStart(sessionId) }
                .getOrElse { error ->
                    publishSessionPreparationFailure(sessionId, error)
                    return@launch
                }
            runIfCurrentSession(owner) {
                _state.value = State.Connecting(sessionId)
            }
            runCatching {
                val net = loadNetworkSettings()
                requireCurrentSession(owner)
                require(net.webrtcEnabled) { "WebRTC disabled in settings" }
                runIfCurrentSession(owner) {
                    updateSignalingStatus(sessionId = sessionId, lastEvent = "lookup start")
                }

                val localBinding = currentPathLocalBinding()
                val lookup = signalServerClient(net.webrtcSignalingUrl).lookupConnectionCode(
                    code = sessionId,
                    binding = localBinding,
                    localIdentity = localIdentity
                )
                requireCurrentSession(owner)
                validateCurrentPathOrigin(lookup.signalingServerOrigin, net.webrtcSignalingUrl)
                if (!runIfCurrentSession(owner) {
                        updateSignalingStatus(sessionId = sessionId, lastEvent = "lookup ok")
                        webrtcSignalingAuthTokenBySessionId[sessionId] = lookup.responderToken
                        currentPathSignalingOriginBySessionId[sessionId] = lookup.signalingServerOrigin
                        currentPathTurnAdmissionTokenBySessionId[sessionId] = lookup.turnAdmissionToken
                        currentPathExpectedRemoteAuthorityBySessionId[sessionId] = CurrentPathRemoteAuthority(
                            deviceId = lookup.initiatorDeviceId,
                            protocolSigningAlgorithm = lookup.initiatorProtocolSigningAlgorithm,
                            protocolPublicKeyFingerprint = lookup.initiatorProtocolPublicKeyFingerprint,
                            deviceName = lookup.initiatorDeviceName
                        )
                        remoteSignalingId = lookup.initiatorDeviceId
                        remoteDeviceId = lookup.initiatorDeviceId
                    }
                ) {
                    throw StaleWebRtcSessionOwnerException()
                }
                ensureAnswererSignalingConfigured(owner, net)
                runIfCurrentSession(owner) {
                    updateSignalingStatus(sessionId = sessionId, lastEvent = "session start")
                }
                startAnswererSession(owner, net)
            }.onFailure {
                val safeMessage = sanitizeErrorMessage(it, "startAnswerer failed")
                Log.e("SB-WEBRTC", "startAnswerer failure message=$safeMessage")
                if (it !is StaleWebRtcSessionOwnerException) {
                    failCurrentSession(owner, safeMessage, signalingEventPrefix = "failed")
                }
            }
        }
    }

    fun disconnect() {
        scope.launch {
            try {
                resetConnection(recreateSignaling = true)
            } catch (error: WebRtcResourceCleanupException) {
                val safeMessage = sanitizeErrorMessage(error, "cleanup failed")
                Log.e("SB-WEBRTC", "disconnect cleanup failed message=$safeMessage")
                _state.value = State.Failed(null, "WebRTC disconnect cleanup failed")
                updateSignalingStatus(
                    sessionId = null,
                    peerSignalingId = null,
                    lastEvent = "disconnect cleanup failed"
                )
            }
        }
    }

    /**
     * Fail one exact application-secure key epoch without granting an old callback authority over
     * a same-session rekey or a replacement session. The owner check, state terminalization, and
     * capture/removal of the exact native session run under the existing session-owner monitor.
     */
    fun failSecureOperation(
        owner: WebRtcSecureOperationOwner,
        reason: String
    ): Boolean = withCurrentSecureOperationOwner(owner, false) { productOwner, _ ->
        val closingSession = session
        session = null
        val didFail = failCurrentSession(
            owner = productOwner,
            reason = reason,
            signalingEventPrefix = "remote control failed"
        )
        if (didFail) {
            val cleanup = closingSession?.close()
            if (cleanup?.isSuccessful == false) {
                val error = cleanup.asException("exact secure-operation session")
                Log.e(
                    "SB-WEBRTC",
                    "exact secure-operation session close failed message=${sanitizeErrorMessage(error, "close failed")}"
                )
            }
        }
        didFail
    }

    /**
     * Linearization boundary for feature-level commits that must not race a session replacement or
     * same-session rekey. The existing product-session monitor remains held through [commit]; the
     * secure capability is validated against the canonical key snapshot before the closure runs.
     */
    fun runIfCurrentSecureOperationOwner(
        owner: WebRtcSecureOperationOwner,
        commit: () -> Unit
    ): Boolean = withCurrentSecureOperationOwner(owner, false) { _, _ ->
        commit()
        true
    }

    fun release() {
        onData = null
        onPacketData = null
        onOwnedData = null
        onOwnedPacketData = null
        onSecurePacketData = null
        scope.launch {
            try {
                resetConnection(recreateSignaling = false)
            } catch (error: WebRtcResourceCleanupException) {
                Log.e(
                    "SB-WEBRTC",
                    "release cleanup failed message=${sanitizeErrorMessage(error, "cleanup failed")}"
                )
            } finally {
                scope.cancel()
            }
        }
    }

    /**
     * Send an application payload over WebRTC.
     * Application data is allowed only after the app-layer handshake derives session keys.
     * Handshake and rekey frames use sendHandshakeFrame(), which intentionally stays unencrypted.
     *
     * The payload is sealed in the SBWC application-secure envelope (matching the macOS
     * WebRTCAppSecureEnvelope) so the Mac can decrypt it; without the SBWC framing the Mac
     * rejects every cross-network app payload with `unsupportedMagic`. SBP2 traffic padding still
     * wraps OUTSIDE the envelope and framing is applied last, exactly as on macOS.
     *
     * @param packetType the SBWC packet type. App-control payloads (PIB pairing, clipboard,
     *   heartbeat, stream config) use [WebRtcAppSecureEnvelope.PacketType.APP_CONTROL]; file
     *   transfer and remote control pass their dedicated types.
     */
    fun send(
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL
    ): Boolean {
        val owner = sessionOwnerGate.current() ?: return false
        var sent = false
        val current = runIfCurrentSession(owner) {
            sent = sendForCurrentOwner(owner, bytes, packetType)
        }
        return current && sent
    }

    /**
     * Send only through the exact established session represented by [owner]. A delayed operation
     * cannot re-resolve a replacement and spill its payload into the new session.
     */
    fun send(
        owner: ProductSessionOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL
    ): Boolean {
        var sent = false
        val current = sessionOwnerGate.runIfCurrent(owner) {
            if (
                currentSessionId == owner.sessionId &&
                _state.value is State.Established &&
                sessionKeys != null
            ) {
                sent = sendForCurrentOwner(owner, bytes, packetType)
            }
        }
        return current && sent
    }

    /** Send only through the exact secure key epoch represented by [owner]. */
    fun send(
        owner: WebRtcSecureOperationOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType = WebRtcAppSecureEnvelope.PacketType.APP_CONTROL
    ): Boolean = withCurrentSecureOperationOwner(owner, false) { productOwner, _ ->
        sendForCurrentOwner(productOwner, bytes, packetType)
    }

    private fun sendForCurrentOwner(
        owner: ProductSessionOwner,
        bytes: ByteArray,
        packetType: WebRtcAppSecureEnvelope.PacketType
    ): Boolean {
        val keys = sessionKeys ?: run {
            Log.w(
                "SB-WEBRTC",
                "reject app send before secure session session=${redactLogIdentifier(owner.sessionId)} bytes=${bytes.size}"
            )
            updateSignalingStatus(
                sessionId = owner.sessionId,
                peerSignalingId = remoteSignalingId,
                lastEvent = "rejected app send before secure session"
            )
            return false
        }
        val role = secureEnvelopeRole() ?: run {
            Log.w(
                "SB-WEBRTC",
                "reject app send: no session role session=${redactLogIdentifier(owner.sessionId)}"
            )
            return false
        }
        val sessionIdForEnvelope = secureEnvelopeSessionId(keys)
        val counter = nextSecureEnvelopeSendCounter()
        val encrypted = WebRtcAppSecureEnvelope.seal(
            plaintext = bytes,
            sendKey = keys.sendKey,
            role = role,
            sessionId = sessionIdForEnvelope,
            transcriptHash = keys.transcriptHash,
            packetType = packetType,
            counter = counter
        )
        val payload = TrafficPaddingP2.wrapIfEnabled(encrypted, "tx/webrtc")
        return sendFramed(owner, payload)
    }

    /** Map the WebRTC offer/answer role onto the SBWC initiator/responder role. */
    private fun secureEnvelopeRole(): WebRtcAppSecureEnvelope.Role? = when (session?.role) {
        WebRtcSession.Role.OFFERER -> WebRtcAppSecureEnvelope.Role.INITIATOR
        WebRtcSession.Role.ANSWERER -> WebRtcAppSecureEnvelope.Role.RESPONDER
        null -> null
    }

    /** Deterministic SBWC sessionId (matches macOS SessionKeys.deterministicSessionId). */
    private fun secureEnvelopeSessionId(
        keys: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys
    ): String {
        val cached = webrtcSecureEnvelopeSessionId
        if (cached != null) return cached
        val derived = WebRtcAppSecureEnvelope.deterministicSessionId(keys.transcriptHash)
        webrtcSecureEnvelopeSessionId = derived
        return derived
    }

    /** Monotonic per-direction counter; SBWC rejects 0, so the first frame uses 1. */
    private fun nextSecureEnvelopeSendCounter(): Long {
        webrtcSecureEnvelopeSendCounter += 1
        return webrtcSecureEnvelopeSendCounter
    }

    private fun sendHandshakeFrame(owner: ProductSessionOwner, payload: ByteArray): Boolean {
        Log.i(
            "SB-HANDSHAKE",
            "send session=${redactLogIdentifier(currentSessionId)} bytes=${payload.size} phase=${initiatorHandshakePhase ?: responderHandshakePhase ?: HandshakePhase.INITIAL}"
        )
        return sendFramed(owner, payload)
    }

    private fun sendFramed(owner: ProductSessionOwner, payload: ByteArray): Boolean =
        framedSender.send(owner, payload)

    private fun terminatePartiallyWrittenFramedTransport(
        owner: ProductSessionOwner,
        reason: String,
    ) {
        var closingSession: WebRtcSession? = null
        val detached = runIfCurrentSession(owner) {
            closingSession = session
            session = null
        }
        if (!detached) return

        // Release the exact product-session authority before native teardown so all subsequent
        // sends are rejected even if cleanup reports a platform failure.
        failSecureTransport(owner, reason)
        val cleanup = closingSession?.close() ?: WebRtcResourceCloseReport()
        if (!cleanup.isSuccessful) {
            Log.e(
                "SB-WEBRTC",
                "partialSendCleanupFailed session=${redactLogIdentifier(owner.sessionId)} " +
                    "stages=${cleanup.failures.joinToString(",") { it.stage }}",
            )
        }
    }

    /** Returns true when app-layer session keys are established (P2P handshake completed). */
    fun hasSessionKeys(): Boolean = sessionKeys != null

    /** Return the exact current owner only after the application-secure session is established. */
    fun currentEstablishedOwner(): ProductSessionOwner? {
        val owner = sessionOwnerGate.current() ?: return null
        var established = false
        val current = sessionOwnerGate.runIfCurrent(owner) {
            established = currentSessionId == owner.sessionId &&
                _state.value is State.Established &&
                sessionKeys != null
        }
        return owner.takeIf { current && established }
    }

    /** Acquire the opaque capability for the current established key epoch. */
    fun currentSecureOperationOwner(): WebRtcSecureOperationOwner? {
        val owner = sessionOwnerGate.current() ?: return null
        var capability: WebRtcSecureOperationOwner? = null
        sessionOwnerGate.runIfCurrent(owner) {
            val keys = sessionKeys
            if (
                currentSessionId == owner.sessionId &&
                _state.value is State.Established &&
                keys != null
            ) {
                capability = secureOperationOwnerState.current(owner, keys)
            }
        }
        return capability
    }

    fun isCurrentSecureOperationOwner(owner: WebRtcSecureOperationOwner): Boolean =
        withCurrentSecureOperationOwner(owner, false) { _, _ -> true }

    /** True only after this exact formal key epoch completed the read-only peer-KEM exchange. */
    fun hasExistingTrustPeerKemAdmission(owner: WebRtcSecureOperationOwner): Boolean =
        diagnosticsConfig.existingTrustOnly &&
            withCurrentSecureOperationOwner(owner, false) { _, _ ->
                existingTrustPeerKemAdmissionState.isCurrent(owner) &&
                    existingTrustPeerKemAdmissionState.isSendConfirmed(owner)
            }

    /** Key readiness for one exact session incarnation; stale owners always fail closed. */
    fun hasSessionKeys(owner: ProductSessionOwner): Boolean {
        var hasKeys = false
        val current = sessionOwnerGate.runIfCurrent(owner) {
            hasKeys = currentSessionId == owner.sessionId &&
                _state.value is State.Established &&
                sessionKeys != null
        }
        return current && hasKeys
    }

    fun hasSessionKeys(owner: WebRtcSecureOperationOwner): Boolean =
        isCurrentSecureOperationOwner(owner)

    /** Selected-route lookup for one exact owner. */
    fun selectedRoute(owner: ProductSessionOwner): WebRtcSelectedRoute? {
        var route: WebRtcSelectedRoute? = null
        val current = sessionOwnerGate.runIfCurrent(owner) {
            if (currentSessionId == owner.sessionId) {
                route = selectedRouteStore.current(owner)
            }
        }
        return route.takeIf { current }
    }

    fun selectedRoute(owner: WebRtcSecureOperationOwner): WebRtcSelectedRoute? =
        withCurrentSecureOperationOwner(owner, null) { productOwner, _ ->
            selectedRouteStore.current(productOwner)
        }

    /** Direct-only admission rejects relay, unknown, missing, and stale-owner evidence. */
    fun hasDirectRoute(owner: ProductSessionOwner): Boolean {
        var allowed = false
        val current = sessionOwnerGate.runIfCurrent(owner) {
            if (
                currentSessionId == owner.sessionId &&
                _state.value is State.Established &&
                sessionKeys != null
            ) {
                allowed = WebRtcDirectRouteAdmissionPolicy.allows(
                    owner = owner,
                    witness = selectedRouteWitness.value
                )
            }
        }
        return current && allowed
    }

    fun hasDirectRoute(owner: WebRtcSecureOperationOwner): Boolean =
        withCurrentSecureOperationOwner(owner, false) { productOwner, _ ->
            WebRtcDirectRouteAdmissionPolicy.allows(
                owner = productOwner,
                witness = selectedRouteWitness.value
            )
        }

    /**
     * Authenticated application peer identity for the established secure session.
     *
     * Returns null before the app-layer handshake has produced session keys, so callers do not
     * accidentally treat signaling IDs or peer-declared metadata as authenticated identity.
     */
    fun authenticatedPeerDeviceId(): String? =
        if (sessionKeys != null) currentPeerId() else null

    /** Returns the currently negotiated app-layer suite, when the handshake has completed. */
    fun negotiatedSuiteName(): String? = negotiatedSuite?.name

    /** Returns the currently negotiated app-layer suite wire id, when the handshake has completed. */
    fun negotiatedSuiteWireId(): Int? = negotiatedSuite?.wireId?.toInt()

    /** Returns true once the active app-layer session has been upgraded onto a PQC suite. */
    fun hasPqcSessionKeys(): Boolean = sessionKeys != null && (negotiatedSuite?.isPqc == true)

    /** Returns true once the active app-layer session has specifically negotiated Q-Periapt. */
    fun hasQPeriaptSessionKeys(): Boolean =
        sessionKeys != null && negotiatedSuite == P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND

    private fun localBusinessIdentity(): LocalPeerBusinessIdentity? =
        localBusinessIdentityProvider?.invoke()?.normalizedOrNull()

    /** Returns true once the current peer has published PQC bootstrap material into the local alias store. */
    fun hasBootstrappedPeerKemForCurrentPeer(): Boolean {
        val owner = sessionOwnerGate.current()
        val pending = if (diagnosticsConfig.existingTrustOnly) {
            null
        } else {
            owner?.let { currentPendingJoinBootstrapKeys(it, currentPeerId()) }
        }
        if (
            pending?.qPeriaptPublicKey != null ||
            pending?.xWingPublicKey != null ||
            pending?.mlKem768PublicKey != null
        ) {
            return true
        }
        return currentPeerKemCandidateIds().any { peerId ->
            val peerKem = loadPeerKem(peerId)
            peerKem.qPeriaptPublicKey != null ||
                peerKem.xWingPublicKey != null ||
                peerKem.mlKem768PublicKey != null
        }
    }

    /** Returns true once the current peer has published Q-Periapt bootstrap material. */
    fun hasBootstrappedPeerQPeriaptForCurrentPeer(): Boolean {
        val owner = sessionOwnerGate.current()
        if (!diagnosticsConfig.existingTrustOnly && owner?.let {
                currentPendingJoinBootstrapKeys(it, currentPeerId())
            }
                ?.qPeriaptPublicKey != null
        ) {
            return true
        }
        return currentPeerKemCandidateIds().any { peerId ->
            loadPeerKem(peerId).qPeriaptPublicKey != null
        }
    }

    private fun currentPeerKemCandidateIds(): List<String> {
        val candidateIds = buildList {
            remoteDeviceId?.takeIf { it.isNotBlank() }?.let { add(it) }
            remoteSignalingId?.takeIf { it.isNotBlank() && it != remoteDeviceId }?.let { add(it) }
        }
        return candidateIds
    }

    private fun loadPeerKem(peerId: String): PeerKemKeyStore.PeerKemPublicKeys =
        if (diagnosticsConfig.existingTrustOnly) {
            peerKemStore.loadVerifiedReadOnly(peerId)
        } else {
            peerKemStore.load(peerId)
        }

    fun debugKickoffHandshakeNow() {
        val owner = sessionOwnerGate.current() ?: return
        val activeSession = session ?: return
        if (!activeSession.isDataChannelOpen()) {
            Log.i(
                "SB-HANDSHAKE",
                "debugKickoff skipped session=${activeSession.sessionId} reason=datachannel_not_open"
            )
            return
        }
        Log.i(
            "SB-HANDSHAKE",
            "debugKickoff session=${activeSession.sessionId} role=${activeSession.role} hasKeys=${sessionKeys != null} initPending=${initiatorHandshake != null} respPending=${responderHandshake != null}"
        )
        scheduleHandshakeStart(owner, activeSession.role)
    }

    /**
     * Compute a v1 MAC for merkleRootSignature:
     * HMAC-SHA256(key = sendKey, data = preimage).
     *
     * Backward compatible: callers may omit signature fields if keys are not available.
     */
    fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray? {
        val keys = sessionKeys ?: return null
        return hmacSha256(keys.sendKey, preimage)
    }

    /** Compute transfer integrity evidence only for the exact established session owner. */
    fun computeOutboundHmacSha256(
        owner: ProductSessionOwner,
        preimage: ByteArray
    ): ByteArray? {
        var result: ByteArray? = null
        sessionOwnerGate.runIfCurrent(owner) {
            if (currentSessionId == owner.sessionId && _state.value is State.Established) {
                result = sessionKeys?.let { keys -> hmacSha256(keys.sendKey, preimage) }
            }
        }
        return result
    }

    fun computeOutboundHmacSha256(
        owner: WebRtcSecureOperationOwner,
        preimage: ByteArray
    ): ByteArray? = withCurrentSecureOperationOwner(owner, null) { _, keys ->
        hmacSha256(keys.sendKey, preimage)
    }

    /**
     * Verify a v1 MAC for merkleRootSignature:
     * HMAC-SHA256(key = receiveKey, data = preimage) == mac.
     */
    fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean {
        val keys = sessionKeys ?: return false
        val expected = hmacSha256(keys.receiveKey, preimage)
        return expected.contentEquals(mac)
    }

    /** Verify transfer integrity evidence only against the exact established session owner. */
    fun verifyInboundHmacSha256(
        owner: ProductSessionOwner,
        preimage: ByteArray,
        mac: ByteArray
    ): Boolean {
        var verified = false
        sessionOwnerGate.runIfCurrent(owner) {
            if (currentSessionId == owner.sessionId && _state.value is State.Established) {
                val keys = sessionKeys
                if (keys != null) {
                    verified = hmacSha256(keys.receiveKey, preimage).contentEquals(mac)
                }
            }
        }
        return verified
    }

    fun verifyInboundHmacSha256(
        owner: WebRtcSecureOperationOwner,
        preimage: ByteArray,
        mac: ByteArray
    ): Boolean = withCurrentSecureOperationOwner(owner, false) { _, keys ->
        hmacSha256(keys.receiveKey, preimage).contentEquals(mac)
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private suspend fun loadNetworkSettings(): NetworkSettings =
        networkSettingsOverrideProvider?.invoke()
            ?: NetworkSettingsStore.observe(appContext).first()

    private suspend fun prepareForSessionStart(sessionId: String): ProductSessionOwner =
        lifecycleMutex.withLock {
            val transition = sessionOwnerGate.begin(sessionId)
            val owner = transition.owner
            check(
                sessionOwnerGate.runIfCurrent(owner) {
                    authenticatedSessionPeerKemStore.applyLifecycleEvent(
                        owner,
                        AuthenticatedSessionPeerKemLifecycleEvent.OWNER_STARTED
                    )
                }
            ) { "new WebRTC session owner was replaced during preparation" }
            pendingJoinBootstrapKem = null
            selectedRouteStore.bind(owner)
            transition.replacedOwner?.let { previousOwner ->
                productSessionAuthorityStore?.markDisconnected(previousOwner)?.let { result ->
                    logRejectedAuthorityMutation("replace product session owner", previousOwner, result)
                }
                if (previousOwner.sessionId != owner.sessionId) {
                    clearSessionCredentials(previousOwner.sessionId)
                }
            }
            val replacedSessionCleanup = session?.close()
            session = null
            if (replacedSessionCleanup?.isSuccessful == false) {
                failCurrentSession(
                    owner,
                    "previous WebRTC session cleanup failed",
                    signalingEventPrefix = "session replacement failed"
                )
                throw replacedSessionCleanup.asException("previous WebRTC session")
            }
            appHeartbeatTask?.cancel()
            appHeartbeatTask = null
            val ownerClaim = productSessionAuthorityStore?.claimSession(owner)
            when (ownerClaim) {
                ProductSessionOwnerClaimResult.CAPACITY_REACHED -> {
                    sessionOwnerGate.releaseIfCurrent(owner)
                    selectedRouteStore.clearIfOwned(owner)
                    currentSessionId = null
                    SecureSessionKeyLifecycle.wipeKeyMaterial(sessionKeys)
                    sessionKeys = null
                    secureOperationOwnerState.clear()
                    existingTrustPeerKemAdmissionState.clear()
                    resetSecureEnvelopeState()
                    negotiatedSuite = null
                    inboundFrames.reset()
                    throw IllegalStateException("Product session owner capacity reached")
                }
                ProductSessionOwnerClaimResult.CLAIMED,
                ProductSessionOwnerClaimResult.REPLACED_EXISTING_OWNER,
                ProductSessionOwnerClaimResult.ALREADY_CURRENT,
                null -> Unit
            }
            currentSessionId = owner.sessionId
            // 任务 9.9 / R4.9：新会话起点替换旧会话时置零擦除上一会话遗留的密钥材料，不仅置空引用。
            SecureSessionKeyLifecycle.wipeKeyMaterial(sessionKeys)
            sessionKeys = null
            secureOperationOwnerState.clear()
            existingTrustPeerKemAdmissionState.clear()
            resetSecureEnvelopeState()
            negotiatedSuite = null
            _authenticatedPeerMetadata.value = null
            initiatorHandshake = null
            initiatorHandshakePhase = null
            initiatorPendingMessageB = null
            initiatorPendingResponderFinished = null
            responderHandshake = null
            responderHandshakePhase = null
            responderNegotiatedSuite = null
            remoteSignalingId = null
            remoteDeviceId = null
            pairingExchangeSent = false
            rekeyInProgress = false
            rekeyAttempted = false
            inboundFrames.reset()
            // 任务 9.7 / R4.1：本次连接建立的整体时限计时自此刻（用户选择设备后的会话起点）开始。
            armEstablishmentDeadline(owner)
            owner
        }

    private suspend fun startOffererSession(owner: ProductSessionOwner, net: NetworkSettings) {
        requireCurrentSession(owner)
        val sessionId = owner.sessionId
        ensureSignalingConfigured(net, owner)
        val joinPayload = buildJoinBootstrapPayload()
        sendSignalingEnvelope(
            owner,
            WebRtcSignalingEnvelope(
                sessionId = sessionId,
                from = localId,
                type = WebRtcSignalingEnvelope.MessageType.JOIN,
                payload = joinPayload,
                sentAt = nowSeconds()
            )
        )
        runIfCurrentSession(owner) {
            updateSignalingStatus(
                sessionId = sessionId,
                lastEvent = "sent join keys=${joinPayload?.kemPublicKeys?.size ?: 0}"
            )
        }
        prepareSession(owner = owner, net = net, role = WebRtcSession.Role.OFFERER)
        runIfCurrentSession(owner) {
            _state.value = State.Waiting(sessionId)
        }
    }

    private suspend fun startAnswererSession(owner: ProductSessionOwner, net: NetworkSettings) {
        requireCurrentSession(owner)
        val sessionId = owner.sessionId
        ensureSignalingConfigured(net, owner)
        val joinPayload = buildJoinBootstrapPayload()
        sendSignalingEnvelope(
            owner,
            WebRtcSignalingEnvelope(
                sessionId = sessionId,
                from = localId,
                type = WebRtcSignalingEnvelope.MessageType.JOIN,
                payload = joinPayload,
                sentAt = nowSeconds()
            )
        )
        runIfCurrentSession(owner) {
            updateSignalingStatus(
                sessionId = sessionId,
                lastEvent = "sent join keys=${joinPayload?.kemPublicKeys?.size ?: 0}"
            )
        }
        prepareSession(owner = owner, net = net, role = WebRtcSession.Role.ANSWERER)
    }

    private fun buildJoinBootstrapPayload(): WebRtcSignalingEnvelope.Payload? {
        if (!pqcEnabled) return null
        val policy = effectivePolicyOverride()
        val allowQPeriapt = policy.minimumTierRaw == P2PQPeriaptKem.MINIMUM_TIER_RAW
        if (allowQPeriapt) {
            QPeriaptPlatformPolicy.requireLocalAndroidSupported(
                QPeriaptPlatformPolicy.androidHandshakePlatformVersion(
                    Build.VERSION.RELEASE,
                    Build.VERSION.SDK_INT
                )
            )
        }
        val pairingPayload = localIdentity.buildPairingIdentityExchange(
            nowSwiftSeconds = SwiftDateSeconds.now(),
            platform = "Android",
            allowQPeriapt = allowQPeriapt
        )
        return JoinBootstrapPayload.fromPairingIdentity(
            payload = pairingPayload,
            authority = currentPathLocalBinding()
        )
    }

    private suspend fun ensureAnswererSignalingConfigured(owner: ProductSessionOwner, net: NetworkSettings) {
        ensureSignalingConfigured(net, owner)
        runIfCurrentSession(owner) {
            updateSignalingStatus(sessionId = owner.sessionId, lastEvent = "answerer signaling configured")
        }
    }

    private suspend fun prepareSession(
        owner: ProductSessionOwner,
        net: NetworkSettings,
        role: WebRtcSession.Role
    ) {
        requireCurrentSession(owner)
        val sessionId = owner.sessionId
        ensureSignalingConfigured(net, owner)
        val ice = dynamicIceConfig(owner)
        requireCurrentSession(owner)
        withContext(Dispatchers.Main.immediate) {
            requireCurrentSession(owner)
            updateSignalingStatus(sessionId = sessionId, lastEvent = "peerconnection create")
            val created = WebRtcSession(
                appContext = appContext,
                sessionId = sessionId,
                localDeviceId = localId,
                role = role,
                ice = ice,
                diagnosticsConfig = diagnosticsConfig
            )
            attachSessionCallbacks(created, owner)
            val installed = runIfCurrentSession(owner) {
                session = created
                _state.value = State.Connecting(sessionId)
                updateSignalingStatus(sessionId = sessionId, lastEvent = "peerconnection start")
                created.start()
            }
            if (!installed) {
                val cleanup = created.close()
                if (!cleanup.isSuccessful) {
                    throw cleanup.asException("stale WebRTC session")
                }
                throw StaleWebRtcSessionOwnerException()
            }
        }
    }

    private fun currentPathLocalBinding(): ProtocolIdentityBinding {
        val signingKeys = localIdentity.getOrCreateProtocolSigningKeys()
        return CurrentPathProtocolAuthority.bindingFor(
            deviceId = localIdentity.deviceId(),
            policy = effectivePolicyOverride(),
            signingKeys = signingKeys
        )
    }

    private fun signalServerClient(signalingEndpoint: String): SignalServerClient =
        SignalServerClient(
            baseUrlProvider = { controlPlaneBaseUrl(signalingEndpoint) },
            userAuthContextProvider = {
                if (
                    SignalingEndpointTrustPolicy.allowsUserAuthContext(signalingEndpoint) ||
                    (
                        diagnosticsConfig.allowLoopbackOriginAlias &&
                            SignalingEndpointTrustPolicy.allowsDiagnosticLoopbackAuthContext(signalingEndpoint)
                    ) ||
                    (
                        diagnosticsConfig.allowLocalNetworkCompatSignaling &&
                            SignalingEndpointTrustPolicy.allowsDiagnosticLocalNetworkAuthContext(signalingEndpoint)
                    )
                ) {
                    userAuthContextProvider?.invoke()
                } else {
                    null
                }
            },
            clientVersionProvider = { resolvedClientVersion() },
            protocolVersionProvider = { resolvedProtocolVersion() }
        )

    private fun validateCurrentPathOrigin(rawOrigin: String, configuredSignalingUrl: String): String {
        val configuredOrigin = canonicalOriginForCurrentPathValidation(controlPlaneBaseUrl(configuredSignalingUrl))
        val claimedOrigin = canonicalOriginForCurrentPathValidation(rawOrigin)
        require(
            configuredOrigin == claimedOrigin ||
                (
                    diagnosticsConfig.allowLoopbackOriginAlias &&
                        originsEquivalentForSmoke(configuredOrigin, claimedOrigin)
                    )
        ) { "Invalid signaling origin" }
        return claimedOrigin
    }

    private fun canonicalOriginForCurrentPathValidation(rawOrigin: String): String =
        runCatching {
            CurrentPathOriginPolicy.canonicalOrigin(rawOrigin)
        }.getOrElse { originalError ->
            if (diagnosticsConfig.allowLocalNetworkCompatSignaling) {
                diagnosticLocalHttpOrigin(rawOrigin)?.let { return it }
            }
            throw originalError
        }

    private fun diagnosticLocalHttpOrigin(rawOrigin: String): String? {
        val uri = runCatching { URI(rawOrigin.trim()) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "http") return null
        if (!uri.rawPath.isNullOrEmpty() && uri.rawPath != "/") return null
        if (uri.rawQuery != null || uri.rawFragment != null) return null
        val host = uri.host?.lowercase() ?: return null
        if (!SignalingEndpointTrustPolicy.isDiagnosticLocalNetworkHost(host)) return null
        val port = uri.port.takeIf { it >= 0 && it != 80 }?.let { ":$it" }.orEmpty()
        return "$scheme://$host$port"
    }

    private fun originsEquivalentForSmoke(left: String, right: String): Boolean {
        val leftUri = runCatching { URI(left) }.getOrNull() ?: return false
        val rightUri = runCatching { URI(right) }.getOrNull() ?: return false
        if (!leftUri.scheme.equals(rightUri.scheme, ignoreCase = true)) return false

        fun normalizedPort(uri: URI): Int =
            when {
                uri.port >= 0 -> uri.port
                uri.scheme.equals("https", ignoreCase = true) -> 443
                else -> 80
            }

        val leftHost = leftUri.host?.lowercase() ?: return false
        val rightHost = rightUri.host?.lowercase() ?: return false
        if (normalizedPort(leftUri) != normalizedPort(rightUri)) return false

        val loopbackAliases = setOf("127.0.0.1", "localhost", "10.0.2.2")
        return leftHost in loopbackAliases && rightHost in loopbackAliases
    }

    private fun controlPlaneBaseUrl(signalingEndpoint: String): String {
        val uri = runCatching { URI(signalingEndpoint.trim()) }
            .getOrElse { throw IllegalArgumentException("invalid signaling base url") }
        val scheme = when (uri.scheme?.lowercase()) {
            "wss" -> "https"
            "ws" -> "http"
            "https", "http" -> uri.scheme.lowercase()
            else -> throw IllegalArgumentException("invalid signaling base url")
        }
        val host = uri.host ?: throw IllegalArgumentException("invalid signaling base url")
        val port = uri.port
        val includePort = when {
            port < 0 -> false
            scheme == "https" && port == 443 -> false
            scheme == "http" && port == 80 -> false
            else -> true
        }
        return if (includePort) {
            "$scheme://$host:$port"
        } else {
            "$scheme://$host"
        }
    }

    private suspend fun ensureSignalingConfigured(net: NetworkSettings, owner: ProductSessionOwner) {
        requireCurrentSession(owner)
        val sessionId = owner.sessionId
        val baseUrl = net.webrtcSignalingUrl.trim().ifBlank { SkyBridgeServerConfig.signalingWebSocketURL }
        val desiredShard = sessionId.trim().takeIf { it.isNotEmpty() }
        val desired = signalingUrlWithShard(baseUrl, desiredShard)
        val desiredHeaders = signalingHeadersForShard(desiredShard)
        var routeReady = false
        var previousSignaling: WebSocketSignalingClient? = null
        if (!runIfCurrentSession(owner) {
                routeReady = desired == signalingUrl &&
                    desiredShard == signalingShard &&
                    desiredHeaders == signalingHeaders &&
                    signalingOwner == owner
                if (routeReady) {
                    updateSignalingStatus(sessionId = sessionId, lastEvent = "signaling route ready")
                } else {
                    previousSignaling = signaling
                }
            }
        ) {
            throw StaleWebRtcSessionOwnerException()
        }
        if (routeReady) {
            return
        }

        val previousCleanup = requireNotNull(previousSignaling).close()
        if (!previousCleanup.isSuccessful) {
            throw previousCleanup.asException("replaced WebRTC signaling client")
        }
        val installed = runIfCurrentSession(owner) {
            signalingUrl = desired
            signalingShard = desiredShard
            signalingHeaders = desiredHeaders
            signaling = WebSocketSignalingClient(
                wsUrlString = desired,
                additionalHeaders = desiredHeaders
            )
            signalingOwner = owner
            bindSignalingCallbacks(owner)
            signaling.connect()
            updateSignalingStatus(sessionId = sessionId, lastEvent = "signaling reconnect")
        }
        if (!installed) {
            throw StaleWebRtcSessionOwnerException()
        }
    }

    private suspend fun resetConnection(recreateSignaling: Boolean) {
        lifecycleMutex.withLock {
            val owner = sessionOwnerGate.current()
            // The authority store is the durable capability boundary. Terminalize it while this
            // exact owner is still active, then release the in-memory gate so late callbacks cannot
            // publish or bind anything for the closed session.
            terminateDisconnectedOwner(owner)
            val closingSession = session
            session = null
            val closingSignaling = signaling
            val cleanup = WebRtcResourceCloseReport()
            closingSession?.let { cleanup.merge("session", it.close()) }
            cleanup.merge("signaling", closingSignaling.close())
            closingSignaling.onEnvelope = null
            closingSignaling.onServerFrame = null
            closingSignaling.onError = null
            signalingOwner = null
            clearConnectionState(owner)
            if (!cleanup.isSuccessful) {
                throw cleanup.asException("WebRTC connection reset")
            }
            if (recreateSignaling) {
                signaling = WebSocketSignalingClient(
                    wsUrlString = signalingUrl,
                    additionalHeaders = signalingHeaders
                )
                signalingOwner = null
                bindSignalingCallbacks(owner = null)
                signaling.connect()
            }
        }
    }

    private fun bindSignalingCallbacks(owner: ProductSessionOwner?) {
        val callbackSignaling = signaling
        signaling.onEnvelope = { env ->
            if (owner != null && callbackSignaling === signaling && sessionOwnerGate.isCurrent(owner)) {
                handleEnvelope(owner, env)
            }
        }
        signaling.onServerFrame = { frame ->
            if (owner != null && callbackSignaling === signaling && sessionOwnerGate.isCurrent(owner)) {
                handleServerFrame(owner, frame)
            }
        }
        signaling.onError = { throwable ->
            val safeMessage = sanitizeErrorMessage(throwable, "unknown")
            if (owner == null) {
                if (callbackSignaling === signaling && sessionOwnerGate.current() == null) {
                    updateSignalingStatus(
                        sessionId = null,
                        peerSignalingId = null,
                        lastEvent = "signaling error: $safeMessage"
                    )
                }
            } else {
                runIfCurrentSession(owner) {
                    if (callbackSignaling === signaling) {
                        updateSignalingStatus(
                            sessionId = owner.sessionId,
                            peerSignalingId = remoteSignalingId,
                            lastEvent = "signaling error: $safeMessage"
                        )
                    }
                }
            }
        }
    }

    private fun clearConnectionState(owner: ProductSessionOwner?) {
        cancelEstablishmentDeadline()
        owner?.let { clearSessionCredentials(it.sessionId) }
        appHeartbeatTask?.cancel()
        appHeartbeatTask = null
        // 任务 9.9 / R4.9：主动断开时对内存中的会话密钥材料做置零擦除，而非仅置空引用；随后
        // 关闭全部 DataChannel（session.close，见 resetConnection）、释放信令与 ICE 并呈现已断开。
        SecureSessionKeyLifecycle.wipeKeyMaterial(sessionKeys)
        sessionKeys = null
        secureOperationOwnerState.clear()
        existingTrustPeerKemAdmissionState.clear()
        resetSecureEnvelopeState()
        negotiatedSuite = null
        _authenticatedPeerMetadata.value = null
        initiatorHandshake = null
        initiatorHandshakePhase = null
        initiatorPendingMessageB = null
        initiatorPendingResponderFinished = null
        responderHandshake = null
        responderHandshakePhase = null
        responderNegotiatedSuite = null
        lastSentPairingExchangeFingerprint = null
        currentSessionId = null
        remoteSignalingId = null
        remoteDeviceId = null
        pendingJoinBootstrapKem = null
        signalingShard = null
        pairingExchangeSent = false
        rekeyInProgress = false
        rekeyAttempted = false
        inboundFrames.reset()
        if (owner == null) {
            selectedRouteStore.clear()
        } else {
            selectedRouteStore.clearIfOwned(owner)
        }
        _state.value = State.Idle
        updateSignalingStatus(sessionId = null, peerSignalingId = null, lastEvent = "idle")
    }

    private fun terminateDisconnectedOwner(owner: ProductSessionOwner?) {
        owner ?: return
        sessionOwnerGate.runIfCurrent(owner) {
            productSessionAuthorityStore?.markDisconnected(owner)?.let { result ->
                logRejectedAuthorityMutation("disconnect product session", owner, result)
            }
            authenticatedSessionPeerKemStore.applyLifecycleEvent(
                owner,
                AuthenticatedSessionPeerKemLifecycleEvent.SESSION_DISCONNECTED
            )
            sessionOwnerGate.releaseIfCurrent(owner)
        }
    }

    private fun clearSessionCredentials(sessionId: String) {
        webrtcSignalingAuthTokenBySessionId.remove(sessionId)
        currentPathExpectedRemoteAuthorityBySessionId.remove(sessionId)
        currentPathSignalingOriginBySessionId.remove(sessionId)
        currentPathTurnAdmissionTokenBySessionId.remove(sessionId)
    }

    private fun failCurrentSession(
        owner: ProductSessionOwner,
        reason: String,
        signalingEventPrefix: String
    ): Boolean {
        val safeReason = sanitizeStatusMessage(reason)
        return runIfCurrentSession(owner) {
            productSessionAuthorityStore?.markFailed(owner)?.let { result ->
                logRejectedAuthorityMutation("fail product session", owner, result)
            }
            authenticatedSessionPeerKemStore.applyLifecycleEvent(
                owner,
                AuthenticatedSessionPeerKemLifecycleEvent.SESSION_FAILED
            )
            sessionOwnerGate.releaseIfCurrent(owner)
            selectedRouteStore.clearIfOwned(owner)
            _state.value = State.Failed(owner.sessionId, safeReason)
            _authenticatedPeerMetadata.value = null
            updateSignalingStatus(
                sessionId = owner.sessionId,
                peerSignalingId = remoteSignalingId,
                lastEvent = "$signalingEventPrefix: $safeReason"
            )
            clearSessionCredentials(owner.sessionId)
            cancelEstablishmentDeadline()
            appHeartbeatTask?.cancel()
            appHeartbeatTask = null
            SecureSessionKeyLifecycle.wipeKeyMaterial(sessionKeys)
            sessionKeys = null
            secureOperationOwnerState.clear()
            existingTrustPeerKemAdmissionState.clear()
            resetSecureEnvelopeState()
            negotiatedSuite = null
            initiatorHandshake = null
            initiatorHandshakePhase = null
            initiatorPendingMessageB = null
            initiatorPendingResponderFinished = null
            responderHandshake = null
            responderHandshakePhase = null
            responderNegotiatedSuite = null
            pairingExchangeSent = false
            lastSentPairingExchangeFingerprint = null
            pendingJoinBootstrapKem = null
            rekeyInProgress = false
            rekeyAttempted = false
            val cleanup = session?.close()
            session = null
            if (cleanup?.isSuccessful == false) {
                val cleanupError = cleanup.asException("failed WebRTC session")
                Log.e(
                    "SB-WEBRTC",
                    "session cleanup failed after primary failure message=${sanitizeErrorMessage(cleanupError, "cleanup failed")}"
                )
                _state.value = State.Failed(
                    owner.sessionId,
                    sanitizeStatusMessage("$safeReason; native cleanup incomplete")
                )
            }
            currentSessionId = null
            inboundFrames.reset()
        }
    }

    private suspend fun dynamicIceConfig(owner: ProductSessionOwner): WebRtcSession.IceConfig {
        requireCurrentSession(owner)
        val net = loadNetworkSettings()
        var admission: Pair<String, String?>? = null
        val captured = runIfCurrentSession(owner) {
            val token = currentPathTurnAdmissionTokenBySessionId[owner.sessionId]
                ?.takeIf { it.isNotBlank() }
            if (token == null) {
                updateSignalingStatus(
                    sessionId = owner.sessionId,
                    peerSignalingId = remoteSignalingId,
                    lastEvent = "turn admission token missing"
                )
            } else {
                admission = token to currentPathSignalingOriginBySessionId[owner.sessionId]
                    ?.takeIf { it.isNotBlank() }
            }
        }
        if (!captured) {
            throw StaleWebRtcSessionOwnerException()
        }
        val (turnAdmissionToken, signalingServerOrigin) = admission
            ?: throw IllegalStateException("TURN credential admission token missing")
        val creds = try {
            turnService.getCredentials(
                turnAdmissionToken = turnAdmissionToken,
                deviceId = localIdentity.deviceId(),
                signalingServerOrigin = signalingServerOrigin
            )
        } catch (t: Throwable) {
            val safeReason = diagnosticErrorMessage(t, "turn admission failed")
            updateSignalingStatus(
                sessionId = owner.sessionId,
                peerSignalingId = remoteSignalingId,
                lastEvent = "turn admission failed: $safeReason"
            )
            Log.e("SB-WEBRTC", "turn admission failure reason=$safeReason")
            throw IllegalStateException("TURN credential admission failed: $safeReason", t)
        }
        requireCurrentSession(owner)
        val stunUrl = net.stunServers.firstOrNull()?.trim().orEmpty().ifBlank { SkyBridgeServerConfig.stunURL }
        return WebRtcSession.IceConfig(
            stunUrl = stunUrl,
            turnUrls = NetworkEndpointPolicy.resolveTurnUrlsForCredentials(
                configuredTurnServers = net.turnServers,
                credentialTurnUris = creds.uris
            ),
            turnUsername = creds.username,
            turnPassword = creds.password
        )
    }

    private fun attachSessionCallbacks(s: WebRtcSession, owner: ProductSessionOwner) {
        val sessionId = owner.sessionId
        s.onLocalOffer = { sdp ->
            scope.launch {
                if (!sessionOwnerGate.isCurrent(owner) || session !== s) return@launch
                runCatching {
                    sendSignalingEnvelope(
                        owner,
                        WebRtcSignalingEnvelope(
                            sessionId = sessionId,
                            from = localId,
                            type = WebRtcSignalingEnvelope.MessageType.OFFER,
                            payload = WebRtcSignalingEnvelope.Payload(sdp = sdp),
                            sentAt = nowSeconds()
                        )
                    )
                }.onSuccess {
                    runIfCurrentSession(owner) {
                        if (session === s) {
                            updateSignalingStatus(sessionId, remoteSignalingId, "sent offer")
                        }
                    }
                }.onFailure { error ->
                    if (error !is StaleWebRtcSessionOwnerException) {
                        failCurrentSession(owner, "signaling offer failed", "failed")
                    }
                }
            }
        }
        s.onLocalAnswer = { sdp ->
            scope.launch {
                if (!sessionOwnerGate.isCurrent(owner) || session !== s) return@launch
                runCatching {
                    sendSignalingEnvelope(
                        owner,
                        WebRtcSignalingEnvelope(
                            sessionId = sessionId,
                            from = localId,
                            type = WebRtcSignalingEnvelope.MessageType.ANSWER,
                            payload = WebRtcSignalingEnvelope.Payload(sdp = sdp),
                            sentAt = nowSeconds()
                        )
                    )
                }.onSuccess {
                    runIfCurrentSession(owner) {
                        if (session === s) {
                            updateSignalingStatus(sessionId, remoteSignalingId, "sent answer")
                        }
                    }
                }.onFailure { error ->
                    if (error !is StaleWebRtcSessionOwnerException) {
                        failCurrentSession(owner, "signaling answer failed", "failed")
                    }
                }
            }
        }
        s.onLocalIceCandidate = { payload ->
            scope.launch {
                if (!sessionOwnerGate.isCurrent(owner) || session !== s) return@launch
                runCatching {
                    sendSignalingEnvelope(
                        owner,
                        WebRtcSignalingEnvelope(
                            sessionId = sessionId,
                            from = localId,
                            type = WebRtcSignalingEnvelope.MessageType.ICE_CANDIDATE,
                            payload = payload,
                            sentAt = nowSeconds()
                        )
                    )
                }.onSuccess {
                    runIfCurrentSession(owner) {
                        if (session === s) {
                            updateSignalingStatus(sessionId, remoteSignalingId, "sent iceCandidate")
                        }
                    }
                }.onFailure { error ->
                    if (error !is StaleWebRtcSessionOwnerException) {
                        failCurrentSession(owner, "signaling ICE candidate failed", "failed")
                    }
                }
            }
        }
        s.onData = { raw ->
            runIfCurrentSession(owner) {
                if (session !== s) return@runIfCurrentSession
                // Pro release framing: 4-byte big-endian length prefix; frames may be chunked across DC messages.
                try {
                    for (frame in inboundFrames.push(raw)) {
                        handleInboundFrame(owner, frame)
                    }
                } catch (err: WebRtcDataChannelProtocolException) {
                    failSecureTransport(owner, "invalid datachannel frame: ${err.javaClass.simpleName}")
                }
            }
        }
        s.onProtocolViolation = { reason ->
            runIfCurrentSession(owner) {
                if (session !== s) return@runIfCurrentSession
                failSecureTransport(owner, "datachannel protocol violation: $reason")
            }
        }
        s.onReady = {
            runIfCurrentSession(owner) {
                if (session !== s) return@runIfCurrentSession
                Log.i(
                    "SB-HANDSHAKE",
                    "onReady session=${redactLogIdentifier(sessionId)} role=${s.role} hasKeys=${sessionKeys != null} initPending=${initiatorHandshake != null} respPending=${responderHandshake != null}"
                )
                _state.value = State.Connected(sessionId)
                updateSignalingStatus(sessionId, remoteSignalingId, "datachannel ready")
                scheduleHandshakeStart(owner, s.role)
            }
        }
        s.onDisconnected = { reason ->
            val safeReason = sanitizeStatusMessage(reason)
            if (session === s) {
                failCurrentSession(
                    owner,
                    "WebRTC transport disconnected: $safeReason",
                    signalingEventPrefix = "transport disconnected"
                )
            }
        }
        s.onDataChannelConfigStatus = { status ->
            runIfCurrentSession(owner) {
                if (session === s) {
                    _dataChannelConfigStatus.value = status
                }
            }
        }
        s.onSelectedRoute = { route ->
            runIfCurrentSession(owner) {
                if (session !== s) return@runIfCurrentSession
                check(selectedRouteStore.commit(owner, route)) {
                    "WebRTC selected route does not belong to the current owner"
                }
                Log.i(
                    "SB-WEBRTC",
                    "selectedRoute session=${redactLogIdentifier(owner.sessionId)} generation=${owner.generation} route=$route"
                )
            }
        }
    }

    private fun authenticatedEnvelope(
        owner: ProductSessionOwner,
        env: WebRtcSignalingEnvelope
    ): WebRtcSignalingEnvelope {
        check(env.sessionId == owner.sessionId) {
            "Signaling envelope session does not match its exact owner"
        }
        if (!env.authToken.isNullOrBlank()) return env
        val token = webrtcSignalingAuthTokenBySessionId[owner.sessionId]
        require(!token.isNullOrBlank()) { "Missing signaling authorization" }
        return env.copy(authToken = token)
    }

    private suspend fun sendSignalingEnvelope(
        owner: ProductSessionOwner,
        env: WebRtcSignalingEnvelope
    ) {
        lateinit var exactSignaling: WebSocketSignalingClient
        lateinit var outboundEnvelope: WebRtcSignalingEnvelope
        val prepared = runIfCurrentSession(owner) {
            check(signalingOwner == owner) {
                "WebRTC signaling connection is not owned by this session"
            }
            exactSignaling = signaling
            outboundEnvelope = authenticatedEnvelope(owner, env)
        }
        if (!prepared) {
            throw StaleWebRtcSessionOwnerException()
        }

        // Send through the client captured for this exact owner. A replacement may close it and
        // make this operation fail, but the stale operation can never spill into the replacement's
        // newly installed signaling connection.
        exactSignaling.send(outboundEnvelope)
        val stillCurrent = runIfCurrentSession(owner) {
            check(signaling === exactSignaling && signalingOwner == owner) {
                "WebRTC signaling connection changed during an owned send"
            }
        }
        if (!stillCurrent) {
            throw StaleWebRtcSessionOwnerException()
        }
    }

    private fun handleServerFrame(
        owner: ProductSessionOwner,
        frame: WebSocketSignalingClient.SignalingServerFrame
    ) {
        if (!sessionOwnerGate.isCurrent(owner)) return
        val sessionId = frame.sessionId ?: owner.sessionId
        if (sessionId != owner.sessionId) return
        val event = if (frame.isError) {
            "server error: ${sanitizeStatusMessage(frame.error ?: frame.type)}"
        } else {
            "server frame: ${frame.type}"
        }
        runIfCurrentSession(owner) {
            updateSignalingStatus(
                sessionId = sessionId,
                peerSignalingId = remoteSignalingId,
                lastEvent = event
            )
        }
        if (frame.isError) {
            failCurrentSession(
                owner,
                sanitizeStatusMessage(frame.error ?: frame.type),
                signalingEventPrefix = "server error"
            )
        }
    }

    private fun handleInboundFrame(owner: ProductSessionOwner, frame: ByteArray) {
        if (!sessionOwnerGate.isCurrent(owner)) return
        val sessionId = owner.sessionId
        val traffic = TrafficPaddingP2.unwrapIfNeeded(frame, "rx/webrtc")

        val keys = sessionKeys
        if (keys != null) {
            // Decrypt-first (safer): only treat non-decryptable frames as handshake/control.
            // App payloads arrive in the SBWC application-secure envelope; open() validates the
            // header (magic/version/packetType/direction/sessionHash/transcriptPrefix/epoch/counter)
            // and AES-256-GCM verifies with the full header as AAD, then the replay window enforces
            // per-(packetType,direction) monotonic counters. Frames that are not a valid SBWC app
            // envelope (e.g. handshake/rekey driver frames) fall through to handleHandshakeFrame.
            val role = secureEnvelopeRole()
            val envelopeResult = if (role != null) {
                runCatching {
                    val opened = WebRtcAppSecureEnvelope.open(
                        packet = traffic,
                        recvKey = keys.receiveKey,
                        role = role,
                        sessionId = secureEnvelopeSessionId(keys),
                        transcriptHash = keys.transcriptHash,
                        allowedPacketTypes = INBOUND_ALLOWED_PACKET_TYPES
                    )
                    webrtcSecureEnvelopeReplayWindow.validateAndRecord(opened)
                    opened
                }
            } else {
                null
            }
            val openedEnvelope = envelopeResult?.getOrNull()
            val plain = openedEnvelope?.payload
            if (plain != null) {
                val secureOwner = checkNotNull(secureOperationOwnerState.current(owner, keys)) {
                    "WebRTC secure payload has no current key-epoch owner"
                }
                if (openedEnvelope.packetType == WebRtcAppSecureEnvelope.PacketType.APP_CONTROL) {
                    val decoded = decodeAuthenticatedAppControl(owner, plain) ?: return
                    val app = when (decoded) {
                        is AppMessageCodec.DecodeResult.Known -> decoded.message
                        is AppMessageCodec.DecodeResult.UnknownType -> {
                            failSecureTransport(
                                owner = owner,
                                reason = "unsupported authenticated app-control message: ${decoded.type}"
                            )
                            return
                        }
                    }
                    if (app is AppMessage.PairingIdentityExchange) {
                        Log.i(
                            "SB-WEBRTC",
                            "pairingExchangeRecv session=${redactLogIdentifier(sessionId)} deviceId=${redactLogIdentifier(app.payload.deviceId)} keys=${app.payload.kemPublicKeys.size}"
                        )
                        if (!diagnosticsConfig.existingTrustOnly) {
                            updateAuthenticatedPeerMetadata(app.payload)
                        }
                        handlePairingIdentityExchange(owner, secureOwner, app.payload)
                        return
                    }
                    if (app is AppMessage.Heartbeat) {
                        Log.i(
                            "SB-WEBRTC",
                            "heartbeatRecv session=${redactLogIdentifier(sessionId)} formats=${app.payload.remoteVideoFormats?.joinToString(",") ?: "-"}"
                        )
                        updateAuthenticatedPeerMetadata(app.payload)
                    }
                    if (app is AppMessage.AuthenticatedRouteBinding) {
                        handleAuthenticatedRouteBinding(
                            owner = owner,
                            openedEnvelope = openedEnvelope,
                            payload = app.payload
                        )
                        return
                    }
                }
                onSecurePacketData?.invoke(secureOwner, plain, openedEnvelope.packetType)
                onOwnedPacketData?.invoke(owner, plain, openedEnvelope.packetType)
                onOwnedData?.invoke(owner, plain)
                onPacketData?.invoke(plain, openedEnvelope.packetType)
                onData?.invoke(plain)
                return
            }
            if (diagnosticsConfig.keepAliveHeartbeat) {
                Log.i(
                    "SB-WEBRTC",
                    "decryptMiss session=${redactLogIdentifier(sessionId)} bytes=${traffic.size} hasKeys=true"
                )
            }
            val handledAsHandshake = handleHandshakeFrame(owner, traffic)
            if (!handledAsHandshake) {
                val reason = envelopeResult?.exceptionOrNull()
                    ?.let { "secure envelope rejected: ${it.javaClass.simpleName}" }
                    ?: "unexpected secure-session frame"
                failSecureTransport(owner, reason)
            }
            return
        }

        // No keys yet: only handshake/control frames are meaningful.
        handleHandshakeFrame(owner, traffic)
    }

    private fun decodeAuthenticatedAppControl(
        owner: ProductSessionOwner,
        plaintext: ByteArray
    ): AppMessageCodec.DecodeResult? {
        return try {
            appMessageCodec.decodeAuthenticatedControl(plaintext)
        } catch (_: AppMessageCodec.DecodeException) {
            failSecureTransport(
                owner = owner,
                reason = "malformed authenticated app-control payload"
            )
            null
        }
    }

    private fun handleAuthenticatedRouteBinding(
        owner: ProductSessionOwner,
        openedEnvelope: WebRtcAppSecureEnvelope.Opened,
        payload: AppMessage.AuthenticatedRouteBindingPayload
    ) {
        val sessionId = owner.sessionId
        val consumer = routeBindingConsumer ?: run {
            failSecureTransport(owner, "authenticated route-binding store is unavailable")
            return
        }
        if (!sessionOwnerGate.isCurrent(owner)) {
            return
        }
        if (_state.value !is State.Established) {
            failSecureTransport(owner, "route-binding received before established product session")
            return
        }
        val authority = currentPathExpectedRemoteAuthorityBySessionId[sessionId] ?: run {
            failSecureTransport(owner, "route-binding remote authority is unavailable")
            return
        }

        runCatching {
            consumer.consume(
                payload = payload,
                context = AuthenticatedRouteBindingValidationContext(
                    sessionOwner = owner,
                    localDeviceId = localIdentity.deviceId(),
                    localProtocolPublicKeyFingerprint = currentPathLocalBinding().protocolPublicKeyFingerprint,
                    expectedRemoteDeviceId = authority.deviceId,
                    expectedRemotePublicKeyFingerprint = authority.protocolPublicKeyFingerprint,
                    sessionHashHex = unsignedLongHex16(openedEnvelope.sessionHash),
                    transcriptPrefixHex = unsignedLongHex16(openedEnvelope.transcriptPrefix),
                    nowEpochMillis = System.currentTimeMillis()
                )
            )
        }.onSuccess {
            productSessionAuthorityStore?.clearExpired(System.currentTimeMillis())
            Log.i(
                "SB-WEBRTC",
                "routeBindingAccepted session=${redactLogIdentifier(sessionId)} kind=${payload.kind}"
            )
        }.onFailure { err ->
            failSecureTransport(
                owner = owner,
                reason = "authenticated route-binding rejected: ${err.message ?: err.javaClass.simpleName}"
            )
        }
    }

    private fun failSecureTransport(owner: ProductSessionOwner, reason: String) {
        val safeReason = sanitizeStatusMessage(reason)
        Log.e("SB-WEBRTC", "secureTransportFailed session=${redactLogIdentifier(owner.sessionId)} reason=$safeReason")
        failCurrentSession(owner, safeReason, signalingEventPrefix = "secure transport failed")
    }

    private fun handleHandshakeFrame(owner: ProductSessionOwner, frame: ByteArray): Boolean {
        if (!sessionOwnerGate.isCurrent(owner)) return false
        val sessionId = owner.sessionId
        Log.i(
            "SB-HANDSHAKE",
            "recv session=${redactLogIdentifier(sessionId)} bytes=${frame.size} hasKeys=${sessionKeys != null} initPending=${initiatorHandshake != null} respPending=${responderHandshake != null}"
        )
        // Initiator handshake (initial or rekey): wait for MessageB + responder Finished, then send client Finished.
        val init = initiatorHandshake
        if (init != null) {
            val (st, client) = init
            if (isLikelyMessageA(frame)) {
                // Simultaneous open: if we should be responder, abandon initiator and respond.
                val local = localId
                val remote = remoteDeviceId ?: remoteSignalingId
                val shouldYield = when {
                    remote != null -> local > remote
                    session?.role == WebRtcSession.Role.OFFERER -> true
                    else -> false
                }
                if (shouldYield) {
                    initiatorHandshake = null
                    initiatorHandshakePhase = null
                    initiatorPendingMessageB = null
                    initiatorPendingResponderFinished = null
                    rekeyInProgress = false
                    // Continue below and treat this as inbound MessageA.
                } else {
                    return true
                }
            } else {
                if (isLikelyMessageB(frame)) {
                    initiatorPendingMessageB = frame
                } else if (isLikelyFinished(frame)) {
                    initiatorPendingResponderFinished = frame
                } else {
                    return false
                }

                val rawMessageB = initiatorPendingMessageB ?: return true
                val rawResponderFinished = initiatorPendingResponderFinished ?: return true
                val phase = initiatorHandshakePhase ?: HandshakePhase.INITIAL
                val messageB = runCatching { P2PHandshakeWire.decodeMessageB(rawMessageB) }.getOrElse { err ->
                    onHandshakeFailed(owner, phase, "messageB decode failed: ${err.message ?: "unknown"}")
                    return true
                }

                if (phase == HandshakePhase.INITIAL) {
                    runCatching {
                        validateCurrentPathRemoteAuthority(
                            sessionId = sessionId,
                            peerId = currentPeerId(),
                            identityPublicKeys = messageB.identityPublicKeys
                        )
                    }.onFailure { err ->
                        onHandshakeFailed(owner, phase, err.message ?: "current-path validation failed")
                        return true
                    }
                }

                val peerIdForTrust = currentPeerId()
                val currentAuthority = currentSessionId?.let(currentPathExpectedRemoteAuthorityBySessionId::get)
                val usePinnedTrustStore =
                    peerIdForTrust != null &&
                        currentAuthority?.protocolPublicKeyFingerprint.isNullOrBlank()
                val trustPeerId = peerIdForTrust?.takeIf { usePinnedTrustStore }
                val trustStore = if (usePinnedTrustStore) localIdentity.trustStore() else null
                val result = runCatching {
                    client.finish(
                        state = st,
                        rawMessageB = rawMessageB,
                        peerIdForTrust = trustPeerId,
                        trustStore = trustStore,
                        allowTrustOnFirstUse = false
                    )
                }.getOrElse { err ->
                    onHandshakeFailed(owner, phase, "handshake finish failed: ${err.message ?: "unknown"}")
                    return true
                }

                val okFinished = runCatching { client.verifyResponderFinished(rawResponderFinished, result.sessionKeys) }.getOrDefault(false)
                if (!okFinished) {
                    onHandshakeFailed(owner, phase, "responder finished MAC invalid")
                    return true
                }
                if (!sendHandshakeFrame(owner, result.clientFinishedToSend)) {
                    onHandshakeFailed(owner, phase, "send client finished failed")
                    return true
                }

                onHandshakeEstablished(
                    owner = owner,
                    keys = result.sessionKeys,
                    suite = result.negotiatedSuite,
                    phase = phase,
                    remoteProtocolIdentityFingerprint = result.remoteProtocolIdentityFingerprint
                )
                return true
            }
        }

        // Responder handshake: wait for MessageA then send MessageB + responder Finished, then verify client Finished.
        val existingResponder = responderHandshake
        if (existingResponder == null) {
            if (!isLikelyMessageA(frame)) return false

            val phase = if (sessionKeys == null) HandshakePhase.INITIAL else HandshakePhase.REKEY
            responderHandshakePhase = phase
            val messageA = runCatching { P2PHandshakeWire.decodeMessageA(frame) }.getOrElse { err ->
                onHandshakeFailed(owner, phase, "messageA decode failed: ${err.message ?: "unknown"}")
                return true
            }

            if (phase == HandshakePhase.INITIAL) {
                runCatching {
                    validateCurrentPathRemoteAuthority(
                        sessionId = sessionId,
                        peerId = currentPeerId(),
                        identityPublicKeys = messageA.identityPublicKeys
                    )
                }.onFailure { err ->
                    onHandshakeFailed(owner, phase, err.message ?: "current-path validation failed")
                    return true
                }
            }

            val policyOverride = effectivePolicyOverride()
            val peerIdForTrust = currentPeerId()
            val currentAuthority = currentSessionId?.let(currentPathExpectedRemoteAuthorityBySessionId::get)
            val usePinnedTrustStore =
                peerIdForTrust != null &&
                    currentAuthority?.protocolPublicKeyFingerprint.isNullOrBlank()
            val trustPeerId = peerIdForTrust?.takeIf { usePinnedTrustStore }
            val trustStore = if (usePinnedTrustStore) localIdentity.trustStore() else null
            val allowClassicBootstrap =
                peerIdForTrust != null &&
                    (
                        trustStore?.isPeerPinned(peerIdForTrust) == true ||
                            !currentAuthority?.protocolPublicKeyFingerprint.isNullOrBlank()
                    )
            val effectiveHandshakePolicy = policyOverride.forTrustedClassicBootstrap(
                enabled = allowClassicBootstrap
            )
            val allowQPeriapt = effectiveHandshakePolicy.minimumTierRaw == P2PQPeriaptKem.MINIMUM_TIER_RAW
            val kem = localIdentity.getOrCreateKemIdentityKeys(allowQPeriapt = allowQPeriapt)
            val signKeys = localIdentity.getOrCreateProtocolSigningKeys()
            val protocolSigningKeys = P2PProtocolSigningKeys(
                ed25519PrivateKey = signKeys.ed25519PrivateKey,
                ed25519PublicKeyRaw32 = signKeys.ed25519PublicRaw32,
                mlDsa65PrivateKeyRaw = signKeys.mlDsa65PrivateKeyRaw,
                mlDsa65PublicKeyRaw = signKeys.mlDsa65PublicKeyRaw
            )

            val server = P2PHandshakeServer()
            val resp = runCatching {
                server.respond(
                    rawMessageA = frame,
                    peerIdForTrust = trustPeerId,
                    trustStore = trustStore,
                    allowTrustOnFirstUse = false,
                    options = P2PHandshakeServer.RespondOptions(
                        platformVersion = QPeriaptPlatformPolicy.androidHandshakePlatformVersion(
                            release = Build.VERSION.RELEASE,
                            sdkInt = Build.VERSION.SDK_INT
                        ),
                        kemPrivateKeys = P2PHandshakeServer.KemPrivateKeys(
                            qPeriaptPrivateKey = kem.qPeriaptPrivateKey,
                            xWingPrivateKey = kem.xWingPrivateKey,
                            mlKem768PrivateKey = kem.mlKem768PrivateKey
                        ),
                        handshakePolicy = effectiveHandshakePolicy.toWirePolicy(),
                        allowClassicBootstrapForTrustedPeer = allowClassicBootstrap,
                        protocolSigningKeys = protocolSigningKeys
                    )
                )
            }.getOrElse { err ->
                onHandshakeFailed(owner, phase, "handshake respond failed: ${err.message ?: "unknown"}")
                return true
            }

            responderHandshake = resp.state to server
            responderNegotiatedSuite = runCatching {
                val msgB = P2PHandshakeWire.decodeMessageB(resp.messageBToSend)
                (msgB.selectedSuite as? com.skybridge.compass.shared.p2p.P2PCryptoSuiteId.Known)?.suite
            }.getOrNull()

            if (!sendHandshakeFrame(owner, resp.messageBToSend)) {
                onHandshakeFailed(owner, phase, "send messageB failed")
                return true
            }
            val responderFinished = server.buildResponderFinished(resp.state.sessionKeys)
            if (!sendHandshakeFrame(owner, responderFinished)) {
                onHandshakeFailed(owner, phase, "send responder finished failed")
                return true
            }
            return true
        } else {
            if (!isLikelyFinished(frame)) return false
            val (st, server) = existingResponder
            val phase = responderHandshakePhase ?: HandshakePhase.INITIAL
            val ok = runCatching { server.verifyClientFinished(frame, st.sessionKeys) }.getOrDefault(false)
            if (!ok) {
                onHandshakeFailed(owner, phase, "client finished MAC invalid")
                return true
            }
            val suite = responderNegotiatedSuite ?: negotiatedSuite
            onHandshakeEstablished(
                owner = owner,
                keys = st.sessionKeys,
                suite = suite,
                phase = phase,
                remoteProtocolIdentityFingerprint = st.remoteProtocolIdentityFingerprint
            )
            return true
        }
    }

    private fun validateCurrentPathRemoteAuthority(
        sessionId: String,
        peerId: String?,
        identityPublicKeys: P2PIdentityPublicKeys.Keys
    ) {
        val expected = currentPathExpectedRemoteAuthorityBySessionId[sessionId] ?: return
        if (peerId != null) {
            require(peerId == expected.deviceId) {
                "Unexpected remote deviceId: expected ${expected.deviceId}, got $peerId"
            }
        }
        val actualAlgorithm = ProtocolSigningAlgorithm.fromIdentityAlgorithm(identityPublicKeys.protocolAlgorithm)
            ?: throw IllegalArgumentException("Unsupported current-path signing algorithm")
        require(actualAlgorithm == expected.protocolSigningAlgorithm) {
            "Unexpected remote signing algorithm"
        }
        val actualFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm = actualAlgorithm,
            publicKeyBytes = identityPublicKeys.protocolPublicKey
        )
        require(actualFingerprint.equals(expected.protocolPublicKeyFingerprint, ignoreCase = true)) {
            "Remote signing fingerprint mismatch"
        }
    }

    private fun onHandshakeEstablished(
        owner: ProductSessionOwner,
        keys: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys,
        suite: com.skybridge.compass.shared.p2p.P2PCryptoSuite?,
        phase: HandshakePhase,
        remoteProtocolIdentityFingerprint: String
    ) {
        runIfCurrentSession(owner) {
            val sessionCode = owner.sessionId
            val current = _state.value
            // 任务 9.9 / R4.8：密钥更新连续性。REKEY 阶段在 Connected 或 Established 下都保持会话
            // 为已建立——一次成功的密钥更新以新密钥继续，不撕毁已建立会话、不丢已确认数据。
            val shouldEstablish = when (phase) {
                HandshakePhase.INITIAL -> current is State.Connected
                HandshakePhase.REKEY -> current is State.Connected || current is State.Established
            }
            if (!shouldEstablish) {
                Log.w(
                    "SB-HANDSHAKE",
                    "ignored established handshake for inactive session=${redactLogIdentifier(sessionCode)} phase=$phase state=${current.javaClass.simpleName}"
                )
                return@runIfCurrentSession
            }

            val authorityResult = productSessionAuthorityStore?.clearEstablishedAuthority(owner)
            if (authorityResult != null && authorityResult != ProductSessionMutationResult.APPLIED) {
                logRejectedAuthorityMutation("rekey product session authority", owner, authorityResult)
                failCurrentSession(
                    owner,
                    reason = "product session authority owner was replaced",
                    signalingEventPrefix = "handshake failed"
                )
                return@runIfCurrentSession
            }

            Log.i("SB-HANDSHAKE", "established session=${redactLogIdentifier(sessionCode)} suite=${suite?.name ?: "unknown"} phase=$phase")
            // New session keys (initial or rekey) => restart SBWC counters / replay lanes / sessionId
            // cache so the outbound counter begins at 1 against the freshly derived keys.
            // REKEY 阶段不擦除仍在服务中的旧密钥引用；这里只原子切换到新密钥并重置新 replay lane。
            resetSecureEnvelopeState()
            sessionKeys = keys
            observedHandshakeAuthority = ObservedHandshakeAuthority(
                owner = owner,
                protocolFingerprint = remoteProtocolIdentityFingerprint
            )
            val secureOwner = secureOperationOwnerState.replace(owner, keys)
            existingTrustPeerKemAdmissionState.clear()
            pairingExchangeSent = false
            lastSentPairingExchangeFingerprint = null
            if (pendingJoinBootstrapKem?.owner == owner) {
                pendingJoinBootstrapKem = null
            }
            negotiatedSuite = suite
            initiatorHandshake = null
            initiatorHandshakePhase = null
            initiatorPendingMessageB = null
            initiatorPendingResponderFinished = null
            responderHandshake = null
            responderHandshakePhase = null
            responderNegotiatedSuite = null

            if (phase == HandshakePhase.REKEY) {
                rekeyInProgress = false
                authenticatedSessionPeerKemStore.applyLifecycleEvent(
                    owner,
                    AuthenticatedSessionPeerKemLifecycleEvent.REKEY_SUCCEEDED
                )
            }

            _state.value = State.Established(sessionCode)
            cancelEstablishmentDeadline()
            updateSignalingStatus(
                sessionId = sessionCode,
                peerSignalingId = remoteSignalingId,
                lastEvent = "handshake established: ${suite?.name ?: "unknown"}"
            )

            scope.launch {
                sendPairingIdentityExchangeIfNeeded(
                    owner = owner,
                    force = false,
                    secureOwner = secureOwner,
                )
            }
            startAppHeartbeatLoop(owner)
            scope.launch { maybeStartPqcRekey(owner, trigger = "post_handshake") }
        }
    }

    private fun onHandshakeFailed(
        owner: ProductSessionOwner,
        phase: HandshakePhase,
        message: String
    ) {
        val safeMessage = sanitizeStatusMessage(message)
        runIfCurrentSession(owner) {
            Log.e(
                "SB-HANDSHAKE",
                "failed session=${redactLogIdentifier(owner.sessionId)} phase=$phase message=$safeMessage"
            )
            updateSignalingStatus(
                sessionId = owner.sessionId,
                peerSignalingId = remoteSignalingId,
                lastEvent = "handshake failed: $safeMessage"
            )
            // Initial handshake failures are fatal; rekey failures keep the established keys.
            if (phase == HandshakePhase.REKEY) {
                initiatorHandshake = null
                initiatorHandshakePhase = null
                initiatorPendingMessageB = null
                initiatorPendingResponderFinished = null
                responderHandshake = null
                responderHandshakePhase = null
                responderNegotiatedSuite = null
                rekeyInProgress = false
                authenticatedSessionPeerKemStore.applyLifecycleEvent(
                    owner,
                    AuthenticatedSessionPeerKemLifecycleEvent.REKEY_FAILED
                )
            } else {
                failCurrentSession(owner, safeMessage, signalingEventPrefix = "handshake failed")
            }
        }
    }

    /**
     * 启动单次连接建立的整体时限看门狗（任务 9.7 / R4.1）。
     *
     * 自本次连接建立起点（用户选择设备、[prepareForSessionStart]）计时，若在
     * [establishmentDeadline] 的整体上限（design §4 的 30s 端到端）内会话仍未被呈现为已建立
     * （即应用层会话密钥未建立、状态未进入 [State.Established]），则如实以「超时」失败：
     * 把状态置为 [State.Failed]，经既有 signaling-status 叶节点呈现失败原因分类（不新增屏幕、G2），
     * 并通过 exact-owner 的 [failCurrentSession] 释放本次尝试已分配的连接资源。
     */
    private fun armEstablishmentDeadline(owner: ProductSessionOwner) {
        establishmentDeadlineTask?.cancel()
        establishmentDeadline.start()
        establishmentDeadlineTask = scope.launch {
            delay(establishmentDeadline.overallDeadline.inWholeMilliseconds)
            if (!sessionOwnerGate.isCurrent(owner)) return@launch
            // 会话密钥是否已建立决定终态：仅当应用层会话密钥已建立才视为已建立（R4.2 不变式）。
            val outcome = establishmentDeadline.evaluateOnDeadline(
                appLayerSessionKeysEstablished = hasSessionKeys()
            )
            if (outcome is ConnectionEstablishmentDeadline.Outcome.TimedOut) {
                onEstablishmentDeadlineExpired(owner, outcome.category)
            }
        }
    }

    /** 取消整体时限看门狗并停用时限（会话成功建立、失败或被清理时调用）。 */
    private fun cancelEstablishmentDeadline() {
        establishmentDeadlineTask?.cancel()
        establishmentDeadlineTask = null
        establishmentDeadline.clear()
    }

    /**
     * 整体建立时限到期且会话仍未呈现为已建立时的处置（R4.1 / R4.4）。
     *
     * 只在时限对应的会话仍是当前活跃会话、且尚未进入终态（已建立 / 已失败）时生效，
     * 避免迟到的时限迁移把一个已成功或已失败的会话错误改写。
     */
    private fun onEstablishmentDeadlineExpired(
        owner: ProductSessionOwner,
        category: com.skybridge.compass.shared.p2p.HandshakeFailureCategory
    ) {
        if (!sessionOwnerGate.isCurrent(owner)) return
        val sessionId = owner.sessionId
        val current = _state.value
        if (current is State.Established || current is State.Failed) return
        // 如实呈现：失败原因分类恒为「超时」（timeout），不隐瞒、不改分类（R4.4）。
        val reason = "connection establishment deadline exceeded: ${category.diagnosticCode}"
        Log.w(
            "SB-WEBRTC",
            "establishment deadline expired session=${redactLogIdentifier(sessionId)} category=${category.diagnosticCode}"
        )
        failCurrentSession(
            owner,
            reason = reason,
            signalingEventPrefix = "establishment timeout"
        )
    }

    private fun handlePairingIdentityExchange(
        owner: ProductSessionOwner,
        secureOwner: WebRtcSecureOperationOwner,
        payload: AppMessage.PairingIdentityExchangePayload
    ) {
        scope.launch {
            processIncomingPairingIdentityExchange(owner, secureOwner, payload)
        }
    }

    private fun updateAuthenticatedPeerMetadata(payload: AppMessage.PairingIdentityExchangePayload) {
        val deviceId = payload.deviceId.normalizedMetadataString() ?: return
        _authenticatedPeerMetadata.value = AuthenticatedPeerMetadata(
            deviceId = deviceId,
            deviceName = payload.deviceName.normalizedMetadataString(),
            accountDisplayName = payload.accountDisplayName.normalizedMetadataString(),
            nebulaId = payload.nebulaId.normalizedNebulaId(),
            platform = payload.platform.normalizedMetadataString(),
            modelName = payload.modelName.normalizedMetadataString(),
            osVersion = payload.osVersion.normalizedMetadataString(),
            chip = payload.chip.normalizedMetadataString(),
            capabilities = payload.capabilities.normalizedMetadataList(),
            remoteVideoFormats = payload.remoteVideoFormats.normalizedMetadataList()
        )
    }

    private fun updateAuthenticatedPeerMetadata(payload: AppMessage.HeartbeatPayload) {
        val existing = _authenticatedPeerMetadata.value
        val deviceId = payload.deviceId.normalizedMetadataString()
            ?: existing?.deviceId
            ?: return
        _authenticatedPeerMetadata.value = AuthenticatedPeerMetadata(
            deviceId = deviceId,
            deviceName = payload.deviceName.normalizedMetadataString() ?: existing?.deviceName,
            accountDisplayName = payload.accountDisplayName.normalizedMetadataString() ?: existing?.accountDisplayName,
            nebulaId = payload.nebulaId.normalizedNebulaId() ?: existing?.nebulaId,
            platform = payload.platform.normalizedMetadataString() ?: existing?.platform,
            modelName = payload.modelName.normalizedMetadataString() ?: existing?.modelName,
            osVersion = payload.osVersion.normalizedMetadataString() ?: existing?.osVersion,
            chip = payload.chip.normalizedMetadataString() ?: existing?.chip,
            capabilities = payload.capabilities.normalizedMetadataList() ?: existing?.capabilities,
            remoteVideoFormats = payload.remoteVideoFormats.normalizedMetadataList() ?: existing?.remoteVideoFormats
        )
    }

    private fun String?.normalizedMetadataString(): String? =
        this?.trim()?.takeIf { it.isNotEmpty() }

    private fun String?.normalizedNebulaId(): String? =
        NebulaId.parseOrNull(this)?.value

    private fun List<String>?.normalizedMetadataList(): List<String>? =
        this
            ?.mapNotNull { it.normalizedMetadataString() }
            ?.distinct()
            ?.takeIf { it.isNotEmpty() }

    private suspend fun processIncomingPairingIdentityExchange(
        owner: ProductSessionOwner,
        secureOwner: WebRtcSecureOperationOwner,
        payload: AppMessage.PairingIdentityExchangePayload
    ) = pairingIdentityExchangeMutex.withLock {
        processIncomingPairingIdentityExchangeLocked(owner, secureOwner, payload)
    }

    private suspend fun processIncomingPairingIdentityExchangeLocked(
        owner: ProductSessionOwner,
        secureOwner: WebRtcSecureOperationOwner,
        payload: AppMessage.PairingIdentityExchangePayload
    ) {
        var attemptSnapshot: PairingPersistenceAttemptSnapshot? = null
        if (!runIfCurrentSession(owner) {
                val observed = observedHandshakeAuthority?.takeIf { it.owner == owner }
                if (observed != null) {
                    attemptSnapshot = PairingPersistenceAttemptSnapshot(
                        observedAuthority = observed,
                        priorPeerId = currentPeerId(),
                        remoteSignalingId = remoteSignalingId,
                        expectedAuthority = currentPathExpectedRemoteAuthorityBySessionId[owner.sessionId]
                    )
                }
            }
        ) {
            return
        }
        val snapshot = attemptSnapshot ?: run {
            failSecureOperation(secureOwner, "authenticated product-session KEM authority is unavailable")
            return
        }
        val observedAuthority = snapshot.observedAuthority
        val observedProtocolFingerprint = observedAuthority.protocolFingerprint
        val priorPeerId = snapshot.priorPeerId
        val peerId = AuthenticatedPairingBindingNormalization.peerId(
            payload.deviceId.ifBlank { priorPeerId } ?: return
        ) ?: run {
            failSecureOperation(secureOwner, "authenticated peer identifier is invalid")
            return
        }
        val aliasIds = buildSet {
            add(peerId)
            priorPeerId?.let { add(it) }
            snapshot.remoteSignalingId?.let { add(it) }
        }
        val trustedPeerStore = localIdentity.trustedPeerStore()
        val currentAuthority = snapshot.expectedAuthority
        if (currentAuthority != null &&
            !currentAuthority.protocolPublicKeyFingerprint.equals(
                observedProtocolFingerprint,
                ignoreCase = true
            )
        ) {
            failSecureOperation(secureOwner, "authenticated product-session authority binding changed")
            return
        }
        if (diagnosticsConfig.existingTrustOnly) {
            val admission = trustedPeerStore.evaluateExactExistingAuthorityReadOnly(
                deviceIds = aliasIds,
                protocolPublicKeyFingerprint = observedProtocolFingerprint
            )
            if (admission.conflict != null || admission.exactAuthority == null) {
                failSecureOperation(secureOwner, "formal diagnostic requires exact existing peer trust")
                return
            }
            val presentedKem = try {
                PeerKemKeyStoreRecords.materialize(
                    kemPublicKeys = payload.kemPublicKeys,
                    platform = payload.platform,
                    osVersion = payload.osVersion
                )
            } catch (_: IllegalArgumentException) {
                failSecureOperation(secureOwner, "formal diagnostic peer KEM material is invalid")
                return
            }
            val existingKem = try {
                peerKemStore.loadVerifiedReadOnly(peerId)
            } catch (_: RuntimeException) {
                failSecureOperation(secureOwner, "formal diagnostic existing peer KEM trust is unreadable")
                return
            }
            if (!existingKem.hasSamePeerKemMaterial(presentedKem)) {
                failSecureOperation(secureOwner, "formal diagnostic peer KEM trust is missing or changed")
                return
            }
            var admitted = false
            val current = runIfCurrentSession(owner) {
                if (observedHandshakeAuthority == observedAuthority) {
                    remoteDeviceId = peerId
                    admitted = true
                }
            }
            if (!current || !admitted) {
                failSecureOperation(
                    secureOwner,
                    "formal diagnostic pairing attempt was replaced before existing-trust admission"
                )
                return
            }
            if (
                !isCurrentSecureOperationOwner(secureOwner) ||
                !existingTrustPeerKemAdmissionState.wasSentBy(secureOwner)
            ) {
                failSecureOperation(
                    secureOwner,
                    "formal diagnostic pairing response has no exact-epoch request"
                )
                return
            }
            existingTrustPeerKemAdmissionState.install(secureOwner)
            updateAuthenticatedPeerMetadata(payload)
            maybeStartPqcRekey(owner, trigger = "existing_pairing_identity_exchange")
            return
        }
        val storeConflict = trustedPeerStore.corruptionConflictOrNull()
        val exactExistingAuthority = if (storeConflict == null) {
            trustedPeerStore.findExactVerifiedAuthorityReadOnly(
                deviceIds = aliasIds,
                protocolPublicKeyFingerprint = observedProtocolFingerprint
            )
        } else {
            null
        }
        val conflict = storeConflict ?: aliasIds.asSequence()
            .mapNotNull { deviceId ->
                trustedPeerStore.evaluateCurrentPathBinding(
                    deviceId = deviceId,
                    protocolPublicKeyFingerprint = observedProtocolFingerprint
                )
            }
            .firstOrNull()
        val request = PairingTrustRequest(
            peerId = priorPeerId ?: peerId,
            declaredDeviceId = peerId,
            deviceName = payload.deviceName ?: currentAuthority?.deviceName,
            platform = payload.platform,
            modelName = payload.modelName,
            osVersion = payload.osVersion,
            chip = payload.chip,
            protocolPublicKeyFingerprint = observedProtocolFingerprint,
            conflict = conflict
        )
        val decision = when {
            conflict != null -> {
                val explicitDecision = PairingTrustManager.requestDecision(request)
                if (conflict == PairingTrustConflict.DEVICE_ID_MIGRATION_REQUIRED) {
                    explicitDecision
                } else {
                    PairingTrustDecision.DECLINE
                }
            }
            else -> PairingTrustManager.requestDecision(
                request = request,
                isKnownDevice = exactExistingAuthority != null
            )
        }
        if (decision == PairingTrustDecision.DECLINE) return
        if (!sessionOwnerGate.isCurrent(owner) || observedHandshakeAuthority != observedAuthority) {
            failSecureOperation(secureOwner, "authenticated pairing attempt was replaced before approval")
            return
        }

        var persistenceOutcome: AuthenticatedPairingPersistenceOutcome? = null
        var persistenceFailure: String? = null
        val committed = runIfCurrentSession(owner) {
            if (observedHandshakeAuthority != observedAuthority) {
                persistenceFailure = "authenticated pairing attempt was replaced before persistence"
                return@runIfCurrentSession
            }
            remoteDeviceId = peerId
            try {
                val outcome = AuthenticatedPairingPersistence(
                    trustedPeerStore = trustedPeerStore,
                    peerKemStore = peerKemStore
                ).persistApprovedAttemptWithOutcome(
                    decision = decision,
                    declaredDeviceId = peerId,
                    aliasIds = aliasIds,
                    observedProtocolFingerprint = observedProtocolFingerprint,
                    deviceName = payload.deviceName?.trim()?.takeIf { it.isNotEmpty() }
                        ?: currentAuthority?.deviceName,
                    protocolSigningAlgorithm = currentAuthority?.protocolSigningAlgorithm?.rawValue
                        ?: exactExistingAuthority?.protocolSigningAlgorithm,
                    kemPublicKeys = payload.kemPublicKeys,
                    platform = payload.platform,
                    osVersion = payload.osVersion
                )
                if (outcome.disposition == AuthenticatedPairingPersistenceResult.SESSION_ONLY) {
                    authenticatedSessionPeerKemStore.install(owner, outcome)
                } else {
                    authenticatedSessionPeerKemStore.applyLifecycleEvent(
                        owner,
                        AuthenticatedSessionPeerKemLifecycleEvent.DURABLE_MATERIAL_COMMITTED
                    )
                }
                persistenceOutcome = outcome
            } catch (_: AuthenticatedPairingPartialPersistenceException) {
                persistenceFailure =
                    "approved trust is durable but authenticated KEM persistence failed"
            } catch (_: AuthenticatedSessionPeerKemBindingException) {
                persistenceFailure = "authenticated session KEM binding was rejected"
            } catch (_: TrustedPeerStoreCorruptionException) {
                persistenceFailure = "trusted peer store is corrupted"
            } catch (_: TrustedPeerStorePersistenceException) {
                persistenceFailure = "trusted peer persistence rejected"
            } catch (_: PeerKemKeyStorePersistenceException) {
                persistenceFailure = "authenticated product-session KEM persistence failed"
            }
        }
        if (!committed) return
        persistenceFailure?.let { failure ->
            failSecureOperation(secureOwner, failure)
            return
        }
        persistenceOutcome ?: return

        sendPairingIdentityExchangeIfNeeded(owner, force = true)
        maybeStartPqcRekey(owner, trigger = "pairing_identity_exchange")
    }

    private suspend fun sendPairingIdentityExchangeIfNeeded(
        owner: ProductSessionOwner,
        force: Boolean,
        secureOwner: WebRtcSecureOperationOwner? = null,
    ): Boolean {
        if (!sessionOwnerGate.isCurrent(owner)) return false
        if (!pqcEnabled) return false
        if (sessionKeys == null) return false
        if (secureOwner != null && !isCurrentSecureOperationOwner(secureOwner)) return false
        val now = SwiftDateSeconds.now()
        val policy = effectivePolicyOverride()
        val businessIdentity = localBusinessIdentity()
        val payload = localIdentity.buildPairingIdentityExchange(
            nowSwiftSeconds = now,
            platform = "Android",
            allowQPeriapt = policy.minimumTierRaw == P2PQPeriaptKem.MINIMUM_TIER_RAW,
            accountDisplayName = businessIdentity?.accountDisplayName,
            nebulaId = businessIdentity?.nebulaId
        )
        val payloadFingerprint = pairingExchangeFingerprint(payload)
        val payloadChanged = payloadFingerprint != lastSentPairingExchangeFingerprint
        if (!force && pairingExchangeSent && !payloadChanged) return true
        Log.i(
            "SB-WEBRTC",
            "pairingExchangeSend session=${redactLogIdentifier(currentSessionId)} deviceId=${redactLogIdentifier(payload.deviceId)} keys=${payload.kemPublicKeys.size} force=$force changed=$payloadChanged"
        )
        val encoded = appMessageCodec.encode(AppMessage.PairingIdentityExchange(payload))
        val formalExactOwner = secureOwner?.takeIf { diagnosticsConfig.existingTrustOnly }
        formalExactOwner?.let(existingTrustPeerKemAdmissionState::beginSend)
        val transportSent = if (secureOwner == null) {
            send(owner, encoded)
        } else {
            send(secureOwner, encoded)
        }
        val sent = if (formalExactOwner == null) {
            transportSent
        } else {
            existingTrustPeerKemAdmissionState.finishSend(
                owner = formalExactOwner,
                transportDelivered = transportSent,
            )
        }
        if (sent) {
            runIfCurrentSession(owner) {
                pairingExchangeSent = true
                lastSentPairingExchangeFingerprint = payloadFingerprint
            }
        }
        return sent
    }

    private fun startAppHeartbeatLoop(owner: ProductSessionOwner) {
        appHeartbeatTask?.cancel()
        appHeartbeatTask = scope.launch {
            val intervalMillis = if (diagnosticsConfig.keepAliveHeartbeat) {
                1_000L
            } else {
                2_000L
            }
            while (sessionOwnerGate.isCurrent(owner) && sessionKeys != null) {
                if (handshakeInProgress()) {
                    delay(250L)
                    continue
                }
                val businessIdentity = localBusinessIdentity()
                val heartbeat = AppMessage.Heartbeat(
                    AppMessage.HeartbeatPayload(
                        sentAt = SwiftDateSeconds.now(),
                        deviceId = localIdentity.deviceId(),
                        deviceName = localIdentity.deviceName(),
                        modelName = Build.MODEL,
                        platform = "Android",
                        osVersion = AndroidPlatformMetadata.versionString(Build.VERSION.RELEASE, Build.VERSION.SDK_INT),
                        remoteVideoFormats = AndroidRemoteVideoFormats.supportedStreamingFormats(),
                        capabilities = androidBusinessCapabilities(),
                        accountDisplayName = businessIdentity?.accountDisplayName,
                        nebulaId = businessIdentity?.nebulaId
                    )
                )
                var sent = false
                if (!runIfCurrentSession(owner) {
                        sent = send(appMessageCodec.encode(heartbeat))
                    }
                ) {
                    break
                }
                if (diagnosticsConfig.keepAliveHeartbeat) {
                    Log.i(
                        "SB-WEBRTC",
                        "smokeHeartbeat session=${redactLogIdentifier(owner.sessionId)} generation=${owner.generation} sent=$sent"
                    )
                }
                if (!sent) break
                delay(intervalMillis)
            }
        }
    }

    private suspend fun maybeStartPqcRekey(owner: ProductSessionOwner, trigger: String) {
        if (!sessionOwnerGate.isCurrent(owner)) return
        if (!pqcEnabled) return
        if (rekeyInProgress || rekeyAttempted) return
        if (handshakeInProgress()) return
        if (sessionKeys == null) return
        val suite = negotiatedSuite ?: return
        if (suite.isPqc) return
        val policy = effectivePolicyOverride()
        val allowQPeriapt = policy.minimumTierRaw == P2PQPeriaptKem.MINIMUM_TIER_RAW
        val localKem = localIdentity.getOrCreateKemIdentityKeys(allowQPeriapt = allowQPeriapt)
        if (localKem.qPeriaptPublicKey == null && localKem.xWingPublicKey == null && localKem.mlKem768PublicKey == null) return
        var capturedPeerId: String? = null
        var sessionKemLookup: AuthenticatedSessionPeerKemLookup? = null
        if (!runIfCurrentSession(owner) {
                capturedPeerId = currentPeerId()
                val observedFingerprint = observedHandshakeAuthority
                    ?.takeIf { authority -> authority.owner == owner }
                    ?.protocolFingerprint
                sessionKemLookup = authenticatedSessionPeerKemStore.lookup(
                    owner = owner,
                    peerId = capturedPeerId,
                    observedProtocolFingerprint = observedFingerprint
                )
            }
        ) {
            return
        }
        val peerId = capturedPeerId ?: return
        val peerKem = try {
            resolveAuthenticatedSessionPeerKemForRekey(
                lookup = sessionKemLookup
                    ?: throw AuthenticatedSessionPeerKemBindingException(),
                persistentLoader = { peerKemStore.loadVerifiedReadOnly(peerId) }
            )
        } catch (_: AuthenticatedSessionPeerKemBindingException) {
            failSecureTransport(owner, "authenticated session KEM binding was rejected")
            return
        } catch (_: PeerKemKeyStoreCorruptionException) {
            failSecureTransport(owner, "authenticated peer KEM provenance is corrupted")
            return
        } catch (_: TrustedPeerStoreCorruptionException) {
            failSecureTransport(owner, "trusted peer store is corrupted")
            return
        }
        if (peerKem.qPeriaptPublicKey == null && peerKem.xWingPublicKey == null && peerKem.mlKem768PublicKey == null) return
        val shouldInitiate = shouldInitiatePqcRekey(
            localDeviceId = localIdentity.deviceId(),
            remoteDeviceId = peerId
        ) ?: return
        if (!shouldInitiate) return

        // Start a second handshake over the established channel (un-encrypted frames) to upgrade to PQC.
        runIfCurrentSession(owner) {
            rekeyInProgress = true
            rekeyAttempted = true
            startInitiatorHandshake(
                owner = owner,
                peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                    qPeriaptPublicKey = peerKem.qPeriaptPublicKey,
                    xWingPublicKey = peerKem.xWingPublicKey,
                    mlKem768PublicKey = peerKem.mlKem768PublicKey
                ),
                phase = HandshakePhase.REKEY,
                trigger = trigger
            )
            if (initiatorHandshake == null) {
                rekeyInProgress = false
            }
        }
    }

    private fun currentPeerId(): String? =
        remoteDeviceId ?: remoteSignalingId

    private fun handshakeInProgress(): Boolean =
        initiatorHandshake != null ||
            initiatorHandshakePhase != null ||
            responderHandshake != null ||
            responderHandshakePhase != null

    private fun pairingExchangeFingerprint(payload: AppMessage.PairingIdentityExchangePayload): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(payload.deviceId.toByteArray(Charsets.UTF_8))
        payload.kemPublicKeys
            .sortedBy { it.suiteWireId }
            .forEach { key ->
                digest.update(key.suiteWireId.toString().toByteArray(Charsets.UTF_8))
                digest.update(key.publicKey)
            }
        payload.remoteVideoFormats
            ?.map { it.lowercase() }
            ?.sorted()
            ?.forEach { format ->
                digest.update(format.toByteArray(Charsets.UTF_8))
        }
        payload.capabilities
            ?.map { it.lowercase() }
            ?.sorted()
            ?.forEach { capability ->
                digest.update(capability.toByteArray(Charsets.UTF_8))
            }
        payload.accountDisplayName
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { digest.update(it.toByteArray(Charsets.UTF_8)) }
        payload.nebulaId
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { digest.update(it.toByteArray(Charsets.UTF_8)) }
        return Base64.encodeToString(digest.digest(), Base64.NO_WRAP)
    }

    private fun androidBusinessCapabilities(): List<String> =
        listOf(
            "webrtcMedia",
            "remoteControl",
            "clipboard",
            "fileTransfer"
        )

    private fun shouldInitiatePqcRekey(localDeviceId: String?, remoteDeviceId: String?): Boolean? {
        val local = canonicalPqcRekeyElectionDeviceId(localDeviceId) ?: return null
        val remote = canonicalPqcRekeyElectionDeviceId(remoteDeviceId) ?: return null
        if (local == remote) return null
        return local < remote
    }

    private fun canonicalPqcRekeyElectionDeviceId(raw: String?): String? {
        val trimmed = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        if (trimmed.startsWith("webrtc-")) return null
        return trimmed
    }

    private fun effectivePolicyOverride(): P2PHandshakePolicyOverride {
        if (!pqcEnabled) {
            return P2PHandshakePolicyOverride(
                requirePqc = false,
                allowClassicFallback = true,
                minimumTierRaw = "classic",
                requireSecureEnclavePoP = false,
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_CLASSIC
            )
        }
        return handshakePolicyOverride ?: localIdentity.defaultHandshakePolicyOverride()
    }

    private fun startInitiatorHandshake(
        owner: ProductSessionOwner,
        peerKemPublicKeys: P2PHandshakeClient.PeerKemPublicKeys,
        phase: HandshakePhase,
        trigger: String
    ) {
        if (!sessionOwnerGate.isCurrent(owner)) return
        if (handshakeInProgress()) return

        val peerId = currentPeerId()
        val peerKem = peerKemPublicKeys
        val policyOverride = effectivePolicyOverride()
        val currentAuthority = currentPathExpectedRemoteAuthorityBySessionId[owner.sessionId]
        val hasAuthoritativeCurrentPathIdentity =
            !currentAuthority?.protocolPublicKeyFingerprint.isNullOrBlank()
        // The trusted-classic-bootstrap shortcut emits a classic-ONLY INITIAL (provider =
        // CryptoKit-classic). A strict-PQC peer (the Apple macOS/iOS default) rejects an INITIAL
        // that advertises no PQC group via StrictPQCAdmissionGate, killing the session before any
        // rekey can happen. When we can do PQC, offer it directly in the INITIAL instead of taking
        // the classic shortcut; classic-only peers are still reachable via allowClassicFallback.
        val allowClassicBootstrap =
            phase == HandshakePhase.INITIAL &&
            peerId != null &&
            !pqcEnabled &&
                (
                    localIdentity.trustStore().isPeerPinned(peerId) ||
                        hasAuthoritativeCurrentPathIdentity
                )
        val effectiveHandshakePolicy = policyOverride.forTrustedClassicBootstrap(
            enabled = allowClassicBootstrap
        ).let {
            // A strict-PQC peer canonicalizes the offered policy to allowClassicFallback=false in
            // its MessageA transcript re-encode; if we advertise allowClassicFallback=true our
            // transcriptA diverges by one byte and MessageB signature verification fails. When we
            // are doing a PQC INITIAL, mirror the strict policy so the transcripts match.
            if (pqcEnabled && phase == HandshakePhase.INITIAL && !allowClassicBootstrap) {
                it.copy(allowClassicFallback = false)
            } else {
                it
            }
        }
        val signKeys = localIdentity.getOrCreateProtocolSigningKeys()
        val protocolSigningKeys = P2PProtocolSigningKeys(
            ed25519PrivateKey = signKeys.ed25519PrivateKey,
            ed25519PublicKeyRaw32 = signKeys.ed25519PublicRaw32,
            mlDsa65PrivateKeyRaw = signKeys.mlDsa65PrivateKeyRaw,
            mlDsa65PublicKeyRaw = signKeys.mlDsa65PublicKeyRaw
        )

        val client = localIdentity.handshakeClient(peerKem = peerKem, policy = effectiveHandshakePolicy)
        val bypassFallbackCooldown = diagnosticsConfig.ignoreClassicFallbackCooldown
        Log.i(
            "SB-HANDSHAKE",
            "start session=${redactLogIdentifier(owner.sessionId)} generation=${owner.generation} phase=$phase trigger=$trigger peerId=${redactLogIdentifier(peerId)} classicOnly=${!pqcEnabled} bootstrapClassic=$allowClassicBootstrap minTier=${effectiveHandshakePolicy.minimumTierRaw} requirePqc=${effectiveHandshakePolicy.requirePqc}"
        )
        updateSignalingStatus(
            sessionId = owner.sessionId,
            peerSignalingId = remoteSignalingId,
            lastEvent = "handshake start: $phase/$trigger"
        )
        val (st, msgA) = runCatching {
            client.start(
                P2PHandshakeClient.StartOptions(
                    peerIdForFallbackCooldown = if (bypassFallbackCooldown) null else peerId,
                    fallbackCooldownStore = if (bypassFallbackCooldown) null else localIdentity.fallbackCooldownStore(),
                    peerKemPublicKeys = peerKem,
                    handshakePolicy = effectiveHandshakePolicy.toWirePolicy(),
                    allowClassicBootstrapForTrustedPeer = allowClassicBootstrap,
                    protocolSigningKeys = protocolSigningKeys
                )
            )
        }.getOrElse { err ->
            onHandshakeFailed(owner, phase, "handshake start failed: ${err.message ?: "unknown"}")
            return
        }

        initiatorHandshake = st to client
        initiatorHandshakePhase = phase
        initiatorPendingMessageB = null
        initiatorPendingResponderFinished = null
        if (!sendHandshakeFrame(owner, msgA)) {
            onHandshakeFailed(owner, phase, "send messageA failed")
        }
    }

    private fun scheduleHandshakeStart(owner: ProductSessionOwner, role: WebRtcSession.Role) {
        if (!sessionOwnerGate.isCurrent(owner)) return
        if (handshakeInProgress()) return

        // Prefer the answerer to initiate; offerer will initiate as a fallback (macOS is responder-only).
        val immediate = diagnosticsConfig.immediateHandshake
        val baseDelayMs = if (immediate) 0L else if (role == WebRtcSession.Role.ANSWERER) 150L else 900L
        val jitterMs = if (immediate) 0L else SecureRandom().nextInt(200).toLong()
        Log.i("SB-HANDSHAKE", "schedule session=${redactLogIdentifier(owner.sessionId)} generation=${owner.generation} role=$role delayMs=${baseDelayMs + jitterMs} immediate=$immediate")
        updateSignalingStatus(
            sessionId = owner.sessionId,
            peerSignalingId = remoteSignalingId,
            lastEvent = "handshake scheduled: ${baseDelayMs + jitterMs}ms"
        )
        scope.launch {
            delay(baseDelayMs + jitterMs)
            if (!sessionOwnerGate.isCurrent(owner)) return@launch
            if (handshakeInProgress()) return@launch

            val peerId = currentPeerId()
            val policy = effectivePolicyOverride()
            val peerKem = awaitPeerKemForInitialHandshake(owner, peerId, policy)
                ?: run {
                    onHandshakeFailed(
                        owner,
                        HandshakePhase.INITIAL,
                        "missing_qperiapt_join_bootstrap"
                    )
                    return@launch
                }
            runIfCurrentSession(owner) {
                startInitiatorHandshake(
                    owner = owner,
                    peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                        qPeriaptPublicKey = peerKem.qPeriaptPublicKey,
                        xWingPublicKey = peerKem.xWingPublicKey,
                        mlKem768PublicKey = peerKem.mlKem768PublicKey
                    ),
                    phase = HandshakePhase.INITIAL,
                    trigger = "datachannel_ready"
                )
            }
        }
    }

    private suspend fun awaitPeerKemForInitialHandshake(
        owner: ProductSessionOwner,
        peerId: String?,
        policy: P2PHandshakePolicyOverride
    ): PeerKemKeyStore.PeerKemPublicKeys? {
        if (policy.minimumTierRaw != P2PQPeriaptKem.MINIMUM_TIER_RAW) {
            return initialPeerKem(owner, peerId)
        }
        val normalizedPeerId = peerId?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val deadline = System.currentTimeMillis() + qPeriaptJoinBootstrapWaitTimeoutMs
        while (System.currentTimeMillis() <= deadline) {
            if (!sessionOwnerGate.isCurrent(owner)) return null
            val keys = initialPeerKem(owner, normalizedPeerId)
            if (keys.qPeriaptPublicKey != null) {
                return keys
            }
            delay(qPeriaptJoinBootstrapPollIntervalMs)
        }
        Log.e(
            "SB-HANDSHAKE",
            "missing_qperiapt_join_bootstrap session=${redactLogIdentifier(owner.sessionId)} generation=${owner.generation} peerId=${redactLogIdentifier(normalizedPeerId)}"
        )
        updateSignalingStatus(
            sessionId = owner.sessionId,
            peerSignalingId = remoteSignalingId,
            lastEvent = "handshake failed: missing_qperiapt_join_bootstrap"
        )
        return null
    }

    private fun initialPeerKem(
        owner: ProductSessionOwner,
        peerId: String?
    ): PeerKemKeyStore.PeerKemPublicKeys {
        val normalizedPeerId = peerId?.trim()?.takeIf { it.isNotEmpty() }
        val persisted = normalizedPeerId?.let(::loadPeerKem)
            ?: PeerKemKeyStore.PeerKemPublicKeys()
        if (diagnosticsConfig.existingTrustOnly) {
            return persisted
        }
        val pending = currentPendingJoinBootstrapKeys(owner, normalizedPeerId)
            ?: return persisted
        return PeerKemKeyStore.PeerKemPublicKeys(
            qPeriaptPublicKey = pending.qPeriaptPublicKey ?: persisted.qPeriaptPublicKey,
            xWingPublicKey = pending.xWingPublicKey ?: persisted.xWingPublicKey,
            mlKem768PublicKey = pending.mlKem768PublicKey ?: persisted.mlKem768PublicKey
        )
    }

    private fun currentPendingJoinBootstrapKeys(
        owner: ProductSessionOwner,
        peerId: String?
    ): PeerKemKeyStore.PeerKemPublicKeys? {
        if (!sessionOwnerGate.isCurrent(owner)) return null
        val pending = pendingJoinBootstrapKem ?: return null
        if (pending.owner != owner) return null
        val normalizedPeerId = peerId?.trim()?.takeIf { it.isNotEmpty() }
        if (normalizedPeerId != null && normalizedPeerId !in pending.peerIds) return null
        return pending.keys
    }

    private fun samePendingJoinBootstrap(
        lhs: PendingJoinBootstrapKem,
        rhs: PendingJoinBootstrapKem
    ): Boolean = lhs.owner == rhs.owner &&
        lhs.peerIds == rhs.peerIds &&
        nullableBytesEqual(lhs.keys.qPeriaptPublicKey, rhs.keys.qPeriaptPublicKey) &&
        nullableBytesEqual(lhs.keys.xWingPublicKey, rhs.keys.xWingPublicKey) &&
        nullableBytesEqual(lhs.keys.mlKem768PublicKey, rhs.keys.mlKem768PublicKey)

    private fun nullableBytesEqual(lhs: ByteArray?, rhs: ByteArray?): Boolean = when {
        lhs == null -> rhs == null
        rhs == null -> false
        else -> lhs.contentEquals(rhs)
    }

    private fun isLikelyMessageA(data: ByteArray): Boolean =
        runCatching { P2PHandshakeWire.decodeMessageA(data) }.isSuccess

    private fun isLikelyMessageB(data: ByteArray): Boolean =
        runCatching { P2PHandshakeWire.decodeMessageB(data) }.isSuccess

    private fun isLikelyFinished(data: ByteArray): Boolean {
        if (data.size != 38 && HandshakePaddingP1.unwrapIfNeeded(data).size != 38) return false
        return runCatching { P2PHandshakeWire.decodeFinished(data) }.isSuccess
    }

    private fun handleEnvelope(owner: ProductSessionOwner, env: WebRtcSignalingEnvelope) {
        if (env.sessionId != owner.sessionId) return
        if (env.from == localId) return
        runIfCurrentSession(owner) {
            // Strict-PQC JOIN bootstrap KEM must be ingested even before the WebRtcSession exists:
            // a strict-PQC host sends its KEM in the JOIN, which arrives ahead of the offer. It only
            // needs to reach peerKemStore before the INITIAL handshake, so guard on the exact
            // manager owner rather than the not-yet-created session object.
            if (env.type == WebRtcSignalingEnvelope.MessageType.JOIN) {
                if (remoteSignalingId.isNullOrBlank()) remoteSignalingId = env.from
                if (remoteDeviceId.isNullOrBlank()) remoteDeviceId = env.from
                ingestJoinBootstrap(owner, env)
                if (!sessionOwnerGate.isCurrent(owner)) return@runIfCurrentSession
            }
            val exactSession = session ?: return@runIfCurrentSession
            if (env.sessionId != exactSession.sessionId) return@runIfCurrentSession
            remoteSignalingId = env.from
            if (remoteDeviceId.isNullOrBlank()) {
                remoteDeviceId = env.from
            }
            updateSignalingStatus(
                sessionId = env.sessionId,
                peerSignalingId = env.from,
                lastEvent = "received ${env.type.name.lowercase()}"
            )

            when (env.type) {
                WebRtcSignalingEnvelope.MessageType.OFFER ->
                    env.payload?.sdp?.let(exactSession::setRemoteOffer)
                WebRtcSignalingEnvelope.MessageType.ANSWER ->
                    env.payload?.sdp?.let(exactSession::setRemoteAnswer)
                WebRtcSignalingEnvelope.MessageType.ICE_CANDIDATE -> {
                    val payload = env.payload ?: return@runIfCurrentSession
                    val candidate = payload.candidate ?: return@runIfCurrentSession
                    exactSession.addRemoteIceCandidate(
                        candidate,
                        payload.sdpMid,
                        payload.sdpMLineIndex
                    )
                }
                WebRtcSignalingEnvelope.MessageType.JOIN -> Unit // KEM ingested before session guard
                WebRtcSignalingEnvelope.MessageType.LEAVE -> Unit
            }
        }
    }

    /**
     * Ingest a peer's strict-PQC JOIN bootstrap material. A strict-PQC macOS/iOS host advertises
     * its current-path protocol authority and KEM public keys in the signaling JOIN. The authority
     * is not treated as a completed trust decision: the subsequent MessageA/MessageB signature key
     * must still match this fingerprint before session keys become usable.
     */
    private fun ingestJoinBootstrap(owner: ProductSessionOwner, env: WebRtcSignalingEnvelope) {
        if (!sessionOwnerGate.isCurrent(owner)) return
        val authority = runCatching {
            JoinBootstrapAuthority.fromJoinEnvelope(env)
        }.getOrElse {
            failSecureTransport(owner, "JOIN bootstrap authority rejected")
            return
        }
        if (authority != null && !rememberJoinBootstrapAuthority(owner, authority)) {
            return
        }

        val payload = env.payload ?: return
        val keys = payload.kemPublicKeys?.takeIf { it.isNotEmpty() } ?: return
        val admitted = JoinBootstrapKemAdmission.admit(
            keys = keys,
            platform = payload.platform,
            osVersion = payload.osVersion
        )
        val infos = admitted.acceptedKeys
        val peerIds = listOfNotNull(currentPeerId(), env.from.takeIf { it.isNotBlank() })
            .map(String::trim)
            .filter(String::isNotEmpty)
            .toSet()
        if (admitted.rejectedQPeriapt) {
            Log.i(
                "SB-HANDSHAKE",
                "joinBootstrapKem rejected qperiapt session=${redactLogIdentifier(currentSessionId)} reason=unsupported_or_ambiguous_platform"
            )
        }
        if (infos.isEmpty()) {
            return
        }
        val pending = PendingJoinBootstrapKem(
            owner = owner,
            peerIds = peerIds,
            keys = PeerKemKeyStoreRecords.materialize(
                kemPublicKeys = infos,
                platform = payload.platform,
                osVersion = payload.osVersion
            )
        )
        val existing = pendingJoinBootstrapKem
        if (
            existing != null &&
            existing.owner == owner &&
            !samePendingJoinBootstrap(existing, pending)
        ) {
            failSecureTransport(owner, "JOIN bootstrap KEM changed")
            return
        }
        pendingJoinBootstrapKem = pending
        Log.i(
            "SB-HANDSHAKE",
            "joinBootstrapKem admitted ephemerally session=${redactLogIdentifier(currentSessionId)} keys=${infos.size} peers=${peerIds.size} rejectedQPeriapt=${admitted.rejectedQPeriapt}"
        )
    }

    private fun rememberJoinBootstrapAuthority(
        owner: ProductSessionOwner,
        authority: ProtocolIdentityBinding
    ): Boolean {
        if (!sessionOwnerGate.isCurrent(owner)) return false
        val sessionId = owner.sessionId
        val existing = currentPathExpectedRemoteAuthorityBySessionId[sessionId]
        if (existing != null) {
            val sameAuthority =
                existing.deviceId == authority.deviceId &&
                    existing.protocolSigningAlgorithm == authority.protocolSigningAlgorithm &&
                    existing.protocolPublicKeyFingerprint.equals(
                        authority.protocolPublicKeyFingerprint,
                        ignoreCase = true
                    )
            if (!sameAuthority) {
                failSecureTransport(owner, "JOIN bootstrap authority changed")
                return false
            }
            return true
        }

        currentPathExpectedRemoteAuthorityBySessionId[sessionId] = CurrentPathRemoteAuthority(
            deviceId = authority.deviceId,
            protocolSigningAlgorithm = authority.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint = authority.protocolPublicKeyFingerprint,
            deviceName = null
        )
        Log.i(
            "SB-HANDSHAKE",
            "joinBootstrapAuthority ingested session=${redactLogIdentifier(sessionId)} peerId=${redactLogIdentifier(authority.deviceId)} algorithm=${authority.protocolSigningAlgorithm.rawValue}"
        )
        return true
    }

    private fun normalizeCode(code: String): String? {
        val normalized = code.uppercase().filter { it.isLetterOrDigit() }
        return normalized.takeIf { it.length in 6..16 }
    }

    private fun signalingUrlWithShard(baseUrl: String, shard: String?): String {
        return currentPathSignalingUrlWithShard(
            baseUrl = baseUrl,
            shard = shard,
            clientVersion = resolvedClientVersion(),
            protocolVersion = resolvedProtocolVersion()
        )
    }

    private fun signalingHeadersForShard(shard: String?): Map<String, String> {
        val normalizedShard = shard?.trim()?.takeIf { it.isNotEmpty() } ?: return emptyMap()
        val token = webrtcSignalingAuthTokenBySessionId[normalizedShard]
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return emptyMap()
        return currentPathSignalingHeaders(
            sessionId = normalizedShard,
            sessionToken = token,
            clientVersion = resolvedClientVersion(),
            protocolVersion = resolvedProtocolVersion()
        )
    }

    private fun resolvedClientVersion(): String =
        System.getProperty("skybridge.clientVersion")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: runCatching {
                appContext.packageManager.getPackageInfo(appContext.packageName, 0).versionName
            }.getOrNull()
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
            ?: "1.0.0"

    private fun resolvedProtocolVersion(): String =
        System.getProperty("skybridge.protocolVersion")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "1"

    internal companion object {
        internal const val qPeriaptJoinBootstrapWaitTimeoutMs: Long = 2_500L
        internal const val qPeriaptJoinBootstrapPollIntervalMs: Long = 50L

        fun currentPathSignalingUrlWithShard(
            baseUrl: String,
            shard: String?,
            clientVersion: String,
            protocolVersion: String
        ): String {
            val normalizedBase = baseUrl.trim().ifBlank { SkyBridgeServerConfig.signalingWebSocketURL }
            val normalizedShard = shard?.trim().takeIf { !it.isNullOrEmpty() } ?: return normalizedBase
            val uri = URI(normalizedBase)
            val baseWithoutQuery = URI(
                uri.scheme,
                uri.rawAuthority,
                uri.rawPath ?: "",
                null,
                null
            ).toASCIIString()
            val queryItems = mutableListOf<String>()
            val existingKeys = linkedSetOf<String>()
            uri.rawQuery
                ?.split("&")
                ?.filter { it.isNotBlank() }
                ?.groupBy { rawPair ->
                    decodeQueryComponent(rawPair.substringBefore("=", rawPair))
                }
                ?.forEach { (name, rawPairs) ->
                    val normalizedName = name.lowercase()
                    if (isWebSocketCredentialQueryName(name) || normalizedName == "cv" || normalizedName == "pv") return@forEach
                    if (!existingKeys.add(name)) return@forEach
                    queryItems.addAll(rawPairs)
                }
            queryItems += "shard=${encodeQueryComponent(normalizedShard.uppercase())}"
            queryItems += "cv=${encodeQueryComponent(clientVersion)}"
            queryItems += "pv=${encodeQueryComponent(protocolVersion)}"
            return "$baseWithoutQuery?${queryItems.joinToString("&")}"
        }

        private fun encodeQueryComponent(value: String): String =
            URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")

        private fun decodeQueryComponent(value: String): String =
            URLDecoder.decode(value, Charsets.UTF_8.name())

        private fun isWebSocketCredentialQueryName(name: String): Boolean {
            val normalized = name.lowercase()
            return normalized == "shard" ||
                normalized == "st" ||
                "token" in normalized ||
                "session" in normalized ||
                "secret" in normalized
        }

        fun currentPathSignalingHeaders(
            sessionId: String,
            sessionToken: String,
            clientVersion: String,
            protocolVersion: String
        ): Map<String, String> =
            mapOf(
                "X-SkyBridge-Session-Id" to sessionId.trim().uppercase(),
                "X-SkyBridge-Session" to sessionToken.trim(),
                "X-SkyBridge-Client-Version" to clientVersion.trim(),
                "X-SkyBridge-Protocol-Version" to protocolVersion.trim()
            )
    }

    private fun updateSignalingStatus(
        sessionId: String?,
        peerSignalingId: String? = remoteSignalingId,
        lastEvent: String
    ) {
        _signalingStatus.value = SignalingStatus(
            sessionId = sessionId,
            websocketUrl = WebSocketSignalingClient.redactedUrlString(signalingUrl),
            shard = signalingShard,
            peerSignalingId = peerSignalingId,
            lastEvent = lastEvent
        )
    }

    private fun sanitizeErrorMessage(error: Throwable, fallback: String): String =
        sanitizeStatusMessage(error.message?.takeIf { it.isNotBlank() } ?: fallback)

    private fun diagnosticErrorMessage(error: Throwable, fallback: String): String {
        val seen = linkedSetOf<String>()
        val chain = generateSequence(error) { it.cause }
            .take(3)
            .map { throwable ->
                val type = throwable::class.java.simpleName.takeIf { it.isNotBlank() } ?: "Throwable"
                val message = throwable.message?.takeIf { it.isNotBlank() }?.let(::sanitizeStatusMessage)
                if (message == null) type else "$type: $message"
            }
            .filter { seen.add(it) }
            .joinToString(" <- ")
        return chain.ifBlank { sanitizeStatusMessage(fallback) }
    }

    private fun sanitizeStatusMessage(message: String): String =
        WebSocketSignalingClient.sanitizeTextForLog(message)

    private fun redactLogIdentifier(value: String?): String =
        WebSocketSignalingClient.redactIdentifierForLog(value)

    private fun nowSeconds(): Double = System.currentTimeMillis() / 1000.0

    private fun defaultDeviceId(): String =
        localIdentity.deviceId()

}
