import CoreVideo
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class NativeWebRTCFramePacingStateTests: XCTestCase {
    func testInitialRawFrameSubmitsCaptureTimestampWithoutDuplicates() throws {
        let state = NativeWebRTCFramePacingState(
            frameIntervalNs: 16_666_667,
            maxFramesPerRawFrame: 3
        )
        let pixelBuffer = try makePixelBuffer()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let plan = state.planForRawFrame(
            pixelBuffer: pixelBuffer,
            rawTimestampNs: 100,
            now: now
        )

        XCTAssertEqual(plan.timestampsNs, [100])
        XCTAssertEqual(plan.rawDeltaNs, 0)
        XCTAssertEqual(plan.submittedFrames, 1)
        XCTAssertEqual(plan.duplicateFrames, 0)
        XCTAssertFalse(plan.shouldLogBurst)
    }

    func testRawFrameBurstIsCappedByMaxFramesPerCapture() throws {
        let state = NativeWebRTCFramePacingState(
            frameIntervalNs: 10_000_000,
            maxFramesPerRawFrame: 3
        )
        let pixelBuffer = try makePixelBuffer()
        let start = Date(timeIntervalSince1970: 1_700_000_100)

        _ = state.planForRawFrame(
            pixelBuffer: pixelBuffer,
            rawTimestampNs: 0,
            now: start
        )
        let plan = state.planForRawFrame(
            pixelBuffer: pixelBuffer,
            rawTimestampNs: 50_000_000,
            now: start.addingTimeInterval(0.1)
        )

        XCTAssertEqual(plan.timestampsNs, [10_000_000, 20_000_000, 30_000_000])
        XCTAssertEqual(plan.rawDeltaNs, 50_000_000)
        XCTAssertEqual(plan.submittedFrames, 3)
        XCTAssertEqual(plan.duplicateFrames, 2)
        XCTAssertTrue(plan.shouldLogBurst)
    }

    func testTimerPacedFrameWaitsForStallGraceBeforeRepeatingLatestFrame() throws {
        let state = NativeWebRTCFramePacingState(
            frameIntervalNs: 10_000_000,
            maxFramesPerRawFrame: 3
        )
        let pixelBuffer = try makePixelBuffer()
        let start = Date(timeIntervalSince1970: 1_700_000_200)

        _ = state.planForRawFrame(
            pixelBuffer: pixelBuffer,
            rawTimestampNs: 40_000_000,
            now: start
        )

        XCTAssertNil(state.nextTimerFrame(now: start.addingTimeInterval(0.005)))

        let frame = try XCTUnwrap(state.nextTimerFrame(now: start.addingTimeInterval(0.030)))
        XCTAssertEqual(frame.rawTimestampNs, 40_000_000)
        XCTAssertEqual(frame.timestampNs, 50_000_000)
        XCTAssertEqual(frame.timerPacedFrames, 1)
        XCTAssertGreaterThanOrEqual(frame.lastRawAgeMs, 30)
        XCTAssertTrue(frame.shouldLog)
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }
}
