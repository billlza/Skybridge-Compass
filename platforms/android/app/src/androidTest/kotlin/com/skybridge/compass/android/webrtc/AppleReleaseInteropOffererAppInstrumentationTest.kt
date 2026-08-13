package com.skybridge.compass.android.webrtc

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.security.toHandshakePolicyOverride
import com.skybridge.compass.core.data.NetworkSettings
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcDiagnosticsConfig
import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner
import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import com.skybridge.compass.filetransfer.webrtc.InboundFileDestinationPolicy
import com.skybridge.compass.filetransfer.webrtc.InboundFileTransferApprovalProvider
import com.skybridge.compass.filetransfer.webrtc.InboundFileTransferDecision
import com.skybridge.compass.filetransfer.webrtc.AppPrivateInboundFileCommitter
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.file.Files
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class AppleReleaseInteropOffererAppInstrumentationTest {

    @Test
    fun hostsCodeForAppleResponderUsingAppProcess() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
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
        val expectBidirectionalFileTransfer = args.getString(ARG_EXPECT_BIDIRECTIONAL_FILE_TRANSFER)
            .strictBooleanInstrumentationArg(ARG_EXPECT_BIDIRECTIONAL_FILE_TRANSFER, defaultValue = false)
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

        val useDedicatedTestStorage = args.getString(ARG_USE_DEDICATED_TEST_STORAGE)
            .strictBooleanInstrumentationArg(ARG_USE_DEDICATED_TEST_STORAGE, defaultValue = false)
        val smokeRunRef = args.getString(ARG_SMOKE_RUN_REF)?.trim().orEmpty()
        val runtimeContext = if (useDedicatedTestStorage) {
            instrumentation.context.applicationContext
        } else {
            instrumentation.targetContext.applicationContext
        }
        if (useDedicatedTestStorage) {
            val expectedPackage = args.getString(ARG_EXPECTED_STORAGE_PACKAGE)?.trim().orEmpty()
            require(expectedPackage.isNotEmpty()) {
                "$ARG_EXPECTED_STORAGE_PACKAGE is required with dedicated test storage"
            }
            require(runtimeContext.packageName == expectedPackage) {
                "Dedicated smoke storage package mismatch"
            }
            require(SHA256_HEX.matches(smokeRunRef)) {
                "$ARG_SMOKE_RUN_REF must be one lowercase SHA-256 reference"
            }
            println("SB-ANDROID-APP-OFFER storage=dedicated-test-package package=$expectedPackage")
        }
        require(!expectBidirectionalFileTransfer || useDedicatedTestStorage) {
            "Bidirectional formal file transfer requires dedicated test storage"
        }
        require(!expectBidirectionalFileTransfer || expectFileTransfer) {
            "Bidirectional formal file transfer requires the file-transfer lane"
        }
        val identityContext = instrumentation.targetContext.applicationContext
        val injectedAuthBundle = readSmokeAuthBundle(
            context = runtimeContext,
            authContextFileName = args.getString(ARG_AUTH_CONTEXT_FILE)
        )
        val sensitiveStateBefore = if (useDedicatedTestStorage) {
            rawSensitiveStateDigest(identityContext).also { digest ->
                println("SB-ANDROID-APP-OFFER sensitive-state phase=before digest=$digest")
            }
        } else {
            null
        }
        val localIdentity = LocalP2PIdentity(
            appContext = identityContext.createDeviceProtectedStorageContext(),
            storageMode = if (useDedicatedTestStorage) {
                LocalP2PIdentity.StorageMode.ENCRYPTED_EXISTING_ONLY
            } else if (pqcEnabled) {
                LocalP2PIdentity.StorageMode.ENCRYPTED
            } else {
                LocalP2PIdentity.StorageMode.ISOLATED_PLAINTEXT_TEST
            }
        )
        val manager = SkyBridgeWebRtcConnectionManager(
            runtimeContext,
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
            peerKemStoreProvider = {
                com.skybridge.compass.core.p2p.PeerKemKeyStore.existingReadOnly(identityContext)
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
                ignoreClassicFallbackCooldown = !useDedicatedTestStorage,
                existingTrustOnly = useDedicatedTestStorage
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
                context = runtimeContext,
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
                val androidToPeerTransferId = args.canonicalTransferIdArg(
                    ARG_ANDROID_TO_PEER_TRANSFER_ID,
                    required = expectBidirectionalFileTransfer,
                ) ?: UUID.randomUUID().toString()
                val peerToAndroidTransferId = args.canonicalTransferIdArg(
                    ARG_PEER_TO_ANDROID_TRANSFER_ID,
                    required = expectBidirectionalFileTransfer,
                )
                val result = sendFileToAppleResponder(
                    manager = manager,
                    fileTransferTimeoutSeconds = fileTransferTimeoutSeconds,
                    routeExpectation = routeExpectation,
                    runtimeContext = runtimeContext,
                    useDedicatedTestStorage = useDedicatedTestStorage,
                    smokeRunRef = smokeRunRef,
                    androidToPeerTransferId = androidToPeerTransferId,
                    peerToAndroidTransferId = peerToAndroidTransferId,
                )
                val completionRoute = routeExpectation.requireAdmittedAtCompletion(
                    manager = manager,
                    secureOwner = result.owner
                )
                val frozenSessionRef = manager.requireEstablishedSessionRef()
                val frozenBootstrapKem = suiteExpectation.bootstrapMatches(manager, pqcEnabled)
                val frozenBootstrapQPeriapt = manager.hasBootstrappedPeerQPeriaptForCurrentPeer()
                val frozenQPeriapt = manager.hasQPeriaptSessionKeys()
                val frozenSuite = manager.actualSuiteDescription()
                val frozenSuiteWireId = manager.negotiatedSuiteWireId().toCanonicalWireId()
                delay(postSuccessHoldMillis)
                val terminalRoute = routeExpectation.requireAdmittedAtCompletion(
                    manager = manager,
                    secureOwner = result.owner
                )
                check(manager.hasExistingTrustPeerKemAdmission(result.owner)) {
                    "Exact peer-KEM admission changed during the post-success hold"
                }
                check(terminalRoute == completionRoute) {
                    "Selected route changed during the post-success hold"
                }
                check(manager.requireEstablishedSessionRef() == frozenSessionRef) {
                    "Established session changed during the post-success hold"
                }
                check(suiteExpectation.bootstrapMatches(manager, pqcEnabled) == frozenBootstrapKem) {
                    "Peer KEM bootstrap changed during the post-success hold"
                }
                check(manager.hasBootstrappedPeerQPeriaptForCurrentPeer() == frozenBootstrapQPeriapt) {
                    "Peer Q-Periapt bootstrap changed during the post-success hold"
                }
                check(manager.hasQPeriaptSessionKeys() == frozenQPeriapt) {
                    "Negotiated Q-Periapt state changed during the post-success hold"
                }
                check(manager.actualSuiteDescription() == frozenSuite) {
                    "Negotiated suite changed during the post-success hold"
                }
                check(manager.negotiatedSuiteWireId().toCanonicalWireId() == frozenSuiteWireId) {
                    "Negotiated suite wire id changed during the post-success hold"
                }
                val commonTerminal =
                    "SB-ANDROID-APP-OFFER success code=<redacted> " +
                        "runRef=$smokeRunRef " +
                        "sessionRef=$frozenSessionRef " +
                        "bootstrapKem=$frozenBootstrapKem " +
                        "bootstrapQPeriapt=$frozenBootstrapQPeriapt " +
                        "qperiapt=$frozenQPeriapt " +
                        "expectedSuite=${suiteExpectation.describeExpected()} " +
                        "suite=$frozenSuite " +
                        "suiteWireId=$frozenSuiteWireId " +
                        "route=${completionRoute.wireName} " +
                        "fileTransfer=true "
                if (result.peerToAndroid != null) {
                    println(
                        commonTerminal +
                            "bidirectionalFileTransfer=true " +
                            "androidToPeerTransferId=${result.androidToPeer.transferId} " +
                            "androidToPeerBytes=${result.androidToPeer.payloadSize} " +
                            "androidToPeerSha256=${result.androidToPeer.payloadSha256.toHex()} " +
                            "androidToPeerOutboundOps=${result.androidToPeer.outboundOps.joinToString(",")} " +
                            "androidToPeerInboundAcks=${result.androidToPeer.inboundAcks.joinToString(",")} " +
                            "peerToAndroidTransferId=${result.peerToAndroid.transferId} " +
                            "peerToAndroidBytes=${result.peerToAndroid.payloadSize} " +
                            "peerToAndroidSha256=${result.peerToAndroid.payloadSha256.toHex()} " +
                            "peerToAndroidInboundOps=${result.peerToAndroid.inboundOps.joinToString(",")} " +
                            "peerToAndroidOutboundAcks=${result.peerToAndroid.outboundAcks.joinToString(",")} " +
                            "androidRunOwnedPayloadCleaned=${result.peerToAndroid.runOwnedPayloadCleaned}"
                    )
                } else {
                    println(
                        commonTerminal +
                            "transferBytes=${result.androidToPeer.payloadSize} " +
                            "payloadSha256=${result.androidToPeer.payloadSha256.toHex()} " +
                            "outboundOps=${result.androidToPeer.outboundOps.joinToString(",")} " +
                            "inboundAcks=${result.androidToPeer.inboundAcks.joinToString(",")}"
                    )
                }
            } else {
                delay(postSuccessHoldMillis)
                val completionRoute = routeExpectation.requireAdmittedAtCompletion(manager)
                println(
                    "SB-ANDROID-APP-OFFER success code=<redacted> " +
                        "runRef=$smokeRunRef " +
                        "sessionRef=${manager.requireEstablishedSessionRef()} " +
                        "bootstrapKem=${suiteExpectation.bootstrapMatches(manager, pqcEnabled)} " +
                        "bootstrapQPeriapt=${manager.hasBootstrappedPeerQPeriaptForCurrentPeer()} " +
                        "qperiapt=${manager.hasQPeriaptSessionKeys()} " +
                        "expectedSuite=${suiteExpectation.describeExpected()} " +
                        "suite=${manager.actualSuiteDescription()} " +
                        "suiteWireId=${manager.negotiatedSuiteWireId().toCanonicalWireId()} " +
                        "route=${completionRoute.wireName}"
                )
            }
        } finally {
            System.clearProperty("skybridge.clientVersion")
            System.clearProperty("skybridge.protocolVersion")
            manager.release()
            if (sensitiveStateBefore != null) {
                val sensitiveStateAfter = rawSensitiveStateDigest(identityContext)
                println("SB-ANDROID-APP-OFFER sensitive-state phase=after digest=$sensitiveStateAfter")
                check(sensitiveStateAfter == sensitiveStateBefore) {
                    "Formal Android identity/trust state changed during the smoke run"
                }
            }
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
        private const val ARG_EXPECT_BIDIRECTIONAL_FILE_TRANSFER =
            "skybridgeExpectBidirectionalFileTransfer"
        private const val ARG_ANDROID_TO_PEER_TRANSFER_ID = "skybridgeAndroidToPeerTransferId"
        private const val ARG_PEER_TO_ANDROID_TRANSFER_ID = "skybridgePeerToAndroidTransferId"
        private const val ARG_FILE_TRANSFER_TIMEOUT_SECONDS = "skybridgeFileTransferTimeoutSeconds"
        private const val ARG_POST_SUCCESS_HOLD_MILLIS = "skybridgePostSuccessHoldMillis"
        private const val ARG_AUTH_CONTEXT_FILE = "skybridgeAuthContextFile"
        private const val ARG_CODE_OUTPUT_FILE = "skybridgeCodeOutputFile"
        private const val ARG_CLIENT_VERSION = "skybridgeClientVersion"
        private const val ARG_PROTOCOL_VERSION = "skybridgeProtocolVersion"
        private const val ARG_REQUIRE_DIRECT_ROUTE = "skybridgeRequireDirectRoute"
        private const val ARG_USE_DEDICATED_TEST_STORAGE = "skybridgeUseDedicatedTestStorage"
        private const val ARG_EXPECTED_STORAGE_PACKAGE = "skybridgeExpectedStoragePackage"
        private const val ARG_SMOKE_RUN_REF = "skybridgeSmokeRunRef"
        private val SHA256_HEX = Regex("[0-9a-f]{64}")
    }
}

