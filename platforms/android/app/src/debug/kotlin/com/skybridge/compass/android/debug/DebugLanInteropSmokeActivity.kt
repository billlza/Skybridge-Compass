package com.skybridge.compass.android.debug

import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.skybridge.compass.R
import com.skybridge.compass.android.account.AccountBusinessIdentityProvider
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.remote.mac.LanRemotePeer
import com.skybridge.compass.android.remote.mac.MacRemoteControlClient
import com.skybridge.compass.android.remote.mac.MacRemoteFormalRouteAuthorizationLease
import com.skybridge.compass.android.remote.mac.MacRemoteControlTrustContextFactory
import com.skybridge.compass.android.remote.mac.MacRemoteTrustedSessionPolicy
import com.skybridge.compass.android.remote.mac.RemoteControlSecurityIdentity
import com.skybridge.compass.android.security.toHandshakePolicyOverride
import com.skybridge.compass.core.p2p.FormalLanPeerSnapshot
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.usecases.StartDeviceDiscoveryUseCase
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PXWingKem
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.inject.Inject

internal object DebugLanInteropTrustMutationPolicy {
    data class Decision(
        val mutationRequested: Boolean,
        val acceptanceEligible: Boolean
    )

    fun authorize(
        allowDiagnosticTrustInjection: Boolean,
        allowTrustOnFirstUse: Boolean,
        hasPeerKemInput: Boolean,
        hasPrePairingRequest: Boolean,
        requireExistingProductTrust: Boolean = false,
        hasExpectedDeviceId: Boolean = false
    ): Decision {
        require(!hasPrePairingRequest) {
            "debug_automatic_pairing_removed_use_product_sas_pairing"
        }
        if (requireExistingProductTrust) {
            require(hasExpectedDeviceId) {
                "existing_product_trust_requires_candidate_device_id"
            }
            require(!allowDiagnosticTrustInjection) {
                "existing_product_trust_conflicts_with_diagnostic_injection"
            }
            require(!allowTrustOnFirstUse) {
                "existing_product_trust_conflicts_with_tofu"
            }
        }
        val mutationRequested = hasPeerKemInput || allowTrustOnFirstUse
        require(!mutationRequested || allowDiagnosticTrustInjection) {
            "diagnostic_trust_injection_not_authorized"
        }
        return Decision(
            mutationRequested = mutationRequested,
            acceptanceEligible = !allowDiagnosticTrustInjection
        )
    }
}

internal object DebugLanInteropRunScope {
    const val MAX_NONCE_BYTES = 128
    private val noncePattern = Regex("^[A-Za-z0-9_-]{32,128}$")

    fun isValidNonce(raw: String): Boolean = noncePattern.matches(raw)

    fun matchesStagedNonce(provided: String, stagedBytes: ByteArray): Boolean {
        val staged = stagedBytes.toString(Charsets.UTF_8)
        val providedBytes = provided.toByteArray(Charsets.UTF_8)
        val equal = MessageDigest.isEqual(providedBytes, stagedBytes)
        return isValidNonce(provided) && isValidNonce(staged) && equal
    }

    fun runRef(nonce: String): String {
        require(isValidNonce(nonce)) { "invalid_smoke_nonce_format" }
        return MessageDigest.getInstance("SHA-256")
            .digest(nonce.toByteArray(Charsets.UTF_8))
            .joinToString(separator = "") { byte ->
                "%02x".format(byte.toInt() and 0xff)
            }
    }

    fun statusFileName(nonce: String): String =
        "$STATUS_FILE_PREFIX${runRef(nonce)}.log"

    private const val STATUS_FILE_PREFIX = "debug-lan-interop-smoke-status-"
}

