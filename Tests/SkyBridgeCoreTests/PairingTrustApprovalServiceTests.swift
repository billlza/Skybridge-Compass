import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class PairingTrustApprovalServiceTests: XCTestCase {
    func testIdentityBoundPoliciesNeverAuthorizeAnotherKeyAndUnboundAllowIsOneShot() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let deviceId = "id:binding-isolation-\(UUID().uuidString.lowercased())"
        let firstFingerprint = String(repeating: "1", count: 64)
        let secondFingerprint = String(repeating: "2", count: 64)
        let first = PairingTrustApprovalService.Request(
            peerEndpoint: "policy-test",
            declaredDeviceId: deviceId,
            policyBindingKey: "\(deviceId)|ED25519|\(firstFingerprint)",
            displayName: "Binding A",
            kemKeyCount: 0
        )
        let second = PairingTrustApprovalService.Request(
            peerEndpoint: "policy-test",
            declaredDeviceId: deviceId,
            policyBindingKey: "\(deviceId)|ED25519|\(secondFingerprint)",
            displayName: "Binding B",
            kemKeyCount: 0
        )
        let legacyUnbound = PairingTrustApprovalService.Request(
            peerEndpoint: "policy-test",
            declaredDeviceId: deviceId,
            displayName: "Legacy Device Policy",
            kemKeyCount: 0
        )
        defer {
            service.userDismissedCurrentPrompt()
            XCTAssertNoThrow(try service.clearPolicy(for: deviceId))
        }

        let firstTask = Task { @MainActor in
            try await service.decide(for: first)
        }
        try await waitForPendingRequest(first.id, service: service)
        service.resolve(first, decision: .alwaysAllow)
        let firstDecision = try await firstTask.value
        XCTAssertEqual(firstDecision, .alwaysAllow)
        XCTAssertEqual(try service.persistedPolicyDecision(for: first), .alwaysAllow)
        XCTAssertNil(try service.persistedPolicyDecision(for: second))
        XCTAssertNil(try service.persistedPolicyDecision(for: legacyUnbound))
        service.userDismissedCurrentPrompt()

        let legacyTask = Task { @MainActor in
            try await service.decide(for: legacyUnbound)
        }
        try await waitForPendingRequest(legacyUnbound.id, service: service)
        service.resolve(legacyUnbound, decision: .alwaysAllow)
        let legacyDecision = try await legacyTask.value
        XCTAssertEqual(legacyDecision, .allowOnce)
        XCTAssertNil(try service.persistedPolicyDecision(for: legacyUnbound))
        XCTAssertNil(
            try service.persistedPolicyDecision(for: second),
            "an unbound allow must never authorize a new bound identity"
        )
    }

    func testCancelledApprovalRemovesPromptAndCannotPersistStaleResolution() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let deviceId = "id:cancelled-approval-\(UUID().uuidString.lowercased())"
        let request = PairingTrustApprovalService.Request(
            peerEndpoint: "policy-test",
            declaredDeviceId: deviceId,
            policyBindingKey: "\(deviceId)|ED25519|\(String(repeating: "a", count: 64))",
            displayName: "Cancelled Approval",
            kemKeyCount: 0
        )
        defer { XCTAssertNoThrow(try service.clearPolicy(for: deviceId)) }

        let decisionTask = Task { @MainActor in
            try await service.decide(for: request)
        }
        try await waitForPendingRequest(request.id, service: service)
        XCTAssertEqual(service.pendingDecisionWaiterCountForTesting, 1)
        decisionTask.cancel()
        do {
            _ = try await decisionTask.value
            XCTFail("cancelled approval must throw")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertNil(service.pendingRequest)
        XCTAssertEqual(service.pendingDecisionWaiterCountForTesting, 0)
        service.resolve(request, decision: .alwaysAllow)
        XCTAssertNil(try service.persistedPolicyDecision(for: request))
    }

    func testCancellingOneCoalescedWaiterPreservesPromptAndRemainingDecision() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let deviceId = "id:coalesced-cancel-\(UUID().uuidString.lowercased())"
        let bindingKey = "\(deviceId)|ED25519|\(String(repeating: "b", count: 64))"
        let first = PairingTrustApprovalService.Request(
            peerEndpoint: "policy-test-a",
            declaredDeviceId: deviceId,
            policyBindingKey: bindingKey,
            displayName: "Coalesced A",
            kemKeyCount: 0
        )
        let second = PairingTrustApprovalService.Request(
            peerEndpoint: "policy-test-b",
            declaredDeviceId: deviceId,
            policyBindingKey: bindingKey,
            displayName: "Coalesced B",
            kemKeyCount: 0
        )
        defer {
            service.userDismissedCurrentPrompt()
            XCTAssertNoThrow(try service.clearPolicy(for: deviceId))
        }

        let firstTask = Task { @MainActor in try await service.decide(for: first) }
        try await waitForPendingRequest(first.id, service: service)
        try await waitForWaiterCount(1, service: service)
        let secondTask = Task { @MainActor in try await service.decide(for: second) }
        try await waitForWaiterCount(2, service: service)

        firstTask.cancel()
        do {
            _ = try await firstTask.value
            XCTFail("the cancelled waiter must throw")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(service.pendingRequest?.id, first.id)
        XCTAssertEqual(service.pendingDecisionWaiterCountForTesting, 1)
        service.resolve(first, decision: .allowOnce)
        let secondDecision = try await secondTask.value
        XCTAssertEqual(secondDecision, .allowOnce)
    }

    func testWaiterAdmissionIsBoundedAndOverflowFailsClosed() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let deviceId = "id:waiter-capacity-\(UUID().uuidString.lowercased())"
        let bindingKey = "\(deviceId)|ED25519|\(String(repeating: "c", count: 64))"
        let requests = (0...8).map { index in
            PairingTrustApprovalService.Request(
                peerEndpoint: "policy-test-\(index)",
                declaredDeviceId: deviceId,
                policyBindingKey: bindingKey,
                displayName: "Bounded Waiter \(index)",
                kemKeyCount: 0
            )
        }
        var admittedTasks: [Task<PairingTrustApprovalService.Decision, any Error>] = []
        defer {
            admittedTasks.forEach { $0.cancel() }
            service.userDismissedCurrentPrompt()
            XCTAssertNoThrow(try service.clearPolicy(for: deviceId))
        }

        for index in 0..<8 {
            let request = requests[index]
            admittedTasks.append(
                Task { @MainActor in try await service.decide(for: request) }
            )
            if index == 0 {
                try await waitForPendingRequest(request.id, service: service)
            }
            try await waitForWaiterCount(index + 1, service: service)
        }

        do {
            _ = try await service.decide(for: requests[8])
            XCTFail("the ninth waiter must be rejected by bounded admission")
        } catch let error as PairingTrustApprovalAdmissionError {
            XCTAssertEqual(error, .waiterLimitExceeded(maximum: 8))
        }
        XCTAssertEqual(service.pendingDecisionWaiterCountForTesting, 8)
        let pending = try XCTUnwrap(service.pendingRequest)
        service.resolve(pending, decision: .allowOnce)
        for task in admittedTasks {
            let decision = try await task.value
            XCTAssertEqual(decision, .allowOnce)
        }
    }

    func testInformationalBindingCodeCannotOverwritePendingApproval() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let deviceId = "id:show-isolation-\(UUID().uuidString.lowercased())"
        let request = PairingTrustApprovalService.Request(
            peerEndpoint: "policy-test",
            declaredDeviceId: deviceId,
            policyBindingKey: "\(deviceId)|ED25519|\(String(repeating: "d", count: 64))",
            displayName: "Pending Approval",
            kemKeyCount: 0
        )
        defer {
            service.userDismissedCurrentPrompt()
            XCTAssertNoThrow(try service.clearPolicy(for: deviceId))
        }

        let decisionTask = Task { @MainActor in try await service.decide(for: request) }
        try await waitForPendingRequest(request.id, service: service)
        service.showProtocolIdentityBindingCode(
            peerEndpoint: "informational-test",
            declaredDeviceId: "id:informational-\(UUID().uuidString.lowercased())",
            displayName: "Informational Code",
            verificationCode: "654321",
            protocolIdentityFingerprint: String(repeating: "e", count: 64)
        )

        XCTAssertEqual(service.pendingRequest?.id, request.id)
        XCTAssertNil(service.pendingDecision)
        XCTAssertNil(service.pendingVerificationCode)
        XCTAssertEqual(service.pendingDecisionWaiterCountForTesting, 1)
        service.resolve(request, decision: .allowOnce)
        let decision = try await decisionTask.value
        XCTAssertEqual(decision, .allowOnce)
    }

    func testPolicySaveFailureDowngradesAllowButKeepsRejectFailClosed() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        service.setPolicyStoreSaveFailureForTesting(false)
        let deviceId = "id:policy-save-failure-\(UUID().uuidString.lowercased())"
        let bindingKey = "\(deviceId)|ED25519|\(String(repeating: "f", count: 64))"
        defer {
            service.setPolicyStoreSaveFailureForTesting(false)
            service.userDismissedCurrentPrompt()
            XCTAssertNoThrow(try service.clearPolicy(for: deviceId))
        }

        let allowRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "policy-test",
            declaredDeviceId: deviceId,
            policyBindingKey: bindingKey,
            displayName: "Failed Durable Allow",
            kemKeyCount: 0
        )
        let allowTask = Task { @MainActor in try await service.decide(for: allowRequest) }
        try await waitForPendingRequest(allowRequest.id, service: service)
        service.setPolicyStoreSaveFailureForTesting(true)
        service.resolve(allowRequest, decision: .alwaysAllow)
        let allowDecision = try await allowTask.value
        XCTAssertEqual(allowDecision, .allowOnce)
        XCTAssertNil(try service.persistedPolicyDecision(for: allowRequest))
        service.userDismissedCurrentPrompt()

        let rejectRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "policy-test",
            declaredDeviceId: deviceId,
            policyBindingKey: bindingKey,
            displayName: "Failed Durable Reject",
            kemKeyCount: 0
        )
        let rejectTask = Task { @MainActor in try await service.decide(for: rejectRequest) }
        try await waitForPendingRequest(rejectRequest.id, service: service)
        service.resolve(rejectRequest, decision: .reject)
        let rejectDecision = try await rejectTask.value
        XCTAssertEqual(rejectDecision, .reject)
        XCTAssertNil(try service.persistedPolicyDecision(for: rejectRequest))
    }

    func testFirstAllowDecisionOwnsProtocolIdentityCommitAndLaterRejectIsIgnored() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let requesterId = "id:pin-cancel-\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "7", count: 64)
        let trust = TrustSyncService.shared
        await trust.beginInMemoryPersistenceForTesting()
        await trust.removeRecordsForTesting(deviceIds: [requesterId])
        await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
        addTeardownBlock { @MainActor [trust] in
            PairingTrustApprovalService.shared.userDismissedCurrentPrompt()
            XCTAssertNoThrow(try PairingTrustApprovalService.shared.clearPolicy(for: requesterId))
            await trust.removeRecordsForTesting(deviceIds: [requesterId])
            trust.endInMemoryPersistenceForTesting()
            await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
        }

        let approvalTask = Task { @MainActor in
            try await service.stageProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-test",
                requesterDeviceIds: [requesterId],
                displayName: requesterId,
                platform: "iOS",
                verificationCode: "123456",
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint
            )
        }
        let request = try await waitForPendingDevice(requesterId, service: service)
        service.resolve(request, decision: .allowOnce)
        service.resolve(request, decision: .reject)

        let approvalDecision = try await approvalTask.value
        XCTAssertEqual(approvalDecision, .allowOnce)
        await Task.yield()
        XCTAssertNotNil(trust.getTrustRecord(deviceId: requesterId))
        let pinned = await PeerProtocolIdentityBootstrapStore.shared.trustedFingerprints(
            forCandidates: [requesterId]
        )
        XCTAssertTrue(pinned.contains(fingerprint))
    }

    func testForgetClearsAllAliasAndPIB1PolicySchemas() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let firstId = "ID:Policy-Forget-\(UUID().uuidString)"
        let secondId = "bonjour:policy-forget-\(UUID().uuidString.lowercased())@local."
        let thirdId = "id:direct-policy-forget-\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "8", count: 64)
        let requests = [
            PairingTrustApprovalService.Request(
                peerEndpoint: "policy-test",
                declaredDeviceId: firstId,
                policyBindingKey: "PIB-1|\(firstId)|\(fingerprint)",
                displayName: "Policy Test",
                kemKeyCount: 0
            ),
            PairingTrustApprovalService.Request(
                peerEndpoint: "policy-test",
                declaredDeviceId: secondId,
                policyBindingKey: "PIB-1-requester|\(secondId)|ED25519|\(fingerprint)",
                displayName: "Policy Test Alias",
                kemKeyCount: 0
            ),
            PairingTrustApprovalService.Request(
                peerEndpoint: "policy-test",
                declaredDeviceId: thirdId,
                policyBindingKey: "\(thirdId)|ED25519|\(fingerprint)",
                displayName: "Direct Binding Policy",
                kemKeyCount: 0
            )
        ]
        defer {
            XCTAssertNoThrow(try service.clearPolicies(for: [firstId, secondId, thirdId]))
        }

        for request in requests {
            let decisionTask = Task { @MainActor in
                try await service.decide(for: request)
            }
            try await waitForPendingRequest(request.id, service: service)
            service.resolve(request, decision: .reject)
            let decision = try await decisionTask.value
            XCTAssertEqual(decision, .reject)
            XCTAssertEqual(try service.persistedPolicyDecision(for: request), .reject)
        }

        try service.clearPolicies(for: [firstId.lowercased(), secondId.uppercased(), thirdId.uppercased()])
        for request in requests {
            XCTAssertNil(try service.persistedPolicyDecision(for: request))
        }
    }

    func testForgetRejectsPendingApprovalAndStaleResolutionCannotRestorePolicy() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let deviceId = "id:pending-forget-\(UUID().uuidString.lowercased())"
        let request = PairingTrustApprovalService.Request(
            peerEndpoint: "policy-test",
            declaredDeviceId: deviceId,
            displayName: "Pending Forget",
            kemKeyCount: 0
        )
        defer { XCTAssertNoThrow(try service.clearPolicy(for: deviceId)) }

        let decisionTask = Task { @MainActor in
            try await service.decide(for: request)
        }
        try await waitForPendingRequest(request.id, service: service)
        try service.clearPolicy(for: deviceId)

        let decision = try await decisionTask.value
        XCTAssertEqual(decision, .reject)
        service.resolve(request, decision: .alwaysAllow)
        XCTAssertNil(try service.persistedPolicyDecision(for: request))
    }

    func testProtocolIdentityRequesterApprovalWaitsForOperatorBeforeServing() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()

        let requesterId = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "a", count: 64)
        let verificationCode = "123456"
        let trust = TrustSyncService.shared
        await trust.beginInMemoryPersistenceForTesting()
        await trust.removeRecordsForTesting(deviceIds: [requesterId])
        await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
        addTeardownBlock { @MainActor [trust] in
            await trust.removeRecordsForTesting(deviceIds: [requesterId])
            trust.endInMemoryPersistenceForTesting()
            await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
        }
        let completion = DecisionRecorder()

        let approvalTask = Task { @MainActor in
            let decision = try await service.stageProtocolIdentityBindingRequesterApproval(
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

        let decision = try await approvalTask.value
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

    private func waitForPendingRequest(
        _ requestId: UUID,
        service: PairingTrustApprovalService
    ) async throws {
        for _ in 0..<100 {
            if service.pendingRequest?.id == requestId { return }
            await Task.yield()
        }
        XCTFail("pairing approval request did not become pending")
        throw NSError(domain: "PairingTrustApprovalServiceTests", code: 1)
    }

    private func waitForPendingDevice(
        _ deviceId: String,
        service: PairingTrustApprovalService
    ) async throws -> PairingTrustApprovalService.Request {
        for _ in 0..<100 {
            if let request = service.pendingRequest,
               request.declaredDeviceId == deviceId {
                return request
            }
            await Task.yield()
        }
        XCTFail("pairing approval request did not become pending")
        throw NSError(domain: "PairingTrustApprovalServiceTests", code: 2)
    }

    private func waitForWaiterCount(
        _ expected: Int,
        service: PairingTrustApprovalService
    ) async throws {
        for _ in 0..<100 {
            if service.pendingDecisionWaiterCountForTesting == expected { return }
            await Task.yield()
        }
        XCTFail("pairing approval waiter count did not reach \(expected)")
        throw NSError(domain: "PairingTrustApprovalServiceTests", code: 3)
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