private fun rawSensitiveStateDigest(identityContext: android.content.Context): String {
    val digest = MessageDigest.getInstance("SHA-256")
    fun updateField(label: String, value: ByteArray) {
        digest.update(label.toByteArray(Charsets.UTF_8))
        digest.update(0)
        digest.update(value.size.toString().toByteArray(Charsets.US_ASCII))
        digest.update(0)
        digest.update(value)
        digest.update('\n'.code.toByte())
    }

    updateField("schema", "SkyBridge-Android-Raw-Sensitive-State-v1".toByteArray())

    val deviceProtectedContext = identityContext.createDeviceProtectedStorageContext()
    val persistentFiles = listOf(
        File(deviceProtectedContext.dataDir, "shared_prefs/skybridge_p2p_identity.xml"),
        File(deviceProtectedContext.dataDir, "shared_prefs/skybridge_pqc_keys.xml"),
        File(identityContext.dataDir, "shared_prefs/skybridge_peer_kem_keys.xml")
    )
    for (file in persistentFiles) {
        check(!Files.isSymbolicLink(file.toPath())) {
            "Existing sensitive-state path is symbolic: ${file.name}"
        }
        val canonicalRoot = if (file.path.startsWith(deviceProtectedContext.dataDir.path)) {
            deviceProtectedContext.dataDir.canonicalFile
        } else {
            identityContext.dataDir.canonicalFile
        }
        val canonicalFile = file.canonicalFile
        check(canonicalFile.path.startsWith(canonicalRoot.path + File.separator)) {
            "Sensitive-state file escaped the app data directory"
        }
        check(canonicalFile.isFile) {
            "Existing sensitive-state file is missing or unsafe: ${file.name}"
        }
        updateField("file:${file.name}", canonicalFile.readBytes())
    }

    val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    val aliases = keyStore.aliases().toList().sorted()
    check(aliases.isNotEmpty()) { "Existing Android Keystore identity is missing" }
    for (alias in aliases) {
        updateField("keystore-alias", alias.toByteArray())
        keyStore.getCertificate(alias)?.encoded?.let { certificate ->
            updateField("keystore-certificate:$alias", certificate)
        }
    }
    return digest.digest().joinToString(separator = "") { byte -> "%02x".format(byte) }
}

