import Foundation
import XCTest
import enum SkyBridgeProtocolCore.WebRTCFramedPayloadPolicy
@testable import SkyBridgeCore

final class CrossNetworkInboundChunkQueueTests: XCTestCase {
    func testQueueFailsClosedAndDiscardsBufferedDataOnOverflow() async {
        let queue = CrossNetworkConnectionManager.InboundChunkQueue(
            maximumChunkByteCount: 4,
            maxPendingBytes: 4
        )

        let acceptedAtLimit = await queue.push(Data(repeating: 0x11, count: 4))
        let acceptedPastLimit = await queue.push(Data([0x22]))
        XCTAssertEqual(acceptedAtLimit, .accepted)
        XCTAssertEqual(acceptedPastLimit, .overflow)

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
        let queue = CrossNetworkConnectionManager.InboundChunkQueue(
            maximumChunkByteCount: 4,
            maxPendingBytes: 4
        )
        let acceptedInitialChunk = await queue.push(Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(acceptedInitialChunk, .accepted)

        let head = try await queue.next(max: 2)
        XCTAssertEqual(head, Data([0x01, 0x02]))
        let acceptedOverflowingChunk = await queue.push(Data([0x05, 0x06, 0x07]))
        XCTAssertEqual(acceptedOverflowingChunk, .overflow)

        do {
            _ = try await queue.next()
            XCTFail("expected overflow")
        } catch CrossNetworkConnectionManager.InboundChunkQueue.QueueError.overflow {
            // Expected.
        }
    }

    func testSharedSingleChunkLimitIsEnforcedBeforeWaiterResume() async throws {
        let maximum = WebRTCFramedPayloadPolicy.maximumPayloadByteCount
        let exactQueue = CrossNetworkConnectionManager.InboundChunkQueue(
            maximumChunkByteCount: maximum,
            maxPendingBytes: 32 * 1_024 * 1_024,
            maxPendingChunks: 4
        )
        let exactPushResult = await exactQueue.push(
            Data(repeating: 0xA5, count: maximum)
        )
        XCTAssertEqual(exactPushResult, .accepted)
        let exactReceived = try await exactQueue.next()
        XCTAssertEqual(exactReceived.count, maximum)

        let overflowQueue = CrossNetworkConnectionManager.InboundChunkQueue(
            maximumChunkByteCount: maximum,
            maxPendingBytes: 32 * 1_024 * 1_024,
            maxPendingChunks: 4
        )
        let waiter = Task { try await overflowQueue.next() }
        for _ in 0..<1_000 {
            if await overflowQueue.testOnlyWaiterCount() == 1 { break }
            await Task.yield()
        }
        let waiterCount = await overflowQueue.testOnlyWaiterCount()
        XCTAssertEqual(waiterCount, 1)
        let overflowPushResult = await overflowQueue.push(
            Data(repeating: 0x5A, count: maximum + 1)
        )
        XCTAssertEqual(overflowPushResult, .overflow)
        do {
            _ = try await waiter.value
            XCTFail("An oversized chunk must fail the active waiter")
        } catch CrossNetworkConnectionManager.InboundChunkQueue.QueueError.overflow {
            // Expected: cap validation happens before waiter delivery.
        } catch {
            XCTFail("expected queue overflow, got \(error)")
        }
    }

    func testWaiterSplitTailIsAccountedBeforeConcurrentBacklogAdmission() async throws {
        let queue = CrossNetworkConnectionManager.InboundChunkQueue(
            maximumChunkByteCount: 4,
            maxPendingBytes: 4,
            maxPendingChunks: 2
        )
        let waiter = Task { try await queue.next(max: 2) }
        for _ in 0..<1_000 {
            if await queue.testOnlyWaiterCount() == 1 { break }
            await Task.yield()
        }
        let registeredWaiterCount = await queue.testOnlyWaiterCount()
        XCTAssertEqual(registeredWaiterCount, 1)

        let firstPush = await queue.push(Data([0x01, 0x02, 0x03, 0x04]))
        let overflowingPush = await queue.push(Data([0x05, 0x06, 0x07]))
        XCTAssertEqual(firstPush, .accepted)
        XCTAssertEqual(overflowingPush, .overflow)
        let waiterValue = try await waiter.value
        XCTAssertEqual(waiterValue, Data([0x01, 0x02]))
        do {
            _ = try await queue.next()
            XCTFail("Overflow must discard the accounted split tail")
        } catch CrossNetworkConnectionManager.InboundChunkQueue.QueueError.overflow {
            // Expected: the split tail consumed aggregate budget before the second push.
        } catch {
            XCTFail("expected overflow, got \(error)")
        }
    }

    func testSplitTailPreservesFIFOAcrossMultipleWaitingConsumers() async throws {
        let queue = CrossNetworkConnectionManager.InboundChunkQueue(
            maximumChunkByteCount: 4,
            maxPendingBytes: 4,
            maxPendingChunks: 2
        )
        let first = Task { try await queue.next(max: 2) }
        for _ in 0..<1_000 {
            if await queue.testOnlyWaiterCount() == 1 { break }
            await Task.yield()
        }
        let firstRegisteredWaiterCount = await queue.testOnlyWaiterCount()
        XCTAssertEqual(firstRegisteredWaiterCount, 1)
        guard firstRegisteredWaiterCount == 1 else {
            await queue.finish()
            first.cancel()
            return
        }

        let second = Task { try await queue.next(max: 4) }
        for _ in 0..<1_000 {
            if await queue.testOnlyWaiterCount() == 2 { break }
            await Task.yield()
        }
        let registeredWaiterCount = await queue.testOnlyWaiterCount()
        XCTAssertEqual(registeredWaiterCount, 2)
        guard registeredWaiterCount == 2 else {
            await queue.finish()
            first.cancel()
            second.cancel()
            return
        }

        let pushResult = await queue.push(Data([0x10, 0x11, 0x12, 0x13]))
        XCTAssertEqual(pushResult, .accepted)
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, Data([0x10, 0x11]))
        XCTAssertEqual(secondValue, Data([0x12, 0x13]))
    }