/** Debug-only route freshness. Peer authority still comes exclusively from durable product trust. */
internal class DebugLanInteropRouteAuthorizationLease(
    private val runRef: String
) : MacRemoteFormalRouteAuthorizationLease {
    private data class Binding(
        val runRef: String,
        val attempt: Long,
        val peer: FormalLanPeerSnapshot
    )

    private val current = AtomicBoolean(true)
    private val binding = AtomicReference<Binding?>(null)

    init {
        require(runRef.matches(Regex("^[0-9a-f]{64}$"))) { "invalid_debug_run_ref" }
    }

    val isBound: Boolean
        get() = binding.get() != null

    fun bindAttempt(attempt: Long, peer: FormalLanPeerSnapshot) {
        require(attempt > 0L) { "invalid_debug_route_attempt" }
        val exact = Binding(runRef = runRef, attempt = attempt, peer = peer)
        check(current.get()) { "debug_route_lease_revoked" }
        check(binding.compareAndSet(null, exact)) { "debug_route_lease_already_bound" }
        check(current.get()) { "debug_route_lease_revoked" }
    }

    fun retainIfAnyObserved(peers: Iterable<FormalLanPeerSnapshot>): Boolean {
        val expected = binding.get() ?: return current.get()
        val exactStillPresent = peers.any(expected.peer::sameSecuritySnapshot)
        if (!exactStillPresent) revoke()
        return exactStillPresent && current.get()
    }

    override fun isCurrent(): Boolean =
        current.get() && binding.get() != null && current.get()

    fun revoke() {
        current.set(false)
    }
}

@AndroidEntryPoint
class DebugLanInteropSmokeActivity : ComponentActivity() {

    @Inject
    lateinit var startDeviceDiscovery: StartDeviceDiscoveryUseCase

    private lateinit var statusView: TextView
    private lateinit var client: MacRemoteControlClient
    private var diagnosticTrustMaterial: DebugEphemeralMacRemoteControlTrustMaterial? = null
    private var smokeJob: Job? = null
    private var runScopedRouteLease: DebugLanInteropRouteAuthorizationLease? = null
    private var routeAttempt = 0L
    private val statusLines = ArrayDeque<String>()
    private lateinit var runScopedStatusFile: File

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val expectedServiceName = intent.getStringExtra(EXTRA_EXPECTED_SERVICE_NAME)?.trim().orEmpty()
        val expectedDeviceId = intent.getStringExtra(EXTRA_EXPECTED_DEVICE_ID)?.trim().orEmpty()
        val expectedFingerprint = intent.getStringExtra(EXTRA_EXPECTED_FINGERPRINT)
            ?.trim()
            ?.lowercase(Locale.ROOT)
            .orEmpty()
        val requireExistingProductTrust =
            intent.getBooleanExtra(EXTRA_REQUIRE_EXISTING_PRODUCT_TRUST, false)
        val directHost = intent.getStringExtra(EXTRA_DIRECT_HOST)?.trim().orEmpty()
        val directPort = intent.getStringExtra(EXTRA_DIRECT_PORT)?.toIntOrNull() ?: DEFAULT_REMOTE_PORT
        val prePairingHost = intent.getStringExtra(EXTRA_PREPAIRING_HOST)?.trim().orEmpty()
        val prePairingPort = intent.getStringExtra(EXTRA_PREPAIRING_PORT)?.toIntOrNull() ?: 0
        val peerMlKemPublicB64 = intent.getStringExtra(EXTRA_PEER_MLKEM_PUBLIC_B64)?.trim().orEmpty()
        val peerXWingPublicB64 = intent.getStringExtra(EXTRA_PEER_XWING_PUBLIC_B64)?.trim().orEmpty()
        val timeoutSeconds = intent.getStringExtra(EXTRA_TIMEOUT_SECONDS)?.toLongOrNull()
            ?: DEFAULT_TIMEOUT_SECONDS
        val requireSecure = intent.getBooleanExtra(EXTRA_REQUIRE_SECURE, true)
        val allowPlaintextFallback = intent.getBooleanExtra(EXTRA_ALLOW_PLAINTEXT_FALLBACK, false)
        val allowTrustOnFirstUse = intent.getBooleanExtra(EXTRA_ALLOW_TRUST_ON_FIRST_USE, false)
        val allowDiagnosticTrustInjection =
            intent.getBooleanExtra(EXTRA_ALLOW_DIAGNOSTIC_TRUST_INJECTION, false)
        val autoFinish = intent.getBooleanExtra(EXTRA_AUTO_FINISH, true)
        val remoteNoticeAccountDisplayName = intent.getStringExtra(EXTRA_REMOTE_NOTICE_ACCOUNT_DISPLAY_NAME)
            ?.trim()
            .orEmpty()
        val remoteNoticeNebulaId = intent.getStringExtra(EXTRA_REMOTE_NOTICE_NEBULA_ID)
            ?.trim()
            .orEmpty()

