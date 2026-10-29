import Foundation
import OSLog
import SkyBridgeCameraKit

private actor CameraH264FrameProcessor {
    private let renderer: RemoteFrameRenderer
    private var isActive = true

    init(renderer: RemoteFrameRenderer) {
        self.renderer = renderer
    }

    func process(_ data: Data) throws -> RemoteH264FrameSubmissionResult {
        guard isActive else { throw CancellationError() }
        try Task.checkCancellation()
        return try renderer.processH264AnnexBAccessUnit(data: data)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        renderer.teardown()
    }
}

final class CameraFramePresentationState: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    private var didPresentFirstFrame = false
    private var didReportFailure = false
    private var lastPresentedFrameAt: ContinuousClock.Instant?

    /// Decoder output is only a presentation candidate. It must not update the
    /// visible-frame watchdog or connected state.
    func acceptsDecodedFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive && !didReportFailure
    }

    /// Returns `nil` after invalidation/failure, otherwise whether Metal just
    /// presented the first visible frame for this session.
    func acceptPresentedFrame() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive, !didReportFailure else { return nil }
        let isFirst = !didPresentFirstFrame
        didPresentFirstFrame = true
        lastPresentedFrameAt = ContinuousClock.now
        return isFirst
    }

    func beginFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isActive, !didReportFailure else { return false }
        didReportFailure = true
        return true
    }

    func invalidate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    func latestPresentedFrameAt() -> ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return lastPresentedFrameAt
    }
}

enum CameraVisibleFrameWatchdogViolation: Equatable {
    case firstFrame
    case stalled
}

struct CameraVisibleFrameWatchdogPolicy {
    static let firstFrameTimeout: Duration = .seconds(20)
    static let stallTimeout: Duration = .seconds(12)

    static func violation(
        startedAt: ContinuousClock.Instant,
        lastVisibleFrameAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant
    ) -> CameraVisibleFrameWatchdogViolation? {
        if let lastVisibleFrameAt {
            return lastVisibleFrameAt.duration(to: now) >= stallTimeout ? .stalled : nil
        }
        return startedAt.duration(to: now) >= firstFrameTimeout ? .firstFrame : nil
    }
}

/// A single, read-only local-camera session. Protocol I/O, RTP reconstruction and H.264 decode
/// remain outside MainActor; only bounded summary/texture publication crosses into the UI actor.
@MainActor
final class CameraRemoteDesktopSession {
    let id = UUID()
    let textureFeed: RemoteTextureFeed

    private let client: RTSPInterleavedClient
    private let renderer: RemoteFrameRenderer
    private let frameProcessor: CameraH264FrameProcessor
    private let deliveryGate: LatestTextureDeliveryGate
    private let presentationState = CameraFramePresentationState()
    private let summaryChanged: @MainActor () -> Void
    private let stateChanged: @MainActor () -> Void
    private let terminalFailure: @MainActor (UUID) -> Void
    private let log = Logger(subsystem: "com.skybridge.compass", category: "CameraSession")

    private var streamTask: Task<Void, Never>?
    private var visibleFrameWatchdogTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isStopPrepared = false
    private var didStopResources = false
    private var hasPresentedVisibleFrame = false
    private var didSendTerminalNotification = false

    private(set) var summary: RemoteSessionSummary

    init(
        displayName: String,
        protocolDescription: String,
        client: RTSPInterleavedClient,
        renderer: RemoteFrameRenderer,
        feed: RemoteTextureFeed,
        summaryChanged: @escaping @MainActor () -> Void,
        stateChanged: @escaping @MainActor () -> Void,
        terminalFailure: @escaping @MainActor (UUID) -> Void
    ) {
        self.client = client
        self.renderer = renderer
        self.frameProcessor = CameraH264FrameProcessor(renderer: renderer)
        self.textureFeed = feed
        self.deliveryGate = LatestTextureDeliveryGate(feed: feed)
        self.summaryChanged = summaryChanged
        self.stateChanged = stateChanged
        self.terminalFailure = terminalFailure
        self.summary = RemoteSessionSummary(
            id: id,
            targetName: displayName,
            protocolDescription: protocolDescription,
            kind: .readOnlyCamera,
            bandwidthMbps: 0,
            frameLatencyMilliseconds: 0,
            status: .connecting
        )

        configureRendererCallbacks()
    }

