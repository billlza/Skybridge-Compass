import Foundation
import XCTest
@testable import SkyBridgeCore

final class CrossNetworkInboundChunkQueueTests: XCTestCase {
    func testQueueFailsClosedAndDiscardsBufferedDataOnOverflow() async {
        let queue = CrossNetworkConnectionManager.InboundChunkQueue(maxPendingBytes: 4)

        let acceptedAtLimit = await queue.push(Data(repeating: 0x11, count: 4))
        let acceptedPastLimit = await queue.push(Data([0x22]))
        XCTAssertTrue(acceptedAtLimit)
        XCTAssertFalse(acceptedPastLimit)

        do {
            _ = try await queue.next()
            XCTFail("expected overflow")
        } catch CrossNetworkConnectionManager.InboundChunkQueue.QueueError.overflow {
            // Expected: buffered data is not delivered after integrity was lost.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSplitTailRemainsAccountedAgainstByteLimit() async throws {
        let queue = CrossNetworkConnectionManager.InboundChunkQueue(maxPendingBytes: 4)
        let acceptedInitialChunk = await queue.push(Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertTrue(acceptedInitialChunk)

        let head = try await queue.next(max: 2)
        XCTAssertEqual(head, Data([0x01, 0x02]))
        let acceptedOverflowingChunk = await queue.push(Data([0x05, 0x06, 0x07]))
        XCTAssertFalse(acceptedOverflowingChunk)

        do {
            _ = try await queue.next()
            XCTFail("expected overflow")
        } catch CrossNetworkConnectionManager.InboundChunkQueue.QueueError.overflow {
            // Expected.
        }
    }
}
