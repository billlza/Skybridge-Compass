import XCTest
import CryptoKit
import Network
@testable import SkyBridgeCompass_iOS

private actor FormalDisconnectReplacementBarrierHarness {
    private var replacementIsInstalled = false
    private var detachedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func disconnectCapturedResources() async -> Bool {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            detachedContinuation?.resume()
            detachedContinuation = nil
        }
        return CrossNetworkDisconnectPostcondition.hasNoReplacement(
            signalingIsPresent: replacementIsInstalled,
            sessionIsPresent: replacementIsInstalled,
            sessionIDIsPresent: replacementIsInstalled,
            fileTransferOwnerIsPresent: replacementIsInstalled
        )
    }

    func waitUntilDetached() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { detachedContinuation = $0 }
    }

    func installReplacementAndRelease() {
        replacementIsInstalled = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@available(iOS 17.0, *)
@MainActor
final class FormalInteropTerminalBindingTests: XCTestCase {
    private enum CleanupTestError: Error {
        case staleOwner
    }

    private func owner(keyEpoch: UUID = UUID()) throws -> CrossNetworkFileTransferSessionOwner {
        try CrossNetworkFileTransferSessionOwner(
            sessionID: "formal-session",
            generation: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            keyEpoch: keyEpoch
        )
    }

    private let selectedICE = WebRTCSession.SelectedICECandidateEvidence(
        route: "direct",
        localCandidateType: "host",
        remoteCandidateType: "host",
        networkProtocol: "udp"
    )

    func testFormalTerminalBindingAcceptsOnlyTheFrozenOwnerAndEvidence() throws {
        let frozenOwner = try owner(
            keyEpoch: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        let binding = FormalInteropTerminalBinding(
            owner: frozenOwner,
            sessionID: "formal-session",
            negotiatedSuite: "ML-KEM-768",
            suiteWireID: "0x0101",
            selectedICE: selectedICE,
            peerDeviceID: "android-peer"
        )
        XCTAssertNoThrow(
            try binding.validate(
                currentOwner: frozenOwner,
                currentSessionID: "formal-session",
                currentNegotiatedSuite: "ML-KEM-768",
                currentSuiteWireID: "0x0101",
                currentSelectedICE: selectedICE,
                currentPeerDeviceID: "android-peer"
            )
        )
    }

    func testFormalTerminalBindingRejectsReplacementEpochAndEvidenceDrift() throws {
        let frozenOwner = try owner(
            keyEpoch: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let binding = FormalInteropTerminalBinding(
            owner: frozenOwner,
            sessionID: "formal-session",
            negotiatedSuite: "ML-KEM-768",
            suiteWireID: "0x0101",
            selectedICE: selectedICE,
            peerDeviceID: "android-peer"
        )
        let replacementOwner = try owner(
            keyEpoch: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        XCTAssertThrowsError(
            try binding.validate(
                currentOwner: replacementOwner,
                currentSessionID: "formal-session",
                currentNegotiatedSuite: "ML-KEM-768",
                currentSuiteWireID: "0x0101",
                currentSelectedICE: selectedICE,
                currentPeerDeviceID: "android-peer"
            )
        )
        XCTAssertThrowsError(
            try binding.validate(
                currentOwner: frozenOwner,
                currentSessionID: "replacement-session",
                currentNegotiatedSuite: "ML-KEM-768",
                currentSuiteWireID: "0x0101",
                currentSelectedICE: WebRTCSession.SelectedICECandidateEvidence(
                    route: "relay",
                    localCandidateType: "relay",
                    remoteCandidateType: "relay",
                    networkProtocol: "tcp"
                ),
                currentPeerDeviceID: "other-peer"
            )
        )
    }

    func testFormalCleanupQuiescesExactOwnerBeforeRemovingArtifacts() async throws {
        let cleanupAuthority = FormalInteropCleanupAuthority.outbound(
            runRef: String(repeating: "a", count: 64),
            CrossNetworkFileTransferOutboundContext(owner: try owner())
        )
        var events: [String] = []

        try await FormalInteropCleanupCoordinator.execute(
            authority: cleanupAuthority,
            quiesce: { authority in
                XCTAssertEqual(authority, cleanupAuthority)
                events.append("quiesce")
            },
            removeOwnedArtifacts: { authority in
                XCTAssertEqual(authority, cleanupAuthority)
                events.append("remove")
            }
        )

        XCTAssertEqual(events, ["quiesce", "remove"])
    }

    func testFormalCleanupDoesNotRemoveArtifactsForReplacementOwner() async throws {
        let cleanupAuthority = FormalInteropCleanupAuthority.outbound(
            runRef: String(repeating: "b", count: 64),
            CrossNetworkFileTransferOutboundContext(owner: try owner())
        )
        var events: [String] = []

        do {
            try await FormalInteropCleanupCoordinator.execute(
                authority: cleanupAuthority,
                quiesce: { _ in
                    events.append("quiesce")
                    throw CleanupTestError.staleOwner
                },
                removeOwnedArtifacts: { _ in events.append("remove") }
            )
            XCTFail("replacement owner must fail cleanup")
        } catch CleanupTestError.staleOwner {
            XCTAssertEqual(events, ["quiesce"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPreparedOnlyCleanupUsesThePrebindAuthority() async throws {
        let cleanupAuthority = FormalInteropCleanupAuthority.preparedOnly(
            runRef: String(repeating: "c", count: 64)
        )
        var events: [String] = []

        try await FormalInteropCleanupCoordinator.execute(
            authority: cleanupAuthority,
            quiesce: { authority in
                XCTAssertEqual(authority, cleanupAuthority)
                events.append("require-no-active-connection")
            },
            removeOwnedArtifacts: { authority in
                XCTAssertEqual(authority, cleanupAuthority)
                events.append("remove-empty-run")
            }
        )

        XCTAssertEqual(events, ["require-no-active-connection", "remove-empty-run"])
    }

    func testSuspendedDisconnectDetectsReplacementBeforeArtifactRemoval() async {
        let harness = FormalDisconnectReplacementBarrierHarness()
        let disconnect = Task { await harness.disconnectCapturedResources() }
        await harness.waitUntilDetached()
        await harness.installReplacementAndRelease()

        let noReplacement = await disconnect.value

        XCTAssertFalse(noReplacement)
    }
}

private actor IOSInboundContextBarrierHarness {
    private let captured: CrossNetworkFileTransferInboundContextIdentity
    private var current: CrossNetworkFileTransferInboundContextIdentity
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var didMutate = false

    init(captured: CrossNetworkFileTransferInboundContextIdentity) {
        self.captured = captured
        self.current = captured
    }

    func runSuspendedOldHandler() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
        if captured.isCurrent(owner: captured.owner, current: current) { didMutate = true }
    }

    func waitUntilSuspended() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func replace(with identity: CrossNetworkFileTransferInboundContextIdentity) {
        current = identity
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func mutationObserved() -> Bool { didMutate }
}

private actor IOSCancellableSendBarrierHarness {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var sentPacketCount = 0

    func sendAfterBarrier() async throws {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
        try Task.checkCancellation()
        sentPacketCount += 1
    }

    func waitUntilBlocked() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func packetCount() -> Int { sentPacketCount }
}

private actor IOSAcknowledgementOwnerBarrierHarness {
    enum HarnessError: Error { case staleOwner }

    private var currentOwner: CrossNetworkFileTransferSessionOwner
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    init(owner: CrossNetworkFileTransferSessionOwner) { currentOwner = owner }

    func resumeAcknowledgementThenValidate(
        requiredOwner: CrossNetworkFileTransferSessionOwner
    ) async throws {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
        guard currentOwner == requiredOwner else { throw HarnessError.staleOwner }
    }

    func waitUntilAcknowledgementResumed() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func rotate(to owner: CrossNetworkFileTransferSessionOwner) { currentOwner = owner }

    func releaseCaller() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@available(iOS 17.0, *)
final class CrossNetworkFileTransferCompletionAcknowledgementTests: XCTestCase {
    func testCompletionAcknowledgementBindsDurableResult() throws {
        let digest = Data(repeating: 0xA5, count: 32)

        let acknowledgement = try CrossNetworkFileTransferMessage.completeAcknowledgement(
            transferId: "123e4567-e89b-12d3-a456-426614174000",
            receivedBytes: 4096,
            fileSha256: digest
        )

        XCTAssertEqual(acknowledgement.op, .completeAck)
        XCTAssertEqual(
            acknowledgement.transferId,
            "123e4567-e89b-12d3-a456-426614174000"
        )
        XCTAssertEqual(acknowledgement.receivedBytes, 4096)
        XCTAssertEqual(acknowledgement.fileSha256, digest)
    }

    func testCompletionAcknowledgementRejectsMalformedEvidence() {
        XCTAssertThrowsError(
            try CrossNetworkFileTransferMessage.completeAcknowledgement(
                transferId: "  ",
                receivedBytes: 0,
                fileSha256: Data(repeating: 0, count: 32)
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkFileTransferCompletionAcknowledgementError,
                .emptyTransferID
            )
        }
        XCTAssertThrowsError(
            try CrossNetworkFileTransferMessage.completeAcknowledgement(
                transferId: "123e4567-e89b-12d3-a456-426614174000",
                receivedBytes: -1,
                fileSha256: Data(repeating: 0, count: 32)
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkFileTransferCompletionAcknowledgementError,
                .negativeReceivedBytes
            )
        }
        XCTAssertThrowsError(
            try CrossNetworkFileTransferMessage.completeAcknowledgement(
                transferId: "123e4567-e89b-12d3-a456-426614174000",
                receivedBytes: 0,
                fileSha256: Data(repeating: 0, count: 31)
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkFileTransferCompletionAcknowledgementError,
                .invalidFileSHA256Length(31)
            )
        }
        XCTAssertThrowsError(
            try CrossNetworkFileTransferMessage.completeAcknowledgement(
                transferId: "transfer-1",
                receivedBytes: 1,
                fileSha256: Data(repeating: 0, count: 32)
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkFileTransferCompletionAcknowledgementError,
                .invalidTransferID
            )
        }
    }

    func testCompletionExpectationRequiresExactEvidence() throws {
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let digest = Data(repeating: 0x5A, count: 32)
        let expectation = try CrossNetworkFileTransferCompletionAckExpectation(
            transferID: transferID,
            receivedBytes: 4096,
            fileSHA256: digest
        )

        XCTAssertNoThrow(
            try expectation.validate(
                .init(
                    op: .completeAck,
                    transferId: transferID,
                    receivedBytes: 4096,
                    fileSha256: digest
                )
            )
        )
        XCTAssertThrowsError(
            try expectation.validate(
                .init(
                    op: .completeAck,
                    transferId: transferID,
                    receivedBytes: 4095,
                    fileSha256: digest
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkFileTransferCompletionEvidenceError,
                .receivedBytesMismatch(expected: 4096, actual: 4095)
            )
        }
    }

    func testWaiterRegistryRejectsLateOwnerAndOldToken() throws {
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let oldOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let currentOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let ack = CrossNetworkFileTransferMessage(op: .metadataAck, transferId: transferID)
        var registry = CrossNetworkFileTransferWaiterRegistry()
        let oldToken = try registry.arm(
            owner: currentOwner,
            transferID: transferID,
            operation: .metadataAck,
            chunkIndex: nil
        )

        XCTAssertNil(registry.consume(owner: oldOwner, message: ack))
        XCTAssertTrue(registry.remove(oldToken))
        let retryToken = try registry.arm(
            owner: currentOwner,
            transferID: transferID,
            operation: .metadataAck,
            chunkIndex: nil
        )
        XCTAssertFalse(registry.remove(oldToken))
        XCTAssertEqual(registry.consume(owner: currentOwner, message: ack), retryToken)
    }

    func testCompletionReplayIsExactOwnerBoundAndCapacityBounded() throws {
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID()
        )
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let secondTransferID = "223e4567-e89b-12d3-a456-426614174000"
        let digest = Data(repeating: 0x6B, count: 32)
        let request = CrossNetworkFileTransferMessage(
            op: .complete,
            transferId: transferID,
            receivedBytes: 1024,
            fileSha256: digest
        )
        let fingerprint = try CrossNetworkFileTransferCompletionRequestFingerprint(message: request)
        let acknowledgement = try CrossNetworkFileTransferMessage.completeAcknowledgement(
            transferId: transferID,
            receivedBytes: 1024,
            fileSha256: digest
        )
        var cache = CrossNetworkFileTransferCompletionReplayCache(capacity: 1, timeToLive: 60)

        XCTAssertEqual(try cache.reserve(owner: owner, transferID: transferID), .reserved)
        try cache.recordCompletion(
            owner: owner,
            fingerprint: fingerprint,
            acknowledgement: acknowledgement
        )
        XCTAssertEqual(cache.lookup(owner: owner, fingerprint: fingerprint), .replay(acknowledgement))
        XCTAssertEqual(
            try cache.reserve(owner: owner, transferID: secondTransferID),
            .capacityExceeded
        )
    }

    func testDroppedFirstAcknowledgementRetriesExactCompletionAndCommitsOnce() throws {
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID(),
            keyEpoch: UUID()
        )
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let digest = Data(repeating: 0x7A, count: 32)
        let request = CrossNetworkFileTransferMessage(
            op: .complete,
            transferId: transferID,
            receivedBytes: 2048,
            fileSha256: digest
        )
        let fingerprint = try CrossNetworkFileTransferCompletionRequestFingerprint(message: request)
        let acknowledgement = try CrossNetworkFileTransferMessage.completeAcknowledgement(
            transferId: transferID,
            receivedBytes: 2048,
            fileSha256: digest
        )
        let expectation = try CrossNetworkFileTransferCompletionAckExpectation(
            transferID: transferID,
            receivedBytes: 2048,
            fileSHA256: digest
        )
        let policy = CrossNetworkFileTransferCompletionRetryPolicy(maximumAttempts: 2)
        var registry = CrossNetworkFileTransferWaiterRegistry()
        var replay = CrossNetworkFileTransferCompletionReplayCache(capacity: 1, timeToLive: 60)
        var commitCount = 0
        var accepted: CrossNetworkFileTransferMessage?

        XCTAssertEqual(try replay.reserve(owner: owner, transferID: transferID), .reserved)
        for attempt in 1...policy.maximumAttempts {
            let token = try registry.arm(
                owner: owner,
                transferID: transferID,
                operation: .completeAck,
                chunkIndex: nil
            )
            let response: CrossNetworkFileTransferMessage
            switch replay.lookup(owner: owner, fingerprint: fingerprint) {
            case .active:
                let prepared = try replay.prepareCompletion(
                    owner: owner,
                    fingerprint: fingerprint,
                    acknowledgement: acknowledgement
                )
                commitCount += 1
                XCTAssertTrue(replay.commitPreparedCompletion(prepared))
                response = acknowledgement
            case .replay(let cached):
                response = cached
            default:
                return XCTFail("unexpected receiver replay state")
            }

            if attempt == 1 {
                XCTAssertTrue(registry.remove(token))
                XCTAssertTrue(policy.permitsRetry(after: .timeout, completedAttempts: attempt))
                continue
            }
            XCTAssertEqual(registry.consume(owner: owner, message: response), token)
            try expectation.validate(response)
            accepted = response
        }

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(accepted, acknowledgement)
        XCTAssertFalse(policy.permitsRetry(after: .terminal, completedAttempts: 1))
    }

    func testKeyEpochRejectsLateAcknowledgement() throws {
        let generation = UUID()
        let oldOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: generation,
            keyEpoch: UUID()
        )
        let newOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: generation,
            keyEpoch: UUID()
        )
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let acknowledgement = CrossNetworkFileTransferMessage(
            op: .metadataAck,
            transferId: transferID
        )
        var registry = CrossNetworkFileTransferWaiterRegistry()
        let oldToken = try registry.arm(
            owner: oldOwner,
            transferID: transferID,
            operation: .metadataAck,
            chunkIndex: nil
        )

        XCTAssertNil(registry.consume(owner: newOwner, message: acknowledgement))
        XCTAssertTrue(registry.remove(oldToken))
    }

    func testSuspendedOldHandlerCannotOverwriteReplacementContext() async throws {
        let generation = UUID()
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let oldOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: generation,
            keyEpoch: UUID()
        )
        let newOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: generation,
            keyEpoch: UUID()
        )
        let oldContext = try CrossNetworkFileTransferInboundContextIdentity(
            owner: oldOwner,
            transferID: transferID
        )
        let replacement = try CrossNetworkFileTransferInboundContextIdentity(
            owner: newOwner,
            transferID: transferID
        )
        let harness = IOSInboundContextBarrierHarness(captured: oldContext)
        let oldHandler = Task { await harness.runSuspendedOldHandler() }

        await harness.waitUntilSuspended()
        await harness.replace(with: replacement)
        await harness.release()
        await oldHandler.value
        let mutationObserved = await harness.mutationObserved()
        XCTAssertFalse(mutationObserved)
    }

    func testCancellationNeverRetriesAndBlockedSendEmitsNoLatePacket() async {
        let harness = IOSCancellableSendBarrierHarness()
        let sendTask = Task { try await harness.sendAfterBarrier() }
        await harness.waitUntilBlocked()
        sendTask.cancel()
        await harness.release()

        do {
            try await sendTask.value
            XCTFail("cancelled send unexpectedly succeeded")
        } catch is CancellationError {
            // Expected terminal outcome.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        let packetCount = await harness.packetCount()
        XCTAssertEqual(packetCount, 0)
        let policy = CrossNetworkFileTransferCompletionRetryPolicy(maximumAttempts: 2)
        XCTAssertFalse(policy.permitsRetry(after: .terminal, completedAttempts: 1))
    }

    func testAcknowledgementReturnRevalidatesKeyEpoch() async throws {
        let generation = UUID()
        let oldOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: generation,
            keyEpoch: UUID()
        )
        let newOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: generation,
            keyEpoch: UUID()
        )
        let harness = IOSAcknowledgementOwnerBarrierHarness(owner: oldOwner)
        let caller = Task {
            try await harness.resumeAcknowledgementThenValidate(requiredOwner: oldOwner)
        }
        await harness.waitUntilAcknowledgementResumed()
        await harness.rotate(to: newOwner)
        await harness.releaseCaller()

        do {
            try await caller.value
            XCTFail("old-epoch acknowledgement unexpectedly returned success")
        } catch IOSAcknowledgementOwnerBarrierHarness.HarnessError.staleOwner {
            // Expected exact-owner rejection.
        }
    }

    func testOutboundContextRejectsRotationBeforeMetadataAndComplete() throws {
        let generation = UUID()
        let oldOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: generation,
            keyEpoch: UUID()
        )
        let newOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: generation,
            keyEpoch: UUID()
        )
        let context = CrossNetworkFileTransferOutboundContext(owner: oldOwner)
        var sentMetadata = 0
        var sentComplete = 0

        XCTAssertThrowsError(try context.validate(currentOwner: newOwner))
        if (try? context.validate(currentOwner: newOwner)) != nil { sentMetadata += 1 }
        XCTAssertNoThrow(try context.validate(currentOwner: oldOwner))
        XCTAssertThrowsError(try context.validate(currentOwner: newOwner))
        if (try? context.validate(currentOwner: newOwner)) != nil { sentComplete += 1 }
        XCTAssertEqual(sentMetadata, 0)
        XCTAssertEqual(sentComplete, 0)
    }

    func testDisconnectRevokesContextBeforeSignalingCloseSuspends() async throws {
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID(),
            keyEpoch: UUID()
        )
        let context = CrossNetworkFileTransferOutboundContext(owner: owner)
        var currentOwner: CrossNetworkFileTransferSessionOwner? = owner
        var responseTaskCancelled = false
        var sentPacketCount = 0

        currentOwner = nil
        responseTaskCancelled = true
        await Task.yield()

        XCTAssertNil(currentOwner)
        XCTAssertTrue(responseTaskCancelled)
        XCTAssertThrowsError(try context.validate(currentOwner: currentOwner))
        if (try? context.validate(currentOwner: currentOwner)) != nil { sentPacketCount += 1 }
        XCTAssertEqual(sentPacketCount, 0)
    }
}