        statusView = TextView(this).apply {
            textSize = 14f
            setPadding(32, 48, 32, 48)
            typeface = Typeface.MONOSPACE
            gravity = Gravity.START
            text = getString(R.string.debug_lan_smoke_starting)
        }
        setContentView(statusView)

        val smokeNonce = intent.getStringExtra(EXTRA_SMOKE_NONCE).orEmpty()
        if (!consumeSmokeNonce(smokeNonce)) {
            Log.e(TAG, "LAN smoke rejected an invalid run nonce")
            statusView.setText(R.string.debug_lan_smoke_failure_invalid_nonce)
            finish()
            return
        }
        val statusFile = File(filesDir, DebugLanInteropRunScope.statusFileName(smokeNonce))
        if (statusFile.exists() || !statusFile.createNewFile()) {
            Log.e(TAG, "LAN smoke refused a pre-existing run-scoped status file")
            statusView.setText(R.string.debug_lan_smoke_failure_status_file_preexisting)
            finish()
            return
        }
        runScopedStatusFile = statusFile
        val smokeRunRef = DebugLanInteropRunScope.runRef(smokeNonce)
        emit("attempt ref=$smokeRunRef")

        val smokeLocalIdentity = LocalP2PIdentity(applicationContext)
        val smokeSecurityIdentityProvider: (() -> RemoteControlSecurityIdentity?)? = if (
            remoteNoticeAccountDisplayName.isNotBlank() &&
            remoteNoticeNebulaId.isNotBlank()
        ) {
            val provider = {
                RemoteControlSecurityIdentity(
                    accountDisplayName = remoteNoticeAccountDisplayName,
                    nebulaId = remoteNoticeNebulaId,
                    deviceId = smokeLocalIdentity.deviceId(),
                    deviceName = Build.MODEL?.trim()?.takeIf { it.isNotEmpty() }
                )
            }
            provider
        } else {
            null
        }

        val trustContextOverride = if (allowDiagnosticTrustInjection) {
            DebugEphemeralMacRemoteControlTrustMaterial().also {
                diagnosticTrustMaterial = it
            }.clientTrustContext
        } else {
            MacRemoteControlTrustContextFactory.persistentReadOnly(
                appContext = applicationContext,
                localIdentity = smokeLocalIdentity
            )
        }
        runScopedRouteLease = if (allowDiagnosticTrustInjection) {
            null
        } else {
            DebugLanInteropRouteAuthorizationLease(smokeRunRef)
        }
        client = MacRemoteControlClient(
            applicationContext,
            accountBusinessIdentityProvider = AccountBusinessIdentityProvider { null },
            remoteControlSecurityIdentityProvider = smokeSecurityIdentityProvider,
            localIdentityOverride = smokeLocalIdentity,
            trustContextOverride = trustContextOverride,
            formalRouteAuthorizationLease = runScopedRouteLease
        )
        emit(
            "boot expectedService=${expectedServiceName.ifBlank { "-" }} " +
                "expectedDevice=${DebugSmokeRedaction.sensitiveValue(expectedDeviceId)} " +
                "requireSecure=$requireSecure allowPlaintext=$allowPlaintextFallback " +
                "allowTofu=$allowTrustOnFirstUse " +
                "noticeAccount=${DebugSmokeRedaction.presence(remoteNoticeAccountDisplayName)} " +
                "noticeNebula=${DebugSmokeRedaction.presence(remoteNoticeNebulaId)} " +
                "directHost=${directHost.ifBlank { "-" }}:$directPort"
        )
        val xWingFailureReason = P2PXWingKem.availabilityFailureReason()
        emit(
            "runtime sdk=${Build.VERSION.SDK_INT} " +
                "mlkem=${AndroidPQCCryptoProvider.isAvailable()} " +
                "xwing=${xWingFailureReason == null} " +
                "xwingReason=${xWingFailureReason ?: "ok"}"
        )
        emit("status-file=run-scoped")

