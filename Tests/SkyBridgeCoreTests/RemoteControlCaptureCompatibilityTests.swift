#if os(macOS)
import VideoToolbox
import XCTest
@testable import SkyBridgeCore

final class RemoteControlCaptureCompatibilityTests: XCTestCase {
    func testReducedCaptureFitsTheDisplayAspectWithinRequestedBounds() throws {
        let fitted = try RemoteControlCaptureCompatibility.fittedCaptureSize(
            CGSize(width: 1280, height: 720), displaySize: CGSize(width: 2056, height: 1329)
        )
        XCTAssertEqual(fitted.height, 720, accuracy: 0.001)
        XCTAssertLessThan(fitted.width, 1280)
        XCTAssertEqual(fitted.width / fitted.height, 2056.0 / 1329.0, accuracy: 0.000001)
        let encoded = RemoteControlCaptureCompatibility.normalizedCaptureSize(fitted, for: .h264)
        XCTAssertLessThanOrEqual(abs(encoded.width - fitted.width), 2)
        XCTAssertLessThanOrEqual(abs(encoded.height - fitted.height), 2)
    }

    func testMatchingDisplayAspectAndPortraitCapturePreserveGeometry() throws {
        XCTAssertEqual(
            try RemoteControlCaptureCompatibility.fittedCaptureSize(
                CGSize(width: 1280, height: 720), displaySize: CGSize(width: 3840, height: 2160)
            ), CGSize(width: 1280, height: 720)
        )
        XCTAssertEqual(
            try RemoteControlCaptureCompatibility.fittedCaptureSize(
                CGSize(width: 720, height: 1280), displaySize: CGSize(width: 1080, height: 1920)
            ), CGSize(width: 720, height: 1280)
        )
    }

    func testFittedCaptureRejectsInvalidDimensions() {
        for size in [CGSize(width: CGFloat.nan, height: 720), CGSize(width: 1280, height: 0), CGSize(width: -1, height: 720)] {
            XCTAssertThrowsError(try RemoteControlCaptureCompatibility.fittedCaptureSize(size, displaySize: CGSize(width: 1920, height: 1080)))
            XCTAssertThrowsError(try RemoteControlCaptureCompatibility.fittedCaptureSize(CGSize(width: 1280, height: 720), displaySize: size))
        }
    }

    func testEncodedCaptureSizeUsesEvenDimensions() {
        let normalized = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            CGSize(width: 2056, height: 1329),
            for: .h264
        )

        XCTAssertEqual(normalized.width, 2056)
        XCTAssertEqual(normalized.height, 1328)
    }

    func testVisibleCaptureSizeCanPreserveExplicitOddDimensions() {
        let visible = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            CGSize(width: 2056, height: 1329),
            for: .h264,
            preserveExactVisibleSize: true
        )

        XCTAssertEqual(visible.width, 2056)
        XCTAssertEqual(visible.height, 1329)
    }

    func testEncodedBackingSizeUsesEvenDimensionsWhenVisibleSizeIsOdd() {
        let encoded = RemoteControlCaptureCompatibility.encodedBackingCaptureSize(
            CGSize(width: 2056, height: 1329),
            for: .hevc,
            preserveExactVisibleSize: true
        )

        XCTAssertEqual(encoded.width, 2056)
        XCTAssertEqual(encoded.height, 1330)
    }

    func testJPEGCaptureSizeKeepsRequestedDimensions() {
        let normalized = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            CGSize(width: 2056, height: 1329),
            for: .bgra
        )

        XCTAssertEqual(normalized.width, 2056)
        XCTAssertEqual(normalized.height, 1329)
    }

    func testInvalidSessionDoesNotDowngradeHEVCToH264() {
        let fallback = RemoteControlCaptureCompatibility.fallbackCodec(
            afterEncodeFailure: kVTInvalidSessionErr,
            activeCodec: .hevc
        )

        XCTAssertNil(fallback)
    }

    func testInvalidSessionDoesNotChainFallbackFromH264ToJPEG() {
        let fallback = RemoteControlCaptureCompatibility.fallbackCodec(
            afterEncodeFailure: kVTInvalidSessionErr,
            activeCodec: .h264
        )

        XCTAssertNil(fallback)
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
