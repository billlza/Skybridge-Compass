package com.skybridge.compass.android.debug

import android.graphics.Typeface
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.skybridge.compass.R
import com.skybridge.compass.core.data.NetworkSettingsStore
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcDiagnosticsConfig
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class DebugInteropSmokeActivity : ComponentActivity() {

    private lateinit var statusView: TextView
    private lateinit var manager: SkyBridgeWebRtcConnectionManager
    private var smokeJob: Job? = null
    private val statusLines = ArrayDeque<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val code = intent.getStringExtra(EXTRA_CODE)?.trim().orEmpty()
        val wsUrl = intent.getStringExtra(EXTRA_WS_URL)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: DEFAULT_SIGNALING_WS_URL
        val timeoutSeconds = intent.getStringExtra(EXTRA_TIMEOUT_SECONDS)?.toLongOrNull()
            ?: DEFAULT_TIMEOUT_SECONDS
        val pqcEnabled = intent.getBooleanExtra(EXTRA_PQC_ENABLED, true)
        val autoFinish = intent.getBooleanExtra(EXTRA_AUTO_FINISH, true)

        statusView = TextView(this).apply {
            textSize = 14f
            setPadding(32, 48, 32, 48)
            typeface = Typeface.MONOSPACE
            gravity = Gravity.START
            text = getString(R.string.debug_interop_smoke_starting)
        }
        setContentView(statusView)
        statusFile().delete()

        if (!consumeSmokeNonce(intent.getStringExtra(EXTRA_SMOKE_NONCE))) {
            emit("failure reason=invalid_smoke_nonce")
            finish()
            return
        }

        val localIdentity = LocalP2PIdentity(
            appContext = applicationContext.createDeviceProtectedStorageContext(),
            storageMode = if (pqcEnabled) {
                LocalP2PIdentity.StorageMode.ENCRYPTED
            } else {
                LocalP2PIdentity.StorageMode.ISOLATED_PLAINTEXT_TEST
            }
        )
        manager = SkyBridgeWebRtcConnectionManager(
            appContext = applicationContext,
            localIdentityProvider = { localIdentity },
            diagnosticsConfig = WebRtcDiagnosticsConfig(
                forceRelayIce = true,
                immediateHandshake = true
            )
        )

        emit("boot code=<redacted> signaling=${DebugSmokeRedaction.urlForArtifact(wsUrl)} pqc=$pqcEnabled")
        emit("status-file=${statusFile().absolutePath}")

        if (code.isEmpty()) {
            markFailure("missing_code")
            return
        }

        smokeJob = lifecycleScope.launch {
            runCatching {
                var completedSuccessfully = false
                NetworkSettingsStore.setWebRtcEnabled(applicationContext, true)
                NetworkSettingsStore.setWebRtcSignalingUrl(applicationContext, wsUrl)

                manager.setPqcEnabled(pqcEnabled)
                if (!pqcEnabled) {
                    manager.setHandshakePolicyOverride(
                        P2PHandshakePolicyOverride(
                            requirePqc = false,
                            allowClassicFallback = true,
                            minimumTierRaw = "classic",
                            requireSecureEnclavePoP = false,
                            providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_CLASSIC
                        )
                    )
                }

                emit("starting answerer")
                manager.startAnswerer(code)

                withTimeout(timeoutSeconds * 1000L) {
                    while (true) {
                        val state = manager.state.value
                        val signaling = manager.signalingStatus.value.lastEvent
                        when (state) {
                            is SkyBridgeWebRtcConnectionManager.State.Idle ->
                                emitOnce("state idle signaling=$signaling")

                            is SkyBridgeWebRtcConnectionManager.State.Waiting ->
                                emitOnce("state waiting code=<redacted> signaling=$signaling")

                            is SkyBridgeWebRtcConnectionManager.State.Connecting ->
                                emitOnce("state connecting code=<redacted> signaling=$signaling")

                            is SkyBridgeWebRtcConnectionManager.State.Connected -> {
                                // DataChannel open, handshake not yet complete. Keep waiting.
                                emitOnce("state connected code=<redacted> signaling=$signaling")
                            }

                            is SkyBridgeWebRtcConnectionManager.State.Established -> {
                                emitOnce("state established code=<redacted> signaling=$signaling")
                                if (manager.hasSessionKeys()) {
                                    markSuccess("established_with_session_keys")
                                    completedSuccessfully = true
                                    if (autoFinish) {
                                        delay(1500L)
                                        finish()
                                    }
                                    return@withTimeout
                                }
                            }

                            is SkyBridgeWebRtcConnectionManager.State.Failed ->
                                error("state_failed=${state.message}; signaling=$signaling")
                        }
                        if (!manager.hasSessionKeys() &&
                            (signaling.contains("sent iceCandidate", ignoreCase = true) ||
                                signaling.contains("datachannel ready", ignoreCase = true))
                        ) {
                            emitOnce("debug kickoff handshake")
                            manager.debugKickoffHandshakeNow()
                        }
                        delay(250L)
                    }
                }

                if (completedSuccessfully) {
                    return@runCatching
                }
                error("timeout")
            }.onFailure { error ->
                Log.e(TAG, "Debug smoke failed", error)
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
        if (::manager.isInitialized) {
            manager.release()
        }
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

    private fun statusFile(): File =
        File(filesDir, STATUS_FILE_NAME)

    private fun nonceFile(): File =
        File(filesDir, NONCE_FILE_NAME)

    private fun consumeSmokeNonce(providedRaw: String?): Boolean {
        val provided = providedRaw?.trim().orEmpty()
        val file = nonceFile()
        val expected = if (file.isFile) file.readText().trim() else ""
        file.delete()
        return provided.isNotEmpty() &&
            expected.isNotEmpty() &&
            MessageDigest.isEqual(provided.toByteArray(), expected.toByteArray())
    }

    private fun timestamp(): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())

    companion object {
        private const val TAG = "SB-DEBUG-SMOKE"
        private const val STATUS_FILE_NAME = "debug-interop-smoke-status.log"
        private const val NONCE_FILE_NAME = "debug-interop-smoke-nonce"
        private const val EXTRA_CODE = "skybridgeCode"
        private const val EXTRA_WS_URL = "skybridgeWsUrl"
        private const val EXTRA_TIMEOUT_SECONDS = "skybridgeTimeoutSeconds"
        private const val EXTRA_PQC_ENABLED = "skybridgePqcEnabled"
        private const val EXTRA_AUTO_FINISH = "skybridgeAutoFinish"
        private const val EXTRA_SMOKE_NONCE = "skybridgeSmokeNonce"
        private const val DEFAULT_SIGNALING_WS_URL = "ws://10.0.2.2:18443/ws"
        private const val DEFAULT_TIMEOUT_SECONDS = 120L
    }
}
