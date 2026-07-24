import CryptoKit
import XCTest
@testable import SkyBridgeCore
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
final class WebRTCInboundFileTransferSupportTests: XCTestCase {
    func testRemoteStatusNormalizationEnforcesUTF8ByteLimitWithoutSplittingScalar() {
        let exactBoundary = String(repeating: "a", count: 509) + "界"
        let exactResult = WebRTCInboundFileTransferSupport.normalizedRemoteStatusMessage(
            exactBoundary,
            fallback: "fallback"
        )
        XCTAssertEqual(exactResult, exactBoundary)
        XCTAssertEqual(
            exactResult.utf8.count,
            WebRTCInboundFileTransferSupport.maximumRemoteStatusMessageBytes
        )

        let overflowingScalar = String(repeating: "a", count: 510) + "界"
        let truncatedResult = WebRTCInboundFileTransferSupport.normalizedRemoteStatusMessage(
            overflowingScalar,
            fallback: "fallback"
        )
        XCTAssertEqual(truncatedResult, String(repeating: "a", count: 510))
        XCTAssertLessThanOrEqual(
            truncatedResult.utf8.count,
            WebRTCInboundFileTransferSupport.maximumRemoteStatusMessageBytes
        )
    }

    func testRemoteStatusNormalizationReplacesControlCharactersAndUsesFallbackWhenEmpty() {
        let normalized = WebRTCInboundFileTransferSupport.normalizedRemoteStatusMessage(
            "denied\u{0000}retry\nlater\t\u{007F}",
            fallback: "fallback"
        )

        XCTAssertEqual(normalized, "denied retry later")
        XCTAssertFalse(
            normalized.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.normalizedRemoteStatusMessage(
                "\u{0000}\n\t\u{007F}",
                fallback: "fallback"
            ),
            "fallback"
        )
    }

