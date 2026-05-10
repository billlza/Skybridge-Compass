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

    @MainActor
    func testSampleBufferDisplayAcknowledgementDoesNotPublishNewFrameVersion() throws {
        let feed = RemoteVideoFrameFeed()
        feed.enqueue(frame: try makeFrame(index: 1))
        let versionAfterEnqueue = feed.frameVersion

        feed.markDisplayedFrame()

        XCTAssertTrue(feed.hasDisplayedFrame)
        XCTAssertEqual(feed.frameVersion, versionAfterEnqueue)
    }

    @MainActor
    func testMetalDisplayAcknowledgementDoesNotResubmitRetainedLatestFrame() throws {
        let feed = RemoteMetalVideoFrameFeed()
        feed.enqueue(
            frame: DecodedPixelBufferFrame(
                pixelBuffer: try makePixelBuffer(),
                width: 1,
                height: 1,
                presentationTimeStamp: CMTime(value: 1, timescale: 60)
            )
        )
        let versionAfterEnqueue = feed.frameVersion

        feed.markDisplayedFrame()

        XCTAssertTrue(feed.hasDisplayedFrame)
        XCTAssertEqual(feed.frameVersion, versionAfterEnqueue)
        XCTAssertNotNil(feed.takeLatestFrame())
    }

    func testMetalRendererUsesMTKViewRenderPassAndSingleDrawableLifecycle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("DispatchSemaphore(value: 3)"))
        XCTAssertFalse(
            source.contains("view.currentRenderPassDescriptor"),
            "The Metal renderer must not mix MTKView.currentRenderPassDescriptor with currentDrawable; one draw should own one explicit drawable lifecycle."
        )
        XCTAssertTrue(source.contains("let drawable = view.currentDrawable"))
        XCTAssertEqual(source.components(separatedBy: "view.currentDrawable").count - 1, 1)
        XCTAssertTrue(source.contains("let drawableTexture = drawable.texture"))
        XCTAssertEqual(source.components(separatedBy: "drawable.texture").count - 1, 1)
        XCTAssertTrue(source.contains("let renderPassDescriptor = MTLRenderPassDescriptor()"))
        guard let textureRange = source.range(of: "let drawableTexture = drawable.texture"),
              let returnRange = source.range(of: "return DrawableRenderTarget(", range: textureRange.upperBound..<source.endIndex) else {
            XCTFail("Metal renderer must keep drawable.texture inside the single drawable target helper")
            return
        }
        XCTAssertLessThan(textureRange.lowerBound, returnRange.lowerBound)
        guard let framePathRange = source.range(of: "let drawableWidth ="),
              let drawableRange = source.range(
                of: "guard let renderTarget = makeDrawableRenderTarget(for: view)",
                range: framePathRange.upperBound..<source.endIndex
              ),
              let renderRange = source.range(
                of: "ciContext.render(",
                range: drawableRange.upperBound..<source.endIndex
              ),
              let presentRange = source.range(
                of: "commandBuffer.present(renderTarget.drawable)",
                range: renderRange.upperBound..<source.endIndex
              ) else {
            XCTFail("Metal renderer must render directly into one owned CAMetalDrawable")
            return
        }
        XCTAssertLessThan(framePathRange.lowerBound, drawableRange.lowerBound)
        XCTAssertLessThan(drawableRange.lowerBound, renderRange.lowerBound)
        XCTAssertLessThan(drawableRange.lowerBound, presentRange.lowerBound)
        XCTAssertFalse(source.contains("makeRenderTexture("))
        XCTAssertFalse(source.contains("commandBuffer.makeBlitCommandEncoder()"))
        XCTAssertTrue(source.contains("metalView.enableSetNeedsDisplay = true"))
        XCTAssertTrue(source.contains("metalView.isPaused = true"))
        XCTAssertTrue(source.contains("view.setNeedsDisplay()"))
        XCTAssertTrue(source.contains("view.draw()"))
        XCTAssertTrue(source.contains("pendingRedraw"))
        XCTAssertTrue(source.contains("requestFollowUpDrawIfPossible"))
        XCTAssertTrue(source.contains("let uprightTransform = CGAffineTransform("))
        XCTAssertTrue(source.contains("d: scaleY"))
        XCTAssertFalse(source.contains("d: -scaleY"))
        XCTAssertFalse(source.contains("a: -scaleX"))
        XCTAssertTrue(source.contains("Metal render telemetry"))
        XCTAssertTrue(source.contains("frameAgeMs="))
        XCTAssertTrue(source.contains("orientation=upright"))
        XCTAssertTrue(source.contains("drawableAccess=single-late"))
        XCTAssertTrue(source.contains("frameDriven=true"))
    }

    func testNativeVideoPromotionRequiresNonNilRenderedFrame() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("func renderFrame(_ frame: RTCVideoFrame?)"))
        XCTAssertTrue(
            source.contains("guard let frame else { return }"),
            "renderFrame(nil) is only a heartbeat/size event and must not trigger nativeReady evidence."
        )
        XCTAssertTrue(source.contains("renderer-bound-no-native-frame"))
    }

    func testVisibleNativeVideoPromotionIsDrivenByObservableMTLViewRenderFrame() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let rtcVideoViewBody = try sourceSlice(
            from: "struct RemoteDesktopRTCVideoView: UIViewRepresentable",
            to: "#endif",
            in: source
        )
        let coordinatorBody = try sourceSlice(
            from: "final class Coordinator: NSObject, RTCVideoViewDelegate",
            to: "final class ObservableRTCMTLVideoView: RTCMTLVideoView",
            in: rtcVideoViewBody
        )

        XCTAssertTrue(rtcVideoViewBody.contains("final class ObservableRTCMTLVideoView: RTCMTLVideoView"))
        XCTAssertTrue(rtcVideoViewBody.contains("override func renderFrame(_ frame: RTCVideoFrame?)"))
        XCTAssertTrue(rtcVideoViewBody.contains("super.renderFrame(frame)"))
        XCTAssertTrue(rtcVideoViewBody.contains("guard let frame else { return }"))
        XCTAssertTrue(rtcVideoViewBody.contains("minimumVisibleNativeRenderFrames = 1"))
        XCTAssertTrue(rtcVideoViewBody.contains("nativeRenderEvidenceSource"))
        XCTAssertTrue(rtcVideoViewBody.contains("uiSurface"))
        XCTAssertTrue(source.contains("uiSurface: \"remoteDesktopView\""))
        XCTAssertTrue(rtcVideoViewBody.contains("currentRemoteVideoTrackRenderToken(trackId: track.trackId)"))
        XCTAssertTrue(rtcVideoViewBody.contains("renderEpoch: renderEpoch"))
        XCTAssertTrue(source.contains("acceptsRenderEvidence: nativeVideoOwnsSurface"))
        XCTAssertTrue(rtcVideoViewBody.contains("acceptsNativeRenderEvidence"))
        XCTAssertTrue(rtcVideoViewBody.contains("isOpaque = false"))
        XCTAssertTrue(rtcVideoViewBody.contains("backgroundColor = .clear"))
        XCTAssertTrue(rtcVideoViewBody.contains("DispatchQueue.main.async"))
        XCTAssertTrue(rtcVideoViewBody.contains("lastRenderedFrameTimestampNs"))
        XCTAssertTrue(rtcVideoViewBody.contains("resetVisibleRenderEvidence()"))
        XCTAssertTrue(rtcVideoViewBody.contains("uiView.resetVisibleRenderEvidence()"))
        XCTAssertTrue(rtcVideoViewBody.contains("isVisibleForNativeRenderEvidence"))
        XCTAssertTrue(rtcVideoViewBody.contains("acceptsNativeRenderEvidence\n                && window != nil"))
        XCTAssertTrue(rtcVideoViewBody.contains("window != nil"))
        XCTAssertTrue(rtcVideoViewBody.contains("consecutiveVisibleRenderFrames"))
        XCTAssertTrue(rtcVideoViewBody.contains("hasLoggedVisibleRenderEvidence"))
        XCTAssertTrue(rtcVideoViewBody.contains("WebRTC native video render diagnostic"))
        XCTAssertTrue(rtcVideoViewBody.contains("WebRTC native video visible render evidence"))
        XCTAssertTrue(rtcVideoViewBody.contains("nativeRenderEvidenceSource=\\(Self.nativeRenderEvidenceSource)"))
        XCTAssertTrue(rtcVideoViewBody.contains("onRenderedFrame?(size)"))
        XCTAssertTrue(coordinatorBody.contains("VisibleRTCMTLVideoRenderer"))
        XCTAssertTrue(coordinatorBody.contains("track.add(renderer)"))
        XCTAssertTrue(coordinatorBody.contains("boundTrack.remove(boundRenderer)"))
        XCTAssertTrue(coordinatorBody.contains("view.renderFrame(frame)"))
        XCTAssertTrue(coordinatorBody.contains("view.setSize(size)"))
        XCTAssertTrue(coordinatorBody.contains("renderer=forwarder"))
        XCTAssertFalse(
            coordinatorBody.contains("track.add(view)"),
            "The visible RTCMTLVideoView is driven through a retained forwarding renderer so evidence is recorded on the same frame submitted to the view."
        )
        XCTAssertTrue(rtcVideoViewBody.contains("WebRTC native video UIView created and bound"))
        XCTAssertFalse(
            coordinatorBody.contains("track.add(self)"),
            "The coordinator is only lifecycle glue; the retained forwarding renderer submits frames to the visible RTCMTLVideoView and lets the observable subclass record render evidence."
        )

        let didChangeBody = try sourceSlice(
            from: "func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize)",
            to: "}\n    }\n\n    final class ObservableRTCMTLVideoView",
            in: rtcVideoViewBody
        )
        XCTAssertFalse(
            didChangeBody.contains("noteRemoteVideoTrackRenderedFrame"),
            "A size callback is not proof that the visible RTCMTLVideoView rendered pixels."
        )
        let sizeEvidenceBody = try sourceSlice(
            from: "func noteVideoViewSizeEvidence(_ size: CGSize)",
            to: "func resetVisibleRenderEvidence()",
            in: rtcVideoViewBody
        )
        XCTAssertFalse(
            sizeEvidenceBody.contains("onRenderedFrame?(size)"),
            "RTCVideoViewDelegate size evidence must not indirectly promote native video before renderFrame sees a real frame."
        )
    }

    func testNativeVideoSurfaceFollowsActualCrossNetworkTransportState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift"
        )
        let managerSourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )
        let viewSource = try String(contentsOf: viewSourceURL, encoding: .utf8)
        let managerSource = try String(contentsOf: managerSourceURL, encoding: .utf8)
        let nativeVideoPredicate = try sourceSlice(
            from: "private var isUsingNativeCrossNetworkVideo: Bool",
            to: "private var nativeCrossNetworkVideoTrack",
            in: viewSource
        )

        XCTAssertTrue(nativeVideoPredicate.contains("remoteDesktopManager.isUsingCrossNetworkTransport"))
        XCTAssertFalse(nativeVideoPredicate.contains("connection.device.capabilities.contains"))
        XCTAssertFalse(nativeVideoPredicate.contains("advertisedCapabilities.contains"))
        XCTAssertTrue(managerSource.contains("@Published public private(set) var isUsingCrossNetworkTransport = false"))
        XCTAssertTrue(managerSource.contains("activeTransportMode = .crossNetwork\n                isUsingCrossNetworkTransport = true"))
        XCTAssertTrue(managerSource.contains("activeTransportMode = .lan\n            isUsingCrossNetworkTransport = false"))
    }

    private func makeFrame(index: Int) throws -> DisplaySampleBufferFrame {
        let pixelBuffer = try makePixelBuffer()

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

    private func makePixelBuffer() throws -> CVPixelBuffer {
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
        return pixelBuffer
    }

    private func sourceSlice(from startMarker: String, to endMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
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
        XCTAssertTrue(CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("rtc-mtl-video-view"))

        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("fallback-screen-data-confirmed")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("heartbeat-renderer")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("receiver-stats")
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
