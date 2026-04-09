package com.skybridge.compass.android.debug

import android.graphics.Typeface
import android.os.Bundle
import android.os.Build
import android.util.Log
import android.util.Base64
import android.view.Gravity
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.remote.mac.MacRemoteControlClient
import com.skybridge.compass.android.remote.mac.MacRemoteDiscovery
import com.skybridge.compass.android.remote.mac.identityHint
import com.skybridge.compass.android.security.toHandshakePolicyOverride
import com.skybridge.compass.core.p2p.AppMessage
import com.skybridge.compass.core.p2p.PeerKemKeyStore
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PXWingKem
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class DebugLanInteropSmokeActivity : ComponentActivity() {

    private lateinit var statusView: TextView
    private lateinit var client: MacRemoteControlClient
    private lateinit var discovery: MacRemoteDiscovery
    private lateinit var peerKemStore: PeerKemKeyStore
    private var smokeJob: Job? = null
    private val statusLines = ArrayDeque<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val expectedServiceName = intent.getStringExtra(EXTRA_EXPECTED_SERVICE_NAME)?.trim().orEmpty()
        val expectedDeviceId = intent.getStringExtra(EXTRA_EXPECTED_DEVICE_ID)?.trim().orEmpty()
        val expectedFingerprint = intent.getStringExtra(EXTRA_EXPECTED_FINGERPRINT)
            ?.trim()
            ?.lowercase(Locale.ROOT)
            .orEmpty()
        val directHost = intent.getStringExtra(EXTRA_DIRECT_HOST)?.trim().orEmpty()
        val directPort = intent.getStringExtra(EXTRA_DIRECT_PORT)?.toIntOrNull() ?: DEFAULT_REMOTE_PORT
        val peerMlKemPublicB64 = intent.getStringExtra(EXTRA_PEER_MLKEM_PUBLIC_B64)?.trim().orEmpty()
        val peerXWingPublicB64 = intent.getStringExtra(EXTRA_PEER_XWING_PUBLIC_B64)?.trim().orEmpty()
        val timeoutSeconds = intent.getStringExtra(EXTRA_TIMEOUT_SECONDS)?.toLongOrNull()
            ?: DEFAULT_TIMEOUT_SECONDS
        val requireSecure = intent.getBooleanExtra(EXTRA_REQUIRE_SECURE, true)
        val allowPlaintextFallback = intent.getBooleanExtra(EXTRA_ALLOW_PLAINTEXT_FALLBACK, false)
        val autoFinish = intent.getBooleanExtra(EXTRA_AUTO_FINISH, true)

        statusView = TextView(this).apply {
            textSize = 14f
            setPadding(32, 48, 32, 48)
            typeface = Typeface.MONOSPACE
            gravity = Gravity.START
            text = "Starting SkyBridge LAN smoke..."
        }
        setContentView(statusView)

        client = MacRemoteControlClient(applicationContext)
        discovery = MacRemoteDiscovery(applicationContext)
        peerKemStore = PeerKemKeyStore(applicationContext)
        statusFile().delete()

        emit(
            "boot expectedService=${expectedServiceName.ifBlank { "-" }} " +
            "expectedDevice=${expectedDeviceId.ifBlank { "-" }} " +
                "requireSecure=$requireSecure allowPlaintext=$allowPlaintextFallback " +
                "directHost=${directHost.ifBlank { "-" }}:$directPort"
        )
        val xWingFailureReason = P2PXWingKem.availabilityFailureReason()
        emit(
            "runtime sdk=${Build.VERSION.SDK_INT} " +
                "mlkem=${AndroidPQCCryptoProvider.isAvailable()} " +
                "xwing=${xWingFailureReason == null} " +
                "xwingReason=${xWingFailureReason ?: "ok"}"
        )
        emit("status-file=${statusFile().absolutePath}")

        smokeJob = lifecycleScope.launch {
            runCatching {
                val baseSettings = SecuritySettingsStore.observe(applicationContext).first()
                val securityConfig = MacRemoteControlClient.SecurityConfig(
                    encryptionRequired = requireSecure && baseSettings.encryptionEnabled,
                    allowPlaintextFallback = allowPlaintextFallback,
                    allowTrustOnFirstUse = true,
                    handshakePolicyOverride = baseSettings.toHandshakePolicyOverride()
                )

                seedPeerKemIfProvided(
                    peerIds = listOfNotNull(
                        expectedDeviceId.ifBlank { null },
                        directHost.ifBlank { null }
                    ),
                    mlKemPublicB64 = peerMlKemPublicB64,
                    xWingPublicB64 = peerXWingPublicB64
                )
                emit(
                    "policy requirePqc=${securityConfig.handshakePolicyOverride?.requirePqc} " +
                        "allowClassicFallback=${securityConfig.handshakePolicyOverride?.allowClassicFallback}"
                )

                var connectStarted = false
                var lastSeenServices = 0

                val discoveryJob = if (directHost.isBlank()) {
                    launch {
                        discovery.discover().collectLatest { services ->
                            lastSeenServices = services.size
                            if (services.isEmpty()) {
                                emitOnce("discovery empty")
                                return@collectLatest
                            }
                            emitOnce("discovery services=${services.size}")

                            val matched = services.firstOrNull { service ->
                                val hint = service.identityHint()
                                val serviceNameMatches = expectedServiceName.isBlank() || service.name == expectedServiceName
                                val deviceMatches = expectedDeviceId.isBlank() || hint.deviceId == expectedDeviceId
                                val fingerprintMatches =
                                    expectedFingerprint.isBlank() || hint.advertisedFingerprint == expectedFingerprint
                                serviceNameMatches && deviceMatches && fingerprintMatches
                            } ?: services.firstOrNull().takeIf {
                                expectedServiceName.isBlank() && expectedDeviceId.isBlank() && expectedFingerprint.isBlank()
                            }

                            if (matched != null && !connectStarted) {
                                connectStarted = true
                                val hint = matched.identityHint()
                                emit(
                                    "service matched name=${matched.name} host=${matched.host}:${matched.port} " +
                                        "deviceId=${hint.deviceId ?: "-"} fp=${hint.advertisedFingerprint ?: "-"}"
                                )
                                connectToTarget(
                                    target = MacRemoteControlClient.ConnectionTarget(
                                        host = matched.host,
                                        port = matched.port,
                                        displayName = matched.name,
                                        deviceIdHint = hint.deviceId,
                                        advertisedFingerprint = hint.advertisedFingerprint
                                    ),
                                    securityConfig = securityConfig
                                )
                            }
                        }
                    }
                } else {
                    emit("direct connect host=$directHost:$directPort")
                    connectStarted = true
                    connectToTarget(
                        target = MacRemoteControlClient.ConnectionTarget(
                            host = directHost,
                            port = directPort,
                            displayName = expectedServiceName.ifBlank { directHost },
                            deviceIdHint = expectedDeviceId.ifBlank { null },
                            advertisedFingerprint = expectedFingerprint.ifBlank { null }
                        ),
                        securityConfig = securityConfig
                    )
                    null
                }

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
                                        "security negotiating peer=${securityState.peerId ?: "-"} pinned=${securityState.pinned}"
                                    )

                                is MacRemoteControlClient.SecurityState.Secure -> {
                                    emitOnce(
                                        "security secure peer=${securityState.peerId ?: "-"} " +
                                            "suite=${securityState.suite} trust=${securityState.trustState}"
                                    )
                                    if (client.latestFrame.value != null) {
                                        markSuccess("secure_frame_received")
                                        if (autoFinish) {
                                            delay(1500L)
                                            finish()
                                        }
                                        return@withTimeout
                                    }
                                }

                                is MacRemoteControlClient.SecurityState.Plaintext -> {
                                    emitOnce("security plaintext reason=${securityState.reason}")
                                    if (!requireSecure && client.latestFrame.value != null) {
                                        markSuccess("plaintext_frame_received")
                                        if (autoFinish) {
                                            delay(1500L)
                                            finish()
                                        }
                                        return@withTimeout
                                    }
                                }

                                is MacRemoteControlClient.SecurityState.Failed ->
                                    error("security_failed=${securityState.reason}")
                            }

                            val frame = client.latestFrame.value
                            if (frame != null) {
                                emitOnce(
                                    "frame width=${frame.width} height=${frame.height} format=${frame.format ?: "-"}"
                                )
                            }

                            delay(250L)
                        }
                    }
                    error("timeout")
                } finally {
                    discoveryJob?.cancel()
                }
            }.onFailure { error ->
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
        smokeJob?.cancel()
        client.disconnect()
        super.onDestroy()
    }

    private fun markSuccess(reason: String) {
        emit("success reason=$reason")
    }

    private fun markFailure(reason: String) {
        emit("failure reason=$reason")
    }

    private fun emitOnce(line: String) {
        if (statusLines.lastOrNull() == line) return
        emit(line)
    }

    private fun emit(line: String) {
        val stamped = "[${timestamp()}] $line"
        Log.i(TAG, stamped)
        statusFile().parentFile?.mkdirs()
        statusFile().appendText("$stamped\n")
        statusLines.addLast(line)
        while (statusLines.size > 12) {
            statusLines.removeFirst()
        }
        runOnUiThread {
            statusView.text = statusLines.joinToString(separator = "\n")
        }
    }

    private fun statusFile(): File =
        File(filesDir, STATUS_FILE_NAME)

    private fun connectToTarget(
        target: MacRemoteControlClient.ConnectionTarget,
        securityConfig: MacRemoteControlClient.SecurityConfig
    ) {
        client.connect(
            target = target,
            securityConfig = securityConfig
        )
    }

    private fun seedPeerKemIfProvided(
        peerIds: List<String>,
        mlKemPublicB64: String,
        xWingPublicB64: String
    ) {
        val kemKeys = buildList {
            if (mlKemPublicB64.isNotBlank()) {
                add(
                    AppMessage.KemPublicKeyInfo(
                        suiteWireId = P2PCryptoSuite.MLKEM_768.wireId.toInt(),
                        publicKey = Base64.decode(mlKemPublicB64, Base64.DEFAULT)
                    )
                )
            }
            if (xWingPublicB64.isNotBlank()) {
                add(
                    AppMessage.KemPublicKeyInfo(
                        suiteWireId = P2PCryptoSuite.X_WING.wireId.toInt(),
                        publicKey = Base64.decode(xWingPublicB64, Base64.DEFAULT)
                    )
                )
            }
        }
        if (kemKeys.isEmpty()) return
        peerIds
            .filter { it.isNotBlank() }
            .forEach { peerId ->
                peerKemStore.save(peerId, kemKeys)
                emit("seeded peer KEM peer=$peerId mlkem=${mlKemPublicB64.isNotBlank()} xwing=${xWingPublicB64.isNotBlank()}")
            }
    }

    private fun timestamp(): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())

    companion object {
        private const val TAG = "SB-LAN-SMOKE"
        private const val STATUS_FILE_NAME = "debug-lan-interop-smoke-status.log"
        private const val EXTRA_EXPECTED_SERVICE_NAME = "skybridgeExpectedServiceName"
        private const val EXTRA_EXPECTED_DEVICE_ID = "skybridgeExpectedDeviceId"
        private const val EXTRA_EXPECTED_FINGERPRINT = "skybridgeExpectedFingerprint"
        private const val EXTRA_DIRECT_HOST = "skybridgeDirectHost"
        private const val EXTRA_DIRECT_PORT = "skybridgeDirectPort"
        private const val EXTRA_PEER_MLKEM_PUBLIC_B64 = "skybridgePeerMlkemPublicB64"
        private const val EXTRA_PEER_XWING_PUBLIC_B64 = "skybridgePeerXwingPublicB64"
        private const val EXTRA_TIMEOUT_SECONDS = "skybridgeTimeoutSeconds"
        private const val EXTRA_REQUIRE_SECURE = "skybridgeRequireSecure"
        private const val EXTRA_ALLOW_PLAINTEXT_FALLBACK = "skybridgeAllowPlaintextFallback"
        private const val EXTRA_AUTO_FINISH = "skybridgeAutoFinish"
        private const val DEFAULT_TIMEOUT_SECONDS = 120L
        private const val DEFAULT_REMOTE_PORT = 5901
    }
}
