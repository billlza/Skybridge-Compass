import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class PairingTrustApprovalServiceTests: XCTestCase {
    func testProtocolIdentityRequesterApprovalWaitsForOperatorBeforeServing() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()

        let requesterId = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "a", count: 64)
        let verificationCode = "123456"
        let trust = TrustSyncService.shared
        trust.setInMemoryPersistenceForTesting(true)
        await trust.removeRecordsForTesting(deviceIds: [requesterId])
        await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
        defer {
            Task { @MainActor in
                await trust.removeRecordsForTesting(deviceIds: [requesterId])
                trust.setInMemoryPersistenceForTesting(false)
                await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
            }
        }
        let completion = DecisionRecorder()

        let approvalTask = Task { @MainActor in
            let decision = await service.stageProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-test",
                requesterDeviceIds: [requesterId],
                displayName: requesterId,
                platform: "iOS",
                verificationCode: verificationCode,
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint
            )
            await completion.set(decision)
            return decision
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        let earlyDecision = await completion.value()
        XCTAssertNil(earlyDecision, "PIB-1 target side must not serve a signed identity response before local requester approval.")

        let request = try XCTUnwrap(service.pendingRequest)
        XCTAssertEqual(service.pendingVerificationCode, verificationCode)
        service.resolve(request, decision: .allowOnce)

        let decision = await approvalTask.value
        XCTAssertEqual(decision, .allowOnce)
        let trusted = await PeerProtocolIdentityBootstrapStore.shared.trustedFingerprints(
            forCandidates: [requesterId]
        )
        XCTAssertTrue(
            trusted.contains(fingerprint),
            "PIB-1 approval must pin requester protocol identity before the networking continuation resumes."
        )
        XCTAssertTrue(
            trust.getTrustRecord(deviceId: requesterId)?.currentPathAuthorityFingerprints.contains(fingerprint) ?? false,
            "PIB-1 approval must promote requester protocol identity into the authoritative TrustSync record."
        )
    }

    private actor DecisionRecorder {
        private var storedDecision: PairingTrustApprovalService.Decision?

        func set(_ decision: PairingTrustApprovalService.Decision) {
            storedDecision = decision
        }

        func value() -> PairingTrustApprovalService.Decision? {
            storedDecision
        }
    }
}
