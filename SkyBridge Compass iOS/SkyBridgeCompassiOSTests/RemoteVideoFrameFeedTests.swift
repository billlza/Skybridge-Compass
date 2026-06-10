import XCTest
import AVFoundation
import Combine
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
    func testSampleBufferFeedFlushCanPreserveDisplayedImageOwnership() throws {
        let feed = RemoteVideoFrameFeed()
        feed.enqueue(frame: try makeFrame(index: 1))
        feed.markDisplayedFrame()
        let frameVersionAfterDisplay = feed.frameVersion
        let flushVersionBeforeFlush = feed.flushVersion

        feed.flush(removeDisplayedImage: false)

        XCTAssertTrue(feed.pendingFrames.isEmpty)
        XCTAssertTrue(feed.hasDisplayedFrame)
        XCTAssertTrue(feed.hasFrame)
        XCTAssertFalse(feed.removeDisplayedImageOnFlush)
        XCTAssertEqual(feed.flushVersion, flushVersionBeforeFlush + 1)
        XCTAssertEqual(feed.frameVersion, frameVersionAfterDisplay + 1)

        feed.flush(removeDisplayedImage: true)

        XCTAssertFalse(feed.hasDisplayedFrame)
        XCTAssertFalse(feed.hasFrame)
        XCTAssertTrue(feed.removeDisplayedImageOnFlush)
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

    @MainActor
    func testMetalFeedReportsConsumerDeliveryAndRemovesStaleConsumers() throws {
        let feed = RemoteMetalVideoFrameFeed()
        var acceptedInvocations = 0
        var staleInvocations = 0
        var rejectedInvocations = 0
        _ = feed.addFrameConsumer { _, _ in
            acceptedInvocations += 1
            return .accepted
        }
        _ = feed.addFrameConsumer { _, _ in
            staleInvocations += 1
            return .staleConsumer
        }
        _ = feed.addFrameConsumer { _, _ in
            rejectedInvocations += 1
            return .rejected(reason: "queue-full depth=3")
        }

        let firstResult = feed.enqueue(
            frame: DecodedPixelBufferFrame(
                pixelBuffer: try makePixelBuffer(),
                width: 1,
                height: 1,
                presentationTimeStamp: CMTime(value: 1, timescale: 60)
            )
        )

        XCTAssertEqual(firstResult.consumerCount, 3)
        XCTAssertEqual(firstResult.staleConsumerCount, 1)
        XCTAssertEqual(firstResult.acceptedConsumerCount, 1)
        XCTAssertEqual(firstResult.rejectedConsumerCount, 1)
        XCTAssertEqual(firstResult.activeConsumerCount, 2)
        XCTAssertTrue(firstResult.acceptedByRenderer)
        XCTAssertTrue(firstResult.hasQueueBackpressureRejection)
        XCTAssertEqual(firstResult.rejectionSummary, "queue-full depth=3")

        let secondResult = feed.enqueue(
            frame: DecodedPixelBufferFrame(
                pixelBuffer: try makePixelBuffer(),
                width: 1,
                height: 1,
                presentationTimeStamp: CMTime(value: 2, timescale: 60)
            )
        )

        XCTAssertEqual(secondResult.consumerCount, 2)
        XCTAssertEqual(secondResult.staleConsumerCount, 0)
        XCTAssertEqual(secondResult.acceptedConsumerCount, 1)
        XCTAssertEqual(secondResult.rejectedConsumerCount, 1)
        XCTAssertEqual(acceptedInvocations, 2)
        XCTAssertEqual(staleInvocations, 1)
        XCTAssertEqual(rejectedInvocations, 2)
    }

    func testMetalRendererUsesMTKViewRenderPassAndDisplayLinkDrawableLifecycle() throws {
        let source = try remoteDesktopViewSource()

        XCTAssertTrue(source.contains("private static let inFlightLimit = 2"))
        XCTAssertTrue(source.contains("private static let maxQueuedFrames = 3"))
        XCTAssertFalse(source.contains("realtimeCoalescingQueueBudget"))
        XCTAssertTrue(source.contains("private static let realtimeQueuePolicy = \"strict-fifo-3-frame-no-drop-no-replacement-vsync\""))
        XCTAssertTrue(source.contains("private static let realtimeReplacementReason = \"none\""))
        XCTAssertTrue(source.contains("private var renderFrameAgeMaxMs: Int?"))
        XCTAssertTrue(source.contains("pendingFrames.append(PendingRenderFrame"))
        XCTAssertFalse(source.contains("renderCoalescedFrames += coalescedCount"))
        XCTAssertTrue(source.contains("private var renderQueueBackpressure = 0"))
        XCTAssertTrue(source.contains("metal-renderer-backpressure reason="))
        XCTAssertTrue(source.contains("queue-full depth="))
        XCTAssertFalse(source.contains("failed stage=remote-desktop phase=metal_render_queue_overflow"))
        XCTAssertTrue(source.contains("private var renderInFlightCount = 0"))
        XCTAssertFalse(source.contains("guard !renderInFlightCount"))
        XCTAssertFalse(source.contains("private var frameDeadlineDrawScheduled = false"))
        XCTAssertFalse(source.contains("requestScheduledFollowUpDrawIfPossible"))
        XCTAssertFalse(source.contains("if pendingFrames.count > 1 {\n                renderFrameArrivalDrawSkips += 1\n                return false"))
        XCTAssertFalse(source.contains("lowLatencyCoalescingThreshold"))
        XCTAssertFalse(source.contains("pendingFrames.removeFirst(framesToDiscard)"))
        XCTAssertFalse(source.contains("pendingFrames.removeFirst(coalescedCount)"))
        XCTAssertFalse(source.contains("pendingFrames.removeFirst(dropCount)"))
        XCTAssertTrue(source.contains("private var renderCoalescedFrames = 0"))
        XCTAssertFalse(source.contains("pendingDisplayedCallbackCount"))
        XCTAssertFalse(source.contains("lastDisplayedCallbackFlushAt"))
        XCTAssertTrue(source.contains("onFramesDisplayed: @escaping @Sendable (CMTime, Int, Date, Int?) -> Void"))
        XCTAssertTrue(source.contains("recordMetalRendererDisplayedFramesForSmoke("))
        XCTAssertTrue(source.contains("displayedCallbackCompletedAt,"))
        XCTAssertTrue(source.contains("frameAgeMs"))
        XCTAssertTrue(source.contains("self.lastDisplayedFrameVersion = max(self.lastDisplayedFrameVersion, frameVersion)"))
        XCTAssertFalse(source.contains("else if frameVersion > self.lastDisplayedFrameVersion"))
        XCTAssertTrue(source.contains("DispatchSemaphore(value: MetalVideoRenderer.inFlightLimit)"))
        XCTAssertFalse(source.contains("view.currentRenderPassDescriptor"))
        XCTAssertTrue(source.contains("let drawable = view.currentDrawable"))
        XCTAssertEqual(source.components(separatedBy: "view.currentDrawable").count - 1, 1)
        XCTAssertTrue(source.contains("let renderPassDescriptor = MTLRenderPassDescriptor()"))
        XCTAssertTrue(source.contains("renderPassDescriptor.colorAttachments[0].texture = drawable.texture"))
        guard let currentDrawableRange = source.range(of: "let drawable = view.currentDrawable"),
              let descriptorRange = source.range(of: "let renderPassDescriptor = MTLRenderPassDescriptor()", range: currentDrawableRange.upperBound..<source.endIndex),
              let textureRange = source.range(of: "renderPassDescriptor.colorAttachments[0].texture = drawable.texture", range: descriptorRange.upperBound..<source.endIndex),
              let returnRange = source.range(of: "return DrawableRenderTarget(", range: textureRange.upperBound..<source.endIndex) else {
            XCTFail("Metal renderer must acquire one currentDrawable and build one render-pass descriptor around that drawable")
            return
        }
        XCTAssertLessThan(currentDrawableRange.lowerBound, descriptorRange.lowerBound)
        XCTAssertLessThan(descriptorRange.lowerBound, textureRange.lowerBound)
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
        XCTAssertTrue(source.contains("metalView.enableSetNeedsDisplay = false"))
        XCTAssertTrue(source.contains("metalView.isPaused = false"))
        XCTAssertFalse(source.contains("startDisplayLinkIfNeeded()"))
        XCTAssertTrue(source.contains("metalView.presentsWithTransaction = false"))
        XCTAssertFalse(source.contains("CADisplayLink("))
        XCTAssertFalse(source.contains("preferredFrameRateRange = CAFrameRateRange("))
        XCTAssertTrue(source.contains("screen.maximumFramesPerSecond"))
        XCTAssertTrue(source.contains("displayLinkPumpFPS(for screen: UIScreen)"))
        XCTAssertTrue(source.contains("metalView.preferredFramesPerSecond = pumpFPS"))
        XCTAssertTrue(source.contains("private static func displayLinkPumpFPS(for screen: UIScreen) -> Int {\n            max(displayLinkTargetFPS(for: screen), screen.maximumFramesPerSecond)\n        }"))
        XCTAssertTrue(source.contains("let hasNativePumpHeadroom = displayLinkPumpFPS > displayLinkTargetFPS"))
        XCTAssertTrue(source.contains("&& lateBy > Self.frameCadenceTolerance"))
        XCTAssertTrue(source.contains("&& lateBy <= Self.missedCadenceResetThreshold"))
        XCTAssertFalse(source.contains("let hasBurstBacklog = pendingFrames.count > 1"))
        XCTAssertTrue(source.contains("private static let frameCadenceTolerance"))
        XCTAssertFalse(source.contains("shouldRequestFrameArrivalDrawLocked(now: enqueuedAt)"))
        XCTAssertFalse(source.contains("private func shouldRequestFrameArrivalDrawLocked(now: Date) -> Bool"))
        XCTAssertFalse(source.contains("private var lastFrameArrivalDrawAt = Date.distantPast"))
        XCTAssertFalse(source.contains("private static let videoPaceEarlyDrawTolerance"))
        XCTAssertFalse(source.contains("elapsed + Self.videoPaceEarlyDrawTolerance >= targetInterval"))
        XCTAssertFalse(source.contains("renderFrameArrivalDrawSkips += 1"))
        XCTAssertFalse(source.contains("renderCadenceBacklogDraws += 1"))
        XCTAssertFalse(source.contains("renderCadenceTick(in: metalView, timestamp: displayLink.timestamp)"))
        XCTAssertFalse(source.contains("func renderCadenceTick(in view: MTKView, timestamp: CFTimeInterval)"))
        XCTAssertFalse(source.contains("private var lastCadenceDrawTimestamp: CFTimeInterval = 0"))
        XCTAssertFalse(source.contains("private var lastCadenceTickTimestamp: CFTimeInterval = 0"))
        XCTAssertFalse(source.contains("private var cadenceFrameCredit: Double = 0"))
        XCTAssertFalse(source.contains("private var lastSubmittedAt = Date.distantPast"))
        XCTAssertTrue(source.contains("private var nextFrameDueAt = Date.distantPast"))
        XCTAssertTrue(source.contains("private static let missedCadenceResetThreshold"))
        XCTAssertTrue(source.contains("advanceNextFrameDueAtLocked"))
        XCTAssertTrue(source.contains("lateBy > Self.missedCadenceResetThreshold"))
        XCTAssertTrue(source.contains("nextFrameDueAt = nextFrameDueAt.addingTimeInterval(Self.targetFrameInterval)"))
        XCTAssertFalse(source.contains("shouldHoldForTargetCadence("))
        XCTAssertFalse(source.contains("let shouldDrainDecodedBacklog = pendingFrames.count >= Self.backlogDrainQueueDepth"))
        XCTAssertFalse(source.contains("renderCadenceBacklogDrains += 1"))
        XCTAssertFalse(source.contains("isEarlyBacklogDrain"))
        XCTAssertFalse(source.contains("guard !view.isPaused else { return }"))
        if let displayRange = source.range(of: "func display(frame: DecodedPixelBufferFrame, version: UInt64, in view: MTKView)"),
           let flushRange = source.range(of: "func flush(", range: displayRange.upperBound..<source.endIndex) {
            XCTAssertFalse(
                source[displayRange.lowerBound..<flushRange.lowerBound].contains("view.draw()"),
                "Frame arrival must not manually draw; MTKView native cadence owns every CAMetalDrawable."
            )
        } else {
            XCTFail("Missing Metal display or flush method while checking draw ownership")
        }
        XCTAssertFalse(source.contains("pendingRedraw"))
        XCTAssertFalse(source.contains("requestScheduledFollowUpDrawIfPossible"))
        XCTAssertFalse(source.contains("nextFrameDeadlineDrawDelayLocked"))
        XCTAssertFalse(source.contains("private var frameDeadlineDrawGeneration: UInt64 = 0"))
        XCTAssertFalse(source.contains("generation == frameDeadlineDrawGeneration"))
        XCTAssertFalse(source.contains("private func requestDrawableRefresh(on view: MTKView)"))
        XCTAssertFalse(source.contains("view.draw()"))
        XCTAssertTrue(source.contains("let uprightTransform = CGAffineTransform("))
        XCTAssertTrue(source.contains("d: scaleY"))
        XCTAssertFalse(source.contains("d: -scaleY"))
        XCTAssertFalse(source.contains("a: -scaleX"))
        XCTAssertTrue(source.contains("Metal render telemetry"))
        XCTAssertTrue(source.contains("sampleMs="))
        XCTAssertTrue(source.contains("input=\\(snapshot.input)"))
        XCTAssertTrue(source.contains("submitted=\\(snapshot.submitted)"))
        XCTAssertTrue(source.contains("displayed=\\(snapshot.displayed)"))
        XCTAssertTrue(source.contains("inputFPS="))
        XCTAssertTrue(source.contains("frameAgeMs="))
        XCTAssertTrue(source.contains("source="))
        XCTAssertTrue(source.contains("drawCallbacks="))
        XCTAssertTrue(source.contains("inFlightLimit="))
        XCTAssertTrue(source.contains("queuePolicy=\\(Self.realtimeQueuePolicy)"))
        XCTAssertTrue(source.contains("queueCapacity="))
        XCTAssertTrue(source.contains("queueDepthMax="))
        XCTAssertTrue(source.contains("queueDrop="))
        XCTAssertTrue(source.contains("queueBackpressure="))
        XCTAssertTrue(source.contains("coalescedBeforeDraw="))
        XCTAssertTrue(source.contains("realtimeReplacementBeforeDraw="))
        XCTAssertTrue(source.contains("realtimeReplacementReason="))
        XCTAssertTrue(source.contains("emptyQueueTick="))
        XCTAssertTrue(source.contains("cadenceHoldTick="))
        XCTAssertFalse(source.contains("cadenceBacklogDrain="))
        XCTAssertTrue(source.contains("orientation=upright"))
        XCTAssertTrue(source.contains("drawableAccess=single-current-drawable displayLink"))
        XCTAssertTrue(source.contains("displayLink=mtkview-native"))
        XCTAssertTrue(source.contains("displayLinkTargetFPS=\\(snapshot.displayLinkTargetFPS)"))
        XCTAssertTrue(source.contains("displayLinkPumpFPS=\\(snapshot.displayLinkPumpFPS)"))
        XCTAssertTrue(source.contains("screenMaxFPS=\\(snapshot.screenMaxFPS)"))
        XCTAssertTrue(source.contains("displayCadence=strict-60-native-pump-catch-up-vsync"))
        XCTAssertTrue(source.contains("manualDraw=0"))
        XCTAssertFalse(source.contains("drawable.addPresentedHandler"))
        XCTAssertFalse(source.contains("cadenceNotDueTick="))
        XCTAssertFalse(source.contains("arrivalDraw="))
        XCTAssertFalse(source.contains("arrivalDrawSkip="))
        XCTAssertFalse(source.contains("cadenceBacklogDraw="))
        XCTAssertFalse(source.contains("cadenceLateMaxMs="))
        XCTAssertTrue(source.contains("frameDriven=mtkview-native-vsync"))
        XCTAssertTrue(source.contains("renderPath="))
        XCTAssertTrue(source.contains("directBGRA="))
        XCTAssertTrue(source.contains("ciFallback="))
    }

    @MainActor
    func testMetalFeedDoesNotPublishSwiftUIInvalidationsForEveryFrame() throws {
        let feed = RemoteMetalVideoFrameFeed()
        var invalidationCount = 0
        let cancellable = feed.objectWillChange.sink {
            invalidationCount += 1
        }

        for _ in 0..<5 {
            feed.enqueue(
                frame: DecodedPixelBufferFrame(
                    pixelBuffer: try makePixelBuffer(),
                    width: 1,
                    height: 1,
                    presentationTimeStamp: CMTime(value: 1, timescale: 60)
                )
            )
        }

        XCTAssertEqual(
            invalidationCount,
            1,
            "Metal direct frame consumer should not drive SwiftUI body invalidation at video frame rate."
        )

        feed.flush()
        XCTAssertEqual(invalidationCount, 2)
        _ = cancellable
    }

    func testMetalDecodePathDoesNotPublishFallbackFeedsEveryFrame() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )
        let source = try readRepositorySourceForSourceShapeTests(at: sourceURL)
        let decodedOutputBody = try sourceSlice(
            from: "private func applyDecodedOutput(",
            to: "private func startDecodeLoopIfNeeded()",
            in: source
        )
        let pixelBufferBranch = try sourceSlice(
            from: "case .pixelBuffer(let frame):",
            to: "case .sampleBuffer(let frame):",
            in: decodedOutputBody
        )
        let metalBranch = try sourceSlice(
            from: "case .metal:",
            to: "case .sampleBuffer:",
            in: pixelBufferBranch
        )

        XCTAssertTrue(
            pixelBufferBranch.contains("if currentFrame != nil {\n                currentFrame = nil\n            }"),
            "Metal pixel-buffer decode should not publish the same nil fallback image at video frame rate."
        )
        XCTAssertTrue(
            metalBranch.contains("if renderPipelineStatus != .metalRenderer {\n                    videoFrameFeed.flush(removeDisplayedImage: false)\n                }"),
            "Metal pixel-buffer decode should flush the SampleBuffer feed only when switching renderer ownership."
        )
        XCTAssertTrue(
            metalBranch.contains("await enqueueMetalFrameForDisplay("),
            "Decoded pixel buffers should enter the bounded Metal feed pacer instead of synchronously pushing bursts into the renderer."
        )
        XCTAssertFalse(
            metalBranch.contains("metalVideoFrameFeed.enqueue(frame: frame)"),
            "The LAN Metal branch must not synchronously push every decoded frame into the renderer queue."
        )
        XCTAssertTrue(
            pixelBufferBranch.contains("if renderPipelineStatus != .sampleBufferDisplayLayer {\n                        flushMetalVideoFrameFeed(removeDisplayedImage: true)\n                    }"),
            "SampleBuffer ownership should flush Metal only when switching away from Metal."
        )
        XCTAssertTrue(
            pixelBufferBranch.contains("if renderPipelineStatus != .metalRenderer {\n                        videoFrameFeed.flush(removeDisplayedImage: false)\n                    }"),
            "SampleBuffer-to-Metal recovery should flush SampleBuffer only when switching ownership."
        )
    }

    func testVideoToolboxDecodeRunsOffMainActorBeforeApplyingMetalFrame() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )
        let source = try readRepositorySourceForSourceShapeTests(at: sourceURL)
        let decodeLoopBody = try sourceSlice(
            from: "private func startDecodeLoopIfNeeded()",
            to: "@MainActor\n    private func finishDecodeTask(",
            in: source
        )
        XCTAssertTrue(decodeLoopBody.contains("Task.detached(priority: .high)"))
        XCTAssertTrue(decodeLoopBody.contains("try await decoder.submit(screenData: screenData)"))
        XCTAssertTrue(decodeLoopBody.contains("try await handle.wait()"))
        XCTAssertFalse(
            decodeLoopBody.contains("Task { @MainActor"),
            "HEVC submission and callback wait must not run on MainActor; only decoded results should return to MainActor for UI/Metal state."
        )
    }

    func testSuccessfulDecodeUsesOrderedCompletionDrainBeforeApplyingMetalFrame() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )
        let source = try readRepositorySourceForSourceShapeTests(at: sourceURL)
        let drainBody = try sourceSlice(
            from: "private func drainDecodeCompletionsIfNeeded()",
            to: "private func applyDecodeCompletion(",
            in: source
        )
        let applyBody = try sourceSlice(
            from: "private func applyDecodeCompletion(",
            to: "consecutiveDecodeMisses += 1",
            in: source
        )

        XCTAssertTrue(source.contains("pendingDecodeCompletions[decodeOrder]"))
        XCTAssertTrue(source.contains("completeDecodeTask(for: decodeGeneration)"))
        XCTAssertTrue(source.contains("await drainDecodeCompletionsIfNeeded()"))
        XCTAssertTrue(drainBody.contains("pendingDecodeCompletions.removeValue(forKey: nextDecodeCompletionOrder)"))
        XCTAssertTrue(drainBody.contains("nextDecodeCompletionOrder &+= 1"))
        XCTAssertTrue(applyBody.contains("await applyDecodedOutput("))
        XCTAssertTrue(applyBody.contains("guard applied else { return }"))
    }

    func testNativeVideoPromotionRequiresNonNilRenderedFrame() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let rendererSourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/RemoteVideoTrackHeartbeatRenderer.swift"
        )
        let managerSource = try readRepositorySourceForSourceShapeTests(at: managerSourceURL)
        let rendererSource = try readRepositorySourceForSourceShapeTests(at: rendererSourceURL)

        XCTAssertTrue(rendererSource.contains("func renderFrame(_ frame: RTCVideoFrame?)"))
        XCTAssertTrue(
            rendererSource.contains("guard let frame else { return }"),
            "renderFrame(nil) is only a heartbeat/size event and must not trigger nativeReady evidence."
        )
        XCTAssertTrue(managerSource.contains("renderer-bound-no-native-frame"))
    }

    func testVisibleNativeVideoPromotionIsDrivenByObservableMTLViewRenderFrame() throws {
        let source = try remoteDesktopViewSource()
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
        let managerSourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )
        let viewSource = try remoteDesktopViewSource()
        let managerSource = try readRepositorySourceForSourceShapeTests(at: managerSourceURL)
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

    private func remoteDesktopViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePaths = [
            "SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift",
            "SkyBridgeCompassiOS/Sources/Views/RemoteDesktopRTCVideoView.swift"
        ]
        return try sourcePaths.map { path in
            try readRepositorySourceForSourceShapeTests(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")
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