    func testCancellingSuspendedWaiterRemovesItAndDoesNotConsumeLateChunk() async throws {
        let queue = CrossNetworkConnectionManager.InboundChunkQueue(
            maximumChunkByteCount: 4,
            maxPendingBytes: 4
        )
        let cancelledWaiter = Task { try await queue.next() }
        for _ in 0..<1_000 {
            if await queue.testOnlyWaiterCount() == 1 { break }
            await Task.yield()
        }
        let waiterCountBeforeCancellation = await queue.testOnlyWaiterCount()
        XCTAssertEqual(waiterCountBeforeCancellation, 1)

        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("A cancelled waiter must not receive a later session frame")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
        let waiterCountAfterCancellation = await queue.testOnlyWaiterCount()
        XCTAssertEqual(waiterCountAfterCancellation, 0)

        let lateChunk = Data([0x31, 0x32])
        let latePushResult = await queue.push(lateChunk)
        XCTAssertEqual(latePushResult, .accepted)
        let activeConsumerValue = try await queue.next()
        XCTAssertEqual(activeConsumerValue, lateChunk)
    }

    func testAlreadyCancelledConsumerCannotDrainBufferedData() async throws {
        let queue = CrossNetworkConnectionManager.InboundChunkQueue(
            maximumChunkByteCount: 4,
            maxPendingBytes: 4
        )
        let buffered = Data([0x41, 0x42])
        let bufferedPushResult = await queue.push(buffered)
        XCTAssertEqual(bufferedPushResult, .accepted)

        let cancelledConsumer = Task { () throws -> Data in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await queue.next()
        }
        do {
            _ = try await cancelledConsumer.value
            XCTFail("A cancelled consumer must not drain buffered session data")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }

        let activeConsumerValue = try await queue.next()
        XCTAssertEqual(activeConsumerValue, buffered)
    }

    func testFinishDiscardsBufferedDataAndRejectsLateCallbacks() async {
        let queue = CrossNetworkConnectionManager.InboundChunkQueue(
            maximumChunkByteCount: 4,
            maxPendingBytes: 4
        )
        let bufferedPushResult = await queue.push(Data([0x51, 0x52]))
        XCTAssertEqual(bufferedPushResult, .accepted)

        await queue.finish()

        let latePushResult = await queue.push(Data([0x53]))
        XCTAssertEqual(latePushResult, .closed)
        do {
            _ = try await queue.next()
            XCTFail("A finished queue must not deliver buffered or late session data")
        } catch CrossNetworkConnectionManager.InboundChunkQueue.QueueError.finished {
            // Expected.
        } catch {
            XCTFail("expected finished, got \(error)")
        }
    }

    func testFinishWakesSuspendedWaiterWithoutDeliveringLateCallback() async {
        let queue = CrossNetworkConnectionManager.InboundChunkQueue(
            maximumChunkByteCount: 4,
            maxPendingBytes: 4
        )
        let waiter = Task { try await queue.next(max: 4) }
        for _ in 0..<1_000 {
            if await queue.testOnlyWaiterCount() == 1 { break }
            await Task.yield()
        }
        let waiterCountBeforeFinish = await queue.testOnlyWaiterCount()
        XCTAssertEqual(waiterCountBeforeFinish, 1)

        await queue.finish()
        let latePushResult = await queue.push(Data([0x61]))
        XCTAssertEqual(latePushResult, .closed)
        do {
            _ = try await waiter.value
            XCTFail("Closing a session must fail its suspended consumer")
        } catch CrossNetworkConnectionManager.InboundChunkQueue.QueueError.finished {
            // Expected.
        } catch {
            XCTFail("expected finished, got \(error)")
        }
    }
}