        smokeJob = lifecycleScope.launch {
            try {
                val baseSettings = SecuritySettingsStore.observe(applicationContext).first()
                val securityConfig = MacRemoteControlClient.SecurityConfig(
                    encryptionRequired = requireSecure && baseSettings.encryptionEnabled,
                    allowPlaintextFallback = allowPlaintextFallback,
                    allowTrustOnFirstUse = allowTrustOnFirstUse,
                    handshakePolicyOverride = baseSettings.toHandshakePolicyOverride()
                )
                if (requireExistingProductTrust) {
                    val strictPolicy = securityConfig.handshakePolicyOverride
                        ?: error("existing_product_trust_requires_explicit_pqc_policy")
                    check(strictPolicy.requirePqc) {
                        "existing_product_trust_requires_strict_pqc_policy"
                    }
                    check(strictPolicy.allowClassicFallback.not()) {
                        "existing_product_trust_forbids_classic_fallback"
                    }
                }

                val trustMutationDecision = DebugLanInteropTrustMutationPolicy.authorize(
                    allowDiagnosticTrustInjection = allowDiagnosticTrustInjection,
                    allowTrustOnFirstUse = allowTrustOnFirstUse,
                    hasPeerKemInput =
                        peerMlKemPublicB64.isNotBlank() || peerXWingPublicB64.isNotBlank(),
                    hasPrePairingRequest = prePairingHost.isNotBlank() || prePairingPort > 0,
                    requireExistingProductTrust = requireExistingProductTrust,
                    hasExpectedDeviceId = expectedDeviceId.isNotBlank()
                )
                if (!trustMutationDecision.acceptanceEligible) {
                    emit("diagnostic trustInjection=enabled acceptanceEligible=false")
                }

                seedPeerKemIfProvided(
                    peerId = expectedDeviceId,
                    mlKemPublicB64 = peerMlKemPublicB64,
                    xWingPublicB64 = peerXWingPublicB64
                )
                emit(
                    "policy requirePqc=${securityConfig.handshakePolicyOverride?.requirePqc} " +
                        "allowClassicFallback=${securityConfig.handshakePolicyOverride?.allowClassicFallback}"
                )

                var connectStarted = false
                var lastSeenServices = 0
                if (directHost.isNotBlank()) {
                    emit("direct constraint host=$directHost:$directPort")
                    check(expectedDeviceId.isNotBlank()) {
                        "direct_secure_connect_requires_expected_identity"
                    }
                }

                val discoveryJob = launch {
                    startDeviceDiscovery(
                        protocols = setOf(DiscoveryProtocol.BONJOUR)
                    ).collectLatest { devices ->
                        val peers = devices
                            .mapNotNull(LanRemotePeer::fromDiscoveredDevice)
                            .filter { it.formalSnapshot != null }
                            .groupBy(LanRemotePeer::id)
                            .values
                            .mapNotNull { sameIdPeers -> sameIdPeers.singleOrNull() }
                        lastSeenServices = peers.size
                        val currentFormalSnapshots = peers.mapNotNull(LanRemotePeer::formalSnapshot)
                        runScopedRouteLease?.takeIf { it.isBound }
                            ?.retainIfAnyObserved(currentFormalSnapshots)
                        if (peers.isEmpty()) {
                            emitOnce("discovery empty")
                            return@collectLatest
                        }
                        emitOnce("discovery formalPeers=${peers.size}")

                        val matched = peers.singleOrNull { peer ->
                            val formal = requireNotNull(peer.formalSnapshot)
                            val remote = peer.remoteDesktopEndpoint
                            val serviceNameMatches = expectedServiceName.isBlank() ||
                                remote.instanceName == expectedServiceName
                            val deviceMatches = expectedDeviceId.isBlank() ||
                                peer.id == expectedDeviceId || formal.deviceId == expectedDeviceId
                            val fingerprintMatches = expectedFingerprint.isBlank() ||
                                remote.advertisedProtocolFingerprint == expectedFingerprint
                            val directConstraintMatches = directHost.isBlank() ||
                                (remote.hostAddress == directHost && remote.port == directPort)
                            serviceNameMatches && deviceMatches && fingerprintMatches &&
                                directConstraintMatches
                        }

                        if (matched != null && !connectStarted) {
                            connectStarted = true
                            val remote = matched.remoteDesktopEndpoint
                            emit(
                                "service matched name=${matched.name} " +
                                    "deviceId=${DebugSmokeRedaction.sensitiveValue(matched.id)} " +
                                    "fp=${DebugSmokeRedaction.sensitiveValue(remote.advertisedProtocolFingerprint)}"
                            )
                            connectToPeer(
                                peer = matched,
                                expectedFingerprint = expectedFingerprint,
                                requireExistingProductTrust = requireExistingProductTrust,
                                securityConfig = securityConfig
                            )
                        }
                    }
                }

                var smokeSucceeded = false
                try {
                    withTimeout(timeoutSeconds * 1000L) {
                        while (true) {
                            val state = client.state.value
                            val securityState = client.securityState.value
                            when (state) {
                                is MacRemoteControlClient.State.Disconnected ->
                                    emitOnce("state disconnected seenServices=$lastSeenServices")

                                is MacRemoteControlClient.State.Connecting ->
                                    emitOnce("state connecting host=${state.target.host}:${state.target.port}")

                                is MacRemoteControlClient.State.Connected ->
                                    emitOnce("state connected host=${state.target.host}:${state.target.port}")

                                is MacRemoteControlClient.State.Failed ->
                                    error("state_failed=${state.message}")
                            }

                            when (securityState) {
                                MacRemoteControlClient.SecurityState.Disconnected ->
                                    emitOnce("security disconnected")

                                is MacRemoteControlClient.SecurityState.Negotiating ->
                                    emitOnce(
                                        "security negotiating peer=${DebugSmokeRedaction.sensitiveValue(securityState.peerId)} pinned=${securityState.pinned}"
                                    )

                                is MacRemoteControlClient.SecurityState.Secure -> {
                                    emitOnce(
                                        "security secure peer=${DebugSmokeRedaction.sensitiveValue(securityState.peerId)} " +
                                            "suite=${securityState.suite} trust=${securityState.trustState}"
                                    )
                                    if (!MacRemoteTrustedSessionPolicy.isTrustedRemoteControlSession(securityState)) {
                                        error("security_untrusted=${securityState.trustState}")
                                    }
                                    val trustedFrameEvidence = client.currentTrustedFrameEvidence()
                                    if (trustedFrameEvidence != null) {
                                        if (requireExistingProductTrust &&
                                            trustedFrameEvidence.securityState.trustState !=
                                            MacRemoteControlClient.TrustState.TRUSTED_EXISTING
                                        ) {
                                            error("existing_product_trust_not_preserved")
                                        }
                                        if (requireExistingProductTrust) {
                                            emitOnce(
                                                "identity authority=authenticated_product_v1 " +
                                                    "handshake=verified frameOwner=current"
                                            )
                                        }
                                        val frame = trustedFrameEvidence.frame
                                        emitOnce(
                                            "frame width=${frame.width} height=${frame.height} " +
                                                "format=${frame.format ?: "-"} owner=current"
                                        )
                                        markSuccess("secure_frame_received")
                                        smokeSucceeded = true
                                        return@withTimeout
                                    }
                                }

                                is MacRemoteControlClient.SecurityState.Plaintext -> {
                                    emitOnce("security plaintext reason=${securityState.reason}")
                                    if (!requireSecure && client.latestFrame.value != null) {
                                        markSuccess("plaintext_frame_received")
                                        smokeSucceeded = true
                                        return@withTimeout
                                    }
                                }

                                is MacRemoteControlClient.SecurityState.Failed ->
                                    error("security_failed=${securityState.reason}")
                            }

                            delay(250L)
                        }
                    }
                } finally {
                    discoveryJob.cancel()
                }
                if (!smokeSucceeded) {
                    error("timeout")
                }
                if (autoFinish) {
                    delay(1500L)
                    finish()
                }
            } catch (error: TimeoutCancellationException) {
                Log.e(TAG, "LAN smoke timed out", error)
                markFailure("timeout")
                if (autoFinish) {
                    delay(1500L)
                    finish()
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                Log.e(TAG, "LAN smoke failed", error)
                markFailure(error.message ?: "unknown_failure")
                if (autoFinish) {
                    delay(1500L)
                    finish()
                }
            }
        }
    }

