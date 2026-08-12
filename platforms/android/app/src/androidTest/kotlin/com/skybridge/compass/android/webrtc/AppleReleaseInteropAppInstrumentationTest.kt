package com.skybridge.compass.android.webrtc

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.security.toHandshakePolicyOverride
import com.skybridge.compass.core.data.NetworkSettings
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcDiagnosticsConfig
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
        val signalingUrl = args.getString(ARG_SIGNALING_WS_URL)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "ws://10.0.2.2:18443/ws"
        val timeoutSeconds = args.getString(ARG_TIMEOUT_SECONDS)?.toLongOrNull() ?: 90L
        val pqcEnabled = args.getString(ARG_PQC_ENABLED)
            .strictBooleanInstrumentationArg(ARG_PQC_ENABLED, defaultValue = true)
        val pqcMinimumTier = args.getString(ARG_PQC_MINIMUM_TIER)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "nativePQC"
        val suiteExpectation = SmokeSuiteExpectation.fromArgs(
            pqcMinimumTier = pqcMinimumTier,
            expectedNegotiatedSuiteRaw = args.getString(ARG_EXPECTED_NEGOTIATED_SUITE),
            expectQPeriaptRaw = args.getString(ARG_EXPECT_QPERIAPT)
        )
        val routeExpectation = SmokeRouteExpectation(
            requireDirect = args.getString(ARG_REQUIRE_DIRECT_ROUTE)
                .strictBooleanInstrumentationArg(ARG_REQUIRE_DIRECT_ROUTE, defaultValue = false)
        )
        val postSuccessHoldMillis = args.getString(ARG_POST_SUCCESS_HOLD_MILLIS)?.toLongOrNull() ?: 4_000L
        val clientVersion = args.getString(ARG_CLIENT_VERSION)?.trim().orEmpty()
        val protocolVersion = args.getString(ARG_PROTOCOL_VERSION)?.trim().orEmpty()
        if (clientVersion.isNotEmpty()) {
            System.setProperty("skybridge.clientVersion", clientVersion)
        }
        if (protocolVersion.isNotEmpty()) {
            System.setProperty("skybridge.protocolVersion", protocolVersion)
        }
        val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
        val code = readSmokePrivateTextFile(
            context = context,
            fileName = args.getString(ARG_CODE_FILE),
            label = "Connection code"
        )
        val injectedAuthBundle = readSmokeAuthBundle(
            context = context,
            authContextFileName = args.getString(ARG_AUTH_CONTEXT_FILE)
        )
        val localIdentity = LocalP2PIdentity(
            appContext = context.createDeviceProtectedStorageContext(),
            storageMode = if (pqcEnabled) {
                LocalP2PIdentity.StorageMode.ENCRYPTED
            } else {
                LocalP2PIdentity.StorageMode.ISOLATED_PLAINTEXT_TEST
            }
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
                injectedAuthBundle?.userAuthContext
            },
            localBusinessIdentityProvider = {
                injectedAuthBundle?.localBusinessIdentity
            },
            diagnosticsConfig = WebRtcDiagnosticsConfig(
                allowLoopbackOriginAlias = true,
                allowLocalNetworkCompatSignaling = true,
                keepAliveHeartbeat = true,
                ignoreClassicFallbackCooldown = true
            )
        )
        var observedSessionKeys = false
        var observedBootstrapKem = false
        var observedExpectedSuite = false
        try {
            println("SB-ANDROID-APP-SMOKE starting code=<redacted> signaling=$signalingUrl")
            println(
                "SB-ANDROID-APP-SMOKE binding deviceId=<redacted> fingerprint=<redacted>"
            )
            manager.setPqcEnabled(pqcEnabled)
            if (pqcEnabled) {
                manager.setHandshakePolicyOverride(
                    SecuritySettings(pqcMinimumTier = pqcMinimumTier).toHandshakePolicyOverride()
                )
            }
            manager.startAnswerer(code)

            withTimeout(timeoutSeconds * 1000L) {
                while (true) {
                    when (val state = manager.state.value) {
                        is SkyBridgeWebRtcConnectionManager.State.Failed ->
                            error(
                                "Interop failed: ${state.message}; signaling=${manager.signalingStatus.value.lastEvent}"
                            )

                        is SkyBridgeWebRtcConnectionManager.State.Established -> {
                            val hasSessionKeys = manager.hasSessionKeys()
                            val hasBootstrapKem = suiteExpectation.bootstrapMatches(manager, pqcEnabled)
                            val hasExpectedSuite = !pqcEnabled || suiteExpectation.sessionMatches(manager)
                            val routeObservation = routeExpectation.observe(manager)
                            observedSessionKeys = observedSessionKeys || hasSessionKeys
                            observedBootstrapKem = observedBootstrapKem || hasBootstrapKem
                            observedExpectedSuite = observedExpectedSuite || hasExpectedSuite
                            if (
                                hasSessionKeys &&
                                suiteExpectation.expectsExactSuite &&
                                !suiteExpectation.sessionMatches(manager)
                            ) {
                                error(
                                    "Expected negotiated suite ${suiteExpectation.describeExpected()}, " +
                                        "actual=${manager.actualSuiteDescription()}"
                                )
                            }
                            if (
                                hasSessionKeys &&
                                hasBootstrapKem &&
                                hasExpectedSuite &&
                                routeObservation.admitted
                            ) {
                                delay(postSuccessHoldMillis)
                                val completionRoute =
                                    routeExpectation.requireAdmittedAtCompletion(manager)
                                println(
                                    "SB-ANDROID-APP-SMOKE success code=<redacted> " +
                                        "bootstrapKem=$hasBootstrapKem " +
                                        "bootstrapQPeriapt=${manager.hasBootstrappedPeerQPeriaptForCurrentPeer()} " +
                                        "qperiapt=${manager.hasQPeriaptSessionKeys()} " +
                                        "expectedSuite=${suiteExpectation.describeExpected()} " +
                                        "suite=${manager.actualSuiteDescription()} " +
                                        "route=${completionRoute.wireName}"
                                )
                                return@withTimeout
                            }
                        }

                        else -> Unit
                    }
                    delay(250L)
                }
            }

            assertTrue("Expected app-layer session keys after Apple smoke join", observedSessionKeys)
            if (pqcEnabled) {
                assertTrue(
                    "Expected peer KEM bootstrap material after Apple smoke join",
                    observedBootstrapKem
                )
                assertTrue(
                    "Expected ${suiteExpectation.describeExpected()} rekey to complete after Apple smoke join",
                    observedExpectedSuite
                )
            }
        } finally {
            System.clearProperty("skybridge.clientVersion")
            System.clearProperty("skybridge.protocolVersion")
            manager.release()
        }
    }

    companion object {
        private const val ARG_CODE_FILE = "skybridgeCodeFile"
        private const val ARG_SIGNALING_WS_URL = "skybridgeWsUrl"
        private const val ARG_TIMEOUT_SECONDS = "skybridgeTimeoutSeconds"
        private const val ARG_PQC_ENABLED = "skybridgePqcEnabled"
        private const val ARG_PQC_MINIMUM_TIER = "skybridgePqcMinimumTier"
        private const val ARG_EXPECT_QPERIAPT = "skybridgeExpectQPeriapt"
        private const val ARG_EXPECTED_NEGOTIATED_SUITE = "skybridgeExpectedNegotiatedSuite"
        private const val ARG_POST_SUCCESS_HOLD_MILLIS = "skybridgePostSuccessHoldMillis"
        private const val ARG_AUTH_CONTEXT_FILE = "skybridgeAuthContextFile"
        private const val ARG_CLIENT_VERSION = "skybridgeClientVersion"
        private const val ARG_PROTOCOL_VERSION = "skybridgeProtocolVersion"
        private const val ARG_REQUIRE_DIRECT_ROUTE = "skybridgeRequireDirectRoute"
    }
}
