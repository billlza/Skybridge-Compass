import XCTest

final class RemoteControlAudioSchedulingTests: XCTestCase {
    private func remoteControlManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func screenCaptureKitStreamerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func testP2PAudioDrainIsDecoupledFromVideoFramePump() throws {
        let source = try remoteControlManagerSource()

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
            source.contains("private let maxQueuedAudioPayloads = 3"),
            "P2P audio must keep only a tiny live queue because it shares the LAN remote-control connection with video frames."
        )
        XCTAssertTrue(
            source.contains("private let maxAudioVideoFrameGap: TimeInterval = 0.08"),
            "Audio should be suppressed when video is already below an acceptable live cadence."
        )
        XCTAssertTrue(
            source.contains("guard canSendAudioWithoutCompetingWithVideo else"),
            "Audio should be dropped whenever the video sender has backlog or an in-flight frame send."
        )
        XCTAssertTrue(
            source.contains("Date().timeIntervalSince(lastSentFrameAt) <= maxAudioVideoFrameGap"),
            "The video-priority gate must stop audio if video cadence has already collapsed."
        )
        XCTAssertTrue(
            source.contains("Task.detached(priority: .utility) {\n                    await outboundFramePump.submitAudioPayload(wirePayload)\n                }"),
            "Captured audio chunks should enter the outbound pump at utility priority so they cannot preempt screen-frame work."
        )
        XCTAssertFalse(
            source.contains("Task.detached(priority: .userInitiated) {\n                    await outboundFramePump.submitAudioPayload(wirePayload)"),
            "Audio chunk submission must not run at the same priority as latency-critical video."
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

    func testWebRTCFallbackAudioDoesNotUseMainActorSendLoop() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

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
}
