import CryptoKit
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class WebRTCInboundFileTransferReceiverTests: XCTestCase {
    func testMetadataAckCannotEnterInboundRequestQueue() {
        assertInvalidQueuedOperationRejected(.metadataAck)
    }

    func testErrorCannotEnterInboundRequestQueue() {
        assertInvalidQueuedOperationRejected(.error)
    }

    func testChunkAckCannotEnterInboundRequestQueue() {
        assertInvalidQueuedOperationRejected(.chunkAck)
    }

    func testCompleteAckCannotEnterInboundRequestQueue() {
        assertInvalidQueuedOperationRejected(.completeAck)
    }

    func testMetadataAckUsesInjectedDestinationAndCleanupRemovesPartial() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(destinationBaseDirectory: { fixture.directory })
        var sent: [(CrossNetworkFileTransferMessage, String)] = []

        try await receiver.handle(
            metadata(transferId: transferId, fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )

        XCTAssertEqual(sent.map(\.0.op), [.metadataAck])
        XCTAssertEqual(sent.map(\.1), ["tx/webrtc-ft-metaAck"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))

        await receiver.cleanupOnChannelClosed().value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
    }

    func testInvalidMetadataSendsErrorWithoutCreatingPartial() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(destinationBaseDirectory: { fixture.directory })
        var sent: [(CrossNetworkFileTransferMessage, String)] = []

        try await receiver.handle(
            metadata(transferId: transferId, fileName: "   ", fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("invalid metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("invalid metadata must not resume outbound waiters") }
        )

        XCTAssertEqual(sent.last?.0.op, .error)
        XCTAssertEqual(sent.last?.0.message, "Invalid metadata (empty fileName)")
        XCTAssertEqual(sent.last?.1, "tx/webrtc-ft-error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
    }

    func testMetadataWithoutExplicitApprovalSendsErrorWithoutCreatingPartial() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
            senderAuthorityProvider: { _ in Self.senderAuthority() }
        )
        var sent: [(CrossNetworkFileTransferMessage, String)] = []

        try await receiver.handle(
            metadata(transferId: transferId, fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("approval rejection must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("approval rejection must not resume outbound waiters") }
        )

        XCTAssertEqual(sent.map(\.0.op), [.error])
        XCTAssertEqual(sent.last?.0.message, WebRTCInboundFileTransferSupport.explicitApprovalRequiredMessage)
        XCTAssertEqual(sent.last?.1, "tx/webrtc-ft-error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
    }

    func testMetadataMissingSenderIdentityFailsClosedBeforeApproval() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        var approvalCalled = false
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
            senderAuthorityProvider: { _ in Self.senderAuthority() },
            approvalProvider: { _ in
                approvalCalled = true
                return .approved
            }
        )
        var sent: [(CrossNetworkFileTransferMessage, String)] = []

        try await receiver.handle(
            metadata(transferId: transferId, senderDeviceId: nil, fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "endpoint-peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("missing sender identity must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("missing sender identity must not resume outbound waiters") }
        )

        XCTAssertFalse(approvalCalled)
        XCTAssertEqual(sent.map(\.0.op), [.error])
        XCTAssertEqual(sent.last?.0.message, WebRTCInboundFileTransferSupport.missingSenderIdentityMessage)
        XCTAssertEqual(sent.last?.1, "tx/webrtc-ft-error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
    }

    func testMetadataBlankSenderIdentityFailsClosedBeforeApproval() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        var approvalCalled = false
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
            senderAuthorityProvider: { _ in Self.senderAuthority() },
            approvalProvider: { _ in
                approvalCalled = true
                return .approved
            }
        )
        var sent: [(CrossNetworkFileTransferMessage, String)] = []

        try await receiver.handle(
            metadata(transferId: transferId, senderDeviceId: " \n\t ", fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "endpoint-peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("blank sender identity must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("blank sender identity must not resume outbound waiters") }
        )

        XCTAssertFalse(approvalCalled)
        XCTAssertEqual(sent.map(\.0.op), [.error])
        XCTAssertEqual(sent.last?.0.message, WebRTCInboundFileTransferSupport.missingSenderIdentityMessage)
        XCTAssertEqual(sent.last?.1, "tx/webrtc-ft-error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
    }

    func testMetadataSenderClaimMustMatchAuthenticatedSessionAuthority() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        var approvalCalled = false
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
            senderAuthorityProvider: { _ in Self.senderAuthority() },
            approvalProvider: { _ in
                approvalCalled = true
                return .approved
            }
        )
        var sent: [CrossNetworkFileTransferMessage] = []

        try await receiver.handle(
            metadata(
                transferId: transferId,
                senderDeviceId: "spoofed-sender",
                fileSize: 4,
                chunkSize: 2,
                totalChunks: 2
            ),
            sessionID: "session",
            endpointDescription: "endpoint-peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, _ in sent.append(message) },
            failSenderWaiters: { _, _ in XCTFail("sender mismatch must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("sender mismatch must not resume outbound waiters") }
        )

        XCTAssertFalse(approvalCalled)
        XCTAssertEqual(sent.last?.op, .error)
        XCTAssertEqual(sent.last?.message, "sender identity does not match authenticated session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
    }

    func testMetadataApprovalProviderReceivesValidatedMetadataBeforePartialCreation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        var capturedRequest: WebRTCInboundFileTransferApprovalRequest?
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
            senderAuthorityProvider: { _ in Self.senderAuthority() },
            approvalProvider: { request in
                capturedRequest = request
                return .rejected(reason: "operator_rejected")
            }
        )
        var sent: [(CrossNetworkFileTransferMessage, String)] = []

        try await receiver.handle(
            metadata(transferId: transferId, fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "endpoint-peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("approval rejection must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("approval rejection must not resume outbound waiters") }
        )

        XCTAssertEqual(capturedRequest?.transferId, transferId)
        XCTAssertEqual(capturedRequest?.fileName, "payload.bin")
        XCTAssertEqual(capturedRequest?.senderDeviceId, "sender")
        XCTAssertEqual(capturedRequest?.senderDeviceName, "Sender")
        XCTAssertEqual(capturedRequest?.endpointDescription, "endpoint-peer")
        XCTAssertEqual(capturedRequest?.destinationDirectoryPath, fixture.directory.path)
        XCTAssertEqual(capturedRequest?.proposedSavePath, fixture.directory.appendingPathComponent("payload.bin").path)
        XCTAssertEqual(sent.last?.0.message, "operator_rejected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
    }

    func testApprovalCompletingAfterChannelCleanupCannotCreateTransferOrAck() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let approvalStarted = expectation(description: "approval started")
        var approvalContinuation: CheckedContinuation<WebRTCInboundFileTransferApprovalDecision, Never>?
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
            senderAuthorityProvider: { _ in Self.senderAuthority() },
            approvalProvider: { _ in
                approvalStarted.fulfill()
                return await withCheckedContinuation { continuation in
                    approvalContinuation = continuation
                }
            }
        )
        var sent: [CrossNetworkFileTransferMessage] = []

        let handlingTask = Task { @MainActor in
            try await receiver.handle(
                metadata(transferId: transferId, fileSize: 4, chunkSize: 2, totalChunks: 2),
                sessionID: "session",
                endpointDescription: "peer",
                keys: Self.sessionKeys(),
                sendMessage: { message, _ in sent.append(message) },
                failSenderWaiters: { _, _ in XCTFail("stale approval must not fail outbound waiters") },
                resumeSenderWaiter: { _ in XCTFail("stale approval must not resume outbound waiters") }
            )
        }

        await fulfillment(of: [approvalStarted], timeout: 1)
        await receiver.cleanupOnChannelClosed().value
        approvalContinuation?.resume(returning: .approved)
        try await handlingTask.value

        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
    }

    func testQueuedTransferApprovalDoesNotBlockIndependentTransferLane() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let suspendedTransferID = UUID().uuidString
        let independentTransferID = UUID().uuidString
        let suspendedApprovalStarted = expectation(description: "suspended approval started")
        let independentResponseSent = expectation(description: "independent transfer received a response")
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
            senderAuthorityProvider: { _ in Self.senderAuthority() },
            approvalProvider: { request in
                if request.transferId == suspendedTransferID {
                    suspendedApprovalStarted.fulfill()
                    do {
                        try await Task.sleep(for: .seconds(30))
                        XCTFail("The suspended lane must be cancelled during test cleanup")
                    } catch is CancellationError {
                        return .approved
                    } catch {
                        XCTFail("Unexpected suspended approval error: \(error)")
                    }
                    return .rejected(reason: "unexpected_approval_completion")
                }
                XCTAssertEqual(request.transferId, independentTransferID)
                return .rejected(reason: "independent_transfer_rejected")
            }
        )
        var responsesByTransferID: [String: [CrossNetworkFileTransferMessage]] = [:]
        let sendMessage: WebRTCInboundFileTransferReceiver.SendMessage = { message, _ in
            responsesByTransferID[message.transferId, default: []].append(message)
            if message.transferId == independentTransferID {
                independentResponseSent.fulfill()
            }
        }

        try receiver.enqueueInboundRequest(
            metadata(
                transferId: suspendedTransferID,
                fileSize: 4,
                chunkSize: 4,
                totalChunks: 1
            ),
            encodedPayloadByteCount: 256,
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: sendMessage,
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") },
            onFatalError: { error in XCTFail("Queued metadata failed: \(error)") }
        )
        await fulfillment(of: [suspendedApprovalStarted], timeout: 1)

        try receiver.enqueueInboundRequest(
            metadata(
                transferId: independentTransferID,
                fileSize: 4,
                chunkSize: 4,
                totalChunks: 1
            ),
            encodedPayloadByteCount: 256,
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: sendMessage,
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") },
            onFatalError: { error in XCTFail("Queued metadata failed: \(error)") }
        )
        await fulfillment(of: [independentResponseSent], timeout: 1)

        XCTAssertTrue(responsesByTransferID[suspendedTransferID, default: []].isEmpty)
        XCTAssertEqual(responsesByTransferID[independentTransferID]?.map(\.op), [.error])
        XCTAssertEqual(
            responsesByTransferID[independentTransferID]?.last?.message,
            "independent_transfer_rejected"
        )

        await receiver.cleanupOnChannelClosed().value
    }

    func testChannelCleanupCancelsAndJoinsEveryActiveTransferLane() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferIDs = [UUID().uuidString, UUID().uuidString]
        let firstApprovalStarted = expectation(description: "first approval started")
        let secondApprovalStarted = expectation(description: "second approval started")
        var cancelledApprovalIDs = Set<String>()
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
            senderAuthorityProvider: { _ in Self.senderAuthority() },
            approvalProvider: { request in
                if request.transferId == transferIDs[0] {
                    firstApprovalStarted.fulfill()
                } else if request.transferId == transferIDs[1] {
                    secondApprovalStarted.fulfill()
                } else {
                    XCTFail("Unexpected transfer lane: \(request.transferId)")
                }
                do {
                    try await Task.sleep(for: .seconds(30))
                    XCTFail("Channel cleanup must cancel every suspended approval lane")
                } catch is CancellationError {
                    cancelledApprovalIDs.insert(request.transferId)
                } catch {
                    XCTFail("Unexpected approval error: \(error)")
                }
                return .approved
            }
        )
        var sentMessages: [CrossNetworkFileTransferMessage] = []

        for transferID in transferIDs {
            try receiver.enqueueInboundRequest(
                metadata(
                    transferId: transferID,
                    fileSize: 4,
                    chunkSize: 4,
                    totalChunks: 1
                ),
                encodedPayloadByteCount: 256,
                sessionID: "session",
                endpointDescription: "peer",
                keys: Self.sessionKeys(),
                sendMessage: { message, _ in sentMessages.append(message) },
                failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
                resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") },
                onFatalError: { error in XCTFail("Queued metadata failed: \(error)") }
            )
        }
        await fulfillment(of: [firstApprovalStarted, secondApprovalStarted], timeout: 1)

        await receiver.cleanupOnChannelClosed().value

        XCTAssertEqual(cancelledApprovalIDs, Set(transferIDs))
        XCTAssertTrue(sentMessages.isEmpty)
        for transferID in transferIDs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferID).path))
        }
    }

    func testRetainedByteBudgetIncludesActiveAndQueuedOperationsUntilCleanup() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let approvalStarted = expectation(description: "approval started")
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
            maxConcurrentInboundTransfers: 1,
            maxGlobalConcurrentInboundTransfers: 1,
            senderAuthorityProvider: { _ in Self.senderAuthority() },
            approvalProvider: { _ in
                approvalStarted.fulfill()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch is CancellationError {
                    return .approved
                } catch {
                    XCTFail("Unexpected approval wait error: \(error)")
                }
                return .rejected(reason: "unexpected approval completion")
            }
        )
        let transferID = UUID().uuidString
        let metadataCharge = 256

        try receiver.enqueueInboundRequest(
            metadata(
                transferId: transferID,
                fileSize: 1,
                chunkSize: 1,
                totalChunks: 1
            ),
            encodedPayloadByteCount: metadataCharge,
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { _, _ in },
            failSenderWaiters: { _, _ in },
            resumeSenderWaiter: { _ in },
            onFatalError: { error in XCTFail("Queued operation failed: \(error)") }
        )
        await fulfillment(of: [approvalStarted], timeout: 1)

        let maximumFrameBytes = CrossNetworkFileTransferWireDecoder
            .maximumEncodedPayloadByteCount
        let queuedChunk = chunk(
            transferId: transferID,
            index: 0,
            data: Data([0x01])
        )
        let fullFrameCount = (
            CrossNetworkFileTransferInboundAdmissionPolicy.maximumRetainedOperationBytes
                - metadataCharge
        ) / maximumFrameBytes
        for _ in 0..<fullFrameCount {
            try receiver.enqueueInboundRequest(
                queuedChunk,
                encodedPayloadByteCount: maximumFrameBytes,
                sessionID: "session",
                endpointDescription: "peer",
                keys: Self.sessionKeys(),
                sendMessage: { _, _ in },
                failSenderWaiters: { _, _ in },
                resumeSenderWaiter: { _ in },
                onFatalError: { error in XCTFail("Queued operation failed: \(error)") }
            )
        }
        let exactRemainder = CrossNetworkFileTransferInboundAdmissionPolicy
            .maximumRetainedOperationBytes - receiver.retainedInboundOperationByteCount
        try receiver.enqueueInboundRequest(
            queuedChunk,
            encodedPayloadByteCount: exactRemainder,
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { _, _ in },
            failSenderWaiters: { _, _ in },
            resumeSenderWaiter: { _ in },
            onFatalError: { error in XCTFail("Queued operation failed: \(error)") }
        )

        XCTAssertEqual(
            receiver.retainedInboundOperationByteCount,
            CrossNetworkFileTransferInboundAdmissionPolicy.maximumRetainedOperationBytes
        )
        XCTAssertEqual(receiver.retainedInboundOperationCount, fullFrameCount + 2)
        XCTAssertThrowsError(
            try receiver.enqueueInboundRequest(
                queuedChunk,
                encodedPayloadByteCount: 1,
                sessionID: "session",
                endpointDescription: "peer",
                keys: Self.sessionKeys(),
                sendMessage: { _, _ in },
                failSenderWaiters: { _, _ in },
                resumeSenderWaiter: { _ in },
                onFatalError: { _ in }
            )
        ) { error in
            guard case WebRTCInboundFileTransferReceiver.InboundOperationQueueError
                .retainedByteCapacityExceeded = error else {
                return XCTFail("Expected retained-byte rejection, got \(error)")
            }
        }

        await receiver.cleanupOnChannelClosed().value

        XCTAssertEqual(receiver.retainedInboundOperationCount, 0)
        XCTAssertEqual(receiver.retainedInboundOperationByteCount, 0)
    }

    func testActiveLaneLimitCannotExceedSessionGlobalOrHardCeiling() {
        XCTAssertEqual(
            WebRTCInboundFileTransferReceiver.activeInboundOperationLaneLimit(
                sessionLimit: 8,
                globalLimit: 16
            ),
            8
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferReceiver.activeInboundOperationLaneLimit(
                sessionLimit: 20,
                globalLimit: 10
            ),
            10
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferReceiver.activeInboundOperationLaneLimit(
                sessionLimit: 64,
                globalLimit: 100
            ),
            32
        )
    }

    func testCompletedOperationReleasesReservationBeforeWorkerExit() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let responseSent = expectation(description: "rejection response sent")
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
            senderAuthorityProvider: { _ in Self.senderAuthority() },
            approvalProvider: { _ in .rejected(reason: "operator_rejected") }
        )

        try receiver.enqueueInboundRequest(
            metadata(
                transferId: UUID().uuidString,
                fileSize: 1,
                chunkSize: 1,
                totalChunks: 1
            ),
            encodedPayloadByteCount: CrossNetworkFileTransferWireDecoder
                .maximumEncodedPayloadByteCount,
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, _ in
                XCTAssertEqual(message.op, .error)
                responseSent.fulfill()
            },
            failSenderWaiters: { _, _ in },
            resumeSenderWaiter: { _ in },
            onFatalError: { error in XCTFail("Operation failed: \(error)") }
        )
        XCTAssertEqual(receiver.retainedInboundOperationCount, 1)

        await fulfillment(of: [responseSent], timeout: 1)
        await Task.yield()

        XCTAssertEqual(receiver.retainedInboundOperationCount, 0)
        XCTAssertEqual(receiver.retainedInboundOperationByteCount, 0)
        await receiver.cleanupOnChannelClosed().value
    }

    func testFatalLaneReleasesActiveAndPendingReservationsExactlyOnce() async throws {
        enum InjectedFailure: Error { case sendFailed }

        let fatalSendStarted = expectation(description: "fatal send started")
        let fatalReported = expectation(description: "fatal error reported")
        var resumeFatalSend: CheckedContinuation<Void, Never>?
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { nil },
            maxConcurrentInboundTransfers: 1,
            maxGlobalConcurrentInboundTransfers: 1,
            senderAuthorityProvider: { _ in Self.senderAuthority() }
        )
        let transferID = UUID().uuidString
        let sendMessage: WebRTCInboundFileTransferReceiver.SendMessage = { _, _ in
            fatalSendStarted.fulfill()
            await withCheckedContinuation { continuation in
                resumeFatalSend = continuation
            }
            throw InjectedFailure.sendFailed
        }
        let onFatalError: @MainActor (Error) -> Void = { error in
            guard error is InjectedFailure else {
                return XCTFail("Expected injected failure, got \(error)")
            }
            fatalReported.fulfill()
        }

        try receiver.enqueueInboundRequest(
            metadata(
                transferId: transferID,
                fileSize: 1,
                chunkSize: 1,
                totalChunks: 1
            ),
            encodedPayloadByteCount: 1_024,
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: sendMessage,
            failSenderWaiters: { _, _ in },
            resumeSenderWaiter: { _ in },
            onFatalError: onFatalError
        )
        await fulfillment(of: [fatalSendStarted], timeout: 1)
        try receiver.enqueueInboundRequest(
            CrossNetworkFileTransferMessage(
                op: .cancel,
                transferId: transferID,
                message: "sender cancelled"
            ),
            encodedPayloadByteCount: 512,
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: sendMessage,
            failSenderWaiters: { _, _ in },
            resumeSenderWaiter: { _ in },
            onFatalError: onFatalError
        )
        XCTAssertEqual(receiver.retainedInboundOperationCount, 2)
        XCTAssertEqual(receiver.retainedInboundOperationByteCount, 1_536)

        resumeFatalSend?.resume()
        await fulfillment(of: [fatalReported], timeout: 1)
        await Task.yield()

        XCTAssertEqual(receiver.retainedInboundOperationCount, 0)
        XCTAssertEqual(receiver.retainedInboundOperationByteCount, 0)
        await receiver.cleanupOnChannelClosed().value
        XCTAssertEqual(receiver.retainedInboundOperationCount, 0)
        XCTAssertEqual(receiver.retainedInboundOperationByteCount, 0)
    }

    #if os(macOS)
    func testFileTransferManagerMapsFileApprovalToWebRTCInboundDecision() {
        XCTAssertEqual(
            FileTransferManager.webRTCInboundFileTransferApprovalDecision(from: InboundFileTransferApprovalService.Decision.allowOnce),
            .approved
        )
        XCTAssertEqual(
            FileTransferManager.webRTCInboundFileTransferApprovalDecision(from: InboundFileTransferApprovalService.Decision.reject),
            .rejected(reason: "operator_rejected_inbound_file_transfer")
        )
    }
    #endif

    func testCrossNetworkManagerInjectsProductApprovalProviderForInboundReceiver() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")

        XCTAssertTrue(
            source.contains("let inboundFileTransferReceiver = WebRTCInboundFileTransferReceiver(") &&
                source.contains("senderAuthorityProvider: { [weak self] requestedSessionID in") &&
                source.contains("currentPathExpectedRemoteAuthorityBySessionId[requestedSessionID]") &&
                source.contains("approvalProvider: { request in") &&
                source.contains("await FileTransferManager.shared.approveInboundWebRTCFileTransfer(request)"),
            "CrossNetworkConnectionManager must route WebRTC inbound metadata through the product approval provider instead of leaving the receiver on its default reject-only policy."
        )
    }

    func testConcurrentMetadataLimitRejectsNewPartialFiles() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let firstTransferId = UUID().uuidString
        let secondTransferId = UUID().uuidString
        let receiver = approvedReceiver(
            destinationBaseDirectory: { fixture.directory },
            maxConcurrentInboundTransfers: 1
        )
        var sent: [(CrossNetworkFileTransferMessage, String)] = []

        try await receiver.handle(
            metadata(transferId: firstTransferId, fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )
        try await receiver.handle(
            metadata(transferId: secondTransferId, fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("over-cap metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("over-cap metadata must not resume outbound waiters") }
        )

        XCTAssertEqual(sent.map(\.0.op), [.metadataAck, .error])
        XCTAssertEqual(sent.last?.0.transferId, secondTransferId)
        XCTAssertEqual(sent.last?.0.message, "Too many concurrent inbound file transfers")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partialURL(firstTransferId).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(secondTransferId).path))

        await receiver.cleanupOnChannelClosed().value
    }

    func testGlobalConcurrentMetadataLimitSpansReceiverInstances() async throws {
        let firstFixture = try makeFixture()
        let secondFixture = try makeFixture()
        defer {
            firstFixture.cleanup()
            secondFixture.cleanup()
        }

        let ledger = WebRTCInboundFileTransferAdmissionLedger()
        let firstReceiver = approvedReceiver(
            destinationBaseDirectory: { firstFixture.directory },
            maxGlobalConcurrentInboundTransfers: 1,
            admissionLedger: ledger
        )
        let secondReceiver = approvedReceiver(
            destinationBaseDirectory: { secondFixture.directory },
            maxGlobalConcurrentInboundTransfers: 1,
            admissionLedger: ledger
        )
        var secondResponses: [CrossNetworkFileTransferMessage] = []

        try await firstReceiver.handle(
            metadata(transferId: UUID().uuidString, fileSize: 4, chunkSize: 4, totalChunks: 1),
            sessionID: "session-a",
            endpointDescription: "peer-a",
            keys: Self.sessionKeys(sessionID: "session-a"),
            sendMessage: { _, _ in },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )
        let rejectedTransferID = UUID().uuidString
        try await secondReceiver.handle(
            metadata(transferId: rejectedTransferID, fileSize: 4, chunkSize: 4, totalChunks: 1),
            sessionID: "session-b",
            endpointDescription: "peer-b",
            keys: Self.sessionKeys(sessionID: "session-b"),
            sendMessage: { message, _ in secondResponses.append(message) },
            failSenderWaiters: { _, _ in XCTFail("global limit must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("global limit must not resume outbound waiters") }
        )

        XCTAssertEqual(secondResponses.last?.op, .error)
        XCTAssertEqual(secondResponses.last?.message, "Global inbound file transfer limit reached")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondFixture.partialURL(rejectedTransferID).path))
        await firstReceiver.cleanupOnChannelClosed().value
        await secondReceiver.cleanupOnChannelClosed().value
    }

    func testIdleTimeoutClosesAndRemovesPartialTransfer() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(
            destinationBaseDirectory: { fixture.directory },
            transferIdleTimeout: .milliseconds(50)
        )
        var sent: [(CrossNetworkFileTransferMessage, String)] = []

        try await receiver.handle(
            metadata(transferId: transferId, fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
    }

    func testRefreshingIdleTimeoutDoesNotLetCancelledTimerDeleteActiveTransfer() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(
            destinationBaseDirectory: { fixture.directory },
            transferIdleTimeout: .milliseconds(200)
        )

        try await receiver.handle(
            metadata(transferId: transferId, fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { _, _ in },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )
        try await Task.sleep(for: .milliseconds(120))
        try await receiver.handle(
            chunk(transferId: transferId, index: 0, data: Data("ab".utf8)),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { _, _ in },
            failSenderWaiters: { _, _ in XCTFail("chunk must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("chunk must not resume outbound waiters") }
        )
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path),
            "The cancelled metadata timer must not wake and delete a transfer whose chunk refreshed the idle deadline"
        )
        await receiver.cleanupOnChannelClosed().value
    }

    func testChunkHashMismatchSendsErrorWithoutDroppingTransfer() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(destinationBaseDirectory: { fixture.directory })
        var sent: [(CrossNetworkFileTransferMessage, String)] = []

        try await receiver.handle(
            metadata(transferId: transferId, fileSize: 4, chunkSize: 4, totalChunks: 1),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("chunk mismatch must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("chunk mismatch must not resume outbound waiters") }
        )

        try await receiver.handle(
            CrossNetworkFileTransferMessage(
                op: .chunk,
                transferId: transferId,
                chunkIndex: 0,
                chunkData: Data("test".utf8),
                chunkSha256: Data(repeating: 0, count: 32),
                rawSize: 4
            ),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("chunk mismatch must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("chunk mismatch must not resume outbound waiters") }
        )

        XCTAssertEqual(sent.last?.0.op, .error)
        XCTAssertEqual(sent.last?.0.chunkIndex, 0)
        XCTAssertEqual(sent.last?.0.message, "chunk hash mismatch")
        XCTAssertEqual(sent.last?.1, "tx/webrtc-ft-error")

        await receiver.cleanupOnChannelClosed().value
    }

    func testCompleteWithMissingChunkRequestsMissingChunks() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(destinationBaseDirectory: { fixture.directory })
        var sent: [(CrossNetworkFileTransferMessage, String)] = []
        let keys = Self.sessionKeys()
        let firstChunk = Data("ab".utf8)

        try await receiver.handle(
            metadata(transferId: transferId, fileSize: 4, chunkSize: 2, totalChunks: 2),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )
        try await receiver.handle(
            chunk(transferId: transferId, index: 0, data: firstChunk),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("chunk must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("chunk must not resume outbound waiters") }
        )
        try await receiver.handle(
            CrossNetworkFileTransferMessage(
                op: .complete,
                transferId: transferId,
                receivedBytes: 4,
                fileSha256: Data(SHA256.hash(data: Data("abcd".utf8)))
            ),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("complete must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("complete must not resume outbound waiters") }
        )

        XCTAssertEqual(sent.last?.0.op, .chunkAck)
        XCTAssertEqual(sent.last?.0.missingChunks, [1])
        XCTAssertEqual(sent.last?.0.message, "missingChunks")
        XCTAssertEqual(sent.last?.1, "tx/webrtc-ft-missingChunks")

        await receiver.cleanupOnChannelClosed().value
    }

    func testCompleteMovesFileAndSendsCompleteAck() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(destinationBaseDirectory: { fixture.directory })
        var sent: [(CrossNetworkFileTransferMessage, String)] = []
        let keys = Self.sessionKeys()
        let payload = Data("abcd".utf8)
        let payloadHash = Data(SHA256.hash(data: payload))

        try await receiver.handle(
            metadata(transferId: transferId, fileSize: Int64(payload.count), chunkSize: payload.count, totalChunks: 1),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )
        try await receiver.handle(
            chunk(transferId: transferId, index: 0, data: payload),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("chunk must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("chunk must not resume outbound waiters") }
        )
        try await receiver.handle(
            CrossNetworkFileTransferMessage(
                op: .complete,
                transferId: transferId,
                receivedBytes: Int64(payload.count),
                fileSha256: payloadHash
            ),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("complete must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("complete must not resume outbound waiters") }
        )

        XCTAssertEqual(sent.last?.0.op, .completeAck)
        XCTAssertEqual(sent.last?.0.receivedBytes, Int64(payload.count))
        XCTAssertEqual(sent.last?.0.fileSha256, payloadHash)
        XCTAssertEqual(sent.last?.1, "tx/webrtc-ft-completeAck")
        XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("payload.bin")), payload)
    }

    func testLostCompleteAckIsReplayedExactlyWithoutReprocessingSavedFile() async throws {
        enum SendFailure: Error { case injected }

        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(destinationBaseDirectory: { fixture.directory })
        let keys = Self.sessionKeys()
        let payload = Data("terminal-receipt".utf8)
        let payloadHash = Data(SHA256.hash(data: payload))
        let complete = CrossNetworkFileTransferMessage(
            op: .complete,
            transferId: transferId,
            receivedBytes: Int64(payload.count),
            fileSha256: payloadHash
        )

        try await receiver.handle(
            metadata(
                transferId: transferId,
                fileSize: Int64(payload.count),
                chunkSize: payload.count,
                totalChunks: 1
            ),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { _, _ in },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )
        try await receiver.handle(
            chunk(transferId: transferId, index: 0, data: payload),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { _, _ in },
            failSenderWaiters: { _, _ in XCTFail("chunk must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("chunk must not resume outbound waiters") }
        )

        var firstReceipt: (CrossNetworkFileTransferMessage, String)?
        try await receiver.handle(
            complete,
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in
                firstReceipt = (message, label)
                throw SendFailure.injected
            },
            failSenderWaiters: { _, _ in XCTFail("complete must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("complete must not resume outbound waiters") }
        )

        var replayedReceipt: (CrossNetworkFileTransferMessage, String)?
        try await receiver.handle(
            complete,
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in replayedReceipt = (message, label) },
            failSenderWaiters: { _, _ in XCTFail("complete retry must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("complete retry must not resume outbound waiters") }
        )

        XCTAssertEqual(firstReceipt?.0.op, .completeAck)
        XCTAssertEqual(replayedReceipt?.0.op, firstReceipt?.0.op)
        XCTAssertEqual(replayedReceipt?.0.transferId, firstReceipt?.0.transferId)
        XCTAssertEqual(replayedReceipt?.0.receivedBytes, firstReceipt?.0.receivedBytes)
        XCTAssertEqual(replayedReceipt?.0.fileSha256, firstReceipt?.0.fileSha256)
        XCTAssertEqual(replayedReceipt?.1, firstReceipt?.1)
        XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("payload.bin")), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("payload (1).bin").path))
    }

    func testLostTerminalIntegrityErrorIsReplayedExactly() async throws {
        enum SendFailure: Error { case injected }

        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(destinationBaseDirectory: { fixture.directory })
        let keys = Self.sessionKeys()
        let payload = Data("abcd".utf8)
        let complete = CrossNetworkFileTransferMessage(
            op: .complete,
            transferId: transferId,
            receivedBytes: Int64(payload.count),
            fileSha256: Data(repeating: 0, count: 32)
        )

        try await receiver.handle(
            metadata(
                transferId: transferId,
                fileSize: Int64(payload.count),
                chunkSize: payload.count,
                totalChunks: 1
            ),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { _, _ in },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )
        try await receiver.handle(
            chunk(transferId: transferId, index: 0, data: payload),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { _, _ in },
            failSenderWaiters: { _, _ in XCTFail("chunk must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("chunk must not resume outbound waiters") }
        )

        var firstError: (CrossNetworkFileTransferMessage, String)?
        try await receiver.handle(
            complete,
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in
                firstError = (message, label)
                throw SendFailure.injected
            },
            failSenderWaiters: { _, _ in XCTFail("complete must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("complete must not resume outbound waiters") }
        )

        var replayedError: (CrossNetworkFileTransferMessage, String)?
        try await receiver.handle(
            complete,
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in replayedError = (message, label) },
            failSenderWaiters: { _, _ in XCTFail("complete retry must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("complete retry must not resume outbound waiters") }
        )

        XCTAssertEqual(firstError?.0.op, .error)
        XCTAssertEqual(firstError?.0.message, "file sha256 mismatch")
        XCTAssertEqual(replayedError?.0.op, firstError?.0.op)
        XCTAssertEqual(replayedError?.0.message, firstError?.0.message)
        XCTAssertEqual(replayedError?.1, firstError?.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
    }

    func testRepeatedTransferIdRejectsConflictingMetadataWithoutReplacingActiveTransfer() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(destinationBaseDirectory: { fixture.directory })
        var sent: [CrossNetworkFileTransferMessage] = []

        try await receiver.handle(
            metadata(transferId: transferId, fileSize: 4, chunkSize: 4, totalChunks: 1),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, _ in sent.append(message) },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )
        try await receiver.handle(
            metadata(
                transferId: transferId,
                fileName: "different.bin",
                fileSize: 4,
                chunkSize: 4,
                totalChunks: 1
            ),
            sessionID: "session",
            endpointDescription: "peer",
            keys: Self.sessionKeys(),
            sendMessage: { message, _ in sent.append(message) },
            failSenderWaiters: { _, _ in XCTFail("metadata conflict must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata conflict must not resume outbound waiters") }
        )

        XCTAssertEqual(sent.map(\.op), [.metadataAck, .error])
        XCTAssertEqual(sent.last?.message, "transferId metadata conflict")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partialURL(transferId).path))
        await receiver.cleanupOnChannelClosed().value
    }

    func testCompleteDoesNotOverwriteDestinationCreatedAfterApproval() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        let receiver = approvedReceiver(destinationBaseDirectory: { fixture.directory })
        var sent: [(CrossNetworkFileTransferMessage, String)] = []
        let keys = Self.sessionKeys()
        let payload = Data("abcd".utf8)
        let existing = Data("existing".utf8)
        let payloadHash = Data(SHA256.hash(data: payload))
        let originalDestination = fixture.directory.appendingPathComponent("payload.bin")
        let alternateDestination = fixture.directory.appendingPathComponent("payload (1).bin")

        try await receiver.handle(
            metadata(transferId: transferId, fileSize: Int64(payload.count), chunkSize: payload.count, totalChunks: 1),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("metadata must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("metadata must not resume outbound waiters") }
        )
        try existing.write(to: originalDestination)
        try await receiver.handle(
            chunk(transferId: transferId, index: 0, data: payload),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("chunk must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("chunk must not resume outbound waiters") }
        )
        try await receiver.handle(
            CrossNetworkFileTransferMessage(
                op: .complete,
                transferId: transferId,
                receivedBytes: Int64(payload.count),
                fileSha256: payloadHash
            ),
            sessionID: "session",
            endpointDescription: "peer",
            keys: keys,
            sendMessage: { message, label in sent.append((message, label)) },
            failSenderWaiters: { _, _ in XCTFail("complete must not fail outbound waiters") },
            resumeSenderWaiter: { _ in XCTFail("complete must not resume outbound waiters") }
        )

        XCTAssertEqual(sent.last?.0.op, .completeAck)
        XCTAssertEqual(try Data(contentsOf: originalDestination), existing)
        XCTAssertEqual(try Data(contentsOf: alternateDestination), payload)
    }

    func testInboundReceiverStateStaysOutOfCrossNetworkManagerAndOutboundExtension() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )
        let outboundExtensionSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCFileTransfer.swift"),
            encoding: .utf8
        )
        let receiverSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCInboundFileTransferReceiver.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(managerSource.contains("WebRTCInboundFileTransferState"))
        XCTAssertFalse(managerSource.contains("FileHandle(forWritingTo:"))
        XCTAssertFalse(managerSource.contains("completeTimers"))
        XCTAssertFalse(outboundExtensionSource.contains("final class WebRTCInboundFileTransferReceiver"))
        XCTAssertTrue(receiverSource.contains("final class WebRTCInboundFileTransferReceiver"))
        XCTAssertTrue(receiverSource.contains("private var transfers: [String: WebRTCInboundFileTransferState]"))
        XCTAssertTrue(receiverSource.contains("private var completeTimers: [String: Task<Void, Never>]"))
        XCTAssertTrue(receiverSource.contains("private var idleTimers: [String: Task<Void, Never>]"))
        XCTAssertTrue(receiverSource.contains("private var terminalReceipts: WebRTCInboundFileTransferTerminalReceiptCache"))
        XCTAssertTrue(receiverSource.contains("private static let defaultMaxConcurrentInboundTransfers = 8"))
        XCTAssertTrue(receiverSource.contains("private static let defaultTransferIdleTimeout: Duration = .seconds(120)"))
        XCTAssertTrue(receiverSource.contains("private static let defaultMaxTerminalReceiptsPerSession = 128"))
        XCTAssertTrue(receiverSource.contains("private static let defaultTerminalReceiptTTL: TimeInterval = 300"))
        XCTAssertTrue(receiverSource.contains("recordTerminalReceiptAndRemoveActive("))
        XCTAssertTrue(receiverSource.contains("current.stateToken == expected.stateToken"))
        XCTAssertTrue(receiverSource.contains("current.revision == expected.revision"))
        XCTAssertTrue(receiverSource.contains("closeAndDigest(using:"))
        XCTAssertTrue(receiverSource.contains("transferId metadata conflict"))
        XCTAssertTrue(receiverSource.contains("transferId completion conflict"))
    }

    private func metadata(
        transferId: String,
        senderDeviceId: String? = "sender",
        fileName: String = "payload.bin",
        fileSize: Int64,
        chunkSize: Int,
        totalChunks: Int
    ) -> CrossNetworkFileTransferMessage {
        CrossNetworkFileTransferMessage(
            op: .metadata,
            transferId: transferId,
            senderDeviceId: senderDeviceId,
            senderDeviceName: "Sender",
            fileName: fileName,
            fileSize: fileSize,
            chunkSize: chunkSize,
            totalChunks: totalChunks
        )
    }

    private func chunk(
        transferId: String,
        index: Int,
        data: Data
    ) -> CrossNetworkFileTransferMessage {
        CrossNetworkFileTransferMessage(
            op: .chunk,
            transferId: transferId,
            chunkIndex: index,
            chunkData: data,
            chunkSha256: Data(SHA256.hash(data: data)),
            rawSize: data.count
        )
    }

    private func makeFixture() throws -> ReceiverFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebRTCInboundFileTransferReceiverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return ReceiverFixture(directory: directory)
    }

    private func assertInvalidQueuedOperationRejected(
        _ operation: CrossNetworkFileTransferOp,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { nil },
            senderAuthorityProvider: { _ in Self.senderAuthority() }
        )
        let message = CrossNetworkFileTransferMessage(
            op: operation,
            transferId: UUID().uuidString
        )

        do {
            try receiver.enqueueInboundRequest(
                message,
                encodedPayloadByteCount: 128,
                sessionID: "session",
                endpointDescription: "peer",
                keys: Self.sessionKeys(),
                sendMessage: { _, _ in },
                failSenderWaiters: { _, _ in },
                resumeSenderWaiter: { _ in },
                onFatalError: { _ in }
            )
            XCTFail("Non-request operation entered the inbound request queue", file: file, line: line)
        } catch WebRTCInboundFileTransferReceiver.InboundOperationQueueError.invalidRequestOperation(let rejectedOperation) {
            XCTAssertEqual(rejectedOperation.rawValue, operation.rawValue, file: file, line: line)
        } catch {
            XCTFail("expected invalidRequestOperation, got \(error)", file: file, line: line)
        }
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func approvedReceiver(
        destinationBaseDirectory: @escaping () -> URL?,
        maxConcurrentInboundTransfers: Int = 8,
        maxGlobalConcurrentInboundTransfers: Int = 16,
        transferIdleTimeout: Duration = .seconds(120),
        maxTerminalReceiptsPerSession: Int = 128,
        terminalReceiptTTL: TimeInterval = 300,
        now: @escaping () -> Date = Date.init,
        admissionLedger: WebRTCInboundFileTransferAdmissionLedger = .shared
    ) -> WebRTCInboundFileTransferReceiver {
        WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: destinationBaseDirectory,
            maxConcurrentInboundTransfers: maxConcurrentInboundTransfers,
            maxGlobalConcurrentInboundTransfers: maxGlobalConcurrentInboundTransfers,
            transferIdleTimeout: transferIdleTimeout,
            maxTerminalReceiptsPerSession: maxTerminalReceiptsPerSession,
            terminalReceiptTTL: terminalReceiptTTL,
            now: now,
            admissionLedger: admissionLedger,
            senderAuthorityProvider: { _ in Self.senderAuthority() },
            approvalProvider: { _ in .approved }
        )
    }

    private static func sessionKeys(sessionID: String = "session") -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x01, count: 32),
            receiveKey: Data(repeating: 0x02, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x03, count: 32),
            sessionId: sessionID
        )
    }

    private static func senderAuthority() -> WebRTCInboundFileTransferSenderAuthority {
        WebRTCInboundFileTransferSenderAuthority(deviceId: "sender", deviceName: "Sender")
    }

    private struct ReceiverFixture {
        let directory: URL

        init(directory: URL) {
            self.directory = directory
        }

        func partialURL(_ transferId: String) -> URL {
            directory.appendingPathComponent(".skybridge-\(transferId).partial")
        }

        func cleanup(
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail(
                    "Failed to remove owned receiver fixture: \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