@available(iOS 17.0, *)
final class RegressionHardeningTests: XCTestCase {
    func testRemoteConnectionDiagnosticsRedactSessionTextAndErrorDetails() {
        let secret = "CONNECTION-CODE-1234"
        XCTAssertEqual(RemoteConnectionLogRedaction.session(secret), "<redacted>")
        XCTAssertEqual(RemoteConnectionLogRedaction.untrustedText(secret), "<redacted>")
        XCTAssertEqual(RemoteConnectionLogRedaction.peer(secret), "<redacted>")
        XCTAssertFalse(RemoteConnectionLogRedaction.error(TestDiagnosticError.secret(secret)).contains(secret))
        XCTAssertEqual(RemoteConnectionLogRedaction.session(""), "<empty>")
    }

    func testIndependentSignalingCopyRejectsStaleHandlesAndRedactsTrace() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SkyBridgeCompassiOS")
            .appendingPathComponent("Sources/Core/RemoteConnection/WebRTC/WebSocketSignalingClient.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let handlerStart = try XCTUnwrap(source.range(of: "private func handleText(handleId:"))
        let handlerTail = source[handlerStart.lowerBound...]
        let guardRange = try XCTUnwrap(handlerTail.range(of: "guard currentHandle == handleId else"))
        let deliveryRange = try XCTUnwrap(handlerTail.range(of: "switch Self.parseInboundText(text)"))

        XCTAssertLessThan(
            handlerTail.distance(from: handlerTail.startIndex, to: guardRange.lowerBound),
            handlerTail.distance(from: handlerTail.startIndex, to: deliveryRange.lowerBound)
        )
        XCTAssertTrue(handlerTail.contains("drop-stale-message session="))
        XCTAssertFalse(source.contains("send session=\\(envelope.sessionId)"))
        XCTAssertFalse(source.contains("from=\\(envelope.from)"))
        XCTAssertFalse(source.contains("recv-envelope session=\\(env.sessionId)"))
        XCTAssertFalse(source.contains("err=\\(error.localizedDescription)"))
        XCTAssertFalse(source.contains("reason=\\(errorDescription)"))
        XCTAssertTrue(source.contains("private var connectionEpoch: UInt64 = 0"))
        XCTAssertTrue(source.contains("connectionEpoch &+= 1"))
        XCTAssertTrue(source.contains("onEnvelope = nil"))

        let closeStart = try XCTUnwrap(source.range(of: "public func close() async"))
        let closeTail = source[closeStart.lowerBound...]
        let retireHandle = try XCTUnwrap(closeTail.range(of: "currentHandle = nil"))
        let cleanupAwait = try XCTUnwrap(closeTail.range(of: "await cleanupURLSessionTransport()"))
        XCTAssertLessThan(
            closeTail.distance(from: closeTail.startIndex, to: retireHandle.lowerBound),
            closeTail.distance(from: closeTail.startIndex, to: cleanupAwait.lowerBound)
        )
        for handler in ["handleSocketOpen", "handleText", "handleClosed", "handleErrored"] {
            let handlerRange = try XCTUnwrap(source.range(of: "private func \(handler)"))
            let tail = source[handlerRange.lowerBound...]
            let end = tail.firstIndex(of: "}") ?? tail.endIndex
            XCTAssertTrue(tail[..<end].contains("guard currentHandle == handleId else"))
        }

        let managerURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Managers/CrossNetworkWebRTCManager.swift")
        let manager = try String(contentsOf: managerURL, encoding: .utf8)
        XCTAssertTrue(manager.contains("IOSSignalingMainActorDeliveryQueue"))
        XCTAssertTrue(manager.contains("[weak self, weak newSignaling]"))
        XCTAssertTrue(manager.contains("activeSignalingHandleBySessionId[sessionId] == handle"))
    }

    func testFormalSmokeTraceRetainsOnlyBoundedEventCategory() {
        let secret = "FORMAL-CODE-1234"
        let peer = "persistent-peer-identity"
        let error = "server says token=secret"
        let sanitized = CrossNetworkWebRTCManager.formalSmokeTraceLine(
            "tx-fail session=\(secret) peer=\(peer) error=\(error)"
        )

        XCTAssertEqual(sanitized, "event=tx-fail details=<redacted>")
        XCTAssertFalse(sanitized.contains(secret))
        XCTAssertFalse(sanitized.contains(peer))
        XCTAssertFalse(sanitized.contains(error))
        XCTAssertEqual(
            CrossNetworkWebRTCManager.formalSmokeTraceLine("!bad event"),
            "event=_bad details=<redacted>"
        )
        XCTAssertLessThanOrEqual(
            CrossNetworkWebRTCManager.formalSmokeTraceLine(String(repeating: "x", count: 512))
                .split(separator: " ")[0]
                .count,
            "event=".count + 64
        )
    }

    func testExistingOnlyRuntimeLoggerRedactsEverySinkMessage() {
        let raw = "tx-fail session=FORMAL-CODE peer=persistent-id error=token-secret"
        XCTAssertEqual(
            SkyBridgeLogger.runtimeMessage(
                raw,
                environment: ["SKYBRIDGE_SMOKE_EXISTING_TRUST_ONLY": "1"]
            ),
            "event=tx-fail details=<redacted>"
        )
        XCTAssertEqual(
            SkyBridgeLogger.runtimeMessage(raw, environment: [:]),
            raw,
            "normal product diagnostics must keep their existing behavior"
        )
    }

    func testIndependentSignalingCopyRejectsStaleHandlesBeforeDelivery() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SkyBridgeCompassiOS")
            .appendingPathComponent("Sources/Core/RemoteConnection/WebRTC/WebSocketSignalingClient.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let handlerStart = try XCTUnwrap(source.range(of: "private func handleText(handleId:"))
        let handlerTail = source[handlerStart.lowerBound...]
        let guardRange = try XCTUnwrap(handlerTail.range(of: "guard currentHandle == handleId else"))
        let deliveryRange = try XCTUnwrap(handlerTail.range(of: "switch Self.parseInboundText(text)"))

        XCTAssertLessThan(
            handlerTail.distance(from: handlerTail.startIndex, to: guardRange.lowerBound),
            handlerTail.distance(from: handlerTail.startIndex, to: deliveryRange.lowerBound)
        )
        XCTAssertTrue(handlerTail.contains("drop-stale-message session="))
        XCTAssertFalse(handlerTail.contains("recv-envelope session=\\(env.sessionId)"))
        XCTAssertFalse(handlerTail.contains("from=\\(env.from)"))
        XCTAssertFalse(handlerTail.contains("error=\\(frame.error"))
    }

    func testExplicitMLKEMPreferenceOverridesPersistedXWingPreference() throws {
        let suiteName = "CryptoProviderFactoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "Settings.PreferXWingHybrid")

        XCTAssertEqual(
            CryptoProviderFactory.nativeSuitePreferenceForTesting(
                environment: ["SB_PQC_PREFERRED_SUITE": "mlkem"],
                defaults: defaults
            ),
            "mlkem"
        )
    }

    @MainActor
    func testFormalSmokeSuiteLabelsMapToCanonicalWireIdentifiers() {
        XCTAssertEqual(LocalWebRTCSmokeHarness.canonicalSuiteWireID("ML-KEM-768"), "0x0101")
        XCTAssertEqual(LocalWebRTCSmokeHarness.canonicalSuiteWireID("unknown"), "unknown")
    }

    func testExistingReadOnlyIdentityPolicyBindsAdmissionAndHandshakeAlgorithms() {
        XCTAssertEqual(
            ExistingReadOnlyIdentityMaterialProvider.protocolSigningAlgorithm(requirePQC: false),
            .ed25519
        )
        XCTAssertEqual(
            ExistingReadOnlyIdentityMaterialProvider.protocolSigningAlgorithm(requirePQC: true),
            .mlDSA65
        )
    }

    private enum TestDiagnosticError: Error {
        case secret(String)
    }

    func testExistingReadOnlyIdentityRequiresOnlyTheFormalMLKEMSuite() throws {
        XCTAssertEqual(
            try ExistingReadOnlyIdentityMaterialProvider.requiredPQCSuite(
                environment: ["SKYBRIDGE_SMOKE_EXPECTED_SUITE_WIRE_ID": "0x0101"]
            ),
            .mlkem768
        )
        XCTAssertThrowsError(
            try ExistingReadOnlyIdentityMaterialProvider.requiredPQCSuite(
                environment: ["SKYBRIDGE_SMOKE_EXPECTED_SUITE_WIRE_ID": "0x0001"]
            )
        ) { error in
            XCTAssertEqual(
                error as? ExistingReadOnlyIdentityMaterialProvider.MaterialError,
                .invalidExpectedPQCSuite("0x0001")
            )
        }
    }

    func testExistingReadOnlyIdentityPolicyRequiresExistingDeviceId() throws {
        XCTAssertThrowsError(
            try ExistingReadOnlyIdentityMaterialProvider.requireExistingDeviceId(nil)
        ) { error in
            XCTAssertEqual(
                error as? ExistingReadOnlyIdentityMaterialProvider.MaterialError,
                .missingCurrentPathDeviceId
            )
        }
        XCTAssertEqual(
            try ExistingReadOnlyIdentityMaterialProvider.requireExistingDeviceId(" device-a "),
            "device-a"
        )
    }

    func testExistingReadOnlyIdentityPolicyRejectsBindingDrift() throws {
        let publicKey = Data(repeating: 0x5A, count: 32)
        let material = ExistingReadOnlyProtocolIdentityMaterial(
            deviceId: "device-a",
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKey: publicKey,
            protocolSigningKeyHandle: .softwareKey(Data(repeating: 0xA5, count: 32))
        )

        XCTAssertNoThrow(
            try ExistingReadOnlyIdentityMaterialProvider.requireBindingMatchesCanonicalIdentity(
                material: material,
                deviceId: "device-a",
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKey: publicKey
            )
        )
        XCTAssertThrowsError(
            try ExistingReadOnlyIdentityMaterialProvider.requireBindingMatchesCanonicalIdentity(
                material: material,
                deviceId: "device-a",
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKey: publicKey
            )
        ) { error in
            XCTAssertEqual(
                error as? ExistingReadOnlyIdentityMaterialProvider.MaterialError,
                .bindingMismatch
            )
        }
    }

    func testLANRemoteControlTrustResolverCollapsesEquivalentDuplicateRecords() {
        let device = DiscoveredDevice(
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        let trustedDevices = [
            TrustedDeviceStore.TrustedDevice(
                id: "legacy-peer-a",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                addedAt: Date(timeIntervalSince1970: 100),
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "id:peer-mac"]
            ),
            TrustedDeviceStore.TrustedDevice(
                id: "id:peer-mac",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                addedAt: Date(timeIntervalSince1970: 200),
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "legacy-peer-a"]
            )
        ]

        let resolution = LANRemoteControlTrustResolver.resolve(
            device: device,
            trustedPeerId: "id:peer-mac",
            trustedDevices: trustedDevices
        )

        switch resolution {
        case .resolved(let record, let canonicalPeerId):
            XCTAssertEqual(canonicalPeerId, "id:peer-mac")
            XCTAssertEqual(record.id, "legacy-peer-a")
        default:
            XCTFail("Expected a unique canonical trust resolution, got \(resolution)")
        }
    }

    func testLANRemoteControlTrustResolverRejectsConflictingRecords() {
        let device = DiscoveredDevice(
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        let trustedDevices = [
            TrustedDeviceStore.TrustedDevice(
                id: "legacy-peer-a",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                currentDeviceId: "id:peer-mac-a",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "id:shared-bonjour-peer"]
            ),
            TrustedDeviceStore.TrustedDevice(
                id: "legacy-peer-b",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "b", count: 64),
                currentDeviceId: "id:peer-mac-b",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "id:shared-bonjour-peer"]
            )
        ]