    override fun onDestroy() {
        runScopedRouteLease?.revoke()
        smokeJob?.cancel()
        if (::client.isInitialized) {
            client.disconnect()
        }
        super.onDestroy()
    }

    override fun onStop() {
        runScopedRouteLease?.revoke()
        if (::client.isInitialized) client.disconnect()
        super.onStop()
    }

    private fun markSuccess(reason: String) {
        runScopedRouteLease?.revoke()
        emit("success reason=$reason")
    }

    private fun markFailure(reason: String) {
        runScopedRouteLease?.revoke()
        emit("failure reason=$reason")
    }

    private fun emitOnce(line: String) {
        if (statusLines.lastOrNull() == line) return
        emit(line)
    }

    private fun emit(line: String) {
        val safeLine = DebugSmokeRedaction.statusLine(line)
        val stamped = "[${timestamp()}] $safeLine"
        Log.i(TAG, stamped)
        statusFile().parentFile?.mkdirs()
        statusFile().appendText("$stamped\n")
        statusLines.addLast(safeLine)
        while (statusLines.size > 12) {
            statusLines.removeFirst()
        }
        runOnUiThread {
            statusView.text = statusLines.joinToString(separator = "\n")
        }
    }

    private fun statusFile(): File {
        check(::runScopedStatusFile.isInitialized) {
            "run-scoped status file is not initialized"
        }
        return runScopedStatusFile
    }

