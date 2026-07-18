import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class PeerTrustLookupTests: XCTestCase {
    func testLookupCandidatesNormalizesHostAndStableIDAliases() {
        let hostCandidates = PeerTrustLookup.lookupCandidates(
            for: "recent:peer:[FE80::81D:BB45:8C18:6D6A%en0].9527"
        )
        XCTAssertTrue(hostCandidates.contains("host:fe80::81d:bb45:8c18:6d6a"))

        let bareUUID = UUID().uuidString
        let idCandidates = PeerTrustLookup.lookupCandidates(for: bareUUID)
        XCTAssertTrue(idCandidates.contains(bareUUID))
        XCTAssertTrue(idCandidates.contains("id:\(bareUUID.lowercased())"))
    }

    func testPersistentDeviceIdRejectsDisplayNamesAndDoesNotSynthesizeBogusHostAliases() {
        XCTAssertNil(PeerTrustLookup.persistentDeviceId(from: "Lza的MacBook Pro"))
        XCTAssertNil(PeerTrustLookup.persistentDeviceId(from: "id:lza的macbook pro"))
        XCTAssertNil(PeerTrustLookup.persistentDeviceId(from: "192.168.10.22"))
        XCTAssertNil(PeerTrustLookup.persistentDeviceId(from: "id:192.168.10.22"))
        XCTAssertNil(PeerTrustLookup.persistentDeviceId(from: "fe80::81d:bb45:8c18:6d6a%en0"))
        XCTAssertNil(PeerTrustLookup.hostAlias(fromIPAddress: "id:lza的macbook pro"))

        let candidates = PeerTrustLookup.lookupCandidates(for: "id:lza的macbook pro")
        XCTAssertFalse(candidates.contains("host:id:lza的macbook pro"))
    }

    func testBonjourServiceNameSanitizerRejectsSyntheticIdentifiers() {
        XCTAssertNil(PeerTrustLookup.sanitizedBonjourServiceInstanceName("id:11111111-1111-1111-1111-111111111111"))
        XCTAssertNil(PeerTrustLookup.sanitizedBonjourServiceInstanceName("host:11111111-1111-1111-1111-111111111111"))
        XCTAssertNil(PeerTrustLookup.sanitizedBonjourServiceInstanceName("11111111-1111-1111-1111-111111111111"))
        XCTAssertNil(PeerTrustLookup.sanitizedBonjourServiceInstanceName("fe80::ce0:3cf9:13d0:85b3%en0"))
        XCTAssertEqual(PeerTrustLookup.sanitizedBonjourServiceInstanceName("Lza's MacBook Pro._skybridge._tcp"), "Lza's MacBook Pro")
    }

    func testRecordMatchesKnownDeviceAliasesAndPeerEndpointMetadata() {
        let canonicalId = "id:\(UUID().uuidString)"
        let hostAlias = "host:fe80::81d:bb45:8c18:6d6a%en0"
        let record = TrustRecord(
            deviceId: canonicalId,
            pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data([0x01]),
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data(repeating: 0xAA, count: 1_184))],
            capabilities: ["peerEndpoint=\(canonicalId)"],
            signature: Data([0x02]),
            deviceName: "Lza's iPhone",
            currentDeviceId: canonicalId,
            knownDeviceIds: [hostAlias, "bonjour:lza's iphone@local."]
        )

        let candidates = Set(PeerTrustLookup.lookupCandidates(for: "peer:[fe80::81d:bb45:8c18:6d6a%en0].9527"))
        XCTAssertTrue(
            PeerTrustLookup.recordMatches(
                record,
                candidates: candidates,
                candidateLowercased: Set(candidates.map { $0.lowercased() })
            )
        )
    }

    @MainActor
    func testDefaultHandshakeTrustProviderDoesNotTrustUnsignedBootstrapKEMThroughAliases() async throws {
        let canonicalId = "id:\(UUID().uuidString)"
        let hostAlias = "host:fe80::81d:bb45:8c18:6d6a%en0"
        let normalizedHostAlias = "host:fe80::81d:bb45:8c18:6d6a"
        let expectedKey = Data(repeating: 0xAB, count: 1_184)
        let bootstrapStore = PeerKEMBootstrapStore.shared
        await bootstrapStore.clearForTesting()
        addTeardownBlock { [bootstrapStore] in
            await bootstrapStore.clearForTesting()
        }

        await bootstrapStore.upsert(
            deviceIds: [canonicalId, hostAlias, normalizedHostAlias, "bonjour:trusted iphone@local."],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: expectedKey)]
        )

        let provider = DefaultHandshakeTrustProvider()
        let resolved = await provider.trustedKEMPublicKeys(for: canonicalId)
        let endpointOnly = await provider.trustedKEMPublicKeys(for: "host:[fe80::81d:bb45:8c18:6d6a%en0].9527")

        XCTAssertNil(resolved[CryptoSuite(wireId: 257)])
        XCTAssertNil(endpointOnly[CryptoSuite(wireId: 257)])
    }

    @MainActor
    func testDefaultHandshakeTrustProviderIgnoresEmptyTrustedKEMPublicKeys() async throws {
        let canonicalId = "id:\(UUID().uuidString)"
        let trust = TrustSyncService.shared

        await trust.beginInMemoryPersistenceForTesting()
        await trust.removeRecordsForTesting(deviceIds: [canonicalId])
        addTeardownBlock { @MainActor [trust] in
            await trust.removeRecordsForTesting(deviceIds: [canonicalId])
            trust.endInMemoryPersistenceForTesting()
        }

        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: canonicalId,
                pubKeyFP: String(repeating: "1", count: 64),
                publicKey: Data([0x01]),
                kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data())],
                signature: Data(),
                deviceName: "Empty KEM",
                currentDeviceId: canonicalId,
                knownDeviceIds: []
            )
        )

        let provider = DefaultHandshakeTrustProvider()
        let resolved = await provider.trustedKEMPublicKeys(for: canonicalId)

        XCTAssertNil(resolved[CryptoSuite(wireId: 257)])
    }

    @MainActor
    func testDefaultHandshakeTrustProviderFailsClosedWhenTrustedKEMKeysConflict() async throws {
        let alias = "bonjour:office ipad@local."
        let suite = CryptoSuite(wireId: 257)
        let cachedKey = Data(repeating: 0xCC, count: 1_184)
        let trust = TrustSyncService.shared
        let bootstrapStore = PeerKEMBootstrapStore.shared
        let cleanupIds = ["id:conflict-a", "id:conflict-b"]

        await trust.beginInMemoryPersistenceForTesting()
        await trust.removeRecordsForTesting(deviceIds: cleanupIds)
        await bootstrapStore.clearForTesting()

        addTeardownBlock { @MainActor [bootstrapStore, trust] in
            await trust.removeRecordsForTesting(deviceIds: cleanupIds)
            trust.endInMemoryPersistenceForTesting()
            await bootstrapStore.clearForTesting()
        }

        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: cleanupIds[0],
                pubKeyFP: String(repeating: "1", count: 64),
                publicKey: Data([0x01]),
                kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: suite.wireId, publicKey: Data(repeating: 0xAA, count: 1_184))],
                signature: Data(),
                deviceName: "Office iPad",
                currentDeviceId: cleanupIds[0],
                knownDeviceIds: [alias]
            )
        )
        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: cleanupIds[1],
                pubKeyFP: String(repeating: "2", count: 64),
                publicKey: Data([0x02]),
                kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: suite.wireId, publicKey: Data(repeating: 0xBB, count: 1_184))],
                signature: Data(),
                deviceName: "Office iPad",
                currentDeviceId: cleanupIds[1],
                knownDeviceIds: [alias]
            )
        )

        await bootstrapStore.upsert(
            deviceIds: [alias],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: suite.wireId, publicKey: cachedKey)]
        )

        let provider = DefaultHandshakeTrustProvider()
        let resolved = await provider.trustedKEMPublicKeys(for: alias)

        XCTAssertNil(resolved[suite])
    }

    func testDefaultHandshakeTrustProviderUsesAuthoritativeProtocolFingerprint() async throws {
        let protocolPublicKey = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let expectedFingerprint = try IdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeProtocolFingerprint()

        let record = TrustRecord(
            deviceId: "id:\(UUID().uuidString)",
            pubKeyFP: String(repeating: "f", count: 64),
            publicKey: Data([0x01]),
            protocolPublicKey: protocolPublicKey,
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: expectedFingerprint,
            signature: Data()
        )

        let provider = DefaultHandshakeTrustProvider()
        let resolved = provider.resolvedTrustedFingerprint(
            directRecord: record,
            matchingRecords: [record]
        )

        XCTAssertEqual(resolved, expectedFingerprint.lowercased())
        XCTAssertNotEqual(resolved, record.pubKeyFP.lowercased())
    }

    func testDefaultHandshakeTrustProviderDoesNotMisuseLegacyPubKeyFingerprintForProtocolPinning() async throws {
        let record = TrustRecord(
            deviceId: "id:\(UUID().uuidString)",
            pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data([0x02]),
            signature: Data()
        )

        let provider = DefaultHandshakeTrustProvider()
        let resolved = provider.resolvedTrustedFingerprint(
            directRecord: record,
            matchingRecords: [record]
        )

        XCTAssertNil(resolved)
    }

    @MainActor
    func testP2PDiscoveryKEMAliasRepairFindsUniqueDisplayNameBackedTrustRecord() {
        let scannedDevice = DiscoveredDevice(
            id: UUID(),
            name: "Ziang's iPhone 16 Pro",
            ipv4: "192.168.0.106",
            ipv6: "fe80::c55:97f0:7246:915%en0",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 50873],
            uniqueIdentifier: "recent:bonjour:Ziang's iPhone 16 Pro@local.",
            source: .skybridgeBonjour
        )
        let trustedRecord = TrustRecord(
            deviceId: "id:ios-protocol-device",
            pubKeyFP: String(repeating: "b", count: 64),
            publicKey: Data([0x01]),
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 0x0001, publicKey: Data(repeating: 0xAA, count: 1_216))],
            signature: Data([0x02]),
            deviceName: "Ziang's iPhone 16 Pro",
            currentDeviceId: "id:ios-protocol-device",
            knownDeviceIds: ["host:fe80::c55:97f0:7246:915"]
        )

        let selected = P2PDiscoveryService.uniqueKEMTrustRecordForAliasRepair(
            device: scannedDevice,
            records: [trustedRecord]
        )

        XCTAssertEqual(selected?.deviceId, trustedRecord.deviceId)
        let aliases = P2PDiscoveryService.kemBootstrapAliasRepairCandidates(for: scannedDevice)
        XCTAssertTrue(aliases.contains("recent:bonjour:Ziang's iPhone 16 Pro@local."))
        XCTAssertTrue(aliases.contains("host:fe80::c55:97f0:7246:915"))
    }

    @MainActor
    func testP2PDiscoveryKEMAliasRepairToleratesOSVersionSuffixInDiscoveryName() {
        let scannedDevice = DiscoveredDevice(
            id: UUID(),
            name: "Ziang's iPhone 16 Pro - iOS 26.5",
            ipv4: "192.168.0.106",
            ipv6: "fe80::c55:97f0:7246:915%en0",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 50873],
            uniqueIdentifier: "recent:bonjour:Ziang's iPhone 16 Pro - Version 26.5 (Build 23F77)@local.",
            source: .skybridgeBonjour
        )
        let trustedRecord = TrustRecord(
            deviceId: "id:ios-protocol-device",
            pubKeyFP: String(repeating: "e", count: 64),
            publicKey: Data([0x01]),
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 0x0001, publicKey: Data(repeating: 0xCC, count: 1_216))],
            signature: Data([0x02]),
            deviceName: "Ziang's iPhone 16 Pro",
            currentDeviceId: "id:ios-protocol-device",
            knownDeviceIds: ["host:fe80::c55:97f0:7246:915"]
        )

        let selected = P2PDiscoveryService.uniqueKEMTrustRecordForAliasRepair(
            device: scannedDevice,
            records: [trustedRecord]
        )

        XCTAssertEqual(selected?.deviceId, trustedRecord.deviceId)
    }

    @MainActor
    func testP2PDiscoveryKEMAliasRepairRejectsAmbiguousDisplayNameMatches() {
        let scannedDevice = DiscoveredDevice(
            id: UUID(),
            name: "Office iPhone",
            ipv4: "192.168.0.110",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 50873],
            uniqueIdentifier: "recent:name:Office iPhone",
            source: .skybridgeBonjour
        )
        let firstRecord = TrustRecord(
            deviceId: "id:office-iphone-a",
            pubKeyFP: String(repeating: "c", count: 64),
            publicKey: Data([0x01]),
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 0x0001, publicKey: Data(repeating: 0xA1, count: 1_216))],
            signature: Data([0x02]),
            deviceName: "Office iPhone",
            currentDeviceId: "id:office-iphone-a"
        )
        let secondRecord = TrustRecord(
            deviceId: "id:office-iphone-b",
            pubKeyFP: String(repeating: "d", count: 64),
            publicKey: Data([0x03]),
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 0x0001, publicKey: Data(repeating: 0xB1, count: 1_216))],
            signature: Data([0x04]),
            deviceName: "Office iPhone",
            currentDeviceId: "id:office-iphone-b"
        )

        let selected = P2PDiscoveryService.uniqueKEMTrustRecordForAliasRepair(
            device: scannedDevice,
            records: [firstRecord, secondRecord]
        )

        XCTAssertNil(selected)
    }
}
