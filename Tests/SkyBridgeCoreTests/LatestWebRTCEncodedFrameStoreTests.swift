import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class LatestWebRTCEncodedFrameStoreTests: XCTestCase {
    func testPendingSyncFrameIsNotOverwrittenByLaterPredictiveFrames() {
        let store = LatestWebRTCEncodedFrameStore()
        let syncFrame = makeFrame(byte: 0xAA, timestamp: 1, isSyncFrame: true)
        let predictiveFrame = makeFrame(byte: 0xBB, timestamp: 2, isSyncFrame: false)

        store.store(syncFrame)
        store.store(predictiveFrame)

        XCTAssertEqual(store.takeLatest(), syncFrame)
        XCTAssertEqual(store.takeLatest(), predictiveFrame)
        XCTAssertNil(store.takeLatest())
    }

    func testNewestPredictiveFrameWinsWhenNoSyncFrameIsPending() {
        let store = LatestWebRTCEncodedFrameStore()
        let first = makeFrame(byte: 0x01, timestamp: 1, isSyncFrame: false)
        let second = makeFrame(byte: 0x02, timestamp: 2, isSyncFrame: false)

        store.store(first)
        store.store(second)

        XCTAssertEqual(store.takeLatest(), second)
        XCTAssertNil(store.takeLatest())
    }

    func testNewerSyncFrameInvalidatesOlderPredictiveContinuation() {
        let store = LatestWebRTCEncodedFrameStore()
        let olderSync = makeFrame(byte: 0x10, timestamp: 1, isSyncFrame: true)
        let stalePredictive = makeFrame(byte: 0x11, timestamp: 2, isSyncFrame: false)
        let newerSync = makeFrame(byte: 0x12, timestamp: 3, isSyncFrame: true)

        store.store(olderSync)
        store.store(stalePredictive)
        store.store(newerSync)

        XCTAssertEqual(store.takeLatest(), newerSync)
        XCTAssertNil(store.takeLatest())
    }

    func testFreshFrameCanBeTakenWithinMaxAge() {
        let store = LatestWebRTCEncodedFrameStore()
        let now = Date(timeIntervalSince1970: 10)
        let fresh = makeFrame(byte: 0x21, timestamp: 9.75, isSyncFrame: false)

        store.store(fresh)

        XCTAssertEqual(store.latestAgeMs(now: now), 250)
        XCTAssertEqual(store.takeLatest(maxAge: 0.5, now: now), fresh)
        XCTAssertNil(store.takeLatest())
    }

    func testStaleFrameIsDroppedWhenMaxAgeExpires() {
        let store = LatestWebRTCEncodedFrameStore()
        let now = Date(timeIntervalSince1970: 10)
        let stale = makeFrame(byte: 0x22, timestamp: 9.25, isSyncFrame: true)

        store.store(stale)

        XCTAssertEqual(store.latestAgeMs(now: now), 750)
        XCTAssertNil(store.takeLatest(maxAge: 0.5, now: now))
        XCTAssertNil(store.takeLatest())
    }

    private func makeFrame(
        byte: UInt8,
        timestamp: TimeInterval,
        isSyncFrame: Bool
    ) -> WebRTCEncodedScreenFrame {
        WebRTCEncodedScreenFrame(
            width: 1920,
            height: 1080,
            imageData: Data([byte]),
            timestamp: timestamp,
            format: "h264",
            isSyncFrame: isSyncFrame
        )
    }
}
