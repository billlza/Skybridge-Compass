import XCTest

final class RemoteControlAudioSchedulingTests: XCTestCase {
    private func remoteControlManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pumpSourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlOutboundFramePump.swift")
        let managerSourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        return try [
            String(contentsOf: pumpSourceURL, encoding: .utf8),
            String(contentsOf: managerSourceURL, encoding: .utf8)
        ].joined(separator: "\n")
    }

    private func screenCaptureKitStreamerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePaths = [
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer+CaptureTypes.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer+VideoPolicy.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer+JPEGEncoding.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureTelemetrySnapshot.swift"
        ]
        return try sourcePaths.map { path in
            try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
        }.joined(separator: "\n")
    }

    private func realDeviceP2PRemoteSmokeScriptSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Scripts/run_real_device_p2p_remote_smoke.sh")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func testP2PAudioDrainIsDecoupledFromVideoFramePump() throws {
        let source = try remoteControlManagerSource()
        let pumpBody = try sourceSlice(
            from: "actor RemoteControlOutboundFramePump",
            to: "private final class PeerConnection",
            in: source
        )

        XCTAssertTrue(
            source.contains("scheduleAudioDrainIfNeeded()"),
            "Remote audio payloads should be drained by their own bounded background path."
        )
        XCTAssertFalse(
            source.contains("await drainQueuedAudioPayloads(limit: 1)"),
            "Video frame sends must not synchronously wait for one audio packet after every frame."
        )
        XCTAssertTrue(
            source.contains("private var sendingAudio = false"),
            "Audio drain should be independently guarded so it cannot spawn unbounded sends."
        )
        XCTAssertTrue(
            source.contains("audioDrainGeneration &+="),
            "Stopping or restarting remote control must fence old audio drain tasks."
        )
        XCTAssertTrue(
            source.contains("audioDrainTask?.cancel()"),
            "Stopping or restarting remote control should cancel in-flight audio drain work."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let maxAudioPayloadsPerDrain = 4"),
            "P2P audio must interleave small bounded send batches without dropping live audio behind video."
        )
        XCTAssertTrue(
            pumpBody.contains("scheduler=independent-interleaved"),
            "Audio tx telemetry must prove the shared LAN connection no longer gates audio behind video cadence."
        )
        XCTAssertTrue(
            pumpBody.contains("mac-remote-audio-tx"),
            "Real-device smoke logs must show audio submitted/sent/failed/queued evidence instead of inferring zero-rx from jitter."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let maxAudioQueuedPayloads = 240") &&
            pumpBody.contains("private static let maxAudioQueuedBytes = 2 * 1024 * 1024") &&
            pumpBody.contains("result=failed-closed reason=audio-queue-hard-limit"),
            "Audio queue backpressure must have a hard fail-closed bound instead of growing indefinitely."
        )
        XCTAssertFalse(
            pumpBody.contains("canSendAudioWithoutCompetingWithVideo"),
            "Audio must not be silently suppressed when video has in-flight frames, pending frames, or a waiting-for-sync state."
        )
        XCTAssertFalse(
            pumpBody.contains("reason: \"video-priority\"") ||
            pumpBody.contains("reason: \"video-backlog\"") ||
            pumpBody.contains("reason: \"queue-overflow\"") ||
            pumpBody.contains("audioPayloadQueue.removeFirst(overflow)"),
            "Audio continuity must not be manufactured by dropping packets whenever video cadence collapses or the old tiny queue overflows."
        )
        XCTAssertTrue(
            source.contains("Task.detached(priority: .userInitiated) {\n                    await outboundFramePump.submitAudioPayload(wirePayload)\n                }"),
            "Captured audio chunks should reach the outbound pump promptly instead of being starved behind 2K60 video work."
        )
        XCTAssertFalse(
            source.contains("Task.detached(priority: .utility) {\n                    await outboundFramePump.submitAudioPayload(wirePayload)\n                }"),
            "Legacy shared-channel audio should not be scheduled at utility priority during strict 2K60 sessions."
        )
    }

    func testRemoteFrameBackpressureTelemetryIgnoresSingleInFlightSendOverlap() throws {
        let source = try remoteControlManagerSource()

        XCTAssertTrue(
            source.contains("private static let harmfulBackpressurePendingFrameThreshold = 6"),
            "Backpressure telemetry should allow a bounded 60fps queue near the 100ms smoke latency cap."
        )
        XCTAssertTrue(
            source.contains("pendingFramesBeforeEnqueue >= Self.harmfulBackpressurePendingFrameThreshold"),
            "Backpressure telemetry should describe actual queued backlog or sync starvation, not a normal one-frame send overlap."
        )
        XCTAssertTrue(
            source.contains("let rawBackpressured = pendingFramesBeforeEnqueue > 0 || frameQueue.waitingForSyncFrame || contentBacklogFull"),
            "Raw backpressure should stay visible for diagnosis even when the harmful gate ignores normal writer/contentProcessed overlap."
        )
        XCTAssertTrue(
            source.contains("rawBackpressure=\\(snapshot.rawBackpressureEvents)"),
            "Smoke logs should keep raw backpressure separate from harmful backpressure."
        )
        XCTAssertTrue(
            source.contains("orderedThrottle=\\(snapshot.orderedThrottleEvents)"),
            "Smoke logs should expose intentional ordered throttling separately from harmful backpressure."
        )
        XCTAssertTrue(
            source.contains("queueBacklog=\\(snapshot.queueBacklogEvents)"),
            "Smoke logs should expose real queue backlog separately from ordered throttling."
        )
        XCTAssertFalse(
            source.contains("let wasBackpressured = sending || !frameQueue.pendingFrames.isEmpty || frameQueue.waitingForSyncFrame"),
            "Counting every in-flight send as backpressure creates a sustained false positive at 60 fps."
        )
        XCTAssertFalse(
            source.contains("let wasBackpressured = !frameQueue.pendingFrames.isEmpty || frameQueue.waitingForSyncFrame"),
            "A single pending frame is normal pipeline overlap, not harmful backpressure."
        )
    }

    func testP2PVideoFramePumpUsesBoundedCadenceAndDoesNotCatchUpFromCompletions() throws {
        let source = try remoteControlManagerSource()
        let pumpBody = try sourceSlice(
            from: "actor RemoteControlOutboundFramePump",
            to: "private final class PeerConnection",
            in: source
        )
        let completionBody = try sourceSlice(
            from: "private func completeVideoFrameSend(",
            to: "private func scheduleVideoPaceWakeIfNeeded()",
            in: pumpBody
        )
        let paceWakeBody = try sourceSlice(
            from: "private func scheduleVideoPaceWakeIfNeeded()",
            to: "private func videoPaceWakeDelay(from now: Date) -> TimeInterval",
            in: pumpBody
        )

        XCTAssertTrue(
            pumpBody.contains("private var videoSendInterval: TimeInterval = 1.0 / 60.0"),
            "The sender should record the 60 fps remote-desktop cadence in telemetry for diagnosing real-device misses."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let maxInFlightVideoSends = 3"),
            "P2P video must bound TCP/NWConnection flight depth so 60 fps HEVC does not accumulate hundreds of milliseconds of queued video."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let maxChunkedContentProcessedBacklogFrames = 18"),
            "SBC2 chunked video must absorb measured Network.framework contentProcessed callback tails while iOS frame-age telemetry remains the viewer latency gate."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let maxChunkedContentProcessedBacklogBytes = 12 * 256 * 1024"),
            "SBC2 chunked video must bound contentProcessed backlog by bytes without treating short Network.framework callback stalls as viewer latency."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let maxChunkedVideoFramesPerDrain = 1"),
            "Lower-rate SBC2 video must schedule at most one frame per writer-clock tick so aggregate FPS cannot be manufactured by catch-up bursts."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let maxChunkedHighFPSVideoFramesPerDrain = 1"),
            "Strict 2K60 SBC2 must not manufacture aggregate FPS with multi-frame catch-up bursts that can overload the iOS parser."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let boundedCadenceCatchUpFrameAgeLimitMs: Double = 50"),
            "Bounded catch-up must be age-limited so it cannot replay stale HEVC frames to manufacture aggregate FPS."
        )
        XCTAssertTrue(
            source.contains("final class RemoteControlVideoPaceClock"),
            "The strict remote sender should use a dedicated writer clock instead of parking actor work on Task.sleep."
        )
        XCTAssertTrue(
            source.contains("DispatchSource.makeTimerSource(flags: .strict, queue: queue)"),
            "The strict remote sender wake should be driven by a non-coalesced userInteractive dispatch timer."
        )
        XCTAssertTrue(
            source.contains("leeway: .nanoseconds(100_000)"),
            "The strict 2K60 writer clock needs sub-millisecond timer leeway so scheduling jitter is measured rather than introduced."
        )
        XCTAssertTrue(
            pumpBody.contains("private let videoPaceClock = RemoteControlVideoPaceClock"),
            "The outbound frame pump must own a dedicated writer clock for frame cadence."
        )
        XCTAssertFalse(
            pumpBody.contains("maxChunkedStaleQueueCatchUpFramesPerDrain"),
            "Strict 2K60 sender must not replay stale queued HEVC frames to manufacture aggregate FPS."
        )
        XCTAssertFalse(
            pumpBody.contains("staleQueueCatchUpAgeThresholdMs"),
            "Stale HEVC queues should fail through backlog telemetry instead of enabling a hidden recovery threshold."
        )
        XCTAssertTrue(
            pumpBody.contains("private var effectiveMaxContentProcessedBacklogFrames: Int"),
            "The sender should make the negotiated wire format decide the actual contentProcessed backlog window."
        )
        XCTAssertTrue(
            pumpBody.contains("usesChunkedScreenFrameWire ? Self.maxChunkedContentProcessedBacklogFrames : Self.maxInFlightVideoSends"),
            "Only the strict chunked path should decouple frame cadence from contentProcessed completions; legacy paths should not drift accidentally."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let maxChunkedScreenFrameMessageBytes = 256 * 1024"),
            "LAN P2P screen frames must stay chunked while matching the iOS LAN receive chunk window, reducing 2K60 HEVC callback pressure without returning to hidden whole-frame sends."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let videoPaceEarlySendTolerance: TimeInterval = 0.0005"),
            "The 60 fps sender needs only a sub-millisecond early-send tolerance; wider tolerance overdrives the viewer and grows the Metal queue."
        )
        XCTAssertTrue(
            source.contains("Task(priority: .high)"),
            "The video pace clock should hop back into Swift concurrency at high priority so bounded strict cadence does not miss slots under 2K60 LAN load."
        )
        XCTAssertTrue(
            pumpBody.contains("usesChunkedScreenFrameWire = frameTransport == .binaryWire"),
            "The host must honor the viewer's sbc2-chunked-v1 wire request on the LAN screen path."
        )
        XCTAssertTrue(
            pumpBody.contains("RemoteDesktopStreamConfiguration.screenChannelWireFormatSBC2ChunkedV1"),
            "The LAN chunked path should use the same negotiated wire-format constant as WebRTC instead of a magic fallback string."
        )
        XCTAssertTrue(
            pumpBody.contains("makeOutboundScreenWireMessages(from: outboundData)"),
            "Video frames must be encrypted once and then split into SBC2 chunks, not chunked before encryption or sent as one hidden whole-frame body."
        )
        XCTAssertTrue(
            pumpBody.contains("RemoteDesktopScreenFrameWire.encodeChunkEnvelope("),
            "Chunk metadata must be explicit on the wire so the iOS receiver can fail fast on missing or reordered chunks."
        )
        XCTAssertTrue(
            pumpBody.contains("chunkedFrames: usedChunkedScreenWire ? 1 : 0"),
            "Mac tx telemetry must prove that counted video frames used the chunked screen wire."
        )
        XCTAssertTrue(
            pumpBody.contains("sentChunks: usedChunkedScreenWire ? wireMessageCount : 0"),
            "Mac tx telemetry must expose chunk counts so whole-frame length-framed sends cannot pass as chunked."
        )
        XCTAssertTrue(
            pumpBody.contains("return .singleUnbatched"),
            "Single-chunk SBC2 video frames should use a direct Network.framework send instead of paying batch overhead for one message."
        )
        XCTAssertTrue(
            pumpBody.contains("case singleUnbatched = \"single-unbatched\""),
            "Mac tx telemetry must distinguish direct single-chunk video sends from batched multi-chunk sends."
        )
        XCTAssertTrue(
            pumpBody.contains("wireSingleUnbatchedFrames"),
            "Mac tx telemetry must expose unbatched sends so a fake chunkSend=batch label cannot hide a flush/cadence regression."
        )
        XCTAssertTrue(
            pumpBody.contains("chunkSend=\\(chunkSendMode)"),
            "Mac tx telemetry should prove which Network.framework send mode carried strict SBC2 frames."
        )
        XCTAssertTrue(
            pumpBody.contains("sendModeKinds > 1"),
            "Mixed single and batched sends must be logged as mixed so a multi-chunk batch cannot be hidden by single-unbatched telemetry."
        )
        XCTAssertTrue(
            pumpBody.contains("chunkCapBytes=\\(Self.maxChunkedScreenFrameMessageBytes)"),
            "Mac tx telemetry must prove the SBC2 envelope cap that controls send callback pressure."
        )
        XCTAssertTrue(
            pumpBody.contains("Self.sendFramedMessages(")
                && pumpBody.contains("mode: sendMode"),
            "A video frame should complete only after every chunk has reached NWConnection contentProcessed, while preserving the explicit wire send mode."
        )
        XCTAssertTrue(
            pumpBody.contains("sendFramedMessagesBatchedInOrder("),
            "SBC2 chunks for one HEVC frame should enter NWConnection in frame order without per-chunk completion stalls."
        )
        XCTAssertTrue(
            pumpBody.contains("connection.batch {"),
            "Chunked frames should batch same-frame writes so large keyframes do not create 150ms+ send stalls."
        )
        XCTAssertTrue(
            pumpBody.contains("FramedMessageBatchCompletionState"),
            "Batched chunk writes still need one aggregated contentProcessed completion so backlog telemetry remains real."
        )
        XCTAssertTrue(
            pumpBody.contains("let contentBacklogFull = isContentProcessedBacklogFull"),
            "A full frame or byte-bounded contentProcessed backlog must remain visible in raw/ordered throttle telemetry."
        )
        XCTAssertTrue(
            pumpBody.contains("let queueBacklog = pendingFramesBeforeEnqueue >= Self.harmfulBackpressurePendingFrameThreshold"),
            "Only a bounded queued backlog near the smoke latency cap should count as harmful backpressure."
        )
        XCTAssertTrue(
            pumpBody.contains("videoSendInterval = 1.0 / Double(max(1, min(requestedFPS, 240)))"),
            "Stream configuration fps must be visible in sender telemetry so strict sessions can prove the negotiated cadence."
        )
        XCTAssertTrue(
            pumpBody.contains("private func drainIfNeeded(maxVideoFramesToSchedule requestedBudget: Int? = nil) async"),
            "The video pump should schedule from an explicit bounded budget so 60 fps recovery cannot empty the queue opportunistically."
        )
        XCTAssertTrue(
            pumpBody.contains("if !isStaleQueueCatchUpFrame, !isBoundedCadenceCatchUpFrame, videoPaceWakeDelay(from: now) > 0"),
            "Ordinary sends must be smoothed by the negotiated 60 fps cadence; bounded catch-up is the only explicit exception and stale queue recovery stays disabled."
        )
        XCTAssertTrue(
            pumpBody.contains("if !usesChunkedScreenFrameWire,\n           shouldDrainPendingVideoBeforeEnqueue(now: submittedAt)"),
            "Legacy callbacks may drain at the cadence deadline, but strict SBC2 sends must be scheduled only by the writer clock."
        )
        XCTAssertTrue(
            pumpBody.contains("let scheduleBudget = requestedBudget ?? videoScheduleBudget()"),
            "The sender should derive a bounded catch-up budget from elapsed cadence slots, not empty the queue opportunistically."
        )
        XCTAssertTrue(
            pumpBody.contains("maxVideoFramesPerDrain"),
            "A larger contentProcessed backlog window must not turn cadence recovery into a multi-frame burst."
        )
        XCTAssertFalse(
            pumpBody.contains("staleQueuedFrameCatchUpEligible"),
            "The strict sender should not have a stale-queue catch-up branch; stale frames must be exposed as backlog."
        )
        XCTAssertTrue(
            pumpBody.contains("let staleQueueCatchUpBudgetActive = false"),
            "Stale queue catch-up telemetry must remain impossible in the strict 2K60 sender."
        )
        XCTAssertTrue(
            pumpBody.contains("let boundedCadenceCatchUpBudgetActive = usesChunkedScreenFrameWire && scheduleBudget > 1"),
            "Cadence recovery must be an explicit high-FPS catch-up path instead of an opportunistic queue drain."
        )
        XCTAssertTrue(
            pumpBody.contains("!isNextVideoFrameFreshForBoundedCadenceCatchUp(now: now)"),
            "Bounded cadence catch-up must refuse stale queued frames and leave a diagnostic backlog instead."
        )
        XCTAssertTrue(
            pumpBody.contains("let budget = min(\n            max(1, elapsedCadenceSlots),\n            frameQueue.pendingFrames.count,\n            availableInFlightSlots\n        )"),
            "Cadence recovery must stay capped by maxVideoFramesPerDrain and the contentProcessed window."
        )
        XCTAssertTrue(
            pumpBody.contains("schedulableCadenceSlots: schedulableCadenceSlots"),
            "Cadence misses must compare against schedulable slots so timer lateness remains covered by schedule gap/jitter gates instead of being hidden by aggregate sent FPS."
        )
        XCTAssertTrue(
            pumpBody.contains("await drainIfNeeded(maxVideoFramesToSchedule: videoScheduleBudget(now: firedAt))"),
            "Cadence-slot accounting must use the DispatchSource fire time; actor hop delay is tracked separately by clockFireToDrainMaxMs."
        )
        XCTAssertTrue(
            pumpBody.contains("cadenceAnchorMode: isStaleQueueCatchUpFrame ? .staleQueueCatchUp : .normal"),
            "Stale queue catch-up must be visible in the scheduling path rather than hidden as ordinary cadence."
        )
        XCTAssertTrue(
            pumpBody.contains("var remainingVideoFrameBudget = max(0, scheduleBudget)"),
            "The sender must carry an explicit per-drain frame budget instead of emptying the queue opportunistically."
        )
        XCTAssertTrue(
            pumpBody.contains("remainingVideoFrameBudget -= 1"),
            "Each scheduled frame must consume the per-drain budget so completion callbacks cannot batch-drain old frames."
        )
        XCTAssertFalse(
            completionBody.contains("await drainIfNeeded("),
            "NWConnection contentProcessed completions must not catch up queued video frames; capture submissions own the 60 fps pace."
        )
        XCTAssertTrue(
            completionBody.contains("scheduleVideoPaceWakeIfNeeded()"),
            "A completed send may arm only a frame-interval wake so pending frames do not stall until an unrelated source callback."
        )
        XCTAssertFalse(
            paceWakeBody.contains("guard canScheduleVideoFrameSend else { return }"),
            "A full contentProcessed backlog must not stop the writer clock; the blocked cadence tick should be logged instead of disappearing."
        )
        XCTAssertTrue(
            paceWakeBody.contains("let delay = isContentProcessedBacklogFull\n            ? max(videoSendInterval, videoPaceWakeDelay(from: now))"),
            "When Network.framework contentProcessed is full, the strict sender should keep clock ownership without spinning immediate completion-driven drains."
        )
        XCTAssertTrue(
            pumpBody.contains("private func elapsedVideoCadenceSlots(now: Date) -> Int"),
            "Blocked writer-clock ticks need elapsed cadence-slot evidence so a final window cannot hide Network.framework stalls."
        )
        XCTAssertTrue(
            pumpBody.contains("noteVideoScheduleBudget(0, elapsedCadenceSlots: elapsedCadenceSlots)"),
            "A contentProcessed-full tick must record missed cadence instead of pretending no 60fps slot elapsed."
        )
        XCTAssertFalse(
            paceWakeBody.contains("Task.sleep"),
            "P2P remote 2K60 pacing must not depend on Swift concurrency sleep jitter."
        )
        XCTAssertTrue(
            paceWakeBody.contains("interval: videoSendInterval"),
            "P2P remote 2K60 pacing should arm the dedicated repeating writer clock at the frame deadline cadence."
        )
        XCTAssertTrue(
            pumpBody.contains("let drainStartedAt = Date()"),
            "Writer-clock telemetry must measure actor drain start so timer-to-actor latency is visible and bounded."
        )
        XCTAssertTrue(
            pumpBody.contains("await drainIfNeeded(maxVideoFramesToSchedule: videoScheduleBudget(now: firedAt))"),
            "Each writer-clock tick may fill only elapsed DispatchSource cadence slots; actor hop delay is separate telemetry."
        )
        XCTAssertTrue(
            pumpBody.contains("private func videoPaceWakeDelay(from now: Date) -> TimeInterval"),
            "Pending frames should be woken by the configured frame interval, not by immediate completion-driven catch-up."
        )
        XCTAssertTrue(
            pumpBody.contains("private func videoScheduleBudget(now: Date = Date()) -> Int"),
            "Short NWConnection tail latency should recover by filling only elapsed cadence slots within the existing in-flight window."
        )
        XCTAssertTrue(
            pumpBody.contains("effectiveMaxContentProcessedBacklogFrames - inFlightVideoSends"),
            "Cadence catch-up must stay inside the bounded contentProcessed backlog window instead of hiding LAN send pressure."
        )
        XCTAssertTrue(
            pumpBody.contains("private static let videoCadenceResetThreshold: TimeInterval = 0.250"),
            "Long stalls should reset the cadence anchor instead of bursting stale queued frames."
        )
        XCTAssertTrue(
            pumpBody.contains("private var effectiveVideoCadenceResetThreshold: TimeInterval"),
            "Chunked strict sessions need a tighter cadence reset than the legacy 250ms threshold so missed slots are not replayed as a burst."
        )
        XCTAssertTrue(
            pumpBody.contains("usesChunkedScreenFrameWire ? max(videoSendInterval * 2, Self.videoPaceEarlySendTolerance) : Self.videoCadenceResetThreshold"),
            "SBC2 chunked video should reset after at most two missed frame intervals instead of catching up a 250ms stale cadence."
        )
        XCTAssertTrue(
            pumpBody.contains("lastVideoFrameScheduledAt = nextVideoFrameCadenceAnchor(for: sendStartedAt)"),
            "Late timer wakeups should keep the deadline phase, while the sub-millisecond early-send tolerance prevents sustained viewer overdrive."
        )
        XCTAssertTrue(
            pumpBody.contains("private func nextVideoFrameCadenceAnchor(for now: Date) -> Date"),
            "The sender should recover small timer lateness by anchoring to the expected frame deadline."
        )
        XCTAssertTrue(
            source.contains("paceMs=\\(paceMs)"),
            "Real-device smoke logs must expose the configured video send pace for diagnosing 60 fps misses."
        )
        XCTAssertTrue(
            source.contains("maxFramesPerDrain=\\(snapshot.maxVideoFramesPerDrain)"),
            "Real-device smoke logs must prove strict SBC2 sender drains only one video frame per writer-clock tick."
        )
        XCTAssertTrue(
            source.contains("scheduleBudgetMax=\\(snapshot.scheduleBudgetMax)"),
            "Real-device smoke logs must expose actual per-drain send budget so catch-up bursts cannot pass as normal cadence."
        )
        XCTAssertTrue(
            source.contains("missedCadenceSlotsMax=\\(snapshot.missedCadenceSlotsMax)"),
            "Real-device smoke logs must expose missed writer-clock cadence slots instead of hiding them behind aggregate FPS."
        )
        XCTAssertTrue(
            source.contains("catchUp=bounded-cadence-catch-up-no-stale"),
            "Real-device smoke logs must show that only bounded non-stale cadence catch-up is enabled in the strict path."
        )
        XCTAssertTrue(
            source.contains("boundedCadenceCatchUp=\\(snapshot.boundedCadenceCatchUpFrames)"),
            "Real-device smoke logs must expose whether bounded catch-up actually ran."
        )
        XCTAssertTrue(
            source.contains("cadenceAnchor=strict-deadline-phase-no-stale"),
            "Real-device smoke logs must prove that strict SBC2 pacing keeps a deadline phase without enabling stale-frame catch-up."
        )
        XCTAssertTrue(
            source.contains("writerClock=dispatch-source-userinteractive"),
            "Real-device smoke logs must prove which writer clock produced the 60fps send cadence."
        )
        XCTAssertTrue(
            source.contains("writerClockStrict=1"),
            "Real-device smoke logs must prove strict DispatchSource timer mode so timer coalescing cannot masquerade as 60fps."
        )
        XCTAssertTrue(
            source.contains("sendScheduler=dispatch-clock-only"),
            "Strict SBC2 telemetry must prove the sender did not hide inline-drain work behind writer-clock labels."
        )
        XCTAssertTrue(
            source.contains("clockFireToDrainMaxMs=\\(clockFireToDrainMaxMs)"),
            "Real-device smoke logs must expose DispatchSource fire-to-actor-drain latency so writer-clock hop jitter cannot be hidden."
        )
        XCTAssertTrue(
            source.contains("paceWake=\\(snapshot.paceWakeDrains)"),
            "Real-device smoke logs must expose whether pending sends required cadence wakeups."
        )
        XCTAssertTrue(
            source.contains("staleQueueCatchUp=\\(snapshot.staleQueueCatchUpFrames)"),
            "Real-device smoke logs must expose when sender queue recovery used an extra in-order HEVC send."
        )
        XCTAssertTrue(
            source.contains("contentBacklogMax=\\(snapshot.inFlightVideoSendsMax)"),
            "Real-device smoke logs must expose the contentProcessed backlog separately from queued video backlog."
        )
        XCTAssertTrue(
            source.contains("contentBacklogBytesMax=\\(snapshot.contentBacklogBytesMax)"),
            "Real-device smoke logs must expose byte backlog so the larger frame window cannot hide socket pressure."
        )
        XCTAssertTrue(
            source.contains("contentBacklogByteLimit=\\(snapshot.contentBacklogByteLimit)"),
            "Real-device smoke logs must expose the byte backlog ceiling used by the strict sender."
        )
        XCTAssertTrue(
            source.contains("contentBacklogFull=\\(snapshot.contentBacklogFullEvents)"),
            "Real-device smoke logs must expose whether the writer hit the contentProcessed ceiling."
        )
        XCTAssertTrue(
            source.contains("oldestContentBacklogMs=\\(String(format: \"%.1f\", snapshot.oldestContentBacklogMs))"),
            "Real-device smoke logs must expose contentProcessed tail latency after decoupling writer cadence from completions."
        )
        XCTAssertTrue(
            source.contains("contentCallbackGapMaxMs=\\(contentCallbackGapMaxMs)"),
            "Real-device smoke logs must separate actual NWConnection contentProcessed callback cadence from actor/logging hops."
        )
        XCTAssertTrue(
            source.contains("contentActorHopMaxMs=\\(contentActorHopMaxMs)"),
            "Real-device smoke logs must expose actor hop delay after the contentProcessed callback so telemetry backpressure cannot be mistaken for socket backpressure."
        )
        XCTAssertTrue(
            source.contains("encodedToSubmitMaxMs=\\(encodedToSubmitMaxMs)"),
            "Real-device smoke logs must expose whether frames are already stale before they enter the outbound sender actor."
        )
        XCTAssertTrue(
            source.contains("submitGapMaxMs=\\(submitGapMaxMs)"),
            "Real-device smoke logs must expose capture/encoder submission gaps separately from writer gaps."
        )
        XCTAssertTrue(
            completionBody.contains("let sendLatencyMs = contentProcessedAt.timeIntervalSince(sendStartedAt) * 1_000"),
            "Mac send latency must be measured at the NWConnection contentProcessed callback, not after the actor resumes."
        )
        XCTAssertTrue(
            completionBody.contains("noteVideoFrameCompleted(at: completedAt, contentProcessedAt: contentProcessedAt)"),
            "The sender must log both callback cadence and actor-hop delay when diagnosing 60fps misses."
        )
        XCTAssertTrue(
            source.contains("queueAgeMaxMs=\\(String(format: \"%.1f\", snapshot.queuedFrameAgeMaxMs))"),
            "Real-device smoke logs must expose stale queued video rather than hiding it behind aggregate sent FPS."
        )
        XCTAssertTrue(
            source.contains("dequeuedAgeMaxMs=\\(String(format: \"%.1f\", snapshot.dequeuedFrameAgeMaxMs))"),
            "Real-device smoke logs must expose when the sender actually transmits stale queued frames."
        )
    }

    func testStrictP2PMediaPolicyDisablesCaptureFallbacks() throws {
        let source = try remoteControlManagerSource()

        XCTAssertTrue(
            source.contains("let strictMediaFallbacks = streamConfiguration?.allowsDegradedMediaFallbacks == false"),
            "P2P strict media sessions must derive a sender-side fail-fast gate from the viewer stream policy."
        )
        XCTAssertTrue(
            source.contains("failFastOnMediaFallbacks: strictMediaFallbacks"),
            "ScreenCaptureKitStreamer must run in fail-fast mode when the viewer forbids degraded media fallback."
        )
        XCTAssertTrue(
            source.contains("严格媒体策略禁止远控采集/编码降级或静默重启"),
            "Strict P2P sessions should expose encoder/capture fallback attempts as failures instead of silently restarting."
        )
        XCTAssertTrue(
            source.contains("if !strictMediaFallbacks {\n                    self.applyCaptureCompatibilityOverrideIfNeeded"),
            "Codec compatibility downgrade must remain unavailable in strict media sessions."
        )
    }

    func testStrictP2PMediaConfigDoesNotSerializeDamageReportsInVideoPath() throws {
        let source = try remoteControlManagerSource()
        let streamerSource = try screenCaptureKitStreamerSource()
        let smokeScript = try realDeviceP2PRemoteSmokeScriptSource()
        let pumpBody = try sourceSlice(
            from: "actor RemoteControlOutboundFramePump",
            to: "private final class PeerConnection",
            in: source
        )

        XCTAssertTrue(
            pumpBody.contains("if !damageTrackingEnabled {\n            latestDamageReport = nil\n        }"),
            "When the viewer disables damage telemetry for strict media, stale damage reports must not wait in the video sender."
        )
        XCTAssertTrue(
            pumpBody.contains("guard !closed, streamingEnabled, damageTrackingEnabled else"),
            "Damage reports must be rejected before they can wake the outbound video pump in strict 60fps sessions."
        )
        XCTAssertTrue(
            pumpBody.contains("if usesChunkedScreenFrameWire {\n            scheduleVideoPaceWakeIfNeeded()\n            return\n        }\n        await drainIfNeeded()"),
            "Strict SBC2 sessions must not let damage reports trigger an inline video drain outside the DispatchSource writer clock."
        )
        XCTAssertTrue(
            source.contains("mac-stream-config peer="),
            "The real-device smoke log should expose whether a strict stream accidentally re-enabled damage traffic."
        )
        XCTAssertTrue(
            source.contains("damage=\\(effectiveConfig.damageTrackingEnabled ?? false)"),
            "Mac stream configuration telemetry must include the damage flag that can contend with video sends."
        )
        XCTAssertTrue(
            streamerSource.contains("requestedGOP=\\(configuredKeyInterval) lowLatency=\\(lowLatencyEnabled)"),
            "SCK startup telemetry must expose the negotiated GOP so 2K60 HEVC IDR bursts can be tied to sender backlog."
        )
        XCTAssertTrue(
            streamerSource.contains("mac-sck-encoder targetFPS=\\(configuredFPS) codec="),
            "SCK encoder telemetry must expose the actual VideoToolbox keyframe interval used by the strict HEVC main path."
        )
        XCTAssertTrue(
            streamerSource.contains("lowLatencyRateControl=\\(lowLatencyRateControlEnabled)"),
            "SCK encoder telemetry must expose the VideoToolbox low-latency rate-control selection instead of hiding encoder mode changes."
        )
        XCTAssertTrue(
            streamerSource.contains("videoEncodeSubmissionQueue"),
            "Strict 2K60 HEVC must not let a blocking VTCompressionSessionEncodeFrame call stall the display-cadence timer."
        )
        XCTAssertTrue(
            streamerSource.contains("encodePreparedVideoPixelBuffer"),
            "SCK cadence should reserve one timestamp per tick and submit encode work off the cadence queue without enabling burst catch-up."
        )
        XCTAssertTrue(
            streamerSource.contains("actualEncodeLatencyMaxMs"),
            "SCK telemetry must distinguish real VideoToolbox encode latency from logical cadence delay."
        )
        XCTAssertTrue(
            streamerSource.contains("encodeSubmissionDelayMaxMs"),
            "SCK telemetry must expose encode submission queue delay when diagnosing missed 60fps windows."
        )
        XCTAssertTrue(
            streamerSource.contains("strict-video-first-frame-timeout"),
            "Strict 2K60 HEVC must fail fast with structured first-frame evidence when SCK/VT never produces an encoded frame."
        )
        XCTAssertTrue(
            streamerSource.contains("mac-sck-encode-failed targetFPS=\\(configuredFPS) codec="),
            "Strict HEVC smoke artifacts must expose the exact VideoToolbox encode failure status instead of only a window counter."
        )
        XCTAssertTrue(
            streamerSource.contains("mac-sck-encode-failed stage=callback targetFPS=\\(configuredFPS) codec="),
            "Asynchronous VideoToolbox callback failures must expose status and flags instead of only incrementing encodeFailures."
        )
        XCTAssertTrue(
            streamerSource.contains("VTCompressionSession callback status=\\(statusCode),flags=\\(infoFlags.rawValue),frameDropped=\\(frameDropped),missingSample=\\(missingSample)"),
            "Strict HEVC callback failures must record callback status, flags, and missing-sample state in the fail-fast detail."
        )
        XCTAssertTrue(
            streamerSource.contains("sourceFrameRepeatCount=\\(timing.sourceFrameRepeatCount)"),
            "Strict HEVC callback failures must expose repeated source-frame submissions instead of hiding cadence replay pressure."
        )
        XCTAssertTrue(
            streamerSource.contains("sourceFrameAgeMs=\\(sourceAge)"),
            "Strict HEVC callback failures must expose source-frame age so VT drops can be separated from stale cadence submissions."
        )
        XCTAssertTrue(
            streamerSource.contains("dataRateBurstLimitBytes=\\(dataRateBurstLimitBytes)"),
            "Strict HEVC callback failures must include the applied VideoToolbox burst window used to diagnose status=0 frameDropped callbacks."
        )
        XCTAssertTrue(
            streamerSource.contains("issue: \"strict-video-encode-failed\""),
            "Strict HEVC encode failures must become fail-fast media failures rather than silent compatibility restarts."
        )
        XCTAssertTrue(
            smokeScript.contains("timestamp is None or timestamp > pass_time"),
            "The real-device smoke gate should accept the startup HEVC encoder configuration that remains active through the final window."
        )
        XCTAssertTrue(
            smokeScript.contains("no Mac HEVC encoder configuration telemetry before final pass"),
            "The real-device smoke gate must still fail when the run never proves the strict HEVC encoder configuration."
        )
        XCTAssertTrue(
            smokeScript.contains("expected_encoder_gop = max(60, int(round(target_fps)))"),
            "The real-device smoke gate must mirror the strict HEVC one-second GOP rule instead of assuming every run targets exactly 60 fps."
        )
        XCTAssertTrue(
            smokeScript.contains("dataRateBurstLimitBytes"),
            "The real-device smoke gate must require the HEVC short-window burst cap that keeps IDR frames inside the SBC2 transport budget."
        )
        XCTAssertTrue(
            smokeScript.contains("dataRateBurstWindowMs"),
            "The real-device smoke gate must prove the HEVC burst cap is enforced on the single-frame transport window."
        )
        XCTAssertTrue(
            smokeScript.contains("hevc_burst_headroom_multiplier = 8"),
            "The real-device smoke gate must mirror the bounded HEVC short-window headroom used to prevent VT realtime rate-control drops."
        )
        XCTAssertTrue(
            smokeScript.contains("hevc_single_chunk_encoded_budget_bytes = 256 * 1024 - 36 - 68 - 36"),
            "The real-device smoke gate must bind HEVC burst size to the actual SBC2 single-chunk encrypted frame budget."
        )
        XCTAssertTrue(
            smokeScript.contains("dataRateLimitsStatus"),
            "The real-device smoke gate must prove VideoToolbox accepted the HEVC DataRateLimits property."
        )
        XCTAssertTrue(
            smokeScript.contains("dataRateLimitsApplied"),
            "The real-device smoke gate must fail if the HEVC burst cap is only logged but not read back from VideoToolbox."
        )
        XCTAssertTrue(
            smokeScript.contains("lowLatencyRateControl"),
            "The real-device smoke gate must require explicit VideoToolbox low-latency rate-control telemetry."
        )
        XCTAssertTrue(
            streamerSource.contains("maxFrameDelayCount=\\(maxFrameDelayCount)"),
            "Mac HEVC telemetry must expose the VideoToolbox frame-delay budget used to diagnose status=0 frameDropped callbacks."
        )
        XCTAssertTrue(
            streamerSource.contains("static func videoToolboxMaxFrameDelayCount("),
            "The 2K60 HEVC path should use an explicit bounded VideoToolbox delay policy instead of a magic MaxFrameDelayCount literal."
        )
        XCTAssertTrue(
            smokeScript.contains("encoder_max_frame_delay_count != 3"),
            "The real-device smoke gate must prove the strict 2K60 HEVC path is using the bounded three-frame encoder delay window."
        )
        XCTAssertTrue(
            smokeScript.contains("sck_cadence_catch_up_limit = 2"),
            "The real-device smoke gate must fail if the SCK producer exceeds the bounded two-frame cadence recovery path."
        )
        XCTAssertTrue(
            smokeScript.contains("sender_cadence_catch_up_limit = 1"),
            "The real-device smoke gate must prove the Mac sender stays on the single-frame strict dispatch-clock path."
        )
        XCTAssertTrue(
            smokeScript.contains("bounded strict producer path: cadenceCatchUpLimit"),
            "The real-device smoke gate must keep the SCK producer on its two-frame bounded cadence path."
        )
        XCTAssertTrue(
            smokeScript.contains("display cadence exceeded bounded producer recovery inside final pass window"),
            "The real-device smoke gate must fail if final-window 60 fps depends on unbounded SCK producer catch-up instead of bounded steady cadence."
        )
        XCTAssertTrue(
            smokeScript.contains("Mac remote tx emitted multi-chunk HEVC frames inside final pass window"),
            "The real-device smoke gate must fail if strict HEVC 2K60 still emits multi-chunk frames after the burst cap."
        )
        XCTAssertTrue(
            smokeScript.contains("Mac remote tx did not expose a real Network.framework send mode for SBC2 frames"),
            "The real-device smoke gate must require real send-mode evidence instead of trusting inferred chunkSend labels."
        )
        XCTAssertTrue(
            smokeScript.contains("Mac remote tx used single-message sends for multi-chunk SBC2 frames"),
            "The real-device smoke gate must keep multi-chunk SBC2 frames on the explicit batched path."
        )
        XCTAssertTrue(
            smokeScript.contains("Mac remote tx did not prove an explicit Network.framework send mode for every final-window frame"),
            "The final pass window must prove every SBC2 frame used a real Network.framework send path."
        )
        XCTAssertTrue(
            smokeScript.contains("Mac remote SBC2 chunk cap did not match the LAN receive window"),
            "The real-device smoke gate must fail when the sender regresses to the old 16 KB chunk cap."
        )
        XCTAssertTrue(
            smokeScript.contains("sender_content_backlog_frame_limit = 18"),
            "The real-device smoke gate must require the bounded contentProcessed backlog window used by the strict SBC2 sender."
        )
        XCTAssertTrue(
            smokeScript.contains("minimum_source_observed_seconds = max(2.0, soak_seconds - 4.0)") &&
            smokeScript.contains("minimum_source_samples = 2") &&
            smokeScript.contains("source_observed_seconds = (source_time_end - source_time_start).total_seconds()") &&
            smokeScript.contains("Mac smoke source heartbeat coverage was too short inside final pass window") &&
            smokeScript.contains("source_frame_delta = source_frame_end - source_frame_start") &&
            smokeScript.contains("macSourceRenderProgressFPS="),
            "The smoke source gate must prove helper liveness while treating helper aggregate render cadence as diagnostic evidence behind the SCK and remote-display hard gates."
        )
        XCTAssertTrue(
            smokeScript.contains("strict_mac_sender_queue_limit = 6"),
            "The Mac pending queue cap must be enforced on the normal one-chunk path, not hidden under the multi-chunk failure branch."
        )
        XCTAssertTrue(
            smokeScript.contains("\nif tx_content_backlog_max >= sender_content_backlog_frame_limit:"),
            "The contentProcessed backlog ceiling must be enforced even when cadence telemetry is otherwise clean."
        )
        XCTAssertTrue(
            smokeScript.contains("contentBacklogByteLimit\") != 12 * 256 * 1024"),
            "The real-device smoke gate must require the byte-bounded contentProcessed backlog window used by the strict SBC2 sender."
        )
        XCTAssertTrue(
            smokeScript.contains("contentProcessed backlog exceeded the strict frame limit"),
            "The real-device smoke gate must still fail if decoupled scheduling hides an excessive NWConnection completion backlog."
        )
        XCTAssertTrue(
            smokeScript.contains("oldest contentProcessed backlog exceeded 300ms"),
            "The real-device smoke gate must fail if contentProcessed completions lag beyond the explicit 60fps backlog budget."
        )
        XCTAssertTrue(
            smokeScript.contains("contentProcessed latency exceeded the 200ms budget"),
            "The real-device smoke gate must fail if a contentProcessed tail exceeds the explicit Network.framework callback-tail budget."
        )
        XCTAssertTrue(
            smokeScript.contains("contentProcessed callback gap exceeded the 200ms budget"),
            "The real-device smoke gate must fail on actual NWConnection contentProcessed callback stalls, not only actor-completion gaps."
        )
        XCTAssertTrue(
            smokeScript.contains("contentProcessed actor hop exceeded 25ms"),
            "The real-device smoke gate must expose telemetry/actor backpressure instead of misclassifying it as socket throughput."
        )
        XCTAssertTrue(
            smokeScript.contains("sender schedule gap exceeded 50ms"),
            "The real-device smoke gate must fail if the Mac sender only proves aggregate FPS while scheduling frames in bursts."
        )
        XCTAssertTrue(
            smokeScript.contains("direct encoded-frame handoff to the sender pump"),
            "The real-device smoke gate must prove encoded frames bypass the old peer queue hop before entering the sender pump."
        )
        XCTAssertTrue(
            smokeScript.contains("contentProcessed backlog hit the strict frame ceiling"),
            "The real-device smoke gate must fail if the writer repeatedly reaches the contentProcessed ceiling."
        )
        XCTAssertTrue(
            smokeScript.contains("queued frame age exceeded 100ms"),
            "The real-device smoke gate must fail if queued HEVC frames become stale instead of claiming a clean 60 fps pass."
        )
        XCTAssertTrue(
            smokeScript.contains("dequeued frame age exceeded 100ms"),
            "The real-device smoke gate must fail if stale queued frames are transmitted to satisfy aggregate FPS."
        )
        XCTAssertTrue(
            smokeScript.contains("stale queue catch-up was nonzero"),
            "The real-device smoke gate must fail if the final 60 fps window still depends on explicit stale-queue catch-up."
        )
        XCTAssertTrue(
            smokeScript.contains("macStaleQueueCatchUp="),
            "The real-device smoke summary must expose whether the final window used stale-queue catch-up."
        )
        XCTAssertTrue(
            smokeScript.contains("macContentCallbackGapMaxMs="),
            "The real-device smoke summary must expose the raw contentProcessed callback cadence."
        )
        XCTAssertTrue(
            smokeScript.contains("macContentActorHopMaxMs="),
            "The real-device smoke summary must expose actor-hop delay separately from socket callback timing."
        )
        XCTAssertTrue(
            smokeScript.contains("macScheduleGapMaxMs="),
            "The real-device smoke summary must expose the sender schedule gap to distinguish sender jitter from receiver batching."
        )
        XCTAssertTrue(
            smokeScript.contains("lanSourceToReadMaxMs="),
            "The real-device smoke summary must expose source-to-read latency instead of only aggregate receive FPS."
        )
    }

    func testRealDeviceP2PRemoteSmokePythonHeredocsAreIndentationClean() throws {
        let script = try realDeviceP2PRemoteSmokeScriptSource()
        let blocks = pythonHeredocBlocks(in: script)

        XCTAssertGreaterThan(
            blocks.count,
            0,
            "The smoke script should keep Python helpers in parseable heredoc blocks."
        )
        for (index, block) in blocks.enumerated() {
            XCTAssertFalse(
                block.contains("\t"),
                "Python heredoc block \(index) must not use tabs; bash -n will not catch TabError before the real-device run."
            )
        }
    }

    func testP2PSyncRefreshIsThrottledUnderVideoBackpressure() throws {
        let source = try remoteControlManagerSource()

        XCTAssertTrue(
            source.contains("private static let sendQueueOverflowSyncRefreshMinimumInterval: TimeInterval = 2.0"),
            "A full P2P video send queue should not request a new forced keyframe on every dropped predictive frame."
        )
        XCTAssertTrue(
            source.contains("private static let waitingForSyncFrameRefreshMinimumInterval: TimeInterval = 2.0"),
            "Waiting-for-sync recovery should be slow enough to avoid an IDR storm on constrained LAN links."
        )
        XCTAssertTrue(
            source.contains("requestSyncRefreshIfNeeded(\n                reason: \"send-queue-overflow\",\n                minimumInterval: Self.sendQueueOverflowSyncRefreshMinimumInterval\n            )"),
            "Queue overflow recovery must use the shared throttle instead of bypassing it."
        )
        XCTAssertTrue(
            source.contains("streamer?.requestKeyFrameRefresh(reason: \"outbound-frame-drop\", count: 1)"),
            "A queue-overflow recovery request should force only one IDR frame."
        )
        XCTAssertTrue(
            source.contains("var lastViewerStreamRefreshAt: Date = .distantPast"),
            "Viewer-initiated refreshes should also be throttled on the Mac sender."
        )
        XCTAssertTrue(
            source.contains("captureStreamer?.requestKeyFrameRefresh(reason: \"viewer-stream-refresh\", count: 1)"),
            "Viewer refresh tokens should request one keyframe instead of compounding backpressure with multiple forced IDRs."
        )
        XCTAssertFalse(
            source.contains("requestSyncRefreshIfNeeded(reason: \"send-queue-overflow\", minimumInterval: 0)"),
            "Immediate keyframe retries can amplify backpressure into a video frame-rate collapse."
        )
        XCTAssertFalse(
            source.contains("requestSyncRefreshIfNeeded(reason: \"waiting-for-sync-frame\", minimumInterval: 0.4)"),
            "The recovery loop must not keep forcing large keyframes multiple times per second."
        )
    }

    func testFullFrameDamageFallbackDoesNotForceContinuousSceneCutIDRs() throws {
        let source = try screenCaptureKitStreamerSource()
        let body = try sourceSlice(
            from: "private func shouldTreatDamageAsSceneCut(",
            to: "private func damageReport(",
            in: source
        )

        XCTAssertTrue(
            body.contains("if report.fullFrameFallback {\n            return false\n        }"),
            "Full-frame damage fallback means damage tracking is coarse; it must not force IDR frames on every sample."
        )
        XCTAssertFalse(
            body.contains("if report.fullFrameFallback {\n            return true\n        }"),
            "Treating coarse full-frame damage as a scene cut creates a continuous keyframe storm."
        )
    }

    func testSceneCutRecoveryDoesNotCreateIDRStormDuringComplexOperations() throws {
        let source = try screenCaptureKitStreamerSource()
        let body = try sourceSlice(
            from: "private static let sceneCutKeyFrameRefreshCount",
            to: "private func reportStrictMediaFailure(",
            in: source
        )
        let annexBBody = try sourceSlice(
            from: "private func annexBPayload(",
            to: "private func nalUnitHeaderLength(",
            in: source
        )

        XCTAssertTrue(
            body.contains("private static let sceneCutKeyFrameRefreshCount = 1"),
            "Scene-cut recovery should request one IDR; repeated forced keyframes can collapse 2K60 during app switching or damage surges."
        )
        XCTAssertTrue(
            body.contains("private static let activeTransitionSceneCutMinimumInterval: TimeInterval = 0.50"),
            "Active app/space transitions can fire in bursts, so scene-cut recovery needs a real throttle."
        )
        XCTAssertTrue(
            body.contains("private static let damageSceneCutMinimumInterval: TimeInterval = 0.75"),
            "Damage-surge recovery should be slower than the frame cadence to avoid keyframe storms under complex UI updates."
        )
        XCTAssertTrue(
            body.contains("requestKeyFrameRefresh(reason: \"scene-cut-\\(reason)\", count: Self.sceneCutKeyFrameRefreshCount)"),
            "Scene-cut recovery must use the bounded IDR count instead of per-caller multi-keyframe requests."
        )
        XCTAssertFalse(
            body.contains("requestSceneCutRecovery(reason: String, count: Int = 3)"),
            "A multi-IDR default makes normal scene changes expensive enough to show as short frame-rate drops."
        )
        XCTAssertFalse(
            body.contains("count: 4"),
            "Active app and full-frame damage events must not force four consecutive IDR frames."
        )
        XCTAssertTrue(
            annexBBody.contains("let pendingParameterSetReannounce = consumePendingParameterSetReannounce()"),
            "Scene-cut parameter-set reannounce should be consumed with the forced IDR instead of leaking into the next predictive frame."
        )
        XCTAssertFalse(
            annexBBody.contains("|| consumePendingParameterSetReannounce()"),
            "Short-circuit parameter-set consumption can create an unnecessary extra parameter-set prepend after a sync frame."
        )
    }

    func testWebRTCFallbackAudioDoesNotUseMainActorSendLoop() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let audioSupportSourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCAudioFallbackSupport.swift")
        let source = try String(contentsOf: managerSourceURL, encoding: .utf8)
            + "\n"
            + String(contentsOf: audioSupportSourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("WebRTCAudioFallbackSender"),
            "WebRTC fallback audio should use a dedicated bounded sender."
        )
        XCTAssertTrue(
            source.contains("generation &+="),
            "WebRTC fallback audio sender should fence old-key sends across close/rekey."
        )
        XCTAssertTrue(
            source.contains("drainTask?.cancel()"),
            "WebRTC fallback audio sender should cancel in-flight background drain work on close."
        )
        XCTAssertFalse(
            source.contains("Task { @MainActor [weak self] in\n                                guard let self else { return }\n                                do {\n                                    let ciphertext = try encryptAppPayload(audioWire"),
            "WebRTC fallback audio must not encrypt and send every audio chunk from MainActor."
        )
        XCTAssertFalse(
            source.contains("await directAudioFallbackSender?.close()\n                    }\n#endif\n                    encodedFrameStore.clear()"),
            "WebRTC fallback audio close should not be fire-and-forget from the screen streaming defer."
        )

        let fallbackSenderInit = try sourceSlice(
            from: "directAudioFallbackSender = WebRTCAudioFallbackSender(",
            to: "scheduleRealtimeAudioAttachIfNeeded()",
            in: source
        )
        XCTAssertTrue(
            fallbackSenderInit.contains("packetType: .remoteDesktopAudio"),
            "Fallback audio must use its own secure envelope packet type so control-channel audio cannot advance the screen replay lane."
        )
        XCTAssertFalse(
            fallbackSenderInit.contains("packetType: .remoteDesktop\n"),
            "Fallback audio must not share the screen packet type across independently ordered WebRTC data channels."
        )
    }

    func testRemoteAudioPlaybackOverflowUsesBackpressureBeforeReset() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteDesktop/AudioRedirection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("queued-audio-overflow"),
            "Normal live-audio jitter must not repeatedly stop/reset the player node; that creates audible crackle."
        )
        XCTAssertTrue(
            source.contains("logPlaybackBackpressureIfNeeded("),
            "Playback queue pressure should drop excess live chunks and let already scheduled audio drain naturally."
        )
        XCTAssertTrue(
            source.contains("queued-audio-runaway"),
            "A hard player reset should remain as a last-resort runaway guard, not the normal overflow path."
        )
        XCTAssertTrue(
            source.contains("queuedFrameCount + chunk.frameLength > currentMaxQueuedFrames"),
            "The soft cap must be checked before scheduling more audio into an already full player queue."
        )
        XCTAssertTrue(
            source.contains("Task.detached(priority: .utility) { [weak self, decodeWorker, chunk, generation] in"),
            "Remote audio decoding should stay below video/render priority to avoid starving the display path."
        )
        XCTAssertFalse(
            source.contains("Task.detached(priority: .userInitiated) { [weak self, decodeWorker, chunk, generation] in"),
            "Audio decoding must not run at userInitiated priority while the screen pipeline is active."
        )
    }

    func testP2PAudioDoesNotFallbackToPCMWhenAACEncodingFails() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("系统音频 AAC 编码失败，已丢弃该音频块以保护远控视频帧率"),
            "If AAC encoding fails, remote-control audio should be dropped instead of falling back to high-bitrate PCM on the shared P2P pipe."
        )
        XCTAssertTrue(
            source.contains("if requestedAudioEncoding == .aacLC {\n            return\n        }"),
            "AAC-requested transport must not continue into PCM fallback after compression failure."
        )
        XCTAssertFalse(
            source.contains("系统音频 AAC 编码失败，已回退为 PCM 传输"),
            "PCM fallback can flood the shared P2P connection and collapse video frame rate."
        )
    }

    private func sourceSlice(from startMarker: String, to endMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }

    private func pythonHeredocBlocks(in script: String) -> [String] {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [String] = []
        var current: [String]?

        for line in lines {
            if line.contains("<<'PY'") {
                current = []
                continue
            }

            if line == "PY", let block = current {
                blocks.append(block.joined(separator: "\n"))
                current = nil
                continue
            }

            current?.append(line)
        }

        return blocks
    }
}
