package com.skybridge.compass.android.discovery

import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidLocalNodeBootstrapPolicyTest {
    @Test
    fun advertisementSettingsHonorsShowDeviceNamePrivacyToggle() {
        val settings = AndroidLocalNodeBootstrapPolicy.advertisementSettings(
            SecuritySettings(showDeviceName = false)
        )

        assertEquals(false, settings.showDeviceName)
    }

    @Test
    fun advertisementSettingsIsNonEmptyWhenAtLeastOnePreconditionHolds() {
        val settings = AndroidLocalNodeBootstrapPolicy.advertisementSettings(
            SecuritySettings(
                allowFileTransfer = true,
                allowClipboardSync = false,
                allowRemoteControl = false,
                allowScreenMirroring = false
            )
        )

        assertTrue(settings.verifiedCapabilities.isNotEmpty())
        assertEquals(setOf(DeviceCapability.FILE_TRANSFER), settings.verifiedCapabilities)
    }

    @Test
    fun advertisementSettingsIsEmptyWhenNoPreconditionHolds() {
        val settings = AndroidLocalNodeBootstrapPolicy.advertisementSettings(
            SecuritySettings(
                allowFileTransfer = false,
                allowClipboardSync = false,
                allowRemoteControl = false,
                allowScreenMirroring = false
            )
        )

        assertTrue(settings.verifiedCapabilities.isEmpty())
    }

    @Test
    fun advertisementSettingsOmitsCapabilitiesWithoutServiceReadiness() {
        // Screen sharing (host capture) and remote control (accessibility injection) host
        // capabilities are not delivered yet, so enabling their access toggles must not promote
        // them to advertised capabilities while their backing services are unavailable.
        val settings = AndroidLocalNodeBootstrapPolicy.advertisementSettings(
            SecuritySettings(
                allowFileTransfer = false,
                allowClipboardSync = false,
                allowRemoteControl = true,
                allowScreenMirroring = true
            )
        )

        assertFalse(settings.verifiedCapabilities.contains(DeviceCapability.REMOTE_CONTROL))
        assertFalse(settings.verifiedCapabilities.contains(DeviceCapability.SCREEN_SHARING))
        assertTrue(settings.verifiedCapabilities.isEmpty())
    }

    @Test
    fun advertisementSettingsIncludesEveryCapabilityWhosePreconditionHolds() {
        val settings = AndroidLocalNodeBootstrapPolicy.advertisementSettings(
            SecuritySettings(
                allowFileTransfer = true,
                allowClipboardSync = true,
                allowRemoteControl = true,
                allowScreenMirroring = true
            )
        )

        assertEquals(
            setOf(DeviceCapability.FILE_TRANSFER, DeviceCapability.CLIPBOARD_SYNC),
            settings.verifiedCapabilities
        )
    }
}
