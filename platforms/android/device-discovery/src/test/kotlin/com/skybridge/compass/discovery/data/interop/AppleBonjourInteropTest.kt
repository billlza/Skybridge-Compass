package com.skybridge.compass.discovery.data.interop

import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe

class AppleBonjourInteropTest : FunSpec({

    test("appleCompatibleCapabilities include Apple aliases") {
        val raw = AppleBonjourInterop.appleCompatibleCapabilities(
            setOf(
                DeviceCapability.SCREEN_SHARING,
                DeviceCapability.FILE_TRANSFER,
                DeviceCapability.REMOTE_CONTROL,
                DeviceCapability.CLIPBOARD_SYNC
            )
        )

        raw.contains("screen_sharing") shouldBe true
        raw.contains("remote_desktop") shouldBe true
        raw.contains("rdview") shouldBe true
        raw.contains("file_transfer") shouldBe true
        raw.contains("file") shouldBe true
        raw.contains("remote_control") shouldBe true
        raw.contains("rdcontrol") shouldBe true
        raw.contains("clipboard") shouldBe true
    }

    test("parseCapabilities falls back to service defaults") {
        val parsed = AppleBonjourInterop.parseCapabilities(
            rawCapabilities = null,
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE
        )

        parsed.contains(DeviceCapability.SCREEN_SHARING) shouldBe true
        parsed.contains(DeviceCapability.REMOTE_CONTROL) shouldBe true
    }

    test("remoteVideoFormats normalize Apple formats to Android safe set") {
        val normalized = AppleBonjourInterop.extractRemoteVideoFormats(
            mapOf("remoteVideoFormats" to "bgra,h264,hevc")
        )

        normalized shouldBe linkedSetOf("jpeg", "h264", "hevc")
    }

    test("preferredPort uses Apple TXT fallbacks when resolve has no port") {
        val resolved = AppleBonjourInterop.preferredPort(
            serviceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            resolvedPort = 0,
            txtRecords = mapOf("remotePort" to "5901")
        )

        resolved shouldBe 5901
    }
})
