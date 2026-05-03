#if os(macOS)
import CoreMedia
import ScreenCaptureKit
import XCTest
@testable import SkyBridgeCore

final class ScreenCaptureKitStreamerFrameStatusTests: XCTestCase {
    func testStartedAndCompleteFramesRemainProcessable() {
        XCTAssertTrue(ScreenCaptureKitStreamer.shouldProcessFrame(with: nil))
        XCTAssertTrue(ScreenCaptureKitStreamer.shouldProcessFrame(with: .started))
        XCTAssertTrue(ScreenCaptureKitStreamer.shouldProcessFrame(with: .complete))
    }

    func testIdleBlankSuspendedAndStoppedFramesAreDropped() {
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .idle))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .blank))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .suspended))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .stopped))
    }

    func testEncodeFrameDurationUsesRequestedFPSAndNeverZero() {
        let duration = ScreenCaptureKitStreamer.encodeFrameDuration(forConfiguredFPS: 60)

        XCTAssertEqual(duration.value, 1)
        XCTAssertEqual(duration.timescale, 60)
        XCTAssertTrue(CMTimeCompare(duration, .zero) > 0)

        let clamped = ScreenCaptureKitStreamer.encodeFrameDuration(forConfiguredFPS: 0)
        XCTAssertEqual(clamped.value, 1)
        XCTAssertEqual(clamped.timescale, 1)
        XCTAssertTrue(CMTimeCompare(clamped, .zero) > 0)
    }
}
#endif
