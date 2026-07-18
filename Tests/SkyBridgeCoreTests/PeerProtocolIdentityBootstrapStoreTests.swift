import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class PeerProtocolIdentityBootstrapStoreTests: XCTestCase {
    func testStoreNormalizesAndReplacesFingerprintObservation() async throws {
        let store = PeerProtocolIdentityBootstrapStore.shared
        await store.clearForTesting()

        let primary = String(repeating: "a", count: 64)
        let secondary = String(repeating: "b", count: 64)

        await store.upsert(deviceIds: ["peer-a"], fingerprints: [primary.uppercased(), "not-a-fingerprint"])
        await store.upsert(deviceIds: ["peer-a"], fingerprints: [secondary])

        let trusted = await store.trustedFingerprints(forCandidates: ["peer-a"])
        XCTAssertEqual(trusted, [secondary])
        await store.clearForTesting()
    }

    func testDefaultTrustProviderNeverExpandsAuthoritativePinsFromBootstrapCache() async throws {
        let store = PeerProtocolIdentityBootstrapStore.shared
        await store.clearForTesting()

        let rejectedOldPin = String(repeating: "a", count: 64)
        let authoritativeReplacementPin = String(repeating: "b", count: 64)
        let record = TrustRecord(
            deviceId: "stable-peer",
            pubKeyFP: "",
            publicKey: Data(),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: authoritativeReplacementPin,
            signature: Data(),
            deviceName: "Peer",
            currentDeviceId: "stable-peer",
            knownDeviceIds: ["stable-peer", "runtime-peer"],
            lifecycleState: .active
        )
        let provider = DefaultHandshakeTrustProvider(trustRecordsSnapshot: [record])

        await store.upsert(
            deviceIds: ["runtime-peer"],
            fingerprints: [rejectedOldPin, authoritativeReplacementPin]
        )
        let resolvedPins = await provider.trustedFingerprints(for: "runtime-peer")
        XCTAssertEqual(
            resolvedPins,
            [authoritativeReplacementPin],
            "bootstrap history may corroborate current authority but must never re-authorize a rejected old pin"
        )
        await store.clearForTesting()
    }

    func testContainsTrustedFingerprintMatchesApprovedPinsAcrossEndpointAliases() async throws {
        let store = PeerProtocolIdentityBootstrapStore.shared
        await store.clearForTesting()

        let fingerprint = String(repeating: "e", count: 64)
        await store.upsert(deviceIds: ["id:requester"], fingerprints: [fingerprint.uppercased()])

        let containsLowercase = await store.containsTrustedFingerprint(fingerprint)
        let containsUppercase = await store.containsTrustedFingerprint(fingerprint.uppercased())
        let containsOther = await store.containsTrustedFingerprint(String(repeating: "f", count: 64))
        let containsInvalid = await store.containsTrustedFingerprint("not-a-fingerprint")

        XCTAssertTrue(containsLowercase)
        XCTAssertTrue(containsUppercase)
        XCTAssertFalse(containsOther)
        XCTAssertFalse(containsInvalid)
        await store.clearForTesting()
    }

    func testClearRemovesOnlyRequestedProtocolIdentityAliases() async throws {
        let store = PeerProtocolIdentityBootstrapStore.shared
        await store.clearForTesting()

        let forgotten = String(repeating: "c", count: 64)
        let kept = String(repeating: "d", count: 64)
        await store.upsert(deviceIds: ["id:forgotten", "bonjour:Forgotten@local."], fingerprints: [forgotten])
        await store.upsert(deviceIds: ["id:kept"], fingerprints: [kept])

        await store.clear(deviceIds: ["id:forgotten", "bonjour:Forgotten@local."])

        let forgottenPins = await store.trustedFingerprints(forCandidates: ["id:forgotten"])
        let forgottenBonjourPins = await store.trustedFingerprints(forCandidates: ["bonjour:Forgotten@local."])
        let keptPins = await store.trustedFingerprints(forCandidates: ["id:kept"])
        XCTAssertTrue(forgottenPins.isEmpty)
        XCTAssertTrue(forgottenBonjourPins.isEmpty)
        XCTAssertEqual(keptPins, [kept])
        await store.clearForTesting()
    }
}
