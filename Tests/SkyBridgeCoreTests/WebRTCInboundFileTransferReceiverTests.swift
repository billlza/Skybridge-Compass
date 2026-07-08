import CryptoKit
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class WebRTCInboundFileTransferReceiverTests: XCTestCase {
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

        receiver.cleanupOnChannelClosed()

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
        let receiver = WebRTCInboundFileTransferReceiver(destinationBaseDirectory: { fixture.directory })
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

    func testMetadataApprovalProviderReceivesValidatedMetadataBeforePartialCreation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let transferId = UUID().uuidString
        var capturedRequest: WebRTCInboundFileTransferApprovalRequest?
        let receiver = WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: { fixture.directory },
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

        receiver.cleanupOnChannelClosed()
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

        receiver.cleanupOnChannelClosed()
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

        receiver.cleanupOnChannelClosed()
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
        XCTAssertTrue(receiverSource.contains("private static let defaultMaxConcurrentInboundTransfers = 8"))
        XCTAssertTrue(receiverSource.contains("private static let defaultTransferIdleTimeout: Duration = .seconds(120)"))
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
        return ReceiverFixture(directory: directory)
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
        transferIdleTimeout: Duration = .seconds(120)
    ) -> WebRTCInboundFileTransferReceiver {
        WebRTCInboundFileTransferReceiver(
            destinationBaseDirectory: destinationBaseDirectory,
            maxConcurrentInboundTransfers: maxConcurrentInboundTransfers,
            transferIdleTimeout: transferIdleTimeout,
            approvalProvider: { _ in .approved }
        )
    }

    private static func sessionKeys() -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x01, count: 32),
            receiveKey: Data(repeating: 0x02, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x03, count: 32),
            sessionId: "session"
        )
    }

    private struct ReceiverFixture {
        let directory: URL

        init(directory: URL) {
            self.directory = directory
        }

        func partialURL(_ transferId: String) -> URL {
            directory.appendingPathComponent(".skybridge-\(transferId).partial")
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
