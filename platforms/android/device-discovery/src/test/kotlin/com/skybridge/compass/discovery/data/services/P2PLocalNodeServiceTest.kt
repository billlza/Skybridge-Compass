package com.skybridge.compass.discovery.data.services

import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.TcpControlServer
import com.skybridge.compass.discovery.data.datasources.BonjourAdvertiserDataSource
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify

/**
 * Service-level coverage for Task 7.7:
 * - When the verified-capability set or the crypto-suite set changes while advertising is active,
 *   start() re-advertises with the new set (TXT hot-update, R3.12) while keeping the service
 *   instance name (derived from uniqueId/deviceId) and the identity fingerprint (pubKeyFP) invariant.
 * - stop() deregisters the NSD advertising registration and stops the TCP control endpoint.
 *
 * The Bonjour browse side is deregistered by BonjourDiscoveryDataSource's callbackFlow awaitClose
 * (nsdManager.stopServiceDiscovery); this test focuses on the advertise-side lifecycle owned by
 * P2PLocalNodeService, which is the unit under test.
 */
class P2PLocalNodeServiceTest : FunSpec({

    fun newIdentity(suitesCsv: String): LocalP2PIdentity = mockk<LocalP2PIdentity>().also { identity ->
        every { identity.deviceId() } returns "device-abc"
        every { identity.pubKeyFingerprint() } returns "a".repeat(64)
        every { identity.publishedDeviceName(any()) } returns "Pixel"
        every { identity.discoveryCryptoSuitesCsv(any(), any()) } returns suitesCsv
    }

    test("changing verified capabilities re-advertises with new caps; serviceName + pubKeyFP invariant") {
        val advertiser = mockk<BonjourAdvertiserDataSource>(relaxed = true)
        val identity = newIdentity(suitesCsv = "0101")
        val tcpServer = mockk<TcpControlServer>()
        every { tcpServer.start(any<IntRange>()) } returns 55001

        val captured = mutableListOf<BonjourAdvertiserDataSource.Advertisement>()
        coEvery {
            advertiser.startAdvertising(any(), capture(captured), any())
        } returns "device-abc"

        val service = P2PLocalNodeService(advertiser, identity, tcpServer, FakeRuntimeNetworkParametersSource())

        service.start(showDeviceName = true, verifiedCapabilities = emptySet())
        service.start(
            showDeviceName = true,
            verifiedCapabilities = setOf(DeviceCapability.FILE_TRANSFER)
        )

        // Two advertising registrations happened: initial + one on capability change.
        captured.size shouldBe 2
        coVerify(exactly = 2) {
            advertiser.startAdvertising(any(), any(), AppleBonjourInterop.MAIN_SERVICE_TYPE)
        }

        val first = captured[0]
        val second = captured[1]

        // Capability TXT field changed (empty -> non-empty file-transfer capabilities).
        first.capabilities shouldBe null
        second.capabilities shouldNotBe null

        // Service instance name source (uniqueId/deviceId) and identity fingerprint stay unchanged.
        first.uniqueId shouldBe second.uniqueId
        first.deviceId shouldBe second.deviceId
        first.pubKeyFP shouldBe second.pubKeyFP
    }

    test("changing only the crypto-suite set re-advertises with new suites; identity invariant") {
        val advertiser = mockk<BonjourAdvertiserDataSource>(relaxed = true)
        // Identity reports a different negotiable suite set on the second start().
        val identity = mockk<LocalP2PIdentity>()
        every { identity.deviceId() } returns "device-xyz"
        every { identity.pubKeyFingerprint() } returns "b".repeat(64)
        every { identity.publishedDeviceName(any()) } returns "Pixel"
        every { identity.discoveryCryptoSuitesCsv(any(), any()) } returnsMany listOf("0101", "0001,0101")

        val tcpServer = mockk<TcpControlServer>()
        every { tcpServer.start(any<IntRange>()) } returns 55002

        val captured = mutableListOf<BonjourAdvertiserDataSource.Advertisement>()
        coEvery {
            advertiser.startAdvertising(any(), capture(captured), any())
        } returns "device-xyz"

        val service = P2PLocalNodeService(advertiser, identity, tcpServer, FakeRuntimeNetworkParametersSource())

        service.start(showDeviceName = true, verifiedCapabilities = emptySet())
        service.start(showDeviceName = true, verifiedCapabilities = emptySet())

        captured.size shouldBe 2
        captured[0].cryptoSuites shouldBe "0101"
        captured[1].cryptoSuites shouldBe "0001,0101"
        // Identity fingerprint and instance-name source unchanged across the suite hot-update.
        captured[0].pubKeyFP shouldBe captured[1].pubKeyFP
        captured[0].uniqueId shouldBe captured[1].uniqueId
    }

    test("an unchanged config does not trigger a second advertising registration") {
        val advertiser = mockk<BonjourAdvertiserDataSource>(relaxed = true)
        val identity = newIdentity(suitesCsv = "0101")
        val tcpServer = mockk<TcpControlServer>()
        every { tcpServer.start(any<IntRange>()) } returns 55003
        coEvery { advertiser.startAdvertising(any(), any(), any()) } returns "device-abc"

        val service = P2PLocalNodeService(advertiser, identity, tcpServer, FakeRuntimeNetworkParametersSource())

        service.start(showDeviceName = true, verifiedCapabilities = setOf(DeviceCapability.FILE_TRANSFER))
        service.start(showDeviceName = true, verifiedCapabilities = setOf(DeviceCapability.FILE_TRANSFER))

        // Identical capability + suite set: only the initial registration should have occurred.
        coVerify(exactly = 1) { advertiser.startAdvertising(any(), any(), any()) }
    }

    test("stop() deregisters advertising and stops the TCP control endpoint") {
        val advertiser = mockk<BonjourAdvertiserDataSource>(relaxed = true)
        val identity = newIdentity(suitesCsv = "0101")
        val tcpServer = mockk<TcpControlServer>()
        every { tcpServer.start(any<IntRange>()) } returns 55004
        every { tcpServer.stop() } just Runs
        coEvery { advertiser.startAdvertising(any(), any(), any()) } returns "device-abc"

        val service = P2PLocalNodeService(advertiser, identity, tcpServer, FakeRuntimeNetworkParametersSource())

        service.start(showDeviceName = true, verifiedCapabilities = emptySet())
        service.stop()

        // Advertising is unregistered (the whole-node stopAdvertising() overload) and the TCP
        // control endpoint is torn down.
        verify(exactly = 1) { advertiser.stopAdvertising() }
        verify(exactly = 1) { tcpServer.stop() }
    }
})
