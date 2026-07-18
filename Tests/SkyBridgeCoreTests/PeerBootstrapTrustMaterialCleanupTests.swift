import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class PeerBootstrapTrustMaterialCleanupTests: XCTestCase {
    @MainActor
    func testFailClosedForgetRunsInMonotonicAuthorizationOrder() async throws {
        var events: [String] = []
        try await PeerBootstrapTrustMaterialCleanup.performFailClosedForget(
            loadVerifiedFingerprints: {
                events.append("load")
                return [String(repeating: "a", count: 64)]
            },
            clearAutoConnect: { _ in events.append("auto") },
            clearPairingPolicies: { events.append("policy") },
            removeTrust: { events.append("trust") },
            clearBootstrap: { events.append("bootstrap") }
        )
        XCTAssertEqual(events, ["load", "auto", "policy", "trust", "bootstrap"])
    }

    @MainActor
    func testFailClosedForgetStopsBeforeDenyRemovalWhenPolicyClearFails() async {
        var events: [String] = []
        do {
            try await PeerBootstrapTrustMaterialCleanup.performFailClosedForget(
                loadVerifiedFingerprints: {
                    events.append("load")
                    return []
                },
                clearAutoConnect: { _ in events.append("auto") },
                clearPairingPolicies: {
                    events.append("policy")
                    throw ForgetCoordinatorTestError.persistenceFailure
                },
                removeTrust: { events.append("trust") },
                clearBootstrap: { events.append("bootstrap") }
            )
            XCTFail("policy persistence failure must stop forget")
        } catch ForgetCoordinatorTestError.persistenceFailure {
            XCTAssertEqual(events, ["load", "auto", "policy"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testFailClosedForgetDoesNotClearBootstrapAfterTrustRemovalFailure() async {
        var events: [String] = []
        do {
            try await PeerBootstrapTrustMaterialCleanup.performFailClosedForget(
                loadVerifiedFingerprints: {
                    events.append("load")
                    return []
                },
                clearAutoConnect: { _ in events.append("auto") },
                clearPairingPolicies: { events.append("policy") },
                removeTrust: {
                    events.append("trust")
                    throw ForgetCoordinatorTestError.persistenceFailure
                },
                clearBootstrap: { events.append("bootstrap") }
            )
            XCTFail("trust persistence failure must stop forget")
        } catch ForgetCoordinatorTestError.persistenceFailure {
            XCTAssertEqual(events, ["load", "auto", "policy", "trust"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testFailClosedForgetReportsBootstrapPersistenceFailure() async {
        var events: [String] = []
        do {
            try await PeerBootstrapTrustMaterialCleanup.performFailClosedForget(
                loadVerifiedFingerprints: {
                    events.append("load")
                    return []
                },
                clearAutoConnect: { _ in events.append("auto") },
                clearPairingPolicies: { events.append("policy") },
                removeTrust: { events.append("trust") },
                clearBootstrap: {
                    events.append("bootstrap")
                    throw ForgetCoordinatorTestError.persistenceFailure
                }
            )
            XCTFail("bootstrap persistence failure must be reported")
        } catch ForgetCoordinatorTestError.persistenceFailure {
            XCTAssertEqual(events, ["load", "auto", "policy", "trust", "bootstrap"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testForgetDeviceClearsKEMAndProtocolIdentityBootstrapMaterial() async throws {
        await PeerKEMBootstrapStore.shared.clearForTesting()
        await PeerProtocolIdentityBootstrapStore.shared.clearForTesting()

        let forgottenKey = KEMPublicKeyInfo(suiteWireId: 1, publicKey: Data(repeating: 0xA1, count: 1_216))
        let keptKey = KEMPublicKeyInfo(suiteWireId: 1, publicKey: Data(repeating: 0xB2, count: 1_216))
        let forgottenFingerprint = String(repeating: "a", count: 64)
        let keptFingerprint = String(repeating: "b", count: 64)

        await PeerKEMBootstrapStore.shared.upsert(
            deviceIds: ["id:forgotten", "bonjour:Forgotten@local."],
            kemPublicKeys: [forgottenKey]
        )
        await PeerProtocolIdentityBootstrapStore.shared.upsert(
            deviceIds: ["id:forgotten", "bonjour:Forgotten@local."],
            fingerprints: [forgottenFingerprint]
        )
        await PeerKEMBootstrapStore.shared.upsert(deviceIds: ["id:kept"], kemPublicKeys: [keptKey])
        await PeerProtocolIdentityBootstrapStore.shared.upsert(
            deviceIds: ["id:kept"],
            fingerprints: [keptFingerprint]
        )

        try await PeerBootstrapTrustMaterialCleanup.forgetDevicePersisting(
            deviceIds: ["id:forgotten", "bonjour:Forgotten@local."]
        )

        let forgottenKEM = await PeerKEMBootstrapStore.shared.mergedKEMPublicKeys(
            forCandidates: ["id:forgotten", "bonjour:Forgotten@local."]
        )
        let forgottenPins = await PeerProtocolIdentityBootstrapStore.shared.trustedFingerprints(
            forCandidates: ["id:forgotten", "bonjour:Forgotten@local."]
        )
        let keptKEM = await PeerKEMBootstrapStore.shared.mergedKEMPublicKeys(forCandidates: ["id:kept"])
        let keptPins = await PeerProtocolIdentityBootstrapStore.shared.trustedFingerprints(
            forCandidates: ["id:kept"]
        )

        XCTAssertTrue(forgottenKEM.isEmpty)
        XCTAssertTrue(forgottenPins.isEmpty)
        XCTAssertEqual(keptKEM[1], keptKey.publicKey)
        XCTAssertEqual(keptPins, [keptFingerprint])

        await PeerKEMBootstrapStore.shared.clearForTesting()
        await PeerProtocolIdentityBootstrapStore.shared.clearForTesting()
    }

    func testRepairP2PTrustClearsOnlyKEMBootstrapAndPreservesProtocolIdentityBootstrapMaterial() async throws {
        await PeerKEMBootstrapStore.shared.clearForTesting()
        await PeerProtocolIdentityBootstrapStore.shared.clearForTesting()

        let staleKey = KEMPublicKeyInfo(suiteWireId: 1, publicKey: Data(repeating: 0xC3, count: 1_216))
        let fingerprint = String(repeating: "c", count: 64)

        await PeerKEMBootstrapStore.shared.upsert(deviceIds: ["id:repair"], kemPublicKeys: [staleKey])
        await PeerProtocolIdentityBootstrapStore.shared.upsert(
            deviceIds: ["id:repair"],
            fingerprints: [fingerprint]
        )

        await PeerBootstrapTrustMaterialCleanup.repairP2PTrust(deviceIds: ["id:repair"])

        let repairedKEM = await PeerKEMBootstrapStore.shared.mergedKEMPublicKeys(forCandidates: ["id:repair"])
        let preservedPins = await PeerProtocolIdentityBootstrapStore.shared.trustedFingerprints(
            forCandidates: ["id:repair"]
        )

        XCTAssertTrue(repairedKEM.isEmpty)
        XCTAssertEqual(preservedPins, [fingerprint])

        await PeerKEMBootstrapStore.shared.clearForTesting()
        await PeerProtocolIdentityBootstrapStore.shared.clearForTesting()
    }
}

private enum ForgetCoordinatorTestError: Error {
    case persistenceFailure
}