    private fun nonceFile(): File =
        File(filesDir, NONCE_FILE_NAME)

    private fun consumeSmokeNonce(provided: String): Boolean {
        val file = nonceFile()
        val expectedBytes = try {
            file.takeIf(File::isFile)?.let(::readBoundedNonce)
        } catch (error: Exception) {
            Log.e(TAG, "LAN smoke could not consume its staged run nonce", error)
            null
        } ?: return false
        if (!DebugLanInteropRunScope.matchesStagedNonce(provided, expectedBytes)) {
            return false
        }
        return try {
            file.delete() && !file.exists()
        } catch (error: SecurityException) {
            Log.e(TAG, "LAN smoke could not remove its consumed run nonce", error)
            false
        }
    }

    private fun readBoundedNonce(file: File): ByteArray? =
        file.inputStream().use { input ->
            val bytes = ByteArray(DebugLanInteropRunScope.MAX_NONCE_BYTES + 1)
            var count = 0
            while (count < bytes.size) {
                val read = input.read(bytes, count, bytes.size - count)
                if (read < 0) break
                if (read == 0) continue
                count += read
            }
            bytes.copyOf(count).takeIf {
                count <= DebugLanInteropRunScope.MAX_NONCE_BYTES
            }
        }

    private fun connectToPeer(
        peer: LanRemotePeer,
        expectedFingerprint: String,
        requireExistingProductTrust: Boolean,
        securityConfig: MacRemoteControlClient.SecurityConfig
    ) {
        val formal = requireNotNull(peer.formalSnapshot) {
            "debug_formal_route_snapshot_required"
        }
        val remote = peer.remoteDesktopEndpoint
        val target = MacRemoteControlClient.ConnectionTarget(
            host = remote.hostAddress,
            port = remote.port,
            displayName = peer.name,
            deviceIdHint = peer.id,
            advertisedFingerprint = remote.advertisedProtocolFingerprint,
            advertisedFingerprintTrustSource =
                if (requireExistingProductTrust) {
                    MacRemoteControlClient.FingerprintTrustSource.UNAUTHENTICATED_DISCOVERY
                } else if (
                    expectedFingerprint.isNotBlank() &&
                    remote.advertisedProtocolFingerprint == expectedFingerprint
                ) {
                    MacRemoteControlClient.FingerprintTrustSource.TRUSTED_CONFIGURATION
                } else {
                    MacRemoteControlClient.FingerprintTrustSource.UNAUTHENTICATED_DISCOVERY
                }
        )
        runScopedRouteLease?.let { lease ->
            check(routeAttempt != Long.MAX_VALUE) { "debug_route_attempt_exhausted" }
            routeAttempt += 1L
            lease.bindAttempt(routeAttempt, formal)
            emit("routeAuthority=debug_run_scoped snapshot=current")
        }
        client.connect(
            target = target,
            securityConfig = securityConfig
        )
    }

