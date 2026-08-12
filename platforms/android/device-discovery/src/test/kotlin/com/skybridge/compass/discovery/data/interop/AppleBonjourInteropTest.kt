package com.skybridge.compass.discovery.data.interop

import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe

class AppleBonjourInteropTest : FunSpec({

    test("discovery emits canonical labels while accepting legacy dedicated labels") {
        AppleBonjourInterop.DISCOVERY_SERVICE_TYPES shouldBe listOf(
            AppleBonjourInterop.MAIN_SERVICE_TYPE,
            AppleBonjourInterop.REMOTE_SERVICE_TYPE,
            AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            AppleBonjourInterop.LEGACY_REMOTE_SERVICE_TYPE,
            AppleBonjourInterop.LEGACY_FILE_TRANSFER_SERVICE_TYPE
        )
        AppleBonjourInterop.REMOTE_SERVICE_TYPE shouldBe "_skybridge-rd._tcp"
        AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE shouldBe "_skybridge-xfer._tcp"
        AppleBonjourInterop.canonicalServiceType("_skybridge-remote._tcp.") shouldBe
            AppleBonjourInterop.REMOTE_SERVICE_TYPE
        AppleBonjourInterop.canonicalServiceType("_skybridge-transfer._tcp") shouldBe
            AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE
        AppleBonjourInterop.canonicalServiceType("._skybridge-xfer._tcp") shouldBe
            AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE
        AppleBonjourInterop.canonicalServiceType("._skybridge-xfer._tcp.") shouldBe
            AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE
        AppleBonjourInterop.canonicalServiceType(".._skybridge-xfer._tcp") shouldBe null
        AppleBonjourInterop.canonicalServiceType("_unknown._tcp") shouldBe null
    }

    test("legacy DNS-SD instance names are projected to canonical service labels") {
        AppleBonjourInterop.canonicalDnsSdInstanceName(
            serviceName = "Desk Mac._skybridge-remote._tcp.local.",
            observedServiceType = "_skybridge-remote._tcp."
        ) shouldBe "Desk Mac._skybridge-rd._tcp.local"

        AppleBonjourInterop.canonicalDnsSdInstanceName(
            serviceName = "Desk Mac",
            observedServiceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE
        ) shouldBe "Desk Mac._skybridge-xfer._tcp.local"

        AppleBonjourInterop.canonicalDnsSdInstanceName(
            serviceName = "Desk Mac",
            observedServiceType = ".${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}"
        ) shouldBe "Desk Mac._skybridge-xfer._tcp.local"

        AppleBonjourInterop.canonicalDnsSdInstanceName(
            serviceName = "Lza的MacBook Pro",
            observedServiceType = ".${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}"
        ) shouldBe "Lza的MacBook Pro._skybridge-xfer._tcp.local"
    }

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
        raw.contains("classic_resume") shouldBe true
        raw.contains("remote_control") shouldBe true
        raw.contains("rdcontrol") shouldBe true
        raw.contains("clipboard") shouldBe true
    }

    test("parseCapabilities does not infer capabilities when TXT is missing") {
        val parsed = AppleBonjourInterop.parseCapabilities(
            rawCapabilities = null
        )

        parsed shouldBe emptySet()
    }

    test("parseCapabilities treats explicit TXT capabilities as authoritative") {
        val parsed = AppleBonjourInterop.parseCapabilities(
            rawCapabilities = "screen_sharing,rdview,classic_resume"
        )

        parsed shouldBe linkedSetOf(DeviceCapability.SCREEN_SHARING, DeviceCapability.FILE_TRANSFER)
    }

    test("parseCapabilities does not infer defaults from unrecognized explicit TXT capabilities") {
        val parsed = AppleBonjourInterop.parseCapabilities(
            rawCapabilities = "future_capability"
        )

        parsed shouldBe emptySet()
    }

    test("missing capabilities stay unknown") {
        val parsed = AppleBonjourInterop.parseCapabilities(
            rawCapabilities = null
        )

        parsed shouldBe emptySet()
    }

    test("remoteVideoFormats normalize Apple formats to Android safe set") {
        val normalized = AppleBonjourInterop.extractRemoteVideoFormats(
            mapOf("remoteVideoFormats" to "bgra,h264,hevc")
        )

        normalized shouldBe linkedSetOf("jpeg", "h264", "hevc")
    }

    test("remoteVideoFormats support Apple fallback alias") {
        val normalized = AppleBonjourInterop.extractRemoteVideoFormats(
            mapOf("remoteformats" to "mjpeg,avc")
        )

        normalized shouldBe linkedSetOf("jpeg", "h264")
    }

    test("supportsSoa parses explicit handshake SOA TXT") {
        AppleBonjourInterop.supportsSoa(mapOf("hs_soa" to "1")) shouldBe true
        AppleBonjourInterop.supportsSoa(mapOf("hs_soa" to "false")) shouldBe false
    }

    test("normalizedPubKeyFingerprint accepts only 64 lowercase hex characters") {
        val fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

        AppleBonjourInterop.normalizedPubKeyFingerprint(" $fingerprint ") shouldBe fingerprint
        AppleBonjourInterop.normalizedPubKeyFingerprint(fingerprint.uppercase()) shouldBe null
        AppleBonjourInterop.normalizedPubKeyFingerprint(fingerprint.dropLast(1)) shouldBe null
        AppleBonjourInterop.normalizedPubKeyFingerprint("not-a-fingerprint") shouldBe null
    }

    test("preferredPort returns resolved DNS-SD port") {
        val resolved = AppleBonjourInterop.preferredPort(
            resolvedPort = 5901
        )

        resolved shouldBe 5901
    }

    test("preferredPort refuses TXT port fallback when resolve has no port") {
        val resolved = AppleBonjourInterop.preferredPort(
            resolvedPort = 0
        )

        resolved shouldBe 0
    }

    test("preferredPort rejects values outside the DNS-SD port range") {
        AppleBonjourInterop.preferredPort(-1) shouldBe 0
        AppleBonjourInterop.preferredPort(65_536) shouldBe 0
    }
})