private data class FileTransferDirectionEvidence(
    val transferId: String,
    val payloadSize: Int,
    val payloadSha256: ByteArray,
    val outboundOps: List<CrossNetworkFileTransferOp> = emptyList(),
    val inboundAcks: List<CrossNetworkFileTransferOp> = emptyList(),
    val inboundOps: List<CrossNetworkFileTransferOp> = emptyList(),
    val outboundAcks: List<CrossNetworkFileTransferOp> = emptyList(),
    val runOwnedPayloadCleaned: Boolean = false,
)

private data class OffererFileTransferResult(
    val owner: WebRtcSecureOperationOwner,
    val androidToPeer: FileTransferDirectionEvidence,
    val peerToAndroid: FileTransferDirectionEvidence?,
)

private fun android.os.Bundle.canonicalTransferIdArg(name: String, required: Boolean): String? {
    val value = getString(name)?.trim()?.takeIf(String::isNotEmpty)
    if (value == null) {
        require(!required) { "$name is required for bidirectional formal file transfer" }
        return null
    }
    require(runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)) {
        "$name must be one canonical lowercase UUID"
    }
    return value
}

private fun Int?.toCanonicalWireId(): String = checkNotNull(this) {
    "Negotiated suite wire id is unavailable"
}.let { wireId -> "0x" + wireId.toString(radix = 16).padStart(4, '0') }