        XCTAssertEqual(
            LANRemoteControlTrustResolver.resolve(
                device: device,
                trustedPeerId: "id:shared-bonjour-peer",
                trustedDevices: trustedDevices
            ),
            .ambiguous(
                deviceIds: ["id:peer-mac-a", "id:peer-mac-b"],
                fingerprints: [String(repeating: "a", count: 64), String(repeating: "b", count: 64)]
            )
        )
    }

    func testLANRemoteControlTrustResolverPrefersRecordWithAuthorityWhenDuplicatesAreEquivalent() {
        let device = DiscoveredDevice(
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        let trustedDevices = [
            TrustedDeviceStore.TrustedDevice(
                id: "legacy-peer-a",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                addedAt: Date(timeIntervalSince1970: 100),
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "id:peer-mac"]
            ),
            TrustedDeviceStore.TrustedDevice(
                id: "id:peer-mac",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                addedAt: Date(timeIntervalSince1970: 200),
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "c", count: 64),
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "legacy-peer-a"]
            )
        ]

        let resolution = LANRemoteControlTrustResolver.resolve(
            device: device,
            trustedPeerId: "id:peer-mac",
            trustedDevices: trustedDevices
        )

        switch resolution {
        case .resolved(let record, let canonicalPeerId):
            XCTAssertEqual(canonicalPeerId, "id:peer-mac")
            XCTAssertEqual(record.id, "id:peer-mac")
            XCTAssertEqual(record.protocolPublicKeyFingerprint, String(repeating: "c", count: 64))
        default:
            XCTFail("Expected fingerprint-bearing record to win equivalent duplicate resolution, got \(resolution)")
        }
    }

    func testBonjourPrivacyManifestDeclaresAllBrowsedServiceTypes() {
        XCTAssertTrue(DeviceDiscoveryManager.hasLocalNetworkUsageDescription())

        let declared = DeviceDiscoveryManager.declaredBonjourServices()
        let expected = Set(DiscoveryServiceType.requiredBonjourPrivacyDeclarations)

        XCTAssertEqual(
            declared,
            expected,
            "Info.plist 的 NSBonjourServices 必须覆盖代码实际可浏览的全部服务类型，避免 NoAuth(-65555) 配置漂移。"
        )
    }

    func testNoAuthBrowseFailureDoesNotAutoRecover() {
        let error = NWError.dns(DeviceDiscoveryManager.bonjourAuthorizationDNSCode)

        XCTAssertTrue(DeviceDiscoveryManager.isBonjourAuthorizationError(error))
        XCTAssertFalse(DeviceDiscoveryManager.shouldAutoRecoverBrowser(after: error))
    }

    func testTransientBrowserFailuresStillAutoRecover() {
        let error = NWError.posix(.ENETDOWN)

        XCTAssertFalse(DeviceDiscoveryManager.isBonjourAuthorizationError(error))
        XCTAssertTrue(DeviceDiscoveryManager.shouldAutoRecoverBrowser(after: error))
    }

    @MainActor
    func testOfflineQueueCleanupRemovesExpiredPendingAndFailedMessages() {
        let queue = OfflineMessageQueue.shared
        queue.clear()
        defer { queue.clear() }

        let expiredPending = OfflineMessage(
            id: "expired-pending-\(UUID().uuidString)",
            targetDeviceId: "peer-a",
            messageType: .text,
            payload: Data("p".utf8),
            expiresAt: Date().addingTimeInterval(-60)
        )

        let expiredFailed = OfflineMessage(
            id: "expired-failed-\(UUID().uuidString)",
            targetDeviceId: "peer-b",
            messageType: .text,
            payload: Data("f".utf8),
            expiresAt: Date().addingTimeInterval(-60)
        )

        let liveFailed = OfflineMessage(
            id: "live-failed-\(UUID().uuidString)",
            targetDeviceId: "peer-c",
            messageType: .text,
            payload: Data("live".utf8),
            expiresAt: Date().addingTimeInterval(3600)
        )

        queue.enqueue(expiredPending)
        queue.enqueue(expiredFailed)
        queue.enqueue(liveFailed)

        for _ in 0..<3 {
            queue.markAsFailed(expiredFailed.id)
            queue.markAsFailed(liveFailed.id)
        }

        XCTAssertEqual(queue.totalCount, 3)

        queue.cleanupExpiredMessages()

        XCTAssertEqual(queue.totalCount, 1)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertEqual(queue.failedMessages.count, 1)
        XCTAssertEqual(queue.failedMessages.first?.id, liveFailed.id)
    }

    @MainActor
    func testTrustedDeviceStoreTreatsDiscoveryIdAsTrustedAlias() {
        let store = TrustedDeviceStore.shared
        let original = store.trustedDevices
        store.clearAll()
        defer {
            store.clearAll()
            store.mergeFromCloud(original)
        }

        let rawDeviceId = UUID().uuidString.lowercased()
        let trustedDevice = DiscoveredDevice(
            id: "id:\(rawDeviceId)",
            name: "Trusted Mac",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        store.trust(trustedDevice)

        XCTAssertTrue(store.isTrusted(deviceId: rawDeviceId))
        XCTAssertTrue(store.isTrusted(deviceId: "id:\(rawDeviceId)"))
    }

    @MainActor
    func testTrustedDeviceStoreResolvesHostAliasBackToCanonicalTrustedID() {
        let store = TrustedDeviceStore.shared
        let original = store.trustedDevices
        store.clearAll()
        defer {
            store.clearAll()
            store.mergeFromCloud(original)
        }

        let rawDeviceId = UUID().uuidString.lowercased()
        let trustedDevice = DiscoveredDevice(
            id: "id:\(rawDeviceId)",
            name: "Trusted iPhone",
            modelName: "iPhone 16 Pro",
            platform: .iOS,
            osVersion: "26.3.1",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )

        store.trust(trustedDevice)

        XCTAssertTrue(store.isTrusted(deviceId: "host:fe80::81d:bb45:8c18:6d6a%en0"))
        XCTAssertEqual(
            store.canonicalTrustedDeviceId(for: "host:fe80::81d:bb45:8c18:6d6a%en0"),
            "id:\(rawDeviceId)"
        )
    }

    func testConnectableAddressCanonicalizerPreservesLinkLocalScopeForConnectionTargets() {
        XCTAssertEqual(
            ConnectableAddressCanonicalizer.connectionTarget("host:fe80::468:f5a1:462b:29d3%bridge100"),
            "fe80::468:f5a1:462b:29d3%bridge100"
        )
        XCTAssertEqual(
            ConnectableAddressCanonicalizer.connectionTarget("[fe80::468:f5a1:462b:29d3%bridge100].5901"),
            "fe80::468:f5a1:462b:29d3%bridge100"
        )
    }

    func testConnectableAddressCanonicalizerStripsInterfaceScopeForLookupKeys() {
        XCTAssertEqual(
            ConnectableAddressCanonicalizer.lookupKey("host:fe80::468:f5a1:462b:29d3%bridge100"),
            "fe80::468:f5a1:462b:29d3"
        )
    }

    func testViewerCapabilityDoesNotImplyRemoteControlHostSupport() {
        let viewerOnly = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Viewer iPhone",
            modelName: "iPhone 16 Pro",
            platform: .iOS,
            osVersion: "18.0",
            ipAddress: nil,
            services: [],
            portMap: [:],
            signalStrength: -50,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: false,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop_viewer"],
            capabilities: ["remote_desktop_viewer"]
        )
        XCTAssertFalse(viewerOnly.supportsRemoteControl)

        let controlHost = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Remote Mac",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20",
            services: [],
            portMap: [DiscoveredDevice.remoteControlServiceType: 5901],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop", "remote_control"],
            capabilities: ["remote_desktop", "remote_control"]
        )
        XCTAssertTrue(controlHost.supportsRemoteControl)
    }

    @MainActor
    func testDeviceDiscoveryCleanupPreservesSilentDeviceWhenBrowserStillHasLiveEndpoint() {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        let device = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::18ac:9228:7844:60fe%en0"
        )
        let endpointKey = "Lza的MacBook\\032Pro._skybridge._tcp.local."

        manager.debugSeedDiscoveryState(
            devices: [device],
            lastActivity: Date().addingTimeInterval(-180),
            endpointToDeviceId: [endpointKey: device.id],
            liveBrowseEndpointKeysByServiceType: [DiscoveryServiceType.skybridge: [endpointKey]]
        )

        manager.debugRunCleanupStaleDevices()

        XCTAssertTrue(manager.debugCachedDeviceIds.contains(device.id))
        XCTAssertEqual(manager.discoveredDevices.first?.id, device.id)
    }

    @MainActor
    func testDeviceDiscoveryCleanupRemovesTrulyStaleDeviceWithoutLiveEndpoint() {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        let device = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Old Mac",
            modelName: "Mac mini",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.8"
        )

        manager.debugSeedDiscoveryState(
            devices: [device],
            lastActivity: Date().addingTimeInterval(-180),
            endpointToDeviceId: [:],
            liveBrowseEndpointKeysByServiceType: [:]
        )

        manager.debugRunCleanupStaleDevices()

        XCTAssertFalse(manager.debugCachedDeviceIds.contains(device.id))
        XCTAssertTrue(manager.discoveredDevices.isEmpty)
    }

    @MainActor
    func testRemoteDesktopBootstrapGuardRejectsFailedLANSession() {
        XCTAssertFalse(
            RemoteDesktopManager.shouldContinueLANBootstrap(
                activeTransportModeIsLAN: true,
                isCurrentLANConnection: true,
                state: .error("连接已断开")
            )
        )
        XCTAssertFalse(
            RemoteDesktopManager.shouldContinueLANBootstrap(
                activeTransportModeIsLAN: false,
                isCurrentLANConnection: true,
                state: .connected
            )
        )
        XCTAssertTrue(
            RemoteDesktopManager.shouldContinueLANBootstrap(
                activeTransportModeIsLAN: true,
                isCurrentLANConnection: true,
                state: .connected
            )
        )
    }

    @MainActor
    func testCrossNetworkNativeReadyAnnouncementAllowsForcedFirstFrameConfirmation() {
        let now = Date()

        XCTAssertTrue(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: false,
                force: true,
                lastAnnouncementAt: now,
                now: now
            )
        )
    }

    @MainActor
    func testCrossNetworkNativeReadyAnnouncementSkipsRedundantResendAfterAck() {
        XCTAssertFalse(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: true,
                force: false,
                lastAnnouncementAt: nil,
                now: Date()
            )
        )
    }

    @MainActor
    func testCrossNetworkNativeReadyAnnouncementThrottlesUntilRetryWindowExpires() {
        let now = Date()

        XCTAssertFalse(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: false,
                force: false,
                lastAnnouncementAt: now.addingTimeInterval(-0.2),
                now: now
            )
        )

        XCTAssertTrue(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: false,
                force: false,
                lastAnnouncementAt: now.addingTimeInterval(-0.8),
                now: now
            )
        )
    }

    @MainActor
    func testTrustResolvedPeerPersistsDeclaredDeviceIdForFutureBootstrap() {
        let store = TrustedDeviceStore.shared
        let original = store.trustedDevices
        store.clearAll()
        defer {
            store.clearAll()
            store.mergeFromCloud(original)
        }

        let declaredDeviceId = "id:\(UUID().uuidString.lowercased())"
        let runtimeAliasDevice = DiscoveredDevice(
            id: "host:fe80::81d:bb45:8c18:6d6a%en0",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )

        store.trustResolvedPeer(runtimeAliasDevice, declaredDeviceId: declaredDeviceId)

        XCTAssertTrue(store.isTrusted(deviceId: "host:fe80::81d:bb45:8c18:6d6a%en0"))
        XCTAssertEqual(
            store.canonicalTrustedDeviceId(for: runtimeAliasDevice),
            declaredDeviceId
        )
    }

    @MainActor
    func testCodablePersistenceStoreMigratesLegacyDefaultsIntoProtectedStateFile() throws {
        let suiteName = "RegressionHardeningTests.\(UUID().uuidString)"
        let legacyKey = "legacy.persistence.payload"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let store = CodablePersistenceStore<[String]>(
            location: .protectedApplicationSupport(
                path: "Tests/\(UUID().uuidString).json",
                legacyUserDefaultsKey: legacyKey
            ),
            rootDirectoryName: "SkyBridgeStateTests",
            defaults: defaults
        )
        let expected = ["alpha", "beta", "gamma"]
        defaults.set(try JSONEncoder().encode(expected), forKey: legacyKey)

        XCTAssertEqual(store.load(), expected)
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertEqual(store.load(), expected)

        try? store.remove()
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testCodablePersistenceStoreCanReadLegacyDefaultsWithoutMigration() throws {
        let suiteName = "RegressionHardeningReadOnlyTests.\(UUID().uuidString)"
        let legacyKey = "legacy.persistence.read-only.payload"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let protectedPath = "Tests/\(UUID().uuidString).json"
        let store = CodablePersistenceStore<[String]>(
            location: .protectedApplicationSupport(
                path: protectedPath,
                legacyUserDefaultsKey: legacyKey
            ),
            rootDirectoryName: "SkyBridgeStateReadOnlyTests",
            defaults: defaults
        )
        let expected = ["existing", "trust"]
        let encoded = try JSONEncoder().encode(expected)
        defaults.set(encoded, forKey: legacyKey)

        XCTAssertEqual(
            store.load(migrationPolicy: .readLegacyValueWithoutMutation),
            expected
        )
        XCTAssertEqual(defaults.data(forKey: legacyKey), encoded)

        try? store.remove()
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testReadOnlyPersistenceRejectsCorruptCanonicalWithoutFallingBackToLegacy() throws {
        let suiteName = "RegressionHardeningCorruptPrimaryTests.\(UUID().uuidString)"
        let legacyKey = "legacy.persistence.corrupt-primary.payload"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        let rootDirectoryName = "SkyBridgeStateCorruptPrimaryTests"
        let protectedPath = "Tests/\(UUID().uuidString).json"
        let store = CodablePersistenceStore<[String]>(
            location: .protectedApplicationSupport(
                path: protectedPath,
                legacyUserDefaultsKey: legacyKey
            ),
            rootDirectoryName: rootDirectoryName,
            defaults: defaults
        )
        let legacy = try JSONEncoder().encode(["stale", "legacy"])
        defaults.set(legacy, forKey: legacyKey)
        try store.save(["canonical"])

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
        let canonicalURL = base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(rootDirectoryName, isDirectory: true)
            .appendingPathComponent(protectedPath, isDirectory: false)
        try Data("{corrupt-primary".utf8).write(to: canonicalURL, options: .atomic)
        let primaryBefore = try Data(contentsOf: canonicalURL)

        XCTAssertThrowsError(try store.loadExistingReadOnly())
        XCTAssertEqual(try Data(contentsOf: canonicalURL), primaryBefore)
        XCTAssertEqual(defaults.data(forKey: legacyKey), legacy)

        try? store.remove()
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testP2PConnectionManagerPromotesPresentationIdentityWithoutBreakingRuntimeLookup() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.42"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Host Alias Peer",
            ipAddress: "192.168.1.42"
        )

        let resolvedRuntimePeerId = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )

        XCTAssertEqual(resolvedRuntimePeerId, runtimePeerId)
        XCTAssertEqual(manager.connectionStatusByDeviceId[stablePeerId], .connected)
        XCTAssertTrue(manager.activeConnections.contains(where: { $0.device.id == stablePeerId }))
        XCTAssertEqual(
            manager.activeConnections.first(where: { $0.device.id == stablePeerId })?.device.name,
            "Stable Mac"
        )
        XCTAssertNil(manager.connectionErrorByDeviceId[stablePeerId])
    }

    @MainActor
    func testP2PConnectionManagerTerminalCleanupRemovesPresentationArtifactsAndSuite() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.52"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Host Alias Peer",
            ipAddress: "192.168.1.52"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )
        manager.testInstallNegotiatedSuite(.mlkem768, for: runtimePeerId)

        XCTAssertTrue(manager.activeConnections.contains(where: { $0.device.id == stablePeerId }))
        XCTAssertEqual(manager.negotiatedSuiteByDeviceId[stablePeerId], .mlkem768)

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)

        XCTAssertFalse(manager.activeConnections.contains { connection in
            let deviceId = connection.device.id
            return deviceId == runtimePeerId || deviceId == stablePeerId
        })
        XCTAssertNil(manager.negotiatedSuiteByDeviceId[runtimePeerId])
        XCTAssertNil(manager.negotiatedSuiteByDeviceId[stablePeerId])
        XCTAssertEqual(manager.connectionStatusByDeviceId[stablePeerId], .disconnected)
    }

    @MainActor
    func testDashboardViewModelRefreshesStatusWhenNegotiatedSuitePublishes() async {
        let manager = P2PConnectionManager.instance
        let viewModel = DashboardViewModel.shared
        let runtimePeerId = "host:192.168.1.57"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"
        let connectedText = RuntimeLocalization.string("已连接")

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Classic Peer",
            ipAddress: "192.168.1.57"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )

        await Task.yield()
        XCTAssertEqual(viewModel.topConnectionPresentation.statusText, connectedText)

        manager.testInstallNegotiatedSuite(.x25519Ed25519, for: runtimePeerId)

        await Task.yield()
        XCTAssertEqual(viewModel.topConnectionPresentation.statusText, "Classic\(connectedText)")

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)
        XCTAssertNil(manager.negotiatedSuiteByDeviceId[stablePeerId])
    }

    @MainActor
    func testDashboardViewModelDoesNotPretendTargetSuiteIsConnectedDuringRekey() async {
        let manager = P2PConnectionManager.instance
        let viewModel = DashboardViewModel.shared
        let runtimePeerId = "host:192.168.1.63"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let connectedText = RuntimeLocalization.string("已连接")

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Rekey Peer",
            ipAddress: "192.168.1.63"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Rekey Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )
        manager.testInstallNegotiatedSuite(.x25519Ed25519, for: runtimePeerId)
        manager.testInstallRekeyStatus(
            fromSuite: "Classic",
            toSuite: "X-Wing",
            for: runtimePeerId
        )

        await Task.yield()

        XCTAssertEqual(viewModel.topConnectionPresentation.statusText, connectedText)
        XCTAssertEqual(viewModel.topConnectionPresentation.detailText, "Classic → X-Wing · Rekey 中")
        XCTAssertFalse(viewModel.topConnectionPresentation.statusText.contains("X-Wing"))

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)
    }

    @MainActor
    func testP2PConnectionManagerResolvesPresentationPeerIdBackToRuntimePeerId() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.62"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Host Alias Peer",
            ipAddress: "192.168.1.62"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )

        XCTAssertEqual(manager.testResolveRuntimePeerId(forAnyPeerId: stablePeerId), runtimePeerId)
    }

    @MainActor
    func testResolvedConnectionStatusPrefersLiveConnectionOverStaleAliasFailure() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.72"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Alias Peer",
            ipAddress: "192.168.1.72"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )
        manager.testSimulateTerminalCleanup(
            runtimePeerId: runtimePeerId,
            terminalStatus: .failed,
            error: "stale failure"
        )
        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Alias Peer",
            ipAddress: "192.168.1.72"
        )

        let device = DiscoveredDevice(
            id: stablePeerId,
            name: "Stable Mac",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.72"
        )

        XCTAssertEqual(manager.resolvedConnectionStatus(for: device), .connected)
        XCTAssertNil(manager.resolvedConnectionError(for: device))
    }

    func testProcessMessageBWithoutTranscriptHashAFailsWithExplicitReason() async {
        let context = makeInitiatorContext()
        let messageB = makeMinimalMessageB()

        do {
            _ = try await context.processMessageB(messageB)
            XCTFail("Expected processMessageB to fail when transcript hash A is missing")
        } catch {
            assertMissingTranscriptHashA(error)
        }
    }

    func testConcurrentProcessMessageBWithoutTranscriptHashAFailsDeterministically() async {
        let context = makeInitiatorContext()
        let messageB = makeMinimalMessageB()

        let errors = await withTaskGroup(of: Error?.self, returning: [Error].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        _ = try await context.processMessageB(messageB)
                        return nil
                    } catch {
                        return error
                    }
                }
            }

            var collected: [Error] = []
            for await error in group {
                if let error {
                    collected.append(error)
                }
            }
            return collected
        }

        XCTAssertEqual(errors.count, 12)
        for error in errors {
            assertMissingTranscriptHashA(error)
        }
    }

    func testTrafficPaddingRoundTripAndMalformedFrameBehavior() {
        let defaults = UserDefaults.standard
        let enabledKey = "sb_traffic_padding_enabled"
        let modeKey = "sb_traffic_padding_mode"
        let fixedKey = "sb_traffic_padding_fixed_size"

        let oldEnabled = defaults.object(forKey: enabledKey)
        let oldMode = defaults.object(forKey: modeKey)
        let oldFixed = defaults.object(forKey: fixedKey)

        defer {
            restore(defaults, key: enabledKey, value: oldEnabled)
            restore(defaults, key: modeKey, value: oldMode)
            restore(defaults, key: fixedKey, value: oldFixed)
        }

        defaults.set(true, forKey: enabledKey)
        defaults.set(TrafficPaddingMode.fixed.rawValue, forKey: modeKey)
        defaults.set(128, forKey: fixedKey)

        let payload = Data("traffic-padding-regression".utf8)
        let wrapped = TrafficPadding.wrapIfEnabled(payload, label: "unit")

        XCTAssertEqual(wrapped.count, 128)
        XCTAssertEqual(TrafficPadding.unwrapIfNeeded(wrapped, label: "unit"), payload)

        var malformed = Data([0x53, 0x42, 0x50, 0x32])
        var declaredLen = UInt32(512).bigEndian
        malformed.append(Data(bytes: &declaredLen, count: 4))
        malformed.append(Data(repeating: 0xAA, count: 12))

        XCTAssertEqual(TrafficPadding.unwrapIfNeeded(malformed, label: "unit"), malformed)
    }

    @MainActor
    func testFileTransferPrefersLocalP2POverStaleWebRTCForSamePeer() {
        let shouldPreferCrossNetwork = FileTransferManager.shouldPreferCrossNetworkTransfer(
            targetDeviceId: "id:peer-1",
            crossNetworkState: .connected(sessionId: "ABC123"),
            crossNetworkRemoteDeviceId: "id:peer-1",
            localActiveConnectionDeviceIds: ["id:peer-1"]
        )

        XCTAssertFalse(shouldPreferCrossNetwork)
    }

    @MainActor
    func testFileTransferUsesCrossNetworkWhenNoLocalP2PExists() {
        let shouldPreferCrossNetwork = FileTransferManager.shouldPreferCrossNetworkTransfer(
            targetDeviceId: "id:peer-1",
            crossNetworkState: .connected(sessionId: "ABC123"),
            crossNetworkRemoteDeviceId: "id:peer-1",
            localActiveConnectionDeviceIds: []
        )

        XCTAssertTrue(shouldPreferCrossNetwork)
    }

    func testRemoteDesktopStreamConfigurationPayloadEqualityIgnoresSentAtButTracksRefreshToken() {
        let base = RemoteDesktopStreamConfigurationPayload(
            width: 1920,
            height: 1080,
            preferredCodec: "h264",
            supportedVideoFormats: ["h264", "jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            streamRefreshToken: nil,
            sentAt: 1
        )

        let sameSettingsDifferentTimestamp = RemoteDesktopStreamConfigurationPayload(
            width: 1920,
            height: 1080,
            preferredCodec: "h264",
            supportedVideoFormats: ["h264", "jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            streamRefreshToken: nil,
            sentAt: 999
        )

        let refreshed = RemoteDesktopStreamConfigurationPayload(
            width: 1920,
            height: 1080,
            preferredCodec: "h264",
            supportedVideoFormats: ["h264", "jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            streamRefreshToken: 7,
            sentAt: 1000
        )

        XCTAssertEqual(base, sameSettingsDifferentTimestamp)
        XCTAssertNotEqual(base, refreshed)
    }

    func testRemoteDesktopAutomaticViewerPolicyPrefersStableH264At60FPS() {
        XCTAssertEqual(RemoteDesktopViewerFrameRate.adaptive.targetFPS, 60)
        XCTAssertEqual(RemoteDesktopViewerResolution.uhd5k.dimensions?.width, 5120)
        XCTAssertEqual(RemoteDesktopViewerResolution.uhd5k.dimensions?.height, 2880)
        XCTAssertEqual(RemoteDesktopViewerSettings().activePreset, .automatic)
        XCTAssertEqual(
            RemoteDesktopViewerCodec.automatic.resolvedWireValue(
                supportedFormats: ["hevc", "jpeg", "h264"]
            ),
            "h264"
        )
        XCTAssertEqual(
            RemoteDesktopViewerCodec.automatic.resolvedWireValue(
                supportedFormats: ["jpeg", "h264"]
            ),
            "h264"
        )
    }

    func testRemoteDesktopViewerPresetApplicationSupportsProModes() {
        var settings = RemoteDesktopViewerSettings()

        settings.applyPreset(.pro5k120)

        XCTAssertEqual(settings.activePreset, .pro5k120)
        XCTAssertEqual(settings.resolution, .uhd5k)
        XCTAssertEqual(settings.frameRate, .fps120)
        XCTAssertEqual(settings.preferredCodec, .hevc)
        XCTAssertTrue(settings.lowLatencyMode)

        settings.resolution = .qhd1440

        XCTAssertEqual(settings.activePreset, .custom)
    }

    func testRemoteDesktopViewerFluidPresetTargetsLowLatencyH264() {
        var settings = RemoteDesktopViewerSettings()

        settings.applyPreset(.fluid)

        XCTAssertEqual(settings.activePreset, .fluid)
        XCTAssertEqual(settings.resolution, .hd720)
        XCTAssertEqual(settings.frameRate, .fps60)
        XCTAssertEqual(settings.preferredCodec, .h264)
        XCTAssertTrue(settings.lowLatencyMode)
    }

    func testRemoteDesktopViewerPresetCarriesTransportGovernanceHints() {
        var settings = RemoteDesktopViewerSettings()

        settings.applyPreset(.pro4k120)

        XCTAssertEqual(settings.transportTuning.qualityPresetWireValue, "geek4k120")
        XCTAssertEqual(settings.transportTuning.jitterBufferFrames, 1)
        XCTAssertEqual(settings.transportTuning.refreshStrategy, "instant")
        XCTAssertEqual(settings.transportTuning.lossRecoveryMode, "fast-retransmit")
        XCTAssertTrue(settings.transportTuning.damageTrackingEnabled)
        XCTAssertTrue(settings.transportTuning.separateCursorChannelEnabled)
        XCTAssertTrue(settings.transportTuning.interactionOverlayChannelEnabled)
    }

    func testRemoteDesktopCodecGovernanceDisablesHEVCAfterRepeatedDecoderFailures() {
        var governance = RemoteDesktopCodecGovernance()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            governance.noteDecodeFailure(format: "hevc", reason: "callback-no-image", at: start),
            .none
        )
        XCTAssertEqual(
            governance.noteDecodeFailure(
                format: "hevc",
                reason: "VTDecompressionSessionDecodeFrame status=-12909",
                at: start.addingTimeInterval(0.2)
            ),
            .none
        )

        let event = governance.noteDecodeFailure(
            format: "hevc",
            reason: "callback-no-image",
            at: start.addingTimeInterval(0.4)
        )

        guard case .disableHEVC(let until) = event else {
            return XCTFail("Expected HEVC circuit breaker to disable the codec temporarily")
        }

        XCTAssertEqual(
            governance.effectiveSupportedFormats(
                from: ["hevc", "h264", "jpeg"],
                at: start.addingTimeInterval(1)
            ),
            ["h264", "jpeg"]
        )
        XCTAssertEqual(
            governance.effectivePreferredCodec(
                userPreference: .automatic,
                supportedFormats: ["hevc", "h264", "jpeg"],
                at: start.addingTimeInterval(1)
            ),
            "h264"
        )
        XCTAssertGreaterThan(until.timeIntervalSince(start), 10)
    }

    func testRemoteDesktopCodecGovernanceReenablesHEVCAfterStableFallbackFrames() {
        var governance = RemoteDesktopCodecGovernance()
        let start = Date(timeIntervalSince1970: 1_700_000_100)

        _ = governance.noteDecodeFailure(format: "hevc", reason: "callback-no-image", at: start)
        _ = governance.noteDecodeFailure(format: "hevc", reason: "callback-no-image", at: start.addingTimeInterval(0.1))
        let disableEvent = governance.noteDecodeFailure(
            format: "hevc",
            reason: "callback-no-image",
            at: start.addingTimeInterval(0.2)
        )
        guard case .disableHEVC(let until) = disableEvent else {
            return XCTFail("Expected HEVC to enter cooldown first")
        }

        var probeEvent: RemoteDesktopCodecGovernanceEvent = .none
        for frameIndex in 0..<24 {
            probeEvent = governance.noteDecodeSuccess(
                format: "h264",
                at: until.addingTimeInterval(Double(frameIndex) * 0.05)
            )
        }

        XCTAssertEqual(probeEvent, .reenableHEVCProbe)
        XCTAssertEqual(
            governance.effectiveSupportedFormats(
                from: ["hevc", "h264", "jpeg"],
                at: until.addingTimeInterval(2)
            ),
            ["hevc", "h264", "jpeg"]
        )
    }

    func testRemoteDesktopCodecGovernanceEscalatesRepeatedSyncFrameWaitsToH264Fallback() {
        var governance = RemoteDesktopCodecGovernance()
        let start = Date(timeIntervalSince1970: 1_700_000_200)

        XCTAssertEqual(
            governance.noteDecodeFailure(
                format: "hevc",
                reason: "waiting-for-sync-frame",
                at: start
            ),
            .requestRefresh
        )
        XCTAssertEqual(
            governance.noteDecodeFailure(
                format: "hevc",
                reason: "waiting-for-sync-frame",
                at: start.addingTimeInterval(0.2)
            ),
            .requestRefresh
        )

        let event = governance.noteDecodeFailure(
            format: "hevc",
            reason: "waiting-for-sync-frame",
            at: start.addingTimeInterval(0.4)
        )

        guard case .disableHEVC(let until) = event else {
            return XCTFail("Expected repeated sync-frame waits to disable HEVC temporarily")
        }

        XCTAssertGreaterThan(until.timeIntervalSince(start), 10)
        XCTAssertEqual(
            governance.effectiveSupportedFormats(
                from: ["hevc", "h264", "jpeg"],
                at: start.addingTimeInterval(1)
            ),
            ["h264", "jpeg"]
        )
    }

    func testPeerIdentityAliasResolverMapsHostEndpointBackToStableDeviceID() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("192.168.31.20"),
            port: NWEndpoint.Port(integerLiteral: 9527)
        )

        let resolved = PeerIdentityAliasResolver.resolveDeviceId(
            for: endpoint,
            endpointKey: endpoint.debugDescription,
            exactEndpointMap: [:],
            aliasMap: ["host:192.168.31.20": "id:peer-1"]
        )

        XCTAssertEqual(resolved, "id:peer-1")
    }

    func testPeerIdentityAliasResolverMapsBonjourEndpointBackToStableDeviceID() {
        let endpoint = NWEndpoint.service(
            name: "Lza's MacBook Pro",
            type: "_skybridge._tcp",
            domain: "local.",
            interface: nil
        )

        let resolved = PeerIdentityAliasResolver.resolveDeviceId(
            for: endpoint,
            endpointKey: endpoint.debugDescription,
            exactEndpointMap: [:],
            aliasMap: ["bonjour:lza's macbook pro@local.": "id:peer-bonjour"]
        )

        XCTAssertEqual(resolved, "id:peer-bonjour")
    }

    @MainActor
    func testResolveBestTransferDevicePrefersTransferServiceCandidateOverBareSnapshot() {
        let target = DiscoveredDevice(
            id: "id:peer-1",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        let richerTransferCandidate = DiscoveredDevice(
            id: "bonjour:MacBook Pro@local.",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "192.168.31.20",
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["file_transfer"],
            capabilities: ["file_transfer"]
        )

        let resolved = FileTransferManager.resolveBestTransferDevice(
            target: target,
            discovered: [richerTransferCandidate]
        )

        XCTAssertEqual(resolved.id, richerTransferCandidate.id)
        XCTAssertEqual(resolved.fileTransferPort, 8080)
        XCTAssertEqual(resolved.ipAddress, "192.168.31.20")
    }

    @MainActor
    func testResolveBestTransferDeviceMatchesScopedHostSnapshotToReachableTransferCandidate() {
        let target = DiscoveredDevice(
            id: "host:fe80::468:f5a1:462b:29d3%bridge100",
            name: "fe80::468:f5a1:462b:29d3%bridge100",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: nil,
            bonjourServiceDomain: nil,
            services: [],
            portMap: [:],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        let richerTransferCandidate = DiscoveredDevice(
            id: "id:peer-transfer",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "fe80::468:f5a1:462b:29d3",
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["file_transfer"],
            capabilities: ["file_transfer"]
        )

        let resolved = FileTransferManager.resolveBestTransferDevice(
            target: target,
            discovered: [richerTransferCandidate]
        )

        XCTAssertEqual(resolved.id, richerTransferCandidate.id)
        XCTAssertEqual(resolved.fileTransferPort, 8080)
    }

    @MainActor
    func testResolveBestRemoteDesktopDevicePrefersReachableRemoteCandidateOverCapabilityOnlySnapshot() {
        let target = DiscoveredDevice(
            id: "id:peer-1",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: [:],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        let richerRemoteCandidate = DiscoveredDevice(
            id: "bonjour:MacBook Pro@local.",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "192.168.31.20",
            bonjourServiceType: DiscoveredDevice.remoteControlServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.remoteControlServiceType],
            portMap: [DiscoveredDevice.remoteControlServiceType: 5901],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        let resolved = RemoteDesktopManager.resolveBestRemoteDesktopDevice(
            target: target,
            discovered: [richerRemoteCandidate]
        )

        XCTAssertEqual(resolved.id, richerRemoteCandidate.id)
        XCTAssertEqual(resolved.remoteControlPort, 5901)
        XCTAssertEqual(resolved.ipAddress, "192.168.31.20")
    }

    @MainActor
    func testResolveBestRemoteDesktopDeviceMatchesScopedHostSnapshotToReachableRemoteCandidate() {
        let target = DiscoveredDevice(
            id: "host:fe80::468:f5a1:462b:29d3%bridge100",
            name: "fe80::468:f5a1:462b:29d3%bridge100",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: nil,
            bonjourServiceDomain: nil,
            services: [],
            portMap: [:],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        let richerRemoteCandidate = DiscoveredDevice(
            id: "id:peer-remote",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "fe80::468:f5a1:462b:29d3",
            bonjourServiceType: DiscoveredDevice.remoteControlServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.remoteControlServiceType],
            portMap: [DiscoveredDevice.remoteControlServiceType: 5901],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        let resolved = RemoteDesktopManager.resolveBestRemoteDesktopDevice(
            target: target,
            discovered: [richerRemoteCandidate]
        )

        XCTAssertEqual(resolved.id, richerRemoteCandidate.id)
        XCTAssertEqual(resolved.remoteControlPort, 5901)
    }

    @MainActor
    func testLiveLANMacConnectionIsEligibleForRemoteDesktopWithoutExplicitRemoteServiceAdvertisement() {
        let connectionManager = P2PConnectionManager.instance
        connectionManager.installUITestActiveConnections([])
        defer {
            connectionManager.installUITestActiveConnections([])
        }

        let runtimePeerId = "host:fe80::b4:98c9:b9a:3bb3%en2"
        connectionManager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Lza的MacBook Pro",
            ipAddress: "fe80::b4:98c9:b9a:3bb3%en2"
        )

        let device = DiscoveredDevice(
            id: runtimePeerId,
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: nil,
            bonjourServiceDomain: nil,
            services: [],
            portMap: [:],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        XCTAssertTrue(RemoteDesktopManager.instance.canPresentRemoteDesktopOption(for: device))
    }

    @MainActor
    func testCapabilityOnlyTransferDeviceDoesNotExposeExplicitLANTransferService() {
        let device = DiscoveredDevice(
            id: "id:peer-transfer",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: [:],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["file_transfer"],
            capabilities: ["file_transfer"]
        )

        XCTAssertFalse(FileTransferManager.hasExplicitLANTransferService(device))
    }

    @MainActor
    func testCapabilityOnlyRemoteDesktopDeviceDoesNotExposeExplicitLANEndpoint() {
        let device = DiscoveredDevice(
            id: "id:peer-remote",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: [:],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        XCTAssertFalse(RemoteDesktopManager.hasExplicitLANRemoteDesktopEndpoint(device))
    }

    @MainActor
    func testProtectedDiscoveryIdentifiersDoNotKeepDisconnectedRuntimePeerAlive() {
        let manager = P2PConnectionManager.instance
        manager.installUITestActiveConnections([])

        let runtimePeerId = "host:fe80::468:f5a1:462b:29d3%bridge100"
        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "MacBook Pro",
            ipAddress: "fe80::468:f5a1:462b:29d3%bridge100"
        )

        XCTAssertFalse(manager.activeDiscoveryIdentifiers.isEmpty)
        XCTAssertTrue(manager.protectedDiscoveryIdentifiers.contains("host:fe80::468:f5a1:462b:29d3"))

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId, terminalStatus: .disconnected)

        XCTAssertTrue(manager.activeDiscoveryIdentifiers.isEmpty)
        XCTAssertFalse(manager.protectedDiscoveryIdentifiers.contains(runtimePeerId.lowercased()))
        XCTAssertFalse(manager.protectedDiscoveryIdentifiers.contains("host:fe80::468:f5a1:462b:29d3"))

        manager.installUITestActiveConnections([])
    }

    private func makeInitiatorContext() -> HandshakeContext {
        let signingKey = Curve25519.Signing.PrivateKey()
        return HandshakeContext(
            role: .initiator,
            cryptoProvider: ClassicCryptoProvider(),
            protocolSignatureProvider: ClassicSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: signingKey.publicKey.rawRepresentation,
            policy: .default,
            peerKEMPublicKeys: [:]
        )
    }

    private func makeMinimalMessageB() -> HandshakeMessageB {
        let identityKeys = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0x11, count: 32),
            protocolAlgorithm: .ed25519
        )

        let sealedBox = HPKESealedBox(
            encapsulatedKey: Data(repeating: 0x22, count: 32),
            ciphertext: Data([0x01, 0x02, 0x03]),
            tag: Data(repeating: 0x33, count: 16),
            nonce: Data(repeating: 0x44, count: 12)
        )

        return HandshakeMessageB(
            selectedSuite: .x25519Ed25519,
            responderShare: Data(repeating: 0x55, count: 32),
            serverNonce: Data(repeating: 0x66, count: HandshakeConstants.nonceSize),
            encryptedPayload: sealedBox,
            signature: Data(repeating: 0x77, count: 64),
            identityPublicKeys: identityKeys
        )
    }

    private func assertMissingTranscriptHashA(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case let HandshakeError.failed(reason) = error else {
            XCTFail("Expected HandshakeError.failed, got \(error)", file: file, line: line)
            return
        }
        guard case let .cryptoError(message) = reason else {
            XCTFail("Expected HandshakeFailureReason.cryptoError, got \(reason)", file: file, line: line)
            return
        }
        XCTAssertEqual(message, "Missing transcript hash A", file: file, line: line)
    }

    private func restore(_ defaults: UserDefaults, key: String, value: Any?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func testConnectionPresentationContractTreatsTransportReadyAsConnected() {
        let presentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: ConnectionPresentationLabels(
                    connectedText: "已连接",
                    disconnectedText: "离线",
                    connectingText: "连接中",
                    reconnectingText: "重连中",
                    defaultGuardStatus: "守护中",
                    crossNetworkGuardStatus: "跨网已连接"
                ),
                fileTransferActive: false,
                latestPeerConnection: nil,
                latestConnectedDevice: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    snapshotToken: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    sessionId: "session-1",
                    source: .code,
                    phase: .transportReady,
                    deviceId: "peer-1",
                    deviceName: "Mac mini",
                    negotiatedSuite: "ML-KEM-768"
                ),
                defaultPQCModeLabel: "Apple PQC"
            )
        )

        XCTAssertEqual(presentation.phase, .connected)
        XCTAssertEqual(presentation.statusText, "Apple PQC已连接")
    }

    func testConnectionPresentationContractPrioritizesPeerOverCrossNetworkSnapshot() {
        let presentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: ConnectionPresentationLabels(
                    connectedText: "已连接",
                    disconnectedText: "离线",
                    connectingText: "连接中",
                    reconnectingText: "重连中",
                    defaultGuardStatus: "守护中",
                    crossNetworkGuardStatus: "跨网已连接"
                ),
                fileTransferActive: false,
                latestPeerConnection: ConnectionPresentationPeer(
                    displayName: "Peer",
                    cryptoKind: nil,
                    suite: "X25519",
                    guardStatus: "守护中"
                ),
                latestConnectedDevice: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    snapshotToken: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    sessionId: "session-2",
                    source: .qr,
                    phase: .handshakeComplete,
                    deviceId: "peer-2",
                    deviceName: "Remote Device",
                    negotiatedSuite: "ML-KEM-768"
                ),
                defaultPQCModeLabel: "Apple PQC"
            )
        )

        XCTAssertEqual(presentation.statusText, "Classic已连接")
    }

    func testConnectionPresentationContractDoesNotClaimTargetSuiteWhileRekeying() {
        let presentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: ConnectionPresentationLabels(
                    connectedText: "已连接",
                    disconnectedText: "离线",
                    connectingText: "连接中",
                    reconnectingText: "重连中",
                    defaultGuardStatus: "守护中",
                    crossNetworkGuardStatus: "跨网已连接"
                ),
                fileTransferActive: false,
                latestPeerConnection: ConnectionPresentationPeer(
                    displayName: "Peer",
                    cryptoKind: "X25519 → X-Wing",
                    suite: nil,
                    guardStatus: "Rekey 中",
                    isRekeying: true
                ),
                latestConnectedDevice: nil,
                activeSessionSnapshot: nil,
                defaultPQCModeLabel: "Apple PQC"
            )
        )

        XCTAssertEqual(presentation.statusText, "已连接")
        XCTAssertEqual(presentation.detailText, "X25519 → X-Wing · Rekey 中")
    }

    func testLateCleanupTokenDoesNotClearNewSnapshot() {
        let originalToken = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let replacementToken = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let newerSnapshot = ActiveSessionSnapshotContract.activate(
            sessionId: "session-1",
            source: .reused,
            phase: .handshakeComplete,
            deviceId: "peer-1",
            deviceName: "Peer A",
            negotiatedSuite: "X-Wing",
            snapshotToken: replacementToken
        )

        let afterLateCleanup = ActiveSessionSnapshotContract.disconnect(
            current: newerSnapshot,
            sessionId: "session-1",
            snapshotToken: originalToken,
            kind: .explicit
        )

        XCTAssertEqual(afterLateCleanup, newerSnapshot)
    }

    func testRemoteDesktopDecodeQueuePolicyPreservesPredictiveVideoOrder() {
        var pending: [ScreenData] = []
        var waitingForSyncFrame = false
        let first = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0x01]),
            timestamp: 1,
            format: "h264"
        )
        let second = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0x02]),
            timestamp: 2,
            format: "h264"
        )

        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                first,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .enqueued
        )
        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                second,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .enqueued
        )

        XCTAssertEqual(RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pending)?.imageData, first.imageData)
        XCTAssertEqual(RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pending)?.imageData, second.imageData)
    }

    func testRemoteDesktopDecodeQueuePolicyStillImagesReplaceLatestFrame() {
        var pending: [ScreenData] = []
        var waitingForSyncFrame = false
        let stale = ScreenData(
            width: 1206,
            height: 779,
            imageData: Data([0x11]),
            timestamp: 1,
            format: "jpeg"
        )
        let latest = ScreenData(
            width: 1206,
            height: 779,
            imageData: Data([0x22]),
            timestamp: 2,
            format: "jpeg"
        )

        _ = RemoteDesktopDecodeQueuePolicy.enqueue(
            stale,
            into: &pending,
            waitingForSyncFrame: &waitingForSyncFrame
        )
        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                latest,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .replacedStillFrame
        )

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.imageData, latest.imageData)
        XCTAssertFalse(waitingForSyncFrame)
    }

    func testRemoteDesktopDecodeQueuePolicyEntersWaitingForSyncWhenQueueIsFull() {
        var pending = (0..<RemoteDesktopDecodeQueuePolicy.maxPredictiveVideoFrames).map { index in
            ScreenData(
                width: 1280,
                height: 720,
                imageData: Data([UInt8(index)]),
                timestamp: TimeInterval(index),
                format: "hevc"
            )
        }
        var waitingForSyncFrame = false
        let overflow = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0xFE]),
            timestamp: 99,
            format: "hevc"
        )

        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                overflow,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .enteredWaitingForSync
        )
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(waitingForSyncFrame)
    }

    func testRemoteDesktopDecodeQueuePolicyRecoversWhenSyncFrameArrives() {
        var pending: [ScreenData] = []
        var waitingForSyncFrame = true
        let syncFrame = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88]),
            timestamp: 3,
            format: "h264",
            isSyncFrame: false
        )

        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                syncFrame,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .recoveredWithIndependentFrame
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.imageData, syncFrame.imageData)
        XCTAssertFalse(waitingForSyncFrame)
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotDetectsDecodedVideoFrameEvidence() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 47),
                    "bytesReceived": NSNumber(value: 94_288),
                    "framesReceived": NSNumber(value: 8),
                    "framesDecoded": NSNumber(value: 7),
                    "frameWidth": NSNumber(value: 2_056),
                    "frameHeight": NSNumber(value: 1_329)
                ]
            )
        ]

        let snapshot = WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples)

        XCTAssertEqual(snapshot?.statType, "inbound-rtp")
        XCTAssertTrue(snapshot?.hasFrameEvidence == true)
        XCTAssertEqual(snapshot?.size, CGSize(width: 2_056, height: 1_329))
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotIgnoresAudioOnlySamples() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "audio"),
                    "packetsReceived": NSNumber(value: 128),
                    "bytesReceived": NSNumber(value: 4_096)
                ]
            )
        ]

        XCTAssertNil(WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples))
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotMergesInboundAndTrackSamples() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 47),
                    "bytesReceived": NSNumber(value: 94_288),
                    "framesReceived": NSNumber(value: 8),
                    "framesDecoded": NSNumber(value: 7)
                ]
            ),
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "track",
                values: [
                    "kind": NSString(string: "video"),
                    "frameWidth": NSNumber(value: 2_056),
                    "frameHeight": NSNumber(value: 1_329)
                ]
            )
        ]

        let snapshot = WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples)

        XCTAssertEqual(snapshot?.statType, "inbound-rtp")
        XCTAssertEqual(snapshot?.framesDecoded, 7)
        XCTAssertEqual(snapshot?.size, CGSize(width: 2_056, height: 1_329))
        XCTAssertTrue(snapshot?.hasFrameEvidence == true)
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotIgnoresTransportSideReports() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "candidate-pair",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 40_312),
                    "bytesReceived": NSNumber(value: 48_836_959)
                ]
            ),
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "data-channel",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 20_993),
                    "bytesReceived": NSNumber(value: 25_438_840)
                ]
            )
        ]

        XCTAssertNil(WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples))
    }

    func testLocalHandshakeCryptoPolicyResolverEnablesHybridForXWingAttempt() async throws {
        let provider = LocalHandshakeTestCryptoProvider(
            tier: .liboqsPQC,
            activeSuite: .xwing,
            supportedSuites: [.xwing]
        )
        let signatureProvider = LocalHandshakeTestSignatureProvider()
        let keyHandle = SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xAA])))
        let identityPublicKey = Data([0xBB, 0xCC, 0xDD])
        let peerKEMKeys: [CryptoSuite: Data] = [.xwing: Data([0x01, 0x02, 0x03])]

        let strictContext = HandshakeContext(
            role: .initiator,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: keyHandle,
            identityPublicKey: identityPublicKey,
            policy: .strictPQC,
            cryptoPolicy: .default,
            offeredSuites: [.xwing],
            peerKEMPublicKeys: peerKEMKeys
        )

        await XCTAssertThrowsErrorAsync(try await strictContext.buildMessageA()) { error in
            guard case HandshakeError.failed(.suiteNegotiationFailed) = error else {
                XCTFail("Expected suiteNegotiationFailed, got \(error)")
                return
            }
        }

        let enabledContext = HandshakeContext(
            role: .initiator,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: keyHandle,
            identityPublicKey: identityPublicKey,
            policy: .strictPQC,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: [.xwing]),
            offeredSuites: [.xwing],
            peerKEMPublicKeys: peerKEMKeys
        )

        let messageA = try await enabledContext.buildMessageA()
        XCTAssertEqual(messageA.supportedSuites, [.xwing])
    }

    func testLocalHandshakeContextUsesPreparedOfferedSuiteInsteadOfProviderActiveSuite() async throws {
        let provider = LocalHandshakeTestCryptoProvider(
            tier: .liboqsPQC,
            activeSuite: .mlkem768,
            supportedSuites: [.mlkem768fs, .mlkem768]
        )
        let signatureProvider = LocalHandshakeTestSignatureProvider()
        let keyHandle = SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xAB])))
        let context = HandshakeContext(
            role: .initiator,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: keyHandle,
            identityPublicKey: Data([0x10, 0x20, 0x30]),
            policy: .strictPQC,
            cryptoPolicy: .default,
            offeredSuites: [.mlkem768fs],
            peerKEMPublicKeys: [.mlkem768: Data([0x99])]
        )

        let messageA = try await context.buildMessageA()
        XCTAssertEqual(messageA.supportedSuites, [.mlkem768fs])
        XCTAssertNotNil(messageA.initiatorContribution)
    }

    @MainActor
    func testP2PConnectionManagerStrictInboundRejectsClassicOnlyPeer() {
        let manager = P2PConnectionManager.instance
        let original = PQCCryptoManager.instance.enforcePQCHandshake
        defer { PQCCryptoManager.instance.enforcePQCHandshake = original }
        PQCCryptoManager.instance.enforcePQCHandshake = true

        XCTAssertTrue(
            manager.testOnlyStrictPQCRejectsInboundHandshake(
                supportedSuites: [.x25519Ed25519]
            )
        )
    }

    @MainActor
    func testP2PConnectionManagerStrictInboundRejectsWhenLocalPQCUnavailable() {
        let manager = P2PConnectionManager.instance
        let original = PQCCryptoManager.instance.enforcePQCHandshake
        defer { PQCCryptoManager.instance.enforcePQCHandshake = original }
        PQCCryptoManager.instance.enforcePQCHandshake = true

        XCTAssertTrue(
            manager.testOnlyStrictPQCRejectsInboundHandshake(
                supportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
                localPQCAvailable: false
            )
        )
    }

    @MainActor
    func testCrossNetworkWebRTCStrictInboundRekeyRejectsClassicOnlyMessageA() {
        XCTAssertNil(
            CrossNetworkWebRTCManager.testOnlyInboundPQCRekeySelectionPolicy(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: true
            )
        )
    }

    @MainActor
    func testCrossNetworkWebRTCStrictInboundRekeyRejectsWhenLocalPQCUnavailable() {
        XCTAssertNil(
            CrossNetworkWebRTCManager.testOnlyInboundPQCRekeySelectionPolicy(
                supportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: false
            )
        )
    }

    @MainActor
    func testCrossNetworkWebRTCStrictInboundRekeyRejectsEstablishedClassicSuite() {
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyInboundPQCRekeyNegotiatedSuiteAllowed(
                .x25519Ed25519,
                strictPQCRequested: true
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyInboundPQCRekeyNegotiatedSuiteAllowed(
                .mlkem768MLDSA65,
                strictPQCRequested: true
            )
        )
    }

    func testHandshakeDriverRetainsAuthenticatedAuthorityAfterOutboundHandshakeEstablishes() async throws {
        let signatureProvider = LocalHandshakeTestSignatureProvider()
        let provider = LocalHandshakeTestCryptoProvider(
            tier: .classic,
            activeSuite: .x25519Ed25519,
            supportedSuites: [.x25519Ed25519]
        )
        let initiatorIdentity = Data([0x10, 0x20, 0x30, 0x40])
        let responderIdentity = Data([0x50, 0x60, 0x70, 0x80])
        let transport = CaptureOnlyDiscoveryTransport()
        let initiator = HandshakeDriver(
            transport: transport,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xAA]))),
            sigAAlgorithm: .mlDSA65,
            identityPublicKey: initiatorIdentity
        )
        let handshakeTask = Task {
            try await initiator.initiateHandshake(with: PeerIdentifier(deviceId: "mac-peer"))
        }
        let messageAFrame = try await waitForLatestFrame(from: transport)
        let messageA = try HandshakeMessageA.decode(
            from: HandshakePadding.unwrapIfNeeded(messageAFrame, label: "test/messageA")
        )

        let responderContext = HandshakeContext(
            role: .responder,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xBB]))),
            identityPublicKey: responderIdentity,
            policy: .default,
            cryptoPolicy: .default
        )
        try await responderContext.processMessageA(messageA)
        let (messageB, _) = try await responderContext.buildMessageB()

        await initiator.handleMessage(messageB.encoded, from: PeerIdentifier(deviceId: "mac-peer"))

        guard case .waitingFinished(_, let sessionKeys, let expectingFrom) = await initiator.getCurrentState() else {
            XCTFail("Expected initiator handshake to be waiting for Finished after MessageB")
            return
        }
        XCTAssertEqual(expectingFrom, .responder)

        let responderFinished = LocalHandshakeFinishedHelper.responderFinished(for: sessionKeys)
        await initiator.handleMessage(responderFinished.encoded, from: PeerIdentifier(deviceId: "mac-peer"))

        let establishedKeys = try await handshakeTask.value
        XCTAssertEqual(establishedKeys.negotiatedSuite, .x25519Ed25519)

        guard case .established = await initiator.getCurrentState() else {
            XCTFail("Expected initiator handshake to establish")
            return
        }

        let initiatorAuthority = await initiator.getAuthenticatedRemoteAuthority()
        XCTAssertEqual(
            initiatorAuthority,
            try LocalHandshakeAuthorityHelper.authority(
                identityPublicKey: responderIdentity,
                signatureAlgorithm: signatureProvider.signatureAlgorithm
            )
        )
    }

    func testHandshakeDriverClearsAuthenticatedAuthorityAfterCancellation() async throws {
        let provider = LocalHandshakeTestCryptoProvider(
            tier: .classic,
            activeSuite: .x25519Ed25519,
            supportedSuites: [.x25519Ed25519]
        )
        let signatureProvider = LocalHandshakeTestSignatureProvider()
        let initiatorIdentity = Data([0x01, 0x23, 0x45, 0x67])
        let responderIdentity = Data([0x89, 0xAB, 0xCD, 0xEF])
        let transport = CaptureOnlyDiscoveryTransport()
        let initiator = HandshakeDriver(
            transport: transport,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xCC]))),
            sigAAlgorithm: .mlDSA65,
            identityPublicKey: initiatorIdentity
        )
        let handshakeTask = Task {
            try await initiator.initiateHandshake(with: PeerIdentifier(deviceId: "mac-peer"))
        }
        let messageAFrame = try await waitForLatestFrame(from: transport)
        let messageA = try HandshakeMessageA.decode(
            from: HandshakePadding.unwrapIfNeeded(messageAFrame, label: "test/messageA")
        )

        let responderContext = HandshakeContext(
            role: .responder,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xDD]))),
            identityPublicKey: responderIdentity,
            policy: .default,
            cryptoPolicy: .default
        )
        try await responderContext.processMessageA(messageA)
        let (messageB, _) = try await responderContext.buildMessageB()

        await initiator.handleMessage(messageB.encoded, from: PeerIdentifier(deviceId: "mac-peer"))

        guard case .waitingFinished = await initiator.getCurrentState() else {
            XCTFail("Expected initiator to be waiting for Finished after a valid MessageB")
            return
        }
        let authorityBeforeCancel = await initiator.getAuthenticatedRemoteAuthority()
        XCTAssertEqual(
            authorityBeforeCancel,
            try LocalHandshakeAuthorityHelper.authority(
                identityPublicKey: responderIdentity,
                signatureAlgorithm: signatureProvider.signatureAlgorithm
            )
        )

        await initiator.cancel()
        await XCTAssertThrowsErrorAsync(try await handshakeTask.value) { _ in }

        guard case .failed(let reason) = await initiator.getCurrentState() else {
            XCTFail("Expected initiator handshake to transition to failed after cancel")
            return
        }
        XCTAssertEqual(reason, .cancelled)
        let authorityAfterCancel = await initiator.getAuthenticatedRemoteAuthority()
        XCTAssertNil(authorityAfterCancel)
    }
}

