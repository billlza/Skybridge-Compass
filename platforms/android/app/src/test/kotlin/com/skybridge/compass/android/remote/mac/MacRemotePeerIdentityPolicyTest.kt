package com.skybridge.compass.android.remote.mac

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class MacRemotePeerIdentityPolicyTest {

    @Test
    fun secureHandshakeRequiresStableDeviceId() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            MacRemotePeerIdentityPolicy.stablePeerIdForSecureConnection(
                target = MacRemoteControlClient.ConnectionTarget(host = "192.168.1.10"),
                enableHandshake = true,
                securityConfig = MacRemoteControlClient.SecurityConfig(encryptionRequired = true)
            )
        }

        assertEquals("stable peer deviceId is required for secure LAN remote control", error.message)
    }

    @Test
    fun secureHandshakeRejectsBlankDeviceId() {
        assertThrows(IllegalArgumentException::class.java) {
            MacRemotePeerIdentityPolicy.stablePeerIdForSecureConnection(
                target = MacRemoteControlClient.ConnectionTarget(
                    host = "192.168.1.10",
                    deviceIdHint = "  "
                ),
                enableHandshake = true,
                securityConfig = MacRemoteControlClient.SecurityConfig(encryptionRequired = true)
            )
        }
    }

    @Test
    fun secureHandshakeUsesTrimmedDeviceId() {
        val peerId = MacRemotePeerIdentityPolicy.stablePeerIdForSecureConnection(
            target = MacRemoteControlClient.ConnectionTarget(
                host = "192.168.1.10",
                deviceIdHint = " mac-device-1 "
            ),
            enableHandshake = true,
            securityConfig = MacRemoteControlClient.SecurityConfig(encryptionRequired = true)
        )

        assertEquals("mac-device-1", peerId)
    }

    @Test
    fun insecureDebugPathDoesNotInventPeerIdFromHost() {
        val peerId = MacRemotePeerIdentityPolicy.stablePeerIdForSecureConnection(
            target = MacRemoteControlClient.ConnectionTarget(host = "192.168.1.10"),
            enableHandshake = false,
            securityConfig = MacRemoteControlClient.SecurityConfig(encryptionRequired = false)
        )

        assertNull(peerId)
    }
}
