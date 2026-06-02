import CryptoKit
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class WebRTCInboundFileTransferSupportTests: XCTestCase {
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
                fileSize: 1,
                chunkSize: WebRTCInboundFileTransferSupport.maxChunkSize + 1,
                totalChunks: 1
            ),
            "Invalid metadata (chunkSize out of range)"
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

    func testExpectedChunkSizeMatchesDeclaredFileShape() throws {
        let fixture = try makeState(fileSize: 1025, chunkSize: 512, totalChunks: 3)
        defer {
            try? fixture.state.handle.close()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

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
    }

    func testIntegrityProofAcceptsFileHashOrSignedMerkleProof() throws {
        let fixture = try makeState(fileSize: 512, chunkSize: 512, totalChunks: 1)
        defer {
            try? fixture.state.handle.close()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

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
    }

    func testIntegrityValidationReportsSpecificFailureReasons() throws {
        let payload = Data("hello".utf8)
        let receiveKey = Data(repeating: 7, count: 32)
        let fixture = try makeState(fileSize: Int64(payload.count), chunkSize: payload.count, totalChunks: 1)
        var state = fixture.state
        try state.handle.write(contentsOf: payload)
        try state.handle.close()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let leaf = Data(SHA256.hash(data: payload))
        let fileHash = Data(SHA256.hash(data: payload))

        state.expectedFileSha256 = Data(repeating: 0, count: 32)
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.integrityFailure(state: state, receiveKey: receiveKey),
            .fileSHA256Mismatch
        )

        state.expectedFileSha256 = fileHash
        state.chunkHashes = [0: leaf]
        state.expectedMerkleRoot = Data(repeating: 1, count: 32)
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.integrityFailure(state: state, receiveKey: receiveKey),
            .merkleRootMismatch
        )

        let merkleRoot = try XCTUnwrap(CrossNetworkMerkle.root(leaves: [leaf]))
        state.expectedMerkleRoot = merkleRoot
        state.expectedMerkleSig = Data(repeating: 2, count: 32)
        state.expectedMerkleSigAlg = "unsupported"
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.integrityFailure(state: state, receiveKey: receiveKey),
            .unknownMerkleSignatureAlgorithm
        )

        state.expectedMerkleSigAlg = CrossNetworkMerkleAuth.signatureAlgV1
        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.integrityFailure(state: state, receiveKey: receiveKey),
            .merkleSignatureMismatch
        )

        let preimage = CrossNetworkMerkleAuth.preimage(
            transferId: state.transferId,
            merkleRoot: merkleRoot,
            fileSha256: state.expectedFileSha256
        )
        state.expectedMerkleSig = CrossNetworkMerkleAuth.hmacSha256(key: receiveKey, data: preimage)
        XCTAssertNil(WebRTCInboundFileTransferSupport.integrityFailure(state: state, receiveKey: receiveKey))
    }

    func testSHA256FileStreamsExpectedDigest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebRTCInboundFileTransferSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let data = Data((0..<2048).map { UInt8($0 % 251) })
        let url = directory.appendingPathComponent("payload.bin")
        try data.write(to: url)

        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.sha256File(at: url),
            Data(SHA256.hash(data: data))
        )
    }

    func testPathHelpersReuseSharedFileTransferPathPolicySemantics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebRTCInboundFileTransferSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(WebRTCInboundFileTransferSupport.sanitizedFileName("../secret.txt"), "secret.txt")
        XCTAssertEqual(WebRTCInboundFileTransferSupport.sanitizedFileName("   "), "SkyBridgeFile")

        let existing = directory.appendingPathComponent("report.pdf")
        FileManager.default.createFile(atPath: existing.path, contents: Data())

        XCTAssertEqual(
            WebRTCInboundFileTransferSupport.uniqueDestinationURL(
                baseDirectory: directory,
                fileName: "report.pdf"
            ).lastPathComponent,
            "report (1).pdf"
        )
    }

    private func makeState(
        fileSize: Int64,
        chunkSize: Int,
        totalChunks: Int
    ) throws -> (state: WebRTCInboundFileTransferState, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebRTCInboundFileTransferSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent("transfer.partial")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        let state = WebRTCInboundFileTransferState(
            transferId: UUID().uuidString,
            fileName: "payload.bin",
            fileSize: fileSize,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            senderDeviceId: "sender-device",
            senderDeviceName: "Sender Device",
            tempURL: tempURL,
            finalURL: directory.appendingPathComponent("payload.bin"),
            handle: try FileHandle(forWritingTo: tempURL),
            receivedBytes: 0
        )

        return (state, directory)
    }
}
