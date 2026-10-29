import XCTest
@preconcurrency import Metal
@testable import SkyBridgeCore

private actor CameraLateSubmissionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private final class CameraBackingLifetimeProbe: @unchecked Sendable {}

private final class CameraWeakBackingBox: @unchecked Sendable {
    weak var value: CameraBackingLifetimeProbe?

    init(_ value: CameraBackingLifetimeProbe) {
        self.value = value
    }
}

final class CameraRemoteDesktopPolicyTests: XCTestCase {
    func testCameraSessionKindDisablesRemoteInput() {
        XCTAssertFalse(RemoteSessionKind.readOnlyCamera.supportsRemoteInput)
        XCTAssertTrue(RemoteSessionKind.interactiveDesktop.supportsRemoteInput)
    }

    func testVisibleFrameWatchdogDistinguishesStartupAndStall() {
        let startedAt = ContinuousClock.now
        XCTAssertNil(CameraVisibleFrameWatchdogPolicy.violation(
            startedAt: startedAt,
            lastVisibleFrameAt: nil,
            now: startedAt.advanced(by: .seconds(19))
        ))
        XCTAssertEqual(CameraVisibleFrameWatchdogPolicy.violation(
            startedAt: startedAt,
            lastVisibleFrameAt: nil,
            now: startedAt.advanced(by: .seconds(20))
        ), .firstFrame)

        let visibleAt = startedAt.advanced(by: .seconds(5))
        XCTAssertNil(CameraVisibleFrameWatchdogPolicy.violation(
            startedAt: startedAt,
            lastVisibleFrameAt: visibleAt,
            now: visibleAt.advanced(by: .seconds(11))
        ))
        XCTAssertEqual(CameraVisibleFrameWatchdogPolicy.violation(
            startedAt: startedAt,
            lastVisibleFrameAt: visibleAt,
            now: visibleAt.advanced(by: .seconds(12))
        ), .stalled)
    }

    func testDecodedFrameDoesNotAdvanceVisiblePresentationState() {
        let state = CameraFramePresentationState()

        XCTAssertTrue(state.acceptsDecodedFrame())
        XCTAssertNil(state.latestPresentedFrameAt())
        XCTAssertEqual(state.acceptPresentedFrame(), true)
        XCTAssertNotNil(state.latestPresentedFrameAt())
        XCTAssertEqual(state.acceptPresentedFrame(), false)
    }

    @MainActor
    func testTextureFeedOnlyReportsCurrentMonotonicPresentedFrames() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let feed = RemoteTextureFeed()
        var presentationCount = 0
        feed.setPresentationCompletionHandler {
            presentationCount += 1
        }

        feed.update(texture: texture)
        let firstFrame = try XCTUnwrap(feed.frame)
        XCTAssertEqual(presentationCount, 0, "Texture publication is not presentation")

        feed.reportPresentedFrame(firstFrame)
        XCTAssertEqual(presentationCount, 1)
        feed.reportPresentedFrame(firstFrame)
        XCTAssertEqual(presentationCount, 1, "A drawable callback must be accepted once")

        feed.update(texture: texture)
        let secondFrame = try XCTUnwrap(feed.frame)
        feed.reportPresentedFrame(firstFrame)
        XCTAssertEqual(presentationCount, 1, "Older completions must not move presentation backwards")
        feed.reportPresentedFrame(secondFrame)
        XCTAssertEqual(presentationCount, 2)