    func testValidateTransferIdRequiresCanonicalUUID() {
        XCTAssertNil(WebRTCInboundFileTransferSupport.validateTransferId(UUID().uuidString))
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.validateTransferId("../escape"),
            "Invalid metadata (invalid transferId)"
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.validateTransferId("a/b"),
            "Invalid metadata (invalid transferId)"
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.validateTransferId("transfer"),
            "Invalid metadata (invalid transferId)"
        )
    }

    func testValidateMetadataRejectsInvalidFileShapes() {
        XCTAssertNil(
            WebRTCInboundFileTransferSupport.validateMetadata(
                fileName: "report.pdf",
                fileSize: 1025,
                chunkSize: 512,
                totalChunks: 3
            )
        )

        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.validateMetadata(
                fileName: "   ",
                fileSize: 1,
                chunkSize: 512,
                totalChunks: 1
            ),
            "Invalid metadata (empty fileName)"
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.validateMetadata(
                fileName: "report.pdf",
                fileSize: -1,
                chunkSize: 512,
                totalChunks: 1
            ),
            "Invalid metadata (negative fileSize)"
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.validateMetadata(
                fileName: "report.pdf",
                fileSize: WebRTCInboundFileTransferSupport.maxFileSize + 1,
                chunkSize: WebRTCInboundFileTransferSupport.maxChunkSize,
                totalChunks: 1
            ),
            "Invalid metadata (fileSize out of range)"
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.validateMetadata(
                fileName: "report.pdf",
                fileSize: 1,
                chunkSize: WebRTCInboundFileTransferSupport.maxChunkSize + 1,
                totalChunks: 1
            ),
            "Invalid metadata (chunkSize out of range)"
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.validateMetadata(
                fileName: "report.pdf",
                fileSize: Int64(WebRTCInboundFileTransferSupport.maxTotalChunks + 1),
                chunkSize: 1,
                totalChunks: WebRTCInboundFileTransferSupport.maxTotalChunks + 1
            ),
            "Invalid metadata (totalChunks out of range)"
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.validateMetadata(
                fileName: "report.pdf",
                fileSize: 1025,
                chunkSize: 512,
                totalChunks: 2
            ),
            "Invalid metadata (fileSize/chunkSize/totalChunks mismatch)"
        )
    }

    func testExpectedChunkSizeMatchesDeclaredFileShape() async throws {
        let fixture = try await makeState(fileSize: 1025, chunkSize: 512, totalChunks: 3)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.expectedChunkSize(state: fixture.state, index: 0),
            512
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.expectedChunkSize(state: fixture.state, index: 1),
            512
        )
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.expectedChunkSize(state: fixture.state, index: 2),
            1
        )
        XCTAssertNil(WebRTCInboundFileTransferSupport.expectedChunkSize(state: fixture.state, index: -1))
        XCTAssertNil(WebRTCInboundFileTransferSupport.expectedChunkSize(state: fixture.state, index: 3))
        try await fixture.ioActor.discard(fixture.state.ioHandle)
    }

    func testIntegrityProofAcceptsFileHashOrSignedMerkleProof() async throws {
        let fixture = try await makeState(fileSize: 512, chunkSize: 512, totalChunks: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var state = fixture.state
        XCTAssertFalse(WebRTCInboundFileTransferSupport.hasRequiredIntegrityProof(state))

        state.expectedFileSha256 = Data(repeating: 1, count: 32)
        XCTAssertTrue(WebRTCInboundFileTransferSupport.hasRequiredIntegrityProof(state))

        state.expectedFileSha256 = nil
        state.expectedMerkleRoot = Data(repeating: 2, count: 32)
        state.expectedMerkleSig = Data(repeating: 3, count: 32)
        state.expectedMerkleSigAlg = "unsupported"
        XCTAssertFalse(WebRTCInboundFileTransferSupport.hasRequiredIntegrityProof(state))

        state.expectedMerkleSigAlg = CrossNetworkMerkleAuth.signatureAlgV1
        XCTAssertTrue(WebRTCInboundFileTransferSupport.hasRequiredIntegrityProof(state))
        try await fixture.ioActor.discard(fixture.state.ioHandle)
    }

    func testIntegrityValidationReportsSpecificFailureReasons() async throws {
        let payload = Data("hello".utf8)
        let receiveKey = Data(repeating: 7, count: 32)
        let fixture = try await makeState(fileSize: Int64(payload.count), chunkSize: payload.count, totalChunks: 1)
        var state = fixture.state
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let leaf = Data(SHA256.hash(data: payload))
        let fileHash = Data(SHA256.hash(data: payload))

        state.expectedFileSha256 = Data(repeating: 0, count: 32)
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.integrityFailure(
                state: state,
                receiveKey: receiveKey,
                actualFileSha256: fileHash
            ),
            .fileSHA256Mismatch
        )

        state.expectedFileSha256 = fileHash
        state.chunkHashes = [0: leaf]
        state.expectedMerkleRoot = Data(repeating: 1, count: 32)
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.integrityFailure(
                state: state,
                receiveKey: receiveKey,
                actualFileSha256: fileHash
            ),
            .merkleRootMismatch
        )

        let merkleRoot = try XCTUnwrap(CrossNetworkMerkle.root(leaves: [leaf]))
        state.expectedMerkleRoot = merkleRoot
        state.expectedMerkleSig = Data(repeating: 2, count: 32)
        state.expectedMerkleSigAlg = "unsupported"
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.integrityFailure(
                state: state,
                receiveKey: receiveKey,
                actualFileSha256: fileHash
            ),
            .unknownMerkleSignatureAlgorithm
        )

        state.expectedMerkleSigAlg = CrossNetworkMerkleAuth.signatureAlgV1
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.integrityFailure(
                state: state,
                receiveKey: receiveKey,
                actualFileSha256: fileHash
            ),
            .merkleSignatureMismatch
        )

        let preimage = CrossNetworkMerkleAuth.preimage(
            transferId: state.transferId,
            merkleRoot: merkleRoot,
            fileSha256: state.expectedFileSha256
        )
        state.expectedMerkleSig = CrossNetworkMerkleAuth.hmacSha256(key: receiveKey, data: preimage)
        XCTAssertNil(
            WebRTCInboundFileTransferSupport.integrityFailure(
                state: state,
                receiveKey: receiveKey,
                actualFileSha256: fileHash
            )
        )
        try await fixture.ioActor.discard(fixture.state.ioHandle)
    }

    func testIntegrityValidationFailsClosedWhenExpectedHashCannotBeRead() async throws {
        let fixture = try await makeState(fileSize: 512, chunkSize: 512, totalChunks: 1)
        var state = fixture.state
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        state.expectedFileSha256 = Data(repeating: 0, count: 32)

        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.integrityFailure(
                state: state,
                receiveKey: Data(repeating: 7, count: 32),
                actualFileSha256: nil
            ),
            .fileSHA256Unavailable
        )
        try await fixture.ioActor.discard(fixture.state.ioHandle)
    }

    func testPathHelpersReuseSharedFileTransferPathPolicySemantics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebRTCInboundFileTransferSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(WebRTCInboundFileTransferSupport.sanitizedFileName("../secret.txt"), "SkyBridgeFile")
        XCTAssertEqual(WebRTCInboundFileTransferSupport.sanitizedFileName("   "), "SkyBridgeFile")
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.validateMetadata(
                fileName: "../secret.txt",
                fileSize: 1,
                chunkSize: 1,
                totalChunks: 1
            ),
            "Invalid metadata (unsafe fileName)"
        )

        let existing = directory.appendingPathComponent("report.pdf")
        FileManager.default.createFile(atPath: existing.path, contents: Data())

        XCTAssertEqual(
            try WebRTCInboundFileTransferSupport.uniqueDestinationURL(
                baseDirectory: directory,
                fileName: "report.pdf"
            ).lastPathComponent,
            "report (1).pdf"
        )

        XCTAssertThrowsError(
            try WebRTCInboundFileTransferSupport.uniqueDestinationURL(
                baseDirectory: directory,
                fileName: "../report.pdf"
            )
        )
    }

    func testTerminalReceiptCacheIsBoundedPerSessionAndExpiresEntries() {
        let now = Date(timeIntervalSince1970: 1_000)
        let metadata = WebRTCInboundFileTransferMetadataBinding(
            version: 1,
            senderDeviceId: "sender",
            senderDeviceName: "Sender",
            fileName: "payload.bin",
            fileSize: 4,
            chunkSize: 4,
            totalChunks: 1,
            mimeType: nil,
            encryption: nil,
            batchId: nil,
            batchIndex: nil,
            batchTotal: nil,
            relativePath: nil
        )
        let complete = CrossNetworkFileTransferMessage(
            op: .complete,
            transferId: "ignored-by-binding",
            receivedBytes: 4,
            fileSha256: Data(repeating: 7, count: 32)
        )
        let completion = WebRTCInboundFileTransferCompletionBinding(message: complete)
        var cache = WebRTCInboundFileTransferTerminalReceiptCache(
            maxReceiptsPerSession: 1,
            timeToLive: 10
        )

        cache.store(
            sessionID: "session-a",
            transferID: "transfer-a",
            metadataBinding: metadata,
            completionBinding: completion,
            response: .init(op: .completeAck, transferId: "transfer-a", receivedBytes: 4),
            label: "completeAck",
            now: now
        )
        cache.store(
            sessionID: "session-b",
            transferID: "transfer-a",
            metadataBinding: metadata,
            completionBinding: completion,
            response: .init(op: .error, transferId: "transfer-a", message: "terminal"),
            label: "completeError",
            now: now
        )
        cache.store(
            sessionID: "session-a",
            transferID: "transfer-b",
            metadataBinding: metadata,
            completionBinding: completion,
            response: .init(op: .completeAck, transferId: "transfer-b", receivedBytes: 4),
            label: "completeAck",
            now: now
        )

        XCTAssertNil(cache.receipt(sessionID: "session-a", transferID: "transfer-a", now: now))
        XCTAssertEqual(
            cache.receipt(sessionID: "session-a", transferID: "transfer-b", now: now)?.response.op,
            .completeAck
        )
        XCTAssertEqual(
            cache.receipt(sessionID: "session-b", transferID: "transfer-a", now: now)?.response.op,
            .error
        )
        XCTAssertNil(
            cache.receipt(
                sessionID: "session-a",
                transferID: "transfer-b",
                now: now.addingTimeInterval(10)
            )
        )
    }

    private func makeState(
        fileSize: Int64,
        chunkSize: Int,
        totalChunks: Int
    ) async throws -> (
        state: WebRTCInboundFileTransferState,
        directory: URL,
        ioActor: InboundFileTransferIOActor
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebRTCInboundFileTransferSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent("transfer.partial")
        let ioActor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let ioHandle = try await ioActor.createTemporaryFile(
            at: tempURL,
            declaredFileSize: fileSize
        )

        let transferID = UUID().uuidString
        let state = WebRTCInboundFileTransferState(
            stateToken: UUID(),
            presentationToken: FileTransferManager.ExternalTransferToken(
                identifier: UUID(),
                transferID: transferID,
                lifecycleGeneration: UUID(),
                direction: .incoming
            ),
            lifecycleToken: UUID(),
            sessionID: "session",
            transferId: transferID,
            metadataBinding: WebRTCInboundFileTransferMetadataBinding(
                version: 1,
                senderDeviceId: "sender-device",
                senderDeviceName: "Sender Device",
                fileName: "payload.bin",
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                mimeType: nil,
                encryption: nil,
                batchId: nil,
                batchIndex: nil,
                batchTotal: nil,
                relativePath: nil
            ),
            fileName: "payload.bin",
            fileSize: fileSize,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            senderDeviceId: "sender-device",
            senderDeviceName: "Sender Device",
            tempURL: tempURL,
            finalURL: directory.appendingPathComponent("payload.bin"),
            ioHandle: ioHandle,
            revision: 0,
            receivedBytes: 0
        )

        return (state, directory, ioActor)
    }
}
