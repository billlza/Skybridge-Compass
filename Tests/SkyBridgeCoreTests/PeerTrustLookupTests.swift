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
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data([0xAA]))],
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
    func testDefaultHandshakeTrustProviderFindsKEMThroughKnownDeviceAliases() async throws {
        let canonicalId = "id:\(UUID().uuidString)"
        let hostAlias = "host:fe80::81d:bb45:8c18:6d6a%en0"
        let normalizedHostAlias = "host:fe80::81d:bb45:8c18:6d6a"
        let expectedKey = Data([0xAB, 0xCD, 0xEF])
        let bootstrapStore = PeerKEMBootstrapStore.shared
        await bootstrapStore.clearForTesting()
        defer {
            Task { await bootstrapStore.clearForTesting() }
        }

        await bootstrapStore.upsert(
            deviceIds: [canonicalId, hostAlias, normalizedHostAlias, "bonjour:trusted iphone@local."],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: expectedKey)]
        )

        let provider = DefaultHandshakeTrustProvider()
        let resolved = await provider.trustedKEMPublicKeys(for: "host:[fe80::81d:bb45:8c18:6d6a%en0].9527")

        XCTAssertEqual(resolved[CryptoSuite(wireId: 257)], expectedKey)
    }

    @MainActor
    func testDefaultHandshakeTrustProviderIgnoresEmptyTrustedKEMPublicKeys() async throws {
        let canonicalId = "id:\(UUID().uuidString)"
        let trust = TrustSyncService.shared

        trust.setInMemoryPersistenceForTesting(true)
        await trust.removeRecordsForTesting(deviceIds: [canonicalId])
        defer {
            trust.setInMemoryPersistenceForTesting(false)
            Task { @MainActor in
                await trust.removeRecordsForTesting(deviceIds: [canonicalId])
            }
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
    func testDefaultHandshakeTrustProviderPrefersBootstrapCacheWhenTrustedKEMKeysConflict() async throws {
        let alias = "bonjour:office ipad@local."
        let suite = CryptoSuite(wireId: 257)
        let cachedKey = Data([0xCC, 0xDD, 0xEE])
        let trust = TrustSyncService.shared
        let bootstrapStore = PeerKEMBootstrapStore.shared
        let cleanupIds = ["id:conflict-a", "id:conflict-b"]

        trust.setInMemoryPersistenceForTesting(true)
        await trust.removeRecordsForTesting(deviceIds: cleanupIds)
        await bootstrapStore.clearForTesting()

        defer {
            trust.setInMemoryPersistenceForTesting(false)
            Task { @MainActor in
                await trust.removeRecordsForTesting(deviceIds: cleanupIds)
            }
            Task {
                await bootstrapStore.clearForTesting()
            }
        }

        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: cleanupIds[0],
                pubKeyFP: String(repeating: "1", count: 64),
                publicKey: Data([0x01]),
                kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: suite.wireId, publicKey: Data([0xAA]))],
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
                kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: suite.wireId, publicKey: Data([0xBB]))],
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

        XCTAssertEqual(resolved[suite], cachedKey)
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
}
