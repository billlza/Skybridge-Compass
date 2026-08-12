package com.skybridge.compass.android.debug

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DebugLanInteropTrustIsolationWiringTest {
    @Test
    fun productionDefaultsRemainPersistentAndDiagnosticActivityOverridesThem() {
        val clientSource = sourceFile(
            "app/src/main/kotlin/com/skybridge/compass/android/remote/mac/MacRemoteControlClient.kt",
            "src/main/kotlin/com/skybridge/compass/android/remote/mac/MacRemoteControlClient.kt"
        ).readText()
        val activitySource = sourceFile(
            "app/src/debug/kotlin/com/skybridge/compass/android/debug/DebugLanInteropSmokeActivity.kt",
            "src/debug/kotlin/com/skybridge/compass/android/debug/DebugLanInteropSmokeActivity.kt"
        ).readText()
        val ephemeralSource = sourceFile(
            "app/src/debug/kotlin/com/skybridge/compass/android/debug/DebugEphemeralMacRemoteControlTrustMaterial.kt",
            "src/debug/kotlin/com/skybridge/compass/android/debug/DebugEphemeralMacRemoteControlTrustMaterial.kt"
        ).readText()
        val debugStrings = sourceFile(
            "app/src/debug/res/values/strings.xml",
            "src/debug/res/values/strings.xml"
        ).readText()
        val trustContextSource = sourceFile(
            "app/src/main/kotlin/com/skybridge/compass/android/remote/mac/MacRemoteControlTrustContext.kt",
            "src/main/kotlin/com/skybridge/compass/android/remote/mac/MacRemoteControlTrustContext.kt"
        ).readText()
        val peerKemStoreSource = sourceFile(
            "core/src/main/kotlin/com/skybridge/compass/core/p2p/PeerKemKeyStore.kt",
            "../core/src/main/kotlin/com/skybridge/compass/core/p2p/PeerKemKeyStore.kt"
        ).readText()

        assertTrue(
            clientSource.contains(
                "trustContextOverride ?: MacRemoteControlTrustContextFactory.persistentReadWrite("
            )
        )
        assertTrue(trustContextSource.contains("peerKemPublicKeys = PeerKemKeyStore("))
        assertTrue(trustContextSource.contains("peerSigningFingerprints = localIdentity.trustStore()"))
        assertTrue(activitySource.contains("DebugEphemeralMacRemoteControlTrustMaterial()"))
        assertTrue(activitySource.contains("MacRemoteControlTrustContextFactory.persistentReadOnly("))
        assertTrue(activitySource.contains("trustContextOverride = trustContextOverride"))
        assertTrue(activitySource.contains("@AndroidEntryPoint"))
        assertTrue(activitySource.contains("StartDeviceDiscoveryUseCase"))
        assertTrue(activitySource.contains("LanRemotePeer::fromDiscoveredDevice"))
        assertTrue(activitySource.contains("DebugLanInteropRouteAuthorizationLease(smokeRunRef)"))
        assertTrue(activitySource.contains("formalRouteAuthorizationLease = runScopedRouteLease"))
        assertTrue(activitySource.contains("retainIfAnyObserved(currentFormalSnapshots)"))
        assertTrue(activitySource.contains("routeAuthority=debug_run_scoped"))
        assertFalse(activitySource.contains("MacRemoteDiscovery"))
        assertTrue(activitySource.contains("skybridgeRequireExistingProductTrust"))
        assertTrue(activitySource.contains("existing_product_trust_requires_strict_pqc_policy"))
        assertTrue(activitySource.contains("existing_product_trust_forbids_classic_fallback"))
        assertTrue(activitySource.contains("MacRemoteControlClient.TrustState.TRUSTED_EXISTING"))
        assertTrue(activitySource.contains("identity authority=authenticated_product_v1 "))
        assertTrue(activitySource.contains("handshake=verified frameOwner=current"))
        assertTrue(activitySource.contains("client.currentTrustedFrameEvidence()"))
        assertTrue(
            activitySource.contains(
                "val smokeRunRef = DebugLanInteropRunScope.runRef(smokeNonce)"
            )
        )
        assertTrue(activitySource.contains("emit(\"attempt ref=\$smokeRunRef\")"))
        assertTrue(
            activitySource.contains(
                "statusView.setText(R.string.debug_lan_smoke_failure_invalid_nonce)"
            )
        )
        assertTrue(
            activitySource.contains(
                "statusView.setText(R.string.debug_lan_smoke_failure_status_file_preexisting)"
            )
        )
        assertFalse(activitySource.contains("statusView.text = \"failure reason="))
        assertTrue(
            debugStrings.contains(
                ">failure reason=invalid_smoke_nonce</string>"
            )
        )
        assertTrue(
            debugStrings.contains(
                ">failure reason=status_file_preexisting</string>"
            )
        )

        val nonceConsumer = activitySource.substring(
            startIndex = activitySource.indexOf("private fun consumeSmokeNonce(provided: String): Boolean"),
            endIndex = activitySource.indexOf("private fun readBoundedNonce(file: File)")
        )
        val nonceComparison = nonceConsumer.indexOf("matchesStagedNonce(provided, expectedBytes)")
        val nonceDeletion = nonceConsumer.indexOf("file.delete() && !file.exists()")
        assertTrue(nonceComparison >= 0)
        assertTrue(nonceDeletion > nonceComparison)
        assertTrue(
            trustContextSource.contains(
                "PeerKemPublicKeySource(peerKemStore::loadVerifiedReadOnly)"
            )
        )
        assertTrue(
            trustContextSource.contains(
                "peerSigningFingerprints = localIdentity.formalAcceptanceTrustStore()"
            )
        )
        val formalReadOnlyLoader = peerKemStoreSource.substring(
            startIndex = peerKemStoreSource.indexOf("fun loadVerifiedReadOnly(peerId: String)"),
            endIndex = peerKemStoreSource.indexOf(
                "\n    private fun load(",
                peerKemStoreSource.indexOf("fun loadVerifiedReadOnly(peerId: String)")
            )
        )
        assertTrue(formalReadOnlyLoader.contains("findVerifiedRecordByKnownDeviceIdReadOnly"))
        assertTrue(formalReadOnlyLoader.contains("readTypedOrigin("))
        assertTrue(formalReadOnlyLoader.contains("loadFormalKeys(peerId)"))
        listOf(".edit(", ".save(", "clearQPeriapt(", ".remove(").forEach { mutation ->
            assertFalse(formalReadOnlyLoader.contains(mutation))
        }
        assertTrue(peerKemStoreSource.contains("internal fun save("))

        assertFalse(activitySource.contains("PeerKemKeyStore("))
        assertFalse(activitySource.contains("PibPairingClient"))
        assertFalse(activitySource.contains("confirmPairing("))
        assertFalse(activitySource.contains("SignedLanKemRefreshClient"))
        assertFalse(ephemeralSource.contains("SignedLanKemRefreshClient"))
        assertFalse(ephemeralSource.contains("EncryptedSharedPreferences"))
        assertFalse(ephemeralSource.contains("SharedPreferences"))
    }

    private fun sourceFile(vararg candidates: String): File =
        candidates.map(::File).firstOrNull(File::isFile)
            ?: error("source file not found from cwd=${File(".").absolutePath}: ${candidates.joinToString()}")
}
