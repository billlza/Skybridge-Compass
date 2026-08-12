package com.skybridge.compass.android.webrtc

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.security.toHandshakePolicyOverride
import com.skybridge.compass.core.data.NetworkSettings
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.webrtc.ProtocolIdentityBinding
import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcDiagnosticsConfig
import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner
import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class AppleReleaseInteropOffererAppInstrumentationTest {

    @Test
    fun hostsCodeForAppleResponderUsingAppProcess() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val signalingUrl = args.getString(ARG_SIGNALING_WS_URL)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "wss://api.nebula-technologies.net/ws"
        val timeoutSeconds = args.getString(ARG_TIMEOUT_SECONDS)?.toLongOrNull() ?: 120L
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
        val expectFileTransfer = args.getString(ARG_EXPECT_FILE_TRANSFER)
            .strictBooleanInstrumentationArg(ARG_EXPECT_FILE_TRANSFER, defaultValue = false)
        val fileTransferTimeoutSeconds = args.getString(ARG_FILE_TRANSFER_TIMEOUT_SECONDS)?.toLongOrNull() ?: 30L
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
        try {
            println("SB-ANDROID-APP-OFFER starting signaling=$signalingUrl")
            println(
                "SB-ANDROID-APP-OFFER binding deviceId=<redacted> fingerprint=<redacted>"
            )
            manager.setPqcEnabled(pqcEnabled)
            if (pqcEnabled) {
                manager.setHandshakePolicyOverride(
                    SecuritySettings(pqcMinimumTier = pqcMinimumTier).toHandshakePolicyOverride()
                )
            }
            val code = manager.generateConnectionCode()
            writeSmokePrivateTextFile(
                context = context,
                fileName = args.getString(ARG_CODE_OUTPUT_FILE),
                contents = code,
                label = "Connection code"
            )
            println("SB-ANDROID-APP-OFFER code=<redacted>")

            var observedSessionKeys = false
            var observedBootstrapKem = false
            var observedExpectedSuite = false
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
                                return@withTimeout
                            }
                        }

                        else -> Unit
                    }
                    delay(250L)
                }
            }

            assertTrue("Expected app-layer session keys after Apple responder joined", observedSessionKeys)
            if (pqcEnabled) {
                assertTrue(
                    "Expected peer KEM bootstrap material after Apple responder joined",
                    observedBootstrapKem
                )
                assertTrue(
                    "Expected ${suiteExpectation.describeExpected()} rekey to complete after Apple responder joined",
                    observedExpectedSuite
                )
            }
            routeExpectation.requireAdmittedAtCompletion(manager)
            if (expectFileTransfer) {
                val result = sendFileToAppleResponder(
                    manager = manager,
                    fileTransferTimeoutSeconds = fileTransferTimeoutSeconds,
                    routeExpectation = routeExpectation
                )
                delay(postSuccessHoldMillis)
                val completionRoute = routeExpectation.requireAdmittedAtCompletion(
                    manager = manager,
                    secureOwner = result.owner
                )
                println(
                    "SB-ANDROID-APP-OFFER success code=<redacted> " +
                        "bootstrapKem=${suiteExpectation.bootstrapMatches(manager, pqcEnabled)} " +
                        "bootstrapQPeriapt=${manager.hasBootstrappedPeerQPeriaptForCurrentPeer()} " +
                        "qperiapt=${manager.hasQPeriaptSessionKeys()} " +
                        "expectedSuite=${suiteExpectation.describeExpected()} " +
                        "suite=${manager.actualSuiteDescription()} " +
                        "fileTransfer=true " +
                        "transferBytes=${result.payloadSize} " +
                        "payloadSha256=${result.payloadSha256.toHex()} " +
                        "outboundOps=${result.outboundOps.joinToString(",")} " +
                        "inboundAcks=${result.inboundAcks.joinToString(",")} " +
                        "route=${completionRoute.wireName}"
                )
            } else {
                delay(postSuccessHoldMillis)
                val completionRoute = routeExpectation.requireAdmittedAtCompletion(manager)
                println(
                    "SB-ANDROID-APP-OFFER success code=<redacted> " +
                        "bootstrapKem=${suiteExpectation.bootstrapMatches(manager, pqcEnabled)} " +
                        "bootstrapQPeriapt=${manager.hasBootstrappedPeerQPeriaptForCurrentPeer()} " +
                        "qperiapt=${manager.hasQPeriaptSessionKeys()} " +
                        "expectedSuite=${suiteExpectation.describeExpected()} " +
                        "suite=${manager.actualSuiteDescription()} " +
                        "route=${completionRoute.wireName}"
                )
            }
        } finally {
            System.clearProperty("skybridge.clientVersion")
            System.clearProperty("skybridge.protocolVersion")
            manager.release()
        }
    }

    companion object {
        private const val ARG_SIGNALING_WS_URL = "skybridgeWsUrl"
        private const val ARG_TIMEOUT_SECONDS = "skybridgeTimeoutSeconds"
        private const val ARG_PQC_ENABLED = "skybridgePqcEnabled"
        private const val ARG_PQC_MINIMUM_TIER = "skybridgePqcMinimumTier"
        private const val ARG_EXPECT_QPERIAPT = "skybridgeExpectQPeriapt"
        private const val ARG_EXPECTED_NEGOTIATED_SUITE = "skybridgeExpectedNegotiatedSuite"
        private const val ARG_EXPECT_FILE_TRANSFER = "skybridgeExpectFileTransfer"
        private const val ARG_FILE_TRANSFER_TIMEOUT_SECONDS = "skybridgeFileTransferTimeoutSeconds"
        private const val ARG_POST_SUCCESS_HOLD_MILLIS = "skybridgePostSuccessHoldMillis"
        private const val ARG_AUTH_CONTEXT_FILE = "skybridgeAuthContextFile"
        private const val ARG_CODE_OUTPUT_FILE = "skybridgeCodeOutputFile"
        private const val ARG_CLIENT_VERSION = "skybridgeClientVersion"
        private const val ARG_PROTOCOL_VERSION = "skybridgeProtocolVersion"
        private const val ARG_REQUIRE_DIRECT_ROUTE = "skybridgeRequireDirectRoute"
    }
}

