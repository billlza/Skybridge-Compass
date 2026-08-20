import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class PairingTrustApprovalServiceTests: XCTestCase {
    func testStaleResolutionCannotChangeCurrentPolicy() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let currentRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "current",
            declaredDeviceId: "current:\(UUID().uuidString.lowercased())",
            displayName: "Current request",
            kemKeyCount: 1
        )
        let staleRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "stale",
            declaredDeviceId: "stale:\(UUID().uuidString.lowercased())",
            displayName: "Stale request",
            kemKeyCount: 1
        )
        let currentDecision = Task { @MainActor in await service.decide(for: currentRequest) }
        _ = try await waitForPendingRequest(service, matching: currentRequest.id)

        service.resolve(staleRequest, decision: .alwaysAllow)

        XCTAssertEqual(service.pendingRequest?.id, currentRequest.id)
        let stalePolicy = await service.persistedPolicyDecision(for: staleRequest)
        XCTAssertNil(stalePolicy)
        service.resolve(currentRequest, decision: .reject)
        let finalDecision = await currentDecision.value
        XCTAssertEqual(finalDecision, .reject)
        let cleared = await service.clearPolicy(for: currentRequest.declaredDeviceId)
        XCTAssertTrue(cleared)
    }

    func testCoalescedApprovalWaitersResolveTogether() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let deviceId = "coalesced:\(UUID().uuidString.lowercased())"
        let firstRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "first",
            declaredDeviceId: deviceId,
            displayName: "Coalesced test",
            kemKeyCount: 1
        )
        let secondRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "second",
            declaredDeviceId: deviceId,
            displayName: "Coalesced test",
            kemKeyCount: 1
        )

        let first = Task { @MainActor in await service.decide(for: firstRequest) }
        let pendingRequest = try await waitForPendingRequest(service)
        let second = Task { @MainActor in await service.decide(for: secondRequest) }
        try await waitForWaiterCount(service, requestID: pendingRequest.id, count: 2)

        service.resolve(try XCTUnwrap(service.pendingRequest), decision: .allowOnce)

        let firstDecision = await first.value
        let secondDecision = await second.value
        XCTAssertEqual(firstDecision, .allowOnce)
        XCTAssertEqual(secondDecision, .allowOnce)
        service.userDismissedCurrentPrompt()
    }

    func testAllowOnceDoesNotAuthorizeANewRequestForSameDevice() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let deviceId = "allow-once:\(UUID().uuidString.lowercased())"
        let firstRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "first",
            declaredDeviceId: deviceId,
            displayName: "Allow once test",
            kemKeyCount: 1
        )
        let first = Task { @MainActor in await service.decide(for: firstRequest) }
        _ = try await waitForPendingRequest(service)
        service.resolve(try XCTUnwrap(service.pendingRequest), decision: .allowOnce)
        let firstDecision = await first.value
        XCTAssertEqual(firstDecision, .allowOnce)

        let secondRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "second",
            declaredDeviceId: deviceId,
            displayName: "Allow once test",
            kemKeyCount: 1
        )
        let second = Task { @MainActor in await service.decide(for: secondRequest) }
        _ = try await waitForPendingRequest(service, matching: secondRequest.id)
        XCTAssertFalse(second.isCancelled)
        service.resolve(try XCTUnwrap(service.pendingRequest), decision: .reject)
        let secondDecision = await second.value
        XCTAssertEqual(secondDecision, .reject)
        let cleared = await service.clearPolicy(for: deviceId)
        XCTAssertTrue(cleared)
    }

    func testFailedProtocolIdentityPinDoesNotPersistAlwaysAllowPolicy() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        service.setProtocolIdentityPinResultOverrideForTesting(false)
        defer { service.setProtocolIdentityPinResultOverrideForTesting(nil) }
        let requesterId = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "c", count: 64)
        let transactionId = UUID()
        let requestHash = String(repeating: "1", count: 64)
        let candidateHash = String(repeating: "2", count: 64)
        let sasHash = String(repeating: "3", count: 64)

        let approvalTask = Task { @MainActor in
            await service.stageTestProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-pin-failure-test",
                requesterDeviceIds: [requesterId],
                displayName: requesterId,
                platform: "iOS",
                verificationCode: "123456",
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint,
                transactionId: transactionId,
                requestHashHex: requestHash,
                candidateHashHex: candidateHash,
                sasTranscriptHashHex: sasHash
            )
        }

        let request = try await waitForPendingRequest(service)
        service.resolve(request, decision: .alwaysAllow)

        let approvalDecision = await approvalTask.value
        XCTAssertEqual(approvalDecision, .alwaysAllow)
        let commitDecision = await service.commitProtocolIdentityBindingRequesterApproval(
            decision: approvalDecision,
            transactionId: transactionId,
            requesterDeviceIds: [requesterId],
            requesterProtocolSigningAlgorithm: .mlDSA65,
            requesterProtocolIdentityFingerprint: fingerprint,
            requestHashHex: requestHash,
            candidateHashHex: candidateHash,
            sasTranscriptHashHex: sasHash
        )
        XCTAssertEqual(commitDecision, .reject)
        let persistedDecision = await service.persistedPolicyDecision(for: request)
        XCTAssertNil(
            persistedDecision,
            "A failed PIB pin must never leave a persisted allow decision behind."
        )
    }

    func testPostCommitCleanupResidueStillCommitsRequesterApproval() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        service.setProtocolIdentityPinErrorForTesting(
            TrustSyncError.aliasCleanupFailedAfterAuthoritativeCommit("error_domain=test code=1")
        )
        defer { service.setProtocolIdentityPinErrorForTesting(nil) }
        let requesterId = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "d", count: 64)
        let transactionId = UUID()
        let requestHash = String(repeating: "1", count: 64)
        let candidateHash = String(repeating: "2", count: 64)
        let sasHash = String(repeating: "3", count: 64)

        let approvalTask = Task { @MainActor in
            await service.stageTestProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-pin-residue-test",
                requesterDeviceIds: [requesterId],
                displayName: requesterId,
                platform: "iOS",
                verificationCode: "123456",
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint,
                transactionId: transactionId,
                requestHashHex: requestHash,
                candidateHashHex: candidateHash,
                sasTranscriptHashHex: sasHash
            )
        }

        let request = try await waitForPendingRequest(service)
        service.resolve(request, decision: .allowOnce)

        let approvalDecision = await approvalTask.value
        XCTAssertEqual(approvalDecision, .allowOnce)
        let commitDecision = await service.commitProtocolIdentityBindingRequesterApproval(
            decision: approvalDecision,
            transactionId: transactionId,
            requesterDeviceIds: [requesterId],
            requesterProtocolSigningAlgorithm: .mlDSA65,
            requesterProtocolIdentityFingerprint: fingerprint,
            requestHashHex: requestHash,
            candidateHashHex: candidateHash,
            sasTranscriptHashHex: sasHash
        )
        XCTAssertEqual(
            commitDecision,
            .allowOnce,
            "Post-commit cleanup residue must not reject an approval whose authority pin already committed."
        )
        let cachedFingerprints = await PeerProtocolIdentityBootstrapStore.shared
            .trustedFingerprints(forCandidates: [requesterId])
        XCTAssertTrue(
            cachedFingerprints.contains(fingerprint),
            "The bootstrap-cache upsert must still run after a success-with-residue pin commit."
        )
        _ = await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
    }

    func testCancellingRequesterApprovalRejectsAndClearsPendingPrompt() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let requesterId = "id:\(UUID().uuidString.lowercased())"

        let approvalTask = Task { @MainActor in
            await service.stageTestProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-cancel-test",
                requesterDeviceIds: [requesterId],
                displayName: requesterId,
                platform: "iOS",
                verificationCode: "654321",
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: String(repeating: "b", count: 64)
            )
        }

        _ = try await waitForPendingRequest(service)
        approvalTask.cancel()
        let decision = await approvalTask.value

        XCTAssertEqual(decision, .reject)
        XCTAssertNil(service.pendingRequest)
    }

    func testRequesterApprovalDoesNotCoalesceAcrossDifferentSASOrEndpoint() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let requesterID = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "1", count: 64)
        let transactionId = UUID()
        let requestHash = String(repeating: "4", count: 64)
        let candidateHash = String(repeating: "5", count: 64)
        let sasHash = String(repeating: "6", count: 64)
        let first = Task { @MainActor in
            await service.stageTestProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-transcript-a",
                requesterDeviceIds: [requesterID],
                displayName: requesterID,
                platform: "iOS",
                verificationCode: "123456",
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint,
                transactionId: transactionId,
                requestHashHex: requestHash,
                candidateHashHex: candidateHash,
                sasTranscriptHashHex: sasHash
            )
        }
        let firstRequest = try await waitForPendingRequest(service)

        let differentSAS = await service.stageTestProtocolIdentityBindingRequesterApproval(
            peerEndpoint: "lan-transcript-a",
            requesterDeviceIds: [requesterID],
            displayName: requesterID,
            platform: "iOS",
            verificationCode: "654321",
            requesterProtocolSigningAlgorithm: .mlDSA65,
            requesterProtocolIdentityFingerprint: fingerprint,
            transactionId: transactionId,
            requestHashHex: requestHash,
            candidateHashHex: candidateHash,
            sasTranscriptHashHex: sasHash
        )
        let differentEndpoint = await service.stageTestProtocolIdentityBindingRequesterApproval(
            peerEndpoint: "lan-transcript-b",
            requesterDeviceIds: [requesterID],
            displayName: requesterID,
            platform: "iOS",
            verificationCode: "123456",
            requesterProtocolSigningAlgorithm: .mlDSA65,
            requesterProtocolIdentityFingerprint: fingerprint,
            transactionId: transactionId,
            requestHashHex: requestHash,
            candidateHashHex: candidateHash,
            sasTranscriptHashHex: sasHash
        )

        XCTAssertEqual(differentSAS, .reject)
        XCTAssertEqual(differentEndpoint, .reject)
        XCTAssertEqual(service.pendingRequest?.id, firstRequest.id)
        service.resolve(firstRequest, decision: .reject)
        let firstDecision = await first.value
        XCTAssertEqual(firstDecision, .reject)
    }

    func testBareDeviceAlwaysAllowCannotAuthorizeANewPIB1Fingerprint() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let requesterID = "bare-policy:\(UUID().uuidString.lowercased())"
        let bareRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "bare-policy-setup",
            declaredDeviceId: requesterID,
            displayName: requesterID,
            kemKeyCount: 1
        )
        let bareDecisionTask = Task { @MainActor in await service.decide(for: bareRequest) }
        _ = try await waitForPendingRequest(service, matching: bareRequest.id)
        service.resolve(bareRequest, decision: .alwaysAllow)
        let bareDecision = await bareDecisionTask.value
        XCTAssertEqual(bareDecision, .allowOnce)
        service.userDismissedCurrentPrompt()

        let pibTask = Task { @MainActor in
            await service.stageTestProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-new-fingerprint",
                requesterDeviceIds: [requesterID],
                displayName: requesterID,
                platform: "iOS",
                verificationCode: "135790",
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: String(repeating: "2", count: 64)
            )
        }
        let pibRequest = try await waitForPendingRequest(service)
        XCTAssertTrue(pibRequest.policyBindingKey?.hasPrefix("PIB-1-requester|") == true)
        service.resolve(pibRequest, decision: .reject)
        let pibDecision = await pibTask.value
        let cleared = await service.clearPolicy(for: requesterID)
        XCTAssertEqual(pibDecision, .reject)
        XCTAssertTrue(cleared)
    }

    func testBareDeviceAlwaysAllowCannotAuthorizeAuthorityBoundPairingRequest() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let deviceID = "bound-policy:\(UUID().uuidString.lowercased())"
        let bareRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "bare-authority-policy-setup",
            declaredDeviceId: deviceID,
            displayName: deviceID,
            kemKeyCount: 1
        )
        let bareDecisionTask = Task { @MainActor in
            await service.decide(for: bareRequest)
        }
        _ = try await waitForPendingRequest(service, matching: bareRequest.id)
        service.resolve(bareRequest, decision: .alwaysAllow)
        let bareDecision = await bareDecisionTask.value
        XCTAssertEqual(bareDecision, .allowOnce)
        service.userDismissedCurrentPrompt()

        let fingerprint = String(repeating: "a", count: 64)
        let boundRequest = PairingTrustApprovalService.Request(
            peerEndpoint: "new-authority",
            declaredDeviceId: deviceID,
            policyBindingKey: try XCTUnwrap(
                PairingTrustApprovalService.policyBindingKey(
                    declaredDeviceId: deviceID,
                    algorithmRawValue: ProtocolSigningAlgorithm.mlDSA65.rawValue,
                    protocolPublicKeyFingerprint: fingerprint
                )
            ),
            displayName: deviceID,
            kemKeyCount: 1
        )
        let boundDecisionTask = Task { @MainActor in
            await service.decide(for: boundRequest)
        }
        _ = try await waitForPendingRequest(service, matching: boundRequest.id)
        service.resolve(boundRequest, decision: .reject)
        let boundDecision = await boundDecisionTask.value
        let cleared = await service.clearPolicy(for: deviceID)
        XCTAssertEqual(boundDecision, .reject)
        XCTAssertTrue(cleared)
    }

    func testInformationalPIBCodeCannotReplaceAnUnresolvedApprovalPrompt() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let request = PairingTrustApprovalService.Request(
            peerEndpoint: "existing-prompt",
            declaredDeviceId: "existing:\(UUID().uuidString.lowercased())",
            displayName: "Existing prompt",
            kemKeyCount: 1
        )
        let decisionTask = Task { @MainActor in await service.decide(for: request) }
        _ = try await waitForPendingRequest(service, matching: request.id)

        service.showProtocolIdentityBindingCode(
            peerEndpoint: "attacker",
            declaredDeviceId: "replacement",
            displayName: "Replacement",
            verificationCode: "123456",
            protocolIdentityFingerprint: String(repeating: "3", count: 64)
        )

        XCTAssertEqual(service.pendingRequest?.id, request.id)
        service.resolve(request, decision: .reject)
        let decision = await decisionTask.value
        XCTAssertEqual(decision, .reject)
    }

    func testAlwaysAllowPolicySaveFailureDowngradesToVisibleAllowOnceWithoutUndoingPin() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let requesterID = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "e", count: 64)
        let transactionId = UUID()
        let requestHash = String(repeating: "7", count: 64)
        let candidateHash = String(repeating: "8", count: 64)
        let sasHash = String(repeating: "9", count: 64)
        let trust = TrustSyncService.shared
        trust.setInMemoryPersistenceForTesting(true)
        try await trust.removeRecordsForTesting(deviceIds: [requesterID])
        await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterID])
        service.setPolicySaveResultOverrideForTesting(false)

        let cleanup: @MainActor () async throws -> Void = {
            service.setPolicySaveResultOverrideForTesting(nil)
            service.userDismissedCurrentPrompt()
            try await trust.removeRecordsForTesting(deviceIds: [requesterID])
            trust.setInMemoryPersistenceForTesting(false)
            await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterID])
        }

        do {
            let approvalTask = Task { @MainActor in
                await service.stageTestProtocolIdentityBindingRequesterApproval(
                    peerEndpoint: "lan-policy-save-failure-test",
                    requesterDeviceIds: [requesterID],
                    displayName: requesterID,
                    platform: "iOS",
                    verificationCode: "112233",
                    requesterProtocolSigningAlgorithm: .mlDSA65,
                    requesterProtocolIdentityFingerprint: fingerprint,
                    transactionId: transactionId,
                    requestHashHex: requestHash,
                    candidateHashHex: candidateHash,
                    sasTranscriptHashHex: sasHash
                )
            }
            let request = try await waitForPendingRequest(service)
            service.resolve(request, decision: .alwaysAllow)

            let approvalDecision = await approvalTask.value
            XCTAssertEqual(approvalDecision, .alwaysAllow)
            let decision = await service.commitProtocolIdentityBindingRequesterApproval(
                decision: approvalDecision,
                transactionId: transactionId,
                requesterDeviceIds: [requesterID],
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint,
                requestHashHex: requestHash,
                candidateHashHex: candidateHash,
                sasTranscriptHashHex: sasHash
            )
            XCTAssertEqual(decision, .allowOnce)
            XCTAssertEqual(service.pendingDecision, .allowOnce)
            XCTAssertNotNil(service.pendingResolutionNotice)
            XCTAssertTrue(
                trust.getTrustRecord(deviceId: requesterID)?
                    .currentPathAuthorityFingerprints.contains(fingerprint) ?? false,
                "The explicit current-session pin must remain authoritative when only permanent policy persistence fails."
            )
            let pinned = await PeerProtocolIdentityBootstrapStore.shared.trustedFingerprints(
                forCandidates: [requesterID]
            )
            XCTAssertTrue(pinned.contains(fingerprint))
            let persistedDecision = await service.persistedPolicyDecision(for: request)
            XCTAssertNil(
                persistedDecision,
                "A failed Always Allow write must not be reported as a permanent policy."
            )
        } catch {
            try await cleanup()
            throw error
        }
        try await cleanup()
    }

    func testDerivedBootstrapCachePersistenceFailureIsVisibleButDoesNotUndoAuthorityCommit() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let requesterID = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "f", count: 64)
        let transactionId = UUID()
        let requestHash = String(repeating: "a", count: 64)
        let candidateHash = String(repeating: "b", count: 64)
        let sasHash = String(repeating: "c", count: 64)
        let trust = TrustSyncService.shared
        let cache = PeerProtocolIdentityBootstrapStore.shared
        trust.setInMemoryPersistenceForTesting(true)
        try await trust.removeRecordsForTesting(deviceIds: [requesterID])
        await cache.clear(deviceIds: [requesterID])
        await cache.setPersistenceResultOverrideForTesting(false)

        let approvalTask = Task { @MainActor in
            await service.stageTestProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-cache-save-failure-test",
                requesterDeviceIds: [requesterID],
                displayName: requesterID,
                platform: "iOS",
                verificationCode: "445566",
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint,
                transactionId: transactionId,
                requestHashHex: requestHash,
                candidateHashHex: candidateHash,
                sasTranscriptHashHex: sasHash
            )
        }
        let request = try await waitForPendingRequest(service)
        service.resolve(request, decision: .allowOnce)
        let approvalDecision = await approvalTask.value
        let decision = await service.commitProtocolIdentityBindingRequesterApproval(
            decision: approvalDecision,
            transactionId: transactionId,
            requesterDeviceIds: [requesterID],
            requesterProtocolSigningAlgorithm: .mlDSA65,
            requesterProtocolIdentityFingerprint: fingerprint,
            requestHashHex: requestHash,
            candidateHashHex: candidateHash,
            sasTranscriptHashHex: sasHash
        )

        XCTAssertEqual(decision, .allowOnce)
        XCTAssertNotNil(service.pendingResolutionNotice)
        XCTAssertTrue(
            trust.getTrustRecord(deviceId: requesterID)?
                .currentPathAuthorityFingerprints.contains(fingerprint) ?? false
        )
        let runtimePins = await cache.trustedFingerprints(forCandidates: [requesterID])
        XCTAssertTrue(runtimePins.contains(fingerprint))

        await cache.setPersistenceResultOverrideForTesting(nil)
        service.userDismissedCurrentPrompt()
        try await trust.removeRecordsForTesting(deviceIds: [requesterID])
        trust.setInMemoryPersistenceForTesting(false)
        await cache.clear(deviceIds: [requesterID])
    }

    func testProtocolIdentityRequesterApprovalWaitsForOperatorBeforeServing() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()

        let requesterId = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "a", count: 64)
        let verificationCode = "123456"
        let transactionId = UUID()
        let requestHash = String(repeating: "d", count: 64)
        let candidateHash = String(repeating: "e", count: 64)
        let sasHash = String(repeating: "f", count: 64)
        let trust = TrustSyncService.shared
        trust.setInMemoryPersistenceForTesting(true)
        try await trust.removeRecordsForTesting(deviceIds: [requesterId])
        await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
        addTeardownBlock { @MainActor [trust] in
            try await trust.removeRecordsForTesting(deviceIds: [requesterId])
            trust.setInMemoryPersistenceForTesting(false)
            await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
        }
        let completion = DecisionRecorder()

        let approvalTask = Task { @MainActor in
            let decision = await service.stageTestProtocolIdentityBindingRequesterApproval(
                peerEndpoint: "lan-test",
                requesterDeviceIds: [requesterId],
                displayName: requesterId,
                platform: "iOS",
                verificationCode: verificationCode,
                requesterProtocolSigningAlgorithm: .mlDSA65,
                requesterProtocolIdentityFingerprint: fingerprint,
                transactionId: transactionId,
                requestHashHex: requestHash,
                candidateHashHex: candidateHash,
                sasTranscriptHashHex: sasHash
            )
            await completion.set(decision)
            return decision
        }

        let request = try await waitForPendingRequest(service)
        try await Task.sleep(nanoseconds: 120_000_000)
        let earlyDecision = await completion.value()
        XCTAssertNil(earlyDecision, "PIB-1 target side must not serve a signed identity response before local requester approval.")

        XCTAssertEqual(service.pendingVerificationCode, verificationCode)
        service.resolve(request, decision: .allowOnce)

        let decision = await approvalTask.value
        XCTAssertEqual(decision, .allowOnce)
        let preCommitTrusted = await PeerProtocolIdentityBootstrapStore.shared.trustedFingerprints(
            forCandidates: [requesterId]
        )
        XCTAssertFalse(
            preCommitTrusted.contains(fingerprint),
            "Operator approval alone must not install a responder-side pin before the signed ACK exists."
        )
        let committedDecision = await service.commitProtocolIdentityBindingRequesterApproval(
            decision: decision,
            transactionId: transactionId,
            requesterDeviceIds: [requesterId],
            requesterProtocolSigningAlgorithm: .mlDSA65,
            requesterProtocolIdentityFingerprint: fingerprint,
            requestHashHex: requestHash,
            candidateHashHex: candidateHash,
            sasTranscriptHashHex: sasHash
        )
        XCTAssertEqual(committedDecision, .allowOnce)
        let trusted = await PeerProtocolIdentityBootstrapStore.shared.trustedFingerprints(
            forCandidates: [requesterId]
        )
        XCTAssertTrue(
            trusted.contains(fingerprint),
            "PIB-1 final-ACK commit must install the requester protocol identity pin."
        )
        XCTAssertTrue(
            trust.getTrustRecord(deviceId: requesterId)?.currentPathAuthorityFingerprints.contains(fingerprint) ?? false,
            "PIB-1 approval must promote requester protocol identity into the authoritative TrustSync record."
        )
    }

    func testMLDSA87RequesterApprovalCommitsExactRawKeyAuthority() async throws {
        let service = PairingTrustApprovalService.shared
        service.userDismissedCurrentPrompt()
        let requesterId = "id:\(UUID().uuidString.lowercased())"
        let publicKey = Data(repeating: 0x87, count: 2_592)
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: publicKey
        )
        let transactionId = UUID()
        let requestHash = String(repeating: "1", count: 64)
        let candidateHash = String(repeating: "2", count: 64)
        let sasHash = String(repeating: "3", count: 64)
        let trust = TrustSyncService.shared
        trust.setInMemoryPersistenceForTesting(true)
        try await trust.removeRecordsForTesting(deviceIds: [requesterId])
        await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])

        do {
            let approvalTask = Task { @MainActor in
                await service.stageTestProtocolIdentityBindingRequesterApproval(
                    peerEndpoint: "lan-ml-dsa-87-test",
                    requesterDeviceIds: [requesterId],
                    displayName: requesterId,
                    platform: "iOS",
                    verificationCode: "870087",
                    requesterProtocolSigningAlgorithm: .mlDSA87,
                    requesterProtocolIdentityFingerprint: fingerprint,
                    requesterProtocolIdentityPublicKey: publicKey,
                    transactionId: transactionId,
                    requestHashHex: requestHash,
                    candidateHashHex: candidateHash,
                    sasTranscriptHashHex: sasHash
                )
            }
            let request = try await waitForPendingRequest(service)
            service.resolve(request, decision: .allowOnce)
            let decision = await approvalTask.value
            XCTAssertEqual(decision, .allowOnce)

            let committed = await service.commitProtocolIdentityBindingRequesterApproval(
                decision: decision,
                transactionId: transactionId,
                requesterDeviceIds: [requesterId],
                requesterProtocolSigningAlgorithm: .mlDSA87,
                requesterProtocolIdentityFingerprint: fingerprint,
                requesterProtocolIdentityPublicKey: publicKey,
                requestHashHex: requestHash,
                candidateHashHex: candidateHash,
                sasTranscriptHashHex: sasHash
            )
            XCTAssertEqual(committed, .allowOnce)
            XCTAssertEqual(
                trust.getTrustRecord(deviceId: requesterId)?
                    .authenticatedProtocolIdentityBinding(for: .mlDSA87)?.publicKey,
                publicKey
            )
        } catch {
            service.userDismissedCurrentPrompt()
            try await trust.removeRecordsForTesting(deviceIds: [requesterId])
            trust.setInMemoryPersistenceForTesting(false)
            await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
            throw error
        }

        service.userDismissedCurrentPrompt()
        try await trust.removeRecordsForTesting(deviceIds: [requesterId])
        trust.setInMemoryPersistenceForTesting(false)
        await PeerProtocolIdentityBootstrapStore.shared.clear(deviceIds: [requesterId])
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

    private func waitForPendingRequest(
        _ service: PairingTrustApprovalService,
        matching expectedID: UUID? = nil,
        timeout: Duration = .seconds(2)
    ) async throws -> PairingTrustApprovalService.Request {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let request = service.pendingRequest,
               expectedID == nil || request.id == expectedID {
                return request
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PairingTrustApprovalTestError.timedOutWaitingForPendingRequest
    }

    private func waitForWaiterCount(
        _ service: PairingTrustApprovalService,
        requestID: UUID,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if service.pendingWaiterCountForTesting(requestID: requestID) == count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PairingTrustApprovalTestError.timedOutWaitingForWaiters
    }
}

