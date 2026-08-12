package com.skybridge.compass.discovery.data.datasources

import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.string.shouldContain

class BonjourLocalNetworkPolicyTest : FunSpec({

    test("rejects advertising when no local network transport is active") {
        val error = shouldThrow<BonjourAdvertisingException> {
            BonjourLocalNetworkPolicy.requireAdvertisingNetwork(emptySet())
        }

        error.message shouldContain "requires an active default Wi-Fi, Ethernet, or Android local network"
        error.message shouldContain "active transports=none"
    }

    test("allows Wi-Fi advertising transport") {
        BonjourLocalNetworkPolicy.requireAdvertisingNetwork(setOf(BonjourAdvertisingTransport.WIFI))
    }

    test("allows Ethernet advertising transport") {
        BonjourLocalNetworkPolicy.requireAdvertisingNetwork(setOf(BonjourAdvertisingTransport.ETHERNET))
    }

    test("allows Android local-network advertising transport") {
        BonjourLocalNetworkPolicy.requireAdvertisingNetwork(setOf(BonjourAdvertisingTransport.LOCAL_NETWORK))
    }

    test("rejects ordinary cellular active network for Bonjour advertising") {
        val transports = BonjourLocalNetworkPolicy.emulatorAdvertisingTransports(
            isAndroidEmulator = false,
            hasCellularActiveNetwork = true,
            hasEmulatorLocalInterface = true
        )

        val error = shouldThrow<BonjourAdvertisingException> {
            BonjourLocalNetworkPolicy.requireAdvertisingNetwork(transports)
        }

        error.message shouldContain "active transports=none"
    }

    test("rejects emulator cellular network without emulator local interface evidence") {
        val transports = BonjourLocalNetworkPolicy.emulatorAdvertisingTransports(
            isAndroidEmulator = true,
            hasCellularActiveNetwork = true,
            hasEmulatorLocalInterface = false
        )

        val error = shouldThrow<BonjourAdvertisingException> {
            BonjourLocalNetworkPolicy.requireAdvertisingNetwork(transports)
        }

        error.message shouldContain "active transports=none"
    }

    test("rejects emulator nat transport because Mac and iOS cannot discover it") {
        val transports = BonjourLocalNetworkPolicy.emulatorAdvertisingTransports(
            isAndroidEmulator = true,
            hasCellularActiveNetwork = true,
            hasEmulatorLocalInterface = true
        )

        val error = shouldThrow<BonjourAdvertisingException> {
            BonjourLocalNetworkPolicy.requireAdvertisingNetwork(transports)
        }

        error.message shouldContain "active transports=ANDROID_EMULATOR_NAT"
        error.message shouldContain "diagnostic-only"
    }

    test("requires local network permission on Android API 37 and newer") {
        // ACCESS_LOCAL_NETWORK is introduced and enforced on Android 17 / API 37.
        BonjourLocalNetworkPermissionPolicy.isLocalNetworkPermissionRequired(sdkInt = 35) shouldBe false
        BonjourLocalNetworkPermissionPolicy.isLocalNetworkPermissionRequired(sdkInt = 36) shouldBe false
        BonjourLocalNetworkPermissionPolicy.isLocalNetworkPermissionRequired(sdkInt = 37) shouldBe true
        BonjourLocalNetworkPermissionPolicy.isLocalNetworkPermissionRequired(sdkInt = 38) shouldBe true
    }

    test("gate does not require the API 37 permission on minSdk 36") {
        val minSdk = 36
        BonjourLocalNetworkPermissionPolicy.isLocalNetworkPermissionRequired(sdkInt = minSdk) shouldBe false
        BonjourLocalNetworkPermissionPolicy.requiredPermission(sdkInt = minSdk) shouldBe null
    }

    test("requiredPermission returns ACCESS_LOCAL_NETWORK when required, null otherwise") {
        BonjourLocalNetworkPermissionPolicy.requiredPermission(sdkInt = 36) shouldBe null
        BonjourLocalNetworkPermissionPolicy.requiredPermission(sdkInt = 37) shouldBe
            android.Manifest.permission.ACCESS_LOCAL_NETWORK
        BonjourLocalNetworkPermissionPolicy.requiredPermission(sdkInt = 35) shouldBe null
    }
})