        feed.update(texture: nil)
        feed.reportPresentedFrame(secondFrame)
        XCTAssertEqual(presentationCount, 2, "Clearing the feed must invalidate in-flight callbacks")
    }

    @MainActor
    func testInvalidatedTextureGateRejectsLateConcurrentSubmitAndReleasesBacking() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let feed = RemoteTextureFeed()
        let deliveryGate = LatestTextureDeliveryGate(feed: feed)
        let callbackReachedSubmissionBoundary = CameraLateSubmissionGate()
        let allowLateSubmission = CameraLateSubmissionGate()
        var backing: CameraBackingLifetimeProbe? = CameraBackingLifetimeProbe()
        let weakBacking = CameraWeakBackingBox(try XCTUnwrap(backing))

        var lateSubmissionTask: Task<Void, Never>? = Task.detached {
            [deliveryGate, texture, backing] in
            await callbackReachedSubmissionBoundary.open()
            await allowLateSubmission.wait()
            deliveryGate.submit(texture: texture, backing: backing)
        }

        await callbackReachedSubmissionBoundary.wait()
        deliveryGate.invalidate()
        backing = nil
        await allowLateSubmission.open()
        if let lateSubmissionTask {
            await lateSubmissionTask.value
        }
        lateSubmissionTask = nil

        for _ in 0..<100 where weakBacking.value != nil {
            await Task.yield()
        }

        XCTAssertNil(feed.frame, "A post-invalidation decoder callback must not republish a frame")
        XCTAssertNil(
            weakBacking.value,
            "Rejected post-invalidation work must not leave the decoder backing retained"
        )
    }

    @MainActor
    func testReusableTextureGateClearCannotEraseNewerCoalescedFrame() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        let previouslyPresentedTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let supersededTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let newestTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let feed = RemoteTextureFeed()
        let deliveryGate = LatestTextureDeliveryGate(feed: feed)
        var presentationCount = 0
        feed.setPresentationCompletionHandler {
            presentationCount += 1
        }
        feed.update(texture: previouslyPresentedTexture)
        let previousFrame = try XCTUnwrap(feed.frame)

        // The first submit owns the single scheduled drain. `clear` must remain
        // an epoch barrier, but its asynchronous nil must not run after the
        // subsequent frame that replaces this pending frame.
        deliveryGate.submit(texture: supersededTexture)
        deliveryGate.clear()
        deliveryGate.submit(texture: newestTexture)

        for _ in 0..<100 where feed.frame?.texture !== newestTexture {
            await Task.yield()
        }
        XCTAssertTrue(feed.frame?.texture === newestTexture)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertTrue(
            feed.frame?.texture === newestTexture,
            "A delayed clear must not erase a frame submitted after its barrier"
        )

        feed.reportPresentedFrame(previousFrame)
        XCTAssertEqual(
            presentationCount,
            0,
            "A coalesced clear must still invalidate presentation callbacks from the prior stream"
        )
    }

    @MainActor
    func testManagerRejectsPublicCameraEndpointBeforeNetworkIO() async {
        do {
            try await RemoteDesktopManager.shared.connectCamera(
                endpoint: "rtsp://203.0.113.10/live",
                acknowledgesPlaintextRTSP: true
            )
            XCTFail("A public camera endpoint must be rejected")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("private IP literal"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    func testManagerRequiresExplicitPlaintextAcknowledgement() async {
        do {
            try await RemoteDesktopManager.shared.connectCamera(
                endpoint: "rtsp://192.168.1.20/live"
            )
            XCTFail("Plain RTSP must require an explicit acknowledgement")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("explicit user acknowledgement"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    func testManagerRequiresCredentialPairBeforeNetworkIO() async {
        do {
            try await RemoteDesktopManager.shared.connectCamera(
                endpoint: "rtsps://192.168.1.20/live",
                username: "operator"
            )
            XCTFail("A partial credential pair must be rejected")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("supplied together"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testMacCameraConnectionSheetOwnsAndCancelsItsConnectionTask() throws {
        let source = try repositorySource("Sources/SkyBridgeCompassApp/RemoteDesktopView.swift")
        guard let sheetStart = source.range(of: "struct NewConnectionSheet: View"),
              let sheetEnd = source.range(
                of: "// MARK: - 远程桌面设置视图",
                range: sheetStart.upperBound..<source.endIndex
              ) else {
            XCTFail("NewConnectionSheet source boundary is missing")
            return
        }
        let sheet = String(source[sheetStart.lowerBound..<sheetEnd.lowerBound])

        XCTAssertTrue(sheet.contains("@State private var cameraConnectionTask: Task<Void, Never>?"))
        XCTAssertTrue(sheet.contains("guard cameraConnectionTask == nil else { return }"))
        XCTAssertTrue(sheet.contains("cameraConnectionTask?.cancel()"))
        XCTAssertTrue(sheet.contains("cameraConnectionTask.cancel()"))
        XCTAssertTrue(sheet.contains("try Task.checkCancellation()"))
        XCTAssertTrue(sheet.contains("terminate(sessionID: connectedSessionID)"))
        XCTAssertTrue(sheet.contains(".interactiveDismissDisabled(cameraConnectionTask != nil)"))
    }

    func testCameraConnectionRequiresActualMetalDrawablePresentation() throws {
        let cameraSource = try repositorySource(
            "Sources/SkyBridgeCore/RemoteDesktop/CameraRemoteDesktopSession.swift"
        )
        let displaySource = try repositorySource(
            "Sources/SkyBridgeCompassApp/RemoteDisplayView.swift"
        )
        let callbackStart = try XCTUnwrap(
            cameraSource.range(of: "private func configureRendererCallbacks()")
        )
        let callbackEnd = try XCTUnwrap(
            cameraSource.range(
                of: "private func recordPresentedFrame",
                range: callbackStart.upperBound..<cameraSource.endIndex
            )
        )
        let decoderPublication = String(
            cameraSource[callbackStart.lowerBound..<callbackEnd.lowerBound]
        )

        XCTAssertFalse(decoderPublication.contains("markFirstVisibleFrame"))
        XCTAssertTrue(cameraSource.contains("textureFeed.setPresentationCompletionHandler"))
        XCTAssertTrue(cameraSource.contains("presentationState.acceptPresentedFrame()"))
        XCTAssertTrue(displaySource.contains("drawable.addPresentedHandler"))
        XCTAssertTrue(displaySource.contains("reportPresentedFrame(frame)"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