@available(macOS 14.0, *)
@MainActor
extension PairingTrustApprovalService {
    /// Test-only PIB-1 v3 approval entry point. Every call receives complete
    /// transcript metadata by default so tests cannot accidentally exercise the
    /// removed pre-v3 approval path.
    func stageTestProtocolIdentityBindingRequesterApproval(
        peerEndpoint: String,
        requesterDeviceIds: [String],
        displayName: String,
        model: String? = nil,
        platform: String? = nil,
        osVersion: String? = nil,
        verificationCode: String,
        requesterProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        requesterProtocolIdentityFingerprint: String,
        requesterProtocolIdentityPublicKey: Data? = nil,
        transactionId: UUID = UUID(),
        requestHashHex: String = String(repeating: "a", count: 64),
        candidateHashHex: String = String(repeating: "b", count: 64),
        sasTranscriptHashHex: String = String(repeating: "c", count: 64)
    ) async -> Decision {
        await stageProtocolIdentityBindingRequesterApproval(
            peerEndpoint: peerEndpoint,
            requesterDeviceIds: requesterDeviceIds,
            displayName: displayName,
            model: model,
            platform: platform,
            osVersion: osVersion,
            verificationCode: verificationCode,
            requesterProtocolSigningAlgorithm: requesterProtocolSigningAlgorithm,
            requesterProtocolIdentityFingerprint: requesterProtocolIdentityFingerprint,
            requesterProtocolIdentityPublicKey: requesterProtocolIdentityPublicKey,
            transactionId: transactionId,
            requestHashHex: requestHashHex,
            candidateHashHex: candidateHashHex,
            sasTranscriptHashHex: sasTranscriptHashHex
        )
    }
}

private enum PairingTrustApprovalTestError: Error {
    case timedOutWaitingForPendingRequest
    case timedOutWaitingForWaiters
}
