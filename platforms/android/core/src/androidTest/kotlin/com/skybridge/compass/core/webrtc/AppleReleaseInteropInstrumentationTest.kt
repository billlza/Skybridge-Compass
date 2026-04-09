package com.skybridge.compass.core.webrtc

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.skybridge.compass.core.data.NetworkSettings
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppleReleaseInteropInstrumentationTest {

    @Test
    fun joinsAppleSmokeHostUsingCurrentSignalingContract() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val code = args.getString(ARG_CODE)?.trim().orEmpty()
        require(code.isNotEmpty()) { "Missing instrumentation arg: $ARG_CODE" }
        val signalingUrl = args.getString(ARG_SIGNALING_WS_URL)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "ws://10.0.2.2:18443/ws"
        val timeoutSeconds = args.getString(ARG_TIMEOUT_SECONDS)?.toLongOrNull() ?: 90L
        val pqcEnabled = args.getString(ARG_PQC_ENABLED)?.toBooleanStrictOrNull() ?: true
        val allowStaticFallback = args.getString(ARG_ALLOW_STATIC_ED25519_FALLBACK)
            ?.toBooleanStrictOrNull()
            ?: false
        if (allowStaticFallback) {
            System.setProperty("skybridge.smoke.allowStaticEd25519Fallback", "1")
        } else {
            System.clearProperty("skybridge.smoke.allowStaticEd25519Fallback")
        }
        if (!pqcEnabled) {
            System.setProperty("skybridge.smoke.classicOnly", "1")
        } else {
            System.clearProperty("skybridge.smoke.classicOnly")
        }
        args.getString(ARG_CLIENT_VERSION)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { System.setProperty("skybridge.clientVersion", it) }
        args.getString(ARG_PROTOCOL_VERSION)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { System.setProperty("skybridge.protocolVersion", it) }
        args.getString(ARG_BEARER_TOKEN)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { System.setProperty("skybridge.smoke.bearerToken", it) }
        args.getString(ARG_TENANT_ID)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { System.setProperty("skybridge.smoke.tenantId", it) }

        val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
        val manager = SkyBridgeWebRtcConnectionManager(
            context,
            networkSettingsOverrideProvider = {
                NetworkSettings(
                    webrtcEnabled = true,
                    webrtcSignalingUrl = signalingUrl,
                    stunServers = emptyList(),
                    turnServers = emptyList()
                )
            },
            localIdentityProvider = {
                LocalP2PIdentity(context.createDeviceProtectedStorageContext())
            }
        )
        try {
            println("SB-ANDROID-SMOKE starting code=$code signaling=$signalingUrl")
            manager.setPqcEnabled(pqcEnabled)
            manager.startAnswerer(code)

            withTimeout(timeoutSeconds * 1000L) {
                while (true) {
                    when (val state = manager.state.value) {
                        is SkyBridgeWebRtcConnectionManager.State.Failed ->
                            error(
                                "Interop failed: ${state.message}; signaling=${manager.signalingStatus.value.lastEvent}"
                            )

                        is SkyBridgeWebRtcConnectionManager.State.Connected -> {
                            if (manager.hasSessionKeys()) {
                                println("SB-ANDROID-SMOKE success code=${state.code}")
                                return@withTimeout
                            }
                        }

                        else -> Unit
                    }
                    delay(250L)
                }
            }

            assertTrue("Expected app-layer session keys after Apple smoke join", manager.hasSessionKeys())
        } finally {
            System.clearProperty("skybridge.smoke.bearerToken")
            System.clearProperty("skybridge.smoke.tenantId")
            System.clearProperty("skybridge.clientVersion")
            System.clearProperty("skybridge.protocolVersion")
            manager.release()
        }
    }

    companion object {
        private const val ARG_CODE = "skybridgeCode"
        private const val ARG_SIGNALING_WS_URL = "skybridgeWsUrl"
        private const val ARG_TIMEOUT_SECONDS = "skybridgeTimeoutSeconds"
        private const val ARG_PQC_ENABLED = "skybridgePqcEnabled"
        private const val ARG_ALLOW_STATIC_ED25519_FALLBACK = "skybridgeAllowStaticEd25519Fallback"
        private const val ARG_BEARER_TOKEN = "skybridgeBearerToken"
        private const val ARG_TENANT_ID = "skybridgeTenantId"
        private const val ARG_CLIENT_VERSION = "skybridgeClientVersion"
        private const val ARG_PROTOCOL_VERSION = "skybridgeProtocolVersion"
    }
}
