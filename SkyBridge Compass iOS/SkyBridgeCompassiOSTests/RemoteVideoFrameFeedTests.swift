import XCTest
import AVFoundation
import Combine
import ImageIO
import SkyBridgeCameraKit
import UniformTypeIdentifiers
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class RemoteVideoFrameFeedTests: XCTestCase {
    func testDecoderPixelBudgetSupportsPublished5KAndEquivalentPortrait() throws {
        let landscape = try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
            width: 5_120,
            height: 2_880
        )
        let portrait = try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
            width: 2_880,
            height: 5_120
        )

        XCTAssertEqual(landscape.pixelBytes, 5_120 * 2_880 * 4)
        XCTAssertEqual(portrait.pixelBytes, landscape.pixelBytes)
        XCTAssertEqual(
            landscape.pixelBytes,
            RemoteDesktopVideoDecoderLimits.maximumDecodedPixelBytes
        )
    }

    func testDecoderPixelBudgetRejectsNonFiniteAndOversizedDimensions() {
        XCTAssertThrowsError(
            try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
                width: .infinity,
                height: 1
            )
        ) { error in
            XCTAssertEqual(error as? RemoteDesktopVideoDecoderInputError, .invalidDimensions)
        }
        XCTAssertThrowsError(
            try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
                width: 5_121,
                height: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteDesktopVideoDecoderInputError,
                .dimensionLimitExceeded(actual: 5_121, maximum: 5_120)
            )
        }
        XCTAssertThrowsError(
            try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
                width: 4_000,
                height: 4_000
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteDesktopVideoDecoderInputError,
                .decodedFrameTooLarge(
                    actualBytes: 4_000 * 4_000 * 4,
                    maximumBytes: 5_120 * 2_880 * 4
                )
            )
        }
    }

    func testFormatDescriptionDimensionsAreBoundedBeforeVideoToolboxSessionCreation() throws {
        var createdFormatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_H264,
                width: 5_121,
                height: 1,
                extensions: nil,
                formatDescriptionOut: &createdFormatDescription
            ),
            noErr
        )
        let description = try XCTUnwrap(createdFormatDescription)
        XCTAssertThrowsError(
            try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(of: description)
        ) { error in
            XCTAssertEqual(
                error as? RemoteDesktopVideoDecoderInputError,
                .dimensionLimitExceeded(actual: 5_121, maximum: 5_120)
            )
        }

        let source = try videoDecoderSource()
        let sessionCreationBody = try sourceSlice(
            from: "private func ensureDecompressionSession(",
            to: "private func submitPixelBufferDecode(",
            in: source
        )
        let validationOffset = try XCTUnwrap(
            sessionCreationBody.range(of: "validatedPixelDimensions(\n            of: formatDescription")
        ).lowerBound
        let allocationOffset = try XCTUnwrap(
            sessionCreationBody.range(of: "VTDecompressionSessionCreate(")
        ).lowerBound
        XCTAssertLessThan(validationOffset, allocationOffset)
    }

    func testStillImageMetadataLimitFailsBeforeDecodeAllocation() async throws {
        let encodedImage = try makeJPEG(width: 5_121, height: 1)
        XCTAssertLessThan(encodedImage.count, RemoteDesktopVideoDecoderLimits.maximumEncodedImageBytes)
        let decoder = VideoDecoder()

        do {
            _ = try await decoder.decode(
                screenData: ScreenData(
                    width: 1,
                    height: 1,
                    imageData: encodedImage,
                    timestamp: 0,
                    format: "jpeg"
                )
            )
            XCTFail("Oversized ImageIO metadata must fail before CIImage render or IOSurface allocation")
        } catch {
            XCTAssertEqual(
                error as? RemoteDesktopVideoDecoderInputError,
                .dimensionLimitExceeded(actual: 5_121, maximum: 5_120)
            )
        }
    }

    func testBGRARequiresExactValidatedPixelByteCount() async {
        let decoder = VideoDecoder()
        do {
            _ = try await decoder.decode(
                screenData: ScreenData(
                    width: 2,
                    height: 2,
                    imageData: Data(repeating: 0, count: 15),
                    timestamp: 0,
                    format: "bgra"
                )
            )
            XCTFail("Truncated BGRA must fail instead of producing a partial image")
        } catch {
            XCTAssertEqual(
                error as? RemoteDesktopVideoDecoderInputError,
                .bgraByteCountMismatch(expected: 16, actual: 15)
            )
        }
    }

    func testAccessUnitParserAcceptsCompleteAnnexBAndLengthPrefixedData() throws {
        let annexB = Data([
            0, 0, 0, 1, 0x67, 0x01,
            0, 0, 1, 0x65, 0x02, 0x03
        ])
        XCTAssertEqual(
            try RemoteDesktopVideoAccessUnitParser.parse(annexB, codec: .h264),
            [Data([0x67, 0x01]), Data([0x65, 0x02, 0x03])]
        )

        let lengthPrefixed = Data([
            0, 0, 0, 2, 0x67, 0x01,
            0, 0, 0, 3, 0x65, 0x02, 0x03
        ])
        XCTAssertEqual(
            try RemoteDesktopVideoAccessUnitParser.parse(lengthPrefixed, codec: .h264),
            [Data([0x67, 0x01]), Data([0x65, 0x02, 0x03])]
        )
    }

    func testAccessUnitParserRejectsTruncatedAnnexBAndLengthPrefixedData() {
        let truncatedLengthPrefix = Data([0, 0, 0, 5, 0x65, 0x01])
        XCTAssertThrowsError(
            try RemoteDesktopVideoAccessUnitParser.parse(truncatedLengthPrefix, codec: .h264)
        ) { error in
            XCTAssertEqual(error as? RemoteDesktopVideoDecoderInputError, .malformedAccessUnit)
        }

        let trailingAnnexBStartCode = Data([0, 0, 0, 1, 0x65, 0, 0, 1])
        XCTAssertThrowsError(
            try RemoteDesktopVideoAccessUnitParser.parse(trailingAnnexBStartCode, codec: .h264)
        ) { error in
            XCTAssertEqual(error as? RemoteDesktopVideoDecoderInputError, .malformedAccessUnit)
        }

        let trailingLengthPrefixByte = Data([0, 0, 0, 2, 0x65, 0x01, 0])
        XCTAssertThrowsError(
            try RemoteDesktopVideoAccessUnitParser.parse(trailingLengthPrefixByte, codec: .h264)
        ) { error in
            XCTAssertEqual(error as? RemoteDesktopVideoDecoderInputError, .malformedAccessUnit)
        }

        let truncatedHEVCHeader = Data([0, 0, 0, 1, 0x26])
        XCTAssertThrowsError(
            try RemoteDesktopVideoAccessUnitParser.parse(truncatedHEVCHeader, codec: .hevc)
        ) { error in
            XCTAssertEqual(error as? RemoteDesktopVideoDecoderInputError, .malformedAccessUnit)
        }
    }

    func testAccessUnitParserEnforcesIndependentAllocationBounds() throws {
        let oversizedAccessUnit = Data(
            repeating: 0,
            count: RemoteDesktopVideoDecoderLimits.maximumAccessUnitBytes + 1
        )
        XCTAssertThrowsError(
            try RemoteDesktopVideoAccessUnitParser.parse(oversizedAccessUnit, codec: .h264)
        ) { error in
            XCTAssertEqual(
                error as? RemoteDesktopVideoDecoderInputError,
                .accessUnitTooLarge(
                    actualBytes: RemoteDesktopVideoDecoderLimits.maximumAccessUnitBytes + 1,
                    maximumBytes: RemoteDesktopVideoDecoderLimits.maximumAccessUnitBytes
                )
            )
        }

        var largeIDRNALUnit = Data([0, 0, 0, 1])
        largeIDRNALUnit.append(
            Data(
                repeating: 0x65,
                count: RemoteDesktopVideoDecoderLimits.maximumParameterSetBytes + 1
            )
        )
        let parsedLargeIDR = try RemoteDesktopVideoAccessUnitParser.parse(
            largeIDRNALUnit,
            codec: .h264
        )
        XCTAssertEqual(parsedLargeIDR.count, 1)
        XCTAssertEqual(parsedLargeIDR[0].count, RemoteDesktopVideoDecoderLimits.maximumParameterSetBytes + 1)

        var oversizedParameterSet = Data([0, 0, 0, 1, 0x67])
        oversizedParameterSet.append(
            Data(
                repeating: 0,
                count: RemoteDesktopVideoDecoderLimits.maximumParameterSetBytes
            )
        )
        XCTAssertThrowsError(
            try RemoteDesktopVideoAccessUnitParser.parse(oversizedParameterSet, codec: .h264)
        ) { error in
            XCTAssertEqual(
                error as? RemoteDesktopVideoDecoderInputError,
                .nalUnitTooLarge(
                    actualBytes: RemoteDesktopVideoDecoderLimits.maximumParameterSetBytes + 1,
                    maximumBytes: RemoteDesktopVideoDecoderLimits.maximumParameterSetBytes
                )
            )
        }

        let oversizedParameterSetLength = RemoteDesktopVideoDecoderLimits.maximumParameterSetBytes + 1
        var bigEndianLength = UInt32(oversizedParameterSetLength).bigEndian
        var lengthPrefixedParameterSet = Data()
        withUnsafeBytes(of: &bigEndianLength) { lengthBytes in
            lengthPrefixedParameterSet.append(contentsOf: lengthBytes)
        }
        lengthPrefixedParameterSet.append(0x67)
        lengthPrefixedParameterSet.append(
            Data(repeating: 0, count: oversizedParameterSetLength - 1)
        )
        XCTAssertThrowsError(
            try RemoteDesktopVideoAccessUnitParser.parse(
                lengthPrefixedParameterSet,
                codec: .h264
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteDesktopVideoDecoderInputError,
                .nalUnitTooLarge(
                    actualBytes: oversizedParameterSetLength,
                    maximumBytes: RemoteDesktopVideoDecoderLimits.maximumParameterSetBytes
                )
            )
        }

        var tooManyNALUnits = Data()
        for _ in 0...RemoteDesktopVideoDecoderLimits.maximumNALUnits {
            tooManyNALUnits.append(contentsOf: [0, 0, 1, 0x65])
        }
        XCTAssertThrowsError(
            try RemoteDesktopVideoAccessUnitParser.parse(tooManyNALUnits, codec: .h264)
        ) { error in
            XCTAssertEqual(
                error as? RemoteDesktopVideoDecoderInputError,
                .tooManyNALUnits(
                    actual: RemoteDesktopVideoDecoderLimits.maximumNALUnits + 1,
                    maximum: RemoteDesktopVideoDecoderLimits.maximumNALUnits
                )
            )
        }
    }

    func testH264ParameterSetsCommitOnlyAsACompleteSyncBootstrap() {
        var coordinator = RemoteDesktopVideoParameterSetCoordinator()
        let sps = Data([0x67, 0x01])
        let pps = Data([0x68, 0x01])
        let idr = Data([0x65, 0x01])

        XCTAssertEqual(
            coordinator.consume(nalus: [sps], codec: .h264, containsSyncFrame: false),
            .requiresCompleteSyncSet
        )
        XCTAssertNil(coordinator.activeSnapshot)
        XCTAssertTrue(coordinator.isWaitingForCompleteSyncSet)

        XCTAssertEqual(
            coordinator.consume(nalus: [sps, pps], codec: .h264, containsSyncFrame: false),
            .requiresCompleteSyncSet
        )
        XCTAssertNil(coordinator.activeSnapshot)

        XCTAssertEqual(
            coordinator.consume(nalus: [sps, pps, idr], codec: .h264, containsSyncFrame: true),
            .committed(changed: true)
        )
        XCTAssertEqual(
            coordinator.activeSnapshot,
            RemoteDesktopVideoParameterSetSnapshot(
                codec: .h264,
                vps: nil,
                sps: sps,
                pps: pps
            )
        )
        XCTAssertFalse(coordinator.isWaitingForCompleteSyncSet)
    }

    func testH264ParameterSetTransitionNeverMixesNewSPSWithOldPPS() {
        var coordinator = RemoteDesktopVideoParameterSetCoordinator()
        let oldSPS = Data([0x67, 0x01])
        let oldPPS = Data([0x68, 0x01])
        let newSPS = Data([0x67, 0x02])
        let newPPS = Data([0x68, 0x02])
        let idr = Data([0x65, 0x01])

        XCTAssertEqual(
            coordinator.consume(
                nalus: [oldSPS, oldPPS, idr],
                codec: .h264,
                containsSyncFrame: true
            ),
            .committed(changed: true)
        )
        let oldSnapshot = coordinator.activeSnapshot

        XCTAssertEqual(
            coordinator.consume(
                nalus: [newSPS, idr],
                codec: .h264,
                containsSyncFrame: true
            ),
            .requiresCompleteSyncSet
        )
        XCTAssertEqual(coordinator.activeSnapshot, oldSnapshot)
        XCTAssertTrue(coordinator.isWaitingForCompleteSyncSet)

        XCTAssertEqual(
            coordinator.consume(nalus: [idr], codec: .h264, containsSyncFrame: true),
            .requiresCompleteSyncSet,
            "An IDR without the complete pending set must not resume with the old PPS"
        )
        XCTAssertEqual(coordinator.activeSnapshot, oldSnapshot)

        XCTAssertEqual(
            coordinator.consume(
                nalus: [newSPS, newPPS, idr],
                codec: .h264,
                containsSyncFrame: true
            ),
            .committed(changed: true)
        )
        XCTAssertEqual(coordinator.activeSnapshot?.sps, newSPS)
        XCTAssertEqual(coordinator.activeSnapshot?.pps, newPPS)
        XCTAssertFalse(coordinator.isWaitingForCompleteSyncSet)
    }

    func testHEVCParameterSetTransitionRequiresVPSBeforeAtomicCommit() {
        var coordinator = RemoteDesktopVideoParameterSetCoordinator()
        let vps = Data([0x40, 0x01])
        let sps = Data([0x42, 0x01])
        let pps = Data([0x44, 0x01])
        let irap = Data([0x26, 0x01])

        XCTAssertEqual(
            coordinator.consume(
                nalus: [sps, pps, irap],
                codec: .hevc,
                containsSyncFrame: true
            ),
            .requiresCompleteSyncSet
        )
        XCTAssertNil(coordinator.activeSnapshot)

        XCTAssertEqual(
            coordinator.consume(
                nalus: [vps, sps, pps, irap],
                codec: .hevc,
                containsSyncFrame: true
            ),
            .committed(changed: true)
        )
        XCTAssertEqual(coordinator.activeSnapshot?.vps, vps)
        XCTAssertEqual(coordinator.activeSnapshot?.sps, sps)
        XCTAssertEqual(coordinator.activeSnapshot?.pps, pps)
    }

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
        XCTAssertTrue(source.contains("onFramesDisplayed: @escaping @Sendable ("))
        XCTAssertTrue(source.contains("CameraFramePresentationContext?"))
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
        XCTAssertTrue(decodeLoopBody.contains("let task = Task.detached("))
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

        var createdFormatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &createdFormatDescription
            ),
            noErr
        )
        let formatDescription = try XCTUnwrap(
            createdFormatDescription,
            "CMVideoFormatDescriptionCreateForImageBuffer returned success without a format description"
        )

        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 60),
            decodeTimeStamp: .invalid
        )
        var createdSampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timingInfo,
                sampleBufferOut: &createdSampleBuffer
            ),
            noErr
        )
        let sampleBuffer = try XCTUnwrap(
            createdSampleBuffer,
            "CMSampleBufferCreateReadyWithImageBuffer returned success without a sample buffer"
        )

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
        return try XCTUnwrap(
            pixelBuffer,
            "CVPixelBufferCreate returned success without a pixel buffer"
        )
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func videoDecoderSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopVideoDecoder.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
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

