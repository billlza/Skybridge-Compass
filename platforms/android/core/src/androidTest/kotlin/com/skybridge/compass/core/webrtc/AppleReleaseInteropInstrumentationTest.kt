package com.skybridge.compass.core.webrtc

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.skybridge.compass.core.data.NetworkSettings
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.capabilityAwareHandshakePolicyOverride
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class AppleReleaseInteropInstrumentationTest {

    @Test
    fun joinsAppleSmokeHostUsingCurrentSignalingContract() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
        val code = readSmokePrivateTextFile(
            context = context,
            fileName = args.getString(ARG_CODE_FILE),
            label = "Connection code"
        )
        val signalingUrl = args.getString(ARG_SIGNALING_WS_URL)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "ws://10.0.2.2:18443/ws"
        val timeoutSeconds = args.getString(ARG_TIMEOUT_SECONDS)?.toLongOrNull() ?: 90L
        val pqcEnabled = parseBooleanInstrumentationArg(
            args.getString(ARG_PQC_ENABLED),
            ARG_PQC_ENABLED,
            defaultValue = true
        )
        val pqcMinimumTier = requireCanonicalPqcMinimumTier(
            args.getString(ARG_PQC_MINIMUM_TIER)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "nativePQC"
        )
        val expectQPeriapt = args.getString(ARG_EXPECT_QPERIAPT)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.toBooleanStrict()
            ?: (pqcMinimumTier == P2PQPeriaptKem.MINIMUM_TIER_RAW)
        val expectedSuite = args.getString(ARG_EXPECTED_NEGOTIATED_SUITE)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let(::parseExpectedSuite)
            ?: if (expectQPeriapt) P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND else null
        args.getString(ARG_CLIENT_VERSION)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { System.setProperty("skybridge.clientVersion", it) }
        args.getString(ARG_PROTOCOL_VERSION)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { System.setProperty("skybridge.protocolVersion", it) }

        val injectedAuthContext = readSmokeAuthContext(
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
                injectedAuthContext
            },
            diagnosticsConfig = WebRtcDiagnosticsConfig(
                allowLoopbackOriginAlias = true,
                allowLocalNetworkCompatSignaling = true,
                keepAliveHeartbeat = true,
                ignoreClassicFallbackCooldown = true
            )
        )
        try {
            println("SB-ANDROID-SMOKE starting code=<redacted> signaling=$signalingUrl")
            manager.setPqcEnabled(pqcEnabled)
            if (pqcEnabled) {
                manager.setHandshakePolicyOverride(
                    capabilityAwareHandshakePolicyOverride(
                        requirePqc = true,
                        allowClassicFallback = false,
                        minimumTierRaw = pqcMinimumTier
                    )
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
                            val hasBootstrapKem = when {
                                !pqcEnabled -> true
                                expectedSuite == P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND ->
                                    manager.hasBootstrappedPeerQPeriaptForCurrentPeer()
                                else -> manager.hasBootstrappedPeerKemForCurrentPeer()
                            }
                            val hasExpectedSuite = when {
                                !pqcEnabled -> true
                                expectedSuite != null -> manager.negotiatedSuiteWireId() == expectedSuite.wireId.toInt()
                                else -> manager.hasPqcSessionKeys()
                            }
                            if (
                                hasSessionKeys &&
                                expectedSuite != null &&
                                manager.negotiatedSuiteWireId() != expectedSuite.wireId.toInt()
                            ) {
                                error(
                                    "Expected negotiated suite ${expectedSuite.name}, " +
                                        "actual=${manager.actualSuiteDescription()}"
                                )
                            }
                            if (hasSessionKeys && hasBootstrapKem && hasExpectedSuite) {
                                println(
                                    "SB-ANDROID-SMOKE success code=<redacted> " +
                                        "bootstrapKem=$hasBootstrapKem " +
                                        "bootstrapQPeriapt=${manager.hasBootstrappedPeerQPeriaptForCurrentPeer()} " +
                                        "qperiapt=${manager.hasQPeriaptSessionKeys()} " +
                                        "expectedSuite=${expectedSuite?.name ?: "any-pqc"} " +
                                        "suite=${manager.actualSuiteDescription()}"
                                )
                                return@withTimeout
                            }
                        }

                        else -> Unit
                    }
                    delay(250L)
                }
            }

            assertTrue("Expected app-layer session keys after Apple smoke join", manager.hasSessionKeys())
            if (pqcEnabled && expectedSuite != null) {
                assertTrue(
                    "Expected negotiated suite ${expectedSuite.name}, actual=${manager.actualSuiteDescription()}",
                    manager.negotiatedSuiteWireId() == expectedSuite.wireId.toInt()
                )
                if (expectedSuite == P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND) {
                    assertTrue(
                        "Expected peer Q-Periapt bootstrap material after Apple smoke join",
                        manager.hasBootstrappedPeerQPeriaptForCurrentPeer()
                    )
                }
            } else if (pqcEnabled) {
                assertTrue("Expected PQC session keys after Apple smoke join", manager.hasPqcSessionKeys())
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
        private const val ARG_AUTH_CONTEXT_FILE = "skybridgeAuthContextFile"
        private const val ARG_CLIENT_VERSION = "skybridgeClientVersion"
        private const val ARG_PROTOCOL_VERSION = "skybridgeProtocolVersion"
    }
}