private data class OffererFileTransferResult(
    val owner: WebRtcSecureOperationOwner,
    val payloadSize: Int,
    val payloadSha256: ByteArray,
    val outboundOps: List<CrossNetworkFileTransferOp>,
    val inboundAcks: List<CrossNetworkFileTransferOp>
)

private suspend fun sendFileToAppleResponder(
    manager: SkyBridgeWebRtcConnectionManager,
    fileTransferTimeoutSeconds: Long,
    routeExpectation: SmokeRouteExpectation
): OffererFileTransferResult {
    val peerMetadataReady = withTimeoutOrNull(fileTransferTimeoutSeconds * 1000L) {
        while (manager.authenticatedPeerMetadata.value?.deviceId.isNullOrBlank()) {
            when (val state = manager.state.value) {
                is SkyBridgeWebRtcConnectionManager.State.Failed ->
                    error(
                        "WebRTC failed while waiting for authenticated peer metadata: " +
                            "${state.message}; signaling=${manager.signalingStatus.value.lastEvent}"
                    )

                else -> Unit
            }
            delay(100L)
        }
        true
    } ?: false
    if (!peerMetadataReady) {
        error(
            "Timed out waiting for authenticated peer metadata before iOS file transfer; " +
                "managerState=${manager.state.value} " +
                "signaling=${manager.signalingStatus.value.lastEvent}"
        )
    }

    val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    val transferId = UUID.randomUUID().toString()
    val preflightOwner = checkNotNull(manager.currentSecureOperationOwner()) {
        "File-transfer smoke has no current secure owner after route admission"
    }
    routeExpectation.requireAdmittedAtCompletion(manager, preflightOwner)
    val transfer = RecordingFileTransferTransport(
        manager = manager,
        json = json,
        expectedTransferId = transferId,
        preflightOwner = preflightOwner
    )
    val controller = WebRtcFileTransferController(transfer, json = json)
    transfer.attach(controller::handleIncoming)

    val payload = buildString {
        appendLine("skybridge-android-ios-file-transfer-smoke")
        appendLine("transferId=$transferId")
        appendLine("suite=${manager.actualSuiteDescription()}")
    }.encodeToByteArray()
    val payloadSha256 = sha256(payload)
    controller.sendBytesAsFile(
        transferId = transferId,
        fileName = "android-ios-smoke.txt",
        mimeType = "text/plain",
        bytes = payload,
        chunkSize = 16 * 1024
    )
    println(
        "SB-ANDROID-APP-OFFER fileTransferSent " +
            "outboundOps=${transfer.outboundOpsSnapshot().joinToString(",")} " +
            "progress=${controller.progress.value.lastStatus}"
    )
    val completionAck: CrossNetworkFileTransferMessage =
        withTimeoutOrNull<CrossNetworkFileTransferMessage>(fileTransferTimeoutSeconds * 1000L) {
            while (true) {
                if (transfer.peerError.isCompleted) {
                    val peerError = transfer.peerError.await()
                    error(
                        "iOS file-transfer error: ${peerError.message ?: "unspecified"}; " +
                            "outboundOps=${transfer.outboundOpsSnapshot()} " +
                            "inboundOps=${transfer.inboundOpsSnapshot()} " +
                            "progress=${controller.progress.value} " +
                            "managerState=${manager.state.value} " +
                            "signaling=${manager.signalingStatus.value.lastEvent}"
                    )
                }
                if (transfer.completeAck.isCompleted) {
                    return@withTimeoutOrNull transfer.completeAck.await()
                }
                when (val state = manager.state.value) {
                    is SkyBridgeWebRtcConnectionManager.State.Failed ->
                        error(
                            "WebRTC failed while waiting for iOS completeAck: ${state.message}; " +
                                "outboundOps=${transfer.outboundOpsSnapshot()} " +
                                "inboundOps=${transfer.inboundOpsSnapshot()} " +
                                "progress=${controller.progress.value} " +
                                "signaling=${manager.signalingStatus.value.lastEvent}"
                        )

                    else -> Unit
                }
                delay(100L)
            }
            error("unreachable completeAck wait loop exited")
        } ?: error(
            "Timed out waiting for iOS completeAck after ${fileTransferTimeoutSeconds}s; " +
                "outboundOps=${transfer.outboundOpsSnapshot()} " +
                "inboundOps=${transfer.inboundOpsSnapshot()} " +
                "progress=${controller.progress.value} " +
                "managerState=${manager.state.value} " +
                "signaling=${manager.signalingStatus.value.lastEvent}"
        )
    assertEquals(
        "Expected iOS completeAck receivedBytes to match payload",
        payload.size.toLong(),
        completionAck.receivedBytes
    )
    assertArrayEquals(
        "Expected iOS completeAck fileSha256 to match payload",
        payloadSha256,
        completionAck.fileSha256
    )
    assertEquals(
        "Expected Android outbound file-transfer ops",
        listOf(
            CrossNetworkFileTransferOp.metadata,
            CrossNetworkFileTransferOp.chunk,
            CrossNetworkFileTransferOp.complete
        ),
        transfer.outboundOpsSnapshot()
    )
    assertTrue(
        "Expected iOS ACK sequence to include metadataAck/chunkAck/completeAck; " +
            "actual=${transfer.inboundOpsSnapshot()}",
        transfer.inboundOpsSnapshot().containsAll(
            listOf(
                CrossNetworkFileTransferOp.metadataAck,
                CrossNetworkFileTransferOp.chunkAck,
                CrossNetworkFileTransferOp.completeAck
            )
        )
    )

    return OffererFileTransferResult(
        owner = transfer.exactFileTransferOwner(),
        payloadSize = payload.size,
        payloadSha256 = payloadSha256,
        outboundOps = transfer.outboundOpsSnapshot(),
        inboundAcks = transfer.inboundOpsSnapshot()
    )
}
