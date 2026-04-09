package com.skybridge.compass.android.webrtc

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.skybridge.compass.core.data.NetworkSettings
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.webrtc.ProtocolIdentityBinding
import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.core.webrtc.SignalServerClient
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppleReleaseInteropAppInstrumentationTest {

    @Test
    fun joinsAppleSmokeHostUsingAppProcess() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val code = args.getString(ARG_CODE)?.trim().orEmpty()
        require(code.isNotEmpty()) { "Missing instrumentation arg: $ARG_CODE" }
        val signalingUrl = args.getString(ARG_SIGNALING_WS_URL)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "ws://10.0.2.2:18443/ws"
        val timeoutSeconds = args.getString(ARG_TIMEOUT_SECONDS)?.toLongOrNull() ?: 90L
        val pqcEnabled = args.getString(ARG_PQC_ENABLED)?.toBooleanStrictOrNull() ?: true
        val postSuccessHoldMillis = args.getString(ARG_POST_SUCCESS_HOLD_MILLIS)?.toLongOrNull() ?: 4_000L
        val allowStaticFallback = args.getString(ARG_ALLOW_STATIC_ED25519_FALLBACK)
            ?.toBooleanStrictOrNull()
            ?: false
        val clientVersion = args.getString(ARG_CLIENT_VERSION)?.trim().orEmpty()
        val protocolVersion = args.getString(ARG_PROTOCOL_VERSION)?.trim().orEmpty()
        val injectedAuthContext = SignalServerClient.UserAuthContext(
            bearerToken = args.getString(ARG_BEARER_TOKEN)?.trim().orEmpty(),
            tenantId = args.getString(ARG_TENANT_ID)?.trim().orEmpty()
        ).takeIf { it.bearerToken.isNotBlank() && it.tenantId.isNotBlank() }
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
        System.setProperty("skybridge.smoke.ignoreClassicFallbackCooldown", "1")
        System.setProperty("skybridge.smoke.keepAliveHeartbeat", "1")
        System.setProperty("skybridge.smoke.allowLoopbackOriginAlias", "1")
        if (clientVersion.isNotEmpty()) {
            System.setProperty("skybridge.clientVersion", clientVersion)
        }
        if (protocolVersion.isNotEmpty()) {
            System.setProperty("skybridge.protocolVersion", protocolVersion)
        }

        val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
        val localIdentity = LocalP2PIdentity(context.createDeviceProtectedStorageContext())
        val signingKeys = localIdentity.getOrCreateProtocolSigningKeys()
        val localBinding = ProtocolIdentityBinding(
            deviceId = localIdentity.deviceId(),
            protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
            protocolPublicKeyBytes = signingKeys.ed25519PublicRaw32
        )
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
                localIdentity
            },
            userAuthContextProvider = {
                injectedAuthContext
            }
        )
        try {
            println("SB-ANDROID-APP-SMOKE starting code=$code signaling=$signalingUrl")
            println(
                "SB-ANDROID-APP-SMOKE binding deviceId=${localBinding.deviceId} fingerprint=${localBinding.protocolPublicKeyFingerprint}"
            )
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
                            val hasSessionKeys = manager.hasSessionKeys()
                            val hasBootstrapKem = !pqcEnabled || manager.hasBootstrappedPeerKemForCurrentPeer()
                            val hasExpectedSuite = !pqcEnabled || manager.hasPqcSessionKeys()
                            if (hasSessionKeys && hasBootstrapKem && hasExpectedSuite) {
                                println(
                                    "SB-ANDROID-APP-SMOKE success code=${state.code} bootstrapKem=$hasBootstrapKem suite=${manager.negotiatedSuiteName() ?: "-"}"
                                )
                                delay(postSuccessHoldMillis)
                                return@withTimeout
                            }
                        }

                        else -> Unit
                    }
                    delay(250L)
                }
            }

            assertTrue("Expected app-layer session keys after Apple smoke join", manager.hasSessionKeys())
            if (pqcEnabled) {
                assertTrue(
                    "Expected peer KEM bootstrap material after Apple smoke join",
                    manager.hasBootstrappedPeerKemForCurrentPeer()
                )
                assertTrue(
                    "Expected PQC rekey to complete after Apple smoke join",
                    manager.hasPqcSessionKeys()
                )
            }
        } finally {
            System.clearProperty("skybridge.smoke.ignoreClassicFallbackCooldown")
            System.clearProperty("skybridge.smoke.keepAliveHeartbeat")
            System.clearProperty("skybridge.smoke.allowLoopbackOriginAlias")
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
        private const val ARG_POST_SUCCESS_HOLD_MILLIS = "skybridgePostSuccessHoldMillis"
        private const val ARG_BEARER_TOKEN = "skybridgeBearerToken"
        private const val ARG_TENANT_ID = "skybridgeTenantId"
        private const val ARG_CLIENT_VERSION = "skybridgeClientVersion"
        private const val ARG_PROTOCOL_VERSION = "skybridgeProtocolVersion"
    }
}
