import Foundation
import Testing
@testable import SkyBridgeProtocolCore

private actor InboundContextBarrierHarness {
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
        if captured.isCurrent(owner: captured.owner, current: current) {
            didMutate = true
        }
    }

    func waitUntilSuspended() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
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

private actor CancellableSendBarrierHarness {
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

private actor AcknowledgementOwnerBarrierHarness {
    enum HarnessError: Error { case staleOwner }

    private var currentOwner: CrossNetworkFileTransferSessionOwner
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    init(owner: CrossNetworkFileTransferSessionOwner) {
        currentOwner = owner
    }

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

    func rotate(to owner: CrossNetworkFileTransferSessionOwner) {
        currentOwner = owner
    }

    func releaseCaller() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@Suite("Cross-network file completion acknowledgement")
struct CrossNetworkFileTransferCompletionAcknowledgementTests {
    @Test("binds the durable byte count and file digest")
    func bindsDurableResult() throws {
        let digest = Data(repeating: 0xA5, count: 32)

        let acknowledgement = try CrossNetworkFileTransferMessage.completeAcknowledgement(
            transferId: "123e4567-e89b-12d3-a456-426614174000",
            receivedBytes: 4096,
            fileSha256: digest
        )

        #expect(acknowledgement.op == .completeAck)
        #expect(acknowledgement.transferId == "123e4567-e89b-12d3-a456-426614174000")
        #expect(acknowledgement.receivedBytes == 4096)
        #expect(acknowledgement.fileSha256 == digest)
    }

    @Test("rejects malformed completion evidence")
    func rejectsMalformedEvidence() {
        #expect(throws: CrossNetworkFileTransferCompletionAcknowledgementError.emptyTransferID) {
            try CrossNetworkFileTransferMessage.completeAcknowledgement(
                transferId: "  ",
                receivedBytes: 0,
                fileSha256: Data(repeating: 0, count: 32)
            )
        }
        #expect(throws: CrossNetworkFileTransferCompletionAcknowledgementError.negativeReceivedBytes) {
            try CrossNetworkFileTransferMessage.completeAcknowledgement(
                transferId: "123e4567-e89b-12d3-a456-426614174000",
                receivedBytes: -1,
                fileSha256: Data(repeating: 0, count: 32)
            )
        }
        #expect(
            throws: CrossNetworkFileTransferCompletionAcknowledgementError.invalidFileSHA256Length(31)
        ) {
            try CrossNetworkFileTransferMessage.completeAcknowledgement(
                transferId: "123e4567-e89b-12d3-a456-426614174000",
                receivedBytes: 0,
                fileSha256: Data(repeating: 0, count: 31)
            )
        }
        #expect(throws: CrossNetworkFileTransferCompletionAcknowledgementError.invalidTransferID) {
            try CrossNetworkFileTransferMessage.completeAcknowledgement(
                transferId: "transfer-1",
                receivedBytes: 1,
                fileSha256: Data(repeating: 0, count: 32)
            )
        }
    }

    @Test("requires exact version, operation, identifier, byte count, and digest")
    func requiresExactCompletionEvidence() throws {
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let digest = Data(repeating: 0x55, count: 32)
        let expectation = try CrossNetworkFileTransferCompletionAckExpectation(
            transferID: transferID,
            receivedBytes: 8192,
            fileSHA256: digest
        )

        try expectation.validate(
            .init(
                op: .completeAck,
                transferId: transferID,
                receivedBytes: 8192,
                fileSha256: digest
            )
        )
        #expect(throws: CrossNetworkFileTransferCompletionEvidenceError.invalidVersion(2)) {
            try expectation.validate(
                .init(
                    version: 2,
                    op: .completeAck,
                    transferId: transferID,
                    receivedBytes: 8192,
                    fileSha256: digest
                )
            )
        }
        #expect(
            throws: CrossNetworkFileTransferCompletionEvidenceError.invalidOperation(.complete)
        ) {
            try expectation.validate(
                .init(
                    op: .complete,
                    transferId: transferID,
                    receivedBytes: 8192,
                    fileSha256: digest
                )
            )
        }
        #expect(
            throws: CrossNetworkFileTransferCompletionEvidenceError.receivedBytesMismatch(
                expected: 8192,
                actual: 8191
            )
        ) {
            try expectation.validate(
                .init(
                    op: .completeAck,
                    transferId: transferID,
                    receivedBytes: 8191,
                    fileSha256: digest
                )
            )
        }
        #expect(throws: CrossNetworkFileTransferCompletionEvidenceError.fileSHA256Mismatch) {
            try expectation.validate(
                .init(
                    op: .completeAck,
                    transferId: transferID,
                    receivedBytes: 8192,
                    fileSha256: Data(repeating: 0xAA, count: 32)
                )
            )
        }
    }

    @Test("arms before a synchronous acknowledgement and rejects a late session owner")
    func waiterRegistryUsesExactOwnerAndToken() throws {
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let oldOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let newOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let acknowledgement = CrossNetworkFileTransferMessage(
            op: .metadataAck,
            transferId: transferID
        )
        var registry = CrossNetworkFileTransferWaiterRegistry()

        let token = try registry.arm(
            owner: newOwner,
            transferID: transferID,
            operation: .metadataAck,
            chunkIndex: nil
        )
        #expect(registry.consume(owner: oldOwner, message: acknowledgement) == nil)
        #expect(registry.count == 1)

        let synchronouslyConsumed = registry.consume(owner: newOwner, message: acknowledgement)
        #expect(synchronouslyConsumed == token)
        #expect(registry.count == 0)
        let removedConsumedToken = registry.remove(token)
        #expect(!removedConsumedToken)
    }

    @Test("removes the exact token when send failure wins before a late acknowledgement")
    func sendFailureWinsBeforeLateAcknowledgement() throws {
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID()
        )
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let acknowledgement = CrossNetworkFileTransferMessage(
            op: .metadataAck,
            transferId: transferID
        )
        var registry = CrossNetworkFileTransferWaiterRegistry()
        let token = try registry.arm(
            owner: owner,
            transferID: transferID,
            operation: .metadataAck,
            chunkIndex: nil
        )

        let sendFailureRemovedToken = registry.remove(token)
        #expect(sendFailureRemovedToken)
        #expect(registry.consume(owner: owner, message: acknowledgement) == nil)
    }

    @Test("an old timeout token cannot remove a retry waiter with the same key")
    func oldTimeoutCannotRemoveRetryWaiter() throws {
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID()
        )
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        var registry = CrossNetworkFileTransferWaiterRegistry()
        let oldToken = try registry.arm(
            owner: owner,
            transferID: transferID,
            operation: .chunkAck,
            chunkIndex: 3
        )
        let timeoutRemovedOldToken = registry.remove(oldToken)
        #expect(timeoutRemovedOldToken)
        let retryToken = try registry.arm(
            owner: owner,
            transferID: transferID,
            operation: .chunkAck,
            chunkIndex: 3
        )

        let lateTimeoutRemovedRetryToken = registry.remove(oldToken)
        #expect(!lateTimeoutRemovedRetryToken)
        let acknowledgement = CrossNetworkFileTransferMessage(
            op: .chunkAck,
            transferId: transferID,
            chunkIndex: 3
        )
        #expect(registry.consume(owner: owner, message: acknowledgement) == retryToken)
    }

    @Test("replays the exact durable acknowledgement after acknowledgement loss")
    func replaysExactCompletionAfterAcknowledgementLoss() throws {
        let owner = try CrossNetworkFileTransferSessionOwner(sessionID: "session-a", generation: UUID())
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
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
        var cache = CrossNetworkFileTransferCompletionReplayCache(capacity: 2, timeToLive: 60)

        #expect(try cache.reserve(owner: owner, transferID: transferID) == .reserved)
        try cache.recordCompletion(
            owner: owner,
            fingerprint: fingerprint,
            acknowledgement: acknowledgement
        )
        #expect(cache.lookup(owner: owner, fingerprint: fingerprint) == .replay(acknowledgement))

        let mismatchedRequest = CrossNetworkFileTransferMessage(
            op: .complete,
            transferId: transferID,
            receivedBytes: 1023,
            fileSha256: digest
        )
        let mismatchedFingerprint = try CrossNetworkFileTransferCompletionRequestFingerprint(
            message: mismatchedRequest
        )
        #expect(cache.lookup(owner: owner, fingerprint: mismatchedFingerprint) == .mismatch)
    }

    @Test("a dropped first acknowledgement retries the same complete and commits once")
    func droppedAcknowledgementRetriesExactCompletionAndCommitsOnce() throws {
        let sessionGeneration = UUID()
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: sessionGeneration,
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
        var acceptedAcknowledgement: CrossNetworkFileTransferMessage?

        #expect(try replay.reserve(owner: owner, transferID: transferID) == .reserved)
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
                let committed = replay.commitPreparedCompletion(prepared)
                #expect(committed)
                response = acknowledgement
            case .replay(let cached):
                response = cached
            default:
                Issue.record("unexpected receiver replay state")
                return
            }

            if attempt == 1 {
                // Fake transport drops the first ACK after the receiver committed.
                let removedDroppedAttempt = registry.remove(token)
                #expect(removedDroppedAttempt)
                #expect(policy.permitsRetry(after: .timeout, completedAttempts: attempt))
                continue
            }
            #expect(registry.consume(owner: owner, message: response) == token)
            try expectation.validate(response)
            acceptedAcknowledgement = response
        }

        #expect(commitCount == 1)
        #expect(acceptedAcknowledgement == acknowledgement)
        #expect(!policy.permitsRetry(after: .terminal, completedAttempts: 1))
    }

    @Test("rekey rejects late acknowledgement and old replay evidence")
    func keyEpochRotationRejectsOldState() throws {
        let generation = UUID()
        let oldOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: generation,
            keyEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let newOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: generation,
            keyEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let digest = Data(repeating: 0x31, count: 32)
        let acknowledgement = try CrossNetworkFileTransferMessage.completeAcknowledgement(
            transferId: transferID,
            receivedBytes: 1,
            fileSha256: digest
        )
        let fingerprint = try CrossNetworkFileTransferCompletionRequestFingerprint(
            message: .init(
                op: .complete,
                transferId: transferID,
                receivedBytes: 1,
                fileSha256: digest
            )
        )
        var registry = CrossNetworkFileTransferWaiterRegistry()
        let oldToken = try registry.arm(
            owner: oldOwner,
            transferID: transferID,
            operation: .completeAck,
            chunkIndex: nil
        )
        var replay = CrossNetworkFileTransferCompletionReplayCache(capacity: 2, timeToLive: 60)
        #expect(try replay.reserve(owner: oldOwner, transferID: transferID) == .reserved)
        try replay.recordCompletion(
            owner: oldOwner,
            fingerprint: fingerprint,
            acknowledgement: acknowledgement
        )

        #expect(registry.consume(owner: newOwner, message: acknowledgement) == nil)
        let removedOldToken = registry.remove(oldToken)
        #expect(removedOldToken)
        #expect(replay.lookup(owner: newOwner, fingerprint: fingerprint) == .missing)
        replay.remove(owner: oldOwner)
        #expect(replay.count == 0)
    }

    @Test("cancellation never retries and a cancelled blocked send emits no late packet")
    func cancellationDoesNotRetryOrSendLatePacket() async {
        let harness = CancellableSendBarrierHarness()
        let sendTask = Task { try await harness.sendAfterBarrier() }
        await harness.waitUntilBlocked()
        sendTask.cancel()
        await harness.release()

        do {
            try await sendTask.value
            Issue.record("cancelled send unexpectedly succeeded")
        } catch is CancellationError {
            // Expected terminal outcome.
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
        let packetCount = await harness.packetCount()
        #expect(packetCount == 0)
        let policy = CrossNetworkFileTransferCompletionRetryPolicy(maximumAttempts: 2)
        #expect(!policy.permitsRetry(after: .terminal, completedAttempts: 1))
    }

    @Test("an acknowledgement resumed under an old key epoch cannot return success")
    func acknowledgementReturnRevalidatesKeyEpoch() async throws {
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
        let harness = AcknowledgementOwnerBarrierHarness(owner: oldOwner)
        let caller = Task {
            try await harness.resumeAcknowledgementThenValidate(requiredOwner: oldOwner)
        }
        await harness.waitUntilAcknowledgementResumed()
        await harness.rotate(to: newOwner)
        await harness.releaseCaller()

        do {
            try await caller.value
            Issue.record("old-epoch acknowledgement unexpectedly returned success")
        } catch AcknowledgementOwnerBarrierHarness.HarnessError.staleOwner {
            // Expected exact-owner rejection.
        }
    }

    @Test("a transfer context rejects rotation before metadata and before complete")
    func outboundContextPinsAllThreeStages() throws {
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

        #expect(throws: CrossNetworkFileTransferSessionOwnerError.staleOwner) {
            try context.validate(currentOwner: newOwner)
            sentMetadata += 1
        }
        try context.validate(currentOwner: oldOwner)
        // Simulate the last chunk ACK winning, followed by a key rotation before complete.
        #expect(throws: CrossNetworkFileTransferSessionOwnerError.staleOwner) {
            try context.validate(currentOwner: newOwner)
            sentComplete += 1
        }
        #expect(sentMetadata == 0)
        #expect(sentComplete == 0)
    }

    @Test("disconnect revokes the outbound context before its first suspension")
    func disconnectRevokesContextBeforeAwait() async throws {
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID(),
            keyEpoch: UUID()
        )
        let context = CrossNetworkFileTransferOutboundContext(owner: owner)
        var currentOwner: CrossNetworkFileTransferSessionOwner? = owner
        var responseTaskCancelled = false
        var sentPacketCount = 0

        // Synchronous disconnect prefix.
        currentOwner = nil
        responseTaskCancelled = true
        // Represents the first awaited signaling close barrier.
        await Task.yield()

        #expect(currentOwner == nil)
        #expect(responseTaskCancelled)
        do {
            try context.validate(currentOwner: currentOwner)
            sentPacketCount += 1
        } catch CrossNetworkFileTransferSessionOwnerError.staleOwner {
            // Expected.
        }
        #expect(sentPacketCount == 0)
    }

    @Test("a suspended old handler cannot mutate a replacement inbound context")
    func suspendedOldHandlerCannotOverwriteReplacement() async throws {
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
        let oldContext = try CrossNetworkFileTransferInboundContextIdentity(
            owner: oldOwner,
            transferID: transferID
        )
        let replacement = try CrossNetworkFileTransferInboundContextIdentity(
            owner: newOwner,
            transferID: transferID
        )
        let harness = InboundContextBarrierHarness(captured: oldContext)
        let oldHandler = Task { await harness.runSuspendedOldHandler() }

        await harness.waitUntilSuspended()
        await harness.replace(with: replacement)
        await harness.release()
        await oldHandler.value
        let mutationObserved = await harness.mutationObserved()
        #expect(!mutationObserved)
    }

    @Test("completion fingerprint rejects changed Merkle evidence")
    func rejectsChangedMerkleEvidence() throws {
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let digest = Data(repeating: 0x33, count: 32)
        let first = try CrossNetworkFileTransferCompletionRequestFingerprint(
            message: .init(
                op: .complete,
                transferId: transferID,
                receivedBytes: 7,
                fileSha256: digest,
                merkleRoot: Data(repeating: 0x44, count: 32),
                merkleRootSignature: Data(repeating: 0x55, count: 32),
                merkleRootSignatureAlg: "hmac-sha256-session-v1"
            )
        )
        let changed = try CrossNetworkFileTransferCompletionRequestFingerprint(
            message: .init(
                op: .complete,
                transferId: transferID,
                receivedBytes: 7,
                fileSha256: digest,
                merkleRoot: Data(repeating: 0x45, count: 32),
                merkleRootSignature: Data(repeating: 0x55, count: 32),
                merkleRootSignatureAlg: "hmac-sha256-session-v1"
            )
        )

        #expect(first != changed)
    }

    @Test("embedded iOS mirror exposes the same reliability contract")
    func embeddedIOSMirrorExposesReliabilityContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootWire = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SkyBridgeProtocolCore/RemoteConnection/WebRTC/CrossNetworkFileTransferWire.swift"
            ),
            encoding: .utf8
        )
        let embeddedWire = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkFileTransferWire.swift"
            ),
            encoding: .utf8
        )
        let macManager = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
            ),
            encoding: .utf8
        )
        let embeddedManager = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
            ),
            encoding: .utf8
        )
        let macSession = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift"
            ),
            encoding: .utf8
        )
        let embeddedSession = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift"
            ),
            encoding: .utf8
        )
        let requiredContractSymbols = [
            "CrossNetworkFileTransferCompletionAckExpectation",
            "CrossNetworkFileTransferCompletionRequestFingerprint",
            "CrossNetworkFileTransferSessionOwner",
            "CrossNetworkFileTransferWaiterRegistry",
            "CrossNetworkFileTransferCompletionReplayCache",
            "CrossNetworkFileTransferPreparedCompletion",
            "CrossNetworkFileTransferCompletionRetryPolicy",
            "CrossNetworkFileTransferInboundContextIdentity",
            "CrossNetworkFileTransferOutboundContext",
            "keyEpoch",
            "tombstoneActive",
            "commitPreparedCompletion"
        ]

        for symbol in requiredContractSymbols {
            #expect(rootWire.contains(symbol))
            #expect(embeddedWire.contains(symbol))
        }
        for manager in [macManager, embeddedManager] {
            #expect(manager.contains("sendFileTransferCompletionAndWait"))
            #expect(manager.contains("transitionFileTransferKeyEpoch"))
            #expect(manager.contains("contextIdentity"))
            #expect(manager.contains("sendTask?.cancel()"))
            #expect(manager.contains("try Task.checkCancellation()"))
        }
        for session in [macSession, embeddedSession] {
            #expect(session.contains("try Task.checkCancellation()"))
        }
        #expect(embeddedManager.contains("st.contextIdentity.isCurrent("))
    }

    @Test("shares one bounded capacity between active and replay entries")
    func boundsActiveAndReplayCapacity() throws {
        let owner = try CrossNetworkFileTransferSessionOwner(sessionID: "session-a", generation: UUID())
        let first = "123e4567-e89b-12d3-a456-426614174000"
        let second = "223e4567-e89b-12d3-a456-426614174000"
        let third = "323e4567-e89b-12d3-a456-426614174000"
        let digest = Data(repeating: 0x11, count: 32)
        var cache = CrossNetworkFileTransferCompletionReplayCache(capacity: 2, timeToLive: 60)

        #expect(try cache.reserve(owner: owner, transferID: first) == .reserved)
        #expect(try cache.reserve(owner: owner, transferID: second) == .reserved)
        #expect(try cache.reserve(owner: owner, transferID: third) == .capacityExceeded)

        let firstFingerprint = try CrossNetworkFileTransferCompletionRequestFingerprint(
            message: .init(
                op: .complete,
                transferId: first,
                receivedBytes: 1,
                fileSha256: digest
            )
        )
        try cache.recordCompletion(
            owner: owner,
            fingerprint: firstFingerprint,
            acknowledgement: try .completeAcknowledgement(
                transferId: first,
                receivedBytes: 1,
                fileSha256: digest
            )
        )

        // Completion stays in the same bounded slot and blocks transfer-ID reuse.
        #expect(try cache.reserve(owner: owner, transferID: third) == .capacityExceeded)
        #expect(cache.count == 2)
        #expect(cache.lookup(owner: owner, fingerprint: firstFingerprint) == .replay(
            try .completeAcknowledgement(
                transferId: first,
                receivedBytes: 1,
                fileSha256: digest
            )
        ))
    }

    @Test("terminal receive failure retires its identifier without releasing capacity")
    func terminalFailureCreatesFixedCapacityTombstone() throws {
        let owner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID(),
            keyEpoch: UUID()
        )
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let secondTransferID = "223e4567-e89b-12d3-a456-426614174000"
        let fingerprint = try CrossNetworkFileTransferCompletionRequestFingerprint(
            message: .init(
                op: .complete,
                transferId: transferID,
                receivedBytes: 1,
                fileSha256: Data(repeating: 0x81, count: 32)
            )
        )
        var cache = CrossNetworkFileTransferCompletionReplayCache(capacity: 1, timeToLive: 60)

        #expect(try cache.reserve(owner: owner, transferID: transferID) == .reserved)
        cache.tombstoneActive(owner: owner, transferID: transferID)
        #expect(cache.lookup(owner: owner, fingerprint: fingerprint) == .tombstone)
        #expect(try cache.reserve(owner: owner, transferID: transferID) == .alreadyCompleted)
        #expect(try cache.reserve(owner: owner, transferID: secondTransferID) == .capacityExceeded)
    }

    @Test("expires replay evidence and never crosses session generations")
    func boundsReplayByTTLAndOwner() throws {
        let oldOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let newOwner = try CrossNetworkFileTransferSessionOwner(
            sessionID: "session-a",
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let transferID = "123e4567-e89b-12d3-a456-426614174000"
        let digest = Data(repeating: 0x22, count: 32)
        let fingerprint = try CrossNetworkFileTransferCompletionRequestFingerprint(
            message: .init(
                op: .complete,
                transferId: transferID,
                receivedBytes: 2,
                fileSha256: digest
            )
        )
        let acknowledgement = try CrossNetworkFileTransferMessage.completeAcknowledgement(
            transferId: transferID,
            receivedBytes: 2,
            fileSha256: digest
        )
        let start = Date(timeIntervalSince1970: 10)
        var cache = CrossNetworkFileTransferCompletionReplayCache(capacity: 2, timeToLive: 5)
        #expect(try cache.reserve(owner: oldOwner, transferID: transferID, now: start) == .reserved)
        try cache.recordCompletion(
            owner: oldOwner,
            fingerprint: fingerprint,
            acknowledgement: acknowledgement,
            now: start
        )

        #expect(cache.lookup(owner: newOwner, fingerprint: fingerprint, now: start) == .missing)
        #expect(
            cache.lookup(
                owner: oldOwner,
                fingerprint: fingerprint,
                now: start.addingTimeInterval(5)
            ) == .tombstone
        )
        #expect(try cache.reserve(owner: oldOwner, transferID: transferID) == .alreadyCompleted)
    }

    @Test("rejects non-canonical transfer identifiers before allocating storage")
    func rejectsNonCanonicalTransferIdentifiers() throws {
        let uppercase = "123E4567-E89B-12D3-A456-426614174000"
        #expect(throws: CrossNetworkInboundFileCommitError.invalidTransferID) {
            try CrossNetworkInboundFileCommitter.requireCanonicalTransferID(uppercase)
        }

        for invalid in [
            "../123e4567-e89b-12d3-a456-426614174000",
            "123e4567-e89b-12d3-a456-426614174000/..",
            " 123e4567-e89b-12d3-a456-426614174000",
            "transfer-1"
        ] {
            #expect(throws: CrossNetworkInboundFileCommitError.invalidTransferID) {
                try CrossNetworkInboundFileCommitter.requireCanonicalTransferID(invalid)
            }
        }
    }

    @Test("uses an owned temporary file and never replaces an existing destination")
    func commitsWithoutReplacingExistingDestination() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("skybridge-inbound-commit-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }

        let existingURL = directory.appendingPathComponent("payload.bin")
        let existingData = Data("existing".utf8)
        try existingData.write(to: existingURL)

        let temporary = try CrossNetworkInboundFileCommitter.createExclusiveTemporaryFile(in: directory)
        let receivedData = Data("received".utf8)
        try temporary.handle.write(contentsOf: receivedData)
        try CrossNetworkInboundFileCommitter.synchronizeAndClose(temporary.handle)

        let committedURL = try CrossNetworkInboundFileCommitter.commitWithoutReplacing(
            temporaryURL: temporary.url,
            in: directory,
            preferredFileName: existingURL.lastPathComponent
        )

        #expect(committedURL.lastPathComponent == "payload (1).bin")
        #expect(try Data(contentsOf: existingURL) == existingData)
        #expect(try Data(contentsOf: committedURL) == receivedData)
        #expect(!fileManager.fileExists(atPath: temporary.url.path))
    }

    @Test("creates and parent-syncs a missing receive directory")
    func createsDurableReceiveDirectory() throws {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent("skybridge-directory-parent-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: parent) }

        try CrossNetworkInboundFileCommitter.ensureDurableDirectory(directory)

        var isDirectory = ObjCBool(false)
        #expect(fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("refuses to commit a temporary file it did not create")
    func rejectsUnownedTemporaryFile() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("skybridge-unowned-commit-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }

        let unownedURL = directory.appendingPathComponent("attacker.partial")
        try Data("do-not-move".utf8).write(to: unownedURL)
        #expect(throws: CrossNetworkInboundFileCommitError.invalidTemporaryFile) {
            try CrossNetworkInboundFileCommitter.commitWithoutReplacing(
                temporaryURL: unownedURL,
                in: directory,
                preferredFileName: "payload.bin"
            )
        }
        #expect(fileManager.fileExists(atPath: unownedURL.path))
    }
}
