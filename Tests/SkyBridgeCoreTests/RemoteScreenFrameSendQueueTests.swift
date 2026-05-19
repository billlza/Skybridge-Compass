import XCTest
@testable import SkyBridgeCore

final class RemoteScreenFrameSendQueueTests: XCTestCase {
    func testDefaultQueueDepthMatchesStrictSixFrameLatencyBudget() {
        let queue = RemoteScreenFrameSendQueue()

        XCTAssertEqual(queue.maxQueuedFrames, 6)
    }

    func testQueueRequestsSyncRefreshWhenPredictiveFrameOverflows() {
        var queue = RemoteScreenFrameSendQueue(maxQueuedFrames: 2)

        XCTAssertEqual(queue.enqueue(makeFrame(sync: true)), .enqueued)
        XCTAssertEqual(queue.enqueue(makeFrame(sync: false)), .enqueued)

        let result = queue.enqueue(makeFrame(sync: false))

        XCTAssertEqual(result, .droppedPredictiveFrameNeedsSyncRefresh)
        XCTAssertTrue(queue.waitingForSyncFrame)
        XCTAssertEqual(queue.pendingFrames.count, 0)
    }

    func testQueueDropsPredictiveFramesUntilNextSyncArrives() {
        var queue = RemoteScreenFrameSendQueue(maxQueuedFrames: 1)

        XCTAssertEqual(queue.enqueue(makeFrame(sync: true)), .enqueued)
        XCTAssertEqual(queue.enqueue(makeFrame(sync: false)), .droppedPredictiveFrameNeedsSyncRefresh)
        XCTAssertEqual(queue.enqueue(makeFrame(sync: false)), .droppedPredictiveFrameWaitingForSync)

        XCTAssertTrue(queue.waitingForSyncFrame)
        XCTAssertEqual(queue.pendingFrames.count, 0)

        XCTAssertEqual(queue.enqueue(makeFrame(sync: true)), .enqueued)
        XCTAssertFalse(queue.waitingForSyncFrame)
        XCTAssertEqual(queue.pendingFrames.count, 1)
        XCTAssertEqual(queue.pendingFrames.first?.isSyncFrame, true)
    }

    func testQueueTreatsH264IDRPayloadAsIndependentWhenFlagIsWrong() {
        var queue = RemoteScreenFrameSendQueue(maxQueuedFrames: 1)

        let result = queue.enqueue(
            ScreenData(
                width: 1920,
                height: 1080,
                imageData: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88]),
                timestamp: 1,
                format: "h264",
                isSyncFrame: false
            )
        )

        XCTAssertEqual(result, .enqueued)
        XCTAssertFalse(queue.waitingForSyncFrame)
        XCTAssertEqual(queue.pendingFrames.count, 1)
    }

    func testQueueDoesNotRecoverFromWaitingSyncUsingAdvertisedFlagWithoutIRAPNAL() {
        var queue = RemoteScreenFrameSendQueue(maxQueuedFrames: 1)
        _ = queue.enqueue(makeFrame(sync: true))
        _ = queue.enqueue(makeFrame(sync: false))

        let advertisedSyncPredictiveHEVC = ScreenData(
            width: 2056,
            height: 1329,
            imageData: Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x88]),
            timestamp: 2,
            format: "hevc",
            isSyncFrame: true
        )

        XCTAssertEqual(
            queue.enqueue(advertisedSyncPredictiveHEVC),
            .droppedPredictiveFrameWaitingForSync
        )
        XCTAssertTrue(queue.waitingForSyncFrame)
        XCTAssertTrue(queue.pendingFrames.isEmpty)
    }

    func testIndependentFramesStayDecodableWhenQueueRolls() {
        var queue = RemoteScreenFrameSendQueue(maxQueuedFrames: 2)

        XCTAssertEqual(queue.enqueue(makeJPEGFrame()), .enqueued)
        XCTAssertEqual(queue.enqueue(makeJPEGFrame()), .enqueued)
        XCTAssertEqual(queue.enqueue(makeJPEGFrame()), .droppedStaleIndependentFrame)

        XCTAssertFalse(queue.waitingForSyncFrame)
        XCTAssertEqual(queue.pendingFrames.count, 2)
        XCTAssertTrue(queue.pendingFrames.allSatisfy(\.isIndependentlyDecodableFrame))
    }

    private func makeFrame(sync: Bool) -> ScreenData {
        let nalType: UInt8 = sync ? 0x65 : 0x41
        return ScreenData(
            width: 1920,
            height: 1080,
            imageData: Data([0x00, 0x00, 0x00, 0x01, nalType]),
            timestamp: 1,
            format: "h264",
            isSyncFrame: sync
        )
    }

    private func makeJPEGFrame() -> ScreenData {
        ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            timestamp: 1,
            format: "jpeg",
            isSyncFrame: true
        )
    }
}
