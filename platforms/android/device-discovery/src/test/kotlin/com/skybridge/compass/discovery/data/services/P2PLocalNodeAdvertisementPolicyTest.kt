package com.skybridge.compass.discovery.data.services

import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.nulls.shouldBeNull
import io.kotest.matchers.shouldBe

class P2PLocalNodeAdvertisementPolicyTest : FunSpec({

    test("main service does not advertise unverified capabilities by default") {
        P2PLocalNodeAdvertisementPolicy.capabilityTxt(emptySet()).shouldBeNull()
    }

    test("main service advertises only caller-verified capabilities") {
        val capabilities = P2PLocalNodeAdvertisementPolicy.capabilityTxt(
            setOf(DeviceCapability.FILE_TRANSFER)
        )

        capabilities?.split(",")?.toSet() shouldBe setOf("file_transfer", "file", "classic_resume")
    }

    test("crypto suites TXT passes a non-empty identity CSV through unchanged") {
        P2PLocalNodeAdvertisementPolicy.cryptoSuitesTxt("0001,0101") shouldBe "0001,0101"
    }

    test("crypto suites TXT trims surrounding whitespace") {
        P2PLocalNodeAdvertisementPolicy.cryptoSuitesTxt("  0101  ") shouldBe "0101"
    }

    test("crypto suites TXT is null only when the identity reports no negotiable suites") {
        P2PLocalNodeAdvertisementPolicy.cryptoSuitesTxt("").shouldBeNull()
        P2PLocalNodeAdvertisementPolicy.cryptoSuitesTxt("   ").shouldBeNull()
    }

    test("advertisement config snapshots caller capability set") {
        val capabilities = mutableSetOf(DeviceCapability.FILE_TRANSFER)
        val config = P2PLocalNodeAdvertisementPolicy.config(
            showDeviceName = false,
            verifiedCapabilities = capabilities,
            cryptoSuitesCsv = "0101"
        )

        capabilities.clear()

        config.showDeviceName shouldBe false
        config.verifiedCapabilities shouldBe setOf(DeviceCapability.FILE_TRANSFER)
        config.cryptoSuitesCsv shouldBe "0101"
    }

    test("advertisement config captures the crypto-suite set so a suite-only change is detectable") {
        val capabilities = setOf(DeviceCapability.FILE_TRANSFER)
        val before = P2PLocalNodeAdvertisementPolicy.config(
            showDeviceName = true,
            verifiedCapabilities = capabilities,
            cryptoSuitesCsv = "0101"
        )
        val afterSuiteChange = P2PLocalNodeAdvertisementPolicy.config(
            showDeviceName = true,
            verifiedCapabilities = capabilities,
            cryptoSuitesCsv = "0001,0101"
        )

        // Same capabilities + same device-name flag, but a different suite set must NOT be treated as
        // an equal config; otherwise start() would skip the re-advertise required by R3.12.
        (before == afterSuiteChange) shouldBe false
    }

    test("advertisement config is equal when capabilities and suites are unchanged") {
        val capabilities = setOf(DeviceCapability.FILE_TRANSFER)
        val a = P2PLocalNodeAdvertisementPolicy.config(
            showDeviceName = true,
            verifiedCapabilities = capabilities,
            cryptoSuitesCsv = "0101"
        )
        val b = P2PLocalNodeAdvertisementPolicy.config(
            showDeviceName = true,
            verifiedCapabilities = capabilities.toSet(),
            cryptoSuitesCsv = "0101"
        )

        (a == b) shouldBe true
    }
})
