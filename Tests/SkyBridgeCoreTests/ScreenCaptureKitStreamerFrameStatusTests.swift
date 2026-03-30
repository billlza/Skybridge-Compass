#if os(macOS)
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
}
#endif