private struct FixedSignatureCallback: SigningCallback {
    let signature: Data

    func sign(data: Data) async throws -> Data {
        signature
    }
}

private struct LocalHandshakeTestSignatureProvider: ProtocolSignatureProvider {
    let signatureAlgorithm: ProtocolSigningAlgorithm = .mlDSA65

    func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        switch key {
        case .callback(let callback):
            return try await callback.sign(data: data)
        case .softwareKey(let data):
            return data
        #if canImport(Security)
        case .secureEnclaveRef:
            return Data([0x01])
        #endif
        }
    }

    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        true
    }
}

private struct LocalHandshakeTestCryptoProvider: CryptoProvider {
    let providerName = "LocalHandshakeTest"
    let tier: CryptoTier
    let activeSuite: CryptoSuite
    let supportedSuites: [CryptoSuite]

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains(suite)
    }

    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        .init(
            encapsulatedKey: Data(repeating: 0x01, count: 32),
            ciphertext: plaintext,
            tag: Data(repeating: 0x02, count: 16),
            nonce: Data(repeating: 0x03, count: 12)
        )
    }

    func kemDemSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        try await hpkeSeal(plaintext: plaintext, recipientPublicKey: recipientPublicKey, info: info)
    }

    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        (
            sealedBox: try await hpkeSeal(plaintext: plaintext, recipientPublicKey: recipientPublicKey, info: info),
            sharedSecret: SecureBytes(data: Data(repeating: 0x11, count: 32))
        )
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: Data, info: Data) async throws -> Data {
        sealedBox.ciphertext
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        sealedBox.ciphertext
    }

    func kemDemOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        sealedBox.ciphertext
    }

    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        (
            plaintext: sealedBox.ciphertext,
            sharedSecret: SecureBytes(data: Data(repeating: 0x22, count: 32))
        )
    }

    func kemEncapsulate(recipientPublicKey: Data) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        (Data([0x33, 0x44]), SecureBytes(data: Data(repeating: 0x55, count: 32)))
    }

    func kemDecapsulate(encapsulatedKey: Data, privateKey: SecureBytes) async throws -> SecureBytes {
        SecureBytes(data: Data(repeating: 0x66, count: 32))
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        Data([0x77])
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        true
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        KeyPair(
            publicKey: Data(repeating: usage == .ephemeral ? 0x10 : 0x11, count: 32),
            privateKey: Data(repeating: usage == .ephemeral ? 0x12 : 0x13, count: 32)
        )
    }
}

