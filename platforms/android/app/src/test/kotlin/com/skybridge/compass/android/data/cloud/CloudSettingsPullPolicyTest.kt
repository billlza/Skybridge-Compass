package com.skybridge.compass.android.data.cloud

import com.skybridge.compass.android.data.cloud.CloudUserSettingsSyncManager.NetworkSettingsDto
import com.skybridge.compass.android.data.cloud.CloudUserSettingsSyncManager.SecuritySettingsDto
import com.skybridge.compass.android.data.cloud.CloudUserSettingsSyncManager.SettingsSnapshot
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import org.junit.Assert.assertThrows
import org.junit.Test

class CloudSettingsPullPolicyTest {

    @Test
    fun acceptsDefaultSnapshot() {
        CloudSettingsPullPolicy.validateIncomingSnapshot(SettingsSnapshot())
    }

    @Test
    fun acceptsLoopbackWebSocketSignalingForLocalDevelopmentOnly() {
        CloudSettingsPullPolicy.validateIncomingSnapshot(
            SettingsSnapshot(
                network = NetworkSettingsDto(
                    webrtcSignalingUrl = "ws://127.0.0.1:8080/ws"
                )
            )
        )

        CloudSettingsPullPolicy.validateIncomingSnapshot(
            SettingsSnapshot(
                network = NetworkSettingsDto(
                    webrtcSignalingUrl = "ws://127.255.255.255:8080/ws"
                )
            )
        )

        CloudSettingsPullPolicy.validateIncomingSnapshot(
            SettingsSnapshot(
                network = NetworkSettingsDto(
                    webrtcSignalingUrl = "ws://localhost:8080/ws"
                )
            )
        )

        CloudSettingsPullPolicy.validateIncomingSnapshot(
            SettingsSnapshot(
                network = NetworkSettingsDto(
                    webrtcSignalingUrl = "ws://[::1]:8080/ws"
                )
            )
        )

        CloudSettingsPullPolicy.validateIncomingSnapshot(
            SettingsSnapshot(
                network = NetworkSettingsDto(
                    webrtcSignalingUrl = "ws://[0:0:0:0:0:0:0:1]:8080/ws"
                )
            )
        )
    }

    @Test
    fun rejectsPlaintextRemoteWebSocketSignaling() {
        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        webrtcSignalingUrl = "ws://api.nebula-technologies.net/ws"
                    )
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        webrtcSignalingUrl = "ws://127.evil.com/ws"
                    )
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        webrtcSignalingUrl = "ws://127.0.0.1.evil.com/ws"
                    )
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        webrtcSignalingUrl = "ws://127.0.0.256:8080/ws"
                    )
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        webrtcSignalingUrl = "ws://localhost.evil.com/ws"
                    )
                )
            )
        }
    }

    @Test
    fun rejectsCloudSnapshotThatChangesRemoteSignalingOriginOrPath() {
        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        webrtcSignalingUrl = "wss://evil.example/ws"
                    )
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        webrtcSignalingUrl = "wss://api.nebula-technologies.net/alternate"
                    )
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        webrtcSignalingUrl = "ws://[::2]:8080/ws"
                    )
                )
            )
        }
    }

    @Test
    fun rejectsInvalidWebRtcSignalingUrl() {
        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        webrtcSignalingUrl = "wss://"
                    )
                )
            )
        }
    }

    @Test
    fun rejectsUnsupportedOrBlankIceUrls() {
        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        stunServers = listOf("http://relay.invalid/stun")
                    )
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        turnServers = listOf("")
                    )
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(
                        stunServers = listOf("turn:54.92.79.99:3478")
                    )
                )
            )
        }
    }

    @Test
    fun rejectsCloudSnapshotThatWeakensNetworkSecurityPosture() {
        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(tlsStrictMode = false)
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(handshakeEnabled = false)
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    network = NetworkSettingsDto(encryptionMode = "AES_CBC")
                )
            )
        }
    }

    @Test
    fun rejectsCloudSnapshotThatDisablesCoreCrypto() {
        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(encryptionEnabled = false)
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(pqcEnabled = false)
                )
            )
        }
    }

    @Test
    fun rejectsCloudSnapshotThatWeakensPqcPosture() {
        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(enforcePqcHandshake = false)
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(allowClassicFallbackForCompatibility = true)
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(pqcMinimumTier = "classic")
                )
            )
        }
    }

    @Test
    fun acceptsCloudSnapshotWithStrongerPqcMinimumTierButRejectsUnknownTier() {
        CloudSettingsPullPolicy.validateIncomingSnapshot(
            SettingsSnapshot(
                security = SecuritySettingsDto(pqcMinimumTier = "nativePQC")
            )
        )

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(pqcMinimumTier = "futureWeakTier")
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(pqcMinimumTier = "x-wing")
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(pqcMinimumTier = "mlkem")
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(pqcMinimumTier = P2PQPeriaptKem.MINIMUM_TIER_RAW)
                )
            )
        }
    }

    @Test
    fun rejectsCloudSnapshotThatEnablesRemoteControlFromDefaultPosture() {
        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(allowRemoteControl = true)
                )
            )
        }
    }

    @Test
    fun rejectsCloudSnapshotThatDisablesRemoteControlConfirmation() {
        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(remoteControlRequireConfirmation = false)
                )
            )
        }
    }

    @Test
    fun rejectsCloudSnapshotThatWeakensApprovalGates() {
        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(requirePairing = false)
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(autoTrustKnownDevices = true)
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(autoAcceptTrustedDevices = true)
                )
            )
        }

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    security = SecuritySettingsDto(confirmOverwriteOnInbound = false)
                )
            )
        }
    }

    @Test
    fun legacySchemaStillRejectsRemoteControlButDoesNotInterpretMissingPqcFieldsAsDowngrade() {
        CloudSettingsPullPolicy.validateIncomingSnapshot(
            SettingsSnapshot(
                schemaVersion = 1,
                security = SecuritySettingsDto(
                    enforcePqcHandshake = false,
                    allowClassicFallbackForCompatibility = true,
                    pqcMinimumTier = "classic"
                )
            )
        )

        assertThrows(CloudSettingsPullPolicy.Violation::class.java) {
            CloudSettingsPullPolicy.validateIncomingSnapshot(
                SettingsSnapshot(
                    schemaVersion = 1,
                    security = SecuritySettingsDto(allowRemoteControl = true)
                )
            )
        }
    }
}