    private fun seedPeerKemIfProvided(
        peerId: String,
        mlKemPublicB64: String,
        xWingPublicB64: String
    ) {
        val mlKemPublicKey = mlKemPublicB64.takeIf(String::isNotBlank)
            ?.let(Base64.getDecoder()::decode)
        val xWingPublicKey = xWingPublicB64.takeIf(String::isNotBlank)
            ?.let(Base64.getDecoder()::decode)
        if (mlKemPublicKey == null && xWingPublicKey == null) return
        if (peerId.isBlank()) {
            error("diagnostic_kem_seed_requires_expected_device_id")
        }
        val ephemeralTrustMaterial = diagnosticTrustMaterial
            ?: error("diagnostic_trust_injection_not_authorized")
        ephemeralTrustMaterial.seedPeerKemKeys(
            peerId = peerId,
            mlKem768PublicKey = mlKemPublicKey,
            xWingPublicKey = xWingPublicKey
        )
        emit(
            "seeded diagnostic peer KEM peer=${DebugSmokeRedaction.sensitiveValue(peerId)} " +
                "mlkem=${mlKemPublicB64.isNotBlank()} xwing=${xWingPublicB64.isNotBlank()} " +
                "acceptanceEligible=false"
        )
    }

    private fun timestamp(): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())

    companion object {
        private const val TAG = "SB-LAN-SMOKE"
        private const val NONCE_FILE_NAME = "debug-lan-interop-smoke-nonce"
        private const val EXTRA_EXPECTED_SERVICE_NAME = "skybridgeExpectedServiceName"
        private const val EXTRA_EXPECTED_DEVICE_ID = "skybridgeExpectedDeviceId"
        private const val EXTRA_EXPECTED_FINGERPRINT = "skybridgeExpectedFingerprint"
        private const val EXTRA_REQUIRE_EXISTING_PRODUCT_TRUST =
            "skybridgeRequireExistingProductTrust"
        private const val EXTRA_DIRECT_HOST = "skybridgeDirectHost"
        private const val EXTRA_DIRECT_PORT = "skybridgeDirectPort"
        private const val EXTRA_PREPAIRING_HOST = "skybridgePrePairingHost"
        private const val EXTRA_PREPAIRING_PORT = "skybridgePrePairingPort"
        private const val EXTRA_PEER_MLKEM_PUBLIC_B64 = "skybridgePeerMlkemPublicB64"
        private const val EXTRA_ALLOW_DIAGNOSTIC_TRUST_INJECTION =
            "skybridgeAllowDiagnosticTrustInjection"
        private const val EXTRA_PEER_XWING_PUBLIC_B64 = "skybridgePeerXwingPublicB64"
        private const val EXTRA_TIMEOUT_SECONDS = "skybridgeTimeoutSeconds"
        private const val EXTRA_REQUIRE_SECURE = "skybridgeRequireSecure"
        private const val EXTRA_ALLOW_PLAINTEXT_FALLBACK = "skybridgeAllowPlaintextFallback"
        private const val EXTRA_ALLOW_TRUST_ON_FIRST_USE = "skybridgeAllowTrustOnFirstUse"
        private const val EXTRA_AUTO_FINISH = "skybridgeAutoFinish"
        private const val EXTRA_SMOKE_NONCE = "skybridgeSmokeNonce"
        private const val EXTRA_REMOTE_NOTICE_ACCOUNT_DISPLAY_NAME = "skybridgeRemoteNoticeAccountDisplayName"
        private const val EXTRA_REMOTE_NOTICE_NEBULA_ID = "skybridgeRemoteNoticeNebulaId"
        private const val DEFAULT_TIMEOUT_SECONDS = 120L
        private const val DEFAULT_REMOTE_PORT = 5901
    }
}
