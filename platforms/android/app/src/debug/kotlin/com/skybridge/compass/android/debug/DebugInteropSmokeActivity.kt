package com.skybridge.compass.android.debug

import android.graphics.Typeface
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.skybridge.compass.core.data.NetworkSettingsStore
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.io.File
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
        val allowStaticFallback = intent.getBooleanExtra(EXTRA_ALLOW_STATIC_ED25519_FALLBACK, false)
        val autoFinish = intent.getBooleanExtra(EXTRA_AUTO_FINISH, true)
        val bearerToken = intent.getStringExtra(EXTRA_BEARER_TOKEN)?.trim().orEmpty()
        val tenantId = intent.getStringExtra(EXTRA_TENANT_ID)?.trim().orEmpty()

        if (allowStaticFallback) {
            System.setProperty("skybridge.smoke.allowStaticEd25519Fallback", "1")
        } else {
            System.clearProperty("skybridge.smoke.allowStaticEd25519Fallback")
        }
        System.setProperty("skybridge.smoke.forceRelayIce", "1")
        System.setProperty("skybridge.smoke.immediateHandshake", "1")
        if (!pqcEnabled) {
            System.setProperty("skybridge.smoke.classicOnly", "1")
        } else {
            System.clearProperty("skybridge.smoke.classicOnly")
        }
        if (bearerToken.isNotEmpty() && tenantId.isNotEmpty()) {
            System.setProperty("skybridge.smoke.bearerToken", bearerToken)
            System.setProperty("skybridge.smoke.tenantId", tenantId)
        }

        statusView = TextView(this).apply {
            textSize = 14f
            setPadding(32, 48, 32, 48)
            typeface = Typeface.MONOSPACE
            gravity = Gravity.START
            text = "Starting SkyBridge debug smoke..."
        }
        setContentView(statusView)

        manager = SkyBridgeWebRtcConnectionManager(applicationContext)

        emit("boot code=$code signaling=$wsUrl pqc=$pqcEnabled staticFallback=$allowStaticFallback")
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
                                emitOnce("state waiting code=${state.code} signaling=$signaling")

                            is SkyBridgeWebRtcConnectionManager.State.Connecting ->
                                emitOnce("state connecting code=${state.code} signaling=$signaling")

                            is SkyBridgeWebRtcConnectionManager.State.Connected -> {
                                emitOnce("state connected code=${state.code} signaling=$signaling")
                                if (manager.hasSessionKeys()) {
                                    markSuccess("connected_with_session_keys")
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
        manager.release()
        System.clearProperty("skybridge.smoke.allowStaticEd25519Fallback")
        System.clearProperty("skybridge.smoke.forceRelayIce")
        System.clearProperty("skybridge.smoke.immediateHandshake")
        System.clearProperty("skybridge.smoke.classicOnly")
        System.clearProperty("skybridge.smoke.bearerToken")
        System.clearProperty("skybridge.smoke.tenantId")
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

    private fun timestamp(): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())

    companion object {
        private const val TAG = "SB-DEBUG-SMOKE"
        private const val STATUS_FILE_NAME = "debug-interop-smoke-status.log"
        private const val EXTRA_CODE = "skybridgeCode"
        private const val EXTRA_WS_URL = "skybridgeWsUrl"
        private const val EXTRA_TIMEOUT_SECONDS = "skybridgeTimeoutSeconds"
        private const val EXTRA_PQC_ENABLED = "skybridgePqcEnabled"
        private const val EXTRA_ALLOW_STATIC_ED25519_FALLBACK = "skybridgeAllowStaticEd25519Fallback"
        private const val EXTRA_AUTO_FINISH = "skybridgeAutoFinish"
        private const val EXTRA_BEARER_TOKEN = "skybridgeBearerToken"
        private const val EXTRA_TENANT_ID = "skybridgeTenantId"
        private const val DEFAULT_SIGNALING_WS_URL = "ws://10.0.2.2:18443/ws"
        private const val DEFAULT_TIMEOUT_SECONDS = 120L
    }
}
