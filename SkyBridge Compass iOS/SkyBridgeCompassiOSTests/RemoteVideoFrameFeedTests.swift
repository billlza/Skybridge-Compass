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

@available(iOS 17.0, *)
@MainActor
final class RemoteDesktopNativePromotionTests: XCTestCase {
    func testShouldAnnounceCrossNetworkNativeVideoReadyRejectsMissingRenderedFrameEvenWhenForced() {
        let shouldAnnounce = RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
            activeTransportModeIsCrossNetwork: true,
            hasCurrentConnection: true,
            hasRenderedNativeFrame: false,
            lastSentNativeVideoTrackReady: false,
            force: true,
            lastAnnouncementAt: nil,
            now: Date()
        )

        XCTAssertFalse(shouldAnnounce)
    }

    func testShouldAnnounceCrossNetworkNativeVideoReadyAcceptsRenderedFrameEvidence() {
        let shouldAnnounce = RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
            activeTransportModeIsCrossNetwork: true,
            hasCurrentConnection: true,
            hasRenderedNativeFrame: true,
            lastSentNativeVideoTrackReady: false,
            force: false,
            lastAnnouncementAt: nil,
            now: Date()
        )

        XCTAssertTrue(shouldAnnounce)
    }

    func testAdvertisedCrossNetworkNativeVideoReadyFlagTracksRenderedFrameEvidenceOnly() {
        XCTAssertNil(
            RemoteDesktopManager.advertisedCrossNetworkNativeVideoReadyFlag(
                activeTransportModeIsCrossNetwork: false,
                hasRenderedNativeFrame: true
            )
        )
        XCTAssertEqual(
            RemoteDesktopManager.advertisedCrossNetworkNativeVideoReadyFlag(
                activeTransportModeIsCrossNetwork: true,
                hasRenderedNativeFrame: false
            ),
            false
        )
        XCTAssertEqual(
            RemoteDesktopManager.advertisedCrossNetworkNativeVideoReadyFlag(
                activeTransportModeIsCrossNetwork: true,
                hasRenderedNativeFrame: true
            ),
            true
        )
    }

    func testActualNativeRenderEvidenceRejectsPacketAndFallbackInference() {
        XCTAssertTrue(CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("heartbeat-renderer"))
        XCTAssertTrue(CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("rtc-mtl-video-view"))
        XCTAssertTrue(CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("receiver-stats"))

        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("fallback-screen-data-confirmed")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("receiver-first-packet")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence(
                "receiver-packet-confirmed:fallback-screen-data-confirmed"
            )
        )
    }
}
