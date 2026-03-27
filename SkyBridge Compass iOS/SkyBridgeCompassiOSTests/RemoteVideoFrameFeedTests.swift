import XCTest
import AVFoundation
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class RemoteVideoFrameFeedTests: XCTestCase {
    @MainActor
    func testEnqueueKeepsOnlyLatestBoundedFrames() throws {
        let feed = RemoteVideoFrameFeed()

        for index in 0..<6 {
            feed.enqueue(frame: try makeFrame(index: index))
        }

        XCTAssertEqual(feed.pendingFrames.count, 3)
        XCTAssertEqual(
            feed.pendingFrames.map(\.presentationTimeStamp.value),
            [3, 4, 5]
        )
    }

    private func makeFrame(index: Int) throws -> DisplaySampleBufferFrame {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                1,
                1,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        guard let pixelBuffer else {
            throw XCTSkip("Failed to create pixel buffer")
        }

        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        guard let formatDescription else {
            throw XCTSkip("Failed to create format description")
        }

        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 60),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timingInfo,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        guard let sampleBuffer else {
            throw XCTSkip("Failed to create sample buffer")
        }

        return DisplaySampleBufferFrame(
            sampleBuffer: sampleBuffer,
            width: 1,
            height: 1,
            presentationTimeStamp: timingInfo.presentationTimeStamp
        )
    }
}
