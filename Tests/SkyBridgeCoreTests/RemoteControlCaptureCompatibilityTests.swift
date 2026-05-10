#if os(macOS)
import VideoToolbox
import XCTest
@testable import SkyBridgeCore

final class RemoteControlCaptureCompatibilityTests: XCTestCase {
    func testEncodedCaptureSizeUsesEvenDimensions() {
        let normalized = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            CGSize(width: 2056, height: 1329),
            for: .h264
        )

        XCTAssertEqual(normalized.width, 2056)
        XCTAssertEqual(normalized.height, 1328)
    }

    func testEncodedCaptureSizeCanPreserveExplicitVisibleDimensions() {
        let normalized = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            CGSize(width: 2056, height: 1329),
            for: .h264,
            preserveExactVisibleSize: true
        )

        XCTAssertEqual(normalized.width, 2056)
        XCTAssertEqual(normalized.height, 1329)
    }

    func testJPEGCaptureSizeKeepsRequestedDimensions() {
        let normalized = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            CGSize(width: 2056, height: 1329),
            for: .bgra
        )

        XCTAssertEqual(normalized.width, 2056)
        XCTAssertEqual(normalized.height, 1329)
    }

    func testInvalidSessionDowngradesHEVCToH264() {
        let fallback = RemoteControlCaptureCompatibility.fallbackCodec(
            afterEncodeFailure: kVTInvalidSessionErr,
            activeCodec: .hevc
        )

        XCTAssertEqual(fallback, .h264)
    }

    func testInvalidSessionDowngradesH264ToJPEG() {
        let fallback = RemoteControlCaptureCompatibility.fallbackCodec(
            afterEncodeFailure: kVTInvalidSessionErr,
            activeCodec: .h264
        )

        XCTAssertEqual(fallback, .bgra)
    }

    func testUnrelatedEncodeFailureDoesNotForceFallback() {
        let fallback = RemoteControlCaptureCompatibility.fallbackCodec(
            afterEncodeFailure: kVTParameterErr,
            activeCodec: .h264
        )

        XCTAssertNil(fallback)
    }
}
#endif