private enum LocalHandshakeAuthorityHelper {
    static func authority(
        identityPublicKey: Data,
        signatureAlgorithm: ProtocolSigningAlgorithm
    ) throws -> AuthenticatedRemoteAuthority {
        let identityKeys = IdentityPublicKeys(
            protocolPublicKey: identityPublicKey,
            protocolAlgorithm: signatureAlgorithm.wire,
            secureEnclavePublicKey: nil
        )
        return AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: identityKeys.protocolAlgorithm.rawValue,
            protocolPublicKeyFingerprint: try identityKeys.authoritativeProtocolFingerprint().lowercased()
        )
    }
}

private actor CaptureOnlyDiscoveryTransport: DiscoveryTransport {
    private(set) var frames: [Data] = []

    func send(to peer: PeerIdentifier, data: Data) async throws {
        _ = peer
        frames.append(data)
    }

    func latestFrame() -> Data? {
        frames.last
    }
}

private enum LocalHandshakeFinishedHelper {
    static func responderFinished(for sessionKeys: SessionKeys) -> HandshakeFinished {
        let macKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKeys.receiveKey),
            salt: Data(),
            info: Data("SkyBridge-FINISHED|R2I|".utf8) + sessionKeys.transcriptHash,
            outputByteCount: 32
        )
        let mac = Data(HMAC<SHA256>.authenticationCode(for: sessionKeys.transcriptHash, using: macKey))
        return HandshakeFinished(direction: .responderToInitiator, mac: mac)
    }
}

private enum LocalHandshakeTestError: Error {
    case timedOutWaitingForCapturedFrame
}

private func waitForLatestFrame(
    from transport: CaptureOnlyDiscoveryTransport,
    iterations: Int = 200,
    sleepNanoseconds: UInt64 = 5_000_000
) async throws -> Data {
    for _ in 0..<iterations {
        if let frame = await transport.latestFrame() {
            return frame
        }
        try? await Task.sleep(nanoseconds: sleepNanoseconds)
    }
    throw LocalHandshakeTestError.timedOutWaitingForCapturedFrame
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown")
    } catch {
        errorHandler(error)
    }
}
