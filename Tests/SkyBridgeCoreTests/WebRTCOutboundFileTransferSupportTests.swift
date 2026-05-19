import CryptoKit
import XCTest
@testable import SkyBridgeCore

final class WebRTCOutboundFileTransferSupportTests: XCTestCase {
    func testWaiterKeyUsesMinusOneForUnindexedWaiters() {
        XCTAssertEqual(
            WebRTCOutboundFileTransferSupport.waiterKey(
                sessionID: "session",
                transferId: "transfer",
                op: .metadataAck,
                chunkIndex: nil
            ),
            "session|transfer|metadataAck|-1"
        )
    }

    func testTotalChunksUsesIntegerCeiling() {
        let chunkSize = WebRTCOutboundFileTransferSupport.dataChannelChunkSize

        XCTAssertEqual(WebRTCOutboundFileTransferSupport.totalChunks(fileSize: 1), 1)
        XCTAssertEqual(WebRTCOutboundFileTransferSupport.totalChunks(fileSize: Int64(chunkSize)), 1)
        XCTAssertEqual(WebRTCOutboundFileTransferSupport.totalChunks(fileSize: Int64(chunkSize + 1)), 2)
        XCTAssertNil(WebRTCOutboundFileTransferSupport.totalChunks(fileSize: 0))
        XCTAssertNil(WebRTCOutboundFileTransferSupport.totalChunks(fileSize: 1, chunkSize: 0))
    }

    func testValidateCompletionAckRequiresExactBytesAndHash() throws {
        let payload = Data("hello".utf8)
        let fileSha = Data(SHA256.hash(data: payload))
        let ack = CrossNetworkFileTransferMessage(
            op: .completeAck,
            transferId: "transfer",
            receivedBytes: Int64(payload.count),
            fileSha256: fileSha
        )

        XCTAssertNoThrow(
            try WebRTCOutboundFileTransferSupport.validateCompletionAck(
                ack,
                expectedFileSize: Int64(payload.count),
                expectedFileSha256: fileSha
            )
        )

        let wrongBytes = CrossNetworkFileTransferMessage(
            op: .completeAck,
            transferId: "transfer",
            receivedBytes: Int64(payload.count + 1),
            fileSha256: fileSha
        )
        XCTAssertThrowsError(
            try WebRTCOutboundFileTransferSupport.validateCompletionAck(
                wrongBytes,
                expectedFileSize: Int64(payload.count),
                expectedFileSha256: fileSha
            )
        )

        let wrongHash = CrossNetworkFileTransferMessage(
            op: .completeAck,
            transferId: "transfer",
            receivedBytes: Int64(payload.count),
            fileSha256: Data(SHA256.hash(data: Data("other".utf8)))
        )
        XCTAssertThrowsError(
            try WebRTCOutboundFileTransferSupport.validateCompletionAck(
                wrongHash,
                expectedFileSize: Int64(payload.count),
                expectedFileSha256: fileSha
            )
        )
    }
}