@available(iOS 17.0, *)
private actor CameraStopProbe {
    private var count = 0

    func recordStop() {
        count += 1
    }

    func snapshot() -> Int {
        count
    }
}

@available(iOS 17.0, *)
private actor CameraOperationBarrier {
    private var didEnter = false
    private var isReleased = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        precondition(!didEnter, "CameraOperationBarrier supports exactly one suspended operation")
        didEnter = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            precondition(releaseContinuation == nil)
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            precondition(enteredContinuation == nil)
            enteredContinuation = continuation
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@available(iOS 17.0, *)
@MainActor
final class CameraRemoteDesktopManagerTests: XCTestCase {
    func testPlaintextRTSPCannotBypassAcknowledgementAtManagerBoundary() async {
        do {
            try await RemoteDesktopManager.instance.startCameraStreaming(
                endpoint: "rtsp://192.168.1.20/live"
            )
            XCTFail("Plaintext RTSP must require explicit acknowledgement")
        } catch {
            XCTAssertEqual(
                error as? CameraRemoteDesktopRuntimeError,
                .plaintextAcknowledgementRequired
            )
        }
    }

    func testCredentialsMustBeSuppliedAsAPairBeforeClientCreation() async {
        do {
            try await RemoteDesktopManager.instance.startCameraStreaming(
                endpoint: "rtsp://192.168.1.20/live",
                username: "viewer",
                password: nil,
                acknowledgesPlaintextRTSP: true
            )
            XCTFail("Partial credentials must fail closed")
        } catch {
            XCTAssertEqual(
                error as? CameraRemoteDesktopRuntimeError,
                .incompleteCredentials
            )
        }
    }

    func testDisplayNameRejectsControlCharactersBeforeClientCreation() async {
        do {
            try await RemoteDesktopManager.instance.startCameraStreaming(
                endpoint: "rtsps://192.168.1.20/live",
                displayName: "Living room\ncredential=secret"
            )
            XCTFail("Control characters in a camera display name must be rejected")
        } catch {
            XCTAssertEqual(error as? CameraRemoteDesktopRuntimeError, .invalidDisplayName)
        }
    }

    func testCameraDisplayNameUsesLocalizedDefaultWithoutWeakeningValidation() throws {
        XCTAssertEqual(
            try CameraDisplayNamePolicy.validated(nil, defaultName: "Smart Camera"),
            "Smart Camera"
        )
        XCTAssertEqual(
            try CameraDisplayNamePolicy.validated("  \n ", defaultName: "スマートカメラ"),
            "スマートカメラ"
        )
        XCTAssertEqual(
            try CameraDisplayNamePolicy.validated("  Living Room  ", defaultName: "Smart Camera"),
            "Living Room"
        )
        XCTAssertThrowsError(
            try CameraDisplayNamePolicy.validated(
                "Living\nRoom",
                defaultName: "Smart Camera"
            )
        ) { error in
            XCTAssertEqual(error as? CameraRemoteDesktopRuntimeError, .invalidDisplayName)
        }
        XCTAssertThrowsError(
            try CameraDisplayNamePolicy.validated(
                String(repeating: "a", count: 129),
                defaultName: "Smart Camera"
            )
        ) { error in
            XCTAssertEqual(error as? CameraRemoteDesktopRuntimeError, .invalidDisplayName)
        }

        let source = try remoteDesktopManagerSource()
        XCTAssertTrue(source.contains("defaultName: RuntimeLocalization.string(\"智能监控\")"))
    }

    func testCameraConnectionFormOnlyEnablesSupportedSchemes() {
        XCTAssertFalse(canSubmitCameraEndpoint(""))
        XCTAssertFalse(canSubmitCameraEndpoint("192.168.1.20/live"))
        XCTAssertFalse(canSubmitCameraEndpoint("http://192.168.1.20/live"))
        XCTAssertFalse(canSubmitCameraEndpoint("rtspx://192.168.1.20/live"))
        XCTAssertFalse(canSubmitCameraEndpoint("rtsp://192.168.1.20/live"))
        XCTAssertTrue(
            canSubmitCameraEndpoint(
                "rtsp://192.168.1.20/live",
                acknowledgesPlaintextRTSP: true
            )
        )
        XCTAssertTrue(canSubmitCameraEndpoint("  RTSPS://192.168.1.20/live  "))
        XCTAssertFalse(
            canSubmitCameraEndpoint(
                "rtsps://192.168.1.20/live",
                username: "viewer"
            )
        )
        XCTAssertFalse(
            canSubmitCameraEndpoint(
                "rtsps://192.168.1.20/live",
                isConnecting: true
            )
        )
    }

    func testCameraConnectionSheetDelegatesEligibilityToFailClosedPolicy() throws {
        let source = try remoteDesktopViewSource()
        let sheetStart = try XCTUnwrap(source.range(of: "private struct CameraConnectionSheet"))
        let sheetSource = String(source[sheetStart.lowerBound...])

        XCTAssertTrue(sheetSource.contains("CameraConnectionFormPolicy.canConnect("))
        XCTAssertFalse(sheetSource.contains("normalizedScheme != \"rtsp\""))
    }

    func testCameraRuntimeLocalizationKeysExistInEverySupportedTable() throws {
        let keys = [
            "智能监控",
            "智能监控 · RTSPS",
            "智能监控 · RTSP（明文）",
            "智能监控已断开",
            "好",
            "连接智能监控",
            "智能监控为只读画面，不会发送键盘或触控输入",
            "摄像头流地址",
            "显示名称（可选）",
            "请输入摄像头提供的精确 RTSP/RTSPS 地址。首版仅允许本地私网 IP、H.264 与 RTP-over-RTSP TCP；不会猜测路径或连接厂商云服务。",
            "摄像头凭据（可选）",
            "用户名",
            "密码",
            "用户名和密码必须同时填写。",
            "明文传输警告",
            "我了解 RTSP 控制信令与视频未加密；仅使用 Digest 认证，绝不允许 Basic 明文认证。",
            "RTSPS 使用系统证书信任与主机身份校验；证书错误会直接失败。",
            "取消连接",
            "取消",
            "连接摄像头",
            "摄像头连接失败"
        ]
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceRoot = projectRoot
            .appendingPathComponent("SkyBridgeCompassiOS")
            .appendingPathComponent("Resources")

        for locale in ["en", "ja", "zh-Hans"] {
            let tableURL = resourceRoot
                .appendingPathComponent("\(locale).lproj")
                .appendingPathComponent("Localizable.strings")
            let table = try String(contentsOf: tableURL, encoding: .utf8)
            for key in keys {
                XCTAssertTrue(
                    table.contains("\"\(key)\" = "),
                    "Missing camera localization key '\(key)' in \(locale)"
                )
            }
        }
    }

    func testBackgroundStopIsSingleOwnerAndClearsReadOnlySession() async {
        let manager = RemoteDesktopManager.instance
        await manager.disconnect(tearDownTransport: true)

        let stopProbe = CameraStopProbe()
        let (stream, continuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: { stream },
                connectAndPlay: {},
                stop: {
                    await stopProbe.recordStop()
                    continuation.finish()
                }
            )
        }
        defer {
            manager.restoreProductionCameraClientFactoryForTesting()
        }

        let startTask = Task { @MainActor in
            try await manager.startCameraStreaming(
                endpoint: "rtsps://192.168.1.20/live",
                displayName: "Test camera"
            )
        }

        for _ in 0..<100 where !manager.isReadOnlyCameraSession {
            await Task.yield()
        }
        XCTAssertTrue(manager.isReadOnlyCameraSession)
        XCTAssertNil(manager.currentConnection, "A transport-only camera must not be presented as connected")
        XCTAssertNotNil(manager.pendingCameraPresentationConnection)
        XCTAssertTrue(manager.isCameraAwaitingFirstPresentation)
        XCTAssertFalse(manager.isStreaming)

        await manager.simulateCameraApplicationBackgroundForTesting()

        do {
            try await startTask.value
            XCTFail("Background teardown must fail the pending visible-frame wait")
        } catch {
            XCTAssertEqual(error as? CameraRemoteDesktopRuntimeError, .stopped)
        }
        let stopCount = await stopProbe.snapshot()
        XCTAssertEqual(stopCount, 1, "RTSP stop/TEARDOWN must have one owner")
        XCTAssertFalse(manager.isReadOnlyCameraSession)
        XCTAssertFalse(manager.isStreaming)
        XCTAssertNil(manager.currentConnection)
        if case .disconnected = manager.state {
            // Expected terminal state.
        } else {
            XCTFail("Background camera teardown must leave the manager disconnected")
        }
    }

    func testConcurrentCameraStartFailsBeforeReplacingSuspendedOwner() async {
        let manager = RemoteDesktopManager.instance
        await manager.disconnect(tearDownTransport: true)

        let framesBarrier = CameraOperationBarrier()
        let stopProbe = CameraStopProbe()
        let (stream, continuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: {
                    await framesBarrier.suspendUntilReleased()
                    return stream
                },
                connectAndPlay: {},
                stop: {
                    await stopProbe.recordStop()
                    await framesBarrier.release()
                    continuation.finish()
                }
            )
        }
        defer {
            manager.restoreProductionCameraClientFactoryForTesting()
        }

        let firstStartTask = Task { @MainActor in
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/first")
        }
        await framesBarrier.waitUntilEntered()
        let firstPendingID = manager.pendingCameraPresentationConnection?.id
        XCTAssertNotNil(firstPendingID)
        XCTAssertTrue(manager.isCameraAwaitingFirstPresentation)

        do {
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/second")
            XCTFail("A concurrent camera start must fail before replacing the reserved owner")
        } catch {
            XCTAssertEqual(
                error as? CameraRemoteDesktopRuntimeError,
                .connectionAttemptInProgress
            )
        }
        XCTAssertEqual(manager.pendingCameraPresentationConnection?.id, firstPendingID)

        firstStartTask.cancel()
        await framesBarrier.release()
        do {
            try await firstStartTask.value
            XCTFail("Cancelling the reserved start must stop its owned camera client")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let stopCount = await stopProbe.snapshot()
        XCTAssertEqual(stopCount, 1)
        assertCameraSessionIsCleared(manager)
    }

    func testCameraTeardownBlocksReplacementUntilOwnedStopCompletes() async throws {
        let manager = RemoteDesktopManager.instance
        await manager.disconnect(tearDownTransport: true)
        let decodedFrame = try makeCameraPixelBufferFrame()

        let firstStopBarrier = CameraOperationBarrier()
        let firstStopProbe = CameraStopProbe()
        let (firstStream, firstContinuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: { firstStream },
                connectAndPlay: {},
                stop: {
                    await firstStopProbe.recordStop()
                    await firstStopBarrier.suspendUntilReleased()
                    firstContinuation.finish()
                }
            )
        }
        defer {
            manager.restoreProductionCameraClientFactoryForTesting()
        }

        let firstStartTask = Task { @MainActor in
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/first")
        }
        for _ in 0..<200 where !manager.isCameraAwaitingFirstPresentation {
            await Task.yield()
        }
        let enqueuedFirstContext = await manager.enqueueDecodedCameraFrameForTesting(decodedFrame)
        let firstContext = try XCTUnwrap(enqueuedFirstContext)
        await manager.handleMetalRendererDidDisplayFrames(
            presentationTimeStamp: decodedFrame.presentationTimeStamp,
            displayedFrameCount: 1,
            completedAt: Date(),
            cameraPresentationContext: firstContext
        )
        try await firstStartTask.value
        let firstConnectionID = try XCTUnwrap(manager.currentConnection?.id)

        let disconnectTask = Task { @MainActor in
            await manager.disconnect(tearDownTransport: true)
        }
        await firstStopBarrier.waitUntilEntered()
        XCTAssertTrue(manager.isReadOnlyCameraSession)
        XCTAssertFalse(manager.isStreaming)
        XCTAssertNil(manager.currentConnection)
        XCTAssertNil(manager.pendingCameraPresentationConnection)

        let secondStopProbe = CameraStopProbe()
        let (secondStream, secondContinuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: { secondStream },
                connectAndPlay: {},
                stop: {
                    await secondStopProbe.recordStop()
                    secondContinuation.finish()
                }
            )
        }
        let secondStartTask = Task { @MainActor in
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/second")
        }
        for _ in 0..<200 where !manager.cameraStartAttemptInProgressForTesting {
            await Task.yield()
        }
        guard manager.cameraStartAttemptInProgressForTesting else {
            secondStartTask.cancel()
            await firstStopBarrier.release()
            await disconnectTask.value
            _ = try? await secondStartTask.value
            XCTFail("The replacement start never reserved its teardown-wait ownership")
            return
        }
        XCTAssertNil(
            manager.pendingCameraPresentationConnection,
            "A replacement camera must not publish ownership before the prior stop completes"
        )
        do {
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/third")
            XCTFail("Only one replacement attempt may wait for teardown completion")
        } catch {
            XCTAssertEqual(
                error as? CameraRemoteDesktopRuntimeError,
                .connectionAttemptInProgress
            )
        }

        await firstStopBarrier.release()
        await disconnectTask.value
        for _ in 0..<200 where !manager.isCameraAwaitingFirstPresentation {
            await Task.yield()
        }
        let secondConnectionID = try XCTUnwrap(manager.pendingCameraPresentationConnection?.id)
        XCTAssertNotEqual(secondConnectionID, firstConnectionID)
        let firstStopCount = await firstStopProbe.snapshot()
        XCTAssertEqual(firstStopCount, 1)

        secondStartTask.cancel()
        do {
            try await secondStartTask.value
            XCTFail("Cancelling the replacement camera must terminate its presentation wait")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let secondStopCount = await secondStopProbe.snapshot()
        XCTAssertEqual(secondStopCount, 1)
        assertCameraSessionIsCleared(manager)
    }

    func testCameraDecodedAndEnqueuedFrameWithoutRendererPresentationTimesOut() async throws {
        let manager = RemoteDesktopManager.instance
        await manager.disconnect(tearDownTransport: true)
        let decodedFrame = try makeCameraPixelBufferFrame()
        let stopProbe = CameraStopProbe()
        let (stream, continuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: { stream },
                connectAndPlay: {},
                stop: {
                    await stopProbe.recordStop()
                    continuation.finish()
                }
            )
        }
        manager.installCameraVisibleFrameTimeoutForTesting(.milliseconds(250))
        defer {
            manager.restoreProductionCameraClientFactoryForTesting()
        }

        let startTask = Task { @MainActor in
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/live")
        }
        for _ in 0..<200 where !manager.isCameraAwaitingFirstPresentation {
            await Task.yield()
        }
        XCTAssertTrue(manager.isCameraAwaitingFirstPresentation)
        XCTAssertFalse(manager.isStreaming)
        let pendingConnection = try XCTUnwrap(manager.pendingCameraPresentationConnection)
        XCTAssertEqual(pendingConnection.status, .connecting)
        XCTAssertFalse(pendingConnection.device.isConnected)
        let enqueuedContext = await manager.enqueueDecodedCameraFrameForTesting(decodedFrame)
        XCTAssertNotNil(
            enqueuedContext,
            "The regression setup must exercise the real camera-to-Metal feed enqueue path"
        )
        XCTAssertNil(manager.currentConnection)

        do {
            try await startTask.value
            XCTFail("Decode and renderer enqueue must not satisfy the visible-frame gate")
        } catch {
            XCTAssertEqual(
                error as? CameraRemoteDesktopRuntimeError,
                .firstVisibleFrameTimedOut
            )
        }
        let stopCount = await stopProbe.snapshot()
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(manager.isReadOnlyCameraSession)
        XCTAssertFalse(manager.isStreaming)
        XCTAssertNil(manager.currentConnection)
        XCTAssertNil(manager.pendingCameraPresentationConnection)
        XCTAssertFalse(manager.isCameraAwaitingFirstPresentation)
    }

    func testCameraRendererPresentationPromotesExactlyOnce() async throws {
        let manager = RemoteDesktopManager.instance
        await manager.disconnect(tearDownTransport: true)
        let decodedFrame = try makeCameraPixelBufferFrame()
        let stopProbe = CameraStopProbe()
        let (stream, continuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: { stream },
                connectAndPlay: {},
                stop: {
                    await stopProbe.recordStop()
                    continuation.finish()
                }
            )
        }
        manager.installCameraVisibleFrameTimeoutForTesting(.seconds(2))
        defer {
            manager.restoreProductionCameraClientFactoryForTesting()
        }

        let startTask = Task { @MainActor in
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/live")
        }
        for _ in 0..<200 where !manager.isCameraAwaitingFirstPresentation {
            await Task.yield()
        }
        let pendingConnection = try XCTUnwrap(manager.pendingCameraPresentationConnection)
        XCTAssertEqual(pendingConnection.status, .connecting)
        XCTAssertFalse(pendingConnection.device.isConnected)
        XCTAssertFalse(manager.isStreaming)
        XCTAssertNil(manager.currentConnection)
        let enqueuedContext = await manager.enqueueDecodedCameraFrameForTesting(decodedFrame)
        let context = try XCTUnwrap(enqueuedContext)
        let presentedAt = Date()
        await manager.handleMetalRendererDidDisplayFrames(
            presentationTimeStamp: decodedFrame.presentationTimeStamp,
            displayedFrameCount: 1,
            completedAt: presentedAt,
            cameraPresentationContext: context
        )
        try await startTask.value

        let connectionID = try XCTUnwrap(manager.currentConnection?.id)
        XCTAssertEqual(manager.state, .streaming)
        XCTAssertTrue(manager.isStreaming)
        XCTAssertEqual(manager.currentConnection?.status, .connected)
        XCTAssertEqual(manager.currentConnection?.device.isConnected, true)
        XCTAssertNil(manager.pendingCameraPresentationConnection)
        XCTAssertFalse(manager.isCameraAwaitingFirstPresentation)
        XCTAssertEqual(manager.cameraFirstPresentationCompletionCountForTesting, 1)

        await manager.handleMetalRendererDidDisplayFrames(
            presentationTimeStamp: decodedFrame.presentationTimeStamp,
            displayedFrameCount: 1,
            completedAt: presentedAt,
            cameraPresentationContext: context
        )
        XCTAssertEqual(manager.currentConnection?.id, connectionID)
        XCTAssertEqual(manager.cameraFirstPresentationCompletionCountForTesting, 1)

        await manager.disconnect(tearDownTransport: true)
        let stopCount = await stopProbe.snapshot()
        XCTAssertEqual(stopCount, 1)
    }

    func testCameraPresentationFromCancelledSessionCannotPromoteNewSession() async throws {
        let manager = RemoteDesktopManager.instance
        await manager.disconnect(tearDownTransport: true)
        let decodedFrame = try makeCameraPixelBufferFrame()
        let firstStopProbe = CameraStopProbe()
        let (firstStream, firstContinuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: { firstStream },
                connectAndPlay: {},
                stop: {
                    await firstStopProbe.recordStop()
                    firstContinuation.finish()
                }
            )
        }
        manager.installCameraVisibleFrameTimeoutForTesting(.seconds(2))
        defer {
            manager.restoreProductionCameraClientFactoryForTesting()
        }

        let firstStartTask = Task { @MainActor in
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/first")
        }
        for _ in 0..<200 where !manager.isCameraAwaitingFirstPresentation {
            await Task.yield()
        }
        let enqueuedContext = await manager.enqueueDecodedCameraFrameForTesting(decodedFrame)
        let staleContext = try XCTUnwrap(enqueuedContext)
        firstStartTask.cancel()
        do {
            try await firstStartTask.value
            XCTFail("Cancelling the first session must fail its presentation wait")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let firstStopCount = await firstStopProbe.snapshot()
        XCTAssertEqual(firstStopCount, 1)

        let secondStopProbe = CameraStopProbe()
        let (secondStream, secondContinuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: { secondStream },
                connectAndPlay: {},
                stop: {
                    await secondStopProbe.recordStop()
                    secondContinuation.finish()
                }
            )
        }
        let secondStartTask = Task { @MainActor in
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/second")
        }
        for _ in 0..<200 where !manager.isCameraAwaitingFirstPresentation {
            await Task.yield()
        }
        XCTAssertTrue(manager.isCameraAwaitingFirstPresentation)
        XCTAssertFalse(manager.isStreaming)

        await manager.handleMetalRendererDidDisplayFrames(
            presentationTimeStamp: decodedFrame.presentationTimeStamp,
            displayedFrameCount: 1,
            completedAt: Date(),
            cameraPresentationContext: staleContext
        )
        XCTAssertNil(manager.currentConnection)
        XCTAssertEqual(manager.state, .connecting)
        XCTAssertEqual(manager.cameraFirstPresentationCompletionCountForTesting, 0)

        secondStartTask.cancel()
        do {
            try await secondStartTask.value
            XCTFail("Cancelling the second pending session must stop it")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let secondStopCount = await secondStopProbe.snapshot()
        XCTAssertEqual(secondStopCount, 1)
    }

    func testCameraFrameActivationGateReleasesExactlyAfterActivation() async throws {
        let gate = CameraFrameActivationGate()
        let waiter = Task {
            try await gate.waitUntilActive()
        }
        await Task.yield()
        await gate.activate()
        try await waiter.value
    }

    func testCameraFrameActivationGateRejectsPreCancelledWaiter() async {
        let gate = CameraFrameActivationGate()
        let waiter = Task {
            try await gate.waitUntilActive()
        }
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("A pre-cancelled activation waiter must not be installed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCameraFrameActivationGatePendingCancellationCompletes() async {
        let gate = CameraFrameActivationGate()
        let waiter = Task {
            try await gate.waitUntilActive()
        }
        await Task.yield()
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("A cancelled pending activation waiter must be removed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCameraGateCancellationRacingResolutionAlwaysCompletes() async {
        for _ in 0..<100 {
            let activationGate = CameraFrameActivationGate()
            let activationWaiter = Task {
                try await activationGate.waitUntilActive()
            }
            await Task.yield()
            activationWaiter.cancel()
            await activationGate.activate()
            _ = await activationWaiter.result

            let visibleGate = CameraVisibleFrameGate()
            let visibleWaiter = Task {
                try await visibleGate.wait()
            }
            await Task.yield()
            visibleWaiter.cancel()
            await visibleGate.succeed()
            _ = await visibleWaiter.result
        }
    }

    func testCameraVisibleFrameGateRejectsPreCancelledAndPendingCancelledWaiters() async {
        let preCancelledGate = CameraVisibleFrameGate()
        let preCancelledWaiter = Task {
            try await preCancelledGate.wait()
        }
        preCancelledWaiter.cancel()
        do {
            try await preCancelledWaiter.value
            XCTFail("A pre-cancelled visible-frame waiter must not be installed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let pendingGate = CameraVisibleFrameGate()
        let pendingWaiter = Task {
            try await pendingGate.wait()
        }
        await Task.yield()
        pendingWaiter.cancel()
        do {
            try await pendingWaiter.value
            XCTFail("A cancelled visible-frame waiter must be removed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellingCameraConnectStopsExactlyOnceAndClearsState() async {
        let manager = RemoteDesktopManager.instance
        await manager.disconnect(tearDownTransport: true)

        let stopProbe = CameraStopProbe()
        let (stream, continuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: { stream },
                connectAndPlay: {
                    try await Task.sleep(for: .seconds(60))
                },
                stop: {
                    await stopProbe.recordStop()
                    continuation.finish()
                }
            )
        }
        defer {
            manager.restoreProductionCameraClientFactoryForTesting()
        }

        let startTask = Task { @MainActor in
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/live")
        }
        for _ in 0..<100 where !manager.isReadOnlyCameraSession {
            await Task.yield()
        }
        XCTAssertTrue(manager.isReadOnlyCameraSession)

        startTask.cancel()
        do {
            try await startTask.value
            XCTFail("Cancelling during RTSP connect must cancel the start operation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let stopCount = await stopProbe.snapshot()
        XCTAssertEqual(stopCount, 1)
        assertCameraSessionIsCleared(manager)
    }

    func testCancellingVisibleFrameWaitStopsExactlyOnceAndClearsState() async {
        let manager = RemoteDesktopManager.instance
        await manager.disconnect(tearDownTransport: true)

        let stopProbe = CameraStopProbe()
        let (stream, continuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: { stream },
                connectAndPlay: {},
                stop: {
                    await stopProbe.recordStop()
                    continuation.finish()
                }
            )
        }
        defer {
            manager.restoreProductionCameraClientFactoryForTesting()
        }

        let startTask = Task { @MainActor in
            try await manager.startCameraStreaming(endpoint: "rtsps://192.168.1.20/live")
        }
        for _ in 0..<100 where !manager.isCameraAwaitingFirstPresentation {
            await Task.yield()
        }
        XCTAssertTrue(manager.isCameraAwaitingFirstPresentation)
        XCTAssertFalse(manager.isStreaming)
        XCTAssertNil(manager.currentConnection)

        startTask.cancel()
        do {
            try await startTask.value
            XCTFail("Cancelling the visible-frame wait must cancel the start operation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let stopCount = await stopProbe.snapshot()
        XCTAssertEqual(stopCount, 1)
        assertCameraSessionIsCleared(manager)
    }

    func testCameraConnectionTaskCoordinatorCancellationStopsExactlyOnce() async {
        let manager = RemoteDesktopManager.instance
        await manager.disconnect(tearDownTransport: true)

        let stopProbe = CameraStopProbe()
        let (stream, continuation) = AsyncThrowingStream<H264AccessUnit, any Error>.makeStream()
        manager.installCameraClientFactoryForTesting { _ in
            CameraRTSPClientOperations(
                frames: { stream },
                connectAndPlay: {},
                stop: {
                    await stopProbe.recordStop()
                    continuation.finish()
                }
            )
        }
        defer {
            manager.restoreProductionCameraClientFactoryForTesting()
        }

        let coordinator = CameraConnectionTaskCoordinator()
        XCTAssertTrue(
            coordinator.start {
                do {
                    try await manager.startCameraStreaming(
                        endpoint: "rtsps://192.168.1.20/live"
                    )
                } catch {
                    XCTAssertTrue(error is CancellationError)
                }
            }
        )
        XCTAssertFalse(
            coordinator.start {},
            "The connection sheet must reject a duplicate in-flight connect task"
        )
        for _ in 0..<100 where !manager.isCameraAwaitingFirstPresentation {
            await Task.yield()
        }
        XCTAssertTrue(manager.isCameraAwaitingFirstPresentation)
        XCTAssertFalse(manager.isStreaming)
        XCTAssertTrue(coordinator.isRunning)

        await coordinator.cancelAndWait()

        let stopCount = await stopProbe.snapshot()
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(coordinator.isRunning)
        assertCameraSessionIsCleared(manager)
    }

    func testCameraTimingAllowsLongGOPBeforeVisibleFrameDeadline() {
        XCTAssertEqual(CameraSessionTimingPolicy.transportFirstFrameTimeout, .seconds(15))
        XCTAssertEqual(CameraSessionTimingPolicy.transportInactivityTimeout, .seconds(12))
        XCTAssertEqual(CameraSessionTimingPolicy.visibleFrameTimeout, .seconds(20))
    }

    func testCameraVisibleGateIsOwnedByRendererPresentationCallbacks() throws {
        let managerSource = try remoteDesktopManagerSource()
        let applyStart = try XCTUnwrap(
            managerSource.range(of: "private func applyDecodedOutput")?.lowerBound
        )
        let applySuffix = managerSource[applyStart...]
        let applyEnd = try XCTUnwrap(
            applySuffix.range(of: "private func startDecodeLoopIfNeeded")?.lowerBound
        )
        let applyBody = String(applySuffix[..<applyEnd])
        XCTAssertFalse(applyBody.contains("promoteCameraSessionAfterFirstPresentedFrame"))

        let enqueueStart = try XCTUnwrap(
            managerSource.range(of: "func handleVideoRendererDidEnqueueFrame")?.lowerBound
        )
        let enqueueSuffix = managerSource[enqueueStart...]
        let enqueueEnd = try XCTUnwrap(
            enqueueSuffix.range(of: "func handleVideoRendererDidPresentFrame")?.lowerBound
        )
        let enqueueBody = String(enqueueSuffix[..<enqueueEnd])
        XCTAssertFalse(enqueueBody.contains("markDisplayedFrame"))
        XCTAssertFalse(enqueueBody.contains("noteDisplayedFrame"))
        XCTAssertTrue(
            managerSource.contains(
                "await promoteCameraSessionAfterFirstPresentedFrame(cameraPresentationContext)"
            )
        )

        let viewSource = try remoteDesktopViewSource()
        XCTAssertTrue(
            viewSource.contains("remoteDesktopManager.pendingCameraPresentationConnection"),
            "The camera's non-authoritative presentation target must mount the renderer before currentConnection exists"
        )
        XCTAssertTrue(
            viewSource.contains("remoteDesktopManager.isCameraAwaitingFirstPresentation"),
            "The camera renderer bootstrap phase must not depend on isStreaming becoming authoritative"
        )
        XCTAssertTrue(viewSource.contains("commandBuffer.addCompletedHandler"))
        XCTAssertTrue(
            viewSource.contains("cameraPresentationContext: frame.cameraPresentationContext")
        )
        XCTAssertTrue(
            viewSource.contains(".AVSampleBufferDisplayLayerReadyForDisplayDidChange")
        )
        XCTAssertTrue(viewSource.contains("layer.isReadyForDisplay"))
    }

    func testCameraFramesAreNeverEligibleForFrozenFrameCaching() {
        for isIndependentlyDecodableFrame in [false, true] {
            for renderFallbackForbidden in [false, true] {
                XCTAssertFalse(
                    RemoteDesktopFrozenFramePolicy.shouldCache(
                        isIndependentlyDecodableFrame: isIndependentlyDecodableFrame,
                        renderFallbackForbidden: renderFallbackForbidden,
                        isReadOnlyCameraSession: true
                    )
                )
            }
        }

        XCTAssertTrue(
            RemoteDesktopFrozenFramePolicy.shouldCache(
                isIndependentlyDecodableFrame: true,
                renderFallbackForbidden: false,
                isReadOnlyCameraSession: false
            ),
            "The optimization must remain available to an eligible desktop session"
        )
        XCTAssertFalse(
            RemoteDesktopFrozenFramePolicy.shouldCache(
                isIndependentlyDecodableFrame: false,
                renderFallbackForbidden: false,
                isReadOnlyCameraSession: false
            )
        )
    }

    func testCameraDecodedOutputSkipsFrozenFrameAllocationAndCache() throws {
        let source = try remoteDesktopManagerSource()
        let updateStart = try XCTUnwrap(source.range(of: "private func updateLastGoodFrozenFrame"))
        let updateSuffix = source[updateStart.lowerBound...]
        let updateEnd = try XCTUnwrap(updateSuffix.range(of: "private var maxLANWireMessageBytes"))
        let updateSource = String(updateSuffix[..<updateEnd.lowerBound])
        XCTAssertTrue(updateSource.contains("guard !isReadOnlyCameraSession, let image else { return }"))

        let applyStart = try XCTUnwrap(source.range(of: "private func applyDecodedOutput"))
        let applySuffix = source[applyStart.lowerBound...]
        let applyEnd = try XCTUnwrap(applySuffix.range(of: "private func startDecodeLoopIfNeeded"))
        let applySource = String(applySuffix[..<applyEnd.lowerBound])
        XCTAssertTrue(applySource.contains("let shouldCacheFrozenFrame = RemoteDesktopFrozenFramePolicy.shouldCache("))
        XCTAssertTrue(
            applySource.contains(
                "let frozenCandidate = shouldCacheFrozenFrame ? makeCGImage(from: presentationFrame) : nil"
            ),
            "Camera frames must be rejected before the MainActor CI-to-CGImage conversion"
        )
        XCTAssertGreaterThanOrEqual(
            applySource.components(separatedBy: "isReadOnlyCameraSession: isReadOnlyCameraSession").count - 1,
            2,
            "Both pixel-buffer and sample-buffer frozen-frame paths must use the camera exclusion"
        )
    }

    func testCameraPassiveRecoveryWaitsForNaturalIDRUntilBoundedDeadline() {
        let now = Date()
        let triggers: [(String, CameraPassiveRecoveryReason)] = [
            ("decode-sequence-gap", .sequenceDiscontinuity),
            ("decode-queue-overflow", .decodeQueuePressure),
            ("decode-stall-reset", .decodeStall),
            ("decode-completion-gap", .decodeCompletionGap)
        ]

        for (rawReason, expectedReason) in triggers {
            let state = CameraPassiveRecoveryPolicy.begin(
                current: nil,
                rawReason: rawReason,
                now: now
            )
            XCTAssertEqual(state.reason, expectedReason)
            XCTAssertEqual(state.startedAt, now)
            XCTAssertEqual(
                CameraPassiveRecoveryPolicy.deadlineDecision(
                    for: state,
                    now: now.addingTimeInterval(0.5)
                ),
                .awaitingNaturalIndependentFrame,
                "\(rawReason) must not terminate a camera at the desktop refresh threshold"
            )
            XCTAssertEqual(
                CameraPassiveRecoveryPolicy.deadlineDecision(
                    for: state,
                    now: now.addingTimeInterval(11.999)
                ),
                .awaitingNaturalIndependentFrame
            )
            XCTAssertEqual(
                CameraPassiveRecoveryPolicy.deadlineDecision(
                    for: state,
                    now: now.addingTimeInterval(12)
                ),
                .timedOut
            )
        }
    }

    func testRepeatedCameraPassiveRecoverySignalsCannotExtendDeadline() {
        let startedAt = Date()
        let initial = CameraPassiveRecoveryPolicy.begin(
            current: nil,
            rawReason: "decode-sequence-gap",
            now: startedAt
        )
        let repeated = CameraPassiveRecoveryPolicy.begin(
            current: initial,
            rawReason: "decode-queue-overflow",
            now: startedAt.addingTimeInterval(11)
        )

        XCTAssertEqual(repeated, initial)
        XCTAssertEqual(
            CameraPassiveRecoveryPolicy.deadlineDecision(
                for: repeated,
                now: startedAt.addingTimeInterval(12)
            ),
            .timedOut,
            "Repeated damaged frames must not keep extending passive recovery"
        )
    }

    func testCameraPassiveRecoveryClearsOnlyAfterAcceptedIndependentDecode() {
        let recovery = CameraPassiveRecoveryState(
            reason: .sequenceDiscontinuity,
            startedAt: Date()
        )
        XCTAssertEqual(
            CameraPassiveRecoveryPolicy.stateAfterDecodeProgress(
                current: recovery,
                isReadOnlyCameraSession: true,
                isIndependentlyDecodableFrame: true,
                decodeWasAccepted: false
            ),
            recovery,
            "A failed IDR decode must not clear the recovery deadline"
        )
        XCTAssertEqual(
            CameraPassiveRecoveryPolicy.stateAfterDecodeProgress(
                current: recovery,
                isReadOnlyCameraSession: true,
                isIndependentlyDecodableFrame: false,
                decodeWasAccepted: true
            ),
            recovery,
            "A predicted frame must not stand in for the natural recovery IDR"
        )
        XCTAssertEqual(
            CameraPassiveRecoveryPolicy.stateAfterDecodeProgress(
                current: recovery,
                isReadOnlyCameraSession: false,
                isIndependentlyDecodableFrame: true,
                decodeWasAccepted: true
            ),
            recovery
        )
        XCTAssertNil(
            CameraPassiveRecoveryPolicy.stateAfterDecodeProgress(
                current: recovery,
                isReadOnlyCameraSession: true,
                isIndependentlyDecodableFrame: true,
                decodeWasAccepted: true
            ),
            "An accepted camera IDR must remove the bounded recovery deadline"
        )
    }

    func testCameraPassiveRecoveryClearIsScopedToAcceptedDecodedOutput() throws {
        let source = try remoteDesktopManagerSource()
        let applyStart = try XCTUnwrap(source.range(of: "private func applyDecodedOutput"))
        let applySuffix = source[applyStart.lowerBound...]
        let applyEnd = try XCTUnwrap(applySuffix.range(of: "private func startDecodeLoopIfNeeded"))
        let applySource = String(applySuffix[..<applyEnd.lowerBound])
        XCTAssertTrue(
            applySource.contains(
                "clearCameraPassiveRecoveryAfterAcceptedDecode(\n            isIndependentlyDecodableFrame: frameTraits.isIndependentlyDecodableFrame"
            )
        )

        let decodedProgressStart = try XCTUnwrap(source.range(of: "private func noteDecodedFrame"))
        let decodedProgressSuffix = source[decodedProgressStart.lowerBound...]
        let decodedProgressEnd = try XCTUnwrap(
            decodedProgressSuffix.range(of: "private func noteVideoRendererEnqueuedFrame")
        )
        XCTAssertFalse(
            decodedProgressSuffix[..<decodedProgressEnd.lowerBound].contains("clearCameraPassiveRecovery")
        )

        let displayedProgressStart = try XCTUnwrap(source.range(of: "private func noteDisplayedFrames"))
        let displayedProgressSuffix = source[displayedProgressStart.lowerBound...]
        let displayedProgressEnd = try XCTUnwrap(
            displayedProgressSuffix.range(of: "private func logRemoteDesktopPipelineStatsIfNeeded")
        )
        XCTAssertFalse(
            displayedProgressSuffix[..<displayedProgressEnd.lowerBound].contains("clearCameraPassiveRecovery")
        )
    }

    func testCameraRefreshIntegrationUsesPassiveRecoveryWithoutDesktopConfigurationPush() throws {
        let source = try remoteDesktopManagerSource()
        let functionStart = try XCTUnwrap(
            source.range(of: "private func requestStreamRefreshIfNeeded")?.lowerBound
        )
        let functionSuffix = source[functionStart...]
        let cameraBranchEnd = try XCTUnwrap(
            functionSuffix.range(of: "guard !handleCrossNetworkSessionAuthorityLostIfNeeded")?.lowerBound
        )
        let cameraBranch = String(functionSuffix[..<cameraBranchEnd])

        XCTAssertTrue(cameraBranch.contains("beginCameraPassiveRecovery"))
        XCTAssertFalse(cameraBranch.contains("failCameraSession"))
        XCTAssertFalse(cameraBranch.contains("pushViewerStreamConfiguration"))
    }

    func testCameraWatchdogToleratesLowFrameRateAndShortDisplayStall() {
        let now = Date()
        XCTAssertEqual(
            CameraVisibleProgressWatchdogPolicy.evaluate(
                now: now,
                firstDisplayAwaitingSince: nil,
                lastFrameArrivalAt: now.addingTimeInterval(-10),
                lastDecodedFrameTime: now.addingTimeInterval(-10),
                lastDisplayedFrameTime: now.addingTimeInterval(-10)
            ),
            .healthy
        )
        XCTAssertEqual(
            CameraVisibleProgressWatchdogPolicy.evaluate(
                now: now,
                firstDisplayAwaitingSince: now.addingTimeInterval(-5),
                lastFrameArrivalAt: now.addingTimeInterval(-1),
                lastDecodedFrameTime: now.addingTimeInterval(-1),
                lastDisplayedFrameTime: nil
            ),
            .healthy
        )
    }

    func testCameraWatchdogFailsOnlyAfterBoundedDecodeOrDisplayStall() {
        let now = Date()
        XCTAssertEqual(
            CameraVisibleProgressWatchdogPolicy.evaluate(
                now: now,
                firstDisplayAwaitingSince: nil,
                lastFrameArrivalAt: now.addingTimeInterval(-1),
                lastDecodedFrameTime: now.addingTimeInterval(-13),
                lastDisplayedFrameTime: now.addingTimeInterval(-13)
            ),
            .decodeProgressTimedOut
        )
        XCTAssertEqual(
            CameraVisibleProgressWatchdogPolicy.evaluate(
                now: now,
                firstDisplayAwaitingSince: now.addingTimeInterval(-13),
                lastFrameArrivalAt: now.addingTimeInterval(-1),
                lastDecodedFrameTime: now.addingTimeInterval(-1),
                lastDisplayedFrameTime: nil
            ),
            .displayProgressTimedOut
        )
    }

    func testCameraDecodeIdentityDoesNotFeedPublishedResolutionBackIntoDecoder() throws {
        XCTAssertEqual(
            CameraDecodeIdentityPolicy.identity(for: .zero),
            CameraDecodeIdentity(width: 1, height: 1)
        )
        XCTAssertEqual(
            CameraDecodeIdentityPolicy.identity(for: CGSize(width: 7_680, height: 4_320)),
            CameraDecodeIdentity(width: 1, height: 1),
            "Published display dimensions must not mutate the camera decoder stream identity"
        )

        let source = try remoteDesktopManagerSource()
        guard let handlerStart = source.range(of: "let cameraDecodeIdentity ="),
              let handlerEnd = source.range(
                of: "cameraFrameTask = frameTask",
                range: handlerStart.upperBound..<source.endIndex
              ) else {
            XCTFail("Camera classification task is missing")
            return
        }
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        XCTAssertTrue(handler.contains("CameraDecodeIdentityPolicy.identity"))
        XCTAssertTrue(handler.contains("for: .zero"))
        XCTAssertFalse(handler.contains("Int(resolution.width"))
        XCTAssertFalse(handler.contains("Int(resolution.height"))
    }

    func testCameraFrameClassificationIsSerializedOffMainActorExactlyOnce() async throws {
        let worker = RemoteDesktopVideoFrameClassificationWorker()
        let advertisedSyncPredictiveFrame = ScreenData(
            width: 1,
            height: 1,
            imageData: Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x88]),
            timestamp: 1,
            format: "h264",
            isSyncFrame: true,
            sequenceNumber: 7
        )
        let classifiedFrame = try await worker.classify(advertisedSyncPredictiveFrame)
        XCTAssertEqual(classifiedFrame.screenData.sequenceNumber, 7)
        XCTAssertFalse(
            classifiedFrame.traits.isIndependentlyDecodableFrame,
            "Advertised metadata must not turn an actual predictive NAL into a recovery anchor"
        )

        let source = try remoteDesktopManagerSource()
        let taskStart = try XCTUnwrap(source.range(of: "let cameraDecodeIdentity =")?.lowerBound)
        let taskSuffix = source[taskStart...]
        let taskEnd = try XCTUnwrap(taskSuffix.range(of: "cameraFrameTask = frameTask")?.lowerBound)
        let taskBody = String(taskSuffix[..<taskEnd])
        XCTAssertTrue(taskBody.contains("Task.detached("))
        XCTAssertTrue(taskBody.contains("try await frameClassificationWorker.classify(screenData)"))
        XCTAssertTrue(taskBody.contains("await self?.handleCameraClassifiedFrame("))
        XCTAssertEqual(
            taskBody.components(separatedBy: "frameClassificationWorker.classify").count - 1,
            1,
            "Each camera frame must be structurally classified exactly once"
        )
        XCTAssertLessThan(
            try XCTUnwrap(taskBody.range(of: "frameClassificationWorker.classify")?.lowerBound),
            try XCTUnwrap(taskBody.range(of: "handleCameraClassifiedFrame")?.lowerBound)
        )
    }

    func testVideoFrameClassifierIsZeroPayloadCopyAndTraitsReachDecodeApply() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let classifierSource = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopScreenFrameWire.swift"
            )
        )
        let classifierStart = try XCTUnwrap(
            classifierSource.range(of: "static func classifyVideoFrame(")?.lowerBound
        )
        let classifierSuffix = classifierSource[classifierStart...]
        let classifierEnd = try XCTUnwrap(
            classifierSuffix.range(of: "private static func readUInt16")?.lowerBound
        )
        let classifierBody = String(classifierSuffix[..<classifierEnd])
        XCTAssertTrue(classifierSource.contains("actor RemoteDesktopVideoFrameClassificationWorker"))
        XCTAssertTrue(classifierBody.contains("imageData.withUnsafeBytes"))
        XCTAssertTrue(classifierBody.contains("UnsafeBufferPointer<UInt8>"))
        XCTAssertTrue(classifierBody.contains("maximumClassifiedAccessUnitBytes"))
        XCTAssertTrue(classifierBody.contains("maximumClassifiedNALUnits"))
        XCTAssertFalse(classifierBody.contains("subdata("))
        XCTAssertFalse(classifierBody.contains("[Data]"))

        let managerSource = try remoteDesktopManagerSource()
        XCTAssertTrue(managerSource.contains("classifiedFrame.traits.isDecoderBootstrapFrame"))
        XCTAssertTrue(managerSource.contains("classifiedFrame.traits.isIndependentlyDecodableFrame"))
        XCTAssertTrue(managerSource.contains("frameTraits: classifiedFrame.traits"))
        XCTAssertTrue(managerSource.contains("frameTraits: completion.frameTraits"))
        XCTAssertFalse(managerSource.contains("screenData.isDecoderBootstrapFrame"))
        XCTAssertFalse(managerSource.contains("sourceFrame.isIndependentlyDecodableFrame"))
    }

    func testTerminalCameraFailurePresentationRequiresAVisibleFrameAndTypedFailure() {
        let preVisibleFailure = CameraTerminalFailurePresentationPolicy.resolve(
                hadVisibleFrame: false,
                intendedState: .error("The camera transport failed."),
                terminalFailure: .transportFailed,
                cleanupFailure: nil
        )
        XCTAssertEqual(preVisibleFailure.state, .error("The camera transport failed."))
        XCTAssertNil(
            preVisibleFailure.message,
            "Connection-sheet failures must not also trigger the terminal-session alert"
        )

        let intentionalStop = CameraTerminalFailurePresentationPolicy.resolve(
                hadVisibleFrame: true,
                intendedState: .disconnected,
                terminalFailure: .stopped,
                cleanupFailure: nil
        )
        XCTAssertEqual(intentionalStop.state, .disconnected)
        XCTAssertNil(intentionalStop.message, "An intentional stop must not be presented as a failure")

        let terminalFailure = CameraTerminalFailurePresentationPolicy.resolve(
            hadVisibleFrame: true,
            intendedState: .error(
                CameraRemoteDesktopRuntimeError.displayProgressTimedOut.localizedDescription
            ),
            terminalFailure: .displayProgressTimedOut,
            cleanupFailure: nil
        )
        XCTAssertEqual(
            terminalFailure.state,
            .error(CameraRemoteDesktopRuntimeError.displayProgressTimedOut.localizedDescription)
        )
        XCTAssertEqual(
            terminalFailure.message,
            CameraRemoteDesktopRuntimeError.displayProgressTimedOut.localizedDescription
        )
        XCTAssertFalse(terminalFailure.message?.contains("rtsp://") == true)
        XCTAssertFalse(terminalFailure.message?.contains("credential") == true)

        let cleanupFailure = CameraTerminalFailurePresentationPolicy.resolve(
            hadVisibleFrame: true,
            intendedState: .disconnected,
            terminalFailure: nil,
            cleanupFailure: .transportFailed
        )
        XCTAssertEqual(
            cleanupFailure.state,
            .error(CameraRemoteDesktopRuntimeError.transportFailed.localizedDescription)
        )
        XCTAssertEqual(
            cleanupFailure.message,
            CameraRemoteDesktopRuntimeError.transportFailed.localizedDescription
        )
    }

    private func remoteDesktopManagerSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("SkyBridgeCompassiOS")
            .appendingPathComponent("Sources")
            .appendingPathComponent("Managers")
            .appendingPathComponent("RemoteDesktopManager.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func remoteDesktopViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("SkyBridgeCompassiOS")
            .appendingPathComponent("Sources")
            .appendingPathComponent("Views")
            .appendingPathComponent("RemoteDesktopView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func canSubmitCameraEndpoint(
        _ endpoint: String,
        username: String = "",
        password: String = "",
        acknowledgesPlaintextRTSP: Bool = false,
        isConnecting: Bool = false
    ) -> Bool {
        CameraConnectionFormPolicy.canConnect(
            endpoint: endpoint,
            username: username,
            password: password,
            acknowledgesPlaintextRTSP: acknowledgesPlaintextRTSP,
            isConnecting: isConnecting
        )
    }

    private func makeCameraPixelBufferFrame() throws -> DecodedPixelBufferFrame {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                16,
                16,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        return DecodedPixelBufferFrame(
            pixelBuffer: try XCTUnwrap(pixelBuffer),
            width: 16,
            height: 16,
            presentationTimeStamp: CMTime(value: 1, timescale: 60)
        )
    }

    private func assertCameraSessionIsCleared(
        _ manager: RemoteDesktopManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(manager.isReadOnlyCameraSession, file: file, line: line)
        XCTAssertFalse(manager.isStreaming, file: file, line: line)
        XCTAssertNil(manager.currentConnection, file: file, line: line)
        XCTAssertNil(manager.pendingCameraPresentationConnection, file: file, line: line)
        XCTAssertFalse(manager.isCameraAwaitingFirstPresentation, file: file, line: line)
        XCTAssertNil(manager.terminalCameraErrorMessage, file: file, line: line)
        XCTAssertNil(manager.cameraPassiveRecoveryReason, file: file, line: line)
        XCTAssertNil(manager.cameraPassiveRecoveryStartedAt, file: file, line: line)
        XCTAssertEqual(manager.state, .disconnected, file: file, line: line)
    }
}