private fun readSmokePrivateTextFile(
    context: android.content.Context,
    fileName: String?,
    label: String
): String {
    val safeFileName = fileName
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: throw IllegalArgumentException("$label file name is missing")
    require(!safeFileName.contains('/') && !safeFileName.contains('\\')) {
        "$label file name must not contain path separators"
    }
    val file = File(context.filesDir, safeFileName)
    require(file.isFile) { "$label file missing: $safeFileName" }
    return try {
        file.readText().trim().also {
            require(it.isNotEmpty()) { "$label file is empty" }
        }
    } finally {
        file.delete()
    }
}

private fun parseExpectedSuite(raw: String): P2PCryptoSuite {
    P2PCryptoSuite.entries.firstOrNull { it.name == raw }?.let { return it }
    val wireId = if (raw.startsWith("0x", ignoreCase = true)) {
        raw.drop(2).toIntOrNull(radix = 16)
    } else {
        raw.toIntOrNull()
    }
    if (wireId != null) {
        require(wireId in 0..UShort.MAX_VALUE.toInt()) {
            "Expected P2P suite wire id out of range: $raw"
        }
        return P2PCryptoSuite.fromWireId(wireId.toUShort())
            ?: throw IllegalArgumentException("Unknown expected P2P suite wire id: $raw")
    }
    throw IllegalArgumentException("Unknown expected P2P suite: $raw")
}

private fun readSmokeAuthContext(
    context: android.content.Context,
    authContextFileName: String?
): SignalServerClient.UserAuthContext? {
    val fileName = authContextFileName
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: return null
    require(!fileName.contains('/') && !fileName.contains('\\')) {
        "Auth context file name must not contain path separators"
    }
    val file = File(context.filesDir, fileName)
    require(file.isFile) { "Auth context file missing: $fileName" }
    return try {
        val payload = JSONObject(file.readText())
        val bearerToken = payload.getString("bearerToken").trim()
        val tenantId = payload.getString("tenantId").trim()
        require(bearerToken.isNotEmpty()) { "Auth context bearer token is empty" }
        require(tenantId.isNotEmpty()) { "Auth context tenant id is empty" }
        SignalServerClient.UserAuthContext(
            bearerToken = bearerToken,
            tenantId = tenantId
        )
    } finally {
        file.delete()
    }
}

private fun parseBooleanInstrumentationArg(
    raw: String?,
    argName: String,
    defaultValue: Boolean
): Boolean =
    raw
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.let { value ->
            try {
                value.toBooleanStrict()
            } catch (error: IllegalArgumentException) {
                throw IllegalArgumentException(
                    "Invalid boolean instrumentation arg $argName: $value (expected true|false)",
                    error
                )
            }
        }
        ?: defaultValue

private fun requireCanonicalPqcMinimumTier(raw: String): String {
    require(raw in canonicalPqcMinimumTiers) {
        "Unsupported PQC minimum tier instrumentation arg: $raw"
    }
    return raw
}

private val canonicalPqcMinimumTiers = setOf(
    "nativePQC",
    "liboqsPQC",
    P2PQPeriaptKem.MINIMUM_TIER_RAW,
    "classic"
)

private fun SkyBridgeWebRtcConnectionManager.actualSuiteDescription(): String {
    val name = negotiatedSuiteName() ?: "-"
    val wireId = negotiatedSuiteWireId()?.let { "0x" + it.toString(radix = 16).padStart(4, '0') } ?: "-"
    return "$name/$wireId"
}