    func start() async throws {
        guard !isStopPrepared, streamTask == nil else {
            throw SkyBridgeCameraError.invalidState("the camera session cannot be started twice")
        }
        generation &+= 1
        let operationGeneration = generation
        let stream = await client.frames()

        try await client.connectAndPlay()
        try Task.checkCancellation()
        guard operationGeneration == generation, !isStopPrepared else {
            throw CancellationError()
        }

        textureFeed.setPresentationCompletionHandler { [weak self] in
            self?.recordPresentedFrame(generation: operationGeneration)
        }

        let processor = frameProcessor
        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            var nextMetricsPublication = ContinuousClock.now
            do {
                for try await accessUnit in stream {
                    try Task.checkCancellation()
                    let result = try await processor.process(accessUnit.data)
                    guard case let .submitted(metrics) = result else { continue }

                    let now = ContinuousClock.now
                    if now >= nextMetricsPublication {
                        nextMetricsPublication = now.advanced(by: .seconds(1))
                        await self?.publishMetrics(
                            metrics,
                            generation: operationGeneration
                        )
                    }
                }
                try Task.checkCancellation()
                await self?.handleStreamFailure(
                    SkyBridgeCameraError.streamEnded,
                    generation: operationGeneration
                )
            } catch is CancellationError {
                // Cancellation is the explicit local shutdown path; no failure state is emitted.
            } catch {
                await self?.handleStreamFailure(error, generation: operationGeneration)
            }
        }
        startVisibleFrameWatchdog(generation: operationGeneration)
    }

    /// Invalidates callbacks and UI publication synchronously before asynchronous socket teardown.
    func prepareForStop(status: SessionStatus) {
        if !isStopPrepared {
            if hasPresentedVisibleFrame, status == .disconnected {
                sendTerminalNotificationIfNeeded(
                    kind: .normal,
                    reason: "camera_terminate"
                )
            }
            isStopPrepared = true
            generation &+= 1
            streamTask?.cancel()
            streamTask = nil
            visibleFrameWatchdogTask?.cancel()
            visibleFrameWatchdogTask = nil
            presentationState.invalidate()
            renderer.frameHandler = nil
            renderer.failureHandler = nil
            textureFeed.setPresentationCompletionHandler(nil)
            deliveryGate.invalidate()
        }
        updateStatus(status)
    }

    /// Always tears down local decoder resources, even when the remote TEARDOWN exchange fails.
    func stop() async throws {
        prepareForStop(status: summary.status == .failed ? .failed : .disconnected)
        guard !didStopResources else { return }
        didStopResources = true

        var protocolError: (any Error)?
        do {
            try await client.stop()
        } catch {
            protocolError = error
        }
        await frameProcessor.stop()
        if let protocolError { throw protocolError }
    }

    private func configureRendererCallbacks() {
        let presentationState = presentationState
        let deliveryGate = deliveryGate
        renderer.frameHandler = { texture, backing in
            guard presentationState.acceptsDecodedFrame() else { return }
            deliveryGate.submit(texture: texture, backing: backing)
        }
        renderer.failureHandler = { [weak self] error in
            guard presentationState.beginFailure() else { return }
            Task { @MainActor [weak self] in
                self?.handleStreamFailure(error, generation: self?.generation ?? 0)
            }
        }
    }

    private func recordPresentedFrame(generation: UInt64) {
        guard generation == self.generation,
              !isStopPrepared,
              summary.status == .connecting || summary.status == .connected,
              let isFirstFrame = presentationState.acceptPresentedFrame() else {
            return
        }
        guard isFirstFrame else { return }
        markFirstVisibleFrame(generation: generation)
    }

    private func markFirstVisibleFrame(generation: UInt64) {
        guard generation == self.generation,
              !isStopPrepared,
              summary.status == .connecting else { return }
        hasPresentedVisibleFrame = true
        RemoteDesktopSessionNotificationService.shared.beginSession(
            sessionID: id.uuidString,
            transport: "rtsp-camera"
        )
        updateStatus(.connected)
    }

    private func startVisibleFrameWatchdog(generation: UInt64) {
        visibleFrameWatchdogTask?.cancel()
        let startedAt = ContinuousClock.now
        let presentationState = presentationState
        visibleFrameWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError {
                    return
                } catch {
                    self?.handleStreamFailure(error, generation: generation)
                    return
                }
                guard let self,
                      generation == self.generation,
                      !self.isStopPrepared else { return }
                guard CameraVisibleFrameWatchdogPolicy.violation(
                    startedAt: startedAt,
                    lastVisibleFrameAt: presentationState.latestPresentedFrameAt(),
                    now: ContinuousClock.now
                ) != nil else { continue }
                self.handleStreamFailure(
                    SkyBridgeCameraError.timedOut("waiting for a presented camera frame"),
                    generation: generation
                )
                return
            }
        }
    }

    private func publishMetrics(_ metrics: RenderMetrics, generation: UInt64) {
        guard generation == self.generation,
              !isStopPrepared,
              summary.status != .failed,
              summary.status != .disconnected else { return }
        summary = RemoteSessionSummary(
            id: summary.id,
            targetName: summary.targetName,
            protocolDescription: summary.protocolDescription,
            kind: .readOnlyCamera,
            bandwidthMbps: metrics.bandwidthMbps,
            frameLatencyMilliseconds: metrics.latencyMilliseconds,
            status: summary.status
        )
        summaryChanged()
    }

    private func handleStreamFailure(_ error: any Error, generation: UInt64) {
        guard generation == self.generation, !isStopPrepared else { return }
        log.error("Camera stream failed in a sanitized protocol or decode boundary")
        if hasPresentedVisibleFrame {
            sendTerminalNotificationIfNeeded(
                kind: .interrupted,
                reason: Self.sanitizedFailureReason(error)
            )
        }
        updateStatus(.failed)
        terminalFailure(id)
    }

    private func sendTerminalNotificationIfNeeded(
        kind: RemoteDesktopSessionTerminationKind,
        reason: String
    ) {
        guard !didSendTerminalNotification else { return }
        didSendTerminalNotification = true
        RemoteDesktopSessionNotificationService.shared.sendTerminalNotificationIfNeeded(
            sessionID: id.uuidString,
            deviceName: summary.targetName,
            transport: "rtsp-camera",
            kind: kind,
            reason: reason
        )
    }

    private static func sanitizedFailureReason(_ error: any Error) -> String {
        if let error = error as? SkyBridgeCameraError {
            return error.localizedDescription
        }
        if let error = error as? RemoteFrameRenderError {
            return error.localizedDescription
        }
        return "camera_stream_failed"
    }

    private func updateStatus(_ status: SessionStatus) {
        guard summary.status != status else { return }
        summary = RemoteSessionSummary(
            id: summary.id,
            targetName: summary.targetName,
            protocolDescription: summary.protocolDescription,
            kind: .readOnlyCamera,
            bandwidthMbps: summary.bandwidthMbps,
            frameLatencyMilliseconds: summary.frameLatencyMilliseconds,
            status: status
        )
        summaryChanged()
        stateChanged()
    }
}