private fun SkyBridgeWebRtcConnectionManager.requireEstablishedSessionRef(): String {
    val code = (state.value as? SkyBridgeWebRtcConnectionManager.State.Established)?.code
        ?: error("Formal evidence requires one currently established session")
    return MessageDigest.getInstance("SHA-256")
        .digest(code.toByteArray(Charsets.UTF_8))
        .joinToString(separator = "") { byte -> "%02x".format(byte) }
}

private suspend fun sendFileToAppleResponder(
    manager: SkyBridgeWebRtcConnectionManager,
    fileTransferTimeoutSeconds: Long,
    routeExpectation: SmokeRouteExpectation,
    runtimeContext: android.content.Context,
    useDedicatedTestStorage: Boolean,
    smokeRunRef: String,
    androidToPeerTransferId: String,
    peerToAndroidTransferId: String?,
): OffererFileTransferResult = coroutineScope {
    val preflightOwner = withTimeoutOrNull(fileTransferTimeoutSeconds * 1000L) {
        while (true) {
            when (val state = manager.state.value) {
                is SkyBridgeWebRtcConnectionManager.State.Failed ->
                    error(
                        "WebRTC failed while waiting for exact peer-KEM admission: " +
                            "${state.message}; signaling=${manager.signalingStatus.value.lastEvent}"
                    )

                else -> Unit
            }
            val candidate = manager.currentSecureOperationOwner()
            if (
                candidate != null &&
                !manager.authenticatedPeerMetadata.value?.deviceId.isNullOrBlank() &&
                manager.hasExistingTrustPeerKemAdmission(candidate)
            ) {
                return@withTimeoutOrNull candidate
            }
            delay(100L)
        }
        error("unreachable peer-KEM admission wait loop exited")
    } ?: error(
        "Timed out waiting for exact peer-KEM admission before Apple file transfer; " +
            "managerState=${manager.state.value} " +
            "signaling=${manager.signalingStatus.value.lastEvent}"
    )

    val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    val transferId = androidToPeerTransferId
    val sessionRef = manager.requireEstablishedSessionRef()
    routeExpectation.requireAdmittedAtCompletion(manager, preflightOwner)
    check(manager.hasExistingTrustPeerKemAdmission(preflightOwner)) {
        "File-transfer smoke lost its exact peer-KEM admission before transport attachment"
    }
    val transfer = if (peerToAndroidTransferId == null) {
        RecordingFileTransferTransport(
            manager = manager,
            json = json,
            expectedTransferId = transferId,
            preflightOwner = preflightOwner,
        )
    } else {
        RecordingFileTransferTransport(
            manager = manager,
            json = json,
            expectedOutboundTransferId = transferId,
            expectedInboundTransferId = peerToAndroidTransferId,
            preflightOwner = preflightOwner,
        )
    }
    val expectedPeerDeviceId = manager.authenticatedPeerMetadata.value?.deviceId
        ?.trim()
        ?.takeIf(String::isNotEmpty)
        ?: error("Formal bidirectional transfer requires authenticated peer metadata")
    val reverseFileName = peerToAndroidTransferId?.let {
        canonicalFormalInteropFileName("peer-to-android", smokeRunRef)
    }
    val reversePayload = peerToAndroidTransferId?.let {
        canonicalFormalInteropPayload(
            direction = "peer-to-android",
            runRef = smokeRunRef,
            sessionRef = sessionRef,
            transferId = it,
        )
    }
    val controller = WebRtcFileTransferController(
        webrtc = transfer,
        json = json,
        appContext = runtimeContext.takeIf { useDedicatedTestStorage },
        inboundApprovalProvider = InboundFileTransferApprovalProvider { request ->
            val expectedTransferId = checkNotNull(peerToAndroidTransferId) {
                "Unexpected inbound file transfer in a one-way smoke"
            }
            val expectedBytes = checkNotNull(reversePayload)
            val expectedName = checkNotNull(reverseFileName)
            check(request.transferId == expectedTransferId) {
                "Formal inbound approval received an unexpected transfer id"
            }
            check(request.fileName == expectedName) {
                "Formal inbound approval received an unexpected file name"
            }
            check(request.mimeType == "text/plain") {
                "Formal inbound approval received an unexpected MIME type"
            }
            check(request.fileSizeBytes == expectedBytes.size.toLong()) {
                "Formal inbound approval received an unexpected byte count"
            }
            check(request.authenticatedSenderDeviceId == expectedPeerDeviceId) {
                "Formal inbound approval is not bound to the authenticated peer"
            }
            InboundFileTransferDecision.Accept(
                downloadsDisplayName = expectedName,
                overwriteExisting = false,
            )
        },
        inboundFileDestinationPolicy = if (useDedicatedTestStorage) {
            InboundFileDestinationPolicy.APP_PRIVATE_DURABLE
        } else {
            InboundFileDestinationPolicy.IN_MEMORY
        },
    )
    transfer.attach(controller::handleIncoming)

    // SharedFlow has no replay. Start the exact reverse receive waiter undispatched before the
    // Android payload can trigger the peer's reverse send.
    val reverseReceive = peerToAndroidTransferId?.let { expectedTransferId ->
        async(start = CoroutineStart.UNDISPATCHED) {
            withTimeout(fileTransferTimeoutSeconds * 1000L) {
                controller.receivedFiles.first { it.transferId == expectedTransferId }
            }
        }
    }

    val payload = if (peerToAndroidTransferId == null) {
        buildString {
            appendLine("skybridge-android-ios-file-transfer-smoke")
            appendLine("transferId=$transferId")
            appendLine("suite=${manager.actualSuiteDescription()}")
        }.encodeToByteArray()
    } else {
        canonicalFormalInteropPayload(
            direction = "android-to-peer",
            runRef = smokeRunRef,
            sessionRef = sessionRef,
            transferId = transferId,
        )
    }
    val payloadSha256 = sha256(payload)
    controller.sendBytesAsFile(
        transferId = transferId,
        fileName = if (peerToAndroidTransferId == null) {
            "android-ios-smoke.txt"
        } else {
            canonicalFormalInteropFileName("android-to-peer", smokeRunRef)
        },
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

    val peerToAndroidEvidence = if (reverseReceive == null) {
        null
    } else {
        val received = reverseReceive.await()
        val expectedBytes = checkNotNull(reversePayload)
        val expectedName = checkNotNull(reverseFileName)
        check(received.fileName == expectedName) {
            "Formal reverse receive emitted an unexpected file name"
        }
        check(received.bytes == null && received.downloadsUri == null) {
            "Formal reverse receive escaped app-private durable storage"
        }
        val committedPath = checkNotNull(received.localPath) {
            "Formal reverse receive omitted its app-private committed path"
        }
        val committedFile = requireOwnedRunFile(
            runtimeContext = runtimeContext,
            localPath = committedPath,
            expectedFileName = expectedName,
        )
        val committedBytes = committedFile.readBytes()
        assertArrayEquals("Formal reverse receive bytes changed", expectedBytes, committedBytes)
        val committedSha256 = sha256(committedBytes)
        assertArrayEquals(
            "Formal reverse receive SHA-256 changed",
            sha256(expectedBytes),
            committedSha256,
        )
        check(committedFile.delete() && !committedFile.exists()) {
            "Unable to remove the exact run-owned Android receive payload"
        }
        AppPrivateInboundFileCommitter.synchronizeCommittedDirectory(runtimeContext)
        FileTransferDirectionEvidence(
            transferId = checkNotNull(peerToAndroidTransferId),
            payloadSize = committedBytes.size,
            payloadSha256 = committedSha256,
            inboundOps = transfer.reverseInboundOpsSnapshot(),
            outboundAcks = transfer.reverseOutboundAcksSnapshot(),
            runOwnedPayloadCleaned = true,
        )
    }

    if (peerToAndroidEvidence != null) {
        assertEquals(
            "Expected peer-to-Android inbound file-transfer ops",
            listOf(
                CrossNetworkFileTransferOp.metadata,
                CrossNetworkFileTransferOp.chunk,
                CrossNetworkFileTransferOp.complete,
            ),
            peerToAndroidEvidence.inboundOps,
        )
        assertEquals(
            "Expected Android reverse ACK sequence",
            listOf(
                CrossNetworkFileTransferOp.metadataAck,
                CrossNetworkFileTransferOp.chunkAck,
                CrossNetworkFileTransferOp.completeAck,
            ),
            peerToAndroidEvidence.outboundAcks,
        )
    }

    check(manager.hasExistingTrustPeerKemAdmission(preflightOwner)) {
        "File-transfer smoke lost its exact peer-KEM admission before completion"
    }

    OffererFileTransferResult(
        owner = transfer.exactFileTransferOwner(),
        androidToPeer = FileTransferDirectionEvidence(
            transferId = transferId,
            payloadSize = payload.size,
            payloadSha256 = payloadSha256,
            outboundOps = transfer.outboundOpsSnapshot(),
            inboundAcks = transfer.inboundOpsSnapshot(),
        ),
        peerToAndroid = peerToAndroidEvidence,
    )
}

private fun canonicalFormalInteropFileName(direction: String, runRef: String): String {
    require(direction == "android-to-peer" || direction == "peer-to-android")
    require(SHA256_HEX_PATTERN.matches(runRef))
    return "$direction-${runRef.take(16)}.txt"
}

private fun canonicalFormalInteropPayload(
    direction: String,
    runRef: String,
    sessionRef: String,
    transferId: String,
): ByteArray {
    require(direction == "android-to-peer" || direction == "peer-to-android")
    require(SHA256_HEX_PATTERN.matches(runRef))
    require(SHA256_HEX_PATTERN.matches(sessionRef))
    require(UUID.fromString(transferId).toString() == transferId)
    return buildString {
        appendLine("skybridge-formal-p2p-file-v1")
        appendLine("direction=$direction")
        appendLine("runRef=$runRef")
        appendLine("sessionRef=$sessionRef")
        appendLine("transferId=$transferId")
    }.encodeToByteArray()
}

private fun requireOwnedRunFile(
    runtimeContext: android.content.Context,
    localPath: String,
    expectedFileName: String,
): File {
    val root = File(runtimeContext.filesDir, "skybridge_inbound_files").canonicalFile
    val file = File(localPath)
    check(!Files.isSymbolicLink(file.toPath())) {
        "Formal reverse receive path is symbolic"
    }
    val canonical = file.canonicalFile
    check(canonical.parentFile == root && canonical.name == expectedFileName && canonical.isFile) {
        "Formal reverse receive path is not the exact run-owned app-private file"
    }
    return canonical
}

private val SHA256_HEX_PATTERN = Regex("[0-9a-f]{64}")
