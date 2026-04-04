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
        XCTAssertTrue(idCandidates.contains("id:\(bareUUID)"))
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
